//! The project's own release feed: is there a newer gitpic than this one?
//!
//! **Not part of [`crate::github`]**, and the separation is deliberate. That module is a
//! client for *the user's image host*, and its error mapping is written in those terms (a 404
//! means "your repo or branch is missing"). This module talks to a fixed endpoint about
//! gitpic itself, where a 404 means "this project has published no releases". Sharing one
//! client would mean one error mapping answering two different questions — that half of the
//! argument still stands, and is why there are still two modules.
//!
//! **The other half — "and would put the user's token on a request that has no business
//! carrying it" — was reversed in 0.20.5, on measurement.** The unauthenticated API allows 60
//! requests an hour *per address*, and an address is not a user: behind a shared NAT egress
//! that budget belongs to everyone behind it. Measured on a real one — GitHub answered
//! `403 API rate limit exceeded for 163.128.6.24` with `x-ratelimit-used: 60` for a machine
//! that had made one check that day, and the same request through a different egress had 52
//! of 60 left. For those users the anonymous path is not slower, it does not work at all, and
//! GitHub's own error names the remedy: an authenticated request is 5000 an hour and is
//! counted against the account rather than the address.
//!
//! What was conceded, and what was not. The credential goes to `api.github.com` — the same
//! host and the same token that `gitpic auth login` already sends there for uploads — and
//! GitHub is the only party that sees it; this project's repository owner does not. No
//! permission is needed for it to work, so a token with no scopes at all raises the limit
//! just as well. It stays **optional**: no credential means no header and the old anonymous
//! request, because the app is usable without ever logging in. A rejected credential falls
//! back to anonymous rather than failing, so a stale image-host token cannot break update
//! checks. And the request cannot follow a redirect at all
//! ([`reqwest::redirect::Policy::none`]), so the header has nowhere else to travel.
//!
//! The test that asserted no credential is ever sent was **narrowed rather than deleted** —
//! see `sends_no_credential_when_there_is_none` and `sends_the_credential_only_to_the_fixed_base`.
//! A blanket prohibition would now be false, and a comment claiming one would be worse than
//! none; what still holds and is still worth guarding is that the header appears only with a
//! credential, only against the compile-time base, and never on a redirect.

use crate::error::{AppError, ErrorCode, Result};
use base64::Engine;
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
    /// The downloadable files. `default` because a release published with no assets omits
    /// nothing — GitHub sends `[]` — but a *stub* in a test that only cares about version
    /// comparison should not have to spell an empty array.
    #[serde(default)]
    assets: Vec<AssetRow>,
}

/// One release asset as GitHub sends it.
///
/// Private, and paired with the public [`ReleaseAsset`] below: the same `…Row` /
/// `…Candidate` split [`crate::github`] uses for repositories and branches, so the wire
/// shape being decoded and the wire shape being emitted can be renamed independently.
#[derive(Deserialize)]
struct AssetRow {
    name: String,
    size: u64,
    browser_download_url: String,
    /// `"sha256:<64 hex>"` when GitHub has computed one. Optional because it is not part of
    /// any documented API contract — it appeared on this project's releases from 0.15.0
    /// onward, and the consumer treats its absence as "cannot verify, do not install"
    /// rather than as permission to skip the check.
    digest: Option<String>,
}

/// One downloadable file from the release, as `--json` emits it.
///
/// **Why the update check reports these at all.** The app can now install an update itself
/// when Homebrew is not the owner of its bundle, and to do that safely it needs two things
/// this endpoint already knows: where the disk image is, and what it should hash to. Both
/// come from the same authenticated-by-TLS response as the version comparison, so there is
/// no second origin to trust — which is the property that makes verification worth anything.
#[derive(Debug, Serialize, PartialEq, Eq)]
pub struct ReleaseAsset {
    pub name: String,
    pub size: u64,
    /// Straight from GitHub's `browser_download_url`, never constructed here. Building it
    /// from a template would put a second spelling of the release URL in this crate, and
    /// `the_release_feed_is_a_compile_time_constant` exists to keep there being exactly one.
    pub url: String,
    /// `"sha256:<64 hex>"`, or absent. Emitted verbatim rather than split into algorithm and
    /// hex: the prefix is what says *which* algorithm, and a consumer that silently assumed
    /// SHA-256 for some future `sha512:` value would verify nothing while looking like it did.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub digest: Option<String>,
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
    /// The release's downloadable files, in the order GitHub lists them.
    ///
    /// Always present, `[]` for a release with no assets — a caller rendering this never has
    /// to distinguish absent from empty, the same reasoning [`Self::notes`] follows.
    pub assets: Vec<ReleaseAsset>,
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
    check_against(API, best_effort_token().as_deref()).await
}

/// The credential to raise the rate limit with, or nothing — never an error.
///
/// Every way [`crate::auth::token`] can fail (no `auth.toml`, an expired credential, one that
/// is not a bare token) collapses to `None` and an anonymous request. Deliberately: this is a
/// background check on a public endpoint, and the app is usable without ever logging in, so
/// none of those states is a reason to stop telling the user a new version exists.
fn best_effort_token() -> Option<String> {
    crate::auth::token().ok()
}

/// One attempt, and enough of its outcome for the caller to decide about a second.
///
/// Generic over the decoded body because two endpoints share it: the release feed and the
/// tap's cask file. What is worth sharing is not the request — that part is three headers —
/// but the retry rule and its third branch; see [`get_json`].
enum Attempt<T> {
    Ok(T),
    /// GitHub rejected the credential itself — the one outcome worth retrying anonymously,
    /// because a stale image-host token must not be able to break update checks.
    CredentialRejected,
    Failed(AppError),
}

