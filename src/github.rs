//! Minimal GitHub REST client for the Contents API + health checks.

use crate::error::{AppError, ErrorCode, Result};
use crate::naming::encode_path;
use base64::Engine;
use serde::{Deserialize, Serialize};
use sha1::{Digest, Sha1};
use std::time::Duration;

const DEFAULT_API: &str = "https://api.github.com";
const UA: &str = concat!("gitpic/", env!("CARGO_PKG_VERSION"));

/// Whole-request ceiling. Uploads of a few MB over a slow link must still fit,
/// but a half-open connection must not hang the CLI forever.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(120);
/// TCP/TLS connect ceiling — a black-holed address should fail fast.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(15);

/// API base URL.
///
/// Release builds always talk to GitHub. Debug and test builds may retarget the
/// client with `GITPIC_API_BASE` so the failure paths can be exercised against a
/// stub, but only to a loopback address: every request carries the configured
/// token in an `Authorization` header, so an arbitrary host would exfiltrate it.
fn api_base() -> String {
    #[cfg(debug_assertions)]
    if let Ok(v) = std::env::var("GITPIC_API_BASE") {
        let v = v.trim_end_matches('/');
        if !v.is_empty() {
            if is_loopback_url(v) {
                return v.to_string();
            }
            // Never silently fall back — a test pointed somewhere unexpected
            // should fail loudly rather than hit the real API with a real token.
            panic!("GITPIC_API_BASE must be a loopback address, got {v:?}");
        }
    }
    DEFAULT_API.to_string()
}

/// True when `url` parses and its host is a loopback address (`127.0.0.0/8`,
/// `::1`, or `localhost`).
#[cfg(debug_assertions)]
fn is_loopback_url(url: &str) -> bool {
    let Ok(parsed) = reqwest::Url::parse(url) else {
        return false;
    };
    match parsed.host_str() {
        Some("localhost") => true,
        // Resolve the literal so 127.0.0.1 and any other 127.0.0.0/8 address
        // both pass, while a name that merely looks local does not.
        Some(h) => match h.trim_start_matches('[').trim_end_matches(']').parse() {
            Ok(std::net::IpAddr::V4(ip)) => ip.is_loopback(),
            Ok(std::net::IpAddr::V6(ip)) => ip.is_loopback(),
            Err(_) => false,
        },
        None => false,
    }
}

pub struct GitHub {
    client: reqwest::Client,
    token: String,
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
    #[serde(default)]
    #[allow(dead_code)]
    pub default_branch: Option<String>,
}
#[derive(Deserialize)]
pub struct RepoPermissions {
    #[serde(default)]
    pub push: bool,
    #[serde(default)]
    pub admin: bool,
}

impl GitHub {
    pub fn new(token: &str, owner: &str, repo: &str, branch: &str) -> Result<Self> {
        let client = reqwest::Client::builder()
            .user_agent(UA)
            .timeout(REQUEST_TIMEOUT)
            .connect_timeout(CONNECT_TIMEOUT)
            .build()
            .map_err(|e| AppError::network(format!("http client: {e}")))?;
        Ok(Self {
            client,
            token: token.to_string(),
            api: api_base(),
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
            429 => AppError::rate_limited(format!("GitHub rate limit reached ({status}): {body}")),
            500..=599 => AppError::network(format!("GitHub server error ({status}): {body}")),
            _ => AppError::new(
                ErrorCode::General,
                format!("GitHub error ({status}): {body}"),
            ),
        }
    }

    /// GET the existing file sha, if present.
    async fn get_existing(&self, path: &str) -> Result<Option<ContentsGet>> {
        let url = format!(
            "{}/repos/{}/{}/contents/{}?ref={}",
            self.api,
            self.owner,
            self.repo,
            encode_path(path),
            self.branch
        );
        let resp = self
            .req(reqwest::Method::GET, url)
            .send()
            .await
            .map_err(|e| AppError::network(format!("network: {e}")))?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Ok(None);
        }
        if !resp.status().is_success() {
            let st = resp.status();
            let body = resp.text().await.unwrap_or_default();
            return Err(Self::map_status(st, &body));
        }
        let parsed: ContentsGet = resp
            .json()
            .await
            .map_err(|e| AppError::new(ErrorCode::General, format!("parse contents: {e}")))?;
        Ok(Some(parsed))
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

        let url = format!(
            "{}/repos/{}/{}/contents/{}",
            self.api,
            self.owner,
            self.repo,
            encode_path(path)
        );
        let resp = self
            .req(reqwest::Method::PUT, url)
            .json(&body)
            .send()
            .await
            .map_err(|e| AppError::network(format!("network: {e}")))?;

        if !resp.status().is_success() {
            let st = resp.status();
            let b = resp.text().await.unwrap_or_default();
            return Err(Self::map_status(st, &b));
        }

        let parsed: PutResponse = resp
            .json()
            .await
            .map_err(|e| AppError::new(ErrorCode::General, format!("parse put response: {e}")))?;

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
        let resp = self
            .req(reqwest::Method::GET, format!("{}/user", self.api))
            .send()
            .await
            .map_err(|e| AppError::network(format!("network: {e}")))?;
        if !resp.status().is_success() {
            let st = resp.status();
            let b = resp.text().await.unwrap_or_default();
            return Err(Self::map_status(st, &b));
        }
        let user: User = resp
            .json()
            .await
            .map_err(|e| AppError::new(ErrorCode::General, format!("parse user: {e}")))?;
        Ok(user.login)
    }

    /// Fetch repo info (permissions, default branch).
    pub async fn repo_info(&self) -> Result<RepoInfo> {
        let resp = self
            .req(
                reqwest::Method::GET,
                format!("{}/repos/{}/{}", self.api, self.owner, self.repo),
            )
            .send()
            .await
            .map_err(|e| AppError::network(format!("network: {e}")))?;
        if !resp.status().is_success() {
            let st = resp.status();
            let b = resp.text().await.unwrap_or_default();
            return Err(Self::map_status(st, &b));
        }
        resp.json()
            .await
            .map_err(|e| AppError::new(ErrorCode::General, format!("parse repo: {e}")))
    }
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

#[cfg(test)]
mod tests {
    use super::*;

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
    }

    // Every request carries the token in an Authorization header, so the test
    // override must never accept a host that could receive it. The helper only
    // exists in debug builds, so the test is gated the same way.
    #[cfg(debug_assertions)]
    #[test]
    fn only_loopback_hosts_are_accepted_as_an_api_base() {
        for ok in [
            "http://127.0.0.1:8771",
            "http://127.5.5.5:1",
            "http://localhost:8771",
            "http://LocalHost:8771",
            "http://[::1]:8771",
        ] {
            assert!(is_loopback_url(ok), "{ok} should be accepted");
        }
        for bad in [
            "http://evil.example.com",
            "https://api.github.com",
            "http://169.254.169.254",
            "http://10.0.0.1",
            "http://127.0.0.1.evil.com",
            "http://localhost.evil.com",
            "not a url",
            "",
        ] {
            assert!(!is_loopback_url(bad), "{bad} must be rejected");
        }
    }

    #[test]
    fn release_builds_always_use_the_real_github_api() {
        // In a release build api_base() ignores the env var entirely; in a debug
        // build (where tests run) it is only consulted when set.
        assert_eq!(DEFAULT_API, "https://api.github.com");
        if std::env::var_os("GITPIC_API_BASE").is_none() {
            assert_eq!(api_base(), DEFAULT_API);
        }
    }
}
