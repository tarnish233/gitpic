//! `gitpic repos` — which repositories this credential could upload to.
//!
//! Not quite "what does this user own": the answer is scope-limited, because a
//! `public_repo` token is not shown private repositories at all. The command reports
//! every reachable row for diagnostics; interactive pickers additionally require a
//! public, writable repository, because neither jsDelivr nor a static unauthenticated
//! raw URL can make a private repository into a shareable image host.
//!
//! It is also, in [`choose_target`], the picker itself — the only way a target reaches
//! `config.toml` interactively now that `gitpic init` is gone.

use super::prompt_opt;
use crate::config::Config;
use crate::error::{AppError, Result};
use crate::github::{GitHub, RepoCandidate};
use crate::output::Mode;
use owo_colors::{OwoColorize, Stream};
use serde::Serialize;

/// Reachable two ways, and the message has to cover both: an account with no
/// repositories at all, and — far likelier — a token whose scope hides them.
/// `public_repo` is not shown private repositories, so "empty" and "all private" look
/// identical from here.
const NOTHING_TO_OFFER: &str =
    "no public, writable repositories are available to this credential.\n\
     GitPic links are meant to be opened without a GitHub credential, so private \
     repositories cannot be used as image hosts.";

/// What to do when the list cannot be used: the two routes that take a value directly.
pub(crate) const SET_IT_BY_HAND: &str = "set a public image host with `gitpic config set \
     github.repo owner/name`, or export GITPIC_REPO=owner/name";

/// The caveats worth printing beside a repository's name.
///
/// Both listings need branch-plus-private, and each was building it separately with its
/// own near-identical comment about jsDelivr. `run` appends `read-only` to this; the
/// picker never needs that one, because it only ever lists what can be pushed to. One
/// owner so a fourth caveat — archived, fork, empty — is one edit rather than two, and
/// so the two lists cannot drift again the way they already had.
fn caveats(r: &RepoCandidate) -> Vec<String> {
    let mut notes = vec![format!("branch {}", r.default_branch)];
    if r.private {
        notes.push("private — not usable as a public image host".to_string());
    }
    notes
}

fn can_be_image_host(repo: &RepoCandidate) -> bool {
    repo.can_push && !repo.private
}

#[derive(Serialize)]
struct ReposReport<'a> {
    ok: bool,
    repos: &'a [RepoCandidate],
    /// False when a listing hit its page ceiling. Present either way: a caller that
    /// only ever saw `true` must not have to guess whether a short list is the whole
    /// list.
    complete: bool,
}

pub async fn run(mode: Mode) -> Result<u8> {
    let token = crate::auth::token()?;
    let (repos, complete) = GitHub::for_user(&token)?.repo_candidates().await?;

    if mode.is_json() {
        crate::output::print_json(&ReposReport {
            ok: true,
            repos: &repos,
            complete,
        });
        return Ok(0);
    }

    if repos.is_empty() {
        // Not an error: an authorised app with no repositories granted is a real and
        // recoverable state, and the remedy is on GitHub rather than in gitpic.
        if !mode.is_quiet() {
            crate::output::line(NOTHING_TO_OFFER);
        }
        return Ok(0);
    }

    for r in &repos {
        // `owner/name` first on every line, so the whole output is pasteable into
        // `gitpic config set github.repo …` with nothing to strip.
        let spec = r.spec();
        if mode.is_quiet() {
            crate::output::line(&spec);
            continue;
        }
        let mut notes = caveats(r);
        if !r.can_push {
            notes.push(
                "read-only"
                    .if_supports_color(Stream::Stdout, |t| t.red().to_string())
                    .to_string(),
            );
        }
        crate::output::line(&format!("{spec}  ({})", notes.join(", ")));
    }
    // Same rule as the rows above: `-q` promises one `owner/name` per line, and a
    // `note:` line in that stream is a repository spec the caller will try to use.
    if !complete && !mode.is_quiet() {
        // Only reachable on an account with more repositories than the page ceiling
        // allows, so the way out is a value rather than a longer list.
        crate::output::note(
            "more repositories exist than were listed; if the one you want is missing, \
             `gitpic config set github.repo owner/name` takes it directly",
        );
    }
    Ok(0)
}

