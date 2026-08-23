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

@Suite("Upload report")
struct UploadReportTests {

    @Test("one file names both dimensions of the form that was copied")
    func singleSuccess() {
        let r = UploadPresentation.report(results: [result(name: "a.png")],
                                         failure: nil,
                                         clipboard: .written,
                                         form: LinkForm())
        #expect(r == .succeeded(summary: "已复制 Markdown · CDN"))
    }

    @Test("the label follows both axes independently, not one flat format")
    func formLabel() {
        // The pair that had no representation at all before syntax and address were
        // split: Markdown wrapping the raw URL.
        let markdownRaw = UploadPresentation.report(
            results: [result(name: "a.png")], failure: nil, clipboard: .written,
            form: LinkForm(syntax: .markdown, target: .raw))
        #expect(markdownRaw == .succeeded(summary: "已复制 Markdown · Raw"))

        let htmlRaw = UploadPresentation.report(
            results: [result(name: "a.png")], failure: nil, clipboard: .written,
            form: LinkForm(syntax: .html, target: .raw))
        #expect(htmlRaw == .succeeded(summary: "已复制 HTML · Raw"))

        let plainCDN = UploadPresentation.report(
            results: [result(name: "a.png")], failure: nil, clipboard: .written,
            form: LinkForm(syntax: .url, target: .cdn))
        #expect(plainCDN == .succeeded(summary: "已复制 纯链接 · CDN"))
    }

    @Test("a deduped upload says so, so a no-op does not read as a fresh commit")
    func deduped() {
        let r = UploadPresentation.report(results: [result(name: "a.png", deduped: true)],
                                         failure: nil,
                                         clipboard: .written,
                                         form: LinkForm())
        #expect(r == .succeeded(summary: "已复制 Markdown · CDN（1 张已存在）"))
    }

    @Test("several files report the count instead of a form")
    func multiple() {
        let r = UploadPresentation.report(results: [result(name: "a.png"),
                                                   result(name: "b.png")],
                                         failure: nil,
                                         clipboard: .written,
                                         form: LinkForm())
        #expect(r == .succeeded(summary: "2 张已复制"))
    }

    @Test("partial success reports how many landed and is never flattened to success")
    func partial() {
        let r = UploadPresentation.report(results: [result(name: "a.png")],
                                         failure: ErrorBody(code: "NETWORK",
                                                            message: "b.png: reset"),
                                         clipboard: .written,
                                         form: LinkForm())
        #expect(r == .failed(summary: "1 张成功，之后失败：NETWORK"))
    }

    @Test("a failed clipboard write is not reported as a success the user can paste")
    func clipboardFailed() {
        // The upload really happened and the link is real; only the copy failed.
        // Saying "已复制" here would send the user to paste stale content.
        let r = UploadPresentation.report(results: [result(name: "a.png")],
                                         failure: nil,
                                         clipboard: .failed,
                                         form: LinkForm())
        #expect(r == .failed(summary: "上传成功，但写剪贴板失败。链接在「最近上传」里"))
    }

    @Test("auto_copy off is neither a copy nor a broken promise, and says where the link is")
    func clipboardSuppressed() {
        // The app honours `upload.auto_copy` itself, because it speaks to the CLI in
        // `--json` and that mode never writes the clipboard. So this outcome is the
        // switch working: report the upload as the success it is, without claiming a
        // copy the user cannot paste — and without the 「写剪贴板失败」 line, which
        // would turn a setting into a bug report.
        let r = UploadPresentation.report(results: [result(name: "a.png")],
                                          failure: nil,
                                          clipboard: .suppressed,
                                          form: LinkForm())
        #expect(r == .succeeded(summary: "1 张已上传，未自动复制。链接在「最近上传」里"))

        // The dedup note is not a property of copying, so it survives here too.
        let deduped = UploadPresentation.report(
            results: [result(name: "a.png", deduped: true)], failure: nil,
            clipboard: .suppressed, form: LinkForm())
        #expect(deduped == .succeeded(
            summary: "1 张已上传（1 张已存在），未自动复制。链接在「最近上传」里"))
    }

    @Test("no results is a failure, not an empty success")
    func emptyResults() {
        let r = UploadPresentation.report(results: [],
                                         failure: nil,
                                         clipboard: .written,
                                         form: LinkForm())
        #expect(r == .failed(summary: "上传没有返回任何结果"))
    }

    @Test("no results with an error body surfaces that error rather than a generic line")
    func emptyResultsWithError() {
        let r = UploadPresentation.report(results: [],
                                         failure: ErrorBody(code: "CONFIG_MISSING",
                                                            message: "no credential"),
                                         clipboard: .written,
                                         form: LinkForm())
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

        // The shape a real credential failure has now, so the fixture cannot outlive
        // the tool it named.
        let summary = "CONFIG_MISSING：no GitHub credential: run `gitpic auth login`"
        let bad = try #require(UploadReport.failed(summary: summary).notice)
        #expect(bad == UploadNotice(title: "GitPic 上传失败", body: summary))
    }
}
