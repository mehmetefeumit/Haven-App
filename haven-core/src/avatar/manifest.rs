//! Inner kind-9 wire schema for avatar share events (M2).
//!
//! Avatars travel as ordinary kind-445 MLS application messages whose decrypted
//! inner rumor is a `Kind::Custom(9)` event (exactly as location uses). Dispatch
//! is keyed off a `"type"` field *inside* the encrypted content — never on the
//! wire — so a relay cannot distinguish an avatar packet from a location packet.
//!
//! This module defines the JSON-serializable payloads ([`AvatarManifest`],
//! [`AvatarChunk`], [`AvatarClear`]) and the [`AvatarInner`] dispatcher that
//! parses an arbitrary decrypted kind-9 content string into one of those, or
//! into [`AvatarInner::Other`] (silently dropped — forward-compat for older
//! Haven builds and other Marmot clients such as White Noise).
//!
//! # Privacy / security
//!
//! * The schema NEVER carries any group identifier (MLS or nostr) — same
//!   invariant location enforces.
//! * All byte payloads are base64 strings; the `data`/`pad` fields are the only
//!   place image bytes appear, and they live inside the ciphertext.
//! * `Debug` output redacts the `data`, `pad`, and `content_hash` fields so no
//!   image bytes or hashes are ever logged.

use serde::{Deserialize, Serialize};

/// Schema version of the avatar wire format.
pub const AVATAR_SCHEMA_VERSION: u8 = 1;

/// `type` discriminator for the manifest (chunk 0) payload.
pub const TYPE_MANIFEST: &str = "haven-avatar-manifest";
/// `type` discriminator for a plain (non-manifest) chunk.
pub const TYPE_CHUNK: &str = "haven-avatar-chunk";
/// `type` discriminator for the removal tombstone.
pub const TYPE_CLEAR: &str = "haven-avatar-clear";

/// Inner `["t", …]` tag value used for code clarity. It lives INSIDE the
/// ciphertext, so it never helps a relay; it mirrors location's `["t",
/// "location"]` tag.
pub const AVATAR_T_TAG: &str = "haven-avatar";

/// The manifest payload, carried by chunk 0 (DEC-3). It folds the header
/// metadata together with the first data slice so all chunks are a single
/// uniform count.
#[derive(Clone, Serialize, Deserialize)]
pub struct AvatarManifest {
    /// Discriminator — always [`TYPE_MANIFEST`].
    #[serde(rename = "type")]
    pub kind: String,
    /// Schema version — always [`AVATAR_SCHEMA_VERSION`].
    pub v: u8,
    /// Sender's monotonic avatar version.
    pub version: i64,
    /// SHA-256 hex of the canonical plaintext image (integrity check).
    pub content_hash: String,
    /// MIME type of the canonical encode (e.g. `image/jpeg`).
    pub mime: String,
    /// Canonical width in pixels.
    pub w: u32,
    /// Canonical height in pixels.
    pub h: u32,
    /// Canonical byte length (receiver trims chunk padding to this).
    pub total_len: usize,
    /// Total number of chunks (manifest included).
    pub chunk_count: u32,
    /// MLS epoch the avatar was built under.
    pub epoch: u64,
    /// Chunk index — always 0 for the manifest.
    pub i: u32,
    /// Base64 of this chunk's payload slice.
    pub data: String,
    /// Base64 padding so the serialized inner length matches every other chunk.
    pub pad: String,
}

impl std::fmt::Debug for AvatarManifest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AvatarManifest")
            .field("v", &self.v)
            .field("version", &self.version)
            .field("content_hash", &"<redacted>")
            .field("mime", &self.mime)
            .field("w", &self.w)
            .field("h", &self.h)
            .field("total_len", &self.total_len)
            .field("chunk_count", &self.chunk_count)
            .field("epoch", &self.epoch)
            .field("i", &self.i)
            .field("data", &"<redacted>")
            .field("pad", &"<redacted>")
            .finish_non_exhaustive()
    }
}

/// A plain (non-manifest) chunk payload, indices `1..chunk_count`.
#[derive(Clone, Serialize, Deserialize)]
pub struct AvatarChunk {
    /// Discriminator — always [`TYPE_CHUNK`].
    #[serde(rename = "type")]
    pub kind: String,
    /// Schema version.
    pub v: u8,
    /// Sender's monotonic avatar version (must match the manifest's).
    pub version: i64,
    /// Chunk index in `1..chunk_count`.
    pub i: u32,
    /// Base64 of this chunk's payload slice.
    pub data: String,
    /// Base64 padding so the serialized inner length matches every other chunk.
    pub pad: String,
}

impl std::fmt::Debug for AvatarChunk {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AvatarChunk")
            .field("v", &self.v)
            .field("version", &self.version)
            .field("i", &self.i)
            .field("data", &"<redacted>")
            .field("pad", &"<redacted>")
            .finish_non_exhaustive()
    }
}

/// The removal tombstone payload (no image bytes).
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct AvatarClear {
    /// Discriminator — always [`TYPE_CLEAR`].
    #[serde(rename = "type")]
    pub kind: String,
    /// Schema version.
    pub v: u8,
    /// Sender's monotonic avatar version (must exceed the prior assignment to
    /// take effect).
    pub version: i64,
}

