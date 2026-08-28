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
                      format: "md", linkKind: "cdn", dedup: true, autoCopy: true,
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

    @Test("a stored CDN URL parses back into owner, repo, branch")
    func parseCDN() {
        let t = LinkURL.parse("https://cdn.jsdelivr.net/gh/o/r@main/images/a%20b/c.png",
                              path: "images/a b/c.png")
        #expect(t?.owner == "o")
        #expect(t?.repo == "r")
        #expect(t?.branch == "main")
    }

    @Test("a stored raw URL keeps a slashed branch, because the path is the suffix")
    func parseRawSlashBranch() {
        let t = LinkURL.parse("https://raw.githubusercontent.com/o/r/feat/x/a.png",
                              path: "a.png")
        #expect(t?.owner == "o")
        #expect(t?.repo == "r")
        #expect(t?.branch == "feat/x")
    }

    @Test("a URL that is not one of gitpic's two templates does not parse")
    func parseRejectsUnknownHost() {
        #expect(LinkURL.parse("https://example.test/a.png", path: "a.png") == nil)
    }

    @Test("decodePath is the inverse of encodePath")
    func decodePathRoundTrip() {
        for s in ["images/a b/c.png", "图/a.png", "a+b#c?.png", "feat/x"] {
            #expect(GitHubEncoding.decodePath(GitHubEncoding.encodePath(s)) == s)
        }
        // A truncated escape stays literal rather than swallowing the rest.
        #expect(GitHubEncoding.decodePath("a%2") == "a%2")
    }

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

    @Test("a history row keeps the repository it was uploaded to")
    func historyRowDoesNotFollowCurrentConfig() throws {
        // Regression: both addresses were rebuilt from today's github.owner/repo/branch,
        // so a row uploaded before `github.repo` changed yielded a link into the new
        // repository — and a thumbnail 404.
        let r: HistoryRecord = try JSONDecoder().decode(HistoryRecord.self, from: Data("""
        { "time": "2026-08-19T23:00:22+08:00", "name": "shot", "path": "images/a b/c.png",
          "url": "https://raw.githubusercontent.com/o/r/main/images/a%20b/c.png",
          "sha": "abc", "size": 1, "deduped": false }
        """.utf8))
        var other = Self.config
        other.github.repo = "other"
        other.github.branch = "feat/x"
        let link = UploadedLink(r, config: other)
        #expect(link.url(.cdn) == "https://cdn.jsdelivr.net/gh/o/r@main/images/a%20b/c.png")
        #expect(link.url(.raw) == "https://raw.githubusercontent.com/o/r/main/images/a%20b/c.png")
        // And it does not need a config at all, once the stored URL parses.
        let noConfig = UploadedLink(r, config: nil)
        #expect(noConfig.url(.raw) == link.url(.raw))
        #expect(noConfig.url(.cdn) == link.url(.cdn))
    }

    @Test("persisted owner repo branch win over parsing the stored URL")
    func persistedTargetIsAuthoritative() {
        let r = HistoryRecord(time: "2026-08-19T23:00:22+08:00", name: "shot",
                              path: "a.png",
                              url: "https://cdn.jsdelivr.net/gh/old/old@main/a.png",
                              sha: "abc", size: 1, deduped: false,
                              owner: "o", repo: "r", branch: "main")
        let link = UploadedLink(r, config: nil)
        #expect(link.url(.cdn) == "https://cdn.jsdelivr.net/gh/o/r@main/a.png")
        #expect(link.url(.raw) == "https://raw.githubusercontent.com/o/r/main/a.png")
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

    /// The bridge the whole "config is the single answer" design rests on: what the
    /// file says is what the app copies, and what the app writes is what the file
    /// gets. A one-way mapping would let the window display one form and copy another.
    @Test("a config round-trips through LinkForm and back")
    func configRoundTrip() {
        for syntax in LinkSyntax.allCases {
            for target in LinkTarget.allCases {
                let form = LinkForm(syntax: syntax, target: target)
                let written = form.applied(to: Self.config)
                #expect(written.upload.format == syntax.rawValue)
                #expect(written.upload.linkKind == target.rawValue)
                // Read back out, it is the same point in the grid.
                #expect(LinkForm(config: written) == form)
                // And nothing else moved: `applied(to:)` is not a config rewrite.
                #expect(changedKeys(from: Self.config, to: written)
                        .allSatisfy { $0 == .format || $0 == .linkKind })
            }
        }
    }

    /// Not laxness — `Config::validate` refuses both keys before the app sees them, so
    /// a fallback means the app is holding something the CLI would have rejected.
    /// Markdown · CDN is what every version before these keys existed produced.
    @Test("a config the CLI would have refused falls back instead of crashing")
    func unparsableConfigFallsBack() {
        var broken = Self.config
        broken.upload.format = "htlm"
        broken.upload.linkKind = "raw2"
        #expect(LinkForm(config: broken) == LinkForm(syntax: .markdown, target: .cdn))
    }

    @Test("raw values are the CLI's own spellings, since they cross that boundary")
    func rawValues() {
        // `upload.link_kind` is written with these, `upload.format` with those, and
        // `--link` / `--format` read the same spellings. `markdown` is the Swift case
        // name; `md` is what crosses the boundary.
        #expect(LinkTarget.allCases.map(\.rawValue) == ["cdn", "raw"])
        #expect(LinkSyntax.allCases.map(\.rawValue) == ["md", "html", "url"])
    }
}
