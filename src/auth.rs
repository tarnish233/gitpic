//! Read the GitHub credential from the GitHub CLI.

use crate::error::{AppError, Result};
use std::io::Read;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

/// How long `gh` gets to produce a token before it is killed. Generous enough
/// for a cold start, short enough that an agent-invoked upload cannot hang.
const GH_TIMEOUT: Duration = Duration::from_secs(10);

pub fn token() -> Result<String> {
    resolve_with(gh_token)
}

/// Split from the process spawn so credential handling can be tested without
/// depending on the developer's `gh` session.
fn resolve_with(gh: impl FnOnce() -> Result<Option<String>>) -> Result<String> {
    let raw = gh()?.ok_or_else(|| {
        AppError::config_missing("no GitHub credential: install GitHub CLI and run `gh auth login`")
    })?;
    sanitize(&raw)
}

/// Trim the trailing newline every credential helper emits, and reject anything
/// that is not a bare token: a helper that printed a prompt or an error message
/// to stdout should produce a clear failure here rather than a puzzling 401.
/// This also keeps whitespace and control characters out of the `Authorization`
/// header.
fn sanitize(raw: &str) -> Result<String> {
    let t = raw.trim();
    if t.is_empty() {
        return Err(AppError::config_missing("GitHub credential is empty"));
    }
    if t.chars().any(|c| c.is_whitespace() || c.is_control()) {
        return Err(AppError::config_missing(
            "GitHub credential is not a bare token (contains whitespace or control characters)",
        ));
    }
    Ok(t.to_string())
}

/// Ask the `gh` CLI for its token.
///
/// Missing/unusable/not-logged-in `gh` returns `Ok(None)` so the caller can show
/// one stable, actionable error. A timeout remains a real error: telling the user
/// to log in would be misleading when the helper actually hung.
fn gh_token() -> Result<Option<String>> {
    let Ok(mut child) = Command::new("gh")
        .args(["auth", "token", "--hostname", "github.com"])
        // gitpic's own stdin may be carrying image bytes (`--stdin`), so the
        // child must not be able to consume them. stderr is discarded because
        // "not logged in" is an expected fall-through, not an error to report.
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
    else {
        return Ok(None);
    };

    let deadline = Instant::now() + GH_TIMEOUT;
    let status = loop {
        match child.try_wait() {
            Ok(Some(s)) => break s,
            Err(_) => return Ok(None),
            Ok(None) => {
                if Instant::now() >= deadline {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Err(AppError::general(format!(
                        "`gh auth token` timed out after {}s",
                        GH_TIMEOUT.as_secs()
                    )));
                }
                // Short enough not to quantize the ~40ms normal case onto a
                // coarse grid; `waitpid(WNOHANG)` costs a couple of µs a call.
                std::thread::sleep(Duration::from_millis(2));
            }
        }
    };

    // Not logged in, or any other `gh` failure.
    if !status.success() {
        return Ok(None);
    }

    // A single short line, far below the pipe buffer, so reading after the
    // child has exited cannot deadlock.
    let mut out = String::new();
    if let Some(mut s) = child.stdout.take() {
        if s.read_to_string(&mut out).is_err() {
            return Ok(None);
        }
    }
    // Blank output falls through rather than hard-failing, so the user gets the
    // actionable message instead of "credential is empty".
    if out.trim().is_empty() {
        return Ok(None);
    }
    Ok(Some(out))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::error::ErrorCode;

    fn no_gh() -> Result<Option<String>> {
        Ok(None)
    }
    fn gh_returns(v: &'static str) -> impl FnOnce() -> Result<Option<String>> {
        move || Ok(Some(v.to_string()))
    }

    #[test]
    fn reads_and_sanitizes_the_gh_token() {
        assert_eq!(resolve_with(gh_returns("gho_abc\n")).unwrap(), "gho_abc");
    }

    #[test]
    fn unavailable_gh_credential_is_config_missing() {
        let err = resolve_with(no_gh).expect_err("must fail");
        assert_eq!(err.code, ErrorCode::ConfigMissing);
        assert!(err.message.contains("gh auth login"), "{}", err.message);
    }

    #[test]
    fn sanitize_trims_the_trailing_newline() {
        // Both `gh auth token` and a keychain helper emit one.
        assert_eq!(sanitize("gho_abc\n").unwrap(), "gho_abc");
        assert_eq!(sanitize("gho_abc\r\n").unwrap(), "gho_abc");
    }

    #[test]
    fn sanitize_rejects_prose_from_a_broken_helper() {
        // Would otherwise become an Authorization header and 401 confusingly.
        assert_eq!(
            sanitize("error: not logged in").unwrap_err().code,
            ErrorCode::ConfigMissing
        );
    }

    #[test]
    fn sanitize_rejects_empty_and_whitespace_only() {
        assert!(sanitize("").is_err());
        assert!(sanitize("  \n ").is_err());
    }
}
