//! `--json` is a contract, so it is checked by running the real binary.
//!
//! The shipped skill tells agents to always pass `--json`, which makes any
//! subcommand that ignores it a broken promise rather than a cosmetic gap:
//! `gitpic config path --json` printed a bare path and `gitpic skill print --json`
//! printed raw Markdown, so an agent parsing stdout got a parse error instead of a
//! result. A unit test cannot catch that — the flag is honoured (or not) in the
//! wiring between `dispatch` and each command's renderer — so these spawn the
//! built executable and parse what actually comes out of stdout.
//!
//! Everything runs against a temporary `XDG_CONFIG_HOME`/`XDG_DATA_HOME`, and only
//! commands that touch no network are exercised.

use std::path::{Path, PathBuf};
use std::process::Command;

/// A sandbox with a valid config, so commands get past `require_target`.
struct Sandbox {
    dir: PathBuf,
}

impl Sandbox {
    fn new(tag: &str) -> Self {
        let dir = std::env::temp_dir().join(format!("gitpic-json-{}-{tag}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("cfg/gitpic")).expect("mkdir cfg");
        std::fs::create_dir_all(dir.join("data/gitpic")).expect("mkdir data");
        std::fs::write(
            dir.join("cfg/gitpic/config.toml"),
            "[github]\nowner = \"someone\"\nrepo = \"pics\"\n",
        )
        .expect("write config");
        std::fs::write(dir.join("data/gitpic/history.jsonl"), "").expect("write history");
        Self { dir }
    }

    fn run(&self, args: &[&str]) -> (String, String, i32) {
        self.spawn(args, None, &[])
    }

    /// Same, with `input` written to the child's stdin — the only way to drive a
    /// command that reads it, and the only way to prove one does not.
    fn run_with_stdin(&self, args: &[&str], input: &str) -> (String, String, i32) {
        self.spawn(args, Some(input), &[])
    }

    /// [`Sandbox::run`] with extra variables for this one run.
    fn run_with_env(&self, args: &[&str], env: &[(&str, &str)]) -> (String, String, i32) {
        self.spawn(args, None, env)
    }

    /// [`Sandbox::run_with_stdin`] with extra variables for this one run.
    fn run_with_stdin_env(
        &self,
        args: &[&str],
        input: &str,
        env: &[(&str, &str)],
    ) -> (String, String, i32) {
        self.spawn(args, Some(input), env)
    }

    fn spawn(
        &self,
        args: &[&str],
        input: Option<&str>,
        env: &[(&str, &str)],
    ) -> (String, String, i32) {
        use std::io::Write;
        let mut cmd = Command::new(env!("CARGO_BIN_EXE_gitpic"));
        cmd.args(args)
            .env("XDG_CONFIG_HOME", self.dir.join("cfg"))
            .env("XDG_DATA_HOME", self.dir.join("data"))
            .env_remove("GITPIC_REPO")
            .env_remove("GITPIC_OWNER")
            .env_remove("GITPIC_BRANCH")
            .env_remove("GITPIC_LINK")
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped());
        // Applied after the removals, never instead of them: a test that needs one
        // variable — a stripped `PATH`, an agent home — gets that one and still
        // inherits the isolation for the rest, which is what keeps every other test
        // repeatable on a machine that exports the `GITPIC_*` ones.
        for (key, value) in env {
            cmd.env(key, value);
        }
        let out = match input {
            None => {
                cmd.stdin(std::process::Stdio::null());
                cmd.output().expect("the binary runs")
            }
            Some(text) => {
                cmd.stdin(std::process::Stdio::piped());
                let mut child = cmd.spawn().expect("the binary runs");
                child
                    .stdin
                    .take()
                    .expect("stdin is piped")
                    .write_all(text.as_bytes())
                    .expect("write stdin");
                child.wait_with_output().expect("the binary finishes")
            }
        };
        (
            String::from_utf8_lossy(&out.stdout).to_string(),
            String::from_utf8_lossy(&out.stderr).to_string(),
            out.status.code().unwrap_or(-1),
        )
    }
}

impl Drop for Sandbox {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn parse(stdout: &str, what: &str) -> serde_json::Value {
    serde_json::from_str(stdout)
        .unwrap_or_else(|e| panic!("`{what}` did not produce JSON on stdout: {e}\n---\n{stdout}"))
}

#[test]
fn every_offline_subcommand_produces_json_when_asked() {
    let sb = Sandbox::new("ok");
    // Each of these was, or could become, a command that quietly ignored --json.
    for args in [
        vec!["config", "path", "--json"],
        vec!["config", "get", "--json"],
        vec!["config", "get", "upload.link_kind", "--json"],
        vec!["config", "set", "upload.quality", "90", "--json"],
        vec![
            "config",
            "set",
            "upload.quality",
            "80",
            "upload.compress",
            "true",
            "--json",
        ],
        vec!["list", "--json"],
        vec!["skill", "print", "--json"],
        vec!["skill", "path", "--json"],
    ] {
        let label = args.join(" ");
        let (stdout, _stderr, code) = sb.run(&args);
        assert_eq!(code, 0, "`{label}` should succeed");
        let v = parse(&stdout, &label);
        assert_eq!(
            v.get("ok").and_then(|b| b.as_bool()),
            Some(true),
            "`{label}` must report ok: true, got {v}"
        );
    }
}

/// One process, several keys, one save — and every key on disk afterwards.
///
/// Its own sandbox, deliberately. This used to ride along at the end of the loop
/// above, where `upload.quality` is also written by the single-pair entry: the
/// assertion held only because the batch happened to be listed second, so
/// reordering that array would have failed here with a message blaming batching
/// for someone else's write.
#[test]
fn a_batch_config_set_lands_every_key() {
    let sb = Sandbox::new("batch-set");
    let (stdout, _, code) = sb.run(&[
        "config",
        "set",
        "upload.quality",
        "80",
        "upload.compress",
        "true",
        "github.branch",
        "gh-pages",
        "--json",
    ]);
    assert_eq!(code, 0, "batch set must succeed: {stdout}");
    let v = parse(&stdout, "batch config set");
    assert_eq!(v.get("ok").and_then(|b| b.as_bool()), Some(true), "{v}");
    // `changes` carries every key; `key`/`value` are the single-pair compatibility
    // fields and must stay absent when there is more than one.
    assert_eq!(
        v.get("changes").and_then(|c| c.as_array()).map(Vec::len),
        Some(3),
        "{v}"
    );
    assert!(v.get("key").is_none() && v.get("value").is_none(), "{v}");

    for (key, want) in [
        ("upload.quality", "80"),
        ("upload.compress", "true"),
        ("github.branch", "gh-pages"),
    ] {
        let (got, _, code) = sb.run(&["config", "get", key]);
        assert_eq!(code, 0, "reading back {key}: {got}");
        assert_eq!(got.trim(), want, "{key} must be on disk");
    }
}

/// `gitpic --json list` and `gitpic list --json` must be one invocation.
///
/// They were not. `args_conflicts_with_subcommands` says what this project wanted —
/// upload options and a subcommand are not usable together — but it also stops clap
/// from looking for a subcommand once *any* top-level argument has been seen, the
/// globals included. So every global-first form parsed the subcommand's own name as
/// a **filename**: `gitpic --json doctor` answered `NOT_FOUND: file not found:
/// doctor`, exit 6, having quietly become an upload nobody asked for. Both orders
/// are what a person or a script types, which is why this is pinned on the real
/// binary and not only on `Cli`.
#[test]
fn a_global_flag_before_the_subcommand_is_the_same_invocation() {
    let sb = Sandbox::new("global-first");
    for sub in [
        vec!["list"],
        vec!["config", "get"],
        vec!["config", "path"],
        vec!["skill", "path"],
    ] {
        let mut global_first = vec!["--json"];
        global_first.extend(sub.iter().copied());
        let mut global_last = sub.clone();
        global_last.push("--json");

        let (before, _, code_before) = sb.run(&global_first);
        let (after, _, code_after) = sb.run(&global_last);
        assert_eq!(
            (code_before, parse(&before, "global first")),
            (code_after, parse(&after, "global last")),
            "`{global_first:?}` and `{global_last:?}` must agree"
        );
        assert_eq!(code_before, 0, "`{global_first:?}` must succeed: {before}");
    }
}

/// The other half of the same rule: an upload option *before* a subcommand is
/// refused rather than parsed and then ignored, since `paste` reads its own copy
/// and nothing else uploads.
#[test]
fn an_upload_option_before_a_subcommand_is_usage() {
    let sb = Sandbox::new("misplaced-upload-flag");
    for args in [
        vec!["--no-copy", "paste", "--json"],
        vec!["--repo", "o/r", "doctor", "--json"],
        vec!["--max-width", "800", "list", "--json"],
    ] {
        let (stdout, _, code) = sb.run(&args);
        assert_eq!(code, 2, "`{args:?}` must be a usage refusal: {stdout}");
        assert_eq!(
            parse(&stdout, "misplaced upload option")
                .pointer("/error/code")
                .and_then(|v| v.as_str()),
            Some("USAGE"),
            "{stdout}"
        );
    }
}

#[test]
fn a_json_error_is_a_json_envelope_on_stdout() {
    let sb = Sandbox::new("err");
    // An agent parsing stdout has to get an envelope for failures too, not prose
    // on stderr and an empty stdout.
    for (args, want_code) in [
        (vec!["config", "get", "no.such.key", "--json"], 2),
        (vec!["config", "set", "github.token", "legacy", "--json"], 2),
        (vec!["config", "set", "upload.quality", "0", "--json"], 2),
        (
            vec!["config", "set", "github.owner", "me", "leftover", "--json"],
            2,
        ),
    ] {
        let label = args.join(" ");
        let (stdout, _stderr, code) = sb.run(&args);
        assert_eq!(code, want_code, "`{label}` exit code");
        let v = parse(&stdout, &label);
        assert_eq!(v.get("ok").and_then(|b| b.as_bool()), Some(false), "{v}");
        assert!(
            v.pointer("/error/code").and_then(|c| c.as_str()).is_some(),
            "`{label}` must carry error.code: {v}"
        );
    }
}

#[test]
fn removed_config_token_is_rejected_without_leaking_its_value() {
    let sb = Sandbox::new("redact");
    std::fs::write(
        sb.dir.join("cfg/gitpic/config.toml"),
        "[github]\ntoken = \"ghp_do_not_print_me\"\nowner = \"someone\"\nrepo = \"pics\"\n",
    )
    .expect("write config");
    let (stdout, stderr, code) = sb.run(&["config", "get", "--json"]);
    assert_eq!(code, 10);
    assert!(
        !stdout.contains("ghp_do_not_print_me") && !stderr.contains("ghp_do_not_print_me"),
        "config diagnostic leaked the removed token:\n{stdout}\n{stderr}"
    );
    let body = parse(&stdout, "config get --json");
    assert_eq!(
        body.pointer("/error/code").and_then(|v| v.as_str()),
        Some("CONFIG_INVALID")
    );
}

/// No path in the crate spawns `gh`.
///
/// The behavioural test below cannot catch the fallback being restored: it depends on
/// the machine having an *authenticated* `gh`, and a CI runner ships one that is not
/// logged in, so it would pass identically either way. This does not — the fallback
/// cannot come back without a spawn. Same shape as `output.rs`'s
/// `no_module_writes_to_stdout_outside_this_one`, and for the same reason: some rules
/// are about the source, not about an invocation.
#[test]
fn nothing_in_the_crate_spawns_gh() {
    fn walk(dir: &Path, found: &mut Vec<String>) {
        let entries = std::fs::read_dir(dir).expect("the crate's own source is readable");
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                walk(&path, found);
            } else if path.extension().is_some_and(|e| e == "rs") {
                let text = std::fs::read_to_string(&path).expect("readable");
                for (i, line) in text.lines().enumerate() {
                    // The spawn, not the word: `gh` appears legitimately in prose that
                    // explains why the fallback was removed.
                    if line.contains("Command::new(\"gh\")") {
                        found.push(format!("{}:{}", path.display(), i + 1));
                    }
                }
            }
        }
    }
    let mut found = Vec::new();
    walk(
        &Path::new(env!("CARGO_MANIFEST_DIR")).join("src"),
        &mut found,
    );
    assert!(
        found.is_empty(),
        "the credential has one source; these spawn `gh`: {found:?}"
    );
}

