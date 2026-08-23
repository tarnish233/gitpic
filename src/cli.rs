//! Command-line interface definition (clap derive).

use clap::{ArgAction, Args, Parser, Subcommand, ValueEnum};
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

/// Flags that only mean something on an upload (`gitpic <files>` or `paste`).
///
/// Flattened onto those two commands rather than marked `global`, so `gitpic list
/// --compress` is a clap error instead of a silent no-op. `--json` / `--quiet` /
/// `--verbose` stay on [`Cli`]: they mean something everywhere.
///
/// `PartialEq` is what [`UploadArgs::any_set`] is built on — see there.
#[derive(Debug, Clone, Default, PartialEq, Eq, Args)]
pub struct UploadArgs {
    /// Read image bytes from stdin instead of a file
    #[arg(long)]
    pub stdin: bool,

    /// Filename stem for stdin, clipboard, or a single-file upload; the extension
    /// follows the image bytes, not this (e.g. `--name shot` on a JPEG → shot.jpg)
    #[arg(long)]
    pub name: Option<String>,

    /// Link kind override: cdn (jsDelivr) or raw (GitHub)
    #[arg(long, value_enum)]
    pub link: Option<LinkKind>,

    // `//`, not `///`: a doc comment's second paragraph becomes clap's *long* help,
    // so this rationale — rustdoc link and all — was printed to anyone who ran
    // `gitpic --help` or `gitpic paste --help`.
    //
    // `Option` rather than a defaulted value so that "the user asked for md" stays
    // distinguishable from "nobody said anything". The default lives in
    // [`Cli::effective_format`].
    /// Output format: md | html | url
    #[arg(short, long, value_enum)]
    pub format: Option<OutputFormat>,

    /// Do not copy the result to the clipboard
    #[arg(long)]
    pub no_copy: bool,

    /// Compress/resize the image before uploading
    #[arg(long)]
    pub compress: bool,

    /// Disable compression even if enabled in config
    #[arg(long)]
    pub no_compress: bool,

    /// Resize so width <= N pixels (0 = keep original)
    #[arg(long)]
    pub max_width: Option<u32>,

    /// JPEG quality 1-100 when compressing (default from config)
    #[arg(long, value_parser = clap::value_parser!(u8).range(1..=100))]
    pub quality: Option<u8>,

    /// Override the upload path template
    #[arg(short, long)]
    pub path: Option<String>,

    /// Override target repo (owner/repo)
    #[arg(long)]
    pub repo: Option<String>,
}

impl UploadArgs {
    /// Whether this invocation set any upload option.
    ///
    /// Compared against `Default` rather than enumerating the flags: an option
    /// added to this struct later is covered without anyone remembering to add it
    /// here, which the hand-written list this replaces could not promise.
    ///
    /// Only [`Cli::reject_misplaced_upload_args`] asks. It is a plain "anything?"
    /// because the user's own command line already names which flag it was.
    pub fn any_set(&self) -> bool {
        *self != Self::default()
    }
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

    #[command(flatten)]
    pub upload: UploadArgs,

    #[command(subcommand)]
    pub command: Option<Command>,
}

impl Cli {
    /// Upload options for this invocation.
    ///
    /// `paste` carries its own copy so the flags can follow the subcommand without
    /// being global. Every other path reads the top-level flatten (empty unless
    /// this is a default-command upload).
    pub fn upload_args(&self) -> &UploadArgs {
        match &self.command {
            Some(Command::Paste { upload }) => upload,
            _ => &self.upload,
        }
    }

    /// Refuse upload options typed *before* a subcommand.
    ///
    /// Clap covers the other side of this on its own: an upload option after a
    /// subcommand that does not declare it — `gitpic list --compress` — is an
    /// unknown-argument error, which is the whole reason these are flattened
    /// rather than `global`. Before the subcommand they parse into [`Cli::upload`],
    /// which nothing then reads: `paste` carries its own copy, and no other
    /// subcommand uploads. That is the "accepted, then silently dropped" shape
    /// this project closes wherever it appears, so it is a usage error.
    ///
    /// **Deliberately not `args_conflicts_with_subcommands`.** That setting says
    /// exactly this, and it was tried — but it also stops clap from recognising a
    /// subcommand at all once any top-level argument has been seen, the globals
    /// included, so `gitpic --json doctor` parsed `doctor` as a *filename* and
    /// reported `NOT_FOUND: file not found: doctor`. Pinned by
    /// `a_global_flag_before_a_subcommand_still_selects_it`.
    pub fn reject_misplaced_upload_args(&self) -> crate::error::Result<()> {
        if self.command.is_none() || !self.upload.any_set() {
            return Ok(());
        }
        // Says where they *do* work rather than only "not here". Without the last
        // clause this was a two-step dead end for `list` and friends: move the flag
        // after the subcommand as told, and clap rejects it there too, because no
        // subcommand but `paste` and `doctor` takes any of these.
        Err(crate::error::AppError::usage(
            "upload options apply to nothing before a subcommand: pass them to the \
             upload itself (`gitpic a.png --compress`), after `paste` (`gitpic paste \
             --no-copy`), or as `--repo` after `doctor` or `branches`. No other \
             subcommand takes them.",
        ))
    }

