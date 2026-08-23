//! gitpic's GitHub credential: one source, one file.
//!
//! The credential comes from `gitpic auth login` and nowhere else — an OAuth user
//! token obtained through the device flow in [`crate::oauth`], kept in
//! `$XDG_CONFIG_HOME/gitpic/auth.toml` at mode 0600.
//!
//! Three routes earlier versions accepted are gone, each for a reason rather than
//! for tidiness:
//!
//! - **`gh auth token`.** A second source meant a second identity: on a machine
//!   with a `gh` session, which account an upload was attributed to depended on
//!   whether a file happened to exist, and every credential failure had two
//!   remedies to explain. It also made `gh` a de-facto dependency for the one job
//!   gitpic can now do itself in a single command.
//! - **A pasted token (`--with-token`).** A token that travels by hand ends up in
//!   shell history, in a scrollback, in a chat log — and it let an agent ask a user
//!   to paste a credential into a conversation. The device flow moves no secret
//!   anywhere a human has to carry it.
//! - **`GITPIC_TOKEN` and a `github.token` config key.** A credential in the
//!   environment leaks into process listings and CI logs; one in `config.toml` gets
//!   printed by `gitpic config get` and opened in `$EDITOR` by `config edit`.
//!   `github.token` stays a `CONFIG_INVALID` error rather than a silently ignored
//!   key, so a file that still has one says so.
//!
//! With one source left there is nothing to report about provenance, which is why
//! neither `doctor` nor `auth status` carries a `token_source` any more.

use crate::error::{AppError, Result};
use serde::{Deserialize, Serialize};
use std::fmt;
use std::path::{Path, PathBuf};

/// The credential file, as written by `gitpic auth login`.
///
/// Deliberately *not* `deny_unknown_fields`, unlike [`crate::config::Config`]. The
/// rule there exists because `config.toml` is hand-edited, so a typo has to be
/// reported rather than ignored. This file is machine-written and machine-read: the
/// failure worth designing against is the opposite one, a version refusing to
/// authenticate over a key it does not recognise in a file it can otherwise read
/// perfectly well.
#[derive(Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Stored {
    pub token: String,
    /// The account the token belonged to at login time, so `auth status` can name it
    /// without a network round-trip. Informational: nothing branches on it.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub login: Option<String>,
    /// Which app the login went through, so a `GITPIC_CLIENT_ID` override is still
    /// identifiable afterwards.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub client_id: Option<String>,
    /// RFC 3339, present only when GitHub said the token expires — i.e. when the app
    /// has expiring user tokens switched on. gitpic's own app has them off, so this is
    /// normally absent.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub expires_at: Option<String>,
}

// A `refresh_token` is deliberately absent. GitHub sends one alongside an expiring
// token, and spending it requires the app's client *secret* — which a distributed CLI
// has no way to hold. Storing it would put a six-month secret on disk for a
// capability gitpic does not have; the remedy for an expiry is another
// `gitpic auth login`, which `commands::auth_cmd` says at login time.

/// Hand-written, not derived.
///
/// `{:?}` is the one place a secret gets printed by accident: a panic message, an
/// `expect` in a test, a stray debug line during a later change. A derived `Debug`
/// would put the token in all three, and none of them are places anyone thinks to
/// check for one. Everything useful for debugging — whose token, which app, when it
/// expires — is still here.
impl fmt::Debug for Stored {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Stored")
            .field("token", &"<redacted>")
            .field("login", &self.login)
            .field("client_id", &self.client_id)
            .field("expires_at", &self.expires_at)
            .finish()
    }
}

impl Stored {
    /// Whether `expires_at` is in the past. `None` — no expiry, or a timestamp that
    /// will not parse — is treated as "not known to be expired", because refusing to
    /// use a working token over an unreadable metadata field would be the worse
    /// failure.
    pub fn expired(&self) -> bool {
        self.expires_at
            .as_deref()
            .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
            .is_some_and(|at| at.timestamp() <= chrono::Utc::now().timestamp())
    }
}

/// Locate the credential file: `$XDG_CONFIG_HOME/gitpic/auth.toml`
/// (falls back to `~/.config/gitpic/auth.toml`). Does not require it to exist.
///
/// Beside `config.toml` and not in it, so that `gitpic config get` — which prints
/// every key it knows — cannot print a token, and so that `config edit` never opens
/// a secret in `$EDITOR`.
pub fn store_path() -> Result<PathBuf> {
    Ok(crate::config::base_dir("XDG_CONFIG_HOME", ".config")?
        .join("gitpic")
        .join("auth.toml"))
}

