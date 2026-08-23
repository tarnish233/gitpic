//! Upload orchestration for files, stdin, and clipboard sources.

use crate::cli::{Cli, Command, LinkKind, OutputFormat, UploadArgs};
use crate::config::Config;
use crate::error::{AppError, Result};
use crate::github::{GitHub, PutOutcome};
use crate::history::{self, Record};
use crate::imageproc::{self, CompressOpts};
use crate::link;
use crate::naming;
use crate::output::{self, ItemResult, Mode};
use std::io::Read;
use std::path::Path;

struct InputImage {
    name: String,
    bytes: Vec<u8>,
}

fn resolve_compress(u: &UploadArgs, cfg: &Config) -> CompressOpts {
    CompressOpts {
        enabled: (cfg.upload.compress || u.compress) && !u.no_compress,
        max_width: u.max_width.unwrap_or(cfg.upload.max_width),
        quality: u.quality.unwrap_or(cfg.upload.quality),
    }
}

fn build_item(
    outcome: &PutOutcome,
    name: &str,
    kind: LinkKind,
    format: OutputFormat,
    cfg: &Config,
) -> ItemResult {
    let alt = naming::alt_text(name);
    let url = link::url_for(
        kind,
        &cfg.github.owner,
        &cfg.github.repo,
        &cfg.github.branch,
        &outcome.path,
    );
    let raw_url = link::raw_url(
        &cfg.github.owner,
        &cfg.github.repo,
        &cfg.github.branch,
        &outcome.path,
    );
    ItemResult {
        markdown: link::markdown(&alt, &url),
        html: link::html(&alt, &url),
        output: link::render(format, &alt, &url),
        name: alt,
        url,
        raw_url,
        path: outcome.path.clone(),
        sha: outcome.content_sha.clone(),
        size: outcome.size,
        deduped: outcome.deduped,
    }
}

