//! The durable outbox behind local-first own-profile editing.
//!
//! A display-name or photo edit is written to the local cache immediately and
//! published later, so the edit itself has to survive the gap — process death,
//! an offline stretch, a relay that took the event and one that did not. These
//! methods extend [`CircleStorage`] with the `profile_sync_state` table that
//! remembers it, alongside the sibling `impl` blocks in
//! [`super::storage_profile`] (the kind-0 / picture cache) and
//! [`super::storage_relay_prefs`].
//!
//! # The versioning contract
//!
//! Every save bumps `local_version`. A publish reports back TWO coverage facts,
//! because "it published" and "every peer can read it" are different:
//!
//! * `published_version` — the newest version at least ONE relay acknowledged;
//! * `synced_version` — the newest version EVERY attempted relay acknowledged.
//!
//! So `pending = local_version > synced_version`, and a pending edit that has
//! already landed somewhere (`published_version >= local_version`) is
//! *partial* rather than unsent. A peer's relay-assignment salt is private to
//! their install, so a partial publish really is still the old name for
//! everyone assigned to a relay that refused it — reporting it as synced would
//! be the app claiming a network success it did not get.
//!
//! [`Self::commit_profile_sync`] is a compare-and-set on that counter: it may
//! only clear the pending set for the exact version it published. An edit saved
//! WHILE that publish was in flight therefore stays pending instead of being
//! silently reported as synced.
//!
//! # The row is never deleted
//!
//! Both destructive paths ([`CircleStorage::wipe_all_profiles`] and
//! [`Self::clear_profile_sync_state`]) RESET the row in place. Deleting it would
//! restart `local_version` at 0, so a save made afterwards would look older than
//! a publish recorded before it and the compare-and-set would clear a pending
//! edit it never published.

// Mirrors `storage.rs` / `storage_profile.rs`: each method acquires the
// connection lock once at the top and holds it for the whole operation.
#![allow(clippy::significant_drop_tightening)]

use nostr::{EventId, PublicKey};
use rusqlite::{params, Connection, OptionalExtension};

use super::error::{CircleError, Result};
use super::storage::CircleStorage;
use crate::avatar::StagedPicture;
use crate::profile::types::{CachedProfile, ProfileMetadata, ProfileState};
use crate::profile::{merge_edits, PendingEdits, PendingSnapshot, PROFILE_SYNC_BACKOFF_SECS};

/// What the UI may honestly say about the own profile right now.
///
/// Deliberately three independent facts rather than one enum: "there is
/// unpublished work", "that work has reached at least one relay" and "the
/// persisted backoff allows another attempt" are decided here, while how they
/// render is a UI concern.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ProfilePendingState {
    /// A save has not been fully acknowledged yet (`local > synced`).
    pub pending: bool,
    /// Pending, but already accepted by at least one relay for this version.
    pub partial: bool,
    /// The persisted retry ladder permits another attempt now.
    pub retry_due: bool,
}

/// Everything one successful own-profile publish must record, as a single
/// parameter object.
///
/// A struct rather than nine positional arguments: several of them are
/// same-typed integers whose transposition would silently corrupt the coverage
/// counters.
pub struct ProfileSyncCommit<'a> {
    /// The local user's identity pubkey. Its hex is the key for every profile
    /// row, derived here so the two can never disagree.
    pub pubkey: &'a PublicKey,
    /// The `local_version` this publish carried — the compare-and-set subject.
    pub published_version: i64,
    /// The metadata that was actually published.
    pub merged: &'a ProfileMetadata,
    /// The published kind-0's event id (for a future NIP-09 retraction).
    pub event_id: &'a EventId,
    /// The published kind-0's `created_at`, in Unix seconds.
    pub event_created_at: i64,
    /// The Blossom URL a staged picture was uploaded to, if one was.
    pub uploaded_picture_url: Option<&'a str>,
    /// Whether EVERY attempted relay acknowledged the event.
    pub fully_acked: bool,
    /// Injected clock, in Unix seconds.
    pub now: i64,
}

/// The backoff to apply after a sync that did not fully land, given the
/// attempts already recorded. Saturates on the last rung of
/// [`PROFILE_SYNC_BACKOFF_SECS`].
fn sync_backoff_secs(prior_attempts: i64) -> i64 {
    // The ladder is a non-empty compile-time constant, so `len() - 1` and the
    // subsequent index are both in range.
    let last = PROFILE_SYNC_BACKOFF_SECS.len().saturating_sub(1);
    let index = usize::try_from(prior_attempts.max(0))
        .unwrap_or(last)
        .min(last);
    PROFILE_SYNC_BACKOFF_SECS.get(index).copied().unwrap_or(0)
}