/// `gitpic auth login` is the only way in: neither the environment nor `gh` can
/// supply a credential.
///
/// **`PATH` is deliberately left intact.** On a developer machine `gh` really is
/// installed and logged in, so this run would have authenticated before the
/// fallback was removed — and would then have gone on to probe GitHub. That it now
/// reports no credential is the removal, observed. It also keeps the file's
/// no-network rule: with nothing to authenticate as, no request is built.
#[test]
fn neither_gh_nor_the_environment_can_supply_a_credential() {
    let sb = Sandbox::new("one-source");
    let out = Command::new(env!("CARGO_BIN_EXE_gitpic"))
        .args(["doctor", "--json"])
        .env("XDG_CONFIG_HOME", sb.dir.join("cfg"))
        .env("XDG_DATA_HOME", sb.dir.join("data"))
        .env("GITPIC_TOKEN", "ghp_legacy_value_must_not_be_used")
        .output()
        .expect("the binary runs");
    assert_eq!(out.status.code(), Some(3));
    let stdout = String::from_utf8_lossy(&out.stdout);
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        !stdout.contains("ghp_legacy") && !stderr.contains("ghp_legacy"),
        "the ignored variable was echoed:\n{stdout}\n{stderr}"
    );
    let body = parse(&stdout, "doctor --json");
    assert_eq!(
        body.get("token_valid").and_then(|v| v.as_bool()),
        Some(false)
    );
    // Provenance is gone with the second source; a field whose value could only
    // ever be "gitpic" would restate what the command already is.
    assert_eq!(body.get("token_source"), None, "{stdout}");
    let message = body
        .pointer("/error/message")
        .and_then(|v| v.as_str())
        .unwrap_or_default();
    assert!(message.contains("gitpic auth login"), "{message}");
    assert!(
        !message.contains("gh auth"),
        "gh is gone; sending the user to install it is a dead end: {message}"
    );
}

