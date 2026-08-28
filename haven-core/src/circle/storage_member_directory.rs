//! Storage methods for the `member_directory` table — the local directory of
//! people the member picker offers (member-picker plan §6.1, requirement R5).
//!
//! Extends [`CircleStorage`] with the operations the directory needs: a
//! full-union rewrite ([`CircleStorage::sync_co_members`]), the picker's ranked
//! read ([`CircleStorage::ranked_directory_members`]), the retention purge
//! ([`CircleStorage::prune_expired_directory_members`]) and the destructive
//! paths ([`CircleStorage::delete_directory_member`] and its batch form
//! [`CircleStorage::delete_directory_members`]).
//!
//! # Privacy
//!
//! * **No circle identifier, ever.** The table records people, never which
//!   circle they came from. `sync_co_members` takes the UNION across all
//!   circles and rewrites the whole table in one pass, so a row cannot be
//!   attributed to a circle even by write timing, and no column can carry the
//!   attribution (`INV-D-DIRECTORY-HOLDS-NO-CIRCLE-IDENTIFIER`, pinned by
//!   `member_directory_has_no_circle_or_group_column`).
//! * **Day granularity only.** Stored days are day buckets and `purge_after` is
//!   day-aligned, so the departure cohort's shared freeze day is the finest
//!   partition information at rest — the cost the plan accepts, rather than the
//!   second-granularity write cluster it does not.
//! * **No arrival order.** The table is `WITHOUT ROWID`, so it carries no
//!   implicit insertion counter. A rowid would be one: each pass inserts that
//!   pass's new pubkeys in sorted order, so a descending pubkey step between
//!   consecutive rowids marks a batch boundary — the `first_seen_day` partition
//!   leak, re-created by the storage engine
//!   ([`migrate_directory_to_without_rowid`] converts installs created before
//!   this, and `member_directory_stores_no_arrival_order` pins it).
//! * **Bounded retention.** A departed co-member survives at most
//!   [`DIRECTORY_RETENTION_DAYS`] and is then DELETED, never merely hidden from
//!   a read (owner decision D3). The window is a deadline, not an eligibility
//!   rule, and it is a deadline for the DISK and not only for the display:
//!   [`CircleStorage::ranked_directory_members`] sweeps before it selects, and
//!   `CircleManager::new` sweeps at every process start, which is the trigger
//!   an idle device still produces — the quiet install the disclosure copy is
//!   least able to be wrong about.
//! * **Encrypted store only.** These rows live in `circles.db` (`SQLCipher`, key
//!   in the platform keyring) and nowhere else — no preferences file, no secure
//!   storage entry, no sidecar. Logout deletes the database files, which is the
//!   whole of the guarantee; `the_member_directory_does_not_outlive_the_circles_db_file`
//!   pins it by reproducing that mechanism.
//!
//! # No name is stored here
//!
//! Nothing folded is written to `SQLite` at all. A row is a pubkey and two day
//! buckets; the picker's search keys are folded per candidate in Dart, from the
//! `profiles` cache, so no index of other people's names outlives the
//! retraction ([`CircleStorage::wipe_all_profiles`]) that is supposed to erase
//! them.

// Mirror `storage.rs`: each method acquires the connection lock once at the top
// and holds it for the whole (single-statement or transactional) operation.
#![allow(clippy::significant_drop_tightening)]

use std::collections::BTreeSet;

use rusqlite::{params, OptionalExtension as _};

use super::error::{CircleError, Result};
use super::storage::CircleStorage;

/// Seconds per day — the bucket width every stored day in this table uses.
const SECS_PER_DAY: i64 = 86_400;

/// How long a person stays in the directory after the last day they shared a
/// circle with this device (owner decision D3, reduced from a drafted 7).
///
/// Retention runs from the START of that day, so the actual window is at most
/// three days and never more — the direction the disclosure copy can honestly
/// promise.
pub const DIRECTORY_RETENTION_DAYS: i64 = 3;

/// [`DIRECTORY_RETENTION_DAYS`] in seconds — the unit `purge_after` is stored
/// in, and the value the disclosure copy's "3 days" is tied to.
pub const DIRECTORY_RETENTION_SECS: i64 = DIRECTORY_RETENTION_DAYS * SECS_PER_DAY;

/// The `purge_after` a CURRENT co-member carries: never purged.
///
/// A sentinel rather than NULL because NULL breaks every read — `>= now` drops
/// the row, `ORDER BY` sorts NULLs first, and `min()`/`count(col)`/`BETWEEN`/
/// `NOT IN` silently exclude them. `i64::MAX` compares correctly in all of them.
pub const DIRECTORY_PURGE_NEVER: i64 = i64::MAX;

/// Which section of the picker a directory row belongs to.
///
/// The tier is a claim about **roster provenance** and nothing more: this
/// pubkey is (or recently was) on the member list of a circle on this device,
/// placed there by an MLS-authenticated commit. It says nothing about whether
/// the person accepted, joined, or is active — none of which Haven can observe.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DirectoryTier {
    /// On the member list of a circle on this device, as of the last sync.
    Current,
    /// Not on any current member list; retained for at most
    /// [`DIRECTORY_RETENTION_DAYS`] after the last day they were.
    Recent,
}

impl DirectoryTier {
    /// Maps to the integer stored in the `member_directory.tier` column
    /// (`0 = Current`, `1 = Recent`).
    #[must_use]
    pub const fn as_db_value(self) -> i64 {
        match self {
            Self::Current => 0,
            Self::Recent => 1,
        }
    }

    /// Maps back from the stored integer; any value other than `0` reads as
    /// [`Self::Recent`].
    ///
    /// Fail-safe toward the weaker claim: a corrupt tier must never promote
    /// someone into "members of your circles", which asserts present roster
    /// membership, when the row cannot support it.
    #[must_use]
    pub const fn from_db_value(value: i64) -> Self {
        if value == 0 {
            Self::Current
        } else {
            Self::Recent
        }
    }
}

/// The five mutable columns of one directory row — what [`CircleStorage::sync_co_members`]
/// compares a stored row against before deciding to write it.
#[derive(Clone, Copy, PartialEq, Eq)]
struct DirectoryRowState {
    is_current: i64,
    last_shared_day: i64,
    tier: i64,
    rank_key: i64,
    purge_after: i64,
}

impl DirectoryRowState {
    /// What a member of the current union holds: today, and no deadline.
    const fn current(today: i64) -> Self {
        Self {
            is_current: 1,
            last_shared_day: today,
            tier: DirectoryTier::Current.as_db_value(),
            rank_key: today,
            purge_after: DIRECTORY_PURGE_NEVER,
        }
    }

