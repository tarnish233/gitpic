#!/usr/bin/env python3
"""The one implementation of what a GitHub Release body is.

A changelog version section is two documents in one: a short summary of the
user-visible changes, then a ``<!-- release-notes-end ... -->`` marker, then the full
detail — what was measured, which design was rejected — that stays in the file. The
Release is read by someone deciding whether to upgrade, so only the part above the
marker is published, and ``GitPic.app`` renders that same text in its update sheet.
The two things a user might read are then identical by construction rather than by
being written twice.

**Why this module exists.** That rule used to have two implementations: an awk
program in ``release.yml`` did the extracting, and a substring test in
``check_manifests.py`` did the checking. They drifted in three ways, all of them
found by review rather than by a failing release:

1. The awk stopped at any line *containing* ``release-notes-end``. A summary bullet
   that merely named the marker — which the 0.19.0 notes were one edit away from
   having, since they document this very feature — truncated the Release to its
   heading alone. The workflow's own non-empty guard passed, because that heading is
   not empty, and the app then stripped it and rendered 「这个版本没有附更新说明。」
2. The checker's substring test could not tell a correctly placed marker from one at
   the bottom of the section. A marker below the detail passed the check and
   published everything — the exact outcome the check exists to prevent.
3. The checker only ever ran in ``ci.yml``, on pushes and PRs to main. ``release.yml``
   triggers on a tag, never invoked it, and shares no reusable workflow with it — so
   ``git push --follow-tags`` could publish before CI had finished, and the guard was
   absent from the one path where it mattered. ``release.yml`` said otherwise in a
   comment.

So: one rule, in one place, used by the publisher and by the checker.

**No marker means publish the whole section**, deliberately. Every one of the 39
sections before 0.19.0 predates the marker, and backfilling one of those tags has to
keep working. What stops that from being a silent hole for *new* releases is
:data:`MARKER_SINCE`: from 0.19.0 on, a missing marker is an error rather than a
licence to publish the internal detail.
"""

from __future__ import annotations

import sys
from pathlib import Path

#: The marker, recognised only at the start of a line (after leading whitespace).
#:
#: Anchoring it is the fix for the truncation above: a line has to *be* the marker
#: comment, not mention it. A bullet reads ``- 新增 `release-notes-end` 标记…`` and is
#: now inert, while the marker itself is always written at column zero.
MARKER = "<!-- release-notes-end"

#: The first version required to carry a marker.
#:
#: The mechanism, not a style preference: it is what lets the guard run on the
#: publishing path without breaking a re-run of an older tag. Below this a marker is
#: optional and its absence publishes the whole section; at or above it, a missing
#: marker fails the check that now gates ``publish``.
MARKER_SINCE = (0, 19, 0)


def _as_tuple(version: str) -> tuple[int, ...]:
    """``"0.19.0"`` -> ``(0, 19, 0)``; anything unparseable sorts above everything.

    Fail-closed on purpose. An unrecognisable version is not a reason to stop
    requiring the marker — it reaches here from ``Cargo.toml`` on the publishing
    path, and "I could not read the version" must not read as "no marker needed".
    """
    try:
        return tuple(int(p) for p in version.split("."))
    except ValueError:
        return (sys.maxsize,)


def section_lines(text: str, version: str) -> list[str] | None:
    """The lines of one version's section: everything after its heading, up to the next.

    The heading rule matches the awk this replaces exactly — the whole line, or the
    heading followed by a space, so ``## [0.19.0] - 2026-08-24`` matches and
    ``## [0.19.01]`` does not. The looser ``^## \\[0.19.0\\]`` regex the checker used
    would also have matched ``## [0.19.0]-2026``, which the publisher would then have
    skipped: two implementations, two answers, and the checker was the lenient one.
    """
    heading = f"## [{version}]"
    lines = text.splitlines()
    start = None
    for i, line in enumerate(lines):
        if line == heading or line.startswith(heading + " "):
            start = i + 1
            break
    if start is None:
        return None
    out: list[str] = []
    for line in lines[start:]:
        if line.startswith("## ["):
            break
        out.append(line)
    return out


def split(text: str, version: str) -> tuple[list[str], list[str] | None] | None:
    """``(above, below)`` around the marker. ``below`` is ``None`` when there is none.

    ``None`` for a version with no section at all — the caller decides whether that is
    a failure to report or a file to skip.
    """
    lines = section_lines(text, version)
    if lines is None:
        return None
    for i, line in enumerate(lines):
        if line.lstrip().startswith(MARKER):
            return lines[:i], lines[i + 1 :]
    return lines, None


def body(text: str, version: str) -> str | None:
    """The Release body: the text above the marker, or the whole section without one."""
    parts = split(text, version)
    if parts is None:
        return None
    return "\n".join(parts[0])