    /// `--repo`, from whichever command actually accepts it.
    pub fn repo_override(&self) -> Option<&str> {
        match &self.command {
            // The two read-only checks that answer a question *about* a repository, so
            // both take one directly — that is what lets someone look before committing
            // the value to `config.toml`.
            Some(Command::Doctor { repo }) | Some(Command::Branches { repo }) => repo.as_deref(),
            _ => self.upload_args().repo.as_deref(),
        }
    }

    /// The output format to actually use: the flag if given, else the config's
    /// `upload.format`.
    ///
    /// The flag stays an `Option` so "the user asked for md" stays distinguishable
    /// from "nobody said anything" — only the second case falls through to the
    /// file.
    ///
    /// The final `unwrap_or` is unreachable through any supported path, because
    /// `Config::validate` rejects a format it cannot parse before a config is ever
    /// handed out. It is here rather than an `expect` because a panic is not a
    /// defensible answer to a config file, and Markdown is what every version before
    /// this key existed produced.
    pub fn effective_format(&self, cfg: &crate::config::Config) -> OutputFormat {
        self.upload_args()
            .format
            .or_else(|| crate::link::parse_output_format_strict(&cfg.upload.format))
            .unwrap_or(OutputFormat::Md)
    }
}

#[derive(Debug, Subcommand)]
pub enum Command {
    /// Log in to GitHub and manage the stored credential
    Auth {
        #[command(subcommand)]
        action: AuthAction,
    },
    /// Read an image from the clipboard and upload it
    Paste {
        #[command(flatten)]
        upload: UploadArgs,
    },
    /// View or modify configuration
    Config {
        #[command(subcommand)]
        action: ConfigAction,
    },
    /// Health check: config present, token valid, repo writable
    Doctor {
        /// Override target repo (owner/repo)
        #[arg(long)]
        repo: Option<String>,
    },
    /// List the repositories this credential could upload to
    Repos,
    /// List the branches on the configured repository
    Branches {
        /// Override target repo (owner/repo)
        #[arg(long)]
        repo: Option<String>,
    },
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
pub enum AuthAction {
    /// Log in to GitHub in the browser and store the credential
    Login {
        /// Print the code and URL without trying to open a browser
        #[arg(long)]
        no_browser: bool,

        /// OAuth scopes to ask for (default: public_repo; use `repo` for a private
        /// image host)
        #[arg(long)]
        scope: Option<String>,

        /// Log in against another OAuth app instead of gitpic's own
        #[arg(long)]
        client_id: Option<String>,
    },
    /// Show which credential gitpic would use, and whose it is
    Status,
    /// Remove the credential stored by `gitpic auth login`
    Logout,
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
    /// Set one or more config values (`KEY VALUE` pairs)
    Set {
        /// Alternating key and value, e.g. `github.repo owner/name upload.format md`
        // Neither clap spelling says "pairs": `value_names = ["KEY", "VALUE"]` renders
        // `<KEY> <VALUE>...`, where the `...` attaches to the last name and can be read
        // as one key with many values, and a single `value_name = "KEY VALUE"` renders
        // `<KEY VALUE> <KEY VALUE>...`, which claims a two-pair minimum that is not
        // real. Kept as the pair, with the rule stated in the help text above, which is
        // the line anyone who gets this wrong will actually read.
        #[arg(required = true, num_args = 2.., value_names = ["KEY", "VALUE"])]
        pairs: Vec<String>,
    },
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
        // Flattened onto `paste`, so they follow the subcommand without being global.
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
        assert!(matches!(cli.command, Some(Command::Paste { .. })));
        let u = cli.upload_args();
        assert!(u.no_copy);
        assert_eq!(u.link, Some(LinkKind::Raw));
        assert_eq!(u.name.as_deref(), Some("shot.png"));
        assert_eq!(u.format, Some(OutputFormat::Url));
    }

    #[test]
    fn upload_options_work_on_the_default_command() {
        let cli = Cli::try_parse_from(["gitpic", "a.png", "--json", "--max-width", "800"])
            .expect("default upload should parse");
        assert!(cli.command.is_none());
        assert!(cli.json);
        assert_eq!(cli.upload_args().max_width, Some(800));
    }

