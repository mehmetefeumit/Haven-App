//! `SQLCipher` storage for the encrypted map-tile cache (`tiles.db`).
//!
//! This module backs Haven's encrypted on-disk map-tile cache. It mirrors the
//! `SQLCipher` open/key/pragma discipline of [`crate::circle::storage`] but
//! diverges in three deliberate, owner-approved ways documented inline:
//!
//! 1. **WAL is enabled** (unlike `circles.db`). Foreground tile reads during a
//!    prefetch write-burst must not block, so we want a WAL reader/writer split.
//!    `SQLCipher` encrypts the `-wal`/`-shm` sidecar pages, so the on-disk
//!    privacy guarantee is preserved.
//! 2. **`cipher_memory_security` is OFF.** This database holds public map
//!    imagery, not secret key material; the privacy win is encrypting the
//!    *coordinates/areas* at rest at all. `temp_store = MEMORY` is kept so no
//!    plaintext tile bytes spill to an unencrypted on-disk temp file.
//! 3. **Two connections** (`read_conn`, `write_conn`) to the same file. `get`
//!    uses `read_conn`; every write uses `write_conn`. With WAL they do not
//!    block each other.
//!
//! # Privacy
//!
//! Tile coordinates and cached bytes are sensitive (a z15 coordinate pins a
//! ~1 km location; a sequence is a movement trace). Nothing here logs or
//! formats coordinates, cached bytes, or the encryption key (Security
//! Rule #6 / #8). The cache is keyed on `(style, z, x, y, retina)` only — never
//! a URL or `api_key`.

// SQLite operations hold the connection lock for the duration of the operation
// (often across a count-then-delete or a multi-statement eviction transaction).
// Dropping the guard earlier would require restructuring the methods, so the
// guard lifetime is intentional, mirroring `circle::storage`.
#![allow(clippy::significant_drop_tightening)]

use std::path::Path;
use std::sync::Mutex;

use rusqlite::{params, Connection, OptionalExtension};

use super::error::{Result, TileCacheError};

/// The on-disk schema version this build understands.
///
/// A mismatch (an on-disk DB created by a future build that bumped this)
/// surfaces [`TileCacheError::SchemaVersionMismatch`], which the FFI layer
/// resolves by dropping and recreating the disposable cache.
const SCHEMA_VERSION: i64 = 1;

/// Coarse `accessed_at` bump threshold, in milliseconds (one hour).
///
/// `get` only writes `accessed_at` when the stored value is older than this, so
/// a tile revisited many times within an hour incurs at most one write. This
/// preserves LRU ordering for daily-revisited tiles (home/work) without
/// per-read write amplification.
pub const COARSE_ACCESS_BUMP_MS: i64 = 3_600_000;

/// Raw columns read by [`TileCacheStorage::get`]:
/// `(bytes, stale_at, last_modified, etag, accessed_at)`.
type TileGetRow = (Vec<u8>, i64, Option<i64>, Option<String>, i64);

/// A cached tile plus its freshness/conditional-revalidation metadata.
///
/// `bytes` is the raw PNG imagery (public, but encrypted at rest so the
/// *areas* it reveals stay private). The three optional/scalar metadata fields
/// drive `flutter_map`'s conditional GET on the next render.
#[derive(Clone, PartialEq, Eq)]
pub struct TileEntry {
    /// Raw tile bytes (PNG).
    pub bytes: Vec<u8>,
    /// HTTP freshness deadline in unix milliseconds (from the caller).
    pub stale_at_ms: i64,
    /// `Last-Modified` as unix milliseconds, if the server provided one.
    pub last_modified_ms: Option<i64>,
    /// `ETag` value, if the server provided one.
    pub etag: Option<String>,
}

impl std::fmt::Debug for TileEntry {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // Never print the raw bytes; the byte length is a benign size hint.
        f.debug_struct("TileEntry")
            .field("bytes", &format_args!("<{} bytes>", self.bytes.len()))
            .field("stale_at_ms", &self.stale_at_ms)
            .field("last_modified_ms", &self.last_modified_ms)
            .field("has_etag", &self.etag.is_some())
            .finish()
    }
}

/// `SQLCipher`-encrypted storage for cached map tiles.
///
/// Holds two connections to the same encrypted file: `read_conn` services
/// `get`, `write_conn` services every mutation. With WAL the reader and writer
/// run concurrently, so a foreground pan-read never queues behind a prefetch
/// write-burst.
pub struct TileCacheStorage {
    /// Connection used for `get` reads (and the lazy `accessed_at` bump, which
    /// actually goes through `write_conn`).
    read_conn: Mutex<Connection>,
    /// Connection used for all writes (`put`, `put_metadata`, `evict`, `clear`,
    /// and the lazy `accessed_at` bump).
    write_conn: Mutex<Connection>,
}

