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
                None => {
                    let safe = redacted_config(&cfg);
                    println!("{}", toml::to_string_pretty(&safe).unwrap_or_default());
                }
                Some(k) => println!("{}", get_key(&cfg, k)?),
            }
        }
        ConfigAction::Set { key, value } => {
            let mut cfg = Config::load()?;
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
                return Err(AppError::new(
                    ErrorCode::General,
                    "editor exited with error",
                ));
            }
        }
    }
    Ok(())
}

fn get_key(cfg: &Config, key: &str) -> Result<String> {
    let v = match key {
        "github.token" => redact_token(&cfg.github.token),
        "github.owner" => cfg.github.owner.clone(),
        "github.repo" => cfg.github.repo.clone(),
        "github.branch" => cfg.github.branch.clone(),
        "upload.path_template" => cfg.upload.path_template.clone(),
        "upload.link_kind" => cfg.upload.link_kind.clone(),
        "upload.dedup" => cfg.upload.dedup.to_string(),
        "upload.auto_copy" => cfg.upload.auto_copy.to_string(),
        "upload.compress" => cfg.upload.compress.to_string(),
        "upload.max_width" => cfg.upload.max_width.to_string(),
        "upload.quality" => cfg.upload.quality.to_string(),
        _ => return Err(AppError::usage(format!("unknown key: {key}"))),
    };
    Ok(v)
}

fn redact_token(token: &str) -> String {
    if token.is_empty() {
        String::new()
    } else {
        "<redacted>".to_string()
    }
}

fn redacted_config(cfg: &Config) -> Config {
    let mut safe = cfg.clone();
    safe.github.token = redact_token(&safe.github.token);
    safe
}

fn set_key(cfg: &mut Config, key: &str, value: &str) -> Result<()> {
    match key {
        "github.token" => cfg.github.token = value.to_string(),
        "github.owner" => cfg.github.owner = value.to_string(),
        "github.repo" => cfg.set_repo_spec(value)?,
        "github.branch" => cfg.github.branch = value.to_string(),
        "upload.path_template" => cfg.upload.path_template = value.to_string(),
        "upload.link_kind" => cfg.upload.link_kind = value.to_string(),
        "upload.dedup" => cfg.upload.dedup = parse_bool(value)?,
        "upload.auto_copy" => cfg.upload.auto_copy = parse_bool(value)?,
        "upload.compress" => cfg.upload.compress = parse_bool(value)?,
        "upload.max_width" => {
            cfg.upload.max_width = value
                .parse()
                .map_err(|_| AppError::usage(format!("invalid u32: {value}")))?
        }
        "upload.quality" => {
            let q: u8 = value
                .parse()
                .map_err(|_| AppError::usage(format!("invalid u8 (1-100): {value}")))?;
            if !(1..=100).contains(&q) {
                return Err(AppError::usage(format!(
                    "quality out of range (1-100): {value}"
                )));
            }
            cfg.upload.quality = q;
        }
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn token_is_never_returned_by_get_key() {
        let mut cfg = Config::default();
        cfg.github.token = "sensitive-value-for-test".to_string();
        assert_eq!(get_key(&cfg, "github.token").unwrap(), "<redacted>");
        let rendered = toml::to_string_pretty(&redacted_config(&cfg)).unwrap();
        assert!(!rendered.contains("sensitive-value-for-test"));
        assert!(rendered.contains("<redacted>"));
    }

    #[test]
    fn empty_token_stays_empty_when_redacted() {
        assert_eq!(redact_token(""), "");
    }
}
