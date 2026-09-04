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

    @Test("the four PATH results are interpreted from the unresolved entry")
    func reachability() {
        let link = URL(fileURLWithPath: "/Users/example/.local/bin/gitpic")
        #expect(CommandLineTool.reach(
            of: link,
            probe: .init(path: link, conclusive: true, reason: nil)) == .reachable)

        let winner = URL(fileURLWithPath: "/opt/example/bin/gitpic")
        #expect(CommandLineTool.reach(
            of: link,
            probe: .init(path: winner, conclusive: true, reason: nil))
                == .shadowed(by: winner))

        #expect(CommandLineTool.reach(
            of: link,
            probe: .init(path: nil, conclusive: true, reason: nil)) == .notOnPath)

        #expect(CommandLineTool.reach(
            of: link,
            probe: .init(path: nil, conclusive: false, reason: "profile stopped"))
                == .unknown(reason: "profile stopped"))
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
        let statuses: [CommandLineTool.Status] = [
            .notInstalled, .linked, .dangling(destination: destination),
            .pointsElsewhere(destination: destination), .occupied,
        ]
        let reaches: [CommandLineTool.Reach] = [
            .reachable, .shadowed(by: destination), .notOnPath,
            .unknown(reason: "cannot ask shell"),
        ]

        #expect(statuses.allSatisfy { $0.label.isEmpty == false && $0.detail.isEmpty == false })
        #expect(Set(statuses.map(\.label)).count == statuses.count)
        #expect(reaches.allSatisfy { $0.label.isEmpty == false && $0.detail.isEmpty == false })
        #expect(Set(reaches.map(\.label)).count == reaches.count)
    }

    /// **The rule is about writers, and a comment cannot write anything.**
    ///
    /// Comment lines are skipped, because the first form of this scan banned the *subject*: it
    /// failed the moment `ToolDiscovery.loginShellProbe` documented why it needs `-i`, which is a
    /// statement about which startup files zsh reads and has no way to be made without naming
    /// `.zshrc`. A tripwire that catches prose about the hazard gets reworded around rather than
    /// obeyed, and the reworded comment is worse than the one it replaced. Anchored on code the
    /// way `QuitPathContractTests` anchors on a receiver instead of the bare word `terminate`,
    /// for the same reason.
    ///
    /// A line that names an rc file *and* carries code still fails, so `write(to: rc) // ~/.zshrc`
    /// is not a way through. What no string scan can catch is a path assembled from pieces; that
    /// is why the real guarantee is structural — `Shell.setUp` returns text and no writer for it
    /// exists in either target — and this is the weaker half.
    @Test("no app source writes or names a shell rc file outside Shell.setUp")
    func rcFilesHaveNoWriter() throws {
        let sources = try appSources()
        let forbidden = [".zshrc", ".bash_profile", ".bashrc", "config.fish"]
        var hits = 0

        for source in sources {
            let text = try String(contentsOf: source, encoding: .utf8)
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") {
                    continue
                }
                guard forbidden.contains(where: { line.contains($0) }) else { continue }
                hits += 1
                #expect(source.lastPathComponent == "CommandLineTool.swift")
                #expect(line.contains("file: \"~/.zshrc\""))
            }
        }
        #expect(hits == 1, "the zsh setup literal must stay visible to the UI")
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
