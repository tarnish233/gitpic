import Foundation
import Testing
@testable import GitPicCore

/// Which upgrade gets offered, and what the swap script says.
///
/// This is the decision `GitPicApp` used to make inline and therefore could not test. It was
/// moved into `GitPicCore` so that the table below — every row of which is a way to do the
/// wrong thing to somebody's applications folder — is checked by something other than reading.
@Suite("Self-update routing")
struct SelfUpdateRouteTests {

    private static let dmg = ReleaseAsset(
        name: "GitPic-0.19.0-macos-arm64.dmg", size: 4_999_203,
        url: "https://example.invalid/d/GitPic-0.19.0-macos-arm64.dmg",
        digest: "sha256:\(String(repeating: "ab", count: 32))")
    private static var choice: AssetChoice {
        .found(dmg, sha256: String(repeating: "ab", count: 32))
    }
    private static let brewPath = URL(fileURLWithPath: "/opt/homebrew/bin/brew")

    /// **Homebrew wins whenever it owns the bundle.** This is the surviving half of the
    /// argument the old `Updater` doc comment made against self-update: replacing a
    /// cask-managed bundle leaves brew's manifest describing a version that is not on disk,
    /// and the next `brew upgrade` fights it.
    @Test("a cask-managed bundle goes to brew, not to the in-app installer")
    func brewWins() {
        let route = SelfUpdate.route(
            location: .applicationsDir, bundleVersion: "0.18.0", latest: "0.19.0",
            brew: .ownsThisCask(brew: Self.brewPath), asset: Self.choice)
        #expect(route == .homebrew(brew: Self.brewPath))
    }

    /// brew is installed but does not manage this app — a drag-installed copy on a machine
    /// that also has Homebrew, which is entirely ordinary.
    @Test("brew that does not own it leaves the in-app installer")
    func brewPresentButNotTheOwner() {
        let route = SelfUpdate.route(
            location: .applicationsDir, bundleVersion: "0.18.0", latest: "0.19.0",
            brew: .doesNotOwnIt, asset: Self.choice)
        #expect(route == .selfInstall(asset: Self.dmg, sha256: String(repeating: "ab", count: 32)))
    }

    /// The user this whole feature exists for: no Homebrew at all.
    ///
    /// This is the row that `locateBrew()`'s single `nil` used to make unreachable — "no brew"
    /// and "the probe timed out" were the same answer, and both meant "ask again later", so
    /// the machine with no brew waited forever for a probe that was never going to say
    /// anything different.
    @Test("no brew on the machine is an answer, and it enables the installer")
    func noBrewAtAll() {
        let route = SelfUpdate.route(
            location: .applicationsDir, bundleVersion: "0.18.0", latest: "0.19.0",
            brew: .doesNotOwnIt, asset: Self.choice)
        guard case .selfInstall = route else {
            Issue.record("a machine with no brew must be offered the in-app installer")
            return
        }
    }

    /// **An unknown answer must never become "not brew's".** A probe that timed out can be
    /// hiding a working Homebrew, and installing over a cask on that guess is exactly the
    /// damage the precedence rule exists to prevent. Retryable, so the sheet asks again
    /// instead of caching it for the life of the process.
    @Test("an inconclusive brew probe is retryable, never an install")
    func unknownBrewIsRetryable() {
        let route = SelfUpdate.route(
            location: .applicationsDir, bundleVersion: "0.18.0", latest: "0.19.0",
            brew: .unknown(reason: "brew list --cask gitpic timed out"), asset: Self.choice)
        guard case .unavailable(let reason, let retryable) = route else {
            Issue.record("an unknown brew answer must not install anything")
            return
        }
        #expect(retryable, "a probe that got no answer must be asked again")
        #expect(reason.contains("timed out"))
    }

