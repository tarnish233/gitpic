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
    private static let otherBrewPath = URL(fileURLWithPath: "/usr/local/bin/brew")
    private static let sha = String(repeating: "ab", count: 32)

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
        #expect(route == .selfInstall(asset: Self.dmg, sha256: Self.sha, version: "0.19.0"))
    }

    /// The user this whole feature exists for: no Homebrew at all.
    ///
    /// This is the row that the old single-`nil` brew lookup used to make unreachable — "no brew"
    /// and "the probe timed out" were the same answer, and both meant "ask again later", so
    /// the machine with no brew waited forever for a probe that was never going to say
    /// anything different.
    @Test("no brew on the machine is an answer, and it enables the installer")
    func noBrewAtAll() {
        // What `brewOwnership` folds a `.absent` location into: no brew, so nothing brew owns.
        #expect(SelfUpdate.fold([]) == .doesNotOwnIt)
        let route = SelfUpdate.route(
            location: .applicationsDir, bundleVersion: "0.18.0", latest: "0.19.0",
            brew: SelfUpdate.fold([]), asset: Self.choice)
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
        // Verbatim what `ToolDiscovery.brewCaskApp` now mints for its 20 s bound. It used to be
        // `"brew list --cask gitpic timed out"`, and this assertion used to pin that English on
        // it — which was wrong in both directions: the string is rendered by `UpdateSheet` as
        // `Text(reason)` in a Chinese-only window, and the command line that belongs in the log
        // was the only thing the window had to show. The diagnostic half goes to
        // `Diagnostics.log` now, and the sheet gets a sentence.
        let reason = "Homebrew 20 秒内没有回答这份 GitPic 是不是它装的"
        let route = SelfUpdate.route(
            location: .applicationsDir, bundleVersion: "0.18.0", latest: "0.19.0",
            brew: .unknown(reason: reason), asset: Self.choice)
        guard case .unavailable(let shown, let retryable) = route else {
            Issue.record("an unknown brew answer must not install anything")
            return
        }
        #expect(retryable, "a probe that got no answer must be asked again")
        #expect(shown == reason, "the sheet shows the reason it was given, verbatim")
        // No developer English reaches the window. Product names are fine — 「Homebrew」 and
        // 「GitPic」 are what the sheet calls them elsewhere — but a command line is not: no
        // option flags, no paths, and the sentence has to actually be in Chinese.
        #expect(shown.contains(where: { $0.unicodeScalars.first.map {
            (0x4E00...0x9FFF).contains($0.value)
        } == true }), "a reason rendered in a Chinese-only sheet has to be Chinese")
        #expect(!shown.contains("--") && !shown.contains("/"),
                "\(shown) reads like a command line, and it is shown in a caption at 480 pt")
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

    /// **The free question is asked first, and the expensive one is not asked at all.**
    ///
    /// `brew` is an `@autoclosure` for this row alone. Passed as a plain argument it was
    /// evaluated before `route` was entered, so a development build in `dist-app/` spawned a
    /// login shell and a `brew list --cask`, serialised on one queue, before the sheet could
    /// print a refusal a string comparison had already decided. Bounds of 8 s and 20 s, and
    /// 0.04 s + 0.42–0.81 s measured on a warm machine — either way, for nothing.
    @Test("a refusal the location decides never spawns Homebrew")
    func locationRefusalDoesNotAskBrew() {
        var asked = 0
        let route = SelfUpdate.route(
            location: .elsewhere(path: "/Users/x/src/gitpic/dist-app/GitPic.app"),
            bundleVersion: "0.18.0", latest: "0.19.0",
            brew: { asked += 1; return .doesNotOwnIt }(), asset: Self.choice)
        #expect(asked == 0, "the location answer is free; the brew answer costs up to 28 s")
        guard case .unavailable = route else {
            Issue.record("only an Applications directory may be installed into")
            return
        }

        // And it *is* asked when the location does not settle it, or nothing would ever be
        // routed to brew.
        var askedAgain = 0
        _ = SelfUpdate.route(
            location: .applicationsDir, bundleVersion: "0.18.0", latest: "0.19.0",
            brew: { askedAgain += 1; return .doesNotOwnIt }(), asset: Self.choice)
        #expect(askedAgain == 1)
    }

    /// The stated cost of asking the location first, pinned so it cannot be paid by accident.
    ///
    /// A cask installed with a custom `--appdir` — `~/Apps`, say — used to be offered
    /// `brew upgrade` because the brew question came first. It now goes to the release page,
    /// where the sheet's fallback line spells out `brew upgrade --cask gitpic`. That is the
    /// trade the ordering makes, and the doc comment on ``SelfUpdate/route`` states it.
    @Test("a cask installed outside the two Applications directories goes to the release page")
    func caskInACustomAppdirIsSentToTheReleasePage() {
        let route = SelfUpdate.route(
            location: .elsewhere(path: "/Users/x/Apps/GitPic.app"),
            bundleVersion: "0.18.0", latest: "0.19.0",
            brew: .ownsThisCask(brew: Self.brewPath), asset: Self.choice)
        guard case .unavailable(_, let retryable) = route else {
            Issue.record("the location rule is shared with the brew path, not looser for it")
            return
        }
        #expect(!retryable)
    }

    // MARK: - Folding what every brew said

    /// **Homebrew owning the bundle always wins, whichever brew says so.**
    ///
    /// The machine this exists for: two prefixes, and the cask installed by the one that is not
    /// checked first. `locateBrewOutcome()` prefers `/opt/homebrew/bin/brew`, which answers a
    /// perfectly truthful "I have nothing under that token" — and folding that straight into
    /// "not brew's" replaced a bundle `/usr/local/bin/brew` manages.
    @Test("any brew that owns this bundle settles it, whatever the others said")
    func foldPrefersTheOwner() {
        #expect(SelfUpdate.fold([.hasNothing, .ownsThisBundle(brew: Self.otherBrewPath)])
                == .ownsThisCask(brew: Self.otherBrewPath))
        // Even ahead of an unanswered brew: there is nothing an unknown answer could add to a
        // positive one.
        #expect(SelfUpdate.fold([.noAnswer(reason: "读不到"),
                                 .ownsThisBundle(brew: Self.brewPath)])
                == .ownsThisCask(brew: Self.brewPath))
        #expect(SelfUpdate.fold([.ownsAnotherBundle,
                                 .ownsThisBundle(brew: Self.brewPath)])
                == .ownsThisCask(brew: Self.brewPath))
    }

    /// **One brew that could not answer makes the whole answer unknown**, because that brew is
    /// exactly the one that could have been the owner.
    @Test("an unanswered brew is never outvoted into an install")
    func foldRefusesToGuessPastAnUnansweredBrew() {
        let reason = "Homebrew 没能说清这份 GitPic 是不是它装的"
        #expect(SelfUpdate.fold([.hasNothing, .noAnswer(reason: reason)])
                == .unknown(reason: reason))
        #expect(SelfUpdate.fold([.ownsAnotherBundle, .noAnswer(reason: reason)])
                == .unknown(reason: reason))
        #expect(SelfUpdate.fold([.noAnswer(reason: reason)]) == .unknown(reason: reason))
    }

    /// The only shape that may authorise replacing a bundle: every brew answered, and none of
    /// them installed this one.
    @Test("only a complete set of negative answers permits an install")
    func foldAllowsInstallOnlyWhenEveryBrewAnswered() {
        #expect(SelfUpdate.fold([.hasNothing]) == .doesNotOwnIt)
        #expect(SelfUpdate.fold([.hasNothing, .hasNothing]) == .doesNotOwnIt)
        // "brew installed the cask, as some *other* bundle" is equally definite — a copy in
        // `~/Applications` on a machine whose cask went to `/Applications`. Handing that to
        // brew upgrades the other bundle and reopens this one unchanged, forever.
        #expect(SelfUpdate.fold([.ownsAnotherBundle]) == .doesNotOwnIt)
        #expect(SelfUpdate.fold([.ownsAnotherBundle, .hasNothing]) == .doesNotOwnIt)
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

    // MARK: - Which bundle does brew own

    /// **The bug an end-to-end run caught, pinned.** `brew list --cask gitpic` exits 0 whenever
    /// the cask is installed *anywhere*, so a copy in `~/Applications` on a machine whose cask
    /// installed to `/Applications` was reported as brew's. It would then be handed to
    /// `brew upgrade`, brew would replace the *other* bundle, and the script would reopen this
    /// one — an old build, still reporting the same update available, with brew reporting
    /// nothing left to do. Repeatable forever.
    ///
    /// Homebrew answers exactly, and this is the shape it answers in: `brew list --cask` prints
    /// the Caskroom paths, one of which is a symlink to the installed bundle. Verbatim from a
    /// machine with the cask installed.
    @Test("brew owning the cask is not the same as brew owning this bundle")
    func brewOwnsOneBundleNotAnyBundle() {
        let listing = """
        /opt/homebrew/Caskroom/gitpic/.metadata/INSTALL_RECEIPT.json
        /opt/homebrew/Caskroom/gitpic/.metadata/config.json
        /opt/homebrew/Caskroom/gitpic/.metadata/0.19.0/20260824093614.436/Casks/gitpic.json
        /opt/homebrew/Caskroom/gitpic/0.19.0/GitPic.app
        """
        // The `.app` line is the one that matters, and it is not the first.
        let app = listing.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasSuffix(".app") }
        #expect(app == "/opt/homebrew/Caskroom/gitpic/0.19.0/GitPic.app",
                "the receipt JSON must not be mistaken for the artifact")

        // With the cask's bundle resolving to /Applications/GitPic.app, a copy in
        // ~/Applications is *not* brew's, so it must reach the in-app installer.
        let route = SelfUpdate.route(
            location: .applicationsDir, bundleVersion: "0.18.0", latest: "0.19.0",
            brew: .doesNotOwnIt, asset: Self.choice)
        guard case .selfInstall = route else {
            Issue.record("a copy brew did not install must not be handed to brew")
            return
        }
    }

    /// **Every non-zero exit is not "not mine", and exit 0 is not "mine either way".**
    ///
    /// Driven through a stub `brew` rather than the real one, because what has to be pinned is
    /// the decision, and Homebrew's answer depends on what happens to be installed on the
    /// machine running the tests. The stub's shapes are all transcribed from Homebrew 6.0.19,
    /// measured while writing this:
    ///
    /// ```
    /// $ brew list --cask firefox            # real cask, not installed
    /// find: /opt/homebrew/Caskroom/firefox: No such file or directory
    /// Error: Failure while executing; `… find …` exited with 1.        → status 1
    /// $ brew list --cask definitely-not-real-xyz
    /// Error: Cask 'definitely-not-real-xyz' is unavailable: No Cask with this name exists.
    ///                                                                  → status 1
    /// $ env -i brew list --cask gitpic
    /// Error: $HOME must be set to run brew.                            → status 1
    /// $ brew list --cask codex                                         → status 0, no .app
    /// $ brew list --cask font-maple-mono-nf-cn                         → status 0, no .app
    /// ```
    ///
    /// One exit code for three completely different situations, so the status cannot be the
    /// evidence. Nor can the message: with `Caskroom/gitpic-fixture-zzz/9.9.9/Fixture.app`
    /// created by hand, `brew list --cask gitpic-fixture-zzz` *still* said `No Cask with this
    /// name exists` — which is what a removed tap looks like on a machine where the cask is
    /// installed. The Caskroom directory is the only thing that answers, and `brew --caskroom`
    /// is what names it.
    @Test("only a Caskroom with nothing in it makes a failed `brew list` an answer")
    func failedBrewListIsOnlyAnAnswerWithAnEmptyCaskroom() throws {
        let fixture = try BrewStub()
        defer { fixture.cleanUp() }

        // 1. brew failed *and* it has installed nothing under this token. The one shape that
        //    may authorise replacing a bundle.
        fixture.write(status: 1, stderr: "Error: Cask 'gitpic' is unavailable: "
                      + "No Cask with this name exists.")
        #expect(ToolDiscovery.brewCaskApp("gitpic", brew: fixture.brew)
                == .notInstalled(status: 1))

        // 2. Same failure, but the Caskroom holds the token — a removed tap, a broken
        //    portable-ruby, a lock held by another brew. Installing here replaces a bundle brew
        //    manages and leaves its manifest describing a version that is not on disk.
        try fixture.populateCaskroom("gitpic")
        guard case .unusable = ToolDiscovery.brewCaskApp("gitpic", brew: fixture.brew) else {
            Issue.record("a failed brew with a populated Caskroom must not authorise an install")
            return
        }

        // 3. brew is broken enough that it cannot even say where its Caskroom is — measured:
        //    `env -i brew list --cask gitpic` exits 1 with `$HOME must be set to run brew.`
        fixture.write(status: 1, stderr: "Error: $HOME must be set to run brew.",
                      answerCaskroom: false)
        guard case .unusable = ToolDiscovery.brewCaskApp("gitpic", brew: fixture.brew) else {
            Issue.record("a brew that cannot answer at all is not evidence of anything")
            return
        }
    }

    /// Exit 0 with no bundle named is "brew has this cask and I cannot see which app it is",
    /// which is the definition of no answer — not of a durable fact.
    ///
    /// It used to be `notInstalled(status: 0)`, with a comment admitting "nothing here can be
    /// compared against". Measured shapes that produce it today: `brew list --cask codex` and
    /// `brew list --cask font-maple-mono-nf-cn`, both exit 0 with zero `.app` lines. A future
    /// `==> Apps` header, a ` (128 files)` suffix, or an appdir path instead of the Caskroom
    /// symlink would do the same.
    @Test("exit 0 with no identifiable bundle is no answer, not `notInstalled`")
    func exitZeroWithoutABundleIsUnusable() throws {
        let fixture = try BrewStub()
        defer { fixture.cleanUp() }

        fixture.write(status: 0, stdout: """
            /opt/homebrew/Caskroom/codex/.metadata/INSTALL_RECEIPT.json
            /opt/homebrew/Caskroom/codex/.metadata/config.json
            """)
        guard case .unusable = ToolDiscovery.brewCaskApp("gitpic", brew: fixture.brew) else {
            Issue.record("brew exited 0, so it has the cask — that cannot mean 'not installed'")
            return
        }
        // And the degenerate case: exit 0, nothing at all on stdout.
        fixture.write(status: 0)
        guard case .unusable = ToolDiscovery.brewCaskApp("gitpic", brew: fixture.brew) else {
            Issue.record("silence from a successful brew is not an answer either")
            return
        }
    }

    /// A dangling `.app` line must not be read as a path, and must not hide a good one.
    ///
    /// Measured: `URL.resolvingSymlinksInPath()` returns a **dangling** symlink *unchanged*, so
    /// `/opt/homebrew/Caskroom/gitpic/0.18.0/GitPic.app` pointing at a bundle somebody moved by
    /// hand came back as itself, compared unequal to the running bundle, and produced
    /// "not brew's" → an install over a cask-managed app. And with two version directories in
    /// the Caskroom, `first(where:)` could pick exactly that one.
    @Test("dangling Caskroom symlinks are dropped, and never hide a live one")
    func danglingCaskroomLinksAreDropped() throws {
        let fixture = try BrewStub()
        defer { fixture.cleanUp() }

        let real = fixture.root.appendingPathComponent("Applications/GitPic.app")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let live = fixture.root.appendingPathComponent("Caskroom/gitpic/0.19.0/GitPic.app")
        let dead = fixture.root.appendingPathComponent("Caskroom/gitpic/0.18.0/GitPic.app")
        for link in [live, dead] {
            try FileManager.default.createDirectory(
                at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try FileManager.default.createSymbolicLink(at: live, withDestinationURL: real)
        try FileManager.default.createSymbolicLink(
            at: dead, withDestinationURL: fixture.root.appendingPathComponent("gone/GitPic.app"))
        // The premise, measured rather than assumed.
        #expect(dead.resolvingSymlinksInPath().standardizedFileURL.path == dead.path,
                "resolvingSymlinksInPath leaves a dangling symlink alone")

        // Older version first, so `first(where:)` would have picked the dangling one.
        fixture.write(status: 0, stdout: "\(dead.path)\n\(live.path)")
        // Compared as paths, the way `brewOwnership` compares them: `resolvingSymlinksInPath`
        // appends a trailing slash for an existing directory and `URL`'s `==` minds that, while
        // `.path` — which is what the ownership check uses — does not.
        guard case .installedAt(let apps) = ToolDiscovery.brewCaskApp("gitpic",
                                                                     brew: fixture.brew) else {
            Issue.record("the live Caskroom link names a bundle that exists")
            return
        }
        #expect(apps.map(\.path) == [real.path])

        // Nothing but a dangling link is no answer at all — brew has the cask and its bundle is
        // not where it said.
        fixture.write(status: 0, stdout: dead.path)
        guard case .unusable = ToolDiscovery.brewCaskApp("gitpic", brew: fixture.brew) else {
            Issue.record("a Caskroom link pointing nowhere identifies no bundle")
            return
        }
    }

    /// A stub `brew` on disk, so the decisions above are tested without depending on what this
    /// machine happens to have installed.
    ///
    /// A shell script rather than a mock, because `ToolDiscovery.brewCaskApp` spawns a real
    /// child through `ChildProcess` and that spawn is part of what is being tested — the
    /// argument list, the two streams, and the exit status.
    private final class BrewStub {
        let root: URL
        let brew: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("gitpic-brewstub-\(UUID().uuidString)")
            brew = root.appendingPathComponent("brew")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            write(status: 1)
        }

        /// `<root>/Caskroom/<cask>/1.0`, which is what makes a failed `brew list` inconclusive.
        func populateCaskroom(_ cask: String) throws {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("Caskroom/\(cask)/1.0"),
                withIntermediateDirectories: true)
        }

        /// Rewrite the stub. `answerCaskroom: false` makes `brew --caskroom` fail too, which is
        /// the broken-environment case.
        func write(status: Int32, stdout: String = "", stderr: String = "",
                   answerCaskroom: Bool = true) {
            func q(_ s: String) -> String {
                "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
            }
            let caskroom = answerCaskroom
                ? "printf '%s\\n' \(q(root.appendingPathComponent("Caskroom").path)); exit 0"
                : "echo 'Error: $HOME must be set to run brew.' >&2; exit 1"
            let script = """
            #!/bin/bash
            if [ "$1" = "--caskroom" ]; then
              \(caskroom)
            fi
            printf '%s' \(q(stdout))
            printf '%s' \(q(stderr)) >&2
            exit \(status)
            """
            try? script.write(to: brew, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: brew.path)
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: - Proving the login shell ran

    /// **A negative answer needs evidence that the probe actually ran**, and the exit status is
    /// not that evidence. The probe brackets `command -v <tool>` between two marks; what lies
    /// between them is the lookup's own output and nothing else.
    ///
    /// Every row below is stdout measured from a real `$SHELL -l -c` on this machine.
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

        // And a tool that exists nowhere must come back as a *definite* no, or the machine with
        // no Homebrew never gets offered the installer this whole feature exists for.
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
