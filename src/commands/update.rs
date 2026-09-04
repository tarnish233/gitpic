//! `gitpic update check` — is there a newer gitpic, and what changed?
//!
//! The comparison and the request live in [`crate::release`]; this is the rendering.
//!
//! **Config-free, and that is not the same as credential-free.** Nothing here reads
//! `config.toml`, because "is there a new version" is a question worth answering on a machine
//! whose config is missing or broken — including one where the answer is that the fix shipped
//! in a release the user does not have yet. It does reach for `auth.toml`:
//! `release::best_effort_token` attaches a credential when one exists, because
//! `api.github.com` allows 60 anonymous requests an hour *per address* and behind a shared
//! egress that budget belongs to everyone behind it. Absent or rejected, the request goes
//! anonymously and still works — see `release`'s header for the measurement. The claim used
//! to read "nothing here reads `config.toml` or the credential", which the second half made
//! false.
//!
//! It checks, and it does not install. That is a statement about *this binary*: the embedded
//! command follows its app's in-app updater, a cargo-installed command uses Cargo, and an
//! unpacked binary has no safe installation mechanism to infer. [`crate::install_source`]
//! distinguishes those shapes and prints one applicable next step instead of guessing.

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
        // One instruction, for the install this binary actually came from.
        crate::output::note(&crate::install_source::detect().upgrade_hint());
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
