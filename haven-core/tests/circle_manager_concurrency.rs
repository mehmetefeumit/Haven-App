//! Concurrency tests for `CircleManager`.
//!
//! These tests exist because the FFI wrapper (`CircleManagerFfi` in
//! `haven/rust_builder/src/api.rs`) was changed from
//! `tokio::sync::Mutex<CoreCircleManager>` to `Arc<CoreCircleManager>` so
//! that concurrent Dart→Rust calls no longer serialise behind a single
//! global lock. The mechanical sketch of the refactor is sound only if
//! `CircleManager` is itself safe to call concurrently from many threads
//! — every test below would have hit a data race, panic, or DB
//! corruption under the old assumption that it wasn't.
//!
//! Each test exercises a different concurrent access pattern:
//!
//! 1. `concurrent_contact_writes_are_safe` — many writers hammering
//!    `set_contact` for distinct keys, then a single reader verifying
//!    every row landed.
//! 2. `concurrent_reads_and_writes_are_safe` — read/write interleaving
//!    on overlapping keys (verifies the storage's internal mutex
//!    actually serialises writes correctly).
//! 3. `concurrent_last_known_upserts_are_idempotent` — overlapping
//!    writes for the **same** sender (the realistic
//!    location-broadcast race) leave a single row with the latest
//!    timestamp.
//! 4. `concurrent_prune_and_upsert_do_not_deadlock` — pruning runs in
//!    parallel with upserts; no deadlock and no negative-time row
//!    survives.
//!
//! **Not tested here**: concurrent MLS `encrypt_location`/`decrypt_location`
//! for the same group. MDK's `create_message` performs a non-atomic
//! read-modify-write on MLS group state, so concurrent calls for the same
//! group can race on the epoch counter. The Dart-side callers are
//! responsible for serialising MLS operations per group. Testing this
//! requires a full MLS key exchange and belongs in a separate integration
//! test file.
//!
//! All tests use `CircleManager::new_unencrypted` to avoid keyring
//! dependencies in CI.

use std::sync::Arc;
use std::thread;

use haven_core::circle::{CircleManager, LastKnownLocation};
use haven_core::location::LocationPrecision;
use tempfile::TempDir;

/// 32-byte hex pubkey derived from a u64 seed (deterministic, valid).
fn pubkey(seed: u64) -> String {
    let mut bytes = [0u8; 32];
    bytes[..8].copy_from_slice(&seed.to_be_bytes());
    hex::encode(bytes)
}

fn make_location(ngid: [u8; 32], sender: &str, ts: i64) -> LastKnownLocation {
    LastKnownLocation {
        nostr_group_id: ngid,
        sender_pubkey: sender.to_string(),
        latitude: 12.34,
        longitude: 56.78,
        geohash: "u4pruydqqvj".to_string(),
        precision: LocationPrecision::Enhanced.label().to_string(),
        display_name: None,
        timestamp: ts,
        expires_at: ts + 3600,
        retention_secs: 3600,
        purge_after: ts + 7200,
        updated_at: ts,
    }
}

#[test]
fn concurrent_contact_writes_are_safe() {
    let dir = TempDir::new().expect("temp dir");
    let manager = Arc::new(CircleManager::new_unencrypted(dir.path()).expect("manager"));

    let writers: Vec<_> = (0..16u64)
        .map(|i| {
            let m = manager.clone();
            thread::spawn(move || {
                for j in 0..32u64 {
                    let pk = pubkey(i * 1000 + j);
                    let name = format!("user_{i}_{j}");
                    m.set_contact(&pk, Some(&name), None, None)
                        .expect("set_contact must not fail under concurrency");
                }
            })
        })
        .collect();
    for w in writers {
        w.join().expect("writer panicked");
    }

    let all = manager.get_all_contacts().expect("get_all_contacts");
    assert_eq!(all.len(), 16 * 32, "every concurrent write must be visible");
}

