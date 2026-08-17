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
    ///
    /// `Option` rather than a defaulted value so that "the user asked for md" is
    /// distinguishable from "nobody said anything" — which is what lets
    /// `upload_only_flags_set` report it. The default lives in `effective_format`.
    #[arg(short, long, value_enum, global = true)]
    pub format: Option<OutputFormat>,

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
    #[arg(long, global = true, value_parser = clap::value_parser!(u8).range(1..=100))]
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

impl Cli {
    /// The output format to actually use.
    pub fn effective_format(&self) -> OutputFormat {
        self.format.unwrap_or(OutputFormat::Md)
    }

    /// Which upload-only options this invocation actually set.
    ///
    /// Every upload option is `global = true`, which is what lets `gitpic paste
    /// --no-copy` work (see `upload_options_work_after_subcommand`). The side
    /// effect was that `gitpic list --compress --max-width 99` also parsed, exited
    /// 0, and ignored every one of them — the same "accepted, then silently
    /// dropped" shape this project has been closing elsewhere. `main::dispatch`
    /// turns a non-empty result into a usage error on subcommands that upload
    /// nothing.
    ///
    /// Only options that can be distinguished from their default appear here; that
    /// is why `format` is an `Option`. `--json`, `--quiet` and `--verbose` are
    /// deliberately absent: they mean something everywhere.
    pub fn upload_only_flags_set(&self) -> Vec<&'static str> {
        let mut set = Vec::new();
        if self.stdin {
            set.push("--stdin");
        }
        if self.name.is_some() {
            set.push("--name");
        }
        if self.link.is_some() {
            set.push("--link");
        }
        if self.format.is_some() {
            set.push("--format");
        }
        if self.no_copy {
            set.push("--no-copy");
        }
        if self.compress {
            set.push("--compress");
        }
        if self.no_compress {
            set.push("--no-compress");
        }
        if self.max_width.is_some() {
            set.push("--max-width");
        }
        if self.quality.is_some() {
            set.push("--quality");
        }
        if self.path.is_some() {
            set.push("--path");
        }
        set
    }

    /// Whether `--repo` was given. Meaningful for the upload path and `doctor`,
    /// which both resolve a target; ignored by every other subcommand.
    pub fn repo_override_set(&self) -> bool {
        self.repo.is_some()
    }
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
    /// Install or print the bundled AI agent skill
    Skill {
        #[command(subcommand)]
        action: SkillAction,
    },
}

