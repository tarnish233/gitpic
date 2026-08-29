import Foundation
import Testing

@testable import GitPicCore

@Suite("Homebrew ownership")
struct CaskOwnershipTests {

    /// **The link is the evidence, and it has to resolve to *this* bundle.**
    ///
    /// The deleted implementation asked `brew list --cask gitpic`, which answers about the
    /// machine: it is true whenever a cask is installed anywhere, including when the copy asking
    /// is a different one at a different path. This asks about the bundle, so a machine that has
    /// the cask *and* a second GitPic somewhere else gets the right answer for each.
    @Test("a Caskroom link resolving to this bundle is what makes it Homebrew's")
    func aCaskroomLinkIsTheEvidence() throws {
        let f = try HomebrewShape.bundle()
        defer { try? FileManager.default.removeItem(at: f.root) }

        // Before the link exists, the same bundle at the same path is nobody's cask.
        let prefix = f.root.appendingPathComponent("homebrew")
        #expect(CaskOwnership.detect(bundle: f.bundle, prefixes: [prefix]) == nil)

        let layout = try HomebrewShape.install(bundle: f.bundle, under: f.root, version: "0.20.9")
        let found = CaskOwnership.detect(bundle: f.bundle, prefixes: [layout.prefix])
        #expect(found == CaskOwnership.Install(cask: "gitpic", prefix: layout.prefix))
    }

    /// A cask installed elsewhere is not evidence about us. This is the case
    /// `brew list --cask` could not distinguish, and getting it wrong would tell someone with a
    /// hand-installed GitPic to run a command that upgrades a different copy.
    @Test("a Caskroom link pointing at some other bundle is not evidence")
    func anotherBundlesLinkIsNotOurs() throws {
        let f = try HomebrewShape.bundle()
        defer { try? FileManager.default.removeItem(at: f.root) }

        let other = f.root.appendingPathComponent("Applications/Other.app")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let layout = try HomebrewShape.install(bundle: other, under: f.root, version: "0.20.9")

        #expect(CaskOwnership.detect(bundle: f.bundle, prefixes: [layout.prefix]) == nil)
    }

    /// A Caskroom entry left behind after the bundle was deleted by hand. `fileExists` follows
    /// the link, so a dangling one is skipped rather than resolved to a path that is not there —
    /// and *not* treated as ownership, because `brew upgrade` on it would be reinstalling rather
    /// than upgrading anything this app is running from.
    @Test("a dangling Caskroom link is not ownership")
    func aDanglingLinkIsNotOwnership() throws {
        let f = try HomebrewShape.bundle()
        defer { try? FileManager.default.removeItem(at: f.root) }

        let layout = try HomebrewShape.install(bundle: f.bundle, under: f.root, version: "0.20.9")
        try FileManager.default.removeItem(at: f.bundle)

        #expect(CaskOwnership.detect(bundle: f.bundle, prefixes: [layout.prefix]) == nil)
    }

    /// Both prefixes are searched, and the one that answered travels back with the answer.
    ///
    /// An Intel and an Apple Silicon Homebrew are independent installations with independent
    /// Caskrooms and independent tap clones — so a machine with both must not have its cask found
    /// under one prefix and its tap version read from under the other.
    @Test("either Homebrew prefix can be the one that owns it, and it says which")
    func eitherPrefixCanOwnIt() throws {
        let f = try HomebrewShape.bundle()
        defer { try? FileManager.default.removeItem(at: f.root) }

        let second = try HomebrewShape.install(
            bundle: f.bundle, under: f.root, version: "0.20.9", prefixName: "usr-local")
        let empty = f.root.appendingPathComponent("empty-prefix")
        let found = CaskOwnership.detect(bundle: f.bundle, prefixes: [empty, second.prefix])
        #expect(found?.prefix == second.prefix)
    }

