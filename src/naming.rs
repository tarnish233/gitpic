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

/// Reject a remote path that would escape the repository or confuse the API.
///
/// The path template is user-supplied from three directions — `config set`, the
/// `--path` flag, and a hand-edited `config.toml` — so the check belongs on the
/// *rendered* result, which is the one thing all three funnel into. A `..`
/// segment or a leading `/` produces a request GitHub answers with a puzzling
/// 404 rather than a usable error, and `{name}` cannot introduce either (the
/// slug keeps only alphanumerics, `-` and `_`, mapping `.` to `-`), so only the
/// template's own literal text can.
pub fn is_safe_remote_path(path: &str) -> bool {
    !path.is_empty()
        && !path.starts_with('/')
        && !path
            .split('/')
            .any(|seg| seg == ".." || seg.is_empty() || seg == ".")
}

/// Judge a path template, returning the bare reason it is unusable.
///
/// The one owner of both halves of that judgement: the dummy sample it is made
/// against (`sample.png` plus a 64-char hash — `{name}` cannot inject `..`, since
/// slugify keeps only alphanumerics, `-` and `_`), and the sentence describing the
/// failure. Both used to be written out at each of the two callers, so the sample was
/// duplicated state that had to stay in sync by hand for the two messages to describe
/// the same rule, and the sentences had already drifted apart.
///
/// The message is bare so the caller can name its own field and attach its own code —
/// `upload.path_template` / `CONFIG_INVALID` from `Config::validate`, `path template` /
/// `USAGE` from `--path` — which is the split `Config::validate` already uses for
/// every other check.
pub fn check_template(template: &str) -> std::result::Result<(), String> {
    let sample = render_path(template, "sample.png", &"0".repeat(64));
    if is_safe_remote_path(&sample) {
        return Ok(());
    }
    Err(format!(
        "must be repo-relative with no empty or `..` segments (renders to {sample:?})"
    ))
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
/// Use this for file paths and for `?ref=` (GitHub wants `feat/x` as one query
/// value). Use [`encode_segment`] when the value occupies a single URL path slot.
pub fn encode_path(path: &str) -> String {
    encode_bytes(path, true)
}

/// Percent-encode one URL path segment, including `/` as `%2F`.
///
/// Owner, repo, and a branch sitting in `/branches/{branch}` are each one slot.
/// Leaving `/` intact in that slot (`feat/x`) would add path segments and hit
/// the wrong endpoint.
pub fn encode_segment(s: &str) -> String {
    encode_bytes(s, false)
}

fn encode_bytes(s: &str, keep_slash: bool) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        match b {
            b'/' if keep_slash => out.push('/'),
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
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
    fn encode_segment_encodes_a_slash_so_it_cannot_add_path_slots() {
        assert_eq!(encode_segment("feat/x"), "feat%2Fx");
        assert_eq!(encode_segment("main"), "main");
        assert_eq!(encode_path("feat/x"), "feat/x");
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

    #[test]
    fn a_path_that_escapes_the_repo_is_rejected() {
        // Regression: `config set upload.path_template ../../../etc/{name}.{ext}`
        // was accepted and produced a request GitHub answers with a bare 404.
        assert!(!is_safe_remote_path("../../../etc/x.png"));
        assert!(!is_safe_remote_path("images/../../x.png"));
        assert!(!is_safe_remote_path("/absolute/x.png"));
        assert!(!is_safe_remote_path(""));
        // Empty and `.` segments are equally unusable as a Contents API path.
        assert!(!is_safe_remote_path("images//x.png"));
        assert!(!is_safe_remote_path("images/./x.png"));
        assert!(!is_safe_remote_path("images/x.png/"));
    }

    #[test]
    fn ordinary_paths_including_the_default_template_are_accepted() {
        assert!(is_safe_remote_path("x.png"));
        assert!(is_safe_remote_path("images/2026/08/abc12345-shot.png"));
        // The shipped default, rendered.
        let rendered = render_path(
            "images/{year}/{month}/{hash8}-{name}.{ext}",
            "shot.png",
            &"a".repeat(64),
        );
        assert!(is_safe_remote_path(&rendered), "{rendered}");
        // A dot inside a segment is fine — only a whole `..` segment is not.
        assert!(is_safe_remote_path("images/a..b/x.png"));
        assert!(is_safe_remote_path("\u{56fe}/x.png"));
    }

    #[test]
    fn a_template_is_judged_by_what_it_dummy_renders_to() {
        for bad in [
            "../x/{name}.{ext}",
            "../../etc/{name}.{ext}",
            "/abs/{name}.{ext}",
            "images/{name}//{ext}",
        ] {
            let why = check_template(bad).expect_err(bad);
            // The caller prefixes its own field name, so the message has to start
            // with the verb for `upload.path_template <why>` to read as a sentence.
            assert!(why.starts_with("must be repo-relative"), "{why}");
            assert!(why.contains("renders to"), "{why}");
        }
        check_template("images/{year}/{month}/{hash8}-{name}.{ext}").expect("the default");
        check_template("{name}.{ext}").expect("a bare name");
        // `{name}` slugifies `.` to `-`, so it cannot inject a `..` segment.
        check_template("{name}/x.png").expect("a literal segment after {name}");
    }
}
