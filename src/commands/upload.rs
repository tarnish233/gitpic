//! Upload orchestration for files, stdin, and clipboard sources.

use crate::cli::{Cli, Command, LinkKind, OutputFormat};
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

fn resolve_compress(cli: &Cli, cfg: &Config) -> CompressOpts {
    CompressOpts {
        enabled: (cfg.upload.compress || cli.compress) && !cli.no_compress,
        max_width: cli.max_width.unwrap_or(cfg.upload.max_width),
        quality: cli.quality.unwrap_or(cfg.upload.quality),
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

    let mut inputs = if is_paste {
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

    apply_explicit_name(&mut inputs, cli.name.as_deref(), is_paste, cli.stdin)?;

    cfg.require_target()?;

    let kind = cli.link.unwrap_or_else(|| {
        link::parse_link_kind_strict(&cfg.upload.link_kind).unwrap_or(crate::cli::LinkKind::Cdn)
    });
    // Deliberately ahead of `auth::token` and every PUT: nothing may be committed
    // for a link this cannot produce.
    reject_dead_cdn_link(kind, &cfg.github.branch)?;

    // Resolved here, after the inputs are in hand: a credential helper may take
    // a moment, and there is no point paying for it to upload a broken image.
    let token = crate::auth::token()?;

    let gh = GitHub::new(
        &token,
        &cfg.github.owner,
        &cfg.github.repo,
        &cfg.github.branch,
    )?;

    let template = cli.path.as_deref().unwrap_or(&cfg.upload.path_template);
    let dedup = cfg.upload.dedup;

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
    let renamed = renamed_file(&inputs[0].name, &inputs[0].bytes, name);
    inputs[0].name = renamed;
    Ok(())
}

/// Re-name a file upload without letting `--name` change what the bytes are.
///
/// `--name` replaced the whole filename, extension included, so `gitpic photo.jpg
/// --name shot.png` published JPEG bytes at a `.png` path — and `--name shot`
/// published them at `.png` too, because `render_path` defaults `{ext}` when the
/// name carries none (`src/naming.rs:80-84`) — which GitHub and jsDelivr then
/// serve as `image/png`. That is the same defect 9ee5320 fixed for `paste --name
/// shot.jpg` and [`stdin_name`] fixed for `--stdin`, on the third and last
/// `--name` consumer. The rule is theirs, unchanged: the stem is the user's, the
/// extension is the content's.
///
/// Authority runs bytes, then `original`, then `explicit`. The bytes are the only
/// real evidence; the extension the file arrived with is what an upload *without*
/// `--name` would have used, so preferring it keeps `--name` a pure rename; and
/// `--name`'s own extension is a wish, taken only when nothing else knows. That
/// last fallback is why this cannot fail the way [`stdin_name`] must — a file
/// upload always has a filename to fall back on, so an SVG (or anything else the
/// `image` crate cannot decode) keeps its extension instead of erroring.
fn renamed_file(original: &str, bytes: &[u8], explicit: &str) -> String {
    let original = Path::new(original);
    let stem = explicit_stem(Some(explicit))
        .or_else(|| original.file_stem().and_then(|s| s.to_str()))
        // What `render_path` and `alt_text` call a nameless input.
        .unwrap_or("image");
    match sniffed_ext(bytes)
        .or_else(|| original.extension().and_then(|s| s.to_str()))
        .or_else(|| Path::new(explicit).extension().and_then(|s| s.to_str()))
    {
        Some(ext) => format!("{stem}.{ext}"),
        // Nothing here knows what these bytes are; leaving the extension off lets
        // `render_path` default it, exactly as it does without `--name` at all.
        None => stem.to_string(),
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
    Ok(InputImage {
        name: stdin_name(cli.name.as_deref(), &bytes)?,
        bytes,
    })
}

/// Name a stdin capture from what the bytes actually are.
///
/// Everything used to be called `image.png`, so `cat photo.jpg | gitpic --stdin`
/// published JPEG bytes at a `.png` path and GitHub and jsDelivr then served them
/// as `image/png`. That is the same defect 9ee5320 fixed for `paste --name
/// shot.jpg`; the clipboard path got the fix and this one did not.
///
/// The extension therefore comes from the content, never from `--name` — only the
/// stem is taken from there. When the format cannot be identified and no `--name`
/// was given there is nothing to guess from, so it is a usage error rather than a
/// wrong `.png`; with a `--name`, the user has asserted an extension and it stands.
fn stdin_name(explicit: Option<&str>, bytes: &[u8]) -> Result<String> {
    match (sniffed_ext(bytes), explicit) {
        (Some(ext), _) => Ok(content_name(explicit, ext)),
        (None, Some(name)) => Ok(name.to_string()),
        (None, None) => Err(AppError::usage(
            "cannot tell what kind of image this is from the bytes; pass --name to set the filename",
        )),
    }
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
        // Always PNG, because that is what was just encoded above.
        name: content_name(cli.name.as_deref(), "png"),
        bytes: png,
    })
}

/// Name a byte stream by what it actually contains.
///
/// The extension always comes from `ext` — the format of the bytes in hand — never
/// from `--name`. Honouring a user-supplied `--name shot.jpg` for PNG data would
/// publish it at a `.jpg` path, which GitHub and jsDelivr then serve as
/// `image/jpeg`. Only the stem is taken from `--name`.
///
/// Shared by the clipboard path (always PNG, since it re-encodes) and stdin (the
/// sniffed format), because they had the same bug and only one of them was fixed.
/// The file path applies the same rule through [`renamed_file`], which differs only
/// in having a real filename to fall back on instead of `clipboard`.
fn content_name(explicit: Option<&str>, ext: &str) -> String {
    format!("{}.{ext}", explicit_stem(explicit).unwrap_or("clipboard"))
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
        assert!(!resolve_compress(&cli, &cfg).enabled);
    }

    #[test]
    fn flag_or_config_enables_compression() {
        let mut cfg = Config::default();
        assert!(resolve_compress(&parse(&["gitpic", "a.png", "--compress"]), &cfg).enabled);
        cfg.upload.compress = true;
        assert!(resolve_compress(&parse(&["gitpic", "a.png"]), &cfg).enabled);
    }

    #[test]
    fn cli_sizing_overrides_config() {
        let mut cfg = Config::default();
        cfg.upload.max_width = 100;
        cfg.upload.quality = 50;
        let overridden = resolve_compress(
            &parse(&["gitpic", "a.png", "--max-width", "800", "--quality", "90"]),
            &cfg,
        );
        assert_eq!((overridden.max_width, overridden.quality), (800, 90));
        let inherited = resolve_compress(&parse(&["gitpic", "a.png"]), &cfg);
        assert_eq!((inherited.max_width, inherited.quality), (100, 50));
    }

    #[test]
    fn content_name_defaults_when_unnamed() {
        assert_eq!(content_name(None, "png"), "clipboard.png");
    }

    #[test]
    fn content_name_keeps_an_explicit_stem() {
        assert_eq!(content_name(Some("shot"), "png"), "shot.png");
        assert_eq!(content_name(Some("shot.png"), "png"), "shot.png");
    }

    #[test]
    fn content_name_rewrites_a_mismatched_extension() {
        // Regression: the bytes are always PNG, so honouring ".jpg" published
        // PNG data at a .jpg path, which GitHub serves as image/jpeg.
        assert_eq!(content_name(Some("shot.jpg"), "png"), "shot.png");
        assert_eq!(content_name(Some("shot.webp"), "png"), "shot.png");
    }

    #[test]
    fn content_name_falls_back_on_an_unusable_name() {
        assert_eq!(content_name(Some(""), "png"), "clipboard.png");
        assert_eq!(content_name(Some(".png"), "png"), "clipboard.png");
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
        assert_eq!(stdin_name(None, &jpeg_bytes()).unwrap(), "clipboard.jpg");
        assert_eq!(stdin_name(None, &png_bytes()).unwrap(), "clipboard.png");
        assert_eq!(stdin_name(None, &gif_bytes()).unwrap(), "clipboard.gif");
    }

    #[test]
    fn stdin_takes_the_stem_from_name_but_never_the_extension() {
        // The user names the file; the bytes decide the type.
        assert_eq!(
            stdin_name(Some("photo.png"), &jpeg_bytes()).unwrap(),
            "photo.jpg",
            "a wrong extension must be corrected, not honoured"
        );
        assert_eq!(stdin_name(Some("shot"), &png_bytes()).unwrap(), "shot.png");
        assert_eq!(
            stdin_name(Some("dir/shot.gif"), &png_bytes()).unwrap(),
            "shot.png"
        );
    }

    #[test]
    fn unidentifiable_stdin_bytes_ask_for_a_name_instead_of_guessing() {
        // Calling it `.png` would be a lie about the content; the previous
        // behaviour did exactly that.
        let err = stdin_name(None, b"this is not an image").expect_err("must be rejected");
        assert_eq!(err.code, crate::error::ErrorCode::Usage);
        assert!(err.message.contains("--name"), "{}", err.message);
        // With a name, the user has asserted the extension and it stands.
        assert_eq!(
            stdin_name(Some("blob.bin"), b"this is not an image").unwrap(),
            "blob.bin"
        );
    }
}