/// A stored token reaches no output stream, on the one command that reads the file
/// without needing a network.
///
/// An unconfigured target is what keeps this off the network: `doctor` settles on
/// `CONFIG_MISSING` before it would probe GitHub, having read the credential file on
/// the way there.
#[test]
fn a_stored_credential_is_never_echoed() {
    let sb = Sandbox::new("auth-hygiene");
    std::fs::write(sb.dir.join("cfg/gitpic/config.toml"), "").expect("write config");
    std::fs::write(
        sb.dir.join("cfg/gitpic/auth.toml"),
        "token = \"ghu_stored_must_not_be_printed\"\nlogin = \"octocat\"\n",
    )
    .expect("write credential");

    let (stdout, stderr, code) = sb.run(&["doctor", "--json"]);
    assert_eq!(code, 3, "an unconfigured target is still CONFIG_MISSING");
    assert!(
        !stdout.contains("ghu_stored") && !stderr.contains("ghu_stored"),
        "doctor leaked the stored token:\n{stdout}\n{stderr}"
    );
    // This is the whole reason the test stays offline, so assert it rather than leave
    // it to the blank config above: with a target configured, a run holding a
    // credential probes api.github.com, and this file promises it never does.
    let body = parse(&stdout, "doctor --json");
    assert_eq!(
        body.get("config_ok").and_then(|v| v.as_bool()),
        Some(false),
        "a configured target here would send the stored token to GitHub"
    );
}

#[test]
fn auth_status_without_a_credential_names_the_only_way_in() {
    let sb = Sandbox::new("auth-status-none");
    // Nothing stored, so resolution fails before a request is ever built — nothing
    // here touches the network. `PATH` is untouched: `gh` being installed and logged
    // in must make no difference any more.
    let (stdout, _, code) = sb.run(&["auth", "status", "--json"]);
    assert_eq!(code, 3);
    let body = parse(&stdout, "auth status --json");
    assert_eq!(
        body.pointer("/error/code").and_then(|v| v.as_str()),
        Some("CONFIG_MISSING")
    );
    let message = body
        .pointer("/error/message")
        .and_then(|v| v.as_str())
        .unwrap_or_default();
    assert!(message.contains("gitpic auth login"), "{message}");
    assert!(!message.contains("gh auth"), "{message}");
}

