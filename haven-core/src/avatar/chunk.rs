//! Avatar chunking, padding, and reassembly (M2).
//!
//! Splits a canonical avatar blob into a FIXED number of equal-size, padded
//! inner kind-9 payloads (R2 indistinguishability) and reassembles received
//! chunks back into the canonical bytes, verifying integrity with a
//! constant-time content-hash compare.
//!
//! # Padding invariant
//!
//! Every serialized inner payload — the manifest (chunk 0) and every plain
//! chunk — is padded via its `pad` field to EXACTLY
//! [`config::AVATAR_CHUNK_WIRE_BYTES`] serialized bytes. The manifest carries
//! more header fields, so non-manifest chunks pad more. This constant
//! inner-plaintext length is what yields a constant outer NIP-44 ciphertext
//! length, so a relay sees N byte-identical kind-445 events regardless of the
//! image's true size.
//!
//! # Security
//!
//! * All plaintext / reassembly buffers are `Zeroizing` and wiped on drop.
//! * Integrity uses [`subtle::ConstantTimeEq`] on the SHA-256 content hash.
//! * No image bytes / hashes are ever logged; errors are byte-free.

use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;
use zeroize::Zeroizing;

use super::config::{
    AVATAR_CHUNK_COUNT, AVATAR_CHUNK_PAYLOAD_BYTES, AVATAR_CHUNK_WIRE_BYTES, AVATAR_MIME,
};
use super::error::{AvatarError, Result};
use super::manifest::{
    AvatarChunk, AvatarManifest, AVATAR_SCHEMA_VERSION, TYPE_CHUNK, TYPE_MANIFEST,
};

/// The serialized inner-content JSON string for one chunk, ready to become a
/// kind-9 rumor's content. Wrapped in `Zeroizing` so the (image-bearing)
/// plaintext is wiped on drop.
pub type SerializedChunk = Zeroizing<String>;

/// Splits `canonical` into the fixed [`AVATAR_CHUNK_COUNT`] padded chunk JSON
/// strings (chunk 0 = manifest), all of EQUAL serialized length.
///
/// `content_hash` is the SHA-256 of `canonical`; `version` and `epoch` come
/// from the sender's stored avatar state. The returned strings are the exact
/// inner kind-9 content for each chunk.
///
/// # Errors
///
/// * [`AvatarError::TooLargeAfterEncode`] if `canonical` does not fit the fixed
///   chunk set (`AVATAR_CHUNK_COUNT * AVATAR_CHUNK_PAYLOAD_BYTES`).
/// * [`AvatarError::Encode`] if a padded payload exceeds the wire-byte target
///   (a config/serialization invariant violation — should never happen with the
///   shipped constants; a test guards it).
pub fn build_chunks(
    canonical: &[u8],
    content_hash: &[u8; 32],
    version: i64,
    epoch: u64,
    width: u32,
    height: u32,
) -> Result<Vec<SerializedChunk>> {
    let total_len = canonical.len();
    let capacity = AVATAR_CHUNK_PAYLOAD_BYTES * (AVATAR_CHUNK_COUNT as usize);
    if total_len > capacity {
        return Err(AvatarError::TooLargeAfterEncode);
    }

    let hash_hex = hex::encode(content_hash);
    let mut out = Vec::with_capacity(AVATAR_CHUNK_COUNT as usize);

    for i in 0..AVATAR_CHUNK_COUNT {
        let start = (i as usize) * AVATAR_CHUNK_PAYLOAD_BYTES;
        let end = (start + AVATAR_CHUNK_PAYLOAD_BYTES).min(total_len);
        // Slices past the real data are empty (the last chunk's tail).
        let slice: &[u8] = if start < total_len {
            &canonical[start..end]
        } else {
            &[]
        };
        let data_b64 = B64.encode(slice);

        // Serialize WITHOUT pad first to learn the un-padded length, then pad
        // the `pad` field's base64 content so the whole serialized string hits
        // exactly AVATAR_CHUNK_WIRE_BYTES.
        let unpadded = if i == 0 {
            serialize_manifest(
                version, &hash_hex, width, height, total_len, epoch, &data_b64, "",
            )?
        } else {
            serialize_chunk(version, i, &data_b64, "")?
        };

        let serialized = pad_to_target(&unpadded, |pad_b64| {
            if i == 0 {
                serialize_manifest(
                    version, &hash_hex, width, height, total_len, epoch, &data_b64, pad_b64,
                )
            } else {
                serialize_chunk(version, i, &data_b64, pad_b64)
            }
        })?;

        out.push(Zeroizing::new(serialized));
    }

    Ok(out)
}