/// The client both lookups use: bounded, and structurally unable to carry a credential to
/// another host.
///
/// Nothing either endpoint asks for redirects — `releases/latest` and a contents read both
/// answer 200 directly — so refusing to follow one costs nothing and makes "the credential
/// cannot travel" structural rather than a property of whichever reqwest release is linked.
/// reqwest does strip sensitive headers across hosts on its own; this does not depend on it.
fn client() -> Result<reqwest::Client> {
    reqwest::Client::builder()
        .user_agent(UA)
        .timeout(REQUEST_TIMEOUT)
        .connect_timeout(CONNECT_TIMEOUT)
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .map_err(|e| AppError::network(format!("http client: {e}")))
}

/// One GET carrying the credential, and — only if GitHub refused *the credential* — one more
/// without it.
///
/// Shared rather than written twice because the interesting part is the third branch. An
/// anonymous retry has no credential left to reject, so that arm is unreachable in practice;
/// it is still stated instead of `unreachable!()`, because a panic inside a background update
/// check would be a worse answer than a sentence.
/// What a request was for, carried far enough down to describe its own failures.
///
/// Both fields used to be constants inside `status_error`, which was written when this module
/// had one endpoint. Generalising the client for the tap lookup left them behind, so a 404 on
/// `Casks/gitpic.rb` reported `tarnish233/gitpic has published no releases yet` — wrong
/// repository, wrong resource, wrong failure, from a command that never touched the release
/// feed. Every arm now names the endpoint it actually failed on, which is what makes one log
/// line enough to tell "the tap moved" from "GitHub is down".
#[derive(Clone, Copy)]
struct Endpoint<'a> {
    /// What the caller was doing, in the imperative: "check for updates".
    what: &'a str,
    /// What a 404 means *here*, as a whole sentence. A missing release feed and a missing cask
    /// file are different facts and neither is worth guessing from a status code alone.
    missing: &'a str,
}

async fn get_json<T: serde::de::DeserializeOwned>(
    client: &reqwest::Client,
    url: &str,
    token: Option<&str>,
    endpoint: Endpoint<'_>,
) -> Result<T> {
    let what = endpoint.what;
    match fetch(client, url, token, endpoint).await {
        Attempt::Ok(value) => Ok(value),
        // Anonymous retry, and only from here: the first attempt carried a credential that
        // GitHub refused, which says nothing about whether the resource is readable.
        Attempt::CredentialRejected => match fetch(client, url, None, endpoint).await {
            Attempt::Ok(value) => Ok(value),
            Attempt::Failed(e) => Err(e),
            Attempt::CredentialRejected => Err(AppError::new(
                ErrorCode::General,
                format!("{what}: GitHub rejected an anonymous request as unauthorised"),
            )),
        },
        Attempt::Failed(e) => Err(e),
    }
}

/// The same, against an explicit API base and with an explicit credential.
///
/// Private, and unlike [`crate::github`]'s equivalent the reason is not only the credential
/// but the release notes: whatever comes back is rendered inside GitPic's own settings
/// window, so the origin must not be reachable from a config file or an environment
/// variable. Tests inject a loopback stub directly.
///
/// The credential is a parameter rather than read here, so that every test states which case
/// it is exercising instead of inheriting whatever `auth.toml` the machine happens to hold.
/// Read from the file it would have been, `sends_no_credential_when_there_is_none` would pass
/// on CI and fail on any developer who had run `gitpic auth login` — a security assertion
/// whose verdict depends on the machine is not one.
async fn check_against(api: &str, token: Option<&str>) -> Result<UpdateReport> {
    let client = client()?;
    let url = format!("{api}/repos/{RELEASES_REPO}/releases/latest");
    let latest: LatestRelease = get_json(
        &client,
        &url,
        token,
        Endpoint {
            what: "check for updates",
            missing: &format!("{RELEASES_REPO} has published no releases yet"),
        },
    )
    .await?;
    report(CURRENT, latest)
}

/// One request, decoded, with the credential attached only if there is one.
async fn fetch<T: serde::de::DeserializeOwned>(
    client: &reqwest::Client,
    url: &str,
    token: Option<&str>,
    endpoint: Endpoint<'_>,
) -> Attempt<T> {
    let what = endpoint.what;
    let mut req = client
        .get(url)
        .header("Accept", "application/vnd.github+json")
        .header("X-GitHub-Api-Version", "2022-11-28");
    if let Some(token) = token {
        req = req.bearer_auth(token);
    }
    let resp = match req.send().await {
        Ok(resp) => resp,
        Err(e) => return Attempt::Failed(AppError::network(format!("{what}: {e}"))),
    };

    let status = resp.status();
    if !status.is_success() {
        if status.as_u16() == 401 && token.is_some() {
            return Attempt::CredentialRejected;
        }
        // Headers and body before the response is dropped. Passing the status alone is why
        // this could not tell a rate limit from any other 403, and could not say when to
        // retry — `x-ratelimit-remaining` is the authoritative signal, and
        // `AppError::with_retry_hint` existed unused for want of a number.
        let headers = resp.headers().clone();
        let body = resp.text().await.unwrap_or_default();
        return Attempt::Failed(status_error(status, &headers, &body, endpoint));
    }
    match resp.json::<T>().await {
        Ok(value) => Attempt::Ok(value),
        Err(e) => Attempt::Failed(AppError::network(format!("{what}: unreadable reply: {e}"))),
    }
}

