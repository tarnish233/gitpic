//! `gitpic auth` — obtain, inspect and remove gitpic's GitHub credential.
//!
//! One way in: the GitHub App device flow in [`crate::oauth`]. `gh` is not
//! consulted and a token cannot be handed over by hand; see [`crate::auth`] for why
//! both routes were removed.
//!
//! No path here ever prints a token. `status` reports *about* the credential —
//! account, app, expiry — and `login` reports only who it belongs to.

use crate::auth::{self, Stored};
use crate::cli::AuthAction;
use crate::error::{AppError, Result};
use crate::github::GitHub;
use crate::output::{note, ErrorBody, Mode};
use owo_colors::{OwoColorize, Stream};
use serde::Serialize;

pub async fn run(action: &AuthAction, mode: Mode) -> Result<u8> {
    match action {
        AuthAction::Login {
            no_browser,
            scope,
            client_id,
        } => login(*no_browser, scope.as_deref(), client_id.as_deref(), mode).await,
        AuthAction::Status => status(mode).await,
        AuthAction::Logout => logout(mode),
    }
}

/// Everything `auth login` and `auth status` are willing to say about a credential.
/// The token is not a field, in either direction.
#[derive(Serialize)]
struct AuthReport {
    ok: bool,
    /// Whether GitHub accepted the credential just now.
    token_valid: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    login: Option<String>,
    /// The GitHub App the login went through — gitpic's own unless
    /// `GITPIC_CLIENT_ID` or `--client-id` said otherwise.
    #[serde(skip_serializing_if = "Option::is_none")]
    client_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    expires_at: Option<String>,
    /// Where the credential file is.
    #[serde(skip_serializing_if = "Option::is_none")]
    path: Option<String>,
    /// The one human-readable note — an expiry that will bite, an account that could
    /// not be confirmed.
    #[serde(skip_serializing_if = "Option::is_none")]
    detail: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<ErrorBody>,
}

// ---------------------------------------------------------------- login

async fn login(
    no_browser: bool,
    scope: Option<&str>,
    client_id: Option<&str>,
    mode: Mode,
) -> Result<u8> {
    // Deliberately not `?`: this is read only to say "replaced the credential that
    // was stored for X", and `auth::load` is `CONFIG_INVALID` for a file that exists
    // but will not parse. Propagating it made a corrupt `auth.toml` — the shape
    // dotfiles sync produces, and the reason `auth.toml` is the one file in that
    // directory to keep out of it — refuse the single command that overwrites the bad
    // file with a good one, while pointing at `auth logout`, which is not what anyone
    // reaches for to repair a login. A credential we cannot read is not a reason to
    // decline to mint one; `auth::save` below is the gate that still reports for real.
    let previous = auth::load().ok().flatten().and_then(|s| s.login);

    // The one subcommand whose `--json` is a *stream* rather than a single envelope,
    // because the shape of the interaction leaves no alternative: the code has to
    // reach the caller minutes before the outcome exists, and one envelope can only be
    // written once. So it is newline-delimited JSON — one complete object per line,
    // each tagged with `event`, and the last line is always the outcome.
    //
    // This is what lets GitPic.app run the login inside its settings window instead of
    // sending the user to a terminal. It is deliberately the only exception to
    // "one invocation, one envelope", and it is why an agent must still not run this
    // command: a reader that parses stdout as a single object will fail on the first
    // line, and only a human can type the code anyway.
    if mode.is_json() {
        return login_streaming(no_browser, scope, client_id, previous).await;
    }

    let stored = from_device_flow(no_browser, scope, client_id).await?;
    let path = auth::save(&stored)?;

    let expiry_note = stored.expires_at.as_deref().map(|at| {
        // An OAuth App's tokens do not expire, so reaching this means the app was
        // reconfigured or `GITPIC_CLIENT_ID` points somewhere else. Said at login
        // rather than left for the upload that fails eight hours later.
        format!(
            "GitHub issued a token that expires at {at}. gitpic does not refresh \
             automatically — run `gitpic auth login` again when it lapses."
        )
    });

    // No `AuthReport` here: `--json` is refused above, so building one would only
    // suggest this path can serialise. `auth status` is the command that reports.
    let who = stored
        .login
        .as_deref()
        .map(|l| format!(" as {l}"))
        .unwrap_or_default();
    crate::output::line(&format!(
        "{} logged in to github.com{who}",
        crate::output::tick()
    ));
    crate::output::line(&format!("  stored in: {}", path.display()));
    if let Some(l) = previous.filter(|p| Some(p.as_str()) != stored.login.as_deref()) {
        note(&format!("replaced the credential that was stored for {l}"));
    }
    if let Some(text) = &expiry_note {
        note(text);
    }

    // Straight into the picker, because this is the one moment it costs nothing: the
    // credential that can read the list was issued seconds ago, and a login that stops
    // here leaves the next upload failing with `CONFIG_MISSING` for a reason the user
    // has no way to connect to what they just did. It is also why `gitpic init` no
    // longer exists — it was this list behind a second command whose name promised to
    // be the first one you ran, and which then refused to run without a credential.
    //
    // A failure in there is a note and not a status. The login has already succeeded
    // and been written to disk; exiting non-zero would say otherwise, and the obvious
    // response to "login failed" is to log in again — minting a second token to fix a
    // repository listing.
    crate::output::line("");
    if let Err(e) = crate::commands::repos::choose_target(&stored.token).await {
        // `repos`' own constant, which exists for exactly this and which this had
        // re-spelled — dropping the `GITPIC_REPO=owner/name` half both other copies
        // offer.
        note(&format!(
            "could not list your repositories: {}\n  {}",
            e.message,
            crate::commands::repos::SET_IT_BY_HAND
        ));
    }
    Ok(0)
}

