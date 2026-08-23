//! Output rendering: human-friendly vs stable JSON schema for agents.

use owo_colors::{OwoColorize, Stream};
use serde::Serialize;
use std::io::{self, Write};
use std::sync::atomic::{AtomicBool, Ordering};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    Human,
    Quiet,
    Json,
}

impl Mode {
    pub fn from_flags(json: bool, quiet: bool) -> Self {
        if json {
            Mode::Json
        } else if quiet {
            Mode::Quiet
        } else {
            Mode::Human
        }
    }
    pub fn is_json(self) -> bool {
        matches!(self, Mode::Json)
    }
    /// Beside [`Mode::is_json`], which existed while this did not — so
    /// `matches!(mode, Mode::Quiet)` was spelled out eight times across four
    /// subcommands, four of them inside one function.
    pub fn is_quiet(self) -> bool {
        matches!(self, Mode::Quiet)
    }
}

/// One uploaded image result (stable JSON schema).
#[derive(Debug, Serialize)]
pub struct ItemResult {
    pub name: String,
    pub url: String,
    pub raw_url: String,
    pub markdown: String,
    pub html: String,
    pub path: String,
    pub sha: String,
    pub size: usize,
    pub deduped: bool,
    /// The chosen output snippet according to --format
    pub output: String,
}

#[derive(Debug, Serialize)]
pub struct SuccessEnvelope<'a> {
    pub ok: bool,
    pub results: &'a [ItemResult],
}

#[derive(Debug, Serialize)]
pub struct ErrorBody {
    pub code: String,
    pub message: String,
}

impl ErrorBody {
    pub fn new(code: &str, message: &str) -> Self {
        Self {
            code: code.to_string(),
            message: message.to_string(),
        }
    }
}

#[derive(Debug, Serialize)]
pub struct ErrorEnvelope {
    pub ok: bool,
    pub error: ErrorBody,
}

/// Envelope for a run where some inputs uploaded and a later one failed.
/// `ok` is false, but `results` still carries every live link.
#[derive(Debug, Serialize)]
pub struct PartialEnvelope<'a> {
    pub ok: bool,
    pub results: &'a [ItemResult],
    pub error: ErrorBody,
}

/// Set once a stdout write was thrown away because the reader had gone, and never
/// cleared: output that was lost stays lost for the rest of the run.
///
/// Global rather than a return value from `line`/`raw` because those are called
/// from every subcommand and return `()`. Handing them a result would put the
/// decision at dozens of call sites where there is nothing to decide — a one-way
/// stream has already done its whole job when the reader leaves. One process, one
/// stdout, so one flag is the entire truth.
///
/// Atomic rather than a `Cell` only because `main` is a multi-threaded tokio
/// runtime and a write can land on whichever worker is running the task.
/// `Relaxed` is enough: the flag publishes no other data, and the load that has
/// to see the store — `prompt_opt`'s, right after its own write — is sequenced
/// after it on the same thread.
static STDOUT_LOST: AtomicBool = AtomicBool::new(false);

fn note_stdout_lost() {
    STDOUT_LOST.store(true, Ordering::Relaxed);
}

/// Whether any stdout write has been discarded because the reader closed the pipe.
///
/// The caller that must ask is an interactive prompt: a question the user could
/// not read has no answer, however many lines stdin still offers. See
/// [`crate::commands::prompt_opt`].
pub fn stdout_lost() -> bool {
    STDOUT_LOST.load(Ordering::Relaxed)
}

/// Write a line to stdout, treating a vanished reader as a normal end.
///
/// `println!` panics when the write fails, and with `panic = "abort"` in the
/// release profile that is SIGABRT — exit 134, outside the documented 1-10
/// contract, with a raw Rust panic on stderr. `gitpic list | head`,
/// `gitpic completion zsh | true`, `gitpic *.png -q | head -1`: any reader that
/// closes early produced that. A closed pipe is not an error — the reader got what
/// it asked for — so the process exits 0, which is what `head` and friends expect.
///
/// The discarded text is remembered rather than forgotten, via [`stdout_lost`].
/// One-way output never has to look; a caller that expects the reader to answer
/// does, because for it a dropped write is not the end of a successful run.
///
/// Other write errors (a full disk, a closed descriptor) still abort loudly rather
/// than being silently dropped: those *are* failures, and pretending output
/// happened would be worse than a panic.
pub fn line(text: &str) {
    write_stdout(|out| writeln!(out, "{text}"));
}