// ---------------------------------------------------------------- the picker

/// How many unusable replies to re-ask before giving up.
///
/// A typo deserves another try: the alternative is ending a completed browser login
/// with `USAGE`. An unbounded loop is not the answer either — a stdin that keeps
/// producing the same unparseable line would spin forever — so the retries are counted.
const MAX_TRIES: usize = 3;

/// Offer the writable candidates as a numbered list and save the chosen one.
///
/// The interactive counterpart to [`run`], and what `gitpic auth login` ends with. It
/// replaces `gitpic init`, which asked for `owner/name` as typed text and so invited
/// three failures a list rules out: a misspelling that surfaces as a bare 404, a
/// repository the credential cannot see, and a branch guessed as `main` when GitHub's
/// default is `master`.
///
/// It lives here rather than in [`crate::commands::auth_cmd`] because the rules about
/// which repositories may be offered at all — push access, the private/jsDelivr caveat,
/// a truncated listing — belong to this module, and a second copy of them would drift
/// from the `--json` listing that agents read.
///
/// Returns whether a config was written. Every reason for not writing one is reported
/// from in here, along with what to do instead, because only this function knows which
/// reason applied — and none of them is an error: the caller has just completed a
/// browser login, and a target that could not be offered must not turn that into a
/// failure the user would answer by logging in again.
pub(crate) async fn choose_target(token: &str) -> Result<()> {
    let (all, complete) = GitHub::for_user(token)?.repo_candidates().await?;

    // Only what can actually be uploaded to. A read-only repository in this list would
    // be a choice that cannot work — the "accepted, then silently broken" shape this
    // project refuses everywhere else — but the count is reported rather than swallowed,
    // because "my repository is missing" is the harder question to answer.
    let skipped_read_only = all.iter().filter(|r| !r.can_push).count();
    let skipped_private = all.iter().filter(|r| r.can_push && r.private).count();
    let repos: Vec<RepoCandidate> = all.into_iter().filter(can_be_image_host).collect();
    if repos.is_empty() {
        crate::output::line(NOTHING_TO_OFFER);
        return Ok(());
    }

    let cfg = Config::load()?;
    let current = repos
        .iter()
        .position(|r| r.owner == cfg.github.owner && r.name == cfg.github.repo);

    crate::output::line("which repository should gitpic upload to?\n");
    let width = repos.iter().map(|r| r.spec().len()).max().unwrap_or(0);
    for (i, r) in repos.iter().enumerate() {
        let notes = caveats(r);
        // Marks the one already configured, which is also the default — so a re-login
        // that only meant to widen a scope costs one keystroke instead of a decision.
        let marker = if Some(i) == current { "*" } else { " " };
        crate::output::line(&format!(
            "{marker} [{}] {:width$}  ({})",
            i + 1,
            r.spec(),
            notes.join(", ")
        ));
    }
    if skipped_read_only > 0 {
        crate::output::line(&format!(
            "\n  ({skipped_read_only} more you cannot push to, not listed)"
        ));
    }
    if skipped_private > 0 {
        crate::output::line(&format!(
            "\n  ({skipped_private} private repositories cannot serve public links, not listed)"
        ));
    }
    if !complete {
        crate::output::line("\n  (more repositories exist than were listed)");
    }
    crate::output::line("");

    let default = current.map(|i| (i + 1).to_string()).unwrap_or_default();
    let range = if repos.len() == 1 {
        "1".to_string()
    } else {
        format!("1-{}", repos.len())
    };
    let Some(chosen) = ask(&format!("image host? [{range}]"), &default, repos.len())? else {
        crate::output::line("");
        crate::output::note(SET_IT_BY_HAND);
        return Ok(());
    };
    let repo = &repos[chosen];

    let (_, cfg, path) = Config::update(|cfg| {
        cfg.github.owner = repo.owner.clone();
        cfg.github.repo = repo.name.clone();
        // GitHub's answer, not a guess. Typing this was how a repository whose default
        // is `master` ended up configured for `main`, with every upload then 404ing on
        // a ref that does not exist. The update transaction reloads after acquiring the
        // writer lock, so unrelated settings changed by another process are retained.
        cfg.github.branch = repo.default_branch.clone();
        Ok(())
    })?;

    crate::output::line(&format!(
        "\n{} {} on {} — saved to {}",
        crate::output::tick(),
        repo.spec(),
        cfg.github.branch,
        crate::output::terminal_safe(&path.display().to_string())
    ));
    Ok(())
}

