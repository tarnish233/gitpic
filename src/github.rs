//! Minimal GitHub REST client for the Contents API + health checks.

use crate::error::{AppError, ErrorCode, Result};
use crate::naming::{encode_path, encode_segment};
use base64::Engine;
use serde::{Deserialize, Serialize};
use sha1::{Digest, Sha1};
use std::time::Duration;

const API: &str = "https://api.github.com";
const UA: &str = concat!("gitpic/", env!("CARGO_PKG_VERSION"));
/// GitHub's Contents API PUT rejects bodies over 100 MB. Checking locally
/// avoids base64-encoding a payload that cannot land.
const CONTENTS_PUT_MAX: usize = 100 * 1024 * 1024;

/// Whole-request ceiling. Uploads of a few MB over a slow link must still fit,
/// but a half-open connection must not hang the CLI forever.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(120);
/// TCP/TLS connect ceiling — a black-holed address should fail fast.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(15);

pub struct GitHub {
    client: reqwest::Client,
    token: String,
    /// API base URL. Always `API` in real use; injectable in unit tests so the
    /// request-building logic can be exercised without a network or an env var.
    api: String,
    pub owner: String,
    pub repo: String,
    pub branch: String,
}

#[derive(Debug)]
pub struct PutOutcome {
    /// remote path uploaded to
    pub path: String,
    /// blob/content sha reported by GitHub
    pub content_sha: String,
    /// whether the identical file already existed (skipped re-upload)
    pub deduped: bool,
    /// byte size uploaded
    pub size: usize,
}

/// The two things an upload needs from a Contents GET: the git blob sha (for
/// dedup, and for the `sha` an overwrite PUT must carry) and the size.
///
/// Reading *only* those two is what makes large files work. For a blob over
/// 1 MB the Contents API still answers **200**, with `sha` and `size` populated
/// but `content: ""` and `encoding: "none"` — verified against a 1.4 MB and a
/// 7.2 MB file with this exact `Accept` and API version. Since `content` and
/// `encoding` are never read and this struct is deliberately not
/// `deny_unknown_fields`, that response parses like any other, so dedup and
/// overwrite behave identically at every size. Adding a required `content`
/// field, or `deny_unknown_fields`, would break every image over 1 MB.
#[derive(Deserialize)]
struct ContentsGet {
    sha: String,
    #[serde(default)]
    size: Option<u64>,
}

#[derive(Deserialize)]
struct PutResponse {
    content: PutContent,
}
#[derive(Deserialize)]
struct PutContent {
    sha: String,
}

/// Request body for the Contents API PUT. Borrows its fields so the base64
/// payload is not copied into an intermediate `serde_json::Value`.
#[derive(Serialize)]
struct PutRequest<'a> {
    message: &'a str,
    content: &'a str,
    branch: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    sha: Option<&'a str>,
}

#[derive(Deserialize)]
pub struct RepoInfo {
    #[serde(default)]
    pub permissions: Option<RepoPermissions>,
    /// Whether GitHub reports the repository private.
    ///
    /// Read from a response `doctor` already fetches, and dropping it was why `doctor`
    /// could not see that a private host plus `link_kind = "cdn"` makes every upload
    /// succeed and every returned link 404: jsDelivr serves only public repositories.
    #[serde(default)]
    pub private: bool,
}
#[derive(Deserialize)]
pub struct RepoPermissions {
    #[serde(default)]
    pub push: bool,
    #[serde(default)]
    pub admin: bool,
}

/// One repository the credential could upload to, as `gitpic repos` reports it.
///
/// Separate from [`RepoInfo`], which answers "may I write to *this* one" for the
/// configured target. This answers "which ones are there at all", which is what a
/// picker needs and what a hand-typed `owner/repo` gets wrong.
///
/// The set is scope-limited rather than complete: with `public_repo` GitHub does not
/// return private repositories, so what a caller sees is already narrowed to what the
/// token could actually use.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct RepoCandidate {
    pub owner: String,
    pub name: String,
    pub private: bool,
    /// What `github.branch` should be set to for this repo. GitHub reports it, so a
    /// picker never has to guess `main` for a repo whose default is `master`.
    pub default_branch: String,
    /// Whether the credential may write.
    ///
    /// Reported rather than filtered here, so the *caller* decides. Both callers
    /// exclude the false ones — a target that cannot be written to is not a choice —
    /// and both say how many they dropped, because "my repo is missing from the list"
    /// is the harder question to answer.
    pub can_push: bool,
}

