//! Storage configuration for the Marmot "Dark Matter" MLS stack.
//!
//! This module resolves the on-disk location and the `SQLCipher` key for the MLS
//! `AccountDeviceSession`'s database (`session.sqlite`) and constructs the
//! `storage-sqlite` backend the session runs on. The database persists MLS
//! group state, `OpenMLS` value rows, and message projections.
//!
//! # Key custody (security F5)
//!
//! Unlike the old `MdkSqliteStorage`, which owned the keyring integration
//! internally, the Dark Matter `storage-sqlite` crate takes a passphrase and
//! does NOT touch the platform keyring. Haven therefore provisions the
//! passphrase here: on first use it mints 32 bytes of `OsRng` entropy, stores
//! the RAW bytes in the platform keyring, and derives a lowercase-hex passphrase
//! from them. `SqliteAccountStorage` feeds that passphrase through `SQLCipher`'s
//! PBKDF2 (`PRAGMA key = '<str>'`, `cipher_compatibility = 4`) — so the
//! passphrase is a defense-in-depth *stretch* over already-256-bit-strong
//! material. The passphrase is `Zeroizing` end to end (keyring buffer, hex
//! string, and the `SqlCipherKey` copy) and is NEVER logged.
//!
//! This is deliberately incompatible with `circles.db` / `tiles.db`, which use
//! the raw-key form (`PRAGMA key = "x'<64-hex>'"`, KDF bypassed). The MLS DB is
//! wiped-and-recreated on the Dark Matter cutover, so there is no in-place
//! re-key to reconcile.
//!
//! # Legacy database (kept for the cutover wipe — security F6)
//!
//! The pre-Dark-Matter `haven_mdk.db` path and its `mdk.db.key.default` keyring
//! entry are retained as `legacy_*` constants so the DM-5 cutover can delete the
//! old database files AND destroy the old keyring key. Unlinking the file is not
//! a secure erase (the old DB was not written with `secure_delete`, and flash
//! wear-levelling leaves residual ciphertext), so key destruction is the
//! practical secure-erase for the abandoned `SQLCipher` database.

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

use rand::rngs::OsRng;
use rand::RngCore;
#[cfg(any(test, feature = "test-utils"))]
use storage_sqlite::SqliteAccountStorage;
use storage_sqlite::{SqlCipherKey, SqliteStorageOptions};
use zeroize::Zeroizing;

use crate::nostr::error::{NostrError, Result};

/// Process-global registry of the canonical `session.sqlite` paths that a live
/// [`AccountDeviceSession`] currently holds open (Rule 14 runtime enforcement).
///
/// [`AccountDeviceSession`]: cgka_session::AccountDeviceSession
static LIVE_SESSIONS: OnceLock<Mutex<HashSet<PathBuf>>> = OnceLock::new();

fn live_sessions() -> &'static Mutex<HashSet<PathBuf>> {
    LIVE_SESSIONS.get_or_init(|| Mutex::new(HashSet::new()))
}

/// Machine-readable marker embedded in — and ONLY in — the error
/// [`LiveSessionGuard::acquire`] returns when the database is already claimed by
/// a live session (Rule 14).
///
/// # This marker is for HUMANS, not for control flow
///
/// Every failure crossing the FFI boundary is flattened to a prose `String`, and
/// "an MLS session is already open" is otherwise indistinguishable in a log from
/// a locked keyring or a full disk. The marker makes that one condition
/// greppable in a bug report or an E2E log.
///
/// It is deliberately NOT the way code answers "is the guard held?". Haven's
/// error strings interpolate remote-authored text (see [`is_session_live`] for
/// the concrete chain), so a substring test over them is remotely influenceable.
/// Code must call [`is_session_live`], which reads the registry directly and has
/// no untrusted input. Treat this constant as a log token: if it ever appears in
/// a `contains` that drives a decision, that is a bug.
pub const SESSION_BUSY_MARKER: &str = "HAVEN_E_SESSION_BUSY";

/// The `session.sqlite` path inside `data_dir`.
///
/// Exported so callers never re-spell the filename. A second literal elsewhere
/// silently decouples on any rename: [`is_session_live`] would keep succeeding
/// and answering `false` for a key nothing ever registers, so a reclaiming
/// caller would conclude the guard is free and never recover an orphan. The
/// direction is fail-safe but permanent and silent.
#[must_use]
pub fn session_db_path(data_dir: &Path) -> PathBuf {
    data_dir.join(MLS_DB_FILENAME)
}

/// Reports whether a live session is currently registered for `db_path`.
///
/// This asks the registry directly instead of pattern-matching an error
/// message, and it is the ONLY supported way for a caller to answer "is the
/// Rule-14 guard held on this database?".
///
/// # Why not classify the error string
///
/// The obvious alternative — test a flattened FFI error for
/// [`SESSION_BUSY_MARKER`] — is unsafe, and not for a subtle reason. Haven's
/// error strings interpolate remote-authored text: a circle admin controls the
/// group's routing relay list, and the live-sync relay gate formats the
/// offending URL into its error (`relay/live_sync/session.rs`). A relay URL of
/// `ws://host/HAVEN_E_SESSION_BUSY` therefore produces an unrelated error that a
/// substring test would classify as session-busy — handing a remote party a
/// one-bit control channel over a local recovery decision. Redaction does not
/// help: `redact_hex_sequences` only collapses long hex runs, so it preserves a
/// planted marker as faithfully as a genuine one.
///
/// A registry lookup has no such input. It answers from process-local state
/// that no remote party can write.
///
/// # This is advisory, not exclusion
///
/// The answer is a snapshot: a session may be opened or closed the instant
/// after it returns. That is fine for its purpose (deciding whether a recovery
/// step is worth attempting), and it must NEVER be used to decide whether
/// opening is safe — [`LiveSessionGuard::acquire`] is the only authority on
/// that, because only a CAS can be atomic with respect to the open.
///
/// # Errors
///
/// Returns [`NostrError::StorageError`] if `db_path` cannot be reduced to a
/// canonical registry key — the same fail-closed condition
/// [`LiveSessionGuard::acquire`] hits, surfaced rather than reported as "not
/// live", which would be a fail-open answer.
pub fn is_session_live(db_path: &Path) -> Result<bool> {
    let key = canonical_session_key(db_path)?;
    Ok(live_sessions()
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .contains(&key))
}

/// Normalizes a `session.sqlite` path to a stable registry key.
///
/// The DB file itself may not exist yet on a first open, so the *parent
/// directory* (which the caller creates before opening) is canonicalized and
/// the file name re-attached. This makes two spellings of the same file
/// (relative vs absolute, `.`/`..` segments, a symlinked parent) collide on one
/// key.
///
/// # Why this fails closed
///
/// An earlier version fell back to the raw path when canonicalization failed,
/// documented as "a fail-safe that can only ever be *stricter*". That is true
/// only for the MERGE direction (it never unifies two distinct files). In the
/// other direction it is a fail-**open** on a confidentiality control: if one
/// caller canonicalizes successfully and another hits a transient failure, the
/// two compute DIFFERENT keys for the SAME file, both acquire, and two live
/// [`AccountDeviceSession`]s hydrate from one database — which is exactly the
/// epoch/generation reuse Rule 14 exists to prevent (see the type doc below).
///
/// On Android this is not hypothetical: `/data/user/0/<pkg>` is a symlink to
/// `/data/data/<pkg>`, so the canonical and raw spellings genuinely differ, and
/// the fallback would produce two keys rather than a stricter one.
///
/// Callers create the parent directory before opening (`CoreCircleManager::new`
/// runs `create_dir_all` before `SessionManager::new`), so a failure here means
/// something is genuinely wrong with the data directory — refusing to open is
/// both correct and safe.
///
/// # Errors
///
/// Returns [`NostrError::StorageError`] if `db_path` has no parent or no file
/// name, or if the parent directory cannot be canonicalized.
fn canonical_session_key(db_path: &Path) -> Result<PathBuf> {
    let (Some(parent), Some(name)) = (db_path.parent(), db_path.file_name()) else {
        return Err(NostrError::StorageError(
            "session database path has no parent directory or no file name \
             (Rule 14: refusing to open without a canonical registry key)"
                .to_string(),
        ));
    };
    let canonical_parent = parent.canonicalize().map_err(|_| {
        NostrError::StorageError(
            "could not canonicalize the session database's parent directory \
             (Rule 14: refusing to open rather than risk two registry keys for \
              one database)"
                .to_string(),
        )
    })?;
    Ok(canonical_parent.join(name))
}

/// RAII registration of a live MLS session's database path (Security Rule 14).
///
/// Rule 14 mandates **exactly one** live `AccountDeviceSession` per
/// `session.sqlite` across *every* Dart isolate and background worker in the
/// process. A second, divergent hydrated session would run its own in-memory
/// epoch state and risk exporter-key / epoch reuse — a confidentiality loss, not
/// merely DB corruption. The concrete threat is an Android `WorkManager`
/// background isolate constructing its own `CircleManager` on the same
/// `data_dir`: Rust statics are shared across all Dart isolates in one loaded
/// `.so`, so this process-global registry catches exactly that case.
///
/// [`Self::acquire`] fails closed if the path is already registered; the guard
/// releases the path on `Drop`, so a legitimately-closed session can be reopened
/// with no false lockout.
///
/// # Cross-process scope (documented decision)
///
/// This guard is **per-process only**. A separate OS advisory lock (`flock`)
/// would add cross-process defense-in-depth, but it is deliberately NOT used:
/// (a) the identified threat — background isolates — is same-process, which this
/// registry fully covers; (b) `flock` needs a third-party crate or `unsafe`
/// (denied crate-wide) and interacts with `SQLCipher`/WAL's own OS locks on the
/// same file across the five target platforms (Linux/macOS/iOS/Android/Windows);
/// and (c) `SQLCipher` already takes its own OS-level DB lock, so a genuinely
/// separate process opening the file is already contended at the storage layer.
/// If a future requirement needs cross-process exclusion, add a `flock` on a
/// dedicated sidecar lock file here.
#[derive(Debug)]
pub struct LiveSessionGuard {
    key: PathBuf,
}

