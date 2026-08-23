//! `gitpic branches` — which branches the configured repository has.
//!
//! The branch half of [`crate::commands::repos`], and it exists for the same reason: the
//! Contents API writes into an *existing* ref and will not create one, so a branch that
//! is not in this list cannot receive an upload. GitHub answers 404 for a ref it cannot
//! find, which is indistinguishable from a missing repository — so a typed branch name
//! fails in the one way that says nothing about what went wrong.
//!
//! Unlike `repos`, this one needs a target: branches belong to a repository. `--repo`
//! and `GITPIC_REPO` therefore both work here, which is what lets someone check a
//! repository before configuring it.

use crate::config::Config;
use crate::error::Result;
use crate::github::{BranchCandidate, GitHub};
use crate::output::Mode;
use owo_colors::{OwoColorize, Stream};
use serde::Serialize;

#[derive(Serialize)]
struct BranchesReport<'a> {
    ok: bool,
    /// `owner/name` the list belongs to, so a caller that passed `--repo` can confirm
    /// which repository answered.
    repo: String,
    /// The branch currently configured. Present even when it is not in `branches` —
    /// that mismatch is the state worth reporting, not one worth hiding.
    configured: &'a str,
    branches: &'a [BranchCandidate],
    /// False when the listing hit its page ceiling.
    complete: bool,
}

pub async fn run(cfg: &Config, mode: Mode) -> Result<u8> {
    cfg.require_target()?;
    let token = crate::auth::token()?;
    let gh = GitHub::new(
        &token,
        &cfg.github.owner,
        &cfg.github.repo,
        &cfg.github.branch,
    )?;
    let (branches, complete) = gh.branch_candidates().await?;
    let spec = format!("{}/{}", cfg.github.owner, cfg.github.repo);

    if mode.is_json() {
        crate::output::print_json(&BranchesReport {
            ok: true,
            repo: spec,
            configured: &cfg.github.branch,
            branches: &branches,
            complete,
        });
        return Ok(0);
    }

    if branches.is_empty() {
        // Real and recoverable: a repository with no commits has no branches, and an
        // upload to it creates the ref. Not an error, so not reported as one.
        if !mode.is_quiet() {
            crate::output::line(&format!(
                "{spec} has no branches yet — it is empty, and the first upload will \
                 create `{}`.",
                cfg.github.branch
            ));
        }
        return Ok(0);
    }

    for b in &branches {
        if mode.is_quiet() {
            crate::output::line(&b.name);
            continue;
        }
        let mut notes = Vec::new();
        // Marked rather than left to be matched by eye: "which one am I using" is the
        // question someone runs this to answer.
        if b.name == cfg.github.branch {
            notes.push("configured".to_string());
        }
        if b.protected {
            notes.push("protected".to_string());
        }
        let marker = if b.name == cfg.github.branch {
            "*"
        } else {
            " "
        };
        if notes.is_empty() {
            crate::output::line(&format!("{marker} {}", b.name));
        } else {
            crate::output::line(&format!("{marker} {}  ({})", b.name, notes.join(", ")));
        }
    }

    // Everything below is commentary, and `-q` exists so a script can read this output:
    // its contract is one branch name per line and nothing else. A `note:` line in that
    // stream is not a stylistic wart, it is a branch name the caller will try to use.
    if !mode.is_quiet() {
        if !branches.iter().any(|b| b.name == cfg.github.branch) {
            // The failure this command exists to make visible: push permission on the
            // repository says nothing about whether the ref an upload targets exists,
            // and GitHub's 404 for a missing ref looks exactly like a missing repository.
            crate::output::note(&format!(
                "`{}` is configured but not in this list, so every upload will fail on a \
                 ref that does not exist — `gitpic config set github.branch <one of the \
                 above>`",
                cfg.github.branch
            ));
        }
        if !complete {
            crate::output::note("more branches exist than were listed");
        }
    }
    if branches.iter().any(|b| b.protected) && !mode.is_quiet() {
        // Kept as its own check rather than folded above: it is about the rows that were
        // printed, not about a problem with the configuration.
        let label = "protected".if_supports_color(Stream::Stdout, |t| t.yellow().to_string());
        crate::output::line(&format!(
            "  ({label} does not mean unwritable — the rules may permit this account; it \
             is the usual cause of a 409/422 when every other check passed)"
        ));
    }
    Ok(0)
}
