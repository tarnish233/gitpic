import Foundation

/// Which syntax a copied snippet is wrapped in — the app's mirror of the CLI's
/// `--format` (`OutputFormat`, `src/cli.rs:16`).
///
/// One of **two independent dimensions**, the other being ``LinkTarget``. They used
/// to be a single flat four-case enum — `markdown, html, cdn, raw` — which is not a
/// decomposition of anything: `markdown` and `html` carried whichever address
/// `upload.link_kind` happened to select, while `cdn` and `raw` were bare URLs. Two
/// consequences, both real: "Markdown pointing at the raw URL" had no entry at all,
/// and the history pane's `cdn` case handed back a `raw.githubusercontent.com` link
/// whenever the config said `raw`, under a label that said CDN.
///
/// The CLI has had these as separate flags (`--format` × `--link`) since before the
/// app existed. This type and ``LinkTarget`` are that same split.
public enum LinkSyntax: String, Sendable, CaseIterable, Identifiable {
    case markdown, html, url

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .markdown: return "Markdown"
        case .html:     return "HTML"
        case .url:      return "纯链接"
        }
    }
}

/// Which host serves the image — the app's mirror of the CLI's `--link`
/// (`LinkKind`, `src/cli.rs:8`) and of the `upload.link_kind` config key.
///
/// Independent of ``LinkSyntax``: every syntax can address either host.
public enum LinkTarget: String, Sendable, CaseIterable, Identifiable {
    case cdn, raw

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .cdn: return "CDN"
        case .raw: return "Raw"
        }
    }

    /// The label for surfaces with room to name the host, which is the thing
    /// actually being chosen between.
    public var detailedLabel: String {
        switch self {
        case .cdn: return "CDN (jsDelivr)"
        case .raw: return "Raw (GitHub)"
        }
    }
}

/// One point in the ``LinkSyntax`` × ``LinkTarget`` grid.
public struct LinkForm: Sendable, Hashable {
    public var syntax: LinkSyntax
    public var target: LinkTarget

    public init(syntax: LinkSyntax = .markdown, target: LinkTarget = .cdn) {
        self.syntax = syntax
        self.target = target
    }

    /// Both halves. A report naming only one of them ("已复制 Markdown") left the
    /// other invisible, which is precisely the collapse this type undoes.
    public var label: String { "\(syntax.label) · \(target.label)" }
}

// MARK: - URLs

/// The two public URL forms, built exactly as `src/link.rs` builds them.
///
/// Ported rather than read back out of the CLI's output, because the output does
/// not carry both. `ItemResult.url` is whichever kind `upload.link_kind` selected
/// (`src/commands/upload.rs:36-42`), so a raw-configured host emits no jsDelivr URL
/// anywhere in the envelope; `list --json` is narrower still — one URL per row, and
/// nothing recording which kind it is.
///
/// Every interpolated value is encoded, not just the path. `src/link.rs` gives the
/// reason: a branch is the one field that realistically carries `&`, `#`, `+` or a
/// space, and unencoded it produces a link that breaks the surrounding Markdown or
/// resolves somewhere else.
public enum LinkURL {
    public static func cdn(owner: String, repo: String, branch: String,
                           path: String) -> String {
        "https://cdn.jsdelivr.net/gh/\(enc(owner))/\(enc(repo))@\(enc(branch))/\(enc(path))"
    }

    public static func raw(owner: String, repo: String, branch: String,
                           path: String) -> String {
        "https://raw.githubusercontent.com/\(enc(owner))/\(enc(repo))/\(enc(branch))/\(enc(path))"
    }

    public static func url(_ target: LinkTarget, owner: String, repo: String,
                           branch: String, path: String) -> String {
        switch target {
        case .cdn: return cdn(owner: owner, repo: repo, branch: branch, path: path)
        case .raw: return raw(owner: owner, repo: repo, branch: branch, path: path)
        }
    }

    /// Whether a jsDelivr URL on this branch would be dead — the port of
    /// `link::cdn_branch_is_ambiguous`.
    ///
    /// jsDelivr encodes the ref as `repo@branch/path`, so a branch containing `/`
    /// leaves the boundary between branch and path unparseable and the link 404s.
    /// Raw GitHub URLs put the branch in its own segments and are unaffected, which
    /// is why this asks only about the CDN form.
    ///
    /// The CLI refuses the *upload* over this (`reject_dead_cdn_link`), so no
    /// envelope ever carries such a URL. The app needs the predicate anyway because
    /// it builds CDN addresses itself, for repositories the CLI was never asked to
    /// serve over the CDN: `--link raw` on a `feat/x` branch uploads perfectly well,
    /// and rebuilding a CDN address for it would manufacture exactly the dead link
    /// the CLI declines to print.
    public static func cdnBranchIsAmbiguous(_ branch: String) -> Bool {
        branch.contains("/")
    }