def problems(text: str, version: str, name: str) -> list[str]:
    """Everything wrong with one changelog's section for `version`, as messages.

    Placement is checked whenever a marker is present, and presence only from
    :data:`MARKER_SINCE` — so an old section stays valid, and a new one cannot put its
    marker somewhere that defeats it.
    """
    parts = split(text, version)
    if parts is None:
        return [
            f"{name} has no `## [{version}]` section, but Cargo.toml says {version} — "
            f"rename the unreleased heading before tagging"
        ]
    above, below = parts
    lines = section_lines(text, version) or []
    found = [line for line in lines if line.lstrip().startswith(MARKER)]
    msgs: list[str] = []

    if not found:
        if _as_tuple(version) >= MARKER_SINCE:
            msgs.append(
                f"{name}'s `## [{version}]` section has no `{MARKER} -->` marker, so the "
                f"whole section — internal detail included — would become the GitHub "
                f"Release body and the app's update text. Add the marker after the short "
                f"summary of user-visible changes"
            )
        return msgs

    if len(found) > 1:
        msgs.append(
            f"{name}'s `## [{version}]` section has {len(found)} `{MARKER} -->` markers; "
            f"extraction stops at the first, so the rest are silently doing nothing"
        )
    if not "\n".join(above).strip():
        msgs.append(
            f"{name}'s `{MARKER} -->` marker sits above the summary in `## [{version}]`, "
            f"so the Release body would be empty and the app would render "
            f"「这个版本没有附更新说明。」 Move it below the user-visible changes"
        )
    if below is not None and not "\n".join(below).strip():
        msgs.append(
            f"{name}'s `{MARKER} -->` marker is at the end of `## [{version}]` with "
            f"nothing below it, so it withholds nothing and the whole section still "
            f"publishes. Move it above the detail it is meant to keep out"
        )
    return msgs


def _self_test() -> int:
    """Assertions over synthetic changelogs, run by CI.

    A ``--self-test`` flag rather than a test file because this repository has no
    Python test infrastructure at all — no pytest, no runner, no `setup-python` step —
    and the shape that gets run is worth more than the shape that is conventional.
    Each case below is one of the three drifts in this module's docstring.
    """
    sample = "\n".join(
        [
            "# 更新日志",
            "",
            "## [0.19.0] - 2026-08-24",
            "",
            "### 主题一行",
            "",
            "- 用户可见的一条",
            "",
            f"{MARKER}: 以上是正文 -->",
            "",
            "### 内部",
            "",
            "- 只留在文件里的细节",
            "",
            "## [0.18.1] - 2026-08-23",
            "",
            "### 旧主题",
            "",
            "- 没有标记的一段",
            "",
        ]
    )
    failures: list[str] = []

    def check(label: str, cond: bool) -> None:
        if not cond:
            failures.append(label)

    got = body(sample, "0.19.0")
    check("body stops at the marker", got == "\n### 主题一行\n\n- 用户可见的一条\n")
    check("body excludes the detail", "只留在文件里的细节" not in (got or ""))
    check("a marked section is clean", problems(sample, "0.19.0", "x") == [])

    # Drift 1: a bullet that merely names the marker must not truncate anything.
    mentions = sample.replace("- 用户可见的一条", f"- 新增 `{MARKER[4:]}` 标记，只发布标记之前")
    check("a bullet naming the marker is inert", "标记，只发布标记之前" in (body(mentions, "0.19.0") or ""))
    check("and it is not a problem", problems(mentions, "0.19.0", "x") == [])

    # No marker: fine below MARKER_SINCE, an error at or above it.
    check("an old section publishes whole", "没有标记的一段" in (body(sample, "0.18.1") or ""))
    check("and is not required to have one", problems(sample, "0.18.1", "x") == [])
    unmarked = sample.replace(f"{MARKER}: 以上是正文 -->\n", "")
    check("a new section must have one", len(problems(unmarked, "0.19.0", "x")) == 1)

    # Drift 2: placement.
    bottom = "\n".join(
        ["## [0.19.0] - x", "", "### 主题", "", "- 一条", "", "### 内部", "", "- 细节", "", f"{MARKER} -->", ""]
    )
    check("a marker at the end is caught", any("withholds nothing" in m for m in problems(bottom, "0.19.0", "x")))
    top = "\n".join(["## [0.19.0] - x", "", f"{MARKER} -->", "", "### 主题", "", "- 一条", ""])
    check("a marker above the summary is caught", any("above the summary" in m for m in problems(top, "0.19.0", "x")))
    twice = sample.replace("### 内部", f"{MARKER} -->\n\n### 内部")
    check("two markers are caught", any("markers" in m for m in problems(twice, "0.19.0", "x")))

    # Heading match: exact line or heading plus a space, like the awk.
    check("a missing section is reported", problems(sample, "9.9.9", "x")[0].startswith("x has no"))
    check("a longer version is not a prefix match", body(sample, "0.19") is None)

    for f in failures:
        print(f"  - {f}", file=sys.stderr)
    if failures:
        print(f"release_notes self-test: {len(failures)} case(s) failed", file=sys.stderr)
        return 1
    print("release_notes self-test passed")
    return 0


def main(argv: list[str]) -> int:
    if "--self-test" in argv:
        return _self_test()
    if len(argv) != 2:
        print(
            "usage: release_notes.py <changelog> <version>\n"
            "       release_notes.py --self-test",
            file=sys.stderr,
        )
        return 2
    path, version = Path(argv[0]), argv[1]
    try:
        text = path.read_text()
    except OSError as e:
        print(f"cannot read {path}: {e}", file=sys.stderr)
        return 1
    out = body(text, version)
    if out is None:
        print(f"No changelog section found for {version} in {path}", file=sys.stderr)
        return 1
    if not out.strip():
        print(f"Changelog section for {version} in {path} is empty", file=sys.stderr)
        return 1
    print(out)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
