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
}
