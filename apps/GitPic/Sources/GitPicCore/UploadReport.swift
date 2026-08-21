import Foundation

/// What one upload is currently doing, in the form the UI needs to present it.
///
/// Replaces `NotchModel.Phase`, which lived in the deleted notch panel and carried
/// two cases this app no longer has a surface for:
///
/// - `.idle` existed to reset a transient icon on a timer. Reset is now driven by
///   the upload finishing, so there is nothing to schedule and nothing to cancel.
/// - `.hovering` existed to open the notch on hover. The status-item drop target
///   needs no hover state of its own: returning `.copy` from `draggingEntered`
///   makes the system draw the copy badge on the cursor, which is the whole of the
///   hover feedback.
public enum UploadReport: Equatable, Sendable {
    /// An upload is in flight. Carries the file count because the file picker still
    /// allows a multiple selection even though a drag accepts only one.
    case started(count: Int)
    case succeeded(summary: String)
    case failed(summary: String)

    /// The system notification this report should post, or `nil` for a report that
    /// gets no notification.
    ///
    /// `.started` deliberately returns `nil`. A banner for every drag would be
    /// noise, and the in-flight state is already visible as the status-item icon;
    /// the banner is reserved for outcomes the user may have walked away from.
    public var notice: UploadNotice? {
        switch self {
        case .started:
            return nil
        case .succeeded(let summary):
            return UploadNotice(title: "GitPic", body: summary)
        case .failed(let summary):
            return UploadNotice(title: "GitPic 上传失败", body: summary)
        }
    }
}

/// The text of one system notification.
public struct UploadNotice: Equatable, Sendable {
    public let title: String
    public let body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}

/// What became of the clipboard write for one finished upload.
///
/// Three cases rather than a `Bool`, because "not copied" was two different events
/// wearing one name: a write that was refused (the user is about to paste something
/// stale) and a write that was never asked for (`upload.auto_copy` is off, and the
/// setting is doing its job). Reporting the second as the first is how a working
/// switch gets mistaken for a bug.
public enum ClipboardOutcome: Equatable, Sendable {
    /// The snippet is on the clipboard.
    case written
    /// The write was attempted and failed.
    case failed
    /// No write was attempted: `upload.auto_copy` is off.
    case suppressed
}

public enum UploadPresentation {
    /// What to report once an upload has finished and the clipboard has been dealt
    /// with — written, refused, or deliberately left alone.
    ///
    /// This was inline in the app layer, where no test could reach it — and it has
    /// five genuinely different outcomes, one of which (`.failed`) exists
    /// specifically to avoid claiming a success the user cannot paste.
    ///
    /// `results.isEmpty` with `ok: true` is not treated as success: nothing was
    /// uploaded, so there is nothing to copy, and copying an empty string would
    /// replace whatever the user had on the clipboard with nothing.
    public static func report(results: [ItemResult],
                              failure: ErrorBody?,
                              clipboard: ClipboardOutcome,
                              form: LinkForm) -> UploadReport {
        guard !results.isEmpty else {
            return .failed(summary: failure.map { "\($0.code)：\($0.message)" }
                                    ?? "上传没有返回任何结果")
        }
        // Partial success is a first-class outcome of this CLI and must not be
        // flattened into either "ok" or "failed": the links that did land are real.
        if let failure {
            return .failed(summary: "\(results.count) 张成功，之后失败：\(failure.code)")
        }
        let deduped = results.filter(\.deduped).count
        let extra = deduped > 0 ? "（\(deduped) 张已存在）" : ""
        switch clipboard {
        case .failed:
            return .failed(summary: "上传成功，但写剪贴板失败。链接在「最近上传」里")
        case .suppressed:
            // Success, not failure: `upload.auto_copy` is off and the app honoured it,
            // the same way the CLI does. Still says where the link is, because the one
            // thing the user cannot do with it is paste it.
            return .succeeded(summary: "\(results.count) 张已上传\(extra)，未自动复制。"
                              + "链接在「最近上传」里")
        case .written:
            // `form.label` names both dimensions, so "已复制 Markdown · CDN" says which
            // address the snippet points at as well as how it is wrapped. The old
            // single-axis label could not.
            return .succeeded(summary: results.count == 1
                              ? "已复制 \(form.label)\(extra)"
                              : "\(results.count) 张已复制\(extra)")
        }
    }
}
