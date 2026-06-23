//! Avatar BLOB storage methods for [`CircleStorage`].
//!
//! These methods extend `CircleStorage` (sharing its single
//! `Mutex<Connection>` via the `pub(crate) conn()` accessor) with the
//! content-addressed, reference-counted avatar blob store described in the
//! profile-pictures plan. They were placed here — as a sibling `impl` block,
//! mirroring [`super::storage_relay_prefs`] — rather than in a standalone
//! `avatar/storage.rs` module precisely so they integrate with the existing
//! lock-once-then-transaction discipline (`storage.rs:45-68`): every method
//! acquires the lock once at the top and does all dependent work (refcount
//! inc/dec, GC) inside a single transaction.
//!
//! # Privacy / security
//!
//! * Blob bytes are encrypted at rest by `SQLCipher` (keyring-managed key);
//!   they are never written as plaintext files.
//! * All plaintext byte buffers handed to / returned from these methods are
//!   `Zeroizing` so they are wiped on drop.
//! * Nothing here logs or formats image bytes, content hashes, or hex of image
//!   content (Security Rule 6 / 8).
//!
//! # Sentinel convention
//!
//! `circle_id` is the MLS group id bytes; the **empty blob** `[]` is the
//! sentinel for the user's OWN avatar (matching `processed_gift_wraps`).

// Mirror `storage.rs`: every method here acquires the connection lock once at
// the top and holds it across the whole transaction (refcount inc/dec + GC), so
// the guard's lifetime is intentional, not over-broad.
#![allow(clippy::significant_drop_tightening)]

use rand::rngs::OsRng;
use rand::RngCore;
use rusqlite::{params, OptionalExtension};
use sha2::{Digest, Sha256};
use zeroize::Zeroizing;

use super::error::{CircleError, Result};
use super::storage::CircleStorage;

/// The `circle_id` sentinel for the user's own avatar: the empty blob.
pub(super) const OWN_AVATAR_CIRCLE_ID: &[u8] = &[];

/// A processed avatar ready to be stored: canonical + thumbnail bytes and
/// metadata. Plaintext bytes are `Zeroizing`.
///
/// This is the storage-layer mirror of the image pipeline's `ProcessedAvatar`;
/// the manager converts between them so the storage layer has no dependency on
/// the `image` crate.
pub struct AvatarBlobs {
    /// Canonical JPEG bytes.
    pub canonical: Zeroizing<Vec<u8>>,
    /// Thumbnail JPEG bytes.
    pub thumbnail: Zeroizing<Vec<u8>>,
    /// SHA-256 of the canonical bytes (32 bytes).
    pub content_hash: [u8; 32],
    /// SHA-256 of the thumbnail bytes (32 bytes).
    pub thumb_hash: [u8; 32],
    /// MIME type (e.g. `image/jpeg`).
    pub mime: String,
    /// Canonical width in pixels.
    pub width: u32,
    /// Thumbnail width in pixels (also its height; thumbnails are square).
    pub thumb_edge: u32,
}

impl std::fmt::Debug for AvatarBlobs {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AvatarBlobs")
            .field("canonical", &"<redacted>")
            .field("thumbnail", &"<redacted>")
            .field("content_hash", &"<redacted>")
            .field("thumb_hash", &"<redacted>")
            .field("mime", &self.mime)
            .field("width", &self.width)
            .field("thumb_edge", &self.thumb_edge)
            .finish()
    }
}

/// Metadata about a stored avatar assignment (no bytes).
#[derive(Clone)]
pub struct AvatarAssignmentMeta {
    /// Content hash of the canonical image (32 bytes).
    pub content_hash: [u8; 32],
    /// MIME type.
    pub mime: String,
    /// Canonical width in pixels.
    pub width: u32,
    /// Canonical height in pixels.
    pub height: u32,
    /// Monotonic avatar version for this (circle, member).
    pub version: i64,
}

impl std::fmt::Debug for AvatarAssignmentMeta {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AvatarAssignmentMeta")
            .field("content_hash", &"<redacted>")
            .field("mime", &self.mime)
            .field("width", &self.width)
            .field("height", &self.height)
            .field("version", &self.version)
            .finish()
    }
}

impl CircleStorage {
    /// Stores the user's OWN avatar: writes the canonical and thumbnail blobs
    /// (de-duplicated, reference-counted) and assigns them under the empty
    /// `circle_id` sentinel for `own_pubkey` with `source = 'local'`.
    ///
    /// The whole operation — upserting both blobs, incrementing their
    /// refcounts, replacing any prior own-avatar assignment (and decrementing
    /// the refcounts of the blobs it referenced, GC'ing any that hit 0) — runs
    /// in a single transaction under one lock acquisition.
    ///
    /// Returns the new monotonic `version` (previous + 1, or 1 if none).
    ///
    /// # Errors
    ///
    /// Returns [`CircleError::Storage`] on lock poisoning and
    /// [`CircleError::Database`] on `SQLite` failure (the transaction is rolled
    /// back).
    pub fn set_own_avatar(
        &self,
        own_pubkey: &str,
        blobs: &AvatarBlobs,
        now_unix_secs: i64,
    ) -> Result<i64> {
        self.upsert_avatar_assignment(
            OWN_AVATAR_CIRCLE_ID,
            own_pubkey,
            blobs,
            "local",
            0,
            now_unix_secs,
        )
    }

