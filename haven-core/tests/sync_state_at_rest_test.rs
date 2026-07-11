//! At-rest verification for the six sync/relay-state tables (M10, N4).
//!
//! Proves that the rows the WN relay+epoch-sync migration adds to `circles.db`
//! are SQLCipher-encrypted at rest. Each of the six tables is seeded with a
//! long, high-entropy ASCII sentinel in a TEXT column and/or a distinctive
//! ≥16-byte BLOB needle. Every value is first round-tripped back THROUGH the
//! cipher (proving the row actually landed), then the raw `circles.db` file and
//! all its sidecars (`-wal`/`-shm`/`-journal`) are byte-scanned to confirm no
//! sentinel/needle appears in plaintext. The scan runs both before and after
//! the handle is dropped, so WAL-resident pages are covered either way.
//!
//! Modeled on `avatar_at_rest_test.rs`. Runs entirely on the host under
//! `cargo test` (rust-check.yml) — no device/`adb`, no workflow edit.

use std::io::Read;
use std::path::PathBuf;

use haven_core::circle::{
    Circle, CircleStorage, CircleType, LastKnownLocation, PublishedKeyPackageRow,
};
use haven_core::nostr::mls::types::GroupId;
use nostr::{EventId, Keys};

/// Long, high-entropy ASCII sentinel written into a TEXT column. Unlikely to
/// appear verbatim in an encrypted (high-entropy) page by chance.
const SENTINEL_CURSOR_STREAM: &str = "M10_AT_REST_SYNC_CURSOR_STREAM_SENTINEL_DO_NOT_LEAK_XY";
const SENTINEL_PUB_EVENT_DTAG: &str = "M10_AT_REST_PUBLISHED_EVENT_DTAG_SENTINEL_DO_NOT_LEAK_XY";
const SENTINEL_PKP_EVENT_ID: &str = "M10_AT_REST_PUBLISHED_KEY_PACKAGE_EVENT_ID_SENTINEL_XY";
const SENTINEL_PKP_DTAG: &str = "M10_AT_REST_PUBLISHED_KEY_PACKAGE_DTAG_SENTINEL_DO_NOT_LEAK";
const SENTINEL_STAGED_HEX: &str = "M10_AT_REST_STAGED_COMMIT_NGID_HEX_SENTINEL_DO_NOT_LEAK_XY";
const SENTINEL_LKL_SENDER: &str = "M10_AT_REST_LAST_KNOWN_LOCATION_SENDER_SENTINEL_DO_NOT_LEAK";

/// Distinctive ≥16-byte BLOB needles written into BLOB columns.
const NEEDLE_WRAPPER_ID: [u8; 32] = *b"M10_AT_REST_GIFTWRAP_WRAP_ID_XYZ";
const NEEDLE_PUB_EVENT_ID: [u8; 32] = *b"M10_AT_REST_PUBLISHED_EVENT_IDXY";
const NEEDLE_PKP_HASH_REF: &[u8] = b"M10_AT_REST_KEY_PACKAGE_HASH_REF_NEEDLE_16B+";

fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    !needle.is_empty()
        && needle.len() <= haystack.len()
        && haystack.windows(needle.len()).any(|w| w == needle)
}

/// Scans `circles.db` and every sidecar for any of the sentinels/needles.
fn assert_no_plaintext_at_rest(db_path: &std::path::Path, phase: &str) {
    let text_sentinels: &[&str] = &[
        SENTINEL_CURSOR_STREAM,
        SENTINEL_PUB_EVENT_DTAG,
        SENTINEL_PKP_EVENT_ID,
        SENTINEL_PKP_DTAG,
        SENTINEL_STAGED_HEX,
        SENTINEL_LKL_SENDER,
    ];
    let blob_needles: &[&[u8]] = &[
        &NEEDLE_WRAPPER_ID,
        &NEEDLE_PUB_EVENT_ID,
        NEEDLE_PKP_HASH_REF,
    ];

    let mut scanned_any = false;
    for ext in ["", "-wal", "-shm", "-journal"] {
        let p = if ext.is_empty() {
            db_path.to_path_buf()
        } else {
            PathBuf::from(format!("{}{ext}", db_path.display()))
        };
        if !p.exists() {
            continue;
        }
        scanned_any = true;
        let mut bytes = Vec::new();
        std::fs::File::open(&p)
            .expect("open db/sidecar")
            .read_to_end(&mut bytes)
            .expect("read db/sidecar");

        for s in text_sentinels {
            assert!(
                !contains(&bytes, s.as_bytes()),
                "TEXT sentinel '{s}' leaked at rest in '{ext}' ({phase})"
            );
        }
        for n in blob_needles {
            assert!(
                !contains(&bytes, n),
                "BLOB needle leaked at rest in '{ext}' ({phase})"
            );
        }
    }
    assert!(scanned_any, "no db files were scanned ({phase})");
}

