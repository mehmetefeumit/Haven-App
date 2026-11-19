//! A store comes back from MDK's fixture recipe unchanged: `sqlcipher_export`
//! to a plain copy, `sqlite3 .dump`, and the dump replayed into a new keyed
//! file before anything opens it (`docs/mdk-v0.16/stage0.md` S0.2a.2).
//!
//! The previous-release fixtures are committed as that SQL text, so this is
//! the proof that what a fixture check opens is what the old build wrote:
//! the schema text, every row under the rowid it had, the `AUTOINCREMENT`
//! counters and the file's own settings. Both keyings are crossed — the test key every rig device
//! uses, and the app's own (a keyring secret stretched by PBKDF2, an
//! encrypted circle store), which every real install has.
//!
//! Needs the `sqlite3` command-line shell, as the fixture writer does.
//!
//! Nothing here renders a row: rows hold keys and group ids, so every
//! comparison names a table at most.

mod helpers;

use std::collections::BTreeMap;
use std::path::Path;

use haven_core::circle::{CircleManager, CircleStorage, CIRCLES_DB_FILENAME};
use haven_core::nostr::mls::storage::{
    dump_store_sql_for_test, export_store_plain_for_test, fanout_writes_for_test,
    import_store_sql_for_test, is_session_live, session_db_path, session_sqlcipher_key_for_test,
    use_mock_keyring_with_session_secret_for_test,
};
use haven_core::nostr::mls::{SessionManager, StorageConfig};
use haven_core::relay::maintenance::build_kp_maintenance_events;
use helpers::setup_two_party_group;
use nostr::key::Keys;
use rusqlite::types::Value;
use tempfile::TempDir;

/// Synthetic, throwaway key material for the production-keyed account.
const SESSION_SECRET: [u8; 32] = [0x5a; 32];
const CIRCLES_KEY_HEX: &str = "c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1";

/// What a store holds, everything a fixture promises to keep.
#[derive(PartialEq)]
struct Snapshot {
    /// `(type, name, tbl_name, sql)`, sorted; the root page is where a table
    /// landed, not what it is.
    schema: Vec<[Option<String>; 4]>,
    /// Every table's rows: a rowid table's as `rowid, *` in rowid order, so
    /// a renumbering or a reorder differs; a `WITHOUT ROWID` table's sorted.
    tables: BTreeMap<String, Vec<Vec<Value>>>,
    /// Read as `SQLite` answers them: a keyed `SQLCipher` connection answers
    /// `page_size` as text.
    auto_vacuum: Value,
    page_size: Value,
    journal_mode: Value,
    /// Both 0 at v0.10.4 and dropped by the `sqlite3` dump: equal, so a
    /// fixture and a real install agree.
    user_version: Value,
    application_id: Value,
}

/// A connection to `db`, keyed with `key` (the value `PRAGMA key` takes), or
/// plain.
fn open(db: &Path, key: Option<&str>) -> rusqlite::Connection {
    haven_core::sqlcipher_init::ensure().expect("SQLite initialises");
    let conn = rusqlite::Connection::open(db).expect("the store opens");
    if let Some(key) = key {
        conn.pragma_update(None, "cipher_compatibility", 4i64)
            .expect("cipher compatibility");
        conn.pragma_update(None, "key", key).expect("the key");
    }
    conn
}