/// Write without a trailing newline. Same broken-pipe rule as [`line`].
pub fn raw(text: &str) {
    write_stdout(|out| write!(out, "{text}"));
}

fn write_stdout(write: impl FnOnce(&mut dyn Write) -> io::Result<()>) {
    let stdout = io::stdout();
    let mut lock = stdout.lock();
    record_write(write(&mut lock));
}

/// The broken-pipe rule for one finished stdout write.
///
/// Split out of [`write_stdout`] so the rule can be exercised without a real pipe:
/// the test binary's stdout is the harness's, and breaking it would break the
/// harness.
fn record_write(result: io::Result<()>) {
    match result {
        Ok(()) => {}
        // The rule, both halves: a closed reader ends a one-way stream normally,
        // and it must not be able to fake consent for an interactive one.
        //
        // Do not `exit(0)`. `print_error` writes stdout too (the `--json`
        // envelopes), so exiting on its broken pipe reported success for a
        // failure: `gitpic --json --nope | true` is a USAGE error and owes the
        // caller exit 2. The write that vanished was the *report* of the failure,
        // not the failure, and `main` still returns the intended status.
        //
        // But not exiting means the writer stops learning that its output went
        // nowhere, and one writer must know. `printf 'someone/pics\nmain\ncdn\n' |
        // gitpic init | true` discarded every prompt, read the piped answers
        // anyway, and saved a config for questions the user never saw;
        // `gitpic skill install` did the same with a numbered target list and an
        // `a=all` default, installing files nobody was shown. So the loss is
        // recorded instead of acted on: `list`/`completion` ignore it and still
        // exit 0, while `prompt_opt` refuses to read an answer to a question that
        // was never delivered.
        Err(e) if e.kind() == io::ErrorKind::BrokenPipe => note_stdout_lost(),
        Err(e) => panic!("failed printing to stdout: {e}"),
    }
}

/// Flush stdout, treating a vanished reader as a normal end.
///
/// Needed because a locked-and-dropped `Stdout` flushes on drop and swallows the
/// result, so a broken pipe on the very last buffered write would otherwise be
/// reported by the runtime as a panic at exit.
///
/// It has to record the loss too, and for a prompt's own text it is the only place
/// that can: `Stdout` is a `LineWriter` whatever it points at, and
/// `raw("image host? [1-3]: ")` carries no newline, so the `write(2)` that earns the
/// EPIPE happens at this flush and nowhere else. An empty arm here would let the
/// repository picker be answered by a reader that left after the listing — every write
/// so far succeeded, so nothing else in this module ever saw a broken pipe.
pub fn finish() {
    match io::stdout().flush() {
        Ok(()) => {}
        Err(e) if e.kind() == io::ErrorKind::BrokenPipe => note_stdout_lost(),
        // Any other flush failure has nowhere left to be reported: `main` calls
        // this after the exit code is decided, and panicking would replace a real
        // code with 134.
        Err(_) => {}
    }
}

/// Serialised access to [`STDOUT_LOST`] for tests, which puts it back afterwards.
///
/// The flag is process-global and in production is never cleared, while
/// `cargo test` runs these tests as threads in one process: a leaked `true` would
/// make an unrelated test believe stdout had vanished, and an interleaved `false`
/// would make the prompt test pass for the wrong reason.
#[cfg(test)]
pub(crate) fn stdout_lost_test_guard(lost: bool) -> StdoutLostGuard {
    static LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
    // A failing test poisons the lock; the next one still needs to run and set the
    // flag itself, so the poison carries no information worth stopping for.
    let held = LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    STDOUT_LOST.store(lost, Ordering::Relaxed);
    StdoutLostGuard { _held: held }
}

