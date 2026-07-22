//! `gitpic completion <shell>` — print a shell completion script.

use crate::cli::Cli;
use crate::error::Result;
use clap::CommandFactory;
use clap_complete::{generate, Shell};

pub fn run(shell: Shell) -> Result<()> {
    let mut cmd = Cli::command();
    let name = cmd.get_name().to_string();
    generate(shell, &mut cmd, name, &mut std::io::stdout());
    Ok(())
}
