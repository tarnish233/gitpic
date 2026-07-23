//! Remote path generation from a template + content hashing.

use chrono::Datelike;
use sha2::{Digest, Sha256};
use std::path::Path;

/// Compute the hex sha256 of the given bytes.
pub fn sha256_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    let out = hasher.finalize();
    let mut s = String::with_capacity(out.len() * 2);
    for b in out {
        s.push_str(&format!("{:02x}", b));
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
        .unwrap_or("png")
        .to_ascii_lowercase();

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
}