impl LiveSessionGuard {
    /// Registers `db_path` as a live session, failing closed if another live
    /// session already holds the same canonical path (Rule 14).
    ///
    /// # Errors
    ///
    /// Returns [`NostrError::StorageError`] if a live session already holds this
    /// database file, or if `db_path` cannot be reduced to a canonical registry
    /// key (see [`canonical_session_key`] — that case fails closed rather than
    /// risking two keys for one database).
    pub fn acquire(db_path: &Path) -> Result<Self> {
        let key = canonical_session_key(db_path)?;
        // A poisoned lock is benign here — the set only gains/loses PathBufs, so
        // recover the guarded set rather than propagate the panic. The guard is a
        // temporary scoped to this statement so it drops before `Self` is built.
        let inserted = live_sessions()
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .insert(key.clone());
        if inserted {
            Ok(Self { key })
        } else {
            // Logged HERE because this is the only place the refusal is still
            // greppable: every log site quotes an error's `code()`, and the one
            // production caller (`CircleManager::new`) converts to
            // `CircleError::Mls`, whose payload no rendering shows — so without
            // this line a Rule-14 violation leaves no trace a human can search
            // for. A literal and nothing else: no database path, no key, no count
            // (Security Rule 15). At `warn` so it survives the release log
            // silencer, because a second live session is a confidentiality risk,
            // not a debug curiosity.
            log::warn!("{SESSION_BUSY_MARKER}: a live MLS session already holds this database");
            // The typed variant's OWN `Display` also leads with the marker, so an
            // FFI surface that ever stops flattening to a code still carries it.
            // Code asks `is_session_live` instead of matching this prose.
            Err(NostrError::SessionBusy)
        }
    }
}

impl Drop for LiveSessionGuard {
    fn drop(&mut self) {
        live_sessions()
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove(&self.key);
    }
}

/// Keyring service identifier (reverse-DNS). Shared with `circles.db` /
/// `tiles.db` in the FFI layer so all Haven keyring items live under one
/// service.
const SERVICE_ID: &str = "com.oblivioustech.haven";

/// Keyring key identifier for the MLS session passphrase. New with the MDK
/// v0.10.4 store (`crate::storage_reset` destroys the pre-v2 id).
const MLS_DB_KEY_ID: &str = "mls.session.key.v2";

/// File name of the MLS database. New with the MDK v0.10.4 store, so a v0.9.4
/// file is never opened (`crate::storage_reset` deletes it).
const MLS_DB_FILENAME: &str = "session-v2.sqlite";

/// Configuration for the MLS session storage.
///
/// Holds the data directory and derives the `session.sqlite` path plus the
/// `SQLCipher` key from it. The actual database is opened either directly via
/// [`StorageConfig::open_encrypted_storage`] or — in production, from DM-2
/// onward — inside `AccountDeviceSession::open`, which opens the SAME file from
/// the [`database_path`](StorageConfig::database_path),
/// [`sqlcipher_key`](StorageConfig::sqlcipher_key), and
/// [`storage_options`](StorageConfig::storage_options) this config supplies
/// (a test fixture's, [`test_storage_options`](StorageConfig::test_storage_options)).
#[derive(Debug, Clone)]
pub struct StorageConfig {
    /// Directory where the MLS database (and its sidecars) live. Created on
    /// demand.
    pub data_dir: PathBuf,
}

impl StorageConfig {
    /// Creates a new storage configuration rooted at `data_dir`.
    ///
    /// The directory is created lazily when the database is opened.
    pub fn new(data_dir: impl AsRef<Path>) -> Self {
        Self {
            data_dir: data_dir.as_ref().to_path_buf(),
        }
    }

    /// Path to the MLS database file (`session-v2.sqlite`).
    #[must_use]
    pub fn database_path(&self) -> PathBuf {
        self.data_dir.join(MLS_DB_FILENAME)
    }

    /// The `storage-sqlite` options the session opens with.
    ///
    /// The defaults are exactly the hardened posture Haven wants: WAL journalling,
    /// `secure_delete`, `cipher_memory_security`, and `cipher_compatibility = 4`.
    #[must_use]
    pub fn storage_options() -> SqliteStorageOptions {
        SqliteStorageOptions::default()
    }

    /// [`Self::storage_options`] with `cipher_memory_security` off: what every
    /// test open of an MLS store uses.
    ///
    /// The setting is process-wide and one-way, and while it is on every
    /// `SQLite` allocation is `mlock`ed and scrubbed under one process-global
    /// mutex, which serialises a test binary's threads. Every other field is
    /// production's: `journal_mode` is persisted in the file.
    #[cfg(any(test, feature = "test-utils"))]
    #[must_use]
    pub fn test_storage_options() -> SqliteStorageOptions {
        SqliteStorageOptions {
            cipher_memory_security: false,
            ..Self::storage_options()
        }
    }

    /// Resolves the `SQLCipher` key for `session.sqlite`, provisioning it on first
    /// use.
    ///
    /// On first call this mints a fresh 32-byte `OsRng` passphrase, stores the
    /// raw bytes in the platform keyring under
    /// (`com.oblivioustech.haven`, `mls.session.key.v2`), and on iOS
    /// migrates the entry to `AfterFirstUnlockThisDeviceOnly` so a locked-device
    /// background wake can open the database. Subsequent calls read it back.
    ///
    /// The returned [`SqlCipherKey`] wraps a `Zeroizing<String>` and is
    /// Debug-redacted; the passphrase is never logged.
    ///
    /// # Errors
    ///
    /// Returns [`NostrError::StorageError`] if the keyring is unavailable or the
    /// key cannot be constructed.
    pub fn sqlcipher_key(&self) -> Result<SqlCipherKey> {
        let passphrase = get_or_create_passphrase(SERVICE_ID, MLS_DB_KEY_ID)?;

        // Migrate the freshly-created key's iOS access policy so a locked-device
        // background wake can read it. No-op on every other target; non-fatal
        // (the migration restores the key on any failure, so a failure here
        // leaves storage fully functional). The warning carries no key material.
        if crate::keyring_policy::ensure_db_key_after_first_unlock(SERVICE_ID, MLS_DB_KEY_ID)
            .is_err()
        {
            // Presence only: a keyring error's text can name the service and
            // account entry it failed on (Security Rule 15).
            log::warn!("MLS session DB key access-policy migration deferred");
        }

        cipher_key(passphrase.as_str())
    }

    /// Opens (or creates) the encrypted `session.sqlite` backend.
    ///
    /// Creates the data directory if missing, resolves the `SQLCipher` key via
    /// [`sqlcipher_key`](StorageConfig::sqlcipher_key), and opens the
    /// `storage-sqlite` backend with the
    /// [`test_storage_options`](StorageConfig::test_storage_options).
    ///
    /// # Single-session invariant (security F4 / Rule 14)
    ///
    /// At most ONE live handle on `session.sqlite` may exist across all isolates
    /// and processes: two opens hydrate two divergent in-memory epoch states,
    /// which risks exporter-key/epoch reuse and forward-secrecy erosion. In
    /// production (DM-2 onward) the session opens this file itself, so this is
    /// compiled for tests and test-utils builds only; do NOT call it while a
    /// session is live on the same directory.
    ///
    /// # Errors
    ///
    /// Returns [`NostrError::StorageError`] if the directory cannot be created,
    /// the keyring is unavailable, or the database cannot be opened/decrypted.
    #[cfg(any(test, feature = "test-utils"))]
    pub fn open_encrypted_storage(&self) -> Result<SqliteAccountStorage> {
        std::fs::create_dir_all(&self.data_dir)
            .map_err(|_| NostrError::StorageError("Failed to create the data directory".into()))?;

        let key = self.sqlcipher_key()?;
        crate::sqlcipher_init::ensure().map_err(|_| storage_err("initialise SQLite"))?;
        SqliteAccountStorage::open_encrypted_with_options(
            self.database_path(),
            &key,
            Self::test_storage_options(),
        )
        .map_err(super::manager::map_storage_err)
    }

    /// Creates an ephemeral, unencrypted in-memory MLS storage backend for
    /// tests.
    ///
    /// Replaces the old `MdkSqliteStorage::new_unencrypted`. The Dark Matter
    /// `SqliteAccountStorage::in_memory()` constructor is public and un-gated
    /// upstream; this feature-gated wrapper keeps the "test-only" contract on
    /// Haven's side (no keyring, no on-disk plaintext).
    ///
    /// # Errors
    ///
    /// Returns [`NostrError::StorageError`] if the in-memory database cannot be
    /// initialized.
    #[cfg(any(test, feature = "test-utils"))]
    pub fn in_memory_storage() -> Result<SqliteAccountStorage> {
        crate::sqlcipher_init::ensure().map_err(|_| storage_err("initialise SQLite"))?;
        SqliteAccountStorage::in_memory_with_options(Self::test_storage_options())
            .map_err(super::manager::map_storage_err)
    }

    /// The fixed `SQLCipher` key every keyring-free test session opens with.
    ///
    /// The ONE place [`TEST_SQLCIPHER_KEY`] is spelled into a key, so a
    /// fixture that has to reach the same database — `new_unencrypted`'s
    /// session, a fault injector, [`openmls_group_keys_for_test`] — cannot open
    /// it with a key that has silently drifted from the session's.
    ///
    /// # Errors
    ///
    /// Returns [`NostrError::StorageError`] if the key cannot be constructed.
    #[cfg(any(test, feature = "test-utils"))]
    pub fn test_sqlcipher_key() -> Result<SqlCipherKey> {
        SqlCipherKey::new(TEST_SQLCIPHER_KEY)
            .map_err(|e| NostrError::StorageError(format!("failed to build test key: {e}")))
    }
}

