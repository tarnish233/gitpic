//! `gitpic skill` — install or print the bundled AI agent skill.

use super::prompt_opt;
use crate::cli::{AgentKind, SkillAction};
use crate::config;
use crate::error::{AppError, Result};
use crate::output::{ErrorBody, Mode};
use serde::Serialize;
use std::io::IsTerminal;
use std::path::{Path, PathBuf};

/// The skill document, embedded at compile time so an installed copy always
/// matches the running binary instead of drifting from it.
const SKILL_MD: &str = include_str!("../../skills/gitpic/SKILL.md");

/// Skill name — also the directory name agents discover the skill under.
const SKILL_NAME: &str = "gitpic";

/// Known agents: display name, home-dir env var, and `$HOME`-relative fallback.
const AGENTS: [(&str, &str, &str); 3] = [
    ("claude", "CLAUDE_CONFIG_DIR", ".claude"),
    ("codex", "CODEX_HOME", ".codex"),
    ("generic", "AGENT_HOME", ".agent"),
];

/// What writing to a target would do.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Action {
    Installed,
    Updated,
    Unchanged,
}

impl Action {
    fn as_str(self) -> &'static str {
        match self {
            Action::Installed => "installed",
            Action::Updated => "updated",
            Action::Unchanged => "already up to date",
        }
    }

    /// Short label for the interactive listing.
    fn label(self) -> &'static str {
        match self {
            Action::Installed => "new",
            // Not "outdated": `classify` returns this for *any* difference, and
            // SKILL.md carries no version, so a file the user edited by hand is
            // indistinguishable from a stale one. Calling it outdated is a claim about
            // their file that this cannot support.
            Action::Updated => "differs",
            Action::Unchanged => "up to date",
        }
    }
}

/// A resolved install target. Agents whose skills directories are symlinked to
/// the same place collapse into a single target with several `agents`.
struct Target {
    agents: Vec<&'static str>,
    path: PathBuf,
}

impl Target {
    fn agent_list(&self) -> String {
        self.agents.join(", ")
    }
}

/// Resolve `<skills_dir>/gitpic/SKILL.md` to a stable identity, following
/// symlinks as far as they exist so that two agents pointing at one real
/// directory are recognised as one target rather than written to twice.
fn resolve(skills_dir: &Path) -> PathBuf {
    // `--dir` pointed at the skill directory itself installs one level too deep and
    // reports success: `gitpic skill install --dir ~/.claude/skills/gitpic` — which is
    // the path `gitpic skill path` prints, and what shell completion offers — wrote
    // `.../gitpic/gitpic/SKILL.md`, said `✓ installed`, and no agent ever found it.
    // A directory already named `gitpic` is the skill directory, not a directory of
    // skills; nothing legitimate nests one inside the other.
    if skills_dir.file_name().and_then(|n| n.to_str()) == Some(SKILL_NAME) {
        if let Ok(real) = skills_dir.canonicalize() {
            return real.join("SKILL.md");
        }
        return skills_dir.join("SKILL.md");
    }
    let skill_dir = skills_dir.join(SKILL_NAME);
    if let Ok(real) = skill_dir.canonicalize() {
        return real.join("SKILL.md");
    }
    if let Ok(real) = skills_dir.canonicalize() {
        return real.join(SKILL_NAME).join("SKILL.md");
    }
    skill_dir.join("SKILL.md")
}

/// The `AGENTS` entry for one named agent.
///
/// `None` for `--agent all`, which means "every detected target" rather than one
/// named directory. Returning `Option` instead of panicking discharges the
/// hand-sync between `AgentKind` and `AGENTS` — and this binary is built with
/// `panic = "abort"`, where a panic exits 134, outside the documented 1-10 codes.
fn agent_entry(kind: AgentKind) -> Option<(&'static str, &'static str, &'static str)> {
    let want = match kind {
        AgentKind::Claude => "claude",
        AgentKind::Codex => "codex",
        AgentKind::Generic => "generic",
        AgentKind::All => return None,
    };
    AGENTS.iter().copied().find(|(name, _, _)| *name == want)
}

