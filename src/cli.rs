//! Command-line interface definition (clap derive).

use clap::{ArgAction, Parser, Subcommand, ValueEnum};
use clap_complete::Shell;
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
    #[arg(long, global = true)]
    pub stdin: bool,

    /// Filename for stdin/clipboard uploads (e.g. shot.png)
    #[arg(long, global = true)]
    pub name: Option<String>,

    /// Link kind override: cdn (jsDelivr) or raw (GitHub)
    #[arg(long, value_enum, global = true)]
    pub link: Option<LinkKind>,

    /// Output format: md | html | url
    #[arg(short, long, value_enum, default_value_t = OutputFormat::Md, global = true)]
    pub format: OutputFormat,

    /// Do not copy the result to the clipboard
    #[arg(long, global = true)]
    pub no_copy: bool,

    /// Compress/resize the image before uploading
    #[arg(long, global = true)]
    pub compress: bool,

    /// Disable compression even if enabled in config
    #[arg(long, global = true)]
    pub no_compress: bool,

    /// Resize so width <= N pixels (0 = keep original)
    #[arg(long, global = true)]
    pub max_width: Option<u32>,

    /// JPEG quality 1-100 when compressing (default from config)
    #[arg(long, global = true)]
    pub quality: Option<u8>,

    /// Override the upload path template
    #[arg(short, long, global = true)]
    pub path: Option<String>,

    /// Override target repo (owner/repo)
    #[arg(long, global = true)]
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
    /// List recent uploads from local history
    List {
        /// Max number of records to show
        #[arg(short, long, default_value_t = 20)]
        limit: usize,
    },
    /// Generate a shell completion script
    Completion {
        /// Target shell
        #[arg(value_enum)]
        shell: Shell,
    },
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

#[cfg(test)]
mod tests {
    use super::*;
    use clap::Parser;

    #[test]
    fn upload_options_work_after_subcommand() {
        // Regression: these used to be rejected after `paste` (not global).
        let cli = Cli::try_parse_from([
            "gitpic",
            "paste",
            "--no-copy",
            "--link",
            "raw",
            "--name",
            "shot.png",
            "-f",
            "url",
        ])
        .expect("paste should accept upload options");
        assert!(matches!(cli.command, Some(Command::Paste)));
        assert!(cli.no_copy);
        assert_eq!(cli.link, Some(LinkKind::Raw));
        assert_eq!(cli.name.as_deref(), Some("shot.png"));
        assert_eq!(cli.format, OutputFormat::Url);
    }

    #[test]
    fn upload_options_work_before_and_default() {
        let cli = Cli::try_parse_from(["gitpic", "a.png", "--json", "--max-width", "800"])
            .expect("default upload should parse");
        assert!(cli.command.is_none());
        assert!(cli.json);
        assert_eq!(cli.max_width, Some(800));
    }

    #[test]
    fn completion_parses_shell() {
        let cli = Cli::try_parse_from(["gitpic", "completion", "zsh"]).unwrap();
        assert!(matches!(cli.command, Some(Command::Completion { .. })));
    }
}
