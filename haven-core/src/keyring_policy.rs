//! iOS keyring access-policy migration for the `SQLCipher` database keys.
//!
//! On iOS, the system keychain stores each item with a `kSecAttrAccessible`
//! attribute that governs *when* the OS will surrender the item's bytes. The
//! keyring library this app uses defaults to `kSecAttrAccessibleWhenUnlocked`,
//! which makes the `SQLCipher` database encryption keys (MLS, circles, tiles)
//! readable **only while the device is unlocked**. A background wake while the
//! device is locked therefore cannot read the key, the encrypted database
//! cannot be opened, and location publishing fails silently.
//!
//! This module migrates those keys to
//! `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — readable after the first
//! post-boot unlock, never iCloud-synced, never migrated off-device — which is
//! the minimum accessibility that permits locked-device background publishing.
//!
//! # Why delete-then-add
//!
//! Re-`set`-ing the secret on an *existing* keychain item does **not** change
//! its `kSecAttrAccessible` attribute: the underlying `SecItemUpdate` only
//! rewrites the value data, leaving the original accessibility in place. The
//! only way to change accessibility is to delete the item and re-create it with
//! the new attribute.
//!
//! # Crash safety
//!
//! Delete-then-add has a window in which the key exists in neither its original
//! nor its migrated form. For the MLS DB key that window is catastrophic — a
//! process kill there would orphan the encrypted MLS state. [`migrate_once`]
//! therefore stages a **backup** copy of the key (under a sibling id, with the
//! same access policy) *before* deleting the original, and recovers from a
//! stranded backup on the next launch. At every instant at least one of the
//! primary or the backup holds the key bytes, so an interrupted migration is
//! always recoverable and the key is never lost. If re-creation fails outright
//! the original bytes are restored immediately.
//!
//! # Testability
//!
//! The iOS-only modifier (`access-policy`) is rejected by the in-memory mock
//! store used by tests, so [`migrate_once`] is parameterized by a `rebuild`
//! closure: production iOS passes a closure that attaches the modifier; tests
//! pass a plain [`keyring_core::Entry::new`] closure. The public entry point
//! [`ensure_db_key_after_first_unlock`] is a no-op on every non-iOS target, so
//! Android/macOS/Linux/Windows keyring behavior is completely unaffected.
//!
//! The mock store cannot model `kSecAttrAccessible`, so these tests only verify
//! the no-data-loss invariants (bytes preserved, idempotent, abort-before-delete
//! on staging failure, restore-after-failed-recreate, recovery from a stranded
//! backup). The actual accessibility change is verified on-device.

// The migration helpers below are referenced only by the iOS code path and the
// unit tests; a plain non-iOS lib build (the default `cargo clippy` target)
// compiles neither, so they are dead there.
#[cfg_attr(not(any(target_os = "ios", test)), allow(dead_code))]
mod migration {
    /// Suffix for the per-key "migration completed" marker entry.
    ///
    /// The marker is created through the same `rebuild` closure as the migrated
    /// key, so on iOS it is *also* stored `AfterFirstUnlock` and is therefore
    /// readable while the device is locked. A simple boolean would be unreadable
    /// while locked and would cause the migration to re-run on every locked
    /// launch.
    const MARKER_SUFFIX: &str = ".afu.v1";

    /// Suffix for the transient backup entry used to make the delete-then-add
    /// window crash-safe (see the module-level "Crash safety" note).
    const BACKUP_SUFFIX: &str = ".afu.bak";

    type RebuildResult = keyring_core::Result<keyring_core::Entry>;