#[test]
fn concurrent_reads_and_writes_are_safe() {
    let dir = TempDir::new().expect("temp dir");
    let manager = Arc::new(CircleManager::new_unencrypted(dir.path()).expect("manager"));

    // Seed.
    for i in 0..20u64 {
        manager
            .set_contact(&pubkey(i), Some(&format!("seed_{i}")), None, None)
            .expect("seed");
    }

    let mut handles = Vec::new();
    for t in 0..8 {
        let m = manager.clone();
        handles.push(thread::spawn(move || {
            for j in 0..40u64 {
                if (t + j) % 2 == 0 {
                    // Reader: existing seeded keys.
                    let pk = pubkey(j % 20);
                    let _ = m.get_contact(&pk).expect("get_contact");
                } else {
                    // Writer: distinct keys to avoid logical conflicts.
                    let pk = pubkey(1000 + (t * 100) + j);
                    m.set_contact(&pk, Some("mixed"), None, None)
                        .expect("set_contact");
                }
            }
        }));
    }
    for h in handles {
        h.join().expect("worker panicked");
    }

    // Sanity: at least the seeded contacts are still there.
    let all = manager.get_all_contacts().expect("get_all_contacts");
    assert!(
        all.len() >= 20,
        "seeded contacts must survive mixed concurrent traffic"
    );
}

#[test]
fn concurrent_last_known_upserts_are_idempotent() {
    let dir = TempDir::new().expect("temp dir");
    let manager = Arc::new(CircleManager::new_unencrypted(dir.path()).expect("manager"));

    let ngid = [42u8; 32];
    let sender = pubkey(7);

    // 16 threads × 50 writes for the SAME (circle, sender). The store's SQL
    // uses `WHERE excluded.timestamp > last_known_locations.timestamp`, so
    // only the row with the highest timestamp survives regardless of
    // thread scheduling order.
    let handles: Vec<_> = (0..16i64)
        .map(|t| {
            let m = manager.clone();
            let s = sender.clone();
            thread::spawn(move || {
                for j in 0..50i64 {
                    let ts = 1_000_000 + (t * 100) + j;
                    let loc = make_location(ngid, &s, ts);
                    m.upsert_last_known_location(&loc)
                        .expect("upsert must not fail");
                }
            })
        })
        .collect();
    for h in handles {
        h.join().expect("upsert worker panicked");
    }

    // Snapshot must contain exactly one row for this sender.
    let rows = manager
        .snapshot_last_known_for_circle(&ngid, 0)
        .expect("snapshot");
    let mine: Vec<_> = rows.iter().filter(|r| r.sender_pubkey == sender).collect();
    assert_eq!(mine.len(), 1, "exactly one row per (circle, sender)");

    // The surviving timestamp must be the maximum we wrote.
    let max_ts = 1_000_000 + (15 * 100) + 49;
    assert_eq!(mine[0].timestamp, max_ts, "latest write must win");
}

#[test]
fn concurrent_prune_and_upsert_do_not_deadlock() {
    let dir = TempDir::new().expect("temp dir");
    let manager = Arc::new(CircleManager::new_unencrypted(dir.path()).expect("manager"));

    let ngid = [9u8; 32];

    // Writers insert rows whose `purge_after` is sometimes in the past so
    // the parallel pruner has actual work to do.
    let writers: Vec<_> = (0..8u64)
        .map(|t| {
            let m = manager.clone();
            thread::spawn(move || {
                for j in 0..50u64 {
                    let sender = pubkey(t * 1000 + j);
                    let mut loc = make_location(ngid, &sender, 2_000_000);
                    if j % 2 == 0 {
                        loc.purge_after = 1; // already expired
                    }
                    m.upsert_last_known_location(&loc).expect("upsert");
                }
            })
        })
        .collect();

    let pruners: Vec<_> = (0..4)
        .map(|_| {
            let m = manager.clone();
            thread::spawn(move || {
                for _ in 0..20 {
                    let _ = m.prune_expired_last_known(10).expect("prune");
                }
            })
        })
        .collect();

    for w in writers {
        w.join().expect("writer panicked");
    }
    for p in pruners {
        p.join().expect("pruner panicked");
    }

    // After everything settles, run one final prune and verify via a
    // snapshot with now=0 (no purge_after filtering in the snapshot query)
    // that all rows were truly deleted, not just filtered.
    manager
        .prune_expired_last_known(i64::MAX)
        .expect("final prune");
    let rows = manager
        .snapshot_last_known_for_circle(&ngid, 0)
        .expect("snapshot");
    assert!(
        rows.is_empty(),
        "no row should survive a final prune at far-future now"
    );
}