/// The constant key of every keyring-free test database.
///
/// Not a secret in any threat model Haven has: it protects nothing, guards no
/// user data, and exists only because the Dark Matter `storage-sqlite` backend
/// has no unencrypted mode. It is gated all the same, so no shipped build can
/// name it. `SQLCipher`'s raw-key form (`x'` + 64 hex digits + `'`), so no
/// test open pays for a passphrase's PBKDF2 derivation.
#[cfg(any(test, feature = "test-utils"))]
const TEST_SQLCIPHER_KEY: &str =
    "x'0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'";

/// One `openmls_values.group_key` — an opaque handle to one group's `OpenMLS`
/// state rows.
///
/// Opaque on purpose, and with **no `Debug`**: the value is
/// `serde_json::to_vec(openmls::group::GroupId)`, i.e. a serde encoding of a
/// real MLS group id (Security Rule 4). A `Vec<u8>` would carry the same bytes
/// while being a std type that every `{:?}` ban is written in terms of foreign
/// *named* types, so it would slip straight through. Nothing outside this
/// module can read the bytes back out; a caller compares handles and passes
/// them to [`delete_openmls_group_state_for_test`].
#[cfg(any(test, feature = "test-utils"))]
#[derive(Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct OpenMlsGroupKey(Vec<u8>);

/// Every distinct `openmls_values.group_key` in the MLS database at `db_path`.
///
/// Test-only fault injection. The engine sets a group's hydration quarantine
/// only at session open, and exposes no way to induce it — so the only honest
/// mechanism is to remove the `OpenMLS` state the next open hydrates from, on a
/// **closed** database, and reopen. Discover the victim by taking the set
/// difference across a circle creation; a difference that is not exactly one
/// key means the upstream schema or key encoding moved, and the caller must
/// fail loudly rather than delete a key it did not identify.
///
/// Mirrors the connection discipline of the in-crate `tamper_session_db`
/// fixture: a plain `rusqlite` connection, `cipher_compatibility = 4`, then the
/// key. If a table named here can no longer be found, MDK renamed it at the
/// pinned rev — the invariant under test is unchanged, only the injection needs
/// re-aiming.
///
/// # Errors
///
/// Returns [`NostrError::StorageError`] if the database cannot be opened,
/// decrypted, or read.
#[cfg(any(test, feature = "test-utils"))]
pub fn openmls_group_keys_for_test(
    db_path: &Path,
    key: &SqlCipherKey,
) -> Result<Vec<OpenMlsGroupKey>> {
    let conn = open_tamper_connection(db_path, key)?;
    let mut stmt = conn
        .prepare(
            "SELECT DISTINCT group_key FROM openmls_values
             WHERE group_key IS NOT NULL ORDER BY group_key",
        )
        .map_err(|_| storage_err("prepare the openmls_values read"))?;
    let keys = stmt
        .query_map([], |row| row.get::<_, Vec<u8>>(0).map(OpenMlsGroupKey))
        .map_err(|_| storage_err("read openmls_values"))?
        .collect::<std::result::Result<Vec<_>, _>>()
        .map_err(|_| storage_err("collect openmls_values"))?;
    Ok(keys)
}

/// The distinct labels of every `OpenMLS` value stored under no group.
///
/// That is account-level state — the MLS signing key pair, the `KeyPackage`
/// bundles — or a leaf key a staged own commit would hold outside its group
/// (MDK `storage-sqlite/src/openmls_storage/provider.rs` 183-197). Read on a
/// **closed** database, as [`openmls_group_keys_for_test`].
///
/// # Errors
///
/// Returns [`NostrError::StorageError`] if the database cannot be opened,
/// decrypted, or read.
#[cfg(any(test, feature = "test-utils"))]
pub fn ungrouped_openmls_labels_for_test(
    db_path: &Path,
    key: &SqlCipherKey,
) -> Result<Vec<String>> {
    let conn = open_tamper_connection(db_path, key)?;
    let mut stmt = conn
        .prepare("SELECT DISTINCT label FROM openmls_values WHERE group_key IS NULL ORDER BY label")
        .map_err(|_| storage_err("prepare the openmls_values read"))?;
    let labels = stmt
        .query_map([], |row| row.get::<_, Vec<u8>>(0))
        .map_err(|_| storage_err("read openmls_values"))?
        .map(|label| label.map(|bytes| String::from_utf8_lossy(&bytes).into_owned()))
        .collect::<std::result::Result<Vec<_>, _>>()
        .map_err(|_| storage_err("collect openmls_values"))?;
    Ok(labels)
}

/// Moves every `OpenMLS` state row of `group` aside, into a table of the
/// test's own in the same database.
///
/// The next open quarantines the group as
/// [`delete_openmls_group_state_for_test`] makes it, and
/// [`restore_openmls_group_state_for_test`] puts the rows back for a retry
/// to hydrate it. Run on a **closed** database.
///
/// # Errors
///
/// Returns [`NostrError::StorageError`] if the database cannot be opened,
/// decrypted, or written.
#[cfg(any(test, feature = "test-utils"))]
pub fn stash_openmls_group_state_for_test(
    db_path: &Path,
    key: &SqlCipherKey,
    group: &OpenMlsGroupKey,
) -> Result<usize> {
    let conn = open_tamper_connection(db_path, key)?;
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS haven_test_openmls_stash AS
         SELECT * FROM openmls_values WHERE 0",
    )
    .map_err(|_| storage_err("create the stash"))?;
    conn.execute(
        "INSERT INTO haven_test_openmls_stash SELECT * FROM openmls_values WHERE group_key = ?1",
        [&group.0],
    )
    .map_err(|_| storage_err("stash openmls_values"))?;
    conn.execute(
        "DELETE FROM openmls_values WHERE group_key = ?1",
        [&group.0],
    )
    .map_err(|_| storage_err("delete openmls_values"))
}

/// Puts back what [`stash_openmls_group_state_for_test`] moved aside.
///
/// The one rows-only write a test makes on a LIVE database here: the group
/// it names is quarantined, so the engine holds nothing of it in memory,
/// and MDK's retry reads it back from the store.
///
/// # Errors
///
/// Returns [`NostrError::StorageError`] if the database cannot be opened,
/// decrypted, or written.
#[cfg(any(test, feature = "test-utils"))]
pub fn restore_openmls_group_state_for_test(db_path: &Path, key: &SqlCipherKey) -> Result<usize> {
    let conn = open_tamper_connection(db_path, key)?;
    let restored = conn
        .execute(
            "INSERT INTO openmls_values SELECT * FROM haven_test_openmls_stash",
            [],
        )
        .map_err(|_| storage_err("restore openmls_values"))?;
    conn.execute_batch("DROP TABLE haven_test_openmls_stash")
        .map_err(|_| storage_err("drop the stash"))?;
    Ok(restored)
}

/// Deletes every `OpenMLS` state row belonging to `group`, returning how many
/// rows went.
///
/// The induction mechanism for hydration quarantine: the next session open finds
/// no `OpenMLS` group to load and quarantines that group for the life of the
/// session, leaving every sibling group in the same database healthy. Run it on
/// a **closed** database (Rule 14 — a live session holds its own connection and
/// its own in-memory state).
///
/// # Errors
///
/// Returns [`NostrError::StorageError`] if the database cannot be opened,
/// decrypted, or written.
#[cfg(any(test, feature = "test-utils"))]
pub fn delete_openmls_group_state_for_test(
    db_path: &Path,
    key: &SqlCipherKey,
    group: &OpenMlsGroupKey,
) -> Result<usize> {
    let conn = open_tamper_connection(db_path, key)?;
    conn.execute(
        "DELETE FROM openmls_values WHERE group_key = ?1",
        [&group.0],
    )
    .map_err(|_| storage_err("delete openmls_values"))
}

/// Marks `group_id` unrecoverable — or, with `halted` false, no longer —
/// in a **closed** database.
///
/// As MDK's convergence persists it when it halts a group
/// (`traits/src/group.rs` 65-75): how a test has a terminal circle, which no
/// event can be made to reach on cue, and one an in-place repair brought
/// back. The next open re-seeds the state from the flag.
///
/// # Errors
///
/// A redacted storage error when the database or the group cannot be read
/// or written.
#[cfg(any(test, feature = "test-utils"))]
pub fn set_group_unrecoverable_for_test(
    db_path: &Path,
    key: &SqlCipherKey,
    group_id: &cgka_traits::types::GroupId,
    halted: bool,
) -> Result<()> {
    use cgka_traits::storage::GroupStorage;
    crate::sqlcipher_init::ensure().map_err(|_| storage_err("initialise SQLite"))?;
    let store = SqliteAccountStorage::open_encrypted_with_options(
        db_path,
        key,
        StorageConfig::test_storage_options(),
    )
    .map_err(|_| storage_err("open the MLS database"))?;
    let mut group = store
        .get_group(group_id)
        .map_err(|_| storage_err("read the group"))?;
    group.unrecoverable = halted;
    store
        .put_group(&group)
        .map_err(|_| storage_err("write the group"))
}

/// Arms or disarms a `BEFORE UPDATE` abort trigger on the engine's stored
/// message table.
///
/// Test-only fault injection, and the only deterministic way to make an
/// in-flight `replay_buffered_messages` fail: the engine writes each replayed
/// message's terminal state through that table, AFTER it has already pushed the
/// decrypted content to its event buffer. With the trigger armed, a confirm /
/// rollback therefore returns `Err` with a peer location stranded in the
/// engine's buffer — the exact shape a `ForkedEpoch` mid-replay abort produces,
/// reachable without building two sibling commits.
///
/// Unlike the `openmls_values` injectors above this runs against a LIVE
/// database: the trigger has to be installed between staging a commit and
/// resolving it. Disarm it as soon as the assertion is made.
///
/// If `cgka_messages` can no longer be found, MDK renamed it at the pinned rev
/// — the invariant under test is unchanged, only the injection needs re-aiming.
///
/// # Errors
///
/// Returns [`NostrError::StorageError`] if the database cannot be opened,
/// decrypted, or written.
#[cfg(any(test, feature = "test-utils"))]
pub fn set_stored_message_write_fault_for_test(
    db_path: &Path,
    key: &SqlCipherKey,
    armed: bool,
) -> Result<()> {
    let conn = open_tamper_connection(db_path, key)?;
    let sql = if armed {
        "CREATE TRIGGER haven_stored_message_write_fault
         BEFORE UPDATE ON cgka_messages
         BEGIN SELECT RAISE(ABORT, 'injected stored-message write fault'); END;"
    } else {
        "DROP TRIGGER IF EXISTS haven_stored_message_write_fault;"
    };
    conn.execute_batch(sql)
        .map_err(|_| storage_err("set the stored-message write fault"))
}