/// Installed agents, merged by real path.
///
/// Detection keys off the agent's *home* directory rather than its `skills`
/// subdirectory: a freshly installed agent has a home but no `skills` yet, and
/// refusing to install for it would be unhelpful. The subdirectory is created
/// on write.
fn detect() -> Result<Vec<Target>> {
    let mut out: Vec<Target> = Vec::new();
    for (name, env_var, fallback) in AGENTS {
        let home = config::base_dir(env_var, fallback)?;
        if !home.is_dir() {
            continue;
        }
        let path = resolve(&home.join("skills"));
        match out.iter_mut().find(|t| t.path == path) {
            Some(existing) => existing.agents.push(name),
            None => out.push(Target {
                agents: vec![name],
                path,
            }),
        }
    }
    Ok(out)
}

/// Compare the embedded document against what is already on disk.
fn classify(path: &Path) -> Result<Action> {
    match std::fs::read_to_string(path) {
        Ok(current) if current == SKILL_MD => Ok(Action::Unchanged),
        Ok(_) => Ok(Action::Updated),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(Action::Installed),
        Err(error) => Err(AppError::general(format!(
            "read skill {}: {error}",
            path.display()
        ))),
    }
}

fn write_skill(path: &Path, force: bool) -> Result<()> {
    // Atomic, not `fs::write`, which truncates and then writes: a crash or a full disk
    // partway through left a *truncated* SKILL.md in an agent's skills directory —
    // frontmatter intact, instructions cut off — which an agent then loads as a valid
    // document. `write_atomic` is the config writer's temp-and-rename without the
    // permission tightening, which must not be applied to a directory the user's agent
    // owns.
    if force {
        crate::config::write_atomic(path, SKILL_MD, "skill")
    } else {
        crate::config::write_new_atomic(path, SKILL_MD, "skill")
    }
}
/// Returns the process exit code.
///
/// `Result<u8>` rather than `Result<()>` for one reason: `skill install --agent all` can
/// half-succeed, and reporting that means printing the envelope *here* and still exiting
/// non-zero. Propagating an `Err` instead would have `main` print a second envelope onto
/// a stream the caller is parsing as one document — the same shape `upload`'s partial
/// report solves the same way.
pub fn run(action: &SkillAction, mode: Mode) -> Result<u8> {
    match action {
        SkillAction::Print => {
            if mode.is_json() {
                // SKILL.md is a document, so JSON mode carries it as a field rather
                // than dumping raw Markdown onto a stream the caller is parsing.
                crate::output::print_json(&PrintEnvelope {
                    ok: true,
                    name: SKILL_NAME,
                    version: env!("CARGO_PKG_VERSION"),
                    content: SKILL_MD,
                });
            } else {
                crate::output::raw(SKILL_MD);
                crate::output::finish();
            }
            Ok(0)
        }
        SkillAction::Path => run_path(mode),
        SkillAction::Install {
            agent,
            dir,
            yes,
            force,
        } => run_install(*agent, dir.as_deref(), *yes, *force, mode),
    }
}

#[derive(Serialize)]
struct PrintEnvelope<'a> {
    ok: bool,
    name: &'a str,
    version: &'a str,
    content: &'a str,
}

#[derive(Serialize)]
struct TargetItem {
    agents: Vec<&'static str>,
    action: &'static str,
    path: String,
}

#[derive(Serialize)]
struct PathEnvelope {
    ok: bool,
    name: &'static str,
    version: &'static str,
    targets: Vec<TargetItem>,
}

fn run_path(mode: Mode) -> Result<u8> {
    let targets = detect()?;
    if mode.is_json() {
        let env = PathEnvelope {
            ok: true,
            name: SKILL_NAME,
            version: env!("CARGO_PKG_VERSION"),
            targets: targets
                .iter()
                .map(|t| {
                    Ok(TargetItem {
                        agents: t.agents.clone(),
                        action: classify(&t.path)?.as_str(),
                        path: t.path.display().to_string(),
                    })
                })
                .collect::<Result<Vec<_>>>()?,
        };
        crate::output::print_json(&env);
        return Ok(0);
    }
    if targets.is_empty() {
        eprintln!("no agent skills directory detected; use --dir to name one");
        return Ok(0);
    }
    for t in &targets {
        crate::output::line(&t.path.display().to_string());
    }
    Ok(0)
}

