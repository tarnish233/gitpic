import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Thumbnails for the history pane, fetched from the image host and cached by
/// content hash.
///
/// The history file records what was uploaded, not what was on disk: a row carries
/// `path`, `sha` and `size` and no trace of the local file it came from
/// (`src/commands/upload.rs:187-195`), which is almost always gone or moved by the
/// time anyone opens the pane. So a thumbnail is a network read, and everything here
/// exists to make that read happen at most once per image, ever.

// MARK: - What to fetch

/// One row's image, reduced to the three things fetching it needs.
///
/// A value rather than a `HistoryRecord` reference so the fetch cannot silently
/// start depending on more of the row than this — and so `.task(id:)` in the UI can
/// compare it: `url` moves when `github.owner/repo/branch` change, which is exactly
/// when a row's thumbnail has to be re-resolved.
public struct ThumbnailSource: Sendable, Hashable {
    /// GitHub's blob sha for the content. Content-addressed, which is what makes it
    /// safe as a cache key: it cannot go stale, because different bytes are a
    /// different key.
    public let sha: String
    /// Addresses to try, in order, until one yields an image. Never empty.
    ///
    /// A list rather than one address because the fast host and the authoritative
    /// host are not the same host — see ``HistoryRecord/thumbnailSource(config:)``.
    public let urls: [String]
    /// The size recorded at upload — the cheap guard that keeps a 40 MB original
    /// from ever being requested for a 160 px thumbnail.
    public let byteSize: Int

    public init(sha: String, urls: [String], byteSize: Int) {
        self.sha = sha
        self.urls = urls
        self.byteSize = byteSize
    }

    /// What the caches are keyed by.
    ///
    /// The sha where there is a usable one, so the key is the *content* and not the
    /// address: the same image is one cache entry whether it was reached over the CDN
    /// or over raw, and it stays one entry after `github.repo` changes underneath it.
    /// Falls back to the first address only for a history line whose sha is not a sha,
    /// which is a corrupt record rather than a case to optimise.
    public var cacheKey: String {
        ThumbnailCache.fileName(sha: sha) ?? urls.first ?? sha
    }
}

extension HistoryRecord {
    /// This row's thumbnail: **jsDelivr first, `raw.githubusercontent.com` behind
    /// it.** Both, in that order, because neither host alone is right.
    ///
    /// **Not a speed choice — that was measured, and between these two hosts it is a
    /// wash.** Fetching all 33 distinct images of this machine's history eight at a
    /// time, two rounds each: jsDelivr 5.16 s then 4.11 s, raw 6.03 s then 3.59 s. One
    /// file re-fetched three times had suggested jsDelivr was 2–3× ahead (TTFB
    /// 0.29–0.31 s against 0.79–0.94 s); over 33 files cold at the edge it is not, and
    /// the single-file figure does not generalise.
    ///
    /// The CDN goes first for two reasons that are not throughput. It is the address
    /// the config points at by default (`upload.link_kind = "cdn"`), so the pane
    /// exercises the same host the user's published links do. And jsDelivr is reachable
    /// from networks that cannot reach `raw.githubusercontent.com` at all — for a
    /// tool whose UI is Simplified Chinese that is the difference between a pane of
    /// pictures and a pane of placeholders.
    ///
    /// Raw is the fallback and not the choice, because it is the one that cannot be
    /// missing or behind:
    ///
    /// - A branch containing `/` has no parseable jsDelivr ref at all
    ///   (``LinkURL/cdnBranchIsAmbiguous(_:)``). Such a repository gets `[raw]` and no
    ///   wasted request — without a fallback *every* row on it would be blank for a
    ///   reason having nothing to do with the image.
    /// - jsDelivr resolves a **branch** ref through its own cache rather than per
    ///   request, so an upload from minutes ago — the top of this pane, the rows
    ///   actually being looked at — can 404 there while being served fine by GitHub.
    ///   That 404 costs one request and then falls through, once, because the decoded
    ///   result is cached by content afterwards.
    ///
    /// This is thumbnails only. What gets *copied* still follows the configured target
    /// exactly, via ``UploadedLink``; a picture that loaded over the fallback is not a
    /// claim about the user's links, and `doctor` remains what tests those.
    public func thumbnailSource(config c: GitpicConfig) -> ThumbnailSource {
        let raw = rawURL(config: c)
        let branch = c.github.branch
        guard !LinkURL.cdnBranchIsAmbiguous(branch) else {
            return ThumbnailSource(sha: sha, urls: [raw], byteSize: size)
        }
        let cdn = LinkURL.cdn(owner: c.github.owner, repo: c.github.repo,
                              branch: branch, path: path)
        return ThumbnailSource(sha: sha, urls: [cdn, raw], byteSize: size)
    }
}