/// [`set_stored_message_write_fault_for_test`], sparing the one stored row
/// `spared` names: every other state change in `cgka_messages` aborts.
///
/// How a resolution is made to fail in the engine's own tail — the replay of
/// what was buffered while a commit was staged, which re-states each replayed
/// row — AFTER its transaction committed, while the write Haven then makes to
/// that commit's own row still lands.
///
/// # Errors
///
/// Returns [`NostrError::StorageError`] if the database cannot be opened,
/// decrypted, or written.
#[cfg(any(test, feature = "test-utils"))]
pub fn set_stored_message_write_fault_sparing_for_test(
    db_path: &Path,
    key: &SqlCipherKey,
    spared: &[u8],
    armed: bool,
) -> Result<()> {
    let conn = open_tamper_connection(db_path, key)?;
    let sql = if armed {
        format!(
            "CREATE TRIGGER haven_stored_message_write_fault_sparing
             BEFORE UPDATE ON cgka_messages WHEN OLD.id <> X'{}'
             BEGIN SELECT RAISE(ABORT, 'injected stored-message write fault'); END;",
            hex::encode(spared)
        )
    } else {
        "DROP TRIGGER IF EXISTS haven_stored_message_write_fault_sparing;".to_owned()
    };
    conn.execute_batch(&sql)
        .map_err(|_| storage_err("set the stored-message write fault"))
}

/// Arms or disarms an abort on the write of every stored message row that
/// does not exist yet; a row written again over itself still lands.
///
/// How the engine is made to fail at the first thing it stores of a message
/// it opens — the row keyed by what the message carries, which it writes in
/// the transaction that processes the message (v0.10.4
/// `cgka-engine/src/message_processor/ingest.rs` 1207-1213) — while what it
/// had already stored is re-stated freely. Armed across a rollback it fails
/// the replay that follows the rollback's own transaction at the first
/// parked event, with nothing of that event stored; armed across the sweep
/// of a deferred row it fails that row's re-ingest.
///
/// # Errors
///
/// Returns [`NostrError::StorageError`] if the database cannot be opened,
/// decrypted, or written.
#[cfg(any(test, feature = "test-utils"))]
pub fn set_new_stored_message_fault_for_test(
    db_path: &Path,
    key: &SqlCipherKey,
    armed: bool,
) -> Result<()> {
    let conn = open_tamper_connection(db_path, key)?;
    let sql = if armed {
        "CREATE TRIGGER haven_new_stored_message_fault
         BEFORE INSERT ON cgka_messages
         WHEN NOT EXISTS (SELECT 1 FROM cgka_messages WHERE id = NEW.id)
         BEGIN SELECT RAISE(ABORT, 'injected new-stored-message fault'); END;"
    } else {
        "DROP TRIGGER IF EXISTS haven_new_stored_message_fault;"
    };
    conn.execute_batch(sql)
        .map_err(|_| storage_err("set the new-stored-message fault"))
}

/// Arms or disarms an abort on every first storing of the one event `row`
/// names.
///
/// Of that event and no other: its row, whichever shape the engine gives it,
/// and the engine's record that it processed it.
/// [`set_new_stored_message_fault_for_test`] for a single event, so that
/// everything else the engine stores — this device's own commits among it —
/// goes on landing while that event's ingest fails with nothing of it
/// recorded, however often it is handed over.
///
/// # Errors
///
/// Returns [`NostrError::StorageError`] if the database cannot be opened,
/// decrypted, or written.
#[cfg(any(test, feature = "test-utils"))]
pub fn set_new_stored_message_fault_naming_for_test(
    db_path: &Path,
    key: &SqlCipherKey,
    row: &[u8],
    armed: bool,
) -> Result<()> {
    let conn = open_tamper_connection(db_path, key)?;
    let sql = if armed {
        format!(
            "CREATE TRIGGER haven_new_stored_message_fault_naming
             BEFORE INSERT ON cgka_messages WHEN NEW.id = X'{id}'
             BEGIN SELECT RAISE(ABORT, 'injected new-stored-message fault'); END;
             CREATE TRIGGER haven_processed_id_fault_naming
             BEFORE INSERT ON cgka_processed_transport_ids WHEN NEW.id = X'{id}'
             BEGIN SELECT RAISE(ABORT, 'injected processed-id fault'); END;",
            id = hex::encode(row)
        )
    } else {
        "DROP TRIGGER IF EXISTS haven_new_stored_message_fault_naming;
         DROP TRIGGER IF EXISTS haven_processed_id_fault_naming;"
            .to_owned()
    };
    conn.execute_batch(&sql)
        .map_err(|_| storage_err("set the new-stored-message fault"))
}

/// Arms or disarms an abort on every state change of the one stored row
/// `row` names, and of no other.
///
/// How the engine's replay of what it parked behind a commit is made to fail
/// at one row AFTER it has opened that row's message and stored what it
/// held: the last thing the replay does with a parked row is re-state it
/// (v0.10.4 `cgka-engine/src/message_processor/mod.rs` 3661-3663), and when
/// that write fails the loop ends there with every row behind it still
/// parked (3698-3706).
///
/// # Errors
///
/// Returns [`NostrError::StorageError`] if the database cannot be opened,
/// decrypted, or written.
#[cfg(any(test, feature = "test-utils"))]
pub fn set_stored_message_write_fault_naming_for_test(
    db_path: &Path,
    key: &SqlCipherKey,
    row: &[u8],
    armed: bool,
) -> Result<()> {
    let conn = open_tamper_connection(db_path, key)?;
    let sql = if armed {
        format!(
            "CREATE TRIGGER haven_stored_message_write_fault_naming
             BEFORE UPDATE ON cgka_messages WHEN OLD.id = X'{}'
             BEGIN SELECT RAISE(ABORT, 'injected stored-message write fault'); END;",
            hex::encode(row)
        )
    } else {
        "DROP TRIGGER IF EXISTS haven_stored_message_write_fault_naming;".to_owned()
    };
    conn.execute_batch(&sql)
        .map_err(|_| storage_err("set the stored-message write fault"))
}

/// Arms or disarms an abort on the deletion of every stored message row.
///
/// How MDK's `release_message_for_replay` is made to fail as it does when
/// its receipt journal is full or the store errs (v0.10.4
/// `storage-sqlite/src/storage/messages.rs` 267-312): the release is one
/// transaction that ends in the row's deletion, so the row stands.
///
/// # Errors
///
/// Returns [`NostrError::StorageError`] if the database cannot be opened,
/// decrypted, or written.
#[cfg(any(test, feature = "test-utils"))]
pub fn set_stored_message_delete_fault_for_test(
    db_path: &Path,
    key: &SqlCipherKey,
    armed: bool,
) -> Result<()> {
    let conn = open_tamper_connection(db_path, key)?;
    let sql = if armed {
        "CREATE TRIGGER haven_stored_message_delete_fault
         BEFORE DELETE ON cgka_messages
         BEGIN SELECT RAISE(ABORT, 'injected stored-message delete fault'); END;"
    } else {
        "DROP TRIGGER IF EXISTS haven_stored_message_delete_fault;"
    };
    conn.execute_batch(sql)
        .map_err(|_| storage_err("set the stored-message delete fault"))
}

/// Makes each of the next `writes` peel attempts outlast MDK's background
/// advance budget, as on a device too slow to try 64 rows an advance.
///
/// An attempt rewrites its parked row's deferred-peel lifecycle (`PeelDeferred`
/// is state 6, `storage-sqlite/src/codec.rs:267`); each armed rewrite costs more
/// than `BACKGROUND_CONVERGENCE_BUDGET_MS` (500 ms), so the advance it lands in
/// ends after that row (`message_processor/mod.rs:1928-1934`). The cost is
/// `SQLite`'s own work, a counted cross join, as no trigger can sleep.
///
/// # Errors
///
/// Returns [`NostrError::StorageError`] if the database cannot be opened,
/// decrypted, or written.
#[cfg(any(test, feature = "test-utils"))]
pub fn slow_deferred_peel_writes_for_test(
    db_path: &Path,
    key: &SqlCipherKey,
    writes: u32,
) -> Result<()> {
    let conn = open_tamper_connection(db_path, key)?;
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS haven_test_burn (x INTEGER);
         DELETE FROM haven_test_burn;
         WITH RECURSIVE r(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM r WHERE x < 300)
         INSERT INTO haven_test_burn SELECT x FROM r;
         CREATE TABLE IF NOT EXISTS haven_test_slow_writes (n INTEGER);
         DELETE FROM haven_test_slow_writes;
         CREATE TRIGGER IF NOT EXISTS haven_test_slow_peel_write
         BEFORE UPDATE OF deferred_peel ON cgka_messages
         WHEN OLD.state = 6 AND NEW.state = 6
             AND (SELECT n FROM haven_test_slow_writes) > 0
         BEGIN
             UPDATE haven_test_slow_writes SET n = n - 1;
             SELECT count(*) FROM haven_test_burn a, haven_test_burn b, haven_test_burn c;
         END;",
    )
    .and_then(|()| {
        conn.execute(
            "INSERT INTO haven_test_slow_writes (n) VALUES (?1)",
            [writes],
        )
    })
    .map(|_| ())
    .map_err(|_| storage_err("arm the slow deferred-peel writes"))
}