    /// What someone absent from the union holds, given the last day they were
    /// in it.
    ///
    /// The deadline is derived from the ROW's own day and never from `now`,
    /// which is what makes a repeated demotion idempotent instead of a rolling
    /// three-day extension that would never expire — and it is day-aligned, so
    /// the stored value carries a day bucket and never the second a departure
    /// was noticed.
    fn recent(last_shared_day: i64) -> Self {
        // Clamped for the same reason `day_bucket` clamps: it keeps the
        // multiplication inside `i64`. Every day this module writes is already
        // in range, so the clamp can only bite on a value from outside this
        // writer, where an early purge is the accepted outcome.
        let day = last_shared_day.clamp(0, MAX_DAY);
        Self {
            is_current: 0,
            last_shared_day: day,
            tier: DirectoryTier::Recent.as_db_value(),
            rank_key: day,
            purge_after: (day + DIRECTORY_RETENTION_DAYS) * SECS_PER_DAY,
        }
    }
}

/// One row of `member_directory`, as the picker reads it.
///
/// `Debug` is derived: every field is either a public key or a day bucket, and
/// no name, circle or secret is present to redact.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DirectoryEntry {
    /// Lowercase-hex Nostr identity key (`Member.id`, never the MLS leaf
    /// signature key).
    pub pubkey_hex: String,
    /// Which picker section this row belongs to.
    pub tier: DirectoryTier,
    /// Day bucket of the last day this person was in the co-member union.
    pub last_shared_day: i64,
    /// Unix second from which the row is purged, or [`DIRECTORY_PURGE_NEVER`]
    /// while the person is a current co-member.
    pub purge_after: i64,
}

impl CircleStorage {
    /// Rewrites the directory from the union of current co-members across ALL
    /// circles.
    ///
    /// Every pubkey in `union_pubkeys_hex` is stamped current
    /// ([`DirectoryTier::Current`], a `purge_after` of
    /// [`DIRECTORY_PURGE_NEVER`], `last_shared_day` = today); everyone absent
    /// from it is demoted to [`DirectoryTier::Recent`] and given a
    /// `purge_after` derived from the `last_shared_day` already on their row —
    /// so a departure noticed late expires on time rather than three days after
    /// it was noticed, and re-running the sync can never extend an existing
    /// row's retention.
    ///
    /// # Callers pass the union, and only a converged one
    ///
    /// This method deliberately reads no roster: partitioning the write by
    /// circle is what the union design exists to prevent, and the caller is the
    /// only layer that can tell a converged roster from a provisional one.
    /// Two obligations therefore sit with the caller, not here:
    ///
    /// * The union must come from rosters read after the group is stable and
    ///   convergence has drained. A commit can still be withdrawn by branch
    ///   selection after it was published and confirmed, and a row created from
    ///   the withdrawn state would describe someone who was never a member.
    /// * When such a state IS withdrawn — or when anyone is deliberately
    ///   removed in either direction — the caller must issue
    ///   [`Self::delete_directory_member`]. Aging that row out over three days
    ///   would retain a co-membership that never existed.
    ///
    /// A pubkey missing from the union because its circle could not be read is
    /// indistinguishable here from one that left, so a caller that cannot read
    /// every circle must not call this at all.
    ///
    /// # Errors
    ///
    /// Returns [`CircleError::Storage`] on lock poisoning and
    /// [`CircleError::Database`] on `SQLite` failure.
    pub fn sync_co_members(&self, union_pubkeys_hex: &[String], now_unix_secs: i64) -> Result<()> {
        let today = day_bucket(now_unix_secs);
        let union: BTreeSet<String> = union_pubkeys_hex.iter().map(|p| directory_key(p)).collect();
        let mut conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        let tx = conn.transaction()?;

        // Read the table, then write only the rows whose target state actually
        // differs. This runs on the RECEIVE path, and most passes change
        // nothing: a set-based "demote everyone, then promote the union" is two
        // statements, but it rewrites every row — and every page — of a
        // directory that already said the right thing, and it rewrites a
        // current co-member twice per pass.
        //
        // Reading first also removes the reason that shape existed: "absent
        // from the union" is a set membership test here, so it needs neither a
        // `NOT IN (?, ?, …)` list (bounded by SQLITE_MAX_VARIABLE_NUMBER) nor a
        // temporary table. Everything stays in one transaction, so no reader
        // ever sees an intermediate state.
        let stored: Vec<(String, DirectoryRowState)> = {
            let mut stmt = tx.prepare(
                "SELECT pubkey, is_current, last_shared_day, tier, rank_key, purge_after
                 FROM member_directory",
            )?;
            let rows = stmt
                .query_map([], |row| {
                    Ok((
                        row.get(0)?,
                        DirectoryRowState {
                            is_current: row.get(1)?,
                            last_shared_day: row.get(2)?,
                            tier: row.get(3)?,
                            rank_key: row.get(4)?,
                            purge_after: row.get(5)?,
                        },
                    ))
                })?
                .collect::<rusqlite::Result<Vec<_>>>()?;
            rows
        };

        {
            // One statement for both directions: the target is a value, and a
            // row already holding it is simply not written.
            let mut write = tx.prepare(
                "INSERT INTO member_directory
                     (pubkey, is_current, last_shared_day, tier, rank_key, purge_after)
                 VALUES (?1, ?2, ?3, ?4, ?3, ?5)
                 ON CONFLICT(pubkey) DO UPDATE SET
                     is_current      = excluded.is_current,
                     last_shared_day = excluded.last_shared_day,
                     tier            = excluded.tier,
                     rank_key        = excluded.rank_key,
                     purge_after     = excluded.purge_after",
            )?;
            let mut execute = |pubkey_hex: &str, target: &DirectoryRowState| -> Result<()> {
                write.execute(params![
                    pubkey_hex,
                    target.is_current,
                    target.last_shared_day,
                    target.tier,
                    target.purge_after
                ])?;
                Ok(())
            };

            for (pubkey_hex, row) in &stored {
                let target = if union.contains(pubkey_hex) {
                    DirectoryRowState::current(today)
                } else {
                    DirectoryRowState::recent(row.last_shared_day)
                };
                if *row != target {
                    execute(pubkey_hex, &target)?;
                }
            }
            let known: BTreeSet<&str> = stored.iter().map(|(k, _)| k.as_str()).collect();
            for pubkey_hex in union.iter().filter(|k| !known.contains(k.as_str())) {
                execute(pubkey_hex, &DirectoryRowState::current(today))?;
            }
        }

        tx.commit()?;
        Ok(())
    }

