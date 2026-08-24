import Foundation

/// Putting a verified disk image in place of the running bundle.
///
/// **Why this is a detached script and not code in this process.** The thing being replaced
/// is the bundle this code is executing from, so the work has to outlive the app. Measured
/// rather than assumed: renaming a running executable's directory away and putting a new one
/// at the old path got the process `Killed: 9`. So the app quits first, and a script that
/// nothing else depends on does two renames.
///
/// **What is different from the Homebrew path, and why it is safer.** `Updater` hands brew a
/// script that then goes to the network, so a stall there costs the user the whole app — which
/// is what its 900 s watchdog exists for. Here the download, the verification, the mount and
/// the copy have all already happened while the app was alive, cancellable, and able to show
/// an error. What is left after the app quits is two same-directory renames and an `open`:
/// local, fast, and rollback-able. The irreversible window shrinks from "however long a
/// download takes" to "between two renames".
extension SelfUpdate {

    /// Which upgrade this install can be offered, if any.
    public enum Route: Equatable, Sendable {
        /// Homebrew owns this bundle. It stays the installer — see ``route``.
        case homebrew(brew: URL)
        /// Nothing else owns the bundle and there is a verifiable image to install.
        ///
        /// `version` travels with the asset because both come out of one report and the
        /// install has to agree with itself. Read separately — the asset from a route the sheet
        /// is holding, the version from `AppModel.update` at click time — a check landing in
        /// between made a download verify against 0.20.0's digest and then die at `stage`'s
        /// version gate with 「映像里是 0.20.0，不是预期的 0.21.0」, which reads like a tampered
        /// release rather than a stale sheet.
        case selfInstall(asset: ReleaseAsset, sha256: String, version: String)
        /// Neither. `reason` is user-facing and therefore **Chinese**; `retryable` is whether
        /// asking again could change the answer, which is what stops a one-off probe failure
        /// being cached for the life of the process.
        ///
        /// `retryable` means "asking the machine again could answer differently" — a fact about
        /// *this install*, not about the release. Every refusal computed from the report is
        /// therefore `retryable: false` and relies on the caller dropping the whole route when
        /// the report changes; see `AppModel.resolveUpgradePath`.
        case unavailable(reason: String, retryable: Bool)
    }

    /// What Homebrew has to say about this bundle.
    ///
    /// Collapsed to three cases by ``brewOwnership(cask:bundle:)`` before it reaches ``route``,
    /// so the decision itself is a pure function over facts rather than a thing that spawns
    /// processes — which is what makes the table below testable at all.
    public enum BrewOwnership: Equatable, Sendable {
        /// brew is here and manages this cask, as this very bundle.
        case ownsThisCask(brew: URL)
        /// Definitively not brew's: every brew on the machine answered "I have nothing under
        /// that token" or "I installed some other bundle", or there is no brew at all. A
        /// durable fact.
        case doesNotOwnIt
        /// No answer. `reason` is user-facing Chinese. Must not be acted on and must not be
        /// cached.
        case unknown(reason: String)
    }

    /// What one `brew` said about one bundle.
    ///
    /// Gathered by ``brewOwnership(cask:bundle:)`` and reduced by ``fold(_:)``, split that way
    /// so the reduction — which is where the safety rule lives — is testable without spawning
    /// Homebrew.
    public enum BrewVerdict: Equatable, Sendable {
        /// This brew manages the cask, and one of the bundles it lists is the running one.
        case ownsThisBundle(brew: URL)
        /// This brew manages the cask, but as some other bundle. A drag-installed copy in
        /// `~/Applications` on a machine whose cask went to `/Applications`.
        case ownsAnotherBundle
        /// This brew has installed nothing under this token.
        case hasNothing
        /// This brew gave no usable answer.
        case noAnswer(reason: String)
    }