/// A decrypted inner kind-9 avatar payload, after dispatch on `type`.
#[derive(Debug)]
pub enum AvatarInner {
    /// A manifest (chunk 0).
    Manifest(Box<AvatarManifest>),
    /// A plain chunk (index ≥ 1).
    Chunk(AvatarChunk),
    /// A removal tombstone.
    Clear(AvatarClear),
    /// Any kind-9 content whose `type` is not an avatar type — silently
    /// dropped by the caller (forward-compat: location messages, future avatar
    /// types, other Marmot clients).
    Other,
}

/// Minimal probe used only to read the `type` discriminator before committing
/// to a full parse. Unknown fields are tolerated (no `deny_unknown_fields`).
#[derive(Deserialize)]
struct TypeProbe {
    #[serde(rename = "type")]
    kind: Option<String>,
}

impl AvatarInner {
    /// Parses a decrypted inner kind-9 `content` string into an [`AvatarInner`].
    ///
    /// Returns [`AvatarInner::Other`] for any content that is not valid JSON,
    /// has no `type`, or whose `type` is not one of the avatar discriminators —
    /// so non-avatar (e.g. location) and forward-incompatible payloads are
    /// dropped silently by the caller rather than erroring.
    #[must_use]
    pub fn parse(content: &str) -> Self {
        let Ok(probe) = serde_json::from_str::<TypeProbe>(content) else {
            return Self::Other;
        };
        match probe.kind.as_deref() {
            Some(TYPE_MANIFEST) => serde_json::from_str::<AvatarManifest>(content)
                .map_or(Self::Other, |m| Self::Manifest(Box::new(m))),
            Some(TYPE_CHUNK) => {
                serde_json::from_str::<AvatarChunk>(content).map_or(Self::Other, Self::Chunk)
            }
            Some(TYPE_CLEAR) => {
                serde_json::from_str::<AvatarClear>(content).map_or(Self::Other, Self::Clear)
            }
            _ => Self::Other,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_dispatches_manifest_chunk_clear() {
        let manifest = AvatarManifest {
            kind: TYPE_MANIFEST.to_string(),
            v: AVATAR_SCHEMA_VERSION,
            version: 7,
            content_hash: "ab".repeat(32),
            mime: "image/jpeg".to_string(),
            w: 512,
            h: 512,
            total_len: 1234,
            chunk_count: 4,
            epoch: 42,
            i: 0,
            data: "AAAA".to_string(),
            pad: String::new(),
        };
        let json = serde_json::to_string(&manifest).unwrap();
        assert!(matches!(
            AvatarInner::parse(&json),
            AvatarInner::Manifest(_)
        ));

        let chunk = AvatarChunk {
            kind: TYPE_CHUNK.to_string(),
            v: AVATAR_SCHEMA_VERSION,
            version: 7,
            i: 2,
            data: "BBBB".to_string(),
            pad: String::new(),
        };
        let json = serde_json::to_string(&chunk).unwrap();
        assert!(matches!(AvatarInner::parse(&json), AvatarInner::Chunk(_)));

        let clear = AvatarClear {
            kind: TYPE_CLEAR.to_string(),
            v: AVATAR_SCHEMA_VERSION,
            version: 8,
        };
        let json = serde_json::to_string(&clear).unwrap();
        assert!(matches!(AvatarInner::parse(&json), AvatarInner::Clear(_)));
    }

    #[test]
    fn unknown_type_and_location_are_other() {
        // A location-shaped kind-9 content.
        let loc = r#"{"latitude":1.0,"longitude":2.0}"#;
        assert!(matches!(AvatarInner::parse(loc), AvatarInner::Other));
        // A future/unknown avatar type.
        let future = r#"{"type":"haven-avatar-request","v":1}"#;
        assert!(matches!(AvatarInner::parse(future), AvatarInner::Other));
        // Not JSON at all.
        assert!(matches!(AvatarInner::parse("not json"), AvatarInner::Other));
        // JSON with no type.
        assert!(matches!(AvatarInner::parse("{}"), AvatarInner::Other));
    }

    #[test]
    fn unknown_fields_tolerated() {
        // A manifest with an extra unknown field still parses (forward-compat).
        let json = format!(
            r#"{{"type":"{TYPE_MANIFEST}","v":1,"version":3,"content_hash":"00",
                 "mime":"image/jpeg","w":512,"h":512,"total_len":9,"chunk_count":4,
                 "epoch":1,"i":0,"data":"AA","pad":"","future_field":true}}"#
        );
        assert!(matches!(
            AvatarInner::parse(&json),
            AvatarInner::Manifest(_)
        ));
    }

    #[test]
    fn debug_redacts_data_and_hash() {
        let manifest = AvatarManifest {
            kind: TYPE_MANIFEST.to_string(),
            v: 1,
            version: 1,
            content_hash: "deadbeef".to_string(),
            mime: "image/jpeg".to_string(),
            w: 512,
            h: 512,
            total_len: 4,
            chunk_count: 4,
            epoch: 0,
            i: 0,
            data: "SECRETDATA".to_string(),
            pad: "PADDING".to_string(),
        };
        let dbg = format!("{manifest:?}");
        assert!(!dbg.contains("deadbeef"), "content_hash must be redacted");
        assert!(!dbg.contains("SECRETDATA"), "data must be redacted");
        assert!(!dbg.contains("PADDING"), "pad must be redacted");
    }
}
