//! GitHub device flow — the protocol half of `gitpic auth login`.
//!
//! The device flow (RFC 8628) is the one browser-based grant a CLI can complete
//! without holding a client *secret*: gitpic asks GitHub for a short user code,
//! the user types it into github.com, and gitpic polls until GitHub hands over a
//! token. That is what lets `gitpic` stop requiring the `gh` CLI just to obtain a
//! credential.
//!
//! This module is only the wire protocol. Where the resulting token is kept, and
//! how it is found again on the next run, is [`crate::auth`]; the prompts and the
//! browser hand-off are `commands::auth_cmd`.

use crate::error::{AppError, Result};
use serde::Deserialize;
use std::time::{Duration, Instant};

/// The `gitpic` OAuth App's client ID.
///
/// Not a secret, by construction: it travels in the device-flow request body in the
/// clear and is the last path segment of the user's own authorisations page
/// (`github.com/settings/connections/applications/<client_id>`). Needing no client
/// secret is the entire point of the device flow — and a secret compiled into a
/// distributed binary would not be one anyway.
///
/// An **OAuth App**, which is what makes [`DEFAULT_SCOPE`] load-bearing: an OAuth
/// token's reach is decided entirely by the scopes granted when the user authorises.
///
/// A GitHub App was the other candidate and would have been narrower — `Contents:
/// write` on one chosen repository, instead of a scope that spans all of them. It lost
/// on the *flow*, not the permissions. A GitHub App's user token can only reach
/// repositories the app has been **installed** on, and the device flow does not ask
/// for an installation: every user would authorise in the terminal and then have to go
/// to a browser again to install the app and pick repositories. One login that
/// immediately yields a list to choose from is worth more than a tighter grant that
/// half the users never finish.
pub const DEFAULT_CLIENT_ID: &str = "Ov23lixXJLMVM3WBedvm";

/// What `gitpic auth login` asks for when nothing overrides it.
///
/// `public_repo` is write access to the user's **public** repositories. It is the
/// narrowest scope that can do gitpic's one job, because GitHub has no scope meaning
/// "this repository" — and it is all a working image host needs, since jsDelivr, which
/// `link_kind = "cdn"` points at, serves only public repositories.
///
/// A private image host needs `repo`, which is broad: read and write on every
/// repository the user can reach. That is why it is not the default — `--scope repo`
/// asks for it deliberately, and only `link_kind = "raw"` links resolve from a private
/// repository anyway.
pub const DEFAULT_SCOPE: &str = "public_repo";

const DEVICE_CODE_URL: &str = "https://github.com/login/device/code";
const TOKEN_URL: &str = "https://github.com/login/oauth/access_token";
const UA: &str = concat!("gitpic/", env!("CARGO_PKG_VERSION"));
const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);
const CONNECT_TIMEOUT: Duration = Duration::from_secs(15);
/// Added to the poll interval when GitHub answers `slow_down`. GitHub documents
/// five seconds as the increment.
const SLOW_DOWN_STEP: Duration = Duration::from_secs(5);
/// Fallbacks for the two timings GitHub does send but the spec leaves optional.
/// Both match GitHub's current values, so they only ever apply if a response
/// omits them.
const DEFAULT_INTERVAL: u64 = 5;
const DEFAULT_EXPIRES_IN: u64 = 900;
/// A poll interval GitHub could never legitimately ask for. Without a ceiling, a
/// response claiming `interval: 86400` would park the CLI for a day inside a
/// wait the user cannot tell from a hang.
const MAX_INTERVAL: Duration = Duration::from_secs(60);
/// The same ceiling for the other server-supplied timing, and for a harder reason
/// than patience: this one bounds a wall-clock wait, so `expires_in:
/// 18446744073709551615` used to park the CLI for longer than the machine will
/// exist. GitHub sends 900, and a code nobody has typed in half an hour is one the
/// user has walked away from.
const MAX_EXPIRES_IN: Duration = Duration::from_secs(30 * 60);
/// The consecutive-fault count that ends a login: two are absorbed, the third
/// gives up.
///
/// A dropped packet somewhere in a 15-minute wait must not send the user back to
/// the browser to start over, which is what propagating the first one did. A
/// machine that is simply offline still fails after three intervals rather than
/// polling a dead network until the code expires.
const MAX_CONSECUTIVE_NETWORK_FAULTS: u32 = 3;

