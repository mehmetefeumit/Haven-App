//! Every store open passes the first-use gate before it reaches `SQLite`.
//!
//! `SQLCipher` finishes its own start-up after `sqlite3_initialize` has already
//! told every other thread the library is ready, and until it has, `PRAGMA key`
//! fails (`haven_core::sqlcipher_init`; `docs/MDK_UPSTREAM_TRACKER.md` row
//! T-SQLCIPHER-FIRST-USE). The UI isolate and a background isolate share one
//! loaded library, so the tile cache opening in one can meet the circle manager
//! opening in the other.
//!
//! Two tests, and what each one holds:
//!
//! * `every_opener_passes_the_gate_before_it_opens` runs each opener in a
//!   process of its own, where nothing else has touched `SQLite`: the gate has
//!   not run before the open and has run after it. It fails, every time, for an
//!   opener that lost its gate call. For the three stores it also drives an open
//!   that fails AT `SQLite` and still finds the gate run, so the call comes
//!   first. It does not see `CircleStorage::migrate_to_encrypted`'s own call
//!   (private, and always behind `CircleStorage::new`'s), nor an opener nobody
//!   added to the table below — `scripts/ci/check_sqlcipher_first_use_gate.sh`
//!   holds both by their source text.
//! * `every_store_opened_as_the_process_starts_opens` opens sixteen stores at
//!   once as this process's first contact with `SQLite`: they all open, and none
//!   deadlocks on the gate. It never touches `SQLite` in any other test of this
//!   binary's process, which is why the first test only spawns.
//!
//! Neither reproduces the race. It is lost only when the initialising thread is
//! held up at one point between `SQLite` announcing itself and `SQLCipher`'s
//! start-up taking its mutex, which no safe code can arrange; that the gate
//! makes a second caller wait is `sqlcipher_init::tests`.
use std::path::Path;
use std::process::Command;
use std::sync::mpsc::{self, RecvTimeoutError};
use std::sync::{Arc, Barrier};
use std::time::{Duration, Instant};

use haven_core::circle::{CircleManager, CircleStorage, CIRCLES_DB_FILENAME};
use haven_core::nostr::mls::storage::openmls_group_keys_for_test;
use haven_core::nostr::mls::{SessionManager, StorageConfig};
use haven_core::sqlcipher_init;
use haven_core::tiles::TileCacheStorage;
use nostr::Keys;

const RAW_KEY: &str = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";
/// More openers than any shipped process has isolates.
const OPENERS: usize = 16;
/// Never waited out by a working gate: only a deadlock or a hung open reaches
/// it, and then the test fails instead of hanging the binary.
const BOUND: Duration = Duration::from_mins(2);

const PER_OPENER_TEST: &str = "every_opener_passes_the_gate_before_it_opens";
const OPENER: &str = "HAVEN_FIRST_USE_OPENER";
const DIR: &str = "HAVEN_FIRST_USE_DIR";

/// One way into `SQLite`, run as a child process's first contact with it.
struct Opener {
    name: &'static str,
    /// An opener run to completion first, in a process of its own over the same
    /// directory, when this one opens a store that must already exist.
    laid_down_by: Option<&'static str>,
    /// Whether the open succeeded.
    open: fn(&Path) -> bool,
    /// `false` for an open that must fail at `SQLite` — after the gate.
    opens: bool,
}

/// Every function in `haven-core/src` that opens `SQLite` and is reachable from
/// outside the crate: the production openers first, then the `test-utils` ones.
const EVERY_OPENER: &[Opener] = &[
    // `SessionManager::open_session`: the second handle, then the session.
    Opener {
        name: "the session, under its keyring key",
        laid_down_by: None,
        open: |dir| SessionManager::new(dir, &Keys::generate()).is_ok(),
        opens: true,
    },
    Opener {
        name: "the session, under the test key",
        laid_down_by: None,
        open: |dir| SessionManager::new_unencrypted(dir, &Keys::generate()).is_ok(),
        opens: true,
    },
    // The app's one entry point: the session, then the circle store.
    Opener {
        name: "the circle manager",
        laid_down_by: None,
        open: |dir| CircleManager::new(dir, &Keys::generate(), Some(RAW_KEY)).is_ok(),
        opens: true,
    },
    Opener {
        name: "the circle store, no key",
        laid_down_by: None,
        open: |dir| CircleStorage::new(&dir.join(CIRCLES_DB_FILENAME), None).is_ok(),
        opens: true,
    },
    Opener {
        name: "the circle store, keyed",
        laid_down_by: None,
        open: |dir| CircleStorage::new(&dir.join(CIRCLES_DB_FILENAME), Some(RAW_KEY)).is_ok(),
        opens: true,
    },
    // `migrate_to_encrypted`: afterwards the file no longer opens without a key.
    Opener {
        name: "the circle store, migrating an unencrypted file",
        laid_down_by: Some("the circle store, no key"),
        open: |dir| {
            let path = dir.join(CIRCLES_DB_FILENAME);
            CircleStorage::new(&path, Some(RAW_KEY)).is_ok()
                && CircleStorage::new(&path, None).is_err()
        },
        opens: true,
    },
    Opener {
        name: "the tile cache",
        laid_down_by: None,
        open: |dir| TileCacheStorage::open(&dir.join("tiles.db"), RAW_KEY).is_ok(),
        opens: true,
    },
    // The same three stores over a path `SQLite` cannot open (a directory): the
    // open fails there, and the gate has still run — so it runs first.
    Opener {
        name: "the session, over a path it cannot open",
        laid_down_by: None,
        open: |dir| {
            std::fs::create_dir_all(StorageConfig::new(dir).database_path())
                .expect("a directory where the database belongs");
            SessionManager::new_unencrypted(dir, &Keys::generate()).is_ok()
        },
        opens: false,
    },
    Opener {
        name: "the circle store, over a path it cannot open",
        laid_down_by: None,
        open: |dir| CircleStorage::new(dir, Some(RAW_KEY)).is_ok(),
        opens: false,
    },
    Opener {
        name: "the tile cache, over a path it cannot open",
        laid_down_by: None,
        open: |dir| TileCacheStorage::open(dir, RAW_KEY).is_ok(),
        opens: false,
    },
    // `test-utils` only: what the soak rig and these tests open with.
    Opener {
        name: "the MLS store, under its keyring key (test-utils)",
        laid_down_by: None,
        open: |dir| StorageConfig::new(dir).open_encrypted_storage().is_ok(),
        opens: true,
    },
    Opener {
        name: "the in-memory MLS store (test-utils)",
        laid_down_by: None,
        open: |_| StorageConfig::in_memory_storage().is_ok(),
        opens: true,
    },
    // `open_tamper_connection`, which every `*_for_test` reader and fault shares.
    Opener {
        name: "a raw read of the MLS store (test-utils)",
        laid_down_by: Some("the session, under the test key"),
        open: |dir| {
            let key = StorageConfig::test_sqlcipher_key().expect("the test key");
            openmls_group_keys_for_test(&StorageConfig::new(dir).database_path(), &key).is_ok()
        },
        opens: true,
    },
];