impl std::fmt::Debug for TileCacheStorage {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // Opaque: never expose the live connections (or anything reachable
        // through them) via Debug. This impl exists only so callers/tests can
        // `expect`/`expect_err` on `Result<TileCacheStorage, _>`.
        f.write_str("TileCacheStorage { .. }")
    }
}

impl TileCacheStorage {
    /// Opens (or creates) the encrypted tile cache at `path`.
    ///
    /// Validates `hex_key` (must be exactly 64 hex characters), opens the write
    /// connection, applies the divergent hardening pragmas + WAL, verifies the
    /// key by reading `sqlite_master`, then creates or version-checks the
    /// schema. The read connection is opened with the same key and pragmas.
    ///
    /// # Errors
    ///
    /// * [`TileCacheError::InvalidKey`] if `hex_key` is not 64 hex chars.
    /// * [`TileCacheError::DecryptFailed`] if the key cannot decrypt the DB.
    /// * [`TileCacheError::SchemaVersionMismatch`] if the on-disk
    ///   `user_version` is newer than [`SCHEMA_VERSION`].
    /// * [`TileCacheError::Storage`] on other `SQLite` failures.
    pub fn open(path: &Path, hex_key: &str) -> Result<Self> {
        if !is_valid_hex_key(hex_key) {
            return Err(TileCacheError::InvalidKey);
        }

        // --- Write connection: applies pragmas, sets WAL, owns schema work. ---
        let write = Self::open_keyed_connection(path, hex_key)?;

        // Schema version gate: 0 = fresh (create + stamp), 1 = current (ok),
        // anything else = a future layout we must not touch. `user_version` is
        // read AFTER the decrypt verification inside `open_keyed_connection`.
        let version: i64 = write.query_row("PRAGMA user_version", [], |r| r.get(0))?;
        match version {
            0 => {
                Self::create_schema(&write)?;
                write.execute_batch(&format!("PRAGMA user_version = {SCHEMA_VERSION}"))?;
            }
            v if v == SCHEMA_VERSION => {}
            _ => return Err(TileCacheError::SchemaVersionMismatch),
        }

        // --- Read connection: same key + pragmas, no schema work. ---
        let read = Self::open_keyed_connection(path, hex_key)?;

        Ok(Self {
            read_conn: Mutex::new(read),
            write_conn: Mutex::new(write),
        })
    }

    /// Opens a single keyed connection with the tile-cache pragma set and
    /// verifies the key decrypts the database.
    ///
    /// Pragma order is load-bearing: `temp_store = MEMORY` first, then
    /// `PRAGMA key` (raw 64-hex AES-256 key — no PBKDF2 since the key already
    /// has 256 bits of `OsRng` entropy), then `busy_timeout`/`synchronous`,
    /// then a `SELECT` against `sqlite_master` to **verify the key BEFORE**
    /// turning on WAL. `PRAGMA journal_mode = WAL` rewrites the database header,
    /// so it must not run on a connection holding the wrong key — otherwise the
    /// wrong-key failure would surface as a generic header-write error instead
    /// of [`TileCacheError::DecryptFailed`]. WAL is applied last.
    ///
    /// # Divergences from the avatar/circle pattern (deliberate, owner-approved)
    ///
    /// * `cipher_memory_security` is intentionally **NOT** set: this DB holds
    ///   public map imagery, not secret bytes. Wiping page buffers buys nothing
    ///   here and costs throughput on the pan-read hot path.
    /// * `journal_mode = WAL` is intentionally set (circles.db deliberately
    ///   avoids touching `journal_mode`). WAL lets foreground reads run
    ///   concurrently with prefetch writes. `SQLCipher` encrypts the
    ///   `-wal`/`-shm` sidecar pages, so the on-disk privacy guarantee holds —
    ///   but those sidecars MUST be deleted alongside `tiles.db` on wipe.
    ///
    /// # Errors
    ///
    /// Returns [`TileCacheError::DecryptFailed`] if the key cannot decrypt the
    /// database, or [`TileCacheError::Storage`] on other `SQLite` failures.
    fn open_keyed_connection(path: &Path, hex_key: &str) -> Result<Connection> {
        let conn = Connection::open(path)?;
        // `temp_store = MEMORY` keeps temp B-trees / sorter spills in RAM so no
        // plaintext tile bytes ever land in an unencrypted on-disk temp file.
        conn.execute_batch("PRAGMA temp_store = MEMORY;")?;
        // hex_key is validated by the caller to be exactly 64 hex chars; the raw
        // key format avoids PBKDF2 since the key already carries 256 bits of
        // entropy from OsRng.
        conn.execute_batch(&format!("PRAGMA key = \"x'{hex_key}'\""))?;

        // Verify the key decrypts the database. SQLCipher only validates the key
        // lazily on first read, so this SELECT is the FIRST statement that
        // touches a page and is what surfaces a wrong key. It must run before
        // ANY other pragma that reads/writes the database (`busy_timeout` and
        // `synchronous` are connection-scoped and safe, but the WAL switch
        // rewrites the header) so a wrong key always surfaces as DecryptFailed
        // rather than a generic storage error.
        conn.query_row("SELECT count(*) FROM sqlite_master", [], |r| {
            r.get::<_, i64>(0)
        })
        .map_err(|_| TileCacheError::DecryptFailed)?;

        conn.execute_batch(
            "PRAGMA busy_timeout = 2000;
             PRAGMA synchronous = NORMAL;
             PRAGMA journal_mode = WAL;",
        )?;
        Ok(conn)
    }

