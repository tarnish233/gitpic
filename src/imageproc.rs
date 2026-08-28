//! Optional image compression / resizing before upload.

use image::{ImageDecoder, ImageEncoder, ImageFormat};

pub struct CompressOpts {
    pub enabled: bool,
    pub max_width: u32,
    pub quality: u8,
}

/// Pixel budget for a decode that is about to allocate a bitmap.
///
/// 4096×4096. The Contents API cap is 100 MB of *file*; a much smaller PNG can
/// decode to a multi-gigabyte bitmap, which is what this stops. A compress that
/// cannot re-encode already returns the original; it must not allocate an
/// impossible image on the way.
const MAX_DECODE_PIXELS: u64 = 16_777_216;

/// Decode `bytes`, with any EXIF orientation baked into the pixels.
///
/// A separate function because the decoder borrows `bytes` for its lifetime, and
/// `maybe_compress` has to be able to hand the original buffer back on any failure.
///
/// `load_from_memory_with_format`, which this replaces, reaches
/// `DynamicImage::from_decoder` without ever calling `orientation()` — and neither
/// re-encoder writes EXIF back (`JpegEncoder` emits it only when `set_exif` was called,
/// and it is not). So `--compress` on an iPhone photo, which stores landscape pixels
/// plus `Orientation = 6`, re-encoded those landscape pixels and dropped the tag that
/// said to rotate them: every viewer then showed the image 90° from what the user saw
/// locally, reported `ok: true`, with nothing to suggest the file had been altered.
///
/// Baking the rotation in is the only option that survives the metadata being dropped.
/// It is also what makes `--max-width` correct — that test compares against
/// `img.width()`, which on the same photo was the *stored* width, so the resize picked
/// the wrong axis.
///
/// Costs nothing in the common case: an image with no orientation tag reads as
/// `NoTransforms`, which `apply_orientation` handles by doing nothing at all.
///
/// Dimensions are read from the header *before* `from_decoder`, so a PNG whose
/// IHDR claims tens of thousands of pixels on a side cannot allocate that bitmap
/// on the way to "hand the original back".
fn decode_upright(bytes: &[u8], fmt: ImageFormat) -> Option<image::DynamicImage> {
    let mut decoder = image::ImageReader::with_format(std::io::Cursor::new(bytes), fmt)
        .into_decoder()
        .ok()?;
    let (width, height) = decoder.dimensions();
    if u64::from(width).saturating_mul(u64::from(height)) > MAX_DECODE_PIXELS {
        return None;
    }
    // A file whose EXIF will not parse is not a reason to refuse the compression.
    let orientation = decoder
        .orientation()
        .unwrap_or(image::metadata::Orientation::NoTransforms);
    let mut img = image::DynamicImage::from_decoder(decoder).ok()?;
    img.apply_orientation(orientation);
    Some(img)
}

