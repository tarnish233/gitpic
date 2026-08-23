import Testing
import Foundation
@testable import GitPicCore

/// The streaming half of `ChildProcess.run`.
///
/// `gitpic auth login --json` prints its one-time code and then blocks for minutes, so
/// "lines arrive while the child is still running" is not an optimisation here — it is
/// the only reason the settings window can show a code at all. Nothing else in the app
/// needs it, which is exactly why it needs a test: every other caller would still pass
/// if the callback only fired at exit.
@Suite("Child process streaming")
struct ChildProcessStreamTests {

    @Test("lines are handed over as they arrive, not collected until exit")
    func linesArriveEarly() throws {
        var stamps: [(line: String, at: Date)] = []
        let lock = NSLock()
        // A second between the two lines, asserted against half of one: enough margin
        // that a loaded machine cannot fail it, and far too much for both callbacks to
        // land at exit.
        let out = try ChildProcess.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            args: ["-c", "echo first; sleep 1; echo second"],
            onStdoutLine: { line in
                lock.lock()
                stamps.append((line, Date()))
                lock.unlock()
            })

        #expect(out.status == 0)
        #expect(stamps.map(\.line) == ["first", "second"])
        let gap = try #require(stamps.count == 2 ? stamps[1].at.timeIntervalSince(stamps[0].at) : nil)
        #expect(gap > 0.5, "both lines arrived together, so nothing was streamed (gap \(gap)s)")
    }

    @Test("a line with no newline yet is never handed over half-finished")
    func partialLinesAreWithheld() throws {
        // The rule the JSON stream depends on: half an object is worse than nothing.
        // `three` has no trailing newline, so it must not be emitted — but it must
        // still be in the collected stdout, because that is where a caller that wants
        // the whole output looks.
        var lines: [String] = []
        let out = try ChildProcess.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            args: ["-c", "echo one; echo two; printf three"],
            onStdoutLine: { lines.append($0) })

        #expect(lines == ["one", "two"])
        #expect(String(data: out.stdout, encoding: .utf8) == "one\ntwo\nthree")
    }

    @Test("a line split across two reads is emitted once, whole")
    func splitLinesAreJoined() throws {
        // Writes half a line, pauses, then finishes it. A naive implementation that
        // emitted whatever each `read` returned would hand over `{"event":"co` — which
        // for the login stream means a JSON parse failure instead of a code.
        var lines: [String] = []
        let out = try ChildProcess.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            args: ["-c", #"printf '{"event":"co'; sleep 0.4; printf 'de"}\n'"#],
            onStdoutLine: { lines.append($0) })

        #expect(out.status == 0)
        #expect(lines == [#"{"event":"code"}"#])
    }

    @Test("stderr never reaches the line callback")
    func stderrIsNotStreamed() throws {
        // The callback feeds a JSON parser. A warning on stderr arriving there would be
        // noise at best; `Diagnostics` and `rawText` are where stderr belongs.
        var lines: [String] = []
        let out = try ChildProcess.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            args: ["-c", "echo out; echo err 1>&2"],
            onStdoutLine: { lines.append($0) })

        #expect(lines == ["out"])
        #expect(String(data: out.stderr, encoding: .utf8) == "err\n")
    }

    @Test("the spawned process is handed out so a caller can stop it")
    func onSpawnGivesAHandle() throws {
        // How cancellation reaches a login: without this there is no way to stop a
        // child that will otherwise poll GitHub until its code expires.
        let held = NSLock()
        var process: Process?
        let out = try ChildProcess.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            args: ["-c", "sleep 30"],
            onSpawn: { p in
                held.lock()
                process = p
                held.unlock()
                // Terminated from inside the callback, which is the same thread the
                // drain then runs on — proving the handle is live before the wait.
                p.terminate()
            })

        held.lock()
        let seen = process != nil
        held.unlock()
        #expect(seen, "onSpawn must run")
        // SIGTERM, not a clean exit, and not the 30 seconds it was asked to sleep for.
        #expect(out.status != 0)
        #expect(!out.timedOut)
    }
}