/// How many of the writes [`slow_deferred_peel_writes_for_test`] armed are
/// still to come.
///
/// # Errors
///
/// Returns [`NostrError::StorageError`] if the database cannot be opened,
/// decrypted, or read, or nothing was armed.
#[cfg(any(test, feature = "test-utils"))]
pub fn slow_deferred_peel_writes_left_for_test(db_path: &Path, key: &SqlCipherKey) -> Result<u32> {
    open_tamper_connection(db_path, key)?
        .query_row("SELECT n FROM haven_test_slow_writes", [], |row| row.get(0))
        .map_err(|_| storage_err("read the slow deferred-peel writes"))
}

/// Changes one character of the signature of the event the stored row `row`
/// keeps, leaving everything else of the row as it was. Returns whether a
/// signature was found to change.
///
/// What nothing but a damaged store can produce — every event the engine is
/// handed has been verified by the relay client (Security Rule 16) — and
/// what Haven must still not take for an event when it reads the row back.
///
/// # Errors
///
/// Returns [`NostrError::StorageError`] if the database cannot be opened,
/// decrypted, or written.
#[cfg(any(test, feature = "test-utils"))]
pub fn forge_stored_event_signature_for_test(
    db_path: &Path,
    key: &SqlCipherKey,
    row: &[u8],
) -> Result<bool> {
    const FIELD: &[u8] = b"\"sig\":\"";
    let conn = open_tamper_connection(db_path, key)?;
    let mut payload: Vec<u8> = conn
        .query_row(
            "SELECT payload FROM cgka_messages WHERE id = ?1",
            [row],
            |found| found.get(0),
        )
        .map_err(|_| storage_err("read the stored message"))?;
    let Some(at) = payload
        .windows(FIELD.len())
        .position(|window| window == FIELD)
        .map(|at| at + FIELD.len())
    else {
        return Ok(false);
    };
    payload[at] = if payload[at] == b'0' { b'1' } else { b'0' };
    conn.execute(
        "UPDATE cgka_messages SET payload = ?1 WHERE id = ?2",
        rusqlite::params![payload, row],
    )
    .map_err(|_| storage_err("write the stored message"))?;
    Ok(true)
}

/// Makes Haven's retirement of one commit's stored row fail and nothing
/// else: the write that marks the row `commit` names `Failed` aborts, while
/// the engine may still give that row any other state.
///
/// `3` is `MessageState::Failed` as `storage-sqlite` stores it
/// (v0.10.4 `storage-sqlite/src/codec.rs` 264). Were MDK to renumber it, the
/// retirement would simply succeed and the test that armed this would say so.
///
/// # Errors
///
/// Returns [`NostrError::StorageError`] if the database cannot be opened,
/// decrypted, or written.
#[cfg(any(test, feature = "test-utils"))]
pub fn set_commit_retirement_fault_for_test(
    db_path: &Path,
    key: &SqlCipherKey,
    commit: &[u8],
    armed: bool,
) -> Result<()> {
    let conn = open_tamper_connection(db_path, key)?;
    let sql = if armed {
        format!(
            "CREATE TRIGGER haven_commit_retirement_fault
             BEFORE UPDATE ON cgka_messages WHEN OLD.id = X'{}' AND NEW.state = 3
             BEGIN SELECT RAISE(ABORT, 'injected commit-retirement fault'); END;",
            hex::encode(commit)
        )
    } else {
        "DROP TRIGGER IF EXISTS haven_commit_retirement_fault;".to_owned()
    };
    conn.execute_batch(&sql)
        .map_err(|_| storage_err("set the commit-retirement fault"))
}

/// An engine write [`set_engine_write_fault_for_test`] can make fail.
#[cfg(any(test, feature = "test-utils"))]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EngineWrite {
    /// Haven's acknowledgement of application outputs: a delete from
    /// `pending_application_events`.
    AcknowledgeOutputs,
    /// `forget_group_local`: its insert into `locally_forgotten_groups`.
    ForgetGroup,
    /// `put_outbound_fanout`: its upsert into `cgka_outbound_fanout`, whose
    /// insert trigger fires whether or not the row exists.
    FanoutPut,
    /// `delete_outbound_fanout`: its delete from `cgka_outbound_fanout`.
    FanoutDelete,
    /// The plain rollback of a commit the engine keeps an own-commit intent
    /// for (a removal, an invite, a settings change): its rewind transaction
    /// deletes that intent first, so the whole rollback fails with nothing
    /// rewound.
    OwnCommitIntentDelete,
    /// The retirement of a queued change
    /// (`confirm_regenerated_queued_intent`): its delete from
    /// `cgka_queued_outbound`.
    QueuedIntentDelete,
}

#[cfg(any(test, feature = "test-utils"))]
impl EngineWrite {
    const fn target(self) -> (&'static str, &'static str) {
        match self {
            Self::AcknowledgeOutputs => ("DELETE", "pending_application_events"),
            Self::ForgetGroup => ("INSERT", "locally_forgotten_groups"),
            Self::FanoutPut => ("INSERT", "cgka_outbound_fanout"),
            Self::FanoutDelete => ("DELETE", "cgka_outbound_fanout"),
            Self::OwnCommitIntentDelete => ("DELETE", "cgka_own_commit_intents"),
            Self::QueuedIntentDelete => ("DELETE", "cgka_queued_outbound"),
        }
    }
}

/// Arms (or disarms) an abort trigger on one engine write, so the one write a
/// test means to break fails while every other lands.
///
/// Like [`set_stored_message_write_fault_for_test`] it runs against a LIVE
/// database and is disarmed as soon as the assertion is made. If the table can
/// no longer be found, MDK renamed it at the pinned rev — re-aim the injection.
///
/// # Errors
///
/// Returns [`NostrError::StorageError`] if the database cannot be opened,
/// decrypted, or written.
#[cfg(any(test, feature = "test-utils"))]
pub fn set_engine_write_fault_for_test(
    db_path: &Path,
    key: &SqlCipherKey,
    write: EngineWrite,
    armed: bool,
) -> Result<()> {
    let conn = open_tamper_connection(db_path, key)?;
    let (op, table) = write.target();
    let sql = if armed {
        format!(
            "CREATE TRIGGER haven_write_fault_{table}_{op} BEFORE {op} ON {table}
             BEGIN SELECT RAISE(ABORT, 'injected write fault'); END;"
        )
    } else {
        format!("DROP TRIGGER IF EXISTS haven_write_fault_{table}_{op};")
    };
    conn.execute_batch(&sql)
        .map_err(|_| storage_err("set the engine write fault"))
}

/// Arms (or disarms) an abort on every Welcome delivery record written past
/// the next `landing`.
///
/// The records MDK stores now, and `landing` more, land; the one after
/// fails. How a hand-over is stopped part-way.
///
/// # Errors
///
/// Returns [`NostrError::StorageError`] if the database cannot be opened,
/// decrypted, read or written.
#[cfg(any(test, feature = "test-utils"))]
pub fn set_welcome_record_write_fault_for_test(
    db_path: &Path,
    key: &SqlCipherKey,
    landing: usize,
    armed: bool,
) -> Result<()> {
    let conn = open_tamper_connection(db_path, key)?;
    let sql = if armed {
        let stored: i64 = conn
            .query_row("SELECT COUNT(*) FROM cgka_transport_fanout", [], |row| {
                row.get(0)
            })
            .map_err(|_| storage_err("count the Welcome records"))?;
        format!(
            "CREATE TRIGGER haven_welcome_record_fault BEFORE INSERT ON cgka_transport_fanout
             WHEN (SELECT COUNT(*) FROM cgka_transport_fanout) >= {}
             BEGIN SELECT RAISE(ABORT, 'injected write fault'); END;",
            usize::try_from(stored).unwrap_or(0) + landing
        )
    } else {
        "DROP TRIGGER IF EXISTS haven_welcome_record_fault;".to_owned()
    };
    conn.execute_batch(&sql)
        .map_err(|_| storage_err("set the Welcome record write fault"))
}

/// Arms or disarms an abort on the write of one epoch's retained anchor: the
/// snapshot the engine takes of a group as it stands at `epoch`.
///
/// How a confirm is made to fail AFTER its durable transaction: the engine
/// retains the anchor of the epoch a commit leaves before it merges, and the
/// anchor of the epoch it reaches once the merge has committed and before it
/// leaves `PendingPublish` (v0.10.4 `cgka-engine/src/publish.rs` 105-107,
/// 260-272). Arm it for the epoch the commit reaches.
///
/// The name is MDK's (`cgka-engine/src/openmls_projection.rs`
/// `retained_anchor_snapshot_name`); were it to change, the confirm would
/// simply succeed and the test that armed this would say so.
///
/// # Errors
///
/// Returns [`NostrError::StorageError`] if the database cannot be opened,
/// decrypted, or written.
#[cfg(any(test, feature = "test-utils"))]
pub fn set_epoch_anchor_write_fault_for_test(
    db_path: &Path,
    key: &SqlCipherKey,
    epoch: u64,
    armed: bool,
) -> Result<()> {
    let conn = open_tamper_connection(db_path, key)?;
    let sql = if armed {
        format!(
            "CREATE TRIGGER haven_epoch_anchor_write_fault
             BEFORE INSERT ON cgka_group_snapshots
             WHEN NEW.name = 'openmls-retained-anchor-{epoch}'
             BEGIN SELECT RAISE(ABORT, 'injected epoch-anchor write fault'); END;"
        )
    } else {
        "DROP TRIGGER IF EXISTS haven_epoch_anchor_write_fault;".to_owned()
    };
    conn.execute_batch(&sql)
        .map_err(|_| storage_err("set the epoch-anchor write fault"))
}

