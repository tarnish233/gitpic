//! Configuration model + resolution.
//!
//! Priority (highest first): CLI flags > environment variables > config.toml
//!   Env vars: GITPIC_TOKEN, GITPIC_OWNER, GITPIC_REPO ("owner/name" or "name"),
//!             GITPIC_BRANCH, GITPIC_LINK (cdn|raw)

use crate::error::{AppError, Result};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct Config {
    #[serde(default)]
    pub github: GithubConfig,
    #[serde(default)]
    pub upload: UploadConfig,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GithubConfig {
    #[serde(default)]
    pub token: String,
    #[serde(default)]
    pub owner: String,
    #[serde(default)]
    pub repo: String,
    #[serde(default = "default_branch")]
    pub branch: String,
}

impl Default for GithubConfig {
    fn default() -> Self {
        Self {
            token: String::new(),
            owner: String::new(),
            repo: String::new(),
            branch: default_branch(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UploadConfig {
    #[serde(default = "default_path_template")]
    pub path_template: String,
    #[serde(default = "default_link_kind")]
    pub link_kind: String,
    #[serde(default = "default_true")]
    pub dedup: bool,
    #[serde(default = "default_true")]
    pub auto_copy: bool,
    #[serde(default)]
    pub compress: bool,
    #[serde(default)]
    pub max_width: u32,
    #[serde(default = "default_quality")]
    pub quality: u8,
}

impl Default for UploadConfig {
    fn default() -> Self {
        Self {
            path_template: default_path_template(),
            link_kind: default_link_kind(),
            dedup: true,
            auto_copy: true,
            compress: false,
            max_width: 0,
            quality: default_quality(),
        }
    }
}

fn default_branch() -> String {
    "main".to_string()
}
fn default_path_template() -> String {
    "images/{year}/{month}/{hash8}-{name}.{ext}".to_string()
}
fn default_link_kind() -> String {
    "cdn".to_string()
}
fn default_true() -> bool {
    true
}
fn default_quality() -> u8 {
    82
}

/// Resolve a base directory: prefer the given XDG env var, else `$HOME/<fallback>`
/// (on Windows, fall back to `%USERPROFILE%`).
fn base_dir(xdg_var: &str, fallback: &str) -> Result<PathBuf> {
    if let Ok(v) = std::env::var(xdg_var) {
        if !v.is_empty() {
            return Ok(PathBuf::from(v));
        }
    }
    let home = std::env::var("HOME")
        .or_else(|_| std::env::var("USERPROFILE"))
        .map_err(|_| {
            AppError::new(
                crate::error::ErrorCode::General,
                "cannot resolve home directory",
            )
        })?;
    let mut p = PathBuf::from(home);
    for part in fallback.split('/') {
        p.push(part);
    }
    Ok(p)
}

impl Config {
    /// Locate the config file: `$XDG_CONFIG_HOME/gitpic/config.toml`
    /// (falls back to `~/.config/gitpic/config.toml`). Does not require it to exist.
    pub fn path() -> Result<PathBuf> {
        Ok(base_dir("XDG_CONFIG_HOME", ".config")?
            .join("gitpic")
            .join("config.toml"))
    }

    /// Locate the upload-history file: `$XDG_DATA_HOME/gitpic/history.jsonl`
    /// (falls back to `~/.local/share/gitpic/history.jsonl`).
    pub fn history_path() -> Result<PathBuf> {
        Ok(base_dir("XDG_DATA_HOME", ".local/share")?
            .join("gitpic")
            .join("history.jsonl"))
    }

    /// Load config from disk, or return defaults if the file is missing.
    pub fn load() -> Result<Self> {
        let path = Self::path()?;
        if !path.exists() {
            return Ok(Config::default());
        }
        let text = std::fs::read_to_string(&path).map_err(|e| {
            AppError::new(
                crate::error::ErrorCode::General,
                format!("read config: {e}"),
            )
        })?;
        toml::from_str(&text).map_err(|e| {
            AppError::new(
                crate::error::ErrorCode::General,
                format!("parse config: {e}"),
            )
        })
    }

    /// Persist config to disk (creating parent dirs).
    pub fn save(&self) -> Result<PathBuf> {
        let path = Self::path()?;
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).map_err(|e| {
                AppError::new(crate::error::ErrorCode::General, format!("mkdir: {e}"))
            })?;
        }
        let text = toml::to_string_pretty(self).map_err(|e| {
            AppError::new(crate::error::ErrorCode::General, format!("serialize: {e}"))
        })?;
        std::fs::write(&path, text).map_err(|e| {
            AppError::new(
                crate::error::ErrorCode::General,
                format!("write config: {e}"),
            )
        })?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
        }
        Ok(path)
    }

    /// Apply environment variable overrides in-place.
    ///
    /// # Errors
    /// Returns a usage error if `GITPIC_REPO` is malformed.
    pub fn apply_env(&mut self) -> Result<()> {
        if let Ok(v) = std::env::var("GITPIC_TOKEN") {
            if !v.is_empty() {
                self.github.token = v;
            }
        }
        if let Ok(v) = std::env::var("GITPIC_OWNER") {
            if !v.is_empty() {
                self.github.owner = v;
            }
        }
        if let Ok(v) = std::env::var("GITPIC_BRANCH") {
            if !v.is_empty() {
                self.github.branch = v;
            }
        }
        if let Ok(v) = std::env::var("GITPIC_LINK") {
            if !v.is_empty() {
                self.upload.link_kind = v;
            }
        }
        if let Ok(v) = std::env::var("GITPIC_REPO") {
            if !v.is_empty() {
                self.set_repo_spec(&v)?;
            }
        }
        Ok(())
    }

    /// Accept "owner/name" or bare "name" (keeps existing owner).
    ///
    /// # Errors
    /// Returns a usage error when the spec has more than one `/`, since the
    /// extra segment would silently become part of the repo name and produce
    /// broken upload URLs.
    pub fn set_repo_spec(&mut self, spec: &str) -> Result<()> {
        let spec = spec.trim();
        if let Some((owner, repo)) = spec.split_once('/') {
            let (owner, repo) = (owner.trim(), repo.trim());
            if repo.contains('/') {
                return Err(AppError::usage(format!(
                    "invalid repo spec {spec:?}: expected \"owner/name\" or \"name\""
                )));
            }
            self.github.owner = owner.to_string();
            self.github.repo = repo.to_string();
        } else {
            self.github.repo = spec.to_string();
        }
        Ok(())
    }

    /// Ensure the minimum required fields are present.
    pub fn require_ready(&self) -> Result<()> {
        if self.github.token.is_empty() {
            return Err(AppError::config_missing(
                "missing GitHub token (set GITPIC_TOKEN or run `gitpic init`)",
            ));
        }
        if self.github.owner.is_empty() || self.github.repo.is_empty() {
            return Err(AppError::config_missing(
                "missing target repo (set GITPIC_REPO=owner/name or run `gitpic init`)",
            ));
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::error::ErrorCode;

    #[test]
    fn repo_spec_accepts_owner_and_name() {
        let mut cfg = Config::default();
        cfg.set_repo_spec("owner/name").unwrap();
        assert_eq!(cfg.github.owner, "owner");
        assert_eq!(cfg.github.repo, "name");
    }

    #[test]
    fn repo_spec_bare_name_keeps_existing_owner() {
        let mut cfg = Config::default();
        cfg.github.owner = "keep".to_string();
        cfg.set_repo_spec("just-the-repo").unwrap();
        assert_eq!(cfg.github.owner, "keep");
        assert_eq!(cfg.github.repo, "just-the-repo");
    }

    #[test]
    fn repo_spec_rejects_extra_path_segments() {
        // Regression: "a/b/c" used to set repo="b/c", producing broken URLs.
        let mut cfg = Config::default();
        let err = cfg.set_repo_spec("a/b/c").expect_err("must be rejected");
        assert_eq!(err.code, ErrorCode::Usage);
        // The config must be left untouched by a rejected spec.
        assert_eq!(cfg.github.owner, "");
        assert_eq!(cfg.github.repo, "");
    }

    #[test]
    fn repo_spec_trims_whitespace() {
        let mut cfg = Config::default();
        cfg.set_repo_spec("  owner / name  ").unwrap();
        assert_eq!(cfg.github.owner, "owner");
        assert_eq!(cfg.github.repo, "name");
    }

    #[test]
    fn incomplete_repo_spec_is_caught_by_require_ready() {
        // "owner/" parses, but require_ready must still reject the empty repo.
        let mut cfg = Config::default();
        cfg.github.token = "t".to_string();
        cfg.set_repo_spec("owner/").unwrap();
        assert_eq!(
            cfg.require_ready().unwrap_err().code,
            ErrorCode::ConfigMissing
        );
    }
}