    /// Returns the per-circle DEC-6 salt for `circle_id`, generating and
    /// persisting a fresh 32-byte `OsRng` salt on first use.
    ///
    /// The salt is local-only (never transmitted) and is used to derive a
    /// RECEIVED avatar's `blob_key = sha256(salt || image)` so the same image
    /// in two circles yields different keys (closes the cross-circle
    /// correlation + known-plaintext oracle). The OWN-avatar sentinel
    /// (`circle_id == []`) is salt-free by design and must not call this.
    ///
    /// # Errors
    ///
    /// As [`Self::set_own_avatar`].
    pub fn circle_avatar_salt(&self, circle_id: &[u8]) -> Result<Zeroizing<[u8; 32]>> {
        let mut conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        let tx = conn.transaction()?;
        let existing: Option<Vec<u8>> = tx
            .query_row(
                "SELECT salt FROM circle_salts WHERE circle_id = ?1",
                params![circle_id],
                |row| row.get(0),
            )
            .optional()?;
        let salt: [u8; 32] = if let Some(bytes) = existing {
            bytes
                .try_into()
                .map_err(|_| CircleError::InvalidData("stored salt is not 32 bytes".to_string()))?
        } else {
            let mut s = [0u8; 32];
            OsRng.fill_bytes(&mut s);
            let now = chrono::Utc::now().timestamp();
            tx.execute(
                "INSERT INTO circle_salts (circle_id, salt, created_at) VALUES (?1, ?2, ?3)",
                params![circle_id, &s[..], now],
            )?;
            s
        };
        tx.commit()?;
        Ok(Zeroizing::new(salt))
    }

    /// Derives the DEC-6 salted blob key `sha256(salt || image)`.
    #[must_use]
    fn salted_blob_key(salt: &[u8; 32], content_hash: &[u8; 32]) -> [u8; 32] {
        // We salt the CONTENT HASH (a collision-resistant stand-in for the
        // image bytes) rather than re-hashing the whole image: it is equivalent
        // for dedup-key purposes and avoids re-streaming the bytes.
        let mut hasher = Sha256::new();
        hasher.update(salt);
        hasher.update(content_hash);
        hasher.finalize().into()
    }

    /// Stores a RECEIVED avatar for `(circle_id, sender_pubkey)` under the
    /// DEC-6 per-circle salted blob key, with supersession ordered by
    /// `(version, sender_epoch)`.
    ///
    /// A new assignment is written only if `(version, sender_epoch)` is
    /// strictly greater than any existing assignment for the same pair
    /// (`created_at` is NEVER consulted — it lives in the unauthenticated
    /// wrapper). The provided `version` is the sender's manifest version
    /// (NOT a local bump). Returns `true` if the store was applied, `false`
    /// if it was a stale (lower-or-equal) replay that was ignored.
    ///
    /// # Errors
    ///
    /// As [`Self::set_own_avatar`].
    pub fn store_received_avatar(
        &self,
        circle_id: &[u8],
        sender_pubkey: &str,
        blobs: &AvatarBlobs,
        version: i64,
        sender_epoch: i64,
        now_unix_secs: i64,
    ) -> Result<bool> {
        let salt = self.circle_avatar_salt(circle_id)?;
        let canonical_key = Self::salted_blob_key(&salt, &blobs.content_hash);
        let thumb_key = Self::salted_blob_key(&salt, &blobs.thumb_hash);

        let mut conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        let tx = conn.transaction()?;

        // Supersession gate: only apply if strictly newer by (version, epoch).
        let existing: Option<(Vec<u8>, Vec<u8>, i64, i64)> = tx
            .query_row(
                "SELECT canonical_key, thumb_key, version, sender_epoch \
                 FROM avatar_assignments WHERE circle_id = ?1 AND member_pubkey = ?2",
                params![circle_id, sender_pubkey],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
            )
            .optional()?;

        if let Some((_, _, ev, ee)) = &existing {
            if (version, sender_epoch) <= (*ev, *ee) {
                // Stale or equal replay — ignore (fail-closed, keep current).
                tx.commit()?;
                return Ok(false);
            }
        }

        Self::upsert_blob_tx(
            &tx,
            &canonical_key,
            &blobs.content_hash,
            &blobs.canonical,
            &blobs.mime,
            blobs.width,
            blobs.width,
            now_unix_secs,
        )?;
        Self::upsert_blob_tx(
            &tx,
            &thumb_key,
            &blobs.thumb_hash,
            &blobs.thumbnail,
            &blobs.mime,
            blobs.thumb_edge,
            blobs.thumb_edge,
            now_unix_secs,
        )?;

        // Inc new refcounts before dec'ing old ones (same ordering rationale as
        // `upsert_avatar_assignment`).
        Self::inc_refcount_tx(&tx, &canonical_key)?;
        Self::inc_refcount_tx(&tx, &thumb_key)?;

        tx.execute(
            "INSERT INTO avatar_assignments \
               (circle_id, member_pubkey, canonical_key, thumb_key, version, \
                sender_epoch, source, updated_at) \
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'received', ?7) \
             ON CONFLICT(circle_id, member_pubkey) DO UPDATE SET \
                canonical_key = excluded.canonical_key, \
                thumb_key     = excluded.thumb_key, \
                version       = excluded.version, \
                sender_epoch  = excluded.sender_epoch, \
                source        = excluded.source, \
                updated_at    = excluded.updated_at",
            params![
                circle_id,
                sender_pubkey,
                &canonical_key[..],
                &thumb_key[..],
                version,
                sender_epoch,
                now_unix_secs,
            ],
        )?;

        if let Some((old_canon, old_thumb, _, _)) = existing {
            Self::dec_refcount_and_gc_tx(&tx, &old_canon)?;
            Self::dec_refcount_and_gc_tx(&tx, &old_thumb)?;
        }

        tx.commit()?;
        Ok(true)
    }

