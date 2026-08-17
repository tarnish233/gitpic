//! `gitpic config get|set|path|edit`

use crate::cli::ConfigAction;
use crate::config::Config;
use crate::error::{AppError, Result};

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
                .map_err(|e| AppError::general(format!("launch editor: {e}")))?;
            if !status.success() {
                return Err(AppError::general("editor exited with error"));
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
        "upload.link_kind" => {
            // Validate on the way in. `parse_link_kind` silently falls back to
            // cdn, so an unchecked typo here is permanent and invisible.
            crate::link::parse_link_kind_strict(value)
                .ok_or_else(|| AppError::usage(format!("invalid link kind (cdn|raw): {value}")))?;
            cfg.upload.link_kind = value.trim().to_ascii_lowercase();
        }
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

    #[test]
    fn every_config_field_is_reachable_by_get_and_set() {
        // One drift direction is already compile-checked: every match arm
        // dereferences a real field. The open hole is adding a `Config` field and
        // forgetting the arms, which silently 404s for the user. Deriving the key
        // list from `Config` itself turns that into a test failure instead.
        let mut cfg = Config::default();
        // Needs a non-empty token, or `skip_serializing_if` hides the key.
        cfg.github.token = "t".to_string();
        let value = toml::Value::try_from(&cfg).expect("Config serializes");
        for (section, body) in value.as_table().expect("Config is a table") {
            for field in body.as_table().expect("each section is a table").keys() {
                let key = format!("{section}.{field}");
                assert!(
                    get_key(&cfg, &key).is_ok(),
                    "`config get {key}` is unreachable"
                );
                // link_kind is validated, so it needs a real value; "1" parses
                // for every other key (u32, u8 in 1..=100, bools, strings, repo).
                let v = if key == "upload.link_kind" {
                    "raw"
                } else {
                    "1"
                };
                assert!(
                    set_key(&mut cfg.clone(), &key, v).is_ok(),
                    "`config set {key} {v}` is unreachable"
                );
            }
        }
    }
}