impl RepoCandidate {
    /// `owner/name`: the label, and exactly what `github.repo` accepts.
    pub fn spec(&self) -> String {
        format!("{}/{}", self.owner, self.name)
    }
}

/// How many pages of 100 the repository listing will walk before giving up.
///
/// A ceiling rather than an unbounded loop, because this is the only paginated request
/// gitpic makes and a response that never shortens would otherwise spin. Ten pages is
/// 1000 repositories; a caller that hits it is told, rather than handed a quietly
/// truncated list.
const MAX_PAGES: u32 = 10;
const PER_PAGE: u32 = 100;

#[derive(Deserialize)]
struct RepoRow {
    name: String,
    #[serde(default)]
    private: bool,
    #[serde(default)]
    default_branch: Option<String>,
    owner: OwnerRow,
    #[serde(default)]
    permissions: Option<RepoPermissions>,
}
#[derive(Deserialize)]
struct OwnerRow {
    login: String,
}

/// The target branch, as GitHub describes it.
#[derive(Deserialize)]
pub struct BranchInfo {
    /// Branch protection is reported but does not by itself mean "cannot write":
    /// the rules may well permit this account. It is surfaced as a caveat because
    /// it is a common cause of an upload failing with 409/422 after every
    /// permission check passed.
    #[serde(default)]
    pub protected: bool,
}

impl GitHub {
    pub fn new(token: &str, owner: &str, repo: &str, branch: &str) -> Result<Self> {
        Self::with_api(API, token, owner, repo, branch)
    }

    /// A client for the endpoints that are not about one repository — `/user`.
    ///
    /// `owner`, `repo` and `branch` stay empty because nothing reachable through
    /// it interpolates them: [`GitHub::whoami`] is the only caller and it hits
    /// `/user`. That is exactly what `gitpic auth login` and `auth status` need —
    /// "is this token accepted, and by whom" — before, or entirely without, an
    /// upload target being configured.
    pub fn for_user(token: &str) -> Result<Self> {
        Self::with_api(API, token, "", "", "")
    }

    /// Construct a client against an explicit API base.
    ///
    /// Deliberately private: every request carries the token in an
    /// `Authorization` header, so the base must never be influenced by the
    /// environment. Tests in this module inject a loopback stub directly.
    fn with_api(api: &str, token: &str, owner: &str, repo: &str, branch: &str) -> Result<Self> {
        let client = reqwest::Client::builder()
            .user_agent(UA)
            .timeout(REQUEST_TIMEOUT)
            .connect_timeout(CONNECT_TIMEOUT)
            .build()
            .map_err(|e| AppError::network(format!("http client: {e}")))?;
        Ok(Self {
            client,
            token: token.to_string(),
            api: api.to_string(),
            owner: owner.to_string(),
            repo: repo.to_string(),
            branch: branch.to_string(),
        })
    }

    fn req(&self, method: reqwest::Method, url: String) -> reqwest::RequestBuilder {
        self.client
            .request(method, url)
            .bearer_auth(&self.token)
            .header("Accept", "application/vnd.github+json")
            .header("X-GitHub-Api-Version", "2022-11-28")
    }

    /// `<api>/repos/<owner>/<repo>`, with every interpolated value encoded.
    ///
    /// Encoding is what stops a value from changing the URL's *structure*.
    /// GitHub constrains owner and repo to `[A-Za-z0-9._-]`, so for those this is
    /// an identity and the point is uniformity: one place where the rule holds,
    /// rather than three format strings to keep in step.
    fn repo_base(&self) -> String {
        format!(
            "{}/repos/{}/{}",
            self.api,
            encode_segment(&self.owner),
            encode_segment(&self.repo)
        )
    }

