//! Subcommand implementations.

pub mod auth_cmd;
pub mod branches;
pub mod completion;
pub mod config_cmd;
pub mod doctor;
pub mod list;
pub mod repos;
pub mod skill;
pub mod update;
pub mod upload;

use crate::error::{AppError, Result};
use std::io;

/// Prompt on stdout and read a line from stdin. Returns `None` on EOF
/// (Ctrl-D / closed stdin), which callers must not confuse with an empty
/// reply — for a write action EOF means "abort", not "take the default".
///
/// Fails outright when the question could not be delivered at all; see the guard
/// below for why that is not the same thing as EOF.
pub(crate) fn prompt_opt(label: &str, default: &str) -> Result<Option<String>> {
    if default.is_empty() {
        crate::output::raw(&format!("{label}: "));
    } else {
        crate::output::raw(&format!("{label} [{default}]: "));
    }
    crate::output::finish();
    // A question nobody could read has no answer, so refuse before touching stdin.
    // `printf 'someone/pics\nmain\ncdn\n' | gitpic init | true` threw every prompt
    // into the closed pipe, read the piped lines regardless, and wrote
    // `owner="someone" repo="pics" branch="main"` to config.toml — the user never
    // saw one of the questions those answers belong to. That command is gone, but
    // both prompts that replaced it write a config or install files from a numbered
    // list: `gitpic auth login`'s repository picker, and `gitpic skill install`,
    // whose default is `a=all` — so an unseen prompt there installs into every
    // detected agent directory. A closed stdout is no more consent than the closed
    // stdin `skill::select_interactively` already refuses to read as one, so it
    // fails the same way an unreadable stdin does — `AppError::general`, exit 1,
    // nothing consumed and nothing written.
    if crate::output::stdout_lost() {
        return Err(AppError::general(
            "write prompt: stdout is closed, so the question was never shown; \
             refusing to read an answer",
        ));
    }
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::error::ErrorCode;

    /// The regression: `gitpic init | true` saved a config built from answers to
    /// questions the user never saw.
    ///
    /// This call may not reach `read_line`. Under `cargo test` stdin is whatever the
    /// runner inherited, so a call that got that far would hang the suite instead of
    /// failing it — returning before the read *is* the contract. The prompt text that
    /// shows up in the test output is this code doing its job: the question is still
    /// written, and only then found to have gone nowhere.
    ///
    /// Both surviving prompts read EOF as an abort, so there is no longer a variant
    /// that turns a missing answer into a default. The one that did went with `init`,
    /// which is also the command whose three defaults added up to a saved config file.
    #[test]
    fn a_prompt_that_could_not_be_written_is_never_answered() {
        let _serialised = crate::output::stdout_lost_test_guard(true);
        let err = prompt_opt("image host? [1-3]", "2")
            .expect_err("a discarded prompt must not be answered out of stdin");
        assert_eq!(err.code, ErrorCode::General, "{}", err.message);
    }
}
