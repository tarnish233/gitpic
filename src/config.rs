//! Configuration model + resolution.
//!
//! Priority (highest first): CLI flags > environment variables > config.toml
//!   Env vars: GITPIC_OWNER, GITPIC_REPO ("owner/name" or "name"),
//!             GITPIC_BRANCH, GITPIC_LINK (cdn|raw)
//!
//! The credential is deliberately absent from that list. `GITPIC_TOKEN` is read
//! by `crate::auth`, which owns the whole credential chain — so no token is ever
//! stored in this struct, which derives `Debug`.

use crate::error::{AppError, Result};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

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
    /// Legacy inline token. Still honoured, and still takes priority over `gh`,
    /// but omitted when empty so a generated config carries no secret at all.
    #[serde(skip_serializing_if = "String::is_empty")]
    pub token: String,
    pub owner: String,
    pub repo: String,
    pub branch: String,
}

impl Default for GithubConfig {
    fn default() -> Self {
        Self {
            token: String::new(),
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
    if let Some(v) = env_var(key) {
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

/// Create (or truncate) `path` with owner-only permissions and write `data`.
///
/// The mode is applied by `open`, not afterwards, so the file is never readable
/// by anyone else — not even for the instant between creation and a chmod. On
/// Windows there is no mode to set; the file inherits the directory's ACL, which
/// is the platform's own answer to this.
fn write_private(path: &std::path::Path, data: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    let mut opts = std::fs::OpenOptions::new();
    opts.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        opts.mode(0o600);
    }
    let mut f = opts.open(path)?;
    f.write_all(data)?;
    // Durability: the rename that follows only guarantees atomicity of the
    // *name*, not that the bytes reached disk first.
    f.sync_all()
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

impl Config {
    /// [`Config::validate`] for callers outside this module — `config set`, which
    /// has to apply exactly the same rules as the file and the environment.
    pub(crate) fn validate_public(&self) -> std::result::Result<(), String> {
        self.validate()
    }

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
        check_segment("github.branch", &self.github.branch)?;
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
        // Rendered, because that is what an upload actually uses and what
        // `is_safe_remote_path` is written against.
        let sample =
            crate::naming::render_path(&self.upload.path_template, "sample.png", &"0".repeat(64));
        if !crate::naming::is_safe_remote_path(&sample) {
            return Err(format!(
                "upload.path_template {:?} must be repo-relative with no empty or `..` segments (renders to {sample:?})",
                self.upload.path_template
            ));
        }
        Ok(())
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
    /// mutating `XDG_CONFIG_HOME` (unsound across the parallel test runner) —
    /// the same seam as `history::parse_recent` and `auth::resolve_with`.
    fn parse(text: &str, shown: &str) -> Result<Self> {
        let cfg: Self = toml::from_str(text).map_err(|e| {
            AppError::config_invalid(format!(
                "cannot use config file {shown}: {}\nfix it with `gitpic config edit`",
                e.to_string().trim_end()
            ))
        })?;
        cfg.validate().map_err(|msg| {
            AppError::config_invalid(format!(
                "cannot use config file {shown}: {msg}\nfix it with `gitpic config edit`"
            ))
        })?;
        Ok(cfg)
    }

    /// Persist config to disk (creating parent dirs).
    ///
    /// The file may still hold a legacy `github.token`, so it is created `0600`
    /// from its first byte rather than written and then chmod'd: `fs::write` uses
    /// the default `0666 & !umask`, which under a typical `umask 022` means the
    /// file is world-readable for the window between the write and the chmod, and
    /// stays that way if the process dies in between. The permission error is
    /// propagated for the same reason — swallowing it left a readable token behind
    /// with no indication anything was wrong.
    ///
    /// Written to a temp file and renamed so a crash mid-write cannot truncate a
    /// working config, and the temp file carries the same mode so the secret is
    /// never briefly exposed under a different name either.
    pub fn save(&self) -> Result<PathBuf> {
        let path = Self::path()?;
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|e| AppError::general(format!("mkdir: {e}")))?;
            // The directory is created 0755 by `create_dir_all`; tighten it so the
            // config cannot be found by listing, not just by reading.
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                let _ = std::fs::set_permissions(parent, std::fs::Permissions::from_mode(0o700));
            }
        }
        let text = toml::to_string_pretty(self)
            .map_err(|e| AppError::general(format!("serialize: {e}")))?;

        let tmp = path.with_extension("toml.tmp");
        write_private(&tmp, text.as_bytes())
            .map_err(|e| AppError::general(format!("write config: {e}")))?;
        if let Err(e) = std::fs::rename(&tmp, &path) {
            let _ = std::fs::remove_file(&tmp);
            return Err(AppError::general(format!("write config: {e}")));
        }
        Ok(path)
    }

    /// Apply environment variable overrides in-place.
    ///
    /// `GITPIC_TOKEN` is deliberately not handled here — `crate::auth` is its
    /// sole reader, which keeps the credential out of this struct entirely.
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
    /// seam as `auth::resolve_with`.
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
        self.validate().map_err(AppError::usage)?;
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
    /// Named for what it checks: the *target*, not the credential. The
    /// credential is resolved separately by `crate::auth`, which may have to run
    /// `gh`, so its availability cannot be known synchronously. A caller needing
    /// both must do both — see `commands::upload::run`.
    pub fn require_target(&self) -> Result<()> {
        if self.github.owner.is_empty() || self.github.repo.is_empty() {
            return Err(AppError::config_missing(
                "missing target repo (set GITPIC_REPO=owner/name or run `gitpic init`)",
            ));
        }
        Ok(())
    }
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
    fn an_empty_token_is_not_written_back_to_disk() {
        // Both READMEs promise a generated config carries no `token` key, so a
        // synced dotfiles repo never gains a secret-shaped placeholder.
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
    fn a_config_gitpic_itself_wrote_is_accepted_by_the_strict_parser() {
        // deny_unknown_fields must not reject our own output — that would brick
        // every existing install on upgrade.
        let generated = toml::to_string_pretty(&Config::default()).unwrap();
        Config::parse(&generated, "/tmp/config.toml").expect("round-trip must parse");

        // And with the optional token key present, which Default omits.
        let mut with_token = Config::default();
        with_token.github.token = "t".to_string();
        let rendered = toml::to_string_pretty(&with_token).unwrap();
        Config::parse(&rendered, "/tmp/config.toml").expect("a token key must parse");
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
}
