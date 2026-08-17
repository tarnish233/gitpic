//! `gitpic skill` — install or print the bundled AI agent skill.

use super::prompt_opt;
use crate::cli::{AgentKind, SkillAction};
use crate::config;
use crate::error::{AppError, Result};
use crate::output::Mode;
use serde::Serialize;
use std::io::IsTerminal;
use std::path::{Path, PathBuf};

/// The skill document, embedded at compile time so an installed copy always
/// matches the running binary instead of drifting from it.
const SKILL_MD: &str = include_str!("../../skills/gitpic/SKILL.md");

/// Skill name — also the directory name agents discover the skill under.
const SKILL_NAME: &str = "gitpic";

/// Known agents: display name, home-dir env var, and `$HOME`-relative fallback.
const AGENTS: [(&str, &str, &str); 2] = [
    ("claude", "CLAUDE_CONFIG_DIR", ".claude"),
    ("codex", "CODEX_HOME", ".codex"),
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
            Action::Updated => "outdated",
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
fn classify(path: &Path) -> Action {
    match std::fs::read_to_string(path) {
        Ok(current) if current == SKILL_MD => Action::Unchanged,
        Ok(_) => Action::Updated,
        Err(_) => Action::Installed,
    }
}

fn write_skill(path: &Path) -> Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| AppError::general(format!("mkdir: {e}")))?;
    }
    std::fs::write(path, SKILL_MD).map_err(|e| AppError::general(format!("write skill: {e}")))
}

pub fn run(action: &SkillAction, mode: Mode) -> Result<()> {
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
            Ok(())
        }
        SkillAction::Path => run_path(mode),
        SkillAction::Install { agent, dir, yes } => run_install(*agent, dir.as_deref(), *yes, mode),
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
    path: String,
}

#[derive(Serialize)]
struct PathEnvelope {
    ok: bool,
    name: &'static str,
    version: &'static str,
    targets: Vec<TargetItem>,
}

fn run_path(mode: Mode) -> Result<()> {
    let targets = detect()?;
    if mode.is_json() {
        let env = PathEnvelope {
            ok: true,
            name: SKILL_NAME,
            version: env!("CARGO_PKG_VERSION"),
            targets: targets
                .iter()
                .map(|t| TargetItem {
                    agents: t.agents.clone(),
                    path: t.path.display().to_string(),
                })
                .collect(),
        };
        crate::output::print_json(&env);
        return Ok(());
    }
    if targets.is_empty() {
        eprintln!("no agent skills directory detected; use --dir to name one");
        return Ok(());
    }
    for t in &targets {
        crate::output::line(&t.path.display().to_string());
    }
    Ok(())
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
}

fn run_install(agent: Option<AgentKind>, dir: Option<&Path>, yes: bool, mode: Mode) -> Result<()> {
    let targets = choose_targets(agent, dir, yes, mode)?;
    if targets.is_empty() {
        // The user declined at the prompt; not an error.
        return Ok(());
    }

    let mut installed = Vec::new();
    for t in &targets {
        let action = classify(&t.path);
        if action != Action::Unchanged {
            write_skill(&t.path)?;
        }
        installed.push(InstalledItem {
            agents: t.agents.clone(),
            action: action.as_str(),
            path: t.path.display().to_string(),
        });
    }

    if mode.is_json() {
        let env = InstallEnvelope {
            ok: true,
            name: SKILL_NAME,
            version: env!("CARGO_PKG_VERSION"),
            installed,
        };
        crate::output::print_json(&env);
        return Ok(());
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
            "\u{2713} {} {SKILL_NAME} skill v{} \u{2192} {}{suffix}",
            item.action,
            env!("CARGO_PKG_VERSION"),
            item.path,
        ));
    }
    Ok(())
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
            "no agent skills directory detected; pass --dir <DIR> or --agent claude|codex",
        ));
    }

    // `--agent all` and `--yes` both mean "every detected target".
    if yes || agent == Some(AgentKind::All) {
        return Ok(detected);
    }

    // Nothing named a target, so ask — but only when there is a human to ask.
    if mode.is_json() || !std::io::stdin().is_terminal() {
        return Err(AppError::usage(
            "not a terminal: pass --yes, --agent claude|codex|all, or --dir <DIR>",
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
        crate::output::line(&format!(
            "  [{}] {:width$}  {}  ({})",
            i + 1,
            t.agent_list(),
            t.path.display(),
            classify(&t.path).label(),
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
            classify(Path::new("/nonexistent-root/skills/gitpic/SKILL.md")),
            Action::Installed
        );
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
