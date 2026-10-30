//! Where each relay stopped vouching for a routing id's history, on
//! `circles-v2.db` (the `relay_floors` table in
//! [`CircleStorage::initialize_schema`]).
//!
//! A circle's cursor advances on the end of stored events of the relays that
//! covered its REQ; a relay left out of that coverage owes the circle the
//! window from its REQ's `since`, which is kept here until a REQ that relay
//! answered to its end reached back that far (Security Rule 12).

#![allow(clippy::significant_drop_tightening)]

use rusqlite::{params, OptionalExtension};

use super::error::{CircleError, Result};
use super::storage::CircleStorage;

impl CircleStorage {
    /// Records that `relay` owes `nostr_group_id`'s history from
    /// `since_secs`, keeping the earlier floor if one is already owed.
    pub(crate) fn owe_relay_floor(
        &self,
        nostr_group_id: &[u8; 32],
        relay: &str,
        since_secs: i64,
    ) -> Result<()> {
        let conn = self
            .conn()
            .lock()
            .map_err(|_| CircleError::Storage("Failed to acquire database lock".into()))?;
        conn.execute(
            "INSERT INTO relay_floors (nostr_group_id, relay, since_secs) VALUES (?1, ?2, ?3)
             ON CONFLICT (nostr_group_id, relay)
             DO UPDATE SET since_secs = MIN(since_secs, excluded.since_secs)",
            params![nostr_group_id.as_slice(), relay, since_secs],
        )?;
        Ok(())
    }

    /// The floor `relay` owes `nostr_group_id`, if any.
    pub(crate) fn relay_floor(
        &self,
        nostr_group_id: &[u8; 32],
        relay: &str,
    ) -> Result<Option<i64>> {
        let conn = self
            .conn()
            .lock()
            .map_err(|_| CircleError::Storage("Failed to acquire database lock".into()))?;
        Ok(conn
            .query_row(
                "SELECT since_secs FROM relay_floors WHERE nostr_group_id = ?1 AND relay = ?2",
                params![nostr_group_id.as_slice(), relay],
                |row| row.get(0),
            )
            .optional()?)
    }

    /// Ends the floor `relay` owes `nostr_group_id` when a REQ it answered to
    /// its end asked from `covered_since` or earlier.
    pub(crate) fn clear_relay_floor(
        &self,
        nostr_group_id: &[u8; 32],
        relay: &str,
        covered_since: i64,
    ) -> Result<()> {
        let conn = self
            .conn()
            .lock()
            .map_err(|_| CircleError::Storage("Failed to acquire database lock".into()))?;
        conn.execute(
            "DELETE FROM relay_floors
             WHERE nostr_group_id = ?1 AND relay = ?2 AND since_secs >= ?3",
            params![nostr_group_id.as_slice(), relay, covered_since],
        )?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ID: [u8; 32] = [7; 32];
    const RELAY: &str = "wss://floor-canary1c4e.example.com";

    #[test]
    fn a_floor_keeps_the_earliest_owed_point_and_ends_only_once_covered() {
        let storage = CircleStorage::in_memory().unwrap();
        storage.owe_relay_floor(&ID, RELAY, 500).unwrap();
        storage.owe_relay_floor(&ID, RELAY, 900).unwrap();
        assert_eq!(storage.relay_floor(&ID, RELAY).unwrap(), Some(500));
        storage.clear_relay_floor(&ID, RELAY, 600).unwrap();
        assert_eq!(
            storage.relay_floor(&ID, RELAY).unwrap(),
            Some(500),
            "a REQ that did not reach back to the floor ended it"
        );
        storage.clear_relay_floor(&ID, RELAY, 500).unwrap();
        assert_eq!(storage.relay_floor(&ID, RELAY).unwrap(), None);
        assert_eq!(storage.relay_floor(&[8; 32], RELAY).unwrap(), None);
    }
}
