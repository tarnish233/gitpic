import Foundation
import Testing
@testable import GitPicCore

/// Which upgrade gets offered, and what the swap script says.
///
/// This is the decision `GitPicApp` used to make inline and therefore could not test. It was
/// moved into `GitPicCore` so every refusal that protects an applications directory is exercised
/// by something other than reading.
@Suite("Self-update routing")
struct SelfUpdateRouteTests {

    private static let dmg = ReleaseAsset(
        name: "GitPic-0.19.0-macos-arm64.dmg", size: 4_999_203,
        url: "https://example.invalid/d/GitPic-0.19.0-macos-arm64.dmg",
        digest: "sha256:\(String(repeating: "ab", count: 32))")
    private static var choice: AssetChoice {
        .found(dmg, sha256: String(repeating: "ab", count: 32))
    }
    private static let sha = String(repeating: "ab", count: 32)

    @Test("an older bundle in an Applications directory gets the installer")
    func installsAnOlderBundle() {
        let route = SelfUpdate.route(
            location: .applicationsDir, bundleVersion: "0.18.0", latest: "0.19.0",
            asset: Self.choice)
        #expect(route == .selfInstall(asset: Self.dmg, sha256: Self.sha, version: "0.19.0"))
    }

    /// With the location, version and asset all in order there is no remaining machine state
    /// that can send this anywhere else. Break each fact in turn and none may install.
    @Test("nothing but the location, version and asset decides the route")
    func routeIsDecidedByThreeFactsOnly() {
        guard case .selfInstall = SelfUpdate.route(
            location: .applicationsDir, bundleVersion: "0.18.0", latest: "0.19.0",
            asset: Self.choice)
        else {
            Issue.record("three facts in order must produce an install and nothing else")
            return
        }

        let broken: [SelfUpdate.Route] = [
            SelfUpdate.route(
                location: .elsewhere(path: "/Users/x/Downloads/GitPic.app"),
                bundleVersion: "0.18.0", latest: "0.19.0", asset: Self.choice),
            SelfUpdate.route(
                location: .applicationsDir, bundleVersion: "not-a-version",
                latest: "0.19.0", asset: Self.choice),
            SelfUpdate.route(
                location: .applicationsDir, bundleVersion: "0.18.0",
                latest: "0.19.0", asset: .none(reason: "GitHub 没有报校验和")),
        ]
        for route in broken {
            guard case .unavailable = route else {
                Issue.record("a broken precondition must not install")
                return
            }
        }
    }

    /// Outside `/Applications` and `~/Applications` nothing is installed — including the
    /// development build in the repository's `dist-app/`.
    @Test("a bundle outside an Applications directory is refused")
    func elsewhereIsRefused() {
        let route = SelfUpdate.route(
            location: .elsewhere(path: "/Users/x/src/gitpic/dist-app/GitPic.app"),
            bundleVersion: "0.18.0", latest: "0.19.0", asset: Self.choice)
        guard case .unavailable(let reason) = route else {
            Issue.record("only an Applications directory may be installed into")
            return
        }
        #expect(reason.contains("dist-app"))
    }

