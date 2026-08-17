//! Upload orchestration for files, stdin, and clipboard sources.

use super::{build_item, resolve_compress, resolve_link_kind, resolve_template, InputImage};
use crate::cli::{Cli, Command};
use crate::config::Config;
use crate::error::{AppError, Result};
use crate::github::GitHub;
use crate::history::{self, Record};
use crate::imageproc;
use crate::naming;
use crate::output::{self, ItemResult, Mode};
use std::io::Read;
use std::path::Path;

/// Entry point for the default (upload) path and `paste`.
///
/// Returns the process exit code: 0 when every input uploaded, otherwise the
/// code of the first failure. Inputs that already uploaded are still reported
/// so their links are never lost.
pub async fn run(cli: &Cli, cfg: &Config, mode: Mode) -> Result<u8> {
    let is_paste = matches!(cli.command, Some(Command::Paste));

    // Guard against silently dropping inputs when sources are mixed. (`paste`
    // plus file args needs no check: clap rejects positionals after the
    // subcommand, and `gitpic a.png paste` parses `paste` as a filename.)
    if cli.stdin && !cli.files.is_empty() {
        return Err(AppError::usage(
            "--stdin reads the image from stdin; do not also pass file arguments",
        ));
    }
    if is_paste && cli.stdin {
        return Err(AppError::usage("--stdin cannot be combined with `paste`"));
    }

    let inputs = if is_paste {
        vec![read_clipboard(cli)?]
    } else if cli.stdin {
        vec![read_stdin(cli)?]
    } else {
        read_files(&cli.files)?
    };

    if inputs.is_empty() {
        return Err(AppError::usage(
            "no image provided (pass a file, --stdin, or use `gitpic paste`)",
        ));
    }

    cfg.require_target()?;

    // Resolved here, after the inputs are in hand: a credential helper may take
    // a moment, and there is no point paying for it to upload a broken image.
    let cred = crate::auth::resolve(cfg)?;

    let gh = GitHub::new(
        &cred.token,
        &cfg.github.owner,
        &cfg.github.repo,
        &cfg.github.branch,
    )?;

    let kind = resolve_link_kind(cli, cfg);
    let template = resolve_template(cli, cfg).to_string();
    let dedup = cfg.upload.dedup;

    if crate::link::cdn_branch_is_ambiguous(kind, &cfg.github.branch) {
        eprintln!(
            "warning: branch {:?} contains '/', which makes the jsDelivr CDN URL ambiguous; \
             consider --link raw",
            cfg.github.branch
        );
    }

    let compress = resolve_compress(cli, cfg);

    if cli.verbose > 0 {
        eprintln!(
            "gitpic: target {}/{}@{} link={:?} compress={}",
            cfg.github.owner, cfg.github.repo, cfg.github.branch, kind, compress.enabled
        );
    }

    let mut results: Vec<ItemResult> = Vec::with_capacity(inputs.len());
    let mut failure: Option<AppError> = None;

    // Uploads are deliberately serial: each Contents API PUT creates a commit
    // that advances the branch ref, so concurrent PUTs race and fail with
    // "409 is at <sha> but expected <sha>" even for distinct paths.
    for img in inputs {
        let orig_len = img.bytes.len();
        let name = img.name;
        // Pass ownership so an uncompressed upload does not copy the payload.
        let bytes = imageproc::maybe_compress(img.bytes, &compress);
        if cli.verbose > 1 && bytes.len() != orig_len {
            eprintln!(
                "gitpic: {} compressed {} -> {} bytes",
                name,
                orig_len,
                bytes.len()
            );
        }
        let hash = naming::sha256_hex(&bytes);
        let remote_path = naming::render_path(&template, &name, &hash);
        // Checked on the rendered result, the single point every template source
        // funnels into — `config set`, `--path`, and a hand-edited config.toml.
        if !naming::is_safe_remote_path(&remote_path) {
            return Err(AppError::usage(format!(
                "path template produced an unusable remote path {remote_path:?}: \
                 it must be repo-relative with no empty or `..` segments"
            )));
        }
        let message = format!("gitpic: upload {remote_path}");

        let outcome = match gh.put_file(&remote_path, &bytes, &message, dedup).await {
            Ok(o) => o,
            Err(mut e) => {
                // Keep the links for everything already uploaded; report the
                // first failure and stop, since later inputs would race the
                // branch ref anyway. Prefix the input name so the caller knows
                // which one failed; the message is printed once, below.
                e.message = format!("{name}: {}", e.message);
                failure = Some(e);
                break;
            }
        };

        if cli.verbose > 0 {
            eprintln!(
                "gitpic: {} -> {} ({} bytes){}",
                name,
                outcome.path,
                outcome.size,
                if outcome.deduped { " [deduped]" } else { "" }
            );
        }
        let item = build_item(
            &outcome,
            &name,
            kind,
            cli.effective_format(),
            &cfg.github.owner,
            &cfg.github.repo,
            &cfg.github.branch,
        );
        // Record to local history (best-effort; never fail an upload for this).
        if let Err(e) = history::append(&Record {
            time: chrono::Local::now().to_rfc3339(),
            name: item.name.clone(),
            path: item.path.clone(),
            url: item.url.clone(),
            sha: item.sha.clone(),
            size: item.size,
            deduped: item.deduped,
        }) {
            if cli.verbose > 0 {
                eprintln!("warning: could not record history: {}", e.message);
            }
        }
        results.push(item);
    }

    // Copy to clipboard only for interactive/human use.
    let want_copy = cfg.upload.auto_copy && !cli.no_copy && matches!(mode, Mode::Human);
    if want_copy && !results.is_empty() {
        let joined = results
            .iter()
            .map(|r| r.output.as_str())
            .collect::<Vec<_>>()
            .join("\n");
        if let Err(e) = copy_to_clipboard(&joined) {
            eprintln!("warning: could not copy to clipboard: {e}");
        }
    }

    match classify(failure, results.len()) {
        Report::Success => {
            output::print_results(mode, &results);
            Ok(0)
        }
        Report::Total(e) => Err(e),
        Report::Partial(e) => {
            // Some inputs did upload. Report their links alongside the error so
            // the caller never loses a link that is already live.
            output::print_partial(mode, &results, e.code.as_str(), &e.message);
            Ok(e.code.exit_code())
        }
    }
}

