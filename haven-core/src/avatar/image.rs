//! Avatar image pipeline: decode → strip metadata → downscale → re-encode.
//!
//! This module turns arbitrary user-supplied image bytes into a canonical,
//! metadata-stripped, size-bounded JPEG plus a small thumbnail, all in pure
//! Rust. It is the only place in the avatar subsystem that touches raw pixels.
//!
//! # Security properties
//!
//! * **Decode-bomb defense is layered and does NOT rely on codec feature
//!   gating** (correction #3): the `image` crate's codecs are pulled in by
//!   mdk-core via feature unification regardless of what we declare. So before
//!   the decoder ever sees a byte we enforce (a) a hard input byte-size cap and
//!   (b) a magic-byte allowlist (JPEG/PNG/WebP only — SVG and everything else
//!   are rejected). Pixel-allocation limits are then applied through the
//!   reader's [`image::Limits`] so a header claiming huge dimensions is
//!   rejected *before* a framebuffer is allocated.
//! * **EXIF/GPS/XMP/ICC stripping is structural**: we decode to raw pixels and
//!   re-encode a fresh JPEG. No container metadata is ever carried forward —
//!   strictly safer than tag deletion. Critical for a location-sharing app
//!   where a camera selfie can embed home coordinates.
//! * **All plaintext byte buffers we own are `Zeroizing`.** The one honest
//!   residual is the `image` crate's [`image::DynamicImage`] decode buffer: it
//!   is a foreign type that cannot be `Zeroizing`-wrapped. It lives only for
//!   the duration of one synchronous decode → crop → scale → encode call and
//!   is dropped immediately after.
//! * **No error ever echoes input bytes**: decode/encode failures map to a
//!   generic [`AvatarError`] variant.

use std::io::Cursor;

use image::{DynamicImage, GenericImageView, ImageReader, Limits};
use sha2::{Digest, Sha256};
use zeroize::Zeroizing;

use super::config::{
    DecodeLimits, AVATAR_CANONICAL_MAX_BYTES, AVATAR_JPEG_QUALITY_FLOOR, AVATAR_JPEG_QUALITY_START,
    AVATAR_THUMB_EDGE_PX, AVATAR_THUMB_JPEG_QUALITY, AVATAR_TIER_EDGE_PX,
};
use super::error::{AvatarError, Result};

/// The canonical processed avatar plus its derived thumbnail and metadata.
///
/// All byte buffers are `Zeroizing` so they are wiped on drop. The struct
/// holds only the bytes the caller needs to store; it never retains the
/// decoded `DynamicImage`.
pub struct ProcessedAvatar {
    /// Canonical JPEG bytes at [`AVATAR_TIER_EDGE_PX`] square.
    pub canonical: Zeroizing<Vec<u8>>,
    /// Thumbnail JPEG bytes at [`AVATAR_THUMB_EDGE_PX`] square.
    pub thumbnail: Zeroizing<Vec<u8>>,
    /// SHA-256 of the canonical bytes (content hash). 32 bytes.
    pub content_hash: [u8; 32],
    /// Canonical image width in pixels.
    pub width: u32,
    /// Canonical image height in pixels.
    pub height: u32,
}

impl std::fmt::Debug for ProcessedAvatar {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // Never print bytes or the content hash (Security Rule 6/8).
        f.debug_struct("ProcessedAvatar")
            .field("canonical", &"<redacted>")
            .field("thumbnail", &"<redacted>")
            .field("content_hash", &"<redacted>")
            .field("width", &self.width)
            .field("height", &self.height)
            .finish()
    }
}

