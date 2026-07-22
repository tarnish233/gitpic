//! Minimal GitHub REST client for the Contents API + health checks.

use crate::error::{AppError, ErrorCode, Result};
use base64::Engine;
use serde::Deserialize;

const API: &str = "https://api.github.com";
const UA: &str = concat!("gitpic/", env!("CARGO_PKG_VERSION"));

pub struct GitHub {
    client: reqwest::Client,
    token: String,
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
            .build()
            .map_err(|e| AppError::network(format!("http client: {e}")))?;
        Ok(Self {
            client,
            token: token.to_string(),
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
            401 | 403 => AppError::auth(format!("GitHub auth failed ({status}): {body}")),
            404 => AppError::not_found(format!("not found ({status}): {body}")),
            _ => AppError::new(ErrorCode::General, format!("GitHub error ({status}): {body}")),
        }
    }

    /// GET the existing file sha, if present.
    async fn get_existing(&self, path: &str) -> Result<Option<ContentsGet>> {
        let url = format!(
            "{API}/repos/{}/{}/contents/{}?ref={}",
            self.owner, self.repo, path, self.branch
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
    /// If `dedup` is true and a file already exists at `path`, skip the upload.
    pub async fn put_file(
        &self,
        path: &str,
        bytes: &[u8],
        message: &str,
        dedup: bool,
    ) -> Result<PutOutcome> {
        let existing = self.get_existing(path).await?;

        if let Some(ref e) = existing {
            if dedup {
                return Ok(PutOutcome {
                    path: path.to_string(),
                    content_sha: e.sha.clone(),
                    deduped: true,
                    size: e.size.unwrap_or(bytes.len() as u64) as usize,
                });
            }
        }

        let content_b64 = base64::engine::general_purpose::STANDARD.encode(bytes);
        let mut body = serde_json::json!({
            "message": message,
            "content": content_b64,
            "branch": self.branch,
        });
        if let Some(e) = existing {
            body["sha"] = serde_json::Value::String(e.sha);
        }

        let url = format!("{API}/repos/{}/{}/contents/{}", self.owner, self.repo, path);
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
            .req(reqwest::Method::GET, format!("{API}/user"))
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
                format!("{API}/repos/{}/{}", self.owner, self.repo),
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
