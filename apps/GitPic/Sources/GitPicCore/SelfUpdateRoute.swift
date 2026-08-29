import Foundation

/// Putting a verified disk image in place of the running bundle.
///
/// **Why this is a detached script and not code in this process.** The thing being replaced is
/// the bundle this code is executing from, so the work has to outlive the app. This file used to
/// justify that with "measured: renaming a running executable's directory away and putting a new
/// one at the old path got the process `Killed: 9`" — the same claim `Updater.swift:28` retracts,
/// and for the same reason: re-measured twice, a `mv` of the bundle directory leaves the process
/// running happily from the moved-aside copy. The ordering stands on the plainer argument
/// instead. A half-replaced bundle is one whose executable, resources and embedded CLI need not
/// be from the same version, and nothing here can put that back. So the app quits first, and a
/// script that nothing else depends on does two renames.
///
/// **This is the install path for every copy nobody else manages.** A bundle a Homebrew cask
/// owns is not installed over at all: `route` hands its user `brew upgrade --cask gitpic` and
/// this file is not reached. `CaskOwnership` decides which of the two it is.
///
/// **Why that is not a return to what `bb07783` deleted.** The route it removed *ran* brew, and
/// both of its measured defects came from that and only from that. The app had to quit before
/// brew was spawned, so a tap refresh and a whole download happened with an `.accessory` app's
/// menu-bar icon already gone, with no progress, nothing to cancel, and a 900 s watchdog as the
/// only bound. And when the tap lagged the release, `brew upgrade` exited **0** saying "the
/// latest version is already installed", which the script logged as success before reopening
/// the same build. Nothing is spawned now and nothing quits: the app says what to run and stays
/// where it is, so neither failure has anywhere to happen. What it costs instead is stated on
/// ``Route/homebrewUpToDate(installed:)`` — during the tap's lag a brew user is told to wait
/// rather than offered an install.
///
/// **The stanza that makes the handed-over command safe is `uninstall quit: "dev.gitpic.app"`**,
/// and it is more load-bearing than before: `Cask::Upgrade` passes `quit: true`, so brew quits
/// the app, re-registers the new bundle with Launch Services and reopens it. For an `.accessory`
/// app that reopen is the only thing that puts the menu-bar icon back. Telling someone to run a
/// command that would leave them with a replaced bundle and a dead icon is not an option.
///
/// `auto_updates true` is the other stanza the cask carries, and it is no longer what makes any
/// of this correct — it asserts that the artifact updates itself, which stops being true of a
/// cask-managed copy the moment this route defers to brew. AGENTS.md's Homebrew section records
/// what becomes of it and why the two repositories have to move in that order.
extension SelfUpdate {

    /// Which upgrade this install can be offered, if any.
    public enum Route: Equatable, Sendable {
        /// There is a verifiable image to install over this bundle.
        ///
        /// `version` travels with the asset because both come out of one report and the
        /// install has to agree with itself. Read separately — the asset from a route the sheet
        /// is holding, the version from `AppModel.update` at click time — a check landing in
        /// between made a download verify against 0.20.0's digest and then die at `stage`'s
        /// version gate with 「映像里是 0.20.0，不是预期的 0.21.0」, which reads like a tampered
        /// release rather than a stale sheet.
        case selfInstall(asset: ReleaseAsset, sha256: String, version: String)
        /// No install can be offered. `reason` is user-facing and therefore **Chinese**;
        /// `retryable` is whether asking again could change the answer, which is what stops a
        /// one-off probe failure being cached for the life of the process.
        ///
        /// `retryable` means "asking the machine again could answer differently" — a fact about
        /// *this install*, not about the release. Every refusal computed from the report is
        /// therefore `retryable: false` and relies on the caller dropping the whole route when
        /// the report changes; see `AppModel.resolveUpgradePath`.
        ///
        /// **Nothing produces `true` any more**, and the reason is worth stating precisely
        /// because it changed shape. The one source was a Homebrew probe that could time out,
        /// so its "I could not get an answer" had to stay askable. Homebrew is asked about
        /// again — but by the *caller*, which hands `route` a finished `CaskOwnership.Verdict`,
        /// so `route` is still a pure function and every refusal it mints is still durable for
        /// as long as the report is. A lookup that fails becomes `Offer.unknown`, which is one
        /// of the Homebrew cases below and not a refusal at all. The parameter and the guard in
        /// `AppModel` that reads it are kept rather than collapsed because they are what
        /// documents that distinction, and removing them would change nothing that runs.
        case unavailable(reason: String, retryable: Bool)
        /// Homebrew owns this bundle and its cask has something newer: hand over the command.
        ///
        /// `installed` is the *bundle's* version and `available` is the **cask's**, not the
        /// release's. Those differ whenever the tap lags a release, which is the whole reason
        /// this case exists rather than reusing the release comparison — see ``route``.
        ///
        /// The command travels as its own value rather than inside a `reason` string, so that
        /// `refusalsAreWrittenForTheWindow`'s ban on command lines in refusals stays exactly as
        /// strict as it was: a refusal still may not read like a command, and this is not one.
        case homebrewManaged(command: String, installed: String, available: String)
        /// Homebrew owns this bundle and its cask has nothing newer.
        ///
        /// Reached even when a *release* newer than `installed` exists — the tap follows a
        /// release by dispatch with a six-hourly cron behind it. No command is offered, because
        /// `brew upgrade --cask gitpic` in this window prints "the latest version is already
        /// installed" and exits 0, and handing someone a command that does nothing is worse
        /// than saying so. This is the accepted cost of the policy; the app does not install
        /// over a cask-managed bundle to fill the gap.
        ///
        /// **`offered` travels alongside `installed` because the two are not always equal**, and
        /// the case is reached whenever the bundle is not *older*. It carried only `installed`
        /// at first, which the sheet rendered as 「已是 Homebrew 提供的最新版本（X）」 — a
        /// statement about what Homebrew provides, made from the bundle's own number. For a user
        /// who self-installed 0.20.10 while the tap still declares 0.20.9 that sentence asserts
        /// Homebrew provides 0.20.10 and tells them to wait for a version they already have.
        /// Both numbers are here so the sheet can say which is which.
        case homebrewUpToDate(installed: String, offered: String)
        /// Homebrew owns this bundle and what its cask offers could not be established.
        ///
        /// The command is still offered, with the caveat, because a network that is down says
        /// nothing about whether the upgrade path works — and it is what Claude Code does in
        /// the same spot ("Could not check for updates" followed by the command).
        case homebrewUnverified(command: String, reason: String)
    }

