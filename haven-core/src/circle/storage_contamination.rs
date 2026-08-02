//! Storage methods for the append-only contamination ledger.
//!
//! Extends [`CircleStorage`] with the `contaminated_relays` table defined in
//! [`CircleStorage::initialize_schema`], plus the two profile-plane accessors
//! built on top of it. See [`super::contamination`] for why the ledger is
//! append-only, flat (no circle/group column), and normalized.
//!
//! # Locking discipline
//!
//! Every public method here follows the parent module's lock-once-then-
//! transaction pattern. The write path is additionally exposed as
//! [`record_contaminated_on`], which takes an ALREADY-OPEN connection: the seed
//! / add / restore paths in [`super::storage_relay_prefs`] record contamination
//! inside their own transaction, and calling a self-locking method from there
//! would deadlock on the non-reentrant `Mutex<Connection>`. Both routes share
//! the same statement, so they cannot drift.

// Single-shot SQLite ops naturally hold the lock to completion; the sibling
// storage modules disable this lint at file level for the same reason.
#![allow(clippy::significant_drop_tightening)]

use rusqlite::{params, Connection};

use super::contamination::{canonical_urls, ContaminationSource};
use super::error::{CircleError, Result};
use super::relay_prefs::RelayType;
use super::storage::CircleStorage;

/// Records `urls` as contaminated on an already-open connection.
///
/// Returns the number of rows actually inserted (i.e. relays seen here for the
/// FIRST time); an already-present URL is ignored, never updated.
///
/// `INSERT OR IGNORE` is the append-only guarantee in SQL form: `first_seen`
/// records the first sighting forever, so a re-record cannot rewrite history
/// into looking more recent, and a later `source` cannot overwrite the original
/// one.
///
/// # Errors
///
/// Propagates `SQLite` errors from the insert.
pub fn record_contaminated_on(
    conn: &Connection,
    urls: &[String],
    source: ContaminationSource,
    now: i64,
) -> rusqlite::Result<usize> {
    let mut inserted = 0;
    for url in canonical_urls(urls) {
        inserted += conn.execute(
            "INSERT OR IGNORE INTO contaminated_relays (url, source, first_seen)
             VALUES (?1, ?2, ?3)",
            params![url, source.as_str(), now],
        )?;
    }
    Ok(inserted)
}

/// Records the relays of one user-relay category as contaminated, on an
/// already-open connection.
///
/// A no-op for [`RelayType::Profile`]: that category IS the profile pool, and
/// [`ContaminationSource::for_relay_type`] gives a caller no source value to
/// pass for it (see that function's docs for why the rule lives in the type
/// system rather than in an `if` at each call site).
///
/// # Errors
///
/// Propagates `SQLite` errors from the insert.
pub fn record_relay_category_on(
    conn: &Connection,
    urls: &[String],
    relay_type: RelayType,
    now: i64,
) -> rusqlite::Result<usize> {
    ContaminationSource::for_relay_type(relay_type).map_or_else(
        // `RelayType::Profile` maps to no source: the profile pool is the set
        // being PROTECTED, so recording it would exclude the plane from itself.
        || Ok(0),
        |source| record_contaminated_on(conn, urls, source, now),
    )
}

impl CircleStorage {
    /// Appends `urls` to the contamination ledger under `source`.
    ///
    /// Idempotent and monotonic: a relay already in the ledger keeps its
    /// original `first_seen` and `source`. URLs are canonicalized through
    /// [`crate::relay::normalize_relay_url`] first, so `wss://Relay.Example/`
    /// and `wss://relay.example` collapse to one row — without that, the
    /// exclusion in [`Self::usable_profile_relays`] would fail OPEN on a
    /// case or trailing-slash variant.
    ///
    /// Entries that cannot be canonicalized are skipped, which is safe: the
    /// profile pool's resolver rejects the same inputs, so a skipped URL can
    /// never be a pool member that goes unexcluded.
    ///
    /// # Errors
    ///
    /// Returns [`CircleError::Storage`] if the lock cannot be acquired and
    /// [`CircleError::Database`] for `SQLite` errors.
    pub fn record_contaminated_relays(
        &self,
        urls: &[String],
        source: ContaminationSource,
        now: i64,
    ) -> Result<()> {
        if urls.is_empty() {
            return Ok(());
        }
        let mut conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        let tx = conn.transaction()?;
        record_contaminated_on(&tx, urls, source, now)?;
        tx.commit()?;
        Ok(())
    }

