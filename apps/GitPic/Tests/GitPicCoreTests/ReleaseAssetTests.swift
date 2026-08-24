import CryptoKit
import Foundation
import Testing
@testable import GitPicCore

/// The rules that decide whether an in-app update is even attempted, and the one that decides
/// whether what arrived may be installed.
///
/// All of this is here rather than in `GitPicApp` for the reason `Package.swift` states: an
/// executable target cannot be imported by tests. The decisions worth testing were therefore
/// written to live in `GitPicCore` from the start.
///
/// `.serialized` because the leftover-file checks below count `gitpic-update-*.dmg` entries in
/// the shared temporary directory, and the successful downloads in this same suite create
/// exactly those. Run in parallel, one test's in-flight file is another's "something was left
/// behind" — which is how this suite first failed.
@Suite("Release assets and verification", .serialized)
struct ReleaseAssetTests {

    /// Verbatim from `gitpic update check --json` against the real feed, trimmed to the two
    /// assets that matter: the image, and a sidecar GitHub reports no digest for.
    private static let payload = Data("""
    {
      "ok": true, "current": "0.18.0", "latest": "0.19.0", "tag": "v0.19.0",
      "update_available": true, "ahead": false, "name": "gitpic v0.19.0",
      "notes": "- a change", "url": "https://example.invalid/rel",
      "published_at": "2026-08-24T01:02:03Z",
      "assets": [
        {"name": "GitPic-0.19.0-macos-arm64.dmg", "size": 4999203,
         "url": "https://example.invalid/d/GitPic-0.19.0-macos-arm64.dmg",
         "digest": "sha256:60f48a611df65e09d17d9b55f7ef730be9070ef3fafcb2e3db54519e47bd14b2"},
        {"name": "GitPic-0.19.0-macos-arm64.dmg.sha256", "size": 96,
         "url": "https://example.invalid/d/sidecar"}
      ]
    }
    """.utf8)

    @Test("the CLI's asset field names decode as written")
    func decodesAssets() throws {
        let report = try JSONDecoder().decode(UpdateReport.self, from: Self.payload)
        let assets = try #require(report.assets)
        #expect(assets.count == 2)
        #expect(assets[0].name == "GitPic-0.19.0-macos-arm64.dmg")
        #expect(assets[0].size == 4_999_203)
        #expect(assets[0].url == "https://example.invalid/d/GitPic-0.19.0-macos-arm64.dmg")
        #expect(assets[0].digest?.hasPrefix("sha256:") == true)
        // The one GitHub reported nothing for stays nil rather than becoming "".
        #expect(assets[1].digest == nil)
    }

    /// The reason ``UpdateReport/assets`` is Optional. A CLI too old to report the field must
    /// not take the whole update check down with it: `GitpicRunner.runJSON` swallows a decode
    /// error with `try?` and reports 「看不懂 gitpic 的回答」, so a missing key on a
    /// non-Optional property would break checking for updates at all — not merely installing.
    @Test("a report from a CLI that does not report assets still decodes")
    func decodesWithoutAssets() throws {
        let old = Data("""
        {"ok": true, "current": "0.18.0", "latest": "0.19.0", "tag": "v0.19.0",
         "update_available": true, "ahead": false, "notes": "", "url": "https://e.invalid"}
        """.utf8)
        let report = try JSONDecoder().decode(UpdateReport.self, from: old)
        #expect(report.assets == nil)
        // And it says so rather than crashing or silently offering an install.
        guard case .none(let reason) = report.installableAsset() else {
            Issue.record("a report with no assets must not yield an installable one")
            return
        }
        #expect(reason.contains("不报告发布资产"))
    }

    @Test("the image for this version and architecture is the one chosen")
    func picksTheImage() throws {
        let report = try JSONDecoder().decode(UpdateReport.self, from: Self.payload)
        // The suite only runs where the tests are built, and only an arm64 image exists in
        // the fixture — so on any other architecture the correct answer is "nothing", which
        // is asserted rather than skipped.
        if UpdateReport.installableArch == "arm64" {
            guard case .found(let asset, let sha) = report.installableAsset() else {
                Issue.record("the arm64 image should have been chosen")
                return
            }
            #expect(asset.name == "GitPic-0.19.0-macos-arm64.dmg")
            #expect(sha == "60f48a611df65e09d17d9b55f7ef730be9070ef3fafcb2e3db54519e47bd14b2")
        } else {
            guard case .none = report.installableAsset() else {
                Issue.record("no image is published for \(UpdateReport.installableArch)")
                return
            }
        }
    }