/// Arms or disarms an abort on every write of a fanout row whose stored
/// record contains `needle` — a relay host, say — and on no other.
///
/// How one write of a row is failed while another of the same row lands: a
/// record frozen for no relay does not name one, the same record once it has
/// been given its relays does.
///
/// # Errors
///
/// Returns [`NostrError::StorageError`] if the database cannot be opened,
/// decrypted, or written.
#[cfg(any(test, feature = "test-utils"))]
pub fn set_fanout_write_fault_naming_for_test(
    db_path: &Path,
    key: &SqlCipherKey,
    needle: &str,
    armed: bool,
) -> Result<()> {
    let conn = open_tamper_connection(db_path, key)?;
    let sql = if armed {
        format!(
            "CREATE TRIGGER haven_fanout_write_fault_naming
             BEFORE INSERT ON cgka_outbound_fanout
             WHEN instr(NEW.record, X'{}') > 0
             BEGIN SELECT RAISE(ABORT, 'injected fanout write fault'); END;",
            hex::encode(needle)
        )
    } else {
        "DROP TRIGGER IF EXISTS haven_fanout_write_fault_naming;".to_owned()
    };
    conn.execute_batch(&sql)
        .map_err(|_| storage_err("set the fanout write fault"))
}

/// How many outer transport ids the engine holds as processed for `group`.
///
/// Test-only read. The engine keeps one `cgka_processed_transport_ids` row per
/// peeled wrapper for the life of its group (MDK v0.10.4
/// `storage-sqlite/src/migrations/0058_processed_transport_ids.rs`), prunes
/// none and exposes no count, so this is the only instrument that can watch
/// the table grow (`docs/MDK_UPSTREAM_TRACKER.md` T-DEDUPE-GROWTH). It only
/// reads, so a live database is fine. The count is compared in process, never
/// rendered.
///
/// # Errors
///
/// Returns [`NostrError::StorageError`] if the database cannot be opened,
/// decrypted, or read.
#[cfg(any(test, feature = "test-utils"))]
pub fn processed_transport_id_count_for_test(
    db_path: &Path,
    key: &SqlCipherKey,
    group: &cgka_traits::types::GroupId,
) -> Result<usize> {
    let conn = open_tamper_connection(db_path, key)?;
    conn.query_row(
        "SELECT COUNT(*) FROM cgka_processed_transport_ids WHERE group_id = ?1",
        [group.as_slice()],
        |row| row.get::<_, i64>(0),
    )
    .ok()
    .and_then(|rows| usize::try_from(rows).ok())
    .ok_or_else(|| storage_err("count processed transport ids"))
}

/// How many rows MDK's journal of released transport receipts holds, and
/// how many its account projection does.
///
/// Test-only read. `MessageStorage::release_message_for_replay` journals a
/// receipt for each row it releases only where the account projection has a
/// row — a host of MDK's own — and fails once that journal holds 8 192 of
/// them (v0.10.4 `storage-sqlite/src/storage/messages.rs` 267-303). Haven
/// has no such host and consumes no receipt, so both must read zero.
///
/// # Errors
///
/// Returns [`NostrError::StorageError`] if the database cannot be opened,
/// decrypted, or read.
#[cfg(any(test, feature = "test-utils"))]
pub fn released_receipts_and_account_rows_for_test(
    db_path: &Path,
    key: &SqlCipherKey,
) -> Result<(usize, usize)> {
    let conn = open_tamper_connection(db_path, key)?;
    let count = |table: &str| {
        conn.query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |row| {
            row.get::<_, i64>(0)
        })
        .ok()
        .and_then(|rows| usize::try_from(rows).ok())
        .ok_or_else(|| storage_err("count an MDK table"))
    };
    Ok((
        count("cgka_released_transport_receipts")?,
        count("account_state")?,
    ))
}

/// A second plain `rusqlite` connection onto an MLS database, keyed the way
/// `storage-sqlite` keys its own.
///
/// The `openmls_values` injectors above require the database to be CLOSED — they
/// delete state a live session holds in memory, so a live one would not see the
/// deletion and would write its cached copy back. The stored-message write
/// fault is the opposite: it is only useful against a LIVE session, because the
/// call it has to break is one the engine is in the middle of. `SQLite` permits
/// both; which one a caller needs is the caller's contract, not this
/// function's.
#[cfg(any(test, feature = "test-utils"))]
fn open_tamper_connection(db_path: &Path, key: &SqlCipherKey) -> Result<rusqlite::Connection> {
    crate::sqlcipher_init::ensure().map_err(|_| storage_err("initialise SQLite"))?;
    let conn =
        rusqlite::Connection::open(db_path).map_err(|_| storage_err("open the MLS database"))?;
    conn.pragma_update(None, "cipher_compatibility", 4i64)
        .map_err(|_| storage_err("set cipher compatibility"))?;
    conn.pragma_update(None, "key", key.as_secret_str())
        .map_err(|_| storage_err("apply the SQLCipher key"))?;
    Ok(conn)
}

/// Counts the writes to the fanout table since the last call.
///
/// Every insert, update and delete from the first call on: how a test
/// measures what a send costs the store.
///
/// # Errors
///
/// Returns [`NostrError::StorageError`] if the database cannot be opened or
/// the count cannot be kept.
#[cfg(any(test, feature = "test-utils"))]
pub fn fanout_writes_for_test(db_path: &Path, key: &SqlCipherKey) -> Result<usize> {
    let conn = open_tamper_connection(db_path, key)?;
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS haven_test_fanout_writes (n INTEGER);
         CREATE TRIGGER IF NOT EXISTS haven_test_fanout_insert AFTER INSERT ON cgka_outbound_fanout
         BEGIN INSERT INTO haven_test_fanout_writes VALUES (1); END;
         CREATE TRIGGER IF NOT EXISTS haven_test_fanout_update AFTER UPDATE ON cgka_outbound_fanout
         BEGIN INSERT INTO haven_test_fanout_writes VALUES (1); END;
         CREATE TRIGGER IF NOT EXISTS haven_test_fanout_delete AFTER DELETE ON cgka_outbound_fanout
         BEGIN INSERT INTO haven_test_fanout_writes VALUES (1); END;",
    )
    .map_err(|_| storage_err("count fanout writes"))?;
    let counted: i64 = conn
        .query_row("SELECT COUNT(*) FROM haven_test_fanout_writes", [], |row| {
            row.get(0)
        })
        .map_err(|_| storage_err("read the fanout write count"))?;
    conn.execute_batch("DELETE FROM haven_test_fanout_writes")
        .map_err(|_| storage_err("reset the fanout write count"))?;
    Ok(usize::try_from(counted).unwrap_or(usize::MAX))
}

/// Makes every read of a group's record fail (`on`), or succeed again.
///
/// The table is set aside under another name, so the engine's own statement
/// errs as it would on a store it cannot read.
///
/// # Errors
///
/// Returns [`NostrError::StorageError`] if the database cannot be opened or
/// the table cannot be renamed.
#[cfg(any(test, feature = "test-utils"))]
pub fn set_group_read_fault_for_test(db_path: &Path, key: &SqlCipherKey, on: bool) -> Result<()> {
    let conn = open_tamper_connection(db_path, key)?;
    let (from, to) = if on {
        ("cgka_groups", "cgka_groups_set_aside")
    } else {
        ("cgka_groups_set_aside", "cgka_groups")
    };
    conn.execute_batch(&format!("ALTER TABLE {from} RENAME TO {to}"))
        .map_err(|_| storage_err("set the group table aside"))
}

/// Makes every read of a stored message fail (`on`), or succeed again, as
/// [`set_group_read_fault_for_test`] does for group records.
///
/// # Errors
///
/// Returns [`NostrError::StorageError`] if the database cannot be opened or
/// the table cannot be renamed.
#[cfg(any(test, feature = "test-utils"))]
pub fn set_message_read_fault_for_test(db_path: &Path, key: &SqlCipherKey, on: bool) -> Result<()> {
    let conn = open_tamper_connection(db_path, key)?;
    let (from, to) = if on {
        ("cgka_messages", "cgka_messages_set_aside")
    } else {
        ("cgka_messages_set_aside", "cgka_messages")
    };
    conn.execute_batch(&format!("ALTER TABLE {from} RENAME TO {to}"))
        .map_err(|_| storage_err("set the message table aside"))
}

/// Makes every read of a stored fanout row fail (`on`), or succeed again, as
/// [`set_group_read_fault_for_test`] does for group records.
///
/// # Errors
///
/// Returns [`NostrError::StorageError`] if the database cannot be opened or
/// the table cannot be renamed.
#[cfg(any(test, feature = "test-utils"))]
pub fn set_fanout_read_fault_for_test(db_path: &Path, key: &SqlCipherKey, on: bool) -> Result<()> {
    let conn = open_tamper_connection(db_path, key)?;
    let (from, to) = if on {
        ("cgka_outbound_fanout", "cgka_outbound_fanout_set_aside")
    } else {
        ("cgka_outbound_fanout_set_aside", "cgka_outbound_fanout")
    };
    conn.execute_batch(&format!("ALTER TABLE {from} RENAME TO {to}"))
        .map_err(|_| storage_err("set the fanout table aside"))
}

/// Marks this device's copy of `group_id` removed in MDK's own group record,
/// leaving the epoch where it stands.
///
/// The field MDK's own tests write (`cgka-engine/src/group_authority.rs`
/// 213, 263). No engine path reaches a removed
/// copy that is still stable at an epoch a live seal used; this is how the
/// clause that reads it is held. The record is MDK's JSON, rewritten with
/// that one field changed.
///
/// # Errors
///
/// Returns a storage error naming the step that failed.
#[cfg(any(test, feature = "test-utils"))]
pub fn mark_group_removed_for_test(
    db_path: &Path,
    key: &SqlCipherKey,
    group_id: &cgka_traits::types::GroupId,
) -> Result<()> {
    use rusqlite::OptionalExtension as _;
    let conn = open_tamper_connection(db_path, key)?;
    let record: Vec<u8> = conn
        .query_row(
            "SELECT record FROM cgka_groups WHERE id = ?1",
            [group_id.as_slice()],
            |row| row.get(0),
        )
        .optional()
        .map_err(|_| storage_err("read the group record"))?
        .ok_or_else(|| storage_err("find the group record"))?;
    let mut group: serde_json::Value =
        serde_json::from_slice(&record).map_err(|_| storage_err("decode the group record"))?;
    group["removed"] = serde_json::Value::Bool(true);
    let record = serde_json::to_vec(&group).map_err(|_| storage_err("encode the group record"))?;
    conn.execute(
        "UPDATE cgka_groups SET record = ?2 WHERE id = ?1",
        rusqlite::params![group_id.as_slice(), record],
    )
    .map(|_| ())
    .map_err(|_| storage_err("write the group record"))
}