/// Which envelope a finished run gets.
#[derive(Debug)]
enum Report {
    Success,
    /// Some inputs uploaded before a later one failed; their links are live.
    Partial(AppError),
    /// Nothing uploaded, so the ordinary error envelope applies.
    Total(AppError),
}

/// Decide how a run is reported.
///
/// Split out of `run` because the rule it encodes is an agent-facing contract
/// that was previously only stated in a comment: the partial shape means "some
/// of these links are live", and agents key off `results` being present to tell
/// partial from total (see `skills/gitpic/SKILL.md`), so an empty `results` must
/// never be reported that way.
fn classify(failure: Option<AppError>, uploaded: usize) -> Report {
    match failure {
        None => Report::Success,
        Some(e) if uploaded == 0 => Report::Total(e),
        Some(e) => Report::Partial(e),
    }
}

fn read_files(files: &[std::path::PathBuf]) -> Result<Vec<InputImage>> {
    let mut out = Vec::with_capacity(files.len());
    for f in files {
        if !f.exists() {
            return Err(AppError::not_found(format!(
                "file not found: {}",
                f.display()
            )));
        }
        let bytes = std::fs::read(f)
            .map_err(|e| AppError::not_found(format!("read {}: {e}", f.display())))?;
        let name = f
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or("image.png")
            .to_string();
        out.push(InputImage { name, bytes });
    }
    Ok(out)
}

