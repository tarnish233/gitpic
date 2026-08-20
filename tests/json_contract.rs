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

    /// Same, with `input` written to the child's stdin — needed for `init`, which
    /// is a conversation and cannot be driven any other way.
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
        // variable — `GITPIC_OWNER`, for the `init` case that only makes sense with
        // it — gets that one and still inherits the isolation for the rest, which is
        // what keeps every other test repeatable on a machine that exports them.
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

#[test]
fn a_json_error_is_a_json_envelope_on_stdout() {
    let sb = Sandbox::new("err");
    // An agent parsing stdout has to get an envelope for failures too, not prose
    // on stderr and an empty stdout.
    for (args, want_code) in [
        (vec!["config", "get", "no.such.key", "--json"], 2),
        (vec!["config", "set", "github.token", "legacy", "--json"], 2),
        (vec!["config", "set", "upload.quality", "0", "--json"], 2),
        // `init` is interactive and refuses --json rather than pretending.
        (vec!["init", "--json"], 2),
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

#[test]
fn gitpic_token_is_ignored_and_gh_is_required() {
    let sb = Sandbox::new("gh-only");
    let empty_path = sb.dir.join("empty-path");
    std::fs::create_dir_all(&empty_path).unwrap();
    let out = Command::new(env!("CARGO_BIN_EXE_gitpic"))
        .args(["doctor", "--json"])
        .env("XDG_CONFIG_HOME", sb.dir.join("cfg"))
        .env("XDG_DATA_HOME", sb.dir.join("data"))
        .env("PATH", &empty_path)
        .env("GITPIC_TOKEN", "ghp_legacy_value_must_not_be_used")
        .output()
        .expect("the binary runs");
    assert_eq!(out.status.code(), Some(3));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(!stdout.contains("ghp_legacy_value_must_not_be_used"));
    let body = parse(&stdout, "doctor --json");
    assert_eq!(body.get("token_source"), Some(&serde_json::Value::Null));
    assert_eq!(
        body.get("token_valid").and_then(|v| v.as_bool()),
        Some(false)
    );
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
fn a_closed_reader_never_answers_its_own_prompts() {
    let sb = Sandbox::new("pipe-prompt");
    let cfg_file = sb.dir.join("cfg/gitpic/config.toml");
    // The sandbox ships a config; `init` writing one is the failure being watched
    // for, so there must be nothing there to begin with.
    std::fs::remove_file(&cfg_file).expect("start with nothing configured");

    // The same answers down a stdout nobody closed. Load-bearing, not decoration:
    // without it, "exit 1 and no file" is what *any* failure looks like, and the
    // test below would pass just as happily on a broken sandbox or a rejected
    // answer. This proves the only thing the run below changes is the reader.
    let (stdout, stderr, code) = sb.run_with_stdin(&["init"], "someone/pics\nmain\ncdn\n");
    assert_eq!(
        code, 0,
        "these are answers that save a config\n{stdout}\n{stderr}"
    );
    assert!(cfg_file.is_file(), "and they save it here");
    std::fs::remove_file(&cfg_file).expect("back to nothing configured");

    // `true` closes the read end immediately, and the EPIPE is a real one: `Stdout`
    // is a `LineWriter`, so the banner's `writeln!` reaches the pipe at once, and
    // the prompt text — which carries no newline — reaches it at `output::finish()`.
    // `PIPESTATUS[1]` is gitpic's own status; `[0]` is printf's and `[2]` is true's.
    let script = format!(
        "printf 'someone/pics\\nmain\\ncdn\\n' | '{}' init | true >/dev/null; \
         exit ${{PIPESTATUS[1]}}",
        env!("CARGO_BIN_EXE_gitpic")
    );
    let out = Command::new("bash")
        .arg("-c")
        .arg(&script)
        .env("XDG_CONFIG_HOME", sb.dir.join("cfg"))
        .env("XDG_DATA_HOME", sb.dir.join("data"))
        .env_remove("GITPIC_REPO")
        .env_remove("GITPIC_OWNER")
        .env_remove("GITPIC_BRANCH")
        .env_remove("GITPIC_LINK")
        .output()
        .expect("bash runs");
    let code = out.status.code().unwrap_or(-1);
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert_eq!(
        code, 1,
        "an undeliverable question must fail the run, got {code}\n{stderr}"
    );
    // Named so the 1 cannot come from somewhere else and still look like a pass.
    assert!(
        stderr.contains("stdout is closed"),
        "the refusal must be about the question nobody saw: {stderr}"
    );
    assert!(
        !cfg_file.exists(),
        "answers to questions that were never delivered must not become a config"
    );
}

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
/// `PATH` is emptied so `gh` is unreachable: it keeps the 3 a deterministic local
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
    let no_gh: &[(&str, &str)] = &[("PATH", empty_path.to_str().expect("utf-8 path"))];

    let (stdout, _, code) = sb.run_with_env(&[shot_arg, "--json"], no_gh);
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
    let (stdout, _, code) = sb.run_with_env(&[shot_arg, "--link", "raw", "--json"], no_gh);
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

/// `init` writes the config file, so it is the one entry point whose validation
/// gap persisted across runs. Needs the real binary: the prompts read stdin.
#[test]
fn init_never_leaves_a_config_it_would_refuse_to_load() {
    let sb = Sandbox::new("init");
    let cfg_file = sb.dir.join("cfg/gitpic/config.toml");
    let before = std::fs::read_to_string(&cfg_file).expect("the sandbox config exists");

    // `me x/pics` parses as a spec — `set_repo_spec` only splits and trims — but
    // `me x` cannot go into a URL path segment. Answering this used to print
    // "✓ saved config" and then make every later command fail CONFIG_INVALID,
    // `init` included, because `init` loads the file before prompting.
    let (stdout, stderr, code) = sb.run_with_stdin(&["init"], "me x/pics\nmain\ncdn\n");
    assert_eq!(code, 2, "must be a usage error\n{stdout}\n{stderr}");
    assert!(
        !stdout.contains("saved config"),
        "must not claim success: {stdout}"
    );
    assert_eq!(
        std::fs::read_to_string(&cfg_file).expect("config still readable"),
        before,
        "a rejected answer must not touch the file on disk"
    );

    // `owner/` parses as a spec (`set_repo_spec` splits on the first `/`) but
    // leaves an empty repo. That used to print "✓ saved config" for a file the
    // next upload then refused with CONFIG_MISSING.
    let (stdout, stderr, code) = sb.run_with_stdin(&["init"], "owner/\nmain\ncdn\n");
    assert_eq!(
        code, 2,
        "empty repo half must be a usage error\n{stdout}\n{stderr}"
    );
    assert!(
        !stdout.contains("saved config"),
        "must not claim success: {stdout}"
    );
    assert_eq!(
        std::fs::read_to_string(&cfg_file).expect("config still readable"),
        before,
        "a rejected answer must not touch the file on disk"
    );

    // And the config is still loadable, so `init` can be re-run to fix the answer.
    let (_, _, code) = sb.run(&["config", "get"]);
    assert_eq!(code, 0, "the existing config must still load");

    let (stdout, stderr, code) = sb.run_with_stdin(&["init"], "someone/pics\nmain\nraw\n");
    assert_eq!(code, 0, "a good answer must still save\n{stdout}\n{stderr}");
    assert!(stdout.contains("saved config"), "{stdout}");
    let (value, _, _) = sb.run(&["config", "get", "upload.link_kind"]);
    assert_eq!(value.trim(), "raw");
}

/// The other side of the rule above: what `init` must judge is the configuration
/// the *next* command resolves — this file plus the environment — not the file on
/// its own.
///
/// `GITPIC_OWNER=me gitpic init` answering a bare `pics` is a setup `upload`
/// accepts, because `upload` applies the environment before it checks the target.
/// `init` judging only the file it was about to write refused it as a usage error,
/// contradicting its own repo prompt, whose default was written for exactly that
/// case: the only way to configure a repo under an environment owner was to stop
/// using `init`.
///
/// Both halves are asserted, because either one alone permits a wrong fix. Reading
/// the variable must not turn into *storing* it — a file carrying `owner = "me"`
/// would outlive the variable that justified it — and it must not turn into
/// accepting a bare name from anyone, which is the `CONFIG_MISSING` on the next
/// upload that this whole check exists to prevent.
#[test]
fn init_validates_the_target_the_next_command_will_resolve() {
    let sb = Sandbox::new("init-env");
    let cfg_file = sb.dir.join("cfg/gitpic/config.toml");
    // The sandbox config already carries an owner, which would complete the answer
    // by itself and hide both halves of this.
    std::fs::remove_file(&cfg_file).expect("start with nothing configured");

    let (stdout, stderr, code) =
        sb.run_with_stdin_env(&["init"], "pics\nmain\ncdn\n", &[("GITPIC_OWNER", "me")]);
    assert_eq!(
        code, 0,
        "the environment completes this target, so it must save\n{stdout}\n{stderr}"
    );
    assert!(stdout.contains("saved config"), "{stdout}");
    let saved = std::fs::read_to_string(&cfg_file).expect("the config was written");
    assert!(
        saved.contains("repo = \"pics\""),
        "the answer belongs in the file: {saved}"
    );
    assert!(
        saved.contains("owner = \"\""),
        "the variable is read to judge the answer and never written — baking it in \
         would leave `owner = \"me\"` behind after it is unset: {saved}"
    );

    std::fs::remove_file(&cfg_file).expect("back to nothing configured");
    let (stdout, stderr, code) = sb.run_with_stdin(&["init"], "pics\nmain\ncdn\n");
    assert_eq!(
        code, 2,
        "with nothing to complete it, a bare repo name is still a usage error\n{stdout}\n{stderr}"
    );
    assert!(
        !stdout.contains("saved config"),
        "must not claim success: {stdout}"
    );
    assert!(
        !cfg_file.exists(),
        "a rejected answer must leave nothing on disk"
    );
}

/// `doctor` was the only subcommand whose failure reason lived solely in the
/// process exit status — a channel `gitpic doctor --json | jq` silently replaces
/// with jq's own 0, and that some agent harnesses never surface. Needs the real
/// binary because the field is added where `summarize`'s result is serialized.
/// Runs with an empty `PATH` so `gh` is unreachable and no network is touched.
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