/// `--with-token` is refused at the CLI boundary.
///
/// Leaving it parseable would be the "accepted, then silently dropped" shape this
/// project closes everywhere else, and here it is worse than usual: quietly discarding
/// a token someone piped in means the secret has already left its keychain with nothing
/// to say it went nowhere.
///
/// There is no test for `auth login --json` itself in this file, and deliberately so:
/// it now *streams* rather than refusing, which means running it reaches github.com —
/// and every test here promises not to. The stream's shape is pinned in
/// `commands::auth_cmd`'s own tests, where it is pure serialisation.
#[test]
fn the_removed_credential_flag_is_refused() {
    let sb = Sandbox::new("auth-removed-flags");
    let args = ["auth", "login", "--with-token", "--json"];
    let (stdout, _, code) = sb.run_with_stdin(&args, "ghp_should_never_be_read");
    assert_eq!(code, 2);
    assert!(
        !stdout.contains("ghp_should_never_be_read"),
        "stdin was echoed:\n{stdout}"
    );
    let body = parse(&stdout, "auth login --json");
    assert_eq!(
        body.pointer("/error/code").and_then(|v| v.as_str()),
        Some("USAGE")
    );
}

#[test]
fn auth_logout_is_idempotent_and_a_logout_really_logs_out() {
    let sb = Sandbox::new("auth-logout");

    // Nothing stored: not an error, because "there is no credential" is the state
    // the caller asked for.
    let (stdout, _, code) = sb.run(&["auth", "logout", "--json"]);
    assert_eq!(code, 0);
    let body = parse(&stdout, "auth logout --json");
    assert_eq!(body.get("removed").and_then(|v| v.as_bool()), Some(false));

    // With one stored, it goes away for real.
    let auth = sb.dir.join("cfg/gitpic/auth.toml");
    std::fs::write(&auth, "token = \"ghu_x\"\n").expect("write credential");
    let (stdout, _, code) = sb.run(&["auth", "logout", "--json"]);
    assert_eq!(code, 0);
    let body = parse(&stdout, "auth logout --json");
    assert_eq!(body.get("removed").and_then(|v| v.as_bool()), Some(true));
    assert!(!auth.exists(), "the credential file must be gone");

    // And with no second source behind it, the next run has no credential at all —
    // which is what makes `logout` mean what it says.
    let (stdout, _, code) = sb.run(&["auth", "status", "--json"]);
    assert_eq!(code, 3, "{stdout}");
}

/// `gitpic init` is gone, and nothing may still be sending people to it.
///
/// Two halves, because either one passes on its own while the other is broken. That the
/// subcommand no longer parses is the easy half. The hard half is that its name was
/// baked into the `CONFIG_MISSING` messages `doctor` and `Config::require_target`
/// publish *as the remedy* — so removing the command without them turns the advice for
/// the single most common first-run failure into a subcommand clap rejects with USAGE.
///
/// So the same test that proves the command is gone also reads the message an
/// unconfigured user actually receives, and requires it to name something that exists.
/// That is the half worth having: an agent following code 3's published remedy would
/// otherwise be handed a subcommand that no longer resolves.
/// It stays off the network by leaving the sandbox with neither a target nor a
/// credential: `doctor` skips all three probes when the target is missing.
#[test]
fn the_removed_setup_command_is_gone_from_the_cli_and_from_its_own_remedies() {
    let sb = Sandbox::new("no-init");

    // `NOT_FOUND`, not `USAGE`: `Cli` takes positional filenames and deliberately does
    // not set `args_conflicts_with_subcommands`, so a word that is no longer a
    // subcommand is read as a file to upload. That is how every mistyped subcommand
    // already behaves (`gitpic doctr` says the same), and pinning it here is the honest
    // record of what someone with the old habit now sees.
    let cfg_file = sb.dir.join("cfg/gitpic/config.toml");
    let before = std::fs::read_to_string(&cfg_file).expect("the sandbox config exists");
    let (stdout, _stderr, code) = sb.run(&["init", "--json"]);
    assert_eq!(
        code, 6,
        "`init` is a filename now, and there is no such file\n{stdout}"
    );
    let v = parse(&stdout, "init --json");
    assert_eq!(
        v.pointer("/error/code").and_then(|c| c.as_str()),
        Some("NOT_FOUND"),
        "{v}"
    );
    // The part that would be a real bug: it must not still be *configuring* anything.
    assert_eq!(
        std::fs::read_to_string(&cfg_file).expect("config still readable"),
        before,
        "`init` must no longer be able to write a config"
    );

    // Nothing configured, so `require_target` fails and `doctor` reports it without
    // probing.
    std::fs::write(sb.dir.join("cfg/gitpic/config.toml"), "[github]\n").expect("empty config");
    let (stdout, _stderr, code) = sb.run(&["doctor", "--json"]);
    assert_eq!(
        code, 3,
        "an unconfigured target is CONFIG_MISSING\n{stdout}"
    );
    let v = parse(&stdout, "doctor --json");
    let detail = v
        .get("detail")
        .and_then(|d| d.as_str())
        .unwrap_or_default()
        .to_string();
    assert!(
        !detail.contains("gitpic init"),
        "the remedy names a command that no longer parses: {detail}"
    );
    assert!(
        detail.contains("gitpic config set github.repo"),
        "the remedy has to name a way to set a target: {detail}"
    );
}