// MARK: - The image, and why there isn't one

/// A decoded thumbnail.
///
/// `@unchecked Sendable` for `CGImage`, which Foundation does not mark: a `CGImage`
/// is immutable by contract, this one is created by ImageIO and handed straight out,
/// and nothing here ever draws into it. That makes crossing an isolation boundary
/// with it safe in fact, which is the only claim `@unchecked` is allowed to make.
public struct Thumbnail: @unchecked Sendable {
    public let image: CGImage
    public init(_ image: CGImage) { self.image = image }

    public var pixelWidth: Int { image.width }
    public var pixelHeight: Int { image.height }
}

/// Why a row has no picture, in the cases where it has none.
///
/// Named rather than collapsed into one "加载失败", for the reason ``CDNUnavailable``
/// is: the causes need different things from the reader. A 404 on a private image
/// host is permanent and needs a decision; a transport error is worth retrying by
/// reopening the pane; an oversized original is working as designed.
public enum ThumbnailFailure: Sendable, Hashable, Error {
    /// The recorded upload size is past the ceiling, so nothing was requested.
    case tooLarge(bytes: Int, ceiling: Int)
    /// No address parsed. Only reachable from a history row written by something
    /// other than this CLI.
    case badURL(String)
    case http(status: Int)
    case transport(String)
    /// Bytes arrived and ImageIO could not make an image of them.
    case undecodable

    /// What to show the user, naming the likely cause where there is one.
    public var message: String {
        switch self {
        case .tooLarge(let bytes, let ceiling):
            return "原图 \(Self.mb(bytes))，超过缩略图的 \(Self.mb(ceiling)) 上限，没有下载"
        case .badURL(let url):
            return "链接不合法，取不了：\(url)"
        case .http(404):
            // Both causes, because raw.githubusercontent.com answers 404 for a
            // private repository exactly as it does for a missing file, and the app
            // holds no token to tell them apart (the CLI gets one from `gh auth
            // token` per invocation; nothing here keeps a credential).
            return "取不到（404）：私有图床的 raw 链接需要令牌，App 不持有；"
                 + "也可能是 owner/repo/branch 改过了，或这张图已被删"
        case .http(let status):
            return "GitHub 返回 \(status)"
        case .transport(let why):
            return "取图失败：\(why)"
        case .undecodable:
            return "下载到了，但解不出图像"
        }
    }

    private static func mb(_ n: Int) -> String {
        String(format: "%.0f MB", Double(n) / (1024 * 1024))
    }
}

// MARK: - Decoding

/// Full-size bytes in, small `CGImage` out.
public enum ThumbnailDecoder {