    #[test]
    fn a_global_flag_before_a_subcommand_still_selects_it() {
        // Regression, and the reason `args_conflicts_with_subcommands` is not set:
        // with it, clap stopped looking for a subcommand as soon as any top-level
        // argument had been seen, so `--json doctor` parsed `doctor` into `files`
        // and the run reported `NOT_FOUND: file not found: doctor` — a subcommand
        // silently turned into an upload of a file nobody named.
        for sub in [
            vec!["doctor"],
            vec!["list"],
            vec!["config", "get"],
            vec!["skill", "path"],
            vec!["completion", "bash"],
            vec!["auth", "status"],
            vec!["repos"],
            vec!["branches"],
            vec!["paste"],
        ] {
            for global in [vec!["--json"], vec!["-q"], vec!["-vv"]] {
                let mut argv = vec!["gitpic"];
                argv.extend(global.iter().copied());
                argv.extend(sub.iter().copied());
                let cli = Cli::try_parse_from(&argv).unwrap_or_else(|e| panic!("{argv:?}: {e}"));
                assert!(cli.command.is_some(), "{argv:?} must select a subcommand");
                assert!(
                    cli.files.is_empty(),
                    "{argv:?} must not swallow the subcommand as a filename, got {:?}",
                    cli.files
                );
            }
        }
    }

    #[test]
    fn upload_options_before_a_subcommand_are_refused() {
        // They parse — they are `Cli`'s own flatten — and then nothing reads them:
        // `paste` has its own copy and no other subcommand uploads. Refused rather
        // than dropped, which is the same rule `list --compress` gets from clap.
        for argv in [
            vec!["gitpic", "--compress", "paste"],
            vec!["gitpic", "--no-copy", "paste"],
            vec!["gitpic", "--name", "shot", "paste"],
            vec!["gitpic", "--repo", "o/r", "doctor"],
            vec!["gitpic", "--max-width", "800", "list"],
            vec!["gitpic", "-f", "url", "config", "get"],
            vec!["gitpic", "--compress", "auth", "login"],
        ] {
            let cli = Cli::try_parse_from(&argv).unwrap_or_else(|e| panic!("{argv:?}: {e}"));
            let err = cli
                .reject_misplaced_upload_args()
                .expect_err(&format!("{argv:?} must be refused"));
            assert_eq!(err.code, crate::error::ErrorCode::Usage);
        }
    }

    #[test]
    fn the_paths_that_do_use_upload_options_are_untouched() {
        for argv in [
            vec!["gitpic", "a.png", "--compress"],
            vec!["gitpic", "--stdin", "--name", "shot"],
            vec!["gitpic", "paste", "--no-copy"],
            vec!["gitpic", "doctor", "--repo", "o/r"],
            vec!["gitpic", "list", "--json"],
        ] {
            let cli = Cli::try_parse_from(&argv).unwrap_or_else(|e| panic!("{argv:?}: {e}"));
            cli.reject_misplaced_upload_args()
                .unwrap_or_else(|e| panic!("{argv:?} must be accepted: {}", e.message));
        }
        // The comparison the guard rests on: an untouched flatten is its default.
        assert!(!UploadArgs::default().any_set());
        assert!(Cli::try_parse_from(["gitpic", "a.png", "--quality", "80"])
            .unwrap()
            .upload
            .any_set());
    }

    #[test]
    fn list_rejects_upload_flags() {
        // The whole point of not making them global: clap, not a second list in
        // dispatch, is what refuses `gitpic list --compress`.
        for args in [
            vec!["gitpic", "list", "--compress"],
            vec!["gitpic", "list", "--no-copy"],
            vec!["gitpic", "list", "--stdin"],
            vec!["gitpic", "list", "--name", "x.png"],
            vec!["gitpic", "list", "--link", "raw"],
            vec!["gitpic", "list", "-f", "url"],
            vec!["gitpic", "list", "--no-compress"],
            vec!["gitpic", "list", "--max-width", "99"],
            vec!["gitpic", "list", "--quality", "50"],
            vec!["gitpic", "list", "-p", "t/{name}.{ext}"],
            vec!["gitpic", "list", "--repo", "o/r"],
        ] {
            assert!(
                Cli::try_parse_from(&args).is_err(),
                "{args:?} must not parse"
            );
        }
    }

    #[test]
    fn doctor_accepts_repo_and_rejects_upload_flags() {
        let cli = Cli::try_parse_from(["gitpic", "doctor", "--repo", "o/r", "--json"]).unwrap();
        assert!(
            matches!(cli.command, Some(Command::Doctor { ref repo }) if repo.as_deref() == Some("o/r"))
        );
        assert!(cli.json);
        assert!(Cli::try_parse_from(["gitpic", "doctor", "--compress"]).is_err());
    }