fn read_stdin(cli: &Cli) -> Result<InputImage> {
    let mut bytes = Vec::new();
    std::io::stdin()
        .read_to_end(&mut bytes)
        .map_err(|e| AppError::usage(format!("read stdin: {e}")))?;
    if bytes.is_empty() {
        return Err(AppError::usage("stdin was empty"));
    }
    let name = cli.name.clone().unwrap_or_else(|| "image.png".to_string());
    Ok(InputImage { name, bytes })
}

fn read_clipboard(cli: &Cli) -> Result<InputImage> {
    use image::ImageEncoder;
    let mut clip =
        arboard::Clipboard::new().map_err(|e| AppError::general(format!("clipboard: {e}")))?;
    let img = clip
        .get_image()
        .map_err(|e| AppError::usage(format!("no image in clipboard: {e}")))?;

    // arboard gives RGBA8 raw pixels; encode to PNG.
    let mut png: Vec<u8> = Vec::new();
    let encoder = image::codecs::png::PngEncoder::new(&mut png);
    encoder
        .write_image(
            &img.bytes,
            img.width as u32,
            img.height as u32,
            image::ExtendedColorType::Rgba8,
        )
        .map_err(|e| AppError::general(format!("encode png: {e}")))?;

    Ok(InputImage {
        name: clipboard_name(cli.name.as_deref()),
        bytes: png,
    })
}

/// Name a clipboard capture.
///
/// The bytes are always PNG (encoded above), so the extension has to say so.
/// Honouring a user-supplied `--name shot.jpg` would publish PNG bytes at a
/// `.jpg` path, which GitHub and jsDelivr then serve as `image/jpeg`.
fn clipboard_name(explicit: Option<&str>) -> String {
    let stem = explicit
        .map(Path::new)
        .and_then(|p| p.file_stem())
        .and_then(|s| s.to_str())
        // A leading dot makes the whole name the "stem" (`.png` -> `.png`), so
        // reject those rather than emitting `.png.png`.
        .filter(|s| !s.is_empty() && !s.starts_with('.'))
        .unwrap_or("clipboard");
    format!("{stem}.png")
}

fn copy_to_clipboard(text: &str) -> std::result::Result<(), String> {
    let mut clip = arboard::Clipboard::new().map_err(|e| e.to_string())?;
    clip.set_text(text.to_string()).map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clipboard_name_defaults_when_unnamed() {
        assert_eq!(clipboard_name(None), "clipboard.png");
    }

    #[test]
    fn clipboard_name_keeps_an_explicit_stem() {
        assert_eq!(clipboard_name(Some("shot")), "shot.png");
        assert_eq!(clipboard_name(Some("shot.png")), "shot.png");
    }

    #[test]
    fn clipboard_name_rewrites_a_mismatched_extension() {
        // Regression: the bytes are always PNG, so honouring ".jpg" published
        // PNG data at a .jpg path, which GitHub serves as image/jpeg.
        assert_eq!(clipboard_name(Some("shot.jpg")), "shot.png");
        assert_eq!(clipboard_name(Some("shot.webp")), "shot.png");
    }

    #[test]
    fn clipboard_name_falls_back_on_an_unusable_name() {
        assert_eq!(clipboard_name(Some("")), "clipboard.png");
        assert_eq!(clipboard_name(Some(".png")), "clipboard.png");
    }

    #[test]
    fn a_clean_run_is_reported_as_success() {
        assert!(matches!(classify(None, 3), Report::Success));
    }

    #[test]
    fn links_already_live_survive_a_later_failure() {
        assert!(matches!(
            classify(Some(AppError::network("boom")), 2),
            Report::Partial(_)
        ));
    }

    #[test]
    fn nothing_uploaded_never_uses_the_partial_envelope() {
        // Agents tell partial from total by whether `results` is present, so a
        // run that uploaded nothing must take the plain error envelope.
        assert!(matches!(
            classify(Some(AppError::network("boom")), 0),
            Report::Total(_)
        ));
    }
}