/// The browser hand-off: print a code, wait for GitHub, keep what it hands back.
async fn from_device_flow(
    no_browser: bool,
    scope: Option<&str>,
    client_id: Option<&str>,
) -> Result<Stored> {
    let client_id = crate::oauth::client_id(client_id)?;
    let scope = crate::oauth::scope(scope);

    // The rule `commands::prompt_opt` applies to a question, applied to a code:
    // something nobody could read has no answer. `gitpic auth login | true` threw
    // the one-time code into a closed pipe and then polled GitHub for the full
    // fifteen minutes it stayed valid, with nothing on screen to explain the wait.
    //
    // A closed stdout can only be *discovered* by writing to it, so this heading is
    // the probe as well as a heading — and putting it ahead of the request is what
    // makes the failure land before a code is minted that nobody can use. Checking
    // before writing anything, which is where this started, can never fire: no
    // write has failed yet.
    crate::output::line("gitpic auth login — authorise in the browser");
    crate::output::finish();
    if crate::output::stdout_lost() {
        return Err(AppError::general(
            "stdout is closed, so the one-time code cannot be shown; refusing to \
             start a login nobody can complete",
        ));
    }

    let device = crate::oauth::start(&client_id, &scope).await?;

    let code = device
        .user_code
        .if_supports_color(Stream::Stdout, |t| t.bold().to_string());
    crate::output::line(&format!("  one-time code: {code}"));
    crate::output::line(&format!("  enter it at:   {}", device.verification_uri));
    if !no_browser && open_browser(&device.verification_uri) {
        crate::output::line("  (opened in your browser)");
    }
    crate::output::line("  waiting for you to finish in the browser…");
    // The code and the URL are of no use sitting in a buffer while this blocks for
    // minutes.
    crate::output::finish();

    let granted = crate::oauth::wait_for_token(&client_id, &device).await?;
    stored_from(granted, client_id).await
}

/// Turn a grant into the record that goes on disk.
///
/// Shared by the human and the streaming logins, so the two cannot end up writing
/// different files for the same grant.
async fn stored_from(granted: crate::oauth::Granted, client_id: String) -> Result<Stored> {
    // `AUTH_FAILED`, not the `CONFIG_MISSING` the shared helper used to pick: the
    // user just finished a browser login, so "nothing is set up yet" is both wrong and
    // — for an agent following code 3's published remedy — a loop.
    let token = auth::sanitize(&granted.access_token)
        .map_err(|msg| AppError::auth(format!("GitHub returned an unusable token: {msg}")))?;

    // GitHub's token endpoint issued this token seconds ago, so it is valid by
    // construction and a failed `/user` probe is not grounds for discarding a login
    // the user already completed in the browser. The account name is a nicety; the
    // credential is the point.
    let login = GitHub::for_user(&token)?.whoami().await.ok();

    Ok(Stored {
        token,
        login,
        client_id: Some(client_id),
        expires_at: granted
            .expires_in
            // Converted rather than cast: a `u64` past `i64::MAX` wraps negative, and
            // `checked_add_signed` then writes a stamp in the *past* — "✓ logged in"
            // followed by AUTH_FAILED on the very next command. Out of range means no
            // usable expiry, which is what `try_seconds` returning `None` says.
            .and_then(|s| i64::try_from(s).ok())
            .and_then(chrono::TimeDelta::try_seconds)
            .and_then(|d| chrono::Local::now().checked_add_signed(d))
            .map(|at| at.to_rfc3339()),
    })
}