/// No prompt is ever answered from a pipe — the rule, checked end to end.
///
/// This used to drive `init`, which took typed answers and could be fed a stdin it
/// should not read from. `init` is gone and its list now lives inside `auth login`,
/// which cannot be reached without a browser; the remaining drivable prompt is
/// `skill install`'s, and it turns out to give the *stronger*
/// guarantee — it refuses a non-terminal stdin outright rather than reading it and then
/// deciding. That is what is pinned here, because it is the property that makes the
/// hazard unreachable: `skill install`'s prompt defaults to `a=all`, so a question
/// nobody saw would install files into every detected agent directory.
///
/// The narrower rule — a prompt whose *text* was thrown away is never answered — has no
/// integration vehicle left and is covered by `commands::tests`, which drives it through
/// the same `stdout_lost` flag a real broken pipe sets.
#[test]
fn no_prompt_is_answered_from_a_pipe() {
    let sb = Sandbox::new("pipe-prompt");
    let agent_home = sb.dir.join("claude");
    let installed = agent_home.join("skills/gitpic/SKILL.md");
    std::fs::create_dir_all(agent_home.join("skills")).expect("mkdir agent home");
    let env: &[(&str, &str)] = &[("CLAUDE_CONFIG_DIR", agent_home.to_str().expect("utf-8"))];

    // A piped answer, which is exactly what must not be read. `Sandbox::run_with_stdin`
    // gives the child a pipe, so `stdin().is_terminal()` is false.
    let (stdout, stderr, code) = sb.run_with_stdin_env(&["skill", "install"], "1\n", env);
    assert_eq!(code, 2, "a pipe is not consent\n{stdout}\n{stderr}");
    assert!(
        !installed.is_file(),
        "nothing may be installed from an answer nobody could have given"
    );
    // And it says which explicit forms do work, rather than only refusing.
    let said = format!("{stdout}{stderr}");
    assert!(said.contains("--yes"), "{said}");
    assert!(said.contains("--dir"), "{said}");

    // The same run with the choice made explicitly installs, which is what proves the
    // refusal above is about the *prompt* and not about a broken sandbox.
    let (stdout, stderr, code) =
        sb.run_with_stdin_env(&["skill", "install", "--agent", "claude", "-y"], "", env);
    assert_eq!(code, 0, "an explicit target installs\n{stdout}\n{stderr}");
    assert!(installed.is_file(), "and it lands inside the sandbox");
}

#[test]
fn quiet_mode_prints_only_machine_usable_lines() {
    let sb = Sandbox::new("quiet");
    // Empty history: `--quiet` used to print "no uploads recorded yet", prose a
    // script would have to filter out.
    let (stdout, _, code) = sb.run(&["list", "--quiet"]);
    assert_eq!(code, 0);
    assert!(stdout.is_empty(), "expected nothing, got {stdout:?}");

    // With records, exactly one URL per line and nothing else.
    let rec = r#"{"time":"2026-08-18T00:00:00+08:00","name":"a","path":"p","url":"https://example.test/a.png","sha":"s","size":1,"deduped":false}"#;
    std::fs::write(
        sb.dir.join("data/gitpic/history.jsonl"),
        format!("{rec}\n{rec}\n"),
    )
    .expect("write history");
    let (stdout, _, code) = sb.run(&["list", "--quiet"]);
    assert_eq!(code, 0);
    let lines: Vec<&str> = stdout.lines().collect();
    assert_eq!(lines, ["https://example.test/a.png"; 2]);
}

/// Unix-only: both the failure and the mechanism are Unix-shaped. Rust ignores
/// SIGPIPE, which is why the write returned an error and `println!` turned it into
/// an abort; and the check itself needs a shell with `PIPESTATUS` to read the
/// *producer's* exit code rather than the consumer's.
#[cfg(unix)]
#[test]
fn a_closed_reader_is_not_a_crash() {
    // `gitpic list | head` panicked on the broken pipe, and with `panic = "abort"`
    // that is exit 134 — outside the documented 1-10 contract, with a raw Rust
    // panic on stderr. Driven through a shell so the pipe is real.
    let sb = Sandbox::new("pipe");
    let rec = r#"{"time":"2026-08-18T00:00:00+08:00","name":"a","path":"p","url":"https://example.test/a.png","sha":"s","size":1,"deduped":false}"#;
    let many: String = (0..3000).map(|_| format!("{rec}\n")).collect();
    std::fs::write(sb.dir.join("data/gitpic/history.jsonl"), many).expect("write history");

    for sub in [
        "list --limit 3000",
        "list --json",
        "completion bash",
        "skill print",
        "config get",
    ] {
        // `head -1` reads one line then closes; `true` closes immediately. Both
        // reproduced 134 before, at different points in the write sequence.
        for consumer in ["head -1", "true"] {
            let script = format!(
                "'{}' {sub} 2>/dev/null | {consumer} >/dev/null; exit ${{PIPESTATUS[0]}}",
                env!("CARGO_BIN_EXE_gitpic")
            );
            let status = Command::new("bash")
                .arg("-c")
                .arg(&script)
                .env("XDG_CONFIG_HOME", sb.dir.join("cfg"))
                .env("XDG_DATA_HOME", sb.dir.join("data"))
                .status()
                .expect("bash runs");
            let code = status.code().unwrap_or(-1);
            assert_eq!(
                code, 0,
                "`gitpic {sub} | {consumer}` should exit 0, got {code}"
            );
        }
    }
}

