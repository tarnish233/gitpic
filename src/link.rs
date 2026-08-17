//! Build public URLs + markdown/html snippets from an uploaded path.

use crate::cli::{LinkKind, OutputFormat};
use crate::naming::encode_path;

pub fn raw_url(owner: &str, repo: &str, branch: &str, path: &str) -> String {
    format!(
        "https://raw.githubusercontent.com/{owner}/{repo}/{branch}/{}",
        encode_path(path)
    )
}

pub fn cdn_url(owner: &str, repo: &str, branch: &str, path: &str) -> String {
    format!(
        "https://cdn.jsdelivr.net/gh/{owner}/{repo}@{branch}/{}",
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
    format!("![{}]({})", escape_md_alt(alt), url)
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
pub fn parse_link_kind(s: &str) -> LinkKind {
    match s.trim().to_ascii_lowercase().as_str() {
        "raw" => LinkKind::Raw,
        _ => LinkKind::Cdn,
    }
}

/// Parse a link kind, rejecting anything unrecognized.
///
/// `parse_link_kind` is deliberately lenient because it reads an already-stored
/// value at upload time. Wherever a value is *accepted* from the user, use this
/// instead: otherwise `config set upload.link_kind raw2` reports success and
/// then silently serves CDN links forever.
pub fn parse_link_kind_strict(s: &str) -> Option<LinkKind> {
    match s.trim().to_ascii_lowercase().as_str() {
        "cdn" => Some(LinkKind::Cdn),
        "raw" => Some(LinkKind::Raw),
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
}