    /// Creates the `tile_blobs` table and its access/fetch indices.
    ///
    /// `byte_len` is stored alongside the BLOB so eviction can sum tile sizes
    /// without scanning (or even reading) the BLOB pages.
    fn create_schema(conn: &Connection) -> Result<()> {
        // NOTE: `tile_blobs` is intentionally a rowid table (a composite PRIMARY
        // KEY does NOT make it `WITHOUT ROWID`). `evict`'s LRU pass selects and
        // deletes victims by `rowid` — do NOT add `WITHOUT ROWID` here, or that
        // eviction would silently break.
        conn.execute_batch(
            r"
            CREATE TABLE IF NOT EXISTS tile_blobs (
                style TEXT NOT NULL,
                z INTEGER NOT NULL,
                x INTEGER NOT NULL,
                y INTEGER NOT NULL,
                retina INTEGER NOT NULL,
                bytes BLOB NOT NULL,
                byte_len INTEGER NOT NULL,
                stale_at INTEGER NOT NULL,
                etag TEXT,
                last_modified INTEGER,
                fetched_at INTEGER NOT NULL,
                accessed_at INTEGER NOT NULL,
                PRIMARY KEY (style, z, x, y, retina)
            );
            CREATE INDEX IF NOT EXISTS idx_tile_accessed ON tile_blobs(accessed_at);
            CREATE INDEX IF NOT EXISTS idx_tile_fetched ON tile_blobs(fetched_at);
            ",
        )?;
        Ok(())
    }

    /// Returns the cached tile for `(style, z, x, y, retina)`, or `None`.
    ///
    /// This is a near-pure read on `read_conn`. On a hit it performs a **lazy**
    /// coarse `accessed_at` bump (decision 4): it writes `accessed_at = now_ms`
    /// only when the stored value is older than [`COARSE_ACCESS_BUMP_MS`],
    /// keeping the read path free of write amplification while still preserving
    /// LRU ordering for daily-revisited tiles. The bump goes through
    /// `write_conn` so the read connection stays read-only.
    ///
    /// # Errors
    ///
    /// Returns [`TileCacheError::Storage`] on lock poisoning or `SQLite`
    /// failure.
    pub fn get(
        &self,
        style: &str,
        z: i64,
        x: i64,
        y: i64,
        retina: bool,
        now_ms: i64,
    ) -> Result<Option<TileEntry>> {
        let read = self
            .read_conn
            .lock()
            .map_err(|e| TileCacheError::Storage(format!("read lock poisoned: {e}")))?;

        let row: Option<TileGetRow> = read
            .query_row(
                "SELECT bytes, stale_at, last_modified, etag, accessed_at
                 FROM tile_blobs
                 WHERE style = ?1 AND z = ?2 AND x = ?3 AND y = ?4 AND retina = ?5",
                params![style, z, x, y, i64::from(retina)],
                |r| {
                    Ok((
                        r.get::<_, Vec<u8>>(0)?,
                        r.get::<_, i64>(1)?,
                        r.get::<_, Option<i64>>(2)?,
                        r.get::<_, Option<String>>(3)?,
                        r.get::<_, i64>(4)?,
                    ))
                },
            )
            .optional()?;
        drop(read);

        let Some((bytes, stale_at_ms, last_modified_ms, etag, accessed_at)) = row else {
            return Ok(None);
        };

        // Lazy, coarse LRU bump: only write when the stored access time is more
        // than COARSE_ACCESS_BUMP_MS stale. Never an UPDATE per read otherwise.
        if now_ms.saturating_sub(accessed_at) > COARSE_ACCESS_BUMP_MS {
            let write = self
                .write_conn
                .lock()
                .map_err(|e| TileCacheError::Storage(format!("write lock poisoned: {e}")))?;
            write.execute(
                "UPDATE tile_blobs SET accessed_at = ?6
                 WHERE style = ?1 AND z = ?2 AND x = ?3 AND y = ?4 AND retina = ?5",
                params![style, z, x, y, i64::from(retina), now_ms],
            )?;
        }

        Ok(Some(TileEntry {
            bytes,
            stale_at_ms,
            last_modified_ms,
            etag,
        }))
    }