/// Hand `url` to the platform opener, best effort.
///
/// Returns whether the opener was launched at all — never whether a browser
/// actually appeared, which nothing here can know. The URL is always printed first,
/// so a headless box, a missing opener and `--no-browser` all leave a usable
/// instruction on screen.
fn open_browser(url: &str) -> bool {
    // The URL comes from GitHub over TLS, but it still ends up as an argument to a
    // platform opener, and `open` on macOS will happily act on a non-http scheme.
    // Only the one host this flow can legitimately point at gets opened; anything
    // else stays on screen for the user to read.
    if !url.starts_with("https://github.com/") {
        return false;
    }
    let (program, args) = if cfg!(target_os = "macos") {
        ("open", vec![url])
    } else if cfg!(target_os = "windows") {
        // `start` is a shell builtin, hence `cmd`. The empty string is `start`'s
        // title argument: without it a quoted URL would be taken *as* the title and
        // nothing would open.
        ("cmd", vec!["/C", "start", "", url])
    } else {
        ("xdg-open", vec![url])
    };
    std::process::Command::new(program)
        .args(args)
        // gitpic's stdin may be carrying image bytes on another invocation, and a
        // browser's chatter must not land in the middle of this command's output.
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .is_ok()
}

/// The three events `auth login --json` can emit, one per line.
///
/// At module scope rather than inside the function that writes them, so the shape is
/// reachable from a test: the flow itself needs a browser and a network, and the part
/// worth pinning — that every line carries an `event` tag, that the outcome lines carry
/// `ok`, and that none of them has anywhere to put a token — is pure serialisation.
#[derive(Serialize)]
struct CodeEvent<'a> {
    event: &'a str,
    user_code: &'a str,
    verification_uri: &'a str,
    interval_seconds: u64,
    expires_in_seconds: u64,
}

#[derive(Serialize)]
struct DoneEvent<'a> {
    event: &'a str,
    ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    login: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    client_id: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    expires_at: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    replaced: Option<&'a str>,
    path: String,
}

#[derive(Serialize)]
struct ErrorEvent<'a> {
    event: &'a str,
    ok: bool,
    error: ErrorBody,
    /// Whether the failure happened after the code was shown, so a UI knows whether
    /// the code still on screen is worth leaving there.
    code_was_issued: bool,
}

/// `auth login --json`: the same flow, reported as a line-per-event stream.
///
/// Errors are rendered here rather than propagated, so the stream's last line is
/// always a tagged event instead of `main`'s bare envelope — a reader that switches on
/// `event` would otherwise meet one object it has no case for. The exit status is
/// still the failure's, which is what `Ok(code)` carries.
async fn login_streaming(
    no_browser: bool,
    scope: Option<&str>,
    client_id: Option<&str>,
    previous: Option<String>,
) -> Result<u8> {
    let mut issued = false;
    let outcome: Result<(Stored, std::path::PathBuf)> = async {
        let client_id = crate::oauth::client_id(client_id)?;
        let device = crate::oauth::start(&client_id, &crate::oauth::scope(scope)).await?;
        crate::output::print_json_line(&CodeEvent {
            event: "code",
            user_code: &device.user_code,
            verification_uri: &device.verification_uri,
            interval_seconds: device.interval.as_secs(),
            expires_in_seconds: device.expires_in.as_secs(),
        });
        // Flushed before the wait, not after it: the whole point of this event is to
        // reach the caller while the poll below is still blocking.
        crate::output::finish();
        issued = true;
        // `from_device_flow`'s probe, at the only point this path can make it. The
        // code has just been written and flushed, so a reader that has already gone
        // is discoverable now; the alternative to looking is polling GitHub every few
        // seconds for the fifteen minutes the code stays valid, on behalf of a code
        // that reached nobody — the exact `| true` hang the human path fixed. It
        // cannot happen *before* the code is minted the way it does over there:
        // there is nothing a JSON reader would accept to probe with.
        if crate::output::stdout_lost() {
            return Err(AppError::general(
                "stdout closed before the one-time code could be read; abandoning a \
                 login nobody can complete",
            ));
        }
        if !no_browser {
            open_browser(&device.verification_uri);
        }
        let granted = crate::oauth::wait_for_token(&client_id, &device).await?;
        let stored = stored_from(granted, client_id).await?;
        // In here rather than in the `Ok` arm below, which is where it was: this is
        // the one failure where the tagged event matters most. The token has been
        // minted and is about to be lost, and `?` out there reaches `main`, whose
        // `print_json` is `to_string_pretty` — seven lines, none of them carrying
        // `event`, so a line-per-event reader drops every one and reports no outcome
        // at all for a login that really did fail. That is precisely what this
        // function's doc promises cannot happen.
        let path = auth::save(&stored)?;
        Ok((stored, path))
    }
    .await;

    match outcome {
        Ok((stored, path)) => {
            crate::output::print_json_line(&DoneEvent {
                event: "done",
                ok: true,
                login: stored.login.as_deref(),
                client_id: stored.client_id.as_deref(),
                expires_at: stored.expires_at.as_deref(),
                replaced: previous
                    .as_deref()
                    .filter(|p| Some(*p) != stored.login.as_deref()),
                path: path.display().to_string(),
            });
            Ok(0)
        }
        Err(e) => {
            crate::output::print_json_line(&ErrorEvent {
                event: "error",
                ok: false,
                error: ErrorBody::new(e.code.as_str(), &e.message),
                code_was_issued: issued,
            });
            Ok(e.code.exit_code())
        }
    }
}