/// Entry point for the default (upload) path and `paste`.
///
/// Returns the process exit code: 0 when every input uploaded, otherwise the
/// code of the first failure. Inputs that already uploaded are still reported
/// so their links are never lost.
pub async fn run(cli: &Cli, cfg: &Config, mode: Mode) -> Result<u8> {
    let is_paste = matches!(cli.command, Some(Command::Paste { .. }));
    let u = cli.upload_args();

    // Guard against silently dropping inputs when sources are mixed. (`paste`
    // plus file args needs no check: clap rejects positionals after the
    // subcommand, and `gitpic a.png paste` parses `paste` as a filename.)
    if u.stdin && !cli.files.is_empty() {
        return Err(AppError::usage(
            "--stdin reads the image from stdin; do not also pass file arguments",
        ));
    }
    if is_paste && u.stdin {
        return Err(AppError::usage("--stdin cannot be combined with `paste`"));
    }

    let mut inputs = if is_paste {
        vec![read_clipboard(u.name.as_deref())?]
    } else if u.stdin {
        vec![read_stdin(u.name.as_deref())?]
    } else {
        read_files(&cli.files)?
    };

    if inputs.is_empty() {
        return Err(AppError::usage(
            "no image provided (pass a file, --stdin, or use `gitpic paste`)",
        ));
    }

    apply_explicit_name(&mut inputs, u.name.as_deref(), is_paste, u.stdin)?;

    cfg.require_target()?;

    let kind = u.link.unwrap_or_else(|| {
        link::parse_link_kind_strict(&cfg.upload.link_kind).unwrap_or(crate::cli::LinkKind::Cdn)
    });
    // Deliberately ahead of `auth::token` and every PUT: nothing may be committed
    // for a link this cannot produce.
    reject_dead_cdn_link(kind, &cfg.github.branch)?;

    let template = u.path.as_deref().unwrap_or(&cfg.upload.path_template);
    // Same timing: a `--path` that would 404 as a `..` Contents path must not
    // wait until after the credential to fail.
    reject_unsafe_path_template(template)?;

    // Resolved here, after the inputs are in hand. It is one read of a small file,
    // but the ordering still matters: there is no point reporting a missing
    // credential to someone whose real problem is an unreadable image.
    let token = crate::auth::token()?;

    let gh = GitHub::new(
        &token,
        &cfg.github.owner,
        &cfg.github.repo,
        &cfg.github.branch,
    )?;

    let dedup = cfg.upload.dedup;

    let compress = resolve_compress(u, cfg);

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
        let remote_path = naming::render_path(template, &name, &hash);
        // Checked on the rendered result, the single point every template source
        // funnels into — `config set`, `--path`, and a hand-edited config.toml.
        if !naming::is_safe_remote_path(&remote_path) {
            failure = Some(AppError::usage(format!(
                "{name}: path template produced an unusable remote path {remote_path:?}: \
                 it must be repo-relative with no empty or `..` segments"
            )));
            break;
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
        let item = build_item(&outcome, &name, kind, cli.effective_format(cfg), cfg);
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
    let want_copy = cfg.upload.auto_copy && !u.no_copy && matches!(mode, Mode::Human);
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

/// Refuse to run when the link the caller asked for cannot be built.
///
/// This used to print `warning:` on stderr and upload anyway, so the run
/// committed the file, printed a jsDelivr link that 404s (see
/// [`crate::link::cdn_branch_is_ambiguous`] for why `repo@feat/x/a.png` cannot be
/// parsed back), and then reported `ok: true`. Two things made the warning
/// insufficient: a `--json` consumer never sees stderr at all — the macOS app
/// parses stdout only (`apps/GitPic/Sources/GitPicCore/GitpicRunner.swift:92-102`)
/// — and even on a terminal, a warning that precedes a successful-looking result
/// is not a result.
///
/// Refusing beats the two alternatives. Quietly emitting a raw link instead is the
/// "accepted, then silently something else" shape `parse_link_kind_strict` exists
/// to close, and `--link raw` is a one-word fix the caller can make deliberately.
/// And this has to happen *before* the upload, which is why it is checked ahead of
/// `auth::token` rather than where the URL is built: once the bytes are in a
/// commit, the only shape left that carries an error is the partial envelope, and
/// that one promises live links (see [`classify`]).
///
/// Split out of `run` so it can be tested at all — `run` past this point needs a
/// token and the network.
fn reject_dead_cdn_link(kind: LinkKind, branch: &str) -> Result<()> {
    if link::cdn_branch_is_ambiguous(kind, branch) {
        return Err(AppError::usage(format!(
            "branch {branch:?} contains '/', which jsDelivr cannot tell apart from the \
             file path in `repo@branch/path`, so the CDN link would 404; use --link raw, \
             or `gitpic config set upload.link_kind raw`"
        )));
    }
    Ok(())
}

/// Refuse a path template that dummy-renders to an unusable Contents path.
///
/// Same check as `Config::validate`, on the effective template (`--path` or the
/// file). Split out of `run` so it can be tested without a token. The per-file
/// `is_safe_remote_path` on the rendered result stays as belt-and-suspenders.
fn reject_unsafe_path_template(template: &str) -> Result<()> {
    if !naming::template_renders_safe(template) {
        let sample = naming::render_path(template, "sample.png", &"0".repeat(64));
        return Err(AppError::usage(format!(
            "path template {template:?} must be repo-relative with no empty or `..` segments \
             (renders to {sample:?})"
        )));
    }
    Ok(())
}

/// Apply `--name` to a file upload. Paste and stdin already consume it in
/// their readers; a multi-file upload cannot honour a single name, so that is
/// a usage error rather than a silent drop.
///
/// Only the stem is taken from it — see [`renamed_file`] for why the extension is
/// not the user's to set.
fn apply_explicit_name(
    inputs: &mut [InputImage],
    name: Option<&str>,
    is_paste: bool,
    stdin: bool,
) -> Result<()> {
    if is_paste || stdin {
        return Ok(());
    }
    let Some(name) = name else {
        return Ok(());
    };
    if inputs.len() != 1 {
        return Err(AppError::usage(
            "--name can only be used with a single file, --stdin, or paste",
        ));
    }
    let renamed = display_name(
        Some(name),
        &inputs[0].bytes,
        ExtFallback::File {
            original: &inputs[0].name,
        },
    )
    .expect("a file upload always has a name to fall back on");
    inputs[0].name = renamed;
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

fn read_stdin(name: Option<&str>) -> Result<InputImage> {
    let mut bytes = Vec::new();
    std::io::stdin()
        .read_to_end(&mut bytes)
        .map_err(|e| AppError::usage(format!("read stdin: {e}")))?;
    if bytes.is_empty() {
        return Err(AppError::usage("stdin was empty"));
    }
    Ok(InputImage {
        name: display_name(name, &bytes, ExtFallback::Stdin)?,
        bytes,
    })
}

/// The canonical extension for whatever these bytes actually are, if the format is
/// one the `image` crate recognises.
///
/// Shared by stdin and the `--name` rename so the two cannot drift into different
/// answers about the same bytes.
fn sniffed_ext(bytes: &[u8]) -> Option<&'static str> {
    image::guess_format(bytes)
        .ok()
        .and_then(|f| f.extensions_str().first().copied())
}

fn read_clipboard(name: Option<&str>) -> Result<InputImage> {
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
        // Always PNG, because that is what was just encoded above.
        name: display_name(name, &png, ExtFallback::Fixed("png"))
            .expect("a fixed extension cannot fail"),
        bytes: png,
    })
}