    /// How long GitHub asked us to wait, in seconds, if it said at all.
    ///
    /// Two headers, two shapes: `retry-after` is a delay and is what a *secondary* rate
    /// limit sends; `x-ratelimit-reset` is an absolute unix timestamp and is what the
    /// primary one sends. Both become a delay so the message carries one shape, and a
    /// reset already in the past clamps to zero rather than wrapping.
    fn retry_hint(headers: &reqwest::header::HeaderMap) -> Option<u64> {
        let get = |k| {
            headers
                .get(k)
                .and_then(|v: &reqwest::header::HeaderValue| v.to_str().ok())
        };
        if let Some(secs) = get("retry-after").and_then(|v| v.trim().parse::<u64>().ok()) {
            return Some(secs);
        }
        let reset = get("x-ratelimit-reset").and_then(|v| v.trim().parse::<i64>().ok())?;
        Some((reset - chrono::Utc::now().timestamp()).max(0) as u64)
    }

    fn map_status(status: reqwest::StatusCode, body: &str) -> AppError {
        match status.as_u16() {
            401 => AppError::auth(format!("GitHub authentication failed ({status}): {body}")),
            403 if body.to_ascii_lowercase().contains("rate limit") => {
                AppError::rate_limited(format!("GitHub rate limit reached ({status}): {body}"))
            }
            403 => {
                AppError::permission_denied(format!("GitHub permission denied ({status}): {body}"))
            }
            404 => AppError::remote_not_found(format!(
                "GitHub repository, branch, or remote path not found ({status}): {body}"
            )),
            409 => AppError::network(format!(
                "GitHub ref conflict ({status}): {body}; retry the upload"
            )),
            // The same race as the 409 below, seen from the other side: `put_file` does
            // GET-then-PUT, so when the path is *created* between the two our PUT
            // carries no `sha` and GitHub answers 422 "sha wasn't supplied". A 409 is
            // when the sha we did send went stale, and that one has been `NETWORK` —
            // "so agents retry it" — since 0.13.2. Two processes uploading the same
            // bytes (`gitpic *.png` under `xargs -P4`, or a right-click batch
            // overlapping a terminal run) hit whichever of the two comes up, so the
            // loser was told exit 1, which `SKILL.md` defines as "do not retry", for a
            // re-run that would have deduped and succeeded instantly.
            //
            // Guarded on the body, not on the status: 422 is also branch protection,
            // which no retry can fix and which would loop an agent forever.
            //
            // Matched on `wasn't supplied` rather than on the quoted `"sha"`: `body` is
            // the raw JSON text, so the quotes GitHub puts round `sha` arrive
            // backslash-escaped and a pattern including them never fires. The
            // apostrophe is not escaped, and no other 422 from this API says it.
            422 if body.contains("wasn't supplied") => AppError::network(format!(
                "GitHub ref conflict ({status}): {body}; retry the upload"
            )),
            422 => AppError::general(format!("GitHub rejected the request ({status}): {body}")),
            429 => AppError::rate_limited(format!("GitHub rate limit reached ({status}): {body}")),
            500..=599 => AppError::network(format!("GitHub server error ({status}): {body}")),
            _ => AppError::general(format!("GitHub error ({status}): {body}")),
        }
    }

    /// Send a request and deserialize a successful JSON body.
    ///
    /// Every response funnels through `map_status`, so the stable error codes
    /// agents key on cannot be bypassed by a new endpoint forgetting to
    /// classify its failures.
    async fn send_json<T: serde::de::DeserializeOwned>(
        &self,
        rb: reqwest::RequestBuilder,
        what: &str,
    ) -> Result<T> {
        let resp = rb
            .send()
            .await
            .map_err(|e| AppError::network(format!("network: {e}")))?;
        if !resp.status().is_success() {
            let st = resp.status();
            // Read before the body is consumed. `RATE_LIMITED` is the one code in the
            // set whose whole purpose is to be retried, and it was the one carrying the
            // least information: GitHub's body says "retry later" without a number, and
            // the header holding the number was dropped one line further down. An agent
            // then had to guess between a minute and three quarters of an hour, and
            // guessing short is what deepens a secondary rate limit.
            let retry_after = Self::retry_hint(resp.headers());
            let body = resp.text().await.unwrap_or_default();
            return Err(Self::map_status(st, &body).with_retry_hint(retry_after));
        }
        resp.json()
            .await
            .map_err(|e| AppError::general(format!("parse {what}: {e}")))
    }

