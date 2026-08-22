import Testing
import Foundation
@testable import GitPicCore

/// Hands a value from a thread we may have to walk away from.
private final class Slot<T: Sendable>: @unchecked Sendable {
    private let ready = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var value: T?
    func put(_ v: T) { lock.lock(); value = v; lock.unlock(); ready.signal() }
    func take(within seconds: Double) -> T? {
        guard ready.wait(timeout: .now() + seconds) == .success else { return nil }
        lock.lock(); defer { lock.unlock() }; return value
    }
}

/// Run one `sh -c` through `ChildProcess`, on a thread of its own, and abandon it
/// if it does not come back inside `within`.
///
/// `nil` therefore means "never returned", which is the shape every regression in
/// this area takes: not a wrong answer, an unbounded block. Measuring it off-thread
/// matters because a blocked test reports *nothing* — the run stops with no failure
/// to read — and because the abandoned thread must not be one of the cooperative
/// pool's.
private func sh(
    _ script: String, timeout: TimeInterval?, within: Double
) -> (out: ProcessOutcome, elapsed: Double)? {
    let slot = Slot<(out: ProcessOutcome, elapsed: Double)>()
    DispatchQueue.global().async {
        let started = Date()
        guard let out = try? ChildProcess.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            args: ["-c", script],
            timeout: timeout)
        else { return }
        slot.put((out, Date().timeIntervalSince(started)))
    }
    return slot.take(within: within)
}

@Suite("Child process spawning", .serialized)
struct ChildProcessTests {

    @Test("a grandchild holding stdout open cannot make a bounded call hang")
    func grandchildHoldingStdout() throws {
        // `sleep 30 &` inherits the write end of stdout and outlives `sh`, so the
        // pipe never reaches EOF and killing the child we spawned does not change
        // that. A login shell does this whenever the profile starts ssh-agent,
        // gpg-agent or nvm — the case `loginShellLookup` runs into with
        // `timeout: 8`, and the one that used to block forever.
        let call = try #require(
            sh("sleep 30 & echo hi", timeout: 1, within: 8),
            "the call never returned: the timeout bounds nothing")
        #expect(call.elapsed < 4, "a 1s bound took \(call.elapsed)s")
        #expect(String(decoding: call.out.stdout, as: UTF8.self).contains("hi"))
        // The child exited on its own and everything it wrote arrived, so this is
        // a completed run rather than a timeout — the answer is usable.
        #expect(call.out.status == 0)
        #expect(!call.out.timedOut)
    }

    @Test("a child killed at the deadline still hands back what it printed")
    func partialOutputSurvivesTheKill() throws {
        let call = try #require(
            sh("echo /opt/homebrew/bin/gh; sleep 30", timeout: 0.5, within: 8),
            "the call never returned")
        #expect(call.elapsed < 4, "a 0.5s bound took \(call.elapsed)s")
        #expect(call.out.timedOut)
        #expect(call.out.status != 0)
        // `ToolDiscovery.loginShellLookup` reads its answer out of exactly this
        // shape — a timed-out outcome whose stdout already holds the path — so
        // dropping the drained bytes here would put back the false "gh missing".
        #expect(String(decoding: call.out.stdout, as: UTF8.self).contains("/opt/homebrew/bin/gh"))
    }

    @Test("the real exit code survives when the drain, not EOF, noticed the exit")
    func exitCodeAfterExitWasObserved() throws {
        // The grandchild keeps both pipes open, so the drain can only end by
        // observing the termination signal. That observation has to be latched:
        // consumed once and a finished child reads as unfinished, which reports the
        // synthesised kill status instead of the 7 the child really exited with —
        // and asking `terminationStatus` while unsure is an uncatchable
        // NSInvalidArgumentException.
        let call = try #require(
            sh("sleep 30 & exit 7", timeout: 3, within: 8),
            "the call never returned")
        #expect(call.out.status == 7)
        #expect(!call.out.timedOut)
    }

    @Test("200 KiB on stderr before a word of stdout neither deadlocks nor drops bytes")
    func bothPipesAreDrained() throws {
        // A child that fills the 64 KiB stderr buffer blocks until someone reads
        // it, so draining stdout to EOF first would deadlock. Both ends have to be
        // polled together.
        let call = try #require(
            sh("yes ABCDEFGH | head -c 200000 1>&2; yes 12345678 | head -c 200000",
               timeout: 20, within: 30),
            "the call never returned: stderr starved stdout")
        #expect(call.out.stdout.count == 200_000)
        #expect(call.out.stderr.count == 200_000)
        #expect(call.out.status == 0)
        #expect(!call.out.timedOut)
    }
}

@Suite("Invocation serialisation", .serialized)
struct RunnerSerialisationTests {

    /// A stand-in for `gitpic` that brackets its own lifetime in a log, so an
    /// overlap is visible as `start` twice before any `end`.
    private static func fakeGitpic(in dir: URL, log: URL) throws -> URL {
        let fake = dir.appendingPathComponent("gitpic")
        try """
        #!/bin/sh
        printf 'start\\n' >> '\(log.path)'
        sleep 0.1
        printf 'end\\n' >> '\(log.path)'
        """.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fake.path)
        return fake
    }

    @Test("two overlapping applyConfig calls never put two gitpic processes side by side")
    func applyConfigNeverOverlaps() async throws {
        // The invariant the whole type rests on, and the one an actor does not
        // provide: two concurrent `config set` processes each load-mutate-save
        // the whole file, so the second write drops the first.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gitpic-serial-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("log")
        let runner = GitpicRunner(
            tools: ToolPaths(gitpic: try Self.fakeGitpic(in: dir, log: log), gh: nil))

        let old = try JSONDecoder()
            .decode(ConfigEnvelope.self, from: Data(ConfigTests.live.utf8)).config
        var a = old; a.upload.quality = 90; a.github.branch = "gh-pages"
        var b = old; b.upload.quality = 91; b.github.branch = "gh-pages-2"

        // Two callers, two keys each, one process per caller. Both tasks are
        // running before either awaits, which is what lets them reach the actor
        // at the same time.
        async let first = runner.applyConfig(from: old, to: a)
        async let second = runner.applyConfig(from: old, to: b)
        let (wroteFirst, wroteSecond) = try await (first, second)
        #expect(wroteFirst.count == 2)
        #expect(wroteSecond.count == 2)

        let lines = try String(contentsOf: log, encoding: .utf8)
            .split(whereSeparator: \.isNewline).map(String.init)
        #expect(lines.count == 4, "expected two invocations, saw \(lines)")
        var live = 0, peak = 0
        for line in lines {
            live += line == "start" ? 1 : -1
            peak = max(peak, live)
        }
        #expect(peak == 1, "two gitpic processes were alive at once: \(lines)")
    }
}