#[cfg(test)]
pub(crate) struct StdoutLostGuard {
    _held: std::sync::MutexGuard<'static, ()>,
}

#[cfg(test)]
impl Drop for StdoutLostGuard {
    fn drop(&mut self) {
        STDOUT_LOST.store(false, Ordering::Relaxed);
    }
}

/// Print a value as pretty JSON on stdout. Every `--json` envelope in the crate
/// goes through here, so the shape and the formatting stay in one place.
pub fn print_json<T: Serialize>(value: &T) {
    line(&serde_json::to_string_pretty(value).unwrap_or_default());
}

/// Serialise `value` to exactly one line.
///
/// The counterpart to [`print_json`], which pretty-prints — right for a single envelope
/// somebody may read, and *wrong* for a stream. `auth login --json` emits one object per
/// line, and pretty-printing turned each of them into seven: a reader splitting on
/// newlines got `{`, then `  "event": "code",`, and not one parseable object among them.
///
/// Split from [`print_json_line`] so the shape is assertable in a test. Serialising the
/// struct directly, as the first test of this did, proves nothing — the bug was entirely
/// in which writer the caller reached for.
pub fn json_line<T: Serialize>(value: &T) -> String {
    serde_json::to_string(value).unwrap_or_default()
}

/// Print one JSON object on one line, for the streaming `auth login --json`.
pub fn print_json_line<T: Serialize>(value: &T) {
    line(&json_line(value));
}

/// Print successful upload results according to the mode.
pub fn print_results(mode: Mode, results: &[ItemResult]) {
    match mode {
        Mode::Json => print_json(&SuccessEnvelope { ok: true, results }),
        Mode::Quiet => {
            for r in results {
                line(&r.output);
            }
        }
        Mode::Human => {
            for r in results {
                print_human_item(r);
            }
        }
    }
}

fn print_human_item(r: &ItemResult) {
    let check = "✓ uploaded".if_supports_color(Stream::Stdout, |t| t.green().bold().to_string());
    let name = r
        .name
        .if_supports_color(Stream::Stdout, |t| t.bold().to_string());
    if r.deduped {
        let tag = " (deduped)".if_supports_color(Stream::Stdout, |t| t.yellow().to_string());
        line(&format!("{check} {name}{tag}"));
    } else {
        line(&format!("{check} {name}"));
    }
    line(&r.output);
}

/// Print results that succeeded before a failure, followed by the error.
/// Successful links are never dropped just because a later input failed.
pub fn print_partial(mode: Mode, results: &[ItemResult], code: &str, message: &str) {
    if mode.is_json() {
        print_json(&PartialEnvelope {
            ok: false,
            results,
            error: ErrorBody::new(code, message),
        });
    } else {
        // Quiet and Human render the successful items exactly as a clean run
        // does, then append the error on stderr.
        print_results(mode, results);
        eprint_error_label(message);
    }
}

/// Write an indented `note: <text>` line to stdout.
///
/// The one advisory shape in the CLI: something worth saying that is neither a result
/// nor a failure, and that must never reach the exit status. Here rather than in each
/// subcommand because two of them had already written their own copy, and a third would
/// have made `note:` three different colours.
pub fn note(text: &str) {
    let label = "note:".if_supports_color(Stream::Stdout, |t| t.yellow().to_string());
    line(&format!("  {label} {text}"));
}

/// A green `✓` or a red `✗`, for a line reporting one pass/fail check.
///
/// Beside [`note`] and for the same reason it is here: this pair had been written out
/// four times — `auth status`, `doctor`, `repos`, `config set` — two of them coloured
/// and two not, so the same judgement was already three different shapes on screen.
/// The next check to be added is the one that would have picked whichever copy it was
/// nearest.
pub fn mark(ok: bool) -> String {
    // `.to_string()` inside each arm, not once around the `if`: `if_supports_color`
    // returns a type carrying the closure, and no two closures share a type.
    if ok {
        "✓"
            .if_supports_color(Stream::Stdout, |t| t.green().to_string())
            .to_string()
    } else {
        "✗"
            .if_supports_color(Stream::Stdout, |t| t.red().to_string())
            .to_string()
    }
}

