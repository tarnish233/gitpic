//! Subcommand implementations.

pub mod completion;
pub mod config_cmd;
pub mod doctor;
pub mod init;
pub mod list;
pub mod skill;
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
    // saw one of the questions those answers belong to. `gitpic skill install |
    // true` is worse: the numbered target list goes to the same closed pipe and
    // the default is `a=all`, so an unseen prompt installs files into every
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

/// Prompt, treating EOF as the default. Suitable for `init`, where EOF on a
/// field just means "keep what is already configured".
///
/// EOF only: a prompt that could not be *written* still fails through `?`.
/// Substituting the default is safe for someone who saw the question and chose to
/// accept it, and `gitpic init | true` saw nothing — taking the default three
/// times there is exactly how it wrote a config file on its own.
pub(crate) fn prompt(label: &str, default: &str) -> Result<String> {
    Ok(prompt_opt(label, default)?.unwrap_or_else(|| default.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::error::ErrorCode;

    /// The regression: `gitpic init | true` saved a config built from answers to
    /// questions the user never saw.
    ///
    /// Neither call here may reach `read_line`. Under `cargo test` stdin is
    /// whatever the runner inherited, so a call that got that far would hang the
    /// suite instead of failing it — returning before the read *is* the contract.
    /// The prompt text that shows up in the test output is this code doing its job:
    /// the question is still written, and only then found to have gone nowhere.
    #[test]
    fn a_prompt_that_could_not_be_written_is_never_answered() {
        let _serialised = crate::output::stdout_lost_test_guard(true);

        let err = prompt_opt("Target repo (owner/name)", "a")
            .expect_err("a discarded prompt must not be answered out of stdin");
        assert_eq!(err.code, ErrorCode::General, "{}", err.message);

        // `prompt` exists to turn a missing answer into the current value. It must
        // not do that here: nobody chose the default, and for `init` accepting it
        // three times is a saved config.
        let err = prompt("Branch", "main").expect_err("an unseen default is not consent");
        assert_eq!(err.code, ErrorCode::General, "{}", err.message);
    }
}