impl CircleStorage {
    /// Saves a display-name / bio edit LOCALLY and queues it for publication,
    /// returning the profile row the UI should render immediately.
    ///
    /// One transaction: the edit is merged onto the cached kind-0 row, folded
    /// into the accumulated pending set, and `local_version` is bumped.
    ///
    /// Neither `event_created_at` nor `fetched_at` advances on an existing row.
    /// `event_created_at` is the NIP-01 supersede floor — claiming a
    /// `created_at` no relay has seen would make the eventual republish tie or
    /// lose the replaceable-event race — and `fetched_at` is the staleness
    /// clock for RELAY reads, which a local save has told us nothing about. A
    /// brand-new row starts at `created_at = 0` (nothing published) with
    /// `fetched_at = now` and `state = Known`, because it does hold real
    /// content: the user's own edit.
    ///
    /// A save is an explicit user action, so it also RESETS the retry ladder —
    /// making a fresh edit wait out a backoff earned by an earlier failure
    /// would be the app quietly refusing to do what it was just told.
    ///
    /// # Errors
    ///
    /// Returns [`CircleError::Storage`] on lock poisoning and
    /// [`CircleError::Database`] on `SQLite` failure.
    pub fn stage_own_profile_edits(
        &self,
        pubkey_hex: &str,
        edits: &PendingEdits,
        now: i64,
    ) -> Result<CachedProfile> {
        let mut conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        let tx = conn.transaction()?;

        let existing = tx
            .query_row(
                "SELECT pubkey, metadata_json, state, event_created_at, fetched_at
                 FROM profiles WHERE pubkey = ?1",
                params![pubkey_hex],
                Self::map_profile_row,
            )
            .optional()?;

        let base = existing
            .as_ref()
            .map_or_else(ProfileMetadata::default, |row| row.metadata.clone());
        let row = CachedProfile {
            pubkey_hex: pubkey_hex.to_string(),
            metadata: merge_edits(&base, &edits.to_edits(None)),
            state: ProfileState::Known,
            event_created_at: existing.as_ref().map_or(0, |row| row.event_created_at),
            fetched_at: existing.as_ref().map_or(now, |row| row.fetched_at),
        };
        // The row the UI renders is the row that was STORED, sanitizer and all
        // — not the one assembled above.
        let row = Self::write_profile_row(&tx, &row)?;

        // Accumulate rather than replace: renaming and then editing the bio must
        // publish BOTH. A replace would drop the rename with no error anywhere.
        let accumulated = Self::read_raw_pending_edits(&tx, pubkey_hex)?.accumulate(edits);
        let edits_json = serde_json::to_string(&accumulated)
            .map_err(|e| CircleError::Storage(format!("Failed to encode pending edits: {e}")))?;
        tx.execute(
            "INSERT INTO profile_sync_state (pubkey, local_version, edits_json)
             VALUES (?1, 1, ?2)
             ON CONFLICT(pubkey) DO UPDATE SET
                local_version = local_version + 1,
                edits_json    = excluded.edits_json,
                sync_attempts = 0,
                next_retry_at = 0",
            params![pubkey_hex, edits_json],
        )?;

        tx.commit()?;
        Ok(row)
    }

    /// Saves sanitized own-picture bytes LOCALLY and queues them for upload.
    ///
    /// One transaction: the bytes are cached with an EMPTY `url` (the public URL
    /// does not exist until a Blossom upload succeeds — see
    /// [`Self::commit_profile_sync`], which re-stamps the row), the outbox marks
    /// a picture staged, `local_version` is bumped and the retry ladder is
    /// reset.
    ///
    /// Takes the sealed [`StagedPicture`] rather than loose slices: what lands
    /// in this row is exactly what a later sync PUTs to a public Blossom host,
    /// so the only way to reach it is to hold the sanitizer's own output.
    ///
    /// # Errors
    ///
    /// As [`Self::stage_own_profile_edits`].
    pub fn stage_own_profile_picture(
        &self,
        pubkey_hex: &str,
        picture: &StagedPicture,
        now: i64,
    ) -> Result<()> {
        let mut conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        let tx = conn.transaction()?;
        Self::write_profile_picture_row(
            &tx,
            pubkey_hex,
            "",
            picture.sha256(),
            picture.canonical(),
            picture.thumbnail(),
            now,
        )?;
        tx.execute(
            "INSERT INTO profile_sync_state (pubkey, local_version, picture_staged)
             VALUES (?1, 1, 1)
             ON CONFLICT(pubkey) DO UPDATE SET
                local_version  = local_version + 1,
                picture_staged = 1,
                sync_attempts  = 0,
                next_retry_at  = 0",
            params![pubkey_hex],
        )?;
        tx.commit()?;
        Ok(())
    }

    /// One consistent read of the outbox, or `None` when nothing is pending.
    ///
    /// # Errors
    ///
    /// As [`Self::stage_own_profile_edits`].
    pub fn pending_profile_sync(&self, pubkey_hex: &str) -> Result<Option<PendingSnapshot>> {
        let conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        let row: Option<(i64, i64, String, i64)> = conn
            .query_row(
                "SELECT local_version, synced_version, edits_json, picture_staged
                 FROM profile_sync_state WHERE pubkey = ?1",
                params![pubkey_hex],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
            )
            .optional()?;
        let Some((local_version, synced_version, edits_json, picture_staged)) = row else {
            return Ok(None);
        };
        if local_version <= synced_version {
            return Ok(None);
        }
        Ok(Some(PendingSnapshot {
            local_version,
            edits: decode_pending_edits(&edits_json),
            picture_staged: picture_staged != 0,
        }))
    }

    /// The three facts the UI needs about the own profile's publication state.
    ///
    /// A pubkey with no outbox row has never saved anything: nothing pending,
    /// nothing partial, and no backoff standing in the way of a future attempt.
    ///
    /// # Errors
    ///
    /// As [`Self::stage_own_profile_edits`].
    pub fn profile_pending_state(&self, pubkey_hex: &str, now: i64) -> Result<ProfilePendingState> {
        let conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        let row: Option<(i64, i64, i64, i64)> = conn
            .query_row(
                "SELECT local_version, synced_version, published_version, next_retry_at
                 FROM profile_sync_state WHERE pubkey = ?1",
                params![pubkey_hex],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
            )
            .optional()?;
        let Some((local, synced, published, next_retry_at)) = row else {
            return Ok(ProfilePendingState {
                pending: false,
                partial: false,
                retry_due: true,
            });
        };
        let pending = local > synced;
        Ok(ProfilePendingState {
            pending,
            partial: pending && published >= local,
            retry_due: now >= next_retry_at,
        })
    }

    /// Whether sanitized picture bytes are staged for upload for this pubkey.
    ///
    /// # Errors
    ///
    /// As [`Self::stage_own_profile_edits`].
    pub fn profile_picture_is_staged(&self, pubkey_hex: &str) -> Result<bool> {
        let conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        let staged: Option<i64> = conn
            .query_row(
                "SELECT picture_staged FROM profile_sync_state WHERE pubkey = ?1",
                params![pubkey_hex],
                |r| r.get(0),
            )
            .optional()?;
        Ok(staged.is_some_and(|flag| flag != 0))
    }