    /// Outside `/Applications` and `~/Applications` nothing is installed — including the
    /// development build in the repository's `dist-app/`, which is the case that would
    /// otherwise replace a developer's build with a release one.
    @Test("a bundle outside an Applications directory is refused, permanently")
    func elsewhereIsRefused() {
        let route = SelfUpdate.route(
            location: .elsewhere(path: "/Users/x/src/gitpic/dist-app/GitPic.app"),
            bundleVersion: "0.18.0", latest: "0.19.0",
            brew: .doesNotOwnIt, asset: Self.choice)
        guard case .unavailable(let reason, let retryable) = route else {
            Issue.record("only an Applications directory may be installed into")
            return
        }
        // Not retryable: asking again cannot move the running bundle.
        #expect(!retryable)
        #expect(reason.contains("dist-app"))
    }

    /// The gate is the *bundle's* version, not the report's `current` — that one comes from
    /// the CLI, and this replaces the bundle. Equal or newer is not an update.
    @Test("the bundle's own version decides, and it must be older")
    func versionGate() {
        for mine in ["0.19.0", "0.20.0", "1.0.0"] {
            let route = SelfUpdate.route(
                location: .applicationsDir, bundleVersion: mine, latest: "0.19.0",
                brew: .doesNotOwnIt, asset: Self.choice)
            guard case .unavailable(let reason, _) = route else {
                Issue.record("\(mine) is not older than 0.19.0 and must not be replaced")
                return
            }
            #expect(reason.contains(mine))
        }
        // And older is.
        guard case .selfInstall = SelfUpdate.route(
            location: .applicationsDir, bundleVersion: "0.9.0", latest: "0.10.0",
            brew: .doesNotOwnIt, asset: Self.choice) else {
            // 0.9.0 < 0.10.0 is the comparison a string sort gets backwards, which is why
            // the version is parsed into numbers rather than compared as text.
            Issue.record("0.9.0 must be older than 0.10.0")
            return
        }
    }

    @Test("an unreadable version is refused rather than guessed at")
    func unreadableVersion() {
        for mine in [nil, "", "0.18", "0.18.0.1", "0.18.0-rc1", "app-v0.1.2", "abc"] {
            let route = SelfUpdate.route(
                location: .applicationsDir, bundleVersion: mine, latest: "0.19.0",
                brew: .doesNotOwnIt, asset: Self.choice)
            guard case .unavailable = route else {
                Issue.record("\(mine ?? "nil") is not a comparable version")
                return
            }
        }
    }

    /// No verifiable asset, no install — the refusal carries the asset layer's own reason so
    /// the sheet can say whether the image is missing or merely unverifiable.
    @Test("an unverifiable asset stops the install and keeps its reason")
    func assetRefusalPropagates() {
        let route = SelfUpdate.route(
            location: .applicationsDir, bundleVersion: "0.18.0", latest: "0.19.0",
            brew: .doesNotOwnIt, asset: .none(reason: "GitHub 没有报校验和"))
        #expect(route == .unavailable(reason: "GitHub 没有报校验和", retryable: false))
    }

    // MARK: - The generated script

