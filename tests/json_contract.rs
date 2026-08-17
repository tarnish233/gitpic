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
        let out = Command::new(env!("CARGO_BIN_EXE_gitpic"))
            .args(args)
            .env("XDG_CONFIG_HOME", self.dir.join("cfg"))
            .env("XDG_DATA_HOME", self.dir.join("data"))
            // Must not leak the developer's own credential into a test run.
            .env_remove("GITPIC_TOKEN")
            .env_remove("GITPIC_REPO")
            .env_remove("GITPIC_OWNER")
            .env_remove("GITPIC_BRANCH")
            .env_remove("GITPIC_LINK")
            .stdin(std::process::Stdio::null())
            .output()
            .expect("the binary runs");
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
fn json_mode_never_leaks_the_token() {
    let sb = Sandbox::new("redact");
    std::fs::write(
        sb.dir.join("cfg/gitpic/config.toml"),
        "[github]\ntoken = \"ghp_do_not_print_me\"\nowner = \"someone\"\nrepo = \"pics\"\n",
    )
    .expect("write config");
    for args in [
        vec!["config", "get", "--json"],
        vec!["config", "get", "github.token", "--json"],
    ] {
        let label = args.join(" ");
        let (stdout, stderr, _) = sb.run(&args);
        assert!(
            !stdout.contains("ghp_do_not_print_me") && !stderr.contains("ghp_do_not_print_me"),
            "`{label}` leaked the token:\n{stdout}\n{stderr}"
        );
        assert!(stdout.contains("<redacted>"), "`{label}`: {stdout}");
    }
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