    private static func enc(_ s: String) -> String { GitHubEncoding.encodePath(s) }
}

/// Why an image has no jsDelivr address, in the cases where it has none.
///
/// Carried rather than re-derived at copy time, and named rather than left to a
/// single hardcoded string, because the two causes need different things from the
/// reader: one is a transient read failure, the other is a config value only they
/// can change. Blaming the config file for a missing CDN link when the branch is
/// the problem is a message the user can act on wrongly.
public enum CDNUnavailable: Sendable, Hashable, Error {
    /// No config was readable when the upload landed, so there was nothing to build
    /// the URL from. Fresh uploads only — a history row is always built with one.
    case noConfig
    /// `github.branch` contains `/`. See ``LinkURL/cdnBranchIsAmbiguous(_:)``.
    case ambiguousBranch(branch: String)

    /// What to tell the user, naming the remedy where there is one.
    public var message: String {
        switch self {
        case .noConfig:
            return "上传时读不到配置，无法生成 CDN 链接"
        case .ambiguousBranch(let branch):
            return "分支 \(branch) 含 /，jsDelivr 无法解析这种 ref，"
                 + "CDN 链接会 404；请改用 Raw"
        }
    }
}

// MARK: - Snippets

/// Markdown and HTML snippets, escaped exactly as `src/link.rs` escapes them.
///
/// The app used to hand `ItemResult.markdown` and `ItemResult.html` straight to the
/// pasteboard, which is right — for the one address the CLI built them for. Making
/// syntax and address independent means building the other combinations here, and
/// building them by plain interpolation is how the history pane's
/// `"![\(r.name)](\(r.url))"` shipped: a filename containing `]` or `(` terminates
/// the label early and yields broken Markdown.
///
/// Both escapers walk `unicodeScalars`, not `Character`s, so that they match Rust's
/// `chars()` scalar-by-scalar. A `Character` loop would fold `\r\n` into one
/// grapheme and emit a single space where the CLI emits two.
public enum LinkText {
    public static func render(_ syntax: LinkSyntax, alt: String, url: String) -> String {
        switch syntax {
        case .markdown: return markdown(alt: alt, url: url)
        case .html:     return html(alt: alt, url: url)
        case .url:      return url
        }
    }

    public static func markdown(alt: String, url: String) -> String {
        "![\(escapingMarkdownAlt(alt))](\(escapingMarkdownURL(url)))"
    }

    public static func html(alt: String, url: String) -> String {
        "<img src=\"\(escapingHTMLAttribute(url))\" alt=\"\(escapingHTMLAttribute(alt))\">"
    }

    /// An unescaped `[`, `]`, `(` or `)` out of a filename would terminate the
    /// `![...]` label early; a newline would break out of the inline image syntax
    /// altogether.
    static func escapingMarkdownAlt(_ alt: String) -> String {
        var out = String.UnicodeScalarView()
        out.reserveCapacity(alt.unicodeScalars.count)
        for u in alt.unicodeScalars {
            switch u {
            case "[", "]", "(", ")", "\\":
                out.append("\\")
                out.append(u)
            case "\n", "\r":
                out.append(" ")
            default:
                out.append(u)
            }
        }
        return String(out)
    }

    /// The delimiters of a CommonMark inline-link destination.
    static func escapingMarkdownURL(_ url: String) -> String {
        var out = String.UnicodeScalarView()
        out.reserveCapacity(url.unicodeScalars.count)
        for u in url.unicodeScalars {
            if u == "\\" || u == "(" || u == ")" { out.append("\\") }
            out.append(u)
        }
        return String(out)
    }

    /// A quote in the alt text must not be able to escape the attribute.
    static func escapingHTMLAttribute(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.unicodeScalars.count)
        for u in s.unicodeScalars {
            switch u {
            case "&":  out += "&amp;"
            case "\"": out += "&quot;"
            case "'":  out += "&#39;"
            case "<":  out += "&lt;"
            case ">":  out += "&gt;"
            default:   out.unicodeScalars.append(u)
            }
        }
        return out
    }
}

// MARK: - One uploaded image, in both addresses

