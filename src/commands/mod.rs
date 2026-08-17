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
use crate::error::{AppError, Result};
use crate::github::PutOutcome;
use crate::imageproc::CompressOpts;
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
        .map_err(|e| AppError::general(format!("read input: {e}")))?;
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

/// Resolve the effective compression settings.
///
/// The one resolver with a non-trivial precedence rule: `--no-compress` wins over
/// both `--compress` and `upload.compress`, so the flag can disable compression
/// that the config enables. A flipped operator here would silently turn
/// compression off for everyone, which is why it lives next to its siblings with
/// a test rather than inline in `upload::run`.
pub fn resolve_compress(cli: &Cli, cfg: &Config) -> CompressOpts {
    CompressOpts {
        enabled: (cfg.upload.compress || cli.compress) && !cli.no_compress,
        max_width: cli.max_width.unwrap_or(cfg.upload.max_width),
        quality: cli.quality.unwrap_or(cfg.upload.quality),
    }
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

#[cfg(test)]
mod tests {
    use super::*;
    use clap::Parser;

    fn parse(args: &[&str]) -> Cli {
        Cli::try_parse_from(args).expect("valid args")
    }

    #[test]
    fn no_compress_overrides_the_compress_flag() {
        let cli = parse(&["gitpic", "a.png", "--compress", "--no-compress"]);
        assert!(!resolve_compress(&cli, &Config::default()).enabled);
    }

    #[test]
    fn no_compress_overrides_the_config() {
        // The documented rule: the flag can disable what the config enables.
        let mut cfg = Config::default();
        cfg.upload.compress = true;
        let cli = parse(&["gitpic", "a.png", "--no-compress"]);
        assert!(!resolve_compress(&cli, &cfg).enabled);
    }

    #[test]
    fn either_the_flag_or_the_config_enables_compression() {
        let mut cfg = Config::default();
        assert!(resolve_compress(&parse(&["gitpic", "a.png", "--compress"]), &cfg).enabled);
        cfg.upload.compress = true;
        assert!(resolve_compress(&parse(&["gitpic", "a.png"]), &cfg).enabled);
    }

    #[test]
    fn cli_sizing_overrides_the_config_but_falls_back_to_it() {
        let mut cfg = Config::default();
        cfg.upload.max_width = 100;
        cfg.upload.quality = 50;
        let overridden = resolve_compress(
            &parse(&["gitpic", "a.png", "--max-width", "800", "--quality", "90"]),
            &cfg,
        );
        assert_eq!((overridden.max_width, overridden.quality), (800, 90));
        let inherited = resolve_compress(&parse(&["gitpic", "a.png"]), &cfg);
        assert_eq!((inherited.max_width, inherited.quality), (100, 50));
    }
}
