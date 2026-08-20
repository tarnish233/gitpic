import Darwin
import Foundation

/// Which snippet the UI hands to the pasteboard.
///
/// This is a *display* choice made entirely in the GUI: a single `--json` upload
/// returns `markdown`, `html`, `url`, and `raw_url` together
/// (`src/output.rs:31-43`), so switching format never costs a re-upload and the
/// CLI's own `--format` flag is not passed at all.
public enum LinkFormat: String, Sendable, CaseIterable, Identifiable {
    case markdown, html, cdn, raw
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .markdown: return "Markdown"
        case .html:     return "HTML"
        case .cdn:      return "CDN URL"
        case .raw:      return "Raw URL"
        }
    }

    public func snippet(_ r: ItemResult) -> String {
        switch self {
        case .markdown: return r.markdown
        case .html:     return r.html
        case .cdn:      return r.url
        case .raw:      return r.rawURL
        }
    }
}

public struct ProcessOutcome: Sendable {
    public let stdout: Data
    public let stderr: Data
    public let status: Int32
    public let timedOut: Bool
}

public enum RunFailure: Error, Sendable, Equatable {
    case spawnFailed(String)
    /// stdout was not the JSON we expect. Carries the raw text so the UI can
    /// show it verbatim instead of inventing an explanation.
    case undecodable(status: Int32, raw: String)
}

