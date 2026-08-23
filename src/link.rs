//! Build public URLs + markdown/html snippets from an uploaded path.

use crate::cli::{LinkKind, OutputFormat};
use crate::naming::encode_path;

/// Build the public URLs.
///
/// Every interpolated value is encoded, not just the path. A branch is the one
/// that can realistically carry trouble — git allows `&`, `#`, `+`, `%` and even
/// a space is only forbidden by convention in some tools — and an unencoded one
/// produces a link that breaks the surrounding Markdown or resolves elsewhere.
/// GitHub constrains owner and repo to `[A-Za-z0-9._-]`, so for those this is an
/// identity, kept for uniformity.
///
/// `/` is preserved by `encode_path`, which is what `raw` needs: the branch there
/// legitimately spans several path segments. For `cdn` that same `/` is what makes
/// the ref ambiguous — see [`cdn_branch_is_ambiguous`], which `reject_dead_cdn_link`
/// refuses the upload on before anything is committed.
pub fn raw_url(owner: &str, repo: &str, branch: &str, path: &str) -> String {
    format!(
        "https://raw.githubusercontent.com/{}/{}/{}/{}",
        encode_path(owner),
        encode_path(repo),
        encode_path(branch),
        encode_path(path)
    )
}

pub fn cdn_url(owner: &str, repo: &str, branch: &str, path: &str) -> String {
    format!(
        "https://cdn.jsdelivr.net/gh/{}/{}@{}/{}",
        encode_path(owner),
        encode_path(repo),
        encode_path(branch),
        encode_path(path)
    )
}

pub fn url_for(kind: LinkKind, owner: &str, repo: &str, branch: &str, path: &str) -> String {
    match kind {
        LinkKind::Cdn => cdn_url(owner, repo, branch, path),
        LinkKind::Raw => raw_url(owner, repo, branch, path),
    }
}

/// Escape alt text for use inside a Markdown `![...]` label.
///
/// An unescaped `]`, `[`, `(`, or `)` from a filename would terminate the label
/// early and produce broken Markdown.
fn escape_md_alt(alt: &str) -> String {
    let mut out = String::with_capacity(alt.len());
    for c in alt.chars() {
        match c {
            '[' | ']' | '(' | ')' | '\\' => {
                out.push('\\');
                out.push(c);
            }
            // A newline would break out of the inline image syntax.
            '\n' | '\r' => out.push(' '),
            _ => out.push(c),
        }
    }
    out
}

/// Escape delimiters inside a CommonMark inline-link destination.
fn escape_md_url(url: &str) -> String {
    let mut out = String::with_capacity(url.len());
    for c in url.chars() {
        if matches!(c, '\\' | '(' | ')') {
            out.push('\\');
        }
        out.push(c);
    }
    out
}

/// Escape text for use inside a double-quoted HTML attribute.
fn escape_html_attr(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            _ => out.push(c),
        }
    }
    out
}

pub fn markdown(alt: &str, url: &str) -> String {
    format!("![{}]({})", escape_md_alt(alt), escape_md_url(url))
}

pub fn html(alt: &str, url: &str) -> String {
    format!(
        "<img src=\"{}\" alt=\"{}\">",
        escape_html_attr(url),
        escape_html_attr(alt)
    )
}

pub fn render(format: OutputFormat, alt: &str, url: &str) -> String {
    match format {
        OutputFormat::Md => markdown(alt, url),
        OutputFormat::Html => html(alt, url),
        OutputFormat::Url => url.to_string(),
    }
}

/// Parse a config string into a LinkKind (defaults to Cdn).
///
/// Kept as the documented counter-example of the silent default that
/// [`parse_link_kind_strict`] exists to close. Production paths all go through
/// the strict parser: `Config::validate` refuses anything else before it can
/// reach an upload.
#[cfg(test)]
pub fn parse_link_kind(s: &str) -> LinkKind {
    match s.trim().to_ascii_lowercase().as_str() {
        "raw" => LinkKind::Raw,
        _ => LinkKind::Cdn,
    }
}

/// The link kind an upload will actually use.
///
/// [`parse_link_kind_strict`] plus the fallback the upload path applies, in one place
/// now that `doctor` has to reach the same verdict about the same config value. The
/// fallback is unreachable in practice — `Config::validate` refuses anything the strict
/// parser rejects before it can be loaded — and exists so neither caller has to invent
/// one of its own, which is how the two would come to disagree about a file neither
/// should ever see.
pub fn effective_link_kind(configured: &str) -> LinkKind {
    parse_link_kind_strict(configured).unwrap_or(LinkKind::Cdn)
}

/// Parse a link kind, rejecting anything unrecognized.
///
/// The previous reader defaulted anything it did not recognise to CDN, so
/// `config set upload.link_kind raw2` reported success and then silently served
/// CDN links forever. Every entry point that accepts a value uses this instead.
pub fn parse_link_kind_strict(s: &str) -> Option<LinkKind> {
    match s.trim().to_ascii_lowercase().as_str() {
        "cdn" => Some(LinkKind::Cdn),
        "raw" => Some(LinkKind::Raw),
        _ => None,
    }
}

/// Parse an output format, rejecting anything unrecognized.
///
/// The same reason `parse_link_kind_strict` exists: `upload.format` is now a config
/// key, and a value the reader silently defaulted to Markdown would make
/// `config set upload.format htlm` report success and then hand back Markdown
/// forever. The three spellings are exactly clap's `OutputFormat` value names, so
/// the file and the `--format` flag cannot disagree about what "html" means.
pub fn parse_output_format_strict(s: &str) -> Option<OutputFormat> {
    match s.trim().to_ascii_lowercase().as_str() {
        "md" => Some(OutputFormat::Md),
        "html" => Some(OutputFormat::Html),
        "url" => Some(OutputFormat::Url),
        _ => None,
    }
}

