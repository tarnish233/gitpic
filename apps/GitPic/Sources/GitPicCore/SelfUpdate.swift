import CryptoKit
import Foundation

/// Fetching a release's disk image and proving it is the one the release published.
///
/// **The trust model, stated plainly, because it is the whole reason this is allowed to
/// exist.** GitPic is signed ad-hoc — no Developer ID, no notarisation (`build-app.sh`) —
/// so there is no signature chain and macOS itself cannot vouch for a download's origin.
/// What verifies it is the SHA-256 that `api.github.com` reports for the asset, fetched over
/// TLS, compared against the bytes that arrive. That is **the same trust root Homebrew
/// uses**: a cask's `sha256` is likewise a hash fetched over TLS from GitHub, and brew has
/// no signature chain either. So this is not a weakening of the path GitPic already shipped.
///
/// What neither model survives is a compromised GitHub account or CI — the hash and the
/// bytes would both be the attacker's. The only real improvement is a Developer ID plus
/// notarisation, which is out of reach for both paths equally.
public enum SelfUpdate {

    /// How far along a download is. `total` is `nil` when the server sends no
    /// `Content-Length`, which is what lets the UI choose a spinner over a bar.
    public struct Progress: Equatable, Sendable {
        public let received: Int64
        public let total: Int64?

        public init(received: Int64, total: Int64?) {
            self.received = received
            self.total = total
        }

        public var fraction: Double? {
            guard let total, total > 0 else { return nil }
            return min(1, Double(received) / Double(total))
        }
    }

    public enum Failure: Error, Equatable {
        /// The download did not complete. `detail` is already user-facing.
        case download(String)
        /// The bytes arrived but are not what the release published. **Not worth retrying
        /// against the same asset**, and the file is deleted before this is thrown.
        case digestMismatch(expected: String, got: String)

        public var message: String {
            switch self {
            case .download(let detail):
                return "下载失败：\(detail)"
            case .digestMismatch(let expected, let got):
                // Both hashes, truncated: enough to tell a corrupted download from a
                // substituted one by comparing against the release page, without putting a
                // wall of hex in a dialog.
                return "下载内容校验不通过，已删除。GitHub 说应当是 \(expected.prefix(12))…，"
                    + "实际是 \(got.prefix(12))…"
            }
        }
    }

    /// Download `asset` and verify it against `sha256`, returning where it landed.
    ///
    /// On **any** failure — a bad status, a broken connection, cancellation, or a digest that
    /// does not match — the file is deleted before this returns or throws. Nothing leaves an
    /// unverified disk image on disk for something later to find and mount.
    ///
    /// Uses a download *task* rather than `session.bytes(from:)`: `AsyncBytes` is a sequence
    /// of individual `UInt8`s, so hashing a five-megabyte image through it costs five million
    /// async iterations. The delegate writes straight to disk at full speed and reports byte
    /// counts from the same callback, which is also where the progress numbers come from.
    public static func download(
        asset: ReleaseAsset,
        sha256 expected: String,
        onProgress: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        guard let url = URL(string: asset.url) else {
            throw Failure.download("下载地址无法解析：\(asset.url)")
        }

        let file = try await fetch(url, onProgress: onProgress)
        // Armed for the verification below: a file that fails the hash must not survive this
        // function, and neither must one whose hashing was interrupted.
        var keep = false
        defer { if !keep { try? FileManager.default.removeItem(at: file) } }

        let got = try sha256OfFile(at: file)
        guard got == expected else {
            throw Failure.digestMismatch(expected: expected, got: got)
        }
        keep = true
        return file
    }