#[derive(Serialize)]
struct InstalledItem {
    agents: Vec<&'static str>,
    action: &'static str,
    path: String,
}

#[derive(Serialize)]
struct InstallEnvelope {
    ok: bool,
    name: &'static str,
    version: &'static str,
    installed: Vec<InstalledItem>,
    /// Present exactly when `ok` is false, in the same shape every other subcommand
    /// uses — so a partly successful install carries both halves: what landed, and why
    /// the rest did not. This is `output::print_partial`'s shape applied to the one
    /// other command that can half-succeed.
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<ErrorBody>,
}

fn run_install(
    agent: Option<AgentKind>,
    dir: Option<&Path>,
    yes: bool,
    force: bool,
    mode: Mode,
) -> Result<u8> {
    let targets = choose_targets(agent, dir, yes, mode)?;
    if targets.is_empty() {
        // The user declined at the prompt; not an error.
        return Ok(0);
    }

    let mut installed = Vec::new();
    // Reported rather than propagated on the spot: `--agent all` with the second
    // directory unwritable used to write the first, return the error, and print nothing
    // but an error envelope — so the caller was never told that one target had in fact
    // been installed, and a re-run is the only way to find out. The first failure still
    // stops the loop and still decides the exit code; what changes is that what already
    // landed is said out loud.
    let mut failure = None;
    for t in &targets {
        let action = match classify(&t.path) {
            Ok(action) => action,
            Err(error) => {
                failure = Some(error);
                break;
            }
        };
        if action == Action::Updated && !force {
            failure = Some(AppError::general(format!(
                "refusing to replace differing skill at {}; inspect it and pass --force to overwrite",
                t.path.display()
            )));
            break;
        }
        if action != Action::Unchanged {
            if let Err(e) = write_skill(&t.path, force) {
                failure = Some(e);
                break;
            }
        }
        installed.push(InstalledItem {
            agents: t.agents.clone(),
            action: action.as_str(),
            path: t.path.display().to_string(),
        });
    }

    if mode.is_json() {
        let env = InstallEnvelope {
            ok: failure.is_none(),
            name: SKILL_NAME,
            version: env!("CARGO_PKG_VERSION"),
            installed,
            error: failure
                .as_ref()
                .map(|e: &AppError| ErrorBody::new(e.code.as_str(), &e.message)),
        };
        crate::output::print_json(&env);
        // The envelope *is* the report, so `main` must not print a second one; the
        // failure's own code still decides the exit status.
        return Ok(failure.map_or(0, |e| e.code.exit_code()));
    }

    for item in &installed {
        // `item` already carries its own agents, so there is no index
        // correspondence with `targets` to keep in step.
        let suffix = if item.agents.is_empty() {
            String::new()
        } else {
            format!("  ({})", item.agents.join(", "))
        };
        crate::output::line(&format!(
            "{} {} {SKILL_NAME} skill v{} \u{2192} {}{suffix}",
            crate::output::tick(),
            item.action,
            env!("CARGO_PKG_VERSION"),
            item.path,
        ));
    }
    // After the lines, so what landed is on screen before the reason the rest did not.
    // An `Err` is right here: `main` renders it as `error: <message>` on stderr, which
    // is a second *line*, not a second envelope.
    match failure {
        Some(e) => Err(e),
        None => Ok(0),
    }
}

