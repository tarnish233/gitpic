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

/// One key that landed, as stored — `link_kind` is lowercased and `repo` may
/// have been split, so this is not always the raw argument.
#[derive(Serialize)]
struct SetChange<'a> {
    key: &'a str,
    value: String,
}

/// `config set`. One pair still carries `key`/`value` at the top level so
/// existing agents keep working; several pairs are `changes` only.
#[derive(Serialize)]
struct SetEnvelope<'a> {
    ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    key: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    value: Option<&'a str>,
    changes: Vec<SetChange<'a>>,
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
                crate::output::untrusted_line(&shown);
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
                        // TOML serialization escapes controls inside values; its
                        // newlines are trusted structure and should remain readable.
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
                        crate::output::untrusted_line(&v);
                    }
                }
            }
        }
        ConfigAction::Set { pairs } => {
            let kv = pair_args(pairs)?;
            let (_, cfg, path) = Config::update(|cfg| {
                for (key, value) in &kv {
                    set_key(cfg, key, value)?;
                }
                Ok(())
            })?;
            let shown = path.display().to_string();
            // Stored values, not the raw arguments: `link_kind` is lowercased
            // and `repo` may have been split.
            let changes: Vec<SetChange> = kv
                .iter()
                .map(|(key, _)| get_key(&cfg, key).map(|value| SetChange { key, value }))
                .collect::<Result<_>>()?;
            if mode.is_json() {
                let single_key = (changes.len() == 1).then_some(changes[0].key);
                let single_value = (changes.len() == 1).then(|| changes[0].value.clone());
                crate::output::print_json(&SetEnvelope {
                    ok: true,
                    key: single_key,
                    value: single_value.as_deref(),
                    changes,
                    path: &shown,
                });
            } else {
                let keys = changes.iter().map(|c| c.key).collect::<Vec<_>>().join(", ");
                crate::output::line(&format!(
                    "{} set {keys} in {}",
                    crate::output::tick(),
                    crate::output::terminal_safe(&shown)
                ));
            }
        }
        ConfigAction::Edit => {
            // Refused under `--json` rather than half-honoured. `Command::status()`
            // inherits stdout, so the editor writes to the stream the caller is parsing:
            // `EDITOR=cat gitpic config edit --json` printed the whole TOML file and
            // *then* an envelope — two documents, the first not JSON at all — and with a
            // real screen editor it is terminal escape sequences instead. This is the
            // one command in the crate whose `--json` could not honour "one invocation,
            // one envelope"; `skill install` closes the same hole the same way.
            // `gitpic config get --json` reads the file without an editor, and
            // `config path` names it.
            if mode.is_json() {
                return Err(AppError::usage(
                    "`config edit` is interactive and cannot produce JSON: it hands \
                     stdout to $EDITOR. Use `gitpic config get --json` to read the \
                     configuration, `gitpic config set` to change it, or \
                     `gitpic config path --json` for the file's location",
                ));
            }
            let path = Config::path()?;
            // Hold the same cross-process lock as `config set` for the entire editor
            // session. Otherwise a setter can save a newer snapshot while the editor
            // still has the old file open, and the editor then overwrites that change.
            let _lock = Config::lock_for_write()?;
            if !path.exists() {
                Config::default().save_to_unlocked(&path)?;
            }
            // `VISUAL` before `EDITOR`, which is the convention and is what most people
            // with a GUI editor actually set.
            let editor = std::env::var("VISUAL")
                .ok()
                .filter(|v| !v.trim().is_empty())
                .or_else(|| {
                    std::env::var("EDITOR")
                        .ok()
                        .filter(|v| !v.trim().is_empty())
                })
                .unwrap_or_else(|| "vi".to_string());
            // Through the platform shell, the way git runs its editor, because the
            // value is a *command* and not a program name. `Command::new(editor)` looked
            // for an executable literally called `code --wait`, so every common wrapper
            // form — `EDITOR="code --wait"`, `"subl -w"`, `"emacsclient -nw"` — failed
            // with `launch editor: No such file or directory`, which reads as gitpic
            // being broken and names no fix. The path goes in as an argument rather than
            // interpolated, so a directory with a space or a quote in it cannot become
            // part of the command.
            let status = editor_command(&editor, &path)
                .status()
                .map_err(|e| AppError::general(format!("launch editor: {e}")))?;
            if !status.success() {
                return Err(AppError::general(format!(
                    "editor exited with error: {editor}"
                )));
            }
            // Re-parse so a typo written in the editor is CONFIG_INVALID, not a
            // silent ok that every later command then refuses.
            Config::load()?;
        }
    }
    Ok(())
}

/// Build the platform-shell command that opens `path` in `editor`.
///
/// The editor is intentionally a shell command (`code --wait`, `subl -w`, ...), while
/// the path is data and must never be interpolated into that command. Unix shells have
/// positional parameters for `sh -c`; `cmd.exe /C` does not offer the same `$1` shape,
/// so Windows passes the path through a one-use environment variable instead. Windows
/// file names cannot contain `"`, and quoting the expansion keeps spaces and command
/// metacharacters inside the argument.
fn editor_command(editor: &str, path: &std::path::Path) -> std::process::Command {
    if cfg!(windows) {
        let mut command = std::process::Command::new("cmd");
        command
            .arg("/D")
            .arg("/S")
            .arg("/C")
            .arg(format!("{editor} \"%GITPIC_EDIT_PATH%\""))
            .env("GITPIC_EDIT_PATH", path);
        command
    } else {
        let mut command = std::process::Command::new("sh");
        command
            .arg("-c")
            .arg(format!("{editor} \"$1\""))
            .arg("sh")
            .arg(path);
        command
    }
}