    /// Whether the running bundle sits somewhere an update may be installed.
    public enum BundleLocation: Equatable, Sendable {
        /// `/Applications` or `~/Applications`.
        case applicationsDir
        case elsewhere(path: String)
    }

    /// Decide whether to offer an upgrade, and for which asset.
    ///
    /// **A pure function of four facts**, each supplied by the caller: who owns the bundle,
    /// where it is, what version it is, and what the release has to install. Homebrew is a
    /// question again — `bb07783` removed it and this puts it back — but nothing here asks it.
    /// `CaskOwnership.verdict` does, and hands the finished answer in, which is why every row
    /// of this table can still be exercised by naming its inputs.
    ///
    /// The old shape is worth remembering as the thing not to return to: `brew` arrived as an
    /// `@autoclosure` producing a verdict from a login-shell probe of up to 8 s plus up to 20 s
    /// per `brew list --cask`, per prefix, on a serial queue — up to 28 seconds of
    /// 「正在确认升级方式…」 before a button could be drawn, and the laziness existed purely so a
    /// bundle outside the two Applications directories could refuse without paying it.
    /// `CaskOwnership` answers the same question with a directory scan and a `readlink`, so
    /// there is nothing left to defer and the parameter is an ordinary value.
    ///
    /// **Ownership is asked first, ahead of the location.** That order is load-bearing, not
    /// tidiness. `brew install --appdir` puts a cask anywhere, and `location(of:)` calls
    /// anything outside `/Applications` and `~/Applications` `.elsewhere` — so asking location
    /// first sends a perfectly ordinary cask install to a dead-end refusal when
    /// `brew upgrade --cask gitpic` is exactly right for it. Claude Code is package-manager-first
    /// for the same reason: whether *we* could install locally is irrelevant when somebody else
    /// owns the install.
    ///
    /// **The Homebrew branch compares against the tap, not the release**, and must not reuse the
    /// gate below. `latest` is the release's, and for a brew user the base is what the cask
    /// offers: bundle 0.20.9 with release 0.20.10 and tap 0.20.9 is `homebrewUpToDate`, which
    /// `mine < theirs` would wave straight through into an install. `latest` is not consulted on
    /// that branch at all, and neither is `asset` — which is also why the branch sits above
    /// both, since `installableAsset()` derives a filename from `latest` and would mint a
    /// refusal about a missing DMG for someone who was never going to download one.
    ///
    /// **The location rule survives on its own merits**, for the copies that are nobody's cask:
    /// one running from `dist-app/` or a Downloads folder must not have its directory written
    /// into, and the sheet sends it to the release page.
    public static func route(
        cask: CaskOwnership.Verdict,
        location: BundleLocation,
        bundleVersion: String?,
        latest: String,
        asset: AssetChoice
    ) -> Route {
        if case .homebrews(let token, let offers) = cask {
            let command = "brew upgrade --cask \(token)"
            switch offers {
            case .unknown(let reason):
                return .homebrewUnverified(command: command, reason: reason)
            case .version(let offered):
                // The bundle's own version, for the reason on the gate below.
                guard let bundleVersion, let mine = Version(bundleVersion) else {
                    return .homebrewUnverified(
                        command: command, reason: "读不出当前 GitPic 的版本号")
                }
                // Both parsers already refuse what they cannot compare, so this is defensive
                // rather than reachable — and a caveat is the right answer to an impossible
                // string, where a comparison against a guess would not be.
                guard let theirs = Version(offered) else {
                    return .homebrewUnverified(
                        command: command, reason: "读不懂 Homebrew 提供的版本号")
                }
                guard mine < theirs else {
                    return .homebrewUpToDate(installed: bundleVersion, offered: offered)
                }
                return .homebrewManaged(
                    command: command, installed: bundleVersion, available: offered)
            }
        }

        if case .elsewhere(let path) = location {
            return .unavailable(
                reason: "这份 GitPic 在 \(path)，不是 /Applications 或 ~/Applications，"
                    + "所以不能在这里直接替换",
                retryable: false)
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
}