/// What GitHub gave back for step one: the code the user types, and the two
/// timings that govern the polling in step two.
pub struct Device {
    /// Passed back on every poll. Not shown to the user — `user_code` is.
    pub device_code: String,
    /// The short code the user types into the browser (`ABCD-1234`).
    pub user_code: String,
    /// Where to type it.
    pub verification_uri: String,
    /// How often GitHub is willing to be polled.
    pub interval: Duration,
    /// How long `user_code` stays valid.
    pub expires_in: Duration,
}

/// Hand-written `Debug` on both of the above, and not derived.
///
/// `{:?}` is the one place a secret gets printed by accident: a panic message, an
/// `expect` in a test, a stray debug line during a later change. `Device` holds the
/// device code, which is what authorises fetching the token, and `Granted` holds the
/// token itself. Neither is formatted anywhere today, which is exactly why a derive
/// is the wrong default here — it costs nothing to remove now and would leak the
/// first time someone reaches for `dbg!`.
impl std::fmt::Debug for Device {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Device")
            .field("device_code", &"<redacted>")
            .field("user_code", &self.user_code)
            .field("verification_uri", &self.verification_uri)
            .field("interval", &self.interval)
            .field("expires_in", &self.expires_in)
            .finish()
    }
}

/// A user access token, plus what GitHub said about its lifetime.
///
/// `expires_in` is present only when the GitHub App has expiring user tokens
/// switched on. The `refresh_token` GitHub sends alongside it is **deliberately not
/// carried**: spending one requires the app's client *secret*, which a distributed
/// CLI has no way to hold, so keeping it would be storing a six-month secret for a
/// capability gitpic does not have. The remedy for an expiry is another
/// `gitpic auth login`, and `commands::auth_cmd` says so at login time rather than
/// eight hours later.
pub struct Granted {
    pub access_token: String,
    pub expires_in: Option<u64>,
}

impl std::fmt::Debug for Granted {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Granted")
            .field("access_token", &"<redacted>")
            .field("expires_in", &self.expires_in)
            .finish()
    }
}

/// One field set for both endpoints: they share an error shape, and every success
/// field is optional in the responses that carry an error instead.
///
/// No `Debug`, for the reason given above — it holds both a device code and a token,
/// and nothing formats it.
#[derive(Default, Deserialize)]
#[serde(default)]
struct Body {
    // Step one.
    device_code: Option<String>,
    user_code: Option<String>,
    verification_uri: Option<String>,
    interval: Option<u64>,
    expires_in: Option<u64>,
    // Step two. A `refresh_token` also arrives here and is not declared: the struct
    // is not `deny_unknown_fields`, so it is dropped on the floor, which is what
    // `Granted` says should happen to it.
    access_token: Option<String>,
    // Either step.
    error: Option<String>,
    error_description: Option<String>,
}

/// Resolve the client ID: `--client-id` > `GITPIC_CLIENT_ID` > [`DEFAULT_CLIENT_ID`].
///
/// Blank candidates are skipped rather than honoured, so `GITPIC_CLIENT_ID=` in a
/// shell profile — or `--client-id ''` — behaves like "not set" instead of
/// sending an empty `client_id` GitHub answers with an opaque error.
pub fn client_id(flag: Option<&str>) -> Result<String> {
    let from_env = std::env::var("GITPIC_CLIENT_ID").ok();
    let id = [flag, from_env.as_deref(), Some(DEFAULT_CLIENT_ID)]
        .into_iter()
        .flatten()
        .map(str::trim)
        .find(|v| !v.is_empty())
        .unwrap_or_default();
    // It goes into a form body, where a stray newline would be encoded rather
    // than injected — but an ID with whitespace in it is a copy-paste
    // accident, and a clear error beats GitHub's generic refusal.
    if id.chars().any(|c| c.is_whitespace() || c.is_control()) {
        return Err(AppError::usage(format!(
            "client ID {id:?} must not contain whitespace or control characters"
        )));
    }
    Ok(id.to_string())
}

/// Resolve the scope to ask for: `--scope` > `GITPIC_SCOPE` > [`DEFAULT_SCOPE`].
///
/// Same precedence and the same blank-is-unset rule as [`client_id`], so a
/// `GITPIC_SCOPE=` left in a shell profile behaves like "not set" rather than
/// requesting nothing — which is the one value that produces a token that cannot
/// upload.
pub fn scope(flag: Option<&str>) -> String {
    if let Some(v) = flag.map(str::trim).filter(|v| !v.is_empty()) {
        return v.to_string();
    }
    if let Some(v) = std::env::var("GITPIC_SCOPE")
        .ok()
        .map(|v| v.trim().to_string())
        .filter(|v| !v.is_empty())
    {
        return v;
    }
    DEFAULT_SCOPE.to_string()
}