/// Work out which targets to write, prompting only when the invocation did not
/// already name them.
fn choose_targets(
    agent: Option<AgentKind>,
    dir: Option<&Path>,
    yes: bool,
    mode: Mode,
) -> Result<Vec<Target>> {
    // An explicit directory is unambiguous — take it as given. It belongs to no
    // particular agent, so leave `agents` empty rather than inventing one.
    if let Some(d) = dir {
        return Ok(vec![Target {
            agents: Vec::new(),
            path: resolve(d),
        }]);
    }

    // A named agent is explicit too, so honour it even if the directory does
    // not exist yet (it gets created on write).
    if let Some((name, env_var, fallback)) = agent.and_then(agent_entry) {
        return Ok(vec![Target {
            agents: vec![name],
            path: resolve(&config::base_dir(env_var, fallback)?.join("skills")),
        }]);
    }

    let detected = detect()?;
    if detected.is_empty() {
        return Err(AppError::usage(
            "no agent skills directory detected; pass --dir <DIR> or --agent claude|codex|generic",
        ));
    }

    // `--agent all` and `--yes` both mean "every detected target".
    if yes || agent == Some(AgentKind::All) {
        return Ok(detected);
    }

    // Nothing named a target, so ask — but only when there is a human to ask.
    if mode.is_json() || !std::io::stdin().is_terminal() {
        return Err(AppError::usage(
            "not a terminal: pass --yes, --agent claude|codex|generic|all, or --dir <DIR>",
        ));
    }
    select_interactively(detected)
}

fn select_interactively(detected: Vec<Target>) -> Result<Vec<Target>> {
    crate::output::line(&format!(
        "gitpic skill v{} \u{2014} detected agent skill directories:\n",
        env!("CARGO_PKG_VERSION")
    ));
    let width = detected
        .iter()
        .map(|t| t.agent_list().len())
        .max()
        .unwrap_or(0);
    for (i, t) in detected.iter().enumerate() {
        let action = classify(&t.path)?;
        crate::output::line(&format!(
            "  [{}] {:width$}  {}  ({})",
            i + 1,
            t.agent_list(),
            t.path.display(),
            action.label(),
        ));
    }
    crate::output::line("");

    let choices = if detected.len() == 1 {
        "1".to_string()
    } else {
        format!("1-{}", detected.len())
    };
    // EOF (Ctrl-D) must abort rather than fall through to the "all" default —
    // this writes files, so a closed stdin is not consent.
    let Some(reply) = prompt_opt(&format!("install to? [{choices} / a=all / q=quit]"), "a")? else {
        crate::output::line("\naborted");
        return Ok(Vec::new());
    };

    match parse_selection(&reply, detected.len())? {
        Selection::Quit => {
            crate::output::line("aborted");
            Ok(Vec::new())
        }
        Selection::All => Ok(detected),
        Selection::Indices(picked) => Ok(detected
            .into_iter()
            .enumerate()
            .filter(|(i, _)| picked.contains(&(i + 1)))
            .map(|(_, t)| t)
            .collect()),
    }
}

/// What the reply at the install prompt asked for.
#[derive(Debug, PartialEq, Eq)]
enum Selection {
    All,
    Quit,
    /// 1-based target numbers, deduped and range-checked.
    Indices(Vec<usize>),
}