/// Serializes a manifest payload with the given `pad` base64 string.
#[allow(clippy::too_many_arguments)]
fn serialize_manifest(
    version: i64,
    content_hash_hex: &str,
    width: u32,
    height: u32,
    total_len: usize,
    epoch: u64,
    data_b64: &str,
    pad_b64: &str,
) -> Result<String> {
    let manifest = AvatarManifest {
        kind: TYPE_MANIFEST.to_string(),
        v: AVATAR_SCHEMA_VERSION,
        version,
        content_hash: content_hash_hex.to_string(),
        mime: AVATAR_MIME.to_string(),
        w: width,
        h: height,
        total_len,
        chunk_count: AVATAR_CHUNK_COUNT,
        epoch,
        i: 0,
        data: data_b64.to_string(),
        pad: pad_b64.to_string(),
    };
    serde_json::to_string(&manifest).map_err(|_| AvatarError::Encode)
}

/// Serializes a plain chunk payload with the given `pad` base64 string.
fn serialize_chunk(version: i64, i: u32, data_b64: &str, pad_b64: &str) -> Result<String> {
    let chunk = AvatarChunk {
        kind: TYPE_CHUNK.to_string(),
        v: AVATAR_SCHEMA_VERSION,
        version,
        i,
        data: data_b64.to_string(),
        pad: pad_b64.to_string(),
    };
    serde_json::to_string(&chunk).map_err(|_| AvatarError::Encode)
}

/// The JSON-escaped length of `s`: the number of bytes `s` occupies when it is
/// embedded as a JSON string value (as it will be — the chunk JSON becomes the
/// kind-9 rumor's `content` field, which MDK re-serializes). Each `"` becomes
/// `\"` (+1) and each `\` becomes `\\` (+1). The chunk JSON contains no other
/// escapable bytes (base64, hex, and the `A` pad are all escape-free), so this
/// is exact.
///
/// We pad to a constant ESCAPED length — not raw length — because the manifest
/// has more quote-delimited fields than a plain chunk, so equal raw lengths
/// would still produce *different* embedded (and therefore different MLS/NIP-44
/// ciphertext) lengths. Equal escaped length is what makes the OUTER kind-445
/// ciphertext byte-identical across chunks.
fn escaped_len(s: &str) -> usize {
    s.len() + s.bytes().filter(|&b| b == b'"' || b == b'\\').count()
}

/// Pads the `pad` field until the serialized payload's JSON-ESCAPED length is
/// EXACTLY [`AVATAR_CHUNK_WIRE_BYTES`] bytes.
///
/// The `pad` field is a JSON string holding plain ASCII `'A'` filler (the
/// receiver never decodes it; `A` is escape-free). Each `'A'` adds exactly one
/// byte to both the raw and escaped serialized length, so the deficit between
/// the empty-pad escaped length and the target equals the exact number of
/// filler chars to emit. A bounded correction loop guards against any
/// serializer quirk.
fn pad_to_target<F>(empty_pad_serialized: &str, reserialize: F) -> Result<String>
where
    F: Fn(&str) -> Result<String>,
{
    let base = escaped_len(empty_pad_serialized);
    if base > AVATAR_CHUNK_WIRE_BYTES {
        // The un-padded payload already exceeds the target — a config/size
        // invariant violation. Surfaced as Encode (byte-free).
        return Err(AvatarError::Encode);
    }
    let mut fill = AVATAR_CHUNK_WIRE_BYTES - base;
    // Bounded correction loop: at most a couple of iterations in practice.
    for _ in 0..8 {
        let pad = "A".repeat(fill);
        let candidate = reserialize(&pad)?;
        let elen = escaped_len(&candidate);
        match elen.cmp(&AVATAR_CHUNK_WIRE_BYTES) {
            std::cmp::Ordering::Equal => return Ok(candidate),
            std::cmp::Ordering::Less => fill += AVATAR_CHUNK_WIRE_BYTES - elen,
            std::cmp::Ordering::Greater => {
                let over = elen - AVATAR_CHUNK_WIRE_BYTES;
                if over > fill {
                    return Err(AvatarError::Encode);
                }
                fill -= over;
            }
        }
    }
    Err(AvatarError::Encode)
}