/// `config set KEY VALUE [KEY VALUE ...]`. Clap's `num_args = 2..` still
/// admits an odd count (`github.owner me leftover`).
fn pair_args(pairs: &[String]) -> Result<Vec<(&str, &str)>> {
    if !pairs.len().is_multiple_of(2) {
        return Err(AppError::usage(
            "config set expects KEY VALUE pairs; got an odd number of arguments",
        ));
    }
    // `as_chunks::<2>()`, not `chunks_exact(2)`: clippy 1.98 flags the constant
    // chunk size (`chunks_exact_to_as_chunks`), and the array pattern is total
    // where indexing a slice was only safe because of the check above. Stable
    // since 1.88.0 — exactly this crate's `rust-version`, so the floor cannot be
    // lowered without this failing to compile.
    Ok(pairs
        .as_chunks::<2>()
        .0
        .iter()
        .map(|[key, value]| (key.as_str(), value.as_str()))
        .collect())
}

fn get_key(cfg: &Config, key: &str) -> Result<String> {
    let v = match key {
        "github.owner" => cfg.github.owner.clone(),
        "github.repo" => cfg.github.repo.clone(),
        "github.branch" => cfg.github.branch.clone(),
        "upload.path_template" => cfg.upload.path_template.clone(),
        "upload.format" => cfg.upload.format.clone(),
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
        "upload.format" => {
            cfg.upload.format = value.trim().to_ascii_lowercase();
        }
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
    // file, environment, `config set`, the login picker and `--repo` cannot drift
    // apart.
    //
    // `require_target` is deliberately not one of them. The picker sets the whole
    // target from one choice, so it cannot leave a half; here one key is set at a
    // time, and `config set github.repo pics` before the owner is the normal first
    // step on a fresh machine. Refusing that would answer a write with
    // `CONFIG_MISSING`, whose remedy points straight back at `config set` — a loop
    // for an agent.
    // A half-configured target is a state — `doctor` reports it, and `check_segment`
    // permits either half to be empty for exactly this reason — not an unusable
    // file. `config edit` stays unchecked for a stronger reason still: every
    // `CONFIG_INVALID` message advertises it as the way back, so it must never be
    // the command that refuses.
    cfg.validate_input()
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
                // The two enum-valued keys are validated, so they need real values;
                // "1" parses for every other key (u32, u8 in 1..=100, bools, strings,
                // repo).
                let v = match key.as_str() {
                    "upload.link_kind" => "raw",
                    "upload.format" => "html",
                    _ => "1",
                };
                assert!(
                    set_key(&mut cfg.clone(), &key, v).is_ok(),
                    "`config set {key} {v}` is unreachable"
                );
            }
        }
    }

    #[test]
    fn pair_args_rejects_an_odd_count() {
        let err =
            pair_args(&["github.owner".into(), "me".into(), "leftover".into()]).expect_err("odd");
        assert_eq!(err.code, crate::error::ErrorCode::Usage);
        assert!(pair_args(&["github.owner".into(), "me".into()]).is_ok());
    }

    #[test]
    fn an_editor_with_arguments_keeps_the_config_path_out_of_shell_code() {
        use std::ffi::OsStr;

        let path = std::path::Path::new("a directory/config.toml");
        let command = editor_command("code --wait", path);
        let args: Vec<_> = command.get_args().collect();
        if cfg!(windows) {
            assert_eq!(command.get_program(), OsStr::new("cmd"));
            assert_eq!(args[0], OsStr::new("/D"));
            assert_eq!(args[1], OsStr::new("/S"));
            assert_eq!(args[2], OsStr::new("/C"));
            assert_eq!(args[3], OsStr::new("code --wait \"%GITPIC_EDIT_PATH%\""));
            assert_eq!(
                command
                    .get_envs()
                    .find(|(key, _)| *key == OsStr::new("GITPIC_EDIT_PATH"))
                    .and_then(|(_, value)| value),
                Some(path.as_os_str())
            );
        } else {
            assert_eq!(command.get_program(), OsStr::new("sh"));
            assert_eq!(args[0], OsStr::new("-c"));
            assert_eq!(args[1], OsStr::new("code --wait \"$1\""));
            assert_eq!(args[2], OsStr::new("sh"));
            assert_eq!(args[3], path.as_os_str());
        }
        assert!(
            args.iter()
                .take(if cfg!(windows) { 4 } else { 3 })
                .all(|arg| arg != path),
            "the path must be passed as data, not interpolated into shell code"
        );
    }

    #[test]
    fn a_later_key_that_fails_does_not_reach_save() {
        // Mutations happen in memory; `run` only saves after every pair succeeds.
        let mut cfg = Config::default();
        set_key(&mut cfg, "github.owner", "me").unwrap();
        set_key(&mut cfg, "github.repo", "pics").unwrap();
        assert!(set_key(&mut cfg, "upload.quality", "0").is_err());
        assert_eq!(cfg.github.owner, "me");
        assert_eq!(cfg.github.repo, "pics");
    }
}