fn http_client() -> Result<reqwest::Client> {
    reqwest::Client::builder()
        .user_agent(UA)
        .timeout(REQUEST_TIMEOUT)
        .connect_timeout(CONNECT_TIMEOUT)
        .build()
        .map_err(|e| AppError::network(format!("http client: {e}")))
}

/// POST a form to `url` and parse the JSON body, whatever the status.
///
/// Both endpoints report protocol errors *in the body*, and not always with a
/// failing status: `authorization_pending` is a 200. So the status is not what
/// decides here — [`refuse`] reads the body. A status is consulted only when the
/// body did not parse at all.
///
/// **No response body is ever quoted, at either endpoint.** At `TOKEN_URL` a
/// successful body *is* the grant, and it is JSON only because of the `Accept` header
/// below: GitHub's default there is form-encoded (`access_token=ghu_…`), so any proxy
/// that drops or rewrites `Accept` turns a success into a parse failure, and quoting
/// would print the token to stderr and into the scrollback. `DEVICE_CODE_URL` used to
/// be treated as the safe case on the grounds that "nothing in a response is a
/// credential" — but its body carries the `device_code`, which [`Device`]'s
/// hand-written `Debug` twenty lines up redacts precisely because it "is what
/// authorises fetching the token". Two comments in one file disagreeing about whether
/// a value is secret is how a secret gets printed, so the question is now settled the
/// same way in both places.
///
/// `what` names the endpoint for the message instead. The status and content-type are
/// what a captive portal or a gateway page needs to be explicable — `content-type
/// text/html` says it — and neither can carry a credential.
async fn post(
    client: &reqwest::Client,
    url: &str,
    form: &[(&str, &str)],
    what: &str,
) -> Result<Body> {
    let resp = client
        .post(url)
        .header("Accept", "application/json")
        .form(form)
        .send()
        .await
        .map_err(|e| AppError::network(format!("network: {e}")))?;
    let status = resp.status();
    // Read before the body is consumed; with the body itself never quoted, this is
    // the one hint about *why* an unreadable response was unreadable.
    let content_type = resp
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("none")
        .to_string();
    let text = resp
        .text()
        .await
        .map_err(|e| AppError::network(format!("read response: {e}")))?;
    serde_json::from_str(&text).map_err(|e| {
        // A 5xx is a gateway having a bad minute, not a protocol answer, so it gets
        // the code the poll loop retries on. Without this an HTML 502 during a
        // fifteen-minute wait threw the whole login away — the exact failure
        // `MAX_CONSECUTIVE_NETWORK_FAULTS` exists to prevent, arriving as `Ok` from
        // `send()` and so never counted as a fault.
        let classify = if status.is_server_error() {
            AppError::network
        } else {
            AppError::general
        };
        classify(format!(
            "GitHub sent an unreadable {what} response ({status}, content-type \
             {content_type}): {e}"
        ))
    })
}

/// Turn a documented device-flow error into gitpic's error vocabulary.
///
/// The code matters as much as the message: agents branch on it. `access_denied`
/// and `expired_token` are ordinary authentication outcomes and get
/// `AUTH_FAILED`, whose documented remedy — log in again — is exactly right.
/// Everything else here is a one-time misconfiguration of the *app*, which
/// neither a retry nor a re-login can fix, so it stays `GENERAL` rather than
/// borrowing a code whose published remedy would send an agent in a loop.
fn refuse(error: &str, description: Option<&str>) -> AppError {
    let detail = description.map(|d| format!(": {d}")).unwrap_or_default();
    match error {
        "access_denied" => AppError::auth(
            "the login was cancelled in the browser; run `gitpic auth login` to try again"
                .to_string(),
        ),
        "expired_token" => AppError::auth(
            "the login code expired before it was entered; run `gitpic auth login` again"
                .to_string(),
        ),
        "device_flow_disabled" => AppError::general(format!(
            "this GitHub App has the device flow turned off{detail}\n\
             enable \"Device flow\" on the app's settings page (Settings → Developer \
             settings → GitHub Apps → gitpic), then run `gitpic auth login` again"
        )),
        "incorrect_client_credentials" | "unauthorized_client" => AppError::general(format!(
            "GitHub does not recognise this client ID{detail}\n\
             check GITPIC_CLIENT_ID / --client-id, or unset it to use the default app"
        )),
        "incorrect_device_code" => AppError::general(format!(
            "GitHub rejected the device code{detail}; run `gitpic auth login` again"
        )),
        other => AppError::general(format!("GitHub refused the login ({other}){detail}")),
    }
}