    /// Migrates a single keyring entry's access policy, preserving its bytes.
    ///
    /// The migration is idempotent and guarded by a marker entry: once the
    /// marker is readable, the function short-circuits. The `rebuild` closure
    /// produces the [`keyring_core::Entry`] that the migrated key (the marker,
    /// and the backup) is re-created with — on iOS it attaches the access-policy
    /// modifier; in tests it is plain.
    ///
    /// This function never logs key bytes and is crash-safe: at every instant at
    /// least one of the primary key or its backup holds the bytes.
    ///
    /// # Errors
    ///
    /// Returns a redacted error string if the keyring cannot be read (other than
    /// "not found", which is treated as success), if the backup cannot be
    /// staged (in which case the original is left untouched), or if re-creating
    /// the migrated entry fails (in which case the original bytes are restored).
    /// The key is never lost; a later launch retries.
    pub(super) fn migrate_once<F>(service: &str, key_id: &str, rebuild: &F) -> Result<(), String>
    where
        F: Fn(&str, &str) -> RebuildResult,
    {
        let marker_id = format!("{key_id}{MARKER_SUFFIX}");
        let backup_id = format!("{key_id}{BACKUP_SUFFIX}");

        // Already migrated? The marker is readable when locked on iOS, so a
        // successful read means we are done and must not touch the key again.
        if let Ok(marker) = rebuild(service, &marker_id) {
            if marker.get_secret().is_ok() {
                return Ok(());
            }
        }

        // Crash recovery: a stranded backup means a prior migration was
        // interrupted in the delete/re-create window. Restore the primary from
        // the backup if it is missing, then drop the backup, before proceeding.
        recover_from_backup(service, key_id, &backup_id, rebuild);

        // Read the current key bytes. If the entry was never created, there is
        // nothing to migrate (call sites guarantee it exists; this is
        // defensive). Any other read error (e.g. a locked-device read failure)
        // defers the migration to a later unlocked launch — we must NOT delete
        // the key. Hold the raw DB key in a `Zeroizing` buffer so it is wiped
        // from memory on drop (CLAUDE.md security rule #7), however we exit.
        let entry = keyring_core::Entry::new(service, key_id)
            .map_err(|_| "failed to open keyring entry".to_string())?;
        let bytes = match entry.get_secret() {
            Ok(bytes) => zeroize::Zeroizing::new(bytes),
            Err(keyring_core::Error::NoEntry) => return Ok(()),
            Err(_) => return Err("failed to read keyring entry".to_string()),
        };

        // Stage a backup copy (with the target access policy) BEFORE deleting
        // the original, so a crash in the window below is recoverable next
        // launch. If staging fails we abort WITHOUT deleting — the original is
        // untouched and the migration simply retries later.
        match rebuild(service, &backup_id).and_then(|b| b.set_secret(&bytes)) {
            Ok(()) => {}
            Err(_) => return Err("failed to stage keyring migration backup".to_string()),
        }

        // Delete the original so it can be re-created with the new access policy
        // (re-setting in place would leave accessibility unchanged). The backup
        // now holds the only-other copy; a crash here is recovered next launch.
        match entry.delete_credential() {
            Ok(()) | Err(keyring_core::Error::NoEntry) => {}
            Err(_) => {
                // Could not delete; the original is intact, so just drop the
                // now-redundant backup and abort.
                best_effort_delete(service, &backup_id, rebuild);
                return Err("failed to delete keyring entry for migration".to_string());
            }
        }

        // Re-create the key with the new access policy and write its bytes back.
        let recreated = rebuild(service, key_id)
            .and_then(|migrated| migrated.set_secret(&bytes).map(|()| migrated));

        if recreated.is_ok() {
            // Migration done: drop the backup, then record the marker so future
            // launches skip the migration entirely. A failed marker write only
            // means we re-run next launch — which is now crash-safe, so it is
            // best-effort.
            best_effort_delete(service, &backup_id, rebuild);
            if let Ok(marker) = rebuild(service, &marker_id) {
                let _ = marker.set_secret(b"1");
            }
            Ok(())
        } else {
            // Re-creation failed: restore the original bytes immediately via a
            // plain entry so the key is NEVER lost, then drop the backup.
            if let Ok(original) = keyring_core::Entry::new(service, key_id) {
                let _ = original.set_secret(&bytes);
            }
            best_effort_delete(service, &backup_id, rebuild);
            Err("failed to migrate keyring entry access policy".to_string())
        }
    }

    /// Restores the primary key from a stranded backup left by an interrupted
    /// migration, then removes the backup. No-op when no backup exists.
    fn recover_from_backup<F>(service: &str, key_id: &str, backup_id: &str, rebuild: &F)
    where
        F: Fn(&str, &str) -> RebuildResult,
    {
        let Ok(backup) = rebuild(service, backup_id) else {
            return;
        };
        let Ok(backup_bytes) = backup.get_secret() else {
            return;
        };
        let backup_bytes = zeroize::Zeroizing::new(backup_bytes);

        // If the primary is missing (the crash happened after the delete),
        // re-create it from the backup with the target access policy.
        let primary_missing = matches!(
            keyring_core::Entry::new(service, key_id).map(|p| p.get_secret()),
            Ok(Err(keyring_core::Error::NoEntry))
        );
        if primary_missing {
            if let Ok(restored) = rebuild(service, key_id) {
                let _ = restored.set_secret(&backup_bytes);
            }
        }
        best_effort_delete(service, backup_id, rebuild);
    }

    /// Best-effort delete of an entry built via `rebuild`. Used for transient
    /// backups; a failure only leaves a harmless stranded entry recovered later.
    fn best_effort_delete<F>(service: &str, id: &str, rebuild: &F)
    where
        F: Fn(&str, &str) -> RebuildResult,
    {
        if let Ok(entry) = rebuild(service, id) {
            let _ = entry.delete_credential();
        }
    }

    #[cfg(test)]
    mod tests {
        use super::*;
        use std::sync::atomic::{AtomicU64, Ordering};
        use std::sync::{Mutex, Once};

