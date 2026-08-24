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

    /// Which `brew`s are on this machine, keeping "none" and "could not tell" apart.
    public enum BrewLocation: Equatable, Sendable {
        /// Every `brew` found, in the order they were looked for.
        ///
        /// A **list**, not one path, and that is the whole point. A machine that has had both
        /// an Intel and an Apple Silicon Homebrew has two prefixes with two independent
        /// Caskrooms, and asking only the first one is how a cask installed by
        /// `/usr/local/bin/brew` gets reported as "nobody's" by `/opt/homebrew/bin/brew` —
        /// after which the in-app installer replaces a bundle brew manages. Never empty.
        case found([URL])
        /// The login shell answered, and there is no `brew`. A durable fact about the
        /// machine.
        case absent
        /// No answer was obtained — the probe hit its 8 s bound, the shell never reached the
        /// lookup, or it could not be spawned. Says nothing either way and must not be cached.
        case unknown(reason: String)
    }

    /// Locate every `brew` on the machine, reporting *which* kind of "not found" this is.
    ///
    /// Exists for the same measured reason ``locateGitpic(bundleResourceURL:)`` does: a
    /// Finder-launched app's PATH is `/usr/bin:/bin:/usr/sbin:/sbin`, so neither Homebrew
    /// prefix is on it and `brew` cannot be found by name however normal it looks in a
    /// terminal.
    ///
    /// **Why the absent/unknown distinction had to exist.** A single `nil` for both a machine
    /// with no Homebrew and a probe that timed out was harmless while Homebrew was the only
    /// way to upgrade — both meant "ask again later". It is not harmless now: a machine with
    /// no `brew` at all is exactly the machine the in-app installer exists for, and folding it
    /// in with "could not tell" left that user retrying a probe forever instead of being
    /// offered the one path that works.
    ///
    /// The two hardcoded prefixes are Homebrew's own defaults (Apple Silicon, then Intel) and
    /// answer the overwhelming majority without spawning a login shell, which costs up to
    /// 8 seconds. The probe is the fallback for a custom `HOMEBREW_PREFIX`.
    ///
    /// **The stated gap.** Because the hardcoded paths short-circuit the probe, a machine with
    /// a *vestigial* `/opt/homebrew/bin/brew` plus a custom-prefix brew that owns the cask is
    /// still asked only the vestigial one. Closing it would mean paying the 8 s login shell on
    /// every sheet open for everyone, including the very common "brew is here and it is not
    /// mine" case. Left open deliberately; the alternative is a worse trade.
    ///
    /// The asymmetry in ``loginShellProbe(_:)`` is deliberate and follows its own reasoning: a
    /// path found in stdout is trusted even if the shell had to be killed, because the answer
    /// was already written. The bound and the two marks only decide whether the *absence* of a
    /// path means anything.
    public static func locateBrewOutcome() -> BrewLocation {
        let hardcoded = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .filter { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
        if !hardcoded.isEmpty { return .found(hardcoded) }
        let probe = loginShellProbe("brew")
        if let path = probe.path { return .found([path]) }
        guard probe.conclusive else {
            return .unknown(reason: probe.reason ?? "没能确认这台机器上有没有 Homebrew")
        }
        return .absent
    }

    /// Which bundle Homebrew installed for `cask`, if any.
    ///
    /// Three answers, and the boundary between them is the whole safety property: only
    /// ``notInstalled`` may authorise replacing a bundle, so anything short of Homebrew
    /// positively saying "I have nothing under that token" has to be ``unusable``.
    public enum BrewCaskApp: Equatable, Sendable {
        /// brew manages this cask, and these are the bundles it lists — plural, because a
        /// Caskroom can hold more than one version and each version directory has its own
        /// `GitPic.app` symlink. Never empty, and every entry exists on disk.
        case installedAt([URL])
        /// brew has nothing installed under this token. A durable fact, and the only answer
        /// that may lead to an install.
        case notInstalled(status: Int32)
        /// No usable answer. `reason` is user-facing Chinese; the command line, the exit
        /// status and brew's own stderr go to ``Diagnostics/log(_:)`` instead, because this
        /// string is rendered in a Chinese-only sheet (`UpdateSheet`).
        case unusable(reason: String)
    }

    /// Ask Homebrew *which* bundle it installed for `cask`, not merely whether it did.
    ///
    /// Bounded at 20 seconds: a first invocation can catch Homebrew doing its own housekeeping,
    /// and this runs behind a window that is waiting to draw a button. Spawning lives here
    /// rather than in `GitPicApp` because `ChildProcess` is internal to this module — the same
    /// reason ``locateBrewOutcome()`` is here and not beside its one caller.
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
    ///
    /// **Every ambiguous answer is ``BrewCaskApp/unusable(reason:)``, never "not mine".** Three
    /// measured reasons, all on Homebrew 6.0.19 on this machine:
    ///
    /// 1. **Homebrew has exactly one error exit code.** `brew list --cask firefox` (a real cask,
    ///    not installed) exits 1 with `find: /opt/homebrew/Caskroom/firefox: No such file or
    ///    directory`; `env -i brew list --cask gitpic` *also* exits 1, with `Error: $HOME must
    ///    be set to run brew.`; and `brew list --cask definitely-not-real-xyz` exits 1 with
    ///    `Error: Cask '…' is unavailable: No Cask with this name exists.` So the status alone
    ///    distinguishes nothing.
    /// 2. **Nor does the message.** That last error is printed *even when the Caskroom holds the
    ///    cask*: with `/opt/homebrew/Caskroom/gitpic-fixture-zzz/9.9.9/Fixture.app` created by
    ///    hand, `brew list --cask gitpic-fixture-zzz` still said `No Cask with this name
    ///    exists.` — which is what a removed tap looks like on a machine where the cask is very
    ///    much installed. So the wording is not evidence either.
    /// 3. What *is* evidence is the Caskroom itself, asked for by ``brewCaskroom(brew:)`` and
    ///    then looked at. A token with no directory under `<prefix>/Caskroom` is one this brew
    ///    has installed nothing for, whatever it said and whichever way it exited — and if brew
    ///    cannot even say where its Caskroom is, that is itself the "no answer" case.
    ///
    /// Exit **0** with no identifiable bundle is also `unusable`, and this is not theoretical:
    /// `brew list --cask codex` and `brew list --cask font-maple-mono-nf-cn` both exit 0 here
    /// with zero `.app` lines. Exit 0 means brew *does* have the cask, so "I cannot see which
    /// bundle" is the one thing it cannot mean.
    public static func brewCaskApp(_ cask: String, brew: URL) -> BrewCaskApp {
        let command = "\(brew.path) list --cask \(cask)"
        let out: ProcessOutcome
        do {
            out = try ChildProcess.run(
                executable: brew, args: ["list", "--cask", cask], timeout: 20)
        } catch {
            Diagnostics.log("update: \(command) could not be spawned: \(error)")
            return .unusable(reason: "无法运行 Homebrew，没法确认这份 GitPic 是不是它装的")
        }
        if out.timedOut {
            Diagnostics.log("update: \(command) timed out after 20s")
            return .unusable(reason: "Homebrew 20 秒内没有回答这份 GitPic 是不是它装的")
        }
        guard out.status == 0 else {
            // Confirmed against the filesystem rather than against brew's prose — see the
            // three measurements above.
            let complaint = Self.firstLine(of: out.stderr)
            guard let caskroom = brewCaskroom(brew: brew) else {
                Diagnostics.log("update: \(command) exited \(out.status) (\(complaint)) and"
                                + " `brew --caskroom` gave no answer either")
                return .unusable(reason: "Homebrew 没能说清这份 GitPic 是不是它装的")
            }
            // Homebrew keys the Caskroom by bare token, so a tap-qualified name
            // (`tarnish233/tap/gitpic`) still lands in `Caskroom/gitpic`.
            let entry = caskroom.appendingPathComponent(
                URL(fileURLWithPath: cask).lastPathComponent)
            if !FileManager.default.fileExists(atPath: entry.path) {
                Diagnostics.log("update: \(command) exited \(out.status) (\(complaint)) and"
                                + " \(entry.path) does not exist — brew installed no \(cask)")
                return .notInstalled(status: out.status)
            }
            Diagnostics.log("update: \(command) exited \(out.status) (\(complaint)) but"
                            + " \(entry.path) exists — brew may well own this cask")
            return .unusable(reason: "Homebrew 没能说清这份 GitPic 是不是它装的")
        }

        // One path per line. The `.app`s among them are the artifacts; the rest are the receipt
        // and the cask's own JSON. **All** of them, not the first: a Caskroom holding two
        // version directories lists two `GitPic.app` symlinks, and the older one can be
        // dangling — measured, `resolvingSymlinksInPath()` returns a dangling symlink
        // *unchanged*, so picking it would compare a path that does not exist against the
        // running bundle and conclude "not brew's".
        let lines = String(decoding: out.stdout, as: UTF8.self)
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let listed = lines.filter { $0.hasSuffix(".app") }
        let apps = listed
            .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !apps.isEmpty else {
            // Exit 0 means brew has this cask; there is simply nothing here to compare the
            // running bundle against. That is the definition of "no answer", not of a durable
            // fact — and the log has to say which, because the remedies differ.
            Diagnostics.log("update: \(command) exited 0 but named no existing .app"
                            + " (\(lines.count) line(s), \(listed.count) ending in .app)"
                            + " — brew has \(cask), its bundle is unidentifiable")
            return .unusable(reason: "Homebrew 管着 gitpic，但没有报出它装的是哪一个 GitPic.app")
        }
        return .installedAt(apps)
    }

    /// Where this `brew` keeps its Caskroom, straight from brew.
    ///
    /// `brew --caskroom` with no cask argument needs no tap and resolves no cask definition, so
    /// it answers on a machine where `brew list --cask <token>` cannot — which is exactly when
    /// it is asked. Measured at 46 ms, against `brew list --cask`'s 0.44 s, so this is cheap
    /// enough to be the tiebreaker on the failure path.
    ///
    /// Deliberately *not* derived from `brew`'s own path: `/usr/local/bin/brew` is commonly a
    /// symlink into `/usr/local/Homebrew/bin/brew`, and a prefix guessed from the wrong one of
    /// those would point at a directory that does not exist — which on this code path reads as
    /// "brew installed nothing" and authorises an install. Asking brew cannot be wrong that
    /// way; failing to get an answer is the safe direction.
    static func brewCaskroom(brew: URL) -> URL? {
        let out = try? ChildProcess.run(executable: brew, args: ["--caskroom"], timeout: 20)
        guard let out, out.status == 0, !out.timedOut else { return nil }
        let path = String(decoding: out.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// The first line of a child's stderr, for the log. Homebrew puts every error there —
    /// measured: `brew list --cask firefox 2>/dev/null` prints nothing at all on stdout.
    private static func firstLine(of stderr: Data) -> String {
        let text = String(decoding: stderr, as: UTF8.self)
        return text.split(whereSeparator: \.isNewline).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? "no stderr"
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
    /// `conclusive: true, path: nil` → `.absent` → "not Homebrew's" → an install over whatever
    /// is in `/Applications`, and they are reachable *exactly* for the custom-`HOMEBREW_PREFIX`
    /// users this probe exists to serve, since the two hardcoded paths are checked first.
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
    ///   alias), which ``commandVPath(in:tool:)`` rightly refuses to spawn — but it is *not*
    ///   absence, and calling it absence is an install over a bundle brew may well own.
    ///
    /// The closing mark is what keeps a late-flushing profile job out of that second case:
    /// measured, `[gpg-agent] ready` arriving after the lookup lands *after* ``probeClose`` and
    /// so cannot turn "no brew" into "cannot tell". A job that flushes in the microseconds
    /// between the two marks still can, and that is the safe direction — the release page.
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
