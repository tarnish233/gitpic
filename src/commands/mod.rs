//! Subcommand implementations.

pub mod completion;
pub mod config_cmd;
pub mod doctor;
pub mod init;
pub mod list;
pub mod skill;
pub mod upload;

use crate::cli::{Cli, LinkKind, OutputFormat};
use crate::config::Config;
use crate::error::{AppError, ErrorCode, Result};
use crate::github::PutOutcome;
use crate::link;
use crate::output::ItemResult;
use std::io::{self, Write};

/// Prompt on stdout and read a line from stdin. Returns `None` on EOF
/// (Ctrl-D / closed stdin), which callers must not confuse with an empty
/// reply — for a write action EOF means "abort", not "take the default".
pub(crate) fn prompt_opt(label: &str, default: &str) -> Result<Option<String>> {
    if default.is_empty() {
        print!("{label}: ");
    } else {
        print!("{label} [{default}]: ");
    }
    io::stdout().flush().ok();
    let mut line = String::new();
    let read = io::stdin()
        .read_line(&mut line)
        .map_err(|e| AppError::new(ErrorCode::General, format!("read input: {e}")))?;
    if read == 0 {
        return Ok(None);
    }
    let v = line.trim();
    if v.is_empty() {
        Ok(Some(default.to_string()))
    } else {
        Ok(Some(v.to_string()))
    }
}

/// Prompt, treating EOF as the default. Suitable for `init`, where EOF on a
/// field just means "keep what is already configured".
pub(crate) fn prompt(label: &str, default: &str) -> Result<String> {
    Ok(prompt_opt(label, default)?.unwrap_or_else(|| default.to_string()))
}

/// An image ready to upload.
pub struct InputImage {
    pub name: String,
    pub bytes: Vec<u8>,
}

/// Resolve the effective link kind from CLI flag or config.
pub fn resolve_link_kind(cli: &Cli, cfg: &Config) -> LinkKind {
    cli.link
        .unwrap_or_else(|| link::parse_link_kind(&cfg.upload.link_kind))
}

/// Resolve the effective path template.
pub fn resolve_template<'a>(cli: &'a Cli, cfg: &'a Config) -> &'a str {
    cli.path.as_deref().unwrap_or(&cfg.upload.path_template)
}

/// Build the JSON/human result record from an upload outcome.
pub fn build_item(
    outcome: &PutOutcome,
    name: &str,
    kind: LinkKind,
    format: OutputFormat,
    owner: &str,
    repo: &str,
    branch: &str,
) -> ItemResult {
    let alt = crate::naming::alt_text(name);
    let url = link::url_for(kind, owner, repo, branch, &outcome.path);
    let raw_url = link::raw_url(owner, repo, branch, &outcome.path);
    let markdown = link::markdown(&alt, &url);
    let html = link::html(&alt, &url);
    let output = link::render(format, &alt, &url);
    ItemResult {
        name: alt,
        url,
        raw_url,
        markdown,
        html,
        path: outcome.path.clone(),
        sha: outcome.content_sha.clone(),
        size: outcome.size,
        deduped: outcome.deduped,
        output,
    }
}