    /// Matched on the exact name `release.yml` builds, not on "ends with .dmg". A release
    /// carries five archives and five `.sha256` sidecars beside the image, and picking "the
    /// first thing that looks like a download" is how a caller ends up hashing a sidecar and
    /// trying to mount it.
    @Test("a sidecar or an archive is never mistaken for the image")
    func doesNotPickASidecar() {
        let report = Self.report(assets: [
            ReleaseAsset(name: "GitPic-0.19.0-macos-arm64.dmg.sha256", size: 96,
                         url: "https://e.invalid/s", digest: "sha256:\(String(repeating: "a", count: 64))"),
            ReleaseAsset(name: "gitpic-aarch64-apple-darwin.tar.gz", size: 1,
                         url: "https://e.invalid/t", digest: "sha256:\(String(repeating: "b", count: 64))"),
        ])
        guard case .none(let reason) = report.installableAsset() else {
            Issue.record("only GitPic-<version>-macos-<arch>.dmg may be installed")
            return
        }
        #expect(reason.contains("没有发布"))
    }

    /// A version mismatch is not an installable asset: the image named in the release has to
    /// be the version the report says is latest, or the app would install something whose
    /// version it never checked.
    @Test("an image for a different version is not installed")
    func refusesAnotherVersionsImage() {
        let report = Self.report(assets: [
            ReleaseAsset(name: "GitPic-0.18.1-macos-arm64.dmg", size: 1,
                         url: "https://e.invalid/d",
                         digest: "sha256:\(String(repeating: "c", count: 64))"),
        ])
        guard case .none = report.installableAsset() else {
            Issue.record("0.18.1's image must not be offered for 0.19.0")
            return
        }
    }

    /// **The check with the most riding on it.** No digest means nothing vouches for the
    /// bytes, and this path replaces the application the user is running — so it refuses
    /// rather than installing something unverified. Absence must never read as permission.
    @Test("no digest means no in-app install")
    func refusesAnAssetWithNoDigest() {
        let report = Self.report(assets: [
            ReleaseAsset(name: "GitPic-0.19.0-macos-\(UpdateReport.installableArch).dmg",
                         size: 1, url: "https://e.invalid/d", digest: nil),
        ])
        guard case .none(let reason) = report.installableAsset() else {
            Issue.record("an asset with no digest must not be installable")
            return
        }
        #expect(reason.contains("校验和"))
    }