/// In-progress reassembly of one avatar from a single sender+version. All
/// payload buffers are `Zeroizing`.
pub struct Reassembler {
    version: i64,
    epoch: u64,
    content_hash: [u8; 32],
    total_len: usize,
    chunk_count: u32,
    width: u32,
    height: u32,
    /// Decoded payload slices by index; `None` until that slot arrives.
    slots: Vec<Option<Zeroizing<Vec<u8>>>>,
    /// Bytes currently buffered (for the orphan/DoS bound).
    buffered_bytes: usize,
}

impl std::fmt::Debug for Reassembler {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Reassembler")
            .field("version", &self.version)
            .field("epoch", &self.epoch)
            .field("content_hash", &"<redacted>")
            .field("total_len", &self.total_len)
            .field("chunk_count", &self.chunk_count)
            .field(
                "present",
                &self.slots.iter().filter(|s| s.is_some()).count(),
            )
            .field("buffered_bytes", &self.buffered_bytes)
            .finish_non_exhaustive()
    }
}

/// The decoded, hash-verified canonical avatar produced by a completed
/// reassembly. Bytes are `Zeroizing`.
pub struct ReassembledAvatar {
    /// Canonical (verified) image bytes.
    pub canonical: Zeroizing<Vec<u8>>,
    /// SHA-256 of the canonical bytes (matches the manifest, verified).
    pub content_hash: [u8; 32],
    /// Sender's avatar version.
    pub version: i64,
    /// MLS epoch the avatar was built under.
    pub epoch: u64,
    /// Canonical width in pixels (from the manifest).
    pub width: u32,
    /// Canonical height in pixels (from the manifest).
    pub height: u32,
}

impl std::fmt::Debug for ReassembledAvatar {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ReassembledAvatar")
            .field("canonical", &"<redacted>")
            .field("content_hash", &"<redacted>")
            .field("version", &self.version)
            .field("epoch", &self.epoch)
            .field("width", &self.width)
            .field("height", &self.height)
            .finish()
    }
}

impl Reassembler {
    /// Creates a reassembler from a parsed manifest, decoding and storing its
    /// own data slice (chunk 0).
    ///
    /// # Errors
    ///
    /// [`AvatarError::InvalidInput`] for a malformed manifest (bad hash hex,
    /// out-of-range counts, oversized declared length, undecodable data).
    pub fn from_manifest(m: &AvatarManifest) -> Result<Self> {
        if m.chunk_count != AVATAR_CHUNK_COUNT {
            return Err(AvatarError::InvalidInput);
        }
        let capacity = AVATAR_CHUNK_PAYLOAD_BYTES * (AVATAR_CHUNK_COUNT as usize);
        if m.total_len > capacity {
            return Err(AvatarError::InvalidInput);
        }
        let hash_bytes = hex::decode(&m.content_hash).map_err(|_| AvatarError::InvalidInput)?;
        let content_hash: [u8; 32] = hash_bytes
            .try_into()
            .map_err(|_| AvatarError::InvalidInput)?;

        let data = B64
            .decode(m.data.as_bytes())
            .map_err(|_| AvatarError::InvalidInput)?;
        if data.len() > AVATAR_CHUNK_PAYLOAD_BYTES {
            return Err(AvatarError::InvalidInput);
        }
        let data = Zeroizing::new(data);
        let buffered_bytes = data.len();

        let mut slots: Vec<Option<Zeroizing<Vec<u8>>>> =
            (0..AVATAR_CHUNK_COUNT).map(|_| None).collect();
        slots[0] = Some(data);

        Ok(Self {
            version: m.version,
            epoch: m.epoch,
            content_hash,
            total_len: m.total_len,
            chunk_count: m.chunk_count,
            width: m.w,
            height: m.h,
            slots,
            buffered_bytes,
        })
    }

