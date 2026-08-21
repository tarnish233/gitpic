import Testing
import Foundation
@testable import GitPicCore

/// `ItemResult` has no public memberwise init; `@testable` reaches the synthesised
/// internal one, which is cheaper here than round-tripping JSON for every case.
private func result(name: String, deduped: Bool = false) -> ItemResult {
    ItemResult(name: name,
               url: "https://cdn.example/\(name)",
               rawURL: "https://raw.example/\(name)",
               markdown: "![\(name)](https://cdn.example/\(name))",
               html: "<img src=\"https://cdn.example/\(name)\">",
               path: "images/\(name)",
               sha: "sha-\(name)",
               size: 1234,
               deduped: deduped,
               output: "![\(name)](https://cdn.example/\(name))")
}

@Suite("Menu-bar drop policy")
struct ImageDropTests {

    @Test("one image is what a drag is allowed to carry")
    func single() throws {
        let url = URL(fileURLWithPath: "/tmp/a.png")
        #expect(ImageDrop.accepted(imageURLs: [url]) == url)
    }

    @Test("a drag carrying no image is refused, so the icon never highlights")
    func none() {
        #expect(ImageDrop.accepted(imageURLs: []) == nil)
    }

    @Test("several images are refused outright rather than partly uploaded")
    func several() {
        // The refusal matters more than it looks: uploading the first of three and
        // silently dropping the rest would leave two files the user believes are
        // hosted. Refusing means the drag visibly snaps back instead.
        let urls = [URL(fileURLWithPath: "/tmp/a.png"), URL(fileURLWithPath: "/tmp/b.png")]
        #expect(ImageDrop.accepted(imageURLs: urls) == nil)
    }
}

@Suite("Upload report")
struct UploadReportTests {

    @Test("one file names the format that was copied")
    func singleSuccess() {
        let r = UploadPresentation.report(results: [result(name: "a.png")],
                                         failure: nil,
                                         clipboardWritten: true,
                                         format: .markdown)
        #expect(r == .succeeded(summary: "已复制 Markdown"))
    }

    @Test("the format label follows the selected format, not the markdown default")
    func formatLabel() {
        let r = UploadPresentation.report(results: [result(name: "a.png")],
                                         failure: nil,
                                         clipboardWritten: true,
                                         format: .cdn)
        #expect(r == .succeeded(summary: "已复制 CDN URL"))
    }

    @Test("a deduped upload says so, so a no-op does not read as a fresh commit")
    func deduped() {
        let r = UploadPresentation.report(results: [result(name: "a.png", deduped: true)],
                                         failure: nil,
                                         clipboardWritten: true,
                                         format: .markdown)
        #expect(r == .succeeded(summary: "已复制 Markdown（1 张已存在）"))
    }

    @Test("several files report the count instead of a format")
    func multiple() {
        let r = UploadPresentation.report(results: [result(name: "a.png"),
                                                   result(name: "b.png")],
                                         failure: nil,
                                         clipboardWritten: true,
                                         format: .markdown)
        #expect(r == .succeeded(summary: "2 张已复制"))
    }

    @Test("partial success reports how many landed and is never flattened to success")
    func partial() {
        let r = UploadPresentation.report(results: [result(name: "a.png")],
                                         failure: ErrorBody(code: "NETWORK",
                                                            message: "b.png: reset"),
                                         clipboardWritten: true,
                                         format: .markdown)
        #expect(r == .failed(summary: "1 张成功，之后失败：NETWORK"))
    }

    @Test("a failed clipboard write is not reported as a success the user can paste")
    func clipboardFailed() {
        // The upload really happened and the link is real; only the copy failed.
        // Saying "已复制" here would send the user to paste stale content.
        let r = UploadPresentation.report(results: [result(name: "a.png")],
                                         failure: nil,
                                         clipboardWritten: false,
                                         format: .markdown)
        #expect(r == .failed(summary: "上传成功，但写剪贴板失败。链接在「最近上传」里"))
    }

    @Test("no results is a failure, not an empty success")
    func emptyResults() {
        let r = UploadPresentation.report(results: [],
                                         failure: nil,
                                         clipboardWritten: true,
                                         format: .markdown)
        #expect(r == .failed(summary: "上传没有返回任何结果"))
    }

    @Test("no results with an error body surfaces that error rather than a generic line")
    func emptyResultsWithError() {
        let r = UploadPresentation.report(results: [],
                                         failure: ErrorBody(code: "CONFIG_MISSING",
                                                            message: "no credential"),
                                         clipboardWritten: true,
                                         format: .markdown)
        #expect(r == .failed(summary: "CONFIG_MISSING：no credential"))
    }

    @Test("an in-flight upload posts no notification — the icon carries that state")
    func startedIsSilent() {
        #expect(UploadReport.started(count: 1).notice == nil)
        #expect(UploadReport.started(count: 5).notice == nil)
    }

    @Test("both outcomes post a notification, and failures are titled as failures")
    func outcomesNotify() throws {
        let ok = try #require(UploadReport.succeeded(summary: "已复制 Markdown").notice)
        #expect(ok == UploadNotice(title: "GitPic", body: "已复制 Markdown"))

        let bad = try #require(UploadReport.failed(summary: "gh 未登录").notice)
        #expect(bad == UploadNotice(title: "GitPic 上传失败", body: "gh 未登录"))
    }
}