    #[test]
    fn global_flags_still_work_on_every_subcommand() {
        let cli = Cli::try_parse_from(["gitpic", "list", "--json", "-q", "-vv"]).unwrap();
        assert!(cli.json && cli.quiet && cli.verbose == 2);
        assert!(cli.repo_override().is_none());
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
            assert_eq!(cli.upload_args().quality, Some(q.parse().unwrap()));
        }
    }

    #[test]
    fn the_format_default_survives_becoming_an_option() {
        // `format` became `Option` so it could be told apart from its default;
        // md must still be what an unadorned upload produces.
        let cli = Cli::try_parse_from(["gitpic", "a.png"]).unwrap();
        assert_eq!(cli.upload_args().format, None);
        assert_eq!(
            cli.effective_format(&crate::config::Config::default()),
            OutputFormat::Md
        );
        let explicit = Cli::try_parse_from(["gitpic", "a.png", "-f", "url"]).unwrap();
        assert_eq!(
            explicit.effective_format(&crate::config::Config::default()),
            OutputFormat::Url
        );

        // With no flag, the file decides — and with a flag, the file does not get a
        // say. Both directions, because the whole value of `format` being an
        // `Option` is that these two cases stay separable.
        let mut cfg = crate::config::Config::default();
        cfg.upload.format = "html".to_string();
        assert_eq!(cli.effective_format(&cfg), OutputFormat::Html);
        assert_eq!(explicit.effective_format(&cfg), OutputFormat::Url);
    }

    #[test]
    fn paste_still_accepts_every_upload_option() {
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
        let u = cli.upload_args();
        assert!(u.no_copy && u.compress);
        assert_eq!(u.link, Some(LinkKind::Raw));
        assert_eq!(u.max_width, Some(800));
        assert_eq!(u.quality, Some(90));
        assert!(matches!(cli.command, Some(Command::Paste { .. })));
    }

    #[test]
    fn auth_login_takes_the_browser_flow_with_no_flags() {
        let cli = Cli::try_parse_from(["gitpic", "auth", "login"]).unwrap();
        match cli.command {
            Some(Command::Auth {
                action:
                    AuthAction::Login {
                        no_browser,
                        ref scope,
                        ref client_id,
                    },
            }) => {
                assert!(!no_browser);
                // Both unset here, and `oauth::scope` is what turns that into
                // `public_repo` — the flag stays an `Option` so "the user asked for
                // public_repo" and "nobody said anything" remain distinguishable.
                assert!(scope.is_none() && client_id.is_none());
            }
            ref other => panic!("expected auth login, got {other:?}"),
        }
    }

    #[test]
    fn auth_login_parses_its_overrides() {
        let cli = Cli::try_parse_from([
            "gitpic",
            "auth",
            "login",
            "--no-browser",
            "--scope",
            "repo",
            "--client-id",
            "Ov23liX",
        ])
        .unwrap();
        match cli.command {
            Some(Command::Auth {
                action:
                    AuthAction::Login {
                        no_browser,
                        ref scope,
                        ref client_id,
                    },
            }) => {
                assert!(no_browser);
                assert_eq!(scope.as_deref(), Some("repo"));
                assert_eq!(client_id.as_deref(), Some("Ov23liX"));
            }
            ref other => panic!("expected auth login, got {other:?}"),
        }
    }

    #[test]
    fn the_removed_credential_route_does_not_parse() {
        // `--with-token` was a real flag once. Left in place it would be accepted and
        // then ignored, which is the shape this project refuses everywhere else — and
        // silently doing nothing with a token someone piped in is the worst available
        // outcome, because the secret has already left its keychain.
        assert!(Cli::try_parse_from(["gitpic", "auth", "login", "--with-token"]).is_err());
    }

    #[test]
    fn auth_status_and_logout_parse() {
        assert!(matches!(
            Cli::try_parse_from(["gitpic", "auth", "status", "--json"])
                .unwrap()
                .command,
            Some(Command::Auth {
                action: AuthAction::Status
            })
        ));
        assert!(matches!(
            Cli::try_parse_from(["gitpic", "auth", "logout"])
                .unwrap()
                .command,
            Some(Command::Auth {
                action: AuthAction::Logout
            })
        ));
        // `auth` on its own names no action; clap must ask for one.
        assert!(Cli::try_parse_from(["gitpic", "auth"]).is_err());
    }

    #[test]
    fn config_set_accepts_several_pairs() {
        let cli = Cli::try_parse_from([
            "gitpic",
            "config",
            "set",
            "github.owner",
            "me",
            "github.repo",
            "pics",
        ])
        .unwrap();
        match cli.command {
            Some(Command::Config {
                action: ConfigAction::Set { pairs },
            }) => assert_eq!(pairs, vec!["github.owner", "me", "github.repo", "pics"]),
            other => panic!("expected config set, got {other:?}"),
        }
    }
}