/// Sniffs the leading bytes of `data` and returns `true` only if they match
/// the JPEG/PNG/WebP magic-byte allowlist.
///
/// This is the second layer of decode-bomb defense (correction #3). It runs
/// before the decoder is constructed and explicitly rejects SVG (an XML format
/// vulnerable to XXE / billion-laughs) and every other format. We do NOT rely
/// on per-codec feature gating because feature unification with mdk-core
/// compiles in codecs (e.g. `gif`) we never declare.
#[must_use]
fn is_allowed_format(data: &[u8]) -> bool {
    // PNG: 89 50 4E 47 0D 0A 1A 0A
    const PNG_MAGIC: [u8; 8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
    // JPEG: FF D8 FF
    if data.len() >= 3 && data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF {
        return true;
    }
    if data.len() >= 8 && data[..8] == PNG_MAGIC {
        return true;
    }
    // WebP: "RIFF" .... "WEBP"
    if data.len() >= 12 && &data[0..4] == b"RIFF" && &data[8..12] == b"WEBP" {
        return true;
    }
    false
}

/// Builds an `image` crate [`Limits`] from our [`DecodeLimits`].
fn to_image_limits(limits: DecodeLimits) -> Limits {
    let mut l = Limits::no_limits();
    l.max_image_width = Some(limits.max_edge_px);
    l.max_image_height = Some(limits.max_edge_px);
    l.max_alloc = Some(limits.max_alloc_bytes);
    l
}

/// Decodes `data` under the given resource `limits`, after enforcing the
/// pre-decode byte-size cap and the magic-byte allowlist.
///
/// This is the single trusted decode entry point shared by the own-avatar
/// pipeline and (in M2) the inbound-avatar path; passing
/// [`DecodeLimits::inbound`] applies the strict untrusted limits.
///
/// # Errors
///
/// * [`AvatarError::InputTooLarge`] if `data` exceeds `limits.max_input_bytes`.
/// * [`AvatarError::UnsupportedFormat`] if the magic bytes are not allowlisted.
/// * [`AvatarError::Decode`] for any decoder failure (including a header that
///   claims dimensions beyond the limits).
pub fn decode_under_limits(data: &[u8], limits: DecodeLimits) -> Result<DynamicImage> {
    // (a) Pre-decode byte-size cap — the primary bomb defense.
    if data.len() > limits.max_input_bytes {
        return Err(AvatarError::InputTooLarge);
    }
    // (b) Format allowlist — reject SVG and everything not JPEG/PNG/WebP.
    if !is_allowed_format(data) {
        return Err(AvatarError::UnsupportedFormat);
    }

    let cursor = Cursor::new(data);
    let mut reader = ImageReader::new(cursor)
        .with_guessed_format()
        .map_err(|_| AvatarError::Decode)?;
    // `.limits()` takes `&mut self` and returns `()`, so it cannot be chained
    // inline — it must be applied to the bound reader before `.decode()`. The
    // limits run before pixel allocation (PNG honors them at construction;
    // other codecs check dimensions/allocations during decode).
    reader.limits(to_image_limits(limits));

    // Belt-and-suspenders: `with_guessed_format` may detect a format outside
    // our allowlist if the magic check above is ever loosened. Re-assert the
    // detected format is one we accept.
    match reader.format() {
        Some(image::ImageFormat::Jpeg | image::ImageFormat::Png | image::ImageFormat::WebP) => {}
        _ => return Err(AvatarError::UnsupportedFormat),
    }

    let decoded = reader.decode().map_err(|_| AvatarError::Decode)?;

    // Explicit total-pixel cap. `image`'s `max_alloc` is NON-STRICT and the JPEG
    // codec's `set_limits` only honors the edge dimensions (`check_dimensions`),
    // not the allocation budget — so `max_alloc` alone does not bound the pixel
    // count for a JPEG. Today the square edge cap implies the pixel cap (e.g.
    // inbound 2048² = 4 MP exactly), but re-deriving and checking the pixel
    // budget here keeps the cap enforced even for non-square decoders and if the
    // edge cap is ever raised independently. `max_alloc_bytes` is the framebuffer
    // budget at 4 bytes/pixel (RGBA), so `/ 4` recovers the pixel cap.
    let (w, h) = decoded.dimensions();
    let max_pixels = limits.max_alloc_bytes / 4;
    if u64::from(w).saturating_mul(u64::from(h)) > max_pixels {
        return Err(AvatarError::Decode);
    }

    Ok(decoded)
}

/// Center-crops `img` to a square and downscales it to `edge`×`edge` using
/// Lanczos3.
fn crop_square_and_resize(img: &DynamicImage, edge: u32) -> DynamicImage {
    let (w, h) = img.dimensions();
    let side = w.min(h);
    let x = (w - side) / 2;
    let y = (h - side) / 2;
    let square = img.crop_imm(x, y, side, side);
    square.resize_exact(edge, edge, image::imageops::FilterType::Lanczos3)
}

/// Encodes `img` to JPEG at the given `quality` into a `Zeroizing` buffer.
fn encode_jpeg(img: &DynamicImage, quality: u8) -> Result<Zeroizing<Vec<u8>>> {
    // Use RGB8 so the JPEG encoder (which has no alpha) gets a well-defined
    // pixel type and produces deterministic output.
    let rgb = img.to_rgb8();
    let mut out = Zeroizing::new(Vec::new());
    {
        let mut encoder =
            image::codecs::jpeg::JpegEncoder::new_with_quality(Cursor::new(&mut *out), quality);
        encoder
            .encode_image(&rgb)
            .map_err(|_| AvatarError::Encode)?;
    }
    Ok(out)
}

/// Re-encodes `img` to a canonical JPEG that fits [`AVATAR_CANONICAL_MAX_BYTES`].
///
/// Starts at [`AVATAR_JPEG_QUALITY_START`] and steps quality down toward
/// [`AVATAR_JPEG_QUALITY_FLOOR`] until the output fits the budget.
///
/// # Errors
///
/// [`AvatarError::TooLargeAfterEncode`] if even the floor quality is over
/// budget.
fn encode_canonical_to_fit(img: &DynamicImage) -> Result<Zeroizing<Vec<u8>>> {
    let mut quality = AVATAR_JPEG_QUALITY_START;
    loop {
        let encoded = encode_jpeg(img, quality)?;
        if encoded.len() <= AVATAR_CANONICAL_MAX_BYTES {
            return Ok(encoded);
        }
        if quality <= AVATAR_JPEG_QUALITY_FLOOR {
            return Err(AvatarError::TooLargeAfterEncode);
        }
        // Step down by a few points; saturate at the floor.
        quality = quality.saturating_sub(6).max(AVATAR_JPEG_QUALITY_FLOOR);
    }
}

/// Processes the user's OWN avatar from raw input bytes.
///
/// Pipeline: pre-size-check → magic allowlist → decode under
/// [`DecodeLimits::own`] → center-crop to square → downscale to
/// [`AVATAR_TIER_EDGE_PX`] (Lanczos3) → re-encode to a canonical JPEG that
/// fits the byte budget (structurally stripping ALL EXIF/GPS/XMP/ICC/thumbnail
/// metadata) → derive a [`AVATAR_THUMB_EDGE_PX`] thumbnail → hash the canonical
/// bytes.
///
/// # Errors
///
/// Returns an [`AvatarError`] if the input is too large, an unsupported
/// format, fails to decode, or cannot be compressed within the size budget.
pub fn process_own_avatar(raw: &[u8]) -> Result<ProcessedAvatar> {
    let decoded = decode_under_limits(raw, DecodeLimits::own())?;

    // Canonical: center-crop + downscale + re-encode-to-fit.
    let canonical_img = crop_square_and_resize(&decoded, AVATAR_TIER_EDGE_PX);
    let canonical = encode_canonical_to_fit(&canonical_img)?;

    // Thumbnail: derive from the already-cropped canonical image so the
    // thumbnail matches the canonical framing exactly.
    let thumb_img = canonical_img.resize_exact(
        AVATAR_THUMB_EDGE_PX,
        AVATAR_THUMB_EDGE_PX,
        image::imageops::FilterType::Lanczos3,
    );
    let thumbnail = encode_jpeg(&thumb_img, AVATAR_THUMB_JPEG_QUALITY)?;

    let content_hash: [u8; 32] = Sha256::digest(&*canonical).into();

    Ok(ProcessedAvatar {
        canonical,
        thumbnail,
        content_hash,
        width: AVATAR_TIER_EDGE_PX,
        height: AVATAR_TIER_EDGE_PX,
    })
}

/// Processes an UNTRUSTED inbound avatar from a peer (M2 receive path).
///
/// Identical pipeline to [`process_own_avatar`] but decodes under the strict
/// [`DecodeLimits::inbound`] preset (≤512 KB input, ≤4 MP, ≤2048 px edge). This
/// re-validates and re-encodes the reassembled bytes a malicious member could
/// have crafted: it strips any polyglot/trailing data, enforces dimensions and
/// size, and never hands untrusted bytes to a platform decoder.
///
/// The output `content_hash` is the hash of OUR re-encoded canonical bytes,
/// which is what gets stored — distinct from the sender's manifest hash (which
/// was already verified against the reassembled input upstream).
///
/// # Errors
///
/// As [`process_own_avatar`], but using the inbound limits (a crafted
/// over-dimension or oversized image is rejected with a generic error that
/// never echoes the input bytes).
pub fn process_inbound_avatar(raw: &[u8]) -> Result<ProcessedAvatar> {
    let decoded = decode_under_limits(raw, DecodeLimits::inbound())?;

    let canonical_img = crop_square_and_resize(&decoded, AVATAR_TIER_EDGE_PX);
    let canonical = encode_canonical_to_fit(&canonical_img)?;

    let thumb_img = canonical_img.resize_exact(
        AVATAR_THUMB_EDGE_PX,
        AVATAR_THUMB_EDGE_PX,
        image::imageops::FilterType::Lanczos3,
    );
    let thumbnail = encode_jpeg(&thumb_img, AVATAR_THUMB_JPEG_QUALITY)?;

    let content_hash: [u8; 32] = Sha256::digest(&*canonical).into();

    Ok(ProcessedAvatar {
        canonical,
        thumbnail,
        content_hash,
        width: AVATAR_TIER_EDGE_PX,
        height: AVATAR_TIER_EDGE_PX,
    })
}

/// Computes the SHA-256 content hash of canonical bytes.
///
/// Exposed so storage can verify integrity without re-running the pipeline.
#[must_use]
pub fn content_hash(canonical: &[u8]) -> [u8; 32] {
    Sha256::digest(canonical).into()
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::{ImageEncoder, RgbImage};
    // `kamadak-exif` is imported under the crate name `exif`.
    use exif;

    /// Builds a synthetic in-memory PNG of the given size filled with a
    /// gradient so it has some entropy (and therefore some encoded size).
    fn synthetic_png(w: u32, h: u32) -> Vec<u8> {
        let mut img = RgbImage::new(w, h);
        for (x, y, px) in img.enumerate_pixels_mut() {
            *px = image::Rgb([(x % 256) as u8, (y % 256) as u8, ((x + y) % 256) as u8]);
        }
        let mut out = Vec::new();
        image::codecs::png::PngEncoder::new(Cursor::new(&mut out))
            .write_image(&img, w, h, image::ExtendedColorType::Rgb8)
            .expect("encode png");
        out
    }

    /// Builds a high-detail (noisy) PNG so the canonical JPEG is hard to
    /// compress — exercises the re-encode-to-fit loop.
    fn high_detail_png(w: u32, h: u32) -> Vec<u8> {
        let mut img = RgbImage::new(w, h);
        let mut state: u32 = 0x1234_5678;
        for px in img.pixels_mut() {
            // xorshift PRNG — deterministic, no external dep.
            state ^= state << 13;
            state ^= state >> 17;
            state ^= state << 5;
            *px = image::Rgb([
                (state & 0xFF) as u8,
                ((state >> 8) & 0xFF) as u8,
                ((state >> 16) & 0xFF) as u8,
            ]);
        }
        let mut out = Vec::new();
        image::codecs::png::PngEncoder::new(Cursor::new(&mut out))
            .write_image(&img, w, h, image::ExtendedColorType::Rgb8)
            .expect("encode png");
        out
    }

    fn is_jpeg(bytes: &[u8]) -> bool {
        bytes.len() >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF
    }

    /// Encodes a plain JPEG (no metadata) of the given size.
    fn plain_jpeg(w: u32, h: u32) -> Vec<u8> {
        let mut img = RgbImage::new(w, h);
        for (x, y, px) in img.enumerate_pixels_mut() {
            *px = image::Rgb([(x % 256) as u8, (y % 256) as u8, 200]);
        }
        let mut out = Vec::new();
        image::codecs::jpeg::JpegEncoder::new_with_quality(Cursor::new(&mut out), 90)
            .encode_image(&img)
            .expect("encode jpeg");
        out
    }

    /// Builds a little-endian TIFF/Exif payload (the bytes that follow the
    /// "Exif\0\0" identifier in an APP1 segment) containing a GPS IFD with one
    /// real GPS tag (GPSLatitudeRef = "N"). Hand-rolled so we control exactly
    /// what EXIF the *input* carries.
    fn exif_payload_with_gps() -> Vec<u8> {
        let mut p: Vec<u8> = Vec::new();
        // TIFF header: little-endian, magic 42, offset to IFD0 = 8.
        p.extend_from_slice(b"II");
        p.extend_from_slice(&42u16.to_le_bytes());
        p.extend_from_slice(&8u32.to_le_bytes());

        // IFD0: 1 entry pointing at the GPS IFD (tag 0x8825).
        p.extend_from_slice(&1u16.to_le_bytes()); // entry count
                                                  // entry: tag=0x8825 (GPSInfo), type=4 (LONG), count=1, value=offset.
                                                  // IFD0 starts at 8: 2 (count) + 12 (entry) + 4 (next-IFD ptr) = 26.
        let gps_ifd_offset: u32 = 8 + 2 + 12 + 4;
        p.extend_from_slice(&0x8825u16.to_le_bytes());
        p.extend_from_slice(&4u16.to_le_bytes());
        p.extend_from_slice(&1u32.to_le_bytes());
        p.extend_from_slice(&gps_ifd_offset.to_le_bytes());
        p.extend_from_slice(&0u32.to_le_bytes()); // next IFD = none

        // GPS IFD: 1 entry, GPSLatitudeRef (tag 1), type=2 (ASCII), count=2,
        // value = "N\0" packed inline.
        p.extend_from_slice(&1u16.to_le_bytes());
        p.extend_from_slice(&1u16.to_le_bytes());
        p.extend_from_slice(&2u16.to_le_bytes());
        p.extend_from_slice(&2u32.to_le_bytes());
        p.extend_from_slice(b"N\0\0\0"); // inline value, padded to 4 bytes
        p.extend_from_slice(&0u32.to_le_bytes()); // next IFD = none
        p
    }

    /// Splices an APP1 "Exif" segment carrying `exif_payload` into `jpeg`
    /// immediately after the SOI marker, producing a JPEG that genuinely
    /// carries EXIF/GPS.
    fn inject_exif_app1(jpeg: &[u8], exif_payload: &[u8]) -> Vec<u8> {
        assert_eq!(&jpeg[0..2], &[0xFF, 0xD8], "input must start with SOI");
        let mut out = Vec::new();
        out.extend_from_slice(&jpeg[0..2]); // SOI

        // APP1 marker.
        out.extend_from_slice(&[0xFF, 0xE1]);
        // Segment length = 2 (length field) + 6 ("Exif\0\0") + payload.
        let seg_len = 2 + 6 + exif_payload.len();
        out.extend_from_slice(&u16::try_from(seg_len).unwrap().to_be_bytes());
        out.extend_from_slice(b"Exif\0\0");
        out.extend_from_slice(exif_payload);

        // Rest of original JPEG.
        out.extend_from_slice(&jpeg[2..]);
        out
    }

    #[test]
    fn allowlist_accepts_jpeg_png_webp_and_rejects_others() {
        assert!(is_allowed_format(&[0xFF, 0xD8, 0xFF, 0x00]));
        assert!(is_allowed_format(&[
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00
        ]));
        let mut webp = Vec::from(*b"RIFF");
        webp.extend_from_slice(&[0, 0, 0, 0]);
        webp.extend_from_slice(b"WEBP");
        assert!(is_allowed_format(&webp));

        // SVG (XML) must be rejected.
        assert!(!is_allowed_format(
            b"<svg xmlns=\"http://www.w3.org/2000/svg\">"
        ));
        // GIF magic must be rejected even though the codec is compiled in.
        assert!(!is_allowed_format(b"GIF89a"));
        // Arbitrary data rejected.
        assert!(!is_allowed_format(b"not an image"));
        assert!(!is_allowed_format(&[]));
    }

    #[test]
    fn process_produces_square_canonical_and_thumbnail() {
        let png = synthetic_png(800, 600);
        let processed = process_own_avatar(&png).expect("pipeline");

        assert_eq!(processed.width, AVATAR_TIER_EDGE_PX);
        assert_eq!(processed.height, AVATAR_TIER_EDGE_PX);
        assert!(is_jpeg(&processed.canonical), "canonical must be JPEG");
        assert!(is_jpeg(&processed.thumbnail), "thumbnail must be JPEG");

        // Re-decode to confirm exact dimensions.
        let canon = image::load_from_memory(&processed.canonical).expect("decode canonical");
        assert_eq!(
            canon.dimensions(),
            (AVATAR_TIER_EDGE_PX, AVATAR_TIER_EDGE_PX)
        );
        let thumb = image::load_from_memory(&processed.thumbnail).expect("decode thumb");
        assert_eq!(
            thumb.dimensions(),
            (AVATAR_THUMB_EDGE_PX, AVATAR_THUMB_EDGE_PX)
        );
    }

    #[test]
    fn content_hash_is_stable_and_matches_sha256() {
        let png = synthetic_png(400, 400);
        let processed = process_own_avatar(&png).expect("pipeline");
        let recomputed: [u8; 32] = Sha256::digest(&*processed.canonical).into();
        assert_eq!(processed.content_hash, recomputed);
        assert_eq!(processed.content_hash, content_hash(&processed.canonical));
    }

    #[test]
    fn high_detail_image_fits_canonical_budget() {
        let png = high_detail_png(1024, 1024);
        let processed = process_own_avatar(&png).expect("pipeline");
        assert!(
            processed.canonical.len() <= AVATAR_CANONICAL_MAX_BYTES,
            "canonical {} must be within budget {}",
            processed.canonical.len(),
            AVATAR_CANONICAL_MAX_BYTES
        );
    }

    #[test]
    fn canonical_output_is_opaque_jpeg_not_input_png() {
        let png = synthetic_png(256, 256);
        let processed = process_own_avatar(&png).expect("pipeline");
        // Output must be JPEG, not the input PNG container.
        assert!(is_jpeg(&processed.canonical));
        const PNG_MAGIC: [u8; 8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
        assert!(processed.canonical.len() < 8 || processed.canonical[..8] != PNG_MAGIC);
    }

    #[test]
    fn oversized_input_rejected_pre_decode() {
        // Build a buffer with valid PNG magic but larger than the inbound cap,
        // and confirm the inbound limits reject it before decode.
        let mut data = vec![0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
        data.resize(super::super::config::INBOUND_MAX_INPUT_BYTES + 1, 0);
        let err = decode_under_limits(&data, DecodeLimits::inbound())
            .expect_err("oversized must be rejected");
        assert!(matches!(err, AvatarError::InputTooLarge));
    }

    #[test]
    fn svg_rejected_by_allowlist() {
        let svg = b"<svg xmlns=\"http://www.w3.org/2000/svg\"><rect/></svg>";
        let err = decode_under_limits(svg, DecodeLimits::own()).expect_err("svg must be rejected");
        assert!(matches!(err, AvatarError::UnsupportedFormat));
    }

    #[test]
    fn decode_bomb_rejected_under_inbound_limits() {
        // A genuine PNG whose declared dimensions exceed the inbound edge cap
        // (2048) must be rejected before a framebuffer is allocated, even
        // though its byte size is under the input cap.
        let png = synthetic_png(4096, 16);
        assert!(png.len() <= super::super::config::INBOUND_MAX_INPUT_BYTES);
        let err = decode_under_limits(&png, DecodeLimits::inbound())
            .expect_err("over-dimension image must be rejected by limits");
        assert!(matches!(err, AvatarError::Decode));
    }

    #[test]
    fn over_megapixel_image_rejected_within_edge_cap() {
        // Proves the explicit total-pixel cap is enforced INDEPENDENTLY of the
        // edge cap: a near-square image whose dimensions sit within the edge
        // bound but whose pixel count exceeds the 4 MP allocation budget must be
        // rejected with `Decode`. We widen the edge cap (so `check_dimensions`
        // passes) while keeping the inbound 4 MP alloc budget, isolating the
        // pixel-count check that the JPEG codec's `max_alloc` does not perform.
        let limits = DecodeLimits {
            max_input_bytes: super::super::config::OWN_MAX_INPUT_BYTES,
            max_edge_px: 4096,
            max_alloc_bytes: super::super::config::INBOUND_MAX_PIXELS * 4,
        };
        // 2100 * 2100 = 4_410_000 px > 4 MP (4_194_304), each edge < 4096.
        let png = synthetic_png(2100, 2100);
        let err = decode_under_limits(&png, limits)
            .expect_err("an image exceeding 4 MP must be rejected by the pixel cap");
        assert!(matches!(err, AvatarError::Decode));

        // Control: an image AT exactly the 4 MP budget within the same edge cap
        // decodes successfully (2048 * 2048 = 4 MP).
        let ok_png = synthetic_png(2048, 2048);
        decode_under_limits(&ok_png, limits).expect("exactly-4-MP image must decode");
    }

    #[test]
    fn corrupt_image_fails_closed() {
        // Valid JPEG magic but garbage body.
        let mut data = vec![0xFF, 0xD8, 0xFF];
        data.extend_from_slice(&[0u8; 64]);
        let err =
            decode_under_limits(&data, DecodeLimits::own()).expect_err("corrupt jpeg must fail");
        assert!(matches!(err, AvatarError::Decode));
    }

    #[test]
    fn webp_input_is_accepted_and_recoded_to_jpeg() {
        // Encode a small WebP (lossless) and confirm the pipeline accepts it
        // and emits a JPEG canonical.
        let mut img = RgbImage::new(300, 200);
        for (x, y, px) in img.enumerate_pixels_mut() {
            *px = image::Rgb([(x % 256) as u8, (y % 256) as u8, 128]);
        }
        let mut webp = Vec::new();
        image::codecs::webp::WebPEncoder::new_lossless(Cursor::new(&mut webp))
            .write_image(&img, 300, 200, image::ExtendedColorType::Rgb8)
            .expect("encode webp");
        let processed = process_own_avatar(&webp).expect("pipeline accepts webp");
        assert!(is_jpeg(&processed.canonical));
        assert_eq!(processed.width, AVATAR_TIER_EDGE_PX);
    }

    #[test]
    fn exif_gps_is_stripped_by_pipeline() {
        // Build a JPEG that genuinely carries an APP1 Exif segment with a GPS
        // IFD, then confirm the pipeline output carries no APP1 Exif marker and
        // that kamadak-exif parses zero fields out of it.
        let base = plain_jpeg(640, 480);
        let exif = exif_payload_with_gps();
        let with_gps = inject_exif_app1(&base, &exif);

        // Positive control: the crafted INPUT must parse as carrying EXIF, and
        // specifically a GPS-context field (kamadak-exif resolves the GPS
        // sub-IFD into fields whose tag carries `Context::Gps`).
        let in_reader = exif::Reader::new();
        let input_exif = in_reader
            .read_from_container(&mut Cursor::new(&with_gps))
            .expect("crafted input must parse as EXIF");
        assert!(
            input_exif.fields().count() > 0,
            "positive control: crafted input must contain EXIF fields"
        );
        assert!(
            input_exif
                .fields()
                .any(|fld| matches!(fld.tag, exif::Tag(exif::Context::Gps, _))),
            "positive control: crafted input must contain a GPS-context field"
        );

        // Run the pipeline.
        let processed = process_own_avatar(&with_gps).expect("pipeline");

        // No APP1 (0xFF 0xE1) Exif segment may survive in the canonical output.
        let has_app1_exif = processed.canonical.windows(2).any(|w| w == [0xFF, 0xE1]);
        assert!(
            !has_app1_exif,
            "canonical output must contain no APP1 Exif marker"
        );

        // kamadak-exif must find zero EXIF in the output.
        let out_reader = exif::Reader::new();
        let parsed = out_reader.read_from_container(&mut Cursor::new(&*processed.canonical));
        match parsed {
            Err(_) => { /* no EXIF at all — ideal */ }
            Ok(exif_data) => {
                assert_eq!(
                    exif_data.fields().count(),
                    0,
                    "output must contain zero EXIF fields"
                );
            }
        }
    }

    #[test]
    fn png_text_chunks_are_dropped_after_reencode() {
        // Encode a PNG, splice in an ancillary tEXt chunk, confirm the input
        // carries it but the JPEG output (a different container) cannot.
        let png = synthetic_png(300, 300);
        let with_text = inject_png_text_chunk(&png, b"Comment", b"home address: 1 secret st");

        // The crafted input genuinely contains the tEXt keyword.
        assert!(
            contains_subslice(&with_text, b"Comment"),
            "crafted input must carry the tEXt chunk"
        );
        assert!(contains_subslice(&with_text, b"secret st"));

        let processed = process_own_avatar(&with_text).expect("pipeline");
        assert!(is_jpeg(&processed.canonical));
        // The JPEG output must not carry the PNG text payload.
        assert!(
            !contains_subslice(&processed.canonical, b"secret st"),
            "re-encoded output must not carry the PNG text payload"
        );
    }

    fn contains_subslice(haystack: &[u8], needle: &[u8]) -> bool {
        haystack.windows(needle.len()).any(|w| w == needle)
    }

    /// Inserts an ancillary PNG tEXt chunk right after the IHDR chunk.
    fn inject_png_text_chunk(png: &[u8], keyword: &[u8], text: &[u8]) -> Vec<u8> {
        // PNG layout: 8-byte signature, then chunks. IHDR is the first chunk:
        // 4 (len) + 4 ("IHDR") + 13 (data) + 4 (crc) = 25 bytes, starting at 8.
        let ihdr_end = 8 + 4 + 4 + 13 + 4;
        let mut out = Vec::new();
        out.extend_from_slice(&png[..ihdr_end]);

        // Build the tEXt chunk data: keyword \0 text.
        let mut data = Vec::new();
        data.extend_from_slice(keyword);
        data.push(0);
        data.extend_from_slice(text);

        out.extend_from_slice(&u32::try_from(data.len()).unwrap().to_be_bytes());
        let chunk_type = b"tEXt";
        out.extend_from_slice(chunk_type);
        out.extend_from_slice(&data);
        // CRC over chunk type + data.
        let mut crc_input = Vec::new();
        crc_input.extend_from_slice(chunk_type);
        crc_input.extend_from_slice(&data);
        out.extend_from_slice(&png_crc32(&crc_input).to_be_bytes());

        out.extend_from_slice(&png[ihdr_end..]);
        out
    }

    /// Minimal CRC-32 (IEEE) for building valid PNG chunks in tests.
    fn png_crc32(data: &[u8]) -> u32 {
        let mut crc: u32 = 0xFFFF_FFFF;
        for &byte in data {
            crc ^= u32::from(byte);
            for _ in 0..8 {
                if crc & 1 != 0 {
                    crc = (crc >> 1) ^ 0xEDB8_8320;
                } else {
                    crc >>= 1;
                }
            }
        }
        crc ^ 0xFFFF_FFFF
    }
}