    /// Inserts or replaces the tile bytes and metadata for the key.
    ///
    /// A bytes-write is the only place `fetched_at` is set (to `now_ms`) — it is
    /// the download anchor for the absolute-retention clock. `accessed_at` is
    /// also set to `now_ms`.
    ///
    /// # Errors
    ///
    /// Returns [`TileCacheError::Storage`] on lock poisoning or `SQLite`
    /// failure.
    #[allow(
        clippy::too_many_arguments,
        reason = "the FFI tile key + payload is inherently wide; grouping would change the wire contract"
    )]
    pub fn put(
        &self,
        style: &str,
        z: i64,
        x: i64,
        y: i64,
        retina: bool,
        bytes: &[u8],
        stale_at_ms: i64,
        last_modified_ms: Option<i64>,
        etag: Option<&str>,
        now_ms: i64,
    ) -> Result<()> {
        let write = self
            .write_conn
            .lock()
            .map_err(|e| TileCacheError::Storage(format!("write lock poisoned: {e}")))?;

        write.execute(
            "INSERT INTO tile_blobs
                 (style, z, x, y, retina, bytes, byte_len, stale_at, etag,
                  last_modified, fetched_at, accessed_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?11)
             ON CONFLICT(style, z, x, y, retina) DO UPDATE SET
                 bytes         = excluded.bytes,
                 byte_len      = excluded.byte_len,
                 stale_at      = excluded.stale_at,
                 etag          = excluded.etag,
                 last_modified = excluded.last_modified,
                 fetched_at    = excluded.fetched_at,
                 accessed_at   = excluded.accessed_at",
            params![
                style,
                z,
                x,
                y,
                i64::from(retina),
                bytes,
                i64::try_from(bytes.len()).unwrap_or(i64::MAX),
                stale_at_ms,
                etag,
                last_modified_ms,
                now_ms,
            ],
        )?;
        Ok(())
    }

    /// Refreshes only the conditional-revalidation metadata for an existing
    /// tile (the HTTP-304 path).
    ///
    /// Updates `stale_at`, `etag`, `last_modified`, and `accessed_at`; it MUST
    /// NOT touch `bytes` or `fetched_at` (a 304 re-downloaded nothing, so the
    /// absolute-retention anchor must not move). If no row matches the key it is
    /// a silent no-op (`rows == 0` → `Ok`).
    ///
    /// # Errors
    ///
    /// Returns [`TileCacheError::Storage`] on lock poisoning or `SQLite`
    /// failure.
    #[allow(
        clippy::too_many_arguments,
        reason = "mirrors the tile key + metadata shape of `put`"
    )]
    pub fn put_metadata(
        &self,
        style: &str,
        z: i64,
        x: i64,
        y: i64,
        retina: bool,
        stale_at_ms: i64,
        last_modified_ms: Option<i64>,
        etag: Option<&str>,
        now_ms: i64,
    ) -> Result<()> {
        let write = self
            .write_conn
            .lock()
            .map_err(|e| TileCacheError::Storage(format!("write lock poisoned: {e}")))?;

        // Deliberately omits `bytes` and `fetched_at` from the SET clause: a 304
        // response carries no body and must not reset the download anchor.
        write.execute(
            "UPDATE tile_blobs SET
                 stale_at      = ?6,
                 etag          = ?7,
                 last_modified = ?8,
                 accessed_at   = ?9
             WHERE style = ?1 AND z = ?2 AND x = ?3 AND y = ?4 AND retina = ?5",
            params![
                style,
                z,
                x,
                y,
                i64::from(retina),
                stale_at_ms,
                etag,
                last_modified_ms,
                now_ms,
            ],
        )?;
        Ok(())
    }

    /// Evicts stale, over-retention, and over-budget tiles in one transaction.
    ///
    /// Runs three passes on `write_conn`, in a single transaction so a prefetch
    /// write cannot interleave and so the byte budget is not overshot:
    ///
    /// 1. Idle purge: delete rows whose `accessed_at < now_ms - idle_age_ms`.
    /// 2. Absolute purge: delete rows whose `fetched_at < now_ms - max_retention_ms`
    ///    (access-independent — the ToS-correct retention model).
    /// 3. LRU-to-budget: if `SUM(byte_len) > max_bytes`, delete least-recently
    ///    accessed rows (oldest `accessed_at` first) until the running total is
    ///    within budget.
    ///
    /// Returns the total number of rows deleted across all three passes.
    ///
    /// # Errors
    ///
    /// Returns [`TileCacheError::Storage`] on lock poisoning or `SQLite`
    /// failure; the transaction is rolled back on error.
    pub fn evict(
        &self,
        max_bytes: i64,
        idle_age_ms: i64,
        max_retention_ms: i64,
        now_ms: i64,
    ) -> Result<u64> {
        let mut write = self
            .write_conn
            .lock()
            .map_err(|e| TileCacheError::Storage(format!("write lock poisoned: {e}")))?;
        let tx = write.transaction()?;

        let mut deleted: u64 = 0;

        // (1) Idle purge by accessed_at.
        let idle_cutoff = now_ms.saturating_sub(idle_age_ms);
        deleted += tx.execute(
            "DELETE FROM tile_blobs WHERE accessed_at < ?1",
            params![idle_cutoff],
        )? as u64;

        // (2) Absolute purge by fetched_at (access-independent).
        let retention_cutoff = now_ms.saturating_sub(max_retention_ms);
        deleted += tx.execute(
            "DELETE FROM tile_blobs WHERE fetched_at < ?1",
            params![retention_cutoff],
        )? as u64;

        // (3) LRU-to-budget. Sum remaining sizes; if over budget, walk rows
        // oldest-accessed-first accumulating byte_len and collect the rowids to
        // delete until the running total is back within `max_bytes`.
        let total_bytes: i64 = tx.query_row(
            "SELECT COALESCE(SUM(byte_len), 0) FROM tile_blobs",
            [],
            |r| r.get(0),
        )?;

        if total_bytes > max_bytes {
            // The amount we must shed to get back to budget.
            let mut overflow = total_bytes - max_bytes;
            let victims: Vec<i64> = {
                let mut stmt = tx.prepare(
                    "SELECT rowid, byte_len FROM tile_blobs ORDER BY accessed_at ASC, rowid ASC",
                )?;
                let mut rows = stmt.query([])?;
                let mut ids = Vec::new();
                while overflow > 0 {
                    let Some(row) = rows.next()? else { break };
                    let rowid: i64 = row.get(0)?;
                    let byte_len: i64 = row.get(1)?;
                    ids.push(rowid);
                    overflow -= byte_len;
                }
                ids
            };

            for rowid in victims {
                deleted +=
                    tx.execute("DELETE FROM tile_blobs WHERE rowid = ?1", params![rowid])? as u64;
            }
        }

        tx.commit()?;
        Ok(deleted)
    }

    /// Deletes every cached tile (used by the logout wipe path).
    ///
    /// # Errors
    ///
    /// Returns [`TileCacheError::Storage`] on lock poisoning or `SQLite`
    /// failure.
    pub fn clear(&self) -> Result<()> {
        let write = self
            .write_conn
            .lock()
            .map_err(|e| TileCacheError::Storage(format!("write lock poisoned: {e}")))?;
        write.execute("DELETE FROM tile_blobs", [])?;
        Ok(())
    }

    /// Test helper: counts cached tile rows.
    ///
    /// # Errors
    ///
    /// Returns [`TileCacheError::Storage`] on lock poisoning or `SQLite`
    /// failure.
    #[cfg(test)]
    pub fn count(&self) -> Result<i64> {
        let read = self
            .read_conn
            .lock()
            .map_err(|e| TileCacheError::Storage(format!("read lock poisoned: {e}")))?;
        read.query_row("SELECT COUNT(*) FROM tile_blobs", [], |r| r.get(0))
            .map_err(Into::into)
    }

    /// Test helper: reads the stored `(fetched_at, accessed_at)` for a key.
    #[cfg(test)]
    fn fetched_and_accessed(
        &self,
        style: &str,
        z: i64,
        x: i64,
        y: i64,
        retina: bool,
    ) -> Result<Option<(i64, i64)>> {
        let read = self
            .read_conn
            .lock()
            .map_err(|e| TileCacheError::Storage(format!("read lock poisoned: {e}")))?;
        read.query_row(
            "SELECT fetched_at, accessed_at FROM tile_blobs
             WHERE style = ?1 AND z = ?2 AND x = ?3 AND y = ?4 AND retina = ?5",
            params![style, z, x, y, i64::from(retina)],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()
        .map_err(Into::into)
    }
}

