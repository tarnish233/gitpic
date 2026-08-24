//! `gitpic update check` — is there a newer gitpic, and what changed?
//!
//! The comparison and the request live in [`crate::release`]; this is the rendering.
//!
//! **Config-free**, like `auth` and `list`: nothing here reads `config.toml` or the
//! credential, because "is there a new version" is a question worth answering on a machine
//! whose config is missing or broken — including one where the answer is that the fix
//! shipped in a release the user does not have yet.
//!
//! It checks, and it does not install. The app is distributed as a Homebrew cask and is
//! signed ad-hoc rather than with a Developer ID (see `scripts/build-app.sh`), so a
//! self-replacing updater would both fight Homebrew's manifest and have no signature chain
//! to verify a download against. `GitPic.app` runs `brew upgrade` instead; the CLI's job is
//! to report, and the human-readable output says how to upgrade rather than doing it.

use crate::error::Result;
use crate::output::Mode;
use crate::release::UpdateReport;

pub async fn run(mode: Mode) -> Result<u8> {
    let report = crate::release::check().await?;

    if mode.is_json() {
        crate::output::print_json(&report);
        return Ok(0);
    }
    if mode.is_quiet() {
        // One line, machine-readable-ish: the version if there is one to move to, and
        // nothing at all otherwise. `-q` output is what a script reads, so "up to date"
        // must not be a string it has to match on.
        if report.update_available {
            crate::output::line(&report.latest);
        }
        return Ok(0);
    }

    human(&report);
    Ok(0)
}

fn human(report: &UpdateReport) {
    if report.update_available {
        crate::output::line(&format!(
            "{} → {}   (current → latest)",
            report.current, report.latest
        ));
        if let Some(name) = &report.name {
            crate::output::line("");
            crate::output::line(name);
        }
        let notes = report.summary();
        if !notes.is_empty() {
            crate::output::line("");
            // Verbatim, indented — but the *summary*, not the raw body. The notes are
            // Markdown written for GitHub and reformatting them here would be a second
            // renderer to keep in step with however the release is actually written; what
            // `summary()` takes out is structure rather than wording — the `## ` install
            // appendix aimed at someone who downloaded the DMG, and the theme line already
            // printed just above as the release name. It is the same rule the app's update
            // sheet applies. Printing `notes` was the version that only claimed to.
            for line in notes.lines() {
                crate::output::line(&format!("  {line}"));
            }
        }
        crate::output::line("");
        crate::output::line(&report.url);
        // Both paths, because the cask and the formula are different installs and
        // `brew upgrade` on the wrong one reports "no available formula".
        crate::output::note(
            "upgrade with `brew upgrade --cask gitpic` (app) or \
             `brew upgrade gitpic_cli` (CLI only)",
        );
        return;
    }
    if report.ahead {
        // An unreleased local build, which is the state this repository's own working copy
        // is in between releases. Saying "up to date" here would be wrong in the direction
        // that matters least but confuses most.
        crate::output::line(&format!(
            "{} is newer than the latest release ({}) — this is an unreleased build",
            report.current, report.latest
        ));
        return;
    }
    crate::output::line(&format!("{} is the latest release", report.current));
}
