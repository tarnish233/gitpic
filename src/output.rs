//! Output rendering: human-friendly vs stable JSON schema for agents.

use owo_colors::{OwoColorize, Stream};
use serde::Serialize;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    Human,
    Quiet,
    Json,
}

impl Mode {
    pub fn from_flags(json: bool, quiet: bool) -> Self {
        if json {
            Mode::Json
        } else if quiet {
            Mode::Quiet
        } else {
            Mode::Human
        }
    }
    pub fn is_json(self) -> bool {
        matches!(self, Mode::Json)
    }
}

/// One uploaded image result (stable JSON schema).
#[derive(Debug, Serialize)]
pub struct ItemResult {
    pub name: String,
    pub url: String,
    pub raw_url: String,
    pub markdown: String,
    pub html: String,
    pub path: String,
    pub sha: String,
    pub size: usize,
    pub deduped: bool,
    /// The chosen output snippet according to --format
    pub output: String,
}

#[derive(Debug, Serialize)]
pub struct SuccessEnvelope<'a> {
    pub ok: bool,
    pub results: &'a [ItemResult],
}

#[derive(Debug, Serialize)]
pub struct ErrorBody {
    pub code: String,
    pub message: String,
}

impl ErrorBody {
    pub fn new(code: &str, message: &str) -> Self {
        Self {
            code: code.to_string(),
            message: message.to_string(),
        }
    }
}

#[derive(Debug, Serialize)]
pub struct ErrorEnvelope {
    pub ok: bool,
    pub error: ErrorBody,
}

/// Envelope for a run where some inputs uploaded and a later one failed.
/// `ok` is false, but `results` still carries every live link.
#[derive(Debug, Serialize)]
pub struct PartialEnvelope<'a> {
    pub ok: bool,
    pub results: &'a [ItemResult],
    pub error: ErrorBody,
}

/// Print a value as pretty JSON on stdout. Every `--json` envelope in the crate
/// goes through here, so the shape and the formatting stay in one place.
pub fn print_json<T: Serialize>(value: &T) {
    println!(
        "{}",
        serde_json::to_string_pretty(value).unwrap_or_default()
    );
}

/// Print successful upload results according to the mode.
pub fn print_results(mode: Mode, results: &[ItemResult]) {
    match mode {
        Mode::Json => print_json(&SuccessEnvelope { ok: true, results }),
        Mode::Quiet => {
            for r in results {
                println!("{}", r.output);
            }
        }
        Mode::Human => {
            for r in results {
                print_human_item(r);
            }
        }
    }
}

fn print_human_item(r: &ItemResult) {
    let check = "✓ uploaded".if_supports_color(Stream::Stdout, |t| t.green().bold().to_string());
    let name = r
        .name
        .if_supports_color(Stream::Stdout, |t| t.bold().to_string());
    if r.deduped {
        let tag = " (deduped)".if_supports_color(Stream::Stdout, |t| t.yellow().to_string());
        println!("{check} {name}{tag}");
    } else {
        println!("{check} {name}");
    }
    println!("{}", r.output);
}

/// Print results that succeeded before a failure, followed by the error.
/// Successful links are never dropped just because a later input failed.
pub fn print_partial(mode: Mode, results: &[ItemResult], code: &str, message: &str) {
    if mode.is_json() {
        print_json(&PartialEnvelope {
            ok: false,
            results,
            error: ErrorBody::new(code, message),
        });
    } else {
        // Quiet and Human render the successful items exactly as a clean run
        // does, then append the error on stderr.
        print_results(mode, results);
        eprint_error_label(message);
    }
}

/// Write `error: <message>` to stderr, coloured only when stderr is a terminal.
fn eprint_error_label(message: &str) {
    let label = "error:".if_supports_color(Stream::Stderr, |t| t.red().bold().to_string());
    eprintln!("{label} {message}");
}

/// Print an error according to the mode (JSON to stdout, human to stderr).
pub fn print_error(mode: Mode, code: &str, message: &str) {
    if mode.is_json() {
        print_json(&ErrorEnvelope {
            ok: false,
            error: ErrorBody::new(code, message),
        });
    } else {
        eprint_error_label(message);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(name: &str) -> ItemResult {
        ItemResult {
            name: name.to_string(),
            url: "u".into(),
            raw_url: "r".into(),
            markdown: "m".into(),
            html: "h".into(),
            path: "p".into(),
            sha: "s".into(),
            size: 1,
            deduped: false,
            output: "o".into(),
        }
    }

    #[test]
    fn success_envelope_has_ok_true_and_no_error_key() {
        let results = [item("one")];
        let json = serde_json::to_string(&SuccessEnvelope {
            ok: true,
            results: &results,
        })
        .unwrap();
        assert!(json.contains(r#""ok":true"#));
        assert!(!json.contains(r#""error""#));
    }

    #[test]
    fn error_envelope_has_no_results_key() {
        // Agents distinguish a total failure from a partial one by the presence
        // of `results`, so a plain error must not carry an empty array.
        let json = serde_json::to_string(&ErrorEnvelope {
            ok: false,
            error: ErrorBody {
                code: "AUTH_FAILED".into(),
                message: "nope".into(),
            },
        })
        .unwrap();
        assert!(json.contains(r#""ok":false"#));
        assert!(
            !json.contains(r#""results""#),
            "plain errors must omit results: {json}"
        );
    }

    #[test]
    fn partial_envelope_carries_both_results_and_error() {
        let results = [item("one")];
        let json = serde_json::to_string(&PartialEnvelope {
            ok: false,
            results: &results,
            error: ErrorBody {
                code: "RATE_LIMITED".into(),
                message: "slow down".into(),
            },
        })
        .unwrap();
        assert!(json.contains(r#""ok":false"#));
        assert!(json.contains(r#""name":"one""#));
        assert!(json.contains(r#""code":"RATE_LIMITED""#));
    }
}
