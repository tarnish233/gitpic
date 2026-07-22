//! Environment health check (agent-friendly).

use crate::config::Config;
use crate::error::Result;
use crate::github::GitHub;
use crate::output::Mode;
use owo_colors::OwoColorize;
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

pub async fn run(cfg: &Config, mode: Mode) -> Result<()> {
    let config_ok = cfg.require_ready().is_ok();

    let mut token_valid = false;
    let mut repo_writable = false;
    let mut login = None;
    let mut detail = None;

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
                    Err(e) => detail = Some(e.message),
                }
                if token_valid {
                    match gh.repo_info().await {
                        Ok(info) => {
                            repo_writable =
                                info.permissions.map(|p| p.push || p.admin).unwrap_or(false);
                        }
                        Err(e) => detail = Some(e.message),
                    }
                }
            }
            Err(e) => detail = Some(e.message),
        }
    } else {
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
                "✓".green().to_string()
            } else {
                "✗".red().to_string()
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
            println!("  {} {}", "note:".yellow(), d);
        }
    }
    Ok(())
}
