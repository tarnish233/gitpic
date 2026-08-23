import Testing
import Foundation
import UniformTypeIdentifiers
@testable import GitPicCore

/// A stub type resolver: anything ending `.png`/`.svg` is an image, nothing else is.
/// Keeps the partition tests off the filesystem — `contentType(of:)` has its own
/// tests below for the part that does need real files.
private func stubType(_ url: URL) -> UTType? {
    switch url.pathExtension {
    case "png": return .png
    case "svg": return .svg
    case "pdf": return .pdf
    default: return nil
    }
}

private func urls(_ names: [String]) -> [URL] {
    names.map { URL(fileURLWithPath: "/tmp/\($0)") }
}

@Suite("Right-click image selection")
struct ImageSelectionTests {

    @Test("images pass through in the order Finder sent them")
    func keepsOrder() {
        let sel = ImageFilter.partition(urls(["b.png", "a.png", "c.svg"]),
                                        contentType: stubType)
        #expect(sel.images.map(\.lastPathComponent) == ["b.png", "a.png", "c.svg"])
        #expect(sel.skipped.isEmpty)
        #expect(sel.refusal == nil)
    }

    /// The case `NSSendFileTypes` is supposed to prevent, and which must still not
    /// put a non-image into the image-host repository if it happens.
    @Test("a mixed selection uploads the images and sets the rest aside")
    func partitionsMixed() {
        let sel = ImageFilter.partition(urls(["a.png", "notes.pdf", "b.svg", "README"]),
                                        contentType: stubType)
        #expect(sel.images.map(\.lastPathComponent) == ["a.png", "b.svg"])
        #expect(sel.skipped.map(\.lastPathComponent) == ["notes.pdf", "README"])
        // Some images landed, so this is an upload, not a refusal — the skipped
        // names go to the log rather than into a banner.
        #expect(sel.refusal == nil)
    }

    @Test("with no image at all, the refusal names what was selected instead")
    func refusesNonImages() {
        let sel = ImageFilter.partition(urls(["notes.pdf", "README"]),
                                        contentType: stubType)
        #expect(sel.images.isEmpty)
        #expect(sel.refusal == "选中的不是图片：notes.pdf、README")
    }

    /// A notification body is truncated by the system at a length it picks, so the
    /// count has to be in the text rather than implied by the list.
    @Test("more than three names collapse to three plus a count")
    func truncatesLongLists() {
        let sel = ImageFilter.partition(urls(["a.txt", "b.txt", "c.txt", "d.txt", "e.txt"]),
                                        contentType: stubType)
        #expect(sel.refusal == "选中的不是图片：a.txt、b.txt、c.txt 等 5 个")
    }

    /// `NSPerformService` can fire with an empty pasteboard. Finder does not, but a
    /// silent no-op is the one outcome nothing would record.
    @Test("an empty selection still says something")
    func refusesEmpty() {
        let sel = ImageFilter.partition([], contentType: stubType)
        #expect(sel.refusal == "右键上传没有收到文件")
    }

    @Test("a real file is classified by the system's own answer")
    func classifiesRealFiles() throws {
        // Both fixtures are `ThumbnailTests`' — a real generated PNG rather than a
        // base64 blob, which reads as what it is and keeps the suite free of binary
        // fixtures. `tempDir()` does not clean up, hence the `defer`.
        let dir = ThumbnailTests.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let png = dir.appendingPathComponent("shot.png")
        try ThumbnailTests.png(w: 1, h: 1).write(to: png)
        let text = dir.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: text)

        let sel = ImageFilter.partition([png, text])
        #expect(sel.images == [png])
        #expect(sel.skipped == [text])
    }

    /// The fallback path: the file is gone by the time the service runs, so
    /// `.contentTypeKey` has nothing to read and only the name is left.
    @Test("a file that no longer exists is classified by its extension")
    func fallsBackToExtension() {
        let missing = URL(fileURLWithPath: "/tmp/gitpic-does-not-exist-\(UUID()).png")
        #expect(ImageFilter.contentType(of: missing)?.conforms(to: .image) == true)
        let neither = URL(fileURLWithPath: "/tmp/gitpic-does-not-exist-\(UUID()).txt")
        #expect(ImageFilter.contentType(of: neither)?.conforms(to: .image) == false)
    }
}