    /// Decode straight to thumbnail size, never to full resolution.
    ///
    /// `CGImageSourceCreateThumbnailAtIndex` and not `NSImage(data:)` for one
    /// measurable reason: it decodes *at* the requested size, so a 6000×4000 photo
    /// never becomes a 96 MB bitmap on the way to a 160 px picture.
    ///
    /// `FromImageAlways` rather than `IfAbsent`, which would prefer a JPEG's embedded
    /// thumbnail — cheaper, and free to be a stale or cropped image that does not
    /// match the file. A history pane showing something other than what is in the
    /// repository is worse than a slower decode.
    ///
    /// `WithTransform` applies the EXIF orientation, so a phone photo is not sideways.
    public static func decode(_ data: Data, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// PNG, for the disk cache. Lossless and alpha-preserving, so a cached
    /// thumbnail is exactly the one that was decoded — a JPEG round-trip would put a
    /// black box behind every transparent screenshot.
    public static func pngData(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}

// MARK: - Cache bookkeeping

/// The pure decisions the on-disk cache rests on, kept out of the actor so they can
/// be tested without a filesystem or a network.
public enum ThumbnailCache {

    /// The cache filename for a blob sha, or `nil` if that sha cannot be one.
    ///
    /// **This is a path-injection guard, not a formality.** `sha` is read out of
    /// `~/.local/share/gitpic/history.jsonl` — an append-only text file any process
    /// can write — and it is about to be joined onto a directory path. A value of
    /// `../../../../Library/Preferences/com.apple.dock` has to be refused *here*,
    /// because `appendingPathComponent` will not refuse it.
    ///
    /// Hex only, lowercased, at most 64 characters: that admits git's SHA-1 (40) and
    /// a future SHA-256 (64), and admits no separator, no `.`, and no `..`.
    public static func fileName(sha: String) -> String? {
        guard (1...64).contains(sha.count) else { return nil }
        var out = ""
        out.reserveCapacity(sha.count + 4)
        for c in sha.unicodeScalars {
            switch c {
            case "0"..."9", "a"..."f": out.unicodeScalars.append(c)
            case "A"..."F":            out += String(Character(c)).lowercased()
            default:                   return nil
            }
        }
        return out + ".png"
    }

    /// One cached file, as the pruner sees it.
    public struct Entry: Sendable, Hashable {
        public let url: URL
        public let bytes: Int
        public let modified: Date

        public init(url: URL, bytes: Int, modified: Date) {
            self.url = url
            self.bytes = bytes
            self.modified = modified
        }
    }

    /// Which files to delete to bring the cache back under `ceiling`, newest kept.
    ///
    /// The same shape as the CLI's history trim (`src/history.rs:trim_file`): a
    /// ceiling, oldest evicted first, and a best-effort job that runs after the thing
    /// worth keeping is already on disk. Newest-first because that is what the pane
    /// shows — `list --limit 100` returns the tail of the history.
    ///
    /// Ties on `modified` are broken by path so the choice is deterministic; a
    /// directory of thumbnails written in the same second is otherwise ordered by
    /// whatever `contentsOfDirectory` felt like returning, and a test could not pin
    /// it.
    ///
    /// Deletes *every* file if one alone is over the ceiling — no minimum retained
    /// set. That is reachable only with a ceiling smaller than a single 160 px PNG,
    /// which is a misconfiguration rather than a state to design around.
    public static func evictions(from entries: [Entry], ceiling: Int) -> [URL] {
        let newestFirst = entries.sorted {
            $0.modified == $1.modified ? $0.url.path < $1.url.path : $0.modified > $1.modified
        }
        var kept = 0
        var evict: [URL] = []
        for e in newestFirst {
            if kept + e.bytes <= ceiling {
                kept += e.bytes
            } else {
                evict.append(e.url)
            }
        }
        return evict
    }
}

// MARK: - Limits

/// Every number the store runs on, in one place so a test can shrink them.
public struct ThumbnailLimits: Sendable, Hashable {
    /// Longest edge of the decoded thumbnail, in pixels.
    ///
    /// 160 for a 44×32 pt box: Retina needs 88×64 and the box may yet grow, so this
    /// is 2× with room. Costs ~10–40 KB per cached PNG.
    public var maxPixel: Int
    /// Originals past this are never requested. A screenshot is a fraction of it;
    /// GitHub's own Contents-API cap is 100 MB (`src/github.rs:CONTENTS_PUT_MAX`),
    /// so without a ceiling here one uploaded video-frame dump would be a 40 MB GET
    /// for a picture 44 pt wide.
    public var maxSourceBytes: Int
    /// Ceiling for the thumbnail directory, pruned oldest-first past it.
    public var maxDiskBytes: Int
    /// Decoded thumbnails held in memory. 120 covers a full `list --limit 100` pane
    /// with room, at roughly 100 KB each worst case.
    public var memoryCount: Int
    /// Concurrent GETs — the number that actually decides how long a cold pane takes.
    ///
    /// There is no "only fetch what is visible" to lean on here: `Form` + `ForEach` on
    /// macOS realises **every** row when the pane appears, measured — opening 历史 on a
    /// 37-row history and touching nothing put all 33 distinct images in the cache. So a
    /// cold history is one burst of N requests whatever this is set to, and this only
    /// decides how wide the burst is. Measured over those 33 images: four at a time
    /// 6.26 s, eight 4.11–5.16 s, twelve 2.21 s.
    ///
    /// Eight rather than twelve is politeness, not a client limit. These come off a CDN
    /// serving them for free, and shaving two seconds off a cost paid once per image is
    /// not worth being the app that opens twelve connections at once.
    public var concurrentFetches: Int

    public init(maxPixel: Int = 160,
                maxSourceBytes: Int = 12 * 1024 * 1024,
                maxDiskBytes: Int = 32 * 1024 * 1024,
                memoryCount: Int = 120,
                concurrentFetches: Int = 8) {
        self.maxPixel = maxPixel
        self.maxSourceBytes = maxSourceBytes
        self.maxDiskBytes = maxDiskBytes
        self.memoryCount = memoryCount
        self.concurrentFetches = concurrentFetches
    }
}

// MARK: - The gate

/// Admits at most `limit` holders at a time.
///
/// Its own actor rather than state on ``ThumbnailStore``, because the code that has
/// to wait on it is deliberately *not* on that actor: a download and an ImageIO
/// decode running on the store's executor would block every cache lookup behind
/// them. This is the one piece both sides touch.
actor FetchGate {
    private let limit: Int
    private var active = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = max(1, limit) }

    func acquire() async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Hands the slot straight to the next waiter rather than decrementing and
    /// letting it race for it — otherwise a caller arriving between the decrement
    /// and the resume jumps a queue it never joined.
    func release() {
        if waiting.isEmpty {
            active = max(0, active - 1)
        } else {
            waiting.removeFirst().resume()
        }
    }
}

// MARK: - The store

/// One thumbnail per image, fetched once and then read from disk.
///
/// Three layers, each answering something the one below it cannot:
///
/// - **memory**, keyed by URL — scrolling back up costs nothing;
/// - **disk**, keyed by blob sha — reopening the window, or relaunching the app,
///   costs one small read instead of the original download. Content-addressed, so it
///   is never invalidated: the same bytes are the same key even after
///   `github.repo` changes, and different bytes are a different key;
/// - **network**, gated and de-duplicated — two rows of the same deduped upload share
///   one GET, not two.
public actor ThumbnailStore {
    private let directory: URL
    private nonisolated let limits: ThumbnailLimits
    private nonisolated let gate: FetchGate
    private nonisolated let session: URLSession

    private var memory: [String: Thumbnail] = [:]
    /// Insertion order for the memory cache's eviction. FIFO, not LRU: the pane is
    /// read top to bottom and a re-read is a scroll, so recency of *use* barely
    /// differs from recency of *arrival* here, and this needs no bookkeeping on the
    /// hot path.
    private var memoryOrder: [String] = []

    /// In-flight fetches, so N rows wanting one image issue one GET.
    ///
    /// Unstructured `Task`s on purpose. A row's `.task` is cancelled the moment it
    /// scrolls out of view, and cancelling the *shared* work because one of its
    /// waiters left would abandon a download the next waiter needs. So the work
    /// finishes and fills the cache; the departed waiter's result is simply dropped.
    private var inFlight: [String: Task<Result<Loaded, ThumbnailFailure>, Never>] = [:]

    /// Thumbnail bytes written since the last prune. Starts *due*, so the first
    /// resolved row of a process walks the directory once — that is where a cache
    /// grown past the ceiling by previous runs gets noticed.
    private var bytesSincePrune = ThumbnailStore.pruneInterval
    /// How much writing it takes to be worth enumerating the directory again.
    private static let pruneInterval = 512 * 1024

    public init(directory: URL = ThumbnailStore.defaultDirectory(),
                limits: ThumbnailLimits = ThumbnailLimits(),
                session: URLSession? = nil) {
        self.directory = directory
        self.limits = limits
        self.gate = FetchGate(limit: limits.concurrentFetches)
        self.session = session ?? Self.makeSession()
    }

    /// `~/Library/Caches/<bundle id>/Thumbnails`.
    ///
    /// Caches, not Application Support: every file here is re-derivable from the
    /// image host, so this is exactly what the directory is for — the system may
    /// evict it under disk pressure and nothing is lost but a re-download.
    ///
    /// Namespaced by bundle identifier by hand, because an unsandboxed app gets the
    /// *shared* `~/Library/Caches` rather than a container of its own. The fallback
    /// covers `swift run`, where there is no bundle to ask.
    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let id = Bundle.main.bundleIdentifier ?? "dev.gitpic.app"
        return base.appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("Thumbnails", isDirectory: true)
    }

