import Testing
import Foundation
import AppKit
@testable import GitPicCore

/// The history pane's thumbnails: what gets fetched, what gets cached, and what is
/// refused.
///
/// The store is tested through a stubbed `URLProtocol` rather than mocked out, because
/// the claims worth pinning are all about *how many* requests a sequence of lookups
/// makes — one per image, ever. A fake that cannot count requests would leave exactly
/// the interesting part untested.
@Suite("History thumbnails")
struct ThumbnailTests {

    // MARK: - Fixtures

    /// A `w`×`h` PNG with a recognisable gradient, built rather than checked in so the
    /// suite needs no binary fixtures.
    static func png(w: Int, h: Int) throws -> Data {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32),
              let plane = rep.bitmapData else { throw Trouble.cannotMakeImage }
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                plane[i + 0] = UInt8(255 * x / max(1, w - 1))
                plane[i + 1] = UInt8(255 * y / max(1, h - 1))
                plane[i + 2] = 0x40
                plane[i + 3] = 0xFF
            }
        }
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw Trouble.cannotMakeImage
        }
        return data
    }

    /// The same image with a real alpha ramp down one edge.
    ///
    /// Every other PNG builder in this target sets `plane[i + 3] = 0xFF`
    /// unconditionally, so no fixture anywhere could notice a cache format that drops
    /// transparency — which is the one property `ThumbnailDecoder.pngData`'s doc says
    /// the PNG choice exists for.
    static func pngWithAlpha(w: Int, h: Int) throws -> Data {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32),
              let plane = rep.bitmapData else { throw Trouble.cannotMakeImage }
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                plane[i + 0] = 0xFF
                plane[i + 1] = 0x20
                plane[i + 2] = 0x20
                // Fully transparent on the left edge, opaque on the right.
                plane[i + 3] = UInt8(255 * x / max(1, w - 1))
            }
        }
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw Trouble.cannotMakeImage
        }
        return data
    }

    enum Trouble: Error { case cannotMakeImage }

    static let config = GitpicConfig(
        github: .init(owner: "o", repo: "r", branch: "main"),
        upload: .init(pathTemplate: "images/{year}/{month}/{hash8}-{name}.{ext}",
                      format: "md", linkKind: "cdn", dedup: true, autoCopy: true,
                      compress: false, maxWidth: 0, quality: 82))

    static func record(sha: String = "abc123def456", path: String = "images/a.png",
                       size: Int = 1024, deduped: Bool = false) -> HistoryRecord {
        HistoryRecord(time: "2026-08-22T10:00:00+08:00", name: "a", path: path,
                      url: "https://cdn.jsdelivr.net/gh/o/r@main/\(path)",
                      sha: sha, size: size, deduped: deduped)
    }

    /// `n` rows of `n` *different* images — distinct shas, distinct paths, so nothing
    /// here is deduped and each one is a unit of work of its own. What a pane full of
    /// ordinary history looks like to the store.
    static func sources(_ n: Int) -> [ThumbnailSource] {
        (0..<n).map { i in
            record(sha: String(format: "%040x", i + 0x1000), path: "images/\(i).png")
                .thumbnailSource(config: config)
        }
    }

    /// A fresh directory per test, so nothing leaks between them.
    static func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitpic-thumb-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Which address a row is fetched from

    @Test("the CDN is tried first and raw is kept behind it")
    func sourceTriesCDNThenRaw() {
        let source = Self.record().thumbnailSource(config: Self.config)
        #expect(source.urls == ["https://cdn.jsdelivr.net/gh/o/r@main/images/a.png",
                                "https://raw.githubusercontent.com/o/r/main/images/a.png"])
        #expect(source.sha == "abc123def456")
        #expect(source.byteSize == 1024)
    }

    /// A slashed branch has no parseable jsDelivr ref at all, so it must not be *tried*
    /// — a dead address in the list is one wasted request per row, on every row.
    @Test("a slashed branch skips the CDN rather than 404ing on it")
    func slashedBranchIsRawOnly() {
        var c = Self.config
        c.github.branch = "feat/x"
        #expect(LinkURL.cdnBranchIsAmbiguous(c.github.branch))
        #expect(Self.record().thumbnailSource(config: c).urls
                == ["https://raw.githubusercontent.com/o/r/feat/x/images/a.png"])
    }

    /// Both addresses of one image are one cache entry, because the key is the content.
    @Test("the cache key is the content, not the address")
    func cacheKeyIsContent() {
        // The normalised sha alone: this is the in-memory key, not a path, so it
        // carries neither the `.png` suffix nor the thumbnail size.
        #expect(Self.record().thumbnailSource(config: Self.config).cacheKey
                == "abc123def456")
        // A history line whose sha is not a sha still has to resolve to something.
        let broken = ThumbnailSource(sha: "../etc", urls: ["https://x/y.png"], byteSize: 1)
        #expect(broken.cacheKey == "https://x/y.png")
    }

    // MARK: - Cache keys are not allowed to be paths

    @Test("a blob sha becomes a filename, or nothing")
    func cacheFileNames() {
        #expect(ThumbnailCache.fileName(sha: "abc123", maxPixel: 160) == "abc123@160.png")
        #expect(ThumbnailCache.fileName(sha: "ABC123", maxPixel: 160) == "abc123@160.png")
        #expect(ThumbnailCache.fileName(sha: String(repeating: "a", count: 64), maxPixel: 160)
                == String(repeating: "a", count: 64) + "@160.png")
    }

    /// The size is part of what the cached bytes *are*, so it has to be part of the key.
    ///
    /// Without it, raising `ThumbnailLimits.maxPixel` — which its own doc says may
    /// happen when the box grows — left every already-cached row a hit, and `decode`
    /// does not upscale, so the pane drew the old small image in the new larger box for
    /// good: nothing but the size pruner ever deletes one of these files.
    @Test("the same blob at two thumbnail sizes is two cache files")
    func cacheFileNamesAreSizeSpecific() {
        let small = ThumbnailCache.fileName(sha: "abc123", maxPixel: 160)
        let large = ThumbnailCache.fileName(sha: "abc123", maxPixel: 320)
        #expect(small != large)
        // Still a plain filename, which is what the traversal guard is about, and still
        // `.png`, which is what the pruner filters on.
        #expect(large == "abc123@320.png")
    }

    /// `sha` is read out of `history.jsonl` and joined onto a directory path, so this
    /// is the guard that keeps a hostile or corrupt line from naming a file outside
    /// the cache. `appendingPathComponent` will not refuse any of these.
    @Test("a sha that is not hex is refused, separators and dots included")
    func cacheFileNamesRefuseTraversal() {
        #expect(ThumbnailCache.fileName(sha: "../../../../etc/passwd", maxPixel: 160) == nil)
        #expect(ThumbnailCache.fileName(sha: "..", maxPixel: 160) == nil)
        #expect(ThumbnailCache.fileName(sha: "a/b", maxPixel: 160) == nil)
        #expect(ThumbnailCache.fileName(sha: "a.b", maxPixel: 160) == nil)
        #expect(ThumbnailCache.fileName(sha: "abc123\u{0}", maxPixel: 160) == nil)
        #expect(ThumbnailCache.fileName(sha: "~", maxPixel: 160) == nil)
        #expect(ThumbnailCache.fileName(sha: "", maxPixel: 160) == nil)
        #expect(ThumbnailCache.fileName(sha: String(repeating: "a", count: 65), maxPixel: 160) == nil)
        // Hex-adjacent but not hex: `g` is out of range.
        #expect(ThumbnailCache.fileName(sha: "abcdefg", maxPixel: 160) == nil)
    }

    // MARK: - Pruning

    @Test("nothing is evicted while the cache is under the ceiling")
    func evictsNothingWhenSmall() {
        let entries = (0..<3).map {
            ThumbnailCache.Entry(url: URL(fileURLWithPath: "/c/\($0).png"), bytes: 100,
                                 modified: Date(timeIntervalSince1970: Double($0)))
        }
        #expect(ThumbnailCache.evictions(from: entries, ceiling: 1000).isEmpty)
    }

    @Test("the oldest go first, and only as many as it takes")
    func evictsOldestFirst() {
        let entries = (0..<5).map {
            ThumbnailCache.Entry(url: URL(fileURLWithPath: "/c/\($0).png"), bytes: 100,
                                 modified: Date(timeIntervalSince1970: Double($0)))
        }
        // 250 keeps the two newest (4, 3) and drops the rest.
        let evicted = ThumbnailCache.evictions(from: entries, ceiling: 250)
        #expect(Set(evicted.map(\.lastPathComponent)) == ["0.png", "1.png", "2.png"])
    }

    @Test("files written in the same second are ordered deterministically")
    func evictionTieBreak() {
        let same = Date(timeIntervalSince1970: 42)
        let entries = ["b", "a", "c"].map {
            ThumbnailCache.Entry(url: URL(fileURLWithPath: "/c/\($0).png"),
                                 bytes: 100, modified: same)
        }
        // Ties sort by path, so `a` is "newest" and `c` is dropped first.
        #expect(ThumbnailCache.evictions(from: entries, ceiling: 250).map(\.lastPathComponent)
                == ["c.png"])
    }

    // MARK: - The one line the pane shows while it waits

    /// `total == 0` is the entire signal the header reads, so it has to mean exactly one
    /// thing — nothing to say — and it must not be reachable any other way.
    @Test("idle is the only inactive reading")
    func progressIdleIsInactive() {
        #expect(ThumbnailProgress.idle == ThumbnailProgress(done: 0, total: 0))
        #expect(!ThumbnailProgress.idle.isActive)
        #expect(ThumbnailProgress(done: 0, total: 1).isActive)
        #expect(ThumbnailProgress(done: 12, total: 33).isActive)
        // A finished episode is reported as idle, never as 33/33 the reader has to know
        // to disregard — but if one is ever constructed by hand it is still "active".
        #expect(ThumbnailProgress(done: 33, total: 33).isActive)
    }

    // MARK: - Decoding

    @Test("decoding downscales to the requested edge and keeps the aspect ratio")
    func decodeDownscales() throws {
        let data = try Self.png(w: 800, h: 400)
        let image = try #require(ThumbnailDecoder.decode(data, maxPixel: 160))
        #expect(image.width == 160)
        #expect(image.height == 80)
    }

    @Test("an image already smaller than the ceiling is not blown up")
    func decodeDoesNotUpscale() throws {
        let data = try Self.png(w: 40, h: 20)
        let image = try #require(ThumbnailDecoder.decode(data, maxPixel: 160))
        #expect(max(image.width, image.height) <= 160)
        #expect(image.width == 40)
    }

    @Test("bytes that are not an image decode to nothing")
    func decodeRefusesGarbage() {
        #expect(ThumbnailDecoder.decode(Data("not an image".utf8), maxPixel: 160) == nil)
        #expect(ThumbnailDecoder.decode(Data(), maxPixel: 160) == nil)
        // A truncated PNG: the header is real, the rest is missing.
        let truncated = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        #expect(ThumbnailDecoder.decode(truncated, maxPixel: 160) == nil)
    }

    /// Dimensions *and* alpha.
    ///
    /// `pngData`'s doc justifies the format by what it preserves — "a JPEG round-trip
    /// would put a black box behind every transparent screenshot" — and this test
    /// asserted only the width and height, both of which survive a JPEG. Swapping
    /// `UTType.png` for `UTType.jpeg` left it green, and left `diskCacheSurvivesTheStore`
    /// green too, since the `.png` filename comes from `fileName` rather than from the
    /// encoder. Every transparent screenshot in the history pane would have gained a
    /// black box with the whole suite passing.
    @Test("the disk cache round-trips through PNG, transparency included")
    func pngRoundTrip() throws {
        let image = try #require(ThumbnailDecoder.decode(try Self.pngWithAlpha(w: 300, h: 300),
                                                         maxPixel: 64))
        let encoded = try #require(ThumbnailDecoder.pngData(image))
        let back = try #require(ThumbnailDecoder.decode(encoded, maxPixel: 64))
        #expect(back.width == image.width)
        #expect(back.height == image.height)
        // The alpha channel is still declared...
        #expect(back.alphaInfo != .none, "the cache format dropped the alpha channel")
        // ...and the transparent edge is still transparent. A JPEG round-trip composites
        // it onto black, which keeps the dimensions and loses this.
        let ctx = try #require(CGContext(
            data: nil, width: back.width, height: back.height, bitsPerComponent: 8,
            bytesPerRow: back.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(back, in: CGRect(x: 0, y: 0, width: back.width, height: back.height))
        let pixels = try #require(ctx.data).assumingMemoryBound(to: UInt8.self)
        // Left column, vertically central: alpha 0 in the source.
        let left = Int(pixels[(back.height / 2) * back.width * 4 + 3])
        let right = Int(pixels[(back.height / 2) * back.width * 4 + (back.width - 1) * 4 + 3])
        #expect(left < 32, "the transparent edge came back opaque (alpha \(left))")
        #expect(right > 223, "the opaque edge came back transparent (alpha \(right))")
    }

    // MARK: - The gate

    @Test("the gate never admits more than its limit at once")
    func gateBoundsConcurrency() async {
        let gate = FetchGate(limit: 2)
        let peak = Peak()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    await gate.acquire()
                    await peak.enter()
                    // Long enough that overlapping holders would be observed.
                    try? await Task.sleep(for: .milliseconds(20))
                    await peak.leave()
                    await gate.release()
                }
            }
        }
        #expect(await peak.highest <= 2)
        // And it really did run concurrently, or the bound above proves nothing.
        #expect(await peak.highest == 2)
    }

    actor Peak {
        private var current = 0
        private(set) var highest = 0
        func enter() { current += 1; highest = max(highest, current) }
        func leave() { current -= 1 }
    }

    // MARK: - The store, counted request by request

    /// Serialized, and that is not caution — it is measured.
    ///
    /// A `URLProtocol` stub is process-global however it is registered: `protocolClasses`
    /// picks the class per session, but the class's own state is shared by every
    /// instance Foundation makes of it. Run in parallel, these tests counted each
    /// other's requests — the 404 test saw 2 requests where 1 was made, and the
    /// shared-fetch test saw 0 and got the 404 test's response body. Serializing the
    /// suite is what makes "one request, ever" a statement about the store rather than
    /// about which test won a race.
    @Suite("Thumbnail store", .serialized)
    struct StoreTests {

    @Test("one image is fetched once, then served from memory")
    func fetchesOnceThenMemory() async throws {
        let stub = Stub(body: try ThumbnailTests.png(w: 400, h: 300))
        let store = ThumbnailStore(directory: ThumbnailTests.tempDir(), session: stub.session)
        let source = ThumbnailTests.record().thumbnailSource(config: ThumbnailTests.config)

        let first = await store.thumbnail(for: source)
        #expect(first.thumbnail?.pixelWidth == 160)
        #expect(stub.requests == 1)

        // Same row again, and a second row of the same image: neither may hit the
        // network. This is the whole reason the store exists.
        _ = await store.thumbnail(for: source)
        _ = await store.thumbnail(for: source)
        #expect(stub.requests == 1)
    }

    @Test("a second store on the same directory reads the disk, not the network")
    func diskCacheSurvivesTheStore() async throws {
        let dir = ThumbnailTests.tempDir()
        let stub = Stub(body: try ThumbnailTests.png(w: 400, h: 300))
        let source = ThumbnailTests.record().thumbnailSource(config: ThumbnailTests.config)

        let first = ThumbnailStore(directory: dir, session: stub.session)
        _ = await first.thumbnail(for: source)
        #expect(stub.requests == 1)
        // Named by the blob sha *and* the size it was decoded at — asked of the same
        // function the store uses, so a change to the naming cannot make this test
        // silently look somewhere the store never writes.
        let named = try #require(ThumbnailCache.fileName(sha: "abc123def456",
                                                         maxPixel: ThumbnailLimits().maxPixel))
        #expect(named == "abc123def456@160.png", "the shape is still a plain filename")
        let cached = dir.appendingPathComponent(named)
        #expect(FileManager.default.fileExists(atPath: cached.path))

        // A fresh store is what a relaunch looks like: empty memory, same directory.
        let second = ThumbnailStore(directory: dir, session: stub.session)
        let hit = await second.thumbnail(for: source)
        #expect(hit.thumbnail?.pixelWidth == 160)
        #expect(stub.requests == 1, "a cached thumbnail must not be re-downloaded")
    }

    /// Content-addressed, so it is the *bytes* that are cached and not the address:
    /// after `github.repo` changes, the same image is still one disk read.
    @Test("the cache follows the content, not the URL")
    func cacheKeyedByContent() async throws {
        let dir = ThumbnailTests.tempDir()
        let stub = Stub(body: try ThumbnailTests.png(w: 400, h: 300))
        let store = ThumbnailStore(directory: dir, session: stub.session)
        let record = ThumbnailTests.record()

        _ = await store.thumbnail(for: record.thumbnailSource(config: ThumbnailTests.config))
        #expect(stub.requests == 1)

        var moved = ThumbnailTests.config
        moved.github.repo = "elsewhere"
        let relocated = record.thumbnailSource(config: moved)
        #expect(relocated.urls.allSatisfy { $0.contains("elsewhere") })
        let hit = await store.thumbnail(for: relocated)
        #expect(hit.thumbnail != nil)
        #expect(stub.requests == 1, "same sha, so the new address is still a cache hit")
    }

    @Test("an original past the size ceiling is never requested")
    func oversizedIsNotRequested() async throws {
        let stub = Stub(body: try ThumbnailTests.png(w: 400, h: 300))
        let store = ThumbnailStore(
            directory: ThumbnailTests.tempDir(),
            limits: ThumbnailLimits(maxSourceBytes: 1024),
            session: stub.session)
        let big = ThumbnailTests.record(size: 4096).thumbnailSource(config: ThumbnailTests.config)

        let result = await store.thumbnail(for: big)
        #expect(result.failure == .tooLarge(bytes: 4096, ceiling: 1024))
        #expect(stub.requests == 0, "the recorded size is enough to refuse it")
    }

    @Test("a CDN miss falls through to raw instead of showing a hole")
    func cdnMissFallsBackToRaw() async throws {
        // Exactly the fresh-upload case: jsDelivr has not caught up, GitHub has it.
        let png = try ThumbnailTests.png(w: 400, h: 300)
        let stub = Stub { url in
            url.host == "cdn.jsdelivr.net" ? (Data("not yet".utf8), 404) : (png, 200)
        }
        let store = ThumbnailStore(directory: ThumbnailTests.tempDir(), session: stub.session)
        let result = await store.thumbnail(
            for: ThumbnailTests.record().thumbnailSource(config: ThumbnailTests.config))
        #expect(result.thumbnail?.pixelWidth == 160)
        #expect(stub.requests == 2, "one wasted CDN request, then the fallback")
    }

    @Test("when both addresses fail it is raw's answer that is reported")
    func bothFailReportsRaw() async throws {
        // raw is authoritative, so its 410 is the one worth showing — not the CDN 404
        // that precedes it and means nothing here.
        let stub = Stub { url in
            url.host == "cdn.jsdelivr.net" ? (Data(), 404) : (Data(), 410)
        }
        let store = ThumbnailStore(directory: ThumbnailTests.tempDir(), session: stub.session)
        let result = await store.thumbnail(
            for: ThumbnailTests.record().thumbnailSource(config: ThumbnailTests.config))
        #expect(result.failure == .http(status: 410))
        #expect(stub.requests == 2)
    }

    @Test("a 404 is reported as a 404, and nothing is cached")
    func notFound() async throws {
        let dir = ThumbnailTests.tempDir()
        let stub = Stub(body: Data("nope".utf8), status: 404)
        let store = ThumbnailStore(directory: dir, session: stub.session)

        let result = await store.thumbnail(for: ThumbnailTests.record().thumbnailSource(config: ThumbnailTests.config))
        #expect(result.failure == .http(status: 404))
        #expect(stub.requests == 2, "both addresses tried before giving up")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
        // The message has to name both causes: raw answers 404 for a private
        // repository exactly as it does for a missing file.
        let message = try #require(result.failure?.message)
        #expect(message.contains("404"))
        #expect(message.contains("私有"))
    }

    @Test("bytes that are not an image are reported as undecodable, not as success")
    func servedGarbage() async throws {
        let stub = Stub(body: Data("<html>rate limited</html>".utf8))
        let store = ThumbnailStore(directory: ThumbnailTests.tempDir(), session: stub.session)
        let result = await store.thumbnail(for: ThumbnailTests.record().thumbnailSource(config: ThumbnailTests.config))
        #expect(result.failure == .undecodable)
        // Bytes that will not decode are a failed candidate like any other, so the
        // fallback is still tried rather than the row giving up on the first host.
        #expect(stub.requests == 2)
    }

    @Test("two rows of the same image share one request")
    func concurrentRowsShareOneFetch() async throws {
        let stub = Stub(body: try ThumbnailTests.png(w: 400, h: 300), delay: .milliseconds(60))
        let store = ThumbnailStore(directory: ThumbnailTests.tempDir(), session: stub.session)
        // A deduped upload is exactly this: a second history row, same sha, same path.
        let a = ThumbnailTests.record().thumbnailSource(config: ThumbnailTests.config)
        let b = ThumbnailTests.record(deduped: true).thumbnailSource(config: ThumbnailTests.config)
        #expect(a == b)

        async let first = store.thumbnail(for: a)
        async let second = store.thumbnail(for: b)
        let (x, y) = await (first, second)
        #expect(x.thumbnail != nil)
        #expect(y.thumbnail != nil)
        #expect(stub.requests == 1, "the second row must join the first row's fetch")
    }

    // MARK: Progress, and the silence that matters more

    /// Everything a watcher was told, in order, so a test can assert on the sequence
    /// rather than on one sampled moment.
    ///
    /// `progressUpdates()` buffers only the newest reading — a progress count is a state
    /// and a late consumer wants the current one — so a slow watcher may legitimately
    /// miss intermediate values. Nothing here asserts that *every* step was seen; the
    /// claims are about which readings are possible and which are forbidden.
    actor Watch {
        private(set) var seen: [ThumbnailProgress] = []
        func add(_ p: ThumbnailProgress) { seen.append(p) }
        var active: [ThumbnailProgress] { seen.filter(\.isActive) }
    }

    /// **The pane that has nothing to fetch must say nothing, and this is the test that
    /// says so.**
    ///
    /// It is the common case — every open after the first — and a line that appeared and
    /// vanished inside 10 ms on each of them would be a flash of garbage added to the one
    /// case that was already fine. Cache hits are not fetches, so no episode ever opens
    /// and the grace timer is never even armed.
    ///
    /// Run with the **default** limits on purpose: 300 ms is the number shipping, so it
    /// is the number under test. Four disk reads and decodes against a 300 ms budget is
    /// the same three orders of magnitude of headroom the real pane has.
    @Test("a pane whose thumbnails are all cached reports nothing at all")
    func cachedPaneStaysSilent() async throws {
        let dir = ThumbnailTests.tempDir()
        let stub = Stub(body: try ThumbnailTests.png(w: 400, h: 300))
        let sources = ThumbnailTests.sources(4)

        let cold = ThumbnailStore(directory: dir, session: stub.session)
        for source in sources { _ = await cold.thumbnail(for: source) }
        #expect(stub.requests == 4)

        // A fresh store over the same directory: empty memory, four disk hits. Exactly
        // the second open of the window, or the first one after a relaunch.
        let warm = ThumbnailStore(directory: dir, session: stub.session)
        let watch = Watch()
        let stream = await warm.progressUpdates()
        let watching = Task { for await update in stream { await watch.add(update) } }

        await withTaskGroup(of: Void.self) { group in
            for source in sources {
                group.addTask { _ = await warm.thumbnail(for: source) }
            }
        }
        // Comfortably past the 300 ms grace, so a reveal that was going to fire has.
        try await Task.sleep(for: .milliseconds(500))
        watching.cancel()

        #expect(stub.requests == 4, "the warm store must not have gone to the network")
        #expect(await watch.active.isEmpty, "a cached pane must never say 正在取缩略图")
        // Silence is not the same as an empty stream: a subscriber is always told where
        // things stand, and here that is `idle`.
        #expect(await watch.seen == [.idle])
    }

    /// The cold pane this whole signal exists for: a running count, a denominator that
    /// does not move, and silence at the end.
    ///
    /// `concurrentFetches: 1` staggers the images 60 ms apart so the count is observable
    /// at all — at the shipping 8 they would finish together and there would be no middle
    /// to catch. It also pins the claim that matters most about the denominator: all three
    /// are counted from the start, while two of them are still only *queued* at the gate.
    /// A total that grew as slots freed up would be a number crawling upward for as long
    /// as the fill takes.
    ///
    /// The grace is short but **not zero**, and that is the point rather than an
    /// impatience: announcing is a disk miss and one actor hop, so every image in a burst
    /// is counted within a millisecond or two of the pane opening, and any grace at all
    /// puts the reveal after all of them. That is the same ordering the shipping 300 ms
    /// has against a four-second fill — reveal a settled denominator, never a climbing
    /// one. At exactly zero the reveal races the burst and 0/1 is a legitimate first
    /// reading, which is a fact about `.zero` and not about the pane.
    @Test("a slow fill is reported as a running count over a fixed total")
    func slowFillIsReported() async throws {
        let stub = Stub(body: try ThumbnailTests.png(w: 400, h: 300),
                        delay: .milliseconds(60))
        let store = ThumbnailStore(
            directory: ThumbnailTests.tempDir(),
            limits: ThumbnailLimits(concurrentFetches: 1,
                                    progressGrace: .milliseconds(30)),
            session: stub.session)
        let sources = ThumbnailTests.sources(3)

        let watch = Watch()
        let stream = await store.progressUpdates()
        let watching = Task { for await update in stream { await watch.add(update) } }

        await withTaskGroup(of: Void.self) { group in
            for source in sources {
                group.addTask { _ = await store.thumbnail(for: source) }
            }
        }
        // One more scheduling round for the final `idle` to be delivered.
        try await Task.sleep(for: .milliseconds(50))
        watching.cancel()

        let active = await watch.active
        #expect(!active.isEmpty, "three 60 ms fetches must be reported")
        #expect(active.allSatisfy { $0.total == 3 },
                "the denominator is the images asked for, and it does not move")
        #expect(active.contains { $0.total == 3 && $0.done < 3 },
                "images waiting at the gate are counted as outstanding, not as absent")
        #expect(active.contains { $0.done > 0 && $0.done < $0.total },
                "a running count, not a binary flag")
        #expect(zip(active, active.dropFirst()).allSatisfy { $0.done <= $1.done },
                "the count never goes backwards")
        #expect(await watch.seen.last == .idle,
                "the line has to go away when the pane is full")
    }

    /// An image refused by the size ceiling is never requested, so it is not work in
    /// progress — it is a row that already has its answer. Counting it would leave a
    /// denominator including images that by definition never arrive.
    @Test("an image refused without a request is never counted as work")
    func refusedImagesAreNotWork() async throws {
        let stub = Stub(body: try ThumbnailTests.png(w: 400, h: 300))
        let store = ThumbnailStore(
            directory: ThumbnailTests.tempDir(),
            // Zero grace, so nothing is being hidden by the timer: if it were counted at
            // all, it would be reported.
            limits: ThumbnailLimits(maxSourceBytes: 1024, progressGrace: .zero),
            session: stub.session)
        let watch = Watch()
        let stream = await store.progressUpdates()
        let watching = Task { for await update in stream { await watch.add(update) } }

        let big = ThumbnailTests.record(size: 4096).thumbnailSource(config: ThumbnailTests.config)
        #expect(await store.thumbnail(for: big).failure
                == .tooLarge(bytes: 4096, ceiling: 1024))
        try await Task.sleep(for: .milliseconds(50))
        watching.cancel()

        #expect(stub.requests == 0)
        #expect(await watch.seen == [.idle])
    }

    /// The count is over *images*, which is what the pane's boxes actually wait on: two
    /// rows of one deduped upload share a single GET, and one CDN miss that falls through
    /// to raw is two requests for one picture. Either counted per request would report
    /// work nobody is waiting on.
    @Test("one image is one unit of work, however many rows and requests it takes")
    func oneImageIsOneUnitOfWork() async throws {
        let png = try ThumbnailTests.png(w: 400, h: 300)
        // The fresh-upload case: jsDelivr has not caught up, GitHub has it.
        let stub = Stub(delay: .milliseconds(60)) { url in
            url.host == "cdn.jsdelivr.net" ? (Data("not yet".utf8), 404) : (png, 200)
        }
        let store = ThumbnailStore(
            directory: ThumbnailTests.tempDir(),
            limits: ThumbnailLimits(progressGrace: .zero),
            session: stub.session)
        let watch = Watch()
        let stream = await store.progressUpdates()
        let watching = Task { for await update in stream { await watch.add(update) } }

        // Two rows, one sha, one path — a deduped upload is exactly this.
        let a = ThumbnailTests.record().thumbnailSource(config: ThumbnailTests.config)
        let b = ThumbnailTests.record(deduped: true).thumbnailSource(config: ThumbnailTests.config)
        async let first = store.thumbnail(for: a)
        async let second = store.thumbnail(for: b)
        let (x, y) = await (first, second)
        #expect(x.thumbnail != nil)
        #expect(y.thumbnail != nil)
        try await Task.sleep(for: .milliseconds(50))
        watching.cancel()

        #expect(stub.requests == 2, "one wasted CDN request, then the fallback")
        let active = await watch.active
        #expect(!active.isEmpty)
        #expect(active.allSatisfy { $0.total == 1 },
                "two rows and two requests, but one image and so one unit of work")
        #expect(await watch.seen.last == .idle)
    }

    /// A second pane arriving mid-fill has to be told where things stand, not left blank
    /// until the next image happens to land — 历史 can be closed and reopened while the
    /// fill it started is still running, and the fetches deliberately survive that.
    @Test("a subscriber that arrives late is told the current count immediately")
    func lateSubscriberSeesCurrentCount() async throws {
        let stub = Stub(body: try ThumbnailTests.png(w: 400, h: 300),
                        delay: .milliseconds(400))
        let store = ThumbnailStore(
            directory: ThumbnailTests.tempDir(),
            limits: ThumbnailLimits(concurrentFetches: 1, progressGrace: .zero),
            session: stub.session)
        let sources = ThumbnailTests.sources(3)

        let filling = Task {
            await withTaskGroup(of: Void.self) { group in
                for source in sources {
                    group.addTask { _ = await store.thumbnail(for: source) }
                }
            }
        }

        // Wait for the *event*, not for a clock.
        //
        // This is the fix for a real flake, and the reason is worth keeping: the first
        // version slept 180 ms to land "into the second of three 120 ms fetches" and then
        // asserted that one had finished. It passed here five runs in a row and failed on
        // CI, where the first fetch had not completed inside that window — so it read 0/3
        // and failed a claim the store was actually honouring. A sleep long enough to be
        // safe on every machine is a sleep nobody can pick.
        //
        // So the precondition is established by watching the store say so. One
        // subscription is consumed until it reports an image landed while others are
        // still outstanding, which is exactly the state a second pane has to be told
        // about. The 400 ms delay is slack now rather than timing: the loop breaks the
        // moment the first fetch lands, leaving two serialized fetches — about 800 ms —
        // before the episode could end and reset the counts underneath the assertions.
        var watcher = await store.progressUpdates().makeAsyncIterator()
        var midFill: ThumbnailProgress?
        var sawWork = false
        while let update = await watcher.next() {
            if update.isActive { sawWork = true }
            if update.done >= 1, update.done < update.total {
                midFill = update
                break
            }
            // An episode ending resets the counts, so work-then-idle means the fill
            // outran this loop and the state under test can no longer occur. Break
            // rather than wait for it forever.
            if sawWork, !update.isActive { break }
        }
        let observed = try #require(midFill, "never observed a partly-finished fill")
        #expect(observed.total == 3)

        // The claim itself: a subscription made at this moment is handed the count that
        // already stands, not a blank it has to wait for the next image to fill in.
        var late = await store.progressUpdates().makeAsyncIterator()
        let first = await late.next()
        #expect(first?.isActive == true, "the very first reading must not be a blank one")
        #expect(first?.total == 3)
        #expect((first?.done ?? -1) >= 1, "it is told what has already landed")
        await filling.value
    }

    }

    // MARK: - The glyphs the pane draws

    /// A misspelled SF Symbol draws nothing at all and is invisible in review.
    @Test("the pane's symbols exist on this system", arguments: [
        "photo", "photo.badge.exclamationmark", "doc.on.doc.fill", "doc.on.clipboard",
    ])
    func symbolsResolve(name: String) {
        #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil)
    }
}

