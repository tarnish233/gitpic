//! Command-line interface definition (clap derive).

use clap::{ArgAction, Parser, Subcommand, ValueEnum};
use std::path::PathBuf;

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum LinkKind {
    /// jsDelivr CDN link (fast, third-party CDN)
    Cdn,
    /// GitHub raw.githubusercontent.com link
    Raw,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum OutputFormat {
    /// Markdown image: ![alt](url)
    Md,
    /// HTML <img> tag
    Html,
    /// Plain URL only
    Url,
}

#[derive(Debug, Parser)]
#[command(
    name = "gitpic",
    version,
    about = "Upload images to a GitHub repo (image host) and get a Markdown link",
    long_about = None,
)]
pub struct Cli {
    /// Image files to upload (used when no subcommand is given)
    pub files: Vec<PathBuf>,

    /// Output structured JSON (for scripts / agents)
    #[arg(long, global = true)]
    pub json: bool,

    /// Only print the resulting link/URL (script friendly)
    #[arg(short, long, global = true)]
    pub quiet: bool,

    /// Increase logging verbosity (-v, -vv)
    #[arg(short, long, global = true, action = ArgAction::Count)]
    pub verbose: u8,

    /// Read image bytes from stdin instead of a file
    #[arg(long)]
    pub stdin: bool,

    /// Filename for stdin/clipboard uploads (e.g. shot.png)
    #[arg(long)]
    pub name: Option<String>,

    /// Link kind override: cdn (jsDelivr) or raw (GitHub)
    #[arg(long, value_enum)]
    pub link: Option<LinkKind>,

    /// Output format: md | html | url
    #[arg(short, long, value_enum, default_value_t = OutputFormat::Md)]
    pub format: OutputFormat,

    /// Do not copy the result to the clipboard
    #[arg(long)]
    pub no_copy: bool,

    /// Override the upload path template
    #[arg(short, long)]
    pub path: Option<String>,

    /// Override target repo (owner/repo)
    #[arg(long)]
    pub repo: Option<String>,

    #[command(subcommand)]
    pub command: Option<Command>,
}

#[derive(Debug, Subcommand)]
pub enum Command {
    /// Interactively initialize configuration
    Init,
    /// Read an image from the clipboard and upload it
    Paste,
    /// View or modify configuration
    Config {
        #[command(subcommand)]
        action: ConfigAction,
    },
    /// Health check: config present, token valid, repo writable
    Doctor,
}

#[derive(Debug, Subcommand)]
pub enum ConfigAction {
    /// Print a config value (or the whole config)
    Get { key: Option<String> },
    /// Set a config value (e.g. github.repo owner/name)
    Set { key: String, value: String },
    /// Print the config file path
    Path,
    /// Open the config file in $EDITOR
    Edit,
}