    /// GET the existing file sha, if present.
    async fn get_existing(&self, path: &str) -> Result<Option<ContentsGet>> {
        // The branch is encoded like every other interpolated value. Git allows
        // `&`, `#`, `+`, `%` and `=` in a ref name, and each one silently changes
        // what this URL means: `#` makes the rest a fragment, `&` starts another
        // parameter, `+` decodes to a space. The result was a GET against the
        // wrong ref — read as "nothing uploaded there yet", which loses dedup and
        // then omits the sha from the PUT below, so overwriting fails with a 409.
        // `/` is deliberately left intact: it is legal in a query value and is
        // exactly what GitHub expects for `feat/x`.
        let url = format!(
            "{}/contents/{}?ref={}",
            self.repo_base(),
            encode_path(path),
            encode_path(&self.branch)
        );
        match self
            .send_json::<ContentsGet>(self.req(reqwest::Method::GET, url), "contents")
            .await
        {
            Ok(c) => Ok(Some(c)),
            // 404 is the only status `map_status` maps to RemoteNotFound, so this
            // is the ordinary "nothing uploaded at that path yet" case. If a
            // future arm maps another status here (e.g. 410), a *gone* path would
            // read as *absent* and the PUT below would omit the sha.
            Err(e) if e.code == ErrorCode::RemoteNotFound => Ok(None),
            Err(e) => Err(e),
        }
    }

    /// Upload (create or update) a file at `path` with `bytes`.
    /// If `dedup` is true and identical bytes already exist at `path`, skip the upload.
    pub async fn put_file(
        &self,
        path: &str,
        bytes: &[u8],
        message: &str,
        dedup: bool,
    ) -> Result<PutOutcome> {
        reject_oversize(path, bytes.len())?;
        let existing = self.get_existing(path).await?;

        if let Some(ref e) = existing {
            if dedup && content_matches(&e.sha, bytes) {
                return Ok(PutOutcome {
                    path: path.to_string(),
                    content_sha: e.sha.clone(),
                    deduped: true,
                    size: e.size.unwrap_or(bytes.len() as u64) as usize,
                });
            }
        }

        let content_b64 = base64::engine::general_purpose::STANDARD.encode(bytes);
        let body = PutRequest {
            message,
            content: &content_b64,
            branch: &self.branch,
            sha: existing.as_ref().map(|e| e.sha.as_str()),
        };

        let url = format!("{}/contents/{}", self.repo_base(), encode_path(path));
        let parsed: PutResponse = self
            .send_json(
                self.req(reqwest::Method::PUT, url).json(&body),
                "put response",
            )
            .await?;

        Ok(PutOutcome {
            path: path.to_string(),
            content_sha: parsed.content.sha,
            deduped: false,
            size: bytes.len(),
        })
    }

    /// Validate the token by calling /user; returns the login on success.
    pub async fn whoami(&self) -> Result<String> {
        #[derive(Deserialize)]
        struct User {
            login: String,
        }
        let user: User = self
            .send_json(
                self.req(reqwest::Method::GET, format!("{}/user", self.api)),
                "user",
            )
            .await?;
        Ok(user.login)
    }

    /// Every repository the credential can reach.
    ///
    /// `affiliation` is spelled out rather than left to GitHub's default so the list
    /// cannot silently change shape under us: repositories the user owns, collaborates
    /// on, or reaches through an organisation. That is the same set a person browsing
    /// their own repositories would expect to pick from.
    ///
    /// Returns `(candidates, complete)`. `complete` is false when the walk hit
    /// [`MAX_PAGES`], so a caller can say "showing the first N" instead of presenting a
    /// truncated list as the whole set.
    pub async fn repo_candidates(&self) -> Result<(Vec<RepoCandidate>, bool)> {
        let mut complete = true;
        let mut candidates = Vec::new();
        for page in 1..=MAX_PAGES {
            let url = format!(
                "{}/user/repos?per_page={PER_PAGE}&page={page}\
                 &affiliation=owner,collaborator,organization_member&sort=full_name",
                self.api
            );
            let rows: Vec<RepoRow> = self
                .send_json(self.req(reqwest::Method::GET, url), "repositories")
                .await?;
            let count = rows.len();
            candidates.extend(rows.into_iter().map(|r| RepoCandidate {
                owner: r.owner.login,
                name: r.name,
                private: r.private,
                // GitHub omits it only for an empty repository, where an upload
                // creates the ref anyway; `main` is what `Config::default` uses.
                default_branch: r.default_branch.unwrap_or_else(|| "main".to_string()),
                can_push: r.permissions.map(|p| p.push || p.admin).unwrap_or(false),
            }));
            // A short page is the last page. Checked before the ceiling so a listing
            // that happens to end exactly on a boundary is not called truncated.
            if count < PER_PAGE as usize {
                break;
            }
            if page == MAX_PAGES {
                complete = false;
            }
        }

        // `sort=full_name` orders each page, but the walk concatenates them and a
        // repository can arrive under two affiliations — which in a dropdown reads as a
        // bug. Sorting locally makes the dedup adjacent and the order independent of
        // how GitHub chose to paginate.
        candidates.sort_by(|a, b| (&a.owner, &a.name).cmp(&(&b.owner, &b.name)));
        candidates.dedup_by(|a, b| a.owner == b.owner && a.name == b.name);
        Ok((candidates, complete))
    }

