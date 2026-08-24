//! The project's own release feed: is there a newer gitpic than this one?
//!
//! **Not part of [`crate::github`]**, and the separation is deliberate. That module is a
//! client for *the user's image host* — every request carries the credential from
//! `gitpic auth login`, and its error mapping is written in those terms (a 401 means "your
//! token was rejected", a 404 means "your repo or branch is missing"). This module talks to
//! a fixed, unauthenticated, public endpoint about gitpic itself, where a 401 is
//! meaningless and a 404 means "this project has published no releases". Sharing one client
//! would mean one error mapping answering two different questions, and would put the user's
//! token on a request that has no business carrying it.

use crate::error::{AppError, ErrorCode, Result};
use serde::{Deserialize, Serialize};
use std::time::Duration;

/// Where this build's updates come from.
///
/// A constant, not a config key: it is the identity of the software, not a preference. A
/// settable value here would let a config file point the update check — and the release
/// notes the app then renders — at an arbitrary repository, which is a way to get
/// attacker-authored text in front of the user inside GitPic's own window.
const RELEASES_REPO: &str = "tarnish233/gitpic";

const API: &str = "https://api.github.com";
const UA: &str = concat!("gitpic/", env!("CARGO_PKG_VERSION"));
/// This build's version, and the thing every comparison here is against.
pub const CURRENT: &str = env!("CARGO_PKG_VERSION");

/// Shorter than [`crate::github`]'s 120 s, on purpose: that ceiling exists so a
/// multi-megabyte upload over a slow link can finish. This is one small GET, and it runs
/// on a daily timer behind the app's UI — a minute of hanging there is a spinner nobody
/// asked for.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(20);
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);

/// A version as this project numbers them: three numbers, nothing else.
///
/// `PartialOrd`/`Ord` are derived, which compares the fields in declaration order — so
/// major, then minor, then patch. That is exactly semver's ordering for a plain triple,
/// and it is the reason this is a struct of integers rather than the string it arrives as:
/// `"0.9.0" < "0.10.0"` is false as text, and a string comparison would have offered a
/// *downgrade* as an update on the first release past `.9`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct Version {
    major: u64,
    minor: u64,
    patch: u64,
}

impl Version {
    /// Parse `0.19.0` or `v0.19.0`; `None` for anything else.
    ///
    /// Strict on purpose, because every rejection here is a tag this project does not
    /// publish releases under and must not be compared against:
    ///
    /// - **A pre-release or build suffix** (`0.20.0-rc1`, `0.20.0+1`) is refused rather
    ///   than truncated to `0.20.0`. `releases/latest` excludes pre-releases, so one
    ///   arriving means something unusual, and ranking it *equal* to the final release of
    ///   the same number is the one answer that is certainly wrong.
    /// - **`app-v0.1.2`**, the historical tags from when the app versioned separately
    ///   (see AGENTS.md). It fails the `v` strip and is refused, which is what keeps one
    ///   of them from ever being read as version `0.1.2`.
    /// - **Anything not exactly three numeric components.** `v1.0` and `v1.0.0.1` are not
    ///   this project's scheme, and guessing the missing or extra part is guessing.
    pub fn parse(s: &str) -> Option<Self> {
        let s = s.strip_prefix('v').unwrap_or(s);
        if s.contains('-') || s.contains('+') {
            return None;
        }
        let mut parts = s.split('.');
        let mut next = || parts.next()?.parse::<u64>().ok();
        let (major, minor, patch) = (next()?, next()?, next()?);
        // Nothing may follow the patch: `1.0.0.1` would otherwise parse as 1.0.0.
        if parts.next().is_some() {
            return None;
        }
        Some(Self {
            major,
            minor,
            patch,
        })
    }
}

impl std::fmt::Display for Version {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}.{}.{}", self.major, self.minor, self.patch)
    }
}

/// What `releases/latest` says, narrowed to the fields this uses.
///
/// `body` and `name` are `Option` because GitHub omits them for a release published with
/// neither — a real state for a tag pushed without notes.
#[derive(Deserialize)]
struct LatestRelease {
    tag_name: String,
    name: Option<String>,
    body: Option<String>,
    html_url: String,
    published_at: Option<String>,
}