    /// SHA-256 of a file, read in chunks so peak memory does not scale with the release.
    public static func sha256OfFile(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
            try Task.checkCancellation()
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 1 MiB: big enough that hashing is not dominated by syscalls, small enough to stay off
    /// the "large allocation" path.
    private static let chunkSize = 1024 * 1024

    /// Run the download task and hand back the file it wrote.
    private static func fetch(
        _ url: URL,
        onProgress: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitpic-update-\(UUID().uuidString).dmg")
        let delegate = DownloadDelegate(destination: destination, onProgress: onProgress)
        // `ephemeral` so nothing is written to a shared cache, and an explicit `User-Agent`
        // for the same reason `ThumbnailStore` sets one.
        //
        // **No `connectionProxyDictionary`, deliberately, and this is the asymmetry with
        // `Updater.upgradeAndRelaunch`** — which forwards `HTTPS_PROXY`/`ALL_PROXY` to brew
        // and calls that "the difference between an upgrade and a stall". URLSession does not
        // read those variables at all (measured: with every one of them pointed at a dead
        // port, a ranged GET of a real release asset still returned 206), so it honours only
        // System Settings. Forwarding them here was written and then rejected on the
        // measurement: on the development machine, whose proxy those variables name,
        //
        //     direct  → HTTP 206 in ~0.8 s, three for three
        //     proxied → connection reset after 5 s, three for three
        //
        // while the *same* proxy serves `api.github.com` fine (200 in 0.25 s). A release
        // asset redirects to `release-assets.githubusercontent.com`, a host the proxy does
        // not carry — so honouring the environment would have broken the download it was
        // meant to rescue. brew still needs the variables because `curl` and `git` do read
        // them and go through the proxy whether or not it works for the asset host.
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        // Ten minutes rather than the thumbnail store's 60 s: this is a ~5 MB image, and a
        // download killed at a minute is a feature that never works for the people on the
        // slow links who most need an easier update path.
        config.timeoutIntervalForResource = 600
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        config.httpAdditionalHeaders = ["User-Agent": "GitPic/\(version) (macOS app)"]

        let session = URLSession(configuration: config, delegate: delegate,
                                 delegateQueue: nil)
        // `invalidateAndCancel` rather than `finishTasksAndInvalidate`: on cancellation the
        // task must actually stop, and by this point the file has already been moved out.
        // Both routes to it go through the gate, which is what keeps it from overtaking the
        // task's creation — see ``SessionGate``.
        let gate = SessionGate(session)
        defer { gate.cancel() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.attach(continuation)
                if !gate.start(url) {
                    // Cancellation already invalidated the session, so no task exists and no
                    // delegate callback will ever arrive. Failing the waiter here is what
                    // turns that into a `catch`-able error instead of a download that waits
                    // forever with its 取消 button gone.
                    delegate.settle(.failure(CancellationError()))
                }
            }
        } onCancel: {
            gate.cancel()
        }
    }
}

/// Serialises "create the download task" against "cancellation invalidated the session".
///
/// **It exists because one order of those two operations kills the process.** Measured:
/// `URLSession.downloadTask(with:)` on an invalidated session does not hand back an errored
/// task, it raises `NSGenericException` — *"Task created in a session that has been
/// invalidated"* — from `-[__NSURLSessionLocal _downloadTaskWithTaskForClass:]`, and exits
/// 134. That is an ObjC exception, so no Swift `catch` can intercept it and no amount of
/// error handling downstream helps. Invalidating *after* creating is fine, and `resume()`
/// after invalidation is fine too; invalidate-then-**create** is the one fatal order.
///
/// And it was reachable rather than theoretical. `withTaskCancellationHandler` runs `onCancel`
/// **before** the body when the task is already cancelled on entry (measured ordering:
/// `["onCancel", "body"]`), and `AppModel.performSelfInstall` paints the 取消 button
/// synchronously before its first `await`, so a click can land before ``SelfUpdate/fetch``
/// runs at all. GitPic is `LSUIElement`, with no window, no Dock icon and no menu-bar icon —
/// so what the user saw was the app silently vanishing, with nothing to report.
///
/// Internal rather than private so ``ReleaseAssetTests`` can pin the invariant directly: a
/// gate that creates a task after `cancel()` aborts the test process, which is the loudest
/// failure available and exactly the one worth having.
final class SessionGate: @unchecked Sendable {
    private let lock = NSLock()
    /// Dropped by ``cancel()``, which is what makes any later ``start(_:)`` refuse.
    private var session: URLSession?

    init(_ session: URLSession) { self.session = session }

    /// Start the download unless cancellation got here first. `false` means no task was
    /// created and none ever will be, so the caller must settle its own waiter.
    ///
    /// Creating the task *inside* the lock is the whole point: asking "is it still valid?" and
    /// then creating would leave the same window open, one `invalidateAndCancel` wide. There
    /// is no inversion to deadlock on — the callbacks this triggers arrive later on the
    /// session's own queue and take ``DownloadDelegate``'s lock, never this one.
    func start(_ url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let session else { return false }
        session.downloadTask(with: url).resume()
        return true
    }

    /// Idempotent, because it is called from the cancellation handler *and* from `fetch`'s
    /// `defer`, in either order and possibly at the same time.
    func cancel() {
        lock.lock()
        let session = self.session
        self.session = nil
        lock.unlock()
        // Outside the lock: invalidation only needs the reference, and either interleaving is
        // safe. A `start` that took the lock first has already created its task, which is the
        // harmless invalidate-*after*-create order; one that takes it afterwards reads `nil`.
        session?.invalidateAndCancel()
    }
}

