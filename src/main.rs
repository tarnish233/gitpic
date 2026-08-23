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
mod oauth;
mod output;

use clap::{error::ErrorKind, Parser};
use cli::{Cli, Command};
use config::Config;
use error::{ErrorCode, Result};
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
                output::print_error(Mode::Json, ErrorCode::Usage.as_str(), &e.to_string());
            } else {
                let _ = e.print();
            }
            // help/version already returned above, so every remaining clap error
            // is a usage error. Going through ErrorCode keeps the wire string and
            // the exit code under the contract test in error.rs.
            output::finish();
            return ExitCode::from(ErrorCode::Usage.exit_code());
        }
    };
    let mode = Mode::from_flags(cli.json, cli.quiet);

    let code = match dispatch(&cli, mode).await {
        Ok(code) => ExitCode::from(code),
        Err(e) => {
            output::print_error(mode, e.code.as_str(), &e.message);
            ExitCode::from(e.code.exit_code())
        }
    };
    output::finish();
    code
}

async fn dispatch(cli: &Cli, mode: Mode) -> Result<u8> {
    // Before the match, because it is about the invocation rather than about any one
    // subcommand — and every arm below would otherwise have to remember it, which is
    // how the check this replaces came to be called seven times.
    cli.reject_misplaced_upload_args()?;
    // One match, so adding a subcommand fails to compile here — on the arm you
    // actually have to write — rather than at a catch-all that would compile and
    // then panic (an abort exits 134, outside the documented 1-10 contract).
    match &cli.command {
        // Config-free: these must work even when config.toml is missing or
        // unparseable, so they never touch `resolve_config`.
        Some(Command::Auth { action }) => commands::auth_cmd::run(action, mode).await,
        Some(Command::Config { action }) => commands::config_cmd::run(action, mode).map(|_| 0),
        Some(Command::List { limit }) => commands::list::run(*limit, mode).map(|_| 0),
        // Config-free like the rest of this group: it answers "which repo *could* I
        // use", which is the question someone asks precisely when the configured one
        // is wrong or absent.
        Some(Command::Repos) => commands::repos::run(mode).await,
        Some(Command::Completion { shell }) => commands::completion::run(*shell).map(|_| 0),
        Some(Command::Skill { action }) => commands::skill::run(action, mode).map(|_| 0),

        Some(Command::Doctor { .. }) => {
            let cfg = resolve_config(cli)?;
            commands::doctor::run(&cfg, mode).await
        }
        // Needs a target, unlike `repos`: branches belong to a repository, so this one
        // resolves the config and honours `--repo` / `GITPIC_REPO`.
        Some(Command::Branches { .. }) => {
            let cfg = resolve_config(cli)?;
            commands::branches::run(&cfg, mode).await
        }
        // No subcommand means the default upload path. `paste` carries the same
        // upload flags, flattened onto the subcommand rather than marked global.
        Some(Command::Paste { .. }) | None => {
            let cfg = resolve_config(cli)?;
            commands::upload::run(cli, &cfg, mode).await
        }
    }
}

/// Resolve config: file -> env -> CLI overrides.
///
/// Each layer is validated by whoever applies it, and `--repo` is applied here —
/// so the check belongs here too. Without it, the *highest*-priority source was
/// the only unchecked one: `--repo o/..` collapsed a segment out of the request
/// URL and `--repo 'o/re po'` sent `%20` into the path, both surfacing as a bare
/// 404 while the identical value from the file or `GITPIC_REPO` was refused with
/// an actionable message.
fn resolve_config(cli: &Cli) -> Result<Config> {
    let mut cfg = Config::load()?;
    cfg.apply_env()?;
    if let Some(repo) = cli.repo_override() {
        cfg.set_repo_spec(repo)?;
        cfg.validate_input()?;
    }
    Ok(cfg)
}
