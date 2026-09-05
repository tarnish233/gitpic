import Darwin
import Foundation
import Testing
@testable import GitPicCore

@Suite("Command-line tool")
struct CommandLineToolTests {
    @Test("the five link states stay distinct")
    func statuses() throws {
        let fixture = try CommandLineFixture()
        defer { fixture.remove() }

        #expect(CommandLineTool.status(of: fixture.link, expecting: fixture.executable)
                == .notInstalled)

        try FileManager.default.createSymbolicLink(
            at: fixture.link, withDestinationURL: fixture.executable)
        #expect(CommandLineTool.status(of: fixture.link, expecting: fixture.executable)
                == .linked)

        try FileManager.default.removeItem(at: fixture.link)
        let missing = fixture.root.appendingPathComponent("missing/gitpic")
        try FileManager.default.createSymbolicLink(at: fixture.link, withDestinationURL: missing)
        #expect(CommandLineTool.status(of: fixture.link, expecting: fixture.executable)
                == .dangling(destination: missing))

        try FileManager.default.removeItem(at: fixture.link)
        let other = try fixture.makeExecutable(named: "other-gitpic")
        try FileManager.default.createSymbolicLink(at: fixture.link, withDestinationURL: other)
        #expect(CommandLineTool.status(of: fixture.link, expecting: fixture.executable)
                == .pointsElsewhere(destination: other))

        try FileManager.default.removeItem(at: fixture.link)
        try Data("not a link".utf8).write(to: fixture.link)
        #expect(CommandLineTool.status(of: fixture.link, expecting: fixture.executable)
                == .occupied)
    }

    @Test("the four PATH results are interpreted from the unresolved entry, and name their shell")
    func reachability() {
        let link = URL(fileURLWithPath: "/Users/example/.local/bin/gitpic")
        let zsh = URL(fileURLWithPath: "/bin/zsh")
        #expect(CommandLineTool.reach(
            of: link,
            probe: .init(path: link, conclusive: true, reason: nil, shell: zsh))
                == .reachable(shell: zsh))

        let winner = URL(fileURLWithPath: "/opt/example/bin/gitpic")
        #expect(CommandLineTool.reach(
            of: link,
            probe: .init(path: winner, conclusive: true, reason: nil, shell: zsh))
                == .shadowed(by: winner, shell: zsh))

        #expect(CommandLineTool.reach(
            of: link,
            probe: .init(path: nil, conclusive: true, reason: nil, shell: zsh))
                == .notOnPath(shell: zsh))

        #expect(CommandLineTool.reach(
            of: link,
            probe: .init(path: nil, conclusive: false, reason: "profile stopped", shell: zsh))
                == .unknown(reason: "profile stopped"))

        // Every verdict about a shell says which one, so a reader cannot take "reachable" for a
        // statement about the shell they happen to be typing into.
        for reach: CommandLineTool.Reach in [
            .reachable(shell: zsh), .shadowed(by: winner, shell: zsh), .notOnPath(shell: zsh),
        ] {
            #expect(reach.shell == zsh)
            #expect(reach.label.contains("zsh") || reach.detail.contains("zsh"),
                    "\(reach) names no shell")
        }
        #expect(CommandLineTool.Reach.unknown(reason: "x").shell == nil)
    }

    /// **A probe that cannot name its shell cannot deliver a verdict about one.** Reach used to be
    /// derived from `path` and `conclusive` alone, so a probe with no shell still produced a
    /// confident `reachable` — attributing an answer to nothing in particular, which is the whole
    /// habit this change exists to break.
    @Test("a probe with no shell is unknown however much else it found")
    func reachWithoutAShellIsUnknown() {
        let link = URL(fileURLWithPath: "/Users/example/.local/bin/gitpic")
        for probe: ToolDiscovery.ShellProbe in [
            .init(path: link, conclusive: true, reason: nil, shell: nil),
            .init(path: nil, conclusive: true, reason: nil, shell: nil),
        ] {
            guard case .unknown = CommandLineTool.reach(of: link, probe: probe) else {
                Issue.record("a shell-less probe produced a verdict about a shell")
                continue
            }
        }
    }

    /// The gap this release closes: PATH is per-shell, and the app measures one shell.
    ///
    /// Measured on the author's machine — `$SHELL` is `/bin/zsh`, `~/.zshrc:126` exports
    /// `~/.local/bin`, so the pane said "reachable"; the fish used for actual work had never heard
    /// of the directory and `gitpic` was `Unknown command` there. The shell that was measured is
    /// left out because its verdict is already on screen.
    @Test("shells that look in use, other than the measured one, get their own PATH line")
    func otherShellsNeedingPath() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitpic-shells-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".config/fish"), withIntermediateDirectories: true)
        try Data().write(to: home.appendingPathComponent(".zshrc"))

        let measuredZsh = CommandLineTool.otherShellsNeedingPath(
            measured: URL(fileURLWithPath: "/bin/zsh"), home: home)
        #expect(measuredZsh.map(\.shell) == [.fish],
                "fish is present and was not measured; zsh was measured and bash is absent")
        #expect(measuredZsh.first?.setUp.lines == ["fish_add_path ~/.local/bin"])

        // Measure fish instead and the pairing flips, which is what proves `measured` is doing
        // the work rather than fish simply always being listed.
        let measuredFish = CommandLineTool.otherShellsNeedingPath(
            measured: URL(fileURLWithPath: "/opt/homebrew/bin/fish"), home: home)
        #expect(measuredFish.map(\.shell) == [.zsh])

        // A shell the app does not install completions for is not spoken about at all, rather
        // than being treated as "nothing was measured" and listing everything.
        let measuredNu = CommandLineTool.otherShellsNeedingPath(
            measured: URL(fileURLWithPath: "/opt/homebrew/bin/nu"), home: home)
        #expect(measuredNu.map(\.shell) == [.zsh, .fish])

        // An empty home has no shell to talk about, so nothing is offered.
        let bare = home.appendingPathComponent("bare")
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        #expect(CommandLineTool.otherShellsNeedingPath(measured: nil, home: bare).isEmpty)
    }

    /// Every shell has a PATH line, they differ, and none of them is a file the app would write.
    @Test("each shell's PATH setup is present, distinct, and never written by the app")
    func pathSetUpPerShell() {
        let all = CommandLineTool.Shell.allCases.map(\.pathSetUp)
        #expect(all.allSatisfy { !$0.lines.isEmpty && !$0.why.isEmpty && !$0.file.isEmpty })
        #expect(Set(all.flatMap(\.lines)).count == Set(all.map(\.lines)).count,
                "two shells share a PATH line, which would make the copy button ambiguous")
        // fish configures PATH with a command rather than a file edit, so it must not be
        // described as a line to paste into something.
        #expect(CommandLineTool.Shell.fish.pathSetUp.lines == ["fish_add_path ~/.local/bin"])
        #expect(CommandLineTool.Shell.zsh.pathSetUp.file == "~/.zshrc")
    }

    @Test("install creates missing directories and the expected link")
    func install() throws {
        let fixture = try CommandLineFixture(createLinkDirectory: false)
        defer { fixture.remove() }

        try CommandLineTool.install(at: fixture.link, pointingTo: fixture.executable)

        #expect(CommandLineTool.status(of: fixture.link, expecting: fixture.executable) == .linked)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.link.path)
                == fixture.executable.path)
    }

    @Test("install refuses a real file unless replacement was explicit")
    func occupiedNeedsConfirmation() throws {
        let fixture = try CommandLineFixture()
        defer { fixture.remove() }
        try Data("mine".utf8).write(to: fixture.link)

        do {
            try CommandLineTool.install(at: fixture.link, pointingTo: fixture.executable)
            Issue.record("install should have refused the occupied path")
        } catch CommandLineTool.Failure.occupied(let path) {
            #expect(path == fixture.link.path)
        } catch {
            Issue.record("wrong error: \(error)")
        }

        try CommandLineTool.install(
            at: fixture.link, pointingTo: fixture.executable, replacing: true)
        #expect(CommandLineTool.status(of: fixture.link, expecting: fixture.executable) == .linked)
    }

    @Test("install refuses to repoint another link unless replacement was explicit")
    func otherLinkNeedsConfirmation() throws {
        let fixture = try CommandLineFixture()
        defer { fixture.remove() }
        let other = try fixture.makeExecutable(named: "other-gitpic")
        try FileManager.default.createSymbolicLink(at: fixture.link, withDestinationURL: other)

        do {
            try CommandLineTool.install(at: fixture.link, pointingTo: fixture.executable)
            Issue.record("install should have refused another link")
        } catch CommandLineTool.Failure.pointsElsewhere(let path, let destination) {
            #expect(path == fixture.link.path)
            #expect(destination == other.path)
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test("replacement keeps the old command present until the atomic rename")
    func replacementIsAtomic() throws {
        let fixture = try CommandLineFixture()
        defer { fixture.remove() }
        let old = try fixture.makeExecutable(named: "old-gitpic")
        try FileManager.default.createSymbolicLink(at: fixture.link, withDestinationURL: old)
        var sawOldAtRename = false

        try CommandLineTool.install(
            at: fixture.link,
            pointingTo: fixture.executable,
            replacing: true
        ) { temporary, destination in
            let oldDestination = try FileManager.default.destinationOfSymbolicLink(
                atPath: destination.path)
            sawOldAtRename = FileManager.default.fileExists(atPath: destination.path)
                && oldDestination == old.path
            try atomicRename(temporary, destination)
        }

        #expect(sawOldAtRename)
        #expect(CommandLineTool.status(of: fixture.link, expecting: fixture.executable) == .linked)
    }

    @Test("completion paths are the conventional per-user locations")
    func completionPaths() {
        let home = URL(fileURLWithPath: "/Users/example")
        #expect(CommandLineTool.Shell.bash.completionURL(home: home).path
                == "/Users/example/.local/share/bash-completion/completions/gitpic")
        #expect(CommandLineTool.Shell.zsh.completionURL(home: home).path
                == "/Users/example/.zfunc/_gitpic")
        #expect(CommandLineTool.Shell.fish.completionURL(home: home).path
                == "/Users/example/.config/fish/completions/gitpic.fish")
    }

    @Test("the app-owned shells are a deliberate wire contract with gitpic completion")
    func shells() {
        #expect(CommandLineTool.Shell.allCases.map(\.rawValue) == ["bash", "zsh", "fish"])
    }

    @Test("removal preserves a completion the user changed")
    func removalPreservesEditedCompletion() throws {
        let fixture = try CommandLineFixture()
        defer { fixture.remove() }
        try CommandLineTool.install(at: fixture.link, pointingTo: fixture.executable)

        let generated = Dictionary(uniqueKeysWithValues: CommandLineTool.Shell.allCases.map {
            ($0, Data("completion for \($0.rawValue)\n".utf8))
        })
        for shell in CommandLineTool.Shell.allCases {
            try CommandLineTool.writeCompletion(try #require(generated[shell]),
                                                for: shell, home: fixture.home)
        }
        let edited = CommandLineTool.Shell.zsh.completionURL(home: fixture.home)
        try Data("user edit\n".utf8).write(to: edited)

        let result = try CommandLineTool.remove(
            at: fixture.link,
            expecting: fixture.executable,
            completions: generated,
            home: fixture.home)

        #expect(result.linkRemoved)
        #expect(result.completions[CommandLineTool.Shell.bash] == CommandLineTool.CompletionRemoval.removed)
        #expect(result.completions[CommandLineTool.Shell.fish] == CommandLineTool.CompletionRemoval.removed)
        #expect(result.completions[CommandLineTool.Shell.zsh] == CommandLineTool.CompletionRemoval.preserved)
        #expect(FileManager.default.fileExists(atPath: edited.path))
    }

    @Test("status and PATH prose are nonempty and distinguish every state")
    func prose() {
        let destination = URL(fileURLWithPath: "/tmp/other/gitpic")
        let shell = URL(fileURLWithPath: "/bin/zsh")
        let statuses: [CommandLineTool.Status] = [
            .notInstalled, .linked, .dangling(destination: destination),
            .pointsElsewhere(destination: destination), .occupied,
        ]
        let reaches: [CommandLineTool.Reach] = [
            .reachable(shell: shell), .shadowed(by: destination, shell: shell),
            .notOnPath(shell: shell), .unknown(reason: "cannot ask shell"),
        ]

        #expect(statuses.allSatisfy { $0.label.isEmpty == false && $0.detail.isEmpty == false })
        #expect(Set(statuses.map(\.label)).count == statuses.count)
        #expect(reaches.allSatisfy { $0.label.isEmpty == false && $0.detail.isEmpty == false })
        #expect(Set(reaches.map(\.label)).count == reaches.count)
    }

    /// **The "nothing writes a shell rc file" guarantee is gone, deliberately, and this is what
    /// replaced it.**
    ///
    /// That scan asserted an absence, and the absence was the whole policy: print the lines, let
    /// the user paste them. It also went too broad twice in the same way — first banning the
    /// *subject*, so it failed when `loginShellProbe` documented why it needs `-i`; then, with
    /// comments skipped, blocking `pathSetUp` from naming the file a bash user must edit. Now the
    /// app writes `.zshrc` on purpose, and the old scan **still passed**, because `configure`
    /// writes through a `URL` variable rather than a literal. A tripwire whose name promises
    /// something the code no longer does, and which passes anyway, is worse than no tripwire: it
    /// is a false assurance in the exact place someone would look for the real one.
    ///
    /// What protects the user now is `ManagedBlock`'s behaviour — every byte outside the markers
    /// preserved, writing idempotent, removal exact, the pre-GitPic file backed up — asserted
    /// directly, on real files, in `ManagedBlockTests` and `ShellConfigurationTests`. This scan
    /// holds the one thing those cannot: that the *subject* stays confined to one file.
    /// Startup-file handling anywhere else would be a second implementation of the same delicate
    /// edit, reviewed by nobody, and that is the regression worth catching.
    @Test("shell startup files are handled in exactly one source file")
    func startupFileHandlingIsConfined() throws {
        let rcFiles = [".zshrc", ".zprofile", ".zshenv", ".bash_profile", ".bashrc", "config.fish"]
        var offenders: [String] = []
        var namedInOwner = 0

        for source in try appSources() {
            let text = try String(contentsOf: source, encoding: .utf8)
            for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") {
                    continue
                }
                guard rcFiles.contains(where: { line.contains($0) }) else { continue }
                if source.lastPathComponent == "CommandLineTool.swift" {
                    namedInOwner += 1
                } else {
                    offenders.append("\(source.lastPathComponent):\(offset + 1)  \(trimmed)")
                }
            }
        }

        #expect(offenders.isEmpty, """
            shell startup files are named outside CommandLineTool.swift. Editing one is delicate \
            enough that it lives in a single reviewed place, behind ManagedBlock:
            \(offenders.joined(separator: "\n"))
            """)
        #expect(namedInOwner > 0, "the owner names none — startup-file support has vanished")

        // And the guidance the UI shows still exists. "Never writes an rc file" had a silent way to
        // pass, and so does "handles them in one place": stop handling them at all.
        #expect(CommandLineTool.Shell.zsh.startupFile == ".zshrc")
        #expect(CommandLineTool.Shell.bash.startupFile == ".bash_profile")
        #expect(CommandLineTool.Shell.fish.startupFile == nil)
    }

    private func atomicRename(_ source: URL, _ destination: URL) throws {
        let result = source.path.withCString { old in
            destination.path.withCString { new in Darwin.rename(old, new) }
        }
        guard result == 0 else {
            throw POSIXError(try #require(POSIXErrorCode(rawValue: errno)))
        }
    }

    private func appSources() throws -> [URL] {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        let directory = root.appendingPathComponent("Sources")
        let walker = try #require(
            FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }
}

private struct CommandLineFixture {
    let root: URL
    let home: URL
    let executable: URL
    let link: URL

    init(createLinkDirectory: Bool = true) throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gitpic-command-line-tests-\(UUID().uuidString)")
        home = root.appendingPathComponent("home")
        executable = root.appendingPathComponent("GitPic.app/Contents/Resources/gitpic")
        link = home.appendingPathComponent(".local/bin/gitpic")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path)
        if createLinkDirectory {
            try FileManager.default.createDirectory(
                at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
    }

    func makeExecutable(named name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

/// The delimited region GitPic writes into a shell startup file.
///
/// These are the tests that let the app touch `.zshrc` at all. The policy it replaced — print the
/// lines, never write them — needed no proof beyond "no writer exists"; this one needs proof that
/// everything outside the markers survives, that writing is idempotent, and that removal is exact.
@Suite("Managed shell block")
struct ManagedBlockTests {
    private let lines = ["export PATH=\"$HOME/.local/bin:$PATH\"", "fpath=(~/.zfunc $fpath)"]

    private func block(_ body: [String]) -> String {
        ([CommandLineTool.ManagedBlock.begin] + body + [CommandLineTool.ManagedBlock.end])
            .joined(separator: "\n")
    }

    @Test("appending to a file keeps every byte of it, newline or no newline")
    func appendPreservesTheFile() {
        for original in ["", "alias ll='ls -l'\n", "alias ll='ls -l'", "a\nb\n\n", "\n"] {
            let written = CommandLineTool.ManagedBlock.applying(lines, to: original)
            #expect(written.hasPrefix(original) || original.trimmed.isEmpty,
                    "original text was altered: \(original.debugDescription) -> \(written.debugDescription)")
            #expect(written.contains(block(lines)), "the block is not present verbatim")
            #expect(CommandLineTool.ManagedBlock.present(in: written))
        }
    }

    /// The property the whole design rests on: uninstall puts the file back.
    @Test("write then remove is a byte-exact round trip")
    func roundTrip() {
        for original in [
            "",
            "alias ll='ls -l'\n",
            "alias ll='ls -l'",            // no trailing newline, as some editors save
            "a\nb\n\n",                    // trailing blank lines
            "# comment only\n",
            "eval \"$(brew shellenv)\"\nsource $ZSH/oh-my-zsh.sh\n",
        ] {
            let written = CommandLineTool.ManagedBlock.applying(lines, to: original)
            let restored = CommandLineTool.ManagedBlock.removing(from: written)
            #expect(restored == original,
                    "round trip changed the file: \(original.debugDescription) -> \(restored.debugDescription)")
        }
    }

    @Test("writing twice replaces the block instead of stacking a second one")
    func idempotent() {
        let once = CommandLineTool.ManagedBlock.applying(lines, to: "setopt AUTO_CD\n")
        let twice = CommandLineTool.ManagedBlock.applying(lines, to: once)
        #expect(once == twice)

        // And a changed body replaces rather than appends, so an upgrade cannot leave two blocks.
        let changed = CommandLineTool.ManagedBlock.applying(["export FOO=1"], to: once)
        #expect(changed.components(separatedBy: CommandLineTool.ManagedBlock.begin).count == 2,
                "a second begin marker appeared")
        #expect(changed.contains("export FOO=1"))
        #expect(!changed.contains("fpath=(~/.zfunc $fpath)"))
        #expect(CommandLineTool.ManagedBlock.removing(from: changed) == "setopt AUTO_CD\n")
    }

    /// Content the user added *after* the block is the case a naive "truncate from the marker"
    /// implementation destroys, and it is the likeliest real shape: the block goes in, and the
    /// person keeps editing their file afterwards.
    @Test("content after the block survives a rewrite and a removal")
    func contentAfterTheBlock() {
        let original = "before\n"
        let written = CommandLineTool.ManagedBlock.applying(lines, to: original)
        let edited = written + "\nafter=1\n"

        let rewritten = CommandLineTool.ManagedBlock.applying(["export NEW=1"], to: edited)
        #expect(rewritten.contains("before"))
        #expect(rewritten.contains("after=1"), "the user's later edit was lost")
        #expect(rewritten.contains("export NEW=1"))

        let removed = CommandLineTool.ManagedBlock.removing(from: rewritten)
        #expect(removed == "before\n\nafter=1\n", "\(removed.debugDescription)")
    }

    /// The markers are the entire mechanism, so a line that merely mentions one is not one.
    @Test("a marker inside a longer line is not a marker")
    func markersAreWholeLines() {
        let decoy = "echo \"\(CommandLineTool.ManagedBlock.begin)\" >> log\n"
        #expect(!CommandLineTool.ManagedBlock.present(in: decoy))
        #expect(CommandLineTool.ManagedBlock.removing(from: decoy) == decoy)

        // Indentation is not a difference: a marker the user re-indented is still ours to replace.
        let indented = "  \(CommandLineTool.ManagedBlock.begin)\n  x\n  \(CommandLineTool.ManagedBlock.end)\n"
        #expect(CommandLineTool.ManagedBlock.present(in: indented))
    }

    @Test("removing from a file that has no block changes nothing")
    func removingNothing() {
        for original in ["", "alias ll='ls -l'\n", "no block here"] {
            #expect(CommandLineTool.ManagedBlock.removing(from: original) == original)
        }
    }

    /// A `begin` with no `end` is not a block. Treating it as one would let a half-written file
    /// swallow everything below it on the next write.
    @Test("an unterminated begin marker is not treated as a block")
    func unterminatedBlock() {
        let broken = "\(CommandLineTool.ManagedBlock.begin)\nexport X=1\nkeep=me\n"
        #expect(!CommandLineTool.ManagedBlock.present(in: broken))
        #expect(CommandLineTool.ManagedBlock.removing(from: broken) == broken)
        // The next write appends a proper block and leaves the damaged lines visible rather than
        // absorbing them.
        let written = CommandLineTool.ManagedBlock.applying(lines, to: broken)
        #expect(written.contains("keep=me"))
    }
}

/// Writing the block into a real file, and taking it back out.
@Suite("Shell startup configuration")
struct ShellConfigurationTests {
    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitpic-cfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    @Test("configuring writes the block, backs the original up, and is idempotent")
    func configureZsh() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let rc = home.appendingPathComponent(".zshrc")
        let original = "source $ZSH/oh-my-zsh.sh\n"
        try Data(original.utf8).write(to: rc)

        let first = try CommandLineTool.configure(.zsh, needsPath: true, home: home)
        #expect(first == .wrote(file: ".zshrc", lines:
            CommandLineTool.Shell.zsh.managedLines(needsPath: true)))
        #expect(CommandLineTool.isConfigured(.zsh, home: home))

        let written = try String(contentsOf: rc, encoding: .utf8)
        #expect(written.hasPrefix(original), "the user's own line was disturbed")
        #expect(written.contains("compdef _gitpic gitpic"))

        // The backup is the file from *before* GitPic, which is the only version worth keeping.
        let backup = rc.appendingPathExtension("gitpic.bak")
        #expect(try String(contentsOf: backup, encoding: .utf8) == original)

        // Second run changes nothing at all, including the backup.
        #expect(try CommandLineTool.configure(.zsh, needsPath: true, home: home)
                == .unchanged(file: ".zshrc"))
        #expect(try String(contentsOf: rc, encoding: .utf8) == written)
        #expect(try String(contentsOf: backup, encoding: .utf8) == original)
    }

    /// The backup must not be overwritten by a later write, or it stops meaning "before GitPic".
    @Test("a rewrite keeps the original backup rather than snapshotting our own block")
    func backupSurvivesARewrite() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let rc = home.appendingPathComponent(".zshrc")
        let original = "setopt AUTO_CD\n"
        try Data(original.utf8).write(to: rc)

        try CommandLineTool.configure(.zsh, needsPath: true, home: home)
        try CommandLineTool.configure(.zsh, needsPath: false, home: home)   // different body

        let backup = rc.appendingPathExtension("gitpic.bak")
        #expect(try String(contentsOf: backup, encoding: .utf8) == original,
                "the backup now contains a version that already had our block in it")
        let text = try String(contentsOf: rc, encoding: .utf8)
        #expect(text.components(separatedBy: CommandLineTool.ManagedBlock.begin).count == 2,
                "a second block appeared")
        #expect(!text.contains("export PATH"), "needsPath: false still wrote the PATH line")
    }

    @Test("unconfiguring restores the file exactly and leaves the backup in place")
    func unconfigure() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let rc = home.appendingPathComponent(".zshrc")
        let original = "alias g=git\n\nexport EDITOR=nvim\n"
        try Data(original.utf8).write(to: rc)

        try CommandLineTool.configure(.zsh, needsPath: true, home: home)
        #expect(try CommandLineTool.unconfigure(.zsh, home: home))
        #expect(try String(contentsOf: rc, encoding: .utf8) == original,
                "removal did not restore the file byte for byte")
        #expect(!CommandLineTool.isConfigured(.zsh, home: home))

        // The backup is deliberately kept: a removal is exactly when someone may want it.
        #expect(FileManager.default.fileExists(
            atPath: rc.appendingPathExtension("gitpic.bak").path))

        // Removing again is a no-op that reports it did nothing.
        #expect(try CommandLineTool.unconfigure(.zsh, home: home) == false)
    }

    @Test("configuring a shell with no startup file is refused rather than guessed at")
    func fishHasNoBlock() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(CommandLineTool.Shell.fish.startupFile == nil)
        #expect(throws: CommandLineTool.Failure.notFileConfigured(shell: .fish)) {
            try CommandLineTool.configure(.fish, needsPath: true, home: home)
        }
    }

    /// `needsPath` exists so a shell that already exports the directory does not get a duplicate.
    @Test("an existing mention outside our block counts, one inside it does not")
    func pathAlreadyConfigured() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let rc = home.appendingPathComponent(".zshrc")

        try Data("setopt AUTO_CD\n".utf8).write(to: rc)
        #expect(!CommandLineTool.pathAlreadyConfigured(.zsh, home: home))

        try Data("export PATH=\"$HOME/.local/bin:$PATH\"\n".utf8).write(to: rc)
        #expect(CommandLineTool.pathAlreadyConfigured(.zsh, home: home))

        // A mention *inside* our own block is our work, not the user's. Counting it would make the
        // next rewrite decide the line is redundant and drop it, undoing PATH on the third run.
        try Data("setopt AUTO_CD\n".utf8).write(to: rc)
        try CommandLineTool.configure(.zsh, needsPath: true, home: home)
        #expect(!CommandLineTool.pathAlreadyConfigured(.zsh, home: home),
                "our own block was mistaken for the user's configuration")

        // Any file the shell reads counts, not just the one the block goes in.
        try Data("setopt AUTO_CD\n".utf8).write(to: rc)
        try Data("path+=(~/.local/bin)\n".utf8)
            .write(to: home.appendingPathComponent(".zprofile"))
        #expect(CommandLineTool.pathAlreadyConfigured(.zsh, home: home))
    }

    /// fish is configured by a command, so the test asserts which command — no fish needed.
    @Test("fish is configured with fish_add_path, and the probe asks with contains")
    func fishUsesItsOwnApi() throws {
        var calls: [[String]] = []
        let fish = URL(fileURLWithPath: "/opt/homebrew/bin/fish")
        let dir = URL(fileURLWithPath: "/Users/example/.local/bin")

        let result = try CommandLineTool.configureFish(fish: fish, directory: dir) { _, args in
            calls.append(args); return 0
        }
        #expect(result == .ranCommand("fish_add_path /Users/example/.local/bin"))
        #expect(calls == [["-c", "fish_add_path /Users/example/.local/bin"]])

        // Captured rather than asserted inside the closure: an `#expect` nested in an argument to
        // `#expect` expands recursively and does not compile.
        var probeArgs: [[String]] = []
        let configured = CommandLineTool.fishPathConfigured(fish: fish, directory: dir) { _, args in
            probeArgs.append(args)
            return 0
        }
        #expect(configured)
        #expect(probeArgs == [["-c", "contains /Users/example/.local/bin $fish_user_paths"]])
        #expect(!CommandLineTool.fishPathConfigured(fish: fish, directory: dir) { _, _ in 1 })
        // A fish that cannot be run at all is "not configured", never a crash.
        #expect(!CommandLineTool.fishPathConfigured(fish: fish, directory: dir) { _, _ in
            throw CommandLineTool.Failure.notOwned(path: "x")
        })

        // A non-zero exit from the write is an error, not a silent success.
        #expect(throws: (any Error).self) {
            try CommandLineTool.configureFish(fish: fish, directory: dir) { _, _ in 7 }
        }
    }
}