    /// The whole directory in picker order: current co-members first, then
    /// recent ones, each block newest-shared first with the pubkey breaking
    /// remaining ties so the order is total and stable.
    ///
    /// Sweeps expired rows before selecting, in one transaction with it, so a
    /// read can never observe a row the sweep was about to remove. That is a
    /// DELETE and not a display filter (owner decision D3): the row leaves the
    /// disk before it could have been shown, rather than being hidden while it
    /// persists.
    ///
    /// Sweeping here is what makes the window a deadline rather than an
    /// eligibility rule. Every other purge caller runs off a membership change
    /// or an ingest, none of which an idle install produces — so without this,
    /// three days would pass with the row still stored and still offered.
    ///
    /// # Errors
    ///
    /// As [`Self::sync_co_members`].
    pub fn ranked_directory_members(&self, now_unix_secs: i64) -> Result<Vec<DirectoryEntry>> {
        let mut conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        let tx = conn.transaction()?;
        purge_expired(&tx, now_unix_secs)?;
        let mut stmt = tx.prepare(
            "SELECT pubkey, tier, last_shared_day, purge_after
             FROM member_directory
             ORDER BY tier ASC, rank_key DESC, pubkey ASC",
        )?;
        let rows = stmt
            .query_map([], |row| {
                Ok(DirectoryEntry {
                    pubkey_hex: row.get(0)?,
                    tier: DirectoryTier::from_db_value(row.get(1)?),
                    last_shared_day: row.get(2)?,
                    purge_after: row.get(3)?,
                })
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        drop(stmt);
        tx.commit()?;
        Ok(rows)
    }

    /// Deletes every row whose `purge_after` has passed, returning how many
    /// were removed.
    ///
    /// A current co-member carries [`DIRECTORY_PURGE_NEVER`], which no clock
    /// can pass, so this is safe to run on any schedule.
    ///
    /// Kept beside the sweep inside [`Self::ranked_directory_members`] because
    /// they bound different things. The read guarantees nothing expired is
    /// ever SHOWN; this guarantees nothing expired is still STORED on a device
    /// whose picker is never opened, which is why `CircleManager::new` runs it
    /// at every process start as well as the reconcile running it per pass —
    /// and [`Self::sync_co_members`] can itself mint an already-expired row,
    /// because a departure noticed days late expires against the last day
    /// shared rather than the day it was noticed.
    ///
    /// # Errors
    ///
    /// As [`Self::sync_co_members`].
    pub fn prune_expired_directory_members(&self, now_unix_secs: i64) -> Result<usize> {
        let conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        Ok(purge_expired(&conn, now_unix_secs)?)
    }

    /// Deletes one person from the directory immediately, returning whether a
    /// row was removed.
    ///
    /// This is the removal path, in either direction: you removed them, they
    /// removed you, or the commit that added them was withdrawn by branch
    /// selection and they were never a co-member at all. None of those may age
    /// out over three days — the row is a record of a relationship that has
    /// ended or never existed, so it goes now (owner decision D3).
    ///
    /// # Errors
    ///
    /// As [`Self::sync_co_members`].
    pub fn delete_directory_member(&self, pubkey_hex: &str) -> Result<bool> {
        let conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        let rows = conn.execute(
            "DELETE FROM member_directory WHERE pubkey = ?1",
            params![directory_key(pubkey_hex)],
        )?;
        Ok(rows > 0)
    }

    /// [`Self::delete_directory_member`] for a whole set, in one transaction.
    ///
    /// Returns how many rows were removed. Same semantics per pubkey; the only
    /// difference is atomicity and cost. The reconcile's retire set arrives on
    /// the receive path, where K separate deletes are K autocommit
    /// transactions — K fsyncs on the main database — for a set the caller
    /// already holds whole.
    ///
    /// # Errors
    ///
    /// As [`Self::sync_co_members`].
    pub fn delete_directory_members(&self, pubkeys_hex: &[String]) -> Result<usize> {
        if pubkeys_hex.is_empty() {
            return Ok(0);
        }
        let mut conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        let tx = conn.transaction()?;
        let mut removed = 0;
        {
            let mut stmt = tx.prepare("DELETE FROM member_directory WHERE pubkey = ?1")?;
            for pubkey_hex in pubkeys_hex {
                removed += stmt.execute(params![directory_key(pubkey_hex)])?;
            }
        }
        tx.commit()?;
        Ok(removed)
    }
}

/// Rebuilds a pre-`WITHOUT ROWID` `member_directory` by dropping it, so the
/// schema's `CREATE TABLE IF NOT EXISTS` re-declares it in the current shape.
///
/// `CREATE TABLE IF NOT EXISTS` does not alter an existing table and `SQLite`
/// offers no in-place conversion, so an install created before this keeps its
/// implicit rowid — the arrival-order counter the module docs describe as a
/// partition leak — for ever otherwise.
///
/// # Why a DROP rather than a copy-and-rename
///
/// The rows are a derived cache, and dropping them is the privacy-safe
/// direction: it erases retained pubkeys rather than migrating them. Current
/// co-members are restored by the reconcile that runs before the picker's very
/// first read, so nothing a user can see is lost; what is lost is at most three
/// days of "recent" rows, once, on the upgrade — against a copy-and-rename that
/// would need a second `member_directory`-shaped table, which is exactly the
/// companion table the privacy guard forbids.
///
/// Keyed on the stored DDL rather than a `user_settings` sentinel, because the
/// condition IS the property: re-running it can only be a no-op, and a lost
/// sentinel cannot leave a rowid table behind.
///
/// # Errors
///
/// Returns the `SQLite` error if the catalogue read or the drop fails.
pub(super) fn migrate_directory_to_without_rowid(
    conn: &rusqlite::Connection,
) -> rusqlite::Result<()> {
    let declared: Option<String> = conn
        .query_row(
            "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'member_directory'",
            [],
            |row| row.get(0),
        )
        .optional()?;
    if declared.is_some_and(|sql| !sql.to_ascii_uppercase().contains("WITHOUT ROWID")) {
        conn.execute_batch("DROP TABLE member_directory;")?;
    }
    Ok(())
}

/// Deletes every row whose retention deadline has passed.
///
/// The single definition of the retention DELETE, shared by the scheduled
/// sweep and by the read that sweeps before it selects, so the two can never
/// disagree about when a person expires. Takes a `Connection` so a caller
/// already inside a transaction can run it there.
fn purge_expired(conn: &rusqlite::Connection, now_unix_secs: i64) -> rusqlite::Result<usize> {
    conn.execute(
        "DELETE FROM member_directory WHERE purge_after < ?1",
        params![now_unix_secs],
    )
}

/// The day bucket for a unix-seconds instant.
///
/// Clamped at both ends so `(day + retention) * 86400` is total: the upper
/// bound keeps the multiplication inside `i64` (`SQLite` would otherwise fall
/// back to floating point and store a REAL in an INTEGER column), and the lower
/// bound keeps a pre-1970 clock from writing a negative day. Both ends are only
/// reachable from a device clock that is wrong by millennia, where the plan's
/// accepted outcome — an early purge — is what a clamped bucket produces.
fn day_bucket(now_unix_secs: i64) -> i64 {
    now_unix_secs.div_euclid(SECS_PER_DAY).clamp(0, MAX_DAY)
}

/// The largest day bucket whose retention deadline still fits in `i64`.
const MAX_DAY: i64 = i64::MAX / SECS_PER_DAY - DIRECTORY_RETENTION_DAYS;

/// Normalizes a pubkey to the table's primary-key form.
///
/// The column is documented lowercase hex, and enforcing it at every write and
/// delete is what makes that true: a case variant would otherwise insert a
/// second row for the same person, and — worse — let a removal silently miss
/// the row it was supposed to delete.
fn directory_key(pubkey_hex: &str) -> String {
    pubkey_hex.to_ascii_lowercase()
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::OptionalExtension;

    /// Day 20 000 (2024-10-04) as unix seconds — an ordinary present-day clock.
    const DAY: i64 = 20_000;
    const DAY_START: i64 = DAY * SECS_PER_DAY;

    fn union(pubkeys: &[&str]) -> Vec<String> {
        pubkeys.iter().map(|p| (*p).to_string()).collect()
    }

    /// The raw stored row, read without going through
    /// [`CircleStorage::ranked_directory_members`], so a write-side assertion
    /// cannot be satisfied by the read.
    fn raw_row(storage: &CircleStorage, pubkey_hex: &str) -> Option<(i64, i64, i64, i64, i64)> {
        let conn = storage.conn().lock().unwrap();
        conn.query_row(
            "SELECT is_current, last_shared_day, tier, rank_key, purge_after
             FROM member_directory WHERE pubkey = ?1",
            params![pubkey_hex],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)),
        )
        .optional()
        .unwrap()
    }

