//! Compile-time configuration constants for the avatar pipeline.
//!
//! Every tunable that the owner might want to change lives here in one place
//! with a doc comment explaining its effect. Changing a value here changes the
//! behavior of the whole avatar subsystem; nothing else hard-codes these
//! numbers.
//!
//! # Privacy / size budget rationale
//!
//! The canonical avatar is encoded to a single app-wide square resolution tier
//! and MUST fit inside [`AVATAR_CANONICAL_MAX_BYTES`]. Milestone M2 splits that
//! canonical blob into a *fixed* number of equal-size, padded chunks so every
//! avatar looks byte-identical on the wire (no size-class leak). Guaranteeing
//! the canonical encode fits a fixed byte budget here is what lets M2 use a
//! fixed chunk count — hence the re-encode-to-fit loop in
//! [`crate::avatar::image`].

/// Canonical square edge length, in pixels (DEC-1 Option B).
///
/// The own avatar is center-cropped to a square and downscaled to exactly this
/// edge before re-encoding. Raising this raises both quality and the constant
/// per-share bandwidth M2 will pay; it is a single constant so the owner can
/// move to a higher tier (e.g. 1024) later.
pub const AVATAR_TIER_EDGE_PX: u32 = 512;

/// Local thumbnail square edge length, in pixels.
///
/// Derived on-device for map markers and member tiles (the hot display path).
/// Never transmitted — only the full [`AVATAR_TIER_EDGE_PX`] tier crosses the
/// wire in M2; receivers derive their own thumbnail.
pub const AVATAR_THUMB_EDGE_PX: u32 = 96;

/// MIME type of the canonical (and thumbnail) encode (DEC-1b).
///
/// JPEG via the pure-Rust `image` encoder. The pure-Rust WebP encoder is
/// lossless-only and would blow the size budget, and libwebp would add a C
/// cross-compile dependency we are avoiding — so the canonical format is JPEG.
pub const AVATAR_MIME: &str = "image/jpeg";

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
/// fits; if it never fits, the pipeline returns an error. This guarantees M2's
/// fixed chunk count can always carry any accepted avatar.
pub const AVATAR_CANONICAL_MAX_BYTES: usize = 90_000;

/// Decode resource limits.
///
/// Two presets exist: a generous one for the user's *own* trusted image
/// ([`DecodeLimits::own`]) and a strict one for *untrusted inbound* images
/// ([`DecodeLimits::inbound`]). The inbound preset is defined now for M2 reuse
/// even though M1 has no inbound path; it is exercised by unit tests.
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

/// Maximum input size for an UNTRUSTED inbound avatar (strict). Reserved for
/// M2's receive path; defined now so the limit is reviewed and tested early.
pub const INBOUND_MAX_INPUT_BYTES: usize = 512 * 1024;

/// Maximum edge for an UNTRUSTED inbound avatar.
pub const INBOUND_MAX_EDGE_PX: u32 = 2048;

/// Maximum total pixel count (4 megapixels) for an UNTRUSTED inbound avatar.
pub const INBOUND_MAX_PIXELS: u64 = 4 * 1024 * 1024;

// ============================================================================
// M2 chunk / padding constants (DEC-3 manifest-in-chunk-0, R2 indistinguish.)
// ============================================================================
//
// The canonical blob (≤ [`AVATAR_CANONICAL_MAX_BYTES`] = 90 000 bytes) is split
// into exactly [`AVATAR_CHUNK_COUNT`] equal-size payload slices, each base64-
// encoded into the inner kind-9 rumor's `data` field and padded (via the `pad`
// field) so that the FINAL SERIALIZED inner-content byte length is IDENTICAL
// for every chunk INCLUDING the manifest (chunk 0). That constant inner-plaintext
// length is what yields a constant *outer* NIP-44 ciphertext length, so a relay
// sees N byte-identical kind-445 events regardless of the actual image size
// (no size-class leak; the count is always [`AVATAR_CHUNK_COUNT`]).
//
// # Sizing rationale (measured, see `chunk.rs` tests)
//
// * payload per chunk = ceil(90 000 / 4) = 22 500 bytes.
// * base64(22 500) = 30 000 chars in the `data` field.
// * The manifest carries ~10 extra header fields (`content_hash`, `mime`,
//   `w`/`h`, `total_len`, `chunk_count`, `epoch`, …). A plain chunk therefore
//   needs MORE `pad` than the manifest to reach the same total length.
// * [`AVATAR_CHUNK_WIRE_BYTES`] is the target serialized-JSON length every
//   chunk pads up to. It is chosen with generous headroom above the largest
//   header (the manifest) so the pad is always non-negative, yet small enough
//   that the resulting NIP-44 + base64 + JSON-framed OUTER kind-445 event stays
//   safely under strfry's 64 KB `maxEventSize` (a wire test asserts
//   `event.content.len() < 60_000` and equal length across chunks).