    /// Every branch on the configured repository.
    ///
    /// The counterpart to [`Self::repo_candidates`], and it exists for the same reason:
    /// an upload's target branch cannot be invented. The Contents API writes into an
    /// existing ref and will not create one, so the set of values `github.branch` may
    /// legally hold is exactly this list — which makes a picker the only shape that
    /// cannot be wrong, and a typed branch name a 404 that reads like a missing repo.
    ///
    /// Returns `(names, complete)` on the same terms as `repo_candidates`.
    pub async fn branch_candidates(&self) -> Result<(Vec<BranchCandidate>, bool)> {
        let mut complete = true;
        let mut branches: Vec<BranchCandidate> = Vec::new();
        for page in 1..=MAX_PAGES {
            let url = format!(
                "{}/branches?per_page={PER_PAGE}&page={page}",
                self.repo_base()
            );
            let rows: Vec<BranchRow> = self
                .send_json(self.req(reqwest::Method::GET, url), "branches")
                .await?;
            let count = rows.len();
            branches.extend(rows.into_iter().map(|r| BranchCandidate {
                name: r.name,
                protected: r.protected,
            }));
            // A short page is the last page, checked before the ceiling so a listing
            // that ends exactly on a boundary is not called truncated.
            if count < PER_PAGE as usize {
                break;
            }
            if page == MAX_PAGES {
                complete = false;
            }
        }
        // GitHub returns branches in its own order, which for a repository with a dozen
        // of them reads as unsorted in a dropdown. The default branch is not hoisted
        // here: which one that is belongs to the caller's config, not to this listing.
        branches.sort_by(|a, b| a.name.cmp(&b.name));
        Ok((branches, complete))
    }

    /// Fetch repo info (permissions).
    pub async fn repo_info(&self) -> Result<RepoInfo> {
        self.send_json(self.req(reqwest::Method::GET, self.repo_base()), "repo")
            .await
    }

    /// Look up the target branch.
    ///
    /// `Ok(None)` means GitHub answered 404: the branch is genuinely absent, which
    /// is a distinct and actionable state rather than a failure — repo-level push
    /// permission says nothing about whether the ref an upload targets exists.
    /// Any other error propagates.
    pub async fn branch_info(&self) -> Result<Option<BranchInfo>> {
        let url = format!(
            "{}/branches/{}",
            self.repo_base(),
            encode_segment(&self.branch)
        );
        match self
            .send_json::<BranchInfo>(self.req(reqwest::Method::GET, url), "branch")
            .await
        {
            Ok(b) => Ok(Some(b)),
            Err(e) if e.code == ErrorCode::RemoteNotFound => Ok(None),
            Err(e) => Err(e),
        }
    }
}

/// One row of `GET /repos/{owner}/{repo}/branches`.
#[derive(Deserialize)]
struct BranchRow {
    name: String,
    #[serde(default)]
    protected: bool,
}

/// One branch an upload could target.
#[derive(Debug, Clone, Serialize)]
pub struct BranchCandidate {
    pub name: String,
    /// Reported, not filtered on: protection does not by itself mean "cannot write" —
    /// the rules may well permit this account — so hiding a protected branch would
    /// remove a legitimate choice. It is the usual explanation when an upload fails
    /// with 409/422 after every permission check passed, which is worth saying next to
    /// the name rather than after the choice.
    pub protected: bool,
}