    /// Reduce what every `brew` on the machine said to one answer.
    ///
    /// **Homebrew owning the bundle always wins, and "I could not get an answer" is never an
    /// install.** Both halves matter and the order encodes them:
    ///
    /// 1. Any brew that says it installed *this* bundle settles it. On a machine with two
    ///    prefixes the cask may have been installed by either, and this is what stops
    ///    `/opt/homebrew/bin/brew`'s "not mine" from overruling `/usr/local/bin/brew`'s "mine".
    /// 2. Otherwise a single unanswered brew makes the whole answer unknown, because that brew
    ///    is exactly the one that could have been the owner. Replacing a bundle brew manages
    ///    leaves the cask manifest describing a version that is not on disk.
    /// 3. Only when every brew answered, and none of them owns this bundle, is this bundle
    ///    definitively not brew's.
    ///
    /// An empty list is `doesNotOwnIt`: no brew means nothing brew installed. That case is the
    /// user this whole feature exists for, and it is only reached when
    /// ``ToolDiscovery/locateBrewOutcome()`` positively established absence.
    public static func fold(_ verdicts: [BrewVerdict]) -> BrewOwnership {
        for case .ownsThisBundle(let brew) in verdicts { return .ownsThisCask(brew: brew) }
        for case .noAnswer(let reason) in verdicts { return .unknown(reason: reason) }
        return .doesNotOwnIt
    }

    /// Whether the running bundle sits somewhere an update may be installed.
    public enum BundleLocation: Equatable, Sendable {
        /// `/Applications` or `~/Applications`.
        case applicationsDir
        case elsewhere(path: String)
    }

    /// Decide how — or whether — to upgrade.
    ///
    /// **Homebrew wins whenever it owns the bundle**, and that is the surviving half of the
    /// argument this file's predecessor made against self-update at all: replacing a
    /// cask-managed bundle behind brew's back leaves its manifest describing a version that
    /// is no longer on disk, and the next `brew upgrade` fights it. So the in-app installer
    /// is not an alternative to brew, it is what happens when brew is not the owner.
    ///
    /// **An unknown answer is never treated as "not brew's".** A probe that timed out could
    /// be hiding a working Homebrew, and installing over a cask on that guess is precisely
    /// the damage the paragraph above describes.
    ///
    /// **The location rule is shared with the brew path** rather than being a second, looser
    /// test, and it is asked *first* because it is the only question here that is free. `brew`
    /// is an `@autoclosure` for exactly that reason: passed as a plain argument it was evaluated
    /// before this function was entered, so a development build in `dist-app/` — or any copy
    /// outside the two Applications directories — spawned a login shell and a `brew list --cask`,
    /// serialised on one queue, before the sheet could print a refusal a string comparison had
    /// already decided. Measured on a warm machine that pays it: 0.04 s for the shell and
    /// 0.42–0.81 s for `brew list` across three runs — but the *bounds* are 8 s and 20 s, and
    /// they exist because both really do take that long sometimes (`brew list`'s own doc comment
    /// names Homebrew's housekeeping). Up to 28 seconds of 「正在确认升级方式…」, every time the
    /// sheet opened, for an answer that needed none of it.
    ///
    /// Its cost, stated in full: a copy kept outside `/Applications` or `~/Applications` is sent
    /// to the release page — **including** one Homebrew installed there with a custom
    /// `--appdir`, which used to be offered `brew upgrade` because the brew question was asked
    /// first. That user is not stranded: the sheet's fallback line spells out
    /// `brew upgrade --cask gitpic`. What the ordering buys is that the free answer is free
    /// again, and that no location gets a looser rule than the one this comment claims.
    public static func route(
        location: BundleLocation,
        bundleVersion: String?,
        latest: String,
        brew: @autoclosure () -> BrewOwnership,
        asset: AssetChoice
    ) -> Route {
        if case .elsewhere(let path) = location {
            return .unavailable(
                reason: "这份 GitPic 在 \(path)，不是 /Applications 或 ~/Applications，"
                    + "所以不能在这里直接替换",
                retryable: false)
        }
        switch brew() {
        case .ownsThisCask(let brew):
            return .homebrew(brew: brew)
        case .unknown(let reason):
            return .unavailable(reason: reason, retryable: true)
        case .doesNotOwnIt:
            break
        }

        // The gate is the *bundle's* version, not the report's `current` — that one is the
        // CLI's, and this replaces the bundle. They are identical in any packaged install
        // (`build-app.sh` refuses to package a mismatch) and can differ for a source build.
        guard let bundleVersion, let mine = Version(bundleVersion) else {
            return .unavailable(reason: "读不出当前 GitPic 的版本号，不能判断是否该替换",
                                retryable: false)
        }
        guard let theirs = Version(latest) else {
            return .unavailable(reason: "读不懂最新版本号 \(latest)", retryable: false)
        }
        guard mine < theirs else {
            return .unavailable(
                reason: "当前 GitPic 是 \(bundleVersion)，并不比最新发布 \(latest) 旧",
                retryable: false)
        }
        switch asset {
        case .found(let asset, let sha):
            return .selfInstall(asset: asset, sha256: sha, version: latest)
        case .none(let reason):
            return .unavailable(reason: reason, retryable: false)
        }
    }