    /// Rows this database has actually written since it was opened.
    ///
    /// `SQLite`'s own counter, so it counts a rewrite that stored identical
    /// bytes — which is exactly the cost under test.
    fn rows_written(storage: &CircleStorage) -> u64 {
        storage.conn().lock().unwrap().total_changes()
    }

    fn row_count(storage: &CircleStorage) -> i64 {
        let conn = storage.conn().lock().unwrap();
        conn.query_row("SELECT COUNT(*) FROM member_directory", [], |r| r.get(0))
            .unwrap()
    }

    /// Every row's `(is_current, tier)` pair, for the lockstep invariant.
    fn current_and_tier(storage: &CircleStorage) -> Vec<(i64, i64)> {
        let conn = storage.conn().lock().unwrap();
        let mut stmt = conn
            .prepare("SELECT is_current, tier FROM member_directory ORDER BY pubkey")
            .unwrap();
        let rows = stmt
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
            .unwrap()
            .collect::<rusqlite::Result<Vec<_>>>()
            .unwrap();
        rows
    }

    #[test]
    fn retention_is_the_owner_decided_three_days() {
        // The disclosure copy promises "3 days" against these constants, so
        // the window cannot move without a reviewer seeing the copy move too.
        assert_eq!(DIRECTORY_RETENTION_DAYS, 3);
        assert_eq!(DIRECTORY_RETENTION_SECS, 259_200);
        assert_eq!(DIRECTORY_PURGE_NEVER, i64::MAX);
    }

    #[test]
    fn member_directory_has_no_circle_or_group_column() {
        // INV-D-DIRECTORY-HOLDS-NO-CIRCLE-IDENTIFIER, structurally: the
        // directory records people, never which circle they came from.
        let storage = CircleStorage::in_memory().unwrap();
        let conn = storage.conn().lock().unwrap();
        let mut stmt = conn.prepare("PRAGMA table_info(member_directory)").unwrap();
        let cols: Vec<String> = stmt
            .query_map([], |row| row.get::<_, String>(1))
            .unwrap()
            .collect::<rusqlite::Result<Vec<_>>>()
            .unwrap();

        for col in &cols {
            let lower = col.to_ascii_lowercase();
            assert!(
                !lower.contains("circle") && !lower.contains("group") && !lower.contains("mls"),
                "member_directory must not carry a circle/group column, found `{col}`"
            );
        }
        // Pinned exactly, so adding a column is a deliberate act reviewed
        // against the invariant above rather than an incidental migration.
        assert_eq!(
            cols,
            vec![
                "pubkey",
                "is_current",
                "last_shared_day",
                "tier",
                "rank_key",
                "purge_after"
            ]
        );
    }

    #[test]
    fn member_directory_stores_no_arrival_order() {
        // The columns above are only half of what the table stores. An implicit
        // rowid is an arrival-order counter, and `sync_co_members` inserts each
        // pass's NEW pubkeys in sorted order — so a descending pubkey step
        // between consecutive rowids says "these people arrived together", which
        // is a circle's roster. That is the `first_seen_day` leak §6.1 dropped,
        // reintroduced by the storage engine. PRAGMA table_info never reports a
        // rowid, so both halves are read from the catalogue and from a query no
        // WITHOUT ROWID table can answer.
        let storage = CircleStorage::in_memory().unwrap();
        storage
            .sync_co_members(&union(&["dd", "ff"]), DAY_START)
            .unwrap();
        storage
            .sync_co_members(&union(&["aa", "bb", "dd", "ff"]), DAY_START)
            .unwrap();

        let conn = storage.conn().lock().unwrap();
        let sql: String = conn
            .query_row(
                "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'member_directory'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert!(
            sql.to_ascii_uppercase().contains("WITHOUT ROWID"),
            "member_directory must be WITHOUT ROWID, declared as: {sql}"
        );
        assert!(
            conn.query_row("SELECT rowid FROM member_directory LIMIT 1", [], |r| r
                .get::<_, i64>(0))
                .is_err(),
            "a rowid is readable, so insertion order — and with it the batch \
             boundary between two circles' rosters — is recoverable from disk"
        );
    }

