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
//! Every save bumps `local_version` (a photo removal is a save), and so does
//! a profile deletion's blank that some relay did not take: the blank is then
//! the version still owed. A publish records TWO coverage facts, because "it
//! published" and "every peer can read it" are different:
//!
//! * `published_version` — the newest version at least ONE relay acknowledged;
//! * `synced_version` — the newest version EVERY usable pool relay serves.
//!
//! So `pending = local_version > synced_version`. A peer's relay-assignment
//! salt is private to their install, so a partial publish really is still the
//! old name for everyone assigned to a relay that does not serve it.
//!
//! # The owed event
//!
//! A complete event (it carries every pending item at `local_version`) that
//! some relays acknowledged is kept in `profile_publish_debt` with the relays
//! that serve it, so a retry re-sends those exact bytes to the rest instead of
//! signing a new kind-0 for the whole pool. Every write that bumps
//! `local_version` deletes it.
//!
//! [`Self::commit_profile_sync`] is a compare-and-set on that counter: it may
//! only clear the pending set for the exact version it published. An edit saved
//! WHILE that publish was in flight therefore stays pending instead of being
//! silently reported as synced.
//!
//! # The row is never deleted
//!
//! Both destructive paths ([`CircleStorage::wipe_all_profiles`] and
//! [`Self::clear_profile_sync_state`]) RESET the row in place (the wipe then
//! leaves a blank some relay refused owed on it). Deleting it would
//! restart `local_version` at 0, so a save made afterwards would look older than
//! a publish recorded before it and the compare-and-set would clear a pending
//! edit it never published.

// Mirrors `storage.rs` / `storage_profile.rs`: each method acquires the
// connection lock once at the top and holds it for the whole operation.
#![allow(clippy::significant_drop_tightening)]

use nostr::{Event, JsonUtil, PublicKey};
use rusqlite::{params, Connection, OptionalExtension};

use super::error::{CircleError, Result};
use super::storage::CircleStorage;
use crate::avatar::StagedPicture;
use crate::profile::types::{CachedProfile, ProfileMetadata, ProfileState};
use crate::profile::{
    merge_edits, owed_event_from_json, uncovered, PendingEdits, PendingSnapshot,
    PROFILE_SYNC_BACKOFF_SECS,
};

/// Whether the own profile has unpublished work, and when the persisted
/// retry ladder next permits an attempt.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ProfilePendingState {
    /// A save is not yet served by every pool relay (`local > synced`).
    pub pending: bool,
    /// The persisted retry ladder permits another attempt now.
    pub retry_due: bool,
    /// Seconds until the next attempt is due: `Some` only when pending and
    /// not due, never more than the longest rung. Relative, never an instant
    /// (Security Rule 15).
    pub next_retry_in_secs: Option<u32>,
}

/// The owed kind-0 and the pool relays known to serve it.
///
/// No `Debug`: a signed event and relay URLs (Security Rule 15).
pub struct ProfileDebt {
    /// The `local_version` the event carries.
    pub version: i64,
    /// The signed event, verified on load.
    pub event: Event,
    /// The relays that serve it, as recorded.
    pub covered: Vec<String>,
}

