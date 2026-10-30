//! The two `KeyPackage` facts that are Haven's own.
//!
//! The `KeyPackage` this device tracks — its slot, its bytes, the signed
//! event a relay acknowledged — lives in MDK's lifecycle record
//! ([`crate::nostr::mls::SessionManager::tracked_key_package`]), not here.
//! What stays in `circles-v2.db` is what MDK has no notion of: whether the
//! retirement of a pre-width-fix `d` slot has completed
//! ([`crate::relay::maintenance::decide_kp_slot_retirement`]), and whether an
//! invitation is being held for the user's answer — which a consumed package's
//! replacement waits for, for a bounded time counted from an instant kept
//! here.

// Single-shot SQLite ops naturally hold the lock to completion; the parent
// module already disables this lint at the file level for storage.rs.
#![allow(clippy::significant_drop_tightening)]

use rusqlite::{params, OptionalExtension};

use super::error::{CircleError, Result};
use super::storage::CircleStorage;

/// The Marmot `KeyPackage` event kind (NIP-33 addressable, single kind).
pub const KEY_PACKAGE_KIND: u16 = 30443;

/// `user_settings` key recording that the one-time retirement of a malformed
/// (pre-width-fix) kind-30443 `d` slot has COMPLETED — the account publishes a
/// binding-shaped coordinate and the orphaned one's retraction was acked.
///
/// Written only by a migration that finished; a run that could not publish the
/// replacement, could not get the retraction acked, or reached no relay leaves
/// it unset so the next tick retries (see
/// [`crate::relay::maintenance::decide_kp_slot_retirement`]).
pub const KP_SLOT_RETIREMENT_DONE_KEY: &str = "kp_slot_retirement_done_v1";

/// `user_settings` key recording that an invitation was held and not every
/// held invitation has been answered since.
///
/// The held invitations themselves live in memory only; this survives a
/// restart, when they are gone until the next poll finds them again.
pub const KP_HELD_INVITATION_KEY: &str = "kp_held_invitation_outstanding_v1";

/// `user_settings` key holding the consumed-package hold's record: the Unix
/// second of the first maintenance tick that left a consumed `KeyPackage` in
/// place for a held invitation, from which the hold is counted — or
/// [`CONSUMED_HOLD_OVER`] once that hold has ended. The next acknowledged
/// replacement deletes it.
pub const KP_CONSUMED_HOLD_SINCE_KEY: &str = "kp_consumed_hold_since_v1";

/// The hold start recorded once a hold has ended: no clock reaches it, so no
/// clock movement resumes the hold before the replacement is acknowledged.
pub const CONSUMED_HOLD_OVER: u64 = u64::MAX;

impl CircleStorage {
    /// The consumed-package hold's record: when the hold began, or
    /// [`CONSUMED_HOLD_OVER`] if it has ended; `None` when there is none, or
    /// what is stored cannot be read.
    ///
    /// # Errors
    ///
    /// Returns a database error on failure.
    pub fn consumed_hold_since(&self) -> Result<Option<u64>> {
        let conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        let raw: Option<String> = conn
            .query_row(
                "SELECT value FROM user_settings WHERE key = ?1",
                params![KP_CONSUMED_HOLD_SINCE_KEY],
                |r| r.get::<_, String>(0),
            )
            .optional()?;
        Ok(raw.and_then(|secs| secs.parse().ok()))
    }

    /// Records when the consumed-package hold began, that it has ended
    /// ([`CONSUMED_HOLD_OVER`]), or — `None` — that there is no hold.
    ///
    /// # Errors
    ///
    /// Returns a database error on failure.
    pub fn set_consumed_hold_since(&self, since_secs: Option<u64>) -> Result<()> {
        let conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        match since_secs {
            Some(secs) => conn.execute(
                "INSERT OR REPLACE INTO user_settings (key, value) VALUES (?1, ?2)",
                params![KP_CONSUMED_HOLD_SINCE_KEY, secs.to_string()],
            )?,
            None => conn.execute(
                "DELETE FROM user_settings WHERE key = ?1",
                params![KP_CONSUMED_HOLD_SINCE_KEY],
            )?,
        };
        Ok(())
    }

    /// Whether an invitation was held that the user has not answered.
    ///
    /// # Errors
    ///
    /// Returns a database error on failure.
    pub fn held_invitation_outstanding(&self) -> Result<bool> {
        Ok(self.held_invitation_count()? > 0)
    }

    /// How many invitations were held unanswered at the last write. A
    /// value this build cannot read counts as one.
    ///
    /// # Errors
    ///
    /// Returns a database error on failure.
    pub fn held_invitation_count(&self) -> Result<usize> {
        let conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        let raw: Option<String> = conn
            .query_row(
                "SELECT value FROM user_settings WHERE key = ?1",
                params![KP_HELD_INVITATION_KEY],
                |r| r.get::<_, String>(0),
            )
            .optional()?;
        Ok(raw.map_or(0, |value| value.parse().unwrap_or(1)))
    }

    /// Records how many invitations are held unanswered; none clears it.
    ///
    /// # Errors
    ///
    /// Returns a database error on failure.
    pub fn set_held_invitation_count(&self, held: usize) -> Result<()> {
        if held == 0 {
            return self.set_held_invitation_outstanding(false);
        }
        let conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        conn.execute(
            "INSERT OR REPLACE INTO user_settings (key, value) VALUES (?1, ?2)",
            params![KP_HELD_INVITATION_KEY, held.to_string()],
        )?;
        Ok(())
    }

