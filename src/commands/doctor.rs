//! Environment health check (agent-friendly).

use crate::config::Config;
use crate::error::{AppError, ErrorCode, Result};
use crate::github::GitHub;
use crate::output::{ErrorBody, Mode};
use serde::Serialize;

#[derive(Serialize)]
struct DoctorReport {
    ok: bool,
    config_ok: bool,
    /// `null` when nothing was checked, which is not the same claim as `false`.
    ///
    /// The probes are gated on `config_ok`, but only two of the three need a target —
    /// so on a machine that has logged in and not yet chosen a repository, `/user` was
    /// never called and `token_valid: false` was reported for a credential nobody had
    /// looked at. `gitpic auth status` on that same machine says the credential is
    /// fine, and the remedy a reader derives from `✗ token valid` is "log in again",
    /// which is exactly what `config.rs` goes out of its way to avoid suggesting —
    /// it mints a second token to fix a config file.
    ///
    /// `false` still means a credential that was resolved and rejected, or one that
    /// could not be resolved at all. Agents keyed on `require token_valid == true` are
    /// unaffected: `null` is not `true`.
    token_valid: Option<bool>,
    /// Repo push permission **and** the target branch existing. Both are needed:
    /// a push-capable token still cannot write to a ref that is not there.
    /// `null` for the same reason as [`DoctorReport::token_valid`].
    repo_writable: Option<bool>,
    /// Whether GitHub reports the target branch protected. `true` does not mean an
    /// upload will fail — the rules may permit this account — but it is the usual
    /// explanation when one does after every other check passed.
    branch_protected: bool,
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
    /// `/user`: `Ok(login)` when the credential is accepted. `None` when the probe
    /// never ran — no credential, or nothing configured to probe against.
    user: Option<Result<String>>,
    /// `/repos/{owner}/{repo}`. `None` as above.
    repo: Option<Result<RepoFacts>>,
    /// `/repos/{owner}/{repo}/branches/{branch}`. `None` as above.
    branch: Option<Result<Branch>>,
    /// A failure that prevented probing at all: no credential, or no client.
    setup_err: Option<AppError>,
    /// Whether `upload.link_kind` is `cdn`, i.e. whether jsDelivr has to be able to
    /// serve what is uploaded for the emitted link to work.
    cdn: bool,
    /// The upload path's own pre-flight refusal, if the configuration would trip it.
    ///
    /// `doctor` never read `cfg.upload.*` at all, and `upload.rs` refuses `cdn` plus a
    /// branch containing `/` as `USAGE` *before* the credential is resolved and before
    /// any request. So a repository whose default branch is `release/v1` — which the
    /// `repos` picker writes verbatim, and which `Config::validate` has no reason to
    /// reject — reported `✓ config present / ✓ token valid / ✓ repo writable`, exit 0,
    /// while every single upload exited 2 having sent nothing. That is the inversion
    /// this module exists to prevent.
    dead_cdn: Option<AppError>,
}

/// What the repository probe found.
///
/// Two facts rather than one bool: `private` decides whether a `cdn` link can ever
/// resolve, and it arrives on the same response as the permissions.
#[derive(Debug, Clone, Copy)]
struct RepoFacts {
    pushable: bool,
    private: bool,
}