/// Writes one row into each of the six tables (with the module's sentinels /
/// needles) and reads each back THROUGH the cipher, proving the row landed.
fn seed_and_verify_roundtrip(storage: &CircleStorage, now: i64) {
    // --- 1. sync_cursors (stream TEXT sentinel) ---
    storage
        .update_sync_cursor_max(SENTINEL_CURSOR_STREAM, 1_700_000_000_000)
        .expect("write sync cursor");
    assert_eq!(
        storage
            .read_sync_cursor(SENTINEL_CURSOR_STREAM)
            .expect("read cursor"),
        Some(1_700_000_000_000),
        "sync cursor must round-trip through the cipher"
    );

    // --- 2. processed_gift_wraps (wrapper_event_id BLOB needle) ---
    let wrapper_id = EventId::from_byte_array(NEEDLE_WRAPPER_ID);
    storage
        .record_gift_wrap_failure(&wrapper_id, now)
        .expect("write processed_gift_wraps");
    assert!(
        storage
            .is_gift_wrap_processed(&wrapper_id)
            .expect("read processed")
            .is_some(),
        "processed_gift_wrap must round-trip through the cipher"
    );

    // --- 3. published_events (d_tag TEXT sentinel + event_id BLOB needle) ---
    let event_id = EventId::from_byte_array(NEEDLE_PUB_EVENT_ID);
    let pubkey = Keys::generate().public_key();
    storage
        .record_published_event(30051, SENTINEL_PUB_EVENT_DTAG, &event_id, &pubkey, now)
        .expect("write published_events");
    let rec = storage
        .last_published_event(30051, SENTINEL_PUB_EVENT_DTAG, &pubkey)
        .expect("read published_event")
        .expect("published_event row must exist");
    assert_eq!(
        rec.event_id, event_id,
        "published_event must round-trip through the cipher"
    );
    assert_eq!(rec.d_tag, SENTINEL_PUB_EVENT_DTAG);

    // --- 4. published_key_packages (event_id hex TEXT + d_tag TEXT + hash_ref BLOB) ---
    let pkp = PublishedKeyPackageRow {
        key_package_hash_ref: NEEDLE_PKP_HASH_REF.to_vec(),
        event_id: SENTINEL_PKP_EVENT_ID.to_string(),
        kind: 30443,
        d_tag: Some(SENTINEL_PKP_DTAG.to_string()),
        created_at: now,
    };
    storage
        .record_published_key_package(&pkp)
        .expect("write published_key_packages");
    assert_eq!(
        storage.latest_canonical_d_tag().expect("read latest d_tag"),
        Some(SENTINEL_PKP_DTAG.to_string()),
        "published_key_package d_tag must round-trip through the cipher"
    );

    // --- 5. staged_commits (nostr_group_id_hex TEXT sentinel) ---
    storage
        .set_staged_commit(SENTINEL_STAGED_HEX, 3, now)
        .expect("write staged_commits");
    assert!(
        storage
            .has_staged_commit(SENTINEL_STAGED_HEX)
            .expect("read staged"),
        "staged_commit must round-trip through the cipher"
    );

    // --- 6. last_known_locations (sender_pubkey TEXT sentinel) ---
    let loc = LastKnownLocation {
        nostr_group_id: [0x5A; 32],
        sender_pubkey: SENTINEL_LKL_SENDER.to_string(),
        latitude: 48.0,
        longitude: 11.0,
        geohash: "u4pruyd".to_string(),
        display_name: None,
        timestamp: now,
        expires_at: now + 900,
        purge_after: now + 86_400,
        updated_at: now,
    };
    storage
        .upsert_last_known_location(&loc)
        .expect("write last_known_locations");
    let snap = storage
        .snapshot_last_known_for_circle(&[0x5A; 32], now)
        .expect("read last_known");
    assert!(
        snap.iter().any(|l| l.sender_pubkey == SENTINEL_LKL_SENDER),
        "last_known_location must round-trip through the cipher"
    );

    // A circle row so the schema is not trivially empty (defense in depth).
    let circle = Circle {
        mls_group_id: GroupId::from_slice(&[0x5A; 32]),
        nostr_group_id: [0x5A; 32],
        display_name: "at-rest circle".to_string(),
        circle_type: CircleType::LocationSharing,
        relays: vec!["wss://relay.test".to_string()],
        created_at: now,
        updated_at: now,
    };
    storage.save_circle(&circle).expect("save circle");
}