    /// A version as this project numbers them: three numbers, nothing else.
    ///
    /// Mirrors `Version::parse` in `src/release.rs`, including the refusals — a `-rc1` suffix
    /// or an `app-v0.1.2` tag is not comparable and must not be guessed at. Kept here rather
    /// than shared with the CLI because this compares the *bundle's* `Info.plist` against a
    /// report, which is a comparison the CLI never makes.
    struct Version: Comparable {
        let major: Int
        let minor: Int
        let patch: Int

        init?(_ string: String) {
            let s = string.hasPrefix("v") ? String(string.dropFirst()) : string
            guard !s.contains("-"), !s.contains("+") else { return nil }
            let parts = s.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 3 else { return nil }
            guard let major = Int(parts[0]), let minor = Int(parts[1]),
                  let patch = Int(parts[2]),
                  major >= 0, minor >= 0, patch >= 0
            else { return nil }
            (self.major, self.minor, self.patch) = (major, minor, patch)
        }

        static func < (a: Self, b: Self) -> Bool {
            (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
        }
    }

    /// Whether `bundle` sits in a directory an app is installed into.
    ///
    /// `/Applications`, or `~/Applications` for a per-user install — the same two Homebrew
    /// puts a cask in, which is why one predicate serves both paths.
    public static func location(of bundle: URL) -> BundleLocation {
        let parent = bundle.resolvingSymlinksInPath().deletingLastPathComponent()
            .standardizedFileURL.path
        let appDirs = [
            "/Applications",
            URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Applications").standardizedFileURL.path,
        ]
        let matches = appDirs.contains {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path == parent
        }
        return matches ? .applicationsDir : .elsewhere(path: bundle.path)
    }

    /// Ask Homebrew whether it owns **this** bundle. Blocking: call it off the main actor.
    ///
    /// The bundle is a parameter because "is the cask installed" is not the question — see
    /// `ToolDiscovery.brewCaskApp`. A copy in `~/Applications` on a machine whose cask
    /// installed to `/Applications` must come back `.doesNotOwnIt`, or it gets handed to brew,
    /// brew replaces the *other* bundle, and this one is reopened unchanged still reporting the
    /// same update. That is not hypothetical: it is what this returned before the end-to-end
    /// run caught it.
    ///
    /// **Every brew is asked, not the first one found.** A machine that has had both an Intel
    /// and an Apple Silicon Homebrew has two prefixes with two independent Caskrooms; asking
    /// only `/opt/homebrew/bin/brew` about a cask installed by `/usr/local/bin/brew` gets a
    /// perfectly truthful "I have nothing under that token", which folded straight into
    /// "not brew's" and an install over a bundle the other brew manages. The second
    /// `brew list --cask` costs a second bound, not a second 20 seconds — measured at 0.44 s on
    /// this machine — and it is the price of not breaking that install.
    ///
    /// The reduction is ``fold(_:)``, which is where the precedence rule is written down and
    /// tested.
    public static func brewOwnership(cask: String, bundle: URL) -> BrewOwnership {
        switch ToolDiscovery.locateBrewOutcome() {
        case .unknown(let reason):
            return .unknown(reason: reason)
        case .absent:
            // A definite answer, and the common one for the users this path exists for.
            return fold([])
        case .found(let brews):
            let mine = bundle.resolvingSymlinksInPath().standardizedFileURL.path
            return fold(brews.map { brew in
                switch ToolDiscovery.brewCaskApp(cask, brew: brew) {
                case .notInstalled:
                    return .hasNothing
                case .unusable(let reason):
                    return .noAnswer(reason: reason)
                case .installedAt(let apps):
                    return apps.contains { $0.path == mine }
                        ? .ownsThisBundle(brew: brew)
                        : .ownsAnotherBundle
                }
            })
        }
    }
}
