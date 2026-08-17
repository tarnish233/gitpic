//! Resolve the GitHub credential.
//!
//! Priority (highest first): `GITPIC_TOKEN` > `config.github.token` > `gh auth token`.
//!
//! Explicit configuration deliberately beats auto-detection: if `gh` won, then
//! upgrading gitpic would silently switch which account uploads for anyone who
//! still has a token in their config — and `gh` may be logged into a different
//! one. Migrating is therefore an explicit act: delete the `token` line.
//!
//! The resolved token is never stored in `Config`. It is fetched only when a
//! request is about to be made, so `gitpic config get` cannot make a keychain
//! prompt appear, and `{:?}` on a `Config` cannot print a secret.

use crate::config::Config;
use crate::error::{AppError, Result};
use std::io::Read;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

/// Where the token came from. Reported by `doctor` so a migration away from a
/// plaintext token can actually be verified.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Source {
    Env,
    Config,
    Gh,
}

impl Source {
    pub fn as_str(self) -> &'static str {
        match self {
            Source::Env => "env",
            Source::Config => "config",
            Source::Gh => "gh",
        }
    }
}

pub struct Credential {
    pub token: String,
    pub source: Source,
}

/// Hand-written so that `{:?}` on a `Credential` cannot leak the token. This is
/// the hazard that `Config`'s derived `Debug` still has for its inline token.
impl std::fmt::Debug for Credential {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Credential")
            .field("token", &"<redacted>")
            .field("source", &self.source)
            .finish()
    }
}

/// How long `gh` gets to produce a token before it is killed. Generous enough
/// for a cold start, short enough that an agent-invoked upload cannot hang.
const GH_TIMEOUT: Duration = Duration::from_secs(10);

pub fn resolve(cfg: &Config) -> Result<Credential> {
    resolve_with(
        std::env::var("GITPIC_TOKEN").ok(),
        &cfg.github.token,
        gh_token,
    )
}

/// Ordering logic, split from the process spawn so it can be tested without
/// running `gh` and without mutating the environment (unsound across parallel
/// test threads). Mirrors the `GitHub::new` / `with_api` seam in `github.rs`.
fn resolve_with(
    env: Option<String>,
    inline: &str,
    gh: impl FnOnce() -> Result<Option<String>>,
) -> Result<Credential> {
    let (source, raw) = if let Some(v) = env.filter(|v| !v.trim().is_empty()) {
        (Source::Env, v)
    } else if !inline.trim().is_empty() {
        (Source::Config, inline.to_string())
    } else if let Some(v) = gh()? {
        (Source::Gh, v)
    } else {
        return Err(AppError::config_missing(
            "no GitHub credential: run `gh auth login`, or set GITPIC_TOKEN",
        ));
    };
    Ok(Credential {
        token: sanitize(&raw)?,
        source,
    })
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
/// Any way `gh` can be unusable — not installed, not executable, not logged in —
/// returns `Ok(None)` so resolution falls through to the actionable error in
/// `resolve_with` instead of surfacing `gh`'s own wording. A timeout is the one
/// real error: falling through after `gh` actually hung would tell the user to
/// run `gh auth login` when that is not the problem.
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

    // Not logged in, or any other `gh` failure: fall through to the next source.
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
    fn env_wins_over_everything() {
        let c = resolve_with(
            Some("from_env".into()),
            "from_config",
            gh_returns("from_gh"),
        )
        .unwrap();
        assert_eq!(c.token, "from_env");
        assert_eq!(c.source, Source::Env);
    }

    #[test]
    fn config_wins_over_gh() {
        // Explicit configuration must beat auto-detection, so upgrading gitpic
        // never silently switches which account uploads.
        let c = resolve_with(None, "from_config", gh_returns("from_gh")).unwrap();
        assert_eq!(c.token, "from_config");
        assert_eq!(c.source, Source::Config);
    }

    #[test]
    fn gh_is_used_when_nothing_is_configured() {
        let c = resolve_with(None, "", gh_returns("from_gh")).unwrap();
        assert_eq!(c.token, "from_gh");
        assert_eq!(c.source, Source::Gh);
    }

    #[test]
    fn blank_sources_do_not_shadow_a_working_one() {
        // An exported-but-empty GITPIC_TOKEN, and a `token = ""` left in the
        // config after migrating, must both fall through rather than fail.
        let c = resolve_with(Some("   ".into()), "", gh_returns("from_gh")).unwrap();
        assert_eq!(c.source, Source::Gh);
    }

    #[test]
    fn no_source_at_all_is_config_missing() {
        let err = resolve_with(None, "", no_gh).expect_err("must fail");
        assert_eq!(err.code, ErrorCode::ConfigMissing);
        // The message has to say what to actually do about it.
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

    #[test]
    fn debug_never_prints_the_token() {
        let c = resolve_with(Some("sensitive-value-for-test".into()), "", no_gh).unwrap();
        let shown = format!("{c:?}");
        assert!(!shown.contains("sensitive-value-for-test"), "{shown}");
        assert!(shown.contains("<redacted>"), "{shown}");
    }
}