/// Read the error out of a body, if it carries one.
fn body_error(body: &Body) -> Option<AppError> {
    let error = body.error.as_deref()?;
    Some(refuse(error, body.error_description.as_deref()))
}

/// Clamp a server-supplied timing to something a human can sit through.
fn interval_from(seconds: Option<u64>) -> Duration {
    Duration::from_secs(seconds.unwrap_or(DEFAULT_INTERVAL).max(1)).min(MAX_INTERVAL)
}

/// The same, for the code's lifetime. See [`MAX_EXPIRES_IN`] for why the ceiling
/// matters more here than for the interval.
fn expires_in_from(seconds: Option<u64>) -> Duration {
    Duration::from_secs(seconds.unwrap_or(DEFAULT_EXPIRES_IN).max(1)).min(MAX_EXPIRES_IN)
}

/// Step one: ask GitHub for a user code.
///
/// `scope` is not optional in practice, whatever the spec allows: an OAuth token with
/// no scope can read public metadata and write nothing, so a login that omits it
/// yields a credential that sails past `/user` and then 404s on every upload.
///
/// GitHub makes that specific bug easy to ship, because it re-issues the
/// *previously granted* scopes when a request names none. An app the user has
/// authorised before therefore keeps working while a first-time authorisation
/// silently does not — the failure appears only on someone else's machine.
pub async fn start(client_id: &str, scope: &str) -> Result<Device> {
    let client = http_client()?;
    let form = [("client_id", client_id), ("scope", scope)];
    // Quotable: a device-code response carries no credential, and an unreadable one
    // is usually a proxy worth showing the user.
    let body = post(&client, DEVICE_CODE_URL, &form, "device-code").await?;
    if let Some(e) = body_error(&body) {
        return Err(e);
    }
    let (Some(device_code), Some(user_code)) = (body.device_code, body.user_code) else {
        return Err(AppError::general(
            "GitHub's device-code response carried neither a code nor an error",
        ));
    };
    Ok(Device {
        device_code,
        user_code,
        // GitHub always sends this; the fallback keeps a missing field from
        // costing the user the one instruction they need.
        verification_uri: body
            .verification_uri
            .unwrap_or_else(|| "https://github.com/login/device".to_string()),
        interval: interval_from(body.interval),
        expires_in: expires_in_from(body.expires_in),
    })
}

/// What one poll of the token endpoint means.
#[derive(Debug, PartialEq, Eq)]
enum Step {
    /// The user has authorised; stop polling.
    Granted,
    /// Nothing yet — poll again on the same interval.
    Pending,
    /// Polling too fast — widen the interval, then poll again.
    SlowDown,
}

/// Classify one token response, without deciding what to do about it.
///
/// Split from the loop because this is where the protocol lives and the loop is
/// only timers: every branch below is reachable in a unit test, while a real
/// round of polling is not.
fn classify(body: &Body) -> Result<Step> {
    if let Some(error) = body.error.as_deref() {
        return match error {
            "authorization_pending" => Ok(Step::Pending),
            "slow_down" => Ok(Step::SlowDown),
            _ => Err(refuse(error, body.error_description.as_deref())),
        };
    }
    if body.access_token.is_some() {
        return Ok(Step::Granted);
    }
    Err(AppError::general(
        "GitHub's token response carried neither a token nor an error",
    ))
}

/// Whether a failed poll should be retried rather than ending the login.
///
/// `NETWORK` is the only transient code, and since [`post`] now maps a 5xx onto it,
/// that covers both a dropped connection and a gateway page. Everything else is an
/// answer that will not change on the next poll.
fn tolerate(error: &AppError, faults: u32) -> bool {
    error.code == crate::error::ErrorCode::Network && faults < MAX_CONSECUTIVE_NETWORK_FAULTS
}