/// Regression: `print_error` also writes stdout under `--json`. Exiting 0 on a
/// broken pipe there turned USAGE/CONFIG_* into success as soon as the consumer
/// went away — `gitpic config get no.such.key --json | true` printed 0.
#[cfg(unix)]
#[test]
fn a_closed_reader_does_not_zero_an_error_exit() {
    let sb = Sandbox::new("pipe-err");
    let script = format!(
        "'{}' config get no.such.key --json 2>/dev/null | true >/dev/null; exit ${{PIPESTATUS[0]}}",
        env!("CARGO_BIN_EXE_gitpic")
    );
    let status = Command::new("bash")
        .arg("-c")
        .arg(&script)
        .env("XDG_CONFIG_HOME", sb.dir.join("cfg"))
        .env("XDG_DATA_HOME", sb.dir.join("data"))
        .status()
        .expect("bash runs");
    let code = status.code().unwrap_or(-1);
    assert_eq!(code, 2, "USAGE must survive a closed stdout, got {code}");
}

/// The complement of `a_closed_reader_does_not_zero_an_error_exit`: that one locks
/// "a closed reader must not turn an error into 0", this one locks "a closed reader
/// must not turn an unseen question into a yes".
///
/// `printf 'someone/pics\nmain\ncdn\n' | gitpic init | true` threw every prompt
/// into the closed pipe, read the piped answers anyway, and wrote
/// `owner="someone" repo="pics" branch="main"` to config.toml — a saved
/// configuration for three questions the user was never shown one of.
///
/// Unix-only for both of its neighbours' reasons: EPIPE is what the write returns
/// (Rust ignores SIGPIPE), and reading the *producer's* status out of a pipeline
/// needs a shell with `PIPESTATUS`.
#[cfg(unix)]
#[test]
fn name_with_two_files_is_usage_not_a_silent_drop() {
    // `--name` used to be accepted on a multi-file upload and then ignored.
    let sb = Sandbox::new("name-two");
    let a = sb.dir.join("a.png");
    let b = sb.dir.join("b.png");
    std::fs::write(&a, b"x").unwrap();
    std::fs::write(&b, b"y").unwrap();
    let a_s = a.to_str().unwrap();
    let b_s = b.to_str().unwrap();
    let (stdout, _, code) = sb.run(&[a_s, b_s, "--name", "shot.png", "--json"]);
    assert_eq!(code, 2);
    let body = parse(&stdout, "two files --name");
    assert_eq!(
        body.pointer("/error/code").and_then(|v| v.as_str()),
        Some("USAGE")
    );
}

/// A cdn link on a branch containing `/` used to be a stderr warning followed by a
/// success envelope holding a jsDelivr URL that 404s: `repo@feat/x/a.png` cannot be
/// split back into ref and path. The image was already committed by then, so the
/// only output that mattered was the one nobody could use.
///
/// Exit **2** is what makes this test mean anything. The target is configured, so a
/// run that got past the guard walks on to `auth::token()` and reports
/// `CONFIG_MISSING` — exit 3 — which the `--link raw` half below shows happening
/// for real. 2 therefore says the refusal came from the guard, and came before the
/// credential was so much as asked for; 3 would say the guard is gone or this
/// config was never read.
///
/// `PATH` is emptied to keep the child from finding anything at all: it keeps the 3
/// a deterministic local
/// failure, and it means a future regression here fails the test instead of
/// attempting a live upload to someone else's repository.
#[test]
fn a_cdn_link_that_would_404_is_refused_before_any_credential() {
    let sb = Sandbox::new("cdn-branch");
    // `GITPIC_BRANCH` and `GITPIC_LINK` are stripped from every run, so the two
    // values under test have to come from the file the run reads.
    std::fs::write(
        sb.dir.join("cfg/gitpic/config.toml"),
        "[github]\nowner = \"someone\"\nrepo = \"pics\"\nbranch = \"feat/x\"\n\n\
         [upload]\nlink_kind = \"cdn\"\n",
    )
    .expect("write config");
    let shot = sb.dir.join("shot.png");
    std::fs::write(&shot, b"x").expect("write image");
    let shot_arg = shot.to_str().expect("utf-8 path");
    let empty_path = sb.dir.join("empty-path");
    std::fs::create_dir_all(&empty_path).expect("mkdir empty-path");
    // What makes the exit 3 deterministic is that the sandbox has no `auth.toml`,
    // not this: there is no longer any tool on `PATH` that could supply a credential.
    let no_path: &[(&str, &str)] = &[("PATH", empty_path.to_str().expect("utf-8 path"))];

    let (stdout, _, code) = sb.run_with_env(&[shot_arg, "--json"], no_path);
    assert_eq!(
        code, 2,
        "a dead cdn link is a usage refusal, not a credential problem: {stdout}"
    );
    let body = parse(&stdout, "cdn upload on a branch with a slash");
    assert_eq!(
        body.get("ok").and_then(|v| v.as_bool()),
        Some(false),
        "{body}"
    );
    assert_eq!(
        body.pointer("/error/code").and_then(|v| v.as_str()),
        Some("USAGE")
    );
    // Agents tell a total failure from a partial one by the presence of `results`,
    // and the old behaviour is exactly what would put a dead URL in there.
    assert!(
        body.get("results").is_none(),
        "nothing was uploaded, so there is no results key: {body}"
    );

    // The same run with the one value the guard looks at changed. Reaching
    // CONFIG_MISSING proves the config above was loaded and every check before
    // `auth::token()` passed — so the 2 above came from the guard and nowhere else.
    let (stdout, _, code) = sb.run_with_env(&[shot_arg, "--link", "raw", "--json"], no_path);
    assert_eq!(
        code, 3,
        "raw links are unambiguous, so this one runs on to the credential: {stdout}"
    );
    assert_eq!(
        parse(&stdout, "raw upload on the same branch")
            .pointer("/error/code")
            .and_then(|v| v.as_str()),
        Some("CONFIG_MISSING")
    );
}