/// Possibly compress/resize `bytes`. Returns the (possibly new) bytes; takes
/// ownership so a no-op returns the original buffer without copying. Falls back
/// to the original bytes on any error or unsupported format.
///
/// The re-encode always preserves the input format, so the caller's filename
/// and extension stay valid.
pub fn maybe_compress(bytes: Vec<u8>, opts: &CompressOpts) -> Vec<u8> {
    if !opts.enabled {
        return bytes;
    }

    let fmt = match image::guess_format(&bytes) {
        Ok(f) => f,
        Err(_) => return bytes,
    };
    // Only handle raster formats we can re-encode meaningfully.
    if !matches!(fmt, ImageFormat::Png | ImageFormat::Jpeg) {
        return bytes;
    }

    let mut img = match decode_upright(&bytes, fmt) {
        Some(i) => i,
        None => return bytes,
    };

    let mut resized = false;
    if opts.max_width > 0 && img.width() > opts.max_width {
        let new_h = ((img.height() as u64 * opts.max_width as u64) / img.width() as u64) as u32;
        let new_h = new_h.max(1);
        img = img.resize(opts.max_width, new_h, image::imageops::FilterType::Lanczos3);
        resized = true;
    }

    let mut out: Vec<u8> = Vec::new();
    let ok = match fmt {
        ImageFormat::Jpeg => {
            let q = opts.quality.clamp(1, 100);
            let mut enc = image::codecs::jpeg::JpegEncoder::new_with_quality(&mut out, q);
            enc.encode_image(&img).is_ok()
        }
        _ => {
            // PNG: re-encode with adaptive filtering + best compression.
            let rgba = img.to_rgba8();
            let enc = image::codecs::png::PngEncoder::new_with_quality(
                &mut out,
                image::codecs::png::CompressionType::Best,
                image::codecs::png::FilterType::Adaptive,
            );
            enc.write_image(
                rgba.as_raw(),
                rgba.width(),
                rgba.height(),
                image::ExtendedColorType::Rgba8,
            )
            .is_ok()
        }
    };

    if !ok || out.is_empty() {
        return bytes;
    }

    // If we resized, honor the explicit dimension change even if the byte size
    // did not shrink. For pure recompression, only keep it when it is smaller.
    if !resized && out.len() >= bytes.len() {
        return bytes;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn png_of(w: u32, h: u32) -> Vec<u8> {
        let img = image::RgbaImage::from_fn(w, h, |x, y| {
            image::Rgba([(x % 256) as u8, (y % 256) as u8, 128, 255])
        });
        let dynimg = image::DynamicImage::ImageRgba8(img);
        let mut out = Vec::new();
        dynimg
            .write_to(&mut std::io::Cursor::new(&mut out), image::ImageFormat::Png)
            .unwrap();
        out
    }

    /// A landscape JPEG carrying `Orientation = 6` ("rotate 90° clockwise"), which is
    /// what a phone camera writes rather than rotating the pixels itself.
    ///
    /// Built by hand because the `image` crate cannot write EXIF: a minimal APP1
    /// segment goes in straight after SOI. zune-jpeg strips the `Exif\0\0` prefix and
    /// hands `Orientation::from_exif_chunk` the TIFF block, which is why this starts at
    /// the `MM\0*` magic.
    fn jpeg_rotated_90(w: u32, h: u32) -> Vec<u8> {
        let img = image::RgbImage::from_fn(w, h, |x, y| {
            image::Rgb([
                (x * 7 % 256) as u8,
                (y * 13 % 256) as u8,
                ((x + y) % 256) as u8,
            ])
        });
        let mut plain = Vec::new();
        // Quality 100 so the quality-82 re-encode is unambiguously smaller and
        // `maybe_compress` keeps it — otherwise it hands the original back and the
        // assertion would pass for the wrong reason.
        image::codecs::jpeg::JpegEncoder::new_with_quality(&mut plain, 100)
            .encode_image(&image::DynamicImage::ImageRgb8(img))
            .unwrap();
        #[rustfmt::skip]
        let app1: [u8; 36] = [
            0xFF, 0xE1, 0x00, 0x22,             // APP1, length 34 (includes these two)
            b'E', b'x', b'i', b'f', 0x00, 0x00, // "Exif\0\0"
            0x4D, 0x4D, 0x00, 0x2A,             // TIFF, big-endian
            0x00, 0x00, 0x00, 0x08,             // IFD0 at offset 8
            0x00, 0x01,                         // one entry
            0x01, 0x12, 0x00, 0x03,             // tag 0x0112 Orientation, type SHORT
            0x00, 0x00, 0x00, 0x01,             // count 1
            0x00, 0x06, 0x00, 0x00,             // value 6, padded
            0x00, 0x00, 0x00, 0x00,             // no next IFD
        ];
        let mut out = Vec::with_capacity(plain.len() + app1.len());
        out.extend_from_slice(&plain[..2]); // SOI
        out.extend_from_slice(&app1);
        out.extend_from_slice(&plain[2..]);
        out
    }

    #[test]
    fn compression_bakes_in_the_exif_rotation_it_is_about_to_discard() {
        // The regression: the re-encode wrote no EXIF, so the tag saying "rotate this"
        // was dropped while the pixels stayed as stored — every viewer then showed the
        // photo 90° from what the user saw locally.
        let bytes = jpeg_rotated_90(64, 32);
        let opts = CompressOpts {
            enabled: true,
            max_width: 0,
            quality: 82,
        };
        let out = maybe_compress(bytes.clone(), &opts);
        assert!(out.len() < bytes.len(), "the re-encode must have been kept");
        let decoded = image::load_from_memory(&out).unwrap();
        // 64x32 landscape rotated 90° is 32x64 portrait, in the pixels themselves.
        assert_eq!(
            (decoded.width(), decoded.height()),
            (32, 64),
            "the rotation was not baked in, so dropping the tag rotated the image"
        );
    }

    #[test]
    fn compression_leaves_an_untagged_image_the_way_round_it_was() {
        // The control for the test above: no orientation tag means no transform, so a
        // plain landscape JPEG must not come back portrait.
        let full = jpeg_rotated_90(64, 32);
        // Same bytes without the 36-byte APP1 segment.
        let mut plain = Vec::new();
        plain.extend_from_slice(&full[..2]);
        plain.extend_from_slice(&full[2 + 36..]);
        let out = maybe_compress(
            plain,
            &CompressOpts {
                enabled: true,
                max_width: 0,
                quality: 82,
            },
        );
        let decoded = image::load_from_memory(&out).unwrap();
        assert_eq!((decoded.width(), decoded.height()), (64, 32));
    }

    #[test]
    fn resizes_when_wider_than_max_width() {
        let bytes = png_of(800, 400);
        let opts = CompressOpts {
            enabled: true,
            max_width: 200,
            quality: 82,
        };
        let out = maybe_compress(bytes, &opts);
        let decoded = image::load_from_memory(&out).unwrap();
        assert_eq!(decoded.width(), 200);
        assert_eq!(decoded.height(), 100);
    }

    #[test]
    fn resized_output_is_kept_and_smaller() {
        // A large gradient PNG resized to a small width must come back resized.
        let bytes = png_of(1200, 600);
        let opts = CompressOpts {
            enabled: true,
            max_width: 64,
            quality: 82,
        };
        let out = maybe_compress(bytes.clone(), &opts);
        let decoded = image::load_from_memory(&out).unwrap();
        assert_eq!(decoded.width(), 64);
        assert!(out.len() < bytes.len());
    }

    #[test]
    fn disabled_returns_original() {
        let bytes = png_of(50, 50);
        let orig_len = bytes.len();
        let opts = CompressOpts {
            enabled: false,
            max_width: 10,
            quality: 82,
        };
        let out = maybe_compress(bytes, &opts);
        assert_eq!(out.len(), orig_len);
    }

    #[test]
    fn compression_preserves_the_input_format() {
        // The caller keeps using the original filename, so a PNG in must not
        // come back as a JPEG (or vice versa).
        let bytes = png_of(300, 300);
        let opts = CompressOpts {
            enabled: true,
            max_width: 100,
            quality: 82,
        };
        let out = maybe_compress(bytes, &opts);
        assert_eq!(image::guess_format(&out).unwrap(), ImageFormat::Png);
    }

    #[test]
    fn non_image_bytes_pass_through_unchanged() {
        let bytes = b"not an image at all".to_vec();
        let opts = CompressOpts {
            enabled: true,
            max_width: 100,
            quality: 82,
        };
        let out = maybe_compress(bytes.clone(), &opts);
        assert_eq!(out, bytes);
    }

    /// PNG CRC-32 (ISO 3309), the polynomial IHDR is checked with.
    fn crc32_png(data: &[u8]) -> u32 {
        let mut crc: u32 = 0xFFFF_FFFF;
        for &b in data {
            crc ^= u32::from(b);
            for _ in 0..8 {
                crc = if crc & 1 != 0 {
                    (crc >> 1) ^ 0xEDB8_8320
                } else {
                    crc >> 1
                };
            }
        }
        !crc
    }

    /// A real 1×1 PNG whose IHDR has been rewritten to claim `w`×`h`.
    ///
    /// `dimensions()` reads that header; `from_decoder` would then try to allocate
    /// the bitmap. The ceiling has to fire on the first of those, which is why the
    /// IDAT is still a 1×1 image: a real 50_000×50_000 PNG cannot exist in a unit
    /// test. CRC is recomputed so the decoder will accept the header at all.
    fn png_claiming(w: u32, h: u32) -> Vec<u8> {
        let mut bytes = png_of(1, 1);
        // signature (8) + length (4) + type (4) = 16; width then height.
        bytes[16..20].copy_from_slice(&w.to_be_bytes());
        bytes[20..24].copy_from_slice(&h.to_be_bytes());
        // CRC covers type + data (13 bytes of IHDR).
        let crc = crc32_png(&bytes[12..29]);
        bytes[29..33].copy_from_slice(&crc.to_be_bytes());
        bytes
    }

    #[test]
    fn a_rewritten_ihdr_is_what_the_decoder_reports() {
        // Without this, `compression_passes_through_an_image_too_large_to_decode`
        // could pass because `into_decoder` failed, not because the ceiling fired.
        let bytes = png_claiming(50_000, 50_000);
        let decoder =
            image::ImageReader::with_format(std::io::Cursor::new(&bytes), ImageFormat::Png)
                .into_decoder()
                .expect("a patched IHDR must still construct a decoder");
        assert_eq!(decoder.dimensions(), (50_000, 50_000));
    }

    #[test]
    fn compression_passes_through_an_image_too_large_to_decode() {
        // 50_000 × 50_000 would be a ~7.5 GB bitmap. The original file is a few
        // dozen bytes; handing it back is the only correct outcome.
        let bytes = png_claiming(50_000, 50_000);
        let out = maybe_compress(
            bytes.clone(),
            &CompressOpts {
                enabled: true,
                max_width: 100,
                quality: 82,
            },
        );
        assert_eq!(out, bytes, "must not allocate the claimed bitmap");
    }

    #[test]
    fn compression_still_decodes_an_image_under_the_pixel_ceiling() {
        // 64×32 is well under 4096×4096; this is the control that the ceiling
        // does not refuse ordinary photographs. Forced through a resize so the
        // output is kept even if the re-encode is not smaller.
        let bytes = png_of(64, 32);
        let out = maybe_compress(
            bytes,
            &CompressOpts {
                enabled: true,
                max_width: 32,
                quality: 82,
            },
        );
        let decoded = image::load_from_memory(&out).unwrap();
        assert_eq!(decoded.width(), 32);
    }
}