    /// Returns every contaminated relay URL, in canonical form.
    ///
    /// Ordered by `first_seen` then `url` so the result is deterministic across
    /// runs (the profile-pool assignment is order-independent, but a stable
    /// order keeps diagnostics and tests reproducible).
    ///
    /// # Errors
    ///
    /// Returns [`CircleError::Storage`] if the lock cannot be acquired and
    /// [`CircleError::Database`] for `SQLite` errors.
    pub fn list_contaminated_relays(&self) -> Result<Vec<String>> {
        let conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        let mut stmt =
            conn.prepare("SELECT url FROM contaminated_relays ORDER BY first_seen ASC, url ASC")?;
        let rows = stmt
            .query_map([], |row| row.get::<_, String>(0))?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    // NOTE: there is deliberately NO method that removes ledger rows.
    //
    // Contamination is historical: a relay that routed a circle's kind-445 last
    // month saw those events, and leaving that circle does not un-see them.
    // Every plausible "clean up stale rows" caller — circle teardown,
    // relay-preference edits, a maintenance task — would silently re-admit a
    // relay that already holds the user's encrypted traffic. The one case where
    // forgetting is correct is LOGOUT, where the identity those relays observed
    // is itself destroyed; that happens by deleting the whole `circles.db` file
    // (the FFI wipe), which needs no API here. A `clear_contaminated_relays`
    // used to exist for that case and had no caller — its only effect was to
    // advertise a removal path this table must not have.

    /// Folds the CURRENT location-plane relay configuration into the ledger.
    ///
    /// Unions every circle's routing relays (`circles.relays`) with the user's
    /// [`RelayType::Inbox`] and [`RelayType::KeyPackage`] rows and the
    /// discovery plane ([`crate::relay::discovery_relays`]), and appends the
    /// result. Returns the number of relays recorded for the first time.
    ///
    /// # Why the discovery plane is folded in HERE and has no write site
    ///
    /// The discovery relays serve `fetch_relay_list` / `fetch_member_keypackage`
    /// (`crate::relay::manager`): read-only queries, but for the pre-invitation
    /// step of the LOCATION plane. "This IP asked for pubkey X's `KeyPackage`"
    /// is a stronger co-membership signal than a kind-0 lookup, so a relay that
    /// answers both can join them.
    ///
    /// Unlike the other sources there is no per-event write site, and none is
    /// needed: the discovery set is a process constant (a shipped list plus an
    /// install-once debug override), not a per-query choice, so folding it once
    /// per launch records exactly the set any discovery query can reach. A
    /// write site at the query would add nothing but lock traffic on a path
    /// that runs on every contact resolution.
    ///
    /// This costs a default-configured user nothing:
    /// `PRODUCTION_PROFILE_RELAYS` is disjoint from
    /// `PRODUCTION_DISCOVERY_RELAYS` by construction (pinned by
    /// `pool_is_disjoint_from_discovery_plane`), so the fold subtracts zero
    /// pool entries — see `default_profile_pool_does_not_underflow_after_the_discovery_fold`.
    /// It matters for the user who adds a discovery relay (e.g.
    /// `wss://relay.primal.net`) to their Profile category by hand: without the
    /// fold that operator would see both this account's `KeyPackage`/NIP-65
    /// lookups and its kind-0 lookups, over overlapping author sets.
    ///
    /// # Why this exists
    ///
    /// The per-event write sites only fire from the moment they shipped. An
    /// install that predates them already has circles, inbox relays and
    /// `KeyPackage` relays whose contamination was never recorded, so its ledger
    /// would be empty and its profile pool would happily include a relay that
    /// has been carrying its kind-445 for months. Running this fold once at
    /// startup backfills those installs; on a current install it is a cheap
    /// no-op because every URL is already present (`INSERT OR IGNORE`).
    ///
    /// It is also a self-healing net for any location-plane write site added
    /// later that forgets to record: the next launch picks the relay up, as long
    /// as it is still in the live configuration.
    ///
    /// # Known limitation: historical welcome-cascade relays are unrecoverable
    ///
    /// The Welcome delivery cascade resolves each invitee's relays at send time
    /// (member inbox → member NIP-65 → creator inbox) and persists that set
    /// NOWHERE — not in `circles`, not in `user_relays`. There is therefore no
    /// on-device record to fold in, and a relay that received a gift-wrapped
    /// Welcome before the [`ContaminationSource::Welcome`] write site shipped
    /// **cannot** be backfilled. Going forward it is recorded at dispatch time;
    /// for the historical window the mitigation is that the curated profile pool
    /// is disjoint from the account seed and the discovery plane by construction,
    /// so the relays most likely to have served those welcomes are not pool
    /// candidates in the first place.
    ///
    /// # Errors
    ///
    /// Returns [`CircleError::Storage`] if the lock cannot be acquired and
    /// [`CircleError::Database`] for `SQLite` errors.
    pub fn refresh_contamination_ledger(&self, now: i64) -> Result<usize> {
        // Gather with the lock RELEASED between reads: `get_all_circles` and
        // `list_user_relays` each take it themselves, and the mutex is not
        // reentrant.
        let circle_relays: Vec<String> = self
            .get_all_circles()?
            .into_iter()
            .flat_map(|circle| circle.relays)
            .collect();
        let inbox = self.list_user_relays(RelayType::Inbox)?;
        let key_package = self.list_user_relays(RelayType::KeyPackage)?;
        // The EFFECTIVE accessor, not `PRODUCTION_DISCOVERY_RELAYS`: a hermetic
        // harness that redirects discovery to a local relay must have THAT
        // relay recorded, or the E2E lanes would exclude eight public hosts
        // they never contact while leaving the one they do contact unexcluded.
        let discovery = crate::relay::discovery_relays();

        let mut conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        let tx = conn.transaction()?;
        let mut inserted =
            record_contaminated_on(&tx, &circle_relays, ContaminationSource::CircleRouting, now)?;
        inserted += record_contaminated_on(&tx, &inbox, ContaminationSource::Inbox, now)?;
        inserted +=
            record_contaminated_on(&tx, &key_package, ContaminationSource::KeyPackage, now)?;
        inserted += record_contaminated_on(&tx, &discovery, ContaminationSource::Discovery, now)?;
        tx.commit()?;
        Ok(inserted)
    }

    /// The profile-plane relays that are safe to use right now.
    ///
    /// The curated pool ([`crate::profile::profile_relay_pool_default`] — the
    /// EFFECTIVE set, not the raw constant, so a hermetic test override is
    /// honoured here too) unioned
    /// with the user's stored [`RelayType::Profile`] rows, minus every entry in
    /// the contamination ledger. Both sides are normalized before subtraction by
    /// [`crate::profile::resolve_profile_pool`].
    ///
    /// # Union rationale, and its one known wart
    ///
    /// Unioning rather than reading the stored rows alone keeps the plane usable
    /// in two situations that would otherwise brick it: an install whose profile
    /// seed has not run yet (no rows at all), and an upgrade that adds curated
    /// entries after the profile seed sentinel is already set. Because underflow
    /// is TERMINAL (there is deliberately no fallback), "brick" here means the
    /// profile plane stops resolving names and avatars entirely.
    ///
    /// The wart: a curated relay the user deliberately REMOVED from the profile
    /// category comes back through the union, because removals are not recorded
    /// anywhere (the `user_relays` table has no tombstone). This is a UX wart,
    /// not a plane-separation hole — a removed-but-contaminated relay is still
    /// excluded by the ledger. Recording removals would need a new table, i.e. a
    /// schema change beyond this module.
    ///
    /// # Errors
    ///
    /// Returns [`crate::profile::ProfileError::PoolUnderflow`] when fewer than
    /// [`crate::profile::PROFILE_POOL_MIN`] relays survive exclusion, and
    /// [`crate::profile::ProfileError::Sqlite`] if the local read fails.
    ///
    /// Underflow is fail-closed and TERMINAL: callers MUST NOT substitute the
    /// discovery plane, the account seed, or any excluded relay. Any such
    /// fallback re-creates the exact cross-plane join the pool exists to break,
    /// and does it at the moment the user is least likely to notice.
    pub fn usable_profile_relays(&self) -> crate::profile::Result<Vec<String>> {
        let mut configured = self
            .list_user_relays(RelayType::Profile)
            .map_err(crate::profile::ProfileError::sqlite)?;
        // MUST be the effective accessor, not `production_profile_relays()`.
        // This union is what re-admits the curated pool after the user's own
        // rows, so reading the raw constant here would silently pull the eight
        // public relays back in even when a hermetic override is installed —
        // making the E2E plane-separation proof a rehearsal against relays the
        // test never intended to dial.
        configured.extend(crate::profile::profile_relay_pool_default());

        let contaminated = self
            .list_contaminated_relays()
            .map_err(crate::profile::ProfileError::sqlite)?;

        crate::profile::resolve_profile_pool(&configured, &contaminated)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::circle::types::{Circle, CircleType};
    use crate::nostr::mls::types::{GroupId, GroupIdExt};
    use crate::profile::{ProfileError, PROFILE_POOL_MIN};

    fn make_storage() -> CircleStorage {
        CircleStorage::in_memory().expect("in-memory storage must initialize")
    }

    fn owned(entries: &[&str]) -> Vec<String> {
        entries.iter().map(|s| (*s).to_string()).collect()
    }

    fn circle_with_relays(id: u8, relays: Vec<String>) -> Circle {
        Circle {
            mls_group_id: GroupId::from_slice(&[id; 32]),
            nostr_group_id: [id; 32],
            display_name: format!("Circle {id}"),
            circle_type: CircleType::LocationSharing,
            relays,
            created_at: 1_000,
            updated_at: 1_000,
        }
    }

    /// Reads the raw `(source, first_seen)` for one canonical URL.
    fn ledger_row(storage: &CircleStorage, url: &str) -> Option<(String, i64)> {
        let conn = storage.conn().lock().unwrap();
        conn.query_row(
            "SELECT source, first_seen FROM contaminated_relays WHERE url = ?1",
            params![url],
            |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?)),
        )
        .ok()
    }

