//! Configuration model + resolution.
//!
//! Priority (highest first): CLI flags > environment variables > config.toml
//!   Env vars: GITPIC_OWNER, GITPIC_REPO ("owner/name" or "name"),
//!             GITPIC_BRANCH, GITPIC_LINK (cdn|raw)
//!
//! Credentials are handled separately by `crate::auth`; configuration contains
//! only the upload target and upload preferences.

use crate::error::{AppError, Result};
use serde::{Deserialize, Serialize};
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

static TEMP_FILE_SEQUENCE: AtomicU64 = AtomicU64::new(0);

/// Every struct here carries `#[serde(default)]` at the container level, so a
/// missing key falls back to that type's `Default` impl — which is therefore the
/// single source of truth for defaults. Declaring them per-field as well would
/// let a generated config and a parsed one drift apart silently.
///
/// `deny_unknown_fields` is the other half of that: `config.toml` is meant to be
/// hand-edited (`gitpic config edit` opens it in `$EDITOR`), and without this a
/// misspelled key or section — `dedupe`, `[uplaod]` — parsed fine and did
/// nothing, with `config get` then showing the default as if the file had never
/// been touched. A typo is now a `CONFIG_INVALID` error naming the file.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(default, deny_unknown_fields)]
pub struct Config {
    pub github: GithubConfig,
    pub upload: UploadConfig,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct GithubConfig {
    pub owner: String,
    pub repo: String,
    pub branch: String,
}

impl Default for GithubConfig {
    fn default() -> Self {
        Self {
            owner: String::new(),
            repo: String::new(),
            branch: "main".to_string(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct UploadConfig {
    pub path_template: String,
    /// Which snippet syntax `--format` defaults to: `md` | `html` | `url`.
    ///
    /// Declared next to `link_kind` because the two answer the two halves of one
    /// question — how the snippet is wrapped, and which host it points at — and
    /// serde writes a generated config in declaration order.
    pub format: String,
    pub link_kind: String,
    pub dedup: bool,
    pub auto_copy: bool,
    pub compress: bool,
    pub max_width: u32,
    pub quality: u8,
}

impl Default for UploadConfig {
    fn default() -> Self {
        Self {
            path_template: "images/{year}/{month}/{hash8}-{name}.{ext}".to_string(),
            format: "md".to_string(),
            link_kind: "cdn".to_string(),
            dedup: true,
            auto_copy: true,
            compress: false,
            max_width: 0,
            quality: 82,
        }
    }
}

/// Read an env var, treating unset and blank alike.
///
/// Used for directory paths, where the value is passed through verbatim: a
/// leading or trailing space is legal in a filename, and silently reinterpreting
/// a path would be worse than honouring an odd one. Values bound for a request
/// URL go through `apply_env_with`, which additionally trims.
fn env_var(key: &str) -> Option<String> {
    std::env::var(key).ok().filter(|v| !v.trim().is_empty())
}

/// Resolve a base directory: prefer the given env var, else `$HOME/<fallback>`
/// (on Windows, fall back to `%USERPROFILE%`). Used for the XDG config/data dirs
/// and for agent home dirs such as `CLAUDE_CONFIG_DIR` / `CODEX_HOME`.
pub(crate) fn base_dir(key: &str, fallback: &str) -> Result<PathBuf> {
    // Absolute only, which is what the XDG spec says to do with a relative value:
    // ignore it. `XDG_CONFIG_HOME=.config` in a shell profile — an easy typo — made
    // every gitpic path *cwd-relative*, so `gitpic config set github.repo o/pics` in
    // one directory wrote a config that the same command one directory up reported
    // `CONFIG_MISSING` about. Since 0.16.0 that takes the credential with it, so a
    // login also stops being found depending on where you are standing. Falling back
    // is the same treatment `env_var` already gives a blank value.
    if let Some(v) = env_var(key).filter(|v| Path::new(v).is_absolute()) {
        return Ok(PathBuf::from(v));
    }
    let home = env_var("HOME")
        .or_else(|| env_var("USERPROFILE"))
        .ok_or_else(|| AppError::general("cannot resolve home directory"))?;
    let mut p = PathBuf::from(home);
    for part in fallback.split('/') {
        p.push(part);
    }
    Ok(p)
}

/// Check that a value destined for a URL path segment cannot change the URL's
/// shape or arrive padded. Empty is the caller's business — `owner` and `repo` are
/// legitimately empty before anything is configured.
fn check_segment(what: &str, value: &str) -> std::result::Result<(), String> {
    if value.is_empty() {
        return Ok(());
    }
    if value != value.trim() {
        return Err(format!(
            "{what} {value:?} has leading or trailing whitespace"
        ));
    }
    if value.contains('/') {
        return Err(format!("{what} {value:?} must not contain '/'"));
    }
    if value == "." || value == ".." {
        return Err(format!("{what} cannot be {value:?}"));
    }
    if value.chars().any(|c| c.is_whitespace() || c.is_control()) {
        return Err(format!(
            "{what} {value:?} must not contain whitespace or control characters"
        ));
    }
    Ok(())
}

/// A git ref may contain `/` (`feat/x`). It must not contain empty segments,
/// `.` / `..`, or whitespace — those deform `/branches/{branch}` even after
/// percent-encoding.
fn check_branch(value: &str) -> std::result::Result<(), String> {
    if value != value.trim() {
        return Err(format!(
            "github.branch {value:?} has leading or trailing whitespace"
        ));
    }
    if value.starts_with('/') || value.ends_with('/') {
        return Err(format!(
            "github.branch {value:?} must not start or end with '/'"
        ));
    }
    for seg in value.split('/') {
        if seg.is_empty() {
            return Err(format!(
                "github.branch {value:?} must not contain empty segments"
            ));
        }
        if seg == "." || seg == ".." {
            return Err(format!("github.branch cannot contain {seg:?}"));
        }
        if seg.chars().any(|c| c.is_whitespace() || c.is_control()) {
            return Err(format!(
                "github.branch {value:?} must not contain whitespace or control characters"
            ));
        }
    }
    Ok(())
}

impl Config {
    /// Check every value, whatever produced it.
    ///
    /// `deny_unknown_fields` guards key *names*; nothing guarded the values. A
    /// hand-edited `link_kind = "raw2"` or a `GITPIC_LINK=raw2` loaded fine and the
    /// lenient reader then served cdn links forever, and `config set
    /// github.owner "  me  "` produced a request against
    /// `/repos/%20%20me%20%20/repo` — the exact failure the env-var trimming was
    /// added to prevent, on the entry point it did not cover. One function, called
    /// from every entry point, is what keeps those from drifting apart again.
    ///
    /// Returns a bare message so each caller can attach the code that fits where
    /// the value came from: a file is `CONFIG_INVALID`, a flag or variable is a
    /// usage error.
    fn validate(&self) -> std::result::Result<(), String> {
        check_segment("github.owner", &self.github.owner)?;
        check_segment("github.repo", &self.github.repo)?;
        if self.github.branch.trim().is_empty() {
            return Err("github.branch must not be empty".to_string());
        }
        check_branch(&self.github.branch)?;
        if crate::link::parse_output_format_strict(&self.upload.format).is_none() {
            return Err(format!(
                "upload.format must be \"md\", \"html\" or \"url\", not {:?}",
                self.upload.format
            ));
        }
        if crate::link::parse_link_kind_strict(&self.upload.link_kind).is_none() {
            return Err(format!(
                "upload.link_kind must be \"cdn\" or \"raw\", not {:?}",
                self.upload.link_kind
            ));
        }
        if !(1..=100).contains(&self.upload.quality) {
            return Err(format!(
                "upload.quality must be 1-100, not {}",
                self.upload.quality
            ));
        }
        // `naming` owns both the dummy sample and the sentence; this names the field.
        if let Err(why) = crate::naming::check_template(&self.upload.path_template) {
            return Err(format!(
                "upload.path_template {:?} {why}",
                self.upload.path_template
            ));
        }
        Ok(())
    }

    /// [`Config::validate`] for values that came from the user *now* — a CLI flag,
    /// an environment variable, an `init` answer, a `config set` argument — where a
    /// bad value is a usage error rather than a broken file.
    ///
    /// Every writer and every override must go through one of these two wrappers.
    /// `--repo` and `init` did not, and each reintroduced on its own entry point
    /// exactly the failure the check exists to prevent: `--repo o/..` deformed the
    /// request URL into a bare 404, and `init` wrote a config that every later
    /// command — `init` included — then refused with `CONFIG_INVALID`.
    pub(crate) fn validate_input(&self) -> Result<()> {
        self.validate().map_err(AppError::usage)
    }

    /// Locate the config file: `$XDG_CONFIG_HOME/gitpic/config.toml`
    /// (falls back to `~/.config/gitpic/config.toml`). Does not require it to exist.
    pub fn path() -> Result<PathBuf> {
        Ok(base_dir("XDG_CONFIG_HOME", ".config")?
            .join("gitpic")
            .join("config.toml"))
    }

    /// Locate the upload-history file: `$XDG_DATA_HOME/gitpic/history.jsonl`
    /// (falls back to `~/.local/share/gitpic/history.jsonl`).
    pub fn history_path() -> Result<PathBuf> {
        Ok(base_dir("XDG_DATA_HOME", ".local/share")?
            .join("gitpic")
            .join("history.jsonl"))
    }

    /// Load config from disk, or return defaults if the file is missing.
    ///
    /// # Errors
    /// Returns `CONFIG_INVALID` when the file exists but cannot be read or
    /// parsed. A missing file is not an error — it means "nothing configured
    /// yet", which `require_target` reports as `CONFIG_MISSING` instead.
    pub fn load() -> Result<Self> {
        let path = Self::path()?;
        if !path.exists() {
            return Ok(Config::default());
        }
        let shown = path.display().to_string();
        let text = std::fs::read_to_string(&path).map_err(|e| {
            AppError::config_invalid(format!("cannot read config file {shown}: {e}"))
        })?;
        Self::parse(&text, &shown)
    }

    /// Parse config text, naming the offending file in any error.
    ///
    /// Split from the file read so the strictness rules are testable without
    /// mutating `XDG_CONFIG_HOME` across parallel test threads.
    fn parse(text: &str, shown: &str) -> Result<Self> {
        let cfg: Self = toml::from_str(text).map_err(|e| {
            // `toml::de::Error`'s Display output includes source text. Keep the
            // useful parser message without echoing config contents.
            AppError::config_invalid(format!(
                "cannot use config file {shown}: {}\nfix it with `gitpic config edit`",
                e.message()
            ))
        })?;
        cfg.validate().map_err(|msg| {
            AppError::config_invalid(format!(
                "cannot use config file {shown}: {msg}\nfix it with `gitpic config edit`"
            ))
        })?;
        Ok(cfg)
    }

    /// Persist config to disk (creating parent dirs) with a same-directory
    /// replace, so an interrupted write cannot leave a partial config behind.
    ///
    /// The file is created privately and atomically replaced from a same-directory
    /// temp file, so interrupted writes cannot leave partial configuration behind.
    pub fn save(&self) -> Result<PathBuf> {
        self.save_to(&Self::path()?)
    }

    fn save_to(&self, path: &Path) -> Result<PathBuf> {
        let text = toml::to_string_pretty(self)
            .map_err(|e| AppError::general(format!("serialize: {e}")))?;
        write_private_atomic(path, &text, "config")?;
        Ok(path.to_path_buf())
    }

    /// Apply environment variable overrides in-place.
    ///
    /// # Errors
    /// Returns a usage error if `GITPIC_REPO` is malformed.
    pub fn apply_env(&mut self) -> Result<()> {
        self.apply_env_with(|key| std::env::var(key).ok())
    }

    /// Apply overrides from an arbitrary variable lookup.
    ///
    /// Split from `std::env` so the normalization rules are testable without
    /// mutating the environment (unsound across parallel test threads) — the same
    /// seam as the other environment-independent parsers in this crate.
    ///
    /// Every variable here ends up inside a request URL, so each is trimmed and
    /// then dropped if nothing is left. Both halves are load-bearing:
    /// `GITPIC_OWNER=" "` used to pass `require_target()` and then request
    /// `/repos/%20/repo`, and a padded `GITPIC_OWNER=" me "` requested
    /// `/repos/%20me%20/repo` — each a confusing 404 rather than an actionable
    /// error, and each falling through to the config file is what the user meant.
    fn apply_env_with(&mut self, get: impl Fn(&str) -> Option<String>) -> Result<()> {
        let value = |key: &str| {
            get(key)
                .map(|v| v.trim().to_string())
                .filter(|v| !v.is_empty())
        };
        if let Some(v) = value("GITPIC_OWNER") {
            self.github.owner = v;
        }
        if let Some(v) = value("GITPIC_BRANCH") {
            self.github.branch = v;
        }
        if let Some(v) = value("GITPIC_LINK") {
            self.upload.link_kind = v;
        }
        if let Some(v) = value("GITPIC_REPO") {
            self.set_repo_spec(&v)?;
        }
        // Checked after the overrides, not per-variable: `GITPIC_LINK=raw2` used to
        // be accepted here and then read back leniently as cdn.
        self.validate_input()?;
        Ok(())
    }

    /// Accept "owner/name" or bare "name" (keeps existing owner).
    ///
    /// # Errors
    /// Returns a usage error when the spec has more than one `/`, since the
    /// extra segment would silently become part of the repo name and produce
    /// broken upload URLs.
    pub fn set_repo_spec(&mut self, spec: &str) -> Result<()> {
        let spec = spec.trim();
        if let Some((owner, repo)) = spec.split_once('/') {
            let (owner, repo) = (owner.trim(), repo.trim());
            if repo.contains('/') {
                return Err(AppError::usage(format!(
                    "invalid repo spec {spec:?}: expected \"owner/name\" or \"name\""
                )));
            }
            self.github.owner = owner.to_string();
            self.github.repo = repo.to_string();
        } else {
            self.github.repo = spec.to_string();
        }
        Ok(())
    }

    /// Ensure the upload target is configured.
    ///
    /// Named for what it checks: the credential is resolved separately by
    /// `crate::auth`, which reads its own file.
    pub fn require_target(&self) -> Result<()> {
        if self.github.owner.is_empty() || self.github.repo.is_empty() {
            // Never "log in", even though `gitpic auth login` is where the picker
            // lives: this fires just as often for someone already logged in who
            // skipped it, and telling them to re-authorise would mint a second token
            // to fix a config file. `repos` is the honest first step either way — it
            // resolves the credential itself, so an unauthenticated user gets the
            // login instruction from the command that actually needs one.
            return Err(AppError::config_missing(
                "missing target repo: `gitpic repos` lists your options and \
                 `gitpic config set github.repo owner/name` sets one \
                 (GITPIC_REPO=owner/name works too)",
            ));
        }
        Ok(())
    }
}

/// Write `text` to `path` privately and atomically: a 0700 parent, a 0600
/// same-directory temp file, then a rename over the destination.
///
/// See [`write_atomic`] for the same guarantees without the permissions.
///
/// Shared by `config.toml` and by the credential file [`crate::auth`] writes, which
/// is why it is one function rather than two copies of it. The config file is merely
/// private; `auth.toml` holds a GitHub token, so "0600 from before the first byte is
/// in it" and "never observable half-written" are properties that must not be
/// re-derived per call site.
pub(crate) fn write_private_atomic(path: &Path, text: &str, what: &str) -> Result<()> {
    write_atomic_inner(path, text, what, true)
}

/// [`write_private_atomic`] without the permissions: atomic, but not tightened.
///
/// For files gitpic writes *outside* its own config directory — `skill install` puts
/// `SKILL.md` under `~/.claude/skills`, which belongs to the user's agent. The
/// atomicity is what is wanted there (a truncate-then-write left a half-written skill
/// that an agent loads as a valid-but-lobotomised document), while chmod-ing that
/// directory to 0700 would be gitpic reaching outside its own house.
pub(crate) fn write_atomic(path: &Path, text: &str, what: &str) -> Result<()> {
    write_atomic_inner(path, text, what, false)
}

fn write_atomic_inner(path: &Path, text: &str, what: &str, private: bool) -> Result<()> {
    // Permissions are a Unix-only guarantee; still consume the policy flag on other
    // targets so their warnings-as-errors builds verify this shared implementation.
    #[cfg(not(unix))]
    let _ = private;

    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| AppError::general(format!("mkdir: {e}")))?;
        // The directory is created 0755 by `create_dir_all`; tighten it so the
        // file cannot be found by listing, not just by reading.
        #[cfg(unix)]
        if private {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(parent, std::fs::Permissions::from_mode(0o700));
        }
    }

    let temp_path = temporary_path(path);
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    if private {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }

    let write_result = (|| -> std::io::Result<()> {
        let mut file = options.open(&temp_path)?;
        file.write_all(text.as_bytes())?;
        file.flush()?;
        file.sync_all()?;

        #[cfg(unix)]
        if private {
            use std::os::unix::fs::PermissionsExt;
            file.set_permissions(fs::Permissions::from_mode(0o600))?;
        }
        drop(file);

        // Replaces an existing destination on Unix and on Windows
        // (`MoveFileExW(MOVEFILE_REPLACE_EXISTING)`). Unlinking first on
        // Windows left a window with no `config.toml`; `Config::load`
        // treats that as defaults.
        fs::rename(&temp_path, path)
    })();

    if let Err(error) = write_result {
        let _ = fs::remove_file(&temp_path);
        return Err(AppError::general(format!("write {what}: {error}")));
    }

    Ok(())
}

fn temporary_path(path: &Path) -> PathBuf {
    let sequence = TEMP_FILE_SEQUENCE.fetch_add(1, Ordering::Relaxed);
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("config.toml");
    path.with_file_name(format!(
        ".{file_name}.tmp-{}-{sequence}",
        std::process::id()
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::error::ErrorCode;

    #[test]
    fn repo_spec_accepts_owner_and_name() {
        let mut cfg = Config::default();
        cfg.set_repo_spec("owner/name").unwrap();
        assert_eq!(cfg.github.owner, "owner");
        assert_eq!(cfg.github.repo, "name");
    }

    #[test]
    fn repo_spec_bare_name_keeps_existing_owner() {
        let mut cfg = Config::default();
        cfg.github.owner = "keep".to_string();
        cfg.set_repo_spec("just-the-repo").unwrap();
        assert_eq!(cfg.github.owner, "keep");
        assert_eq!(cfg.github.repo, "just-the-repo");
    }

    #[test]
    fn repo_spec_rejects_extra_path_segments() {
        // Regression: "a/b/c" used to set repo="b/c", producing broken URLs.
        let mut cfg = Config::default();
        let err = cfg.set_repo_spec("a/b/c").expect_err("must be rejected");
        assert_eq!(err.code, ErrorCode::Usage);
        // The config must be left untouched by a rejected spec.
        assert_eq!(cfg.github.owner, "");
        assert_eq!(cfg.github.repo, "");
    }

    #[test]
    fn repo_spec_trims_whitespace() {
        let mut cfg = Config::default();
        cfg.set_repo_spec("  owner / name  ").unwrap();
        assert_eq!(cfg.github.owner, "owner");
        assert_eq!(cfg.github.repo, "name");
    }

    #[test]
    fn incomplete_repo_spec_is_caught_by_require_target() {
        // "owner/" parses, but require_target must still reject the empty repo.
        let mut cfg = Config::default();
        cfg.set_repo_spec("owner/").unwrap();
        assert_eq!(
            cfg.require_target().unwrap_err().code,
            ErrorCode::ConfigMissing
        );
    }

    #[test]
    fn generated_config_contains_no_token_key() {
        let toml = toml::to_string_pretty(&Config::default()).unwrap();
        assert!(!toml.contains("token"), "{toml}");
    }

    #[test]
    fn a_config_with_no_keys_parses_to_exactly_the_defaults() {
        // Container-level `#[serde(default)]` makes the `Default` impls the only
        // source of defaults. This pins parsing and generation together for
        // every field, including any added later.
        let parsed: Config = toml::from_str("").expect("an empty config is valid");
        assert_eq!(
            toml::to_string_pretty(&parsed).unwrap(),
            toml::to_string_pretty(&Config::default()).unwrap()
        );
    }

    #[test]
    fn a_misspelled_key_is_rejected_instead_of_ignored() {
        // Regression: `dedupe = false` parsed fine and did nothing, and
        // `config get` then printed `dedup = true` as if the file were untouched.
        // config.toml is hand-edited (`config edit`), so a typo must be loud.
        let err = Config::parse("[upload]\ndedupe = false\n", "/tmp/config.toml")
            .expect_err("an unknown key must be rejected");
        assert_eq!(err.code, ErrorCode::ConfigInvalid);
        assert!(err.message.contains("dedupe"), "{}", err.message);
        // Naming the file and the way out is the whole point of a distinct code:
        // `gitpic config edit` still works when `load()` refuses the file.
        assert!(err.message.contains("/tmp/config.toml"), "{}", err.message);
        assert!(err.message.contains("config edit"), "{}", err.message);
    }

    #[test]
    fn a_misspelled_section_is_rejected_too() {
        // `[uplaod]` used to be dropped whole, silently discarding every key in
        // it — the same failure as a bad key, one level up.
        let err = Config::parse("[uplaod]\nlink_kind = \"raw\"\n", "/tmp/config.toml")
            .expect_err("an unknown section must be rejected");
        assert_eq!(err.code, ErrorCode::ConfigInvalid);
        assert!(err.message.contains("uplaod"), "{}", err.message);
    }

    #[test]
    fn bad_toml_syntax_is_config_invalid_not_general() {
        // Exit 1 / GENERAL is the catch-all that also covers clipboard and
        // encoding failures, so an agent cannot act on it. A broken config file
        // has one specific remedy and therefore its own code.
        let err = Config::parse("[github", "/tmp/config.toml").expect_err("must be rejected");
        assert_eq!(err.code, ErrorCode::ConfigInvalid);
    }

    #[test]
    fn removed_token_key_is_rejected_without_echoing_its_value() {
        let secret = "ghp_DO_NOT_PRINT_THIS_SECRET";
        let text = format!("[github]\ntoken = \"{secret}\"\n");
        let err = Config::parse(&text, "/tmp/config.toml").expect_err("must be rejected");
        assert_eq!(err.code, ErrorCode::ConfigInvalid);
        assert!(!err.message.contains(secret), "{}", err.message);
        assert!(err.message.contains("token"), "{}", err.message);
        assert!(err.message.contains("config edit"), "{}", err.message);
    }

    #[test]
    fn save_replaces_an_existing_config_without_leaving_a_temp_file() {
        let dir = std::env::temp_dir().join(format!(
            "gitpic-config-save-{}-{}",
            std::process::id(),
            TEMP_FILE_SEQUENCE.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("config.toml");
        fs::write(&path, "old partial contents").unwrap();

        let mut config = Config::default();
        config.github.owner = "owner".to_string();
        config.github.repo = "repo".to_string();
        config.save_to(&path).unwrap();

        let saved = fs::read_to_string(&path).unwrap();
        assert!(saved.contains("owner = \"owner\""), "{saved}");
        assert!(saved.contains("repo = \"repo\""), "{saved}");
        assert_eq!(fs::read_dir(&dir).unwrap().count(), 1, "temp file survived");

        fs::remove_dir_all(&dir).ok();
    }

    #[cfg(unix)]
    #[test]
    fn saved_config_is_private_on_unix() {
        use std::os::unix::fs::PermissionsExt;

        let dir = std::env::temp_dir().join(format!(
            "gitpic-config-mode-{}-{}",
            std::process::id(),
            TEMP_FILE_SEQUENCE.fetch_add(1, Ordering::Relaxed)
        ));
        let path = dir.join("config.toml");
        Config::default().save_to(&path).unwrap();

        let mode = fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);

        fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn a_config_gitpic_itself_wrote_is_accepted_by_the_strict_parser() {
        // deny_unknown_fields must not reject our own output — that would brick
        // every existing install on upgrade.
        let generated = toml::to_string_pretty(&Config::default()).unwrap();
        Config::parse(&generated, "/tmp/config.toml").expect("round-trip must parse");
    }

    /// Build a lookup over a fixed table, standing in for the environment.
    fn env_of(pairs: &'static [(&'static str, &'static str)]) -> impl Fn(&str) -> Option<String> {
        move |key| {
            pairs
                .iter()
                .find(|(k, _)| *k == key)
                .map(|(_, v)| v.to_string())
        }
    }

    #[test]
    fn env_overrides_are_trimmed_before_reaching_a_url() {
        // Regression: the blank filter looked at the trimmed value but stored the
        // untrimmed one, so `GITPIC_OWNER=" me "` became owner=" me " and
        // requested `/repos/%20me%20/repo`.
        let mut cfg = Config::default();
        cfg.apply_env_with(env_of(&[
            ("GITPIC_OWNER", "  me  "),
            ("GITPIC_BRANCH", "\tdev\n"),
            ("GITPIC_LINK", " raw "),
        ]))
        .unwrap();
        assert_eq!(cfg.github.owner, "me");
        assert_eq!(cfg.github.branch, "dev");
        assert_eq!(cfg.upload.link_kind, "raw");
    }

    #[test]
    fn a_blank_env_override_falls_through_to_the_config() {
        // An exported-but-empty variable must not wipe a configured value.
        let mut cfg = Config::default();
        cfg.github.owner = "from-config".to_string();
        cfg.apply_env_with(env_of(&[("GITPIC_OWNER", "   ")]))
            .unwrap();
        assert_eq!(cfg.github.owner, "from-config");
        assert_eq!(
            cfg.github.branch, "main",
            "an unset variable changes nothing"
        );
    }

    #[test]
    fn a_malformed_env_repo_spec_is_still_rejected() {
        let mut cfg = Config::default();
        let err = cfg
            .apply_env_with(env_of(&[("GITPIC_REPO", " a/b/c ")]))
            .expect_err("must be rejected");
        assert_eq!(err.code, ErrorCode::Usage);
    }

    #[test]
    fn the_default_config_passes_its_own_validation() {
        // If it did not, every fresh install would refuse to start.
        Config::default()
            .validate()
            .expect("defaults must be valid");
    }

    #[test]
    fn a_bad_link_kind_is_rejected_from_the_file_and_the_environment() {
        // Regression: `config set upload.link_kind raw2` was refused, but the same
        // value reached the same field unchecked through a hand-edited file or
        // GITPIC_LINK — and the lenient reader then served cdn links forever.
        let err = Config::parse("[upload]\nlink_kind = \"raw2\"\n", "/tmp/c.toml")
            .expect_err("the file must be rejected too");
        assert_eq!(err.code, ErrorCode::ConfigInvalid);
        assert!(err.message.contains("link_kind"), "{}", err.message);

        let mut cfg = Config::default();
        let err = cfg
            .apply_env_with(env_of(&[("GITPIC_LINK", "raw2")]))
            .expect_err("the variable must be rejected too");
        assert_eq!(err.code, ErrorCode::Usage);
    }

    #[test]
    fn a_bad_output_format_is_rejected_from_the_file() {
        // Same hole `link_kind` had, one key later: a value the reader shrugged at
        // would make `config set upload.format htlm` report success and then hand
        // back Markdown forever.
        let err = Config::parse("[upload]\nformat = \"htlm\"\n", "/tmp/c.toml")
            .expect_err("the file must be rejected");
        assert_eq!(err.code, ErrorCode::ConfigInvalid);
        assert!(err.message.contains("format"), "{}", err.message);

        // The three the flag accepts are the three the file accepts, spelled the
        // same way — that agreement is the point of `parse_output_format_strict`.
        for good in ["md", "html", "url", "HTML", " url "] {
            let toml = format!("[upload]\nformat = {good:?}\n");
            Config::parse(&toml, "/tmp/c.toml")
                .unwrap_or_else(|e| panic!("format {good:?} must be accepted: {}", e.message));
        }
    }

    #[test]
    fn the_default_format_is_markdown_and_writes_no_surprise_into_a_new_file() {
        assert_eq!(Config::default().upload.format, "md");
        // Generated next to link_kind, because they answer the two halves of one
        // question and a config file is read by people.
        let toml = toml::to_string_pretty(&Config::default()).unwrap();
        let format_at = toml.find("format").expect("format is written out");
        let link_at = toml.find("link_kind").expect("link_kind is written out");
        assert!(format_at < link_at, "{toml}");
    }

    #[test]
    fn an_owner_that_would_deform_the_url_is_rejected() {
        // Regression: only the env path trimmed, so `config set github.owner
        // "  me  "` still produced `/repos/%20%20me%20%20/repo`, and `..` silently
        // removed a path segment from the request.
        for bad in ["  me  ", "..", ".", "a/b", "me\tx"] {
            let toml = format!("[github]\nowner = {bad:?}\n");
            let err = Config::parse(&toml, "/tmp/c.toml")
                .err()
                .unwrap_or_else(|| panic!("owner {bad:?} must be rejected"));
            assert_eq!(err.code, ErrorCode::ConfigInvalid, "for {bad:?}");
            assert!(err.message.contains("owner"), "{}", err.message);
        }
        // An ordinary owner, and the unconfigured empty one, both stay valid.
        Config::parse("[github]\nowner = \"tarnish233\"\n", "/tmp/c.toml").expect("valid");
        Config::parse("[github]\nowner = \"\"\n", "/tmp/c.toml").expect("empty is unconfigured");
    }

    #[test]
    fn an_empty_branch_is_rejected() {
        // It reached `?ref=` and `"branch":""`, which GitHub answers with a 422 that
        // maps to the GENERAL catch-all an agent cannot act on.
        let err = Config::parse("[github]\nbranch = \"\"\n", "/tmp/c.toml")
            .expect_err("must be rejected");
        assert_eq!(err.code, ErrorCode::ConfigInvalid);
        assert!(err.message.contains("branch"), "{}", err.message);
    }

    #[test]
    fn a_branch_with_a_slash_is_a_legal_git_ref() {
        Config::parse("[github]\nbranch = \"feat/x\"\n", "/tmp/c.toml")
            .expect("feat/x is a legal branch");
        let err = Config::parse("[github]\nbranch = \"feat//x\"\n", "/tmp/c.toml")
            .expect_err("empty segments are not a ref");
        assert_eq!(err.code, ErrorCode::ConfigInvalid);
    }

    #[test]
    fn an_out_of_range_quality_in_the_file_is_rejected_not_clamped() {
        // `config set upload.quality 0` errored while the file silently reached
        // `clamp(1, 100)` — the same silent clamp `--quality 0` was fixed for.
        for bad in ["0", "200"] {
            let toml = format!("[upload]\nquality = {bad}\n");
            let err = Config::parse(&toml, "/tmp/c.toml")
                .expect_err(&format!("quality {bad} must be rejected"));
            assert_eq!(err.code, ErrorCode::ConfigInvalid);
        }
        Config::parse("[upload]\nquality = 1\n", "/tmp/c.toml").expect("1 is valid");
        Config::parse("[upload]\nquality = 100\n", "/tmp/c.toml").expect("100 is valid");
    }

    #[test]
    fn a_traversing_path_template_in_the_file_is_rejected() {
        let err = Config::parse(
            "[upload]\npath_template = \"../../etc/{name}.{ext}\"\n",
            "/tmp/c.toml",
        )
        .expect_err("must be rejected");
        assert_eq!(err.code, ErrorCode::ConfigInvalid);
    }

    #[test]
    fn a_repo_spec_from_a_flag_is_validated_like_one_from_anywhere_else() {
        // Regression: `--repo` is the highest-priority source and was the only
        // unvalidated one. `set_repo_spec` trims the halves but cannot judge what
        // is left, so `o/..` and `o/re po` were accepted and deformed the request
        // URL — a bare 404 — while the identical value in the file or in
        // GITPIC_REPO was refused with a message naming the field.
        for bad in ["o/..", "o/re po", "o/a\tb", ".."] {
            let mut cfg = Config::default();
            cfg.github.owner = "o".to_string();
            cfg.set_repo_spec(bad)
                .unwrap_or_else(|_| panic!("{bad:?} parses as a spec"));
            let err = cfg
                .validate_input()
                .expect_err(&format!("--repo {bad:?} must be rejected"));
            assert_eq!(err.code, ErrorCode::Usage, "for {bad:?}");
        }
        // An ordinary override still goes through.
        let mut cfg = Config::default();
        cfg.set_repo_spec("owner/pics").unwrap();
        cfg.validate_input().expect("a normal --repo must work");
    }
}
