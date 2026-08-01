//! Environment health check (agent-friendly).

use crate::config::Config;
use crate::error::{AppError, ErrorCode, Result};
use crate::github::{GitHub, RepoPermissions};
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
    /// Stable `ErrorCode` string for the first failing check, matching the
    /// process exit status. Absent when healthy.
    #[serde(skip_serializing_if = "Option::is_none")]
    code: Option<&'static str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    detail: Option<String>,
}

/// Map the repo's reported permissions to writability, plus the cause on failure.
///
/// `None` means GitHub did not return a `permissions` block at all. That is not a
/// refusal, so it must not surface as `PERMISSION_DENIED` — we genuinely do not
/// know, and claiming denial would send the user to fix the wrong thing.
fn classify_permissions(perms: Option<RepoPermissions>) -> (bool, Option<AppError>) {
    match perms {
        Some(p) if p.push || p.admin => (true, None),
        Some(_) => (
            false,
            Some(AppError::permission_denied(
                "token lacks push access to the target repo; grant Contents read/write",
            )),
        ),
        None => (
            false,
            Some(AppError::new(
                ErrorCode::General,
                "GitHub did not report repository permissions; cannot confirm write access",
            )),
        ),
    }
}

pub async fn run(cfg: &Config, mode: Mode) -> Result<()> {
    let mut token_valid = false;
    let mut repo_writable = false;
    let mut login = None;
    // The first failing check wins: it is the most specific thing we know, and
    // later checks are skipped or meaningless once an earlier one fails.
    let mut cause: Option<AppError> = None;

    let config_ok = match cfg.require_ready() {
        Ok(()) => true,
        Err(e) => {
            // Carries the specific missing field (token vs repo), which is more
            // useful than a generic "run gitpic init".
            cause = Some(e);
            false
        }
    };

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
                    Err(e) => cause = Some(e),
                }
                if token_valid {
                    match gh.repo_info().await {
                        Ok(info) => {
                            let (writable, perm_cause) = classify_permissions(info.permissions);
                            repo_writable = writable;
                            cause = perm_cause;
                        }
                        Err(e) => cause = Some(e),
                    }
                }
            }
            Err(e) => cause = Some(e),
        }
    }

    let ok = config_ok && token_valid && repo_writable;
    let report = DoctorReport {
        ok,
        config_ok,
        token_valid,
        repo_writable,
        login,
        code: cause.as_ref().map(|e| e.code.as_str()),
        detail: cause.as_ref().map(|e| e.message.clone()),
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

    // The report above is the diagnostic output, so mark the error as already
    // reported: printing an envelope too would put two JSON objects on stdout.
    match cause {
        Some(e) => Err(e.mark_reported()),
        None => Ok(()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn push_permission_is_writable() {
        let (writable, cause) = classify_permissions(Some(RepoPermissions {
            push: true,
            admin: false,
        }));
        assert!(writable);
        assert!(cause.is_none());
    }

    #[test]
    fn admin_permission_is_writable() {
        let (writable, cause) = classify_permissions(Some(RepoPermissions {
            push: false,
            admin: true,
        }));
        assert!(writable);
        assert!(cause.is_none());
    }

    #[test]
    fn neither_push_nor_admin_is_permission_denied() {
        let (writable, cause) = classify_permissions(Some(RepoPermissions {
            push: false,
            admin: false,
        }));
        assert!(!writable);
        assert_eq!(
            cause.map(|e| e.code),
            Some(ErrorCode::PermissionDenied),
            "an explicit refusal should be PERMISSION_DENIED"
        );
    }

    /// Regression: absent permissions used to collapse into the same
    /// `repo_writable: false` as a refusal. It is not a refusal — GitHub simply
    /// did not say — so it must not be reported as PERMISSION_DENIED.
    #[test]
    fn absent_permissions_is_not_reported_as_denial() {
        let (writable, cause) = classify_permissions(None);
        assert!(!writable);
        assert_eq!(cause.map(|e| e.code), Some(ErrorCode::General));
    }
}
