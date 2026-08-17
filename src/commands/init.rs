//! Interactive configuration setup.

use super::prompt;
use crate::config::Config;
use crate::error::{AppError, Result};

pub fn run() -> Result<()> {
    let mut cfg = Config::load()?;

    println!("gitpic init — configure your GitHub image host\n");

    let token_label = if cfg.github.token.is_empty() {
        "GitHub token (leave blank to use `gh auth token`)"
    } else {
        "GitHub token (leave blank to keep the configured token)"
    };
    let token = prompt(token_label, "")?;
    let repo_spec = {
        let cur = if cfg.github.owner.is_empty() {
            String::new()
        } else {
            format!("{}/{}", cfg.github.owner, cfg.github.repo)
        };
        prompt("Target repo (owner/name)", &cur)?
    };
    let branch = prompt("Branch", &cfg.github.branch)?;
    let link = prompt("Link kind (cdn|raw)", &cfg.upload.link_kind)?;

    if !token.is_empty() {
        cfg.github.token = token;
    }
    cfg.set_repo_spec(&repo_spec)?;
    cfg.github.branch = if branch.is_empty() {
        "main".into()
    } else {
        branch
    };
    cfg.upload.link_kind = if link.is_empty() {
        "cdn".into()
    } else {
        // Same reason as `config set`: an unvalidated typo here would silently
        // pin the user to cdn links forever.
        crate::link::parse_link_kind_strict(&link)
            .ok_or_else(|| AppError::usage(format!("invalid link kind (cdn|raw): {link}")))?;
        link.trim().to_ascii_lowercase()
    };

    let path = cfg.save()?;
    println!("\n\u{2713} saved config to {}", path.display());
    Ok(())
}