// MARK: - Test doubles

extension Result where Success == Thumbnail, Failure == ThumbnailFailure {
    var thumbnail: Thumbnail? { try? get() }
    var failure: ThumbnailFailure? {
        if case .failure(let f) = self { return f }
        return nil
    }
}

/// A `URLProtocol` that answers every request from memory and counts them.
///
/// Counting is the point: "fetched once, ever" is not observable any other way.
///
/// Registered per-session through `protocolClasses` rather than
/// `URLProtocol.registerClass`, which keeps it out of the way of every other suite —
/// but it is **not** isolation between two stubs, because the protocol class's own
/// state is shared. `StoreTests` is serialized for that reason.
final class Stub: @unchecked Sendable {
    let session: URLSession
    private let lock = NSLock()
    private var count = 0

    var requests: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    /// One answer for every address.
    convenience init(body: Data, status: Int = 200, delay: Duration = .zero) {
        self.init(delay: delay) { _ in (body, status) }
    }

    /// A different answer per address — how the CDN-then-raw walk is observed.
    init(delay: Duration = .zero, answer: @escaping @Sendable (URL) -> (Data, Int)) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        session = URLSession(configuration: config)
        StubProtocol.install(.init(answer: answer, delay: delay)) { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.count += 1; self.lock.unlock()
        }
    }
}

final class StubProtocol: URLProtocol {
    struct Response: Sendable {
        let answer: @Sendable (URL) -> (Data, Int)
        let delay: Duration
    }

    /// One installed response at a time, guarded by a lock: `URLProtocol` is
    /// instantiated by Foundation on its own threads, so this cannot be actor state.
    private nonisolated(unsafe) static var current: Response?
    private nonisolated(unsafe) static var onRequest: (@Sendable () -> Void)?
    private static let lock = NSLock()

    static func install(_ response: Response, onRequest: @escaping @Sendable () -> Void) {
        lock.lock()
        current = response
        self.onRequest = onRequest
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        StubProtocol.lock.lock()
        let response = StubProtocol.current
        let notify = StubProtocol.onRequest
        StubProtocol.lock.unlock()
        notify?()
        guard let response, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        if response.delay != .zero {
            let c = response.delay.components
            Thread.sleep(forTimeInterval: Double(c.seconds) + Double(c.attoseconds) / 1e18)
        }
        let (body, status) = response.answer(url)
        let http = HTTPURLResponse(url: url, statusCode: status,
                                   httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "image/png"])!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