// ---------------------------------------------------------------- status

async fn status(mode: Mode) -> Result<u8> {
    // Propagates when nobody has logged in (`CONFIG_MISSING`), when the credential
    // has expired (`AUTH_FAILED`), or when the file is unreadable
    // (`CONFIG_INVALID`) — each already carrying its own remedy.
    //
    // Read twice, deliberately: `auth::token` owns the decision of *whether* the
    // stored credential may be used, and duplicating that rule here to save one
    // read of a 200-byte file is how the two would drift apart.
    let token = auth::token()?;
    let stored = auth::load()?;

    let (login, failure) = match GitHub::for_user(&token)?.whoami().await {
        Ok(login) => (Some(login), None),
        // Fall back to the name recorded at login time, so a network fault still
        // says which account this is about.
        Err(e) => (stored.as_ref().and_then(|s| s.login.clone()), Some(e)),
    };

    let report = AuthReport {
        ok: failure.is_none(),
        token_valid: failure.is_none(),
        login,
        client_id: stored.as_ref().and_then(|s| s.client_id.clone()),
        expires_at: stored.as_ref().and_then(|s| s.expires_at.clone()),
        path: Some(auth::store_path()?.display().to_string()),
        detail: failure.as_ref().map(|e| e.message.clone()),
        error: failure
            .as_ref()
            .map(|e| ErrorBody::new(e.code.as_str(), &e.message)),
    };

    if mode.is_json() {
        crate::output::print_json(&report);
    } else {
        let who = report
            .login
            .as_deref()
            .map(|l| format!(" as {l}"))
            .unwrap_or_default();
        crate::output::line(&format!(
            "{} github.com{who}",
            crate::output::mark(report.token_valid)
        ));
        if let Some(id) = &report.client_id {
            crate::output::line(&format!("  app: {id}"));
        }
        if let Some(at) = &report.expires_at {
            crate::output::line(&format!("  expires: {at}"));
        }
        if let Some(path) = &report.path {
            crate::output::line(&format!("  stored in: {path}"));
        }
        if let Some(detail) = &report.detail {
            note(detail);
        }
    }
    // Same rule as `doctor`: the report is printed either way, and the exit status
    // carries the failure so a caller that only reads the status still sees it.
    Ok(failure.map_or(0, |e| e.code.exit_code()))
}

// ---------------------------------------------------------------- logout

#[derive(Serialize)]
struct LogoutReport {
    ok: bool,
    /// Whether a credential file was actually there to remove.
    removed: bool,
    path: String,
}

