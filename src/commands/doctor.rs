//! Environment health check (agent-friendly).

use crate::config::Config;
use crate::error::{AppError, ErrorCode, Result};
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
    /// Where the credential came from: `env`, `config`, or `gh`; `null` when none
    /// could be obtained. Lets a migration away from a plaintext token be
    /// verified. Always present, so an agent can read it on a failing report too.
    token_source: Option<&'static str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    login: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    detail: Option<String>,
}

/// Pick which of the two probe failures to report.
///
/// `Network` only ever means "could not tell", so a definite answer outranks it:
/// when `/user` returns 503 but the repository endpoint returns 401, the
/// credential really is bad, and reporting the 503 would tell an agent to retry
/// forever instead of re-authenticating. Any other pair keeps the credential
/// probe's verdict, which is the more specific of the two.
fn more_actionable<'a>(
    user: Option<&'a AppError>,
    repo: Option<&'a AppError>,
) -> Option<&'a AppError> {
    match (user, repo) {
        (Some(u), Some(r)) if u.code == ErrorCode::Network && r.code != ErrorCode::Network => {
            Some(r)
        }
        (Some(u), _) => Some(u),
        (None, r) => r,
    }
}

pub async fn run(cfg: &Config, mode: Mode) -> Result<u8> {
    let config_ok = cfg.require_target().is_ok();

    let mut token_valid = false;
    let mut repo_writable = false;
    let mut login = None;
    let mut detail = None;
    let mut failure_code = None;

    // Resolved before the target check so the source is reported even when the
    // repo is unconfigured — that is what tells you whether `gh` is being used.
    let cred = match crate::auth::resolve(cfg) {
        Ok(c) => Some(c),
        Err(e) => {
            failure_code = Some(e.code);
            detail = Some(e.message);
            None
        }
    };

    if !config_ok {
        failure_code = Some(ErrorCode::ConfigMissing);
        detail = Some("run `gitpic init` or set GITPIC_REPO=owner/name".into());
    } else if let Some(cred) = &cred {
        match GitHub::new(
            &cred.token,
            &cfg.github.owner,
            &cfg.github.repo,
            &cfg.github.branch,
        ) {
            Ok(gh) => {
                // Both probes always run, and neither gates the other. `/user`
                // answers "is this credential accepted", the repo endpoint answers
                // "can it write here" — and an upload only ever calls the second
                // kind. Gating them meant a 503 on `/user`, an endpoint uploads
                // never touch, reported `repo_writable: false`, which is
                // indistinguishable from a bad credential and sends an agent to
                // `gh auth login` for a fault that has nothing to do with auth.
                // Concurrent because they are independent.
                let (who, repo) = tokio::join!(gh.whoami(), gh.repo_info());

                let user_err = match who {
                    Ok(name) => {
                        token_valid = true;
                        login = Some(name);
                        None
                    }
                    Err(e) => Some(e),
                };
                let repo_err = match repo {
                    Ok(info) => {
                        repo_writable =
                            info.permissions.map(|p| p.push || p.admin).unwrap_or(false);
                        None
                    }
                    Err(e) => Some(e),
                };

                if let Some(e) = more_actionable(user_err.as_ref(), repo_err.as_ref()) {
                    failure_code = Some(e.code);
                    detail = Some(e.message.clone());
                }
            }
            Err(e) => {
                failure_code = Some(e.code);
                detail = Some(e.message);
            }
        }
    }

    let ok = config_ok && token_valid && repo_writable;
    let report = DoctorReport {
        ok,
        config_ok,
        token_valid,
        repo_writable,
        token_source: cred.as_ref().map(|c| c.source.as_str()),
        login,
        detail,
    };

    if mode.is_json() {
        crate::output::print_json(&report);
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
            "{} token valid{}{}",
            mark(report.token_valid),
            report
                .login
                .as_ref()
                .map(|l| format!(" ({l})"))
                .unwrap_or_default(),
            report
                .token_source
                .map(|s| format!(" via {s}"))
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

#[cfg(test)]
mod tests {
    use super::*;

    fn err(code: ErrorCode) -> AppError {
        AppError::new(code, "boom")
    }

    #[test]
    fn a_transient_user_fault_does_not_mask_a_real_auth_failure() {
        // The case that motivated splitting the probes: `/user` was 503 while the
        // repository endpoint answered. If the repo endpoint says 401, the
        // credential is genuinely bad and an agent must re-authenticate; reporting
        // the 503 would tell it to retry a fault that will never clear.
        let user = err(ErrorCode::Network);
        let repo = err(ErrorCode::AuthFailed);
        assert_eq!(
            more_actionable(Some(&user), Some(&repo)).map(|e| e.code),
            Some(ErrorCode::AuthFailed)
        );
    }

    #[test]
    fn a_network_fault_is_reported_when_it_is_all_we_have() {
        // Both endpoints unreachable: NETWORK is correct and retryable.
        let user = err(ErrorCode::Network);
        let repo = err(ErrorCode::Network);
        assert_eq!(
            more_actionable(Some(&user), Some(&repo)).map(|e| e.code),
            Some(ErrorCode::Network)
        );
        // Only `/user` failed — the repo probe succeeded, so there is nothing to
        // outrank it and the run is still a NETWORK failure the caller can retry.
        assert_eq!(
            more_actionable(Some(&user), None).map(|e| e.code),
            Some(ErrorCode::Network)
        );
    }

    #[test]
    fn the_credential_probe_wins_when_both_answers_are_definite() {
        // Neither is a "could not tell", so the more specific probe stands.
        let user = err(ErrorCode::AuthFailed);
        let repo = err(ErrorCode::RemoteNotFound);
        assert_eq!(
            more_actionable(Some(&user), Some(&repo)).map(|e| e.code),
            Some(ErrorCode::AuthFailed)
        );
    }

    #[test]
    fn a_repo_only_failure_is_reported_on_its_own() {
        // Valid credential, but the repository is missing or unreadable.
        let repo = err(ErrorCode::RemoteNotFound);
        assert_eq!(
            more_actionable(None, Some(&repo)).map(|e| e.code),
            Some(ErrorCode::RemoteNotFound)
        );
    }

    #[test]
    fn a_clean_run_has_nothing_to_report() {
        assert!(more_actionable(None, None).is_none());
    }
}