    #[test]
    fn a_database_created_before_without_rowid_is_rebuilt_on_open() {
        // `CREATE TABLE IF NOT EXISTS` does not alter an existing table, so an
        // upgraded install keeps the leaking shape unless the open drops it.
        // Build the genuine pre-migration table — rowid, and the `updated_day`
        // column that has since been removed — then reopen through the real
        // constructor.
        let dir = tempfile::TempDir::new().expect("temp dir");
        let db_path = dir.path().join("circles.db");
        {
            let storage = CircleStorage::new(&db_path, None).expect("open");
            let conn = storage.conn().lock().unwrap();
            conn.execute_batch(
                "DROP TABLE member_directory;
                 CREATE TABLE member_directory (
                     pubkey           TEXT PRIMARY KEY,
                     is_current       INTEGER NOT NULL DEFAULT 0,
                     last_shared_day  INTEGER NOT NULL DEFAULT 0,
                     tier             INTEGER NOT NULL,
                     rank_key         INTEGER NOT NULL,
                     purge_after      INTEGER NOT NULL,
                     updated_day      INTEGER NOT NULL
                 );
                 INSERT INTO member_directory
                     VALUES ('aa', 1, 20000, 0, 20000, 9223372036854775807, 20000);",
            )
            .unwrap();
        }

        let storage = CircleStorage::new(&db_path, None).expect("reopen");
        let conn = storage.conn().lock().unwrap();
        let sql: String = conn
            .query_row(
                "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'member_directory'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert!(
            sql.to_ascii_uppercase().contains("WITHOUT ROWID"),
            "the upgraded install kept its rowid table: {sql}"
        );
        assert!(
            !sql.contains("updated_day"),
            "the upgraded install kept the removed column: {sql}"
        );
        let rows: i64 = conn
            .query_row("SELECT COUNT(*) FROM member_directory", [], |r| r.get(0))
            .unwrap();
        assert_eq!(
            rows, 0,
            "the rebuild erases the retained pubkeys rather than carrying them \
             across — the reconcile before the picker's first read restores \
             every current co-member"
        );
    }

    #[test]
    fn rebuilding_is_a_no_op_on_a_database_already_migrated() {
        // Keyed on the stored DDL, not a sentinel, so a second open must leave
        // the rows alone — otherwise every launch would empty the directory.
        let dir = tempfile::TempDir::new().expect("temp dir");
        let db_path = dir.path().join("circles.db");
        {
            let storage = CircleStorage::new(&db_path, None).expect("open");
            storage
                .sync_co_members(&union(&["aa", "bb"]), DAY_START)
                .unwrap();
        }

        let storage = CircleStorage::new(&db_path, None).expect("reopen");
        assert_eq!(
            storage.ranked_directory_members(DAY_START).unwrap().len(),
            2
        );
    }

    #[test]
    fn the_union_is_stamped_current_and_never_purged() {
        let storage = CircleStorage::in_memory().unwrap();
        storage
            .sync_co_members(&union(&["aa", "bb"]), DAY_START + 12_345)
            .unwrap();

        for pubkey in ["aa", "bb"] {
            let (is_current, last_shared_day, tier, rank_key, purge_after) =
                raw_row(&storage, pubkey).expect("row present");
            assert_eq!(is_current, 1);
            assert_eq!(tier, DirectoryTier::Current.as_db_value());
            assert_eq!(last_shared_day, DAY, "days are buckets, not seconds");
            assert_eq!(rank_key, DAY);
            assert_eq!(purge_after, DIRECTORY_PURGE_NEVER);
        }
    }

    #[test]
    fn a_pubkey_dropping_out_of_the_union_ages_out_rather_than_vanishing() {
        let storage = CircleStorage::in_memory().unwrap();
        storage
            .sync_co_members(&union(&["aa", "bb"]), DAY_START)
            .unwrap();
        storage.sync_co_members(&union(&["aa"]), DAY_START).unwrap();

        let (is_current, last_shared_day, tier, _, purge_after) =
            raw_row(&storage, "bb").expect("the departed row must still exist");
        assert_eq!(is_current, 0);
        assert_eq!(tier, DirectoryTier::Recent.as_db_value());
        assert_eq!(last_shared_day, DAY, "the last day shared must not move");
        assert_eq!(purge_after, DAY_START + DIRECTORY_RETENTION_SECS);

        // The member still in the union is untouched by the demotion pass.
        let (is_current, _, tier, _, purge_after) = raw_row(&storage, "aa").expect("row present");
        assert_eq!(is_current, 1);
        assert_eq!(tier, DirectoryTier::Current.as_db_value());
        assert_eq!(purge_after, DIRECTORY_PURGE_NEVER);
    }

    #[test]
    fn retention_ends_exactly_three_days_after_the_last_shared_day() {
        let storage = CircleStorage::in_memory().unwrap();
        storage.sync_co_members(&union(&["aa"]), DAY_START).unwrap();
        storage.sync_co_members(&[], DAY_START).unwrap();

        // 259 200 seconds after the last shared day: still retained.
        assert_eq!(
            storage
                .prune_expired_directory_members(DAY_START + 259_200)
                .unwrap(),
            0
        );
        assert_eq!(row_count(&storage), 1, "the boundary second is included");

        // 259 201: gone.
        assert_eq!(
            storage
                .prune_expired_directory_members(DAY_START + 259_201)
                .unwrap(),
            1
        );
        assert_eq!(row_count(&storage), 0, "the next second is excluded");
    }

    #[test]
    fn a_departure_noticed_late_does_not_extend_retention() {
        // Three syncs after the departure, spread over two days, must not roll
        // the deadline forward — otherwise a device that syncs often keeps a
        // former co-member for ever.
        let storage = CircleStorage::in_memory().unwrap();
        storage.sync_co_members(&union(&["aa"]), DAY_START).unwrap();
        for later in [
            DAY_START + SECS_PER_DAY,
            DAY_START + 2 * SECS_PER_DAY,
            DAY_START + 2 * SECS_PER_DAY + 3_600,
        ] {
            storage.sync_co_members(&[], later).unwrap();
        }

        let (_, last_shared_day, _, _, purge_after) = raw_row(&storage, "aa").expect("row present");
        assert_eq!(last_shared_day, DAY);
        assert_eq!(purge_after, DAY_START + DIRECTORY_RETENTION_SECS);
        assert_eq!(
            storage
                .prune_expired_directory_members(DAY_START + 259_201)
                .unwrap(),
            1
        );
    }