/// Parse a prompt reply against `n` offered targets. Kept separate from the
/// prompt itself so the accept/reject rules are unit-testable without a tty.
fn parse_selection(reply: &str, n: usize) -> Result<Selection> {
    let reply = reply.trim().to_ascii_lowercase();
    if reply == "q" {
        return Ok(Selection::Quit);
    }
    if reply == "a" {
        return Ok(Selection::All);
    }

    let mut picked: Vec<usize> = Vec::new();
    for tok in reply.split([',', ' ']).filter(|s| !s.is_empty()) {
        let idx: usize = tok
            .parse()
            .map_err(|_| AppError::usage(format!("not a valid choice: {tok}")))?;
        if idx == 0 || idx > n {
            return Err(AppError::usage(format!("choice out of range: {idx}")));
        }
        if !picked.contains(&idx) {
            picked.push(idx);
        }
    }
    if picked.is_empty() {
        return Err(AppError::usage("no choice made"));
    }
    Ok(Selection::Indices(picked))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_named_agent_resolves_to_an_agents_entry() {
        // Discharges the hand-sync between AgentKind and AGENTS that the old
        // `expect("every AgentKind has an AGENTS entry")` merely asserted.
        assert!(agent_entry(AgentKind::Claude).is_some());
        assert!(agent_entry(AgentKind::Codex).is_some());
        assert!(agent_entry(AgentKind::Generic).is_some());
        assert!(agent_entry(AgentKind::All).is_none());
    }
    use crate::error::ErrorCode;

    /// Guards the contract between the embedded document and the directory
    /// agents discover it under: if SKILL.md moves, is renamed, or its
    /// frontmatter breaks, this fails instead of shipping a broken skill.
    #[test]
    fn embedded_skill_frontmatter_matches_skill_name() {
        // First line only, so a CRLF checkout is not mistaken for a missing
        // frontmatter fence (.gitattributes pins this file to LF, but a local
        // override should surface as a real failure, not a confusing one).
        assert_eq!(
            SKILL_MD.lines().next(),
            Some("---"),
            "SKILL.md must open with YAML frontmatter"
        );
        let name = SKILL_MD
            .lines()
            .find_map(|line| line.strip_prefix("name:"))
            .map(str::trim)
            .expect("SKILL.md frontmatter must declare a name");
        assert_eq!(
            name, SKILL_NAME,
            "frontmatter name must match the skill directory name"
        );
    }

    #[test]
    fn embedded_skill_has_unix_line_endings() {
        // The document is compared byte-for-byte against installed copies, so a
        // CRLF build would disagree with a copy written anywhere else.
        assert!(
            !SKILL_MD.contains('\r'),
            "SKILL.md must use LF endings; check .gitattributes and core.autocrlf"
        );
    }

    #[test]
    fn embedded_skill_documents_json_usage() {
        // The skill is only useful to an agent if it keeps telling it to pass
        // --json/--no-copy; catch an accidental gutting of the document.
        assert!(SKILL_MD.contains("--json"));
        assert!(SKILL_MD.contains("--no-copy"));
    }

    #[test]
    fn resolve_appends_skill_dir_and_filename() {
        let p = resolve(Path::new("/nonexistent-root/skills"));
        assert!(p.ends_with("gitpic/SKILL.md"), "got {}", p.display());
    }

    #[test]
    fn classify_reports_installed_for_missing_file() {
        assert_eq!(
            classify(Path::new("/nonexistent-root/skills/gitpic/SKILL.md")).unwrap(),
            Action::Installed
        );
    }

    #[test]
    fn classify_reports_read_errors_instead_of_calling_them_missing() {
        let dir =
            std::env::temp_dir().join(format!("gitpic-skill-invalid-utf8-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("SKILL.md");
        std::fs::write(&path, [0xff, 0xfe]).unwrap();

        let error = classify(&path).expect_err("invalid UTF-8 is a read failure");
        assert_eq!(error.code, ErrorCode::General);
        assert!(error.message.contains("read skill"), "{}", error.message);

        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn selection_accepts_all_and_quit_case_insensitively() {
        assert_eq!(parse_selection("a", 2).unwrap(), Selection::All);
        assert_eq!(parse_selection(" A ", 2).unwrap(), Selection::All);
        assert_eq!(parse_selection("q", 2).unwrap(), Selection::Quit);
        assert_eq!(parse_selection("Q\n", 2).unwrap(), Selection::Quit);
    }

    #[test]
    fn selection_accepts_indices_in_either_separator() {
        assert_eq!(
            parse_selection("1,2", 2).unwrap(),
            Selection::Indices(vec![1, 2])
        );
        assert_eq!(
            parse_selection("2 1", 2).unwrap(),
            Selection::Indices(vec![2, 1])
        );
        assert_eq!(
            parse_selection("1", 1).unwrap(),
            Selection::Indices(vec![1])
        );
    }

    #[test]
    fn selection_dedupes_repeated_indices() {
        // Writing the same target twice would double-report it.
        assert_eq!(
            parse_selection("1,1,2", 2).unwrap(),
            Selection::Indices(vec![1, 2])
        );
    }

    #[test]
    fn selection_rejects_out_of_range_and_garbage() {
        // Regression: a bad reply must be a USAGE error, never a silent
        // fall-through to installing everything.
        for bad in ["0", "3", "7", "zz", "1,zz", "-1", ""] {
            let err = parse_selection(bad, 2)
                .err()
                .unwrap_or_else(|| panic!("{bad:?} should be rejected"));
            assert_eq!(err.code, ErrorCode::Usage, "for reply {bad:?}");
        }
    }
}