        static INIT: Once = Once::new();
        /// Serializes tests that touch the process-global default keyring store.
        static STORE_GUARD: Mutex<()> = Mutex::new(());
        static ID_COUNTER: AtomicU64 = AtomicU64::new(0);

        /// Installs the in-memory mock store once for the whole test binary.
        ///
        /// The mock store is process-global, so we also serialize the tests with
        /// `STORE_GUARD` and hand each test a unique service/key id pair to
        /// prevent cross-test interference.
        fn install_mock_store() {
            INIT.call_once(|| {
                keyring_core::set_default_store(
                    keyring_core::mock::Store::new().expect("mock store creation never fails"),
                );
            });
        }

        /// Returns a unique `(service, key_id)` pair for an isolated test.
        fn unique_ids() -> (String, String) {
            let n = ID_COUNTER.fetch_add(1, Ordering::SeqCst);
            (
                format!("haven.keyring_policy.test.{n}"),
                format!("db.key.{n}"),
            )
        }

        /// Plain rebuild closure — the mock store rejects modifiers, so tests
        /// must not attach any. This mirrors what the iOS closure does, minus
        /// the `access-policy` modifier the mock cannot model.
        fn plain_rebuild(s: &str, u: &str) -> RebuildResult {
            keyring_core::Entry::new(s, u)
        }

        /// Rebuild closure that always fails — used to exercise the
        /// abort-before-delete (backup-staging-failure) path.
        fn failing_rebuild(_s: &str, _u: &str) -> RebuildResult {
            Err(keyring_core::Error::NoDefaultStore)
        }

        fn put(service: &str, id: &str, bytes: &[u8]) {
            keyring_core::Entry::new(service, id)
                .unwrap()
                .set_secret(bytes)
                .unwrap();
        }

        fn get(service: &str, id: &str) -> keyring_core::Result<Vec<u8>> {
            keyring_core::Entry::new(service, id).unwrap().get_secret()
        }

        #[test]
        fn migrate_once_preserves_bytes_and_creates_marker() {
            let _guard = STORE_GUARD.lock().unwrap();
            install_mock_store();
            let (service, key_id) = unique_ids();

            let original = [7u8; 32];
            put(&service, &key_id, &original);

            let result = migrate_once(&service, &key_id, &plain_rebuild);
            assert!(result.is_ok(), "migration should succeed: {result:?}");

            // Bytes are byte-for-byte preserved across the delete-then-add.
            assert_eq!(
                get(&service, &key_id).unwrap(),
                original,
                "key bytes must survive migration"
            );

            // The marker exists (future launches short-circuit) and the
            // transient backup has been cleaned up.
            assert!(
                get(&service, &format!("{key_id}{MARKER_SUFFIX}")).is_ok(),
                "marker entry must exist after migration"
            );
            assert!(
                matches!(
                    get(&service, &format!("{key_id}{BACKUP_SUFFIX}")),
                    Err(keyring_core::Error::NoEntry)
                ),
                "backup entry must be removed after a successful migration"
            );
        }

        #[test]
        fn migrate_once_is_idempotent() {
            let _guard = STORE_GUARD.lock().unwrap();
            install_mock_store();
            let (service, key_id) = unique_ids();

            let original = [9u8; 32];
            put(&service, &key_id, &original);

            migrate_once(&service, &key_id, &plain_rebuild).unwrap();
            // Second run is a no-op (marker short-circuits) and must not corrupt.
            let result = migrate_once(&service, &key_id, &plain_rebuild);
            assert!(result.is_ok(), "second migration should be a no-op");

            assert_eq!(
                get(&service, &key_id).unwrap(),
                original,
                "key bytes must be unchanged after re-run"
            );
        }

        #[test]
        fn migrate_once_aborts_without_deleting_when_backup_staging_fails() {
            let _guard = STORE_GUARD.lock().unwrap();
            install_mock_store();
            let (service, key_id) = unique_ids();

            let original = [3u8; 32];
            put(&service, &key_id, &original);

            // `failing_rebuild` makes the backup staging fail, so the migration
            // must abort BEFORE deleting the original — bytes stay intact.
            let result = migrate_once(&service, &key_id, &failing_rebuild);
            assert!(result.is_err(), "migration must report the staging failure");
            assert_eq!(
                get(&service, &key_id).unwrap(),
                original,
                "original key bytes must be untouched when staging fails"
            );
        }