/// Read one choice, re-asking a mistyped reply rather than failing the caller over it.
///
/// `None` means the question went unanswered: EOF, or [`MAX_TRIES`] unusable replies.
/// EOF is an abort and not a default — this writes a config file, and a closed stdin is
/// not a choice. Same rule as `skill install`.
fn ask(label: &str, default: &str, count: usize) -> Result<Option<usize>> {
    for _ in 0..MAX_TRIES {
        // Substitutes `default` for an empty line itself, so Enter keeps the repository
        // already configured and only a *typed* answer can change it.
        let Some(reply) = prompt_opt(label, default)? else {
            return Ok(None);
        };
        match parse_choice(reply.trim(), count) {
            Ok(i) => return Ok(Some(i)),
            // Printed rather than returned: the reply is the user's to fix, and the
            // caller has a credential on disk that this must not jeopardise.
            Err(e) => crate::output::line(&format!("  {}", e.message)),
        }
    }
    Ok(None)
}

/// Read one 1-based choice.
///
/// Split out so the off-by-one and the out-of-range message are testable without a
/// terminal — the two mistakes a numbered prompt actually makes.
fn parse_choice(reply: &str, count: usize) -> Result<usize> {
    let n: usize = reply
        .parse()
        .map_err(|_| AppError::usage(format!("not a number: {reply:?}")))?;
    if n == 0 || n > count {
        return Err(AppError::usage(format!(
            "pick a number between 1 and {count}, not {n}"
        )));
    }
    Ok(n - 1)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::error::ErrorCode;

    #[test]
    fn picker_candidates_must_be_public_and_writable() {
        let candidate = |private, can_push| RepoCandidate {
            owner: "o".to_string(),
            name: "r".to_string(),
            private,
            default_branch: "main".to_string(),
            can_push,
        };
        assert!(can_be_image_host(&candidate(false, true)));
        assert!(!can_be_image_host(&candidate(true, true)));
        assert!(!can_be_image_host(&candidate(false, false)));
    }

    #[test]
    fn a_choice_is_one_based() {
        assert_eq!(parse_choice("1", 3).unwrap(), 0);
        assert_eq!(parse_choice("3", 3).unwrap(), 2);
    }

    #[test]
    fn zero_and_past_the_end_are_refused_by_name() {
        // `0` is the off-by-one a 1-based list invites, and it would index the wrong
        // repository rather than fail if it were let through as `n - 1`.
        for reply in ["0", "4", "99"] {
            let err = parse_choice(reply, 3).expect_err("must fail");
            assert_eq!(err.code, ErrorCode::Usage);
            assert!(err.message.contains("1 and 3"), "{}", err.message);
        }
    }

    #[test]
    fn a_non_number_says_what_it_got() {
        // Typing a repo name is the mistake this prompt invites, since that is what
        // `gitpic init` used to ask for. The message has to show what was typed.
        let err = parse_choice("owner/pics", 3).expect_err("must fail");
        assert_eq!(err.code, ErrorCode::Usage);
        assert!(err.message.contains("owner/pics"), "{}", err.message);
    }

    /// The picker runs after a credential is already on disk, so a reply the user could
    /// simply retype must not come back as an error.
    ///
    /// `stdout_lost` is the only way to reach `ask` from a test without hanging on the
    /// harness's own stdin, and it exercises the distinction that matters: a question
    /// that was never *shown* still fails, because "asked and not answered"
    /// (`Ok(None)`) and "could not ask" (`Err`) are not the same state.
    #[test]
    fn a_question_that_could_not_be_shown_still_fails() {
        let _serialised = crate::output::stdout_lost_test_guard(true);
        let err = ask("image host? [1-2]", "1", 2).expect_err("an unshown prompt must fail");
        assert_eq!(err.code, ErrorCode::General, "{}", err.message);
    }
}
