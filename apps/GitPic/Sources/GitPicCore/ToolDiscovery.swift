import Foundation

/// Where the `gitpic` binary actually lives.
///
/// This type exists because of one measured fact: a Finder-launched `.app` gets
/// `PATH=/usr/bin:/bin:/usr/sbin:/sbin` and nothing else, so tools in user or
/// custom prefixes cannot be found by name. `gitpic` ships inside the bundle
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
        for p in [CommandLineTool.link.path]
        where FileManager.default.isExecutableFile(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        return loginShellLookup("gitpic")
    }

    /// Ask the user's login shell where a tool is. A login shell sources the user's
    /// profile, so this covers nix, asdf, and custom prefixes that the Finder process's
    /// minimal PATH does not contain.
    ///
    /// Every measurement quoted here was taken while this probe was locating `gh`, the
    /// second tool the app used to need. The tool name is a parameter and the parse is
    /// unchanged, so the evidence still applies — it is left as recorded rather than
    /// rewritten to name a tool it was never run against.
    static func loginShellLookup(_ tool: String) -> URL? {
        loginShellProbe(tool).path
    }

    /// What one login-shell probe found, and whether "nothing" is an answer.
    public struct ShellProbe: Sendable {
        public let path: URL?
        /// True only when the shell demonstrably reached the lookup **and** the lookup printed
        /// nothing. Only then does `path == nil` mean the tool is not there.
        public let conclusive: Bool
        public let reason: String?

        public init(path: URL?, conclusive: Bool, reason: String?) {
            self.path = path
            self.conclusive = conclusive
            self.reason = reason
        }
    }

    /// Printed by the shell either side of the lookup, the opening one only if `command -v`
    /// works.
    ///
    /// The opening mark's presence is the evidence that the probe ran; what lies between the
    /// two is the lookup's own output and nothing else. Long and unlikely so a profile cannot
    /// forge either of them.
    static let probeOpen = "__gitpic_probe_5f3a__"
    static let probeClose = "__gitpic_done_5f3a__"

    /// ``loginShellLookup(_:)`` with the reason it came back empty.
    ///
    /// A negative answer needs evidence that the shell reached `command -v`; an exit status is
    /// not enough because profile code can terminate before the lookup. The two markers bracket
    /// the lookup's output. Nothing between them is a conclusive absence; an unusable alias,
    /// function or noisy profile remains inconclusive rather than becoming a confident wrong
    /// answer.
    ///
    /// **`-i` as well as `-l`, and leaving it out was a silent wrong answer.** zsh reads
    /// `.zshrc` for *interactive* shells only; `-l -c` is a login shell that is not interactive,
    /// so it sources `.zshenv`, `.zprofile` and `.zlogin` and skips `.zshrc` entirely. bash
    /// divides its files the same way. Measured on macOS 26.6 against this machine, whose
    /// `export PATH="$HOME/.local/bin:$PATH"` lives at `~/.zshrc:126`:
    /// `zsh -l -c` did not see `~/.local/bin` and `zsh -l -i -c` did.
    ///
    /// The bug stayed hidden for as long as the only tool asked about was `gh`, because
    /// `/opt/homebrew/bin` arrives via `eval "$(brew shellenv)"` in `.zprofile` — a file login
    /// shells do read. `~/.local/bin` is the first path this probe has been asked about that a
    /// person is likely to export from `.zshrc`, and it is where the app's own *install the
    /// command-line tool* button puts its link, so the wrong answer landed squarely on the new
    /// feature: a pane reporting "not on PATH" to someone whose terminal resolves `gitpic`
    /// perfectly well, and telling them to add an entry they already have.
    ///
    /// A login *and* interactive shell is also simply the more faithful model of the question
    /// being asked — "what does the user's terminal find" — because that is what Terminal.app
    /// opens. The cost is that `.zshrc` runs, so a heavy plugin manager now runs inside the
    /// 8-second timeout; that is bounded by the timeout and reported as
    /// ``ShellProbe/conclusive`` false rather than as an absence, and profile chatter on stdout
    /// was already tolerated by the bracketed parse below.
    ///
    /// An interactive shell is safe to spawn here because ``ChildProcess/run`` gives the child
    /// `FileHandle.nullDevice` as stdin, so a shell that would otherwise wait for a line reads
    /// EOF and exits.
    ///
    /// `environment` exists so a test can hand the child a `ZDOTDIR` and prove which startup
    /// files a given flag set actually reaches. Production passes `nil` and the child inherits.
    /// Its `SHELL` also selects the shell to spawn, because an environment that names a shell and
    /// then gets a different one tests nothing: handing a `ZDOTDIR` to whatever `$SHELL` happens
    /// to be on the machine running the test made the result depend on that machine, and it did —
    /// green here where `SHELL=/bin/zsh`, red on a runner where it is bash, which reads no
    /// `ZDOTDIR` at all.
    public static func loginShellProbe(
        _ tool: String,
        environment: [String: String]? = nil
    ) -> ShellProbe {
        let shell = environment?["SHELL"]
            ?? ProcessInfo.processInfo.environment["SHELL"]
            ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell) else {
            return ShellProbe(path: nil, conclusive: false,
                              reason: "找不到可执行的登录 shell（\(shell)）")
        }
        let out: ProcessOutcome
        do {
            out = try ChildProcess.run(
                executable: URL(fileURLWithPath: shell),
                args: ["-l", "-i", "-c",
                       "command -v /bin/sh >/dev/null 2>&1 && echo \(probeOpen);"
                           + " command -v \(tool); echo \(probeClose)"],
                environment: environment,
                timeout: 8)
        } catch {
            return ShellProbe(path: nil, conclusive: false,
                              reason: "登录 shell 无法启动：\(error)")
        }
        // Decoded leniently: `String(data:encoding: .utf8)` returns nil for the
        // *whole* blob when one byte in it is not UTF-8, so a latin-1 motd
        // would discard an answer sitting beside that byte. Repaired bytes become U+FFFD and fail
        // `commandVPath` on their own line.
        //
        // `out.status` and `out.timedOut` deliberately do not gate the *positive*
        // result; `commandVPath` proves the answer instead. Profile noise never
        // moves the status — a profile that fails, or sets `err_exit`, still
        // leaves the status of `command -v` (measured) — but both guards throw
        // away a complete answer when a profile leaves a job holding stdout open
        // (ssh-agent, gpg-agent, nvm): the pipe never reaches EOF, so the
        // 8-second bound fires and kills the shell *after* the path was written.
        // The answer can already be in stdout when the reader has to be killed. Scanned over the
        // whole blob for that reason,
        // marks and all — neither mark is absolute, so neither can be mistaken
        // for a path.
        let stdout = String(decoding: out.stdout, as: UTF8.self)
        if let path = commandVPath(in: stdout, tool: tool) {
            return ShellProbe(path: path, conclusive: true, reason: nil)
        }
        if out.timedOut {
            return ShellProbe(path: nil, conclusive: false,
                              reason: "登录 shell 在 8 秒内没有回答")
        }
        switch Self.probeAnswer(in: stdout) {
        case .none:
            return ShellProbe(path: nil, conclusive: false,
                              reason: "登录 shell 没有跑完这次查找，无法判断有没有装 \(tool)")
        case .some(let answer) where !answer.isEmpty:
            return ShellProbe(path: nil, conclusive: false,
                              reason: "\(tool) 在登录 shell 里不是一个可执行文件"
                                  + "（像是别名或者 shell 函数），没法直接调用")
        case .some:
            return ShellProbe(path: nil, conclusive: true, reason: nil)
        }
    }

    /// What the shell printed between the two marks, or `nil` if it never printed both.
    ///
    /// Pure, so the shapes below can be asserted without a shell. Searched as substrings rather
    /// than as whole lines: a profile whose last write has no trailing newline glues the opening
    /// mark onto it — measured, `glued no newline__gitpic_probe_5f3a__`.
    static func probeAnswer(in stdout: String) -> String? {
        guard let open = stdout.range(of: probeOpen),
              let close = stdout.range(of: probeClose, range: open.upperBound..<stdout.endIndex)
        else { return nil }
        return stdout[open.upperBound..<close.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Pick a tool's path out of a login shell's stdout.
    ///
    /// Pure and separate from the spawn so it can be tested against real profile
    /// noise rather than against a faked login shell.
    ///
    /// The blob is never trimmed and taken as one path. `-l` means the profile
    /// has already spoken on stdout — nvm/conda/rbenv init chatter, a motd,
    /// `fortune`, a stray `echo` in `.zprofile` — so joining it all tested
    /// `"Using node v20.11.0\n/custom/bin/gitpic"` as a filename, failed
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
