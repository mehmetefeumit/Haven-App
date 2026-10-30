//! Security Rule 15: `SQLCipher`'s native logger and its statement tracer are
//! compiled out (`-DSQLCIPHER_OMIT_LOG`, `-DSQLITE_OMIT_TRACE` in the root
//! `.cargo/config.toml`), never merely filtered. On a device the logger writes
//! to logcat (tag `sqlcipher`) or `os_log`, beneath every Haven log filter, and
//! its lines carry page numbers, error codes and, on the rekey path, database
//! filenames; the tracer writes every statement's SQL.
//!
//! `session.sqlite`, `circles.db` and `tiles.db` share the one bundled
//! `SQLCipher` (`libsqlite3-sys` is `links = "sqlite3"`, so a graph can hold
//! only one), so a connection in this binary proves the build all three use.

use std::process::Command;

use rusqlite::Connection;

const KEY: &str =
    "PRAGMA key = \"x'000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f'\"";
const WRONG_KEY: &str =
    "PRAGMA key = \"x'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff'\"";

fn pragma(conn: &Connection, sql: &str) -> String {
    conn.query_row(sql, [], |row| row.get(0))
        .expect("the pragma returns one row")
}

/// `sqlcipher_set_log` returns `SQLITE_ERROR` (1) only when the logger is
/// compiled out; with the logger present, `stderr` is accepted (0).
#[test]
fn the_sqlcipher_logger_cannot_be_switched_on() {
    haven_core::sqlcipher_init::ensure().expect("SQLite initialises");
    let conn = Connection::open_in_memory().expect("open");
    conn.execute_batch(KEY).expect("key");
    assert_eq!(
        pragma(&conn, "PRAGMA cipher_log = 'stderr'"),
        "1",
        "SQLCipher accepted a log target: the logger is compiled in"
    );
}

/// `sqlcipher_cipher_profile` returns `SQLITE_ERROR` (1) only when `SQLite`'s
/// tracing is compiled out (`-DSQLITE_OMIT_TRACE`); with it present, `stderr`
/// is accepted (0) and every later statement's SQL is written there — or, with
/// `device`, to logcat / `os_log`.
#[test]
fn the_sqlcipher_statement_tracer_cannot_be_switched_on() {
    haven_core::sqlcipher_init::ensure().expect("SQLite initialises");
    let conn = Connection::open_in_memory().expect("open");
    conn.execute_batch(KEY).expect("key");
    for target in ["stderr", "device"] {
        assert_eq!(
            pragma(&conn, &format!("PRAGMA cipher_profile = '{target}'")),
            "1",
            "SQLCipher accepted a profile target: its tracer is compiled in"
        );
    }
}

/// The child asks for `SQLCipher`'s most verbose useful logging on stderr, then
/// drives the HMAC-failure path (a wrong key), which logs at ERROR in every
/// `SQLCipher` this repository has shipped. Nothing may reach stderr.
#[test]
fn a_wrong_key_open_writes_nothing_to_stderr_even_when_logging_is_requested() {
    const MARKER: &str = "HAVEN_SQLCIPHER_STDERR_CHILD";
    const TEST_NAME: &str =
        "a_wrong_key_open_writes_nothing_to_stderr_even_when_logging_is_requested";

    if let Some(dir) = std::env::var_os(MARKER) {
        let path = std::path::Path::new(&dir).join("wrong-key.db");
        haven_core::sqlcipher_init::ensure().expect("SQLite initialises");
        let conn = Connection::open(&path).expect("open");
        conn.execute_batch(KEY).expect("key");
        conn.execute_batch("CREATE TABLE t(x); INSERT INTO t VALUES (1);")
            .expect("write a page");
        drop(conn);

        let conn = Connection::open(&path).expect("reopen");
        pragma(&conn, "PRAGMA cipher_log_level = 'DEBUG'");
        pragma(&conn, "PRAGMA cipher_log = 'stderr'");
        conn.execute_batch(WRONG_KEY).expect("set the wrong key");
        let read = conn.query_row("SELECT count(*) FROM sqlite_master", [], |row| {
            row.get::<_, i64>(0)
        });
        assert!(
            matches!(
                read,
                Err(rusqlite::Error::SqliteFailure(ref e, _))
                    if e.code == rusqlite::ErrorCode::NotADatabase
            ),
            "the wrong key must fail page 1's HMAC check, or this proves nothing: {read:?}"
        );
        return;
    }

    let dir = tempfile::tempdir().expect("tempdir");
    let output = Command::new(std::env::current_exe().expect("this test binary"))
        .args(["--exact", TEST_NAME, "--test-threads=1"])
        .env(MARKER, dir.path())
        .output()
        .expect("spawn the child");
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        output.status.success() && stdout.contains("1 passed"),
        "the child did not run the wrong-key open to completion: {stdout}"
    );
    assert!(
        output.stderr.is_empty(),
        "SQLCipher wrote to stderr: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

/// Every `.rs` file under `dir`, recursively.
fn rust_sources(dir: &std::path::Path, out: &mut Vec<std::path::PathBuf>) {
    for entry in std::fs::read_dir(dir).expect("read a source dir") {
        let path = entry.expect("dir entry").path();
        if path.is_dir() {
            rust_sources(&path, out);
        } else if path.extension().is_some_and(|ext| ext == "rs") {
            out.push(path);
        }
    }
}

/// The tracer is compiled out (above), and nothing asks for it either: a build
/// that lost `-DSQLITE_OMIT_TRACE` would otherwise write every statement's SQL
/// to logcat / `os_log`, stdout, stderr or a file the moment one source issued
/// `PRAGMA cipher_profile`. No Haven or MDK source may name it.
#[test]
fn no_haven_or_mdk_source_issues_cipher_profile() {
    let manifest_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
    let metadata = Command::new(env!("CARGO"))
        .args(["metadata", "--format-version", "1", "--offline"])
        .current_dir(manifest_dir)
        .output()
        .expect("run cargo metadata");
    assert!(metadata.status.success(), "cargo metadata failed");
    let metadata: serde_json::Value =
        serde_json::from_slice(&metadata.stdout).expect("cargo metadata JSON");

    let mut mdk_roots: Vec<std::path::PathBuf> = metadata["packages"]
        .as_array()
        .expect("packages")
        .iter()
        .filter(|package| {
            package["source"]
                .as_str()
                .is_some_and(|source| source.contains("github.com/marmot-protocol/mdk"))
        })
        .map(|package| {
            std::path::Path::new(package["manifest_path"].as_str().expect("manifest path"))
                .with_file_name("src")
        })
        .collect();
    mdk_roots.sort();
    mdk_roots.dedup();
    let haven_roots = [
        manifest_dir.join("src"),
        manifest_dir.join("../haven/rust_builder/src"),
    ];

    let mut mdk_sources = Vec::new();
    for root in &mdk_roots {
        rust_sources(root, &mut mdk_sources);
    }
    let mut haven_sources = Vec::new();
    for root in &haven_roots {
        rust_sources(root, &mut haven_sources);
    }
    let read = |path: &std::path::PathBuf| std::fs::read_to_string(path).expect("read a source");
    assert!(
        mdk_sources
            .iter()
            .any(|path| read(path).contains("cipher_compatibility")),
        "the scan never reached MDK's SQLCipher setup, so it proves nothing"
    );

    let issuing: Vec<_> = mdk_sources
        .iter()
        .chain(&haven_sources)
        .filter(|path| read(path).to_ascii_lowercase().contains("cipher_profile"))
        .collect();
    assert!(
        issuing.is_empty(),
        "these sources name cipher_profile: {issuing:?}"
    );
}