/// Where the Homebrew cask that installs GitPic is defined.
///
/// A constant for the same reason [`RELEASES_REPO`] is one, and the reason bites harder here:
/// the version this reads is shown in GitPic's update sheet *next to a command the user is
/// being told to type into a terminal*. A settable origin would be a way to put an attacker's
/// version string — and with it an attacker's argument for running something — in front of the
/// user inside GitPic's own window.
const TAP_REPO: &str = "tarnish233/homebrew-tap";
/// The cask, not the formula: this answers "what would `brew upgrade --cask gitpic` install".
const TAP_CASK_PATH: &str = "Casks/gitpic.rb";

/// The cask and the formula the tap defines.
///
/// Here rather than beside the code that prints them, because they are one fact with two
/// readers — [`crate::install_source`] names them in an upgrade command and builds a Caskroom
/// path out of the cask token, and [`tap_cask`] echoes it back to the app so the app does not
/// spell it a third time. They are separate installs, and `brew upgrade` on the wrong one
/// reports "no available formula".
pub(crate) const CASK: &str = "gitpic";
pub(crate) const FORMULA: &str = "gitpic_cli";

/// What the tap's cask currently declares.
///
/// Separate from [`UpdateReport`] and from a separate request on purpose: this costs a round
/// trip that only a Homebrew-managed install has any use for, and folding it into
/// `update check` would spend it on every check for everybody.
#[derive(Debug, Serialize)]
pub struct TapCask {
    pub ok: bool,
    /// Echoed so the caller can build `brew upgrade --cask <token>` without hardcoding it.
    pub cask: String,
    /// `null` when the file was read but declares no version this can compare — see
    /// [`cask_version`]. Distinct from an error, which means the file was not read at all;
    /// both leave the app unable to tell, so both send it to the same outcome.
    pub version: Option<String>,
}

/// The Contents API reply, narrowed to what this reads.
#[derive(Deserialize)]
struct ContentsFile {
    content: String,
    encoding: String,
}

/// Ask the tap what version its cask declares.
pub async fn tap_cask() -> Result<TapCask> {
    tap_cask_against(API, best_effort_token().as_deref()).await
}

/// The same, against an explicit API base and credential — the seam every test uses, for the
/// reasons on [`check_against`].
async fn tap_cask_against(api: &str, token: Option<&str>) -> Result<TapCask> {
    let client = client()?;
    let url = format!("{api}/repos/{TAP_REPO}/contents/{TAP_CASK_PATH}");
    let what = "read the Homebrew tap";
    let file: ContentsFile = get_json(
        &client,
        &url,
        token,
        Endpoint {
            what,
            // The likeliest 404 by far, and the one worth naming: Homebrew moved third-party
            // casks into sharded directories (`Casks/g/gitpic.rb`), so a tap that follows suit
            // makes this path vanish while the repository stays perfectly readable.
            missing: &format!("{TAP_REPO} has no {TAP_CASK_PATH}"),
        },
    )
    .await?;

    // GitHub sends `encoding: "none"` for a file too large to inline. A cask is a few
    // kilobytes so this should not happen, and saying so beats decoding an empty string into
    // "the tap declares nothing".
    if file.encoding != "base64" {
        return Err(AppError::general(format!(
            "{what}: the cask came back {}-encoded, which this cannot read",
            file.encoding
        )));
    }
    // The Contents API wraps its base64 at column 60, and the decoder rejects the newlines.
    let packed: String = file
        .content
        .chars()
        .filter(|c| !c.is_whitespace())
        .collect();
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(&packed)
        .map_err(|e| AppError::general(format!("{what}: the cask is not readable base64: {e}")))?;
    let text = String::from_utf8(bytes)
        .map_err(|e| AppError::general(format!("{what}: the cask is not UTF-8: {e}")))?;

    Ok(TapCask {
        ok: true,
        cask: CASK.to_string(),
        version: cask_version(&text).map(str::to_string),
    })
}

/// The version a cask declares, or `None`.
///
/// Deliberately not a Ruby parser: it takes the first `version` stanza that is a plain quoted
/// literal parsing as three numbers, and answers `None` for everything else — an
/// interpolation, `version :latest`, or Homebrew's comma-separated `version "1.2,345"` form
/// (`Cask#version.csv`).
///
/// `None` is the safe answer and a guess is not. It reaches the app as "could not tell", which
/// shows the upgrade command with a caveat; a version invented out of an unparseable string
/// could instead show 「已是 Homebrew 提供的最新版本」 over a real update, which is the one
/// outcome that hides a pending upgrade behind a reassuring sentence.
fn cask_version(cask: &str) -> Option<&str> {
    for line in cask.lines() {
        let Some(rest) = line.trim().strip_prefix("version ") else {
            continue;
        };
        let literal = rest.trim().strip_prefix('"')?.split('"').next()?;
        return Version::parse(literal).map(|_| literal);
    }
    None
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
        assets: latest
            .assets
            .into_iter()
            .map(|a| ReleaseAsset {
                name: a.name,
                size: a.size,
                url: a.browser_download_url,
                digest: a.digest,
            })
            .collect(),
    })
}