    /// Adds a plain chunk's decoded payload to its slot. Idempotent on
    /// duplicate `i`; out-of-order safe.
    ///
    /// # Errors
    ///
    /// [`AvatarError::InvalidInput`] for an out-of-range index, undecodable
    /// data, an oversized slice, or a version mismatch with the manifest.
    pub fn add_chunk(&mut self, c: &AvatarChunk) -> Result<()> {
        let data = B64
            .decode(c.data.as_bytes())
            .map_err(|_| AvatarError::InvalidInput)?;
        self.add_decoded_chunk(c.i, c.version, Zeroizing::new(data))
    }

    /// Adds an already-base64-DECODED chunk payload to its slot, applying the
    /// same version/index/size/duplicate validation as [`Self::add_chunk`] but
    /// skipping the base64 decode (the bytes are already decoded — e.g. an
    /// orphan that was decoded into `Zeroizing` on arrival). Idempotent on
    /// duplicate `index`; out-of-order safe.
    ///
    /// # Errors
    ///
    /// [`AvatarError::InvalidInput`] for an out-of-range index, an oversized
    /// slice, or a version mismatch with the manifest.
    pub fn add_decoded_chunk(
        &mut self,
        index: u32,
        version: i64,
        data: Zeroizing<Vec<u8>>,
    ) -> Result<()> {
        if version != self.version {
            return Err(AvatarError::InvalidInput);
        }
        if index == 0 || index >= self.chunk_count {
            return Err(AvatarError::InvalidInput);
        }
        if self.slots[index as usize].is_some() {
            // Duplicate — idempotent no-op.
            return Ok(());
        }
        if data.len() > AVATAR_CHUNK_PAYLOAD_BYTES {
            return Err(AvatarError::InvalidInput);
        }
        self.buffered_bytes += data.len();
        self.slots[index as usize] = Some(data);
        Ok(())
    }

    /// Returns this reassembly's avatar version.
    #[cfg(test)]
    #[must_use]
    pub const fn version(&self) -> i64 {
        self.version
    }

    /// Returns this reassembly's epoch.
    #[cfg(test)]
    #[must_use]
    pub const fn epoch(&self) -> u64 {
        self.epoch
    }

    /// Bytes currently buffered (for the orphan/DoS bound).
    #[cfg(test)]
    #[must_use]
    pub const fn buffered_bytes(&self) -> usize {
        self.buffered_bytes
    }

    /// Whether every slot is filled.
    #[must_use]
    pub fn is_complete(&self) -> bool {
        self.slots.iter().all(Option::is_some)
    }