    /// Everything that is not an unambiguous SHA-256 is treated as no digest at all.
    ///
    /// The algorithm prefix is required rather than stripped-if-present. A `sha512:` value
    /// read as SHA-256 is the dangerous case: an implementation that split on `:` and took
    /// the tail would compare a 128-character hex against a 64-character one forever, or —
    /// in a less careful version — truncate it and "verify" against the wrong half.
    @Test("only an explicit, well-formed sha256 counts as a digest")
    func digestParsingIsStrict() {
        let good = String(repeating: "ab", count: 32)  // 64 chars
        #expect(Self.asset(digest: "sha256:\(good)").expectedSHA256 == good)
        // Uppercase hex normalises rather than being rejected — GitHub sends lowercase, but
        // the comparison must not turn a spelling difference into a tampering report.
        #expect(Self.asset(digest: "sha256:\(good.uppercased())").expectedSHA256 == good)

        #expect(Self.asset(digest: nil).expectedSHA256 == nil)
        // A different algorithm, which is the one that must not be mistaken for SHA-256.
        #expect(Self.asset(digest: "sha512:\(String(repeating: "ab", count: 64))")
            .expectedSHA256 == nil)
        // No prefix at all: a bare hash could be anything.
        #expect(Self.asset(digest: good).expectedSHA256 == nil)
        // Wrong length, and non-hex.
        #expect(Self.asset(digest: "sha256:abcd").expectedSHA256 == nil)
        #expect(Self.asset(digest: "sha256:\(String(repeating: "z", count: 64))")
            .expectedSHA256 == nil)
        #expect(Self.asset(digest: "sha256:").expectedSHA256 == nil)
        #expect(Self.asset(digest: "").expectedSHA256 == nil)

        // Fullwidth hex digits are not hex, though `isHexDigit` says they are (measured:
        // `"Ａ".allSatisfy(\.isHexDigit) == true`, and `count` is 64 for 64 of them). Such a
        // digest used to pass validation and then fail the byte comparison, which surfaces a
        // malformed digest as 「下载内容校验不通过」 — a tampering report for what is really a
        // field GitHub never sent.
        #expect(Self.asset(digest: "sha256:\(String(repeating: "Ａ", count: 64))")
            .expectedSHA256 == nil)
        #expect(Self.asset(digest: "sha256:\(String(repeating: "０", count: 64))")
            .expectedSHA256 == nil)
        // One fullwidth character among 63 ASCII ones: the realistic shape, and the one a
        // length check alone cannot see.
        #expect(Self.asset(digest: "sha256:\(String(repeating: "a", count: 63))Ｆ")
            .expectedSHA256 == nil)
    }

    /// The hash the verification actually compares, over a real file on disk.
    ///
    /// Pinned against `shasum -a 256`'s answer for the same bytes rather than against
    /// CryptoKit hashing the same buffer a second time — a round-trip through one
    /// implementation would agree with itself even if the digest were being read wrongly.
    @Test("the file hash is lowercase hex and matches a known vector")
    func hashesAFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitpic-hash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("payload")
        try Data("abc".utf8).write(to: file)
        // The published SHA-256 of "abc" (FIPS 180-4 example B.1).
        #expect(try SelfUpdate.sha256OfFile(at: file)
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")

        // Empty, and larger than one read chunk, so the loop's boundaries are covered.
        let empty = dir.appendingPathComponent("empty")
        try Data().write(to: empty)
        #expect(try SelfUpdate.sha256OfFile(at: empty)
            == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")

        let big = dir.appendingPathComponent("big")
        try Data(repeating: 0x61, count: 3 * 1024 * 1024 + 7).write(to: big)
        let chunked = try SelfUpdate.sha256OfFile(at: big)
        #expect(chunked.count == 64)
        #expect(chunked == chunked.lowercased())
        // Chunking must not change the answer: one-shot over the same bytes agrees.
        let oneShot = SHA256.hash(data: try Data(contentsOf: big))
            .map { String(format: "%02x", $0) }.joined()
        #expect(chunked == oneShot, "reading in 1 MiB chunks changed the hash")
    }

    @Test("progress reports a fraction only when the total is known")
    func progressFraction() {
        #expect(SelfUpdate.Progress(received: 0, total: 100).fraction == 0)
        #expect(SelfUpdate.Progress(received: 50, total: 100).fraction == 0.5)
        // A server that sends no Content-Length leaves this nil, which is what tells the UI
        // to show a spinner instead of a bar stuck at zero.
        #expect(SelfUpdate.Progress(received: 50, total: nil).fraction == nil)
        #expect(SelfUpdate.Progress(received: 50, total: 0).fraction == nil)
        // More bytes than announced is clamped rather than reported as over 100%.
        #expect(SelfUpdate.Progress(received: 150, total: 100).fraction == 1)
    }

    private static func asset(digest: String?) -> ReleaseAsset {
        ReleaseAsset(name: "GitPic-0.19.0-macos-arm64.dmg", size: 1,
                     url: "https://e.invalid/d", digest: digest)
    }

    private static func report(assets: [ReleaseAsset]) -> UpdateReport {
        UpdateReport(ok: true, current: "0.18.0", latest: "0.19.0", tag: "v0.19.0",
                     updateAvailable: true, ahead: false, name: nil, notes: "",
                     url: "https://e.invalid", publishedAt: nil, assets: assets)
    }

    // MARK: - The download itself

    /// The whole download path, over `file://` so it runs offline.
    ///
    /// `URLSessionDownloadTask` handles `file://` the same way it handles `https://` — the
    /// delegate callbacks, the move out of the session's temporary location, and the hashing
    /// are all the shipping code. Only the transport differs, which is the one part not worth
    /// a test of its own.
    @Test("a download whose bytes match the digest is kept and verified")
    func downloadsAndVerifies() async throws {
        let source = try Self.sourceFile(contents: "the disk image's bytes")
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let sha = try SelfUpdate.sha256OfFile(at: source)

        let file = try await SelfUpdate.download(
            asset: Self.asset(url: source, digest: "sha256:\(sha)"),
            sha256: sha, onProgress: { _ in })
        defer { try? FileManager.default.removeItem(at: file) }

        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try SelfUpdate.sha256OfFile(at: file) == sha)
    }

    /// **The test this file exists for.** A download whose hash does not match must be
    /// refused *and deleted*: leaving it on disk is how an unverified bundle ends up mounted
    /// later by something that assumes an earlier step checked it.
    @Test("bytes that do not match the digest are refused and deleted")
    func refusesAndDeletesAMismatch() async throws {
        let source = try Self.sourceFile(contents: "not what the release published")
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

        let wrong = String(repeating: "ab", count: 32)
        let before = Self.leftoverCount()
        await #expect(throws: SelfUpdate.Failure.self) {
            _ = try await SelfUpdate.download(
                asset: Self.asset(url: source, digest: "sha256:\(wrong)"),
                sha256: wrong, onProgress: { _ in })
        }
        #expect(Self.leftoverCount() == before,
                "a rejected download was left in the temporary directory")
    }

    /// An unreachable host: the error is reported as a download failure rather than surfacing
    /// as a digest mismatch, and again nothing is left behind. The two must stay
    /// distinguishable — one means "try again", the other means "do not install this".
    @Test("a transport failure is reported as one, and leaves nothing behind")
    func reportsTransportFailure() async throws {
        // Port 1 on the loopback: nothing listens, and no packet leaves the machine.
        let url = URL(string: "http://127.0.0.1:1/GitPic.dmg")!
        let before = Self.leftoverCount()
        do {
            _ = try await SelfUpdate.download(
                asset: ReleaseAsset(name: "GitPic-0.19.0-macos-arm64.dmg", size: 1,
                                    url: url.absoluteString,
                                    digest: "sha256:\(String(repeating: "a", count: 64))"),
                sha256: String(repeating: "a", count: 64), onProgress: { _ in })
            Issue.record("a connection to a closed port must not succeed")
        } catch let failure as SelfUpdate.Failure {
            guard case .download = failure else {
                Issue.record("expected a download failure, got \(failure)")
                return
            }
        }
        #expect(Self.leftoverCount() == before,
                "a failed download was left in the temporary directory")
    }

    /// Progress is reported, ends at the full size, and never exceeds it.
    @Test("progress is reported while downloading")
    func reportsProgress() async throws {
        let source = try Self.sourceFile(contents: String(repeating: "x", count: 400_000))
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let sha = try SelfUpdate.sha256OfFile(at: source)
        let size = Int64(400_000)

        // A lock rather than an actor: the callback is `@Sendable` and synchronous, which is
        // the same constraint `DownloadDelegate` itself is written against.
        let seen = Locked<[SelfUpdate.Progress]>([])
        let file = try await SelfUpdate.download(
            asset: Self.asset(url: source, digest: "sha256:\(sha)"),
            sha256: sha, onProgress: { progress in seen.withLock { $0.append(progress) } })
        defer { try? FileManager.default.removeItem(at: file) }

        let reports = seen.value
        #expect(!reports.isEmpty, "no progress was reported")
        #expect(reports.allSatisfy { $0.received <= size })
        #expect(reports.last?.received == size)
    }

    /// A file of `contents` in its own directory, so the caller can delete the directory.
    private static func sourceFile(contents: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitpic-src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("GitPic-0.19.0-macos-arm64.dmg")
        try Data(contents.utf8).write(to: file)
        return file
    }

    private static func asset(url: URL, digest: String) -> ReleaseAsset {
        ReleaseAsset(name: "GitPic-0.19.0-macos-arm64.dmg", size: 1,
                     url: url.absoluteString, digest: digest)
    }

    /// How many of this feature's temporary downloads are sitting in the temporary directory.
    /// Compared before and after, so another test's file cannot make this pass or fail.
    private static func leftoverCount() -> Int {
        let tmp = FileManager.default.temporaryDirectory
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
        return entries.filter { $0.hasPrefix("gitpic-update-") && $0.hasSuffix(".dmg") }.count
    }
}

/// Minimal lock box for collecting callback output in a test.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func withLock(_ body: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&stored)
    }
}