/// Everything one own-profile publish that at least one relay acknowledged
/// must record, as a single parameter object.
///
/// A struct rather than positional arguments: several of them are same-typed
/// slices or integers whose transposition would silently corrupt the coverage
/// record.
pub struct ProfileSyncCommit<'a> {
    /// The local user's identity pubkey. Its hex is the key for every profile
    /// row, derived here so the two can never disagree.
    pub pubkey: &'a PublicKey,
    /// The `local_version` this publish carried — the compare-and-set subject.
    pub version: i64,
    /// The metadata that was actually published.
    pub merged: &'a ProfileMetadata,
    /// The published kind-0.
    pub event: &'a Event,
    /// The Blossom URL a staged picture was uploaded to and the sha256 of the
    /// bytes it was uploaded from, if one was.
    pub uploaded_picture: Option<(&'a str, &'a [u8])>,
    /// The pool relays known to serve the event.
    pub covered: &'a [String],
    /// The usable pool this publish was for.
    pub pool: &'a [String],
    /// Whether the event carries every pending item at `version` (no upload
    /// failed).
    pub complete: bool,
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
        let row = Self::stage_edits_on(&tx, pubkey_hex, edits, now)?;
        tx.commit()?;
        Ok(row)
    }

    /// Removes the own photo LOCALLY and queues the removal for publication,
    /// returning the profile row the UI should render immediately.
    ///
    /// One transaction: every picture row (staged and published bytes alike)
    /// is deleted, the cached row loses its `picture`, the removal is staged
    /// at the new `local_version` with the retry ladder reset, and the owed
    /// event is dropped. No lock, no secret, no network: the sync publishes
    /// the removal, and decides there whether there is anything to retract.
    ///
    /// # Errors
    ///
    /// As [`Self::stage_own_profile_edits`].
    pub fn stage_own_picture_removal(&self, pubkey_hex: &str, now: i64) -> Result<CachedProfile> {
        let mut conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        let tx = conn.transaction()?;
        tx.execute(
            "DELETE FROM profile_pictures WHERE pubkey = ?1",
            params![pubkey_hex],
        )?;
        let local_version: i64 = tx
            .query_row(
                "SELECT local_version FROM profile_sync_state WHERE pubkey = ?1",
                params![pubkey_hex],
                |r| r.get(0),
            )
            .optional()?
            .unwrap_or(0);
        let removal = PendingEdits {
            clear_picture: true,
            clear_version: local_version + 1,
            ..PendingEdits::default()
        };
        let row = Self::stage_edits_on(&tx, pubkey_hex, &removal, now)?;
        tx.execute(
            "UPDATE profile_sync_state SET picture_staged = 0 WHERE pubkey = ?1",
            params![pubkey_hex],
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
    /// reset. A pending photo removal stays pending: until this picture's
    /// upload succeeds, the removal is what a sync publishes.
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
        let raw = Self::read_raw_pending_edits(&tx, pubkey_hex)?;
        if raw.resigned {
            Self::write_raw_pending_edits(
                &tx,
                pubkey_hex,
                &PendingEdits {
                    resigned: false,
                    ..raw
                },
            )?;
        }
        Self::delete_publish_debt(&tx, pubkey_hex)?;
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

    /// Whether the own profile has unpublished work and when a retry is due.
    ///
    /// A pubkey with no outbox row has never saved anything: nothing pending,
    /// and no backoff standing in the way of a future attempt.
    ///
    /// # Errors
    ///
    /// As [`Self::stage_own_profile_edits`].
    pub fn profile_pending_state(&self, pubkey_hex: &str, now: i64) -> Result<ProfilePendingState> {
        let conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        let row: Option<(i64, i64, i64)> = conn
            .query_row(
                "SELECT local_version, synced_version, next_retry_at
                 FROM profile_sync_state WHERE pubkey = ?1",
                params![pubkey_hex],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .optional()?;
        let Some((local, synced, next_retry_at)) = row else {
            return Ok(ProfilePendingState {
                pending: false,
                retry_due: true,
                next_retry_in_secs: None,
            });
        };
        let pending = local > synced;
        let wait = next_retry_at.saturating_sub(now);
        // A wait longer than the longest rung was dated on a clock since set
        // back; one retry now beats waiting hours for the clock to catch up.
        let retry_due = wait <= 0 || wait > sync_backoff_secs(i64::MAX);
        Ok(ProfilePendingState {
            pending,
            retry_due,
            next_retry_in_secs: (pending && !retry_due)
                .then(|| u32::try_from(wait).ok())
                .flatten(),
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

    /// Records one own-profile publish at least one relay acknowledged, and
    /// returns the profile row as it was stored.
    ///
    /// What is recorded: the metadata, the picture URL, the published-event
    /// row, and how far its coverage got.
    ///
    /// One transaction, so the cache, the publication record, the coverage
    /// counters and the owed event can never disagree. Every write goes
    /// through a `&Connection` helper rather than the public method that wraps
    /// it: the connection mutex is a plain `std::sync::Mutex` and re-entering it
    /// would deadlock, not block.
    ///
    /// The compare-and-set: `published_version` and (once every pool relay
    /// serves the event) `synced_version` only ever move FORWARD, and the
    /// pending set is cleared only when the version that was published is
    /// still the newest one saved. Short of full coverage the ladder advances,
    /// and a complete event for the newest version is kept as the owed event
    /// with the relays that took it.
    ///
    /// # The row keeps what is still pending
    ///
    /// An edit saved while the publish was in flight is on the row already.
    /// The row is written from `merged` with whatever is pending at that
    /// moment re-applied, under the lock that reads it, as
    /// [`Self::upsert_profile_if_newer`] does — or the name field would lose
    /// the edit until the next sync.
    ///
    /// # Errors
    ///
    /// As [`Self::stage_own_profile_edits`].
    pub fn commit_profile_sync(&self, c: &ProfileSyncCommit<'_>) -> Result<CachedProfile> {
        let pubkey_hex = c.pubkey.to_hex();
        let event_created_at = i64::try_from(c.event.created_at.as_secs())
            .map_err(|_| CircleError::Storage("kind-0 timestamp out of range".to_string()))?;
        let mut conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        let tx = conn.transaction()?;

        if let Some((url, sha256)) = c.uploaded_picture {
            // Re-stamp the staged row (cached with an empty `url`) with the URL
            // the upload resolved to, only while it still holds the bytes that
            // were uploaded: a photo picked or removed since keeps its own row.
            let staged: Option<(Vec<u8>, Vec<u8>)> = tx
                .query_row(
                    "SELECT canonical, thumbnail FROM profile_pictures
                     WHERE pubkey = ?1 AND sha256 = ?2",
                    params![pubkey_hex, sha256],
                    |r| Ok((r.get(0)?, r.get(1)?)),
                )
                .optional()?;
            if let Some((canonical, thumbnail)) = staged {
                Self::write_profile_picture_row(
                    &tx,
                    &pubkey_hex,
                    url,
                    sha256,
                    &canonical,
                    &thumbnail,
                    c.now,
                )?;
            }
        }

        Self::write_published_event_row(&tx, 0, "", &c.event.id, c.pubkey, c.now)?;

        if c.complete && uncovered(c.pool, c.covered).is_empty() {
            tx.execute(
                "UPDATE profile_sync_state SET
                    published_version = MAX(published_version, ?2),
                    synced_version    = MAX(synced_version, ?2),
                    edits_json     = CASE WHEN local_version = ?2 THEN '{}' ELSE edits_json END,
                    picture_staged = CASE WHEN local_version = ?2 THEN 0 ELSE picture_staged END,
                    sync_attempts     = 0,
                    next_retry_at     = 0
                 WHERE pubkey = ?1",
                params![pubkey_hex, c.version],
            )?;
            tx.execute(
                "DELETE FROM profile_publish_debt WHERE pubkey = ?1 AND version <= ?2",
                params![pubkey_hex, c.version],
            )?;
        } else {
            tx.execute(
                "UPDATE profile_sync_state
                 SET published_version = MAX(published_version, ?2)
                 WHERE pubkey = ?1",
                params![pubkey_hex, c.version],
            )?;
            Self::write_sync_attempt_row(&tx, &pubkey_hex, c.now)?;
            if c.complete {
                Self::write_publish_debt(&tx, &pubkey_hex, c.version, c.event, c.covered)?;
            }
        }

        // Before the row is rewritten from what is still pending. A version at
        // or after the removal carried it out: `to_edits` puts an empty picture
        // in every event built while the removal is pending, unless an uploaded
        // URL superseded it.
        let raw = Self::read_raw_pending_edits(&tx, &pubkey_hex)?;
        if raw.clear_picture && c.version >= raw.clear_version {
            Self::write_raw_pending_edits(
                &tx,
                &pubkey_hex,
                &PendingEdits {
                    clear_picture: false,
                    clear_version: 0,
                    ..raw
                },
            )?;
        }

        let metadata = Self::read_pending_edits(&tx, &pubkey_hex)?.map_or_else(
            || c.merged.clone(),
            |pending| merge_edits(c.merged, &pending.to_edits(None)),
        );
        let stored = Self::write_profile_row(
            &tx,
            &CachedProfile {
                pubkey_hex,
                metadata,
                state: ProfileState::Known,
                event_created_at,
                fetched_at: c.now,
            },
        )?;

        tx.commit()?;
        Ok(stored)
    }

    /// The owed event for `version`, or `None` when nothing is owed for it.
    ///
    /// Loads only while `version` is still the newest saved. A row that does
    /// not verify as a genuine own kind-0, or that is older than the cached own
    /// row (a newer profile was fetched since), is deleted and not returned:
    /// re-sending it could only put a superseded profile back on a relay.
    ///
    /// # Errors
    ///
    /// As [`Self::stage_own_profile_edits`].
    pub fn profile_publish_debt(
        &self,
        own: &PublicKey,
        version: i64,
    ) -> Result<Option<ProfileDebt>> {
        let pubkey_hex = own.to_hex();
        let mut conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        let tx = conn.transaction()?;
        let row: Option<(String, String)> = tx
            .query_row(
                "SELECT d.event_json, d.covered_json FROM profile_publish_debt d
                 JOIN profile_sync_state s ON s.pubkey = d.pubkey
                 WHERE d.pubkey = ?1 AND d.version = ?2 AND s.local_version = ?2",
                params![pubkey_hex, version],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?;
        let Some((event_json, covered_json)) = row else {
            return Ok(None);
        };
        let (Some(event), Ok(covered)) = (
            owed_event_from_json(&event_json, own),
            serde_json::from_str::<Vec<String>>(&covered_json),
        ) else {
            log::warn!("profile outbox: the owed kind-0 was unreadable; discarding it");
            Self::delete_publish_debt(&tx, &pubkey_hex)?;
            tx.commit()?;
            return Ok(None);
        };
        let cached_created_at: Option<i64> = tx
            .query_row(
                "SELECT event_created_at FROM profiles WHERE pubkey = ?1",
                params![pubkey_hex],
                |r| r.get(0),
            )
            .optional()?;
        let superseded = cached_created_at.is_some_and(|cached| {
            u64::try_from(cached).is_ok_and(|cached| cached > event.created_at.as_secs())
        });
        if superseded {
            Self::delete_publish_debt(&tx, &pubkey_hex)?;
            tx.commit()?;
            return Ok(None);
        }
        tx.commit()?;
        Ok(Some(ProfileDebt {
            version,
            event,
            covered,
        }))
    }

    /// Records that `newly_covered` relays now serve the owed event of
    /// `version`.
    ///
    /// Once every relay of `pool` does, the outbox is clean; otherwise the
    /// ladder advances. A compare-and-set on both the owed event's version and
    /// `local_version`, so a pass that a save, a removal, a deletion or a
    /// redirect overtook changes nothing.
    ///
    /// # Errors
    ///
    /// As [`Self::stage_own_profile_edits`].
    pub fn commit_profile_coverage(
        &self,
        pubkey_hex: &str,
        version: i64,
        newly_covered: &[String],
        pool: &[String],
        now: i64,
    ) -> Result<()> {
        let mut conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        let tx = conn.transaction()?;
        let covered_json: Option<String> = tx
            .query_row(
                "SELECT d.covered_json FROM profile_publish_debt d
                 JOIN profile_sync_state s ON s.pubkey = d.pubkey
                 WHERE d.pubkey = ?1 AND d.version = ?2 AND s.local_version = ?2",
                params![pubkey_hex, version],
                |r| r.get(0),
            )
            .optional()?;
        let Some(covered_json) = covered_json else {
            return Ok(());
        };
        let mut covered: Vec<String> = serde_json::from_str(&covered_json).unwrap_or_default();
        covered.extend(uncovered(newly_covered, &covered));
        if uncovered(pool, &covered).is_empty() {
            tx.execute(
                "UPDATE profile_sync_state SET
                    published_version = MAX(published_version, ?2),
                    synced_version    = MAX(synced_version, ?2),
                    edits_json        = '{}',
                    picture_staged    = 0,
                    sync_attempts     = 0,
                    next_retry_at     = 0
                 WHERE pubkey = ?1",
                params![pubkey_hex, version],
            )?;
            Self::delete_publish_debt(&tx, pubkey_hex)?;
        } else {
            tx.execute(
                "UPDATE profile_publish_debt SET covered_json = ?2 WHERE pubkey = ?1",
                params![pubkey_hex, encode_covered(&covered)?],
            )?;
            Self::write_sync_attempt_row(&tx, pubkey_hex, now)?;
        }
        tx.commit()?;
        Ok(())
    }

    /// Drops the owed event of `version`, if it is still that one.
    ///
    /// # Errors
    ///
    /// As [`Self::stage_own_profile_edits`].
    pub fn discard_profile_publish_debt(&self, pubkey_hex: &str, version: i64) -> Result<()> {
        let conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        conn.execute(
            "DELETE FROM profile_publish_debt WHERE pubkey = ?1 AND version = ?2",
            params![pubkey_hex, version],
        )?;
        Ok(())
    }

    /// Marks the pending edits of `version` as signed afresh once already
    /// ([`PendingEdits::resigned`]), if it is still the newest saved.
    ///
    /// # Errors
    ///
    /// As [`Self::stage_own_profile_edits`].
    pub fn mark_profile_resigned(&self, pubkey_hex: &str, version: i64) -> Result<()> {
        let mut conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        let tx = conn.transaction()?;
        let current: Option<i64> = tx
            .query_row(
                "SELECT local_version FROM profile_sync_state WHERE pubkey = ?1",
                params![pubkey_hex],
                |r| r.get(0),
            )
            .optional()?;
        if current == Some(version) {
            let raw = Self::read_raw_pending_edits(&tx, pubkey_hex)?;
            Self::write_raw_pending_edits(
                &tx,
                pubkey_hex,
                &PendingEdits {
                    resigned: true,
                    ..raw
                },
            )?;
        }
        tx.commit()?;
        Ok(())
    }

    /// Levels `version` as settled with nothing sent.
    ///
    /// For a pending set that carries nothing public to retract. A
    /// compare-and-set on `local_version`, and never while a photo is staged,
    /// so content the user saved is never discarded.
    ///
    /// # Errors
    ///
    /// As [`Self::stage_own_profile_edits`].
    pub fn settle_profile_sync(&self, pubkey_hex: &str, version: i64) -> Result<()> {
        let conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        conn.execute(
            "UPDATE profile_sync_state SET
                synced_version    = MAX(synced_version, ?2),
                published_version = MAX(published_version, ?2),
                edits_json        = '{}',
                sync_attempts     = 0,
                next_retry_at     = 0
             WHERE pubkey = ?1 AND local_version = ?2 AND picture_staged = 0",
            params![pubkey_hex, version],
        )?;
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
        conn.execute(
            "DELETE FROM profile_publish_debt WHERE ?1 IS NULL OR pubkey = ?1",
            params![pubkey_hex],
        )?;
        Ok(())
    }

    /// Leaves the profile just published as the version the outbox owes, on an
    /// ALREADY-LOCKED connection: for a publish that carried no saved version
    /// and that some relay did not take — the blank of a profile deletion.
    ///
    /// A compare-and-set: only a row with nothing pending takes the new
    /// version, and the retry ladder advances only when one did.
    pub(super) fn write_unqueued_publish_owed(
        conn: &Connection,
        pubkey_hex: &str,
        now: i64,
    ) -> rusqlite::Result<()> {
        let owed = conn.execute(
            "INSERT INTO profile_sync_state (pubkey, local_version, published_version)
             VALUES (?1, 1, 1)
             ON CONFLICT(pubkey) DO UPDATE SET
                local_version     = local_version + 1,
                published_version = local_version + 1
             WHERE local_version <= synced_version",
            params![pubkey_hex],
        )?;
        if owed > 0 {
            Self::write_sync_attempt_row(conn, pubkey_hex, now)?;
        }
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

    /// The shared body of every local edit, on an ALREADY-LOCKED connection.
    ///
    /// Merges `edits` onto the cached row (neither `event_created_at` nor
    /// `fetched_at` moves on an existing row), folds them into the pending
    /// set, bumps `local_version`, resets the ladder and drops the owed event.
    fn stage_edits_on(
        conn: &Connection,
        pubkey_hex: &str,
        edits: &PendingEdits,
        now: i64,
    ) -> Result<CachedProfile> {
        let existing = conn
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
        let row = Self::write_profile_row(conn, &row)?;

        // Accumulate rather than replace: renaming and then editing the bio must
        // publish BOTH. A replace would drop the rename with no error anywhere.
        let accumulated = Self::read_raw_pending_edits(conn, pubkey_hex)?.accumulate(edits);
        conn.execute(
            "INSERT INTO profile_sync_state (pubkey, local_version, edits_json)
             VALUES (?1, 1, ?2)
             ON CONFLICT(pubkey) DO UPDATE SET
                local_version = local_version + 1,
                edits_json    = excluded.edits_json,
                sync_attempts = 0,
                next_retry_at = 0",
            params![pubkey_hex, encode_pending_edits(&accumulated)?],
        )?;
        Self::delete_publish_debt(conn, pubkey_hex)?;
        Ok(row)
    }

    /// Replaces the stored pending set, leaving the counters alone.
    fn write_raw_pending_edits(
        conn: &Connection,
        pubkey_hex: &str,
        edits: &PendingEdits,
    ) -> Result<()> {
        conn.execute(
            "UPDATE profile_sync_state SET edits_json = ?2 WHERE pubkey = ?1",
            params![pubkey_hex, encode_pending_edits(edits)?],
        )?;
        Ok(())
    }

    /// Records `event` as owed for `version` with the relays that serve it, on
    /// an ALREADY-LOCKED connection, only while `version` is the newest saved.
    pub(super) fn write_publish_debt(
        conn: &Connection,
        pubkey_hex: &str,
        version: i64,
        event: &Event,
        covered: &[String],
    ) -> Result<()> {
        conn.execute(
            "INSERT INTO profile_publish_debt (pubkey, version, event_json, covered_json)
             SELECT ?1, ?2, ?3, ?4 FROM profile_sync_state
             WHERE pubkey = ?1 AND local_version = ?2
             ON CONFLICT(pubkey) DO UPDATE SET
                version      = excluded.version,
                event_json   = excluded.event_json,
                covered_json = excluded.covered_json",
            params![
                pubkey_hex,
                version,
                event.as_json(),
                encode_covered(covered)?
            ],
        )?;
        Ok(())
    }

    fn delete_publish_debt(conn: &Connection, pubkey_hex: &str) -> rusqlite::Result<()> {
        conn.execute(
            "DELETE FROM profile_publish_debt WHERE pubkey = ?1",
            params![pubkey_hex],
        )?;
        Ok(())
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

fn encode_pending_edits(edits: &PendingEdits) -> Result<String> {
    serde_json::to_string(edits)
        .map_err(|e| CircleError::Storage(format!("Failed to encode pending edits: {e}")))
}

fn encode_covered(covered: &[String]) -> Result<String> {
    serde_json::to_string(covered)
        .map_err(|_| CircleError::Storage("Failed to encode relay coverage".to_string()))
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
    use nostr::Keys;

    fn storage() -> CircleStorage {
        CircleStorage::in_memory().expect("in-memory storage must initialize")
    }

    fn hex() -> String {
        "ab".repeat(32)
    }

    fn name_edit(display_name: &str) -> PendingEdits {
        PendingEdits {
            display_name: Some(display_name.to_string()),
            ..PendingEdits::default()
        }
    }

    fn bio_edit(about: &str) -> PendingEdits {
        PendingEdits {
            about: Some(about.to_string()),
            ..PendingEdits::default()
        }
    }

    /// A staged picture over arbitrary cache bytes. The content hash is
    /// recomputed by [`StagedPicture`] itself, so no test may pin one that
    /// disagrees with the bytes it travels with.
    fn staged(canonical: &[u8], thumbnail: &[u8]) -> StagedPicture {
        StagedPicture::from_sanitized_cache(canonical.to_vec(), thumbnail.to_vec())
    }

    /// The complete publish of `version`, carrying "Synced" and dated
    /// `FAR + now`, taken by both relays of a two-relay pool or by one.
    fn commit(
        storage: &CircleStorage,
        keys: &Keys,
        version: i64,
        fully_acked: bool,
        now: i64,
    ) -> Result<CachedProfile> {
        let merged = meta("Synced");
        let event = kind0_at(keys, &merged, u64::try_from(now).expect("a timestamp"));
        let pool = relays(&["a", "b"]);
        let covered = if fully_acked { &pool[..] } else { &pool[..1] };
        storage.commit_profile_sync(&ProfileSyncCommit {
            pubkey: &keys.public_key(),
            version,
            merged: &merged,
            event: &event,
            uploaded_picture: None,
            covered,
            pool: &pool,
            complete: true,
            now,
        })
    }

    /// A publish that carried nothing the outbox held — a deletion's blank —
    /// recorded as the wipe records it: owed only when some relay did not
    /// take it.
    fn commit_unqueued(
        storage: &CircleStorage,
        keys: &Keys,
        fully_acked: bool,
        now: i64,
    ) -> Result<()> {
        if fully_acked {
            return Ok(());
        }
        let mut conn = storage.conn().lock().unwrap();
        let tx = conn.transaction()?;
        CircleStorage::write_unqueued_publish_owed(&tx, &keys.public_key().to_hex(), now)?;
        tx.commit()?;
        Ok(())
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
        assert!(!state.pending);
        // The published metadata and its real `created_at` replaced the staged row.
        let stored = storage.get_profile(&pubkey_hex).unwrap().unwrap();
        assert_eq!(stored.metadata.display_name(), Some("Synced"));
        assert_eq!(stored.event_created_at, i64::try_from(FAR).unwrap() + 1_001);
        assert_eq!(raw(&storage, &pubkey_hex).unwrap().3, 0, "ladder reset");
    }

    #[test]
    fn a_commit_keeps_an_edit_saved_while_it_was_published_on_the_row() {
        // The publish carried v1; the bio was saved while it was in flight and
        // is on the row already. A commit that wrote only what it published
        // would take the bio off the row the user's field reads until the
        // next sync put it back.
        let storage = storage();
        let keys = Keys::generate();
        let pubkey_hex = keys.public_key().to_hex();
        storage
            .stage_own_profile_edits(&pubkey_hex, &name_edit("Alice"), 1_000)
            .unwrap();
        storage
            .stage_own_profile_edits(&pubkey_hex, &bio_edit("new bio"), 1_001)
            .unwrap();
        let published = ProfileMetadata::from_metadata(
            nostr::Metadata::new()
                .display_name("Alice")
                .website(nostr::Url::parse("https://w.example.com").unwrap()),
        );
        let event = kind0_at(&keys, &published, 1_002);
        let pool = relays(&["a"]);

        let row = storage
            .commit_profile_sync(&ProfileSyncCommit {
                pubkey: &keys.public_key(),
                version: 1,
                merged: &published,
                event: &event,
                uploaded_picture: None,
                covered: &pool,
                pool: &pool,
                complete: true,
                now: 1_002,
            })
            .unwrap();

        let stored = storage.get_profile(&pubkey_hex).unwrap().unwrap();
        for row in [&row, &stored] {
            assert_eq!(
                row.metadata.about(),
                Some("new bio"),
                "the edit saved during the publish must stay on the row",
            );
            assert_eq!(row.metadata.display_name(), Some("Alice"));
            assert_eq!(
                row.metadata.as_metadata().website,
                published.as_metadata().website,
                "everything else is what was published",
            );
            assert_eq!(row.event_created_at, ts(&event));
        }
    }

    // ---- a publish that carried no saved version ---------------------------

    #[test]
    fn an_unqueued_publish_a_relay_refused_becomes_the_version_owed() {
        // A photo removal with nothing queued, taken by two relays of three.
        // The third still serves the photo, so the profile just published is
        // itself what the outbox owes — partly published, and paced by the
        // ladder like any other partial publish.
        let storage = storage();
        let keys = Keys::generate();
        let pubkey_hex = keys.public_key().to_hex();
        storage
            .stage_own_profile_edits(&pubkey_hex, &name_edit("Alice"), 1_000)
            .unwrap();
        commit(&storage, &keys, 1, true, 1_001).unwrap();
        assert!(storage.pending_profile_sync(&pubkey_hex).unwrap().is_none());

        commit_unqueued(&storage, &keys, false, 2_000).unwrap();

        let state = storage.profile_pending_state(&pubkey_hex, 2_000).unwrap();
        assert!(state.pending);
        assert!(!state.retry_due, "the re-publish waits out the ladder");
        assert_eq!(
            raw(&storage, &pubkey_hex).unwrap(),
            (2, 1, 2, 1, 2_000 + PROFILE_SYNC_BACKOFF_SECS[0]),
        );
        let owed = storage
            .pending_profile_sync(&pubkey_hex)
            .unwrap()
            .expect("a sync has something to publish");
        assert_eq!(owed.local_version, 2);
        assert!(owed.edits.is_empty() && !owed.picture_staged);

        // The sync that follows publishes that version; a full acknowledgement
        // settles it.
        commit(&storage, &keys, 2, true, 2_031).unwrap();
        assert!(
            !storage
                .profile_pending_state(&pubkey_hex, 2_031)
                .unwrap()
                .pending
        );
        assert_eq!(raw(&storage, &pubkey_hex).unwrap(), (2, 2, 2, 0, 0));
    }

    #[test]
    fn an_unqueued_publish_a_relay_refused_is_owed_with_no_outbox_row_yet() {
        // An account that never saved an edit here (an imported key) has no
        // outbox row. Its removal is owed all the same.
        let storage = storage();
        let keys = Keys::generate();
        let pubkey_hex = keys.public_key().to_hex();
        assert!(raw(&storage, &pubkey_hex).is_none());

        commit_unqueued(&storage, &keys, false, 2_000).unwrap();

        let state = storage.profile_pending_state(&pubkey_hex, 2_000).unwrap();
        assert!(state.pending && !state.retry_due);
        assert_eq!(
            raw(&storage, &pubkey_hex).unwrap(),
            (1, 0, 1, 1, 2_000 + PROFILE_SYNC_BACKOFF_SECS[0]),
        );
    }

    #[test]
    fn an_unqueued_publish_never_marks_a_pending_edit_published() {
        // The compare-and-set of the arm above. A name is queued — saved
        // before the removal or while it was published — and the removal did
        // not carry it. No relay has been sent the name: it must not read as
        // partly published, and its own retry must not be put off. Its sync
        // republishes the whole profile to the whole pool anyway.
        let storage = storage();
        let keys = Keys::generate();
        let pubkey_hex = keys.public_key().to_hex();
        storage
            .stage_own_profile_edits(&pubkey_hex, &name_edit("Alice"), 1_000)
            .unwrap();

        commit_unqueued(&storage, &keys, false, 2_000).unwrap();
        let row = storage.get_profile(&pubkey_hex).unwrap().unwrap();

        let state = storage.profile_pending_state(&pubkey_hex, 2_000).unwrap();
        assert!(state.pending, "the name is still to be published");
        assert!(state.retry_due);
        // `published_version` 0: no relay has been sent the name.
        assert_eq!(raw(&storage, &pubkey_hex).unwrap(), (1, 0, 0, 0, 0));
        assert_eq!(
            row.metadata.display_name(),
            Some("Alice"),
            "the queued name stays on the row",
        );
    }

    #[test]
    fn an_unqueued_publish_every_relay_took_leaves_the_outbox_as_it_was() {
        // Nothing is owed for it. And it is not a sync of what IS queued, so
        // it neither clears that nor resets the backoff that paces it.
        let storage = storage();
        let keys = Keys::generate();
        let pubkey_hex = keys.public_key().to_hex();
        commit_unqueued(&storage, &keys, true, 900).unwrap();
        assert!(
            raw(&storage, &pubkey_hex).is_none(),
            "nothing owed seeds no outbox row",
        );

        storage
            .stage_own_profile_edits(&pubkey_hex, &name_edit("Alice"), 1_000)
            .unwrap();
        storage
            .record_profile_sync_attempt(&pubkey_hex, 1_000)
            .unwrap();
        let before = raw(&storage, &pubkey_hex).unwrap();

        commit_unqueued(&storage, &keys, true, 1_001).unwrap();

        assert_eq!(raw(&storage, &pubkey_hex).unwrap(), before);
        assert_eq!(
            storage
                .pending_profile_sync(&pubkey_hex)
                .unwrap()
                .expect("the name is still queued")
                .edits,
            name_edit("Alice"),
        );
        assert!(
            !storage
                .profile_pending_state(&pubkey_hex, 1_001)
                .unwrap()
                .retry_due,
            "the queued name's backoff still stands",
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
        let picture = staged(b"canonical", b"thumb");
        storage
            .stage_own_profile_picture(&pubkey_hex, &picture, 1_000)
            .unwrap();
        let merged = ProfileMetadata::from_metadata(
            nostr::Metadata::new()
                .picture(nostr::Url::parse("https://blossom.example/abc").unwrap()),
        );
        let event = kind0_at(&keys, &merged, 1_001);
        let pool = relays(&["a"]);
        storage
            .commit_profile_sync(&ProfileSyncCommit {
                pubkey: &keys.public_key(),
                version: 1,
                merged: &merged,
                event: &event,
                uploaded_picture: Some((
                    "https://blossom.example/abc",
                    picture.sha256().as_slice(),
                )),
                covered: &pool,
                pool: &pool,
                complete: true,
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

        let blank = crate::profile::build_blank_metadata_event(&keys, None).unwrap();
        let pool = relays(&["a"]);
        storage
            .wipe_all_profiles(&keys.public_key(), &blank, &pool, &pool, 1_003)
            .unwrap();

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
            event_created_at: i64::try_from(FAR).unwrap() + 5_000,
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

    // ======================================================================
    // Instant save: the coverage ledger, the local photo removal, the
    // retry pacing.
    // ======================================================================

    use nostr::{Event, JsonUtil, ToBech32};

    /// Far enough ahead of the wall clock that the profile builder stamps
    /// exactly `FAR + offset`, so an event's `created_at` is a test input.
    const FAR: u64 = 4_000_000_000;
    /// The `now` of [`commit_new`].
    const NOW: i64 = 1_001;

    fn meta(name: &str) -> ProfileMetadata {
        ProfileMetadata::from_metadata(nostr::Metadata::new().display_name(name))
    }

    fn meta_with_picture(name: &str, url: &str) -> ProfileMetadata {
        ProfileMetadata::from_metadata(
            nostr::Metadata::new()
                .display_name(name)
                .picture(nostr::Url::parse(url).expect("a url")),
        )
    }

    fn kind0_at(keys: &Keys, metadata: &ProfileMetadata, offset: u64) -> Event {
        crate::profile::build_metadata_event(keys, metadata, Some(FAR + offset - 1))
            .expect("sign kind0")
    }

    fn ts(event: &Event) -> i64 {
        i64::try_from(event.created_at.as_secs()).expect("a timestamp")
    }

    fn relays(names: &[&str]) -> Vec<String> {
        names.iter().map(|n| format!("wss://{n}.example")).collect()
    }

    fn sorted(mut urls: Vec<String>) -> Vec<String> {
        urls.sort();
        urls
    }

    /// Commits `event` as the publish of `version`; `merged` is what the event
    /// carries.
    fn commit_new(
        storage: &CircleStorage,
        keys: &Keys,
        version: i64,
        event: &Event,
        covered: &[String],
        pool: &[String],
        complete: bool,
    ) -> Result<CachedProfile> {
        let merged = ProfileMetadata::from_metadata(
            nostr::Metadata::from_json(&event.content).expect("content is metadata"),
        );
        storage.commit_profile_sync(&ProfileSyncCommit {
            pubkey: &keys.public_key(),
            version,
            merged: &merged,
            event,
            uploaded_picture: None,
            covered,
            pool,
            complete,
            now: NOW,
        })
    }

    fn version_of(storage: &CircleStorage, pubkey_hex: &str) -> i64 {
        storage
            .pending_profile_sync(pubkey_hex)
            .unwrap()
            .expect("something is pending")
            .local_version
    }

    fn debt_rows(storage: &CircleStorage) -> i64 {
        storage
            .conn()
            .lock()
            .unwrap()
            .query_row("SELECT COUNT(*) FROM profile_publish_debt", [], |r| {
                r.get(0)
            })
            .unwrap()
    }

    /// Stages a name, then records a publish of it that only the first relay of
    /// `pool` took: a debt row at the returned version.
    fn owe_event(storage: &CircleStorage, keys: &Keys, pool: &[String]) -> (i64, Event) {
        let hex = keys.public_key().to_hex();
        storage
            .stage_own_profile_edits(&hex, &name_edit("Owed"), 1_000)
            .unwrap();
        let version = version_of(storage, &hex);
        let event = kind0_at(keys, &meta("Owed"), 1);
        commit_new(storage, keys, version, &event, &pool[..1], pool, true).unwrap();
        (version, event)
    }

    fn own_row_with_picture(storage: &CircleStorage, hex: &str, url: &str) {
        storage
            .upsert_profile(&CachedProfile {
                pubkey_hex: hex.to_string(),
                metadata: meta_with_picture("Me", url),
                state: ProfileState::Known,
                event_created_at: 500,
                fetched_at: 600,
            })
            .unwrap();
    }

    // ---- the local photo removal -------------------------------------------

    #[test]
    fn a_removal_clears_the_picture_locally_in_one_transaction() {
        // Both kinds of bytes a removal can find: a published picture, and one
        // staged for an upload that has not happened.
        for staged_only in [false, true] {
            let storage = storage();
            let hex = Keys::generate().public_key().to_hex();
            own_row_with_picture(&storage, &hex, "https://blossom.example/abc");
            storage
                .stage_own_profile_edits(&hex, &name_edit("Me"), 650)
                .unwrap();
            storage.record_profile_sync_attempt(&hex, 650).unwrap();
            if staged_only {
                storage
                    .stage_own_profile_picture(&hex, &staged(b"c", b"t"), 700)
                    .unwrap();
            } else {
                storage
                    .upsert_profile_picture(
                        &hex,
                        "https://blossom.example/abc",
                        &[0x11; 32],
                        b"c",
                        b"t",
                        1,
                    )
                    .unwrap();
            }
            storage.record_profile_sync_attempt(&hex, 700).unwrap();
            let (before, ..) = raw(&storage, &hex).unwrap();

            let row = storage.stage_own_picture_removal(&hex, 800).unwrap();

            assert!(
                storage.get_profile_picture(&hex).unwrap().is_none(),
                "the bytes are gone (staged_only={staged_only})"
            );
            assert_eq!(storage.get_profile_picture_url(&hex).unwrap(), None);
            assert!(!storage.profile_picture_is_staged(&hex).unwrap());
            assert_eq!(
                row.metadata.picture(),
                None,
                "the avatar falls back at once"
            );
            assert_eq!(row.metadata.display_name(), Some("Me"));
            assert_eq!(
                (row.event_created_at, row.fetched_at),
                (500, 600),
                "a local edit moves neither the supersede floor nor the staleness clock"
            );
            let stored = storage.get_profile(&hex).unwrap().unwrap();
            assert_eq!(
                stored.metadata, row.metadata,
                "the row returned is the row stored"
            );

            let snapshot = storage
                .pending_profile_sync(&hex)
                .unwrap()
                .expect("pending");
            assert_eq!(snapshot.local_version, before + 1);
            assert!(snapshot.edits.clear_picture);
            assert_eq!(snapshot.edits.clear_version, snapshot.local_version);
            assert!(!snapshot.picture_staged);
            let (_, _, _, attempts, next_retry_at) = raw(&storage, &hex).unwrap();
            assert_eq!((attempts, next_retry_at), (0, 0), "the ladder is reset");
            assert!(storage.profile_pending_state(&hex, 800).unwrap().retry_due);
        }
    }

    #[test]
    fn a_removal_that_cannot_finish_leaves_everything_as_it_was() {
        // The bytes, the row's picture, the pending clear and the version bump
        // land together or not at all: a removal that dropped the bytes and
        // lost the clear would leave the photo public with nothing owed.
        let storage = storage();
        let hex = Keys::generate().public_key().to_hex();
        own_row_with_picture(&storage, &hex, "https://blossom.example/abc");
        storage
            .upsert_profile_picture(
                &hex,
                "https://blossom.example/abc",
                &[0x11; 32],
                b"c",
                b"t",
                1,
            )
            .unwrap();
        storage
            .stage_own_profile_edits(&hex, &name_edit("Me"), 650)
            .unwrap();
        let before = raw(&storage, &hex).unwrap();
        storage
            .conn()
            .lock()
            .unwrap()
            .execute_batch(
                "CREATE TRIGGER refused_insert BEFORE INSERT ON profile_sync_state
                 BEGIN SELECT RAISE(ABORT, 'refused'); END;
                 CREATE TRIGGER refused_update BEFORE UPDATE ON profile_sync_state
                 BEGIN SELECT RAISE(ABORT, 'refused'); END;",
            )
            .unwrap();

        assert!(
            storage.stage_own_picture_removal(&hex, 800).is_err(),
            "anti-vacuity: the outbox write was refused"
        );

        assert!(storage.get_profile_picture(&hex).unwrap().is_some());
        assert_eq!(
            storage
                .get_profile(&hex)
                .unwrap()
                .unwrap()
                .metadata
                .picture(),
            Some("https://blossom.example/abc")
        );
        assert_eq!(raw(&storage, &hex).unwrap(), before);
        assert!(
            !storage
                .pending_profile_sync(&hex)
                .unwrap()
                .unwrap()
                .edits
                .clear_picture
        );
    }

    #[test]
    fn a_removal_keeps_a_pending_name_edit() {
        // "Remove my photo" and "rename me" are independent saves.
        let storage = storage();
        storage
            .stage_own_profile_edits(&hex(), &name_edit("Alice"), 1_000)
            .unwrap();
        storage
            .stage_own_profile_picture(&hex(), &staged(b"c", b"t"), 1_001)
            .unwrap();

        storage.stage_own_picture_removal(&hex(), 1_002).unwrap();

        assert!(storage.get_profile_picture(&hex()).unwrap().is_none());
        assert!(!storage.profile_picture_is_staged(&hex()).unwrap());
        let snapshot = storage
            .pending_profile_sync(&hex())
            .unwrap()
            .expect("pending");
        assert_eq!(snapshot.edits.display_name.as_deref(), Some("Alice"));
        assert!(snapshot.edits.clear_picture && !snapshot.picture_staged);
        assert_eq!(snapshot.local_version, 3);
    }

    #[test]
    fn a_new_photo_staged_after_a_removal_keeps_the_removal_pending_until_a_picture_is_published() {
        // Remove A, pick B, then B's upload fails or the app is offline: A's
        // removal must still go out with the next pass, or A would be signed
        // back onto every relay.
        let storage = storage();
        own_row_with_picture(&storage, &hex(), "https://blossom.example/a");
        storage.stage_own_picture_removal(&hex(), 1_000).unwrap();
        storage
            .stage_own_profile_picture(&hex(), &staged(b"b", b"b"), 1_001)
            .unwrap();

        let snapshot = storage
            .pending_profile_sync(&hex())
            .unwrap()
            .expect("pending");
        assert!(snapshot.picture_staged);
        assert!(
            snapshot.edits.clear_picture,
            "staging a photo must not forget the removal"
        );
        assert_eq!(snapshot.edits.clear_version, 1);
        assert_eq!(snapshot.local_version, 2);
        assert_eq!(
            snapshot
                .edits
                .to_edits(Some("https://blossom.example/b".to_string()))
                .picture
                .as_deref(),
            Some("https://blossom.example/b"),
            "once B is uploaded its URL is what publishes"
        );
        assert_eq!(
            snapshot.edits.to_edits(None).picture.as_deref(),
            Some(""),
            "until then the removal is what publishes"
        );
    }

    #[test]
    fn a_removal_staged_after_a_new_photo_gets_a_newer_clear_version() {
        let storage = storage();
        storage
            .stage_own_profile_picture(&hex(), &staged(b"a", b"a"), 1_000)
            .unwrap();
        storage.stage_own_picture_removal(&hex(), 1_001).unwrap();
        storage
            .stage_own_profile_picture(&hex(), &staged(b"b", b"b"), 1_002)
            .unwrap();
        storage.stage_own_picture_removal(&hex(), 1_003).unwrap();

        let snapshot = storage
            .pending_profile_sync(&hex())
            .unwrap()
            .expect("pending");
        assert_eq!(
            (snapshot.local_version, snapshot.edits.clear_version),
            (4, 4)
        );
        assert!(!snapshot.picture_staged);
    }

    #[test]
    fn the_resigned_mark_holds_only_its_version_and_every_staging_resets_it() {
        type Stage = fn(&CircleStorage);
        let storage = storage();
        let resigned = |storage: &CircleStorage| {
            storage
                .pending_profile_sync(&hex())
                .unwrap()
                .expect("pending")
                .edits
                .resigned
        };
        storage
            .stage_own_profile_edits(&hex(), &name_edit("Once"), 1_000)
            .unwrap();
        storage.mark_profile_resigned(&hex(), 0).unwrap();
        assert!(!resigned(&storage), "a superseded version marks nothing");

        let stagings: [(&str, Stage); 3] = [
            ("a name", |s| {
                s.stage_own_profile_edits(&hex(), &name_edit("Again"), 1_001)
                    .map(drop)
                    .unwrap();
            }),
            ("a photo", |s| {
                s.stage_own_profile_picture(&hex(), &staged(b"p", b"p"), 1_001)
                    .unwrap();
            }),
            ("a removal", |s| {
                s.stage_own_picture_removal(&hex(), 1_001)
                    .map(drop)
                    .unwrap();
            }),
        ];
        for (what, stage) in stagings {
            let version = version_of(&storage, &hex());
            storage.mark_profile_resigned(&hex(), version).unwrap();
            assert!(
                resigned(&storage),
                "the mark holds for {what}'s predecessor"
            );
            stage(&storage);
            assert!(!resigned(&storage), "staging {what} must reset the mark");
        }
    }

    #[test]
    fn a_fetch_while_a_removal_is_pending_does_not_bring_the_picture_back() {
        let storage = storage();
        own_row_with_picture(&storage, &hex(), "https://blossom.example/abc");
        storage.stage_own_picture_removal(&hex(), 1_000).unwrap();

        let fetched = CachedProfile {
            pubkey_hex: hex(),
            metadata: meta_with_picture("Other Client", "https://blossom.example/abc"),
            state: ProfileState::Known,
            event_created_at: 5_000,
            fetched_at: 5_000,
        };
        assert!(storage.upsert_profile_if_newer(&fetched).unwrap());

        let stored = storage.get_profile(&hex()).unwrap().unwrap();
        assert_eq!(stored.metadata.picture(), None, "the removal is re-applied");
        assert_eq!(
            stored.metadata.display_name(),
            Some("Other Client"),
            "everything else is the relay's"
        );
        assert_eq!(stored.event_created_at, 5_000);
    }

    // ---- what clears a pending removal -------------------------------------

    #[test]
    fn a_commit_at_or_after_the_removal_clears_it_and_an_older_one_does_not() {
        let pool = relays(&["a", "b"]);
        for complete in [true, false] {
            // The commit's version is the removal's: the removal went out.
            let storage = storage();
            let keys = Keys::generate();
            let hex = keys.public_key().to_hex();
            own_row_with_picture(&storage, &hex, "https://blossom.example/a");
            storage.stage_own_picture_removal(&hex, 1_000).unwrap();
            let event = kind0_at(&keys, &meta("Me"), 1);
            commit_new(&storage, &keys, 1, &event, &pool[..1], &pool, complete).unwrap();
            let snapshot = storage
                .pending_profile_sync(&hex)
                .unwrap()
                .expect("partial");
            assert!(
                !snapshot.edits.clear_picture,
                "a relay took the removal (complete={complete}); it must not be sent again"
            );

            // A text edit before the removal: its commit predates the removal.
            let storage = self::storage();
            storage
                .stage_own_profile_edits(&hex, &name_edit("Me"), 1_000)
                .unwrap();
            storage.stage_own_picture_removal(&hex, 1_001).unwrap();
            commit_new(&storage, &keys, 1, &event, &pool[..1], &pool, complete).unwrap();
            let snapshot = storage
                .pending_profile_sync(&hex)
                .unwrap()
                .expect("pending");
            assert!(
                snapshot.edits.clear_picture,
                "a publish of version 1 must not retire the removal staged as version 2 \
                 (complete={complete})"
            );
            assert_eq!(snapshot.edits.clear_version, 2);

            // A text edit after the removal carries the removal: its commit is
            // at or after it.
            let storage = self::storage();
            storage.stage_own_picture_removal(&hex, 1_000).unwrap();
            storage
                .stage_own_profile_edits(&hex, &name_edit("Me"), 1_001)
                .unwrap();
            commit_new(&storage, &keys, 2, &event, &pool[..1], &pool, complete).unwrap();
            let snapshot = storage
                .pending_profile_sync(&hex)
                .unwrap()
                .expect("pending");
            assert!(!snapshot.edits.clear_picture, "complete={complete}");
        }
    }

    /// Remove photo A, pick B, and publish B to one relay of two.
    fn a_new_photo_published_to_one_relay_of_two() -> (CircleStorage, Keys, String) {
        let storage = storage();
        let keys = Keys::generate();
        let hex = keys.public_key().to_hex();
        let pool = relays(&["a", "b"]);
        own_row_with_picture(&storage, &hex, "https://blossom.example/a");
        storage.stage_own_picture_removal(&hex, 1_000).unwrap();
        let b = staged(b"b-canonical", b"b-thumb");
        storage.stage_own_profile_picture(&hex, &b, 1_001).unwrap();
        let url = "https://blossom.example/b";
        let merged = meta_with_picture("Me", url);
        let event = kind0_at(&keys, &merged, 1);
        storage
            .commit_profile_sync(&ProfileSyncCommit {
                pubkey: &keys.public_key(),
                version: 2,
                merged: &merged,
                event: &event,
                uploaded_picture: Some((url, b.sha256().as_slice())),
                covered: &pool[..1],
                pool: &pool,
                complete: true,
                now: NOW,
            })
            .unwrap();
        (storage, keys, hex)
    }

    #[test]
    fn a_partially_published_new_photo_clears_the_removal_and_keeps_its_url_on_the_row() {
        let (storage, _keys, hex) = a_new_photo_published_to_one_relay_of_two();

        let snapshot = storage
            .pending_profile_sync(&hex)
            .unwrap()
            .expect("partial");
        assert!(
            !snapshot.edits.clear_picture,
            "B went out; the removal of A is behind it"
        );
        assert_eq!(
            storage.get_profile_picture_url(&hex).unwrap().as_deref(),
            Some("https://blossom.example/b")
        );
        assert_eq!(
            &*storage.get_profile_picture(&hex).unwrap().unwrap(),
            b"b-canonical"
        );
        assert_eq!(
            storage
                .get_profile(&hex)
                .unwrap()
                .unwrap()
                .metadata
                .picture(),
            Some("https://blossom.example/b"),
            "a removal still pending would strip B from the row on every re-apply"
        );
    }

    #[test]
    fn a_later_upload_failure_never_publishes_an_empty_picture_after_a_photo_url_was_published() {
        let (storage, _keys, hex) = a_new_photo_published_to_one_relay_of_two();

        // The next pass finds Blossom down: it publishes the text alone.
        let snapshot = storage
            .pending_profile_sync(&hex)
            .unwrap()
            .expect("partial");
        assert_eq!(
            snapshot.edits.to_edits(None).picture,
            None,
            "an empty picture would remove B from every relay"
        );
    }

    #[test]
    fn an_upload_failure_after_a_removal_publishes_the_removal_not_the_old_picture() {
        let storage = storage();
        let keys = Keys::generate();
        let hex = keys.public_key().to_hex();
        let pool = relays(&["a", "b"]);
        own_row_with_picture(&storage, &hex, "https://blossom.example/a");
        storage
            .upsert_profile_picture(
                &hex,
                "https://blossom.example/a",
                &[0x11; 32],
                b"a",
                b"a",
                1,
            )
            .unwrap();
        storage.stage_own_picture_removal(&hex, 1_000).unwrap();
        storage
            .stage_own_profile_picture(&hex, &staged(b"b", b"b"), 1_001)
            .unwrap();

        // Blossom is down for B: the pass publishes with no uploaded URL.
        let edits = storage.pending_profile_sync(&hex).unwrap().unwrap().edits;
        assert_eq!(
            edits.to_edits(None).picture.as_deref(),
            Some(""),
            "'untouched' would leave A on every relay the pass reaches"
        );
        let event = kind0_at(&keys, &meta("Me"), 1);
        commit_new(&storage, &keys, 2, &event, &pool[..1], &pool, false).unwrap();

        let snapshot = storage
            .pending_profile_sync(&hex)
            .unwrap()
            .expect("B is owed");
        assert!(snapshot.picture_staged, "B is still waiting for its upload");
        assert!(!snapshot.edits.clear_picture, "A's removal went out");
        assert_eq!(
            snapshot.edits.to_edits(None).picture,
            None,
            "and a second failure must not publish it again as an empty picture"
        );
        assert_eq!(
            debt_rows(&storage),
            0,
            "a text-only publish is no complete event"
        );
        assert_eq!(
            storage
                .get_profile(&hex)
                .unwrap()
                .unwrap()
                .metadata
                .picture(),
            None
        );
        assert_eq!(
            &*storage.get_profile_picture(&hex).unwrap().unwrap(),
            b"b",
            "B's staged bytes are kept"
        );
    }

    #[test]
    fn a_commit_that_raced_a_removal_never_puts_the_removed_picture_back() {
        // Photo A is uploaded and its publish is in flight when the user
        // removes it. The commit that follows must neither re-create the
        // deleted bytes nor retire the newer removal.
        let storage = storage();
        let keys = Keys::generate();
        let hex = keys.public_key().to_hex();
        let pool = relays(&["a", "b"]);
        let a = staged(b"a-canonical", b"a-thumb");
        storage.stage_own_profile_picture(&hex, &a, 1_000).unwrap();
        storage.stage_own_picture_removal(&hex, 1_001).unwrap();
        let url = "https://blossom.example/a";
        let merged = meta_with_picture("Me", url);
        let event = kind0_at(&keys, &merged, 1);

        storage
            .commit_profile_sync(&ProfileSyncCommit {
                pubkey: &keys.public_key(),
                version: 1,
                merged: &merged,
                event: &event,
                uploaded_picture: Some((url, a.sha256().as_slice())),
                covered: &pool,
                pool: &pool,
                complete: true,
                now: NOW,
            })
            .unwrap();

        assert!(
            storage.get_profile_picture(&hex).unwrap().is_none(),
            "the commit resurrected the bytes the user removed"
        );
        let snapshot = storage
            .pending_profile_sync(&hex)
            .unwrap()
            .expect("removal owed");
        assert!(
            snapshot.edits.clear_picture,
            "the newer removal is still owed"
        );
        assert_eq!(
            storage
                .get_profile(&hex)
                .unwrap()
                .unwrap()
                .metadata
                .picture(),
            None,
            "the row keeps the removal over the event that carried the picture"
        );
    }

    // ---- the owed event ----------------------------------------------------

    #[test]
    fn every_staging_discards_the_owed_event() {
        // A re-send of a superseded event could resurrect an old profile on a
        // relay that missed the later one.
        let pool = relays(&["a", "b"]);
        for op in ["edit", "picture", "removal", "reset"] {
            let storage = storage();
            let keys = Keys::generate();
            let hex = keys.public_key().to_hex();
            let (version, _) = owe_event(&storage, &keys, &pool);
            assert!(
                storage
                    .profile_publish_debt(&keys.public_key(), version)
                    .unwrap()
                    .is_some(),
                "anti-vacuity: the event is owed before `{op}`"
            );

            match op {
                "edit" => {
                    storage
                        .stage_own_profile_edits(&hex, &name_edit("Later"), 2_000)
                        .unwrap();
                }
                "picture" => storage
                    .stage_own_profile_picture(&hex, &staged(b"c", b"t"), 2_000)
                    .unwrap(),
                "removal" => {
                    storage.stage_own_picture_removal(&hex, 2_000).unwrap();
                }
                _ => storage.clear_profile_sync_state(&hex).unwrap(),
            }

            assert_eq!(debt_rows(&storage), 0, "`{op}` left the owed event behind");
            assert!(storage
                .profile_publish_debt(&keys.public_key(), version)
                .unwrap()
                .is_none());
        }
    }

    #[test]
    fn the_owed_event_is_written_only_with_an_acknowledgement_and_only_for_the_current_version() {
        let pool = relays(&["a", "b"]);

        // Nothing staged, nothing recorded: no row from a save alone.
        let storage1 = storage();
        let keys = Keys::generate();
        let hex = keys.public_key().to_hex();
        storage1
            .stage_own_profile_edits(&hex, &name_edit("Owed"), 1_000)
            .unwrap();
        assert!(storage1
            .profile_publish_debt(&keys.public_key(), 1)
            .unwrap()
            .is_none());

        // A text-only publish (the upload failed) is not a complete event.
        let event = kind0_at(&keys, &meta("Owed"), 1);
        commit_new(&storage1, &keys, 1, &event, &pool[..1], &pool, false).unwrap();
        assert_eq!(debt_rows(&storage1), 0);
        assert_eq!(
            raw(&storage1, &hex).unwrap().2,
            1,
            "but a relay did take it"
        );

        // A complete event for a version a later save has passed.
        let storage2 = self::storage();
        storage2
            .stage_own_profile_edits(&hex, &name_edit("Owed"), 1_000)
            .unwrap();
        storage2
            .stage_own_profile_edits(&hex, &name_edit("Owed v2"), 1_001)
            .unwrap();
        commit_new(&storage2, &keys, 1, &event, &pool[..1], &pool, true).unwrap();
        assert_eq!(
            debt_rows(&storage2),
            0,
            "the event no longer carries every pending item"
        );

        // A complete event every relay took owes nothing.
        let storage3 = self::storage();
        storage3
            .stage_own_profile_edits(&hex, &name_edit("Owed"), 1_000)
            .unwrap();
        commit_new(&storage3, &keys, 1, &event, &pool, &pool, true).unwrap();
        assert_eq!(debt_rows(&storage3), 0);

        // A complete event some relay took is owed to the rest, for its version.
        let storage4 = self::storage();
        let (version, owed) = owe_event(&storage4, &keys, &pool);
        let debt = storage4
            .profile_publish_debt(&keys.public_key(), version)
            .unwrap()
            .expect("a complete event one relay of two took is owed");
        assert_eq!(debt.version, version);
        assert_eq!(debt.event, owed);
        assert_eq!(debt.covered, pool[..1].to_vec());
        assert!(storage4
            .profile_publish_debt(&keys.public_key(), version + 1)
            .unwrap()
            .is_none());
    }

    #[test]
    fn a_partial_commit_keeps_the_edit_pending_and_records_its_coverage() {
        let storage = storage();
        let keys = Keys::generate();
        let hex = keys.public_key().to_hex();
        let pool = relays(&["a", "b"]);
        let (version, _) = owe_event(&storage, &keys, &pool);

        let state = storage.profile_pending_state(&hex, NOW).unwrap();
        assert!(state.pending, "a partial publish is not synced");
        assert!(!state.retry_due, "and the ladder paces the re-send");
        assert_eq!(
            raw(&storage, &hex).unwrap(),
            (version, 0, version, 1, NOW + PROFILE_SYNC_BACKOFF_SECS[0])
        );
        assert_eq!(
            storage.pending_profile_sync(&hex).unwrap().unwrap().edits,
            name_edit("Owed"),
            "the pending set survives so a fresh signing would carry it"
        );
        assert_eq!(debt_rows(&storage), 1);
        assert_eq!(
            storage
                .profile_publish_debt(&keys.public_key(), version)
                .unwrap()
                .expect("owed to the relay that did not take it")
                .covered,
            pool[..1].to_vec(),
            "the relay that acknowledged is the one recorded as serving it"
        );
    }

    #[test]
    fn a_full_commit_clears_the_outbox_and_deletes_the_debt() {
        let storage = storage();
        let keys = Keys::generate();
        let hex = keys.public_key().to_hex();
        let pool = relays(&["a", "b"]);
        let (version, event) = owe_event(&storage, &keys, &pool);
        assert_eq!(debt_rows(&storage), 1);

        let row = commit_new(&storage, &keys, version, &event, &pool, &pool, true).unwrap();

        assert!(storage.pending_profile_sync(&hex).unwrap().is_none());
        assert_eq!(debt_rows(&storage), 0);
        assert_eq!(
            raw(&storage, &hex).unwrap(),
            (version, version, version, 0, 0)
        );
        assert_eq!(row.event_created_at, ts(&event));
        assert_eq!(
            storage
                .last_published_event(0, "", &keys.public_key())
                .unwrap()
                .map(|record| record.event_id),
            Some(event.id)
        );
    }

    #[test]
    fn a_commit_returns_the_row_it_stored() {
        // The sanitizer rewrites a name on the way into the row, and the row
        // the UI renders is the one stored.
        let storage = storage();
        let keys = Keys::generate();
        let pool = relays(&["a"]);
        let merged = meta("Ada\u{202E}  Lovelace");
        let event = kind0_at(&keys, &merged, 1);
        let row = storage
            .commit_profile_sync(&ProfileSyncCommit {
                pubkey: &keys.public_key(),
                version: 1,
                merged: &merged,
                event: &event,
                uploaded_picture: None,
                covered: &pool,
                pool: &pool,
                complete: true,
                now: NOW,
            })
            .unwrap();
        assert_eq!(row.metadata.display_name(), Some("Ada Lovelace"));
        let stored = storage
            .get_profile(&keys.public_key().to_hex())
            .unwrap()
            .unwrap();
        assert_eq!(stored.metadata, row.metadata);
        assert_eq!(row.event_created_at, ts(&event));
        assert_eq!(
            (stored.event_created_at, stored.fetched_at),
            (row.event_created_at, row.fetched_at)
        );
    }

    #[test]
    fn coverage_completes_only_when_every_pool_relay_is_covered() {
        let storage = storage();
        let keys = Keys::generate();
        let hex = keys.public_key().to_hex();
        let pool = relays(&["a", "b", "c"]);
        let (version, event) = owe_event(&storage, &keys, &pool);

        storage
            .commit_profile_coverage(&hex, version, &pool[1..2], &pool, 2_000)
            .unwrap();

        let debt = storage
            .profile_publish_debt(&keys.public_key(), version)
            .unwrap()
            .expect("one relay is still owed");
        assert_eq!(sorted(debt.covered), sorted(pool[..2].to_vec()));
        assert_eq!(debt.event, event, "the owed event is never re-signed");
        assert!(storage.profile_pending_state(&hex, 2_000).unwrap().pending);
        let (_, synced, _, attempts, next_retry_at) = raw(&storage, &hex).unwrap();
        assert_eq!(synced, 0);
        assert_eq!(
            attempts, 2,
            "a pass that leaves a relay owed advances the ladder"
        );
        assert_eq!(next_retry_at, 2_000 + PROFILE_SYNC_BACKOFF_SECS[1]);

        storage
            .commit_profile_coverage(&hex, version, &pool[2..], &pool, 3_000)
            .unwrap();

        assert!(storage.pending_profile_sync(&hex).unwrap().is_none());
        assert_eq!(debt_rows(&storage), 0);
        assert_eq!(
            raw(&storage, &hex).unwrap(),
            (version, version, version, 0, 0)
        );
        assert!(!storage.profile_pending_state(&hex, 3_000).unwrap().pending);
    }

    #[test]
    fn coverage_for_a_superseded_version_changes_nothing() {
        let pool = relays(&["a", "b"]);

        // A save after the debt was written supersedes it.
        let storage = storage();
        let keys = Keys::generate();
        let hex = keys.public_key().to_hex();
        let (version, _) = owe_event(&storage, &keys, &pool);
        storage
            .stage_own_profile_edits(&hex, &name_edit("Later"), 1_500)
            .unwrap();
        let before = raw(&storage, &hex).unwrap();
        storage
            .commit_profile_coverage(&hex, version, &pool[1..], &pool, 2_000)
            .unwrap();
        assert_eq!(raw(&storage, &hex).unwrap(), before);
        assert_eq!(
            storage.pending_profile_sync(&hex).unwrap().unwrap().edits,
            name_edit("Later")
        );

        // A debt discarded for a redirect cannot be completed by a stale pass.
        let storage = self::storage();
        let (version, _) = owe_event(&storage, &keys, &pool);
        storage.discard_profile_publish_debt(&hex, version).unwrap();
        assert_eq!(debt_rows(&storage), 0);
        let before = raw(&storage, &hex).unwrap();
        storage
            .commit_profile_coverage(&hex, version, &pool[1..], &pool, 2_000)
            .unwrap();
        assert_eq!(raw(&storage, &hex).unwrap(), before);
        assert!(storage.profile_pending_state(&hex, 2_000).unwrap().pending);
    }

    #[test]
    fn a_pool_that_shrank_inside_the_covered_set_completes_the_debt() {
        // A relay that left the pool (retired, removed by the user) ends its
        // debt with no network.
        let storage = storage();
        let keys = Keys::generate();
        let hex = keys.public_key().to_hex();
        let pool = relays(&["a", "b"]);
        let (version, _) = owe_event(&storage, &keys, &pool);

        storage
            .commit_profile_coverage(&hex, version, &[], &pool[..1], 2_000)
            .unwrap();

        assert!(storage.pending_profile_sync(&hex).unwrap().is_none());
        assert_eq!(debt_rows(&storage), 0);
        assert_eq!(
            raw(&storage, &hex).unwrap(),
            (version, version, version, 0, 0)
        );
    }

    #[test]
    fn an_owed_event_older_than_the_cached_row_is_superseded() {
        // Another client's newer profile was cached after our event went out:
        // re-sending ours would be a stale event onto a relay that moved on.
        let storage = storage();
        let keys = Keys::generate();
        let hex = keys.public_key().to_hex();
        let pool = relays(&["a", "b"]);
        let (version, _) = owe_event(&storage, &keys, &pool);
        assert!(
            storage
                .profile_publish_debt(&keys.public_key(), version)
                .unwrap()
                .is_some(),
            "anti-vacuity: the event is loadable while it is the newest"
        );

        assert!(storage
            .upsert_profile_if_newer(&CachedProfile {
                pubkey_hex: hex,
                metadata: meta("Other Client"),
                state: ProfileState::Known,
                event_created_at: i64::try_from(FAR + 50).unwrap(),
                fetched_at: 3_000,
            })
            .unwrap());

        assert!(storage
            .profile_publish_debt(&keys.public_key(), version)
            .unwrap()
            .is_none());
        assert_eq!(debt_rows(&storage), 0, "the superseded row is discarded");
    }

    #[tokio::test]
    async fn an_owed_event_that_does_not_verify_is_discarded_and_its_line_names_nothing() {
        let pool = relays(&["a", "b"]);
        for corrupt in ["tampered", "not json"] {
            let storage = storage();
            let keys = Keys::generate();
            let (version, event) = owe_event(&storage, &keys, &pool);
            let stored = if corrupt == "tampered" {
                event.as_json().replace("Owed", "Tampered")
            } else {
                "{not json".to_string()
            };
            assert_ne!(stored, event.as_json());
            storage
                .conn()
                .lock()
                .unwrap()
                .execute(
                    "UPDATE profile_publish_debt SET event_json = ?1",
                    params![stored],
                )
                .unwrap();

            let lines = crate::test_log::capture_log_lines(async {
                assert!(
                    storage
                        .profile_publish_debt(&keys.public_key(), version)
                        .unwrap()
                        .is_none(),
                    "{corrupt}: an event that does not verify must not be sent"
                );
            })
            .await;

            assert_eq!(debt_rows(&storage), 0, "{corrupt}: the row is discarded");
            assert!(
                !lines.is_empty(),
                "{corrupt}: the discard has to have spoken for its silence to mean anything"
            );
            let own_hex = keys.public_key().to_hex();
            let id_hex = event.id.to_hex();
            let npub = keys.public_key().to_bech32().unwrap();
            let needles = [
                own_hex.as_str(),
                &own_hex[..8],
                id_hex.as_str(),
                &id_hex[..8],
                npub.as_str(),
                "wss://",
                "Tampered",
            ];
            for line in &lines {
                for needle in needles {
                    assert!(
                        !line.to_lowercase().contains(&needle.to_lowercase()),
                        "{corrupt}: a log line named `{needle}`: {line}"
                    );
                }
            }
        }
    }

    // ---- the upload's re-stamp ---------------------------------------------

    #[test]
    fn a_restamp_never_puts_an_old_url_on_newly_staged_bytes() {
        let storage = storage();
        let keys = Keys::generate();
        let hex = keys.public_key().to_hex();
        let pool = relays(&["a"]);
        let a = staged(b"a-canonical", b"a-thumb");
        let b = staged(b"b-canonical", b"b-thumb");
        storage.stage_own_profile_picture(&hex, &a, 1_000).unwrap();
        // The user picks B while A's publish is in flight.
        storage.stage_own_profile_picture(&hex, &b, 1_001).unwrap();

        let url_a = "https://blossom.example/a";
        let merged = meta_with_picture("Me", url_a);
        let event = kind0_at(&keys, &merged, 1);
        storage
            .commit_profile_sync(&ProfileSyncCommit {
                pubkey: &keys.public_key(),
                version: 1,
                merged: &merged,
                event: &event,
                uploaded_picture: Some((url_a, a.sha256().as_slice())),
                covered: &pool,
                pool: &pool,
                complete: true,
                now: NOW,
            })
            .unwrap();

        assert_eq!(
            storage.get_profile_picture_url(&hex).unwrap().as_deref(),
            Some(""),
            "B's bytes were stamped with A's URL, so B would read as published \
             and never be uploaded"
        );
        assert_eq!(
            &*storage.get_profile_picture(&hex).unwrap().unwrap(),
            b"b-canonical"
        );
        assert!(
            storage.profile_picture_is_staged(&hex).unwrap(),
            "B is still waiting for its upload"
        );

        // Anti-vacuity: the commit for the bytes that ARE staged stamps them.
        let url_b = "https://blossom.example/b";
        let merged = meta_with_picture("Me", url_b);
        let event = kind0_at(&keys, &merged, 2);
        storage
            .commit_profile_sync(&ProfileSyncCommit {
                pubkey: &keys.public_key(),
                version: 2,
                merged: &merged,
                event: &event,
                uploaded_picture: Some((url_b, b.sha256().as_slice())),
                covered: &pool,
                pool: &pool,
                complete: true,
                now: NOW,
            })
            .unwrap();
        assert_eq!(
            storage.get_profile_picture_url(&hex).unwrap().as_deref(),
            Some(url_b)
        );
        assert!(!storage.profile_picture_is_staged(&hex).unwrap());
    }

    // ---- settling ------------------------------------------------------------

    #[test]
    fn settling_an_unpublishable_removal_leaves_nothing_pending() {
        let storage = storage();
        storage
            .stage_own_profile_picture(&hex(), &staged(b"c", b"t"), 1_000)
            .unwrap();
        storage.stage_own_picture_removal(&hex(), 1_001).unwrap();
        storage.record_profile_sync_attempt(&hex(), 1_002).unwrap();
        let version = version_of(&storage, &hex());

        storage.settle_profile_sync(&hex(), version).unwrap();

        assert!(storage.pending_profile_sync(&hex()).unwrap().is_none());
        assert_eq!(
            raw(&storage, &hex()).unwrap(),
            (version, version, version, 0, 0),
            "levelled, and the ladder reset"
        );
        // The pending set is empty: nothing of the removal rides the next save.
        storage
            .stage_own_profile_edits(&hex(), &name_edit("Alice"), 2_000)
            .unwrap();
        let next = storage.pending_profile_sync(&hex()).unwrap().unwrap();
        assert!(!next.edits.clear_picture);
        assert_eq!(next.edits.display_name.as_deref(), Some("Alice"));
    }

    #[test]
    fn settling_a_version_a_later_save_has_passed_changes_nothing() {
        let storage = storage();
        storage.stage_own_picture_removal(&hex(), 1_000).unwrap();
        let version = version_of(&storage, &hex());
        storage
            .stage_own_profile_edits(&hex(), &name_edit("Alice"), 1_001)
            .unwrap();
        let before = raw(&storage, &hex()).unwrap();

        storage.settle_profile_sync(&hex(), version).unwrap();

        assert_eq!(raw(&storage, &hex()).unwrap(), before);
        assert!(storage.pending_profile_sync(&hex()).unwrap().is_some());
    }

    #[test]
    fn settling_changes_nothing_while_a_photo_is_staged() {
        let storage = storage();
        storage
            .stage_own_profile_picture(&hex(), &staged(b"first", b"t1"), 1_000)
            .unwrap();
        storage.stage_own_picture_removal(&hex(), 1_001).unwrap();
        storage
            .stage_own_profile_picture(&hex(), &staged(b"second", b"t2"), 1_002)
            .unwrap();
        storage.record_profile_sync_attempt(&hex(), 1_003).unwrap();
        let version = version_of(&storage, &hex());
        let before = (
            raw(&storage, &hex()).unwrap(),
            storage.pending_profile_sync(&hex()).unwrap(),
        );

        storage.settle_profile_sync(&hex(), version).unwrap();

        assert_eq!(
            (
                raw(&storage, &hex()).unwrap(),
                storage.pending_profile_sync(&hex()).unwrap(),
            ),
            before,
            "the photo saved after the removal is still owed"
        );
        assert!(before
            .1
            .is_some_and(|s| s.picture_staged && s.edits.clear_picture));
        assert_eq!(
            storage
                .get_profile_picture(&hex())
                .unwrap()
                .as_deref()
                .map(Vec::as_slice),
            Some(&b"second"[..])
        );
    }

    // ---- retry pacing --------------------------------------------------------

    #[test]
    fn next_retry_in_secs_is_relative_and_absent_when_due_or_clean() {
        let storage = storage();
        let keys = Keys::generate();
        let hex = keys.public_key().to_hex();

        // No outbox row: nothing pending, nothing to wait for.
        let state = storage.profile_pending_state(&hex, 1_000).unwrap();
        assert_eq!(
            (state.pending, state.retry_due, state.next_retry_in_secs),
            (false, true, None)
        );

        // Pending and never tried: due now, so no wait is reported.
        storage
            .stage_own_profile_edits(&hex, &name_edit("Alice"), 1_000)
            .unwrap();
        let state = storage.profile_pending_state(&hex, 1_000).unwrap();
        assert_eq!(
            (state.pending, state.retry_due, state.next_retry_in_secs),
            (true, true, None)
        );

        // Pending and backing off: the wait is a duration, counting down.
        storage.record_profile_sync_attempt(&hex, 1_000).unwrap();
        for (now, left) in [(1_000, 30), (1_010, 20), (1_029, 1)] {
            let state = storage.profile_pending_state(&hex, now).unwrap();
            assert!(state.pending && !state.retry_due);
            assert_eq!(state.next_retry_in_secs, Some(left), "now={now}");
        }
        for now in [1_030, 1_031] {
            let state = storage.profile_pending_state(&hex, now).unwrap();
            assert!(state.retry_due);
            assert_eq!(state.next_retry_in_secs, None, "due at now={now}");
        }

        // The longest wait is the longest rung, however often it has failed.
        let last = *PROFILE_SYNC_BACKOFF_SECS.last().unwrap();
        for _ in 0..PROFILE_SYNC_BACKOFF_SECS.len() + 2 {
            storage.record_profile_sync_attempt(&hex, 5_000).unwrap();
        }
        let waiting = storage
            .profile_pending_state(&hex, 5_000)
            .unwrap()
            .next_retry_in_secs;
        assert_eq!(waiting, Some(u32::try_from(last).unwrap()));

        // Clean: nothing pending, so nothing to wait for.
        let event = kind0_at(&keys, &meta("Alice"), 1);
        let pool = relays(&["a"]);
        commit_new(&storage, &keys, 1, &event, &pool, &pool, true).unwrap();
        let state = storage.profile_pending_state(&hex, 5_000).unwrap();
        assert_eq!((state.pending, state.next_retry_in_secs), (false, None));
    }

    #[test]
    fn a_clock_moved_back_past_the_longest_rung_makes_the_retry_due() {
        // `next_retry_at` was dated on a clock that has since been set back.
        // Waiting for it to catch up could be hours; one retry now is the
        // failure to prefer, and it re-dates the ladder from the new clock.
        let storage = storage();
        storage
            .stage_own_profile_edits(&hex(), &name_edit("Alice"), 100_000)
            .unwrap();
        storage
            .record_profile_sync_attempt(&hex(), 100_000)
            .unwrap();
        let next = 100_000 + PROFILE_SYNC_BACKOFF_SECS[0];
        let last = *PROFILE_SYNC_BACKOFF_SECS.last().unwrap();

        // Set back by a little: still waiting, and the wait is what remains.
        let state = storage.profile_pending_state(&hex(), 99_900).unwrap();
        assert!(state.pending && !state.retry_due);
        assert_eq!(state.next_retry_in_secs, Some(130));

        // A wait of exactly the longest rung is legitimate; one second more is
        // a clock that moved.
        let state = storage.profile_pending_state(&hex(), next - last).unwrap();
        assert!(!state.retry_due);
        assert_eq!(state.next_retry_in_secs, Some(u32::try_from(last).unwrap()));
        let state = storage
            .profile_pending_state(&hex(), next - last - 1)
            .unwrap();
        assert!(state.pending && state.retry_due);
        assert_eq!(state.next_retry_in_secs, None);
    }
}