    #[test]
    fn record_and_list_round_trip() {
        let storage = make_storage();
        storage
            .record_contaminated_relays(
                &owned(&["wss://a.example", "wss://b.example"]),
                ContaminationSource::CircleRouting,
                10,
            )
            .unwrap();
        assert_eq!(
            storage.list_contaminated_relays().unwrap(),
            owned(&["wss://a.example", "wss://b.example"])
        );
    }

    #[test]
    fn empty_input_is_a_no_op() {
        let storage = make_storage();
        storage
            .record_contaminated_relays(&[], ContaminationSource::Welcome, 1)
            .unwrap();
        assert!(storage.list_contaminated_relays().unwrap().is_empty());
    }

    #[test]
    fn first_seen_and_source_are_never_overwritten() {
        // The append-only guarantee at the row level: a re-record must not
        // rewrite history into looking more recent, nor relabel the origin.
        let storage = make_storage();
        storage
            .record_contaminated_relays(
                &owned(&["wss://a.example"]),
                ContaminationSource::CircleRouting,
                100,
            )
            .unwrap();
        storage
            .record_contaminated_relays(
                &owned(&["wss://a.example"]),
                ContaminationSource::Welcome,
                999,
            )
            .unwrap();
        assert_eq!(
            ledger_row(&storage, "wss://a.example"),
            Some(("circle_routing".to_string(), 100))
        );
        assert_eq!(storage.list_contaminated_relays().unwrap().len(), 1);
    }

