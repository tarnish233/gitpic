import Testing
import Foundation
@testable import GitPicCore

/// The two link dimensions, and the Swift port of `src/link.rs` they rest on.
///
/// Every URL and escaping expectation here is copied from `src/link.rs`'s own tests
/// rather than re-derived, so a change on the Rust side that these do not follow
/// breaks the Swift build too. That matters more than usual: the app builds four of
/// the six snippet combinations itself, and the CLI builds the other two, so the two
/// implementations have to agree byte for byte or the same image yields two different
/// Markdown strings depending on which surface copied it.
@Suite("Link syntax × target")
struct LinkTests {

    /// `owner=o repo=r branch=main` — the target `Fixture.item` was built against.
    static let config = GitpicConfig(
        github: .init(owner: "o", repo: "r", branch: "main"),
        upload: .init(pathTemplate: "images/{year}/{month}/{hash8}-{name}.{ext}",
                      linkKind: "cdn", dedup: true, autoCopy: true,
                      compress: false, maxWidth: 0, quality: 82))

    // MARK: - URLs

    @Test("URL templates match src/link.rs")
    func urlTemplates() {
        #expect(LinkURL.cdn(owner: "o", repo: "r", branch: "main", path: "a/b.png")
                == "https://cdn.jsdelivr.net/gh/o/r@main/a/b.png")
        #expect(LinkURL.raw(owner: "o", repo: "r", branch: "main", path: "a/b.png")
                == "https://raw.githubusercontent.com/o/r/main/a/b.png")
    }

    @Test("every interpolated value is encoded, not just the path")
    func urlEncoding() {
        // A path may legitimately carry spaces or non-ASCII.
        #expect(LinkURL.cdn(owner: "o", repo: "r", branch: "main", path: "my images/a.png")
                == "https://cdn.jsdelivr.net/gh/o/r@main/my%20images/a.png")
        #expect(LinkURL.raw(owner: "o", repo: "r", branch: "main", path: "图/a.png")
                == "https://raw.githubusercontent.com/o/r/main/%E5%9B%BE/a.png")
        // A branch is the field that realistically breaks a link.
        #expect(LinkURL.raw(owner: "o", repo: "r", branch: "feat x", path: "a.png")
                == "https://raw.githubusercontent.com/o/r/feat%20x/a.png")
        #expect(LinkURL.cdn(owner: "o", repo: "r", branch: "a&b", path: "a.png")
                == "https://cdn.jsdelivr.net/gh/o/r@a%26b/a.png")
        // `raw` needs the branch to span several path segments, so `/` survives.
        #expect(LinkURL.raw(owner: "o", repo: "r", branch: "feat/x", path: "a.png")
                == "https://raw.githubusercontent.com/o/r/feat/x/a.png")
    }

    // MARK: - Escaping

    @Test("markdown alt text is escaped as the CLI escapes it")
    func markdownAlt() {
        #expect(LinkText.markdown(alt: "alt", url: "u") == "![alt](u)")
        // Unescaped brackets/parens would terminate the label and break the link.
        #expect(LinkText.markdown(alt: "a]b(c)", url: "u") == #"![a\]b\(c\)](u)"#)
        #expect(LinkText.markdown(alt: "a[b", url: "u") == #"![a\[b](u)"#)
        #expect(LinkText.markdown(alt: #"back\slash"#, url: "u") == #"![back\\slash](u)"#)
    }

    @Test("newlines in alt text become spaces, one per scalar")
    func markdownNewlines() {
        #expect(LinkText.markdown(alt: "a\nb", url: "u") == "![a b](u)")
        // Two spaces, because Rust walks scalars and CR and LF are two of them. A
        // `Character` loop would fold "\r\n" into one grapheme and emit one space,
        // which is why the escapers walk `unicodeScalars`.
        #expect(LinkText.markdown(alt: "a\r\nb", url: "u") == "![a  b](u)")
    }

    @Test("markdown destinations escape their own delimiters")
    func markdownURL() {
        #expect(LinkText.markdown(alt: "image",
                                  url: #"https://example.test/a)b(1)\x.png"#)
                == #"![image](https://example.test/a\)b\(1\)\\x.png)"#)
    }

    @Test("HTML attributes are escaped in both slots")
    func htmlEscaping() {
        // A quote in the alt text must not be able to escape the attribute.
        #expect(LinkText.html(alt: #"x")>evil<img"#, url: "u")
                == #"<img src="u" alt="x&quot;)&gt;evil&lt;img">"#)
        #expect(LinkText.html(alt: "a&b", url: "u?x=1&y=2")
                == #"<img src="u?x=1&amp;y=2" alt="a&amp;b">"#)
    }

    @Test("the url syntax is the bare URL, unwrapped and unescaped")
    func plainURL() {
        let u = "https://cdn.jsdelivr.net/gh/o/r@main/a(1).png"
        #expect(LinkText.render(.url, alt: "ignored", url: u) == u)
    }

    // MARK: - The grid

    @Test("syntax and target vary independently, and all six combinations exist")
    func orthogonality() throws {
        let link = UploadedLink(id: "x", name: "shot", path: "a/b.png",
                                cdn: .success("https://cdn.example/b.png"),
                                rawURL: "https://raw.example/b.png",
                                deduped: false)
        var seen = Set<String>()
        for syntax in LinkSyntax.allCases {
            for target in LinkTarget.allCases {
                let s = try #require(link.snippet(LinkForm(syntax: syntax, target: target)))
                #expect(s.contains(target == .cdn ? "cdn.example" : "raw.example"),
                        "\(syntax.label) · \(target.label) used the wrong address")
                seen.insert(s)
            }
        }
        // Six distinct snippets, not four. The flat enum this replaces could not
        // express Markdown-of-raw or HTML-of-raw at all.
        #expect(seen.count == LinkSyntax.allCases.count * LinkTarget.allCases.count)
    }

    @Test("no CDN address means no CDN snippet, rather than a raw one wearing the label")
    func missingCDN() {
        let link = UploadedLink(id: "x", name: "shot", path: "a/b.png",
                                cdn: .failure(.noConfig),
                                rawURL: "https://raw.example/b.png",
                                deduped: false)
        #expect(link.snippet(LinkForm(syntax: .markdown, target: .cdn)) == nil)
        #expect(link.snippet(LinkForm(syntax: .markdown, target: .raw)) != nil)
        // The reason travels with the absence, and only for the address that lacks one.
        #expect(link.unavailable(.cdn) == .noConfig)
        #expect(link.unavailable(.raw) == nil)
    }

    @Test("a fresh upload with no config read yet still has its raw address")
    func itemWithoutConfig() throws {
        let env: UploadEnvelope = try JSONDecoder()
            .decode(UploadEnvelope.self, from: Data(Fixture.success(["shot"]).utf8))
        let r = try #require(env.results?.first)
        let link = UploadedLink(r, config: nil)
        #expect(link.url(.raw) == r.rawURL)
        #expect(link.url(.cdn) == nil)
    }

    // MARK: - History

    @Test("a history row's CDN address is jsDelivr even when the stored URL is raw")
    func historyRowRebuildsBothAddresses() throws {
        // Regression: the pane returned `record.url` for the CDN option, but `list`
        // stores whichever kind `upload.link_kind` selected — so with `raw`
        // configured, "CDN" handed back a raw.githubusercontent link.
        let r: HistoryRecord = try JSONDecoder().decode(HistoryRecord.self, from: Data("""
        { "time": "2026-08-19T23:00:22+08:00", "name": "shot", "path": "images/a b/c.png",
          "url": "https://raw.githubusercontent.com/o/r/main/images/a%20b/c.png",
          "sha": "abc", "size": 1, "deduped": false }
        """.utf8))
        let link = UploadedLink(r, config: Self.config)
        #expect(link.url(.cdn) == "https://cdn.jsdelivr.net/gh/o/r@main/images/a%20b/c.png")
        #expect(link.url(.raw) == "https://raw.githubusercontent.com/o/r/main/images/a%20b/c.png")
        // The one formula, so the record's own accessor cannot drift from it.
        #expect(link.url(.raw) == r.rawURL(config: Self.config))
    }

    @Test("a branch with a slash has no CDN address at all, in either direction")
    func ambiguousBranchHasNoCDNAddress() throws {
        // The CLI refuses `--link cdn` on such a branch outright, so no envelope ever
        // carries this URL. The app builds CDN addresses itself, though, and
        // `--link raw` on `feat/x` uploads perfectly well — so without the same
        // predicate the app would hand back `gh/o/r@feat/x/a.png`, which jsDelivr
        // cannot parse back into a ref and a path, under a label reading CDN.
        #expect(LinkURL.cdnBranchIsAmbiguous("feat/x"))
        #expect(!LinkURL.cdnBranchIsAmbiguous("main"))

        let cfg = GitpicConfig(
            github: .init(owner: "o", repo: "r", branch: "feat/x"),
            upload: Self.config.upload)

        // From a fresh upload...
        let env: UploadEnvelope = try JSONDecoder()
            .decode(UploadEnvelope.self, from: Data(Fixture.success(["shot"]).utf8))
        let item = try #require(env.results?.first)
        let fresh = UploadedLink(item, config: cfg)
        #expect(fresh.url(.cdn) == nil)
        #expect(fresh.unavailable(.cdn) == .ambiguousBranch(branch: "feat/x"))
        // Raw is unaffected — the branch simply spans two segments.
        #expect(fresh.url(.raw) == item.rawURL)

        // ...and from a history row, which rebuilds both.
        let row: HistoryRecord = try JSONDecoder().decode(HistoryRecord.self, from: Data("""
        { "time": "2026-08-19T23:00:22+08:00", "name": "shot", "path": "a.png",
          "url": "https://raw.githubusercontent.com/o/r/feat/x/a.png",
          "sha": "abc", "size": 1, "deduped": false }
        """.utf8))
        let stored = UploadedLink(row, config: cfg)
        #expect(stored.url(.cdn) == nil)
        #expect(stored.url(.raw) == "https://raw.githubusercontent.com/o/r/feat/x/a.png")
        // The message names the branch and the remedy, since only the user can fix it.
        let why = try #require(stored.unavailable(.cdn))
        #expect(why.message.contains("feat/x"))
        #expect(why.message.contains("Raw"))
    }

    // MARK: - Labels

    @Test("a form's label names both dimensions")
    func formLabel() {
        #expect(LinkForm(syntax: .markdown, target: .cdn).label == "Markdown · CDN")
        #expect(LinkForm(syntax: .url, target: .raw).label == "纯链接 · Raw")
        // The default is what the app opens on.
        #expect(LinkForm() == LinkForm(syntax: .markdown, target: .cdn))
    }

    @Test("raw values are the CLI's own spellings, since they cross that boundary")
    func rawValues() {
        // `upload.link_kind` is written with these, and `--format` reads these.
        #expect(LinkTarget.allCases.map(\.rawValue) == ["cdn", "raw"])
        #expect(LinkSyntax.allCases.map(\.rawValue) == ["markdown", "html", "url"])
    }
}