    /// Records a sync attempt that did not fully land, advancing the persisted
    /// retry ladder.
    ///
    /// Called for an upload failure, a publish failure, and a partial
    /// acknowledgement. A pubkey with no outbox row has nothing to retry, so
    /// this is a no-op for it rather than seeding one.
    ///
    /// # Errors
    ///
    /// As [`Self::stage_own_profile_edits`].
    pub fn record_profile_sync_attempt(&self, pubkey_hex: &str, now: i64) -> Result<()> {
        let conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        Self::write_sync_attempt_row(&conn, pubkey_hex, now)?;
        Ok(())
    }

    /// Records one successful own-profile publish: the metadata, the picture
    /// URL, the published-event row, and how far the publish's coverage got.
    ///
    /// One transaction, so the cache, the publication record and the coverage
    /// counters can never disagree about what was published. Every write goes
    /// through a `&Connection` helper rather than the public method that wraps
    /// it: the connection mutex is a plain `std::sync::Mutex` and re-entering it
    /// would deadlock, not block.
    ///
    /// The compare-and-set: `published_version` and (on a full acknowledgement)
    /// `synced_version` only ever move FORWARD, and the pending set is cleared
    /// only when the version that was published is still the newest one saved.
    /// A partial acknowledgement leaves the edit pending and advances the retry
    /// ladder instead, so an opportunistic re-publish paces itself.
    ///
    /// # Errors
    ///
    /// As [`Self::stage_own_profile_edits`].
    pub fn commit_profile_sync(&self, c: &ProfileSyncCommit<'_>) -> Result<()> {
        let pubkey_hex = c.pubkey.to_hex();
        let mut conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        let tx = conn.transaction()?;

        Self::write_profile_row(
            &tx,
            &CachedProfile {
                pubkey_hex: pubkey_hex.clone(),
                metadata: c.merged.clone(),
                state: ProfileState::Known,
                event_created_at: c.event_created_at,
                fetched_at: c.now,
            },
        )?;

        if let Some(url) = c.uploaded_picture_url {
            // Re-stamp the staged row (cached with an empty `url`) with the URL
            // the upload resolved to. The bytes are read back and rewritten
            // through the same single writer every other picture write uses.
            let staged: Option<(Vec<u8>, Vec<u8>, Vec<u8>)> = tx
                .query_row(
                    "SELECT sha256, canonical, thumbnail FROM profile_pictures WHERE pubkey = ?1",
                    params![pubkey_hex],
                    |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
                )
                .optional()?;
            if let Some((sha256, canonical, thumbnail)) = staged {
                Self::write_profile_picture_row(
                    &tx,
                    &pubkey_hex,
                    url,
                    &sha256,
                    &canonical,
                    &thumbnail,
                    c.now,
                )?;
            }
        }

        Self::write_published_event_row(&tx, 0, "", c.event_id, c.pubkey, c.now)?;

        if c.fully_acked {
            tx.execute(
                "UPDATE profile_sync_state SET
                    published_version = MAX(published_version, ?2),
                    synced_version    = MAX(synced_version, ?2),
                    edits_json     = CASE WHEN local_version = ?2 THEN '{}' ELSE edits_json END,
                    picture_staged = CASE WHEN local_version = ?2 THEN 0 ELSE picture_staged END,
                    sync_attempts     = 0,
                    next_retry_at     = 0
                 WHERE pubkey = ?1",
                params![pubkey_hex, c.published_version],
            )?;
        } else {
            tx.execute(
                "UPDATE profile_sync_state
                 SET published_version = MAX(published_version, ?2)
                 WHERE pubkey = ?1",
                params![pubkey_hex, c.published_version],
            )?;
            Self::write_sync_attempt_row(&tx, &pubkey_hex, c.now)?;
        }

        tx.commit()?;
        Ok(())
    }

    /// Cancels a STAGED picture upload and nothing else.
    ///
    /// The narrow sibling of [`Self::clear_profile_sync_state`], for "remove my
    /// photo": it drops the sanitized bytes queued for Blossom, but a queued
    /// display-name edit has nothing to do with the photo and must still
    /// publish. Cancelling the whole outbox here would discard that rename with
    /// no error anywhere.
    ///
    /// Only the STAGED (empty-`url`) row is deleted — a picture with a real URL
    /// is a published artefact, which the retraction republish is what removes.
    /// The version counters and the retry ladder are deliberately untouched:
    /// the bump the staging made stays pending, so the kind-0 that no longer
    /// names a picture still gets published.
    ///
    /// # Errors
    ///
    /// As [`Self::stage_own_profile_edits`].
    pub fn cancel_staged_profile_picture(&self, pubkey_hex: &str) -> Result<()> {
        let mut conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        let tx = conn.transaction()?;
        tx.execute(
            "DELETE FROM profile_pictures WHERE pubkey = ?1 AND url = ''",
            params![pubkey_hex],
        )?;
        tx.execute(
            "UPDATE profile_sync_state SET picture_staged = 0 WHERE pubkey = ?1",
            params![pubkey_hex],
        )?;
        tx.commit()?;
        Ok(())
    }

    /// Cancels everything pending for this pubkey — the retraction's "and stop
    /// trying to publish what I just deleted".
    ///
    /// Levels both coverage counters with `local_version` (so nothing is
    /// pending), empties the pending set, and drops STAGED picture bytes (the
    /// empty-`url` row); a picture with a real URL is a published artefact and
    /// is left to the retraction itself. The row is reset IN PLACE — see the
    /// module docs for why it is never deleted.
    ///
    /// # Errors
    ///
    /// As [`Self::stage_own_profile_edits`].
    pub fn clear_profile_sync_state(&self, pubkey_hex: &str) -> Result<()> {
        let mut conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        let tx = conn.transaction()?;
        Self::reset_profile_sync_rows(&tx, Some(pubkey_hex))?;
        tx.execute(
            "DELETE FROM profile_pictures WHERE pubkey = ?1 AND url = ''",
            params![pubkey_hex],
        )?;
        tx.commit()?;
        Ok(())
    }

    // ---- private / cross-module helpers ----