    #[test]
    fn expired_rows_are_deleted_by_the_purge_not_hidden_by_the_read() {
        // Owner decision D3: retention is enforced by DELETE. A read that
        // filtered on `purge_after` would leave the row on disk while
        // reporting it gone — the exact failure the decision names.
        let storage = CircleStorage::in_memory().unwrap();
        storage.sync_co_members(&union(&["aa"]), DAY_START).unwrap();
        storage.sync_co_members(&[], DAY_START).unwrap();

        let expired_at = DAY_START + DIRECTORY_RETENTION_SECS + 1;
        // Inside the window, a read neither hides the row nor removes it.
        assert_eq!(
            storage.ranked_directory_members(DAY_START).unwrap().len(),
            1,
            "the read must not hide it"
        );
        assert_eq!(row_count(&storage), 1, "and it is still on disk");

        assert_eq!(
            storage.prune_expired_directory_members(expired_at).unwrap(),
            1
        );
        assert_eq!(row_count(&storage), 0, "the purge must DELETE the row");
        assert!(storage
            .ranked_directory_members(DAY_START)
            .unwrap()
            .is_empty());
    }

    #[test]
    fn an_idle_install_erases_an_expired_row_on_the_ranked_read_alone() {
        // The promise the disclosure copy makes is a deadline, not an
        // eligibility rule. Within one process that sees no membership change,
        // no live-sync ingest and no catch-up, the picker's read is the only
        // sweep left — the start-of-process one already ran — so it is what has
        // to make "erased after 3 days" true. Nothing else is called here,
        // deliberately.
        let storage = CircleStorage::in_memory().unwrap();
        storage.sync_co_members(&union(&["aa"]), DAY_START).unwrap();
        storage.sync_co_members(&[], DAY_START).unwrap();

        // 259 200 seconds after the last shared day: still inside the window,
        // so the read must return it AND leave it alone.
        assert_eq!(
            storage
                .ranked_directory_members(DAY_START + 259_200)
                .unwrap()
                .len(),
            1,
            "the boundary second is included"
        );
        assert_eq!(row_count(&storage), 1);

        // 259 201: gone from the answer, and gone from the disk. The second
        // assertion is the one a display filter would fail while the first
        // passed.
        assert!(
            storage
                .ranked_directory_members(DAY_START + 259_201)
                .unwrap()
                .is_empty(),
            "an expired person must never be offered"
        );
        assert_eq!(
            row_count(&storage),
            0,
            "the read must have DELETED the expired row, not hidden it"
        );
    }

    #[test]
    fn a_current_co_member_is_never_purged() {
        let storage = CircleStorage::in_memory().unwrap();
        storage.sync_co_members(&union(&["aa"]), DAY_START).unwrap();

        assert_eq!(
            storage.prune_expired_directory_members(i64::MAX).unwrap(),
            0,
            "the never-sentinel must outlast any clock"
        );
        assert_eq!(row_count(&storage), 1);
    }

