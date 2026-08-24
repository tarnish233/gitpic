import Foundation

/// One downloadable file from a release, as `gitpic update check --json` reports it.
///
/// Mirrors `ReleaseAsset` in `src/release.rs`, with the same explicit-`CodingKeys` reason
/// ``UpdateReport`` gives: the CLI's spellings are a contract.
public struct ReleaseAsset: Decodable, Equatable, Sendable {
    public let name: String
    public let size: Int64
    /// GitHub's `browser_download_url`, passed through by the CLI rather than constructed.
    public let url: String
    /// `"sha256:<64 hex>"`, or `nil` when GitHub reported none.
    ///
    /// **`nil` means "cannot verify", never "no need to verify".** ``expectedSHA256`` is the
    /// only way to read it, and every caller goes through that, so there is no path that
    /// installs a download this could not vouch for.
    public let digest: String?

    enum CodingKeys: String, CodingKey {
        case name, size, url, digest
    }

    public init(name: String, size: Int64, url: String, digest: String?) {
        self.name = name
        self.size = size
        self.url = url
        self.digest = digest
    }

    /// The 64-character lowercase hex of ``digest``, or `nil` if there is nothing usable.
    ///
    /// The `sha256:` prefix is *required*, not stripped-if-present: it is what says which
    /// algorithm produced the hex, and a future `sha512:` value read as SHA-256 would fail
    /// every comparison — or, far worse in a different implementation, be truncated to 64
    /// characters and compared against the wrong thing. Refusing anything that is not
    /// explicitly SHA-256 is the only reading that cannot silently verify nothing.
    ///
    /// Also rejects the wrong length and non-hex characters, so a malformed value becomes
    /// "no digest" — which the caller turns into "no self-update" — instead of a comparison
    /// that can never match and looks like a corrupted download.
    public var expectedSHA256: String? {
        guard let digest, digest.hasPrefix("sha256:") else { return nil }
        let hex = digest.dropFirst("sha256:".count).lowercased()
        guard hex.count == 64, hex.allSatisfy(\.isHexDigit) else { return nil }
        return hex
    }
}

/// Which asset of a release this build could install, and what to say when there is none.
public enum AssetChoice: Equatable, Sendable {
    case found(ReleaseAsset, sha256: String)
    /// No asset this build can install. The reason is for the log and the sheet's fallback
    /// line — the user's route is the release page either way.
    case none(reason: String)
}

extension UpdateReport {

    /// The architecture segment of the disk image this build would install.
    ///
    /// Read from the running process rather than hardcoded `arm64`. Only an arm64 image is
    /// published today (`release.yml` builds exactly one), so on any other architecture this
    /// deliberately finds nothing and the user is sent to the release page — which is the
    /// safe direction. Hardcoding `arm64` would instead install an image of the wrong
    /// architecture and leave behind an app that cannot launch.
    static var installableArch: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unsupported"
        #endif
    }

    /// The disk image for ``latest`` on this architecture, if the release published one and
    /// GitHub reported a usable SHA-256 for it.
    ///
    /// Matched on the exact name `release.yml:208` builds — `GitPic-<version>-macos-<arch>.dmg`
    /// — rather than on "ends in .dmg". A release carries five archives and five `.sha256`
    /// sidecars beside the image, and "the first thing that looks like a download" is how a
    /// caller ends up hashing a sidecar.
    public func installableAsset() -> AssetChoice {
        guard let assets else {
            // An older CLI than this app, which `locateGitpic`'s bundle-first order makes
            // possible only for a source build — see the property's own doc comment.
            return .none(reason: "这个 gitpic 版本不报告发布资产")
        }
        let wanted = "GitPic-\(latest)-macos-\(Self.installableArch).dmg"
        guard let asset = assets.first(where: { $0.name == wanted }) else {
            return .none(reason: "这个版本没有发布 \(wanted)")
        }
        guard let sha = asset.expectedSHA256 else {
            // Deliberately fatal to the in-app install. GitHub has reported a digest for
            // every release of this project that shipped an image, so this is not an
            // expected state — and installing an app bundle whose bytes nothing vouched for
            // is the one thing this path must never do.
            return .none(reason: "GitHub 没有报 \(wanted) 的校验和，无法验证下载内容")
        }
        return .found(asset, sha256: sha)
    }
}
