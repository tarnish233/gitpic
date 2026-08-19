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
}

public enum RunFailure: Error, Sendable, Equatable {
    case spawnFailed(String)
    /// stdout was not the JSON we expect. Carries the raw text so the UI can
    /// show it verbatim instead of inventing an explanation.
    case undecodable(status: Int32, raw: String)
}

/// Runs the bundled `gitpic`.
///
/// An actor, and that is load-bearing rather than stylistic: two concurrent
/// `gitpic` uploads race on the branch ref, because every Contents-API PUT
/// creates a commit. The CLI serialises *within* one process
/// (`src/commands/upload.rs:136-138`) but nothing stops two processes, and
/// `map_status` has no 409 arm (`src/github.rs:143-159`), so the race surfaces
/// as a bare `GENERAL` exit 1 carrying GitHub's raw response body. Funnelling
/// every invocation through one actor is what keeps that from happening.
public actor GitpicRunner {
    let tools: ToolPaths

    public init(tools: ToolPaths) { self.tools = tools }

    public var toolPaths: ToolPaths { tools }

    /// Upload one batch. Serialised against every other call on this actor.
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
    /// (`src/commands/upload.rs:303-314`). Writing a real `.png` keeps the
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
        try await runJSON(["doctor", "--json"], as: DoctorReport.self, allowNonZeroExit: true)
    }

    private func runJSON<T: Decodable>(
        _ args: [String],
        as: T.Type,
        allowNonZeroExit: Bool = true
    ) async throws -> T {
        let out = try await Self.run(
            executable: tools.gitpic, args: args, childPATH: tools.childPATH)
        guard let decoded = try? JSONDecoder().decode(T.self, from: out.stdout) else {
            let raw = String(data: out.stdout, encoding: .utf8)
                ?? "<\(out.stdout.count) bytes of non-UTF8>"
            throw RunFailure.undecodable(status: out.status, raw: raw)
        }
        return decoded
    }

    /// Spawn and collect. Off the actor's executor: this blocks on pipes, and
    /// blocking a cooperative thread would stall unrelated work.
    ///
    /// Both pipes are drained concurrently with the wait. Draining only stdout
    /// and then waiting deadlocks as soon as the child fills the 64 KiB stderr
    /// buffer — reachable here because `--verbose` and the jsDelivr/clipboard
    /// warnings all go to stderr.
    nonisolated static func run(
        executable: URL, args: [String], childPATH: String
    ) async throws -> ProcessOutcome {
        try await withCheckedThrowingContinuation { cont in
            let queue = DispatchQueue(label: "dev.gitpic.app.spawn")
            queue.async {
                let p = Process()
                p.executableURL = executable
                p.arguments = args
                p.standardInput = FileHandle.nullDevice
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = childPATH
                p.environment = env

                let so = Pipe(), se = Pipe()
                p.standardOutput = so
                p.standardError = se

                do { try p.run() } catch {
                    cont.resume(throwing: RunFailure.spawnFailed(error.localizedDescription))
                    return
                }

                let group = DispatchGroup()
                let box = DataBox()
                for (pipe, isOut) in [(so, true), (se, false)] {
                    group.enter()
                    DispatchQueue.global().async {
                        let d = pipe.fileHandleForReading.readDataToEndOfFile()
                        box.set(d, out: isOut)
                        group.leave()
                    }
                }
                group.wait()
                p.waitUntilExit()
                cont.resume(returning: ProcessOutcome(
                    stdout: box.stdout, stderr: box.stderr, status: p.terminationStatus))
            }
        }
    }
}

/// Tiny lock-guarded box so the two reader queues can hand results back without
/// tripping Swift 6's concurrency checking.
private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _out = Data()
    private var _err = Data()
    func set(_ d: Data, out: Bool) {
        lock.lock(); defer { lock.unlock() }
        if out { _out = d } else { _err = d }
    }
    var stdout: Data { lock.lock(); defer { lock.unlock() }; return _out }
    var stderr: Data { lock.lock(); defer { lock.unlock() }; return _err }
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

    /// Writes only the keys that changed, one process each, strictly in sequence.
    ///
    /// `config set` is load → mutate one key → write the whole file with no lock
    /// (`src/commands/config_cmd.rs:82-84`), so two concurrent sets silently drop
    /// one of the two changes. Being on the actor is what serialises them; the
    /// sequential `await` loop inside is what keeps them from overlapping.
    ///
    /// Returns the keys written, in the order they were applied.
    @discardableResult
    public func applyConfig(from old: GitpicConfig, to new: GitpicConfig) async throws -> [ConfigKey] {
        let keys = changedKeys(from: old, to: new)
        for key in keys {
            let out = try await Self.run(
                executable: tools.gitpic,
                args: ["config", "set", key.rawValue, key.value(in: new), "--json"],
                childPATH: tools.childPATH)
            guard out.status == 0 else {
                let raw = String(data: out.stdout, encoding: .utf8) ?? ""
                throw RunFailure.undecodable(status: out.status, raw: raw)
            }
        }
        return keys
    }
}
