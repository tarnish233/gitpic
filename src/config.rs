//! Configuration model + resolution.
//!
//! Priority (highest first): CLI flags > environment variables > config.toml
//!   Env vars: GITPIC_TOKEN, GITPIC_OWNER, GITPIC_REPO ("owner/name" or "name"),
//!             GITPIC_BRANCH, GITPIC_LINK (cdn|raw)

use crate::error::{AppError, Result};
use directories::ProjectDirs;
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

impl Config {
    /// Locate the config file path (does not require it to exist).
    pub fn path() -> Result<PathBuf> {
        let dirs = ProjectDirs::from("dev", "gitpic", "gitpic").ok_or_else(|| {
            AppError::new(
                crate::error::ErrorCode::General,
                "cannot resolve config directory",
            )
        })?;
        Ok(dirs.config_dir().join("config.toml"))
    }

    /// Locate the upload-history file (JSONL).
    pub fn history_path() -> Result<PathBuf> {
        let dirs = ProjectDirs::from("dev", "gitpic", "gitpic").ok_or_else(|| {
            AppError::new(
                crate::error::ErrorCode::General,
                "cannot resolve data directory",
            )
        })?;
        Ok(dirs.data_dir().join("history.jsonl"))
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
    pub fn apply_env(&mut self) {
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
                self.set_repo_spec(&v);
            }
        }
    }

    /// Accept "owner/name" or bare "name" (keeps existing owner).
    pub fn set_repo_spec(&mut self, spec: &str) {
        if let Some((owner, repo)) = spec.split_once('/') {
            self.github.owner = owner.trim().to_string();
            self.github.repo = repo.trim().to_string();
        } else {
            self.github.repo = spec.trim().to_string();
        }
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