/// Seconds to wait, from whichever header the server used to say so.
///
/// `retry-after` is what a *secondary* rate limit sends and it is already a count of seconds.
/// `x-ratelimit-reset` is what a primary limit sends and it is an absolute epoch second, so it
/// has to be turned into a delta here. A reset in the past — a clock skewed either way, or a
/// response that sat in a proxy — yields `None` rather than `0`, because "retry after 0s" reads
/// as advice and is not.
fn retry_after_secs(headers: &reqwest::header::HeaderMap) -> Option<u64> {
    if let Some(secs) = headers
        .get("retry-after")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.trim().parse::<u64>().ok())
    {
        return (secs > 0).then_some(secs);
    }
    let reset = headers
        .get("x-ratelimit-reset")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.trim().parse::<u64>().ok())?;
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .ok()?
        .as_secs();
    let delta = reset.checked_sub(now)?;
    (delta > 0).then_some(delta)
}

/// Whether this refusal is GitHub saying "too many requests" rather than "no".
///
/// Three signals, because GitHub uses three shapes. A primary limit answers 403 **or** 429
/// with `x-ratelimit-remaining: 0`; a secondary limit answers 403 with `retry-after` and a
/// remaining count that may be anything; and both name it in the body. The status code alone
/// says nothing — 403 is also how GitHub refuses a blocked user agent, and how an intercepting
/// proxy refuses the request before GitHub ever sees it.
fn is_rate_limited(status: u16, headers: &reqwest::header::HeaderMap, body: &str) -> bool {
    let exhausted = headers
        .get("x-ratelimit-remaining")
        .and_then(|v| v.to_str().ok())
        .map(|v| v.trim() == "0")
        .unwrap_or(false);
    // The body last, and deliberately: it is the fallback for a middlebox that stripped the
    // headers, and it is the same test `crate::github` applies to the same statuses.
    exhausted
        || status == 429
        || headers.contains_key("retry-after")
        || body.to_ascii_lowercase().contains("rate limit")
}