    /// The in-place reset shared by the retraction cancel (`Some(pubkey)`) and
    /// the wholesale profile wipe (`None` — every row).
    ///
    /// Keeping it in one statement is what stops the two paths from drifting
    /// into "one resets, the other deletes", which is the shape of the
    /// version-restart hazard the module docs describe.
    pub(super) fn reset_profile_sync_rows(
        conn: &Connection,
        pubkey_hex: Option<&str>,
    ) -> rusqlite::Result<()> {
        conn.execute(
            "UPDATE profile_sync_state SET
                edits_json        = '{}',
                picture_staged    = 0,
                synced_version    = local_version,
                published_version = local_version,
                sync_attempts     = 0,
                next_retry_at     = 0
             WHERE ?1 IS NULL OR pubkey = ?1",
            params![pubkey_hex],
        )?;
        Ok(())
    }

    /// The pending edits to re-apply over a freshly fetched kind-0, or `None`
    /// when there is nothing pending for this pubkey (always the case for a
    /// member — only the local user has an outbox row).
    pub(super) fn read_pending_edits(
        conn: &Connection,
        pubkey_hex: &str,
    ) -> rusqlite::Result<Option<PendingEdits>> {
        let row: Option<(i64, i64, String)> = conn
            .query_row(
                "SELECT local_version, synced_version, edits_json
                 FROM profile_sync_state WHERE pubkey = ?1",
                params![pubkey_hex],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .optional()?;
        let Some((local, synced, edits_json)) = row else {
            return Ok(None);
        };
        if local <= synced {
            return Ok(None);
        }
        let edits = decode_pending_edits(&edits_json);
        Ok((!edits.is_empty()).then_some(edits))
    }

    /// The accumulated pending set as stored, ignoring the version counters —
    /// the base a fresh save folds onto.
    fn read_raw_pending_edits(
        conn: &Connection,
        pubkey_hex: &str,
    ) -> rusqlite::Result<PendingEdits> {
        let edits_json: Option<String> = conn
            .query_row(
                "SELECT edits_json FROM profile_sync_state WHERE pubkey = ?1",
                params![pubkey_hex],
                |r| r.get(0),
            )
            .optional()?;
        Ok(edits_json
            .as_deref()
            .map_or_else(PendingEdits::default, decode_pending_edits))
    }

    /// Advances the retry ladder on an ALREADY-LOCKED connection.
    ///
    /// Read-then-write (rather than a SQL `CASE` ladder) keeps
    /// [`PROFILE_SYNC_BACKOFF_SECS`] as the single source of truth, exactly as
    /// the per-author miss ladder does.
    fn write_sync_attempt_row(
        conn: &Connection,
        pubkey_hex: &str,
        now: i64,
    ) -> rusqlite::Result<()> {
        let prior: Option<i64> = conn
            .query_row(
                "SELECT sync_attempts FROM profile_sync_state WHERE pubkey = ?1",
                params![pubkey_hex],
                |r| r.get(0),
            )
            .optional()?;
        let Some(prior) = prior.map(|attempts| attempts.max(0)) else {
            return Ok(());
        };
        let retry_at = now.saturating_add(sync_backoff_secs(prior));
        conn.execute(
            "UPDATE profile_sync_state SET sync_attempts = ?2, next_retry_at = ?3
             WHERE pubkey = ?1",
            params![pubkey_hex, prior.saturating_add(1), retry_at],
        )?;
        Ok(())
    }
}

/// Decodes a stored pending set, falling back to "nothing pending" on a value
/// that will not parse.
///
/// Only this module writes the column, so an unparseable value means
/// corruption. Failing the whole read would strand the outbox permanently;
/// treating it as empty costs the unpublished edit and lets the plane recover.
fn decode_pending_edits(edits_json: &str) -> PendingEdits {
    serde_json::from_str(edits_json).unwrap_or_else(|_| {
        log::warn!("profile outbox: pending edits were unreadable; treating as empty");
        PendingEdits::default()
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use nostr::{EventBuilder, Keys, Kind};

    fn storage() -> CircleStorage {
        CircleStorage::in_memory().expect("in-memory storage must initialize")
    }

    fn hex() -> String {
        "ab".repeat(32)
    }

    fn name_edit(display_name: &str) -> PendingEdits {
        PendingEdits {
            display_name: Some(display_name.to_string()),
            about: None,
        }
    }

    fn bio_edit(about: &str) -> PendingEdits {
        PendingEdits {
            display_name: None,
            about: Some(about.to_string()),
        }
    }

    /// A staged picture over arbitrary cache bytes. The content hash is
    /// recomputed by [`StagedPicture`] itself, so no test may pin one that
    /// disagrees with the bytes it travels with.
    fn staged(canonical: &[u8], thumbnail: &[u8]) -> StagedPicture {
        StagedPicture::from_sanitized_cache(canonical.to_vec(), thumbnail.to_vec())
    }

    /// A throwaway event used ONLY as an `.id` source. Its kind is irrelevant
    /// (the commit records kind 0 explicitly), so a non-kind-0 builder keeps
    /// kind-0 construction confined to `profile/` per the CI guard.
    fn any_event_id(keys: &Keys) -> EventId {
        EventBuilder::new(Kind::TextNote, "x")
            .sign_with_keys(keys)
            .expect("sign")
            .id
    }

    fn commit(
        storage: &CircleStorage,
        keys: &Keys,
        version: i64,
        fully_acked: bool,
        now: i64,
    ) -> Result<()> {
        let merged = ProfileMetadata::from_metadata(nostr::Metadata::new().display_name("Synced"));
        storage.commit_profile_sync(&ProfileSyncCommit {
            pubkey: &keys.public_key(),
            published_version: version,
            merged: &merged,
            event_id: &any_event_id(keys),
            event_created_at: now,
            uploaded_picture_url: None,
            fully_acked,
            now,
        })
    }

    /// The raw outbox columns, for assertions that must see the counters
    /// themselves rather than the derived state.
    fn raw(storage: &CircleStorage, pubkey_hex: &str) -> Option<(i64, i64, i64, i64, i64)> {
        let conn = storage.conn().lock().unwrap();
        conn.query_row(
            "SELECT local_version, synced_version, published_version, sync_attempts, next_retry_at
             FROM profile_sync_state WHERE pubkey = ?1",
            params![pubkey_hex],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)),
        )
        .optional()
        .unwrap()
    }

    // ---- staging -----------------------------------------------------------

    #[test]
    fn stage_own_profile_edits_returns_the_row_it_stored() {
        // The returned row is what the UI renders immediately after a save. If
        // it were the row as ASSEMBLED rather than the row as WRITTEN, a save
        // would render exactly the text the sanitizer had just rejected, and
        // the screen would silently correct itself on the next read.
        let storage = storage();
        let row = storage
            .stage_own_profile_edits(&hex(), &name_edit("Ada\u{202E}  Lovelace"), 100)
            .unwrap();

        assert_eq!(row.metadata.display_name(), Some("Ada Lovelace"));
        assert_eq!(
            storage.get_profile(&hex()).unwrap().unwrap().metadata,
            row.metadata,
            "returned row must equal the stored row"
        );
    }

    #[test]
    fn a_local_save_is_pending_and_renders_immediately() {
        let storage = storage();
        let row = storage
            .stage_own_profile_edits(&hex(), &name_edit("Alice"), 1_000)
            .expect("stage");
        assert_eq!(row.metadata.display_name(), Some("Alice"));
        assert_eq!(row.state, ProfileState::Known);
        // The cached row is what the UI reads back.
        let stored = storage.get_profile(&hex()).unwrap().expect("row written");
        assert_eq!(stored.metadata.display_name(), Some("Alice"));
        let snapshot = storage
            .pending_profile_sync(&hex())
            .unwrap()
            .expect("the save is pending");
        assert_eq!(snapshot.local_version, 1);
        assert_eq!(snapshot.edits, name_edit("Alice"));
        assert!(!snapshot.picture_staged);
    }

    #[test]
    fn a_local_save_advances_neither_created_at_nor_fetched_at() {
        // `event_created_at` is the NIP-01 supersede floor and `fetched_at` the
        // relay-staleness clock. A local save has learned nothing about either;
        // moving them would make the eventual republish tie the event it is
        // meant to supersede, and would suppress the next real refresh.
        let storage = storage();
        storage
            .upsert_profile(&CachedProfile {
                pubkey_hex: hex(),
                metadata: ProfileMetadata::default(),
                state: ProfileState::Known,
                event_created_at: 500,
                fetched_at: 600,
            })
            .unwrap();
        storage
            .stage_own_profile_edits(&hex(), &name_edit("Alice"), 9_000)
            .unwrap();
        let stored = storage.get_profile(&hex()).unwrap().unwrap();
        assert_eq!(stored.event_created_at, 500, "supersede floor must hold");
        assert_eq!(stored.fetched_at, 600, "staleness clock must not move");
    }

    #[test]
    fn a_first_save_seeds_a_zero_created_at_known_row() {
        let storage = storage();
        storage
            .stage_own_profile_edits(&hex(), &name_edit("Alice"), 1_000)
            .unwrap();
        let stored = storage.get_profile(&hex()).unwrap().unwrap();
        assert_eq!(stored.event_created_at, 0, "nothing has been published");
        assert_eq!(stored.fetched_at, 1_000);
        assert_eq!(stored.state, ProfileState::Known);
    }

    #[test]
    fn a_second_save_accumulates_rather_than_replacing() {
        let storage = storage();
        storage
            .stage_own_profile_edits(&hex(), &name_edit("Renamed"), 1_000)
            .unwrap();
        storage
            .stage_own_profile_edits(&hex(), &bio_edit("new bio"), 1_001)
            .unwrap();
        let snapshot = storage.pending_profile_sync(&hex()).unwrap().unwrap();
        assert_eq!(snapshot.local_version, 2);
        assert_eq!(snapshot.edits.display_name.as_deref(), Some("Renamed"));
        assert_eq!(snapshot.edits.about.as_deref(), Some("new bio"));
    }

    #[test]
    fn staged_picture_bytes_are_the_current_picture() {
        // The photo the user just chose must render right away, even though its
        // public URL does not exist yet and the cached kind-0 still points at
        // the old one (or nowhere).
        let storage = storage();
        storage
            .stage_own_profile_picture(&hex(), &staged(b"canonical", b"thumb"), 1_000)
            .unwrap();
        assert_eq!(
            &*storage.get_profile_picture(&hex()).unwrap().unwrap(),
            b"canonical"
        );
        assert_eq!(
            storage.get_profile_picture_url(&hex()).unwrap().as_deref(),
            Some(""),
            "a staged row carries no public URL",
        );
        assert!(storage.profile_picture_is_staged(&hex()).unwrap());
        assert!(
            storage.has_current_picture(&hex(), None).unwrap(),
            "staged bytes are current — the save must not blank the avatar",
        );
        assert!(
            storage
                .pending_profile_sync(&hex())
                .unwrap()
                .expect("staging queues work")
                .picture_staged
        );
    }

    #[test]
    fn a_save_resets_a_backoff_earned_by_an_earlier_failure() {
        let storage = storage();
        storage
            .stage_own_profile_edits(&hex(), &name_edit("Alice"), 1_000)
            .unwrap();
        storage.record_profile_sync_attempt(&hex(), 1_000).unwrap();
        storage.record_profile_sync_attempt(&hex(), 1_030).unwrap();
        assert!(
            !storage
                .profile_pending_state(&hex(), 1_031)
                .unwrap()
                .retry_due
        );

        storage
            .stage_own_profile_edits(&hex(), &name_edit("Alice v2"), 1_031)
            .unwrap();
        let state = storage.profile_pending_state(&hex(), 1_031).unwrap();
        assert!(state.pending);
        assert!(
            state.retry_due,
            "a fresh user action must not wait out an old failure's backoff",
        );
        assert_eq!(raw(&storage, &hex()).unwrap().3, 0, "attempts reset");
    }

    #[test]
    fn staging_a_picture_also_resets_the_backoff() {
        let storage = storage();
        storage
            .stage_own_profile_edits(&hex(), &name_edit("Alice"), 1_000)
            .unwrap();
        storage.record_profile_sync_attempt(&hex(), 1_000).unwrap();
        assert!(
            !storage
                .profile_pending_state(&hex(), 1_001)
                .unwrap()
                .retry_due
        );
        storage
            .stage_own_profile_picture(&hex(), &staged(b"c", b"t"), 1_001)
            .unwrap();
        assert!(
            storage
                .profile_pending_state(&hex(), 1_001)
                .unwrap()
                .retry_due
        );
    }

    // ---- the compare-and-set -----------------------------------------------

    #[test]
    fn committing_an_older_version_never_clears_a_newer_pending_edit() {
        // THE never-fake-success invariant: an edit saved WHILE a publish was in
        // flight must stay pending. Clearing it would report a version that was
        // never published as synced, and the user's newest name would silently
        // never reach a relay.
        let storage = storage();
        let keys = Keys::generate();
        let pubkey_hex = keys.public_key().to_hex();
        storage
            .stage_own_profile_edits(&pubkey_hex, &name_edit("v1"), 1_000)
            .unwrap();
        storage
            .stage_own_profile_edits(&pubkey_hex, &name_edit("v2"), 1_001)
            .unwrap();

        commit(&storage, &keys, 1, true, 1_002).expect("commit v1");

        let snapshot = storage
            .pending_profile_sync(&pubkey_hex)
            .unwrap()
            .expect("v2 is still pending");
        assert_eq!(snapshot.local_version, 2);
        assert_eq!(
            snapshot.edits.display_name.as_deref(),
            Some("v2"),
            "the in-flight save's edit must survive the older commit",
        );
        let (local, synced, published, _, _) = raw(&storage, &pubkey_hex).unwrap();
        assert_eq!((local, synced, published), (2, 1, 1));
    }

    #[test]
    fn a_full_ack_of_the_newest_version_clears_the_outbox() {
        let storage = storage();
        let keys = Keys::generate();
        let pubkey_hex = keys.public_key().to_hex();
        storage
            .stage_own_profile_edits(&pubkey_hex, &name_edit("Alice"), 1_000)
            .unwrap();
        commit(&storage, &keys, 1, true, 1_001).expect("commit");

        assert!(storage.pending_profile_sync(&pubkey_hex).unwrap().is_none());
        let state = storage.profile_pending_state(&pubkey_hex, 1_001).unwrap();
        assert!(!state.pending && !state.partial);
        // The published metadata and its real `created_at` replaced the staged row.
        let stored = storage.get_profile(&pubkey_hex).unwrap().unwrap();
        assert_eq!(stored.metadata.display_name(), Some("Synced"));
        assert_eq!(stored.event_created_at, 1_001);
        assert_eq!(raw(&storage, &pubkey_hex).unwrap().3, 0, "ladder reset");
    }

    #[test]
    fn a_partial_ack_keeps_the_edit_pending_and_records_its_coverage() {
        // Two of eight relays taking the event is still the OLD name for every
        // peer whose private assignment salt points them elsewhere, so this must
        // stay pending — but it is not "unsent" either, and the distinction is
        // what the UI reports honestly.
        let storage = storage();
        let keys = Keys::generate();
        let pubkey_hex = keys.public_key().to_hex();
        storage
            .stage_own_profile_edits(&pubkey_hex, &name_edit("Alice"), 1_000)
            .unwrap();
        commit(&storage, &keys, 1, false, 1_001).expect("commit");

        let state = storage.profile_pending_state(&pubkey_hex, 1_001).unwrap();
        assert!(state.pending, "a partial publish is not synced");
        assert!(state.partial, "but it HAS reached a relay");
        assert!(
            !state.retry_due,
            "and the retry ladder paces the opportunistic re-publish",
        );
        let (local, synced, published, attempts, next_retry_at) =
            raw(&storage, &pubkey_hex).unwrap();
        assert_eq!((local, synced, published), (1, 0, 1));
        assert_eq!(attempts, 1);
        assert_eq!(next_retry_at, 1_001 + PROFILE_SYNC_BACKOFF_SECS[0]);
        assert_eq!(
            storage
                .pending_profile_sync(&pubkey_hex)
                .unwrap()
                .unwrap()
                .edits,
            name_edit("Alice"),
            "the pending set survives so the re-publish carries it",
        );
    }

    #[test]
    fn a_commit_records_the_kind0_publication_and_arms_the_retraction_gate() {
        let storage = storage();
        let keys = Keys::generate();
        let pubkey_hex = keys.public_key().to_hex();
        assert!(!storage.has_published_profile(&keys.public_key()).unwrap());
        storage
            .stage_own_profile_edits(&pubkey_hex, &name_edit("Alice"), 1_000)
            .unwrap();
        assert!(
            !storage.has_published_profile(&keys.public_key()).unwrap(),
            "staging alone publishes nothing, so it must not arm the gate",
        );
        commit(&storage, &keys, 1, true, 1_001).expect("commit");
        assert!(storage.has_published_profile(&keys.public_key()).unwrap());
        assert!(storage
            .last_published_event(0, "", &keys.public_key())
            .unwrap()
            .is_some());
    }

    #[test]
    fn a_commit_re_stamps_the_staged_picture_with_its_real_url() {
        let storage = storage();
        let keys = Keys::generate();
        let pubkey_hex = keys.public_key().to_hex();
        storage
            .stage_own_profile_picture(&pubkey_hex, &staged(b"canonical", b"thumb"), 1_000)
            .unwrap();
        let merged = ProfileMetadata::from_metadata(
            nostr::Metadata::new()
                .picture(nostr::Url::parse("https://blossom.example/abc").unwrap()),
        );
        storage
            .commit_profile_sync(&ProfileSyncCommit {
                pubkey: &keys.public_key(),
                published_version: 1,
                merged: &merged,
                event_id: &any_event_id(&keys),
                event_created_at: 1_001,
                uploaded_picture_url: Some("https://blossom.example/abc"),
                fully_acked: true,
                now: 1_001,
            })
            .expect("commit");

        assert_eq!(
            storage
                .get_profile_picture_url(&pubkey_hex)
                .unwrap()
                .as_deref(),
            Some("https://blossom.example/abc"),
        );
        assert_eq!(
            &*storage.get_profile_picture(&pubkey_hex).unwrap().unwrap(),
            b"canonical",
            "the sanitized bytes are preserved, only the URL is stamped",
        );
        assert!(!storage.profile_picture_is_staged(&pubkey_hex).unwrap());
        assert!(storage
            .has_current_picture(&pubkey_hex, Some("https://blossom.example/abc"))
            .unwrap());
    }

    // ---- the backoff ladder ------------------------------------------------

    #[test]
    fn repeated_failures_walk_the_sync_ladder_then_saturate() {
        let storage = storage();
        storage
            .stage_own_profile_edits(&hex(), &name_edit("Alice"), 0)
            .unwrap();
        let mut now = 0;
        for (i, rung) in PROFILE_SYNC_BACKOFF_SECS.iter().enumerate() {
            storage.record_profile_sync_attempt(&hex(), now).unwrap();
            let (_, _, _, attempts, next_retry_at) = raw(&storage, &hex()).unwrap();
            assert_eq!(attempts, i64::try_from(i).unwrap() + 1);
            assert_eq!(next_retry_at, now + rung, "rung {i} mismatch");
            now = next_retry_at;
        }
        let last = *PROFILE_SYNC_BACKOFF_SECS.last().unwrap();
        for _ in 0..3 {
            storage.record_profile_sync_attempt(&hex(), now).unwrap();
            let (_, _, _, _, next_retry_at) = raw(&storage, &hex()).unwrap();
            assert_eq!(next_retry_at, now + last, "ladder must saturate, not panic");
            now = next_retry_at;
        }
    }

    #[test]
    fn recording_an_attempt_for_an_unseen_pubkey_seeds_nothing() {
        // Nothing has ever been saved for this pubkey, so there is nothing to
        // retry — and inventing an outbox row would make a never-edited profile
        // look like it had pending work.
        let storage = storage();
        storage.record_profile_sync_attempt(&hex(), 1_000).unwrap();
        assert!(raw(&storage, &hex()).is_none());
        assert!(
            !storage
                .profile_pending_state(&hex(), 1_000)
                .unwrap()
                .pending
        );
    }

    // ---- cancel / wipe -----------------------------------------------------

    #[test]
    fn clearing_the_state_levels_the_counters_and_drops_staged_bytes() {
        let storage = storage();
        storage
            .stage_own_profile_edits(&hex(), &name_edit("Alice"), 1_000)
            .unwrap();
        storage
            .stage_own_profile_picture(&hex(), &staged(b"c", b"t"), 1_001)
            .unwrap();
        storage.record_profile_sync_attempt(&hex(), 1_001).unwrap();

        storage.clear_profile_sync_state(&hex()).unwrap();

        assert!(storage.pending_profile_sync(&hex()).unwrap().is_none());
        let (local, synced, published, attempts, next_retry_at) = raw(&storage, &hex()).unwrap();
        assert_eq!(synced, local, "nothing may remain pending");
        assert_eq!(published, local);
        assert_eq!((attempts, next_retry_at), (0, 0));
        assert!(
            storage.get_profile_picture(&hex()).unwrap().is_none(),
            "staged bytes are cancelled with the upload that would have published them",
        );
    }

    #[test]
    fn cancelling_a_staged_picture_keeps_a_pending_name_edit() {
        // "Remove my photo" and "rename me" are independent saves. Cancelling
        // the whole outbox here would silently discard the rename.
        let storage = storage();
        storage
            .stage_own_profile_edits(&hex(), &name_edit("Alice"), 1_000)
            .unwrap();
        storage
            .stage_own_profile_picture(&hex(), &staged(b"c", b"t"), 1_001)
            .unwrap();

        storage.cancel_staged_profile_picture(&hex()).unwrap();

        assert!(
            storage.get_profile_picture(&hex()).unwrap().is_none(),
            "the queued upload's bytes go with the upload",
        );
        assert!(!storage.profile_picture_is_staged(&hex()).unwrap());
        let snapshot = storage
            .pending_profile_sync(&hex())
            .unwrap()
            .expect("the rename is still queued");
        assert_eq!(snapshot.edits.display_name.as_deref(), Some("Alice"));
        assert!(!snapshot.picture_staged);
    }

    #[test]
    fn cancelling_a_staged_picture_keeps_a_published_one() {
        // A picture with a real URL is a PUBLISHED artefact: only the queued
        // upload is cancelled here, never the bytes the app still renders.
        let storage = storage();
        storage
            .upsert_profile_picture(
                &hex(),
                "https://blossom.example/abc",
                &[0x11; 32],
                b"c",
                b"t",
                1,
            )
            .unwrap();
        storage.cancel_staged_profile_picture(&hex()).unwrap();
        assert!(storage.get_profile_picture(&hex()).unwrap().is_some());
    }

    #[test]
    fn clearing_the_state_keeps_a_published_picture() {
        // A picture with a real URL is a PUBLISHED artefact; cancelling the
        // outbox must not silently delete the bytes the app still renders.
        let storage = storage();
        storage
            .upsert_profile_picture(
                &hex(),
                "https://blossom.example/abc",
                &[0x11; 32],
                b"c",
                b"t",
                1,
            )
            .unwrap();
        storage.clear_profile_sync_state(&hex()).unwrap();
        assert!(storage.get_profile_picture(&hex()).unwrap().is_some());
    }

    #[test]
    fn a_wipe_resets_the_outbox_in_place_rather_than_deleting_it() {
        // Deleting the row would restart `local_version` at 0, so the next save
        // would look OLDER than a publish recorded before the wipe and the
        // compare-and-set would clear a pending edit it never published.
        let storage = storage();
        let keys = Keys::generate();
        let pubkey_hex = keys.public_key().to_hex();
        storage
            .stage_own_profile_edits(&pubkey_hex, &name_edit("Alice"), 1_000)
            .unwrap();
        commit(&storage, &keys, 1, true, 1_001).unwrap();
        storage
            .stage_own_profile_edits(&pubkey_hex, &name_edit("Alice v2"), 1_002)
            .unwrap();

        storage.wipe_all_profiles().unwrap();

        let (local, synced, published, _, _) =
            raw(&storage, &pubkey_hex).expect("the outbox row survives a wipe");
        assert_eq!(local, 2, "the version counter must not restart");
        assert_eq!((synced, published), (2, 2), "and nothing stays pending");
        assert!(storage.pending_profile_sync(&pubkey_hex).unwrap().is_none());
    }

    // ---- pending edits survive a newer fetch --------------------------------

    #[test]
    fn a_newer_fetched_kind0_keeps_the_pending_edit_visible() {
        // Another client publishes a newer kind-0 while our rename is still
        // queued. The fetch must win on everything EXCEPT the field the user is
        // waiting on — otherwise the new name visibly reverts and then
        // reappears when the sync lands.
        let storage = storage();
        storage
            .stage_own_profile_edits(&hex(), &name_edit("Pending Name"), 1_000)
            .unwrap();
        let fetched = CachedProfile {
            pubkey_hex: hex(),
            metadata: ProfileMetadata::from_metadata(
                nostr::Metadata::new()
                    .display_name("Other Client")
                    .about("bio from elsewhere"),
            ),
            state: ProfileState::Known,
            event_created_at: 5_000,
            fetched_at: 5_000,
        };
        assert!(storage.upsert_profile_if_newer(&fetched).unwrap());

        let stored = storage.get_profile(&hex()).unwrap().unwrap();
        assert_eq!(
            stored.metadata.display_name(),
            Some("Pending Name"),
            "the unpublished edit must survive the newer fetch",
        );
        assert_eq!(
            stored.metadata.about(),
            Some("bio from elsewhere"),
            "everything the user is NOT editing still comes from the relay",
        );
        assert_eq!(stored.event_created_at, 5_000);
    }

    #[test]
    fn a_newer_fetched_kind0_is_written_verbatim_for_a_member() {
        // Only the local user has an outbox row; a member's fetched profile must
        // not be reshaped by anything.
        let storage = storage();
        let member = "cd".repeat(32);
        let fetched = CachedProfile {
            pubkey_hex: member.clone(),
            metadata: ProfileMetadata::from_metadata(nostr::Metadata::new().display_name("Bob")),
            state: ProfileState::Known,
            event_created_at: 5_000,
            fetched_at: 5_000,
        };
        assert!(storage.upsert_profile_if_newer(&fetched).unwrap());
        assert_eq!(
            storage
                .get_profile(&member)
                .unwrap()
                .unwrap()
                .metadata
                .display_name(),
            Some("Bob"),
        );
    }

    #[test]
    fn a_synced_edit_no_longer_overrides_a_newer_fetch() {
        // Once the edit is published, it stops being a local override — the
        // relay's copy is authoritative again.
        let storage = storage();
        let keys = Keys::generate();
        let pubkey_hex = keys.public_key().to_hex();
        storage
            .stage_own_profile_edits(&pubkey_hex, &name_edit("Pending Name"), 1_000)
            .unwrap();
        commit(&storage, &keys, 1, true, 1_001).unwrap();

        let fetched = CachedProfile {
            pubkey_hex: pubkey_hex.clone(),
            metadata: ProfileMetadata::from_metadata(
                nostr::Metadata::new().display_name("Other Client"),
            ),
            state: ProfileState::Known,
            event_created_at: 5_000,
            fetched_at: 5_000,
        };
        assert!(storage.upsert_profile_if_newer(&fetched).unwrap());
        assert_eq!(
            storage
                .get_profile(&pubkey_hex)
                .unwrap()
                .unwrap()
                .metadata
                .display_name(),
            Some("Other Client"),
        );
    }

    // ---- the retraction gate's new arms ------------------------------------

    #[test]
    fn a_staged_only_picture_does_not_arm_the_retraction_gate() {
        // Nothing public exists for staged bytes, so a "remove my picture" must
        // stay a no-op rather than minting a first public event.
        let storage = storage();
        let keys = Keys::generate();
        storage
            .stage_own_profile_picture(&keys.public_key().to_hex(), &staged(b"c", b"t"), 1_000)
            .unwrap();
        assert!(!storage.has_published_profile(&keys.public_key()).unwrap());
    }

    #[test]
    fn staging_never_disarms_an_imported_account_that_already_has_a_profile() {
        // An imported nsec whose kind-0 was published by another client has a
        // real public footprint but no local `published_events` row. Staging a
        // new photo overwrites the cached picture row with the empty-URL marker,
        // so without the cached-kind-0 arm the retraction would silently become
        // a no-op and leave the public profile up.
        let storage = storage();
        let keys = Keys::generate();
        let pubkey_hex = keys.public_key().to_hex();
        storage
            .upsert_profile(&CachedProfile {
                pubkey_hex: pubkey_hex.clone(),
                metadata: ProfileMetadata::from_metadata(
                    nostr::Metadata::new().display_name("Imported"),
                ),
                state: ProfileState::Known,
                event_created_at: 4_000,
                fetched_at: 4_000,
            })
            .unwrap();
        storage
            .upsert_profile_picture(
                &pubkey_hex,
                "https://blossom.example/old",
                &[0x11; 32],
                b"c",
                b"t",
                4_000,
            )
            .unwrap();
        assert!(storage.has_published_profile(&keys.public_key()).unwrap());

        storage
            .stage_own_profile_picture(&pubkey_hex, &staged(b"c2", b"t2"), 5_000)
            .unwrap();
        assert!(
            storage.has_published_profile(&keys.public_key()).unwrap(),
            "the account's existing public profile still deserves a retraction",
        );
    }

    #[test]
    fn an_unresolved_profile_row_does_not_arm_the_retraction_gate() {
        // A recorded MISS (`Unknown`, created_at 0) is the absence of a profile,
        // not evidence of one.
        let storage = storage();
        let keys = Keys::generate();
        storage
            .record_profile_misses(&[keys.public_key().to_hex()], 1_000)
            .unwrap();
        assert!(!storage.has_published_profile(&keys.public_key()).unwrap());
    }
}
