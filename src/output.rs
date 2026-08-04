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

/// Print successful upload results according to the mode.
pub fn print_results(mode: Mode, results: &[ItemResult]) {
    match mode {
        Mode::Json => {
            let env = SuccessEnvelope { ok: true, results };
            println!("{}", serde_json::to_string_pretty(&env).unwrap_or_default());
        }
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
    let error = ErrorBody {
        code: code.to_string(),
        message: message.to_string(),
    };
    match mode {
        Mode::Json => {
            let env = PartialEnvelope {
                ok: false,
                results,
                error,
            };
            println!("{}", serde_json::to_string_pretty(&env).unwrap_or_default());
        }
        Mode::Quiet => {
            for r in results {
                println!("{}", r.output);
            }
            eprint_error_label(message);
        }
        Mode::Human => {
            for r in results {
                print_human_item(r);
            }
            eprint_error_label(message);
        }
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
        let env = ErrorEnvelope {
            ok: false,
            error: ErrorBody {
                code: code.to_string(),
                message: message.to_string(),
            },
        };
        println!("{}", serde_json::to_string_pretty(&env).unwrap_or_default());
    } else {
        eprint_error_label(message);
    }
}