/// `--path ../x/{name}.{ext}` used to pass `require_target` and then wait until
/// after `auth::token()` (and the file read) to fail the per-file
/// `is_safe_remote_path` check. Exit **2** is what makes this test mean anything:
/// the target is configured, so a run that got past the guard walks on to
/// `auth::token()` and reports `CONFIG_MISSING` — exit 3 — which the safe
/// `--path` half below shows happening for real.
///
/// `PATH` is emptied to keep the child from finding anything at all: it keeps the 3
/// a deterministic local
/// failure, and it means a future regression here fails the test instead of
/// attempting a live upload to someone else's repository.
#[test]
fn an_escaping_path_template_is_refused_before_any_credential() {
    let sb = Sandbox::new("path-template");
    let shot = sb.dir.join("shot.png");
    std::fs::write(&shot, b"x").expect("write image");
    let shot_arg = shot.to_str().expect("utf-8 path");
    let empty_path = sb.dir.join("empty-path");
    std::fs::create_dir_all(&empty_path).expect("mkdir empty-path");
    // What makes the exit 3 deterministic is that the sandbox has no `auth.toml`,
    // not this: there is no longer any tool on `PATH` that could supply a credential.
    let no_path: &[(&str, &str)] = &[("PATH", empty_path.to_str().expect("utf-8 path"))];

    let (stdout, _, code) = sb.run_with_env(
        &[shot_arg, "--path", "../x/{name}.{ext}", "--json"],
        no_path,
    );
    assert_eq!(
        code, 2,
        "an escaping --path is a usage refusal, not a credential problem: {stdout}"
    );
    let body = parse(&stdout, "upload with a traversing --path");
    assert_eq!(
        body.get("ok").and_then(|v| v.as_bool()),
        Some(false),
        "{body}"
    );
    assert_eq!(
        body.pointer("/error/code").and_then(|v| v.as_str()),
        Some("USAGE")
    );
    assert!(
        body.get("results").is_none(),
        "nothing was uploaded, so there is no results key: {body}"
    );

    // The same run with the one value the guard looks at changed. Reaching
    // CONFIG_MISSING proves the config above was loaded and every check before
    // `auth::token()` passed — so the 2 above came from the guard and nowhere else.
    let (stdout, _, code) = sb.run_with_env(
        &[shot_arg, "--path", "images/{name}.{ext}", "--json"],
        no_path,
    );
    assert_eq!(code, 3, "a safe --path runs on to the credential: {stdout}");
    assert_eq!(
        parse(&stdout, "upload with a safe --path")
            .pointer("/error/code")
            .and_then(|v| v.as_str()),
        Some("CONFIG_MISSING")
    );
}

/// `doctor` was the only subcommand whose failure reason lived solely in the
/// process exit status — a channel `gitpic doctor --json | jq` silently replaces
/// with jq's own 0, and that some agent harnesses never surface. Needs the real
/// binary because the field is added where `summarize`'s result is serialized.
/// Runs with an empty `PATH` and no stored credential, so no network is touched.
#[test]
fn an_unhealthy_doctor_report_carries_its_code_on_stdout() {
    let sb = Sandbox::new("doctor-error");
    let empty_path = sb.dir.join("empty-path");
    std::fs::create_dir_all(&empty_path).unwrap();
    let out = Command::new(env!("CARGO_BIN_EXE_gitpic"))
        .args(["doctor", "--json"])
        .env("XDG_CONFIG_HOME", sb.dir.join("cfg"))
        .env("XDG_DATA_HOME", sb.dir.join("data"))
        .env("PATH", &empty_path)
        .output()
        .expect("the binary runs");

    assert_eq!(out.status.code(), Some(3));
    let body = parse(&String::from_utf8_lossy(&out.stdout), "doctor --json");
    assert_eq!(body.get("ok").and_then(|v| v.as_bool()), Some(false));
    assert_eq!(
        body.pointer("/error/code").and_then(|v| v.as_str()),
        Some("CONFIG_MISSING"),
        "an agent parsing stdout must see the code the exit status carries: {body}"
    );
    assert!(
        body.pointer("/error/message")
            .and_then(|v| v.as_str())
            .is_some_and(|m| !m.is_empty()),
        "the code needs a message next to it: {body}"
    );
}

#[test]
fn the_binary_under_test_is_the_one_we_built() {
    // Guards against a stale binary quietly making these tests meaningless — a
    // trap hit more than once while developing this.
    assert!(
        Path::new(env!("CARGO_BIN_EXE_gitpic")).is_file(),
        "the test binary path must exist"
    );
    let sb = Sandbox::new("version");
    let (stdout, _, code) = sb.run(&["--version"]);
    assert_eq!(code, 0);
    assert!(
        stdout.contains(env!("CARGO_PKG_VERSION")),
        "expected {}, got {stdout:?}",
        env!("CARGO_PKG_VERSION")
    );
}