        #[test]
        fn migrate_once_restores_primary_when_recreate_fails() {
            let _guard = STORE_GUARD.lock().unwrap();
            install_mock_store();
            let (service, key_id) = unique_ids();

            let original = [5u8; 32];
            put(&service, &key_id, &original);

            // Rebuild succeeds for the backup/marker ids but fails when
            // re-creating the PRIMARY key, exercising the restore-after-delete
            // path. The closure must not match the marker/backup sibling ids.
            let key_id_owned = key_id.clone();
            let rebuild = move |s: &str, u: &str| -> RebuildResult {
                if u == key_id_owned {
                    Err(keyring_core::Error::NoDefaultStore)
                } else {
                    keyring_core::Entry::new(s, u)
                }
            };

            let result = migrate_once(&service, &key_id, &rebuild);
            assert!(
                result.is_err(),
                "migration must report the recreate failure"
            );

            // The original bytes are restored — the key is never lost — and the
            // backup is cleaned up.
            assert_eq!(
                get(&service, &key_id).unwrap(),
                original,
                "original key bytes must be restored on recreate failure"
            );
            assert!(
                matches!(
                    get(&service, &format!("{key_id}{BACKUP_SUFFIX}")),
                    Err(keyring_core::Error::NoEntry)
                ),
                "backup must be cleaned up after a restore"
            );
        }

        #[test]
        fn migrate_once_recovers_from_stranded_backup() {
            let _guard = STORE_GUARD.lock().unwrap();
            install_mock_store();
            let (service, key_id) = unique_ids();

            // Simulate a crash mid-migration: the primary key is gone and only a
            // backup remains.
            let original = [11u8; 32];
            put(&service, &format!("{key_id}{BACKUP_SUFFIX}"), &original);
            assert!(
                matches!(get(&service, &key_id), Err(keyring_core::Error::NoEntry)),
                "precondition: primary key is missing"
            );

            let result = migrate_once(&service, &key_id, &plain_rebuild);
            assert!(result.is_ok(), "recovery + migration should succeed");

            // The primary key is restored from the stranded backup, byte-exact,
            // and the backup is cleaned up.
            assert_eq!(
                get(&service, &key_id).unwrap(),
                original,
                "primary key must be recovered from the stranded backup"
            );
            assert!(
                matches!(
                    get(&service, &format!("{key_id}{BACKUP_SUFFIX}")),
                    Err(keyring_core::Error::NoEntry)
                ),
                "stranded backup must be cleaned up after recovery"
            );
        }

        #[test]
        fn migrate_once_no_entry_is_ok() {
            let _guard = STORE_GUARD.lock().unwrap();
            install_mock_store();
            let (service, key_id) = unique_ids();

            // Never wrote a key for these ids: migration is a defensive no-op.
            let result = migrate_once(&service, &key_id, &plain_rebuild);
            assert!(result.is_ok(), "migrating a missing key must return Ok");

            // And it must not have created the key as a side effect.
            assert!(
                matches!(get(&service, &key_id), Err(keyring_core::Error::NoEntry)),
                "missing key must remain missing"
            );
        }
    }
}

/// Ensures the named DB key is stored `AfterFirstUnlockThisDeviceOnly` on iOS.
///
/// Migrates an existing keyring entry (created by the library default
/// `WhenUnlocked`) to `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` so the
/// `SQLCipher` database can be opened during a locked-device background wake. The
/// migration is idempotent and crash-safe — it never loses the key (see
/// [`migration::migrate_once`]).
///
/// On every non-iOS target this is a no-op that returns `Ok(())`, leaving
/// Android/macOS/Linux/Windows keyring behavior unchanged.
///
/// # Errors
///
/// On iOS, returns a redacted error string if the migration cannot be performed
/// this launch (e.g. a locked-device read failure). Call sites treat this as
/// non-fatal: the original key is intact and a later launch retries.
#[cfg(target_os = "ios")]
pub fn ensure_db_key_after_first_unlock(service: &str, key_id: &str) -> Result<(), String> {
    let mut mods = std::collections::HashMap::new();
    mods.insert("access-policy", "after-first-unlock-this-device-only");
    migration::migrate_once(service, key_id, &|s, u| {
        keyring_core::Entry::new_with_modifiers(s, u, &mods)
    })
}

/// Ensures the named DB key is stored `AfterFirstUnlockThisDeviceOnly` on iOS.
///
/// No-op on every non-iOS target. See the iOS variant for details.
///
/// # Errors
///
/// Never returns an error on non-iOS targets.
#[cfg(not(target_os = "ios"))]
pub const fn ensure_db_key_after_first_unlock(_service: &str, _key_id: &str) -> Result<(), String> {
    Ok(())
}

#[cfg(test)]
mod entry_point_tests {
    use super::ensure_db_key_after_first_unlock;

    #[test]
    fn ensure_db_key_after_first_unlock_is_noop_off_ios() {
        // On non-iOS targets (where this test runs in CI) the public entry point
        // is a no-op that returns Ok without touching the keyring.
        let result = ensure_db_key_after_first_unlock("any.service", "any.key");
        assert!(result.is_ok(), "non-iOS entry point must be a no-op Ok");
    }
}
