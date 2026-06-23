//! Per-(circle, sender) in-flight avatar reassembly state (M2 receive path).
//!
//! Holds at most one in-flight reassembly per `(circle, sender)` plus a small
//! bounded buffer of orphan chunks that arrived before their manifest. Newer
//! `version`s evict older in-flight state; orphan bytes are capped; an
//! incomplete set is evicted after a timeout (§5.9). The active reassembly
//! buffer ([`Reassembler`]) holds its decoded payload in `Zeroizing`, wiped on
//! eviction.
//!
//! # Security
//!
//! The orphan path is also fully `Zeroizing`: a chunk that arrives before its
//! manifest is base64-DECODED into a `Zeroizing<Vec<u8>>` on arrival (its `pad`
//! — pure filler — is discarded, never buffered or counted), so the only image
//! bytes ever held are wiped on drop, just like the active reassembler. Drops
//! are silent. Nothing here logs image bytes or hashes. Resource bounds make a
//! malicious member unable to make us buffer unboundedly or pin memory by
//! withholding the manifest.

use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use zeroize::Zeroizing;

use crate::avatar::{
    AvatarChunk, AvatarError, AvatarManifest, ReassembledAvatar, Reassembler,
    AVATAR_MAX_ORPHAN_BYTES,
};

/// A chunk that arrived before its manifest, base64-DECODED into `Zeroizing`
/// bytes on arrival. Only the decoded `data` payload is retained; the chunk's
/// `pad` (pure filler) is discarded and never counted toward the byte cap.
struct DecodedOrphan {
    /// Chunk index in `1..chunk_count`.
    index: u32,
    /// Sender's avatar version (matches the tracked version by construction).
    version: i64,
    /// Decoded chunk payload, wiped on drop.
    data: Zeroizing<Vec<u8>>,
}

/// In-flight reassembly state for one `(circle, sender)`.
pub struct AvatarReassemblyState {
    /// The active reassembler once the manifest has arrived.
    reassembler: Option<Reassembler>,
    /// The version this state tracks (the manifest's, or the orphans' shared
    /// version). `None` until the first chunk/manifest sets it.
    version: Option<i64>,
    /// Chunks that arrived before the manifest, base64-decoded into `Zeroizing`
    /// bytes (bounded). Discarded/wiped on eviction or after replay.
    orphans: Vec<DecodedOrphan>,
    /// Bytes of DECODED orphan `data` buffered, for the `DoS` cap (pad excluded).
    orphan_bytes: usize,
    /// Unix-seconds timestamp of the last update (for timeout eviction).
    last_touched: i64,
}

impl std::fmt::Debug for AvatarReassemblyState {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AvatarReassemblyState")
            .field("has_reassembler", &self.reassembler.is_some())
            .field("version", &self.version)
            .field("orphans", &self.orphans.len())
            .field("orphan_bytes", &self.orphan_bytes)
            .field("last_touched", &self.last_touched)
            .finish()
    }
}

impl AvatarReassemblyState {
    /// Creates an empty state stamped at `now`.
    #[must_use]
    pub const fn new(now: i64) -> Self {
        Self {
            reassembler: None,
            version: None,
            orphans: Vec::new(),
            orphan_bytes: 0,
            last_touched: now,
        }
    }

    /// Whether this state has expired relative to `now` given `timeout_secs`.
    #[must_use]
    pub const fn is_expired(&self, now: i64, timeout_secs: i64) -> bool {
        now.saturating_sub(self.last_touched) >= timeout_secs
    }

    /// The version currently tracked, if any.
    #[cfg(test)]
    #[must_use]
    pub const fn tracked_version(&self) -> Option<i64> {
        self.version
    }

    /// Bytes of DECODED orphan `data` currently buffered (test introspection).
    #[cfg(test)]
    #[must_use]
    pub const fn orphan_bytes_for_test(&self) -> usize {
        self.orphan_bytes
    }

    /// Resets this state to track a newer `version`, discarding any older
    /// in-flight work (newest-version-wins). Wipes buffers by dropping them.
    fn reset_for_version(&mut self, version: i64, now: i64) {
        self.reassembler = None;
        self.orphans.clear();
        self.orphan_bytes = 0;
        self.version = Some(version);
        self.last_touched = now;
    }

