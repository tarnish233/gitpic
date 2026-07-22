//! `gitpic config get|set|path|edit`

use crate::cli::ConfigAction;
use crate::config::Config;
use crate::error::{AppError, ErrorCode, Result};

pub fn run(action: &ConfigAction) -> Result<()> {
    match action {
        ConfigAction::Path => {
            println!("{}", Config::path()?.display());
        }
        ConfigAction::Get { key } => {
            let cfg = Config::load()?;
            match key.as_deref() {
                None => println!("{}", toml::to_string_pretty(&cfg).unwrap_or_default()),
                Some(k) => println!("{}", get_key(&cfg, k)?),
            }
        }
        ConfigAction::Set { key, value } => {
            let mut cfg = Config::load().unwrap_or_default();
            set_key(&mut cfg, key, value)?;
            let path = cfg.save()?;
            println!("\u{2713} set {key} in {}", path.display());
        }
        ConfigAction::Edit => {
            let path = Config::path()?;
            if !path.exists() {
                Config::default().save()?;
            }
            let editor = std::env::var("EDITOR").unwrap_or_else(|_| "vi".to_string());
            let status = std::process::Command::new(editor)
                .arg(&path)
                .status()
                .map_err(|e| AppError::new(ErrorCode::General, format!("launch editor: {e}")))?;
            if !status.success() {
                return Err(AppError::new(ErrorCode::General, "editor exited with error"));
            }
        }
    }
    Ok(())
}

fn get_key(cfg: &Config, key: &str) -> Result<String> {
    let v = match key {
        "github.token" => cfg.github.token.clone(),
        "github.owner" => cfg.github.owner.clone(),
        "github.repo" => cfg.github.repo.clone(),
        "github.branch" => cfg.github.branch.clone(),
        "upload.path_template" => cfg.upload.path_template.clone(),
        "upload.link_kind" => cfg.upload.link_kind.clone(),
        "upload.dedup" => cfg.upload.dedup.to_string(),
        "upload.auto_copy" => cfg.upload.auto_copy.to_string(),
        _ => return Err(AppError::usage(format!("unknown key: {key}"))),
    };
    Ok(v)
}

fn set_key(cfg: &mut Config, key: &str, value: &str) -> Result<()> {
    match key {
        "github.token" => cfg.github.token = value.to_string(),
        "github.owner" => cfg.github.owner = value.to_string(),
        "github.repo" => cfg.set_repo_spec(value),
        "github.branch" => cfg.github.branch = value.to_string(),
        "upload.path_template" => cfg.upload.path_template = value.to_string(),
        "upload.link_kind" => cfg.upload.link_kind = value.to_string(),
        "upload.dedup" => cfg.upload.dedup = parse_bool(value)?,
        "upload.auto_copy" => cfg.upload.auto_copy = parse_bool(value)?,
        _ => return Err(AppError::usage(format!("unknown key: {key}"))),
    }
    Ok(())
}

fn parse_bool(v: &str) -> Result<bool> {
    match v.trim().to_ascii_lowercase().as_str() {
        "true" | "1" | "yes" | "on" => Ok(true),
        "false" | "0" | "no" | "off" => Ok(false),
        _ => Err(AppError::usage(format!("invalid bool: {v}"))),
    }
}