/// Read the stored credential, or `None` when nobody has logged in.
///
/// # Errors
/// `CONFIG_INVALID` when the file is there but unusable. That is a distinct state
/// from "not logged in": reporting no credential would send the user to log in again
/// over a file that `gitpic auth logout` is what actually clears.
pub fn load() -> Result<Option<Stored>> {
    load_from(&store_path()?)
}

/// Split from [`load`] for the same reason [`save_to`] is split from [`save`]: the
/// two `CONFIG_INVALID` states are then reachable in a test without mutating
/// `XDG_CONFIG_HOME` out from under a parallel one.
fn load_from(path: &Path) -> Result<Option<Stored>> {
    if !path.exists() {
        return Ok(None);
    }
    let shown = path.display().to_string();
    let text = std::fs::read_to_string(path).map_err(|e| {
        AppError::config_invalid(format!("cannot read credential file {shown}: {e}"))
    })?;
    // `toml::de::Error`'s Display includes the offending source line, which here
    // would be the token itself. Only the parser's own message is quoted.
    let stored: Stored = toml::from_str(&text).map_err(|e| {
        AppError::config_invalid(format!(
            "cannot use credential file {shown}: {}\nrun `gitpic auth logout` then `gitpic auth login`",
            e.message()
        ))
    })?;
    if stored.token.trim().is_empty() {
        return Err(AppError::config_invalid(format!(
            "credential file {shown} has no token\nrun `gitpic auth logout` then `gitpic auth login`"
        )));
    }
    Ok(Some(stored))
}

/// Write the credential file, 0600 and atomically.
///
/// Shares [`crate::config::write_private_atomic`] with `config.toml`, which is what
/// guarantees the file is private from before its first byte rather than chmod-ed
/// after the token is already on disk world-readable.
pub fn save(stored: &Stored) -> Result<PathBuf> {
    save_to(&store_path()?, stored)
}

/// Split from [`save`] for the same reason `Config::save_to` is: the file's
/// permissions are testable without mutating `XDG_CONFIG_HOME` out from under a
/// parallel test.
fn save_to(path: &Path, stored: &Stored) -> Result<PathBuf> {
    let text = toml::to_string_pretty(stored)
        .map_err(|e| AppError::general(format!("serialize credential: {e}")))?;
    let text = format!(
        "# Written by `gitpic auth login`. Contains a GitHub token — keep it private.\n\
         # Remove it with `gitpic auth logout`.\n{text}"
    );
    crate::config::write_private_atomic(path, &text, "credential")?;
    Ok(path.to_path_buf())
}

/// Delete the credential file. `Ok(false)` means there was nothing to delete.
pub fn delete() -> Result<bool> {
    let path = store_path()?;
    match std::fs::remove_file(&path) {
        Ok(()) => Ok(true),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(e) => Err(AppError::general(format!(
            "remove credential file {}: {e}",
            path.display()
        ))),
    }
}

/// The token to authenticate with.
pub fn token() -> Result<String> {
    token_from(load()?)
}

/// Split from the file read so both failure states are testable without a real
/// `$XDG_CONFIG_HOME`.
fn token_from(stored: Option<Stored>) -> Result<String> {
    let stored = stored
        .ok_or_else(|| AppError::config_missing("no GitHub credential: run `gitpic auth login`"))?;

    // Expiry is `AUTH_FAILED`, not `CONFIG_MISSING`: something *is* configured, and
    // the two codes carry different documented remedies. They happen to name the
    // same command here, but an agent that reads 3 as "nothing is set up yet" would
    // otherwise go and reconfigure a repo that was never the problem.
    if stored.expired() {
        return Err(AppError::auth(
            "the stored GitHub credential has expired; run `gitpic auth login` again",
        ));
    }
    // A file that exists and cannot be used is `CONFIG_INVALID` — the same call
    // `load` makes for the blank-token version of this problem, which the two paths
    // used to disagree about. `CONFIG_MISSING` would claim nothing is set up yet and
    // carry no remedy at all.
    sanitize(&stored.token).map_err(|msg| {
        AppError::config_invalid(format!(
            "{msg}\nrun `gitpic auth logout` then `gitpic auth login`"
        ))
    })
}

