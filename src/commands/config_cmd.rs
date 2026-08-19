//! `gitpic config get|set|path|edit`

use crate::cli::ConfigAction;
use crate::config::Config;
use crate::error::{AppError, Result};
use crate::output::Mode;
use serde::Serialize;

/// `config path` / `config edit`.
#[derive(Serialize)]
struct PathEnvelope<'a> {
    ok: bool,
    path: &'a str,
}

/// `config get <key>`.
#[derive(Serialize)]
struct ValueEnvelope<'a> {
    ok: bool,
    key: &'a str,
    value: &'a str,
}

/// `config get` with no key.
#[derive(Serialize)]
struct ConfigEnvelope<'a> {
    ok: bool,
    config: &'a Config,
}

/// `config set`.
#[derive(Serialize)]
struct SetEnvelope<'a> {
    ok: bool,
    key: &'a str,
    value: &'a str,
    path: &'a str,
}

pub fn run(action: &ConfigAction, mode: Mode) -> Result<()> {
    match action {
        ConfigAction::Path => {
            let path = Config::path()?;
            let shown = path.display().to_string();
            if mode.is_json() {
                crate::output::print_json(&PathEnvelope {
                    ok: true,
                    path: &shown,
                });
            } else {
                crate::output::line(&shown);
            }
        }
        ConfigAction::Get { key } => {
            let cfg = Config::load()?;
            match key.as_deref() {
                None => {
                    if mode.is_json() {
                        crate::output::print_json(&ConfigEnvelope {
                            ok: true,
                            config: &cfg,
                        });
                    } else {
                        crate::output::line(&toml::to_string_pretty(&cfg).unwrap_or_default());
                    }
                }
                Some(k) => {
                    let v = get_key(&cfg, k)?;
                    if mode.is_json() {
                        crate::output::print_json(&ValueEnvelope {
                            ok: true,
                            key: k,
                            value: &v,
                        });
                    } else {
                        crate::output::line(&v);
                    }
                }
            }
        }
        ConfigAction::Set { key, value } => {
            let mut cfg = Config::load()?;
            set_key(&mut cfg, key, value)?;
            let path = cfg.save()?;
            let shown = path.display().to_string();
            if mode.is_json() {
                // The stored value, not the raw argument: `link_kind` is
                // lowercased and `repo` may have been split, so echoing the input
                // would misreport what is now on disk.
                let stored = get_key(&cfg, key)?;
                crate::output::print_json(&SetEnvelope {
                    ok: true,
                    key,
                    value: &stored,
                    path: &shown,
                });
            } else {
                crate::output::line(&format!("\u{2713} set {key} in {shown}"));
            }
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
            if mode.is_json() {
                let shown = path.display().to_string();
                crate::output::print_json(&PathEnvelope {
                    ok: true,
                    path: &shown,
                });
            }
        }
    }
    Ok(())
}

fn get_key(cfg: &Config, key: &str) -> Result<String> {
    let v = match key {
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

fn set_key(cfg: &mut Config, key: &str, value: &str) -> Result<()> {
    match key {
        "github.owner" => cfg.github.owner = value.to_string(),
        "github.repo" => cfg.set_repo_spec(value)?,
        "github.branch" => cfg.github.branch = value.to_string(),
        "upload.path_template" => cfg.upload.path_template = value.to_string(),
        "upload.link_kind" => {
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
            cfg.upload.quality = value
                .parse()
                .map_err(|_| AppError::usage(format!("invalid u8 (1-100): {value}")))?;
        }
        _ => return Err(AppError::usage(format!("unknown key: {key}"))),
    }
    // Syntax is parsed above; all semantic rules are centralized in Config so
    // file, environment, and `config set` cannot drift apart.
    cfg.validate().map_err(AppError::usage)
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
    fn every_config_field_is_reachable_by_get_and_set() {
        // One drift direction is already compile-checked: every match arm
        // dereferences a real field. The open hole is adding a `Config` field and
        // forgetting the arms, which silently 404s for the user. Deriving the key
        // list from `Config` itself turns that into a test failure instead.
        let cfg = Config::default();
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