    /// No `URLCache`, deliberately.
    ///
    /// The disk layer here already stores the *decoded, downscaled* image keyed by
    /// content hash, and a URL cache on top of it would keep a second copy of every
    /// full-size original — the expensive half — to answer a request this store will
    /// never make twice.
    private static func makeSession() -> URLSession {
        let c = URLSessionConfiguration.default
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 60
        // Says who is asking, which is ordinary politeness toward a host serving
        // these for free and the difference between a diagnosable and an anonymous
        // burst of requests if one ever gets rate-limited.
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        c.httpAdditionalHeaders = ["User-Agent": "GitPic/\(version ?? "dev") (macOS app)"]
        return URLSession(configuration: c)
    }

    // MARK: Lookup

    /// The thumbnail for one row, from whichever layer has it.
    public func thumbnail(for source: ThumbnailSource) async -> Result<Thumbnail, ThumbnailFailure> {
        let key = source.cacheKey
        if let hit = memory[key] { return .success(hit) }

        if let running = inFlight[key] {
            // The write accounting belongs to whoever started the task, so a joiner
            // takes the image and nothing else.
            return await running.value.map(\.thumbnail)
        }

        // Detached, so the download and the ImageIO decode run on the cooperative
        // pool instead of on this actor — where they would hold up every other row's
        // cache lookup for the duration.
        let dir = directory
        let limits = self.limits
        let gate = self.gate
        let session = self.session
        let task = Task<Result<Loaded, ThumbnailFailure>, Never>.detached(priority: .utility) {
            await Self.load(source, directory: dir, limits: limits,
                            gate: gate, session: session)
        }
        inFlight[key] = task
        let result = await task.value
        // Cleared and accounted in the same actor-isolated run as the resume above,
        // with no `await` in between: that is what keeps a second caller from reaching
        // this path for the same URL and counting the same write twice.
        inFlight[key] = nil
        if case .success(let loaded) = result {
            remember(loaded.thumbnail, for: key)
            bytesSincePrune += loaded.bytesWritten
            await pruneIfDue()
        }
        return result.map(\.thumbnail)
    }

