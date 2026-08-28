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
/// **This is the only install path now, including for a bundle Homebrew installed.** It used to
/// be what happened when brew was *not* the owner, and the gap between the two is why that
/// changed: brew was handed a script that went to the network *after* the app had quit, so an
/// `.accessory` app's menu-bar icon was gone for the length of a tap refresh plus a download,
/// with no progress, nothing to cancel, and a 900 s watchdog as the only bound. Here the
/// download, the verification, the mount and the copy have all already happened while the app
/// was alive, cancellable, and able to show an error. What is left after the quit is two
/// same-directory renames and an `open`: local, fast, and rollback-able.
///
/// **What became of the argument for handing brew the install.** That argument was not wrong — a
/// bundle replaced behind brew's back leaves its manifest describing a version that is not on
/// disk, and the next `brew upgrade` fights it. Homebrew has a stanza for precisely this and the
/// cask was missing it. `auto_updates true` asserts that the artifact updates itself, which the
/// Cask Cookbook defines as the case where the app menu has a *Check for Updates…* that really
/// downloads and installs; current Homebrew then decides by reading the **installed bundle's**
/// `Info.plist` rather than its own receipt (`Cask#auto_updates_bundle_outdated?`, and
/// `HOMEBREW_UPGRADE_AUTO_UPDATES_CASKS` defaults on). So `brew upgrade` still upgrades a GitPic
/// that is genuinely behind, and now correctly does nothing when this installer has already
/// moved it on — where comparing against the stale receipt used to make it reinstall a version
/// already on disk. The cask also gained `uninstall quit: "dev.gitpic.app"`, so a
/// `brew upgrade --cask gitpic` typed into a terminal quits the app before the swap and reopens
/// it afterwards, instead of replacing a running bundle.
///
/// **Both stanzas live in `tarnish233/homebrew-tap`'s `Casks/gitpic.rb`, and this file's
/// correctness depends on them being there** — a cross-repository premise, so it is also
/// recorded in AGENTS.md's Homebrew section.
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
        /// **Nothing produces `true` any more.** The one source was the Homebrew ownership
        /// probe, whose "I could not get an answer" had to stay askable; ``route`` is now a pure
        /// function of the report and this bundle's path, so every refusal is durable for as
        /// long as the report is. The parameter and the guard in `AppModel` that reads it are
        /// kept rather than collapsed because they are what documents that distinction, and
        /// removing them would change nothing that runs.
        case unavailable(reason: String, retryable: Bool)
    }

    /// Whether the running bundle sits somewhere an update may be installed.
    public enum BundleLocation: Equatable, Sendable {
        /// `/Applications` or `~/Applications`.
        case applicationsDir
        case elsewhere(path: String)
    }

    /// Decide whether to offer an upgrade, and for which asset.
    ///
    /// **A pure function of the report and this bundle's path.** It used to spawn Homebrew: the
    /// first question was who owns the bundle, and a cask-managed one was sent to
    /// `brew upgrade --cask gitpic` instead. That question is gone — the cask now declares
    /// `auto_updates true`, so this installer is what upgrades every copy and brew defers to it
    /// (the file header has the full argument). Everything left here is a string comparison, a
    /// version comparison and a lookup in the report's asset list.
    ///
    /// **What that removal bought, since it is the point of the change.** The brew questions cost
    /// up to 8 s for a login-shell probe and up to 20 s per `brew list --cask`, on a serial queue,
    /// every time the sheet opened — up to 28 seconds of 「正在确认升级方式…」 before a button
    /// could be drawn. `brew` used to be an `@autoclosure` purely so that a bundle outside the
    /// two Applications directories could refuse without paying it. There is nothing left to
    /// defer, so the parameter and the laziness are both gone.
    ///
    /// **The location rule survives on its own merits**, not as a shared test with a brew path
    /// that no longer exists: a copy running from `dist-app/` or a Downloads folder must not have
    /// its directory written into, and the sheet sends it to the release page. It is still asked
    /// first, now simply because it is the one refusal that does not depend on the report.
    public static func route(
        location: BundleLocation,
        bundleVersion: String?,
        latest: String,
        asset: AssetChoice
    ) -> Route {
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