#[derive(Debug, Subcommand)]
pub enum SkillAction {
    /// Install the skill into agent skill directories
    Install {
        /// Only install for this agent (default: pick from the detected ones)
        #[arg(long, value_enum)]
        agent: Option<AgentKind>,

        /// Install into an explicit skills directory (e.g. ~/.agents/skills)
        #[arg(long, conflicts_with = "agent")]
        dir: Option<PathBuf>,

        /// Skip the prompt and install into every detected directory
        #[arg(short = 'y', long)]
        yes: bool,
    },
    /// Print the skill document to stdout
    Print,
    /// Print the skill paths that would be written
    Path,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum AgentKind {
    /// Claude Code (`~/.claude/skills`)
    Claude,
    /// Codex CLI (`~/.codex/skills`)
    Codex,
    /// Every detected agent
    All,
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
        assert_eq!(cli.format, Some(OutputFormat::Url));
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

    #[test]
    fn skill_install_defaults_to_no_explicit_target() {
        let cli = Cli::try_parse_from(["gitpic", "skill", "install"]).unwrap();
        match cli.command {
            Some(Command::Skill {
                action: SkillAction::Install { agent, dir, yes },
            }) => {
                assert!(agent.is_none());
                assert!(dir.is_none());
                assert!(!yes);
            }
            other => panic!("expected skill install, got {other:?}"),
        }
    }

    #[test]
    fn skill_install_parses_agent_and_yes() {
        let cli =
            Cli::try_parse_from(["gitpic", "skill", "install", "--agent", "codex", "-y"]).unwrap();
        match cli.command {
            Some(Command::Skill {
                action: SkillAction::Install { agent, yes, .. },
            }) => {
                assert_eq!(agent, Some(AgentKind::Codex));
                assert!(yes);
            }
            other => panic!("expected skill install, got {other:?}"),
        }
    }

    #[test]
    fn skill_install_parses_dir() {
        let cli =
            Cli::try_parse_from(["gitpic", "skill", "install", "--dir", "/tmp/skills"]).unwrap();
        match cli.command {
            Some(Command::Skill {
                action: SkillAction::Install { dir, .. },
            }) => assert_eq!(dir, Some(PathBuf::from("/tmp/skills"))),
            other => panic!("expected skill install, got {other:?}"),
        }
    }

    #[test]
    fn skill_install_rejects_dir_with_agent() {
        // --dir names a target outright; combining it with --agent is ambiguous.
        assert!(Cli::try_parse_from([
            "gitpic",
            "skill",
            "install",
            "--dir",
            "/tmp/skills",
            "--agent",
            "claude",
        ])
        .is_err());
    }

    #[test]
    fn skill_print_and_path_parse() {
        assert!(matches!(
            Cli::try_parse_from(["gitpic", "skill", "print"])
                .unwrap()
                .command,
            Some(Command::Skill {
                action: SkillAction::Print
            })
        ));
        assert!(matches!(
            Cli::try_parse_from(["gitpic", "skill", "path"])
                .unwrap()
                .command,
            Some(Command::Skill {
                action: SkillAction::Path
            })
        ));
    }

    #[test]
    fn quality_outside_1_to_100_is_rejected() {
        // Regression: --quality 0 was silently clamped to 1 instead of erroring,
        // and --quality 300 reported a misleading "not in 0..=255".
        assert!(Cli::try_parse_from(["gitpic", "a.png", "--quality", "0"]).is_err());
        assert!(Cli::try_parse_from(["gitpic", "a.png", "--quality", "101"]).is_err());
        assert!(Cli::try_parse_from(["gitpic", "a.png", "--quality", "300"]).is_err());
    }

    #[test]
    fn quality_bounds_are_accepted() {
        for q in ["1", "82", "100"] {
            let cli = Cli::try_parse_from(["gitpic", "a.png", "--quality", q])
                .unwrap_or_else(|e| panic!("quality {q} should parse: {e}"));
            assert_eq!(cli.quality, Some(q.parse().unwrap()));
        }
    }

    #[test]
    fn the_format_default_survives_becoming_an_option() {
        // `format` became `Option` so it could be told apart from its default;
        // md must still be what an unadorned upload produces.
        let cli = Cli::try_parse_from(["gitpic", "a.png"]).unwrap();
        assert_eq!(cli.format, None);
        assert_eq!(cli.effective_format(), OutputFormat::Md);
        let explicit = Cli::try_parse_from(["gitpic", "a.png", "-f", "url"]).unwrap();
        assert_eq!(explicit.effective_format(), OutputFormat::Url);
    }

    #[test]
    fn an_untouched_invocation_reports_no_upload_only_flags() {
        // The flags that mean something everywhere must never be reported.
        let cli = Cli::try_parse_from(["gitpic", "list", "--json", "-q", "-vv"]).unwrap();
        assert!(cli.upload_only_flags_set().is_empty());
        assert!(!cli.repo_override_set());
    }

    #[test]
    fn every_upload_only_flag_is_detected() {
        // Regression: these all parsed on `list`/`completion`/`config`, exited 0,
        // and were silently ignored. Each must be reportable so dispatch can
        // refuse it. Listed one per line so a newly added upload option that
        // nobody wired up shows here as a missing entry.
        for (args, want) in [
            (vec!["--stdin"], "--stdin"),
            (vec!["--name", "x.png"], "--name"),
            (vec!["--link", "raw"], "--link"),
            (vec!["-f", "url"], "--format"),
            (vec!["--no-copy"], "--no-copy"),
            (vec!["--compress"], "--compress"),
            (vec!["--no-compress"], "--no-compress"),
            (vec!["--max-width", "99"], "--max-width"),
            (vec!["--quality", "50"], "--quality"),
            (vec!["-p", "t/{name}.{ext}"], "--path"),
        ] {
            let mut argv = vec!["gitpic", "list"];
            argv.extend(args.iter().copied());
            let cli = Cli::try_parse_from(&argv).unwrap_or_else(|e| panic!("{argv:?}: {e}"));
            assert_eq!(cli.upload_only_flags_set(), vec![want], "for {argv:?}");
        }
    }

    #[test]
    fn the_upload_path_still_accepts_all_of_them() {
        // The rejection must not leak into the paths that do use these options.
        let cli = Cli::try_parse_from([
            "gitpic",
            "paste",
            "--no-copy",
            "--link",
            "raw",
            "--name",
            "s.png",
            "-f",
            "url",
            "--compress",
            "--max-width",
            "800",
            "--quality",
            "90",
        ])
        .expect("paste must still accept every upload option");
        assert_eq!(
            cli.upload_only_flags_set(),
            vec![
                "--name",
                "--link",
                "--format",
                "--no-copy",
                "--compress",
                "--max-width",
                "--quality"
            ]
        );
        assert!(matches!(cli.command, Some(Command::Paste)));
    }
}
