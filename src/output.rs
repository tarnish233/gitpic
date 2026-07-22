//! Output rendering: human-friendly vs stable JSON schema for agents.

use owo_colors::OwoColorize;
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
                let tag = if r.deduped { " (deduped)".yellow().to_string() } else { String::new() };
                println!("{} {}{}", "✓ uploaded".green().bold(), r.name.bold(), tag);
                println!("{}", r.output);
            }
        }
    }
}

/// Print an error according to the mode (JSON to stdout, human to stderr).
pub fn print_error(mode: Mode, code: &str, message: &str) {
    if mode.is_json() {
        let env = ErrorEnvelope {
            ok: false,
            error: ErrorBody { code: code.to_string(), message: message.to_string() },
        };
        println!("{}", serde_json::to_string_pretty(&env).unwrap_or_default());
    } else {
        eprintln!("{} {}", "error:".red().bold(), message);
    }
}
