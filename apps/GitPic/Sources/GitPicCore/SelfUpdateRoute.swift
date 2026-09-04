import Foundation

/// Putting a verified disk image in place of the running bundle.
///
/// **Why this is a detached script and not code in this process.** The thing being replaced is
/// the bundle this code is executing from, so the work has to outlive the app. A half-replaced
/// bundle is one whose executable, resources and embedded CLI need not be from the same version,
/// and nothing here can put that back. So the app quits first, and a script that nothing else
/// depends on does two renames.
extension SelfUpdate {

    /// Which upgrade this install can be offered, if any.
    public enum Route: Equatable, Sendable {
        /// There is a verifiable image to install over this bundle.
        ///
        /// `version` travels with the asset because both come out of one report and the install
        /// has to agree with itself. Reading the asset from one report and the version from a
        /// later one would make a valid download fail the staging version gate.
        case selfInstall(asset: ReleaseAsset, sha256: String, version: String)
        /// No install can be offered. `reason` is user-facing and therefore **Chinese**.
        case unavailable(reason: String)
    }

    /// Whether the running bundle sits somewhere an update may be installed.
    public enum BundleLocation: Equatable, Sendable {
        /// `/Applications` or `~/Applications`.
        case applicationsDir
        case elsewhere(path: String)
    }

    /// Decide whether to offer an upgrade from three facts supplied by the caller: where the
    /// bundle is, what version it is, and what the release has to install.
    ///
    /// Location is the first gate. A copy running from a build directory or Downloads must not
    /// have its directory written into, and the sheet sends it to the release page instead.
    public static func route(
        location: BundleLocation,
        bundleVersion: String?,
        latest: String,
        asset: AssetChoice
    ) -> Route {
        if case .elsewhere(let path) = location {
            return .unavailable(
                reason: "这份 GitPic 在 \(path)，不是 /Applications 或 ~/Applications，"
                    + "所以不能在这里直接替换")
        }

        // The gate is the *bundle's* version, not the report's `current` — that one is the
        // CLI's, and this replaces the bundle. They are identical in any packaged install
        // (`build-app.sh` refuses to package a mismatch) and can differ for a source build.
        guard let bundleVersion, let mine = Version(bundleVersion) else {
            return .unavailable(reason: "读不出当前 GitPic 的版本号，不能判断是否该替换")
        }
        guard let theirs = Version(latest) else {
            return .unavailable(reason: "读不懂最新版本号 \(latest)")
        }
        guard mine < theirs else {
            return .unavailable(
                reason: "当前 GitPic 是 \(bundleVersion)，并不比最新发布 \(latest) 旧")
        }
        switch asset {
        case .found(let asset, let sha):
            return .selfInstall(asset: asset, sha256: sha, version: latest)
        case .none(let reason):
            return .unavailable(reason: reason)
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
    /// `/Applications`, or `~/Applications` for a per-user install.
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
