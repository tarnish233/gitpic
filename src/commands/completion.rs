//! `gitpic completion <shell>` — print a shell completion script.

use crate::cli::Cli;
use crate::error::Result;
use clap::CommandFactory;
use clap_complete::{generate, Shell};

pub fn run(shell: Shell) -> Result<()> {
    let mut cmd = Cli::command();
    let name = cmd.get_name().to_string();
    // Generated into a buffer rather than straight to stdout: `generate` writes
    // through an `.expect()`, so `gitpic completion zsh | head` used to abort with
    // exit 134 from inside clap_complete, where this crate cannot intercept it.
    // Buffering moves the write to a place that can treat a closed reader as the
    // normal end of output.
    let mut buf: Vec<u8> = Vec::new();
    generate(shell, &mut cmd, name, &mut buf);
    crate::output::raw(&String::from_utf8_lossy(&buf));
    crate::output::finish();
    Ok(())
}