    #[test]
    fn the_never_sentinel_survives_every_read() {
        let storage = CircleStorage::in_memory().unwrap();
        storage.sync_co_members(&union(&["aa"]), DAY_START).unwrap();
        // Re-sync (the UPSERT arm) and a purge sweep both leave it intact.
        storage
            .sync_co_members(&union(&["aa"]), DAY_START + SECS_PER_DAY)
            .unwrap();
        storage
            .prune_expired_directory_members(DAY_START + SECS_PER_DAY)
            .unwrap();

        // Read at the end of time: the read's own sweep must not reach the
        // sentinel either, or the picker's first section empties itself on a
        // device whose clock is wrong.
        let entries = storage.ranked_directory_members(i64::MAX).unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].purge_after, i64::MAX);
        assert_eq!(entries[0].tier, DirectoryTier::Current);
        assert_eq!(entries[0].last_shared_day, DAY + 1);
        assert_eq!(
            raw_row(&storage, "aa").expect("row present").4,
            i64::MAX,
            "the raw column must hold the sentinel, not a float or a truncation"
        );
    }

    #[test]
    fn a_returning_member_is_promoted_back_to_current() {
        let storage = CircleStorage::in_memory().unwrap();
        storage.sync_co_members(&union(&["aa"]), DAY_START).unwrap();
        storage.sync_co_members(&[], DAY_START).unwrap();
        storage
            .sync_co_members(&union(&["aa"]), DAY_START + SECS_PER_DAY)
            .unwrap();

        let (is_current, last_shared_day, tier, _, purge_after) =
            raw_row(&storage, "aa").expect("row present");
        assert_eq!(is_current, 1);
        assert_eq!(tier, DirectoryTier::Current.as_db_value());
        assert_eq!(last_shared_day, DAY + 1);
        assert_eq!(purge_after, DIRECTORY_PURGE_NEVER);
    }

    #[test]
    fn an_empty_union_ages_everyone_out_and_deletes_nobody() {
        // Leaving every circle is not the same as never having shared one.
        let storage = CircleStorage::in_memory().unwrap();
        storage
            .sync_co_members(&union(&["aa", "bb"]), DAY_START)
            .unwrap();
        storage.sync_co_members(&[], DAY_START).unwrap();

        let entries = storage.ranked_directory_members(DAY_START).unwrap();
        assert_eq!(entries.len(), 2);
        assert!(entries.iter().all(|e| e.tier == DirectoryTier::Recent));
        assert!(entries
            .iter()
            .all(|e| e.purge_after == DAY_START + DIRECTORY_RETENTION_SECS));
    }

    #[test]
    fn ranked_read_puts_current_first_then_most_recent_then_pubkey() {
        let storage = CircleStorage::in_memory().unwrap();
        // "cc" and "dd" last shared on day DAY; "bb" a day later; "aa" is
        // current. Insertion order is deliberately not the expected order.
        storage
            .sync_co_members(&union(&["cc", "dd"]), DAY_START)
            .unwrap();
        storage
            .sync_co_members(&union(&["bb"]), DAY_START + SECS_PER_DAY)
            .unwrap();
        storage
            .sync_co_members(&union(&["aa"]), DAY_START + 2 * SECS_PER_DAY)
            .unwrap();

        let order: Vec<String> = storage
            .ranked_directory_members(DAY_START + 2 * SECS_PER_DAY)
            .unwrap()
            .into_iter()
            .map(|e| e.pubkey_hex)
            .collect();
        assert_eq!(order, vec!["aa", "bb", "cc", "dd"]);
    }

    #[test]
    fn explicit_removal_deletes_the_row_immediately() {
        let storage = CircleStorage::in_memory().unwrap();
        storage
            .sync_co_members(&union(&["aa", "bb"]), DAY_START)
            .unwrap();

        assert!(storage.delete_directory_member("aa").unwrap());
        assert_eq!(row_count(&storage), 1, "no three-day grace on a removal");
        assert!(raw_row(&storage, "aa").is_none());
        assert!(
            !storage.delete_directory_member("aa").unwrap(),
            "a second removal reports that nothing was there"
        );
        // The person removed stays removed through the next sync, because the
        // union no longer contains them.
        storage.sync_co_members(&union(&["bb"]), DAY_START).unwrap();
        assert!(raw_row(&storage, "aa").is_none());
    }

    #[test]
    fn a_case_variant_neither_duplicates_a_row_nor_defeats_a_removal() {
        // The primary key is lowercase hex; a caller handing back the same
        // pubkey in another case must not create a second person, and must not
        // make the removal silently miss.
        let storage = CircleStorage::in_memory().unwrap();
        storage
            .sync_co_members(&union(&["AABB", "aabb"]), DAY_START)
            .unwrap();
        assert_eq!(row_count(&storage), 1);
        assert!(raw_row(&storage, "aabb").is_some());

        assert!(storage.delete_directory_member("AaBb").unwrap());
        assert_eq!(row_count(&storage), 0);
    }

    #[test]
    fn the_batch_removal_deletes_the_whole_set_and_nobody_else() {
        // The reconcile's retire set arrives on the receive path; batching it
        // must not change WHAT is removed, only how many transactions it costs.
        // Case normalization and the "absent pubkey" case are carried over from
        // the single-row path, because the caller reads the count.
        let storage = CircleStorage::in_memory().unwrap();
        storage
            .sync_co_members(&union(&["aa", "bb", "cc"]), DAY_START)
            .unwrap();

        assert_eq!(
            storage
                .delete_directory_members(&union(&["AA", "cc", "dd"]))
                .unwrap(),
            2,
            "a pubkey with no row contributes nothing to the count"
        );
        assert_eq!(
            storage
                .ranked_directory_members(DAY_START)
                .unwrap()
                .into_iter()
                .map(|e| e.pubkey_hex)
                .collect::<Vec<_>>(),
            vec!["bb"]
        );
    }

    #[test]
    fn an_empty_batch_removal_touches_nothing() {
        // The reconcile calls this every pass, and most passes retire nobody.
        let storage = CircleStorage::in_memory().unwrap();
        storage
            .sync_co_members(&union(&["aa", "bb"]), DAY_START)
            .unwrap();

        assert_eq!(storage.delete_directory_members(&[]).unwrap(), 0);
        assert_eq!(row_count(&storage), 2);
    }

    #[test]
    fn a_sync_writes_only_the_rows_whose_state_actually_changed() {
        // `sync_co_members` runs on the RECEIVE path, where most passes are
        // triggered by traffic that changed no roster at all. A pass that
        // rewrites every row to store what was already there costs every page
        // of the directory, per commit, on battery.
        let storage = CircleStorage::in_memory().unwrap();
        storage
            .sync_co_members(&union(&["aa", "bb", "cc"]), DAY_START)
            .unwrap();

        let before = rows_written(&storage);
        storage
            .sync_co_members(&union(&["aa", "bb", "cc"]), DAY_START + 3_600)
            .unwrap();
        assert_eq!(
            rows_written(&storage) - before,
            0,
            "an unchanged roster, later the same day, must write nothing"
        );

        let before = rows_written(&storage);
        storage
            .sync_co_members(&union(&["aa", "cc"]), DAY_START + 3_600)
            .unwrap();
        assert_eq!(
            rows_written(&storage) - before,
            1,
            "one person leaving must cost one row, not the table"
        );
        assert_eq!(
            raw_row(&storage, "bb")
                .expect("the departed row is still there")
                .2,
            DirectoryTier::Recent.as_db_value(),
            "and the one row written must be the demotion"
        );

        let before = rows_written(&storage);
        storage
            .sync_co_members(&union(&["aa", "cc"]), DAY_START + 7_200)
            .unwrap();
        assert_eq!(
            rows_written(&storage) - before,
            0,
            "re-running the same demotion must be free, not another rewrite"
        );

        // A new day genuinely changes every current row (`last_shared_day`
        // moves), so the skip must not swallow that write.
        let before = rows_written(&storage);
        storage
            .sync_co_members(&union(&["aa", "cc"]), DAY_START + SECS_PER_DAY)
            .unwrap();
        assert_eq!(
            rows_written(&storage) - before,
            2,
            "crossing into a new day must restamp exactly the current members"
        );
    }

    #[test]
    fn a_hand_corrupted_row_is_repaired_by_the_next_sync() {
        // The skip is a comparison against the row as stored, so a row that
        // disagrees with its target — here `tier` contradicting `is_current`,
        // the pair a reader of either column depends on — must be rewritten
        // rather than left alone because "nothing changed".
        let storage = CircleStorage::in_memory().unwrap();
        storage
            .sync_co_members(&union(&["aa", "bb"]), DAY_START)
            .unwrap();
        {
            let conn = storage.conn().lock().unwrap();
            conn.execute(
                "UPDATE member_directory SET tier = ?1, purge_after = 0 WHERE pubkey = 'aa'",
                params![DirectoryTier::Recent.as_db_value()],
            )
            .unwrap();
        }

        storage
            .sync_co_members(&union(&["aa", "bb"]), DAY_START)
            .unwrap();
        let (is_current, _, tier, _, purge_after) = raw_row(&storage, "aa").expect("row present");
        assert_eq!(is_current, 1);
        assert_eq!(tier, DirectoryTier::Current.as_db_value());
        assert_eq!(
            purge_after, DIRECTORY_PURGE_NEVER,
            "a current co-member whose row lost its sentinel must get it back, \
             or the next sweep deletes someone still in a circle"
        );
    }

    #[test]
    fn is_current_and_tier_never_drift() {
        // The two columns encode the same fact and the plan's schema keeps
        // both; this pins the single writer so a reader of either is right.
        let storage = CircleStorage::in_memory().unwrap();
        let assert_lockstep = |storage: &CircleStorage| {
            for (is_current, tier) in current_and_tier(storage) {
                assert_eq!(
                    is_current == 1,
                    tier == DirectoryTier::Current.as_db_value(),
                    "is_current={is_current} contradicts tier={tier}"
                );
            }
        };

        storage
            .sync_co_members(&union(&["aa", "bb"]), DAY_START)
            .unwrap();
        assert_lockstep(&storage);
        storage.sync_co_members(&union(&["aa"]), DAY_START).unwrap();
        assert_lockstep(&storage);
        storage.sync_co_members(&[], DAY_START).unwrap();
        assert_lockstep(&storage);
        storage
            .sync_co_members(&union(&["bb"]), DAY_START + SECS_PER_DAY)
            .unwrap();
        assert_lockstep(&storage);
    }

    #[test]
    fn the_member_directory_does_not_outlive_the_circles_db_file() {
        // INV-D-DIRECTORY-NEVER-LEAVES-SQLCIPHER: logout deletes exactly the
        // circles.db files, so the guarantee holds only while these rows have
        // no second home — a preferences entry, a sidecar, a keyring blob.
        // Reproduce the real mechanism against a file-backed database.
        let dir = tempfile::TempDir::new().expect("temp dir");
        let db_path = dir.path().join("circles.db");

        {
            let storage = CircleStorage::new(&db_path, None).expect("open");
            storage
                .sync_co_members(&union(&["aa", "bb"]), DAY_START)
                .unwrap();
            assert_eq!(
                storage.ranked_directory_members(DAY_START).unwrap().len(),
                2
            );
        } // dropped: the connection closes and any journal is checkpointed.

        assert!(
            db_path.exists(),
            "the rows must have been persisted on disk"
        );
        // Exactly what `delete_circles_db_files` removes on logout.
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let path = if suffix.is_empty() {
                db_path.clone()
            } else {
                std::path::PathBuf::from(format!("{}{suffix}", db_path.display()))
            };
            let _ = std::fs::remove_file(path);
        }
        assert!(!db_path.exists());

        let storage = CircleStorage::new(&db_path, None).expect("reopen a fresh database");
        assert!(
            storage
                .ranked_directory_members(DAY_START)
                .unwrap()
                .is_empty(),
            "the directory must not survive deletion of circles.db — if this \
             fails, co-membership is being persisted somewhere the logout wipe \
             does not reach"
        );
    }

    #[test]
    fn day_bucket_is_clamped_so_the_purge_arithmetic_stays_integral() {
        assert_eq!(day_bucket(0), 0);
        assert_eq!(day_bucket(SECS_PER_DAY - 1), 0);
        assert_eq!(day_bucket(SECS_PER_DAY), 1);
        assert_eq!(
            day_bucket(-1),
            0,
            "a pre-1970 clock cannot write a negative"
        );
        assert_eq!(day_bucket(i64::MIN), 0);
        assert_eq!(
            day_bucket(i64::MAX),
            i64::MAX / SECS_PER_DAY - DIRECTORY_RETENTION_DAYS
        );

        // End to end at both extremes: SQLite falls back to floating point on
        // integer overflow and would store a REAL in this INTEGER column, so
        // reading the row back as an `i64` is the assertion that matters.
        for clock in [i64::MIN, i64::MAX] {
            let storage = CircleStorage::in_memory().unwrap();
            storage.sync_co_members(&union(&["aa"]), clock).unwrap();
            storage.sync_co_members(&[], clock).unwrap();
            let (_, last_shared_day, _, _, purge_after) =
                raw_row(&storage, "aa").expect("row present");
            assert_eq!(last_shared_day, day_bucket(clock));
            assert_eq!(
                purge_after,
                day_bucket(clock) * SECS_PER_DAY + DIRECTORY_RETENTION_SECS
            );
        }
    }
}