    /// Attempts to finalize: concat all slots, trim to `total_len`, verify the
    /// content hash in constant time. Returns `Ok(None)` if not yet complete.
    ///
    /// # Errors
    ///
    /// [`AvatarError::InvalidInput`] if the content hash does not match (the
    /// whole set must then be discarded by the caller — fail-closed).
    pub fn try_finalize(&self) -> Result<Option<ReassembledAvatar>> {
        if !self.is_complete() {
            return Ok(None);
        }
        let mut buf: Zeroizing<Vec<u8>> = Zeroizing::new(Vec::with_capacity(self.total_len));
        // `is_complete` guarantees every slot is Some.
        for bytes in self.slots.iter().flatten() {
            buf.extend_from_slice(bytes);
        }
        if buf.len() < self.total_len {
            // A slot decoded short — cannot reach the declared length.
            return Err(AvatarError::InvalidInput);
        }
        buf.truncate(self.total_len);

        let computed: [u8; 32] = Sha256::digest(&*buf).into();
        // Constant-time compare (subtle): no early-exit timing oracle on the
        // attacker-controllable bytes.
        if computed.ct_eq(&self.content_hash).unwrap_u8() != 1 {
            return Err(AvatarError::InvalidInput);
        }

        Ok(Some(ReassembledAvatar {
            canonical: buf,
            content_hash: self.content_hash,
            version: self.version,
            epoch: self.epoch,
            width: self.width,
            height: self.height,
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::avatar::manifest::AvatarInner;

    fn hash(bytes: &[u8]) -> [u8; 32] {
        Sha256::digest(bytes).into()
    }

    /// Builds chunks for `canonical`, parses each back into an `AvatarInner`,
    /// reassembles, and returns the finalized avatar.
    fn round_trip(canonical: &[u8]) -> ReassembledAvatar {
        let h = hash(canonical);
        let chunks = build_chunks(canonical, &h, 3, 9, 512, 512).expect("build");
        // Feed manifest first, then plain chunks (order tested separately).
        let mut reasm: Option<Reassembler> = None;
        for s in &chunks {
            match AvatarInner::parse(s) {
                AvatarInner::Manifest(m) => {
                    reasm = Some(Reassembler::from_manifest(&m).expect("from_manifest"));
                }
                AvatarInner::Chunk(c) => {
                    reasm
                        .as_mut()
                        .expect("manifest first")
                        .add_chunk(&c)
                        .expect("add");
                }
                _ => panic!("unexpected inner type"),
            }
        }
        reasm
            .expect("had manifest")
            .try_finalize()
            .expect("finalize ok")
            .expect("complete")
    }

    #[test]
    fn all_chunks_have_equal_escaped_length() {
        // The padding targets a constant JSON-ESCAPED length (so the chunk JSON
        // embedded as a rumor's `content` field is equal-length across chunks,
        // yielding a constant outer NIP-44 ciphertext). Raw lengths may differ
        // (the manifest has more structural quotes, hence fewer pad chars), but
        // escaped lengths must be identical and hit the target exactly.
        let canonical = vec![0xABu8; 50_000];
        let chunks = build_chunks(&canonical, &hash(&canonical), 1, 0, 512, 512).expect("build");
        assert_eq!(chunks.len(), AVATAR_CHUNK_COUNT as usize);
        let elen0 = escaped_len(&chunks[0]);
        assert_eq!(
            elen0, AVATAR_CHUNK_WIRE_BYTES,
            "escaped length must hit the wire target exactly"
        );
        for c in &chunks {
            assert_eq!(
                escaped_len(c),
                elen0,
                "every chunk must be equal escaped length"
            );
        }
    }

    #[test]
    fn round_trip_exact_capacity() {
        // Exactly fills the capacity (no last-chunk padding).
        let canonical = vec![0x5Au8; AVATAR_CHUNK_PAYLOAD_BYTES * (AVATAR_CHUNK_COUNT as usize)];
        let out = round_trip(&canonical);
        assert_eq!(&*out.canonical, &canonical[..]);
        assert_eq!(out.content_hash, hash(&canonical));
        assert_eq!(out.version, 3);
        assert_eq!(out.epoch, 9);
    }

    #[test]
    fn round_trip_boundary_and_plus_one() {
        // Exactly one chunk worth.
        let one = vec![1u8; AVATAR_CHUNK_PAYLOAD_BYTES];
        assert_eq!(&*round_trip(&one).canonical, &one[..]);
        // One byte into the second chunk.
        let plus = vec![2u8; AVATAR_CHUNK_PAYLOAD_BYTES + 1];
        assert_eq!(&*round_trip(&plus).canonical, &plus[..]);
    }

    #[test]
    fn round_trip_small_image_pads_to_full_count() {
        let small = vec![7u8; 1234];
        let h = hash(&small);
        let chunks = build_chunks(&small, &h, 1, 0, 512, 512).expect("build");
        // Even a tiny image emits the full fixed count of equal-length chunks.
        assert_eq!(chunks.len(), AVATAR_CHUNK_COUNT as usize);
        let out = round_trip(&small);
        assert_eq!(&*out.canonical, &small[..]);
    }

    #[test]
    fn empty_canonical_is_rejected_or_round_trips() {
        // total_len 0 is degenerate; build succeeds (all chunks empty data) and
        // round-trips to empty. The image pipeline never produces 0 bytes, but
        // the chunker must not panic.
        let empty: Vec<u8> = Vec::new();
        let out = round_trip(&empty);
        assert!(out.canonical.is_empty());
    }

    #[test]
    fn oversized_canonical_rejected() {
        let too_big = vec![0u8; AVATAR_CHUNK_PAYLOAD_BYTES * (AVATAR_CHUNK_COUNT as usize) + 1];
        let err = build_chunks(&too_big, &hash(&too_big), 1, 0, 512, 512)
            .expect_err("over-capacity must be rejected");
        assert!(matches!(err, AvatarError::TooLargeAfterEncode));
    }

    #[test]
    fn out_of_order_reassembly_works() {
        let canonical = vec![0x33u8; AVATAR_CHUNK_PAYLOAD_BYTES * 2 + 500];
        let h = hash(&canonical);
        let chunks = build_chunks(&canonical, &h, 5, 1, 512, 512).expect("build");
        // Parse all.
        let mut inners: Vec<AvatarInner> = chunks.iter().map(|s| AvatarInner::parse(s)).collect();
        // Reverse so plain chunks arrive before we even build the reassembler.
        inners.reverse();
        let mut reasm: Option<Reassembler> = None;
        let mut orphans: Vec<AvatarChunk> = Vec::new();
        for inner in inners {
            match inner {
                AvatarInner::Manifest(m) => {
                    let mut r = Reassembler::from_manifest(&m).unwrap();
                    for o in orphans.drain(..) {
                        r.add_chunk(&o).unwrap();
                    }
                    reasm = Some(r);
                }
                AvatarInner::Chunk(c) => {
                    if let Some(r) = reasm.as_mut() {
                        r.add_chunk(&c).unwrap();
                    } else {
                        orphans.push(c);
                    }
                }
                _ => panic!(),
            }
        }
        let out = reasm.unwrap().try_finalize().unwrap().unwrap();
        assert_eq!(&*out.canonical, &canonical[..]);
    }

    #[test]
    fn duplicate_chunk_is_idempotent() {
        let canonical = vec![0x9u8; AVATAR_CHUNK_PAYLOAD_BYTES + 10];
        let h = hash(&canonical);
        let chunks = build_chunks(&canonical, &h, 1, 0, 512, 512).unwrap();
        let m = match AvatarInner::parse(&chunks[0]) {
            AvatarInner::Manifest(m) => m,
            _ => panic!(),
        };
        let mut r = Reassembler::from_manifest(&m).unwrap();
        let c1 = match AvatarInner::parse(&chunks[1]) {
            AvatarInner::Chunk(c) => c,
            _ => panic!(),
        };
        r.add_chunk(&c1).unwrap();
        let before = r.buffered_bytes();
        r.add_chunk(&c1).unwrap(); // duplicate
        assert_eq!(r.buffered_bytes(), before, "dup must not double-count");
    }

    #[test]
    fn flipped_byte_fails_content_hash() {
        // Fill all four chunks so the set is complete, then corrupt chunk 1.
        let canonical = vec![0x44u8; AVATAR_CHUNK_PAYLOAD_BYTES * 3 + 7];
        let h = hash(&canonical);
        let chunks = build_chunks(&canonical, &h, 1, 0, 512, 512).unwrap();
        let m = match AvatarInner::parse(&chunks[0]) {
            AvatarInner::Manifest(m) => m,
            _ => panic!(),
        };
        let mut r = Reassembler::from_manifest(&m).unwrap();
        for (idx, s) in chunks.iter().enumerate().skip(1) {
            let mut c = match AvatarInner::parse(s) {
                AvatarInner::Chunk(c) => c,
                _ => panic!(),
            };
            if idx == 1 {
                // Flip a byte in chunk 1's decoded data.
                let mut decoded = B64.decode(c.data.as_bytes()).unwrap();
                decoded[0] ^= 0xFF;
                c.data = B64.encode(&decoded);
            }
            r.add_chunk(&c).unwrap();
        }
        assert!(r.is_complete());
        let err = r.try_finalize().expect_err("hash mismatch must error");
        assert!(matches!(err, AvatarError::InvalidInput));
    }

    #[test]
    fn missing_chunk_is_incomplete_not_an_error() {
        let canonical = vec![0x12u8; AVATAR_CHUNK_PAYLOAD_BYTES * 3];
        let h = hash(&canonical);
        let chunks = build_chunks(&canonical, &h, 1, 0, 512, 512).unwrap();
        let m = match AvatarInner::parse(&chunks[0]) {
            AvatarInner::Manifest(m) => m,
            _ => panic!(),
        };
        let mut r = Reassembler::from_manifest(&m).unwrap();
        // Add only chunk 1, leave 2 and 3 missing.
        if let AvatarInner::Chunk(c) = AvatarInner::parse(&chunks[1]) {
            r.add_chunk(&c).unwrap();
        }
        assert!(!r.is_complete());
        assert!(r.try_finalize().unwrap().is_none(), "incomplete → Ok(None)");
    }

    #[test]
    fn chunk_version_mismatch_rejected() {
        let canonical = vec![0x88u8; AVATAR_CHUNK_PAYLOAD_BYTES + 1];
        let h = hash(&canonical);
        let chunks = build_chunks(&canonical, &h, 10, 0, 512, 512).unwrap();
        let m = match AvatarInner::parse(&chunks[0]) {
            AvatarInner::Manifest(m) => m,
            _ => panic!(),
        };
        let mut r = Reassembler::from_manifest(&m).unwrap();
        let mut c1 = match AvatarInner::parse(&chunks[1]) {
            AvatarInner::Chunk(c) => c,
            _ => panic!(),
        };
        c1.version = 11; // mismatched
        assert!(matches!(r.add_chunk(&c1), Err(AvatarError::InvalidInput)));
    }

    #[test]
    fn ciphertext_plaintext_has_no_image_magic_after_split() {
        // The padded chunk strings are base64+JSON; the raw image magic bytes
        // (FF D8 FF for JPEG) must not survive as a contiguous byte sequence in
        // the SERIALIZED chunk (they are base64-encoded inside `data`).
        let mut canonical = vec![0xFFu8, 0xD8, 0xFF, 0xE0]; // JPEG SOI+APP0
        canonical.extend_from_slice(&[0x11u8; AVATAR_CHUNK_PAYLOAD_BYTES]);
        let h = hash(&canonical);
        let chunks = build_chunks(&canonical, &h, 1, 0, 512, 512).unwrap();
        for c in &chunks {
            assert!(
                !c.as_bytes().windows(3).any(|w| w == [0xFF, 0xD8, 0xFF]),
                "serialized chunk must not contain raw JPEG magic"
            );
        }
    }

    proptest::proptest! {
        /// Across arbitrary input sizes (and arbitrary version/epoch digit
        /// counts), every chunk — manifest included — has the SAME JSON-escaped
        /// serialized length, exactly the wire target. This is the constant-
        /// inner-plaintext property that yields a constant outer ciphertext.
        #[test]
        fn padding_yields_constant_escaped_length(
            len in 0usize..=(AVATAR_CHUNK_PAYLOAD_BYTES * (AVATAR_CHUNK_COUNT as usize)),
            version in 0i64..=9_999_999_999i64,
            epoch in 0u64..=9_999_999u64,
        ) {
            let canonical = vec![0xC3u8; len];
            let h = hash(&canonical);
            let chunks = build_chunks(&canonical, &h, version, epoch, 512, 512)
                .expect("build within capacity");
            proptest::prop_assert_eq!(chunks.len(), AVATAR_CHUNK_COUNT as usize);
            for c in &chunks {
                proptest::prop_assert_eq!(escaped_len(c), AVATAR_CHUNK_WIRE_BYTES);
            }
        }

        /// Round-trip holds across arbitrary input sizes.
        #[test]
        fn round_trip_arbitrary_sizes(
            len in 0usize..=(AVATAR_CHUNK_PAYLOAD_BYTES * (AVATAR_CHUNK_COUNT as usize)),
        ) {
            let canonical = vec![0x2Bu8; len];
            let out = round_trip(&canonical);
            proptest::prop_assert_eq!(&*out.canonical, &canonical[..]);
        }
    }

    #[test]
    fn reassembler_slot_buffers_are_zeroizing() {
        // Compile-time assertion: the reassembler stores its decoded payload
        // slices as `Zeroizing<Vec<u8>>` so they are wiped on drop. If the slot
        // type ever changes away from Zeroizing this fails to compile.
        fn _assert_zeroizing(r: &Reassembler) -> &Option<Zeroizing<Vec<u8>>> {
            &r.slots[0]
        }
        // The finalized canonical buffer is also Zeroizing.
        fn _assert_canonical_zeroizing(a: &ReassembledAvatar) -> &Zeroizing<Vec<u8>> {
            &a.canonical
        }
    }
}
