//! Compile-time configuration constants for the avatar pipeline.
//!
//! Every tunable that the owner might want to change lives here in one place
//! with a doc comment explaining its effect. Changing a value here changes the
//! behavior of the whole avatar subsystem; nothing else hard-codes these
//! numbers.
//!
//! # Privacy / size budget rationale
//!
//! The canonical picture is encoded to a single app-wide square resolution tier
//! and MUST fit inside [`AVATAR_CANONICAL_MAX_BYTES`]. The byte budget bounds
//! the size of the re-encoded picture that the public-profile Blossom upload
//! path ships — hence the re-encode-to-fit loop in [`crate::avatar::image`].

/// Canonical square edge length, in pixels (DEC-1 Option B).
///
/// The own picture is center-cropped to a square and downscaled to exactly this
/// edge before re-encoding. Raising this raises both quality and the size of the
/// re-encoded blob; it is a single constant so the owner can move to a higher
/// tier (e.g. 1024) later.
pub const AVATAR_TIER_EDGE_PX: u32 = 512;

/// Local thumbnail square edge length, in pixels.
///
/// Derived on-device for map markers and member tiles (the hot display path).
pub const AVATAR_THUMB_EDGE_PX: u32 = 96;

/// MIME type of the canonical (and thumbnail) encode (DEC-1b).
///
/// JPEG via the pure-Rust `image` encoder. The pure-Rust WebP encoder is
/// lossless-only and would blow the size budget, and libwebp would add a C
/// cross-compile dependency we are avoiding — so the canonical format is JPEG.
pub const AVATAR_MIME: &str = "image/jpeg";

// Note: the M2 chunk / orphan / reassembly-timeout constants that used to live
// below were removed with the MLS in-group avatar broadcast at the
// public-profile cutover. The tiers above are all the public-profile image
// pipeline needs.

/// Starting JPEG quality for the canonical re-encode-to-fit loop.
///
/// The pipeline encodes at this quality first and only steps down toward
/// [`AVATAR_JPEG_QUALITY_FLOOR`] if the output exceeds
/// [`AVATAR_CANONICAL_MAX_BYTES`].
pub const AVATAR_JPEG_QUALITY_START: u8 = 82;

/// Lowest JPEG quality the canonical re-encode-to-fit loop will try.
///
/// If even this quality produces an output larger than
/// [`AVATAR_CANONICAL_MAX_BYTES`], the pipeline returns an error rather than
/// shipping an over-budget blob (which would break M2's fixed chunk count).
pub const AVATAR_JPEG_QUALITY_FLOOR: u8 = 40;

/// JPEG quality for the local thumbnail encode.
///
/// The thumbnail is tiny ([`AVATAR_THUMB_EDGE_PX`] square) and only ever lives
/// on-device, so it uses a single fixed quality (no fit loop).
pub const AVATAR_THUMB_JPEG_QUALITY: u8 = 70;

/// Hard upper bound, in bytes, on the canonical encode.
///
/// The canonical JPEG MUST fit within this budget. The pipeline re-encodes at
/// progressively lower quality (down to [`AVATAR_JPEG_QUALITY_FLOOR`]) until it
/// fits; if it never fits, the pipeline returns an error. This bounds the size
/// of the re-encoded picture the public-profile upload path ships.
pub const AVATAR_CANONICAL_MAX_BYTES: usize = 90_000;

/// Decode resource limits.
///
/// Two presets exist: a generous one for the user's *own* trusted image
/// ([`DecodeLimits::own`]) and a strict one for *untrusted inbound* images
/// ([`DecodeLimits::inbound`]). The inbound preset guards pictures downloaded
/// from a member's chosen Blossom host (see [`crate::profile::blossom`]).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DecodeLimits {
    /// Maximum accepted *input* byte length, checked BEFORE the decoder is
    /// ever constructed. This independent pre-check — not per-codec feature
    /// gating — is the primary decode-bomb defense (correction #3).
    pub max_input_bytes: usize,
    /// Maximum image edge (width or height), in pixels. Enforced via the
    /// `image` crate's `Limits` before pixel allocation.
    pub max_edge_px: u32,
    /// Maximum total pixel-allocation budget, in bytes (the `image` crate's
    /// `max_alloc`). Derived from the edge cap assuming up to 4 bytes/pixel
    /// (RGBA), so a claimed-but-undersized buffer still cannot allocate a
    /// huge framebuffer.
    pub max_alloc_bytes: u64,
}

/// Maximum input size for the user's OWN avatar (trusted, generous).
pub const OWN_MAX_INPUT_BYTES: usize = 16 * 1024 * 1024;

/// Maximum edge for the user's OWN avatar.
pub const OWN_MAX_EDGE_PX: u32 = 8192;

/// Maximum input size for an UNTRUSTED inbound avatar (strict). Applied to
/// pictures downloaded from a member's chosen Blossom host.
pub const INBOUND_MAX_INPUT_BYTES: usize = 512 * 1024;

/// Maximum edge for an UNTRUSTED inbound avatar.
pub const INBOUND_MAX_EDGE_PX: u32 = 2048;

/// Maximum total pixel count (4 megapixels) for an UNTRUSTED inbound avatar.
pub const INBOUND_MAX_PIXELS: u64 = 4 * 1024 * 1024;

impl DecodeLimits {
    /// Limits for decoding the user's own (trusted) image. Generous, but still
    /// bounded so a corrupt own file cannot OOM the device.
    #[must_use]
    pub const fn own() -> Self {
        Self {
            max_input_bytes: OWN_MAX_INPUT_BYTES,
            max_edge_px: OWN_MAX_EDGE_PX,
            // 8192 * 8192 * 4 bytes (RGBA) = 256 MiB worst-case framebuffer.
            max_alloc_bytes: (OWN_MAX_EDGE_PX as u64) * (OWN_MAX_EDGE_PX as u64) * 4,
        }
    }

    /// Strict limits for decoding an untrusted inbound image (M2 reuse).
    ///
    /// The allocation cap is derived from the 4-megapixel cap at 4 bytes/pixel
    /// so even an image whose declared edges are within `max_edge_px` cannot
    /// allocate beyond a small framebuffer.
    #[must_use]
    pub const fn inbound() -> Self {
        Self {
            max_input_bytes: INBOUND_MAX_INPUT_BYTES,
            max_edge_px: INBOUND_MAX_EDGE_PX,
            // 4 MP * 4 bytes (RGBA) = 16 MiB worst-case framebuffer.
            max_alloc_bytes: INBOUND_MAX_PIXELS * 4,
        }
    }
}
