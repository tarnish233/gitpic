//! Environment health check (agent-friendly).

use crate::config::Config;
use crate::error::{AppError, ErrorCode, Result};
use crate::github::GitHub;
use crate::output::{ErrorBody, Mode};
use owo_colors::{OwoColorize, Stream};
use serde::Serialize;

#[derive(Serialize)]
struct DoctorReport {
    ok: bool,
    config_ok: bool,
    token_valid: bool,
    /// Repo push permission **and** the target branch existing. Both are needed:
    /// a push-capable token still cannot write to a ref that is not there.
    repo_writable: bool,
    /// Whether GitHub reports the target branch protected. `true` does not mean an
    /// upload will fail — the rules may permit this account — but it is the usual
    /// explanation when one does after every other check passed.
    branch_protected: bool,
    /// Always `gh` when a credential was obtained, otherwise `null`. Kept in the
    /// JSON contract for compatibility with earlier releases.
    token_source: Option<&'static str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    login: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    detail: Option<String>,
    /// The failure, in the same `{ code, message }` shape every other subcommand
    /// uses — present on exactly the reports where `ok` is false.
    ///
    /// The exit status carries the same code, but that is a side channel an agent
    /// may never see: `gitpic doctor --json | jq` replaces it with jq's own 0, and
    /// some agent harnesses do not surface it at all. stdout is the one channel a
    /// caller parsing this report definitely has, so the code goes there too.
    /// `detail` carries the same message for the human renderer.
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<ErrorBody>,
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

/// What the branch probe found.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Branch {
    /// GitHub answered 404 for the target ref.
    Missing,
    Present {
        protected: bool,
    },
}

/// The facts a run gathered, independent of how they were obtained.
///
/// This is the seam that makes `doctor`'s reporting testable. The alternative was
/// injecting an API base into `GitHub`, but `with_api` is deliberately private —
/// every request carries the token in an `Authorization` header, so the base must
/// never be influenced from outside. Splitting *after* the I/O keeps that intact
/// and still covers the part that had the bug.
struct Probed {
    config_ok: bool,
    source: Option<&'static str>,
    /// `/user`: `Ok(login)` when the credential is accepted. `None` when the probe
    /// never ran — no credential, or nothing configured to probe against.
    user: Option<Result<String>>,
    /// `/repos/{owner}/{repo}`: `Ok(push_or_admin)`. `None` as above.
    repo: Option<Result<bool>>,
    /// `/repos/{owner}/{repo}/branches/{branch}`. `None` as above.
    branch: Option<Result<Branch>>,
    /// A failure that prevented probing at all: no credential, or no client.
    setup_err: Option<AppError>,
}

/// Reduce gathered facts to the report body and the process exit code.
fn summarize(p: Probed) -> (DoctorReport, u8) {
    let mut token_valid = false;
    let mut push_ok = false;
    let mut login = None;
    // Code and message travel together, in the type that already pairs them.
    // Holding them in two loose `Option`s is what let the synthesised
    // PERMISSION_DENIED below end up with a code and no message at all.
    let mut failure: Option<AppError> = p.setup_err;
    // Worth reporting but not a failure, so it must not reach the exit status.
    let mut caveat: Option<String> = None;

    // Synthesised up front so a missing branch can compete with the probe errors
    // on equal footing: it is a definite, actionable answer, not a "could not
    // tell". Building it unconditionally costs one small String and keeps the
    // borrow simple.
    let branch_missing = AppError::remote_not_found(
        "target branch does not exist on the remote; create it or set github.branch",
    );
    let mut protected = false;
    let mut branch_present = false;

    if !p.config_ok {
        // An unconfigured target outranks everything else: it is the first thing
        // the user has to fix, and its remedy is the one they can act on.
        failure = Some(AppError::config_missing(
            "run `gitpic init` or set GITPIC_REPO=owner/name",
        ));
    } else {
        let user_err = match &p.user {
            Some(Ok(name)) => {
                token_valid = true;
                login = Some(name.clone());
                None
            }
            Some(Err(e)) => Some(e),
            None => None,
        };
        let repo_err = match &p.repo {
            Some(Ok(allowed)) => {
                push_ok = *allowed;
                None
            }
            Some(Err(e)) => Some(e),
            None => None,
        };
        let branch_err = match &p.branch {
            Some(Ok(Branch::Present { protected: prot })) => {
                branch_present = true;
                protected = *prot;
                None
            }
            Some(Ok(Branch::Missing)) => Some(&branch_missing),
            Some(Err(e)) => Some(e),
            None => None,
        };
        let worst = more_actionable(more_actionable(user_err, repo_err), branch_err);
        if let Some(e) = worst {
            failure = Some(AppError::new(e.code, e.message.clone()));
        } else if protected {
            // Not a failure: the rules may well permit this account. Worth saying,
            // because it is the usual reason an upload 409/422s after every check
            // above came back clean.
            caveat = Some(
                "target branch is protected; an upload may still be refused by its rules".into(),
            );
        }
    }

    // Repo-level push permission is not the same claim as "the ref an upload
    // targets can be written". A push-capable token against a branch that does not
    // exist still fails the Contents API, so both have to hold.
    let repo_writable = push_ok && branch_present;

    let ok = p.config_ok && token_valid && repo_writable;

    // One value decides all three of `ok`, the exit status and `error`, so a report
    // can no longer claim one thing and exit another. The fallback covers the run
    // where every probe answered and GitHub simply said no: there is no probe error
    // to take a code or a message from, and that is the most common way an upload
    // turns out to be impossible — it used to report neither.
    let failure = (!ok).then(|| {
        failure.unwrap_or_else(|| {
            AppError::permission_denied(
                "GitHub reports no push or admin permission on this repository; check the \
                 credential's access to it and its Contents read/write permission",
            )
        })
    });
    let exit = failure.as_ref().map_or(0, |e| e.code.exit_code());
    // `detail` keeps its meaning — the one human-readable note — which is the
    // failure's message whenever there is one, and the caveat otherwise.
    let detail = failure.as_ref().map(|e| e.message.clone()).or(caveat);
    let error = failure.map(|e| ErrorBody::new(e.code.as_str(), &e.message));

    (
        DoctorReport {
            ok,
            config_ok: p.config_ok,
            token_valid,
            repo_writable,
            branch_protected: protected,
            token_source: p.source,
            login,
            detail,
            error,
        },
        exit,
    )
}

