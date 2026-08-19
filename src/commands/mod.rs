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
pub(crate) fn prompt_opt(label: &str, default: &str) -> Result<Option<String>> {
    if default.is_empty() {
        crate::output::raw(&format!("{label}: "));
    } else {
        crate::output::raw(&format!("{label} [{default}]: "));
    }
    crate::output::finish();
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