    /// **Ownership does not depend on where the bundle lives**, which is the whole reason this
    /// reads the link rather than the bundle's own path. `brew install --appdir` puts a cask
    /// anywhere the user likes, and `SelfUpdate.location(of:)` calls anything outside the two
    /// Applications directories `.elsewhere` — so a cask at a custom appdir is exactly the case
    /// that used to reach a dead-end refusal when `brew upgrade --cask gitpic` was correct and
    /// safe for it.
    @Test("a cask at a custom appdir is still the cask's")
    func aCustomAppdirIsStillTheCasks() throws {
        for appDir in ["Applications", "Apps", "Users/x/Applications"] {
            let f = try HomebrewShape.bundle(named: appDir)
            defer { try? FileManager.default.removeItem(at: f.root) }

            let layout = try HomebrewShape.install(
                bundle: f.bundle, under: f.root, version: "0.20.9")
            #expect(CaskOwnership.detect(bundle: f.bundle, prefixes: [layout.prefix]) != nil,
                    "a cask installed at \(appDir) is still a cask")
        }
    }

    // MARK: - What the tap offers

    /// The clone Homebrew already keeps, read under the prefix that owned the bundle.
    @Test("the tap's own clone is where the offered version comes from")
    func theLocalCloneAnswers() throws {
        let f = try HomebrewShape.bundle()
        defer { try? FileManager.default.removeItem(at: f.root) }

        let layout = try HomebrewShape.install(bundle: f.bundle, under: f.root, version: "0.20.9")
        // No clone yet: `nil` means "ask something authoritative", not "up to date".
        #expect(CaskOwnership.localTapVersion(prefix: layout.prefix) == nil)

        try HomebrewShape.tapClone(under: layout.prefix, declaring: "0.20.10")
        #expect(CaskOwnership.localTapVersion(prefix: layout.prefix) == "0.20.10")
    }

    /// **The parse refuses more than it accepts, and the refusals are the point.**
    ///
    /// These rows mirror `release.rs`'s `a_cask_version_is_read_only_when_it_is_plainly_comparable`
    /// one for one, because the two parsers have to agree: the app reads the local clone with
    /// this one and the network copy with that one, and a version accepted by one and refused by
    /// the other would make the answer depend on which path happened to be taken.
    ///
    /// `version "1.2,345"` is the row that matters most. It is a real Homebrew spelling
    /// (`Cask#version.csv`) and reading it as a version would let the sheet claim
    /// 「已是 Homebrew 提供的最新版本」 over a pending upgrade.
    @Test("a cask version is read only when it is plainly comparable")
    func onlyAComparableVersionIsRead() {
        #expect(CaskOwnership.declaredVersion(in: "cask \"gitpic\" do\n  version \"0.20.9\"\n")
                == "0.20.9")
        #expect(CaskOwnership.declaredVersion(
            in: "# the version below is rewritten by the tap\n  version \"1.2.3\"\nend") == "1.2.3")
        for refused in [
            "  version \"1.2,345\"\n",      // csv — two fields, not a version
            "  version :latest\n",          // a symbol, not a literal
            "  version \"#{ENV['V']}\"\n",  // interpolated
            "  version \"0.20\"\n",         // not three components
            "  version \"0.20.0-rc1\"\n",   // prerelease, which `Version` refuses
            "cask \"gitpic\" do\nend\n",    // no stanza at all
            "",
        ] {
            #expect(CaskOwnership.declaredVersion(in: refused) == nil,
                    "\(refused) is not something to compare a bundle against")
        }
    }

    // MARK: - The whole question, in the order that costs least

    /// Counts calls across an isolation boundary without pulling an actor into the test.
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    private static func tap(_ version: String?) -> TapCask {
        TapCask(ok: true, cask: "gitpic", version: version)
    }

    /// A bundle no cask owns costs nothing at all — in particular it does **not** spend the
    /// request. Almost every GitPic is this case, and it runs on the sheet-open path.
    @Test("a bundle no cask owns never reaches the network")
    func nothingIsSpentOnANonCask() async throws {
        let f = try HomebrewShape.bundle()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let calls = Calls()

        let verdict = await CaskOwnership.verdict(
            bundle: f.bundle, prefixes: [f.root.appendingPathComponent("homebrew")],
            bundleVersion: "0.18.0",
            askTap: { calls.bump(); return Self.tap("0.19.0") })

        #expect(verdict == .notHomebrews)
        #expect(calls.count == 0, "a bundle Homebrew does not own must not cost a request")
    }

    /// **The local clone short-circuits, and only in the direction where it can be trusted.**
    ///
    /// The clone is a lower bound: `brew upgrade` auto-updates before it resolves, so if the
    /// clone already names something newer than the bundle, brew will certainly find at least
    /// that — the answer is settled and no request is needed. This is the common case on a
    /// machine that runs `brew update` regularly, which is most of them.
    @Test("a local clone that already proves an upgrade skips the request")
    func aLocalCloneAheadSettlesItForFree() async throws {
        let f = try HomebrewShape.bundle()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let layout = try HomebrewShape.install(bundle: f.bundle, under: f.root, version: "0.18.0")
        try HomebrewShape.tapClone(under: layout.prefix, declaring: "0.19.0")
        let calls = Calls()

        let verdict = await CaskOwnership.verdict(
            bundle: f.bundle, prefixes: [layout.prefix], bundleVersion: "0.18.0",
            askTap: { calls.bump(); return Self.tap("0.20.0") })

        #expect(verdict == .homebrews(cask: "gitpic", offers: .version("0.19.0")))
        #expect(calls.count == 0, "the clone already proved an upgrade exists")
    }

    /// **And in the other direction it is not trusted at all**, which is the half that makes the
    /// request worth keeping. A clone saying "nothing newer" is indistinguishable from a clone
    /// nobody has updated in a week, so the authoritative answer is fetched — and it wins.
    @Test("a local clone with nothing newer is not believed, it is checked")
    func aStaleCloneIsCheckedRatherThanBelieved() async throws {
        let f = try HomebrewShape.bundle()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let layout = try HomebrewShape.install(bundle: f.bundle, under: f.root, version: "0.18.0")
        try HomebrewShape.tapClone(under: layout.prefix, declaring: "0.18.0")
        let calls = Calls()

        let verdict = await CaskOwnership.verdict(
            bundle: f.bundle, prefixes: [layout.prefix], bundleVersion: "0.18.0",
            askTap: { calls.bump(); return Self.tap("0.19.0") })

        #expect(verdict == .homebrews(cask: "gitpic", offers: .version("0.19.0")))
        #expect(calls.count == 1, "a clone that cannot prove an upgrade has to be checked")
    }

    /// A missing clone is the same "cannot prove it" as a stale one, not an error.
    @Test("no local clone means ask, not fail")
    func aMissingCloneAsks() async throws {
        let f = try HomebrewShape.bundle()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let layout = try HomebrewShape.install(bundle: f.bundle, under: f.root, version: "0.18.0")

        let verdict = await CaskOwnership.verdict(
            bundle: f.bundle, prefixes: [layout.prefix], bundleVersion: "0.18.0",
            askTap: { Self.tap("0.19.0") })

        #expect(verdict == .homebrews(cask: "gitpic", offers: .version("0.19.0")))
    }

    /// **A failure is never a refusal.** Both ways the answer can be missing — the lookup threw,
    /// or it succeeded and the cask declares nothing comparable — become `Offer.unknown`, which
    /// the route turns into the command plus a caveat. A brew user whose network is down still
    /// gets something to run; their upgrade path is fine and the app has no business implying
    /// otherwise. This is Claude Code's behaviour in the same spot.
    @Test("a lookup that fails or says nothing still leaves the user a command")
    func failureBecomesUnknownAndNotARefusal() async throws {
        let f = try HomebrewShape.bundle()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let layout = try HomebrewShape.install(bundle: f.bundle, under: f.root, version: "0.18.0")

        struct Boom: Error {}
        let threw = await CaskOwnership.verdict(
            bundle: f.bundle, prefixes: [layout.prefix], bundleVersion: "0.18.0",
            askTap: { throw Boom() })
        guard case .homebrews(_, .unknown(let thrownReason)) = threw else {
            Issue.record("a failed lookup must still be a Homebrew answer")
            return
        }
        #expect(!thrownReason.isEmpty)

        let saidNothing = await CaskOwnership.verdict(
            bundle: f.bundle, prefixes: [layout.prefix], bundleVersion: "0.18.0",
            askTap: { Self.tap(nil) })
        guard case .homebrews(_, .unknown) = saidNothing else {
            Issue.record("a cask with no comparable version must be `unknown`")
            return
        }
    }

    /// An unreadable bundle version cannot short-circuit on the clone — there is nothing to
    /// compare it against — so the lookup happens and the route decides what to do about it.
    @Test("an unreadable bundle version does not skip the check")
    func anUnreadableBundleVersionStillAsks() async throws {
        let f = try HomebrewShape.bundle()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let layout = try HomebrewShape.install(bundle: f.bundle, under: f.root, version: "0.18.0")
        try HomebrewShape.tapClone(under: layout.prefix, declaring: "0.19.0")
        let calls = Calls()

        let verdict = await CaskOwnership.verdict(
            bundle: f.bundle, prefixes: [layout.prefix], bundleVersion: nil,
            askTap: { calls.bump(); return Self.tap("0.19.0") })

        #expect(verdict == .homebrews(cask: "gitpic", offers: .version("0.19.0")))
        #expect(calls.count == 1, "with no bundle version the clone proves nothing")
    }

    /// **Taps hang off `HOMEBREW_REPOSITORY`, which is not the prefix on an Intel install.**
    ///
    /// Read out of Homebrew's own `bin/brew`: the repository starts equal to the prefix, is
    /// re-derived from the `bin/brew` symlink target when there is one, and an x86_64 install
    /// then forces the prefix back to `/usr/local`. So on Apple Silicon everything is under
    /// `/opt/homebrew`, while on Intel the Caskroom is `/usr/local/Caskroom` and the tap clone is
    /// `/usr/local/Homebrew/Library/Taps`.
    ///
    /// Reading only `<prefix>/Library/Taps` therefore found nothing on any Intel Mac, and the
    /// failure was invisible: `detect` still worked, so ownership was right and only the free
    /// short-circuit was dead — every sheet paid for a request the clone on disk could have
    /// answered, and an Intel user whose network was down was told 「暂时读不到」 while the
    /// answer sat in a file. The fixture could not have caught it either, because it wrote the
    /// Apple Silicon layout by construction.
    @Test("the tap clone is found under either Homebrew repository layout")
    func theTapCloneIsFoundOnIntelToo() async throws {
        for repositorySubpath in [nil, "Homebrew"] {
            let f = try HomebrewShape.bundle()
            defer { try? FileManager.default.removeItem(at: f.root) }
            let layout = try HomebrewShape.install(
                bundle: f.bundle, under: f.root, version: "0.18.0")
            try HomebrewShape.tapClone(under: layout.prefix, declaring: "0.19.0",
                                       repositorySubpath: repositorySubpath)

            let where_ = repositorySubpath ?? "<prefix>"
            #expect(CaskOwnership.localTapVersion(prefix: layout.prefix) == "0.19.0",
                    "a clone under \(where_)/Library/Taps has to be read")

            // And the whole point of reading it: the request is not spent.
            let calls = Calls()
            let verdict = await CaskOwnership.verdict(
                bundle: f.bundle, prefixes: [layout.prefix], bundleVersion: "0.18.0",
                askTap: { calls.bump(); return Self.tap("0.19.0") })
            #expect(verdict == .homebrews(cask: "gitpic", offers: .version("0.19.0")))
            #expect(calls.count == 0, "the clone already proved 0.19.0 is newer")
        }
    }

    /// A CRLF clone parses, which it did not.
    ///
    /// `"\r\n"` is a single Swift `Character` and is not equal to `"\n"`, so
    /// `split(separator: "\n")` returned the entire file as one piece — measured, one piece
    /// against `str::lines()`'s three on the same bytes. The line never began with `version `,
    /// the parser returned nil, and the doc's claim to follow "the same rules as `release.rs`'s
    /// `cask_version`" was false for any clone checked out with `core.autocrlf` set or a
    /// `.gitattributes` asking for CRLF.
    @Test("a cask with Windows line endings parses the same as one without")
    func aCrlfCaskParses() throws {
        for ending in ["\n", "\r\n", "\r"] {
            let f = try HomebrewShape.bundle()
            defer { try? FileManager.default.removeItem(at: f.root) }
            let layout = try HomebrewShape.install(
                bundle: f.bundle, under: f.root, version: "0.18.0")
            try HomebrewShape.tapClone(under: layout.prefix, declaring: "0.19.0",
                                       lineEnding: ending)
            #expect(CaskOwnership.localTapVersion(prefix: layout.prefix) == "0.19.0",
                    "line ending \(ending.debugDescription) must not change the answer")
        }
    }

    /// The captions **`verdict` itself writes**, as opposed to the ones a test hands it.
    ///
    /// Both are shown in a caption at 480 pt in a Chinese-only sheet, and neither may read like
    /// a command — the command has its own monospaced row. `route`'s two are pinned by
    /// `SelfUpdateRouteTests.theRoutesOwnCaptionsAreWrittenForTheWindow`; these are the other
    /// two, and between them that is every user-facing Homebrew string in the codebase.
    @Test("the captions the verdict writes are Chinese sentences, not command lines")
    func everyCaptionIsWrittenForTheWindow() async throws {
        let f = try HomebrewShape.bundle()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let layout = try HomebrewShape.install(bundle: f.bundle, under: f.root, version: "0.18.0")

        func caption(
            _ askTap: @escaping @Sendable () async throws -> TapCask
        ) async -> String? {
            let verdict = await CaskOwnership.verdict(
                bundle: f.bundle, prefixes: [layout.prefix], bundleVersion: "0.18.0",
                askTap: askTap)
            guard case .homebrews(_, .unknown(let reason)) = verdict else { return nil }
            return reason
        }

        // The lookup failed outright, and the cask was read but declares nothing comparable.
        let failed = await caption { throw RunFailure.spawnFailed("gitpic 还没准备好") }
        let saidNothing = await caption { Self.tap(nil) }
        guard let failed, let saidNothing else {
            Issue.record("both cases have to reach `unknown`")
            return
        }
        #expect(failed != saidNothing,
                "a read that failed and a cask that says nothing are different facts")
        for reason in [failed, saidNothing] {
            #expect(!reason.isEmpty)
            #expect(!reason.contains("--"),
                    "\(reason) reads like a command line, and the command has its own row")
            #expect(!reason.contains("brew upgrade"), "\(reason) names the command inside prose")
            #expect(reason.contains(where: { $0.unicodeScalars.first.map {
                (0x4E00...0x9FFF).contains($0.value)
            } == true }), "\(reason) is rendered in a Chinese-only sheet and has to be Chinese")
        }
    }

    /// The Swift/Rust wire shape, decoded from the bytes rather than built by hand.
    ///
    /// Every other row in this suite constructs `TapCask` through its memberwise initialiser,
    /// which exercises none of the decoding — so renaming `ok`, `cask` or `version` on either
    /// side, or adding `CodingKeys`, left both suites green while every Homebrew user silently
    /// got the caveat instead of the real answer. `UpdateReport` has four decode tests over
    /// canned JSON for exactly this reason; this is `TapCask`'s.
    @Test("the wire shape is a contract")
    func theWireShapeIsAContract() throws {
        let full = Data(#"{"ok":true,"cask":"gitpic","version":"0.20.9"}"#.utf8)
        let decoded = try JSONDecoder().decode(TapCask.self, from: full)
        #expect(decoded == TapCask(ok: true, cask: "gitpic", version: "0.20.9"))

        // A cask that was read and declares nothing comparable: `version` is absent, not empty.
        // `release.rs` skips the field entirely when it is `None`, so the absent form is the one
        // that actually arrives.
        let nothing = try JSONDecoder().decode(
            TapCask.self, from: Data(#"{"ok":true,"cask":"gitpic"}"#.utf8))
        #expect(nothing.version == nil)
        #expect(nothing.ok)

        // `ok` and `cask` are not optional, so a reply missing either is a contract break and
        // has to fail loudly rather than decode into a default.
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(TapCask.self, from: Data(#"{"cask":"gitpic"}"#.utf8))
        }
    }

    /// The path a user-facing version is read from is built from pinned constants.
    ///
    /// `CaskOwnership`'s doc claimed a counterpart to `release.rs`'s
    /// `the_release_feed_is_a_compile_time_constant` already existed here. It did not — the three
    /// constants that build the tap path were pinned only incidentally, by a raw string literal
    /// inside the test fixture, so changing one of them here would have left the fixture agreeing
    /// with the mistake. Same argument as the Rust side: a version read out of the wrong file
    /// gets shown next to a command the user is told to run.
    @Test("the tap path is built from pinned constants")
    func theTapPathIsBuiltFromPinnedConstants() {
        #expect(CaskOwnership.cask == "gitpic")
        #expect(CaskOwnership.tapOwner == "tarnish233")
        #expect(CaskOwnership.tapRepository == "homebrew-tap")
    }
}