pub async fn run(cfg: &Config, mode: Mode) -> Result<u8> {
    let config_ok = cfg.require_target().is_ok();

    // Resolved before the target check so the source is reported even when the
    // repo is unconfigured — that is what tells you whether `gh` is being used.
    let (token, mut setup_err) = match crate::auth::token() {
        Ok(token) => (Some(token), None),
        Err(e) => (None, Some(e)),
    };
    let source = token.as_ref().map(|_| "gh");

    let mut user = None;
    let mut repo = None;
    let mut branch = None;
    if config_ok {
        if let Some(token) = &token {
            match GitHub::new(
                token,
                &cfg.github.owner,
                &cfg.github.repo,
                &cfg.github.branch,
            ) {
                Ok(gh) => {
                    // All three probes always run, and none gates another. `/user`
                    // answers "is this credential accepted", the repo endpoint
                    // answers "may it push here", the branch endpoint answers "does
                    // the ref an upload targets exist" — and an upload only ever
                    // calls the last two kinds. Gating them meant a 503 on `/user`,
                    // an endpoint uploads never touch, reported `repo_writable:
                    // false`, indistinguishable from a bad credential. Concurrent
                    // because they are independent.
                    let (who, info, br) =
                        tokio::join!(gh.whoami(), gh.repo_info(), gh.branch_info());
                    user = Some(who);
                    repo = Some(
                        info.map(|i| i.permissions.map(|p| p.push || p.admin).unwrap_or(false)),
                    );
                    branch = Some(br.map(|b| match b {
                        Some(b) => Branch::Present {
                            protected: b.protected,
                        },
                        None => Branch::Missing,
                    }));
                }
                Err(e) => setup_err = Some(e),
            }
        }
    }

    let (report, exit) = summarize(Probed {
        config_ok,
        source,
        user,
        repo,
        branch,
        setup_err,
    });

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
        crate::output::line(&format!("{} config present", mark(report.config_ok)));
        crate::output::line(&format!(
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
        ));
        crate::output::line(&format!(
            "{} repo writable{}",
            mark(report.repo_writable),
            if report.branch_protected {
                " (branch protected)"
            } else {
                ""
            }
        ));
        if let Some(d) = &report.detail {
            let note = "note:".if_supports_color(Stream::Stdout, |t| t.yellow().to_string());
            crate::output::line(&format!("  {note} {d}"));
        }
    }
    Ok(exit)
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

    /// A run where all three probes were attempted and the branch exists.
    fn probed(user: Result<String>, repo: Result<bool>) -> Probed {
        Probed {
            config_ok: true,
            source: Some("gh"),
            user: Some(user),
            repo: Some(repo),
            branch: Some(Ok(Branch::Present { protected: false })),
            setup_err: None,
        }
    }

    #[test]
    fn a_user_outage_no_longer_hides_that_the_repo_is_writable() {
        // THE regression this release exists for. Observed live: `/user` 503 while
        // the repository endpoint answered `push: true`. Before the probes were
        // split, `repo_writable` came back false and was indistinguishable from a
        // dead credential.
        let (r, exit) = summarize(probed(Err(AppError::network("503")), Ok(true)));
        assert!(r.repo_writable, "the repo answered, so say so");
        assert!(
            !r.token_valid,
            "/user did not answer, so do not claim it did"
        );
        assert!(!r.ok);
        assert_eq!(exit, ErrorCode::Network.exit_code(), "retryable");
        assert_eq!(r.token_source, Some("gh"));
    }

    #[test]
    fn a_healthy_run_is_ok_and_exits_zero() {
        let (r, exit) = summarize(probed(Ok("tarnish233".into()), Ok(true)));
        assert!(r.ok && r.config_ok && r.token_valid && r.repo_writable);
        assert_eq!(r.login.as_deref(), Some("tarnish233"));
        assert_eq!(exit, 0);
        assert!(r.detail.is_none(), "nothing to note on a clean run");
    }

    #[test]
    fn a_dead_credential_is_still_reported_as_auth_failed() {
        // Both probes fail: the definite 401 must win over a 503, or an agent
        // retries a credential that will never work.
        let (r, exit) = summarize(probed(
            Err(AppError::network("503")),
            Err(AppError::auth("bad credentials")),
        ));
        assert!(!r.token_valid && !r.repo_writable);
        assert_eq!(exit, ErrorCode::AuthFailed.exit_code());
    }

    #[test]
    fn a_valid_token_without_push_is_permission_denied() {
        // Everything answered; GitHub just says no. There is no probe error to take
        // a code or a message from, so both are synthesised — this outcome used to
        // carry neither `error` nor `detail`, which left the exit status as the only
        // thing that said why `repo_writable` was false.
        let (r, exit) = summarize(probed(Ok("someone".into()), Ok(false)));
        assert!(r.token_valid && !r.repo_writable && !r.ok);
        assert_eq!(exit, ErrorCode::PermissionDenied.exit_code());
        assert_eq!(
            r.error.as_ref().map(|e| e.code.as_str()),
            Some("PERMISSION_DENIED")
        );
        assert!(
            r.detail
                .as_deref()
                .unwrap_or_default()
                .contains("permission"),
            "{:?}",
            r.detail
        );
    }

    /// The reporting contract agents key on: `error` is on stdout, in the shape
    /// every other subcommand uses, and it is present on exactly the unhealthy
    /// reports. The exit status says the same thing, but it is a side channel —
    /// `gitpic doctor --json | jq` replaces it with jq's own 0 — so the two must
    /// never disagree, and neither may go missing.
    #[test]
    fn error_marks_exactly_the_unhealthy_reports_and_names_the_exit_status() {
        let cases: Vec<(&str, Probed, Option<ErrorCode>)> = vec![
            ("healthy", probed(Ok("me".into()), Ok(true)), None),
            (
                "protected but healthy",
                Probed {
                    branch: Some(Ok(Branch::Present { protected: true })),
                    ..probed(Ok("me".into()), Ok(true))
                },
                None,
            ),
            (
                "no push permission",
                probed(Ok("me".into()), Ok(false)),
                Some(ErrorCode::PermissionDenied),
            ),
            (
                "dead credential",
                probed(Err(AppError::auth("nope")), Ok(true)),
                Some(ErrorCode::AuthFailed),
            ),
            (
                "/user outage only",
                probed(Err(AppError::network("503")), Ok(true)),
                Some(ErrorCode::Network),
            ),
            (
                "missing branch",
                Probed {
                    branch: Some(Ok(Branch::Missing)),
                    ..probed(Ok("me".into()), Ok(true))
                },
                Some(ErrorCode::RemoteNotFound),
            ),
            (
                "nothing configured",
                Probed {
                    config_ok: false,
                    source: None,
                    user: None,
                    repo: None,
                    branch: None,
                    setup_err: Some(AppError::config_missing("no credential")),
                },
                Some(ErrorCode::ConfigMissing),
            ),
        ];
        for (what, p, want) in cases {
            let (r, exit) = summarize(p);
            assert_eq!(
                r.error.as_ref().map(|e| e.code.clone()),
                want.map(|c| c.as_str().to_string()),
                "{what}: error.code"
            );
            assert_eq!(exit, want.map_or(0, ErrorCode::exit_code), "{what}: exit");
            assert_eq!(r.ok, want.is_none(), "{what}: ok");
            assert_eq!(
                r.ok,
                r.error.is_none(),
                "{what}: `error` must be present on exactly the unhealthy reports"
            );
            if let Some(e) = &r.error {
                assert!(
                    !e.message.is_empty(),
                    "{what}: error.message must say something"
                );
                assert_eq!(
                    r.detail.as_deref(),
                    Some(e.message.as_str()),
                    "{what}: detail must carry the same message"
                );
            }
        }
    }

    #[test]
    fn an_unconfigured_target_outranks_a_missing_credential() {
        // Neither probe ran. The report still carries `token_source: null` so an
        // agent can read it, and the detail names the fix the user can act on.
        let (r, exit) = summarize(Probed {
            config_ok: false,
            source: None,
            user: None,
            repo: None,
            branch: None,
            setup_err: Some(AppError::config_missing("no GitHub credential")),
        });
        assert!(!r.config_ok && !r.token_valid && !r.repo_writable && !r.ok);
        assert_eq!(exit, ErrorCode::ConfigMissing.exit_code());
        assert_eq!(r.token_source, None);
        assert!(
            r.detail
                .as_deref()
                .unwrap_or_default()
                .contains("gitpic init"),
            "{:?}",
            r.detail
        );
    }

    #[test]
    fn a_missing_credential_with_a_configured_target_keeps_its_own_message() {
        // config_ok is true, so the ConfigMissing override must not fire and
        // overwrite the credential error's wording.
        let (r, exit) = summarize(Probed {
            config_ok: true,
            source: None,
            user: None,
            repo: None,
            branch: None,
            setup_err: Some(AppError::config_missing("run `gh auth login`")),
        });
        assert!(r.config_ok && !r.token_valid);
        assert_eq!(exit, ErrorCode::ConfigMissing.exit_code());
        assert_eq!(r.detail.as_deref(), Some("run `gh auth login`"));
    }

    #[test]
    fn push_permission_alone_is_not_reported_as_writable() {
        // The semantic fix: repo-level `push` says nothing about whether the ref an
        // upload targets exists. A push-capable token against a branch that is not
        // there still fails the Contents API, so claiming `repo_writable: true`
        // sent the user looking in the wrong place.
        let (r, exit) = summarize(Probed {
            config_ok: true,
            source: Some("gh"),
            user: Some(Ok("me".into())),
            repo: Some(Ok(true)),
            branch: Some(Ok(Branch::Missing)),
            setup_err: None,
        });
        assert!(!r.repo_writable, "a missing branch is not writable");
        assert!(r.token_valid, "the credential itself is fine");
        assert!(!r.ok);
        assert_eq!(exit, ErrorCode::RemoteNotFound.exit_code());
        assert!(
            r.detail.as_deref().unwrap_or_default().contains("branch"),
            "{:?}",
            r.detail
        );
    }

    #[test]
    fn a_missing_branch_outranks_a_transient_user_fault() {
        // Definite answers beat "could not tell", and that has to keep holding now
        // that a third probe can produce one.
        let (_, exit) = summarize(Probed {
            config_ok: true,
            source: Some("gh"),
            user: Some(Err(AppError::network("503"))),
            repo: Some(Ok(true)),
            branch: Some(Ok(Branch::Missing)),
            setup_err: None,
        });
        assert_eq!(exit, ErrorCode::RemoteNotFound.exit_code());
    }

    #[test]
    fn a_protected_branch_is_a_caveat_not_a_failure() {
        // Protection does not mean this account cannot write — the rules may permit
        // it — so the run stays ok. It is reported because it is the usual reason an
        // upload 409/422s after every check above came back clean.
        let (r, exit) = summarize(Probed {
            config_ok: true,
            source: Some("gh"),
            user: Some(Ok("me".into())),
            repo: Some(Ok(true)),
            branch: Some(Ok(Branch::Present { protected: true })),
            setup_err: None,
        });
        assert!(r.ok && r.repo_writable, "still a healthy run");
        assert_eq!(exit, 0);
        assert!(r.branch_protected);
        assert!(
            r.detail
                .as_deref()
                .unwrap_or_default()
                .contains("protected"),
            "{:?}",
            r.detail
        );
    }

    #[test]
    fn an_unprotected_healthy_run_says_nothing_extra() {
        let (r, _) = summarize(probed(Ok("me".into()), Ok(true)));
        assert!(!r.branch_protected);
        assert!(r.detail.is_none());
    }
}