    /// No developer English reaches the Chinese window, and refusal prose never looks like a
    /// command line. A path is allowed because the location refusal needs to name what it refused.
    @Test("every refusal is a Chinese sentence, not a command line")
    func refusalsAreWrittenForTheWindow() {
        let refusals: [SelfUpdate.Route] = [
            SelfUpdate.route(
                location: .elsewhere(path: "/Users/x/Downloads/GitPic.app"),
                bundleVersion: "0.18.0", latest: "0.19.0", asset: Self.choice),
            SelfUpdate.route(
                location: .applicationsDir, bundleVersion: nil,
                latest: "0.19.0", asset: Self.choice),
            SelfUpdate.route(
                location: .applicationsDir, bundleVersion: "0.18.0",
                latest: "not-a-version", asset: Self.choice),
            SelfUpdate.route(
                location: .applicationsDir, bundleVersion: "0.19.0",
                latest: "0.19.0", asset: Self.choice),
        ]
        for route in refusals {
            guard case .unavailable(let shown) = route else {
                Issue.record("expected a refusal to check the wording of")
                return
            }
            #expect(shown.contains(where: { $0.unicodeScalars.first.map {
                (0x4E00...0x9FFF).contains($0.value)
            } == true }), "\(shown) is rendered in a Chinese-only sheet and has to be Chinese")
            #expect(shown.contains("--") == false,
                    "\(shown) reads like a command line, and is shown in a compact caption")
        }
    }

    /// The gate is the *bundle's* version, not the report's `current` — that one comes from
    /// the CLI, and this replaces the bundle. Equal or newer is not an update.
    @Test("the bundle's own version decides, and it must be older")
    func versionGate() {
        for mine in ["0.19.0", "0.20.0", "1.0.0"] {
            let route = SelfUpdate.route(
                location: .applicationsDir, bundleVersion: mine, latest: "0.19.0",
                asset: Self.choice)
            guard case .unavailable(let reason) = route else {
                Issue.record("\(mine) is not older than 0.19.0 and must not be replaced")
                return
            }
            #expect(reason.contains(mine))
        }
        guard case .selfInstall = SelfUpdate.route(
            location: .applicationsDir, bundleVersion: "0.9.0", latest: "0.10.0",
            asset: Self.choice)
        else {
            Issue.record("0.9.0 must be older than 0.10.0")
            return
        }
    }

    @Test("an unreadable version is refused rather than guessed at")
    func unreadableVersion() {
        for mine in [nil, "", "0.18", "0.18.0.1", "0.18.0-rc1", "app-v0.1.2", "abc"] {
            let route = SelfUpdate.route(
                location: .applicationsDir, bundleVersion: mine, latest: "0.19.0",
                asset: Self.choice)
            guard case .unavailable = route else {
                Issue.record("\(mine ?? "nil") is not a comparable version")
                return
            }
        }
    }

    /// No verifiable asset, no install — the refusal carries the asset layer's own reason.
    @Test("an unverifiable asset stops the install and keeps its reason")
    func assetRefusalPropagates() {
        let route = SelfUpdate.route(
            location: .applicationsDir, bundleVersion: "0.18.0", latest: "0.19.0",
            asset: .none(reason: "GitHub 没有报校验和"))
        #expect(route == .unavailable(reason: "GitHub 没有报校验和"))
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
        // Nothing here deletes the rollback material: `open -a` returning 0 is not the new
        // version running, so the delete belongs to a later launch
        // (`SelfUpdate.sweepLeftovers`). This used to assert that the reopen came *before* the
        // `rm -rf "$backup"`, an ordering that cannot be worth anything while the thing it
        // orders against is a delete the script has no evidence for.
        #expect(!script.contains("rm -rf"), "the script must not delete anything recursively")
        // `rmdir` is not a smaller `rm -rf`: it refuses a directory with anything in it. So if
        // the second `mv` failed and the staging directory still holds the new bundle, the
        // tidy-up fails harmlessly instead of destroying what was about to be installed.
        #expect(script.contains(#"rmdir "$stagedir""#),
                "the emptied staging directory should go by rmdir")
        let reopened = try #require(script.range(of: "\nreopen\ntrap - EXIT"))
        let tidied = try #require(script.range(of: #"rmdir "$stagedir""#))
        #expect(reopened.upperBound < tidied.lowerBound,
                "the app is reopened before any tidying")
        // PATH is pinned because a swap script has no business resolving `mv` through a
        // user-writable directory. `ToolPaths.childPATH` is exactly these four directories.
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

    // MARK: - Proving the login shell ran

    /// A negative answer needs evidence that the probe actually ran, and the exit status is not
    /// that evidence. The probe brackets `command -v <tool>` between two marks; what lies between
    /// them is the lookup's own output and nothing else.
    @Test("only a bracketed empty answer means the tool is absent")
    func probeAnswerSeparatesAbsenceFromSilence() {
        let open = ToolDiscovery.probeOpen
        let close = ToolDiscovery.probeClose

        // Both marks with nothing between them is the one conclusive negative.
        #expect(ToolDiscovery.probeAnswer(in: "\(open)\n\(close)\n") == "")
        // A path between the marks is the positive answer.
        #expect(ToolDiscovery.probeAnswer(in: "\(open)\n/custom/bin/gitpic\n\(close)\n")
                == "/custom/bin/gitpic")
        // A shell function and an alias are not paths, but neither means absence.
        #expect(ToolDiscovery.probeAnswer(in: "\(open)\ngitpic\n\(close)\n") == "gitpic")
        #expect(ToolDiscovery.probeAnswer(
            in: "\(open)\nalias gitpic=/nowhere/gitpic\n\(close)\n")
                == "alias gitpic=/nowhere/gitpic")
        // tcsh and csh have no `command` builtin: measured, status 1 and stdout completely
        // empty. `.zprofile` with `exit 1` gives the same, and `exec /usr/bin/true` gives it
        // with status **0** — which is why the status cannot be the test.
        #expect(ToolDiscovery.probeAnswer(in: "") == nil)
        // A profile whose last write has no trailing newline glues the opening mark onto it —
        // measured verbatim, so the marks are searched as substrings, not as whole lines.
        #expect(ToolDiscovery.probeAnswer(in: "glued no newline\(open)\n\(close)\n") == "")
        // A profile-spawned job that flushes after the lookup lands *after* the closing mark,
        // so it cannot turn "not found" into "cannot tell".
        #expect(ToolDiscovery.probeAnswer(in: "\(open)\n\(close)\n[gpg-agent] ready\n") == "")
        // Half a bracket is no bracket: a shell killed at the 8 s bound may have written the
        // opening mark and nothing else.
        #expect(ToolDiscovery.probeAnswer(in: "\(open)\n") == nil)
        #expect(ToolDiscovery.probeAnswer(in: "\(close)\n\(open)\n") == nil)
    }

    /// The live half: this machine's own login shell, so the argument list and the two marks
    /// stay covered rather than only their parse.
    @Test("the real login shell brackets its answer, both ways")
    func liveProbeIsConclusiveBothWays() {
        // `sh` exists on every macOS, so this is the positive answer.
        let found = ToolDiscovery.loginShellProbe("sh")
        #expect(found.path?.lastPathComponent == "sh")
        #expect(found.conclusive)

        // And a tool that exists nowhere must come back as a *definite* no; otherwise a normal
        // missing command is indistinguishable from a broken profile.
        let absent = ToolDiscovery.loginShellProbe("gitpic-absent-\(UUID().uuidString)")
        #expect(absent.path == nil)
        #expect(absent.conclusive,
                """
                a login shell that ran and found nothing is an answer; a failure here means \
                this developer's profile breaks the probe itself (reason: \
                \(absent.reason ?? "none"))
                """)
    }

    // MARK: - Sweeping leftovers
    /// A failed install can leave a bundle-sized staging directory and a backup in
    /// `/Applications`; the script cannot remove its own staging directory, and deliberately
    /// keeps the backup until a later launch. They are swept from here, one launch later.
    ///
    /// **This half only: nothing of ours is deleted, and nothing of anyone else's ever is.**
    /// What decides *when* a leftover goes belongs with the code — see
    /// `SelfUpdateInstallTests.sweepAgesFromCtimeNotMtime`, which drives the cutoff directly.
    /// It has to live there because the age is read from `st_ctime`, and a fixture cannot
    /// fabricate that: measured, `touch` moves mtime and birthtime but cannot move ctime
    /// backwards. This test used to set `.modificationDate` three days back and expect a
    /// sweep, which is exactly the rule that made a fresh backup deletable — `mv` does not
    /// touch mtime and `ditto` preserves it, so a backup's mtime is its release's build time.
    @Test("leftovers created moments ago are kept, and lookalikes are never touched")
    func sweepsOnlyStaleLeftovers() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitpic-sweep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fresh = [".GitPic-update-fresh", ".GitPic-old-fresh"]
        // Something that merely looks similar, and a real app, must both survive.
        let bystanders = ["GitPic.app", ".GitPicSomethingElse", "Other.app"]

        for name in fresh + bystanders {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        let swept = SelfUpdate.sweepLeftovers(in: [root])
        #expect(swept.isEmpty, "swept: \(swept.map(\.lastPathComponent))")
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