/// Reduce gathered facts to the report body and the process exit code.
fn summarize(p: Probed) -> (DoctorReport, u8) {
    // `None` until a probe answers: see `DoctorReport::token_valid`.
    let mut token_valid: Option<bool> = None;
    let mut push_ok: Option<bool> = None;
    let mut private = false;
    let mut login = None;
    // Code and message travel together, in the type that already pairs them.
    // Holding them in two loose `Option`s is what let the synthesised
    // PERMISSION_DENIED below end up with a code and no message at all.
    // Asked before `failure` takes ownership below.
    let credential_unresolved = p.setup_err.is_some();
    let mut failure: Option<AppError> = p.setup_err;
    // Worth reporting but not failures, so they must not reach the exit status. A list
    // because there are now two, and a run can be in both states at once.
    let mut caveats: Vec<String> = Vec::new();

    // Synthesised up front so a missing branch can compete with the probe errors
    // on equal footing: it is a definite, actionable answer, not a "could not
    // tell". Building it unconditionally costs one small String and keeps the
    // borrow simple.
    let branch_missing = AppError::remote_not_found(
        "target branch does not exist on the remote; create it or set github.branch",
    );
    let mut protected = false;
    let mut branch_present = false;

    // A credential that could not be resolved at all is a definite `false`, wherever
    // that was discovered: `setup_err` *is* an answer about the credential, and nothing
    // more needs asking. What stays `None` is the other case — a credential that was
    // resolved fine and then never used, because there was no target to use it against.
    if credential_unresolved {
        token_valid = Some(false);
        push_ok = Some(false);
    }

    if !p.config_ok {
        // An unconfigured target outranks everything else: it is the first thing
        // the user has to fix, and its remedy is the one they can act on.
        failure = Some(AppError::config_missing(
            "no image host configured: `gitpic repos` lists your options and \
             `gitpic config set github.repo owner/name` sets one",
        ));
    } else {
        let user_err = match &p.user {
            Some(Ok(name)) => {
                token_valid = Some(true);
                login = Some(name.clone());
                None
            }
            Some(Err(e)) => Some(e),
            None => None,
        };
        let repo_err = match &p.repo {
            Some(Ok(facts)) => {
                push_ok = Some(facts.pushable);
                private = facts.private;
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
        if p.user.is_some() && token_valid.is_none() {
            token_valid = Some(false);
        }
        if p.repo.is_some() && push_ok.is_none() {
            push_ok = Some(false);
        }
        let worst = more_actionable(more_actionable(user_err, repo_err), branch_err);
        // The upload path's pre-flight refusal outranks every probe: it stops the
        // upload before the network is touched at all, so whatever a probe found is
        // downstream of a run that cannot start.
        if let Some(e) = &p.dead_cdn {
            failure = Some(AppError::new(e.code, e.message.clone()));
        } else if let Some(e) = worst {
            failure = Some(AppError::new(e.code, e.message.clone()));
        }
        // Caveats are independent of the failure and of each other, so they are
        // collected rather than chosen between.
        if private && p.cdn {
            // Not a failure: the upload really does succeed. It is the *link* that is
            // dead, which is worse than an error in one way — nothing reports it.
            caveats.push(
                "the repository is private and `upload.link_kind` is \"cdn\", so jsDelivr \
                 cannot serve these links; `gitpic config set upload.link_kind raw`"
                    .into(),
            );
        }
        if protected {
            // Not a failure: the rules may well permit this account. Worth saying,
            // because it is the usual reason an upload 409/422s after every check
            // above came back clean.
            caveats.push(
                "target branch is protected; an upload may still be refused by its rules".into(),
            );
        }
    }

    // Repo-level push permission is not the same claim as "the ref an upload
    // targets can be written". A push-capable token against a branch that does not
    // exist still fails the Contents API, so both have to hold.
    // `None` propagates: "may it push" is unanswerable when nobody asked.
    let repo_writable = push_ok.map(|allowed| allowed && branch_present);

    // A dead `cdn` link is counted here, or `ok: true` could stand beside a failure and
    // the one-value invariant below would not hold.
    let ok = p.config_ok
        && token_valid == Some(true)
        && repo_writable == Some(true)
        && p.dead_cdn.is_none();

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
    let detail = failure
        .as_ref()
        .map(|e| e.message.clone())
        .or_else(|| (!caveats.is_empty()).then(|| caveats.join("; ")));
    let error = failure.map(|e| ErrorBody::new(e.code.as_str(), &e.message));

    (
        DoctorReport {
            ok,
            config_ok: p.config_ok,
            token_valid,
            repo_writable,
            branch_protected: protected,
            login,
            detail,
            error,
        },
        exit,
    )
}

pub async fn run(cfg: &Config, mode: Mode) -> Result<u8> {
    let config_ok = cfg.require_target().is_ok();

    // Resolved before the target check, so a missing credential is reported even
    // when the repo is unconfigured too: both are things the user has to fix, and
    // `summarize` decides which one to lead with.
    let (token, mut setup_err) = match crate::auth::token() {
        Ok(token) => (Some(token), None),
        Err(e) => (None, Some(e)),
    };

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
                    repo = Some(info.map(|i| RepoFacts {
                        pushable: i.permissions.map(|p| p.push || p.admin).unwrap_or(false),
                        private: i.private,
                    }));
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

    // Read here rather than in `summarize`, which is deliberately free of `Config`:
    // this is the same judgement the upload path makes before it does anything, asked
    // of the same two values.
    let kind = crate::link::effective_link_kind(&cfg.upload.link_kind);
    let (report, exit) = summarize(Probed {
        config_ok,
        user,
        repo,
        branch,
        setup_err,
        cdn: matches!(kind, crate::cli::LinkKind::Cdn),
        dead_cdn: crate::commands::upload::reject_dead_cdn_link(kind, &cfg.github.branch).err(),
    });

    if mode.is_json() {
        crate::output::print_json(&report);
    } else {
        crate::output::line(&format!(
            "{} config present",
            crate::output::mark(report.config_ok)
        ));
        crate::output::line(&format!(
            "{} token valid{}",
            crate::output::mark_maybe(report.token_valid),
            report
                .login
                .as_ref()
                .map(|l| format!(" ({l})"))
                .unwrap_or_default(),
        ));
        crate::output::line(&format!(
            "{} repo writable{}",
            crate::output::mark_maybe(report.repo_writable),
            if report.branch_protected {
                " (branch protected)"
            } else {
                ""
            }
        ));
        if let Some(d) = &report.detail {
            // `output::note`, not a local copy of it: this was the fourth spelling of
            // `note:`, and the one `json_contract.rs`'s scan for `output::note(` — the
            // check that keeps advisories out of `-q` — could not see.
            crate::output::note(d);
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
            user: Some(user),
            // Takes the push permission alone, which is what every test here is
            // about; the private-plus-cdn pair has its own test below.
            repo: Some(repo.map(|pushable| RepoFacts {
                pushable,
                private: false,
            })),
            branch: Some(Ok(Branch::Present { protected: false })),
            setup_err: None,
            cdn: false,
            dead_cdn: None,
        }
    }

    #[test]
    fn a_user_outage_no_longer_hides_that_the_repo_is_writable() {
        // THE regression this release exists for. Observed live: `/user` 503 while
        // the repository endpoint answered `push: true`. Before the probes were
        // split, `repo_writable` came back false and was indistinguishable from a
        // dead credential.
        let (r, exit) = summarize(probed(Err(AppError::network("503")), Ok(true)));
        assert!(
            r.repo_writable == Some(true),
            "the repo answered, so say so"
        );
        assert!(
            r.token_valid != Some(true),
            "/user did not answer, so do not claim it did"
        );
        assert!(!r.ok);
        assert_eq!(exit, ErrorCode::Network.exit_code(), "retryable");
    }

    #[test]
    fn a_healthy_run_is_ok_and_exits_zero() {
        let (r, exit) = summarize(probed(Ok("tarnish233".into()), Ok(true)));
        assert!(
            r.ok && r.config_ok && r.token_valid == Some(true) && r.repo_writable == Some(true)
        );
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
        assert!(r.token_valid != Some(true) && r.repo_writable != Some(true));
        assert_eq!(exit, ErrorCode::AuthFailed.exit_code());
    }

    #[test]
    fn a_valid_token_without_push_is_permission_denied() {
        // Everything answered; GitHub just says no. There is no probe error to take
        // a code or a message from, so both are synthesised — this outcome used to
        // carry neither `error` nor `detail`, which left the exit status as the only
        // thing that said why `repo_writable` was false.
        let (r, exit) = summarize(probed(Ok("someone".into()), Ok(false)));
        assert!(r.token_valid == Some(true) && r.repo_writable != Some(true) && !r.ok);
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
                    user: None,
                    repo: None,
                    branch: None,
                    setup_err: Some(AppError::config_missing("no credential")),
                    cdn: false,
                    dead_cdn: None,
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
    fn a_configuration_no_upload_can_run_is_not_a_clean_bill_of_health() {
        // `doctor` never read `cfg.upload.*`, so `cdn` plus a branch containing `/` —
        // which `gitpic repos` writes verbatim for a repository whose default branch is
        // `release/v1`, and which `Config::validate` has no reason to refuse — reported
        // ✓ ✓ ✓ and exit 0 while every upload exited 2 having sent nothing.
        let (r, exit) = summarize(Probed {
            cdn: true,
            dead_cdn: Some(AppError::usage("branch contains '/'")),
            ..probed(Ok("me".into()), Ok(true))
        });
        assert!(!r.ok, "an upload that cannot start is not a healthy setup");
        assert_eq!(exit, ErrorCode::Usage.exit_code());
        assert_eq!(
            r.error.as_ref().map(|e| e.code.as_str()),
            Some("USAGE"),
            "and it reports the same code the upload path would"
        );
        // The probes still answered, and the report still says so — the dead link is a
        // separate fault, not a reason to withhold what was learned.
        assert_eq!(r.token_valid, Some(true));
        assert_eq!(r.repo_writable, Some(true));
    }

    #[test]
    fn a_private_host_serving_cdn_links_is_a_caveat_and_not_a_failure() {
        // Every upload succeeds and every jsDelivr link 404s, because jsDelivr serves
        // only public repositories. `RepoInfo` dropped `private`, so `doctor` could not
        // see it on a response it already fetched.
        let (r, exit) = summarize(Probed {
            cdn: true,
            repo: Some(Ok(RepoFacts {
                pushable: true,
                private: true,
            })),
            ..probed(Ok("me".into()), Ok(true))
        });
        // A caveat, because the upload really does work — it is the link that is dead,
        // which is worse in one way: nothing else reports it at all.
        assert!(r.ok, "the upload is not refused, so this is not a failure");
        assert_eq!(exit, 0);
        let detail = r.detail.unwrap_or_default();
        assert!(detail.contains("jsDelivr"), "{detail}");
        assert!(detail.contains("link_kind raw"), "{detail}");
        // Same repository on `raw` links has nothing to warn about.
        let (clean, _) = summarize(Probed {
            cdn: false,
            repo: Some(Ok(RepoFacts {
                pushable: true,
                private: true,
            })),
            ..probed(Ok("me".into()), Ok(true))
        });
        assert_eq!(clean.detail, None);
    }

    #[test]
    fn a_credential_nobody_checked_is_null_rather_than_false() {
        // The first-run state: `gitpic auth login` done, `gitpic repos` not yet. The
        // probes are gated on `config_ok` but only two of the three need a target, so
        // `/user` was never called — and `token_valid: false` was reported for a
        // credential nobody had looked at, while `auth status` on the same machine said
        // it was fine. The remedy a reader takes from ✗ is "log in again", which mints a
        // second token to fix a config file.
        let (r, exit) = summarize(Probed {
            config_ok: false,
            user: None,
            repo: None,
            branch: None,
            setup_err: None,
            cdn: true,
            dead_cdn: None,
        });
        assert_eq!(r.token_valid, None, "nothing was checked, so say nothing");
        assert_eq!(r.repo_writable, None);
        // Still a failure, and still the one the user can act on.
        assert!(!r.ok);
        assert_eq!(exit, ErrorCode::ConfigMissing.exit_code());
        // A credential that could not be *resolved* is a different claim: that is a
        // definite answer, and it stays `false` the way every consumer expects.
        let (unresolved, _) = summarize(Probed {
            config_ok: false,
            user: None,
            repo: None,
            branch: None,
            setup_err: Some(AppError::config_missing("no GitHub credential")),
            cdn: true,
            dead_cdn: None,
        });
        assert_eq!(unresolved.token_valid, Some(false));
    }

    #[test]
    fn an_unconfigured_target_outranks_a_missing_credential() {
        // Neither probe ran, and the report still has to be a complete one so an
        // agent can read it, and the detail names the fix the user can act on.
        let (r, exit) = summarize(Probed {
            config_ok: false,
            user: None,
            repo: None,
            branch: None,
            setup_err: Some(AppError::config_missing("no GitHub credential")),
            cdn: false,
            dead_cdn: None,
        });
        assert!(
            !r.config_ok && r.token_valid != Some(true) && r.repo_writable != Some(true) && !r.ok
        );
        assert_eq!(exit, ErrorCode::ConfigMissing.exit_code());
        assert!(
            r.detail
                .as_deref()
                .unwrap_or_default()
                .contains("gitpic config set github.repo"),
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
            user: None,
            repo: None,
            branch: None,
            setup_err: Some(AppError::config_missing("run `gitpic auth login`")),
            cdn: false,
            dead_cdn: None,
        });
        assert!(r.config_ok && r.token_valid != Some(true));
        assert_eq!(exit, ErrorCode::ConfigMissing.exit_code());
        assert_eq!(r.detail.as_deref(), Some("run `gitpic auth login`"));
    }

    #[test]
    fn push_permission_alone_is_not_reported_as_writable() {
        // The semantic fix: repo-level `push` says nothing about whether the ref an
        // upload targets exists. A push-capable token against a branch that is not
        // there still fails the Contents API, so claiming `repo_writable: true`
        // sent the user looking in the wrong place.
        let (r, exit) = summarize(Probed {
            config_ok: true,
            user: Some(Ok("me".into())),
            repo: Some(Ok(RepoFacts {
                pushable: true,
                private: false,
            })),
            branch: Some(Ok(Branch::Missing)),
            setup_err: None,
            cdn: false,
            dead_cdn: None,
        });
        assert!(
            r.repo_writable != Some(true),
            "a missing branch is not writable"
        );
        assert!(r.token_valid == Some(true), "the credential itself is fine");
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
            user: Some(Err(AppError::network("503"))),
            repo: Some(Ok(RepoFacts {
                pushable: true,
                private: false,
            })),
            branch: Some(Ok(Branch::Missing)),
            setup_err: None,
            cdn: false,
            dead_cdn: None,
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
            user: Some(Ok("me".into())),
            repo: Some(Ok(RepoFacts {
                pushable: true,
                private: false,
            })),
            branch: Some(Ok(Branch::Present { protected: true })),
            setup_err: None,
            cdn: false,
            dead_cdn: None,
        });
        assert!(r.ok && r.repo_writable == Some(true), "still a healthy run");
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
