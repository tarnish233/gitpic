//! Optional image compression / resizing before upload.

use image::{ImageEncoder, ImageFormat};

pub struct CompressOpts {
    pub enabled: bool,
    pub max_width: u32,
    pub quality: u8,
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

    let img = match image::load_from_memory_with_format(&bytes, fmt) {
        Ok(i) => i,
        Err(_) => return bytes,
    };

    let mut img = img;
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
}
