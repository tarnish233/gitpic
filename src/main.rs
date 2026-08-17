//! gitpic — upload images to a GitHub repo (image host) and get a Markdown link.

mod auth;
mod cli;
mod commands;
mod config;
mod error;
mod github;
mod history;
mod imageproc;
mod link;
mod naming;
mod output;

use clap::{error::ErrorKind, Parser};
use cli::{Cli, Command};
use config::Config;
use error::Result;
use output::Mode;
use std::process::ExitCode;

#[tokio::main]
async fn main() -> ExitCode {
    let args: Vec<_> = std::env::args_os().collect();
    let wants_json = args.iter().any(|arg| arg == "--json");
    let cli = match Cli::try_parse_from(args) {
        Ok(cli) => cli,
        Err(e) => {
            if matches!(e.kind(), ErrorKind::DisplayHelp | ErrorKind::DisplayVersion) {
                let _ = e.print();
                return ExitCode::SUCCESS;
            }
            if wants_json {
                output::print_error(Mode::Json, "USAGE", &e.to_string());
            } else {
                let _ = e.print();
            }
            return ExitCode::from(e.exit_code() as u8);
        }
    };
    let mode = Mode::from_flags(cli.json, cli.quiet);

    match dispatch(&cli, mode).await {
        Ok(code) => ExitCode::from(code),
        Err(e) => {
            output::print_error(mode, e.code.as_str(), &e.message);
            ExitCode::from(e.code.exit_code())
        }
    }
}

async fn dispatch(cli: &Cli, mode: Mode) -> Result<u8> {
    // Commands that do not need config resolution / network.
    match &cli.command {
        Some(Command::Init) => return commands::init::run().map(|_| 0),
        Some(Command::Config { action }) => return commands::config_cmd::run(action).map(|_| 0),
        Some(Command::List { limit }) => return commands::list::run(*limit, mode).map(|_| 0),
        Some(Command::Completion { shell }) => return commands::completion::run(*shell).map(|_| 0),
        Some(Command::Skill { action }) => return commands::skill::run(action, mode).map(|_| 0),
        _ => {}
    }

    // Resolve config: file -> env -> CLI overrides.
    let mut cfg = Config::load()?;
    cfg.apply_env()?;
    if let Some(repo) = &cli.repo {
        cfg.set_repo_spec(repo)?;
    }

    match &cli.command {
        Some(Command::Doctor) => commands::doctor::run(&cfg, mode).await,
        Some(Command::Paste) => commands::upload::run(cli, &cfg, mode).await,
        None => commands::upload::run(cli, &cfg, mode).await,
        // handled above
        Some(Command::Init)
        | Some(Command::Config { .. })
        | Some(Command::List { .. })
        | Some(Command::Completion { .. })
        | Some(Command::Skill { .. }) => unreachable!(),
    }
}