    /// Ingests a manifest, returning a finalized avatar if the set is already
    /// complete (manifest + all previously-buffered orphans).
    ///
    /// If the manifest's version is older than the tracked version it is
    /// ignored (returns `Ok(None)`); equal or newer (re)initializes the
    /// reassembler and replays compatible orphans.
    ///
    /// # Errors
    ///
    /// [`AvatarError::InvalidInput`] on a malformed manifest. On error the
    /// caller MUST evict this state (fail-closed); the partial buffers are
    /// dropped/wiped.
    pub fn ingest_manifest(
        &mut self,
        manifest: &AvatarManifest,
        now: i64,
    ) -> Result<Option<ReassembledAvatar>, AvatarError> {
        if let Some(v) = self.version {
            if manifest.version < v {
                // Older than what we're tracking — ignore.
                return Ok(None);
            }
            if manifest.version > v {
                self.reset_for_version(manifest.version, now);
            }
        } else {
            self.version = Some(manifest.version);
        }

        let mut reassembler = Reassembler::from_manifest(manifest)?;
        // Replay buffered orphans (already base64-decoded into Zeroizing) that
        // match this version. Draining moves the Zeroizing bytes into the
        // reassembler's slots; any remainder is wiped on drop at scope end.
        let orphans = std::mem::take(&mut self.orphans);
        self.orphan_bytes = 0;
        for orphan in orphans {
            if orphan.version == manifest.version {
                // A malformed orphan (bad index/size) fails the whole set
                // (fail-closed).
                reassembler.add_decoded_chunk(orphan.index, orphan.version, orphan.data)?;
            }
        }
        let finalized = reassembler.try_finalize()?;
        self.reassembler = Some(reassembler);
        self.last_touched = now;
        Ok(finalized)
    }