    /// The swap script is shell text generated in Swift, so this is the only thing that checks
    /// it before it runs against somebody's `/Applications`.
    @Test("the swap script is valid bash and does the renames in the safe order")
    func scriptIsValidAndOrdered() throws {
        let script = SelfUpdate.installScript(
            staged: Self.staged(), pid: 4242,
            log: URL(fileURLWithPath: "/tmp/x/GitPic-update.log"))

        // Parsed by bash itself rather than by reading it.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitpic-script-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("install.sh")
        try script.write(to: file, atomically: true, encoding: .utf8)

        let check = try ChildProcess.run(
            executable: URL(fileURLWithPath: "/bin/bash"),
            args: ["-n", file.path], timeout: 30)
        let complaint = String(decoding: check.stderr, as: UTF8.self)
        #expect(check.status == 0, "bash -n rejected the script: \(complaint)")

        // The relaunch is a trap, not a line at the bottom: GitPic is .accessory, so a script
        // that dies before reopening leaves no icon anywhere to click.
        #expect(script.contains("trap reopen EXIT"))
        // Reopen happens before the rollback material is deleted, so a bundle that will not
        // launch still has the old one behind it.
        let reopened = try #require(script.range(of: "\nreopen\ntrap - EXIT"))
        let removed = try #require(script.range(of: "rm -rf \"$backup\""))
        #expect(reopened.upperBound < removed.lowerBound,
                "the backup is deleted before the app is reopened")
        // PATH is pinned: the app's own has a Homebrew prefix prepended, and a swap script has
        // no business resolving `mv` through a user-writable directory.
        #expect(script.contains("PATH=/usr/bin:/bin:/usr/sbin:/sbin"))
        #expect(script.contains("kill -0 4242"))
    }

    /// The bug that would have destroyed the old bundle. `mv a b` where `b` exists as a
    /// directory moves `a` *into* `b` — so a fixed backup name plus one retry gives
    /// `GitPic.app.old/GitPic.app`, a "rollback" that restores a wrapper directory, and a
    /// `rm -rf` that takes the real app with it. Reproduced before this was written.
    @Test("the backup name is unique per run and its absence is asserted")
    func backupNameIsUniqueAndChecked() {
        let a = SelfUpdate.installScript(staged: Self.staged(), pid: 1,
                                         log: URL(fileURLWithPath: "/tmp/a.log"))
        let b = SelfUpdate.installScript(staged: Self.staged(), pid: 1,
                                         log: URL(fileURLWithPath: "/tmp/a.log"))
        let names = [a, b].map { script -> String in
            let line = script.split(separator: "\n").first { $0.hasPrefix("backup=") }
            return line.map(String.init) ?? ""
        }
        #expect(names[0] != names[1], "two runs must not share a backup path")
        #expect(names.allSatisfy { $0.contains(".GitPic-old-") })
        // And the script refuses rather than moving into an existing directory.
        #expect(a.contains("if [ -e \"$backup\" ]"))
        // The backup sits beside the target so the rename cannot cross filesystems.
        #expect(names[0].contains("/Applications/"))
    }

    // MARK: - Sweeping leftovers

    /// A failed install can leave a bundle-sized staging directory and a backup in
    /// `/Applications`; the script cannot remove its own staging directory, and deliberately
    /// keeps the backup until after the reopen. They are swept a launch later.
    @Test("stale staging and backup directories are swept, fresh ones are left alone")
    func sweepsOnlyStaleLeftovers() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitpic-sweep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let old = Date().addingTimeInterval(-86_400 * 3)
        let stale = [".GitPic-update-stale", ".GitPic-old-stale"]
        let fresh = [".GitPic-update-fresh", ".GitPic-old-fresh"]
        // Something that merely looks similar, and a real app, must both survive.
        let bystanders = ["GitPic.app", ".GitPicSomethingElse", "Other.app"]

        for name in stale + fresh + bystanders {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        for name in stale + [bystanders[1]] {
            try FileManager.default.setAttributes([.modificationDate: old],
                                                 ofItemAtPath: root.appendingPathComponent(name).path)
        }

        let swept = SelfUpdate.sweepLeftovers(in: [root])
        #expect(Set(swept.map(\.lastPathComponent)) == Set(stale))
        for name in fresh + bystanders {
            #expect(FileManager.default.fileExists(
                atPath: root.appendingPathComponent(name).path),
                "\(name) must not be swept")
        }
    }

    private static func staged() -> SelfUpdate.Staged {
        let dir = URL(fileURLWithPath: "/Applications/.GitPic-update-abc")
        return SelfUpdate.Staged(
            bundle: dir.appendingPathComponent("GitPic.app"),
            directory: dir,
            target: URL(fileURLWithPath: "/Applications/GitPic.app"),
            version: "0.19.0")
    }
}