/// GitHub's Contents API reports a Git blob SHA-1, not a plain file SHA-1.
fn git_blob_sha(bytes: &[u8]) -> String {
    let mut hasher = Sha1::new();
    hasher.update(format!("blob {}\0", bytes.len()).as_bytes());
    hasher.update(bytes);
    format!("{:x}", hasher.finalize())
}

fn content_matches(existing_blob_sha: &str, bytes: &[u8]) -> bool {
    existing_blob_sha.eq_ignore_ascii_case(&git_blob_sha(bytes))
}

pub(crate) fn reject_oversize(path: &str, len: usize) -> Result<()> {
    if len > CONTENTS_PUT_MAX {
        return Err(AppError::usage(format!(
            "{path} is {len} bytes; the GitHub Contents API rejects uploads over 100 MB"
        )));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    // `stub` and `http` moved to `crate::testutil` when `release`'s test needed the same
    // request reader — see that module for why sharing it mattered more than convenience.
    use crate::testutil::{http, stub};

    #[test]
    fn computes_git_blob_sha() {
        assert_eq!(
            git_blob_sha(b""),
            "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391"
        );
    }

    #[test]
    fn dedup_requires_identical_content() {
        let existing = git_blob_sha(b"first image");
        assert!(content_matches(&existing, b"first image"));
        assert!(!content_matches(&existing, b"different image"));
    }

    #[test]
    fn classifies_remote_errors_for_agents() {
        assert_eq!(
            GitHub::map_status(reqwest::StatusCode::UNAUTHORIZED, "bad credentials").code,
            ErrorCode::AuthFailed
        );
        assert_eq!(
            GitHub::map_status(reqwest::StatusCode::FORBIDDEN, "Resource not accessible").code,
            ErrorCode::PermissionDenied
        );
        assert_eq!(
            GitHub::map_status(reqwest::StatusCode::FORBIDDEN, "API rate limit exceeded").code,
            ErrorCode::RateLimited
        );
        assert_eq!(
            GitHub::map_status(reqwest::StatusCode::NOT_FOUND, "Not Found").code,
            ErrorCode::RemoteNotFound
        );
        assert_eq!(
            GitHub::map_status(reqwest::StatusCode::BAD_GATEWAY, "upstream").code,
            ErrorCode::Network
        );
        assert_eq!(
            GitHub::map_status(reqwest::StatusCode::CONFLICT, "is at sha but expected").code,
            ErrorCode::Network
        );
        assert_eq!(
            GitHub::map_status(reqwest::StatusCode::UNPROCESSABLE_ENTITY, "protected").code,
            ErrorCode::General
        );
        // The GET/PUT race, which is the same fault as the 409 above and is now told
        // apart from the other 422s by its body. Branch protection must stay `General`:
        // no retry can fix it, and `Network` would loop an agent on it forever.
        assert_eq!(
            GitHub::map_status(
                reqwest::StatusCode::UNPROCESSABLE_ENTITY,
                r#"{"message":"Invalid request.\n\n\"sha\" wasn't supplied."}"#
            )
            .code,
            ErrorCode::Network
        );
    }

    #[test]
    fn a_rate_limit_carries_when_to_retry_when_github_said() {
        use crate::error::AppError;
        let limited = || AppError::rate_limited("GitHub rate limit reached (403): body");
        // A secondary limit sends `retry-after`, a delay in seconds.
        assert!(limited()
            .with_retry_hint(Some(90))
            .message
            .ends_with("; retry after 90s"));
        // Nothing is appended when GitHub said nothing, and never to another code —
        // "retry after" is guidance only where the remedy is to wait.
        assert!(!limited()
            .with_retry_hint(None)
            .message
            .contains("retry after"));
        assert!(!AppError::general("boom")
            .with_retry_hint(Some(90))
            .message
            .contains("retry after"));
    }

    // The API base is a compile-time constant, so there is no env var or
    // runtime host check that an attacker (or a stray proxy setting) could use
    // to redirect the token-bearing Authorization header.
    #[test]
    fn api_base_is_a_compile_time_constant() {
        assert_eq!(API, "https://api.github.com");
        let gh = GitHub::new("t", "o", "r", "main").unwrap();
        assert_eq!(gh.api, API);
    }

    #[tokio::test]
    async fn put_file_uploads_and_percent_encodes_the_path() {
        // Arrange: 404 (no existing file), then a successful create.
        let (addr, handle) = stub(vec![
            http("404 Not Found", r#"{"message":"Not Found"}"#),
            http("201 Created", r#"{"content":{"sha":"newsha"}}"#),
        ]);
        let gh = GitHub::with_api(&addr, "tok", "o", "r", "main").unwrap();

        // Act
        let out = gh
            .put_file("img/a b.png", b"bytes", "msg", true)
            .await
            .unwrap();

        // Assert
        assert_eq!(out.content_sha, "newsha");
        assert!(!out.deduped);
        assert_eq!(out.size, 5);
        let reqs = handle.join().unwrap();
        assert!(reqs[0].contains("img/a%20b.png"), "GET: {}", reqs[0]);
        assert!(reqs[1].starts_with("PUT "), "expected PUT: {}", reqs[1]);
        assert!(reqs[1].contains("img/a%20b.png"), "PUT: {}", reqs[1]);
    }

    #[tokio::test]
    async fn put_file_skips_upload_when_content_already_matches() {
        // Arrange: the existing blob sha equals the sha of the bytes we send,
        // so only ONE request (the GET) may happen.
        let existing = git_blob_sha(b"same");
        let (addr, handle) = stub(vec![http(
            "200 OK",
            &format!(r#"{{"sha":"{existing}","size":4}}"#),
        )]);
        let gh = GitHub::with_api(&addr, "tok", "o", "r", "main").unwrap();

        let out = gh.put_file("a.png", b"same", "msg", true).await.unwrap();

        assert!(out.deduped);
        assert_eq!(out.content_sha, existing);
        let reqs = handle.join().unwrap();
        assert_eq!(reqs.len(), 1, "dedup must not issue a PUT");
        assert!(reqs[0].starts_with("GET "));
    }

    #[tokio::test]
    async fn put_file_sends_the_existing_sha_when_overwriting() {
        // dedup disabled, so an existing file must be updated with its sha.
        let (addr, handle) = stub(vec![
            http("200 OK", r#"{"sha":"oldsha","size":3}"#),
            http("200 OK", r#"{"content":{"sha":"updated"}}"#),
        ]);
        let gh = GitHub::with_api(&addr, "tok", "o", "r", "main").unwrap();

        let out = gh.put_file("a.png", b"new", "msg", false).await.unwrap();

        assert_eq!(out.content_sha, "updated");
        let reqs = handle.join().unwrap();
        assert!(reqs[1].contains("oldsha"), "PUT body: {}", reqs[1]);
    }

    #[tokio::test]
    async fn put_file_maps_a_remote_error_to_a_stable_code() {
        let (addr, handle) = stub(vec![
            http("404 Not Found", r#"{"message":"Not Found"}"#),
            http("401 Unauthorized", r#"{"message":"Bad credentials"}"#),
        ]);
        let gh = GitHub::with_api(&addr, "tok", "o", "r", "main").unwrap();

        let err = gh
            .put_file("a.png", b"x", "msg", true)
            .await
            .expect_err("401 must be an error");

        assert_eq!(err.code, ErrorCode::AuthFailed);
        let _ = handle.join();
    }

    #[tokio::test]
    async fn a_branch_name_cannot_change_the_query_it_sits_in() {
        // Regression: the branch went into `?ref=` unencoded. Git allows `&`, `#`,
        // `+` and `%` in a ref name, and each rewrites the URL: `#` makes the rest
        // a fragment, `&` starts another parameter, `+` decodes to a space. The
        // GET then read the WRONG ref, which looks like "nothing uploaded here
        // yet" — losing dedup and omitting the sha from the PUT.
        let (addr, handle) = stub(vec![
            http("404 Not Found", r#"{"message":"Not Found"}"#),
            http("201 Created", r#"{"content":{"sha":"newsha"}}"#),
        ]);
        let gh = GitHub::with_api(&addr, "tok", "o", "r", "feat&x#y+z").unwrap();

        gh.put_file("a.png", b"bytes", "msg", true).await.unwrap();

        let reqs = handle.join().unwrap();
        let get = &reqs[0];
        assert!(
            get.contains("?ref=feat%26x%23y%2Bz"),
            "branch must be encoded in the query: {get}"
        );
        // The literal separators must be gone, or the server sees a different ref.
        assert!(!get.contains("ref=feat&"), "raw & survived: {get}");
        assert!(!get.contains('#'), "raw # survived: {get}");
    }

    #[tokio::test]
    async fn a_branch_with_a_slash_still_reaches_the_ref_intact() {
        // `/` is legal in a query value and is what GitHub expects for `feat/x`,
        // so encoding must not touch it. Stub both GET and PUT so the client
        // cannot hang waiting for a second accept after the listing.
        let (addr, handle) = stub(vec![
            http("404 Not Found", r#"{"message":"Not Found"}"#),
            http("201 Created", r#"{"content":{"sha":"newsha"}}"#),
        ]);
        let gh = GitHub::with_api(&addr, "tok", "o", "r", "feat/x").unwrap();

        gh.put_file("a.png", b"bytes", "msg", true).await.unwrap();

        let reqs = handle.join().unwrap();
        assert!(reqs[0].contains("?ref=feat/x"), "GET: {}", reqs[0]);
    }

    #[tokio::test]
    async fn branch_lookup_encodes_a_slash_as_one_path_segment() {
        let (addr, handle) = stub(vec![http("200 OK", r#"{"protected":false}"#)]);
        let gh = GitHub::with_api(&addr, "t", "o", "r", "feat/x").unwrap();
        gh.branch_info().await.unwrap();
        let reqs = handle.join().unwrap();
        assert!(
            reqs[0].contains("/branches/feat%2Fx"),
            "slash must not add a path slot: {}",
            reqs[0]
        );
        assert!(
            !reqs[0].contains("/branches/feat/x"),
            "raw slash survived: {}",
            reqs[0]
        );
    }

    #[tokio::test]
    async fn dedup_works_for_a_blob_the_contents_api_will_not_inline() {
        // A blob over 1 MB comes back 200 with `sha` and `size` populated but
        // `content: ""` and `encoding: "none"` (verified live against a 1.4 MB
        // and a 7.2 MB file). `ContentsGet` reads only sha+size and is not
        // `deny_unknown_fields`, so this parses like any other hit and dedup
        // still fires. Adding a required `content` field, or tightening the
        // struct, would break every image over 1 MB — this test is the tripwire.
        let bytes = b"same";
        let sha = git_blob_sha(bytes);
        let big = format!(
            r#"{{"name":"a.png","path":"dir/a.png","sha":"{sha}","size":1408345,"type":"file","content":"","encoding":"none","download_url":"https://raw.example/a.png"}}"#
        );
        let (addr, handle) = stub(vec![http("200 OK", &big)]);
        let gh = GitHub::with_api(&addr, "t", "o", "r", "main").unwrap();

        let out = gh.put_file("dir/a.png", bytes, "msg", true).await.unwrap();

        assert!(out.deduped, "a large blob must still dedup");
        assert_eq!(out.content_sha, sha);
        // `size` is taken from the response, not from the local byte count.
        assert_eq!(out.size, 1408345);
        let reqs = handle.join().unwrap();
        assert_eq!(reqs.len(), 1, "dedup must not issue a PUT");
    }

    #[tokio::test]
    async fn a_real_403_on_contents_get_is_still_permission_denied() {
        let (addr, handle) = stub(vec![http(
            "403 Forbidden",
            r#"{"message":"Resource not accessible by integration"}"#,
        )]);
        let gh = GitHub::with_api(&addr, "t", "o", "r", "main").unwrap();
        let err = gh
            .put_file("a.png", b"x", "msg", true)
            .await
            .expect_err("must fail");
        assert_eq!(err.code, ErrorCode::PermissionDenied);
        let _ = handle.join();
    }

    #[test]
    fn rejects_a_payload_the_contents_api_cannot_accept() {
        let err = reject_oversize("a.png", CONTENTS_PUT_MAX + 1).expect_err("must fail");
        assert_eq!(err.code, ErrorCode::Usage);
        assert!(err.message.contains("100"), "{}", err.message);
        reject_oversize("a.png", CONTENTS_PUT_MAX).expect("at the limit is accepted");
    }
}