fn logout(mode: Mode) -> Result<u8> {
    let path = auth::store_path()?;
    let removed = auth::delete()?;

    if mode.is_json() {
        crate::output::print_json(&LogoutReport {
            ok: true,
            removed,
            path: path.display().to_string(),
        });
        return Ok(0);
    }
    if removed {
        crate::output::line(&format!(
            "{} removed {}",
            crate::output::tick(),
            path.display()
        ));
        // There is no fallback source left, so a logout really is a logout — worth
        // saying, because the next upload will fail until someone logs in again.
        note("gitpic now has no credential: run `gitpic auth login` before uploading");
    } else {
        crate::output::line("no credential was stored");
    }
    Ok(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_github_urls_are_handed_to_the_platform_opener() {
        // The URL arrives in a response body. It is printed regardless, so refusing
        // to *launch* anything for an unexpected one costs nothing.
        assert!(!open_browser("file:///etc/passwd"));
        assert!(!open_browser("http://github.com/login/device"));
        assert!(!open_browser("https://github.example.com/login/device"));
        assert!(!open_browser("javascript:alert(1)"));
    }

    /// The device flow's counterpart to
    /// `commands::tests::a_prompt_that_could_not_be_written_is_never_answered`.
    ///
    /// That the call *returns* is the contract: the guard sits ahead of the
    /// device-code request, so this reaches no network — and a guard placed after the
    /// code was printed would hang the suite on the poll loop instead of failing it,
    /// which is the shape of the bug this closes.
    #[test]
    fn a_login_code_that_cannot_be_shown_is_never_requested() {
        let _serialised = crate::output::stdout_lost_test_guard(true);
        let err = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("a runtime")
            .block_on(from_device_flow(true, None, Some("Ov23liTestOnly")))
            .expect_err("a code nobody can read must not be requested");
        assert_eq!(
            err.code,
            crate::error::ErrorCode::General,
            "{}",
            err.message
        );
        assert!(err.message.contains("stdout is closed"), "{}", err.message);
    }

    /// The stream contract GitPic.app reads: one tagged object per line, the last one
    /// the outcome.
    ///
    /// Pinned here because the flow that emits these cannot run in a test — it needs a
    /// browser and fifteen minutes — and because this is the one `--json` in the CLI
    /// that is *not* a single envelope. A reader switching on `event` breaks the moment
    /// a line arrives without the tag.
    #[test]
    fn every_login_stream_line_is_tagged_and_carries_no_token() {
        // `json_line`, not `serde_json::to_string`: the printer these events go through
        // is what decides whether the stream is newline-delimited at all, and testing
        // the struct instead is how a pretty-printed seven-line "line" shipped.
        let code = crate::output::json_line(&CodeEvent {
            event: "code",
            user_code: "D5F9-4823",
            verification_uri: "https://github.com/login/device",
            interval_seconds: 5,
            expires_in_seconds: 900,
        });
        assert!(code.contains(r#""event":"code""#), "{code}");
        assert!(code.contains("D5F9-4823"), "{code}");

        let done = crate::output::json_line(&DoneEvent {
            event: "done",
            ok: true,
            login: Some("octocat"),
            client_id: Some("Ov23liX"),
            expires_at: None,
            replaced: None,
            path: "/tmp/auth.toml".to_string(),
        });
        assert!(done.contains(r#""event":"done""#), "{done}");
        assert!(done.contains(r#""ok":true"#), "{done}");
        // Absent fields stay absent rather than becoming nulls a reader must special-case.
        assert!(
            !done.contains("expires_at") && !done.contains("replaced"),
            "{done}"
        );

        let failed = crate::output::json_line(&ErrorEvent {
            event: "error",
            ok: false,
            error: ErrorBody::new("AUTH_FAILED", "the login was cancelled in the browser"),
            code_was_issued: true,
        });
        assert!(failed.contains(r#""event":"error""#), "{failed}");
        assert!(failed.contains(r#""ok":false"#), "{failed}");
        assert!(failed.contains(r#""code":"AUTH_FAILED""#), "{failed}");

        for line in [&code, &done, &failed] {
            // One line each. A reader splits the stream on newlines, so an event that
            // spans several is not a formatting nit — it is unparseable.
            assert!(!line.contains('\n'), "{line:?}");
            // And none of the three has a field a token could land in.
            assert!(!line.contains(r#""token""#), "{line}");
            assert!(!line.contains("ghu_") && !line.contains("gho_"), "{line}");
        }
    }

    #[test]
    fn a_report_never_carries_a_token() {
        // The struct is the guarantee: there is no field for one, so no renderer and
        // no `--json` consumer can be handed one by accident.
        let report = AuthReport {
            ok: true,
            token_valid: true,
            login: Some("octocat".to_string()),
            client_id: Some("Ov23liX".to_string()),
            expires_at: None,
            path: Some("/tmp/auth.toml".to_string()),
            detail: None,
            error: None,
        };
        let json = serde_json::to_string(&report).expect("serialises");
        assert!(!json.contains("token\":\""), "{json}");
        assert!(json.contains("\"token_valid\":true"), "{json}");
        // Provenance is gone with the second source: there is one place a credential
        // can come from, so a `token_source` field would only ever restate it.
        assert!(!json.contains("token_source"), "{json}");
        // Absent fields stay absent rather than becoming nulls a caller has to
        // special-case.
        assert!(!json.contains("expires_at"), "{json}");
    }
}
