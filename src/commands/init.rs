//! Interactive configuration setup.

use super::prompt;
use crate::config::Config;
use crate::error::{AppError, Result};

pub fn run() -> Result<()> {
    let mut cfg = Config::load()?;

    crate::output::line("gitpic init — configure your GitHub image host\n");

    crate::output::line("Credentials come from `gh auth token`.");
    crate::output::line("Run `gh auth login` once if you have not already.\n");

    let repo_spec = {
        // Offered whenever *either* half is set, and `require_target` still has to
        // pass before an upload. Deriving this from `owner` alone meant that with
        // an empty owner — which happens when `repo` was set by itself, or the
        // owner comes from GITPIC_OWNER — no default was shown, so pressing Enter
        // returned "" and silently cleared a configured repo.
        let cur = match (cfg.github.owner.as_str(), cfg.github.repo.as_str()) {
            ("", "") => String::new(),
            ("", repo) => repo.to_string(),
            (owner, repo) => format!("{owner}/{repo}"),
        };
        prompt("Target repo (owner/name)", &cur)?
    };
    let branch = prompt("Branch", &cfg.github.branch)?;
    let link = prompt("Link kind (cdn|raw)", &cfg.upload.link_kind)?;

    // An empty answer with nothing configured would otherwise "succeed" while
    // leaving the tool unusable — `set_repo_spec("")` clears the repo and `init`
    // prints a checkmark.
    if repo_spec.trim().is_empty() {
        return Err(AppError::usage(
            "a target repo is required (owner/name, or just the name to keep the current owner)",
        ));
    }
    cfg.set_repo_spec(&repo_spec)?;
    cfg.github.branch = if branch.trim().is_empty() {
        "main".into()
    } else {
        branch
    };
    cfg.upload.link_kind = if link.trim().is_empty() {
        "cdn".into()
    } else {
        // Same reason as `config set`: an unvalidated typo here would silently
        // pin the user to cdn links forever.
        crate::link::parse_link_kind_strict(&link)
            .ok_or_else(|| AppError::usage(format!("invalid link kind (cdn|raw): {link}")))?;
        link.trim().to_ascii_lowercase()
    };

    let path = cfg.save()?;
    crate::output::line(&format!("\n\u{2713} saved config to {}", path.display()));
    Ok(())
}