// ==================== Proptest: retention and the never-sentinel ====================
// Outside `mod tests` so proptest can be imported without tripping over the
// `#[cfg(test)]` attribute (mirrors `storage::proptest_gift_wrap`).

#[cfg(test)]
mod proptest_member_directory {
    use super::*;
    use proptest::prelude::*;

    proptest! {
        #![proptest_config(proptest::test_runner::Config::with_cases(50))]

        /// Whatever the device clock says, a departed co-member's `purge_after`
        /// is day-aligned and lands exactly [`DIRECTORY_RETENTION_SECS`] after
        /// the start of the last day they shared a circle.
        ///
        /// Day alignment is the privacy half: a `purge_after` carrying a
        /// second would re-encode the departure moment the day bucketing
        /// exists to blur. Exactness is the retention half. Sampling the whole
        /// `i64` range also proves the clamped bucket keeps the SQL
        /// multiplication in integer arithmetic — an overflow there stores a
        /// REAL in an INTEGER column and the read fails.
        #[test]
        fn prop_purge_after_is_day_aligned_and_exactly_three_days_out(
            now in any::<i64>(),
        ) {
            let storage = CircleStorage::in_memory().unwrap();
            storage.sync_co_members(&[String::from("aa")], now).unwrap();
            storage.sync_co_members(&[], now).unwrap();

            // Read from the start of the last day shared: inside the window
            // for every sampled clock, including the clamped extremes, so the
            // read's own sweep cannot remove the row under test.
            let entry = storage
                .ranked_directory_members(day_bucket(now) * SECS_PER_DAY)
                .unwrap()
                .pop()
                .expect("the departed row survives its own sync");
            prop_assert_eq!(entry.purge_after % 86_400, 0, "purge_after must not encode a second");
            prop_assert_eq!(
                entry.purge_after,
                entry.last_shared_day * 86_400 + DIRECTORY_RETENTION_SECS
            );
        }

        /// No clock, forward or backward, purges a current co-member —
        /// through the scheduled sweep or the one the read runs. The sentinel
        /// is what keeps the picker's first section from emptying itself on a
        /// device whose time is wrong.
        #[test]
        fn prop_a_current_co_member_survives_any_purge_clock(
            synced_at in any::<i64>(),
            purged_at in any::<i64>(),
        ) {
            let storage = CircleStorage::in_memory().unwrap();
            storage.sync_co_members(&[String::from("aa")], synced_at).unwrap();

            prop_assert_eq!(storage.prune_expired_directory_members(purged_at).unwrap(), 0);
            let entry = storage
                .ranked_directory_members(purged_at)
                .unwrap()
                .pop()
                .expect("row present");
            prop_assert_eq!(entry.tier, DirectoryTier::Current);
            prop_assert_eq!(entry.purge_after, DIRECTORY_PURGE_NEVER);
        }
    }
}