    /// Ingests a plain chunk, returning a finalized avatar if the set becomes
    /// complete. Buffers as an orphan if the manifest has not yet arrived.
    ///
    /// # Errors
    ///
    /// [`AvatarError::InvalidInput`] on a malformed chunk or when the orphan
    /// buffer cap would be exceeded. On error the caller MUST evict this state.
    pub fn ingest_chunk(
        &mut self,
        chunk: &AvatarChunk,
        now: i64,
    ) -> Result<Option<ReassembledAvatar>, AvatarError> {
        // Version gating: a chunk for a newer version resets state; an older
        // version is ignored.
        if let Some(v) = self.version {
            if chunk.version < v {
                return Ok(None);
            }
            if chunk.version > v {
                self.reset_for_version(chunk.version, now);
            }
        } else {
            self.version = Some(chunk.version);
        }
        self.last_touched = now;

        if let Some(reassembler) = self.reassembler.as_mut() {
            reassembler.add_chunk(chunk)?;
            return reassembler.try_finalize();
        }

        // No manifest yet — base64-DECODE the chunk's data into Zeroizing bytes
        // and buffer the decoded payload (discarding `pad`, which is pure
        // filler) under the byte cap. Decoding on arrival keeps real image bytes
        // out of non-zeroized memory and lets the cap count only true payload.
        let decoded = Zeroizing::new(
            B64.decode(chunk.data.as_bytes())
                .map_err(|_| AvatarError::InvalidInput)?,
        );
        let added = decoded.len();
        if self.orphan_bytes.saturating_add(added) > AVATAR_MAX_ORPHAN_BYTES {
            return Err(AvatarError::InvalidInput);
        }
        // Dedup orphan by index (idempotent).
        if !self.orphans.iter().any(|o| o.index == chunk.i) {
            self.orphan_bytes += added;
            self.orphans.push(DecodedOrphan {
                index: chunk.i,
                version: chunk.version,
                data: decoded,
            });
        }
        Ok(None)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::avatar::{build_chunks, AvatarInner};
    use sha2::{Digest, Sha256};

    fn hash(b: &[u8]) -> [u8; 32] {
        Sha256::digest(b).into()
    }

    fn chunks_for(canonical: &[u8], version: i64, epoch: u64) -> Vec<String> {
        let h = hash(canonical);
        build_chunks(canonical, &h, version, epoch, 512, 512)
            .expect("build")
            .into_iter()
            .map(|z| z.to_string())
            .collect()
    }

    #[test]
    fn manifest_first_then_chunks_completes() {
        let canonical = vec![0x5Au8; crate::avatar::AVATAR_CHUNK_PAYLOAD_BYTES * 2 + 7];
        let serialized = chunks_for(&canonical, 1, 0);
        let mut state = AvatarReassemblyState::new(0);
        let mut done = None;
        for (i, s) in serialized.iter().enumerate() {
            match AvatarInner::parse(s) {
                AvatarInner::Manifest(m) => {
                    done = state.ingest_manifest(&m, i as i64).unwrap();
                }
                AvatarInner::Chunk(c) => {
                    done = state.ingest_chunk(&c, i as i64).unwrap();
                }
                _ => panic!(),
            }
        }
        let avatar = done.expect("complete");
        assert_eq!(&*avatar.canonical, &canonical[..]);
    }

    #[test]
    fn orphans_before_manifest_are_buffered_then_replayed() {
        let canonical = vec![0x33u8; crate::avatar::AVATAR_CHUNK_PAYLOAD_BYTES * 3 + 1];
        let serialized = chunks_for(&canonical, 2, 1);
        let mut state = AvatarReassemblyState::new(0);
        // Feed chunks 1..n first (orphans), manifest last.
        for s in serialized.iter().skip(1) {
            if let AvatarInner::Chunk(c) = AvatarInner::parse(s) {
                assert!(state.ingest_chunk(&c, 1).unwrap().is_none());
            }
        }
        let m = match AvatarInner::parse(&serialized[0]) {
            AvatarInner::Manifest(m) => m,
            _ => panic!(),
        };
        let avatar = state
            .ingest_manifest(&m, 2)
            .unwrap()
            .expect("complete after manifest");
        assert_eq!(&*avatar.canonical, &canonical[..]);
    }

    #[test]
    fn newer_version_chunk_evicts_older_orphans() {
        let v1 = vec![1u8; crate::avatar::AVATAR_CHUNK_PAYLOAD_BYTES + 1];
        let v2 = vec![2u8; crate::avatar::AVATAR_CHUNK_PAYLOAD_BYTES + 1];
        let s1 = chunks_for(&v1, 1, 0);
        let s2 = chunks_for(&v2, 2, 0);
        let mut state = AvatarReassemblyState::new(0);
        // Orphan from v1.
        if let AvatarInner::Chunk(c) = AvatarInner::parse(&s1[1]) {
            state.ingest_chunk(&c, 0).unwrap();
        }
        assert_eq!(state.tracked_version(), Some(1));
        // Manifest from v2 supersedes; v1 orphan must be discarded (not replayed).
        let m2 = match AvatarInner::parse(&s2[0]) {
            AvatarInner::Manifest(m) => m,
            _ => panic!(),
        };
        assert!(state.ingest_manifest(&m2, 1).unwrap().is_none());
        assert_eq!(state.tracked_version(), Some(2));
        // Completing v2 yields v2 bytes.
        let mut done = None;
        for s in s2.iter().skip(1) {
            if let AvatarInner::Chunk(c) = AvatarInner::parse(s) {
                done = state.ingest_chunk(&c, 2).unwrap();
            }
        }
        assert_eq!(&*done.expect("complete").canonical, &v2[..]);
    }

    #[test]
    fn orphan_byte_cap_enforced() {
        // Fabricate many distinct oversized orphan chunks to exceed the cap.
        // `"A".repeat(N)` is valid base64; each 4 chars decode to 3 bytes, so a
        // chunk whose `data` is `AVATAR_MAX_ORPHAN_BYTES` base64 chars decodes to
        // ~3/4 of the cap. Two therefore exceed the cap.
        let mut state = AvatarReassemblyState::new(0);
        let big = "A".repeat(AVATAR_MAX_ORPHAN_BYTES);
        let c0 = AvatarChunk {
            kind: crate::avatar::TYPE_CHUNK.to_string(),
            v: 1,
            version: 1,
            i: 1,
            data: big.clone(),
            pad: String::new(),
        };
        // First just under is fine; second pushes over the cap.
        assert!(state.ingest_chunk(&c0, 0).unwrap().is_none());
        let c1 = AvatarChunk { i: 2, ..c0.clone() };
        assert!(matches!(
            state.ingest_chunk(&c1, 0),
            Err(AvatarError::InvalidInput)
        ));
    }

    #[test]
    fn orphan_cap_counts_decoded_data_only_not_pad() {
        // The cap must count ONLY the DECODED `data` bytes — never `pad` (pure
        // filler that is discarded on arrival). A single orphan carrying a tiny
        // payload but an enormous `pad` must NOT trip the cap, because pad is
        // neither decoded, buffered, nor counted.
        let mut state = AvatarReassemblyState::new(0);
        let huge_pad = "A".repeat(AVATAR_MAX_ORPHAN_BYTES * 4);
        let chunk = AvatarChunk {
            kind: crate::avatar::TYPE_CHUNK.to_string(),
            v: 1,
            version: 1,
            i: 1,
            // base64 of a 3-byte payload.
            data: "AAAA".to_string(),
            pad: huge_pad,
        };
        // Pad far exceeds the cap, but only the 3 decoded data bytes count, so
        // this is buffered without error.
        assert!(state.ingest_chunk(&chunk, 0).unwrap().is_none());
        assert_eq!(state.orphan_bytes_for_test(), 3);
    }

    #[test]
    fn orphan_buffers_are_zeroizing() {
        // Compile-time assertion: orphan chunks buffered before their manifest
        // hold their decoded payload as `Zeroizing<Vec<u8>>` so the (image-
        // bearing) bytes are wiped on drop. If the orphan buffer type ever
        // changes away from Zeroizing this fails to compile.
        fn _assert_orphan_zeroizing(o: &DecodedOrphan) -> &Zeroizing<Vec<u8>> {
            &o.data
        }
    }

    #[test]
    fn expiry_detection() {
        let state = AvatarReassemblyState::new(100);
        assert!(!state.is_expired(101, 2));
        assert!(state.is_expired(102, 2));
    }
}