/// Step two: poll until the user finishes in the browser.
///
/// Returns `AUTH_FAILED` when the code expires or the user declines, and
/// `NETWORK` when the network stays down for [`MAX_CONSECUTIVE_NETWORK_FAULTS`]
/// polls in a row.
pub async fn wait_for_token(client_id: &str, device: &Device) -> Result<Granted> {
    let client = http_client()?;
    let form = [
        ("client_id", client_id),
        ("device_code", device.device_code.as_str()),
        ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
    ];
    let mut interval = device.interval;
    let mut faults = 0;
    // Elapsed against a start, rather than a precomputed deadline: `Instant + Duration`
    // panics on overflow, and a panic exits 134 under `panic = "abort"` — outside the
    // documented 1-10 contract. `expires_in_from` already clamps the input, so this is
    // the second of two locks on the same door.
    //
    // GitHub starts its clock when it issues the code, so the budget is the user's,
    // not ours: it must not be extended by a slow poll or a retry.
    let started = Instant::now();

    loop {
        // Before the first poll, deliberately: the user has not had time to type
        // anything, and an immediate poll only spends part of the rate budget on
        // an answer that is certain to be `authorization_pending`.
        tokio::time::sleep(interval).await;
        if started.elapsed() >= device.expires_in {
            return Err(AppError::auth(
                "the login code expired before it was entered; run `gitpic auth login` again",
            ));
        }

        // Not quotable: this response body is the grant.
        let body = match post(&client, TOKEN_URL, &form, "token").await {
            Ok(body) => {
                faults = 0;
                body
            }
            Err(e) => {
                faults += 1;
                if !tolerate(&e, faults) {
                    return Err(e);
                }
                continue;
            }
        };

        match classify(&body)? {
            Step::Granted => {
                return Ok(Granted {
                    // `classify` returning `Granted` is what proves this is here.
                    access_token: body.access_token.unwrap_or_default(),
                    expires_in: body.expires_in,
                });
            }
            Step::Pending => {}
            Step::SlowDown => interval = (interval + SLOW_DOWN_STEP).min(MAX_INTERVAL),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::error::ErrorCode;

    fn body(json: &str) -> Body {
        serde_json::from_str(json).expect("test body parses")
    }

    #[test]
    fn the_default_client_id_is_used_when_nothing_overrides_it() {
        // Not `std::env::set_var`: these tests share a process with every other
        // one, and the flag path is what the CLI actually threads through.
        assert_eq!(client_id(Some("Ov23liOther")).unwrap(), "Ov23liOther");
        assert_eq!(client_id(Some("  ")).unwrap(), DEFAULT_CLIENT_ID);
        assert!(!DEFAULT_CLIENT_ID.is_empty());
    }

    #[test]
    fn the_default_scope_is_the_narrowest_one_that_can_upload() {
        // `public_repo`, not `repo`: the second is read/write on every repository the
        // user can reach, and an image host that jsDelivr can serve is public anyway.
        assert_eq!(scope(None), DEFAULT_SCOPE);
        assert_eq!(scope(Some("repo")), "repo");
        // Blank behaves as unset. An empty scope is the one value that yields a token
        // which authenticates and then cannot write.
        assert_eq!(scope(Some("   ")), DEFAULT_SCOPE);
        assert!(!DEFAULT_SCOPE.is_empty());
    }

    #[test]
    fn a_client_id_with_whitespace_in_it_is_a_usage_error() {
        // A paste that swallowed a newline, which would otherwise reach GitHub
        // form-encoded and come back as an opaque refusal.
        assert_eq!(
            client_id(Some("Ov23li abc")).unwrap_err().code,
            ErrorCode::Usage
        );
    }

    #[test]
    fn pending_and_slow_down_keep_the_loop_going() {
        assert_eq!(
            classify(&body(r#"{"error":"authorization_pending"}"#)).unwrap(),
            Step::Pending
        );
        assert_eq!(
            classify(&body(r#"{"error":"slow_down","interval":10}"#)).unwrap(),
            Step::SlowDown
        );
    }

    #[test]
    fn a_granted_token_ends_the_loop() {
        let b = body(r#"{"access_token":"ghu_x","token_type":"bearer","scope":""}"#);
        assert_eq!(classify(&b).unwrap(), Step::Granted);
        assert_eq!(b.access_token.as_deref(), Some("ghu_x"));
        // An unknown field — `token_type` here — must not fail the parse: this
        // struct is deliberately not `deny_unknown_fields`, because GitHub adding
        // a field to its own response is not gitpic's error to report.
    }

    #[test]
    fn an_expiring_token_reports_what_it_knows_and_drops_what_it_cannot_use() {
        let b = body(
            r#"{"access_token":"ghu_x","expires_in":28800,
                "refresh_token":"ghr_y","refresh_token_expires_in":15811200}"#,
        );
        assert_eq!(classify(&b).unwrap(), Step::Granted);
        assert_eq!(b.expires_in, Some(28800));
        // The refresh token parses to nothing: gitpic cannot spend one without the
        // app's client secret, so the alternative to dropping it is storing a
        // six-month secret for a capability it does not have.
        let json = serde_json::to_string(&serde_json::json!({"refresh_token": "ghr_y"}))
            .expect("serialises");
        let dropped: Body = serde_json::from_str(&json).expect("parses");
        assert!(dropped.access_token.is_none());
    }

    #[test]
    fn a_transient_fault_is_retried_and_a_protocol_answer_is_not() {
        // The 5xx that used to throw away a fifteen-minute wait: `post` gives it
        // NETWORK, and only NETWORK is retried.
        let transient = AppError::network("502 gateway");
        assert!(tolerate(&transient, 1));
        assert!(tolerate(&transient, 2));
        // Two absorbed, the third gives up — otherwise an offline machine polls a
        // dead network until the code expires.
        assert!(!tolerate(&transient, MAX_CONSECUTIVE_NETWORK_FAULTS));
        // A malformed 200 will be malformed again; retrying only delays the report.
        assert!(!tolerate(&AppError::general("garbage"), 1));
    }

    #[test]
    fn a_code_lifetime_cannot_outlast_the_user() {
        assert_eq!(
            expires_in_from(None),
            Duration::from_secs(DEFAULT_EXPIRES_IN)
        );
        assert_eq!(expires_in_from(Some(900)), Duration::from_secs(900));
        assert_eq!(expires_in_from(Some(0)), Duration::from_secs(1));
        // `u64::MAX` used to reach `Instant + Duration`, which panics — exit 134,
        // outside the documented 1-10 contract.
        assert_eq!(expires_in_from(Some(u64::MAX)), MAX_EXPIRES_IN);
    }

    #[test]
    fn a_cancelled_or_expired_login_is_auth_failed() {
        // The two outcomes whose remedy really is "log in again", so they get the
        // code whose documented remedy says that.
        for e in ["access_denied", "expired_token"] {
            let err = classify(&body(&format!(r#"{{"error":"{e}"}}"#))).expect_err("must fail");
            assert_eq!(err.code, ErrorCode::AuthFailed, "{e}: {}", err.message);
            assert!(
                err.message.contains("gitpic auth login"),
                "{e} must name its remedy: {}",
                err.message
            );
        }
    }

    #[test]
    fn a_disabled_device_flow_says_which_switch_to_flip() {
        // The first wall a freshly created GitHub App hits, and unfixable by any
        // retry — so it must not be reported with a code whose published remedy
        // is "log in again".
        let err = classify(&body(r#"{"error":"device_flow_disabled"}"#)).expect_err("must fail");
        assert_eq!(err.code, ErrorCode::General);
        assert!(err.message.contains("Device flow"), "{}", err.message);
    }

    #[test]
    fn a_wrong_client_id_points_at_the_override_that_set_it() {
        let err =
            classify(&body(r#"{"error":"incorrect_client_credentials"}"#)).expect_err("must fail");
        assert!(err.message.contains("GITPIC_CLIENT_ID"), "{}", err.message);
    }

    #[test]
    fn an_unknown_error_still_carries_githubs_own_words() {
        let err = classify(&body(
            r#"{"error":"something_new","error_description":"try later"}"#,
        ))
        .expect_err("must fail");
        assert_eq!(err.code, ErrorCode::General);
        assert!(err.message.contains("something_new"), "{}", err.message);
        assert!(err.message.contains("try later"), "{}", err.message);
    }

    #[test]
    fn a_response_that_says_nothing_is_an_error_not_a_hang() {
        // `{}` used to fall through `access_token.is_some()` and poll forever.
        assert_eq!(classify(&body("{}")).unwrap_err().code, ErrorCode::General);
    }

    #[test]
    fn a_server_supplied_interval_cannot_park_the_cli() {
        assert_eq!(interval_from(None), Duration::from_secs(DEFAULT_INTERVAL));
        assert_eq!(interval_from(Some(10)), Duration::from_secs(10));
        // Zero would busy-poll; a day would be indistinguishable from a hang.
        assert_eq!(interval_from(Some(0)), Duration::from_secs(1));
        assert_eq!(interval_from(Some(86_400)), MAX_INTERVAL);
    }

    #[test]
    fn the_device_endpoints_are_compile_time_constants() {
        // Every request here carries a client ID and, on the way back, a token.
        // Neither URL may become influenceable by the environment.
        assert!(DEVICE_CODE_URL.starts_with("https://github.com/"));
        assert!(TOKEN_URL.starts_with("https://github.com/"));
    }
}