#[test]
fn sync_and_relay_state_tables_are_encrypted_at_rest() {
    let dir = tempfile::tempdir().expect("tempdir");
    let db_path = dir.path().join("circles.db");
    // 64 hex chars (a raw 256-bit key), as the FFI layer supplies in production.
    let hex_key = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

    let now = 1_700_000_000_i64;

    {
        let storage = CircleStorage::new(&db_path, Some(hex_key)).expect("open encrypted db");
        seed_and_verify_roundtrip(&storage, now);

        // Scan WHILE the handle is still open (WAL pages may be uncheckpointed).
        assert_no_plaintext_at_rest(&db_path, "pre-drop");

        // Drop closes the connection and flushes any journal/WAL to disk.
    }

    // The main DB file must exist and be non-trivial.
    let main = std::fs::read(&db_path).expect("read db");
    assert!(main.len() > 1024, "db file unexpectedly small");

    // Scan again after the handle is dropped (checkpoint may have moved pages).
    assert_no_plaintext_at_rest(&db_path, "post-drop");
}

/// Deletes `circles.db` and every `SQLite` sidecar (`-wal`/`-shm`/`-journal`),
/// mirroring the FFI logout wipe's file-delete step (`delete_db_files` in
/// `rust_builder/src/api.rs`). Idempotent — an already-absent file is a no-op.
fn delete_db_and_sidecars(db_path: &std::path::Path) {
    for ext in ["", "-wal", "-shm", "-journal"] {
        let p = if ext.is_empty() {
            db_path.to_path_buf()
        } else {
            PathBuf::from(format!("{}{ext}", db_path.display()))
        };
        if p.exists() {
            std::fs::remove_file(&p).expect("delete db/sidecar");
        }
    }
}