/// Reject anything that is not a bare token, so a malformed credential fails here
/// with an explanation rather than as a puzzling 401. This also keeps whitespace and
/// control characters out of the `Authorization` header.
///
/// Returns a bare message, in the same shape and for the same reason as
/// `Config::validate`: the caller attaches the code that fits where the value came
/// from. A malformed token read out of `auth.toml` is `CONFIG_INVALID` and its remedy
/// is that file; one handed back by GitHub's token endpoint is `AUTH_FAILED` and its
/// remedy is another login. Choosing here got both wrong — it reported
/// `CONFIG_MISSING`, whose published meaning is "nothing is set up yet", to a user
/// who had just finished a browser login.
pub(crate) fn sanitize(raw: &str) -> std::result::Result<String, String> {
    let t = raw.trim();
    if t.is_empty() {
        return Err("GitHub credential is empty".to_string());
    }
    if t.chars().any(|c| c.is_whitespace() || c.is_control()) {
        return Err(
            "GitHub credential is not a bare token (contains whitespace or control characters)"
                .to_string(),
        );
    }
    Ok(t.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::error::ErrorCode;

    fn logged_in(token: &str) -> Stored {
        Stored {
            token: token.to_string(),
            ..Stored::default()
        }
    }
    /// An RFC 3339 stamp `secs` from now, in the format [`save`] writes.
    fn from_now(secs: i64) -> String {
        (chrono::Utc::now() + chrono::TimeDelta::seconds(secs)).to_rfc3339()
    }

    #[test]
    fn the_stored_token_is_the_credential() {
        assert_eq!(token_from(Some(logged_in("ghu_abc\n"))).unwrap(), "ghu_abc");
    }

    #[test]
    fn no_credential_names_the_one_command_that_makes_one() {
        // One source now, so one remedy. Offering `gh auth login` here would send
        // the user to install a tool gitpic no longer consults.
        let err = token_from(None).expect_err("must fail");
        assert_eq!(err.code, ErrorCode::ConfigMissing);
        assert!(err.message.contains("gitpic auth login"), "{}", err.message);
        assert!(
            !err.message.contains("gh auth"),
            "gh is gone; the message must not offer it: {}",
            err.message
        );
    }

    #[test]
    fn an_expired_credential_is_auth_failed_not_config_missing() {
        // The distinction an agent branches on: 3 means "nothing is set up", and
        // acting on that here would have it reconfigure a repo that is already fine.
        let mut stored = logged_in("ghu_old");
        stored.expires_at = Some(from_now(-60));
        let err = token_from(Some(stored)).expect_err("must fail");
        assert_eq!(err.code, ErrorCode::AuthFailed);
        assert!(err.message.contains("gitpic auth login"), "{}", err.message);
    }

    #[test]
    fn a_token_that_has_not_expired_yet_is_used() {
        let mut stored = logged_in("ghu_fresh");
        stored.expires_at = Some(from_now(8 * 3600));
        assert_eq!(token_from(Some(stored)).unwrap(), "ghu_fresh");
    }

    #[test]
    fn an_unparseable_expiry_does_not_lock_out_a_working_token() {
        // Metadata gitpic cannot read is not grounds for refusing to authenticate.
        let mut stored = logged_in("ghu_fresh");
        stored.expires_at = Some("not-a-timestamp".to_string());
        assert!(!stored.expired());
        assert_eq!(token_from(Some(stored)).unwrap(), "ghu_fresh");
        // And no expiry at all is the ordinary case: an app with user-token
        // expiration switched off.
        assert!(!logged_in("ghu_fresh").expired());
    }

    #[test]
    fn debug_output_never_carries_the_token() {
        // The reason `Debug` is hand-written: an `expect`, a panic message or a
        // stray debug line must not be how a credential reaches a log.
        let stored = Stored {
            token: "ghu_secret".to_string(),
            login: Some("octocat".to_string()),
            ..Stored::default()
        };
        let shown = format!("{stored:?}");
        assert!(!shown.contains("ghu_secret"), "{shown}");
        // Still useful for debugging: the account is right there.
        assert!(shown.contains("octocat"), "{shown}");
    }

    #[test]
    fn a_stored_credential_round_trips_through_toml() {
        // The file is machine-written, so what is worth pinning is that every field
        // survives — not that the text looks a particular way.
        let stored = Stored {
            token: "ghu_x".to_string(),
            login: Some("octocat".to_string()),
            client_id: Some("Ov23liX".to_string()),
            expires_at: Some("2020-01-01T00:00:00+00:00".to_string()),
        };
        let text = toml::to_string_pretty(&stored).unwrap();
        // Nothing gitpic writes may carry a refresh token, whatever GitHub sent.
        assert!(!text.contains("refresh_token"), "{text}");
        let back: Stored = toml::from_str(&text).unwrap();
        assert_eq!(back.token, "ghu_x");
        assert_eq!(back.login.as_deref(), Some("octocat"));
        assert_eq!(back.client_id.as_deref(), Some("Ov23liX"));
        // A fixed date in the past, not "now minus a bit": a stamp that only reads
        // as expired depending on the hour the suite runs at is how this assertion
        // failed the first time.
        assert!(back.expired(), "a 2020 stamp is in the past");
    }

    #[test]
    fn an_unrecognised_key_does_not_break_the_login() {
        // Why this struct is not `deny_unknown_fields`. `method` is the concrete
        // case: it distinguished a device login from a pasted token, and pasted
        // tokens are gone — a file still carrying it must still authenticate.
        let back: Stored = toml::from_str("token = \"ghu_x\"\nmethod = \"device\"\n")
            .expect("an unknown key must not fail the parse");
        assert_eq!(back.token, "ghu_x");
        assert_eq!(token_from(Some(back)).unwrap(), "ghu_x");
    }

    /// A file gitpic cannot use is a third state, distinct from both "logged in" and
    /// "nobody has logged in" — and the one with its own remedy. Neither branch had
    /// any coverage: the test that claimed to cover it called `token_from` instead,
    /// and asserted the code its own comment said was wrong.
    #[test]
    fn an_unusable_credential_file_is_config_invalid_and_names_itself() {
        let dir = std::env::temp_dir().join(format!("gitpic-auth-load-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("mkdir");
        let path = dir.join("auth.toml");

        // Absent is not an error: it means nobody has logged in, which `token_from`
        // turns into CONFIG_MISSING with the remedy that fits.
        assert!(load_from(&path).expect("absent is not an error").is_none());

        // A file whose token is blank. Falling through to "not logged in" here would
        // hand the user the wrong command.
        std::fs::write(&path, "login = \"octocat\"\n").expect("write");
        let err = load_from(&path).expect_err("a tokenless file must not read as absent");
        assert_eq!(err.code, ErrorCode::ConfigInvalid);
        assert!(err.message.contains("auth.toml"), "{}", err.message);
        assert!(
            err.message.contains("gitpic auth logout"),
            "{}",
            err.message
        );

        // A file that will not parse. The parser's message is quoted; the file's own
        // contents are not, because on this path they are the token.
        std::fs::write(&path, "token = \"ghu_unterminated\n").expect("write");
        let err = load_from(&path).expect_err("broken TOML must not read as absent");
        assert_eq!(err.code, ErrorCode::ConfigInvalid);
        assert!(!err.message.contains("ghu_unterminated"), "{}", err.message);

        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn a_stored_token_that_is_not_a_bare_token_is_config_invalid() {
        // Not `CONFIG_MISSING`: something *is* configured, and that code's published
        // meaning would send an agent to reconfigure a repo. It also used to be the
        // one credential message carrying no remedy at all.
        let err = token_from(Some(logged_in("ghu_ab cd"))).expect_err("must fail");
        assert_eq!(err.code, ErrorCode::ConfigInvalid);
        assert!(err.message.contains("gitpic auth login"), "{}", err.message);
    }

    #[test]
    #[cfg(unix)]
    fn a_saved_credential_is_private_and_reads_back() {
        use std::os::unix::fs::PermissionsExt;

        let dir = std::env::temp_dir().join(format!("gitpic-auth-mode-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let path = dir.join("auth.toml");
        let stored = Stored {
            token: "ghu_x".to_string(),
            login: Some("octocat".to_string()),
            ..Stored::default()
        };
        save_to(&path, &stored).expect("writes");

        // 0600 matters more here than for `config.toml`: this file *is* the token.
        let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);

        let text = std::fs::read_to_string(&path).unwrap();
        // The header is the first thing anyone reading the file by hand sees, and it
        // has to say how to get rid of it.
        assert!(text.contains("gitpic auth logout"), "{text}");
        let back: Stored = toml::from_str(&text).expect("gitpic's own output parses");
        assert_eq!(back.token, "ghu_x");
        assert_eq!(back.login.as_deref(), Some("octocat"));

        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn sanitize_trims_the_trailing_newline() {
        assert_eq!(sanitize("ghu_abc\n").unwrap(), "ghu_abc");
        assert_eq!(sanitize("ghu_abc\r\n").unwrap(), "ghu_abc");
    }

    #[test]
    fn sanitize_rejects_prose_and_blanks_without_choosing_a_code() {
        // Would otherwise become an Authorization header and 401 confusingly. The
        // message is bare on purpose — the caller knows whether this value came off a
        // disk or off the wire, and those have different remedies.
        assert!(sanitize("error: not logged in").is_err());
        assert!(sanitize("").is_err());
        assert!(sanitize("  \n ").is_err());
        assert!(
            sanitize("").unwrap_err().contains("empty"),
            "the message has to survive being handed to a caller"
        );
    }

    #[test]
    fn the_credential_never_shares_a_file_with_the_config() {
        // `gitpic config get` prints every key it knows; a token in `config.toml`
        // would be one of them, and `config edit` would open it in `$EDITOR`.
        let auth = store_path().expect("a path");
        let config = crate::config::Config::path().expect("a path");
        assert_ne!(auth, config);
        assert_eq!(auth.parent(), config.parent());
        assert_eq!(auth.file_name().unwrap(), "auth.toml");
    }
}