/// The success half of [`mark`], for the sites that have nothing to fail.
pub fn tick() -> String {
    mark(true)
}

/// Write `error: <message>` to stderr, coloured only when stderr is a terminal.
fn eprint_error_label(message: &str) {
    let label = "error:".if_supports_color(Stream::Stderr, |t| t.red().bold().to_string());
    eprintln!("{label} {message}");
}

/// Print an error according to the mode (JSON to stdout, human to stderr).
pub fn print_error(mode: Mode, code: &str, message: &str) {
    if mode.is_json() {
        print_json(&ErrorEnvelope {
            ok: false,
            error: ErrorBody::new(code, message),
        });
    } else {
        eprint_error_label(message);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(name: &str) -> ItemResult {
        ItemResult {
            name: name.to_string(),
            url: "u".into(),
            raw_url: "r".into(),
            markdown: "m".into(),
            html: "h".into(),
            path: "p".into(),
            sha: "s".into(),
            size: 1,
            deduped: false,
            output: "o".into(),
        }
    }

    #[test]
    fn success_envelope_has_ok_true_and_no_error_key() {
        let results = [item("one")];
        let json = serde_json::to_string(&SuccessEnvelope {
            ok: true,
            results: &results,
        })
        .unwrap();
        assert!(json.contains(r#""ok":true"#));
        assert!(!json.contains(r#""error""#));
    }

    /// The regression this exists for: `auth login --json` is newline-delimited, and
    /// `print_json` pretty-prints. Every event went out as seven lines, so a reader
    /// splitting on newlines — which is the whole contract — parsed none of them.
    ///
    /// Asserted through `json_line`, the function the printer actually calls. The first
    /// version of this test serialised the event struct itself with `to_string` and
    /// passed while the shipping code used `to_string_pretty`.
    #[test]
    fn a_streamed_object_is_one_line() {
        let rendered = json_line(&SuccessEnvelope {
            ok: true,
            results: &[],
        });
        assert!(!rendered.contains('\n'), "{rendered:?}");
        assert_eq!(rendered, r#"{"ok":true,"results":[]}"#);

        // And the envelope printer keeps pretty-printing: it is one object per
        // invocation, and a human reads it.
        let pretty = serde_json::to_string_pretty(&SuccessEnvelope {
            ok: true,
            results: &[],
        })
        .unwrap();
        assert!(pretty.contains('\n'));
    }

    #[test]
    fn error_envelope_has_no_results_key() {
        // Agents distinguish a total failure from a partial one by the presence
        // of `results`, so a plain error must not carry an empty array.
        let json = serde_json::to_string(&ErrorEnvelope {
            ok: false,
            error: ErrorBody {
                code: "AUTH_FAILED".into(),
                message: "nope".into(),
            },
        })
        .unwrap();
        assert!(json.contains(r#""ok":false"#));
        assert!(
            !json.contains(r#""results""#),
            "plain errors must omit results: {json}"
        );
    }

    #[test]
    fn partial_envelope_carries_both_results_and_error() {
        let results = [item("one")];
        let json = serde_json::to_string(&PartialEnvelope {
            ok: false,
            results: &results,
            error: ErrorBody {
                code: "RATE_LIMITED".into(),
                message: "slow down".into(),
            },
        })
        .unwrap();
        assert!(json.contains(r#""ok":false"#));
        assert!(json.contains(r#""name":"one""#));
        assert!(json.contains(r#""code":"RATE_LIMITED""#));
    }

    /// Swallowing a dropped write and saying nothing about it is what let
    /// `gitpic init | true` answer its own questions, so the record is the fix.
    #[test]
    fn a_dropped_stdout_write_is_recorded_and_a_delivered_one_is_not() {
        let _serialised = stdout_lost_test_guard(false);
        record_write(Ok(()));
        assert!(!stdout_lost(), "a write that arrived must not look lost");
        record_write(Err(io::Error::from(io::ErrorKind::BrokenPipe)));
        assert!(
            stdout_lost(),
            "a write a closed reader threw away must be recorded"
        );
    }

    /// Every broken-pipe arm in this module has to record the loss, and one of them
    /// cannot be reached from a test: `finish` flushes the *harness's* stdout,
    /// which never breaks. It is also the arm a prompt depends on — `Stdout` is a
    /// `LineWriter`, so `raw("Branch [main]: ")` earns its EPIPE at that flush and
    /// nowhere else. Reading the source is the only way to catch the next writer
    /// that adds an empty arm.
    #[test]
    fn every_broken_pipe_arm_records_the_loss() {
        // Assembled at runtime so this test's own source lines do not match it.
        let needle = format!("{}{}", "ErrorKind::BrokenPipe", " =>");
        let src = std::fs::read_to_string(
            std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/output.rs"),
        )
        .expect("this module is readable");
        let arms: Vec<&str> = src
            .lines()
            .map(str::trim_start)
            .filter(|l| !l.starts_with("//") && l.contains(&needle))
            .collect();
        assert!(
            arms.len() >= 2,
            "expected the write arm and the flush arm; the scan has gone blind: {arms:?}"
        );
        for arm in &arms {
            assert!(
                arm.contains("note_stdout_lost"),
                "this arm drops output without recording it, so a prompt cannot \
                 tell it was never seen: {arm}"
            );
        }
    }

    /// Every stdout write in the crate has to go through this module, or a
    /// `println!` somewhere else reintroduces the abort that `line`/`raw` exist to
    /// prevent: `gitpic list | head` panicked on the broken pipe, and with
    /// `panic = "abort"` that is exit 134 — outside the documented 1-10 contract.
    ///
    /// Checked by reading the sources rather than by spawning pipes, so it also
    /// covers paths a test would struggle to reach (the interactive prompt, the
    /// `skill install` picker) and fails at the moment someone adds a new one.
    #[test]
    fn no_module_writes_to_stdout_outside_this_one() {
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
        let mut offenders = Vec::new();
        let mut stack = vec![root];
        while let Some(dir) = stack.pop() {
            for entry in std::fs::read_dir(&dir).expect("src is readable") {
                let path = entry.expect("readable entry").path();
                if path.is_dir() {
                    stack.push(path);
                    continue;
                }
                if path.extension().and_then(|e| e.to_str()) != Some("rs") {
                    continue;
                }
                // This module is where the guarded writes live.
                if path.file_name().and_then(|f| f.to_str()) == Some("output.rs") {
                    continue;
                }
                let text = std::fs::read_to_string(&path).expect("readable source");
                for (i, l) in text.lines().enumerate() {
                    let code = l.trim_start();
                    if code.starts_with("//") {
                        continue;
                    }
                    // `eprintln!` is fine: stderr is not what a reader closes, and
                    // diagnostics must never take the process down either way. It
                    // has to be removed before scanning, because "eprintln!"
                    // contains "println!" as a substring.
                    let code = code.replace("eprintln!", "").replace("eprint!", "");
                    let hit = ["println!", "print!(", "std::io::stdout()", "io::stdout()"]
                        .iter()
                        .any(|pat| code.contains(pat));
                    if hit {
                        offenders.push(format!(
                            "{}:{}: {}",
                            path.file_name().unwrap().to_string_lossy(),
                            i + 1,
                            l.trim_start()
                        ));
                    }
                }
            }
        }
        assert!(
            offenders.is_empty(),
            "these write to stdout without the broken-pipe guard; use output::line / output::raw:\n{}",
            offenders.join("\n")
        );
    }
}