/// `gitpic branches` refuses in the right order, and says which thing is missing.
///
/// Both halves are `CONFIG_MISSING`, and an agent that cannot tell them apart from the
/// code alone acts on the wrong one: "no target" is fixed by `config set github.repo`,
/// "no credential" only by handing `gitpic auth login` to a human. So the message is the
/// contract here, not the code.
///
/// Offline by construction, which is the point — the target check runs before the
/// credential is resolved and the credential before any request, so neither path this
/// test takes reaches GitHub.
#[test]
fn branches_names_whichever_prerequisite_is_missing() {
    let sb = Sandbox::new("branches");

    // The sandbox has a target and no `auth.toml`.
    let (stdout, _stderr, code) = sb.run(&["branches", "--json"]);
    assert_eq!(code, 3, "no credential is CONFIG_MISSING\n{stdout}");
    let v = parse(&stdout, "branches --json");
    assert_eq!(
        v.pointer("/error/code").and_then(|c| c.as_str()),
        Some("CONFIG_MISSING"),
        "{v}"
    );
    let message = v
        .pointer("/error/message")
        .and_then(|m| m.as_str())
        .unwrap_or_default();
    assert!(
        message.contains("gitpic auth login"),
        "a missing credential has exactly one remedy: {message}"
    );

    // With no target either, the target is what gets named — it is checked first
    // because a branch listing is *about* a repository, so "which one" has to be
    // answered before "may I read it".
    std::fs::write(sb.dir.join("cfg/gitpic/config.toml"), "[github]\n").expect("empty config");
    let (stdout, _stderr, code) = sb.run(&["branches", "--json"]);
    assert_eq!(code, 3, "no target is CONFIG_MISSING too\n{stdout}");
    let v = parse(&stdout, "branches --json (no target)");
    let message = v
        .pointer("/error/message")
        .and_then(|m| m.as_str())
        .unwrap_or_default();
    assert!(
        message.contains("missing target repo"),
        "the target must be named ahead of the credential: {message}"
    );
    assert!(
        message.contains("gitpic config set github.repo"),
        "and the remedy has to be a command that exists: {message}"
    );
}

/// The two read-only lookups take `--repo`; nothing else does.
///
/// `--repo` is declared per-subcommand rather than globally, so "which commands accept
/// it" is a list that can silently go stale. Both of these answer a question *about* a
/// repository, which is what makes looking before saving the value worth supporting.
#[test]
fn the_repository_lookups_accept_a_target_and_the_others_refuse_one() {
    let sb = Sandbox::new("repo-flag");
    // Accepted. Neither reaches the network here: the sandbox has no credential, so both
    // stop at `CONFIG_MISSING` — which still proves clap took the flag.
    for args in [
        vec!["doctor", "--repo", "octocat/pics", "--json"],
        vec!["branches", "--repo", "octocat/pics", "--json"],
    ] {
        let label = args.join(" ");
        let (stdout, _stderr, code) = sb.run(&args);
        assert_ne!(code, 2, "`{label}` must not be a usage error\n{stdout}");
    }
    // Refused, and the message says where the flag does work rather than only "not
    // here" — without that last clause this was a two-step dead end.
    let (stdout, stderr, code) = sb.run(&["--repo", "octocat/pics", "list"]);
    assert_eq!(code, 2, "{stdout}{stderr}");
    let said = format!("{stdout}{stderr}");
    assert!(said.contains("branches"), "{said}");
}

/// `-q` output has to stay parseable, which means no advisory lines in it.
///
/// The regression: `gitpic branches -q` printed its branch names and then
/// `  note: \`main\` is configured but not in this list…` on the same stream, so
/// `gitpic branches -q | while read b` handed the caller a sentence as a branch name.
/// `gitpic repos -q` had the identical shape for a truncated listing.
///
/// Checked by reading the sources rather than by provoking each note, because two of the
/// three need a state this test cannot reach offline (a >1000-repo account, a repository
/// whose configured branch is absent). What the scan pins is the rule.
///
/// Scoped to functions that *take* a `mode`, which is the whole set that can honour one:
/// `repos::choose_target` is the interactive picker, has no `mode` parameter, and its
/// notes are part of a conversation rather than of a listing.
#[test]
fn a_quiet_listing_prints_only_the_thing_it_lists() {
    for file in ["src/commands/repos.rs", "src/commands/branches.rs"] {
        let path = Path::new(env!("CARGO_MANIFEST_DIR")).join(file);
        let text = std::fs::read_to_string(&path).expect("readable source");
        let mut takes_mode = false;
        let mut guarded = false;
        let mut checked_a_function = false;
        let mut offenders = Vec::new();
        for (i, line) in text.lines().enumerate() {
            let code = line.trim_start();
            if code.starts_with("//") {
                continue;
            }
            // A signature at column 0 starts a new function, and only one that was
            // handed a `mode` can be asked to consult it.
            if line.starts_with("pub ") && line.contains("fn ") {
                takes_mode = line.contains("mode: Mode");
                guarded = false;
                checked_a_function |= takes_mode;
            }
            if code.contains("Mode::Quiet") {
                guarded = true;
            }
            if takes_mode && !guarded && code.contains("output::note(") {
                offenders.push(format!("{file}:{}: {}", i + 1, code));
            }
        }
        assert!(
            checked_a_function,
            "{file}: the scan found no `mode`-taking function, so it checked nothing — \
             the signature it matches on must have changed"
        );
        assert!(
            offenders.is_empty(),
            "these write an advisory line into `-q` output, where the caller reads every \
             line as a value:\n{}",
            offenders.join("\n")
        );
    }

    // And one end-to-end check of the half that is reachable: no credential, so `-q`
    // must print nothing at all rather than prose on stdout.
    let sb = Sandbox::new("quiet-listing");
    for args in [vec!["repos", "-q"], vec!["branches", "-q"]] {
        let label = args.join(" ");
        let (stdout, _stderr, code) = sb.run(&args);
        assert_eq!(code, 3, "`{label}` needs a credential\n{stdout}");
        assert!(
            stdout.is_empty(),
            "`{label}` must keep stdout clean on failure, got {stdout:?}"
        );
    }
}
