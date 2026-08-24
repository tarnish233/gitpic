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
    /// `nil` collapses "not installed" and "could not tell", which is all the brew upgrade
    /// path ever needed — both have the same remedy there. Use ``locateBrewOutcome()`` when
    /// the difference matters.
    public static func locateBrew() -> URL? {
        if case .found(let url) = locateBrewOutcome() { return url }
        return nil
    }

    /// Whether `brew` is on this machine, keeping "no" and "could not tell" apart.
    public enum BrewLocation: Equatable, Sendable {
        case found(URL)
        /// The login shell answered, and there is no `brew`. A durable fact about the
        /// machine.
        case absent
        /// No answer was obtained — the probe hit its 8 s bound, or the shell could not be
        /// spawned. Says nothing either way and must not be cached.
        case unknown(reason: String)
    }

    /// Locate `brew`, reporting *which* kind of "not found" this is.
    ///
    /// **Why the distinction had to exist.** ``locateBrew()`` returns `nil` both for a
    /// machine with no Homebrew and for a probe that timed out, and the update path treated
    /// both as "ask again later". That was harmless while Homebrew was the only way to
    /// upgrade. It is not harmless now: a machine with no `brew` at all is exactly the
    /// machine the in-app installer exists for, and folding it in with "could not tell" left
    /// that user retrying a probe forever instead of being offered the one path that works.
    ///
    /// The asymmetry is deliberate and follows ``loginShellLookup(_:)``'s own reasoning: a
    /// path found in stdout is trusted even if the shell had to be killed, because the answer
    /// was already written. The bound only decides whether the *absence* of a path means
    /// anything.
    public static func locateBrewOutcome() -> BrewLocation {
        for p in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        where FileManager.default.isExecutableFile(atPath: p) {
            return .found(URL(fileURLWithPath: p))
        }
        let probe = loginShellProbe("brew")
        if let path = probe.path { return .found(path) }
        guard probe.conclusive else {
            return .unknown(reason: probe.reason ?? "brew 探测没有得到结果")
        }
        return .absent
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

    /// Which bundle Homebrew installed for `cask`, if any.
    public enum BrewCaskApp: Equatable, Sendable {
        /// brew manages this cask, and this is the `.app` it put in place.
        case installedAt(URL)
        /// brew answered: it does not manage this cask.
        case notInstalled(status: Int32)
        /// No answer was obtained.
        case unusable(reason: String)
    }

    /// Ask Homebrew *which* bundle it installed for `cask`, not merely whether it did.
    ///
    /// **Why the path and not a yes/no.** `brew list --cask gitpic` exits 0 whenever the cask
    /// is installed *anywhere*, and that is not the question. A copy in `~/Applications` on a
    /// machine whose cask installed to `/Applications` would answer "yes" and then be handed to
    /// `brew upgrade`, which would replace the *other* bundle and leave this one — an old build,
    /// still reporting the same update available, with brew reporting nothing left to do. The
    /// user could repeat that forever. Caught by running it, not by reading it.
    ///
    /// Homebrew answers exactly: the Caskroom holds a symlink at
    /// `<prefix>/Caskroom/<cask>/<version>/GitPic.app` pointing at wherever the app was
    /// installed, and `brew list --cask` prints that path. Resolving it gives the bundle brew
    /// owns, with no parsing of human-readable output and no guessing at `--appdir`.
    public static func brewCaskApp(_ cask: String, brew: URL) -> BrewCaskApp {
        let out: ProcessOutcome
        do {
            out = try ChildProcess.run(
                executable: brew, args: ["list", "--cask", cask], timeout: 20)
        } catch {
            return .unusable(reason: "brew list --cask \(cask) failed: \(error)")
        }
        if out.timedOut { return .unusable(reason: "brew list --cask \(cask) timed out") }
        guard out.status == 0 else { return .notInstalled(status: out.status) }

        // One path per line. The `.app` among them is the artifact; the rest are the receipt
        // and the cask's own JSON.
        let lines = String(decoding: out.stdout, as: UTF8.self)
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let app = lines.first(where: { $0.hasSuffix(".app") }) else {
            // Installed, but it lists no bundle — nothing here can be compared against, so
            // treat it as an answer that does not name this bundle.
            return .notInstalled(status: 0)
        }
        return .installedAt(URL(fileURLWithPath: app).resolvingSymlinksInPath()
            .standardizedFileURL)
    }

    /// Whether Homebrew is managing `cask`.
    ///
    /// Kept for callers that only need the yes/no; ``brewCaskApp(_:brew:)`` is what the update
    /// path uses, because "installed" and "installed *as this bundle*" are different questions.
    ///
    /// Bounded at 20 seconds: a first invocation can catch Homebrew doing its own
    /// housekeeping, and this runs behind a window that is waiting to draw a button.
    ///
    /// Spawning lives here rather than in `GitPicApp` because `ChildProcess` is internal to
    /// this module — the same reason `locateBrew()` is here and not beside its one caller.
    public static func brewCaskStatus(_ cask: String, brew: URL) -> BrewCaskStatus {
        switch brewCaskApp(cask, brew: brew) {
        case .installedAt: return .installed
        case .notInstalled(let status): return .notInstalled(status: status)
        case .unusable(let reason): return .unusable(reason: reason)
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
        loginShellProbe(tool).path
    }

    /// What one login-shell probe found, and whether "nothing" is an answer.
    struct ShellProbe {
        let path: URL?
        /// True when the shell ran to completion. Only then does `path == nil` mean the tool
        /// is not there; otherwise the probe simply did not finish.
        let conclusive: Bool
        let reason: String?
    }

    /// ``loginShellLookup(_:)`` with the reason it came back empty.
    ///
    /// The body is unchanged from when this returned a bare Optional; all that is new is
    /// carrying out *why* there was no path, which only the brew caller needs.
    static func loginShellProbe(_ tool: String) -> ShellProbe {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell) else {
            return ShellProbe(path: nil, conclusive: false,
                              reason: "找不到可执行的登录 shell（\(shell)）")
        }
        let out: ProcessOutcome
        do {
            out = try ChildProcess.run(
                executable: URL(fileURLWithPath: shell),
                args: ["-l", "-c", "command -v \(tool)"],
                timeout: 8)
        } catch {
            return ShellProbe(path: nil, conclusive: false,
                              reason: "登录 shell 无法启动：\(error)")
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
        let path = commandVPath(in: String(decoding: out.stdout, as: UTF8.self), tool: tool)
        // The bound gates only the *negative* answer, which is the other half of the same
        // reasoning: a shell that had to be killed never got to say whether the tool exists,
        // so "no path" from it is not evidence of absence.
        return ShellProbe(
            path: path,
            conclusive: !out.timedOut,
            reason: out.timedOut ? "登录 shell 在 8 秒内没有回答" : nil)
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