    /// Records whether an unanswered held invitation is outstanding.
    ///
    /// # Errors
    ///
    /// Returns a database error on failure.
    pub fn set_held_invitation_outstanding(&self, outstanding: bool) -> Result<()> {
        let conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        if outstanding {
            conn.execute(
                "INSERT OR REPLACE INTO user_settings (key, value) VALUES (?1, '1')",
                params![KP_HELD_INVITATION_KEY],
            )?;
        } else {
            conn.execute(
                "DELETE FROM user_settings WHERE key = ?1",
                params![KP_HELD_INVITATION_KEY],
            )?;
        }
        Ok(())
    }

    /// Returns whether the one-time malformed-slot retirement has COMPLETED.
    ///
    /// Defaults to `false`, so an install that has never run it (including every
    /// pre-width-fix install) migrates on its next maintenance tick. Never set
    /// by a partial run: a done-marker that latches on a migration that did not
    /// finish is how a broken migration becomes permanent.
    ///
    /// # Errors
    ///
    /// Returns a database error on failure.
    pub fn kp_slot_retirement_done(&self) -> Result<bool> {
        let conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        let raw: Option<String> = conn
            .query_row(
                "SELECT value FROM user_settings WHERE key = ?1",
                params![KP_SLOT_RETIREMENT_DONE_KEY],
                |r| r.get::<_, String>(0),
            )
            .optional()?;
        Ok(raw.as_deref() == Some("1"))
    }

    /// Marks the one-time malformed-slot retirement as complete.
    ///
    /// # Errors
    ///
    /// Returns a database error on failure.
    pub fn mark_kp_slot_retirement_done(&self) -> Result<()> {
        let conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        conn.execute(
            "INSERT OR REPLACE INTO user_settings (key, value) VALUES (?1, '1')",
            params![KP_SLOT_RETIREMENT_DONE_KEY],
        )?;
        Ok(())
    }
}

/// Writes `raw` where the hold start is kept, as a damaged row would hold it.
#[cfg(test)]
pub fn plant_hold_start(storage: &CircleStorage, raw: &str) {
    storage
        .conn()
        .lock()
        .expect("lock")
        .execute(
            "INSERT OR REPLACE INTO user_settings (key, value) VALUES (?1, ?2)",
            params![KP_CONSUMED_HOLD_SINCE_KEY, raw],
        )
        .expect("plant");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slot_retirement_marker_defaults_false_then_sticks() {
        let storage = CircleStorage::in_memory().expect("in_memory");
        assert!(
            !storage.kp_slot_retirement_done().expect("default"),
            "an install that never ran the retirement must migrate, not latch"
        );
        storage.mark_kp_slot_retirement_done().expect("mark");
        assert!(storage.kp_slot_retirement_done().expect("after mark"));
    }

    #[test]
    fn held_invitation_marker_defaults_false_sets_and_clears() {
        let storage = CircleStorage::in_memory().expect("in_memory");
        assert!(!storage.held_invitation_outstanding().expect("default"));
        storage.set_held_invitation_outstanding(true).expect("set");
        assert!(storage.held_invitation_outstanding().expect("set"));
        storage
            .set_held_invitation_outstanding(false)
            .expect("clear");
        assert!(!storage.held_invitation_outstanding().expect("cleared"));
        assert!(
            !storage.kp_slot_retirement_done().expect("other key"),
            "the two markers are separate keys"
        );
    }

    #[test]
    fn the_hold_start_is_absent_until_set_and_gone_once_cleared() {
        let storage = CircleStorage::in_memory().expect("in_memory");
        assert_eq!(storage.consumed_hold_since().expect("default"), None);
        storage
            .set_consumed_hold_since(Some(1_700_000_123))
            .expect("set");
        assert_eq!(
            storage.consumed_hold_since().expect("set"),
            Some(1_700_000_123)
        );
        storage
            .set_consumed_hold_since(Some(1_700_000_456))
            .expect("replace");
        assert_eq!(
            storage.consumed_hold_since().expect("replaced"),
            Some(1_700_000_456)
        );
        storage.set_consumed_hold_since(None).expect("clear");
        assert_eq!(storage.consumed_hold_since().expect("cleared"), None);
        assert!(!storage.held_invitation_outstanding().expect("other key"));
    }

    /// A value that is not a Unix second reads as no hold at all, and the
    /// ended-hold mark reads back as itself.
    #[test]
    fn an_unparsable_hold_start_reads_as_absent() {
        let storage = CircleStorage::in_memory().expect("in_memory");
        for unparsable in ["", "soon", "-5", "1.5", "18446744073709551616"] {
            plant_hold_start(&storage, unparsable);
            assert_eq!(
                storage.consumed_hold_since().expect("read"),
                None,
                "{unparsable:?}"
            );
        }
        storage
            .set_consumed_hold_since(Some(CONSUMED_HOLD_OVER))
            .expect("end");
        assert_eq!(
            storage.consumed_hold_since().expect("ended"),
            Some(CONSUMED_HOLD_OVER)
        );
    }
}