/// Where a missing extension may be taken from, once the bytes have said nothing.
enum ExtFallback<'a> {
    /// A file that already had a name: original, then `--name`, then stem-only
    /// (`render_path` defaults `{ext}`). Never a usage error — a file upload
    /// always has something to fall back on, so an SVG keeps `.svg` instead of
    /// erroring.
    File { original: &'a str },
    /// Stdin: bytes, else `--name` if it carries an extension, else `USAGE`.
    Stdin,
    /// Already encoded (clipboard PNG). `--name` supplies only the stem.
    Fixed(&'static str),
}

/// One name for one blob: the stem is the user's, the extension is the content's.
///
/// `--name` used to replace the whole filename, so `gitpic photo.jpg --name
/// shot.png` published JPEG bytes at a `.png` path — and `--name shot` did the
/// same via `render_path`'s `{ext}` default. File, stdin and paste each had their
/// own copy of the rule, and they drifted. Authority is: bytes, then the fallback,
/// then `--name`'s own extension (file only).
fn display_name(explicit: Option<&str>, bytes: &[u8], fallback: ExtFallback<'_>) -> Result<String> {
    let stem = match fallback {
        ExtFallback::File { original } => explicit_stem(explicit)
            .or_else(|| Path::new(original).file_stem().and_then(|s| s.to_str()))
            .unwrap_or("image"),
        ExtFallback::Stdin | ExtFallback::Fixed(_) => {
            explicit_stem(explicit).unwrap_or("clipboard")
        }
    };

    let ext = match fallback {
        ExtFallback::Fixed(ext) => Some(ext),
        ExtFallback::File { original } => sniffed_ext(bytes)
            .or_else(|| Path::new(original).extension().and_then(|s| s.to_str()))
            .or_else(|| {
                explicit
                    .map(Path::new)
                    .and_then(|p| p.extension())
                    .and_then(|s| s.to_str())
            }),
        ExtFallback::Stdin => match sniffed_ext(bytes) {
            Some(ext) => Some(ext),
            None if explicit.is_some_and(name_asserts_ext) => explicit
                .map(Path::new)
                .and_then(|p| p.extension())
                .and_then(|s| s.to_str()),
            None => None,
        },
    };

    match (fallback, ext) {
        // Two different mistakes, and they used to get one message. "pass --name to
        // set the filename" is no answer to someone who *did* pass one: an agent
        // following the skill sends `--name shot`, because the rule everywhere else
        // is that `--name` gives the stem and the bytes give the extension — and
        // then reads a message telling it to do what it just did. Unidentifiable
        // bytes are the one place the extension has nowhere else to come from, so
        // that is what the message has to ask for.
        (ExtFallback::Stdin, None) => Err(AppError::usage(match explicit {
            Some(name) => format!(
                "--name {name:?} carries no extension and these bytes are not an image \
                 gitpic can identify, so there is nothing to take one from; include it \
                 (e.g. --name {}.bin)",
                explicit_stem(explicit).unwrap_or("shot")
            ),
            None => "cannot tell what kind of image this is from the bytes; pass --name \
                     with an extension (e.g. --name shot.bin) to say what they are"
                .to_string(),
        })),
        (_, Some(ext)) => Ok(format!("{stem}.{ext}")),
        (ExtFallback::File { .. }, None) => Ok(stem.to_string()),
        (ExtFallback::Fixed(_), None) => unreachable!("fixed extension is Some"),
    }
}

/// Whether `--name` carries an extension `render_path` would not have to invent.
fn name_asserts_ext(name: &str) -> bool {
    Path::new(name)
        .extension()
        .and_then(|s| s.to_str())
        .is_some_and(|ext| !ext.is_empty() && ext.chars().any(|c| c.is_ascii_alphanumeric()))
}

/// The stem `--name` asks for, when it carries a usable one.
///
/// A leading dot makes the whole name the "stem" (`.png` -> `.png`), so those are
/// rejected rather than emitted as `.png.png`.
fn explicit_stem(explicit: Option<&str>) -> Option<&str> {
    explicit
        .map(Path::new)
        .and_then(|p| p.file_stem())
        .and_then(|s| s.to_str())
        .filter(|s| !s.is_empty() && !s.starts_with('.'))
}

fn copy_to_clipboard(text: &str) -> std::result::Result<(), String> {
    let mut clip = arboard::Clipboard::new().map_err(|e| e.to_string())?;
    clip.set_text(text.to_string()).map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::Parser;

    fn parse(args: &[&str]) -> Cli {
        Cli::try_parse_from(args).expect("valid args")
    }

    #[test]
    fn no_compress_overrides_the_flag_and_config() {
        let mut cfg = Config::default();
        cfg.upload.compress = true;
        let cli = parse(&["gitpic", "a.png", "--compress", "--no-compress"]);
        assert!(!resolve_compress(cli.upload_args(), &cfg).enabled);
    }

    #[test]
    fn flag_or_config_enables_compression() {
        let mut cfg = Config::default();
        assert!(
            resolve_compress(
                parse(&["gitpic", "a.png", "--compress"]).upload_args(),
                &cfg
            )
            .enabled
        );
        cfg.upload.compress = true;
        assert!(resolve_compress(parse(&["gitpic", "a.png"]).upload_args(), &cfg).enabled);
    }

    #[test]
    fn cli_sizing_overrides_config() {
        let mut cfg = Config::default();
        cfg.upload.max_width = 100;
        cfg.upload.quality = 50;
        let overridden = resolve_compress(
            parse(&["gitpic", "a.png", "--max-width", "800", "--quality", "90"]).upload_args(),
            &cfg,
        );
        assert_eq!((overridden.max_width, overridden.quality), (800, 90));
        let inherited = resolve_compress(parse(&["gitpic", "a.png"]).upload_args(), &cfg);
        assert_eq!((inherited.max_width, inherited.quality), (100, 50));
    }

    fn named(explicit: Option<&str>, fallback: ExtFallback<'_>) -> String {
        display_name(explicit, b"", fallback).expect("fixed / file fallback")
    }

    #[test]
    fn clipboard_defaults_when_unnamed() {
        assert_eq!(named(None, ExtFallback::Fixed("png")), "clipboard.png");
    }

    #[test]
    fn clipboard_keeps_an_explicit_stem() {
        assert_eq!(named(Some("shot"), ExtFallback::Fixed("png")), "shot.png");
        assert_eq!(
            named(Some("shot.png"), ExtFallback::Fixed("png")),
            "shot.png"
        );
    }

    #[test]
    fn clipboard_rewrites_a_mismatched_extension() {
        // Regression: the bytes are always PNG, so honouring ".jpg" published
        // PNG data at a .jpg path, which GitHub serves as image/jpeg.
        assert_eq!(
            named(Some("shot.jpg"), ExtFallback::Fixed("png")),
            "shot.png"
        );
        assert_eq!(
            named(Some("shot.webp"), ExtFallback::Fixed("png")),
            "shot.png"
        );
    }

    #[test]
    fn clipboard_falls_back_on_an_unusable_name() {
        assert_eq!(named(Some(""), ExtFallback::Fixed("png")), "clipboard.png");
        assert_eq!(
            named(Some(".png"), ExtFallback::Fixed("png")),
            "clipboard.png"
        );
    }

    fn file_input(name: &str) -> InputImage {
        InputImage {
            name: name.to_string(),
            bytes: b"x".to_vec(),
        }
    }

    /// An input whose bytes really are a JPEG, so the sniffing is exercised rather
    /// than mocked.
    fn jpeg_input(name: &str) -> InputImage {
        InputImage {
            name: name.to_string(),
            bytes: jpeg_bytes(),
        }
    }

    fn renamed(input: InputImage, name: &str) -> String {
        let mut inputs = vec![input];
        apply_explicit_name(&mut inputs, Some(name), false, false).expect("a single file");
        inputs.remove(0).name
    }

    #[test]
    fn name_renames_a_single_file_but_never_its_type() {
        // Regression: `--name` replaced the whole filename, extension included, so
        // every one of these published JPEG bytes under a name GitHub and jsDelivr
        // serve as image/png — `--name shot.png` outright, and bare `--name shot`
        // via the `{ext}` default in `render_path`.
        assert_eq!(renamed(jpeg_input("photo.jpg"), "shot"), "shot.jpg");
        assert_eq!(renamed(jpeg_input("photo.jpg"), "shot.png"), "shot.jpg");
        assert_eq!(renamed(jpeg_input("photo.jpg"), "shot.jpg"), "shot.jpg");
        // The rename itself still happens, and a directory in `--name` is dropped
        // exactly as it is for stdin.
        assert_eq!(renamed(jpeg_input("photo.jpg"), "dir/shot.gif"), "shot.jpg");
    }

    #[test]
    fn a_renamed_file_reaches_the_remote_path_as_what_it_is() {
        // The wrong extension only becomes a wrong content type once `{ext}` is
        // rendered, so follow it all the way to the path that gets committed.
        let name = renamed(jpeg_input("photo.jpg"), "shot.png");
        assert_eq!(
            naming::render_path("{name}.{ext}", &name, &"a".repeat(64)),
            "shot.jpg"
        );
    }

    #[test]
    fn a_renamed_file_of_an_unknown_format_keeps_the_extension_it_arrived_with() {
        // `image::guess_format` knows nothing about SVG, and a file upload — unlike
        // stdin — always has a filename to believe instead of erroring out.
        assert_eq!(renamed(file_input("diagram.svg"), "shot"), "shot.svg");
        assert_eq!(renamed(file_input("diagram.svg"), "shot.png"), "shot.svg");
        // With nothing else claiming a type, `--name`'s own extension is all that
        // is left; with not even that, `render_path` defaults it as it always did.
        assert_eq!(renamed(file_input("blob"), "shot.bin"), "shot.bin");
        assert_eq!(renamed(file_input("blob"), "shot"), "shot");
    }

    #[test]
    fn an_unusable_name_keeps_the_original_stem_instead_of_clipboard() {
        // `clipboard` is the right default for bytes that never had a filename; it
        // would be a strange thing to rename a real file to.
        assert_eq!(renamed(jpeg_input("photo.jpg"), ""), "photo.jpg");
        assert_eq!(renamed(jpeg_input("photo.jpg"), ".png"), "photo.jpg");
    }

    #[test]
    fn name_on_two_files_is_usage() {
        let mut inputs = vec![file_input("a.png"), file_input("b.png")];
        let err = apply_explicit_name(&mut inputs, Some("shot.png"), false, false)
            .expect_err("must be rejected");
        assert_eq!(err.code, crate::error::ErrorCode::Usage);
        assert_eq!(inputs[0].name, "a.png", "rejected --name must not rename");
    }

    #[test]
    fn name_is_left_to_the_reader_for_stdin_and_paste() {
        let mut inputs = vec![file_input("clipboard.png")];
        apply_explicit_name(&mut inputs, Some("shot.png"), true, false).unwrap();
        apply_explicit_name(&mut inputs, Some("shot.png"), false, true).unwrap();
        assert_eq!(inputs[0].name, "clipboard.png");
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

    #[test]
    fn a_cdn_link_that_would_404_is_refused_instead_of_warned_about() {
        // Regression: this printed a warning to stderr and uploaded anyway, so the
        // file really was committed, the printed jsDelivr link 404ed, and the
        // envelope said `ok: true`. `--json` callers never saw the warning at all.
        let err = reject_dead_cdn_link(LinkKind::Cdn, "feat/x").expect_err("must be refused");
        assert_eq!(err.code, crate::error::ErrorCode::Usage);
        // The alternative that works has to be in the message, since this is now
        // the only thing the caller gets.
        assert!(err.message.contains("--link raw"), "{}", err.message);
    }

    #[test]
    fn every_link_and_branch_pair_that_works_is_left_alone() {
        // Only the one combination jsDelivr cannot parse is refused: `raw` gives the
        // branch its own path segments, and a branch without `/` is unambiguous.
        reject_dead_cdn_link(LinkKind::Raw, "feat/x").expect("raw handles a slash");
        reject_dead_cdn_link(LinkKind::Cdn, "main").expect("no slash, no ambiguity");
        reject_dead_cdn_link(LinkKind::Raw, "main").expect("nothing wrong here");
    }

    #[test]
    fn an_escaping_path_template_is_refused_before_any_credential() {
        // Same shape as `reject_dead_cdn_link`: a usage error here means `run`
        // never reaches `auth::token()`. `{name}` cannot inject `..` (slugify).
        let err = reject_unsafe_path_template("../x/{name}.{ext}").expect_err("must be refused");
        assert_eq!(err.code, crate::error::ErrorCode::Usage);
        assert!(err.message.contains(".."), "{}", err.message);
        reject_unsafe_path_template("images/{name}.{ext}").expect("ordinary template is fine");
        reject_unsafe_path_template("images/{year}/{month}/{hash8}-{name}.{ext}")
            .expect("the default is fine");
    }

    /// Real magic bytes, so `image::guess_format` is exercised rather than mocked.
    fn png_bytes() -> Vec<u8> {
        let mut v = b"\x89PNG\r\n\x1a\n".to_vec();
        v.extend_from_slice(&[0, 0, 0, 13]);
        v.extend_from_slice(b"IHDR");
        v
    }
    fn jpeg_bytes() -> Vec<u8> {
        vec![
            0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, b'J', b'F', b'I', b'F', 0,
        ]
    }
    fn gif_bytes() -> Vec<u8> {
        b"GIF89a\x01\x00\x01\x00".to_vec()
    }

    #[test]
    fn stdin_is_named_by_what_the_bytes_are() {
        // Regression: every stdin upload was called `image.png`, so
        // `cat photo.jpg | gitpic --stdin` published JPEG bytes at a `.png` path and
        // GitHub served them as image/png. This is the same defect 9ee5320 fixed for
        // `paste --name shot.jpg`, on the source it missed.
        assert_eq!(
            display_name(None, &jpeg_bytes(), ExtFallback::Stdin).unwrap(),
            "clipboard.jpg"
        );
        assert_eq!(
            display_name(None, &png_bytes(), ExtFallback::Stdin).unwrap(),
            "clipboard.png"
        );
        assert_eq!(
            display_name(None, &gif_bytes(), ExtFallback::Stdin).unwrap(),
            "clipboard.gif"
        );
    }

    #[test]
    fn stdin_takes_the_stem_from_name_but_never_the_extension() {
        // The user names the file; the bytes decide the type.
        assert_eq!(
            display_name(Some("photo.png"), &jpeg_bytes(), ExtFallback::Stdin).unwrap(),
            "photo.jpg",
            "a wrong extension must be corrected, not honoured"
        );
        assert_eq!(
            display_name(Some("shot"), &png_bytes(), ExtFallback::Stdin).unwrap(),
            "shot.png"
        );
        assert_eq!(
            display_name(Some("dir/shot.gif"), &png_bytes(), ExtFallback::Stdin).unwrap(),
            "shot.png"
        );
    }

    #[test]
    fn unidentifiable_stdin_bytes_ask_for_a_name_instead_of_guessing() {
        // Calling it `.png` would be a lie about the content; the previous
        // behaviour did exactly that.
        let err = display_name(None, b"this is not an image", ExtFallback::Stdin)
            .expect_err("must be rejected");
        assert_eq!(err.code, crate::error::ErrorCode::Usage);
        assert!(err.message.contains("--name"), "{}", err.message);
        // With an extension, the user has asserted the type and it stands.
        assert_eq!(
            display_name(
                Some("blob.bin"),
                b"this is not an image",
                ExtFallback::Stdin
            )
            .unwrap(),
            "blob.bin"
        );
        assert_eq!(
            display_name(
                Some("shot.jpg"),
                b"this is not an image",
                ExtFallback::Stdin
            )
            .unwrap(),
            "shot.jpg"
        );
        // Stem-only `--name shot` used to return `"shot"`, then `render_path`
        // defaulted `{ext}` to `png` — the same class of bug as `paste --name
        // shot.jpg` publishing JPEG as PNG.
        let err = display_name(Some("shot"), b"this is not an image", ExtFallback::Stdin)
            .expect_err("must be rejected");
        assert_eq!(err.code, crate::error::ErrorCode::Usage);
        // Not "pass --name": it was passed. The message has to name what is
        // actually missing, or the caller repeats itself — see `display_name`.
        assert!(err.message.contains("extension"), "{}", err.message);
        assert!(err.message.contains("shot"), "{}", err.message);
    }
}