/// Bridges `URLSessionDownloadDelegate` to `async`, and moves the finished file somewhere it
/// will still exist afterwards.
///
/// `@unchecked Sendable` over an `NSLock`, following `Auth.swift`'s `LoginChild`: the
/// delegate callbacks arrive on a URLSession queue while the continuation is resumed from
/// whatever awaited it, and none of the callbacks are `async` so an actor cannot be used
/// without hopping inside every one of them.
///
/// Internal rather than private so ``ReleaseAssetTests`` can pin both arrival orders of the
/// handshake below — the reason it is a state machine rather than two fields.
final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    /// Which half of the handshake has arrived. Whichever is second does the resuming.
    ///
    /// The outcome and the waiter come from different threads — the outcome from a URLSession
    /// callback, the waiter from whoever suspended in `withCheckedThrowingContinuation` — and
    /// **either can be first**. The version this replaced kept a `continuation` and a
    /// `settled` flag and, when an outcome arrived with no continuation stored, returned
    /// *without* setting `settled`: the outcome was dropped, and the continuation that
    /// attached a moment later was never resumed. That is a download that hangs forever with
    /// its 取消 button already gone — strictly worse than the crash, because nothing reports
    /// it. It was latent only while `attach` was guaranteed to run first; settling
    /// cancellation from outside the callbacks (see ``SessionGate``) removes that guarantee.
    private enum Handshake {
        /// Neither half has arrived yet.
        case idle
        /// A waiter, with no outcome yet.
        case waiting(CheckedContinuation<URL, Error>)
        /// An outcome, with no waiter yet — parked until ``attach(_:)`` collects it.
        case parked(Result<URL, Error>)
        /// Resumed. Exactly-once lives here: nothing leaves this state.
        case resumed
    }

    private let lock = NSLock()
    private let destination: URL
    private let onProgress: @Sendable (SelfUpdate.Progress) -> Void
    private var handshake = Handshake.idle

    init(destination: URL,
         onProgress: @escaping @Sendable (SelfUpdate.Progress) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    /// Register the waiter, or hand it an outcome that already arrived.
    ///
    /// Called exactly once per delegate, by ``SelfUpdate/fetch``.
    func attach(_ continuation: CheckedContinuation<URL, Error>) {
        lock.lock()
        switch handshake {
        case .idle:
            handshake = .waiting(continuation)
            lock.unlock()
        case .parked(let result):
            handshake = .resumed
            lock.unlock()
            continuation.resume(with: result)
        case .waiting, .resumed:
            // Unreachable with one call site. Resuming anyway rather than asserting: a
            // continuation that is merely dropped hangs the caller, and hanging is the failure
            // mode this whole state machine exists to rule out.
            lock.unlock()
            continuation.resume(throwing: CancellationError())
        }
    }

    /// Deliver `result` to the waiter, or park it for one — exactly once, in either order.
    ///
    /// A continuation may be resumed exactly once, and both `didFinishDownloadingTo` and
    /// `didCompleteWithError` fire for a successful download, so a second outcome is the
    /// normal path and not an error.
    func settle(_ result: Result<URL, Error>) {
        lock.lock()
        switch handshake {
        case .waiting(let continuation):
            handshake = .resumed
            lock.unlock()
            continuation.resume(with: result)
        case .idle:
            handshake = .parked(result)
            lock.unlock()
        case .parked, .resumed:
            // First outcome wins; a later one is the second callback for the same download.
            lock.unlock()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        // `NSURLSessionTransferSizeUnknown` is -1, which becomes `nil` rather than a
        // nonsensical total.
        let total = totalBytesExpectedToWrite >= 0 ? totalBytesExpectedToWrite : nil
        onProgress(SelfUpdate.Progress(received: totalBytesWritten, total: total))
    }

    /// The handed-over URL is only valid for the duration of this call, so the file is moved
    /// synchronously here rather than remembered.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        if let response = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(response.statusCode) {
            // A 404 body is still "downloaded successfully" as far as the task is concerned,
            // and hashing GitHub's error page would report a digest mismatch — which reads as
            // a tampered release rather than a missing asset.
            settle(.failure(SelfUpdate.Failure.download("GitHub 返回 \(response.statusCode)")))
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            settle(.success(destination))
        } catch {
            settle(.failure(SelfUpdate.Failure.download(
                "无法保存下载内容：\((error as NSError).localizedDescription)")))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        guard let error else { return }  // success already settled above
        if (error as? URLError)?.code == .cancelled {
            settle(.failure(CancellationError()))
        } else {
            settle(.failure(SelfUpdate.Failure.download(
                (error as NSError).localizedDescription)))
        }
    }
}
