import Testing
import Foundation
@testable import GitPicCore

/// Tests for the login-shell probe's parsing decision.
///
/// Separate from the "Tool discovery" suite in `EnvelopeTests.swift`, which covers
/// `childPATH` and the spawn timeout.
///
/// `sh` stands in for the tool being located, because `/bin/sh` exists and is
/// executable on every macOS: the `isExecutableFile` half of the check is really
/// being exercised, not passing for want of a file to reject.
@Suite("Login-shell tool discovery")
struct LoginShellLookupTests {

    @Test("a path buried under profile chatter is still found")
    func noisyProfileStillYieldsThePath() {
        // The shape measured from a login shell whose `.zprofile` echoes:
        // `command -v` speaks last, after the profile has finished.
        let noisy = "Using node v20.11.0\nnvm: default -> lts/iron\n/bin/sh\n"

        // What the old implementation handed to `isExecutableFile`: the whole
        // blob, trimmed, as one filename. This is the false negative — the app
        // said "gh not installed" while the answer was on stdout.
        #expect(!FileManager.default.isExecutableFile(
            atPath: noisy.trimmingCharacters(in: .whitespacesAndNewlines)))

        #expect(ToolDiscovery.commandVPath(in: noisy, tool: "sh")?.path == "/bin/sh")
    }

    @Test("clean output — the common case — is unaffected")
    func cleanOutput() {
        #expect(ToolDiscovery.commandVPath(in: "/bin/sh\n", tool: "sh")?.path == "/bin/sh")
        #expect(ToolDiscovery.commandVPath(in: "/bin/sh", tool: "sh")?.path == "/bin/sh")
        #expect(ToolDiscovery.commandVPath(in: "  /bin/sh  \r\n", tool: "sh")?.path == "/bin/sh")
    }

    @Test("noise arriving after the answer does not hide it")
    func trailingNoise() {
        // A profile-spawned job can flush after `command -v` has answered, so
        // taking the last non-empty line positionally is not enough.
        let out = "conda: activating base\n/bin/sh\n[gpg-agent] ready\n"
        #expect(ToolDiscovery.commandVPath(in: out, tool: "sh")?.path == "/bin/sh")
    }

    @Test("a noise line naming a different executable is never returned as the tool")
    func wrongToolIsRejected() {
        // `/bin/ls` is real and executable; it is simply not what was asked
        // for. Accepting any executable-looking line would hand the caller a
        // binary it then spawns as `sh`.
        #expect(ToolDiscovery.commandVPath(in: "see /bin/ls for details\n/bin/ls\n",
                                          tool: "sh") == nil)
        // With both present the named one wins, whatever the order.
        #expect(ToolDiscovery.commandVPath(in: "/bin/ls\n/bin/sh\n", tool: "sh")?.path == "/bin/sh")
        #expect(ToolDiscovery.commandVPath(in: "/bin/sh\n/bin/ls\n", tool: "sh")?.path == "/bin/sh")
    }

    @Test("what `command -v` prints for a function or an alias is not a path")
    func functionsAndAliasesAreRejected() {
        // Measured: zsh prints the bare name for a function and
        // `alias x='…'` for an alias. Neither can be spawned as a child.
        #expect(ToolDiscovery.commandVPath(in: "sh\n", tool: "sh") == nil)
        #expect(ToolDiscovery.commandVPath(in: "alias sh='sh -x'\n", tool: "sh") == nil)
    }

    @Test("a relative candidate is refused rather than resolved against the cwd")
    func relativePathsAreRejected() {
        // A Finder-launched `.app` has cwd `/`, so `bin/sh` would silently
        // become `/bin/sh` — a right answer arrived at by accident, and a wrong
        // one anywhere else.
        #expect(ToolDiscovery.commandVPath(in: "bin/sh\n", tool: "sh") == nil)
        #expect(ToolDiscovery.commandVPath(in: "./sh\n", tool: "sh") == nil)
    }

    @Test("noise alone, or nothing at all, yields nil")
    func noAnswer() {
        #expect(ToolDiscovery.commandVPath(in: "", tool: "sh") == nil)
        #expect(ToolDiscovery.commandVPath(in: "\n  \n\n", tool: "sh") == nil)
        // What a missing tool looks like: `command -v` prints nothing, the
        // profile's chatter is all that is left.
        #expect(ToolDiscovery.commandVPath(in: "Using node v20.11.0\n", tool: "sh") == nil)
        // A plausible path that does not exist is not evidence of anything.
        #expect(ToolDiscovery.commandVPath(in: "/nix/store/does-not-exist/bin/sh\n",
                                          tool: "sh") == nil)
    }

    @Test("non-UTF8 profile noise cannot discard a clean answer line")
    func nonUTF8NoiseIsSurvivable() {
        // A latin-1 motd: `café welcome` in ISO-8859-1, then the answer.
        var bytes = Data("caf".utf8)
        bytes.append(0xE9)
        bytes.append(contentsOf: Data(" welcome\n/bin/sh\n".utf8))

        // The strict decode the old code used fails on the whole blob, which is
        // a second route to the same false negative.
        #expect(String(data: bytes, encoding: .utf8) == nil)

        let text = String(decoding: bytes, as: UTF8.self)
        #expect(ToolDiscovery.commandVPath(in: text, tool: "sh")?.path == "/bin/sh")
    }

    @Test("the real probe finds `sh` through the user's login shell")
    func liveProbe() {
        // End-to-end over `$SHELL -l -c`, so the argument list and the `-l` that
        // the whole design rests on stay covered. `sh` is on the PATH of every
        // macOS login shell; a failure here means this developer's profile
        // breaks the probe itself, not that the parser regressed.
        let live = ToolDiscovery.loginShellLookup("sh")
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        #expect(live?.lastPathComponent == "sh",
                "probe returned \(String(describing: live?.path)); check what \(shell) -l prints on stdout")
    }

    @Test("a tool that exists nowhere is not conjured out of real profile noise")
    func liveProbeRejectsNoise() {
        // Runs against whatever this machine's profile actually prints, so it
        // guards the other direction: scanning several lines must not turn that
        // output into a false positive.
        let absent = "gitpic-absent-\(UUID().uuidString)"
        #expect(ToolDiscovery.loginShellLookup(absent) == nil)
    }

    /// **The probe has to reach `.zshrc`, and with `-l` alone it did not.**
    ///
    /// zsh reads `.zshrc` for *interactive* shells only, so a login-but-not-interactive
    /// `zsh -l -c` sources `.zshenv`, `.zprofile` and `.zlogin` and skips `.zshrc` entirely. That
    /// went unnoticed while the only tool asked about was `gh`, whose `/opt/homebrew/bin` comes
    /// from `brew shellenv` in `.zprofile` — a file login shells do read. `~/.local/bin`, where
    /// the app's own *install the command-line tool* button puts its link, is the first path this
    /// probe has been asked about that people commonly export from `.zshrc`, and the pane was
    /// reporting "not on PATH" to someone whose terminal resolves the command perfectly well.
    ///
    /// Hermetic, and deliberately not via `setenv`: the environment is handed to the child alone,
    /// so this test does not perturb the others running beside it. `ZDOTDIR` redirects every one
    /// of zsh's per-user startup files, so writing only a `.zshrc` under it makes "which files
    /// did the shell read" the single variable.
    @Test("the probe reads .zshrc, which only an interactive shell does")
    func probeReachesZshrc() throws {
        let shell = "/bin/zsh"
        try #require(FileManager.default.isExecutableFile(atPath: shell),
                     "this test is about zsh's own startup-file rules")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitpic-zdotdir-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // A tool that exists *only* on the PATH that `.zshrc` adds, so finding it is proof the
        // file was read rather than proof the tool is common.
        let tool = "gitpic-zshrc-\(UUID().uuidString.prefix(8))"
        let executable = bin.appendingPathComponent(tool)
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path)

        // `.zshrc` only. No `.zprofile`, so a non-interactive login shell has nowhere else to
        // learn this directory from.
        try Data("export PATH=\"\(bin.path):$PATH\"\n".utf8)
            .write(to: root.appendingPathComponent(".zshrc"))

        let probe = ToolDiscovery.loginShellProbe(tool, environment: [
            "ZDOTDIR": root.path,
            "HOME": root.path,
            "PATH": "/usr/bin:/bin",
            "SHELL": shell,
        ])
        #expect(probe.path?.lastPathComponent == tool,
                """
                the probe missed a tool that only `.zshrc` puts on PATH — \
                `-i` has probably been dropped from its argument list. \
                reason: \(probe.reason ?? "none"), conclusive: \(probe.conclusive)
                """)
    }
}