/// The answer, and the shape `--json` emits.
#[derive(Debug, Serialize, PartialEq, Eq)]
pub struct UpdateReport {
    pub ok: bool,
    /// This build's version.
    pub current: String,
    /// The latest release's version, normalised (no `v`).
    pub latest: String,
    /// The tag as GitHub spells it, kept because that is what identifies the release to
    /// anything else the caller might do with it.
    pub tag: String,
    pub update_available: bool,
    /// True when this build is *newer* than the latest release — an unreleased local
    /// build. Reported rather than folded into `update_available: false`, so the app can
    /// say so instead of claiming a dev build is up to date with something it is ahead of.
    pub ahead: bool,
    /// The release's title, when it has one.
    pub name: Option<String>,
    /// The release notes, verbatim Markdown. Empty string when the release has none, so a
    /// caller never has to distinguish absent from blank to render it.
    pub notes: String,
    pub url: String,
    pub published_at: Option<String>,
}

impl UpdateReport {
    /// [`Self::notes`] with the two structural removals a reader of "what changed" wants,
    /// mirroring `UpdateCheck.summary` in `GitPicCore`.
    ///
    /// **Why this exists here at all.** `human()` printed `notes` verbatim under a comment
    /// claiming it made "the same call" as the app's update sheet. It did not: the sheet
    /// trims, so the terminal was the only place that showed the `## GitPic.app` appendix —
    /// fifteen lines telling someone who *downloaded the DMG* to drag it to Applications and
    /// clear the quarantine flag, printed to a person who already has `gitpic` installed —
    /// and the `### <theme>` line that is also printed just above as the release name.
    ///
    /// `notes` itself stays untrimmed, including in `--json`: a script may want the whole
    /// body, and the app decodes that field and applies its own rule to it.
    ///
    /// **The rule**, kept identical on both sides so the two renderings cannot diverge:
    ///
    /// 1. Stop at the first level-2 ATX heading that is not inside a fenced code block.
    ///    Level, not title — the appendix's wording lives in `release.yml` where this cannot
    ///    see it, so matching "GitPic.app" would stop trimming the day someone rewords it.
    /// 2. Drop leading blank lines.
    /// 3. Drop the first remaining line if it is an ATX heading of any level.
    ///
    /// A heading is `#`s **followed by a space**, and fences are skipped. Both halves were
    /// bugs on the Swift side: `#42 修复剪贴板上传失败` had its first change deleted as a
    /// heading, and a `## ` quoted inside a ``` block ended the notes there.
    pub fn summary(&self) -> String {
        let mut kept: Vec<&str> = Vec::new();
        let mut in_fence = false;
        for line in self.notes.lines() {
            if is_fence_delimiter(line) {
                in_fence = !in_fence;
            } else if !in_fence && heading_level(line) == Some(2) {
                break;
            }
            kept.push(line);
        }
        let mut first = 0;
        while kept.get(first).is_some_and(|l| l.trim().is_empty()) {
            first += 1;
        }
        if kept.get(first).is_some_and(|l| heading_level(l).is_some()) {
            first += 1;
        }
        kept[first.min(kept.len())..].join("\n").trim().to_string()
    }
}

/// The ATX heading level of `line`, or `None` when it is not a heading.
///
/// One or more `#` followed by a space, per CommonMark. The space is what keeps `#42` and
/// `#hashtag` from being read as headings — see [`UpdateReport::summary`].
fn heading_level(line: &str) -> Option<usize> {
    let hashes = line.bytes().take_while(|b| *b == b'#').count();
    if hashes == 0 || !line[hashes..].starts_with(' ') {
        return None;
    }
    Some(hashes)
}

/// Whether `line` opens or closes a fenced code block. Info strings are fine — only the run
/// of delimiters is looked at.
fn is_fence_delimiter(line: &str) -> bool {
    let t = line.trim_start();
    t.starts_with("```") || t.starts_with("~~~")
}

/// Ask GitHub for the latest release and compare it with this build.
pub async fn check() -> Result<UpdateReport> {
    check_against(API).await
}

