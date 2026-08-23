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
            // holds no token to tell them apart (the CLI reads its own auth.toml;
            // nothing here keeps a credential).
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
    /// How long fetches have to be outstanding before ``ThumbnailStore`` admits to
    /// them. Below this, an episode comes and goes with nothing on screen.
    ///
    /// **A progress line that appears and vanishes is worse than no progress line**, and
    /// the pane is opened far more often with little to do than with 33 images to fetch.
    /// The commonest case of all — everything cached — is already silent for a different
    /// and better reason: cache hits are not fetches and are never counted (see
    /// ``ThumbnailStore``'s `beganFetching`). This number is for the short *real*
    /// episodes that counting rule cannot catch: the one image just uploaded, sitting at
    /// the top of the pane, fetched over a link that answers in 200 ms. Flashing
    /// 正在取缩略图 0/1 through that is noise reporting nothing.
    ///
    /// 300 ms because it has to separate a round trip worth mentioning from one that is
    /// already over, and nothing else. For scale, the cache layers it must never trip
    /// over are far below it: 33 thumbnails read from disk into a fresh store take
    /// 5.4 / 5.4 / 9.0 ms over three rounds — 30× under — and 0.2 ms once they are in
    /// memory. (Measured through the test session, which does the same
    /// `Data(contentsOf:)` and ImageIO decode per image the app does.) It is also under
    /// the ~1 s at which a person starts wondering whether the window is broken, and the
    /// cold fill it exists for runs 4.11–5.16 s over those same 33 images
    /// (``concurrentFetches``), so the line still covers about four of those seconds.
    ///
    /// Rejected: pairing this with a minimum on-screen time. That would only matter for
    /// an episode that crosses 300 ms and then ends immediately, and there is no such
    /// cluster to protect against — work here either comes out of a cache in single-digit
    /// milliseconds or waits on a network round trip.
    public var progressGrace: Duration

    public init(maxPixel: Int = 160,
                maxSourceBytes: Int = 12 * 1024 * 1024,
                maxDiskBytes: Int = 32 * 1024 * 1024,
                memoryCount: Int = 120,
                concurrentFetches: Int = 8,
                progressGrace: Duration = .milliseconds(300)) {
        self.maxPixel = maxPixel
        self.maxSourceBytes = maxSourceBytes
        self.maxDiskBytes = maxDiskBytes
        self.memoryCount = memoryCount
        self.concurrentFetches = concurrentFetches
        self.progressGrace = progressGrace
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

// MARK: - Progress

/// How much of the pane's thumbnail fetching is still outstanding — **one number for
/// the whole pane, not one per row.**
///
/// Per-row spinners were the obvious alternative and they are the wrong answer for the
/// same reason each row's placeholder is a static glyph rather than a spinner: a
/// hundred of them chasing each other down the pane reports nothing and is the noisiest
/// thing on screen. One line saying `12/33` says the thing a person actually wants
/// known — that this is progressing, and roughly how much of it is left.
///
/// **Counts images, not rows.** Two rows of one deduped upload share a single GET (see
/// ``ThumbnailStore``), so they are one unit of work here; on this machine's history
/// that is 37 rows and 33 distinct images.
public struct ThumbnailProgress: Sendable, Hashable {
    /// Fetches finished in the current episode.
    public let done: Int
    /// Fetches started in it, `done` included. Zero exactly when there is nothing to
    /// report — see ``isActive``.
    ///
    /// It does not shrink: an episode's total is fixed until the episode ends, so a
    /// denominator never counts backwards while someone is reading it.
    public let total: Int

    /// Nothing outstanding, or nothing outstanding *long enough to mention* — the two
    /// are deliberately indistinguishable from out here. Which of them it is, is
    /// ``ThumbnailLimits/progressGrace``'s business and no caller's.
    public static let idle = ThumbnailProgress(done: 0, total: 0)

    /// Whether there is anything to show. The UI's whole decision.
    public var isActive: Bool { total > 0 }

    public init(done: Int, total: Int) {
        self.done = done
        self.total = total
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

    // MARK: Progress accounting

    /// Keys that have missed both caches and are being fetched right now — queued at
    /// the gate counts as being fetched, because from the pane's side it is the same
    /// grey box either way.
    private var fetching: Set<String> = []
    /// The current episode: fetches started, and of those, finished. Both reset the
    /// moment ``fetching`` empties, which is what makes "episode" mean *one burst of
    /// pane work* rather than the lifetime of the process.
    private var episodeStarted = 0
    private var episodeFinished = 0

    /// Everyone listening. A dictionary rather than one continuation because 历史 can
    /// be closed and reopened, so subscriptions come and go and a second one must not
    /// silently steal the first one's values.
    private var watchers: [UUID: AsyncStream<ThumbnailProgress>.Continuation] = [:]

    /// Whether the current episode has outlived ``ThumbnailLimits/progressGrace`` and
    /// is therefore worth mentioning. Until it has, watchers are told nothing at all.
    private var revealed = false
    /// The pending "has it been long enough yet" timer, cancelled when an episode ends
    /// before it fires — which on a cached pane is every time.
    private var revealTimer: Task<Void, Never>?

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
        // The one tie back to the store from inside the detached work, and deliberately
        // the only one: a single actor hop taken before the request goes out, nothing
        // reached for during the download or the decode.
        //
        // Built out here rather than inline in the task, and strongly, because a `weak
        // self` capture cannot be re-captured by a nested `@Sendable` closure. The
        // reference it holds lives exactly as long as the fetch — the task always
        // returns, and `inFlight[key] = nil` below is what lets go of the task.
        let announce: @Sendable () async -> Void = { await self.beganFetching(key) }
        let task = Task<Result<Loaded, ThumbnailFailure>, Never>.detached(priority: .utility) {
            await Self.load(source, directory: dir, limits: limits,
                            gate: gate, session: session, announceFetch: announce)
        }
        inFlight[key] = task
        let result = await task.value
        // Cleared and accounted in the same actor-isolated run as the resume above,
        // with no `await` in between: that is what keeps a second caller from reaching
        // this path for the same URL and counting the same write twice.
        inFlight[key] = nil
        finishedFetching(key)
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

    // MARK: Progress

    /// How much fetching is outstanding, pushed as it changes — starting with where
    /// things stand right now, so a subscriber that arrives mid-burst is not blind
    /// until the next image lands.
    ///
    /// A stream and not an `isLoading` the UI can read, because the alternative is the
    /// UI asking again and again: this store is an actor, every read is a hop onto it,
    /// and a timer polling it would be 33 pointless hops a second through the exact
    /// four seconds it is meant to describe. It also keeps this file free of SwiftUI —
    /// `AsyncStream` is Foundation, so nothing here knows a view exists.
    ///
    /// `.bufferingNewest(1)`: a progress reading is a *state*, not an event. A
    /// subscriber that fell behind wants the current count, never a backlog of counts
    /// that were true a moment ago, and the unbounded default would keep every one of
    /// them.
    ///
    /// Each call gets its own stream. Reopening 历史 subscribes again, and two live
    /// subscriptions both see everything rather than one of them quietly winning.
    public func progressUpdates() -> AsyncStream<ThumbnailProgress> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<ThumbnailProgress>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        watchers[id] = continuation
        continuation.yield(visibleProgress)
        // Fires when the consumer's `for await` ends — the pane closing, or its task
        // being cancelled. Hops back onto the actor because that is where `watchers`
        // lives; without this every open of the window would leak a continuation.
        continuation.onTermination = { [weak self] _ in
            Task { await self?.dropWatcher(id) }
        }
        return stream
    }

    private func dropWatcher(_ id: UUID) { watchers[id] = nil }

    /// What watchers are allowed to see: the truth once the episode has earned it, and
    /// ``ThumbnailProgress/idle`` before that. The grace period is enforced here, in
    /// one place, rather than by each caller remembering to ask.
    private var visibleProgress: ThumbnailProgress {
        revealed ? ThumbnailProgress(done: episodeFinished, total: episodeStarted) : .idle
    }

    private func broadcast() {
        let now = visibleProgress
        for watcher in watchers.values { watcher.yield(now) }
    }

    /// Called from ``load`` once both caches have missed and the guards have passed, so
    /// a request really is about to go out.
    ///
    /// **Counting here rather than in ``thumbnail(for:)`` is the whole point.** Up there
    /// the store cannot yet tell a network fetch from a disk hit — finding out means
    /// doing the disk read, which is precisely the work kept off this actor — so
    /// counting there would count every cached image as "fetching". A line reading
    /// 正在取缩略图 while 33 images come off the local disk in 9 ms is not a true
    /// sentence, and the size-ceiling refusals it would also count are images that by
    /// definition never get fetched at all.
    ///
    /// Rejected: a `fileExists` check on the actor to decide up front. It is a second,
    /// less reliable copy of a decision ``load`` already makes — a cache file that
    /// exists but will not decode falls through to the network and would go uncounted —
    /// bought with a synchronous filesystem call on the actor.
    private func beganFetching(_ key: String) {
        // De-duplication happens upstream: one key has one in-flight task, so a second
        // announcement for a live key cannot arrive. Guarded anyway, because the cost
        // of being wrong is a total that never comes back down.
        guard fetching.insert(key).inserted else { return }
        episodeStarted += 1
        if revealed {
            broadcast()
        } else if revealTimer == nil {
            // One timer per episode, armed by whichever fetch opened it. Every later
            // fetch joins the episode already being timed rather than pushing the
            // reveal further out — otherwise a steady trickle of work would keep
            // resetting the clock and the line would never appear at all.
            let grace = limits.progressGrace
            revealTimer = Task { [weak self] in
                try? await Task.sleep(for: grace)
                await self?.reveal()
            }
        }
    }

    private func reveal() {
        // A cancelled timer belongs to an episode that has already ended; the store may
        // by now be timing a *new* one, whose registration this must not clobber.
        guard !Task.isCancelled else { return }
        revealTimer = nil
        guard !fetching.isEmpty else { return }
        revealed = true
        broadcast()
    }

    /// The counterpart to ``beganFetching(_:)``, and it is on the actor's side of the
    /// task boundary on purpose: whatever happened to the fetch — image, 404, transport
    /// error, or a waiter that walked away — ``thumbnail(for:)`` still returns, so this
    /// still runs and the count cannot get stuck.
    private func finishedFetching(_ key: String) {
        // Nothing to settle for a memory hit, a disk hit, or a refusal: those never
        // announced themselves.
        guard fetching.remove(key) != nil else { return }
        episodeFinished += 1
        guard fetching.isEmpty else {
            if revealed { broadcast() }
            return
        }
        // Episode over. Reset before the last broadcast, so what watchers see is
        // `idle` and not a final 33/33 they would have to know to ignore.
        episodeStarted = 0
        episodeFinished = 0
        revealTimer?.cancel()
        revealTimer = nil
        let wasVisible = revealed
        revealed = false
        // Only if something was actually on screen. On a cached pane this is the path
        // every single time, and it must stay completely silent.
        if wasVisible { broadcast() }
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
                             session: URLSession,
                             announceFetch: @escaping @Sendable () async -> Void)
                             async -> Result<Loaded, ThumbnailFailure> {
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

        // Announced here and not a line earlier or later: below both cache layers, so
        // nothing already cached is counted, and below the ceiling and URL guards, so
        // nothing that fails without a request is either. Above `acquire()`, because an
        // image waiting its turn at the gate is outstanding work — 25 of the 33 start
        // there, and a total that grew as slots freed up would be a denominator
        // crawling upward for four seconds.
        await announceFetch()

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