    private func remember(_ thumb: Thumbnail, for key: String) {
        if memory[key] == nil { memoryOrder.append(key) }
        memory[key] = thumb
        while memoryOrder.count > limits.memoryCount {
            memory.removeValue(forKey: memoryOrder.removeFirst())
        }
    }

    /// Enumerate and prune, but only every ``pruneInterval`` bytes of writing —
    /// a directory walk per thumbnail would cost more than the thumbnails.
    private func pruneIfDue() async {
        guard bytesSincePrune >= Self.pruneInterval else { return }
        bytesSincePrune = 0
        let dir = directory
        let ceiling = limits.maxDiskBytes
        // Detached and unawaited: this is best-effort housekeeping behind a cache
        // that is already correct, and nothing on screen should wait for it.
        Task.detached(priority: .background) { Self.prune(dir, ceiling: ceiling) }
    }

    // MARK: The actual work, off the actor

    /// A resolved thumbnail plus what it cost the disk — zero when it came *from* the
    /// disk, which is what keeps cache hits from driving the prune counter.
    private struct Loaded: Sendable {
        let thumbnail: Thumbnail
        let bytesWritten: Int
    }

    private static func load(_ source: ThumbnailSource,
                             directory: URL,
                             limits: ThumbnailLimits,
                             gate: FetchGate,
                             session: URLSession) async -> Result<Loaded, ThumbnailFailure> {
        let cacheFile = ThumbnailCache.fileName(sha: source.sha)
            .map { directory.appendingPathComponent($0) }

        if let cacheFile, let data = try? Data(contentsOf: cacheFile),
           let image = ThumbnailDecoder.decode(data, maxPixel: limits.maxPixel) {
            return .success(Loaded(thumbnail: Thumbnail(image), bytesWritten: 0))
        }

        // Checked once, before any request: the ceiling is a property of the image,
        // not of the host serving it.
        guard source.byteSize <= limits.maxSourceBytes else {
            return .failure(.tooLarge(bytes: source.byteSize, ceiling: limits.maxSourceBytes))
        }
        let candidates = source.urls.compactMap(URL.init(string:))
        guard !candidates.isEmpty else {
            return .failure(.badURL(source.urls.first ?? ""))
        }

        // Acquired around the whole walk and released on the single path out of it,
        // rather than in a `defer` that would have to spawn a task to do its `await`:
        // that version releases at some later, unordered moment, and a slot handed back
        // out of order is a queue nobody joined. Held across a fallback too, since a
        // fallback is the same one image still being fetched.
        await gate.acquire()
        var last: Result<Loaded, ThumbnailFailure> = .failure(.badURL(source.urls[0]))
        for url in candidates {
            last = await fetch(url, cacheFile: cacheFile, limits: limits, session: session)
            if case .success = last { break }
        }
        await gate.release()
        // The *last* address's failure, not the first: raw is last and it is the
        // authoritative one, so its answer is the one worth showing. A CDN 404 on a
        // fresh upload is expected and says nothing the user can act on.
        return last
    }