fn snapshot(db: &Path, key: Option<&str>) -> Snapshot {
    let conn = open(db, key);
    let mut schema: Vec<[Option<String>; 4]> = conn
        .prepare("SELECT type, name, tbl_name, sql FROM sqlite_master")
        .and_then(|mut statement| {
            statement
                .query_map([], |row| {
                    Ok([row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?])
                })?
                .collect()
        })
        .expect("the schema reads");
    schema.sort();
    let mut tables = BTreeMap::new();
    for [kind, name, _, sql] in &schema {
        let (Some("table"), Some(name)) = (kind.as_deref(), name) else {
            continue;
        };
        // `sqlite_sequence` is SQLite's own: its rowid is only where a counter
        // row landed when the copy was written, and nothing reads by it.
        let rowid = name != "sqlite_sequence"
            && !sql
                .as_deref()
                .is_some_and(|sql| sql.to_uppercase().contains("WITHOUT ROWID"));
        let select = if rowid {
            format!("SELECT rowid, * FROM \"{name}\" ORDER BY rowid")
        } else {
            format!("SELECT * FROM \"{name}\"")
        };
        let mut statement = conn.prepare(&select).expect("a table reads");
        let width = statement.column_count();
        let mut rows: Vec<Vec<Value>> = statement
            .query_map([], |row| (0..width).map(|index| row.get(index)).collect())
            .and_then(Iterator::collect)
            .expect("a table's rows read");
        if !rowid {
            // Sorted in memory by a rendering that never leaves this function.
            rows.sort_by_cached_key(|row| format!("{row:?}"));
        }
        tables.insert(name.clone(), rows);
    }
    let pragma = |name: &str| -> Value {
        conn.query_row(&format!("PRAGMA {name}"), [], |row| row.get(0))
            .expect("a pragma reads")
    };
    Snapshot {
        schema,
        auto_vacuum: pragma("auto_vacuum"),
        page_size: pragma("page_size"),
        journal_mode: pragma("journal_mode"),
        user_version: pragma("user_version"),
        application_id: pragma("application_id"),
        tables,
    }
}

/// Names the first part of two snapshots that differs, and nothing in it.
fn assert_same(original: &Snapshot, imported: &Snapshot, store: &str) {
    assert!(
        original.schema == imported.schema,
        "{store}: sqlite_master differs"
    );
    for (name, rows) in &original.tables {
        assert!(
            imported.tables.get(name) == Some(rows),
            "{store}: table {name} differs"
        );
    }
    assert!(
        original.tables.len() == imported.tables.len(),
        "{store}: the table sets differ"
    );
    assert_eq!(original.auto_vacuum, imported.auto_vacuum, "{store}");
    assert_eq!(original.page_size, imported.page_size, "{store}");
    assert_eq!(original.journal_mode, imported.journal_mode, "{store}");
    assert_eq!(original.user_version, imported.user_version, "{store}");
    assert_eq!(original.application_id, imported.application_id, "{store}");
    assert!(original == imported, "{store}: the snapshots differ");
}

fn sequence_rows(snapshot: &Snapshot) -> usize {
    snapshot.tables.get("sqlite_sequence").map_or(0, Vec::len)
}

fn assert_released(db: &Path) {
    assert!(
        !is_session_live(db).expect("liveness reads"),
        "the session went with its manager"
    );
}

/// What the product's open makes of the copy is what it makes of the
/// original: the copy is the store, not a lookalike.
async fn opens_alike(original_dir: &Path, imported_dir: &Path, keys: &Keys) {
    let original = SessionManager::new_unencrypted(original_dir, keys).expect("the original opens");
    let copy = SessionManager::new_unencrypted(imported_dir, keys).expect("the copy opens");
    assert!(
        original
            .fanout_shapes_for_test()
            .await
            .expect("shapes read")
            == copy.fanout_shapes_for_test().await.expect("shapes read"),
        "both opens leave the same fanout rows"
    );
    assert!(
        original
            .store_shape_counts_for_test()
            .await
            .expect("counts read")
            == copy
                .store_shape_counts_for_test()
                .await
                .expect("counts read"),
        "both opens leave the same states"
    );
    drop((original, copy));
    assert_released(&session_db_path(original_dir));
    assert_released(&session_db_path(imported_dir));
}

