import Testing
import Foundation
@testable import GitPicCore

/// Envelopes captured from `gitpic 0.9.0` on a machine upgraded from before 0.5.0:
/// its config file still had the removed `github.token` line, so every command that
/// loads the config refuses. Only the home directory in the paths is redacted —
/// everything else is verbatim, including the fact that the message names the
/// offending *key* and never its value (`src/config.rs` has a Rust test pinning that,
/// and the app must not undo it by paraphrasing).
private enum Broken {
    /// `gitpic config get --json` → exit 10
    static let configInvalid = """
    {
      "ok": false,
      "error": {
        "code": "CONFIG_INVALID",
        "message": "cannot use config file /Users/you/.config/gitpic/config.toml: unknown field `token`, expected one of `owner`, `repo`, `branch`\\nfix it with `gitpic config edit`"
      }
    }
    """

    /// `gitpic config path --json` → exit 0, on that same machine. The point of the
    /// fixture is that this one *succeeds* while the config is unreadable.
    static let path = """
    {
      "ok": true,
      "path": "/Users/you/.config/gitpic/config.toml"
    }
    """
}

private func stdout(_ text: String, status: Int32) -> ProcessOutcome {
    ProcessOutcome(stdout: Data(text.utf8), stderr: Data(), status: status, timedOut: false)
}

@Suite("A refused command carries its own reason")
struct CLIFailureTests {

    /// The regression this pins is the one that made three panes useless: the CLI
    /// said `CONFIG_INVALID` and named the key, and the app turned that into
    /// `undecodable(status: 10, raw: "{\n \"ok\": false,…")` — the JSON as prose,
    /// truncated to one line, with 重试 as the only offer.
    @Test("an unparsable config is a typed failure, not raw output")
    func configInvalidIsTyped() {
        let failure = GitpicRunner.failure(stdout(Broken.configInvalid, status: 10))
        guard case .cli(let status, let body) = failure else {
            Issue.record("expected .cli, got \(failure)"); return
        }
        // 10 is `ErrorCode::ConfigInvalid`'s own exit code (`src/error.rs`).
        #expect(status == 10)
        #expect(body.code == "CONFIG_INVALID")
        #expect(body.message.contains("unknown field `token`"))
    }

    @Test("output that is not an envelope at all still surfaces verbatim")
    func nonEnvelopeOutput() {
        let failure = GitpicRunner.failure(stdout("Segmentation fault", status: 139))
        guard case .undecodable(let status, let raw) = failure else {
            Issue.record("expected .undecodable, got \(failure)"); return
        }
        #expect(status == 139)
        #expect(raw.contains("Segmentation fault"))
    }

    /// `ok` is the discriminator, not the mere presence of an `error` key. A payload
    /// that happens to carry one must not be reported as a refusal — `doctor` and a
    /// partial `upload` both emit exactly that shape and are handled as data.
    @Test("ok:true is never turned into a failure")
    func okTrueIsNotAFailure() {
        let envelopeShaped = #"{ "ok": true, "error": { "code": "X", "message": "y" } }"#
        let failure = GitpicRunner.failure(stdout(envelopeShaped, status: 0))
        guard case .undecodable = failure else {
            Issue.record("ok:true must not decode as .cli, got \(failure)"); return
        }
    }

    @Test("the config path is readable even when the config is not")
    func pathSurvivesABrokenConfig() throws {
        let env = try JSONDecoder().decode(PathEnvelope.self, from: Data(Broken.path.utf8))
        #expect(env.ok)
        #expect(env.path.hasSuffix("/gitpic/config.toml"))
    }
}

@Suite("Which read failures have a way out")
struct ConfigFailureTests {

    @Test("an unparsable file is the one failure a rename can fix")
    func unusableFile() {
        let failure = ConfigFailure(RunFailure.cli(
            status: 10,
            error: ErrorBody(code: "CONFIG_INVALID", message: "unknown field `token`")))
        #expect(failure.code == "CONFIG_INVALID")
        #expect(failure.isFileUnusable)
        #expect(failure.headline == "配置文件无法解析")
    }

    /// Renaming the config file is destructive, so it must be offered for exactly
    /// one cause. None of these is about the file's text, and moving it would throw
    /// away a working config to fix nothing.
    @Test("every other failure leaves the file alone")
    func everythingElseIsNotAFileProblem() {
        let others: [RunFailure] = [
            .spawnFailed("no such file or directory"),
            .undecodable(status: 139, raw: "Segmentation fault"),
            // A real code, and still not a file problem: `CONFIG_MISSING` means
            // nothing is configured yet, which the editable form already handles.
            .cli(status: 3, error: ErrorBody(code: "CONFIG_MISSING", message: "run `gitpic init`")),
        ]
        for error in others {
            let failure = ConfigFailure(error)
            #expect(!failure.isFileUnusable, "\(error) must not offer a rename")
            #expect(failure.headline == "读取配置失败")
        }
    }

    /// Shown verbatim, and that is a requirement rather than laziness: the CLI's
    /// message is what names the file and the key, and it is written to be safe to
    /// display — a rejected `github.token` is reported without its value. Rewording
    /// it here is how both properties would get lost.
    @Test("the CLI's own words reach the window unchanged")
    func messagePassesThrough() {
        let body = ErrorBody(
            code: "CONFIG_INVALID",
            message: "cannot use config file /x/config.toml: unknown field `token`")
        #expect(ConfigFailure(RunFailure.cli(status: 10, error: body)).message == body.message)

        // A failure with no envelope behind it is described, not invented.
        let spawn = ConfigFailure(RunFailure.spawnFailed("launch path not accessible"))
        #expect(spawn.code == nil)
        #expect(spawn.message.contains("launch path not accessible"))
    }
}
