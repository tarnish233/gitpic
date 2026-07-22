//! gitpic — upload images to a GitHub repo (image host) and get a Markdown link.

mod cli;
mod commands;
mod config;
mod error;
mod github;
mod link;
mod naming;
mod output;

use clap::Parser;
use cli::{Cli, Command};
use config::Config;
use error::Result;
use output::Mode;
use std::process::ExitCode;

#[tokio::main]
async fn main() -> ExitCode {
    let cli = Cli::parse();
    let mode = Mode::from_flags(cli.json, cli.quiet);

    match dispatch(&cli, mode).await {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            output::print_error(mode, e.code.as_str(), &e.message);
            ExitCode::from(e.code.exit_code())
        }
    }
}

async fn dispatch(cli: &Cli, mode: Mode) -> Result<()> {
    // Commands that do not need config resolution / network.
    match &cli.command {
        Some(Command::Init) => return commands::init::run(),
        Some(Command::Config { action }) => return commands::config_cmd::run(action),
        _ => {}
    }

    // Resolve config: file -> env -> CLI overrides.
    let mut cfg = Config::load()?;
    cfg.apply_env();
    if let Some(repo) = &cli.repo {
        cfg.set_repo_spec(repo);
    }

    match &cli.command {
        Some(Command::Doctor) => commands::doctor::run(&cfg, mode).await,
        Some(Command::Paste) => commands::upload::run(cli, &cfg, mode).await,
        None => commands::upload::run(cli, &cfg, mode).await,
        // handled above
        Some(Command::Init) | Some(Command::Config { .. }) => unreachable!(),
    }
}