    private static func fetch(_ url: URL,
                              cacheFile: URL?,
                              limits: ThumbnailLimits,
                              session: URLSession) async -> Result<Loaded, ThumbnailFailure> {
        var request = URLRequest(url: url)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // A cancelled row is not a failure worth showing; it is a row that left.
            // It still reports one, because whoever is still waiting has to be told
            // something — and the shared task is what actually survives cancellation.
            return .failure(.transport((error as NSError).localizedDescription))
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            return .failure(.http(status: http.statusCode))
        }
        // The recorded size is the guard that matters — checked above, before any
        // request. This second check is for the case that guard cannot cover: the URL
        // is rebuilt from the config as it stands *now*, so after an owner/repo change
        // it may address a completely different blob than the one whose size is on
        // record. GitHub's 100 MB Contents cap bounds even that.
        guard data.count <= limits.maxSourceBytes else {
            return .failure(.tooLarge(bytes: data.count, ceiling: limits.maxSourceBytes))
        }
        guard let image = ThumbnailDecoder.decode(data, maxPixel: limits.maxPixel) else {
            return .failure(.undecodable)
        }

        var written = 0
        if let cacheFile, let png = ThumbnailDecoder.pngData(image) {
            // Best-effort, and last on purpose: the image is already decoded and about
            // to be returned, so a cache that cannot be written costs one re-download
            // next time and nothing else.
            try? FileManager.default.createDirectory(
                at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? png.write(to: cacheFile, options: .atomic)) != nil { written = png.count }
        }
        return .success(Loaded(thumbnail: Thumbnail(image), bytesWritten: written))
    }

    /// Bring the directory back under `ceiling`, oldest first. Best-effort
    /// throughout: every file in here is re-derivable, so a failed unlink is not
    /// worth reporting.
    private static func prune(_ directory: URL, ceiling: Int) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return }
        var entries: [ThumbnailCache.Entry] = []
        var total = 0
        for url in names where url.pathExtension == "png" {
            guard let values = try? url.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let bytes = values.fileSize else { continue }
            total += bytes
            entries.append(.init(url: url, bytes: bytes,
                                 modified: values.contentModificationDate ?? .distantPast))
        }
        guard total > ceiling else { return }
        for victim in ThumbnailCache.evictions(from: entries, ceiling: ceiling) {
            try? fm.removeItem(at: victim)
        }
    }
}
