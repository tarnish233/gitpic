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
    private static let sha = String(repeating: "ab", count: 32)

    /// What every row that is not about Homebrew wants. Spelled out at each call rather than
    /// defaulted in `route` itself: a default would let a new call site skip the question
    /// silently, and this is a question whose wrong answer installs over somebody's cask.
    private static let notBrews = CaskOwnership.Verdict.notHomebrews
    /// A cask that owns this bundle and offers `version`.
    private static func brews(_ version: String) -> CaskOwnership.Verdict {
        .homebrews(cask: "gitpic", offers: .version(version))
    }

    /// **One install path, whoever installed the bundle — but only one of the two branches
    /// installs.** This suite once opened with `brewWins`, went through a period with no brew
    /// question at all, and now asks it again in a narrower form: a cask-managed bundle is handed
    /// a command instead of being installed over, and nothing spawns. The rows that went with the
    /// original fork protected things that no longer exist to protect — how two prefixes' verdicts
    /// were folded, that an unanswered probe never became "not brew's" — because `CaskOwnership`
    /// answers conclusively from the filesystem and its own suite covers it.
    @Test("an older bundle in an Applications directory gets the installer")
    func installsAnOlderBundle() {
        let route = SelfUpdate.route(
            cask: Self.notBrews,
            location: .applicationsDir, bundleVersion: "0.18.0", latest: "0.19.0",
            asset: Self.choice)
        #expect(route == .selfInstall(asset: Self.dmg, sha256: Self.sha, version: "0.19.0"))
    }

    /// The structural claim, one fact wider than it used to be: with ownership, the location, the
    /// version and the asset all in order there is **no** remaining question that could send this
    /// anywhere else — and ownership is the only input that was added, so nothing else about the
    /// machine can change the answer either.
    @Test("nothing but ownership, the location, the version and the asset decides the route")
    func routeIsDecidedByFourFactsOnly() {
        let usable = SelfUpdate.route(
            cask: Self.notBrews,
            location: .applicationsDir, bundleVersion: "0.18.0", latest: "0.19.0",
            asset: Self.choice)
        guard case .selfInstall = usable else {
            Issue.record("four facts in order must produce an install and nothing else")
            return
        }
        // Break exactly one at a time; none may produce an install.
        let broken: [SelfUpdate.Route] = [
            SelfUpdate.route(cask: Self.brews("0.19.0"), location: .applicationsDir,
                             bundleVersion: "0.18.0", latest: "0.19.0", asset: Self.choice),
            SelfUpdate.route(cask: Self.notBrews,
                             location: .elsewhere(path: "/Users/x/Downloads/GitPic.app"),
                             bundleVersion: "0.18.0", latest: "0.19.0", asset: Self.choice),
            SelfUpdate.route(cask: Self.notBrews, location: .applicationsDir,
                             bundleVersion: "not-a-version",
                             latest: "0.19.0", asset: Self.choice),
            SelfUpdate.route(cask: Self.notBrews, location: .applicationsDir,
                             bundleVersion: "0.18.0",
                             latest: "0.19.0", asset: .none(reason: "GitHub 没有报校验和")),
        ]
        for route in broken {
            if case .selfInstall = route {
                Issue.record("a broken precondition must not install")
                return
            }
        }
        // And the ownership row specifically is a hand-over, not a refusal: a brew user must
        // never be left with neither an install nor a command.
        guard case .homebrewManaged = broken[0] else {
            Issue.record("a cask-owned bundle must be handed the command")
            return
        }
        for route in broken.dropFirst() {
            guard case .unavailable = route else {
                Issue.record("a broken precondition that is not about Homebrew must refuse")
                return
            }
        }
    }

    /// Outside `/Applications` and `~/Applications` nothing is installed — including the
    /// development build in the repository's `dist-app/`, which is the case that would
    /// otherwise replace a developer's build with a release one.
    ///
    /// The row this used to absorb, `caskInACustomAppdirIsSentToTheReleasePage`, is now **inverted**
    /// and lives in `casksOutrankTheLocationRule` below. It once proved the location rule was not
    /// *looser* for a cask at a custom `--appdir`; the rule is now that ownership is asked first,
    /// so such a bundle gets the command rather than this refusal. What is left here is the copy
    /// that is nobody's cask.
    @Test("a bundle outside an Applications directory is refused, permanently")
    func elsewhereIsRefused() {
        let route = SelfUpdate.route(
            cask: Self.notBrews,
            location: .elsewhere(path: "/Users/x/src/gitpic/dist-app/GitPic.app"),
            bundleVersion: "0.18.0", latest: "0.19.0", asset: Self.choice)
        guard case .unavailable(let reason, let retryable) = route else {
            Issue.record("only an Applications directory may be installed into")
            return
        }
        // Not retryable: asking again cannot move the running bundle.
        #expect(!retryable)
        #expect(reason.contains("dist-app"))
    }

    // MARK: - When Homebrew owns the bundle

    /// **Ownership is asked before the location, and this is the row that says why.**
    ///
    /// `brew install --cask gitpic --appdir ~/Apps` is an ordinary thing to do, and it produces a
    /// bundle `location(of:)` calls `.elsewhere`. Asking location first sends that user to
    /// 「这份 GitPic 在 …」 — a dead end — when `brew upgrade --cask gitpic` is exactly right for
    /// them and safe, because the cask's own `uninstall quit:` handles the running app.
    ///
    /// This is the inversion of the deleted `caskInACustomAppdirIsSentToTheReleasePage`, which
    /// pinned the opposite: that the location rule was not *looser* for a cask. The rule is now
    /// that ownership outranks it, and the inversion is the load-bearing part.
    @Test("a cask outranks the location rule, at any appdir")
    func casksOutrankTheLocationRule() {
        let route = SelfUpdate.route(
            cask: Self.brews("0.19.0"),
            location: .elsewhere(path: "/Users/x/Apps/GitPic.app"),
            bundleVersion: "0.18.0", latest: "0.19.0", asset: Self.choice)
        #expect(route == .homebrewManaged(command: "brew upgrade --cask gitpic",
                                         installed: "0.18.0", available: "0.19.0"))
    }

    /// **The safety requirement, stated once over the whole space.** Nothing this app does may
    /// install over a bundle Homebrew owns — that is the entire policy, and until now nothing
    /// pinned it. Every other fact is varied underneath a cask verdict, including the
    /// combinations that would otherwise be perfectly installable.
    @Test("a cask-owned bundle is never installed over, whatever else is true")
    func aCaskIsNeverInstalledOver() {
        let locations: [SelfUpdate.BundleLocation] =
            [.applicationsDir, .elsewhere(path: "/Users/x/Apps/GitPic.app")]
        let versions: [String?] = ["0.18.0", "0.19.0", "not-a-version", nil]
        let assets: [AssetChoice] = [Self.choice, .none(reason: "GitHub 没有报校验和")]
        let offers: [CaskOwnership.Offer] =
            [.version("0.19.0"), .version("0.18.0"), .unknown(reason: "暂时读不到")]

        for location in locations {
            for mine in versions {
                for asset in assets {
                    for offer in offers {
                        let route = SelfUpdate.route(
                            cask: .homebrews(cask: "gitpic", offers: offer),
                            location: location, bundleVersion: mine, latest: "0.19.0",
                            asset: asset)
                        if case .selfInstall = route {
                            Issue.record("a cask-owned bundle must never be installed over")
                            return
                        }
                        // Nor may it dead-end: a brew user with neither an install nor a command
                        // has nothing to do, which is the failure this whole route exists to
                        // avoid. `homebrewUpToDate` is the one case with no command, and it is
                        // an answer rather than a dead end.
                        if case .unavailable = route {
                            Issue.record("a cask-owned bundle must never reach a refusal")
                            return
                        }
                    }
                }
            }
        }
    }

    /// The three outcomes, which are Claude Code's three read out of its own binary: the cask has
    /// something newer, the cask has nothing newer, or what the cask has could not be read.
    ///
    /// **The comparison is against the cask, never against the release.** The middle row is the
    /// one that proves it: a release at 0.19.0 exists and the bundle is 0.18.0, so the ordinary
    /// version gate would install — but the tap still says 0.18.0, so `brew upgrade` would print
    /// "the latest version is already installed" and exit 0. That window is real; the tap follows
    /// a release by dispatch with a six-hourly cron behind it, and AGENTS.md records the dispatch
    /// token having expired for three releases.
    @Test("the cask's own version decides, not the release's")
    func theCasksVersionDecides() {
        let ahead = SelfUpdate.route(
            cask: Self.brews("0.19.0"), location: .applicationsDir,
            bundleVersion: "0.18.0", latest: "0.19.0", asset: Self.choice)
        #expect(ahead == .homebrewManaged(command: "brew upgrade --cask gitpic",
                                         installed: "0.18.0", available: "0.19.0"))

        // The tap lags the release: no command, because the command would do nothing.
        let lagging = SelfUpdate.route(
            cask: Self.brews("0.18.0"), location: .applicationsDir,
            bundleVersion: "0.18.0", latest: "0.19.0", asset: Self.choice)
        #expect(lagging == .homebrewUpToDate(installed: "0.18.0", offered: "0.18.0"))

        // A bundle *ahead* of the tap — which a self-updated copy from before this change is —
        // is also nothing for brew to do, and must not be offered a downgrade.
        //
        // Both numbers travel, and the asymmetry is the point: `installed` is 0.19.0 while
        // `offered` is 0.18.0, so the sheet can say which is which. Carrying only `installed`
        // let it print 「已是 Homebrew 提供的最新版本（0.19.0）」 — a claim about what Homebrew
        // provides, made out of the bundle's number, telling this user to wait for a version
        // they are already running.
        let behindTap = SelfUpdate.route(
            cask: Self.brews("0.18.0"), location: .applicationsDir,
            bundleVersion: "0.19.0", latest: "0.19.0", asset: Self.choice)
        #expect(behindTap == .homebrewUpToDate(installed: "0.19.0", offered: "0.18.0"))

        let unreadable = SelfUpdate.route(
            cask: .homebrews(cask: "gitpic", offers: .unknown(reason: "暂时读不到 Homebrew 提供的版本")),
            location: .applicationsDir, bundleVersion: "0.18.0", latest: "0.19.0",
            asset: Self.choice)
        #expect(unreadable == .homebrewUnverified(command: "brew upgrade --cask gitpic",
                                                 reason: "暂时读不到 Homebrew 提供的版本"))
    }

    /// The command names the cask that was actually found, not a hardcoded token — so a rename in
    /// the tap, or a second cask, cannot make the app print a command for the wrong one.
    @Test("the command is built from the cask that owns the bundle")
    func theCommandNamesTheCaskThatWasFound() {
        let route = SelfUpdate.route(
            cask: .homebrews(cask: "gitpic-beta", offers: .version("0.19.0")),
            location: .applicationsDir, bundleVersion: "0.18.0", latest: "0.19.0",
            asset: Self.choice)
        guard case .homebrewManaged(let command, _, _) = route else {
            Issue.record("expected the Homebrew hand-over")
            return
        }
        #expect(command == "brew upgrade --cask gitpic-beta")
    }

    /// **No developer English reaches the window, and nothing reads like a command line.**
    ///
    /// Inherited from `unknownBrewIsRetryable`, which is deleted: that row's reason string used
    /// to be `"brew list --cask gitpic timed out"`, English and a command line both, rendered by
    /// `UpdateSheet` as `Text(reason)` in a caption at 480 pt in a Chinese-only window. The
    /// assertion was worth more than the row, so it is applied to every refusal `route` can mint
    /// instead of to the one that happened to have the bug.
    ///
    /// The old row also asserted `!reason.contains("/")`, and that does **not** generalise: the
    /// location refusal names the path it is refusing, which is the entire information in it.
    /// An option flag is the part that was never legitimate.
    ///
    /// **Reintroducing the Homebrew branch did not weaken this.** The one deliberate command
    /// string in the whole route is `homebrewManaged`/`homebrewUnverified`'s own `command` value,
    /// which the sheet renders as a monospaced row rather than as prose — so the ban below still
    /// applies to every `reason` unaltered, and `theHandOverCarriesTheCommandOutsideTheProse`
    /// pins that the prose half stays clean too.
    @Test("every refusal is a Chinese sentence, not a command line")
    func refusalsAreWrittenForTheWindow() {
        let refusals: [SelfUpdate.Route] = [
            SelfUpdate.route(cask: Self.notBrews,
                             location: .elsewhere(path: "/Users/x/Downloads/GitPic.app"),
                             bundleVersion: "0.18.0", latest: "0.19.0", asset: Self.choice),
            SelfUpdate.route(cask: Self.notBrews, location: .applicationsDir,
                             bundleVersion: nil, latest: "0.19.0", asset: Self.choice),
            SelfUpdate.route(cask: Self.notBrews, location: .applicationsDir,
                             bundleVersion: "0.18.0", latest: "not-a-version",
                             asset: Self.choice),
            SelfUpdate.route(cask: Self.notBrews, location: .applicationsDir,
                             bundleVersion: "0.19.0", latest: "0.19.0", asset: Self.choice),
        ]
        for route in refusals {
            guard case .unavailable(let shown, _) = route else {
                Issue.record("expected a refusal to check the wording of")
                return
            }
            #expect(shown.contains(where: { $0.unicodeScalars.first.map {
                (0x4E00...0x9FFF).contains($0.value)
            } == true }), "\(shown) is rendered in a Chinese-only sheet and has to be Chinese")
            #expect(!shown.contains("--"),
                    "\(shown) reads like a command line, and it is shown in a caption at 480 pt")
        }
    }

    /// **The one command string is carried, not narrated.** `refusalsAreWrittenForTheWindow` bans
    /// a command line from any `reason`, and the Homebrew branch has to respect that rather than
    /// be exempted from it: the flag lives in `command`, which the sheet draws as a monospaced
    /// selectable row, and `homebrewUnverified`'s `reason` — the only prose the branch mints —
    /// stays a Chinese sentence with no flag in it.
    ///
    /// `homebrewUpToDate` carries no command at all, which is the whole point of that case.
    @Test("the hand-over carries the command outside the prose")
    func theHandOverCarriesTheCommandOutsideTheProse() {
        let unverified = SelfUpdate.route(
            cask: .homebrews(cask: "gitpic", offers: .unknown(reason: "暂时读不到 Homebrew 提供的版本")),
            location: .applicationsDir, bundleVersion: "0.18.0", latest: "0.19.0",
            asset: Self.choice)
        guard case .homebrewUnverified(let command, let reason) = unverified else {
            Issue.record("expected the unverified hand-over")
            return
        }
        #expect(command.contains("--cask"), "the command is what the user has to run")
        #expect(!reason.contains("--"),
                "\(reason) is prose in a caption at 480 pt and may not read like a command")
        #expect(reason.contains(where: { $0.unicodeScalars.first.map {
            (0x4E00...0x9FFF).contains($0.value)
        } == true }), "\(reason) is rendered in a Chinese-only sheet and has to be Chinese")

        // Nothing else in the route mints a command, and `homebrewUpToDate` deliberately has
        // none: during the tap's lag `brew upgrade` would print "already installed" and exit 0.
        let upToDate = SelfUpdate.route(
            cask: Self.brews("0.18.0"), location: .applicationsDir,
            bundleVersion: "0.18.0", latest: "0.19.0", asset: Self.choice)
        #expect(upToDate == .homebrewUpToDate(installed: "0.18.0", offered: "0.18.0"))
    }

    /// The reasons **`route` itself writes**, which the check above cannot see.
    ///
    /// The row above hands `route` a `reason` and then asserts that string is Chinese and
    /// flag-free — which it is, because the test wrote it. That is a tautology, and it left the
    /// two captions `route` actually mints covered by nothing. Both are reached only when a
    /// version fails to parse, so neither has a natural call site to notice them.
    ///
    /// `verdict`'s own two are pinned in `CaskOwnershipTests.everyCaptionIsWrittenForTheWindow`;
    /// between them the four user-facing Homebrew strings in the codebase are all exercised.
    @Test("the captions the route writes are Chinese sentences, not command lines")
    func theRoutesOwnCaptionsAreWrittenForTheWindow() {
        let minted = [
            // The bundle's own version is unreadable.
            SelfUpdate.route(cask: Self.brews("0.19.0"), location: .applicationsDir,
                             bundleVersion: nil, latest: "0.19.0", asset: Self.choice),
            // The cask declares something that will not parse. Defensive rather than reachable
            // — both parsers refuse what they cannot compare — and a caveat is still the right
            // answer to an impossible string.
            SelfUpdate.route(cask: Self.brews("not-a-version"), location: .applicationsDir,
                             bundleVersion: "0.18.0", latest: "0.19.0", asset: Self.choice),
        ]
        for route in minted {
            guard case .homebrewUnverified(let command, let reason) = route else {
                Issue.record("expected an unverified hand-over, got \(route)")
                return
            }
            #expect(command == "brew upgrade --cask gitpic")
            #expect(!reason.isEmpty)
            #expect(!reason.contains("--"),
                    "\(reason) reads like a command line, and the command has its own row")
            #expect(reason.contains(where: { $0.unicodeScalars.first.map {
                (0x4E00...0x9FFF).contains($0.value)
            } == true }), "\(reason) is rendered in a Chinese-only sheet and has to be Chinese")
        }
    }

    /// The gate is the *bundle's* version, not the report's `current` — that one comes from
    /// the CLI, and this replaces the bundle. Equal or newer is not an update.
    @Test("the bundle's own version decides, and it must be older")
    func versionGate() {
        for mine in ["0.19.0", "0.20.0", "1.0.0"] {
            let route = SelfUpdate.route(
                cask: Self.notBrews,
                location: .applicationsDir, bundleVersion: mine, latest: "0.19.0",
                asset: Self.choice)
            guard case .unavailable(let reason, _) = route else {
                Issue.record("\(mine) is not older than 0.19.0 and must not be replaced")
                return
            }
            #expect(reason.contains(mine))
        }
        // And older is.
        guard case .selfInstall = SelfUpdate.route(
            cask: Self.notBrews,
            location: .applicationsDir, bundleVersion: "0.9.0", latest: "0.10.0",
            asset: Self.choice) else {
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
                cask: Self.notBrews,
                location: .applicationsDir, bundleVersion: mine, latest: "0.19.0",
                asset: Self.choice)
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
            cask: Self.notBrews,
            location: .applicationsDir, bundleVersion: "0.18.0", latest: "0.19.0",
            asset: .none(reason: "GitHub 没有报校验和"))
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
        // user-writable directory. This used to add "the app's own has a Homebrew prefix
        // prepended" as the motive; that was true of the deleted `upgradeAndRelaunch`, which had
        // to put brew's own directory on PATH for brew to re-exec itself. Nothing prepends
        // anything now — `ToolPaths.childPATH` is these four directories — so the reason is the
        // general one, which was always the stronger half.
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

    /// **A negative answer needs evidence that the probe actually ran**, and the exit status is
    /// not that evidence. The probe brackets `command -v <tool>` between two marks; what lies
    /// between them is the lookup's own output and nothing else.
    ///
    /// Every row below is stdout measured from a real `$SHELL -l -c` on this machine.
    ///
    /// The rows name `brew`, which this probe no longer looks for — its remaining caller is
    /// `locateGitpic`, for `swift run` during development. They are left as measured, the way
    /// `loginShellLookup`'s own doc leaves its `gh` measurements: the tool name is a parameter and
    /// the parse under test is unchanged, so re-labelling the evidence would only make it
    /// evidence of a run that never happened.
    @Test("only a bracketed empty answer means the tool is absent")
    func probeAnswerSeparatesAbsenceFromSilence() {
        let open = ToolDiscovery.probeOpen
        let close = ToolDiscovery.probeClose

        // zsh, brew absent: both marks, nothing between them. The one conclusive negative.
        #expect(ToolDiscovery.probeAnswer(in: "\(open)\n\(close)\n") == "")
        // zsh, brew present: the path is between them (and `commandVPath` takes it first).
        #expect(ToolDiscovery.probeAnswer(in: "\(open)\n/opt/homebrew/bin/brew\n\(close)\n")
                == "/opt/homebrew/bin/brew")
        // A shell function and an alias — measured, zsh prints these. Not a path, and *not*
        // absence: brew exists, it just cannot be spawned.
        #expect(ToolDiscovery.probeAnswer(in: "\(open)\nbrew\n\(close)\n") == "brew")
        #expect(ToolDiscovery.probeAnswer(in: "\(open)\nalias brew=/nowhere/brew\n\(close)\n")
                == "alias brew=/nowhere/brew")
        // tcsh and csh have no `command` builtin: measured, status 1 and stdout completely
        // empty. `.zprofile` with `exit 1` gives the same, and `exec /usr/bin/true` gives it
        // with status **0** — which is why the status cannot be the test.
        #expect(ToolDiscovery.probeAnswer(in: "") == nil)
        // A profile whose last write has no trailing newline glues the opening mark onto it —
        // measured verbatim, so the marks are searched as substrings, not as whole lines.
        #expect(ToolDiscovery.probeAnswer(in: "glued no newline\(open)\n\(close)\n") == "")
        // A profile-spawned job that flushes after the lookup lands *after* the closing mark,
        // so it cannot turn "no brew" into "cannot tell".
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

        // And a tool that exists nowhere must come back as a *definite* no, or `locateGitpic`
        // reports no CLI on a machine that has one. It used to matter more than that: the same
        // answer decided whether Homebrew owned the bundle, so a false "cannot tell" left a
        // brew-less machine retrying a probe instead of being offered the installer.
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