/// One image that is live in the repository, with both address forms resolved.
///
/// Resolved when the upload lands rather than when a snippet is copied: the URLs are
/// built from `github.owner/repo/branch`, so deriving them at copy time would make
/// a menu entry from ten minutes ago silently follow a target that upload never
/// used.
public struct UploadedLink: Sendable, Hashable, Identifiable {
    public let id: String
    /// The alt text, already stem-only as `naming::alt_text` produced it.
    public let name: String
    public let path: String
    /// The jsDelivr address, or why there is none.
    ///
    /// A `Result` rather than a `String?` alongside a separate reason field, so that
    /// "there is no address" and "here is why" cannot drift apart. Not flattened to
    /// the raw URL on failure, because a raw link under a label reading CDN is the
    /// exact bug this type replaces.
    public let cdn: Result<String, CDNUnavailable>
    public let rawURL: String
    public let deduped: Bool

    public init(id: String, name: String, path: String,
                cdn: Result<String, CDNUnavailable>, rawURL: String, deduped: Bool) {
        self.id = id
        self.name = name
        self.path = path
        self.cdn = cdn
        self.rawURL = rawURL
        self.deduped = deduped
    }

    public var cdnURL: String? { try? cdn.get() }

    public func url(_ target: LinkTarget) -> String? {
        switch target {
        case .cdn: return cdnURL
        case .raw: return rawURL
        }
    }

    /// Why the requested address is missing, when it is.
    ///
    /// `nil` for `raw`, which is always present, and for a CDN address that
    /// resolved — so a non-`nil` return is exactly the case ``snippet(_:)`` cannot
    /// serve, and carries the sentence to show for it.
    public func unavailable(_ target: LinkTarget) -> CDNUnavailable? {
        guard target == .cdn, case .failure(let why) = cdn else { return nil }
        return why
    }

    /// The text to put on the pasteboard, or `nil` when this link has no address of
    /// the requested kind — ``unavailable(_:)`` says why.
    public func snippet(_ form: LinkForm) -> String? {
        url(form.target).map { LinkText.render(form.syntax, alt: name, url: $0) }
    }
}

extension UploadedLink {
    /// The jsDelivr address for a config, or why it has none.
    ///
    /// The one place both initialisers decide this, so a fresh upload and a history
    /// row cannot disagree about whether the same repository has a CDN address.
    private static func cdn(for c: GitpicConfig?, path: String)
        -> Result<String, CDNUnavailable> {
        guard let c else { return .failure(.noConfig) }
        let branch = c.github.branch
        guard !LinkURL.cdnBranchIsAmbiguous(branch) else {
            return .failure(.ambiguousBranch(branch: branch))
        }
        return .success(LinkURL.cdn(owner: c.github.owner, repo: c.github.repo,
                                    branch: branch, path: path))
    }

    /// From a fresh upload.
    ///
    /// `raw_url` is taken verbatim, since the envelope always carries it. The CDN
    /// form is rebuilt from `config`, since the envelope may not: `url` is whichever
    /// kind `upload.link_kind` selected, so under `link_kind = "raw"` it is
    /// byte-identical to `raw_url` and no jsDelivr URL is emitted at all.
    ///
    /// `config` is optional only because it is loaded asynchronously. In practice it
    /// is always there by the time an envelope arrives — an upload that succeeded
    /// proves a valid config is on disk, and `AppModel.reload`'s `config get` is
    /// queued ahead of every upload on `GitpicRunner`'s gate — and when it is not,
    /// the raw address is still real and still copyable.
    public init(_ r: ItemResult, config c: GitpicConfig?) {
        self.init(
            id: r.id,
            name: r.name,
            path: r.path,
            cdn: Self.cdn(for: c, path: r.path),
            rawURL: r.rawURL,
            deduped: r.deduped)
    }

    /// From a history row.
    ///
    /// Both forms are rebuilt here, because `list` stores exactly one URL per row and
    /// nothing saying which kind it is (`src/commands/upload.rs:187-195`). The cost is
    /// unavoidable and worth stating: these follow the target as it is configured
    /// *now*, so a row uploaded before `github.repo` changed yields a link into the
    /// new repository.
    public init(_ r: HistoryRecord, config c: GitpicConfig) {
        self.init(
            id: r.id,
            name: r.name,
            path: r.path,
            cdn: Self.cdn(for: c, path: r.path),
            rawURL: LinkURL.raw(owner: c.github.owner, repo: c.github.repo,
                                branch: c.github.branch, path: r.path),
            deduped: r.deduped)
    }
}
