#!/usr/bin/env python3
"""Check that the agent-skill manifests agree with Cargo.toml and with reality.

The skill is shipped through three channels that each carry their own copy of
the version and plugin name:

  * ``.claude-plugin/marketplace.json``  — Claude Code marketplace
  * ``.codex-plugin/plugin.json``        — Codex plugin manifest
  * ``.agents/plugins/marketplace.json`` — Codex marketplace entry

They all point at the single skill source ``skills/gitpic/SKILL.md``. Nothing
stops them from drifting apart, so this asserts they still line up. Run it
locally with ``python3 .github/scripts/check_manifests.py``.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SKILL_NAME = "gitpic"
SKILL_MD = ROOT / "skills" / SKILL_NAME / "SKILL.md"
CLAUDE_MARKET = ROOT / ".claude-plugin" / "marketplace.json"
CODEX_PLUGIN = ROOT / ".codex-plugin" / "plugin.json"
CODEX_MARKET = ROOT / ".agents" / "plugins" / "marketplace.json"
CHANGELOGS = (ROOT / "CHANGELOG.md", ROOT / "CHANGELOG.zh-CN.md")

errors: list[str] = []


def fail(msg: str) -> None:
    errors.append(msg)


def load_json(path: Path):
    """Parse `path`, or record a failure and return None.

    Callers gate on `is not None` rather than on truthiness: `{}` and `[]` parse
    fine and are falsy, so a manifest truncated to `{}` used to skip every check
    below it *and* record no failure — the script then printed "Manifest check
    passed" for a file with no version and no plugin entry in it.
    """
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        fail(f"{path.relative_to(ROOT)} is missing")
    except json.JSONDecodeError as e:
        fail(f"{path.relative_to(ROOT)} is not valid JSON: {e}")
    return None


def cargo_version() -> str | None:
    text = (ROOT / "Cargo.toml").read_text()
    # Only the [package] section; a dependency's version must not match first.
    package = re.split(r"^\[", text, flags=re.M)
    for chunk in package:
        if chunk.startswith("package]"):
            m = re.search(r'^version\s*=\s*"([^"]+)"', chunk, flags=re.M)
            if m:
                return m.group(1)
    fail("could not read [package] version from Cargo.toml")
    return None


def check_skill_source() -> None:
    """The manifests are worthless if they point at a skill that is not there."""
    if not SKILL_MD.is_file():
        fail(f"skill source {SKILL_MD.relative_to(ROOT)} is missing")
        return
    text = SKILL_MD.read_text()
    if not text.startswith("---\n"):
        fail("SKILL.md must open with YAML frontmatter")
        return
    m = re.search(r"^name:\s*(\S+)\s*$", text, flags=re.M)
    if not m:
        fail("SKILL.md frontmatter must declare a name")
    elif m.group(1) != SKILL_NAME:
        fail(
            f"SKILL.md frontmatter name {m.group(1)!r} must match its directory "
            f"{SKILL_NAME!r} — agents discover the skill by directory name"
        )


def check_versions(version: str) -> None:
    claude = load_json(CLAUDE_MARKET)
    if claude is not None:
        got = claude.get("metadata", {}).get("version")
        if got != version:
            fail(f"{CLAUDE_MARKET.name}: metadata.version {got!r} != Cargo.toml {version!r}")
        plugins = claude.get("plugins") or []
        if len(plugins) != 1:
            fail(f"{CLAUDE_MARKET.name}: expected exactly one plugin entry, got {len(plugins)}")
        for p in plugins:
            if p.get("version") != version:
                fail(
                    f"{CLAUDE_MARKET.name}: plugins[].version {p.get('version')!r} "
                    f"!= Cargo.toml {version!r}"
                )
            if p.get("name") != SKILL_NAME:
                fail(f"{CLAUDE_MARKET.name}: plugins[].name {p.get('name')!r} != {SKILL_NAME!r}")

    codex = load_json(CODEX_PLUGIN)
    if codex is not None:
        if codex.get("version") != version:
            fail(
                f"{CODEX_PLUGIN.name}: version {codex.get('version')!r} "
                f"!= Cargo.toml {version!r}"
            )
        if codex.get("name") != SKILL_NAME:
            fail(f"{CODEX_PLUGIN.name}: name {codex.get('name')!r} != {SKILL_NAME!r}")
        # Codex needs an explicit pointer; Claude Code discovers skills/ by convention.
        if codex.get("skills") != "./skills/":
            fail(f"{CODEX_PLUGIN.name}: skills must be \"./skills/\", got {codex.get('skills')!r}")

    market = load_json(CODEX_MARKET)
    if market is not None:
        plugins = market.get("plugins") or []
        if len(plugins) != 1:
            fail(f"{CODEX_MARKET}: expected exactly one plugin entry, got {len(plugins)}")
        for p in plugins:
            if p.get("name") != SKILL_NAME:
                fail(f"{CODEX_MARKET}: plugins[].name {p.get('name')!r} != {SKILL_NAME!r}")


def check_changelogs(version: str) -> None:
    """Both changelogs must carry a section for the version in Cargo.toml.

    ``release.yml`` extracts release notes from ``CHANGELOG.zh-CN.md`` only, and
    aborts on an empty result — so the Chinese one is already guarded at tag time.
    Nothing checked the English one, which meant a release could ship with it left
    at ``## [Unreleased]`` and CI would stay green, even though AGENTS.md requires
    the two to stay aligned for every release.

    These two are now the only changelogs. The CLI and GitPic.app share one version
    and one Release, so app changes go in each version's ``### App`` subsection
    here; ``apps/GitPic/CHANGELOG.md`` is frozen at 0.1.2 as history and is
    deliberately not checked.
    """
    heading = re.compile(r"^## \[" + re.escape(version) + r"\]", flags=re.M)
    for path in CHANGELOGS:
        try:
            text = path.read_text()
        except FileNotFoundError:
            fail(f"{path.relative_to(ROOT)} is missing")
            continue
        if not heading.search(text):
            fail(
                f"{path.name} has no `## [{version}]` section, but Cargo.toml says "
                f"{version} — rename the unreleased heading before tagging"
            )


def main() -> int:
    version = cargo_version()
    check_skill_source()
    if version:
        check_versions(version)
        check_changelogs(version)

    if errors:
        print("Manifest check failed:", file=sys.stderr)
        for e in errors:
            print(f"  - {e}", file=sys.stderr)
        return 1
    print(f"Manifest check passed: gitpic {version}, skill + 3 manifests + 2 changelogs agree")
    return 0


if __name__ == "__main__":
    sys.exit(main())