/// A storage error naming what failed and nothing else.
///
/// The `rusqlite` cause is dropped deliberately rather than redacted: its
/// message can quote the bound values of the statement that failed, and on this
/// table those are serde-encoded MLS group ids (Security Rule 15).
#[cfg(any(test, feature = "test-utils"))]
fn storage_err(doing: &str) -> NostrError {
    NostrError::StorageError(format!("failed to {doing}"))
}

/// Reads the MLS DB passphrase from the keyring, minting it on first use.
///
/// The keyring holds the RAW 32-byte secret; the returned passphrase is its
/// lowercase-hex encoding. Both the raw bytes and the hex string are
/// `Zeroizing`.
/// `as_str()` copies into a fresh String that `SqlCipherKey::new` moves into its
/// own `Zeroizing<String>`; the caller's passphrase is zeroized on drop.
fn cipher_key(passphrase: &str) -> Result<SqlCipherKey> {
    SqlCipherKey::new(passphrase).map_err(super::manager::map_storage_err)
}

fn get_or_create_passphrase(service: &str, key_id: &str) -> Result<Zeroizing<String>> {
    let entry = keyring_core::Entry::new(service, key_id)
        .map_err(|_| NostrError::StorageError("keyring unavailable".to_string()))?;

    match entry.get_secret() {
        Ok(secret_bytes) => {
            let bytes = Zeroizing::new(secret_bytes);
            Ok(Zeroizing::new(hex::encode(bytes.as_slice())))
        }
        Err(keyring_core::Error::NoEntry) => {
            let mut key_bytes = Zeroizing::new([0u8; 32]);
            OsRng.fill_bytes(key_bytes.as_mut());
            entry.set_secret(key_bytes.as_ref()).map_err(|_| {
                NostrError::StorageError("failed to persist MLS DB key".to_string())
            })?;
            Ok(Zeroizing::new(hex::encode(key_bytes.as_ref())))
        }
        Err(_) => Err(NostrError::StorageError(
            "failed to read MLS DB key from keyring".to_string(),
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::env;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::sync::Once;

    static TEST_COUNTER: AtomicU64 = AtomicU64::new(0);

    #[test]
    fn an_unusable_key_is_reported_by_kind_alone() {
        let Err(NostrError::StorageError(payload)) = cipher_key("") else {
            panic!("an empty passphrase is no key");
        };
        assert!(
            !payload.contains("SQLCipher") && !payload.contains("empty"),
            "the engine's own error prose stays out of the error: {payload}"
        );
    }
    static MOCK_STORE: Once = Once::new();

    /// Installs the in-memory mock keyring store for the test binary.
    ///
    /// `keyring_core::set_default_store` is a last-wins `RwLock` swap, so this is
    /// safe even if another test module (e.g. `keyring_policy`) also installs a
    /// mock store; every test below uses a unique service/key id, so a shared
    /// store never causes cross-test interference.
    fn install_mock_store() {
        MOCK_STORE.call_once(|| {
            keyring_core::set_default_store(
                keyring_core::mock::Store::new().expect("mock store creation never fails"),
            );
        });
    }

    fn unique_temp_dir() -> PathBuf {
        let id = TEST_COUNTER.fetch_add(1, Ordering::SeqCst);
        env::temp_dir().join(format!(
            "haven_mls_storage_test_{}_{}",
            std::process::id(),
            id
        ))
    }

    fn unique_key_id(tag: &str) -> String {
        let id = TEST_COUNTER.fetch_add(1, Ordering::SeqCst);
        format!("mls.test.{tag}.{}.{id}", std::process::id())
    }

    // -----------------------------------------------------------------------
    // LiveSessionGuard / canonical_session_key (Security Rule 14).
    //
    // This module previously had NO direct coverage of the guard — the only
    // Rule-14 test lived one level up in `mls::manager` and exercised it through
    // a full `SessionManager::new_unencrypted`. These pin the registry itself,
    // and in particular the fail-CLOSED behaviour of the key derivation, whose
    // fail-open predecessor could hand two keys to one database.
    // -----------------------------------------------------------------------

    #[test]
    fn guard_rejects_a_second_acquire_and_frees_the_path_on_drop() {
        let dir = tempfile::tempdir().expect("tempdir");
        let db = dir.path().join("session.sqlite");

        let first = LiveSessionGuard::acquire(&db).expect("first acquire");
        assert!(
            LiveSessionGuard::acquire(&db).is_err(),
            "Rule 14: a second live session on the same DB must fail closed"
        );

        drop(first);
        // Re-acquirable after the guard drops, or a legitimately-closed session
        // would lock the database out for the rest of the process.
        drop(LiveSessionGuard::acquire(&db).expect("re-acquire after drop"));
    }

    #[test]
    fn busy_error_stays_greppable_after_the_string_flattening_ffi_does() {
        // The marker's only job is diagnosability, so pin the string form rather
        // than the variant: this is the rendering an FFI surface that flattens
        // `Display` would carry. (What a human greps in practice is the `warn!`
        // at the refusal — pinned by `session_busy_refusal_is_logged_once_with_no_identifier`
        // in `tests/session_busy_marker_logged.rs`.) Searched for as a substring
        // rather than a prefix, because where the marker sits in the sentence is
        // `SessionBusy`'s wording to change; only its presence is the contract.
        let dir = tempfile::tempdir().expect("tempdir");
        let db = dir.path().join("session.sqlite");
        let _held = LiveSessionGuard::acquire(&db).expect("first acquire");

        let flattened = LiveSessionGuard::acquire(&db)
            .expect_err("second acquire must fail")
            .to_string();

        assert!(
            flattened.contains(SESSION_BUSY_MARKER),
            "the already-live failure must stay identifiable in a log: {flattened}"
        );
    }

    #[test]
    fn is_session_live_tracks_the_guard_and_is_not_a_constant() {
        // Both directions in one test, because either alone is satisfiable by a
        // function that ignores its argument.
        let dir = tempfile::tempdir().expect("tempdir");
        let db = dir.path().join("session.sqlite");

        assert!(
            !is_session_live(&db).expect("query before acquire"),
            "no session has been opened yet"
        );
        let held = LiveSessionGuard::acquire(&db).expect("acquire");
        assert!(
            is_session_live(&db).expect("query while held"),
            "the registry must report the live session the FGS is contending with"
        );
        drop(held);
        assert!(
            !is_session_live(&db).expect("query after drop"),
            "a released guard must not leave the database looking permanently \
             busy — that would make recovery unreachable forever"
        );
    }

    #[test]
    fn is_session_live_answers_per_database_not_globally() {
        // A global "any session live" answer would tell the caller to reclaim
        // over an unrelated database.
        let a = tempfile::tempdir().expect("tempdir a");
        let b = tempfile::tempdir().expect("tempdir b");
        let db_a = a.path().join("session.sqlite");
        let db_b = b.path().join("session.sqlite");

        let _held_a = LiveSessionGuard::acquire(&db_a).expect("acquire a");
        assert!(is_session_live(&db_a).expect("a is live"));
        assert!(
            !is_session_live(&db_b).expect("b is not live"),
            "holding one database must not report a different one as busy"
        );
    }

    #[test]
    fn is_session_live_fails_closed_rather_than_reporting_not_live() {
        // Mirrors `acquire`: an underivable key must surface as an error. `false`
        // would be a fail-OPEN answer ("nothing is live, go ahead"), which is the
        // wrong default for a question asked in order to decide about recovery.
        let dir = tempfile::tempdir().expect("tempdir");
        let missing = dir.path().join("does-not-exist").join("session.sqlite");

        assert!(
            is_session_live(&missing).is_err(),
            "a non-canonicalizable path must error, never answer `false`"
        );
    }

    #[test]
    fn remote_authored_text_cannot_forge_a_live_session() {
        // The reason this is a registry lookup and not a substring test over an
        // error string. A circle admin controls the group's routing relays, and
        // the live-sync relay gate formats the offending URL into its error —
        // so a relay of `ws://host/HAVEN_E_SESSION_BUSY` yields an unrelated
        // error carrying the marker verbatim. Redaction does not strip it:
        // `redact_hex_sequences` only collapses long hex runs.
        //
        // Assert on the actual redactor rather than a hand-written string, so
        // this keeps testing the real sanitizer if it changes.
        let hostile = crate::util::redact_hex_sequences(
            "plaintext ws:// not allowed for the live-sync engine: \
             ws://evil.example/HAVEN_E_SESSION_BUSY",
        );
        assert!(
            hostile.contains(SESSION_BUSY_MARKER),
            "precondition: the marker survives redaction, which is exactly why \
             classifying error prose would be remotely influenceable"
        );

        // The supported query is unaffected: it never reads a message at all.
        let dir = tempfile::tempdir().expect("tempdir");
        let db = dir.path().join("session.sqlite");
        assert!(
            !is_session_live(&db).expect("query"),
            "no error string can make the registry claim a session is live"
        );
    }

    #[test]
    fn guard_allows_distinct_databases_concurrently() {
        let a = tempfile::tempdir().expect("tempdir a");
        let b = tempfile::tempdir().expect("tempdir b");

        let _ga = LiveSessionGuard::acquire(&a.path().join("session.sqlite")).expect("acquire a");
        let _gb = LiveSessionGuard::acquire(&b.path().join("session.sqlite")).expect("acquire b");
    }

    #[test]
    fn two_spellings_of_one_database_collide_on_a_single_key() {
        // THE property the registry exists for. If these ever resolve to
        // different keys, both acquires succeed and two `AccountDeviceSession`s
        // hydrate from one file — the epoch/generation reuse Rule 14 prevents.
        let dir = tempfile::tempdir().expect("tempdir");
        let nested = dir.path().join("nested");
        std::fs::create_dir(&nested).expect("create nested");

        let direct = nested.join("session.sqlite");
        let indirect = dir
            .path()
            .join("nested")
            .join("..")
            .join("nested")
            .join("session.sqlite");

        // Assert the KEY EQUALITY directly. Going only through `acquire` would
        // be satisfied by any `Err` — including one from a broken
        // `canonical_session_key` — so a regression that stopped deriving keys
        // at all would leave this green while proving nothing about collision.
        assert_eq!(
            canonical_session_key(&direct).expect("direct key"),
            canonical_session_key(&indirect).expect("indirect key"),
            "two spellings of one file must reduce to ONE registry key"
        );

        // Then the integration half: the registry actually rejects the second.
        let _held = LiveSessionGuard::acquire(&direct).expect("acquire direct");
        assert!(
            LiveSessionGuard::acquire(&indirect).is_err(),
            "a `..` round-trip through the same directory must resolve to the \
             SAME registry key, not a second one"
        );
    }

    #[test]
    fn canonical_key_fails_closed_when_the_parent_cannot_be_canonicalized() {
        // The regression test for the fail-open this replaced. A missing parent
        // used to fall back to the raw path, so a caller that COULD canonicalize
        // and one that could not would register two different keys for one file.
        // Refusing to produce a key is the only safe answer.
        let dir = tempfile::tempdir().expect("tempdir");
        let missing = dir.path().join("does-not-exist").join("session.sqlite");

        assert!(
            canonical_session_key(&missing).is_err(),
            "a non-canonicalizable parent must fail, never fall back to the raw path"
        );
        assert!(
            LiveSessionGuard::acquire(&missing).is_err(),
            "acquire must propagate the failure rather than register a raw-path key"
        );
    }

    #[test]
    fn canonical_key_fails_closed_on_a_path_with_no_file_name() {
        let dir = tempfile::tempdir().expect("tempdir");
        assert!(
            canonical_session_key(dir.path().join("..").as_path()).is_err(),
            "a path whose final component is `..` has no file name and must fail"
        );
    }

    #[test]
    fn canonical_key_error_carries_no_path() {
        // Rule 8 / Rule 6: the message is a fixed literal. A path in an error
        // that crosses the FFI would leak the data directory layout.
        let dir = tempfile::tempdir().expect("tempdir");
        let missing = dir.path().join("does-not-exist").join("session.sqlite");
        let err = canonical_session_key(&missing).expect_err("must fail");
        let rendered = err.to_string();

        assert!(
            !rendered.contains(dir.path().to_str().expect("utf8")),
            "the error must not embed the database path: {rendered}"
        );
    }

    #[test]
    fn database_path_is_session_v2_sqlite() {
        let config = StorageConfig::new("/tmp/haven-mls");
        assert_eq!(
            config.database_path(),
            PathBuf::from("/tmp/haven-mls/session-v2.sqlite")
        );
    }

    #[test]
    fn storage_options_are_hardened_defaults() {
        let opts = StorageConfig::storage_options();
        assert!(opts.secure_delete, "secure_delete must be on");
        assert!(
            opts.cipher_memory_security,
            "cipher_memory_security must be on"
        );
        assert_eq!(opts.cipher_compatibility, 4);
    }

    #[test]
    fn test_storage_options_differ_from_production_only_in_memory_security() {
        let production = StorageConfig::storage_options();
        let test = StorageConfig::test_storage_options();
        assert!(production.cipher_memory_security && !test.cipher_memory_security);
        assert_eq!(
            SqliteStorageOptions {
                cipher_memory_security: true,
                ..test
            },
            production,
            "every other field, `journal_mode` (persisted in the file) above all, \
             is production's"
        );
    }

    #[test]
    fn the_test_key_is_a_raw_key_that_skips_the_passphrase_derivation() {
        crate::sqlcipher_init::ensure().expect("SQLite initialises");
        let dir = tempfile::tempdir().expect("tempdir");
        // Lays a store down through MDK under `key`, then reads it back on a
        // bare connection whose KDF runs one iteration instead of 256,000: only
        // a raw key, which skips the KDF, still decrypts.
        let opens_with_one_kdf_iteration = |name: &str, key: &SqlCipherKey| {
            let path = dir.path().join(name);
            let store = SqliteAccountStorage::open_encrypted_with_options(
                &path,
                key,
                StorageConfig::test_storage_options(),
            )
            .expect("the store is created");
            drop(store);
            SqliteAccountStorage::open_encrypted_with_options(
                &path,
                key,
                StorageConfig::test_storage_options(),
            )
            .expect("the store reopens under the same key");
            let conn = rusqlite::Connection::open(&path).expect("open");
            conn.pragma_update(None, "cipher_compatibility", 4i64)
                .expect("compatibility");
            conn.pragma_update(None, "key", key.as_secret_str())
                .expect("key");
            conn.pragma_update(None, "kdf_iter", 1i64)
                .expect("kdf_iter");
            conn.query_row("SELECT count(*) FROM sqlite_master", [], |row| {
                row.get::<_, i64>(0)
            })
            .is_ok()
        };

        assert!(
            !opens_with_one_kdf_iteration(
                "passphrase.sqlite",
                &SqlCipherKey::new("a passphrase").expect("key")
            ),
            "premise: a passphrase-keyed store depends on the KDF's iteration count"
        );
        assert!(
            opens_with_one_kdf_iteration(
                "raw.sqlite",
                &StorageConfig::test_sqlcipher_key().expect("the test key")
            ),
            "the test key is a raw key: no test open pays for PBKDF2"
        );
    }

    #[test]
    fn in_memory_storage_opens() {
        let storage = StorageConfig::in_memory_storage();
        assert!(storage.is_ok(), "in-memory MLS storage should open");
    }

    #[test]
    fn passphrase_is_64_lowercase_hex_and_stable() {
        install_mock_store();
        let key_id = unique_key_id("stable");

        let first = get_or_create_passphrase(SERVICE_ID, &key_id).expect("mint passphrase");
        assert_eq!(first.len(), 64, "hex of 32 bytes is 64 chars");
        assert!(
            first
                .chars()
                .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()),
            "passphrase must be lowercase hex"
        );

        // A second read returns the SAME persisted passphrase (no re-mint).
        let second = get_or_create_passphrase(SERVICE_ID, &key_id).expect("read passphrase");
        assert_eq!(first.as_str(), second.as_str());
    }

    #[test]
    fn distinct_key_ids_yield_distinct_passphrases() {
        install_mock_store();
        let a = get_or_create_passphrase(SERVICE_ID, &unique_key_id("a")).unwrap();
        let b = get_or_create_passphrase(SERVICE_ID, &unique_key_id("b")).unwrap();
        assert_ne!(a.as_str(), b.as_str());
    }

    #[test]
    fn open_encrypted_roundtrips_and_rejects_wrong_key() {
        install_mock_store();
        let dir = unique_temp_dir();
        let config = StorageConfig::new(&dir);

        // First open provisions the key + creates the encrypted DB.
        config
            .open_encrypted_storage()
            .expect("first open creates the encrypted MLS DB");

        // Reopening with the same keyring-provisioned key succeeds.
        config
            .open_encrypted_storage()
            .expect("reopen with the same key succeeds");

        // A different key must NOT decrypt the same file.
        let wrong_key = SqlCipherKey::new("a-different-passphrase").unwrap();
        crate::sqlcipher_init::ensure().expect("SQLite initialises");
        let wrong = SqliteAccountStorage::open_encrypted_with_options(
            config.database_path(),
            &wrong_key,
            StorageConfig::test_storage_options(),
        );
        assert!(wrong.is_err(), "a wrong key must fail to open the DB");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn keyring_constants_are_valid() {
        assert_eq!(SERVICE_ID, "com.oblivioustech.haven");
        assert_eq!(MLS_DB_KEY_ID, "mls.session.key.v2");
        assert_eq!(MLS_DB_FILENAME, "session-v2.sqlite");
    }

    #[test]
    fn session_db_path_is_the_registry_key_callers_must_reuse() {
        // Rule 14's registry is keyed on this exact path. The helper exists so
        // no caller re-spells the filename: a second literal decouples silently
        // on any rename — `is_session_live` would keep answering `false` for a
        // key nothing registers, and a reclaiming caller would conclude the
        // guard is free and never recover an orphaned session.
        let dir = tempfile::tempdir().expect("tempdir");
        let path = session_db_path(dir.path());

        assert_eq!(
            path.file_name().and_then(|n| n.to_str()),
            Some(MLS_DB_FILENAME),
            "the helper must produce the MLS db filename, not a second spelling"
        );
        assert_eq!(
            path,
            StorageConfig::new(dir.path()).database_path(),
            "the free helper and the config method must agree — they key the \
             SAME registry entry, and a divergence is invisible until a \
             reclaim silently fails"
        );
        assert_eq!(path.parent(), Some(dir.path()));
    }

    #[test]
    fn open_encrypted_storage_fails_closed_when_the_data_dir_cannot_exist() {
        // A device whose storage is unavailable (locked, full, or — as here —
        // a path that cannot be a directory) must surface an error rather than
        // fall back to an unencrypted or in-memory store. Silently degrading
        // would put MLS state, and the exporter secrets in it, outside
        // SQLCipher.
        let dir = tempfile::tempdir().expect("tempdir");
        let blocker = dir.path().join("not-a-dir");
        std::fs::write(&blocker, b"regular file").expect("write blocker");

        // `data_dir` NESTED under a regular file, so `create_dir_all` cannot
        // succeed on any platform.
        // `SqliteAccountStorage` is not `Debug`, so match rather than
        // `expect_err`.
        let config = StorageConfig::new(blocker.join("mls"));
        match config.open_encrypted_storage() {
            Err(NostrError::StorageError(_)) => {}
            Err(other) => {
                panic!("the failure must be a StorageError the caller can act on: {other:?}")
            }
            Ok(_) => panic!(
                "an unusable data directory must fail closed — opening anyway \
                 would put MLS state outside SQLCipher"
            ),
        }
    }
}