/// Map a non-2xx from the releases endpoint.
///
/// Its own mapping rather than [`crate::github`]'s, because the same statuses mean
/// different things here. Nothing is sent authenticated, so a 401 is not "your credential
/// was rejected"; and a 404 is about *this project* having no releases, not about the
/// user's repository being missing — advice to run `gitpic config set` would be nonsense.
///
/// **The one difference that mattered was the one this got wrong.** It used to map `403 | 429`
/// to `RATE_LIMITED` on the status code alone, while the module it deliberately diverged from
/// tested the body first. So every 403 was reported as "try again later" — a remedy that never
/// arrives when the refusal came from a blocked user agent or a proxy that answered before
/// GitHub did — and a real rate limit could not say how long, because the caller had thrown
/// the headers away before getting here.
fn status_error(
    status: reqwest::StatusCode,
    headers: &reqwest::header::HeaderMap,
    body: &str,
    endpoint: Endpoint<'_>,
) -> AppError {
    let Endpoint { what, missing } = endpoint;
    let code = status.as_u16();
    match code {
        404 => AppError::new(ErrorCode::RemoteNotFound, missing.to_string()),
        // Reachable only when the anonymous retry is itself refused as unauthorised, since a
        // rejected credential is retried without one before it gets here. Named honestly
        // rather than folded into `General`: 401 has exactly one meaning.
        401 => AppError::new(
            ErrorCode::AuthFailed,
            format!("{what}: GitHub rejected the request as unauthorised"),
        ),
        // Unauthenticated api.github.com allows 60 requests an hour per address. One
        // daily check cannot reach that alone, but it shares the quota with everything
        // else on the network, so this is a state real users will meet.
        _ if is_rate_limited(code, headers, body) => AppError::new(
            ErrorCode::RateLimited,
            format!("GitHub rate-limited the request to {what}; try again later"),
        )
        .with_retry_hint(retry_after_secs(headers)),
        // A 403 that is not a rate limit. Named as itself rather than dressed up as one:
        // waiting will not fix a blocked user agent, and hiding GitHub's own words behind
        // "try again later" leaves nothing to act on.
        403 => AppError::new(
            ErrorCode::General,
            format!("{what}: GitHub refused the request (403){}", {
                let detail = body.trim();
                if detail.is_empty() {
                    String::new()
                } else {
                    format!(": {}", detail.chars().take(200).collect::<String>())
                }
            }),
        ),
        _ => AppError::new(
            ErrorCode::General,
            format!("{what}: GitHub returned {status}"),
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
            assets: Vec::new(),
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

    /// A header map from pairs, so each case below reads as the response it stands for.
    fn headers(pairs: &[(&str, &str)]) -> reqwest::header::HeaderMap {
        let mut map = reqwest::header::HeaderMap::new();
        for (k, v) in pairs {
            map.insert(
                reqwest::header::HeaderName::from_bytes(k.as_bytes()).unwrap(),
                v.parse().unwrap(),
            );
        }
        map
    }

    /// The endpoint every `status_error` row below is asked about.
    ///
    /// One fixture rather than the real constants, so these rows assert the *mapping* from
    /// status to `ErrorCode` and not the wording of either endpoint. What the wording has to do
    /// is stay attached to its own endpoint, which is what
    /// `a_tap_failure_does_not_describe_the_release_feed` pins.
    fn probe() -> Endpoint<'static> {
        Endpoint {
            what: "do the thing",
            missing: "the thing is not there",
        }
    }

    #[test]
    fn statuses_map_to_the_codes_a_caller_can_act_on() {
        use reqwest::StatusCode;
        let none = headers(&[]);
        assert_eq!(
            status_error(StatusCode::NOT_FOUND, &none, "", probe()).code,
            ErrorCode::RemoteNotFound
        );
        assert_eq!(
            status_error(StatusCode::INTERNAL_SERVER_ERROR, &none, "", probe()).code,
            ErrorCode::General
        );
        // 429 is a rate limit whatever else it carries.
        assert_eq!(
            status_error(StatusCode::TOO_MANY_REQUESTS, &none, "", probe()).code,
            ErrorCode::RateLimited
        );
    }

    /// A 403 is only a rate limit when something in the response says so.
    ///
    /// This is the case that used to be wrong in the direction that costs the user the most:
    /// every 403 was reported as `RATE_LIMITED` with "try again later", so a refusal that
    /// waiting cannot fix — a blocked user agent, an intercepting proxy answering before
    /// GitHub — sent them away to wait for something that was never going to change, with
    /// GitHub's own explanation dropped on the floor.
    #[test]
    fn a_bare_403_is_not_called_a_rate_limit() {
        let err = status_error(
            reqwest::StatusCode::FORBIDDEN,
            &headers(&[]),
            "Request forbidden by administrative rules",
            probe(),
        );
        assert_eq!(err.code, ErrorCode::General, "{}", err.message);
        assert!(
            err.message.contains("administrative rules"),
            "GitHub's own words have to survive: {}",
            err.message
        );
        assert!(
            !err.message.contains("try again later"),
            "advice that cannot work must not be given: {}",
            err.message
        );
    }

    /// The three shapes GitHub uses to say "too many requests", each recognised.
    #[test]
    fn every_shape_of_rate_limit_is_recognised() {
        let cases: [(&str, reqwest::header::HeaderMap, &str); 3] = [
            // Primary: 403 with the budget spent.
            (
                "exhausted budget",
                headers(&[("x-ratelimit-remaining", "0")]),
                "",
            ),
            // Secondary: 403 with a wait, and a remaining count that says nothing.
            (
                "secondary limit",
                headers(&[("retry-after", "60"), ("x-ratelimit-remaining", "37")]),
                "",
            ),
            // Headers stripped by a middlebox; the body is the fallback, as in `crate::github`.
            (
                "body only",
                headers(&[]),
                "API rate limit exceeded for 1.2.3.4",
            ),
        ];
        for (what, hdrs, body) in cases {
            let err = status_error(reqwest::StatusCode::FORBIDDEN, &hdrs, body, probe());
            assert_eq!(err.code, ErrorCode::RateLimited, "{what}: {}", err.message);
        }
    }

    /// A real limit says how long, because the number is the whole remedy.
    #[test]
    fn a_rate_limit_carries_the_wait_when_the_server_gave_one() {
        // `retry-after` is already seconds.
        let err = status_error(
            reqwest::StatusCode::FORBIDDEN,
            &headers(&[("retry-after", "90")]),
            "",
            probe(),
        );
        assert!(
            err.message.contains("retry after 90s"),
            "expected the wait in the message: {}",
            err.message
        );

        // `x-ratelimit-reset` is an absolute epoch second and has to become a delta.
        let soon = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs()
            + 600;
        let err = status_error(
            reqwest::StatusCode::FORBIDDEN,
            &headers(&[
                ("x-ratelimit-remaining", "0"),
                ("x-ratelimit-reset", &soon.to_string()),
            ]),
            "",
            probe(),
        );
        assert_eq!(err.code, ErrorCode::RateLimited);
        let secs: u64 = err
            .message
            .rsplit("retry after ")
            .next()
            .and_then(|s| s.trim_end_matches("s").parse().ok())
            .unwrap_or_else(|| panic!("no wait in {}", err.message));
        assert!(
            about_ten_minutes().contains(&secs),
            "600s away should read as about 600s, got {secs} from {}",
            err.message
        );
    }

    /// A reset already in the past is no advice at all, so it is not offered as any.
    #[test]
    fn a_reset_in_the_past_yields_no_wait() {
        let err = status_error(
            reqwest::StatusCode::FORBIDDEN,
            &headers(&[
                ("x-ratelimit-remaining", "0"),
                ("x-ratelimit-reset", "1000000000"),
            ]),
            "",
            probe(),
        );
        assert_eq!(err.code, ErrorCode::RateLimited);
        assert!(
            !err.message.contains("retry after"),
            "a wait of zero or less must be omitted, not printed: {}",
            err.message
        );
    }

    /// The tolerance for the delta test above: the clock moves between building the header
    /// and reading it back, so the assertion is a window rather than an equality.
    fn about_ten_minutes() -> std::ops::RangeInclusive<u64> {
        595..=600
    }

    /// Both origins are fixed at compile time. A config key or an environment variable here
    /// would let something else choose the repository whose release notes get rendered inside
    /// GitPic's window — and, for the tap, the version string shown beside a command the user
    /// is being told to run.
    #[test]
    fn the_release_feed_is_a_compile_time_constant() {
        assert_eq!(RELEASES_REPO, "tarnish233/gitpic");
        assert_eq!(TAP_REPO, "tarnish233/homebrew-tap");
        assert_eq!(TAP_CASK_PATH, "Casks/gitpic.rb");
        assert!(API.starts_with("https://"));
    }

    /// Two endpoints share one client, so each has to describe its own failures.
    ///
    /// `status_error` was written when this module had a single endpoint and hardcoded the
    /// release feed into three of its arms. Generalising the client for the tap lookup left them
    /// alone, so a 404 on the cask reported that `tarnish233/gitpic has published no releases
    /// yet` — the wrong repository and the wrong resource, from a command that never touched the
    /// release feed — and a consumer branching on `RemoteNotFound` for the feed started
    /// receiving it from the tap as well.
    #[test]
    fn a_tap_failure_does_not_describe_the_release_feed() {
        let none = headers(&[]);
        let tap = Endpoint {
            what: "read the Homebrew tap",
            missing: &format!("{TAP_REPO} has no {TAP_CASK_PATH}"),
        };
        let missing = status_error(reqwest::StatusCode::NOT_FOUND, &none, "", tap);
        assert_eq!(missing.code, ErrorCode::RemoteNotFound);
        assert!(
            missing.message.contains(TAP_REPO) && missing.message.contains(TAP_CASK_PATH),
            "a 404 has to name the file that is missing: {}",
            missing.message
        );
        assert!(
            !missing.message.contains(RELEASES_REPO),
            "and must not name the release feed: {}",
            missing.message
        );
        // The same for every other arm: they all used to say "check for updates".
        for status in [
            reqwest::StatusCode::UNAUTHORIZED,
            reqwest::StatusCode::TOO_MANY_REQUESTS,
            reqwest::StatusCode::FORBIDDEN,
            reqwest::StatusCode::INTERNAL_SERVER_ERROR,
        ] {
            let err = status_error(status, &none, "", tap);
            assert!(
                !err.message.contains("check for updates"),
                "{status} still blames the update check: {}",
                err.message
            );
        }
    }

    /// Not a Ruby parser, and the rows that matter are the refusals. A csv version is a real
    /// Homebrew spelling (`Cask#version.csv`) and comparing against `"1.2,345"` as though it
    /// were a version would let the app claim 「已是最新」 over a pending upgrade.
    #[test]
    fn a_cask_version_is_read_only_when_it_is_plainly_comparable() {
        assert_eq!(
            cask_version("cask \"gitpic\" do\n  version \"0.20.9\"\n"),
            Some("0.20.9")
        );
        // Whatever else is in the file, including a comment that mentions the word.
        assert_eq!(
            cask_version("# the version below is rewritten by the tap\n  version \"1.2.3\"\nend"),
            Some("1.2.3")
        );
        for refused in [
            "  version \"1.2,345\"\n",     // csv — two fields, not a version
            "  version :latest\n",         // a symbol, not a literal
            "  version \"#{ENV['V']}\"\n", // interpolated
            "  version \"0.20\"\n",        // not three components
            "  version \"0.20.0-rc1\"\n",  // prerelease, which `Version` refuses
            "cask \"gitpic\" do\nend\n",   // no stanza at all
            "",
        ] {
            assert_eq!(cask_version(refused), None, "{refused:?}");
        }
    }

    /// The happy path, against the wire shape GitHub actually sends: base64 **wrapped**, which
    /// the decoder rejects until the whitespace is stripped. Encoding it unwrapped here would
    /// have tested a reply this code never receives.
    #[tokio::test]
    async fn reads_the_version_the_tap_declares() {
        let cask = "cask \"gitpic\" do\n  version \"9.9.9\"\n  sha256 \"ab\"\nend\n";
        let encoded = base64::engine::general_purpose::STANDARD.encode(cask);
        let mid = encoded.len() / 2;
        let wrapped = format!("{}\\n{}", &encoded[..mid], &encoded[mid..]);
        let body = format!(r#"{{"content":"{wrapped}","encoding":"base64"}}"#);
        let (addr, served) = crate::testutil::stub(vec![crate::testutil::http("200 OK", &body)]);

        let out = tap_cask_against(&addr, None).await.unwrap();
        assert!(out.ok);
        assert_eq!(out.version.as_deref(), Some("9.9.9"));
        assert_eq!(out.cask, CASK);

        let req = served.join().unwrap().remove(0);
        assert!(
            req.contains(&format!("GET /repos/{TAP_REPO}/contents/{TAP_CASK_PATH}")),
            "unexpected request: {req}"
        );
        assert!(
            !req.to_lowercase().contains("authorization:"),
            "no credential was given, so none may be sent: {req}"
        );
    }

    /// A cask that parsed but says nothing comparable is `version: null` and **not** an error:
    /// the file was read. The app treats both as "could not tell", but conflating them here
    /// would report a network failure that did not happen.
    #[tokio::test]
    async fn an_uncomparable_cask_is_read_as_no_version_rather_than_an_error() {
        let encoded = base64::engine::general_purpose::STANDARD.encode("  version \"1.2,345\"\n");
        let body = format!(r#"{{"content":"{encoded}","encoding":"base64"}}"#);
        let (addr, served) = crate::testutil::stub(vec![crate::testutil::http("200 OK", &body)]);

        let out = tap_cask_against(&addr, None).await.unwrap();
        assert!(out.ok);
        assert_eq!(out.version, None);
        served.join().unwrap();
    }

    /// GitHub sends `encoding: "none"` for a file too large to inline. A cask is kilobytes so
    /// this should not happen — and if it does, decoding an empty string into "the tap declares
    /// nothing" would be a silent wrong answer where an error is the honest one.
    #[tokio::test]
    async fn an_unexpected_encoding_is_an_error_and_not_an_empty_version() {
        let body = r#"{"content":"","encoding":"none"}"#;
        let (addr, served) = crate::testutil::stub(vec![crate::testutil::http("200 OK", body)]);

        let err = tap_cask_against(&addr, None).await.unwrap_err();
        assert!(
            err.to_string().contains("none-encoded"),
            "should name the encoding it could not read: {err}"
        );
        served.join().unwrap();
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

    /// End to end over a loopback socket, and the anonymous half of the credential contract.
    ///
    /// Two jobs in one test because they need the same request: the URL that gets asked for
    /// and a real decode of a GitHub-shaped reply, plus the assertion that a check with no
    /// credential sends no `Authorization`. Named for the second because that is the one a
    /// future edit could break silently — a wrong URL or a failed decode fails loudly on its
    /// own.
    #[tokio::test]
    async fn sends_no_credential_when_there_is_none() {
        let body = r#"{"tag_name":"v9.9.9","name":"GitPic 9.9.9",
            "body":"- a line of notes","html_url":"https://example.invalid/rel",
            "published_at":"2026-08-24T01:02:03Z"}"#;
        let (addr, served) = crate::testutil::stub(vec![crate::testutil::http("200 OK", body)]);

        let out = check_against(&addr, None).await.unwrap();
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
        // Header assertions go through one lowercased copy, because HTTP header names are
        // case-insensitive and nothing here may depend on how they were spelled on the wire.
        //
        // Not a style point — this is what CI caught. `hyper` writes them lowercase, so
        // `contains("User-Agent: ")` is false against a real request; it passed on the
        // author's machine only because `http_proxy` was set in the environment, `reqwest`
        // honours that, and the local proxy rewrote the request in title case on its way to
        // the loopback stub. So the assertions were being made against the proxy's output
        // rather than gitpic's — including the credential one below, which is the whole
        // reason this test exists.
        let headers = req.to_lowercase();
        // GitHub refuses requests without one, so this is a contract and not a courtesy.
        assert!(headers.contains("user-agent: gitpic/"), "no UA: {req}");
        // No credential to send, so none is sent. **Narrowed in 0.20.5, not deleted.** This
        // used to assert that the update check never authenticates at all, which was a real
        // property with a real reason — and it stopped being true when a measurement showed
        // the anonymous 60-an-hour budget is per *address*, so a shared NAT egress leaves it
        // permanently spent and the check simply cannot work there. See the module header.
        //
        // What is guarded now is narrower and still worth guarding: the header appears only
        // when there is a credential (here), only against the compile-time base and in bearer
        // form (`sends_the_credential_only_to_the_fixed_base`), and never on a redirect
        // (`does_not_follow_a_redirect_with_a_credential`). A blanket claim would now be false,
        // and a false comment about a credential is worse than none.
        //
        // This assertion is also why the request is read through `testutil` rather than with
        // the single `sock.read` that used to be inlined here. A negative assertion over a
        // partial read passes because the header block was never read, not because no
        // credential was sent — so the one check standing between a future edit and a leaked
        // token would have been reporting success either way. `read_request` reads to the end
        // of the headers before this looks at them.
        assert!(
            !headers.contains("authorization:"),
            "an anonymous check must send no credential: {req}"
        );
    }

    /// With a credential, it goes out — in bearer form, and only to the base under test.
    ///
    /// The positive half of the pair above. Written against an explicit token rather than
    /// whatever `auth.toml` holds, so this states the case instead of inheriting it.
    #[tokio::test]
    async fn sends_the_credential_only_to_the_fixed_base() {
        let body = r#"{"tag_name":"v9.9.9","html_url":"https://example.invalid/rel"}"#;
        let (addr, served) = crate::testutil::stub(vec![crate::testutil::http("200 OK", body)]);

        let out = check_against(&addr, Some("ghp_notarealtoken"))
            .await
            .unwrap();
        assert_eq!(out.latest, "9.9.9");

        let req = served.join().unwrap().remove(0);
        let headers = req.to_lowercase();
        assert!(
            headers.contains("authorization: bearer ghp_notarealtoken"),
            "the credential must be sent as a bearer token: {req}"
        );
        // One request, to the one path. A second would mean the anonymous retry fired on a
        // response that was not a rejection.
        assert!(
            req.contains(&format!("GET /repos/{RELEASES_REPO}/releases/latest")),
            "unexpected request: {req}"
        );
    }

    /// A credential GitHub refuses falls back to an anonymous request instead of failing.
    ///
    /// The point is that a stale *image-host* token cannot break update checks: the two have
    /// nothing to do with each other, and someone whose `auth.toml` expired should still be
    /// told a new version exists. The second request must carry no credential — retrying with
    /// the same rejected one would be a loop with extra steps.
    #[tokio::test]
    async fn a_rejected_credential_retries_anonymously() {
        let body = r#"{"tag_name":"v9.9.9","html_url":"https://example.invalid/rel"}"#;
        let (addr, served) = crate::testutil::stub(vec![
            crate::testutil::http("401 Unauthorized", r#"{"message":"Bad credentials"}"#),
            crate::testutil::http("200 OK", body),
        ]);

        let out = check_against(&addr, Some("expired"))
            .await
            .expect("a rejected credential must not fail the check");
        assert_eq!(out.latest, "9.9.9");

        let reqs = served.join().unwrap();
        assert_eq!(reqs.len(), 2, "expected a second, anonymous attempt");
        assert!(
            reqs[0]
                .to_lowercase()
                .contains("authorization: bearer expired"),
            "the first attempt should carry the credential: {}",
            reqs[0]
        );
        assert!(
            !reqs[1].to_lowercase().contains("authorization:"),
            "the retry must be anonymous: {}",
            reqs[1]
        );
    }

    /// The credential cannot be carried anywhere by a redirect, and this can tell.
    ///
    /// `reqwest` strips sensitive headers across hosts on its own, and this does not rely on
    /// that: the client refuses redirects outright, so there is no second request at all.
    ///
    /// **The `Location` points back at the stub, and that is the whole design of the test.**
    /// The first version sent it to `http://example.invalid/elsewhere`, which resolves
    /// nowhere — so following the redirect and refusing to follow it produced the same two
    /// observable facts, one request and an error, and the assertion passed with the redirect
    /// policy deleted. Checked by deleting it. A relative `Location` resolves against the
    /// request URL, so a client that follows comes straight back here and is counted.
    #[tokio::test]
    async fn does_not_follow_a_redirect_with_a_credential() {
        let moved = "HTTP/1.1 302 Found\r\nLocation: /redirected\r\n\
                     Content-Length: 0\r\nConnection: close\r\n\r\n"
            .to_string();
        let body = r#"{"tag_name":"v9.9.9","html_url":"https://example.invalid/rel"}"#;
        // Two responses queued: if the redirect is followed the stub serves both and the
        // check succeeds, which is the failure this asserts against.
        let (addr, served) =
            crate::testutil::stub(vec![moved, crate::testutil::http("200 OK", body)]);

        let err = check_against(&addr, Some("ghp_notarealtoken"))
            .await
            .expect_err("a redirect must not be followed");

        // The listener still holds an unserved response, so joining it would block. What can
        // be asserted without that is the outcome: a 302 became an error rather than a
        // successful check, which only happens if the hop was refused.
        drop(served);
        assert_ne!(
            err.code,
            ErrorCode::RemoteNotFound,
            "a 302 must not be read as 'no releases': {}",
            err.message
        );
        assert!(
            err.message.contains("302") || err.message.contains("check for updates"),
            "unexpected error for a refused redirect: {}",
            err.message
        );
    }

    /// The asset fields the app installs an update from, decoded from a GitHub-shaped reply.
    ///
    /// Verbatim from `repos/tarnish233/gitpic/releases/latest` (trimmed to two assets), so
    /// this fails if GitHub's spelling of any of the four moves. `digest` is the one that
    /// matters most and is the one with no documented contract behind it.
    #[tokio::test]
    async fn reports_the_assets_with_their_digests() {
        let body = r#"{"tag_name":"v9.9.9","html_url":"https://example.invalid/rel",
            "assets":[
              {"name":"GitPic-9.9.9-macos-arm64.dmg","size":4999203,
               "browser_download_url":"https://example.invalid/d/GitPic-9.9.9-macos-arm64.dmg",
               "digest":"sha256:60f48a611df65e09d17d9b55f7ef730be9070ef3fafcb2e3db54519e47bd14b2"},
              {"name":"GitPic-9.9.9-macos-arm64.dmg.sha256","size":96,
               "browser_download_url":"https://example.invalid/d/sidecar"}
            ]}"#;
        let (addr, served) = crate::testutil::stub(vec![crate::testutil::http("200 OK", body)]);

        let out = check_against(&addr, None).await.unwrap();
        assert_eq!(
            out.assets.len(),
            2,
            "both assets must survive: {:?}",
            out.assets
        );

        let dmg = &out.assets[0];
        assert_eq!(dmg.name, "GitPic-9.9.9-macos-arm64.dmg");
        assert_eq!(dmg.size, 4_999_203);
        // `browser_download_url`, not a URL this crate built.
        assert_eq!(
            dmg.url,
            "https://example.invalid/d/GitPic-9.9.9-macos-arm64.dmg"
        );
        // Prefix included: dropping it would let a future `sha512:` be hashed as SHA-256.
        assert_eq!(
            dmg.digest.as_deref(),
            Some("sha256:60f48a611df65e09d17d9b55f7ef730be9070ef3fafcb2e3db54519e47bd14b2")
        );
        // An asset GitHub reported no digest for stays `None` rather than becoming an empty
        // string — the consumer refuses to install on `None`, so the two must not blur.
        assert_eq!(out.assets[1].digest, None);

        served.join().unwrap();
    }

    /// A release with no assets, and one whose reply omits the key altogether.
    ///
    /// Both must be an empty list rather than an error: every release before 0.15.0 published
    /// no disk image, and `releases/latest` is the endpoint the app polls forever — a decode
    /// that failed on one of those would take the whole update check down with it, reported as
    /// 「看不懂 gitpic 的回答」.
    #[test]
    fn a_release_without_assets_reports_an_empty_list() {
        let out = report("1.0.0", release("v1.2.3")).unwrap();
        assert!(out.assets.is_empty());

        // The key missing entirely, which is not what GitHub sends today but is what
        // `#[serde(default)]` is there for.
        let decoded: LatestRelease =
            serde_json::from_str(r#"{"tag_name":"v1.2.3","html_url":"https://e.invalid"}"#)
                .expect("a reply with no assets key must still decode");
        assert!(decoded.assets.is_empty());
    }

    /// `digest` is omitted from the envelope when absent rather than emitted as `null`.
    ///
    /// The Swift side decodes this into an Optional either way, so this is about the envelope
    /// staying readable — the same `skip_serializing_if` the doctor report uses.
    #[test]
    fn a_missing_digest_is_left_out_of_the_json() {
        let with = serde_json::to_string(&ReleaseAsset {
            name: "a.dmg".to_string(),
            size: 1,
            url: "https://e.invalid/a".to_string(),
            digest: Some("sha256:ab".to_string()),
        })
        .unwrap();
        assert!(with.contains(r#""digest":"sha256:ab""#), "{with}");

        let without = serde_json::to_string(&ReleaseAsset {
            name: "a.dmg".to_string(),
            size: 1,
            url: "https://e.invalid/a".to_string(),
            digest: None,
        })
        .unwrap();
        assert!(!without.contains("digest"), "null digest leaked: {without}");
    }
}
