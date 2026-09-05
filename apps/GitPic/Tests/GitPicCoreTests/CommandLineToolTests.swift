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

    /// **The rule is that nothing writes a shell rc file — not that nothing may name one.**
    ///
    /// This scan has now been too broad twice, in the same way each time, and the second time is
    /// what fixed the shape. First it banned the *subject*, so it failed the moment
    /// `ToolDiscovery.loginShellProbe` documented why it needs `-i` — a statement about which
    /// startup files zsh reads, unmakeable without naming `.zshrc`. Comment lines were skipped and
    /// it failed again as soon as `pathSetUp` had to tell a bash user which file to edit and
    /// `looksInUse` had to check whether those files exist. Both of those are the app doing its
    /// job, and neither writes anything.
    ///
    /// So the assertion is now about the hazard rather than the vocabulary: a line may name an rc
    /// file, and may not name one *while calling something that writes*. A tripwire that catches
    /// legitimate code gets reworded around rather than obeyed, and each rewording left the code
    /// less able to explain itself than the version before.
    ///
    /// What no string scan can catch is a path assembled from pieces, or a write two lines below
    /// the name. That is why the real guarantee is structural — `SetUp` is a value carrying text,
    /// and no writer for one exists in either target — and this stays the weaker half. The
    /// positive assertions at the end are the other half of the job: the guidance has to remain
    /// *present*, since a silent way to satisfy "never writes an rc file" is to stop telling
    /// anyone what to put in one.
    @Test("no app source writes a shell rc file")
    func rcFilesHaveNoWriter() throws {
        let sources = try appSources()
        let rcFiles = [".zshrc", ".zprofile", ".bash_profile", ".bashrc", "config.fish"]
        let writers = [
            ".write(", "write(to:", "createFile", "FileHandle", "removeItem",
            "createSymbolicLink", "Darwin.rename", "appendingData", "\">>\"",
        ]
        var named = 0

        for source in sources {
            let text = try String(contentsOf: source, encoding: .utf8)
            for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") {
                    continue
                }
                guard rcFiles.contains(where: { line.contains($0) }) else { continue }
                named += 1
                if let writer = writers.first(where: { line.contains($0) }) {
                    Issue.record("""
                        \(source.lastPathComponent):\(offset + 1) names a shell rc file on a line \
                        that calls `\(writer)`. GitPic hands the user text to paste and never \
                        edits their shell configuration.
                        \(trimmed)
                        """)
                }
            }
        }

        // The guidance still exists and still reaches the UI as text.
        #expect(named > 0, "no source names an rc file at all — the setup guidance has gone")
        #expect(CommandLineTool.Shell.zsh.setUp?.file == "~/.zshrc")
        #expect(CommandLineTool.Shell.bash.pathSetUp.file == "~/.bash_profile")
        // fish is the one whose PATH is set by a command rather than a file, so it must not be
        // described as an rc file to edit.
        #expect(!rcFiles.contains(CommandLineTool.Shell.fish.pathSetUp.file))
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
