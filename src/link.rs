//! Build public URLs + markdown/html snippets from an uploaded path.

use crate::cli::{LinkKind, OutputFormat};

pub fn raw_url(owner: &str, repo: &str, branch: &str, path: &str) -> String {
    format!("https://raw.githubusercontent.com/{owner}/{repo}/{branch}/{path}")
}

pub fn cdn_url(owner: &str, repo: &str, branch: &str, path: &str) -> String {
    format!("https://cdn.jsdelivr.net/gh/{owner}/{repo}@{branch}/{path}")
}

pub fn url_for(kind: LinkKind, owner: &str, repo: &str, branch: &str, path: &str) -> String {
    match kind {
        LinkKind::Cdn => cdn_url(owner, repo, branch, path),
        LinkKind::Raw => raw_url(owner, repo, branch, path),
    }
}

pub fn markdown(alt: &str, url: &str) -> String {
    format!("![{alt}]({url})")
}

pub fn html(alt: &str, url: &str) -> String {
    format!("<img src=\"{url}\" alt=\"{alt}\">")
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
