//! Upload orchestration for files, stdin, and clipboard sources.

use super::{build_item, resolve_link_kind, resolve_template, InputImage};
use crate::cli::{Cli, Command};
use crate::config::Config;
use crate::error::{AppError, Result};
use crate::github::GitHub;
use crate::history::{self, Record};
use crate::imageproc::{self, CompressOpts};
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

    cfg.require_ready()?;

    let gh = GitHub::new(
        &cfg.github.token,
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

    let compress = CompressOpts {
        enabled: (cfg.upload.compress || cli.compress) && !cli.no_compress,
        max_width: cli.max_width.unwrap_or(cfg.upload.max_width),
        quality: cli.quality.unwrap_or(cfg.upload.quality),
    };

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
            cli.format,
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
        let mut joined = String::new();
        for (i, r) in results.iter().enumerate() {
            if i > 0 {
                joined.push('\n');
            }
            joined.push_str(&r.output);
        }
        if let Err(e) = copy_to_clipboard(&joined) {
            eprintln!("warning: could not copy to clipboard: {e}");
        }
    }

    match failure {
        None => {
            output::print_results(mode, &results);
            Ok(0)
        }
        // Nothing uploaded: this is an ordinary failure, so use the standard
        // error envelope rather than a partial one with an empty `results`.
        Some(e) if results.is_empty() => Err(e),
        Some(e) => {
            // Some inputs did upload. Report their links alongside the error so
            // the caller never loses a link that is already live.
            output::print_partial(mode, &results, e.code.as_str(), &e.message);
            Ok(e.code.exit_code())
        }
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
    let mut clip = arboard::Clipboard::new()
        .map_err(|e| AppError::new(crate::error::ErrorCode::General, format!("clipboard: {e}")))?;
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
        .map_err(|e| AppError::new(crate::error::ErrorCode::General, format!("encode png: {e}")))?;

    let raw_name = cli
        .name
        .clone()
        .unwrap_or_else(|| "clipboard.png".to_string());
    // ensure .png extension for clipboard captures
    let name = if Path::new(&raw_name).extension().is_some() {
        raw_name
    } else {
        format!("{raw_name}.png")
    };
    Ok(InputImage { name, bytes: png })
}

fn copy_to_clipboard(text: &str) -> std::result::Result<(), String> {
    let mut clip = arboard::Clipboard::new().map_err(|e| e.to_string())?;
    clip.set_text(text.to_string()).map_err(|e| e.to_string())
}
