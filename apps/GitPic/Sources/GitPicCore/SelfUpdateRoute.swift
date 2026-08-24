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
        case selfInstall(asset: ReleaseAsset, sha256: String)
        /// Neither. `reason` is user-facing; `retryable` is whether asking again could change
        /// the answer, which is what stops a one-off probe failure being cached for the life
        /// of the process.
        case unavailable(reason: String, retryable: Bool)
    }

    /// What Homebrew has to say about this bundle.
    ///
    /// Collapsed to three cases by ``brewOwnership(cask:)`` before it reaches ``route``, so
    /// the decision itself is a pure function over facts rather than a thing that spawns
    /// processes — which is what makes the table below testable at all.
    public enum BrewOwnership: Equatable, Sendable {
        /// brew is here and manages this cask.
        case ownsThisCask(brew: URL)
        /// Definitively not brew's: it answered "not installed", or there is no brew on the
        /// machine at all. A durable fact.
        case doesNotOwnIt
        /// No answer. Must not be acted on and must not be cached.
        case unknown(reason: String)
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
    /// The location rule is shared with the brew path rather than being a second, looser
    /// test. Its cost, stated: a copy kept outside `/Applications` or `~/Applications` is
    /// sent to the release page. That is the safe direction — it also means a development
    /// build in the repository's `dist-app/` cannot be silently replaced by a release build.
    public static func route(
        location: BundleLocation,
        bundleVersion: String?,
        latest: String,
        brew: BrewOwnership,
        asset: AssetChoice
    ) -> Route {
        if case .ownsThisCask(let brew) = brew { return .homebrew(brew: brew) }

        if case .elsewhere(let path) = location {
            return .unavailable(
                reason: "这份 GitPic 在 \(path)，不是 /Applications 或 ~/Applications，"
                    + "所以不能在这里直接替换",
                retryable: false)
        }
        if case .unknown(let reason) = brew {
            return .unavailable(reason: reason, retryable: true)
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
            return .selfInstall(asset: asset, sha256: sha)
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
    public static func brewOwnership(cask: String, bundle: URL) -> BrewOwnership {
        switch ToolDiscovery.locateBrewOutcome() {
        case .unknown(let reason):
            return .unknown(reason: reason)
        case .absent:
            // A definite answer, and the common one for the users this path exists for.
            return .doesNotOwnIt
        case .found(let brew):
            switch ToolDiscovery.brewCaskApp(cask, brew: brew) {
            case .notInstalled:
                return .doesNotOwnIt
            case .unusable(let reason):
                return .unknown(reason: reason)
            case .installedAt(let app):
                let mine = bundle.resolvingSymlinksInPath().standardizedFileURL.path
                return app.path == mine ? .ownsThisCask(brew: brew) : .doesNotOwnIt
            }
        }
    }
}
