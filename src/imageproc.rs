//! Optional image compression / resizing before upload.

use image::{ImageEncoder, ImageFormat};

pub struct CompressOpts {
    pub enabled: bool,
    pub max_width: u32,
    pub quality: u8,
}

/// Possibly compress/resize `bytes`. Returns the (possibly new) bytes and the
/// filename to use (extension may change if the format changes). Falls back to
/// the original bytes on any error or unsupported format.
pub fn maybe_compress(name: &str, bytes: Vec<u8>, opts: &CompressOpts) -> (Vec<u8>, String) {
    if !opts.enabled {
        return (bytes, name.to_string());
    }

    let fmt = match image::guess_format(&bytes) {
        Ok(f) => f,
        Err(_) => return (bytes, name.to_string()),
    };
    // Only handle raster formats we can re-encode meaningfully.
    if !matches!(fmt, ImageFormat::Png | ImageFormat::Jpeg) {
        return (bytes, name.to_string());
    }

    let img = match image::load_from_memory_with_format(&bytes, fmt) {
        Ok(i) => i,
        Err(_) => return (bytes, name.to_string()),
    };

    let mut img = img;
    if opts.max_width > 0 && img.width() > opts.max_width {
        let new_h = ((img.height() as u64 * opts.max_width as u64) / img.width() as u64) as u32;
        let new_h = new_h.max(1);
        img = img.resize(opts.max_width, new_h, image::imageops::FilterType::Lanczos3);
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
        return (bytes, name.to_string());
    }

    // Only keep the compressed version if it is actually smaller.
    if out.len() >= bytes.len() {
        return (bytes, name.to_string());
    }
    (out, name.to_string())
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
        let (out, name) = maybe_compress("big.png", bytes, &opts);
        let decoded = image::load_from_memory(&out).unwrap();
        assert_eq!(decoded.width(), 200);
        assert_eq!(decoded.height(), 100);
        assert_eq!(name, "big.png");
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
        let (out, _) = maybe_compress("x.png", bytes, &opts);
        assert_eq!(out.len(), orig_len);
    }
}