    #[test]
    fn contaminated_ledger_is_append_only() {
        // Contamination is HISTORICAL. Removing a relay from a circle, and even
        // deleting the circle outright, must leave the ledger row standing —
        // the relay saw those kind-445 events and cannot un-see them.
        let storage = make_storage();
        let circle = circle_with_relays(1, owned(&["wss://routed.example"]));
        storage.save_circle(&circle).unwrap();
        storage.refresh_contamination_ledger(10).unwrap();
        // `contains`, not equality: the fold also records the discovery plane.
        assert!(storage
            .list_contaminated_relays()
            .unwrap()
            .contains(&"wss://routed.example".to_string()));

        // 1. The circle drops the relay from its routing set.
        let mut narrowed = circle.clone();
        narrowed.relays = owned(&["wss://other.example"]);
        storage.save_circle(&narrowed).unwrap();
        assert!(
            storage
                .list_contaminated_relays()
                .unwrap()
                .contains(&"wss://routed.example".to_string()),
            "dropping a relay from a circle must not clear its ledger row"
        );

        // 2. The circle is deleted entirely (leave / decline / rollback).
        assert!(storage.delete_circle(&circle.mls_group_id).unwrap());
        assert!(storage.get_circle(&circle.mls_group_id).unwrap().is_none());
        assert!(
            storage
                .list_contaminated_relays()
                .unwrap()
                .contains(&"wss://routed.example".to_string()),
            "delete_circle must NOT cascade into the contamination ledger"
        );

        // 3. NOTHING in the API can clear it. Logout — the one case where
        // forgetting is correct — deletes the database FILE, so the ledger goes
        // with it and needs no removal method. Reproduce exactly that against a
        // file-backed database: the row survives a reopen, and only deleting
        // circles.db (plus the sidecars the FFI wipe removes) drops it.
        let dir = tempfile::TempDir::new().expect("temp dir");
        let db_path = dir.path().join("circles.db");
        {
            let on_disk = CircleStorage::new(&db_path, None).expect("open");
            on_disk
                .record_contaminated_relays(
                    &owned(&["wss://routed.example"]),
                    ContaminationSource::CircleRouting,
                    10,
                )
                .unwrap();
        }
        {
            let reopened = CircleStorage::new(&db_path, None).expect("reopen");
            assert_eq!(
                reopened.list_contaminated_relays().unwrap(),
                owned(&["wss://routed.example"]),
                "a restart must not forget contamination"
            );
        }
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let path = if suffix.is_empty() {
                db_path.clone()
            } else {
                std::path::PathBuf::from(format!("{}{suffix}", db_path.display()))
            };
            let _ = std::fs::remove_file(path);
        }
        let after_wipe = CircleStorage::new(&db_path, None).expect("fresh database");
        assert!(after_wipe.list_contaminated_relays().unwrap().is_empty());
    }

    #[test]
    fn contaminated_ledger_normalizes_before_insert_and_compare() {
        // Set subtraction over raw strings fails OPEN: a trailing slash or a
        // capitalised host would let a contaminated relay survive exclusion and
        // start serving profile traffic.
        let storage = make_storage();
        storage
            .record_contaminated_relays(
                &owned(&["wss://Relay.Example/"]),
                ContaminationSource::CircleRouting,
                10,
            )
            .unwrap();

        // Stored canonically, exactly once.
        assert_eq!(
            storage.list_contaminated_relays().unwrap(),
            owned(&["wss://relay.example"])
        );

        // A differently-spelled pool entry is still excluded.
        let configured = owned(&[
            "wss://relay.example",
            "wss://a.example",
            "wss://b.example",
            "wss://c.example",
        ]);
        let usable = crate::profile::resolve_profile_pool(
            &configured,
            &storage.list_contaminated_relays().unwrap(),
        )
        .expect("3 survive");
        assert!(
            !usable.iter().any(|u| u.contains("relay.example")),
            "normalization mismatch let a contaminated relay through: {usable:?}"
        );

        // And re-recording another spelling does not create a second row.
        storage
            .record_contaminated_relays(
                &owned(&["WSS://RELAY.EXAMPLE", "  wss://relay.example/  "]),
                ContaminationSource::Inbox,
                20,
            )
            .unwrap();
        assert_eq!(storage.list_contaminated_relays().unwrap().len(), 1);
    }

    #[test]
    fn refresh_contamination_ledger_backfills_existing_installs() {
        // An install that predates the per-event write sites has circles, inbox
        // relays and KeyPackage relays whose contamination was never recorded.
        let storage = make_storage();
        storage
            .save_circle(&circle_with_relays(
                1,
                owned(&["wss://circle-one.example", "wss://shared.example"]),
            ))
            .unwrap();
        storage
            .save_circle(&circle_with_relays(
                2,
                owned(&["wss://circle-two.example", "wss://shared.example"]),
            ))
            .unwrap();

        // Insert the user-relay rows directly, bypassing `add_user_relay`, so
        // the fold is proven to backfill rather than merely observing what the
        // write site already recorded.
        {
            let conn = storage.conn().lock().unwrap();
            for (url, kind) in [
                ("wss://inbox.example", RelayType::Inbox),
                ("wss://kp.example", RelayType::KeyPackage),
                ("wss://profile.example", RelayType::Profile),
            ] {
                conn.execute(
                    "INSERT OR IGNORE INTO user_relays (url, relay_type, created_at)
                     VALUES (?1, ?2, ?3)",
                    params![url, kind.as_str(), 1],
                )
                .unwrap();
            }
        }
        assert!(
            storage.list_contaminated_relays().unwrap().is_empty(),
            "precondition: the pre-upgrade ledger is empty"
        );

        let inserted = storage.refresh_contamination_ledger(500).unwrap();
        let ledger = storage.list_contaminated_relays().unwrap();
        let discovery = crate::relay::discovery_relays();
        assert_eq!(
            inserted,
            5 + discovery.len(),
            "4 circle relays (one shared) + inbox + kp + the discovery plane"
        );
        for expected in [
            "wss://circle-one.example",
            "wss://circle-two.example",
            "wss://shared.example",
            "wss://inbox.example",
            "wss://kp.example",
        ] {
            assert!(ledger.contains(&expected.to_string()), "missing {expected}");
        }
        assert!(
            !ledger.contains(&"wss://profile.example".to_string()),
            "the profile category must never be folded into the ledger"
        );

        // Idempotent: a second fold records nothing new and preserves first_seen.
        assert_eq!(storage.refresh_contamination_ledger(900).unwrap(), 0);
        assert_eq!(
            ledger_row(&storage, "wss://inbox.example").map(|(_, seen)| seen),
            Some(500)
        );
    }

    #[test]
    fn discovery_relays_are_recorded_as_contaminated() {
        // The discovery plane serves `fetch_relay_list` /
        // `fetch_member_keypackage` — read-only, but the PRE-INVITATION step of
        // the location plane. "This IP asked for pubkey X's KeyPackage" is a
        // stronger co-membership signal than a kind-0 lookup, so a discovery
        // relay must never also serve this account's profile traffic.
        let storage = make_storage();
        let discovery = crate::relay::discovery_relays();
        assert!(
            !discovery.is_empty(),
            "non-vacuity: an empty discovery plane would make this pass trivially"
        );

        assert!(
            storage.list_contaminated_relays().unwrap().is_empty(),
            "precondition: the ledger starts empty"
        );
        storage.refresh_contamination_ledger(42).unwrap();

        let ledger = storage.list_contaminated_relays().unwrap();
        for relay in &discovery {
            let normalized =
                crate::relay::normalize_relay_url(relay).expect("discovery URLs are valid");
            assert!(
                ledger.contains(&normalized),
                "discovery relay {relay} was not recorded as contaminated"
            );
            assert_eq!(
                ledger_row(&storage, &normalized).map(|(src, _)| src),
                Some("discovery".to_string()),
                "discovery relay {relay} recorded under the wrong source"
            );
        }

        // The failure scenario the write site exists for: a user hand-adds a
        // discovery relay to their Profile category. Without the fold there is
        // no ledger row, so nothing excludes it and that operator sees both
        // this account's KeyPackage/NIP-65 lookups AND its kind-0 lookups.
        let hand_added = crate::relay::normalize_relay_url(&discovery[0]).expect("valid URL");
        storage
            .add_user_relay(&hand_added, RelayType::Profile)
            .unwrap();
        assert!(
            storage
                .list_user_relays(RelayType::Profile)
                .unwrap()
                .contains(&hand_added),
            "precondition: the relay really is configured for the profile plane"
        );
        let usable = storage
            .usable_profile_relays()
            .expect("pool still resolves");
        assert!(
            !usable.contains(&hand_added),
            "a hand-added discovery relay reached the profile pool: {hand_added}"
        );
    }

    #[test]
    fn default_profile_pool_does_not_underflow_after_the_discovery_fold() {
        // Folding the discovery plane in costs a DEFAULT-configured user
        // nothing: `PRODUCTION_PROFILE_RELAYS` is disjoint from
        // `PRODUCTION_DISCOVERY_RELAYS` by construction (pinned by
        // `pool_is_disjoint_from_discovery_plane`), so the subtraction removes
        // zero pool entries. If that ever stopped holding, the fold would eat a
        // default user's pool toward the terminal `PoolUnderflow` floor — a
        // regression, not a hardening — and this test is what catches it.
        let storage = make_storage();
        storage.seed_defaults_if_unseeded().unwrap();
        let before = storage.usable_profile_relays().expect("pool resolves");

        storage.refresh_contamination_ledger(7).unwrap();

        let after = storage
            .usable_profile_relays()
            .expect("the fold must not underflow a default-configured pool");
        assert_eq!(
            after, before,
            "the discovery fold removed relays from a default user's profile pool"
        );
        assert!(after.len() >= PROFILE_POOL_MIN);

        // Non-vacuity: the fold DID record the discovery plane, so the equality
        // above is a disjointness statement rather than a no-op.
        let ledger = storage.list_contaminated_relays().unwrap();
        for relay in crate::relay::discovery_relays() {
            let normalized =
                crate::relay::normalize_relay_url(&relay).expect("discovery URLs are valid");
            assert!(ledger.contains(&normalized), "fold did not run: {relay}");
        }
    }

    #[test]
    fn profile_relays_are_not_recorded_as_contaminated() {
        // The profile category IS the pool being protected. Recording it would
        // make the pool subtract itself: permanent PoolUnderflow, or — if some
        // caller "fixed" that with a fallback — profile traffic aimed straight
        // at the location plane.
        let storage = make_storage();
        {
            let conn = storage.conn().lock().unwrap();
            // The category-aware writer is a structural no-op for Profile:
            // `ContaminationSource::for_relay_type` yields no source to pass.
            let n = record_relay_category_on(
                &conn,
                &owned(&["wss://profile-only.example"]),
                RelayType::Profile,
                7,
            )
            .unwrap();
            assert_eq!(n, 0);
        }
        assert!(storage.list_contaminated_relays().unwrap().is_empty());

        // The full seeding path likewise leaves the curated pool clean.
        storage.seed_defaults_if_unseeded().unwrap();
        let ledger = storage.list_contaminated_relays().unwrap();
        for relay in crate::profile::production_profile_relays() {
            assert!(
                !ledger.contains(&relay),
                "curated profile relay {relay} was recorded as contaminated"
            );
        }
        // Non-vacuity: the seed DID record the account-seed categories, so the
        // assertion above is about the Profile exemption, not an empty ledger.
        assert!(
            !ledger.is_empty(),
            "seeding must record the inbox / key-package categories"
        );

        // ...and the pool therefore still resolves.
        let usable = storage.usable_profile_relays().expect("pool intact");
        assert!(usable.len() >= PROFILE_POOL_MIN);
    }

    #[test]
    fn usable_profile_relays_excludes_the_ledger() {
        let storage = make_storage();
        storage.seed_defaults_if_unseeded().unwrap();
        let before = storage.usable_profile_relays().expect("pool resolves");
        let victim = before.first().expect("non-empty pool").clone();

        storage
            .record_contaminated_relays(
                std::slice::from_ref(&victim),
                ContaminationSource::CircleRouting,
                10,
            )
            .unwrap();

        let after = storage
            .usable_profile_relays()
            .expect("pool still resolves");
        assert!(
            !after.contains(&victim),
            "a contaminated relay survived exclusion: {victim}"
        );
        assert_eq!(after.len(), before.len() - 1);
    }

    #[test]
    fn usable_profile_relays_unions_the_curated_pool_with_stored_rows() {
        // Nothing seeded: the curated pool alone must still resolve, so a
        // pre-seed launch does not brick the profile plane.
        let storage = make_storage();
        assert_eq!(
            storage.list_user_relays(RelayType::Profile).unwrap(),
            Vec::<String>::new()
        );
        let usable = storage.usable_profile_relays().expect("curated pool alone");
        // The union inside `usable_profile_relays` reads the EFFECTIVE accessor;
        // comparing against the shipped constant is unconditionally sound here
        // because no lib unit test installs the debug pool override (it lives
        // only in the `tests/profile_relay_override_*.rs` integration binaries,
        // one process each — CI-enforced by Check 12 of
        // `check_profile_privacy_boundaries.sh`).
        assert_eq!(usable, crate::profile::production_profile_relays());

        // A user-added profile relay joins the pool without duplicating the
        // curated entries.
        storage
            .add_user_relay("wss://my-own.example", RelayType::Profile)
            .unwrap();
        let widened = storage.usable_profile_relays().expect("union resolves");
        assert_eq!(widened.len(), usable.len() + 1);
        assert!(widened.contains(&"wss://my-own.example".to_string()));
        let unique: std::collections::HashSet<&String> = widened.iter().collect();
        assert_eq!(unique.len(), widened.len(), "union must deduplicate");
    }

    #[test]
    fn usable_profile_relays_underflow_never_returns_a_contaminated_or_discovery_relay() {
        // The single most damaging possible bug in this feature would be a
        // fallback on underflow. Assert BOTH halves: the typed error, and that
        // no discovery / contaminated URL is reachable through the Ok branch.
        let storage = make_storage();
        storage.seed_defaults_if_unseeded().unwrap();

        // Contaminate the whole pool bar two entries.
        let pool = storage.usable_profile_relays().expect("pool resolves");
        let doomed: Vec<String> = pool.iter().skip(2).cloned().collect();
        storage
            .record_contaminated_relays(&doomed, ContaminationSource::Welcome, 10)
            .unwrap();

        match storage.usable_profile_relays() {
            Err(ProfileError::PoolUnderflow { usable, required }) => {
                assert_eq!(usable, 2);
                assert_eq!(required, PROFILE_POOL_MIN);
            }
            Err(other) => panic!("expected PoolUnderflow, got {other:?}"),
            Ok(returned) => panic!("underflow must fail closed, got {returned:?}"),
        }

        // Non-vacuity + the real invariant: exercise the Ok branch by
        // un-contaminating one relay, and prove that NOTHING it returns is a
        // discovery-plane relay, an account-seed relay, or a ledger entry.
        // (Un-contaminating is a test-only manoeuvre, done by raw SQL precisely
        // because production exposes no row-removal API at all.)
        {
            let conn = storage.conn().lock().unwrap();
            conn.execute(
                "DELETE FROM contaminated_relays WHERE url = ?1",
                params![doomed[0]],
            )
            .unwrap();
        }
        let recovered = storage.usable_profile_relays().expect("3 survive");
        assert_eq!(recovered.len(), 3);

        let ledger = storage.list_contaminated_relays().unwrap();
        assert!(!ledger.is_empty(), "non-vacuity: the ledger has entries");
        for url in &recovered {
            assert!(!ledger.contains(url), "contaminated relay returned: {url}");
        }
        for discovery in crate::relay::PRODUCTION_DISCOVERY_RELAYS {
            let normalized =
                crate::relay::normalize_relay_url(discovery).expect("discovery URLs are valid");
            assert!(
                !recovered.contains(&normalized),
                "discovery-plane relay {discovery} reached the profile pool"
            );
        }
        for seed in crate::circle::PRODUCTION_DEFAULT_RELAYS {
            let normalized = crate::relay::normalize_relay_url(seed).expect("seed URLs are valid");
            assert!(
                !recovered.contains(&normalized),
                "account-seed relay {seed} reached the profile pool"
            );
        }
    }

    #[test]
    fn add_user_relay_records_the_location_plane_categories_only() {
        let storage = make_storage();
        storage
            .add_user_relay("wss://inbox.example", RelayType::Inbox)
            .unwrap();
        storage
            .add_user_relay("wss://kp.example", RelayType::KeyPackage)
            .unwrap();
        storage
            .add_user_relay("wss://profile.example", RelayType::Profile)
            .unwrap();

        let ledger = storage.list_contaminated_relays().unwrap();
        assert!(ledger.contains(&"wss://inbox.example".to_string()));
        assert!(ledger.contains(&"wss://kp.example".to_string()));
        assert!(!ledger.contains(&"wss://profile.example".to_string()));
        assert_eq!(
            ledger_row(&storage, "wss://inbox.example").map(|(src, _)| src),
            Some("inbox".to_string())
        );
        assert_eq!(
            ledger_row(&storage, "wss://kp.example").map(|(src, _)| src),
            Some("key_package".to_string())
        );
    }

    #[test]
    fn restore_and_reset_defaults_record_the_location_plane_categories() {
        let storage = make_storage();
        storage.restore_defaults_for(RelayType::Inbox).unwrap();
        storage
            .wipe_and_reset_defaults_for(RelayType::KeyPackage)
            .unwrap();
        storage.restore_defaults_for(RelayType::Profile).unwrap();

        let ledger = storage.list_contaminated_relays().unwrap();
        for relay in super::super::storage_relay_prefs::default_relays_for(RelayType::Inbox) {
            assert!(ledger.contains(&relay), "inbox default {relay} unrecorded");
        }
        for relay in crate::profile::production_profile_relays() {
            assert!(
                !ledger.contains(&relay),
                "profile default {relay} must not be recorded"
            );
        }
    }

    #[test]
    fn removing_a_user_relay_leaves_its_ledger_row() {
        // Un-configuring an inbox relay does not un-send the gift wraps it
        // already received.
        let storage = make_storage();
        storage
            .add_user_relay("wss://one.example", RelayType::Inbox)
            .unwrap();
        storage
            .add_user_relay("wss://two.example", RelayType::Inbox)
            .unwrap();
        assert!(storage
            .remove_user_relay("wss://one.example", RelayType::Inbox)
            .unwrap());
        assert!(storage
            .list_contaminated_relays()
            .unwrap()
            .contains(&"wss://one.example".to_string()));
    }
}
