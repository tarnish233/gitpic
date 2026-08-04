//! Environment health check (agent-friendly).

use crate::config::Config;
use crate::error::{ErrorCode, Result};
use crate::github::GitHub;
use crate::output::Mode;
use owo_colors::{OwoColorize, Stream};
use serde::Serialize;

#[derive(Serialize)]
struct DoctorReport {
    ok: bool,
    config_ok: bool,
    token_valid: bool,
    repo_writable: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    login: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    detail: Option<String>,
}

pub async fn run(cfg: &Config, mode: Mode) -> Result<u8> {
    let config_ok = cfg.require_ready().is_ok();

    let mut token_valid = false;
    let mut repo_writable = false;
    let mut login = None;
    let mut detail = None;
    let mut failure_code = None;

    if config_ok {
        match GitHub::new(
            &cfg.github.token,
            &cfg.github.owner,
            &cfg.github.repo,
            &cfg.github.branch,
        ) {
            Ok(gh) => {
                match gh.whoami().await {
                    Ok(name) => {
                        token_valid = true;
                        login = Some(name);
                    }
                    Err(e) => {
                        failure_code = Some(e.code);
                        detail = Some(e.message);
                    }
                }
                if token_valid {
                    match gh.repo_info().await {
                        Ok(info) => {
                            repo_writable =
                                info.permissions.map(|p| p.push || p.admin).unwrap_or(false);
                        }
                        Err(e) => {
                            failure_code = Some(e.code);
                            detail = Some(e.message);
                        }
                    }
                }
            }
            Err(e) => {
                failure_code = Some(e.code);
                detail = Some(e.message);
            }
        }
    } else {
        failure_code = Some(ErrorCode::ConfigMissing);
        detail = Some("run `gitpic init` or set GITPIC_TOKEN and GITPIC_REPO".into());
    }

    let ok = config_ok && token_valid && repo_writable;
    let report = DoctorReport {
        ok,
        config_ok,
        token_valid,
        repo_writable,
        login,
        detail,
    };

    if mode.is_json() {
        println!(
            "{}",
            serde_json::to_string_pretty(&report).unwrap_or_default()
        );
    } else {
        let mark = |b: bool| {
            if b {
                "✓"
                    .if_supports_color(Stream::Stdout, |t| t.green().to_string())
                    .to_string()
            } else {
                "✗"
                    .if_supports_color(Stream::Stdout, |t| t.red().to_string())
                    .to_string()
            }
        };
        println!("{} config present", mark(report.config_ok));
        println!(
            "{} token valid{}",
            mark(report.token_valid),
            report
                .login
                .as_ref()
                .map(|l| format!(" ({l})"))
                .unwrap_or_default()
        );
        println!("{} repo writable", mark(report.repo_writable));
        if let Some(d) = &report.detail {
            let note = "note:".if_supports_color(Stream::Stdout, |t| t.yellow().to_string());
            println!("  {note} {d}");
        }
    }
    if ok {
        Ok(0)
    } else if let Some(code) = failure_code {
        Ok(code.exit_code())
    } else {
        // The token is valid and the repository exists, but GitHub reports no
        // push/admin permission for it.
        Ok(ErrorCode::PermissionDenied.exit_code())
    }
}