/// R10 (MUST, N4): after the wipe-on-logout teardown NOTHING that was seeded
/// into the six sync/relay-state tables remains decryptable at rest.
///
/// Exercises BOTH halves of the real logout wipe against a REAL `SQLCipher`
/// `circles.db`:
///   1. the **storage/manager reset** — the bulk per-table wipes clear their
///      rows *through the cipher* (the four tables that expose a bulk primitive);
///   2. the **file-delete** — `circles.db` + every sidecar are unlinked
///      (mirrors `delete_db_files`).
///
/// Then it proves the two required post-conditions:
///   (i)  the `circles.db` path (and every sidecar) is gone from disk; and
///   (ii) re-opening at the same path with the RETAINED key recovers NONE of the
///        once-decryptable rows (a fresh, empty DB is minted) and no seeded
///        sentinel survives a byte-scan — i.e. nothing is decryptable at rest.
///
/// The complementary "the key itself is gone ⇒ any *surviving* ciphertext is
/// undecryptable" property is covered by `storage::tests::encrypted_db_wrong_key_cannot_read`
/// (a different key cannot open the DB) and the FFI-level M10 `wipe_all_mls_state`
/// end-to-end tests (which additionally remove the real keyring keys).
#[test]
fn wiped_sync_state_leaves_nothing_decryptable_at_rest() {
    let dir = tempfile::tempdir().expect("tempdir");
    let db_path = dir.path().join("circles.db");
    let hex_key = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    let now = 1_700_000_000_i64;

    let wrapper_id = EventId::from_byte_array(NEEDLE_WRAPPER_ID);

    // --- Seed all six tables (verified round-trip), then apply the storage reset. ---
    {
        let storage = CircleStorage::new(&db_path, Some(hex_key)).expect("open encrypted db");
        seed_and_verify_roundtrip(&storage, now);

        // (1) STORAGE/MANAGER RESET half: the bulk per-table wipes clear their
        // rows through the cipher. (published_events / published_key_packages have
        // no bulk primitive; the file delete below erases them.)
        storage.reset_all_sync_cursors().expect("reset cursors");
        storage.wipe_all_staged_commits().expect("wipe staged");
        storage
            .wipe_all_processed_gift_wraps()
            .expect("wipe processed");
        storage
            .wipe_all_last_known_locations()
            .expect("wipe locations");

        // The reset tables read empty through the cipher.
        assert_eq!(
            storage.read_sync_cursor(SENTINEL_CURSOR_STREAM).unwrap(),
            None
        );
        assert!(!storage.has_staged_commit(SENTINEL_STAGED_HEX).unwrap());
        assert!(storage
            .is_gift_wrap_processed(&wrapper_id)
            .unwrap()
            .is_none());
        assert!(storage
            .snapshot_last_known_for_circle(&[0x5A; 32], now)
            .unwrap()
            .is_empty());
        // Drop → close the connection (flush WAL/journal to disk).
    }

    // A reset alone does NOT delete the file — that is the file-delete's job.
    assert!(db_path.exists(), "the reset must not delete the db file");

    // --- (2) FILE-DELETE half of the logout wipe. ---
    delete_db_and_sidecars(&db_path);

    // (i) The circles.db path AND every sidecar are gone from disk.
    assert!(!db_path.exists(), "circles.db must be deleted by the wipe");
    for ext in ["-wal", "-shm", "-journal"] {
        let p = PathBuf::from(format!("{}{ext}", db_path.display()));
        assert!(!p.exists(), "sidecar '{ext}' must be deleted by the wipe");
    }

    // (ii) Re-open at the SAME path with the RETAINED key. The delete left a clean
    // slate, so a fresh (empty) DB is minted and NONE of the previously seeded,
    // once-decryptable rows survive — spanning ALL six tables.
    let reopened =
        CircleStorage::new(&db_path, Some(hex_key)).expect("re-open mints a fresh empty db");
    assert_eq!(
        reopened.read_sync_cursor(SENTINEL_CURSOR_STREAM).unwrap(),
        None,
        "sync_cursors must not survive the wipe"
    );
    assert!(
        !reopened.has_staged_commit(SENTINEL_STAGED_HEX).unwrap(),
        "staged_commits must not survive the wipe"
    );
    assert!(
        reopened
            .is_gift_wrap_processed(&wrapper_id)
            .unwrap()
            .is_none(),
        "processed_gift_wraps must not survive the wipe"
    );
    assert!(
        reopened
            .snapshot_last_known_for_circle(&[0x5A; 32], now)
            .unwrap()
            .is_empty(),
        "last_known_locations must not survive the wipe"
    );
    assert_eq!(
        reopened.latest_canonical_d_tag().unwrap(),
        None,
        "published_key_packages must not survive the wipe"
    );

    // Byte-scan the freshly-minted file (defense-in-depth): the AUTHORITATIVE
    // erasure is the file-delete above (the old ciphertext pages are unlinked) —
    // this re-open mints an EMPTY db, so a clean scan here confirms the reset +
    // re-open leaked nothing, not that old pages were scrubbed in place.
    // published_events' TEXT sentinel (which has no bulk primitive) is covered here.
    assert_no_plaintext_at_rest(&db_path, "post-wipe-reopen");
    drop(reopened);
    assert_no_plaintext_at_rest(&db_path, "post-wipe-drop");
}