/// jsDelivr encodes the ref as `repo@branch/path`, so a branch containing `/`
/// makes the boundary between branch and path ambiguous. Raw GitHub URLs are
/// unaffected.
pub fn cdn_branch_is_ambiguous(kind: LinkKind, branch: &str) -> bool {
    matches!(kind, LinkKind::Cdn) && branch.contains('/')
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strict_parse_rejects_what_the_lenient_one_swallows() {
        // Regression: `config set upload.link_kind raw2` used to report success
        // and then serve cdn links forever.
        assert!(parse_link_kind_strict("raw2").is_none());
        assert!(parse_link_kind_strict("").is_none());
        assert!(parse_link_kind_strict("CDN ").is_some());
        assert!(matches!(
            parse_link_kind_strict(" Raw "),
            Some(LinkKind::Raw)
        ));
        // The lenient reader still defaults, which is why the strict one exists.
        assert!(matches!(parse_link_kind("raw2"), LinkKind::Cdn));
    }

    #[test]
    fn cdn_and_raw_urls() {
        assert_eq!(
            cdn_url("o", "r", "main", "a/b.png"),
            "https://cdn.jsdelivr.net/gh/o/r@main/a/b.png"
        );
        assert_eq!(
            raw_url("o", "r", "main", "a/b.png"),
            "https://raw.githubusercontent.com/o/r/main/a/b.png"
        );
    }

    #[test]
    fn markdown_format() {
        assert_eq!(markdown("alt", "u"), "![alt](u)");
    }

    #[test]
    fn markdown_alt_is_escaped() {
        // Unescaped brackets/parens would terminate the label and break the link.
        assert_eq!(markdown("a]b(c)", "u"), "![a\\]b\\(c\\)](u)");
        assert_eq!(markdown("a[b", "u"), "![a\\[b](u)");
        assert_eq!(markdown("back\\slash", "u"), "![back\\\\slash](u)");
    }

    #[test]
    fn markdown_alt_newlines_become_spaces() {
        assert_eq!(markdown("a\nb", "u"), "![a b](u)");
        assert_eq!(markdown("a\r\nb", "u"), "![a  b](u)");
    }

    #[test]
    fn markdown_url_parentheses_and_backslashes_are_escaped() {
        assert_eq!(
            markdown("image", "https://example.test/a)b(1)\\x.png"),
            "![image](https://example.test/a\\)b\\(1\\)\\\\x.png)"
        );
    }

    #[test]
    fn html_attributes_are_escaped() {
        // A quote in the alt text must not be able to escape the attribute.
        assert_eq!(
            html("x\")>evil<img", "u"),
            "<img src=\"u\" alt=\"x&quot;)&gt;evil&lt;img\">"
        );
        // Ampersands are escaped in both slots.
        assert_eq!(
            html("a&b", "u?x=1&y=2"),
            "<img src=\"u?x=1&amp;y=2\" alt=\"a&amp;b\">"
        );
    }

    #[test]
    fn urls_percent_encode_the_path() {
        assert_eq!(
            cdn_url("o", "r", "main", "my images/a.png"),
            "https://cdn.jsdelivr.net/gh/o/r@main/my%20images/a.png"
        );
        assert_eq!(
            raw_url("o", "r", "main", "\u{56fe}/a.png"),
            "https://raw.githubusercontent.com/o/r/main/%E5%9B%BE/a.png"
        );
    }

    #[test]
    fn cdn_branch_with_slash_is_flagged_ambiguous() {
        assert!(cdn_branch_is_ambiguous(LinkKind::Cdn, "feat/x"));
        assert!(!cdn_branch_is_ambiguous(LinkKind::Cdn, "main"));
        // Raw GitHub URLs put the branch in its own segment, so it is fine.
        assert!(!cdn_branch_is_ambiguous(LinkKind::Raw, "feat/x"));
    }

    #[test]
    fn parse_link_kind_defaults_to_cdn() {
        assert_eq!(parse_link_kind("raw"), LinkKind::Raw);
        assert_eq!(parse_link_kind(" RAW "), LinkKind::Raw);
        assert_eq!(parse_link_kind("cdn"), LinkKind::Cdn);
        assert_eq!(parse_link_kind("nonsense"), LinkKind::Cdn);
    }

    #[test]
    fn a_branch_name_cannot_break_out_of_the_url() {
        // Regression: the branch was interpolated raw, so a space or `)` in it
        // produced a link that terminated the Markdown label early.
        assert_eq!(
            raw_url("o", "r", "feat x", "a.png"),
            "https://raw.githubusercontent.com/o/r/feat%20x/a.png"
        );
        assert_eq!(
            cdn_url("o", "r", "a&b", "a.png"),
            "https://cdn.jsdelivr.net/gh/o/r@a%26b/a.png"
        );
        // Markdown built from it therefore carries no unescaped paren.
        let md = markdown("alt", &raw_url("o", "r", "we(ird", "a.png"));
        assert!(!md.contains("we(ird"), "{md}");
        assert!(md.ends_with(')') && md.matches(')').count() == 1, "{md}");
    }

    #[test]
    fn a_branch_with_a_slash_keeps_its_segments() {
        // `raw` needs the branch to span several path segments, so `/` survives.
        assert_eq!(
            raw_url("o", "r", "feat/x", "a.png"),
            "https://raw.githubusercontent.com/o/r/feat/x/a.png"
        );
    }
}
