//! Remote path generation from a template + content hashing.

use chrono::Datelike;
use sha2::{Digest, Sha256};
use std::fmt::Write as _;
use std::path::Path;

/// Compute the hex sha256 of the given bytes.
pub fn sha256_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    let out = hasher.finalize();
    let mut s = String::with_capacity(out.len() * 2);
    for b in out {
        // write! into the existing buffer; format! would allocate per byte.
        let _ = write!(s, "{b:02x}");
    }
    s
}

/// Sanitize a filename stem into a URL/path-safe slug.
fn slugify(stem: &str) -> String {
    let mut out = String::with_capacity(stem.len());
    for c in stem.chars() {
        if c.is_ascii_alphanumeric() || c == '-' || c == '_' {
            out.push(c.to_ascii_lowercase());
        } else if c.is_whitespace() || c == '.' {
            out.push('-');
        }
        // drop everything else
    }
    // May be empty for all-non-ASCII names; the caller substitutes a unique
    // fallback (content hash) so distinct images never collapse to one name.
    out.trim_matches('-').to_string()
}

/// Sanitize a file extension into a URL/path-safe suffix.
///
/// Only ASCII alphanumerics survive: an extension reaches the remote path and
/// the generated link verbatim, so characters like `#`, `?`, or a space would
/// truncate or corrupt the URL. Returns `None` when nothing usable is left.
fn sanitize_ext(ext: &str) -> Option<String> {
    let out: String = ext
        .chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .map(|c| c.to_ascii_lowercase())
        .collect();
    if out.is_empty() {
        None
    } else {
        Some(out)
    }
}

/// Render the path template.
///
/// Supported placeholders:
///   {year} {month} {day} {hash} {hash8} {name} {ext}
pub fn render_path(template: &str, original_name: &str, hash_hex: &str) -> String {
    let now = chrono::Local::now();
    let path = Path::new(original_name);
    let stem = path.file_stem().and_then(|s| s.to_str()).unwrap_or("image");
    let ext = path
        .extension()
        .and_then(|s| s.to_str())
        .and_then(sanitize_ext)
        .unwrap_or_else(|| "png".to_string());

    let hash8 = &hash_hex[..hash_hex.len().min(8)];
    // Use the slug when available; otherwise fall back to the content hash so
    // non-ASCII filenames stay unique instead of all becoming the same name.
    let slug = slugify(stem);
    let name = if slug.is_empty() {
        hash8.to_string()
    } else {
        slug
    };

    template
        .replace("{year}", &format!("{:04}", now.year()))
        .replace("{month}", &format!("{:02}", now.month()))
        .replace("{day}", &format!("{:02}", now.day()))
        .replace("{hash8}", hash8)
        .replace("{hash}", hash_hex)
        .replace("{name}", &name)
        .replace("{ext}", &ext)
}

/// Derive an alt-text label from an original filename.
pub fn alt_text(original_name: &str) -> String {
    Path::new(original_name)
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("image")
        .to_string()
}

/// Percent-encode a remote path for use in a URL, preserving `/` separators.
///
/// A path template may legitimately contain spaces or non-ASCII characters
/// (e.g. `图片/{hash8}.{ext}`), which GitHub accepts as a path but which must be
/// encoded before they reach either the API URL or the generated public link.
pub fn encode_path(path: &str) -> String {
    let mut out = String::with_capacity(path.len());
    for b in path.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' | b'/' => {
                out.push(b as char)
            }
            _ => {
                let _ = write!(out, "%{b:02X}");
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn template_renders_placeholders() {
        let hash = "abcdef1234567890";
        let p = render_path("images/{hash8}-{name}.{ext}", "My Photo.PNG", hash);
        assert_eq!(p, "images/abcdef12-my-photo.png");
    }

    #[test]
    fn alt_text_strips_ext() {
        assert_eq!(alt_text("dir/shot.jpg"), "shot");
    }

    #[test]
    fn non_ascii_name_falls_back_to_hash() {
        let hash = "abcdef1234567890";
        // All non-ASCII stem => slug empty => name becomes hash8, not "image".
        let p = render_path("{name}.{ext}", "\u{56fe}\u{7247}.png", hash);
        assert_eq!(p, "abcdef12.png");
    }

    #[test]
    fn extension_is_sanitized_like_the_name() {
        let hash = "abcdef1234567890";
        // A '#' or '?' in the extension would truncate or corrupt the URL.
        assert_eq!(
            render_path("{hash8}.{ext}", "weird.p#ng", hash),
            "abcdef12.png"
        );
        assert_eq!(
            render_path("{hash8}.{ext}", "weird.pn?g", hash),
            "abcdef12.png"
        );
        // A space must not survive into the path either.
        assert_eq!(
            render_path("{hash8}.{ext}", "weird.p g", hash),
            "abcdef12.pg"
        );
    }

    #[test]
    fn extension_with_nothing_usable_falls_back_to_png() {
        let hash = "abcdef1234567890";
        assert_eq!(render_path("{hash8}.{ext}", "f.###", hash), "abcdef12.png");
        // No extension at all also falls back.
        assert_eq!(render_path("{hash8}.{ext}", "noext", hash), "abcdef12.png");
    }

    #[test]
    fn extension_case_is_normalized() {
        let hash = "abcdef1234567890";
        assert_eq!(render_path("{hash8}.{ext}", "a.PNG", hash), "abcdef12.png");
        assert_eq!(
            render_path("{hash8}.{ext}", "a.JpEg", hash),
            "abcdef12.jpeg"
        );
    }

    #[test]
    fn encode_path_preserves_separators_and_escapes_the_rest() {
        assert_eq!(encode_path("images/a-b_c.png"), "images/a-b_c.png");
        assert_eq!(encode_path("my images/a.png"), "my%20images/a.png");
        // Multi-byte UTF-8 is percent-encoded per byte.
        assert_eq!(encode_path("\u{56fe}/a.png"), "%E5%9B%BE/a.png");
        // Characters that would otherwise change URL structure.
        assert_eq!(encode_path("a#b/c?d.png"), "a%23b/c%3Fd.png");
    }

    #[test]
    fn sha256_hex_is_lowercase_and_64_chars() {
        let h = sha256_hex(b"");
        assert_eq!(
            h,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
        assert_eq!(h.len(), 64);
    }
}
