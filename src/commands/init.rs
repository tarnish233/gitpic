//! Interactive configuration setup.

use crate::config::Config;
use crate::error::{AppError, ErrorCode, Result};
use std::io::{self, Write};

fn prompt(label: &str, default: &str) -> Result<String> {
    if default.is_empty() {
        print!("{label}: ");
    } else {
        print!("{label} [{default}]: ");
    }
    io::stdout().flush().ok();
    let mut line = String::new();
    io::stdin()
        .read_line(&mut line)
        .map_err(|e| AppError::new(ErrorCode::General, format!("read input: {e}")))?;
    let v = line.trim();
    if v.is_empty() {
        Ok(default.to_string())
    } else {
        Ok(v.to_string())
    }
}

pub fn run() -> Result<()> {
    let mut cfg = Config::load().unwrap_or_default();

    println!("gitpic init — configure your GitHub image host\n");

    let token = prompt(
        "GitHub token (fine-grained, Contents R/W)",
        &cfg.github.token,
    )?;
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

    cfg.github.token = token;
    cfg.set_repo_spec(&repo_spec);
    cfg.github.branch = if branch.is_empty() {
        "main".into()
    } else {
        branch
    };
    cfg.upload.link_kind = if link.is_empty() { "cdn".into() } else { link };

    let path = cfg.save()?;
    println!("\n\u{2713} saved config to {}", path.display());
    Ok(())
}