#[test]
fn every_opener_passes_the_gate_before_it_opens() {
    if let (Some(name), Some(dir)) = (std::env::var_os(OPENER), std::env::var_os(DIR)) {
        open_as_this_process_first_contact(&name.to_string_lossy(), Path::new(&dir));
        return;
    }

    for opener in EVERY_OPENER {
        let dir = tempfile::TempDir::new().expect("temp dir");
        if let Some(first) = opener.laid_down_by {
            in_a_process_of_its_own(first, dir.path());
        }
        in_a_process_of_its_own(opener.name, dir.path());
    }
}

/// Re-runs this test as a child that opens `name` and nothing else.
fn in_a_process_of_its_own(name: &str, dir: &Path) {
    let output = Command::new(std::env::current_exe().expect("this test binary"))
        .args(["--exact", PER_OPENER_TEST, "--test-threads=1"])
        .env(OPENER, name)
        .env(DIR, dir)
        .output()
        .expect("spawn the child");
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        output.status.success() && stdout.contains("1 passed"),
        "{name}, in a process of its own: {stdout}"
    );
}

/// The child: `name`'s open is the first thing in this process to reach `SQLite`.
fn open_as_this_process_first_contact(name: &str, dir: &Path) {
    let opener = EVERY_OPENER
        .iter()
        .find(|opener| opener.name == name)
        .expect("an opener this test knows");
    // A mock: installing it opens nothing.
    keyring_core::set_default_store(
        keyring_core::mock::Store::new().expect("mock store creation never fails"),
    );
    assert!(
        !sqlcipher_init::ran(),
        "premise: nothing in this process has passed the gate yet"
    );

    let dir = dir.to_path_buf();
    let open = opener.open;
    let (done, answer) = mpsc::channel();
    std::thread::spawn(move || {
        let _ = done.send(open(&dir));
    });
    let succeeded = match answer.recv_timeout(BOUND) {
        Ok(succeeded) => succeeded,
        Err(RecvTimeoutError::Timeout) => panic!("{name}: the open did not return"),
        Err(RecvTimeoutError::Disconnected) => panic!("{name}: the open panicked"),
    };

    assert!(
        sqlcipher_init::ran(),
        "{name} reached SQLite without passing the first-use gate first"
    );
    assert!(
        succeeded == opener.opens,
        "{name}: the open was meant to {}",
        if opener.opens { "succeed" } else { "fail" }
    );
}

#[test]
fn every_store_opened_as_the_process_starts_opens() {
    let root = tempfile::TempDir::new().expect("temp dir");
    let start = Arc::new(Barrier::new(OPENERS));
    let (done, results) = mpsc::channel();
    for n in 0..OPENERS {
        let start = Arc::clone(&start);
        let done = done.clone();
        let dir = root.path().join(n.to_string());
        std::thread::spawn(move || {
            std::fs::create_dir(&dir).expect("the opener's own directory");
            let keys = Keys::generate();
            start.wait();
            let _ = done.send(open_one(n, &dir, &keys));
        });
    }
    drop(done);

    let deadline = Instant::now() + BOUND;
    let mut failed: Vec<&str> = Vec::new();
    for _ in 0..OPENERS {
        match results.recv_timeout(deadline.saturating_duration_since(Instant::now())) {
            Ok(Ok(())) => {}
            Ok(Err(store)) => failed.push(store),
            Err(RecvTimeoutError::Timeout) => {
                panic!("an open did not return: the gate deadlocked or the open hung")
            }
            Err(RecvTimeoutError::Disconnected) => panic!("an opener panicked"),
        }
    }
    assert!(
        failed.is_empty(),
        "failed to open at process start: {failed:?}"
    );
}

/// A session, and the tile cache and the circle store in turn — the two a
/// shipped process can open on two isolates at once.
fn open_one(n: usize, dir: &Path, keys: &Keys) -> Result<(), &'static str> {
    match n {
        0 => SessionManager::new_unencrypted(dir, keys)
            .map(drop)
            .map_err(|_| "the session"),
        n if n % 2 == 0 => TileCacheStorage::open(&dir.join("tiles.db"), RAW_KEY)
            .map(drop)
            .map_err(|_| "the tile cache"),
        _ => CircleStorage::new(&dir.join(CIRCLES_DB_FILENAME), Some(RAW_KEY))
            .map(drop)
            .map_err(|_| "the circle store"),
    }
}