/// The same, against an explicit API base.
///
/// Private, and unlike [`crate::github`]'s equivalent the reason is not the credential —
/// there is none — but the release notes: whatever comes back is rendered inside GitPic's
/// own settings window, so the origin must not be reachable from a config file or an
/// environment variable. Tests inject a loopback stub directly.
async fn check_against(api: &str) -> Result<UpdateReport> {
    let client = reqwest::Client::builder()
        .user_agent(UA)
        .timeout(REQUEST_TIMEOUT)
        .connect_timeout(CONNECT_TIMEOUT)
        .build()
        .map_err(|e| AppError::network(format!("http client: {e}")))?;

    let url = format!("{api}/repos/{RELEASES_REPO}/releases/latest");
    let resp = client
        .get(&url)
        .header("Accept", "application/vnd.github+json")
        .header("X-GitHub-Api-Version", "2022-11-28")
        .send()
        .await
        .map_err(|e| AppError::network(format!("check for updates: {e}")))?;

    let status = resp.status();
    if !status.is_success() {
        return Err(status_error(status));
    }
    let latest: LatestRelease = resp
        .json()
        .await
        .map_err(|e| AppError::network(format!("check for updates: unreadable reply: {e}")))?;

    report(CURRENT, latest)
}

/// Turn a fetched release into the report, or explain why it cannot be compared.
///
/// Split out from the request so the comparison — the part with the interesting edge
/// cases — is testable without a socket.
fn report(current: &str, latest: LatestRelease) -> Result<UpdateReport> {
    // An unparseable *own* version cannot happen through a real build: it comes from
    // `CARGO_PKG_VERSION`, and `check_manifests.py` already pins that against the tag. It
    // is still not something to `expect` on, because the honest answer to "can I compare
    // these" is available and a panic exits outside the documented 1-10 status contract.
    let mine = Version::parse(current).ok_or_else(|| {
        AppError::general(format!(
            "cannot read this build's own version (`{current}`), so there is nothing to \
             compare the latest release against"
        ))
    })?;
    // A tag this project does not publish under. Reported rather than treated as "no
    // update": saying 已是最新 when the comparison never happened is the one outcome that
    // hides a pending update behind a reassuring message.
    let theirs = Version::parse(&latest.tag_name).ok_or_else(|| {
        AppError::general(format!(
            "the latest release is tagged `{}`, which is not a version this can compare \
             against `{current}` — see {}",
            latest.tag_name, latest.html_url
        ))
    })?;

    Ok(UpdateReport {
        ok: true,
        current: mine.to_string(),
        latest: theirs.to_string(),
        tag: latest.tag_name,
        update_available: theirs > mine,
        ahead: mine > theirs,
        name: latest.name.filter(|s| !s.trim().is_empty()),
        notes: latest.body.unwrap_or_default(),
        url: latest.html_url,
        published_at: latest.published_at,
    })
}

