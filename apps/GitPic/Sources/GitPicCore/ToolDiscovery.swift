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
        /// True only when the shell demonstrably reached the lookup **and** the lookup printed
        /// nothing. Only then does `path == nil` mean the tool is not there.
        let conclusive: Bool
        let reason: String?
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
    /// **The negative answer needs its own evidence, and the exit status is not it.** This
    /// probe's `conclusive` used to be `!out.timedOut`, which reads the *positive* answer's
    /// reasoning (below) onto a question it does not cover: when there is no path, whether the
    /// shell ever got as far as asking is the only thing that matters, and a prompt non-zero
    /// exit with empty stdout looks identical to "the tool is not installed". Measured on this
    /// machine, all four of these return promptly, with empty stdout and no timeout:
    ///
    /// | shell / profile                    | status | stdout |
    /// | ---------------------------------- | ------ | ------ |
    /// | `/bin/tcsh -l -c` (no `command`)   | 1      | empty  |
    /// | `/bin/csh -l -c`                   | 1      | empty  |
    /// | `.zprofile` containing `exit 1`    | 1      | empty  |
    /// | `.zprofile` containing `exec true` | **0**  | empty  |
    ///
    /// The last one is why the exit status cannot be the fix either. All four used to come back
    /// `conclusive: true, path: nil`.
    ///
    /// **What that used to cost, and what it costs now.** This probe had a second caller: the
    /// Homebrew ownership question, where a false "absent" folded into "not brew's" and
    /// authorised replacing whatever was in `/Applications`. That caller is gone, and it did not
    /// come back when the ownership question did — `CaskOwnership.detect` reads the Caskroom's own
    /// symlinks instead of asking `brew` whether it exists, so no shell is involved and there is
    /// no "could not tell" to fold. The evidence below is kept as measured, because the
    /// bracketing it justifies is still what makes the *remaining* caller correct: a false
    /// "absent" now means `locateGitpic` reports no CLI on a machine that has one, which is a
    /// milder failure than an unwanted install but still a wrong answer, and still reachable
    /// exactly for the custom-prefix users this probe exists to serve — the hardcoded paths are
    /// checked first, so only they get here.
    ///
    /// So the shell is made to prove it ran, and to bracket its answer. It prints
    /// ``probeOpen`` before the lookup — guarded by `command -v /bin/sh`, a lookup of something
    /// that exists on every macOS, so the guard fails only where `command -v` itself does not
    /// work — and ``probeClose`` after it. Measured: zsh, bash, sh, ksh and dash print both;
    /// tcsh and csh print nothing at all. What is between the marks is the lookup's output,
    /// which separates the two remaining cases:
    ///
    /// - nothing between them → the tool really is not there → conclusive.
    /// - something between them that is not a usable path → the tool exists as an alias or a
    ///   shell function (measured: zsh prints `brew` for a function and `alias brew=…` for an
    ///   alias — the measurement was taken against `brew`, which is no longer a tool this
    ///   locates, and is left as recorded because the parse it exercises is unchanged), which
    ///   ``commandVPath(in:tool:)`` rightly refuses to spawn — but it is *not* absence.
    ///
    /// The closing mark is what keeps a late-flushing profile job out of that second case:
    /// measured, `[gpg-agent] ready` arriving after the lookup lands *after* ``probeClose`` and
    /// so cannot turn "the tool is not here" into "cannot tell". A job that flushes in the
    /// microseconds between the two marks still can, and that is the safe direction — an
    /// inconclusive answer, rather than a confident wrong one.
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
                args: ["-l", "-c",
                       "command -v /bin/sh >/dev/null 2>&1 && echo \(probeOpen);"
                           + " command -v \(tool); echo \(probeClose)"],
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
        // `out.status` and `out.timedOut` deliberately do not gate the *positive*
        // result; `commandVPath` proves the answer instead. Profile noise never
        // moves the status — a profile that fails, or sets `err_exit`, still
        // leaves the status of `command -v` (measured) — but both guards throw
        // away a complete answer when a profile leaves a job holding stdout open
        // (ssh-agent, gpg-agent, nvm): the pipe never reaches EOF, so the
        // 8-second bound fires and kills the shell *after* the path was written.
        // Measured: stdout already held `/opt/homebrew/bin/gh` at the moment the
        // reader had to be killed. Scanned over the whole blob for that reason,
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