/// Runs the bundled `gitpic`.
///
/// Two concurrent `gitpic` uploads race on the branch ref, because every
/// Contents-API PUT creates a commit. The CLI serialises *within* one process
/// (`src/commands/upload.rs`) but nothing stops two processes, so the race
/// surfaces as GitHub 409.
///
/// Being an actor is not what prevents that, and reading it that way is how the
/// race got shipped: actors are reentrant, so every `await` inside a method is a
/// point where the executor admits the next caller. Measured on this exact shape
/// — two overlapping `applyConfig` calls put two `gitpic` processes on the
/// machine at once. `gate` is what actually serialises invocations; the actor
/// only keeps the state around them from being touched concurrently.
public actor GitpicRunner {
    let tools: ToolPaths

    /// The one gate every `gitpic` invocation passes through, and the only reason
    /// no two of them overlap.
    ///
    /// Serial, so an invocation is finished before the next one starts even
    /// though the actor lets its callers interleave freely. A Dispatch queue
    /// rather than an async lock because the spawn blocks on pipes for the whole
    /// run: one dedicated thread absorbs that, and cooperative threads — which
    /// must never block — only ever suspend on the continuation.
    ///
    /// The cost is real and accepted: `gitpic` is invoked with no timeout, so a
    /// wedged CLI holds the gate until it exits. Serialising cannot be had
    /// without that.
    private nonisolated let gate = DispatchQueue(label: "dev.gitpic.app.spawn")

    public init(tools: ToolPaths) { self.tools = tools }

    public var toolPaths: ToolPaths { tools }

    /// Upload one batch, never overlapping another invocation — see `gate`.
    public func upload(paths: [URL]) async throws -> UploadEnvelope {
        precondition(!paths.isEmpty, "upload called with no inputs")
        let args = paths.map(\.path) + ["--json"]
        return try await runJSON(args, as: UploadEnvelope.self)
    }

    /// Upload bytes that have no file on disk yet — a clipboard image.
    ///
    /// Written to a temp file rather than piped through `--stdin` on purpose:
    /// `--stdin` derives the extension by sniffing the bytes and errors with
    /// `USAGE` when it cannot identify them unless `--name` is passed
    /// (`src/commands/upload.rs:397-406`). Writing a real `.png` keeps the
    /// naming path identical to a normal file upload.
    public func upload(pngData: Data, basename: String = "clipboard") async throws -> UploadEnvelope {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gitpic-app-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("\(basename).png")
        try pngData.write(to: file)
        return try await upload(paths: [file])
    }

    public func doctor() async throws -> DoctorReport {
        // doctor exits non-zero when unhealthy but still prints a full report,
        // so a non-zero status here is data, not a failure to report.
        try await runJSON(["doctor", "--json"], as: DoctorReport.self)
    }

    private func runJSON<T: Decodable>(
        _ args: [String],
        as: T.Type
    ) async throws -> T {
        let out = try await run(args)
        guard let decoded = try? JSONDecoder().decode(T.self, from: out.stdout) else {
            throw RunFailure.undecodable(status: out.status, raw: Self.rawText(out))
        }
        return decoded
    }

    nonisolated static func rawText(_ out: ProcessOutcome) -> String {
        let stdout = String(data: out.stdout, encoding: .utf8)
            ?? "<\(out.stdout.count) bytes of non-UTF8>"
        let stderr = (String(data: out.stderr, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if stderr.isEmpty { return stdout }
        if stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return stderr }
        return "\(stdout)\n\(stderr)"
    }

    /// Spawn `gitpic`, wait for it, collect it — one invocation at a time.
    ///
    /// `nonisolated` because none of this needs the actor: `gate` orders the
    /// invocations and `tools` is immutable. Hopping onto the actor would only
    /// add a suspension, and suspensions are precisely what does *not* serialise
    /// here (see the type comment).
    nonisolated func run(_ args: [String]) async throws -> ProcessOutcome {
        let tools = self.tools
        return try await withCheckedThrowingContinuation { cont in
            gate.async {
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = tools.childPATH
                do {
                    let out = try ChildProcess.run(
                        executable: tools.gitpic, args: args, environment: env)
                    cont.resume(returning: out)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }
}

/// Spawn a child, drain both pipes together, optionally bound the wait.
///
/// Draining only stdout and then waiting deadlocks as soon as the child fills
/// the 64 KiB stderr buffer — reachable here because `--verbose` and the
/// clipboard-copy warning both go to stderr. `GHProbe` uses the same helper
/// so a hung `gh auth status` cannot freeze the menu extra.
///
/// With a `timeout`, the total wall clock is bounded for real: the drain gives up
/// on its own deadline instead of waiting for EOF, which is not the same event as
/// the child exiting (see `drain`).
enum ChildProcess {
    /// How long the drain will sit in one `poll` before re-checking whether the
    /// child has gone. It costs nothing in the normal case — EOF wakes `poll`
    /// immediately — so this is only the lag on noticing an exit whose EOF never
    /// comes.
    private static let pollSliceMS: Int32 = 100

    static func run(
        executable: URL,
        args: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval? = nil
    ) throws -> ProcessOutcome {
        let p = Process()
        p.executableURL = executable
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        if let environment { p.environment = environment }

        let so = Pipe(), se = Pipe()
        p.standardOutput = so
        p.standardError = se

        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }

        do { try p.run() } catch {
            throw RunFailure.spawnFailed(error.localizedDescription)
        }

        // Latched, because the drain has to ask repeatedly but the semaphore
        // carries the answer only once: a bare `wait(timeout: .now())` per pass
        // would consume the signal, and the status read below would then believe
        // a finished child is still running.
        var hasExited = false
        func childExited() -> Bool {
            if !hasExited, exited.wait(timeout: .now()) == .success { hasExited = true }
            return hasExited
        }

        let deadline = timeout.map { DispatchTime.now() + $0 }
        let (out, err) = drain(so, se, until: deadline, childExited: childExited)

        // Both pipes closing is not the child exiting — a process can close its
        // output and keep running — so settle exit separately, and inside the
        // same deadline.
        if !hasExited {
            if let deadline {
                if exited.wait(timeout: deadline) == .success { hasExited = true }
            } else {
                exited.wait()
                hasExited = true
            }
        }

        var timedOut = false
        if !hasExited {
            timedOut = true
            p.terminate()
            if exited.wait(timeout: .now() + 2) == .success {
                hasExited = true
            } else {
                kill(p.processIdentifier, SIGKILL)
                if exited.wait(timeout: .now() + 1) == .success { hasExited = true }
            }
        }

        return ProcessOutcome(
            stdout: out,
            stderr: err,
            // `terminationStatus` raises `NSInvalidArgumentException` ("task still
            // running") on a process that has not exited, which `try` cannot catch
            // — it aborts the whole app. The waits above can each expire, SIGKILL
            // included, so only ask when the termination handler has actually
            // fired. Otherwise report the shell's convention for a SIGKILLed
            // child: truthful about what we did, and non-zero, which every caller
            // already treats as failure.
            status: hasExited ? p.terminationStatus : 128 + SIGKILL,
            timedOut: timedOut)
    }

    /// Read both pipes until EOF, `deadline`, or the child exiting with nothing
    /// left to hand over. Returns whatever arrived, on every path.
    ///
    /// One `poll` across both descriptors, so neither pipe can be starved into
    /// the 64 KiB deadlock the type comment names.
    ///
    /// On the calling thread rather than on two reader queues, because a reader
    /// parked in `readDataToEndOfFile()` cannot be recalled: EOF needs *every*
    /// write end closed, and `-l -c` (`ToolDiscovery.loginShellLookup`) sources a
    /// profile that routinely leaves ssh-agent/gpg-agent/nvm holding one, so
    /// killing the child we spawned does not produce EOF. Waiting on those
    /// readers is what made `timeout: 8` bound nothing at all; abandoning them
    /// would instead leak a thread and a `Pipe` per call. A `poll` loop is free
    /// to walk away.
    ///
    /// The child exiting therefore ends the drain, not EOF. Everything it wrote is
    /// already in the pipe buffer by then, so one quiet slice after it is gone
    /// proves nothing more is coming — and that is what turns the ssh-agent case
    /// from an 8-second kill into a clean, complete answer in ~0.1s.
    private static func drain(
        _ stdout: Pipe, _ stderr: Pipe,
        until deadline: DispatchTime?,
        childExited: () -> Bool
    ) -> (Data, Data) {
        var fds = [stdout.fileHandleForReading.fileDescriptor,
                   stderr.fileHandleForReading.fileDescriptor]
        var collected = [Data(), Data()]
        // Non-blocking: a readable `poll` is not a promise that `read` returns, and
        // one blocked read is the exact hang this loop exists to rule out. Only
        // our read ends are touched, so the child's writes stay blocking.
        for fd in fds { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK) }

        var buf = [UInt8](repeating: 0, count: 1 << 16)
        while fds.contains(where: { $0 >= 0 }) {
            if let deadline, DispatchTime.now() >= deadline { break }
            // A negative fd is ignored by `poll` and reports no events, which is how
            // a pipe already at EOF stays out of the way without reshuffling.
            var polled = fds.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
            let ready = poll(&polled, nfds_t(polled.count), pollSliceMS)
            if ready < 0, errno != EINTR { break }

            var moved = false
            for i in fds.indices where fds[i] >= 0 && polled[i].revents != 0 {
                reads: while true {
                    let n = buf.withUnsafeMutableBytes { read(fds[i], $0.baseAddress, $0.count) }
                    switch n {
                    case 1...:
                        collected[i].append(contentsOf: buf.prefix(n))
                        moved = true
                    case 0:
                        fds[i] = -1          // every write end closed
                        break reads
                    default:
                        if errno == EINTR { continue reads }
                        // POLLERR/POLLNVAL land here; there is nothing more to read
                        // from a broken descriptor, so stop polling it.
                        if errno != EAGAIN { fds[i] = -1 }
                        break reads
                    }
                }
            }
            if !moved, ready == 0, childExited() { break }
        }
        return (collected[0], collected[1])
    }
}

// MARK: - Config and history

extension GitpicRunner {
    public func loadConfig() async throws -> GitpicConfig {
        try await runJSON(["config", "get", "--json"], as: ConfigEnvelope.self).config
    }

    public func history(limit: Int = 50) async throws -> [HistoryRecord] {
        try await runJSON(["list", "--limit", String(limit), "--json"],
                          as: HistoryEnvelope.self).results
    }

    /// Writes only the keys that changed, one process each, never overlapping
    /// another invocation.
    ///
    /// `config set` is load → mutate one key → write the whole file with no lock
    /// (`src/commands/config_cmd.rs:82-84`), so two concurrent sets silently drop
    /// one of the two changes. `gate` is what rules that out — not the actor,
    /// which happily admits a second `applyConfig` at the `await` below, and not
    /// this loop, which only orders *this* call's keys.
    ///
    /// What that leaves: two overlapping saves interleave their keys, so a pair
    /// like owner+repo can end up half from each. Deliberately not fixed here —
    /// holding the gate across the whole batch would make each save's pair
    /// consistent, but the loser diffed against a config read before the winner
    /// wrote, so its intent is stale either way. What matters is that no key is
    /// *lost*: each `config set` is a complete load-mutate-write, and it is only
    /// running two of them at once that destroys one.
    ///
    /// Returns the keys written, in the order they were applied.
    @discardableResult
    public func applyConfig(from old: GitpicConfig, to new: GitpicConfig) async throws -> [ConfigKey] {
        let keys = changedKeys(from: old, to: new)
        for key in keys {
            let out = try await run(["config", "set", key.rawValue, key.value(in: new), "--json"])
            guard out.status == 0 else {
                throw RunFailure.undecodable(status: out.status, raw: Self.rawText(out))
            }
        }
        return keys
    }
}