/// Returns `true` if `hex_key` is exactly 64 ASCII-hex characters.
///
/// Defense-in-depth against SQL injection through the `PRAGMA key` string and a
/// guard against a malformed (non-256-bit) key.
fn is_valid_hex_key(hex_key: &str) -> bool {
    hex_key.len() == 64 && hex_key.bytes().all(|b| b.is_ascii_hexdigit())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    /// A valid 64-hex test key (256 bits). Fixed so reopen tests are
    /// deterministic. This is a test fixture, not a real secret.
    const TEST_KEY: &str = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff";
    const OTHER_KEY: &str = "ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100";

    /// Opens an encrypted tile cache backed by a real on-disk `SQLCipher`
    /// tempfile so tests exercise the actual crypto/WAL path, returning the dir
    /// guard (which must outlive the storage) and the storage.
    fn open_temp() -> (TempDir, TileCacheStorage) {
        let dir = TempDir::new().expect("tempdir");
        let path = dir.path().join("tiles.db");
        let storage = TileCacheStorage::open(&path, TEST_KEY).expect("open tiles.db");
        (dir, storage)
    }

    #[test]
    fn put_then_get_round_trips_bytes_and_metadata() {
        let (_dir, storage) = open_temp();
        storage
            .put(
                "alidade_smooth",
                14,
                8187,
                5451,
                false,
                b"PNG-BYTES",
                10_000,
                Some(9_000),
                Some("etag-abc"),
                1_000,
            )
            .unwrap();

        let entry = storage
            .get("alidade_smooth", 14, 8187, 5451, false, 1_000)
            .unwrap()
            .expect("hit");
        assert_eq!(entry.bytes, b"PNG-BYTES");
        assert_eq!(entry.stale_at_ms, 10_000);
        assert_eq!(entry.last_modified_ms, Some(9_000));
        assert_eq!(entry.etag.as_deref(), Some("etag-abc"));
    }

    #[test]
    fn get_absent_returns_none() {
        let (_dir, storage) = open_temp();
        assert!(storage
            .get("osm_bright", 10, 1, 1, false, 1_000)
            .unwrap()
            .is_none());
    }

    #[test]
    fn retina_and_style_shard_the_cache() {
        let (_dir, storage) = open_temp();
        storage
            .put("s", 5, 1, 1, false, b"std", 1, None, None, 1)
            .unwrap();
        storage
            .put("s", 5, 1, 1, true, b"retina", 1, None, None, 1)
            .unwrap();
        storage
            .put("other", 5, 1, 1, false, b"other-style", 1, None, None, 1)
            .unwrap();

        assert_eq!(
            storage.get("s", 5, 1, 1, false, 1).unwrap().unwrap().bytes,
            b"std"
        );
        assert_eq!(
            storage.get("s", 5, 1, 1, true, 1).unwrap().unwrap().bytes,
            b"retina"
        );
        assert_eq!(
            storage
                .get("other", 5, 1, 1, false, 1)
                .unwrap()
                .unwrap()
                .bytes,
            b"other-style"
        );
        assert_eq!(storage.count().unwrap(), 3);
    }

    #[test]
    fn get_does_not_bump_accessed_at_within_the_coarse_threshold() {
        let (_dir, storage) = open_temp();
        let put_at = 1_000_000;
        storage
            .put("s", 1, 0, 0, false, b"b", 1, None, None, put_at)
            .unwrap();

        // A read shortly after (well within COARSE_ACCESS_BUMP_MS) must leave
        // accessed_at untouched — the read path stays pure.
        let read_at = put_at + COARSE_ACCESS_BUMP_MS; // exactly at threshold, not >
        storage.get("s", 1, 0, 0, false, read_at).unwrap();
        let (_, accessed) = storage
            .fetched_and_accessed("s", 1, 0, 0, false)
            .unwrap()
            .unwrap();
        assert_eq!(accessed, put_at, "no bump at-or-below the coarse threshold");
    }

    #[test]
    fn get_bumps_accessed_at_only_past_the_coarse_threshold() {
        let (_dir, storage) = open_temp();
        let put_at = 1_000_000;
        storage
            .put("s", 1, 0, 0, false, b"b", 1, None, None, put_at)
            .unwrap();

        // A read strictly more than COARSE_ACCESS_BUMP_MS later bumps once.
        let read_at = put_at + COARSE_ACCESS_BUMP_MS + 1;
        storage.get("s", 1, 0, 0, false, read_at).unwrap();
        let (fetched, accessed) = storage
            .fetched_and_accessed("s", 1, 0, 0, false)
            .unwrap()
            .unwrap();
        assert_eq!(accessed, read_at, "accessed_at bumped to the read time");
        assert_eq!(fetched, put_at, "a read never moves the fetched_at anchor");
    }

    #[test]
    fn put_metadata_updates_freshness_but_preserves_bytes_and_fetched_at() {
        let (_dir, storage) = open_temp();
        let fetched = 5_000;
        storage
            .put(
                "s",
                2,
                3,
                4,
                false,
                b"original",
                10,
                Some(1),
                Some("old"),
                fetched,
            )
            .unwrap();

        // 304 path: refresh stale_at/etag/last_modified + accessed_at only.
        let meta_at = 50_000;
        storage
            .put_metadata("s", 2, 3, 4, false, 99, Some(7), Some("new"), meta_at)
            .unwrap();

        let entry = storage.get("s", 2, 3, 4, false, meta_at).unwrap().unwrap();
        assert_eq!(entry.bytes, b"original", "bytes untouched by 304");
        assert_eq!(entry.stale_at_ms, 99);
        assert_eq!(entry.last_modified_ms, Some(7));
        assert_eq!(entry.etag.as_deref(), Some("new"));

        let (fetched_after, accessed_after) = storage
            .fetched_and_accessed("s", 2, 3, 4, false)
            .unwrap()
            .unwrap();
        assert_eq!(fetched_after, fetched, "304 must not move fetched_at");
        assert_eq!(accessed_after, meta_at, "304 bumps accessed_at");
    }

    #[test]
    fn put_metadata_is_a_no_op_when_the_tile_is_absent() {
        let (_dir, storage) = open_temp();
        // Must not error, must not insert a row.
        storage
            .put_metadata("s", 9, 9, 9, false, 1, None, None, 1)
            .unwrap();
        assert_eq!(storage.count().unwrap(), 0);
    }

    #[test]
    fn evict_idle_purges_tiles_untouched_past_the_idle_age() {
        let (_dir, storage) = open_temp();
        let now = 200_000;
        let idle_age = 50_000;
        // idle_cutoff = now - idle_age = 150_000. The old tile (accessed at
        // 1_000) is older than the cutoff and must be purged; the fresh tile
        // (accessed at 160_000 > cutoff) must survive.
        storage
            .put("s", 1, 0, 0, false, b"old", 1, None, None, 1_000)
            .unwrap();
        storage
            .put("s", 1, 1, 1, false, b"new", 1, None, None, 160_000)
            .unwrap();

        // huge byte budget + retention so only the idle pass fires.
        let removed = storage.evict(i64::MAX, idle_age, i64::MAX, now).unwrap();
        assert_eq!(removed, 1);
        assert!(storage.get("s", 1, 0, 0, false, now).unwrap().is_none());
        assert!(storage.get("s", 1, 1, 1, false, now).unwrap().is_some());
    }

    #[test]
    fn evict_absolute_purges_regardless_of_recent_access() {
        let (_dir, storage) = open_temp();
        // A tile fetched long ago but accessed very recently must STILL be
        // purged by the absolute-retention clock (ToS-correct behaviour).
        storage
            .put("s", 1, 0, 0, false, b"old-fetch", 1, None, None, 1_000)
            .unwrap();
        // Bump its accessed_at far into the future via a coarse read.
        let recent = 1_000 + COARSE_ACCESS_BUMP_MS + 1;
        storage.get("s", 1, 0, 0, false, recent).unwrap();

        let now = recent + 10;
        let max_retention = 5_000; // fetched_at(1_000) < now - 5_000
                                   // No idle purge (idle age huge), no byte pressure.
        let removed = storage
            .evict(i64::MAX, i64::MAX, max_retention, now)
            .unwrap();
        assert_eq!(removed, 1, "absolute purge ignores recent access");
        assert!(storage.get("s", 1, 0, 0, false, now).unwrap().is_none());
    }

    #[test]
    fn evict_lru_keeps_newest_accessed_under_budget() {
        let (_dir, storage) = open_temp();
        // Three 100-byte tiles, distinct accessed_at via fetched_at=now on put.
        let payload = vec![0u8; 100];
        storage
            .put("s", 1, 0, 0, false, &payload, 1, None, None, 1_000)
            .unwrap(); // oldest
        storage
            .put("s", 1, 1, 0, false, &payload, 1, None, None, 2_000)
            .unwrap(); // middle
        storage
            .put("s", 1, 2, 0, false, &payload, 1, None, None, 3_000)
            .unwrap(); // newest

        // Budget fits ~1.5 tiles → must evict the two oldest, keep the newest.
        let now = 4_000;
        let removed = storage.evict(150, i64::MAX, i64::MAX, now).unwrap();
        assert_eq!(removed, 2);
        assert!(storage.get("s", 1, 0, 0, false, now).unwrap().is_none());
        assert!(storage.get("s", 1, 1, 0, false, now).unwrap().is_none());
        assert!(
            storage.get("s", 1, 2, 0, false, now).unwrap().is_some(),
            "the most-recently-accessed tile survives the byte budget"
        );
    }

    #[test]
    fn evict_lru_no_op_when_under_budget() {
        let (_dir, storage) = open_temp();
        storage
            .put("s", 1, 0, 0, false, &[0u8; 50], 1, None, None, 1_000)
            .unwrap();
        let removed = storage.evict(i64::MAX, i64::MAX, i64::MAX, 2_000).unwrap();
        assert_eq!(removed, 0);
        assert_eq!(storage.count().unwrap(), 1);
    }

    #[test]
    fn evict_runs_all_three_clocks_in_one_call() {
        let (_dir, storage) = open_temp();
        let now = 1_000_000;
        // A: idle victim — accessed 200s ago (> idle age), fetched recently
        // (within retention), so ONLY the idle clock removes it.
        storage
            .put("s", 1, 0, 0, false, &[0u8; 100], 1, None, None, 800_000)
            .unwrap();
        // B: absolute victim — fetched 600s ago (> retention) but accessed just
        // now, so it is NOT idle. put_metadata bumps accessed_at without moving
        // the fetched_at retention anchor, isolating the absolute clock.
        storage
            .put("s", 2, 0, 0, false, &[0u8; 100], 1, None, None, 400_000)
            .unwrap();
        storage
            .put_metadata("s", 2, 0, 0, false, 1, None, None, 999_990)
            .unwrap();
        // C/D: both fresh (neither idle nor over-retention); together they exceed
        // the byte budget, so the LRU clock evicts the least-recently-accessed (C).
        storage
            .put("s", 3, 0, 0, false, &[0u8; 200], 1, None, None, 999_000)
            .unwrap();
        storage
            .put("s", 4, 0, 0, false, &[0u8; 200], 1, None, None, 999_500)
            .unwrap();

        // idle 100s, retention 500s, budget 250 bytes — all three fire at once.
        let removed = storage.evict(250, 100_000, 500_000, now).unwrap();
        assert_eq!(removed, 3, "idle + absolute + LRU each remove one tile");
        assert!(
            storage.get("s", 1, 0, 0, false, now).unwrap().is_none(),
            "A idle-purged"
        );
        assert!(
            storage.get("s", 2, 0, 0, false, now).unwrap().is_none(),
            "B absolute-purged"
        );
        assert!(
            storage.get("s", 3, 0, 0, false, now).unwrap().is_none(),
            "C LRU-evicted (least-recently-accessed over budget)"
        );
        assert!(
            storage.get("s", 4, 0, 0, false, now).unwrap().is_some(),
            "D survives (newest access, fits budget)"
        );
        assert_eq!(storage.count().unwrap(), 1);
    }

    #[test]
    fn clear_empties_the_cache() {
        let (_dir, storage) = open_temp();
        storage
            .put("s", 1, 0, 0, false, b"b", 1, None, None, 1)
            .unwrap();
        storage
            .put("s", 1, 1, 1, false, b"b", 1, None, None, 1)
            .unwrap();
        storage.clear().unwrap();
        assert_eq!(storage.count().unwrap(), 0);
    }

    #[test]
    fn reopen_with_correct_key_reads_back_tiles() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("tiles.db");
        {
            let storage = TileCacheStorage::open(&path, TEST_KEY).unwrap();
            storage
                .put("s", 7, 1, 2, true, b"persisted", 1, None, Some("e"), 1)
                .unwrap();
        }
        let storage = TileCacheStorage::open(&path, TEST_KEY).unwrap();
        let entry = storage.get("s", 7, 1, 2, true, 1).unwrap().unwrap();
        assert_eq!(entry.bytes, b"persisted");
        assert_eq!(entry.etag.as_deref(), Some("e"));
    }

    #[test]
    fn reopen_with_wrong_key_fails_to_decrypt() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("tiles.db");
        {
            let storage = TileCacheStorage::open(&path, TEST_KEY).unwrap();
            storage
                .put("s", 1, 0, 0, false, b"secret-area", 1, None, None, 1)
                .unwrap();
        }
        let err = TileCacheStorage::open(&path, OTHER_KEY)
            .expect_err("a wrong key must not open the cache");
        assert!(
            matches!(err, TileCacheError::DecryptFailed),
            "wrong key must surface DecryptFailed, got {err:?}"
        );
    }

    #[test]
    fn future_user_version_surfaces_schema_mismatch() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("tiles.db");
        {
            let storage = TileCacheStorage::open(&path, TEST_KEY).unwrap();
            // Simulate a future build bumping the schema version on disk.
            let write = storage.write_conn.lock().unwrap();
            write
                .execute_batch(&format!("PRAGMA user_version = {}", SCHEMA_VERSION + 1))
                .unwrap();
        }
        let err = TileCacheStorage::open(&path, TEST_KEY)
            .expect_err("a newer on-disk schema must be rejected");
        assert!(
            matches!(err, TileCacheError::SchemaVersionMismatch),
            "expected SchemaVersionMismatch, got {err:?}"
        );
    }

    #[test]
    fn open_rejects_non_64_hex_keys() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("tiles.db");
        for bad in [
            "",                                                                   // empty
            "abc",                                                                // too short
            "00112233445566778899aabbccddeeff00112233445566778899aabbccddee",     // 62 chars
            "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeffaa", // 66 chars
            "00112233445566778899aabbccddeeff00112233445566778899aabbccddeegg",   // non-hex 'g'
        ] {
            let err =
                TileCacheStorage::open(&path, bad).expect_err("a non-64-hex key must be rejected");
            assert!(
                matches!(err, TileCacheError::InvalidKey),
                "key {bad:?} must surface InvalidKey, got {err:?}"
            );
        }
    }

    #[test]
    fn put_overwrites_bytes_and_resets_fetched_at() {
        let (_dir, storage) = open_temp();
        storage
            .put("s", 1, 0, 0, false, b"v1", 1, None, None, 1_000)
            .unwrap();
        storage
            .put("s", 1, 0, 0, false, b"v2", 2, None, None, 9_000)
            .unwrap();

        let entry = storage.get("s", 1, 0, 0, false, 9_000).unwrap().unwrap();
        assert_eq!(entry.bytes, b"v2");
        assert_eq!(entry.stale_at_ms, 2);
        let (fetched, _) = storage
            .fetched_and_accessed("s", 1, 0, 0, false)
            .unwrap()
            .unwrap();
        assert_eq!(fetched, 9_000, "a bytes-write resets the fetched_at anchor");
        assert_eq!(storage.count().unwrap(), 1, "upsert, not a second row");
    }
}
