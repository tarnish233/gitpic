import Foundation
import UniformTypeIdentifiers

/// What a right-click selection turned out to hold: the files GitPic will upload,
/// and the ones it will not.
///
/// Two lists rather than a filtered array. A right-click acts on a selection made
/// in *another* app, so this side never saw the user choose the files — and an
/// upload that quietly returns three links for four files, with nothing saying
/// which one was dropped or why, is indistinguishable from an upload that lost one.
public struct ImageSelection: Equatable, Sendable {
    /// In the order they arrived. Finder hands over the selection in its own sort
    /// order, and that is the order the copied snippets come back in.
    public let images: [URL]
    public let skipped: [URL]

    /// Why there is nothing to upload, or `nil` when there is.
    ///
    /// Lives here rather than in the app layer so the wording is testable, the same
    /// way ``UploadPresentation`` holds the wording for a finished upload. Only the
    /// nothing-to-upload case gets a sentence: a selection that yielded *some*
    /// images uploads them and the skipped names go to the log, because a mixed
    /// selection is not something Finder's own menu offers the item for — the case is
    /// guarded against, not expected.
    public var refusal: String? {
        guard images.isEmpty else { return nil }
        // No files at all: the service fired with an empty pasteboard. Not a case
        // Finder produces, but `NSPerformService` can, and a silent no-op is the
        // one outcome that cannot be diagnosed afterwards.
        guard !skipped.isEmpty else { return "右键上传没有收到文件" }
        return "选中的不是图片：\(Self.nameList(skipped))"
    }

    /// The skipped names, for a caller that uploaded the rest and has to say so.
    ///
    /// Shares ``nameList``'s three-and-a-count truncation with ``refusal`` so the two
    /// messages cannot describe the same selection two different ways.
    public var skippedSummary: String { Self.nameList(skipped) }

    /// Names, three at a time.
    ///
    /// A right-click can carry a hundred files, and a notification body that long is
    /// truncated by the system at a point it chooses — so the count goes in the text
    /// where it survives.
    private static func nameList(_ urls: [URL]) -> String {
        let names = urls.map(\.lastPathComponent)
        guard names.count > 3 else { return names.joined(separator: "、") }
        return names.prefix(3).joined(separator: "、") + " 等 \(names.count) 个"
    }
}

/// Splits file URLs into the images and everything else.
public enum ImageFilter {

    /// Why this filters at all, when the service already declares `public.image`:
    ///
    /// **`NSSendFileTypes` is not enforced at dispatch.** Measured against the built
    /// bundle: the pasteboard server checks only that the pasteboard carries
    /// `public.file-url` — it says so itself when the type is absent ("Pasteboard
    /// contained types (), but service expects types (public.file-url)") — and it
    /// handed a `notes.txt` straight through to this app. The `public.image` half is
    /// used by whoever *builds* the menu, so it keeps the item out of Finder's
    /// context menu for a text file, and stops there.
    ///
    /// And the CLI does not check either: `gitpic <file>` uploads whatever bytes it
    /// is handed (`src/commands/upload.rs` only sniffs formats for `--stdin` naming,
    /// and `imageproc::maybe_compress` passes anything it cannot decode straight
    /// through), so a `.pdf` that reached this far would become a real commit in the
    /// image-host repository. This is the only place that can refuse it.
    ///
    /// `contentType` is injected so the partition can be tested without a
    /// filesystem; the default is the real answer.
    public static func partition(
        _ urls: [URL],
        contentType: (URL) -> UTType? = ImageFilter.contentType(of:)
    ) -> ImageSelection {
        var images: [URL] = []
        var skipped: [URL] = []
        for url in urls {
            if let type = contentType(url), type.conforms(to: .image) {
                images.append(url)
            } else {
                skipped.append(url)
            }
        }
        return ImageSelection(images: images, skipped: skipped)
    }

    /// The system's own answer for what this file is, falling back to its extension.
    ///
    /// `.contentTypeKey` is asked first because it knows things a filename does not:
    /// a file with no extension, a bundle, an alias. It needs the file to exist,
    /// which a Finder selection does — the extension fallback is for the file having
    /// been moved or deleted between the right-click and this call.
    ///
    /// SVG is included by both routes and that is intended: `public.svg-image`
    /// conforms to `public.image`, GitHub renders it, and the compressor leaves it
    /// byte-for-byte alone.
    public static func contentType(of url: URL) -> UTType? {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type
        }
        return UTType(filenameExtension: url.pathExtension)
    }
}