/// Neither half of the recipe writes over anything, and a store a fault seam
/// marked is refused rather than exported without the mark.
fn refusals_hold(original: &Path, imported: &Path, sql: &str, scratch: &Path) {
    let key = StorageConfig::test_sqlcipher_key().expect("the test key");
    assert!(
        import_store_sql_for_test(sql, imported, &key, &StorageConfig::test_storage_options())
            .is_err(),
        "a dump never replays over a store"
    );
    let again = scratch.join("again.sqlite");
    std::fs::write(&again, b"").expect("a file in the way");
    assert!(
        export_store_plain_for_test(original, &key, &again).is_err(),
        "an export never writes over a file"
    );
    std::fs::remove_file(&again).expect("the file is removed");
    fanout_writes_for_test(original, &key).expect("a fault seam leaves its table");
    assert!(
        export_store_plain_for_test(original, &key, &again).is_err(),
        "a store holding a test object is refused, not filtered"
    );
    assert!(!again.exists(), "a refused export writes nothing");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_test_keyed_store_comes_back_from_its_dump_unchanged() {
    let fx = setup_two_party_group("dump_round_trip").await;
    // A staged commit leaves a fanout row with a pending ref, beside the
    // group, its messages and the account's key material.
    let now_ms = u64::try_from(chrono::Utc::now().timestamp_millis()).expect("after 1970");
    fx.alice
        .update_relays_staging(&fx.group_id, vec!["wss://relay.two.test".into()], now_ms)
        .await
        .expect("a relay change stages");
    let shapes = fx
        .alice
        .fanout_shapes_for_test()
        .await
        .expect("shapes read");
    let counts = fx
        .alice
        .store_shape_counts_for_test()
        .await
        .expect("counts read");
    assert!(
        shapes
            .iter()
            .any(|shape| shape.carries == "group_evolution" && shape.mls == "pending"),
        "the store holds the staged commit's row"
    );
    assert_eq!(counts.epoch_states.get("pending_publish"), Some(&1));
    assert!(!counts.message_states.is_empty());
    assert!(
        serde_json::to_string(&shapes).is_ok() && serde_json::to_string(&counts).is_ok(),
        "a manifest can write the shapes and counts"
    );

    let helpers::TwoPartyGroup {
        alice,
        alice_keys,
        alice_dir: original_dir,
        bob,
        bob_dir,
        ..
    } = fx;
    drop((alice, bob));
    let original = session_db_path(&original_dir);
    assert_released(&original);

    let key = StorageConfig::test_sqlcipher_key().expect("the test key");
    let scratch = TempDir::new().expect("a temp dir");
    let sql = dump_store_sql_for_test(&original, &key, scratch.path()).expect("the store dumps");
    let imported_dir = scratch.path().join("imported");
    std::fs::create_dir(&imported_dir).expect("a directory for the copy");
    let imported = session_db_path(&imported_dir);
    import_store_sql_for_test(
        &sql,
        &imported,
        &key,
        &StorageConfig::test_storage_options(),
    )
    .expect("the dump replays");

    let before = snapshot(&original, Some(key.as_secret_str()));
    assert!(
        sequence_rows(&before) > 0,
        "the store has AUTOINCREMENT counters to keep"
    );
    assert_same(
        &before,
        &snapshot(&imported, Some(key.as_secret_str())),
        "session",
    );

    opens_alike(&original_dir, &imported_dir, &alice_keys).await;
    refusals_hold(&original, &imported, &sql, scratch.path());
    for dir in [original_dir, bob_dir] {
        helpers::cleanup_dir(&dir);
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_production_keyed_account_comes_back_from_its_dump_and_opens() {
    let scratch = TempDir::new().expect("a temp dir");
    let original_dir = scratch.path().join("original");
    let keys = Keys::generate();
    use_mock_keyring_with_session_secret_for_test(&SESSION_SECRET).expect("the keyring");
    let manager = CircleManager::new(&original_dir, &keys, Some(CIRCLES_KEY_HEX))
        .expect("the app's opener opens a new account");
    build_kp_maintenance_events(
        manager.session(),
        &keys,
        &["wss://relay.one.test".to_string()],
        None,
        None,
    )
    .await
    .expect("a key package is minted");
    let bundles = manager
        .session()
        .key_package_bundle_count_for_test()
        .await
        .expect("bundles count");
    assert!(bundles > 0);
    drop(manager);
    let original = session_db_path(&original_dir);
    assert_released(&original);

    let session_key = session_sqlcipher_key_for_test(&SESSION_SECRET).expect("the session key");
    let imported_dir = scratch.path().join("imported");
    std::fs::create_dir(&imported_dir).expect("a directory for the copy");
    let imported = session_db_path(&imported_dir);
    import_store_sql_for_test(
        &dump_store_sql_for_test(&original, &session_key, scratch.path())
            .expect("the session dumps"),
        &imported,
        &session_key,
        &StorageConfig::storage_options(),
    )
    .expect("the session dump replays");
    assert_same(
        &snapshot(&original, Some(session_key.as_secret_str())),
        &snapshot(&imported, Some(session_key.as_secret_str())),
        "session",
    );

    let circles_key = format!("x'{CIRCLES_KEY_HEX}'");
    let original_circles = original_dir.join(CIRCLES_DB_FILENAME);
    let imported_circles = imported_dir.join(CIRCLES_DB_FILENAME);
    let circles_sql =
        CircleStorage::dump_sql_for_test(&original_circles, Some(CIRCLES_KEY_HEX), scratch.path())
            .expect("the circle store dumps");
    CircleStorage::import_sql_for_test(&circles_sql, &imported_circles, Some(CIRCLES_KEY_HEX))
        .expect("the circle dump replays");
    let circles_before = snapshot(&original_circles, Some(&circles_key));
    assert!(
        circles_before.tables.values().any(|rows| !rows.is_empty()),
        "the circle store holds rows to keep"
    );
    assert_same(
        &circles_before,
        &snapshot(&imported_circles, Some(&circles_key)),
        "circles",
    );

    // Through the app's own opener, keyed from the same secret: the account
    // is there, its key material with it, and nothing was reset.
    use_mock_keyring_with_session_secret_for_test(&SESSION_SECRET).expect("the keyring");
    let reopened = CircleManager::new(&imported_dir, &keys, Some(CIRCLES_KEY_HEX))
        .expect("the copy opens through the app's opener");
    assert_eq!(
        reopened
            .session()
            .key_package_bundle_count_for_test()
            .await
            .expect("bundles count"),
        bundles,
        "the copy holds the key material the original did"
    );
}

/// A rowid table whose rows are keyed by something other than an `INTEGER
/// PRIMARY KEY`, holding at least three rows: one whose rowids a stock dump
/// would renumber once a row is gone.
fn implicit_rowid_table(conn: &rusqlite::Connection) -> String {
    conn.prepare(
        "SELECT name FROM sqlite_master m WHERE type = 'table'
           AND name NOT LIKE 'sqlite_%'
           AND upper(sql) NOT LIKE '%WITHOUT ROWID%'
           AND NOT EXISTS (SELECT 1 FROM pragma_table_info(m.name)
                           WHERE pk = 1 AND upper(type) = 'INTEGER'
                             AND (SELECT count(*) FROM pragma_table_info(m.name) WHERE pk > 0) = 1)
         ORDER BY name",
    )
    .and_then(|mut statement| {
        statement
            .query_map([], |row| row.get::<_, String>(0))?
            .collect::<rusqlite::Result<Vec<_>>>()
    })
    .expect("the schema reads")
    .into_iter()
    .find(|name| {
        conn.query_row(&format!("SELECT count(*) FROM \"{name}\""), [], |row| {
            row.get::<_, i64>(0)
        })
        .is_ok_and(|rows| rows >= 3)
    })
    .expect("the store has a table keyed by implicit rowids with rows to spare")
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_gap_in_implicit_rowids_comes_back_as_a_gap() {
    let fx = setup_two_party_group("dump_rowid_gap").await;
    let helpers::TwoPartyGroup {
        alice,
        alice_dir: original_dir,
        bob,
        bob_dir,
        ..
    } = fx;
    drop((alice, bob));
    let original = session_db_path(&original_dir);
    assert_released(&original);

    let key = StorageConfig::test_sqlcipher_key().expect("the test key");
    {
        // A deleted row leaves the gap an old build's store holds.
        let conn = open(&original, Some(key.as_secret_str()));
        let table = implicit_rowid_table(&conn);
        conn.execute(
            &format!(
                "DELETE FROM \"{table}\" WHERE rowid =
                   (SELECT rowid FROM \"{table}\" ORDER BY rowid LIMIT 1 OFFSET 1)"
            ),
            [],
        )
        .expect("a row is deleted");
        let gapped: bool = conn
            .query_row(
                &format!("SELECT max(rowid) > count(*) FROM \"{table}\""),
                [],
                |row| row.get(0),
            )
            .expect("the gap reads");
        assert!(gapped, "the table's rowids have a gap");
    }

    let scratch = TempDir::new().expect("a temp dir");
    let sql = dump_store_sql_for_test(&original, &key, scratch.path()).expect("the store dumps");
    let imported = scratch.path().join("imported.sqlite");
    import_store_sql_for_test(
        &sql,
        &imported,
        &key,
        &StorageConfig::test_storage_options(),
    )
    .expect("the dump replays");
    assert_same(
        &snapshot(&original, Some(key.as_secret_str())),
        &snapshot(&imported, Some(key.as_secret_str())),
        "session",
    );
    for dir in [original_dir, bob_dir] {
        helpers::cleanup_dir(&dir);
    }
}
