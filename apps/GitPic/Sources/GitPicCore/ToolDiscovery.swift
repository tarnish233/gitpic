import Foundation

/// Where the two binaries we depend on actually live.
///
/// This type exists because of one measured fact: a Finder-launched `.app` gets
/// `PATH=/usr/bin:/bin:/usr/sbin:/sbin` and nothing else. `gh` is not on it, and
/// `src/auth.rs:49` looks `gh` up by bare name with no absolute-path fallback and
/// no config key to override — so without explicit discovery every upload from a
/// Finder-launched GUI fails with `CONFIG_MISSING`.
///
/// Measuring this requires launching via Finder (`tell application "Finder" to
/// open …`). Launching with `open(1)` propagates the caller's environment and
/// shows a full PATH, which is a false negative.
public struct ToolPaths: Sendable, Equatable {
    public let gitpic: URL
    /// `nil` means gh was not found; the GUI must route the user to install it
    /// rather than let the upload fail with a collapsed error.
    public let gh: URL?

    /// PATH to hand the `gitpic` child so its own `Command::new("gh")` resolves.
    public var childPATH: String {
        let base = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        guard let gh else { return base.joined(separator: ":") }
        return ([gh.deletingLastPathComponent().path] + base).joined(separator: ":")
    }
}

public enum ToolDiscovery {
    /// Ordered candidates, cheapest first. The login-shell probe is last because
    /// it costs a process spawn and shell startup.
    static let ghCandidates = [
        "/opt/homebrew/bin/gh",   // Apple Silicon Homebrew
        "/usr/local/bin/gh",      // Intel Homebrew
        "/run/current-system/sw/bin/gh",  // nix-darwin
    ]

    /// `gitpic` ships inside the bundle, so it is never searched for on PATH.
    /// Falls back to a PATH lookup only for `swift run` during development,
    /// where there is no bundle.
    public static func locateGitpic(bundleResourceURL: URL?) -> URL? {
        if let bundled = bundleResourceURL?.appendingPathComponent("gitpic"),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        for p in ["/opt/homebrew/bin/gitpic", "/usr/local/bin/gitpic"]
        where FileManager.default.isExecutableFile(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        return loginShellLookup("gitpic")
    }

    public static func locateGH() -> URL? {
        for p in ghCandidates where FileManager.default.isExecutableFile(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        return loginShellLookup("gh")
    }

    /// Ask the user's login shell where a tool is. A login shell sources the
    /// user's profile, so this covers nix, asdf, and custom prefixes that no
    /// hardcoded list would catch. Verified to return `/opt/homebrew/bin/gh`
    /// even from a Finder-launched process whose own PATH lacks it.
    static func loginShellLookup(_ tool: String) -> URL? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-l", "-c", "command -v \(tool)"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let line = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !line.isEmpty,
              FileManager.default.isExecutableFile(atPath: line)
        else { return nil }
        return URL(fileURLWithPath: line)
    }

    public static func resolve(bundleResourceURL: URL?) -> ToolPaths? {
        guard let gitpic = locateGitpic(bundleResourceURL: bundleResourceURL) else { return nil }
        return ToolPaths(gitpic: gitpic, gh: locateGH())
    }
}

/// Why `gitpic` could not get a credential — the distinction the CLI throws away.
///
/// `src/auth.rs` maps "gh missing", "gh not logged in", and "gh exited non-zero"
/// all to `CONFIG_MISSING` with one message, and discards gh's stderr
/// (`Stdio::null()`). First-run guidance needs the first two told apart, so the
/// GUI runs `gh auth status` itself, where stderr survives.
public enum GHStatus: Sendable, Equatable {
    case notInstalled
    case notLoggedIn(detail: String)
    case ready(account: String?)
    case failed(detail: String)
}

public enum GHProbe {
    public static func status(gh: URL?) -> GHStatus {
        guard let gh else { return .notInstalled }
        let p = Process()
        p.executableURL = gh
        p.arguments = ["auth", "status", "--hostname", "github.com"]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return .notInstalled }
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = [o, e].compactMap { String(data: $0, encoding: .utf8) }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if p.terminationStatus == 0 {
            return .ready(account: Self.account(in: text))
        }
        // gh says "not logged in" / "not logged into any hosts" on stderr.
        let lowered = text.lowercased()
        if lowered.contains("not logged in") || lowered.contains("no accounts") {
            return .notLoggedIn(detail: text)
        }
        return .failed(detail: text.isEmpty ? "gh auth status exited \(p.terminationStatus)" : text)
    }

    /// Pulls the account out of gh's prose. Best-effort by design: this is a
    /// display nicety, never a correctness input.
    ///
    /// Anchored on gh's full phrasing — "Logged in to github.com account <login>"
    /// — rather than on the word "account" alone. Searching for the bare word
    /// matches any sentence containing it and returns whatever follows, which
    /// yields a plausible-looking but fabricated login.
    static func account(in text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            guard line.contains("Logged in to"),
                  let r = line.range(of: "account ") else { continue }
            let token = line[r.upperBound...]
                .prefix(while: { !$0.isWhitespace })
                .trimmingCharacters(in: .whitespaces)
            if let t = token.nilIfEmpty { return t }
        }
        return nil
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
