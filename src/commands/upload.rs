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
pub async fn run(cli: &Cli, cfg: &Config, mode: Mode) -> Result<()> {
    let is_paste = matches!(cli.command, Some(Command::Paste));

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
    for img in &inputs {
        let (bytes, name) = imageproc::maybe_compress(&img.name, img.bytes.clone(), &compress);
        if cli.verbose > 1 && bytes.len() != img.bytes.len() {
            eprintln!(
                "gitpic: {} compressed {} -> {} bytes",
                img.name,
                img.bytes.len(),
                bytes.len()
            );
        }
        let hash = naming::sha256_hex(&bytes);
        let remote_path = naming::render_path(&template, &name, &hash);
        let message = format!("gitpic: upload {}", remote_path);
        let outcome = gh.put_file(&remote_path, &bytes, &message, dedup).await?;
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
        let _ = history::append(&Record {
            time: chrono::Local::now().to_rfc3339(),
            name: item.name.clone(),
            path: item.path.clone(),
            url: item.url.clone(),
            sha: item.sha.clone(),
            size: item.size,
            deduped: item.deduped,
        });
        results.push(item);
    }

    // Copy to clipboard only for interactive/human use.
    let want_copy = cfg.upload.auto_copy && !cli.no_copy && matches!(mode, Mode::Human);
    if want_copy {
        let joined = results
            .iter()
            .map(|r| r.output.clone())
            .collect::<Vec<_>>()
            .join("\n");
        if let Err(e) = copy_to_clipboard(&joined) {
            eprintln!("warning: could not copy to clipboard: {e}");
        }
    }

    output::print_results(mode, &results);
    Ok(())
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
