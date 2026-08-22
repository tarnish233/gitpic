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
        let out: ProcessOutcome
        do {
            out = try ChildProcess.run(
                executable: URL(fileURLWithPath: shell),
                args: ["-l", "-c", "command -v \(tool)"],
                timeout: 8)
        } catch {
            return nil
        }
        // Decoded leniently: `String(data:encoding: .utf8)` returns nil for the
        // *whole* blob when one byte in it is not UTF-8, so a latin-1 motd
        // (measured: `caf\xe9 welcome\n/opt/homebrew/bin/gh\n`) would discard an
        // answer sitting right there. Repaired bytes become U+FFFD and fail
        // `commandVPath` on their own line.
        //
        // `out.status` and `out.timedOut` deliberately do not gate the result;
        // `commandVPath` proves the answer instead. Profile noise never moves the
        // status — a profile that fails, or sets `err_exit`, still leaves the
        // status of `command -v` (measured) — but both guards throw away a
        // complete answer when a profile leaves a job holding stdout open
        // (ssh-agent, gpg-agent, nvm): the pipe never reaches EOF, so the
        // 8-second bound fires and kills the shell *after* the path was written.
        // Measured: stdout already held `/opt/homebrew/bin/gh` at the moment the
        // reader had to be killed.
        return commandVPath(in: String(decoding: out.stdout, as: UTF8.self), tool: tool)
    }

    /// Pick a tool's path out of a login shell's stdout.
    ///
    /// Pure and separate from the spawn so it can be tested against real profile
    /// noise rather than against a faked login shell.
    ///
    /// The blob is never trimmed and taken as one path. `-l` means the profile
    /// has already spoken on stdout — nvm/conda/rbenv init chatter, a motd,
    /// `fortune`, a stray `echo` in `.zprofile` — so joining it all tested
    /// `"Using node v20.11.0\n/opt/homebrew/bin/gh"` as a filename, failed
    /// `isExecutableFile`, and reported gh as missing. A noise line from
    /// `command -v` must not be taken as the tool path; that is what this parse
    /// is for, on the machines the probe exists for: nix, asdf, a custom prefix,
    /// anything `ghCandidates` does not list.
    ///
    /// Lines are read last-first, since `command -v` answers after the profile
    /// has finished talking, but position is never why a line is accepted. Each
    /// candidate proves itself, in the same spirit as `GHProbe.account` below
    /// anchoring on a full phrase rather than a bare word:
    ///
    /// - Its last component must be `tool`. `command -v` appends `/<tool>` to the
    ///   PATH entry it found, so a real answer always matches, while a noise line
    ///   naming some *other* real executable — a motd quoting `/bin/sh`, or a
    ///   stdout cut short when the timeout killed the shell — cannot come back as
    ///   `gh` and then be spawned.
    /// - It must be absolute, or it would be resolved against this process's
    ///   working directory, which for a Finder-launched `.app` is `/`.
    /// - It must be an executable file, which is the actual proof.
    ///
    /// Passing all three means a real executable of that name exists at that
    /// path, so the answer holds however the shell exited. The non-paths
    /// `command -v` also prints — `gh` for a function, `alias gh='…'` for an
    /// alias — fail, which is correct: neither can be spawned as a child.
    static func commandVPath(in stdout: String, tool: String) -> URL? {
        for line in stdout.split(whereSeparator: \.isNewline).reversed() {
            let candidate = line.trimmingCharacters(in: .whitespaces)
            guard candidate.hasPrefix("/"),
                  URL(fileURLWithPath: candidate).lastPathComponent == tool,
                  FileManager.default.isExecutableFile(atPath: candidate)
            else { continue }
            return URL(fileURLWithPath: candidate)
        }
        return nil
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
        let out: ProcessOutcome
        do {
            out = try ChildProcess.run(
                executable: gh,
                args: ["auth", "status", "--hostname", "github.com"],
                timeout: 8)
        } catch {
            return .notInstalled
        }
        if out.timedOut {
            return .failed(detail: "gh auth status timed out")
        }
        let text = [out.stdout, out.stderr].compactMap { String(data: $0, encoding: .utf8) }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if out.status == 0 {
            return .ready(account: Self.account(in: text))
        }
        // gh says "not logged in" / "not logged into any hosts" on stderr.
        let lowered = text.lowercased()
        if lowered.contains("not logged in") || lowered.contains("no accounts") {
            return .notLoggedIn(detail: text)
        }
        return .failed(detail: text.isEmpty ? "gh auth status exited \(out.status)" : text)
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
