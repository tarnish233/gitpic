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
        defer { session.invalidateAndCancel() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.attach(continuation)
                session.downloadTask(with: url).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }
}

/// Bridges `URLSessionDownloadDelegate` to `async`, and moves the finished file somewhere it
/// will still exist afterwards.
///
/// `@unchecked Sendable` over an `NSLock`, following `Auth.swift`'s `LoginChild`: the
/// delegate callbacks arrive on a URLSession queue while the continuation is resumed from
/// whatever awaited it, and none of the callbacks are `async` so an actor cannot be used
/// without hopping inside every one of them.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let destination: URL
    private let onProgress: @Sendable (SelfUpdate.Progress) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    /// A continuation may be resumed exactly once, and both `didFinishDownloadingTo` and
    /// `didCompleteWithError` fire for a successful download.
    private var settled = false

    init(destination: URL,
         onProgress: @escaping @Sendable (SelfUpdate.Progress) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    func attach(_ continuation: CheckedContinuation<URL, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    private func settle(_ result: Result<URL, Error>) {
        lock.lock()
        guard !settled, let continuation else { lock.unlock(); return }
        settled = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
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