/// Fixed number of chunks every avatar is split into (DEC-1 / DEC-3).
///
/// Chosen for the 512 px / 90 KB tier: `ceil(90_000 / AVATAR_CHUNK_PAYLOAD_BYTES)`.
/// EVERY avatar — however small the source image — emits exactly this many
/// equal-length kind-445 events, so neither the size class nor the chunk count
/// leaks. Raising the resolution tier ([`AVATAR_TIER_EDGE_PX`]) /
/// [`AVATAR_CANONICAL_MAX_BYTES`] later may require raising this.
pub const AVATAR_CHUNK_COUNT: u32 = 4;

/// Canonical-plaintext payload bytes carried by each chunk (before base64).
///
/// `AVATAR_CHUNK_COUNT * AVATAR_CHUNK_PAYLOAD_BYTES` MUST be ≥
/// [`AVATAR_CANONICAL_MAX_BYTES`] so the fixed chunk set can always carry any
/// accepted canonical blob. The final chunk's tail is zero-filled padding that
/// the receiver trims using the manifest's `total_len`.
pub const AVATAR_CHUNK_PAYLOAD_BYTES: usize = 22_500;

/// Target serialized-JSON byte length that EVERY inner kind-9 chunk (manifest
/// and plain chunks alike) is padded up to via its `pad` field.
///
/// This is the constant inner-plaintext length that makes the outer NIP-44
/// ciphertext constant across all chunks. It must be (a) ≥ the largest
/// un-padded serialized chunk (the manifest, which has the most header fields),
/// and (b) small enough that the framed outer kind-445 event stays under
/// strfry's 64 KB cap. base64(22 500)=30 000 chars of `data` plus headers and
/// pad land the manifest near ~30.4 KB un-padded; 31 000 gives safe headroom
/// while keeping the outer event well under 60 KB.
pub const AVATAR_CHUNK_WIRE_BYTES: usize = 31_000;

/// Maximum bytes of orphan (pre-manifest) chunk payload buffered per sender
/// before the in-flight reassembly is dropped (anti-DoS, §5.9).
///
/// Bounded at one canonical tier so a peer cannot make us buffer unboundedly by
/// withholding the manifest. `data` is base64, so we bound the decoded payload
/// to one full canonical blob worth.
pub const AVATAR_MAX_ORPHAN_BYTES: usize = AVATAR_CANONICAL_MAX_BYTES;

/// Production timeout (seconds) for evicting an incomplete reassembly (§5.9).
///
/// Longer than the anti-entropy period so a fresh full re-send always finishes
/// a set. A `#[cfg(test)]` override shortens this for tests (see
/// [`avatar_reassembly_timeout_secs`]).
pub const AVATAR_REASSEMBLY_TIMEOUT_SECS: i64 = 30 * 60;

/// Returns the active reassembly timeout. In test builds this is a short
/// override so timeout-eviction can be exercised without a 30-minute wait.
#[must_use]
pub const fn avatar_reassembly_timeout_secs() -> i64 {
    #[cfg(test)]
    {
        2
    }
    #[cfg(not(test))]
    {
        AVATAR_REASSEMBLY_TIMEOUT_SECS
    }
}

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