/// Map a non-2xx from the releases endpoint.
///
/// Its own mapping rather than [`crate::github`]'s, because the same statuses mean
/// different things here. Nothing is sent authenticated, so a 401 is not "your credential
/// was rejected"; and a 404 is about *this project* having no releases, not about the
/// user's repository being missing — advice to run `gitpic config set` would be nonsense.
fn status_error(status: reqwest::StatusCode) -> AppError {
    match status.as_u16() {
        404 => AppError::new(
            ErrorCode::RemoteNotFound,
            format!("{RELEASES_REPO} has published no releases yet"),
        ),
        // Unauthenticated api.github.com allows 60 requests an hour per address. One
        // daily check cannot reach that alone, but it shares the quota with everything
        // else on the network, so this is a state real users will meet.
        403 | 429 => AppError::new(
            ErrorCode::RateLimited,
            "GitHub rate-limited the update check; try again later".to_string(),
        ),
        _ => AppError::new(
            ErrorCode::General,
            format!("check for updates: GitHub returned {status}"),
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn release(tag: &str) -> LatestRelease {
        LatestRelease {
            tag_name: tag.to_string(),
            name: Some(format!("GitPic {tag}")),
            body: Some("- something changed".to_string()),
            html_url: "https://example.invalid/r/1".to_string(),
            published_at: Some("2026-08-24T00:00:00Z".to_string()),
        }
    }

    #[test]
    fn parses_the_shape_this_project_tags_with() {
        assert_eq!(Version::parse("0.19.0"), Version::parse("v0.19.0"));
        assert_eq!(Version::parse("v1.2.3").unwrap().to_string(), "1.2.3");
    }

    /// The trap this type exists for. As text `"0.9.0" > "0.10.0"`, so a string comparison
    /// would have called 0.10.0 older than 0.9.0 and offered a downgrade as an update —
    /// on the very next minor release.
    #[test]
    fn ten_is_newer_than_nine() {
        let nine = Version::parse("0.9.0").unwrap();
        let ten = Version::parse("0.10.0").unwrap();
        assert!(ten > nine, "0.10.0 must outrank 0.9.0");
        assert!("0.9.0" > "0.10.0", "the string comparison this replaces");
    }

    #[test]
    fn orders_by_major_then_minor_then_patch() {
        let v = |s| Version::parse(s).unwrap();
        assert!(v("1.0.0") > v("0.99.99"));
        assert!(v("0.19.1") > v("0.19.0"));
        assert_eq!(v("0.19.0"), v("v0.19.0"));
    }

    /// Every rejection is a tag this project does not publish releases under. See
    /// [`Version::parse`] for why each one must not be coerced into a number.
    #[test]
    fn refuses_tags_that_are_not_this_scheme() {
        for tag in [
            "app-v0.1.2", // the historical app-only tags
            "0.20.0-rc1", // a pre-release: ranking it equal to 0.20.0 would be wrong
            "0.20.0+1",
            "1.0",     // too few components
            "1.0.0.1", // too many
            "latest",
            "v",
            "0.x.0",
            "",
            "0. 19.0", // whitespace is not a digit
            "-1.0.0",  // the `-` guard catches this before the parse would
        ] {
            assert!(
                Version::parse(tag).is_none(),
                "`{tag}` must not parse as a version"
            );
        }
    }

    #[test]
    fn a_newer_release_is_an_update() {
        let r = report("0.19.0", release("v0.20.0")).unwrap();
        assert!(r.update_available);
        assert!(!r.ahead);
        assert_eq!(r.current, "0.19.0");
        assert_eq!(r.latest, "0.20.0");
        assert_eq!(r.tag, "v0.20.0");
        assert_eq!(r.notes, "- something changed");
    }

    #[test]
    fn the_same_version_is_not_an_update() {
        let r = report("0.19.0", release("v0.19.0")).unwrap();
        assert!(!r.update_available);
        assert!(!r.ahead);
    }

    /// The state every unreleased build of this repository is in, including the one the
    /// next release is cut from — so it must not read as "up to date" *or* as an update.
    #[test]
    fn a_local_build_ahead_of_the_latest_release_says_so() {
        let r = report("0.20.0", release("v0.19.0")).unwrap();
        assert!(!r.update_available, "must never offer a downgrade");
        assert!(r.ahead);
    }

    /// Refusing to compare is reported, not silently answered "up to date" — that would
    /// hide a real pending update behind a reassuring message.
    #[test]
    fn an_uncomparable_tag_is_an_error_not_a_shrug() {
        let err = report("0.19.0", release("weekly-2026-08-24"))
            .expect_err("an unparseable tag must not report 'no update'");
        assert_eq!(err.code, ErrorCode::General);
        assert!(
            err.message.contains("weekly-2026-08-24"),
            "the message must name the tag: {}",
            err.message
        );
    }

    /// A release published with no notes renders as an empty string rather than forcing
    /// every caller to tell absent from blank.
    #[test]
    fn a_release_without_notes_reports_empty_notes() {
        let mut r = release("v0.20.0");
        r.body = None;
        r.name = Some("   ".to_string());
        let out = report("0.19.0", r).unwrap();
        assert_eq!(out.notes, "");
        assert_eq!(out.name, None, "a blank title is no title");
    }

    #[test]
    fn statuses_map_to_the_codes_a_caller_can_act_on() {
        use reqwest::StatusCode;
        assert_eq!(
            status_error(StatusCode::NOT_FOUND).code,
            ErrorCode::RemoteNotFound
        );
        assert_eq!(
            status_error(StatusCode::FORBIDDEN).code,
            ErrorCode::RateLimited
        );
        assert_eq!(
            status_error(StatusCode::TOO_MANY_REQUESTS).code,
            ErrorCode::RateLimited
        );
        assert_eq!(
            status_error(StatusCode::INTERNAL_SERVER_ERROR).code,
            ErrorCode::General
        );
    }

    /// The update feed is fixed at compile time. A config key or an environment variable
    /// here would let something else choose the repository whose release notes get
    /// rendered inside GitPic's window.
    #[test]
    fn the_release_feed_is_a_compile_time_constant() {
        assert_eq!(RELEASES_REPO, "tarnish233/gitpic");
        assert!(API.starts_with("https://"));
    }

    /// The same rule as `UpdateCheck.summary` in `GitPicCore`, and the same two near-misses
    /// are pinned here: a heading needs a space after its hashes, and a fenced block is not
    /// scanned for one. Both sides render release notes to a person, so they have to agree.
    #[test]
    fn summary_drops_the_appendix_and_the_theme_line() {
        let s = |notes: &str| {
            let mut r = report(CURRENT, release("v9.9.9")).unwrap();
            r.notes = notes.to_string();
            r.summary()
        };
        // The theme line goes: `release.yml` publishes it as the Release *name*, which
        // `human()` prints directly above these notes.
        assert_eq!(s("### 更新检查\n\n- 新增检查更新。"), "- 新增检查更新。");
        // The `## `-level appendix goes, and everything under it.
        assert_eq!(
            s("- a change\n\n## GitPic.app\n\ndrag it to Applications\n"),
            "- a change"
        );
        // A body with no heading at all is left alone.
        assert_eq!(s("- just this"), "- just this");
        assert_eq!(s(""), "");
        // `#42` is an issue reference, not a heading — no space after the hashes. Reading it
        // as one deleted a real change on the app side before this rule was shared.
        assert_eq!(
            s("#42 fixed the clipboard\n- and this"),
            "#42 fixed the clipboard\n- and this"
        );
        // An h2 inside a fence is quoted text. What follows has to survive, and the fence has
        // to stay balanced or the renderer is handed an unterminated block.
        let out = s("- changed the changelog\n\n```md\n## [0.19.0]\n```\n\n- and this");
        assert!(out.contains("and this"), "a fenced h2 truncated: {out}");
        assert_eq!(out.matches("```").count(), 2, "unbalanced fence: {out}");
    }

    /// End to end over a loopback socket: the URL that gets requested, and a real decode
    /// of a GitHub-shaped reply.
    #[tokio::test]
    async fn fetches_the_latest_release_over_http() {
        let body = r#"{"tag_name":"v9.9.9","name":"GitPic 9.9.9",
            "body":"- a line of notes","html_url":"https://example.invalid/rel",
            "published_at":"2026-08-24T01:02:03Z"}"#;
        let (addr, served) = crate::testutil::stub(vec![crate::testutil::http("200 OK", body)]);

        let out = check_against(&addr).await.unwrap();
        // 9.9.9 outranks anything this crate will plausibly be, so the comparison is
        // pinned without hardcoding today's version.
        assert!(out.update_available, "9.9.9 must outrank {}", out.current);
        assert_eq!(out.latest, "9.9.9");
        assert_eq!(out.notes, "- a line of notes");
        assert_eq!(out.url, "https://example.invalid/rel");

        let req = served.join().unwrap().remove(0);
        assert!(
            req.contains(&format!("GET /repos/{RELEASES_REPO}/releases/latest")),
            "unexpected request: {req}"
        );
        // GitHub refuses requests without one, so this is a contract and not a courtesy.
        assert!(req.contains("User-Agent: gitpic/"), "no UA: {req}");
        // Nothing authenticated: this endpoint is public, and the user's credential has
        // no business on a request to a repository that is not theirs.
        //
        // This assertion is the reason the request is read through `testutil` rather than
        // with the single `sock.read` that used to be inlined here. A negative assertion over
        // a partial read passes because the header block was never read, not because no
        // credential was sent — so the one check standing between a future edit and a leaked
        // token would have been reporting success either way. `read_request` reads to the end
        // of the headers before this looks at them.
        assert!(
            !req.to_lowercase().contains("authorization:"),
            "the update check must not send a credential: {req}"
        );
    }
}