    /// Returns the stored `(version, sender_epoch)` for `(circle_id,
    /// member_pubkey)`, or `None`.
    ///
    /// # Errors
    ///
    /// As [`Self::set_own_avatar`].
    pub fn avatar_assignment_version_epoch(
        &self,
        circle_id: &[u8],
        member_pubkey: &str,
    ) -> Result<Option<(i64, i64)>> {
        let conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        conn.query_row(
            "SELECT version, sender_epoch FROM avatar_assignments \
             WHERE circle_id = ?1 AND member_pubkey = ?2",
            params![circle_id, member_pubkey],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()
        .map_err(Into::into)
    }

    /// Core upsert: stores `blobs` and (re)points the `(circle_id,
    /// member_pubkey)` assignment at them, bumping the version, all atomically.
    ///
    /// `source` is `'local'` or `'received'`; `sender_epoch` is the MLS epoch
    /// the avatar was built under (0 for a local own-avatar in M1).
    ///
    /// # Errors
    ///
    /// As [`Self::set_own_avatar`].
    pub fn upsert_avatar_assignment(
        &self,
        circle_id: &[u8],
        member_pubkey: &str,
        blobs: &AvatarBlobs,
        source: &str,
        sender_epoch: i64,
        now_unix_secs: i64,
    ) -> Result<i64> {
        // For M1 the blob_key == content_hash (empty salt, DEC-6). The salt
        // plumbing lands in M2 where per-circle salts make blob_key differ.
        let canonical_key: &[u8] = &blobs.content_hash;
        let thumb_key: &[u8] = &blobs.thumb_hash;

        let mut conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        let tx = conn.transaction()?;

        // 1. Upsert the two blobs (idempotent on content). New rows start at
        //    refcount 0; the assignment step increments.
        Self::upsert_blob_tx(
            &tx,
            canonical_key,
            &blobs.content_hash,
            &blobs.canonical,
            &blobs.mime,
            blobs.width,
            blobs.width,
            now_unix_secs,
        )?;
        Self::upsert_blob_tx(
            &tx,
            thumb_key,
            &blobs.thumb_hash,
            &blobs.thumbnail,
            &blobs.mime,
            blobs.thumb_edge,
            blobs.thumb_edge,
            now_unix_secs,
        )?;

        // 2. Read any existing assignment so we can (a) compute next version
        //    and (b) decrement the refcounts of the blobs it referenced.
        let existing: Option<(Vec<u8>, Vec<u8>, i64)> = tx
            .query_row(
                "SELECT canonical_key, thumb_key, version FROM avatar_assignments \
                 WHERE circle_id = ?1 AND member_pubkey = ?2",
                params![circle_id, member_pubkey],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .optional()?;

        let next_version = existing.as_ref().map_or(1, |(_, _, v)| v + 1);

        // 3. Increment refcounts for the new blobs FIRST, so that if the new
        //    keys equal the old keys (same image re-set) the subsequent
        //    decrement cannot transiently drop them to 0 and GC them.
        Self::inc_refcount_tx(&tx, canonical_key)?;
        Self::inc_refcount_tx(&tx, thumb_key)?;

        // 4. Upsert the assignment so it now points at the NEW blobs. This must
        //    happen BEFORE GC'ing the old blobs, otherwise SQLite's foreign-key
        //    check fires when an old blob is deleted while the (not-yet-updated)
        //    assignment still references it.
        tx.execute(
            "INSERT INTO avatar_assignments \
               (circle_id, member_pubkey, canonical_key, thumb_key, version, \
                sender_epoch, source, updated_at) \
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8) \
             ON CONFLICT(circle_id, member_pubkey) DO UPDATE SET \
                canonical_key = excluded.canonical_key, \
                thumb_key     = excluded.thumb_key, \
                version       = excluded.version, \
                sender_epoch  = excluded.sender_epoch, \
                source        = excluded.source, \
                updated_at    = excluded.updated_at",
            params![
                circle_id,
                member_pubkey,
                canonical_key,
                thumb_key,
                next_version,
                sender_epoch,
                source,
                now_unix_secs,
            ],
        )?;

        // 5. Now that the assignment references the new blobs, decrement the
        //    refcounts of the previously-referenced blobs and GC any that hit 0.
        if let Some((old_canon, old_thumb, _)) = existing {
            Self::dec_refcount_and_gc_tx(&tx, &old_canon)?;
            Self::dec_refcount_and_gc_tx(&tx, &old_thumb)?;
        }

        tx.commit()?;
        Ok(next_version)
    }

    /// Returns the thumbnail bytes for `(circle_id, member_pubkey)`, or `None`
    /// if there is no assignment / blob.
    ///
    /// # Errors
    ///
    /// As [`Self::set_own_avatar`].
    pub fn get_avatar_thumbnail(
        &self,
        circle_id: &[u8],
        member_pubkey: &str,
    ) -> Result<Option<Zeroizing<Vec<u8>>>> {
        self.get_avatar_bytes(circle_id, member_pubkey, AvatarTier::Thumbnail)
    }

    /// Returns the canonical (full-res) bytes for `(circle_id,
    /// member_pubkey)`, or `None`.
    ///
    /// # Errors
    ///
    /// As [`Self::set_own_avatar`].
    pub fn get_avatar_canonical(
        &self,
        circle_id: &[u8],
        member_pubkey: &str,
    ) -> Result<Option<Zeroizing<Vec<u8>>>> {
        self.get_avatar_bytes(circle_id, member_pubkey, AvatarTier::Canonical)
    }

    /// Returns assignment metadata (no bytes) for `(circle_id, member_pubkey)`.
    ///
    /// # Errors
    ///
    /// As [`Self::set_own_avatar`].
    pub fn get_avatar_meta(
        &self,
        circle_id: &[u8],
        member_pubkey: &str,
    ) -> Result<Option<AvatarAssignmentMeta>> {
        let conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        conn.query_row(
            "SELECT b.content_hash, b.mime, b.width, b.height, a.version \
             FROM avatar_assignments a \
             JOIN avatar_blobs b ON b.blob_key = a.canonical_key \
             WHERE a.circle_id = ?1 AND a.member_pubkey = ?2",
            params![circle_id, member_pubkey],
            |row| {
                let hash: Vec<u8> = row.get(0)?;
                let mime: String = row.get(1)?;
                let width: i64 = row.get(2)?;
                let height: i64 = row.get(3)?;
                let version: i64 = row.get(4)?;
                Ok((hash, mime, width, height, version))
            },
        )
        .optional()?
        .map(|(hash, mime, width, height, version)| {
            let content_hash: [u8; 32] = hash.try_into().map_err(|_| {
                CircleError::InvalidData("stored content_hash is not 32 bytes".to_string())
            })?;
            Ok(AvatarAssignmentMeta {
                content_hash,
                mime,
                #[allow(clippy::cast_sign_loss, clippy::cast_possible_truncation)]
                width: width as u32,
                #[allow(clippy::cast_sign_loss, clippy::cast_possible_truncation)]
                height: height as u32,
                version,
            })
        })
        .transpose()
    }

    /// Removes the assignment for `(circle_id, member_pubkey)` and GCs any blob
    /// whose refcount thereby reaches 0. No-op if no assignment exists.
    ///
    /// # Errors
    ///
    /// As [`Self::set_own_avatar`].
    pub fn clear_avatar_assignment(&self, circle_id: &[u8], member_pubkey: &str) -> Result<()> {
        let mut conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        let tx = conn.transaction()?;
        Self::remove_assignment_tx(&tx, circle_id, member_pubkey)?;
        tx.commit()?;
        Ok(())
    }

    /// Clears the user's OWN avatar (assignment under the empty sentinel) and
    /// GCs orphaned blobs.
    ///
    /// # Errors
    ///
    /// As [`Self::set_own_avatar`].
    pub fn clear_own_avatar(&self, own_pubkey: &str) -> Result<()> {
        self.clear_avatar_assignment(OWN_AVATAR_CIRCLE_ID, own_pubkey)
    }

    /// Purges a single member's avatar in one circle (member removal).
    /// Mirrors `remove_last_known_member`.
    ///
    /// # Errors
    ///
    /// As [`Self::set_own_avatar`].
    pub fn remove_member_avatar(&self, circle_id: &[u8], member_pubkey: &str) -> Result<()> {
        self.clear_avatar_assignment(circle_id, member_pubkey)
    }

    /// Purges every avatar assignment for a circle (circle leave/delete).
    /// Mirrors `remove_last_known_circle`. GCs orphaned blobs.
    ///
    /// Also drops the circle's per-circle DEC-6 salt: that row is keyed by the
    /// REAL MLS group id, so leaving it behind would let a forensic attacker who
    /// decrypts circles.db recover the group id (and count) of every LEFT
    /// circle. The salt is purged inside the SAME transaction as the assignments
    /// so a mid-purge failure cannot leave the salt orphaned.
    ///
    /// # Errors
    ///
    /// As [`Self::set_own_avatar`].
    pub fn remove_circle_avatars(&self, circle_id: &[u8]) -> Result<()> {
        let mut conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        let tx = conn.transaction()?;

        let members: Vec<String> = {
            let mut stmt =
                tx.prepare("SELECT member_pubkey FROM avatar_assignments WHERE circle_id = ?1")?;
            let rows = stmt
                .query_map(params![circle_id], |row| row.get::<_, String>(0))?
                .collect::<std::result::Result<Vec<_>, _>>()?;
            rows
        };
        for member in &members {
            Self::remove_assignment_tx(&tx, circle_id, member)?;
        }
        // Purge the per-circle salt so the (real) MLS group id of a left circle
        // does not linger at rest. A single member leaving must NOT do this —
        // see `remove_member_avatar` — but a whole-circle purge must.
        tx.execute(
            "DELETE FROM circle_salts WHERE circle_id = ?1",
            params![circle_id],
        )?;
        tx.commit()?;
        Ok(())
    }

    /// Wipes ALL avatar assignments and blobs (account wipe). Mirrors
    /// `wipe_all_last_known_locations`.
    ///
    /// Also drops every per-circle DEC-6 salt: those rows are keyed by the REAL
    /// MLS group id, so an account wipe that left them would let a forensic
    /// attacker who decrypts circles.db recover the group ids (and count) of the
    /// wiped account's circles.
    ///
    /// # Errors
    ///
    /// As [`Self::set_own_avatar`].
    pub fn wipe_all_avatars(&self) -> Result<()> {
        let mut conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        let tx = conn.transaction()?;
        tx.execute("DELETE FROM avatar_assignments", [])?;
        tx.execute("DELETE FROM avatar_blobs", [])?;
        tx.execute("DELETE FROM circle_salts", [])?;
        tx.commit()?;
        Ok(())
    }

    /// Test-only: clears the entire avatar store for test isolation.
    ///
    /// # Errors
    ///
    /// As [`Self::set_own_avatar`].
    #[cfg(debug_assertions)]
    pub fn clear_avatar_store(&self) -> Result<()> {
        self.wipe_all_avatars()
    }

    /// Test helper: returns the current refcount of a blob, or `None` if the
    /// blob row no longer exists (i.e. it was GC'd).
    #[cfg(test)]
    pub(crate) fn avatar_blob_refcount(&self, blob_key: &[u8]) -> Result<Option<i64>> {
        let conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        conn.query_row(
            "SELECT refcount FROM avatar_blobs WHERE blob_key = ?1",
            params![blob_key],
            |row| row.get::<_, i64>(0),
        )
        .optional()
        .map_err(Into::into)
    }

    /// Test helper: counts blob rows.
    #[cfg(test)]
    pub(crate) fn avatar_blob_count(&self) -> Result<i64> {
        let conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        conn.query_row("SELECT COUNT(*) FROM avatar_blobs", [], |row| row.get(0))
            .map_err(Into::into)
    }

    /// Test helper: counts `circle_salts` rows for `circle_id`.
    #[cfg(test)]
    pub(crate) fn circle_salt_count(&self, circle_id: &[u8]) -> Result<i64> {
        let conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        conn.query_row(
            "SELECT COUNT(*) FROM circle_salts WHERE circle_id = ?1",
            params![circle_id],
            |row| row.get(0),
        )
        .map_err(Into::into)
    }

    /// Test helper: counts ALL `circle_salts` rows.
    #[cfg(test)]
    pub(crate) fn circle_salt_total_count(&self) -> Result<i64> {
        let conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        conn.query_row("SELECT COUNT(*) FROM circle_salts", [], |row| row.get(0))
            .map_err(Into::into)
    }

    // ---- private transaction helpers (all take an active &Transaction) ----

    /// Shared body for thumbnail/canonical reads.
    fn get_avatar_bytes(
        &self,
        circle_id: &[u8],
        member_pubkey: &str,
        tier: AvatarTier,
    ) -> Result<Option<Zeroizing<Vec<u8>>>> {
        let key_col = match tier {
            AvatarTier::Thumbnail => "thumb_key",
            AvatarTier::Canonical => "canonical_key",
        };
        let conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        let sql = format!(
            "SELECT b.bytes FROM avatar_assignments a \
             JOIN avatar_blobs b ON b.blob_key = a.{key_col} \
             WHERE a.circle_id = ?1 AND a.member_pubkey = ?2"
        );
        let bytes: Option<Vec<u8>> = conn
            .query_row(&sql, params![circle_id, member_pubkey], |row| row.get(0))
            .optional()?;
        Ok(bytes.map(Zeroizing::new))
    }

    /// Inserts or no-op-updates a blob row (content-addressed; idempotent).
    /// Does not change refcount.
    #[allow(clippy::too_many_arguments)]
    fn upsert_blob_tx(
        tx: &rusqlite::Transaction<'_>,
        blob_key: &[u8],
        content_hash: &[u8],
        bytes: &[u8],
        mime: &str,
        width: u32,
        height: u32,
        now_unix_secs: i64,
    ) -> Result<()> {
        tx.execute(
            "INSERT INTO avatar_blobs \
               (blob_key, content_hash, bytes, mime, width, height, byte_len, refcount, created_at) \
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 0, ?8) \
             ON CONFLICT(blob_key) DO NOTHING",
            params![
                blob_key,
                content_hash,
                bytes,
                mime,
                i64::from(width),
                i64::from(height),
                i64::try_from(bytes.len()).unwrap_or(i64::MAX),
                now_unix_secs,
            ],
        )?;
        Ok(())
    }

    fn inc_refcount_tx(tx: &rusqlite::Transaction<'_>, blob_key: &[u8]) -> Result<()> {
        tx.execute(
            "UPDATE avatar_blobs SET refcount = refcount + 1 WHERE blob_key = ?1",
            params![blob_key],
        )?;
        Ok(())
    }

    /// Decrements a blob's refcount, clamping at 0, and deletes the row if the
    /// refcount reaches 0 (GC).
    fn dec_refcount_and_gc_tx(tx: &rusqlite::Transaction<'_>, blob_key: &[u8]) -> Result<()> {
        // Clamp at 0 so a logic bug cannot drive the count negative.
        tx.execute(
            "UPDATE avatar_blobs SET refcount = MAX(refcount - 1, 0) WHERE blob_key = ?1",
            params![blob_key],
        )?;
        tx.execute(
            "DELETE FROM avatar_blobs WHERE blob_key = ?1 AND refcount <= 0",
            params![blob_key],
        )?;
        Ok(())
    }

    /// Removes one assignment and decrements/GCs the blobs it referenced.
    fn remove_assignment_tx(
        tx: &rusqlite::Transaction<'_>,
        circle_id: &[u8],
        member_pubkey: &str,
    ) -> Result<()> {
        let existing: Option<(Vec<u8>, Vec<u8>)> = tx
            .query_row(
                "SELECT canonical_key, thumb_key FROM avatar_assignments \
                 WHERE circle_id = ?1 AND member_pubkey = ?2",
                params![circle_id, member_pubkey],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()?;

        let Some((canon, thumb)) = existing else {
            return Ok(());
        };

        tx.execute(
            "DELETE FROM avatar_assignments WHERE circle_id = ?1 AND member_pubkey = ?2",
            params![circle_id, member_pubkey],
        )?;
        Self::dec_refcount_and_gc_tx(tx, &canon)?;
        Self::dec_refcount_and_gc_tx(tx, &thumb)?;
        Ok(())
    }
}

/// Which size tier to read.
#[derive(Clone, Copy)]
enum AvatarTier {
    Thumbnail,
    Canonical,
}

#[cfg(test)]
mod tests {
    use super::*;
    use sha2::{Digest, Sha256};

    fn hash(bytes: &[u8]) -> [u8; 32] {
        Sha256::digest(bytes).into()
    }

    /// Builds an `AvatarBlobs` from raw canonical/thumb bytes (tests don't run
    /// the real image pipeline; they only exercise storage semantics).
    fn blobs(canonical: &[u8], thumbnail: &[u8]) -> AvatarBlobs {
        AvatarBlobs {
            canonical: Zeroizing::new(canonical.to_vec()),
            thumbnail: Zeroizing::new(thumbnail.to_vec()),
            content_hash: hash(canonical),
            thumb_hash: hash(thumbnail),
            mime: "image/jpeg".to_string(),
            width: 512,
            thumb_edge: 96,
        }
    }

    #[test]
    fn set_and_get_own_avatar_round_trip() {
        let storage = CircleStorage::in_memory().unwrap();
        let b = blobs(b"canonical-bytes", b"thumb-bytes");
        let version = storage.set_own_avatar("mypub", &b, 1000).unwrap();
        assert_eq!(version, 1);

        let canon = storage
            .get_avatar_canonical(OWN_AVATAR_CIRCLE_ID, "mypub")
            .unwrap()
            .expect("canonical present");
        assert_eq!(&*canon, b"canonical-bytes");

        let thumb = storage
            .get_avatar_thumbnail(OWN_AVATAR_CIRCLE_ID, "mypub")
            .unwrap()
            .expect("thumb present");
        assert_eq!(&*thumb, b"thumb-bytes");

        let meta = storage
            .get_avatar_meta(OWN_AVATAR_CIRCLE_ID, "mypub")
            .unwrap()
            .expect("meta present");
        assert_eq!(meta.content_hash, hash(b"canonical-bytes"));
        assert_eq!(meta.mime, "image/jpeg");
        assert_eq!(meta.width, 512);
        assert_eq!(meta.version, 1);
    }

    #[test]
    fn missing_avatar_returns_none() {
        let storage = CircleStorage::in_memory().unwrap();
        assert!(storage
            .get_avatar_thumbnail(OWN_AVATAR_CIRCLE_ID, "nobody")
            .unwrap()
            .is_none());
        assert!(storage
            .get_avatar_canonical(&[1, 2, 3], "nobody")
            .unwrap()
            .is_none());
        assert!(storage
            .get_avatar_meta(OWN_AVATAR_CIRCLE_ID, "nobody")
            .unwrap()
            .is_none());
    }

    #[test]
    fn refcount_increments_on_assign() {
        let storage = CircleStorage::in_memory().unwrap();
        let b = blobs(b"canon", b"thumb");
        storage.set_own_avatar("mypub", &b, 1000).unwrap();
        // Both blobs referenced exactly once.
        assert_eq!(
            storage.avatar_blob_refcount(&b.content_hash).unwrap(),
            Some(1)
        );
        assert_eq!(
            storage.avatar_blob_refcount(&b.thumb_hash).unwrap(),
            Some(1)
        );
        assert_eq!(storage.avatar_blob_count().unwrap(), 2);
    }

    #[test]
    fn shared_blob_refcount_across_two_members() {
        let storage = CircleStorage::in_memory().unwrap();
        let b = blobs(b"shared-canon", b"shared-thumb");
        // Same image assigned to two members in the same circle.
        storage
            .upsert_avatar_assignment(&[7; 4], "alice", &b, "received", 3, 1000)
            .unwrap();
        storage
            .upsert_avatar_assignment(&[7; 4], "bob", &b, "received", 3, 1001)
            .unwrap();
        // Two assignments share the same two blobs → refcount 2 each.
        assert_eq!(
            storage.avatar_blob_refcount(&b.content_hash).unwrap(),
            Some(2)
        );
        assert_eq!(storage.avatar_blob_count().unwrap(), 2);

        // Clearing one assignment decrements but does NOT GC the still-shared
        // blob.
        storage.clear_avatar_assignment(&[7; 4], "alice").unwrap();
        assert_eq!(
            storage.avatar_blob_refcount(&b.content_hash).unwrap(),
            Some(1)
        );
        assert_eq!(storage.avatar_blob_count().unwrap(), 2);

        // Clearing the last assignment GCs both blobs.
        storage.clear_avatar_assignment(&[7; 4], "bob").unwrap();
        assert_eq!(storage.avatar_blob_refcount(&b.content_hash).unwrap(), None);
        assert_eq!(storage.avatar_blob_count().unwrap(), 0);
    }

    #[test]
    fn replacing_own_avatar_gcs_old_blob_and_bumps_version() {
        let storage = CircleStorage::in_memory().unwrap();
        let old = blobs(b"old-canon", b"old-thumb");
        let new = blobs(b"new-canon", b"new-thumb");

        let v1 = storage.set_own_avatar("mypub", &old, 1000).unwrap();
        assert_eq!(v1, 1);
        let v2 = storage.set_own_avatar("mypub", &new, 2000).unwrap();
        assert_eq!(v2, 2);

        // Old blobs GC'd, new blobs present.
        assert_eq!(
            storage.avatar_blob_refcount(&old.content_hash).unwrap(),
            None
        );
        assert_eq!(
            storage.avatar_blob_refcount(&new.content_hash).unwrap(),
            Some(1)
        );
        assert_eq!(storage.avatar_blob_count().unwrap(), 2);

        let got = storage
            .get_avatar_canonical(OWN_AVATAR_CIRCLE_ID, "mypub")
            .unwrap()
            .unwrap();
        assert_eq!(&*got, b"new-canon");
    }

    #[test]
    fn re_setting_identical_image_does_not_gc_it() {
        // Regression guard for the inc-before-dec ordering: re-setting the same
        // image must not transiently drop the blob to refcount 0 and GC it.
        let storage = CircleStorage::in_memory().unwrap();
        let b = blobs(b"same-canon", b"same-thumb");
        storage.set_own_avatar("mypub", &b, 1000).unwrap();
        storage.set_own_avatar("mypub", &b, 2000).unwrap();
        assert_eq!(
            storage.avatar_blob_refcount(&b.content_hash).unwrap(),
            Some(1),
            "re-setting the same image keeps refcount at 1"
        );
        assert!(storage
            .get_avatar_canonical(OWN_AVATAR_CIRCLE_ID, "mypub")
            .unwrap()
            .is_some());
    }

    #[test]
    fn clear_own_avatar_removes_assignment_and_gcs() {
        let storage = CircleStorage::in_memory().unwrap();
        let b = blobs(b"c", b"t");
        storage.set_own_avatar("mypub", &b, 1000).unwrap();
        storage.clear_own_avatar("mypub").unwrap();

        assert!(storage
            .get_avatar_thumbnail(OWN_AVATAR_CIRCLE_ID, "mypub")
            .unwrap()
            .is_none());
        assert_eq!(storage.avatar_blob_count().unwrap(), 0);
        // Idempotent: clearing again is a no-op.
        storage.clear_own_avatar("mypub").unwrap();
    }

    #[test]
    fn remove_member_avatar_purges_one_member_only() {
        let storage = CircleStorage::in_memory().unwrap();
        let a = blobs(b"a-canon", b"a-thumb");
        let b = blobs(b"b-canon", b"b-thumb");
        storage
            .upsert_avatar_assignment(&[9; 4], "alice", &a, "received", 1, 1000)
            .unwrap();
        storage
            .upsert_avatar_assignment(&[9; 4], "bob", &b, "received", 1, 1000)
            .unwrap();

        storage.remove_member_avatar(&[9; 4], "alice").unwrap();
        assert!(storage
            .get_avatar_thumbnail(&[9; 4], "alice")
            .unwrap()
            .is_none());
        assert!(storage
            .get_avatar_thumbnail(&[9; 4], "bob")
            .unwrap()
            .is_some());
        assert_eq!(storage.avatar_blob_refcount(&a.content_hash).unwrap(), None);
        assert_eq!(
            storage.avatar_blob_refcount(&b.content_hash).unwrap(),
            Some(1)
        );
    }

    #[test]
    fn remove_circle_avatars_purges_all_members_in_circle() {
        let storage = CircleStorage::in_memory().unwrap();
        let a = blobs(b"ca", b"ta");
        let b = blobs(b"cb", b"tb");
        storage
            .upsert_avatar_assignment(&[3; 4], "alice", &a, "received", 1, 1000)
            .unwrap();
        storage
            .upsert_avatar_assignment(&[3; 4], "bob", &b, "received", 1, 1000)
            .unwrap();
        // A member in a DIFFERENT circle must survive.
        storage
            .upsert_avatar_assignment(&[4; 4], "carol", &a, "received", 1, 1000)
            .unwrap();

        // Seed a per-circle salt for the circle being purged AND a different
        // circle whose salt must survive.
        let _ = storage.circle_avatar_salt(&[3; 4]).unwrap();
        let _ = storage.circle_avatar_salt(&[4; 4]).unwrap();
        assert_eq!(storage.circle_salt_count(&[3; 4]).unwrap(), 1);

        storage.remove_circle_avatars(&[3; 4]).unwrap();
        assert!(storage
            .get_avatar_thumbnail(&[3; 4], "alice")
            .unwrap()
            .is_none());
        assert!(storage
            .get_avatar_thumbnail(&[3; 4], "bob")
            .unwrap()
            .is_none());
        // Carol's assignment (sharing blob `a`) survives, so blob `a` is still
        // referenced; blob `b` is GC'd.
        assert!(storage
            .get_avatar_thumbnail(&[4; 4], "carol")
            .unwrap()
            .is_some());
        assert_eq!(
            storage.avatar_blob_refcount(&a.content_hash).unwrap(),
            Some(1)
        );
        assert_eq!(storage.avatar_blob_refcount(&b.content_hash).unwrap(), None);

        // Privacy: the purged circle's salt (keyed by the real MLS group id)
        // must be gone, but a different circle's salt must remain.
        assert_eq!(
            storage.circle_salt_count(&[3; 4]).unwrap(),
            0,
            "leaving a circle must purge its per-circle salt"
        );
        assert_eq!(
            storage.circle_salt_count(&[4; 4]).unwrap(),
            1,
            "a different circle's salt must survive"
        );
    }

    #[test]
    fn wipe_all_avatars_clears_everything() {
        let storage = CircleStorage::in_memory().unwrap();
        let a = blobs(b"x", b"y");
        storage.set_own_avatar("mypub", &a, 1000).unwrap();
        storage
            .upsert_avatar_assignment(&[1; 4], "alice", &a, "received", 1, 1000)
            .unwrap();
        // Seed salts for two distinct circles; the account wipe must clear both.
        let _ = storage.circle_avatar_salt(&[1; 4]).unwrap();
        let _ = storage.circle_avatar_salt(&[2; 4]).unwrap();
        assert_eq!(storage.circle_salt_total_count().unwrap(), 2);

        storage.wipe_all_avatars().unwrap();
        assert_eq!(storage.avatar_blob_count().unwrap(), 0);
        assert!(storage
            .get_avatar_thumbnail(OWN_AVATAR_CIRCLE_ID, "mypub")
            .unwrap()
            .is_none());
        // Privacy: an account wipe must leave NO per-circle salts (which are
        // keyed by the real MLS group ids of the wiped account's circles).
        assert_eq!(
            storage.circle_salt_total_count().unwrap(),
            0,
            "account wipe must purge all per-circle salts"
        );
    }

    #[test]
    fn concurrent_assign_then_purge_ordering_keeps_refcount_sound() {
        // Sequential model of the assign+purge race: a blob shared by two
        // assignments must not be GC'd while one assignment still references
        // it, regardless of which order the purges happen.
        let storage = CircleStorage::in_memory().unwrap();
        let shared = blobs(b"shared", b"shared-thumb");
        storage
            .upsert_avatar_assignment(&[5; 4], "alice", &shared, "received", 1, 1000)
            .unwrap();
        storage
            .upsert_avatar_assignment(&[6; 4], "alice", &shared, "received", 1, 1000)
            .unwrap();
        assert_eq!(
            storage.avatar_blob_refcount(&shared.content_hash).unwrap(),
            Some(2)
        );

        // Purge circle 5 then assign circle 6's member a NEW image — the shared
        // blob must remain (still referenced by circle 6's old assignment until
        // it is replaced).
        storage.remove_circle_avatars(&[5; 4]).unwrap();
        assert_eq!(
            storage.avatar_blob_refcount(&shared.content_hash).unwrap(),
            Some(1)
        );

        let replacement = blobs(b"replacement", b"replacement-thumb");
        storage
            .upsert_avatar_assignment(&[6; 4], "alice", &replacement, "received", 2, 2000)
            .unwrap();
        // Now the shared blob is fully unreferenced and GC'd.
        assert_eq!(
            storage.avatar_blob_refcount(&shared.content_hash).unwrap(),
            None
        );
        assert_eq!(
            storage
                .avatar_blob_refcount(&replacement.content_hash)
                .unwrap(),
            Some(1)
        );
    }

    #[test]
    fn clear_avatar_store_test_helper_wipes() {
        let storage = CircleStorage::in_memory().unwrap();
        let a = blobs(b"a", b"b");
        storage.set_own_avatar("mypub", &a, 1000).unwrap();
        storage.clear_avatar_store().unwrap();
        assert_eq!(storage.avatar_blob_count().unwrap(), 0);
    }

    // ---- DEC-6 per-circle salt + received-avatar supersession (M2) ----

    #[test]
    fn circle_salt_is_stable_and_distinct_per_circle() {
        let storage = CircleStorage::in_memory().unwrap();
        let s1a = storage.circle_avatar_salt(&[1; 4]).unwrap();
        let s1b = storage.circle_avatar_salt(&[1; 4]).unwrap();
        let s2 = storage.circle_avatar_salt(&[2; 4]).unwrap();
        assert_eq!(*s1a, *s1b, "salt must be stable per circle");
        assert_ne!(*s1a, *s2, "salt must differ between circles");
    }

    #[test]
    fn two_circles_get_distinct_salts() {
        // DEC-6: distinct circle_ids must derive independent 32-byte salts so a
        // shared image cannot be correlated across circles.
        let storage = CircleStorage::in_memory().unwrap();
        let s_a = storage.circle_avatar_salt(&[0xAA; 4]).unwrap();
        let s_b = storage.circle_avatar_salt(&[0xBB; 4]).unwrap();
        assert_ne!(
            *s_a, *s_b,
            "two different circles must derive different salts"
        );
    }

    #[test]
    fn circle_salt_persists_byte_identical_across_db_reopen() {
        // The salt is local persistent state: the SAME circle_id must yield a
        // byte-identical salt after the database file is closed and reopened,
        // otherwise previously-stored salted blob keys would become
        // unreadable.
        let dir = tempfile::TempDir::new().unwrap();
        let db_path = dir.path().join("salt_persist.db");
        let circle_id = [0x7C; 4];

        let first = {
            let storage = CircleStorage::new(&db_path, None).expect("create db");
            *storage.circle_avatar_salt(&circle_id).unwrap()
        };

        let second = {
            let storage = CircleStorage::new(&db_path, None).expect("reopen db");
            *storage.circle_avatar_salt(&circle_id).unwrap()
        };

        assert_eq!(
            first, second,
            "the same circle's salt must be byte-identical across a DB reopen"
        );
    }

    #[test]
    fn stored_salt_with_wrong_length_is_rejected() {
        // A corrupted/tampered salt row that is not exactly 32 bytes must be
        // rejected as InvalidData rather than silently truncated/extended.
        let storage = CircleStorage::in_memory().unwrap();
        let circle_id: &[u8] = &[0x42; 4];
        {
            let conn = storage.conn().lock().unwrap();
            conn.execute(
                "INSERT INTO circle_salts (circle_id, salt, created_at) VALUES (?1, ?2, ?3)",
                params![circle_id, &[0u8; 16][..], 1000i64],
            )
            .unwrap();
        }
        let err = storage
            .circle_avatar_salt(circle_id)
            .expect_err("a non-32-byte stored salt must be rejected");
        assert!(
            matches!(err, CircleError::InvalidData(_)),
            "wrong-length salt must surface InvalidData, got {err:?}"
        );
    }

    #[test]
    fn remove_member_avatar_does_not_drop_circle_salt() {
        // A single member leaving must NOT purge the circle's salt — other
        // members remain and their salted blob keys must stay valid.
        let storage = CircleStorage::in_memory().unwrap();
        let cid: &[u8] = &[0x55; 4];
        let a = blobs(b"member-canon", b"member-thumb");
        storage
            .upsert_avatar_assignment(cid, "alice", &a, "received", 1, 1000)
            .unwrap();
        let _ = storage.circle_avatar_salt(cid).unwrap();
        assert_eq!(storage.circle_salt_count(cid).unwrap(), 1);

        storage.remove_member_avatar(cid, "alice").unwrap();

        assert_eq!(
            storage.circle_salt_count(cid).unwrap(),
            1,
            "a single member leaving must NOT drop the circle's shared salt"
        );
    }

    #[test]
    fn same_image_two_circles_yields_distinct_blob_keys() {
        // DEC-6: the same received image in two circles must NOT collide on a
        // single shared blob row (no cross-circle correlation).
        let storage = CircleStorage::in_memory().unwrap();
        let b = blobs(b"same-received-canon", b"same-received-thumb");
        assert!(storage
            .store_received_avatar(&[10; 4], "alice", &b, 1, 0, 1000)
            .unwrap());
        assert!(storage
            .store_received_avatar(&[11; 4], "alice", &b, 1, 0, 1000)
            .unwrap());
        // Two distinct salted blob rows for the canonical (and two for thumb).
        assert_eq!(storage.avatar_blob_count().unwrap(), 4);
        // Both circles read back the same bytes.
        assert_eq!(
            &*storage
                .get_avatar_canonical(&[10; 4], "alice")
                .unwrap()
                .unwrap(),
            b"same-received-canon"
        );
        assert_eq!(
            &*storage
                .get_avatar_canonical(&[11; 4], "alice")
                .unwrap()
                .unwrap(),
            b"same-received-canon"
        );
    }

    #[test]
    fn received_avatar_supersedes_only_on_higher_version_epoch() {
        let storage = CircleStorage::in_memory().unwrap();
        let v1 = blobs(b"v1-canon", b"v1-thumb");
        let v2 = blobs(b"v2-canon", b"v2-thumb");

        assert!(storage
            .store_received_avatar(&[20; 4], "bob", &v1, 1, 5, 1000)
            .unwrap());
        // Lower version → ignored.
        assert!(!storage
            .store_received_avatar(&[20; 4], "bob", &v2, 0, 9, 1001)
            .unwrap());
        assert_eq!(
            &*storage
                .get_avatar_canonical(&[20; 4], "bob")
                .unwrap()
                .unwrap(),
            b"v1-canon"
        );
        // Equal (version, epoch) → ignored (idempotent replay).
        assert!(!storage
            .store_received_avatar(&[20; 4], "bob", &v2, 1, 5, 1002)
            .unwrap());
        // Higher version → applied, old blob GC'd.
        assert!(storage
            .store_received_avatar(&[20; 4], "bob", &v2, 2, 5, 1003)
            .unwrap());
        assert_eq!(
            &*storage
                .get_avatar_canonical(&[20; 4], "bob")
                .unwrap()
                .unwrap(),
            b"v2-canon"
        );
        assert_eq!(
            storage
                .avatar_assignment_version_epoch(&[20; 4], "bob")
                .unwrap(),
            Some((2, 5))
        );
    }

    #[test]
    fn received_avatar_same_version_higher_epoch_supersedes() {
        let storage = CircleStorage::in_memory().unwrap();
        let a = blobs(b"epoch-a", b"epoch-at");
        let b = blobs(b"epoch-b", b"epoch-bt");
        assert!(storage
            .store_received_avatar(&[30; 4], "carol", &a, 4, 1, 1000)
            .unwrap());
        // Same version, higher epoch → supersedes.
        assert!(storage
            .store_received_avatar(&[30; 4], "carol", &b, 4, 2, 1001)
            .unwrap());
        assert_eq!(
            &*storage
                .get_avatar_canonical(&[30; 4], "carol")
                .unwrap()
                .unwrap(),
            b"epoch-b"
        );
    }
}
