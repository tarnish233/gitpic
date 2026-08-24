import Foundation

/// Where the `gitpic` binary actually lives.
///
/// This type exists because of one measured fact: a Finder-launched `.app` gets
/// `PATH=/usr/bin:/bin:/usr/sbin:/sbin` and nothing else, so nothing on a
/// Homebrew or nix prefix can be found by name. `gitpic` ships inside the bundle
/// and is therefore located by path, not by PATH — but the probe below still
/// exists for `swift run` during development, where there is no bundle.
///
/// Measuring this requires launching via Finder (`tell application "Finder" to
/// open …`). Launching with `open(1)` propagates the caller's environment and
/// shows a full PATH, which is a false negative.
///
/// It used to carry a `gh` location too. The CLI took its credential from
/// `gh auth token`, so a Finder-launched GUI had to find `gh` and put it on the
/// child's PATH or every upload failed with `CONFIG_MISSING`. `gitpic` now holds
/// its own credential (`gitpic auth login`) and spawns nothing to get it, so
/// there is no second tool to locate.
public struct ToolPaths: Sendable, Equatable {
    public let gitpic: URL

    /// The PATH handed to the `gitpic` child.
    ///
    /// Set explicitly rather than inherited so the child's environment is the same
    /// however the app was launched — a Finder launch and a `swift run` from a
    /// terminal otherwise hand it two very different PATHs. The minimal Finder set is
    /// enough: what `gitpic` may spawn is a platform opener (`/usr/bin/open`), and
    /// only during `auth login`, which the app never invokes.
    ///
    /// `static`, because it no longer depends on anything discovery found. It was an
    /// instance member while it had gh's directory to prepend.
    public static let childPATH = "/usr/bin:/bin:/usr/sbin:/sbin"
}

public enum ToolDiscovery {
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

    /// Where `brew` is, for the one thing the app asks of it: upgrading its own cask.
    ///
    /// Same shape as ``locateGitpic(bundleResourceURL:)`` minus the bundle, and it exists
    /// for the same measured reason — a Finder-launched app's PATH is
    /// `/usr/bin:/bin:/usr/sbin:/sbin`, so neither Homebrew prefix is on it and `brew`
    /// cannot be found by name however normal it looks in a terminal.
    ///
    /// The two hardcoded prefixes are Homebrew's own defaults (Apple Silicon, then Intel)
    /// and answer the overwhelming majority without spawning a login shell, which costs up
    /// to 8 seconds. The probe is the fallback for a custom `HOMEBREW_PREFIX`.
    ///
    /// `nil` means "do not offer to upgrade" rather than "not installed": the app cannot
    /// tell those apart from here, and both have the same remedy — send the user to the
    /// release page instead. See `Updater`.
    public static func locateBrew() -> URL? {
        for p in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        where FileManager.default.isExecutableFile(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        return loginShellLookup("brew")
    }

    /// What `brew` says about one cask.
    ///
    /// Three answers, not two, because the caller acts differently on each: an upgrade may
    /// be offered only for ``installed``, and the other two differ in what the log should
    /// say — a non-zero exit is Homebrew answering "I do not manage that", while a spawn
    /// failure means the answer was never obtained.
    public enum BrewCaskStatus: Equatable, Sendable {
        case installed
        case notInstalled(status: Int32)
        case unusable(reason: String)
    }

    /// Whether Homebrew is managing `cask`.
    ///
    /// Asked because finding `brew` proves nothing about *this* app's origin: a
    /// drag-installed copy on a machine that also has Homebrew is entirely ordinary, and
    /// `brew upgrade --cask` there fails with "not installed". `brew list --cask <name>`
    /// exits 0 when installed and non-zero when not; the status is the whole answer, so
    /// stdout is discarded rather than parsed.
    ///
    /// Bounded at 20 seconds: a first invocation can catch Homebrew doing its own
    /// housekeeping, and this runs behind a window that is waiting to draw a button.
    ///
    /// Spawning lives here rather than in `GitPicApp` because `ChildProcess` is internal to
    /// this module — the same reason `locateBrew()` is here and not beside its one caller.
    public static func brewCaskStatus(_ cask: String, brew: URL) -> BrewCaskStatus {
        do {
            let out = try ChildProcess.run(
                executable: brew,
                args: ["list", "--cask", cask],
                timeout: 20)
            if out.timedOut {
                return .unusable(reason: "brew list --cask \(cask) timed out")
            }
            return out.status == 0 ? .installed : .notInstalled(status: out.status)
        } catch {
            return .unusable(reason: "brew list --cask \(cask) failed: \(error)")
        }
    }

    /// Ask the user's login shell where a tool is. A login shell sources the user's
    /// profile, so this covers nix, asdf, and custom prefixes that no hardcoded list
    /// would catch. Verified to return `/opt/homebrew/bin/gh` even from a
    /// Finder-launched process whose own PATH lacks it.
    ///
    /// Every measurement quoted here was taken while this probe was locating `gh`, the
    /// second tool the app used to need. The tool name is a parameter and the parse is
    /// unchanged, so the evidence still applies — it is left as recorded rather than
    /// rewritten to name a tool it was never run against.
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
    /// `"Using node v20.11.0\n/opt/homebrew/bin/gitpic"` as a filename, failed
    /// `isExecutableFile`, and reported the tool as missing. A noise line from
    /// `command -v` must not be taken as the tool path; that is what this parse
    /// is for, on the machines the probe exists for: nix, asdf, a custom prefix,
    /// anything the hardcoded candidates do not list.
    ///
    /// Lines are read last-first, since `command -v` answers after the profile
    /// has finished talking, but position is never why a line is accepted. Each
    /// candidate proves itself, rather than being trusted for its position:
    ///
    /// - Its last component must be `tool`. `command -v` appends `/<tool>` to the
    ///   PATH entry it found, so a real answer always matches, while a noise line
    ///   naming some *other* real executable — a motd quoting `/bin/sh`, or a
    ///   stdout cut short when the timeout killed the shell — cannot come back as
    ///   the tool and then be spawned.
    /// - It must be absolute, or it would be resolved against this process's
    ///   working directory, which for a Finder-launched `.app` is `/`.
    /// - It must be an executable file, which is the actual proof.
    ///
    /// Passing all three means a real executable of that name exists at that
    /// path, so the answer holds however the shell exited. The non-paths
    /// `command -v` also prints — the bare name for a function, `alias x='…'` for
    /// an alias — fail, which is correct: neither can be spawned as a child.
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
        return ToolPaths(gitpic: gitpic)
    }
}
