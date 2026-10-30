//! The one-time storage reset that moves an install onto MDK v0.10.4.
//!
//! Owner decision D1 (hard reset, wipe everything): a v0.10.4 engine never opens
//! a store a v0.9.4 build wrote. Every store therefore lives under a new file
//! name and a new keyring id (`session-v2.sqlite` / `mls.session.key.v2`,
//! `circles-v2.db` / `circles.db.key.v2`, `tiles-v2.db` / `tiles.db.key.v2`),
//! and [`reset_pre_v2_storage`] deletes what the old names left behind — the MLS
//! state, the circle metadata, the tile cache and the pre-Dark-Matter
//! `haven_mdk.db` — and destroys their keyring keys. Unlinking a file is not a
//! secure erase on flash, so destroying the key is what makes the abandoned
//! `SQLCipher` pages unreadable (Rule 5).
//!
//! Every store opener runs it before opening (a background isolate may start
//! first), and it is idempotent: once nothing old is left it deletes nothing.
//! A pass that finds the user's data — the MLS session, the circle metadata or
//! `haven_mdk.db` — writes two zero-byte markers BEFORE deleting anything, so a
//! process killed mid-pass still owes the notice, and the app still owes
//! clearing its own preferences that name what was deleted — the circles, and
//! an unpublished display name ([`storage_reset_prefs_owed`]) — unless it has
//! already cleared them for this identity. If either cannot be written, nothing is
//! deleted and the notice stays owed. The notice marker stays until the user
//! acknowledges the reset notice ([`acknowledge_storage_reset`]); while it
//! stands, or an old user store survives, no relay list is published
//! ([`storage_reset_acknowledged`]), because
//! the reset also returned the relay settings to their defaults and the user
//! has not yet been told. The tile cache and orphaned keyring keys (an iOS
//! keychain outlives an uninstall) are deleted silently: losing them costs the
//! user nothing to be told about.
//!
//! Removal condition: kept until the owner sets a minimum upgrade source (PLAN
//! §7 O12), then deleted in one change.

use std::path::Path;

/// Zero-byte file written by the first reset that deleted anything, and removed
/// when the user acknowledges the reset notice.
pub const STORAGE_RESET_NOTICE_MARKER: &str = "storage-reset-notice";

/// Zero-byte file written beside [`STORAGE_RESET_NOTICE_MARKER`].
///
/// Removed once the app has cleared its own preferences naming what the reset
/// deleted — the circles, and an unpublished display name
/// ([`storage_reset_prefs_cleared`]). Separate from the notice, because
/// the app keeps running — and making new circle-scoped preferences — while the
/// notice waits.
pub const STORAGE_RESET_PREFS_MARKER: &str = "storage-reset-prefs";

/// Zero-byte file written when the app has cleared those preferences, so a pass
/// retrying an old store it could not delete never owes clearing them again —
/// by then they name circles the user made after the reset. Removed only by the
/// logout wipe ([`forget_storage_reset`]).
const STORAGE_RESET_PREFS_CLEARED_MARKER: &str = "storage-reset-prefs-cleared";

/// Keyring service every Haven store key lives under.
const SERVICE_ID: &str = "com.oblivioustech.haven";

/// The pre-migration stores that held the user's circles, each with its
/// `-wal` / `-shm` / `-journal` sidecars. Finding any of them owes the notice.
const PRE_V2_USER_FILES: [&str; 3] = ["session.sqlite", "circles.db", "haven_mdk.db"];

/// The pre-migration map tile cache: deleted, but owes no notice.
const PRE_V2_CACHE_FILE: &str = "tiles.db";

/// The keyring ids the pre-migration stores were keyed under. Each is deleted
/// with its iOS access-policy companions, one of which is a full copy of the key.
const PRE_V2_KEY_IDS: [&str; 4] = [
    "mls.session.key.default",
    "circles.db.key",
    "tiles.db.key",
    "mdk.db.key.default",
];

const SIDECARS: [&str; 4] = ["", "-wal", "-shm", "-journal"];

/// What deleting one old file or key did.
enum Removal {
    Removed,
    Absent,
    Failed,
}

/// Deletes every pre-v2 store file and keyring key under `data_dir` and reports
/// whether the reset notice is owed (the marker stands).
///
/// When the user's data is found, the marker is written first; if it cannot be
/// written nothing is deleted, so the next opener retries both in order rather
/// than deleting circles the user is never told about. `NotFound` and an absent
/// keyring entry are success. A step that genuinely fails (a locked file, an
/// unavailable keyring) is left for the next opener to retry; the stores opened
/// afterwards never read the old names, so a leftover is unreadable, never
/// reused. Logs one line, carrying one boolean — never a path, a count or a key
/// id (Rule 15).
#[must_use]
pub fn reset_pre_v2_storage(data_dir: &Path) -> bool {
    let files = |names: &'static [&'static str]| {
        names.iter().flat_map(move |name| {
            SIDECARS
                .iter()
                .map(move |suffix| data_dir.join(format!("{name}{suffix}")))
        })
    };
    let user_files: Vec<_> = files(&PRE_V2_USER_FILES).collect();
    let markers: &[&str] = if data_dir.join(STORAGE_RESET_PREFS_CLEARED_MARKER).exists() {
        &[STORAGE_RESET_NOTICE_MARKER]
    } else {
        &[STORAGE_RESET_PREFS_MARKER, STORAGE_RESET_NOTICE_MARKER]
    };
    if user_files.iter().any(|path| path.exists())
        && markers
            .iter()
            .any(|marker| std::fs::write(data_dir.join(marker), []).is_err())
    {
        log::info!("pre-migration storage reset ran; complete=false");
        return !storage_reset_acknowledged(data_dir);
    }
    let mut removed = false;
    let mut failed = false;
    let key_removals = PRE_V2_KEY_IDS.iter().flat_map(|id| {
        std::iter::once((*id).to_string())
            .chain(crate::keyring_policy::access_policy_companions(id))
            .map(|entry| remove_key(&entry))
    });
    let removals = user_files
        .iter()
        .map(|path| remove_file(path))
        .chain(files(&[PRE_V2_CACHE_FILE]).map(|path| remove_file(&path)))
        .chain(key_removals);
    for removal in removals {
        match removal {
            Removal::Removed => removed = true,
            Removal::Absent => {}
            Removal::Failed => failed = true,
        }
    }
    if removed || failed {
        log::info!("pre-migration storage reset ran; complete={}", !failed);
    }
    !storage_reset_acknowledged(data_dir)
}

/// Whether no reset notice is waiting for the user.
///
/// True when the marker is absent and no pre-migration user store is left. A
/// store a failed pass could not delete — or whose marker it could not write —
/// keeps the notice owed, so the defaults the reset will restore are never
/// published untold.
#[must_use]
pub fn storage_reset_acknowledged(data_dir: &Path) -> bool {
    !data_dir.join(STORAGE_RESET_NOTICE_MARKER).exists() && !user_files_remain(data_dir)
}

/// Whether the app still owes clearing its preferences that name what the
/// reset deleted: the deleted circles, and the user's display name, which may
/// be an edit the deleted outbox never published.
///
/// Owed while the pass that removed the user's data, in any isolate, left
/// [`STORAGE_RESET_PREFS_MARKER`] and the app has not recorded clearing them.
/// The record wins: it is written before the marker is removed, so a marker a
/// failed removal left behind would otherwise clear preferences made since.
#[must_use]
pub fn storage_reset_prefs_owed(data_dir: &Path) -> bool {
    data_dir.join(STORAGE_RESET_PREFS_MARKER).exists()
        && !data_dir.join(STORAGE_RESET_PREFS_CLEARED_MARKER).exists()
}

/// Records that the app has cleared its circle-scoped preferences.
///
/// # Errors
///
/// Returns an opaque error when the record cannot be written — the preferences
/// are then cleared again next launch — or the marker cannot be removed, which
/// the record already makes harmless ([`storage_reset_prefs_owed`]).
pub fn storage_reset_prefs_cleared(data_dir: &Path) -> Result<(), String> {
    const FAILED: &str = "failed to record that the reset's preferences were cleared";
    std::fs::write(data_dir.join(STORAGE_RESET_PREFS_CLEARED_MARKER), [])
        .map_err(|_| FAILED.to_string())?;
    remove_marker(data_dir, STORAGE_RESET_PREFS_MARKER).map_err(|()| FAILED.to_string())
}

/// Forgets this identity's part of the reset on logout.
///
/// That is the notice owed to it, the preferences clear owed to it, and the
/// record that its preferences were cleared; a pass that still finds an old
/// store afterwards owes the next identity all of them again.
///
/// # Errors
///
/// Returns an opaque error when any of the files exists and cannot be removed.
pub fn forget_storage_reset(data_dir: &Path) -> Result<(), String> {
    let notice = remove_marker(data_dir, STORAGE_RESET_NOTICE_MARKER);
    let prefs = remove_marker(data_dir, STORAGE_RESET_PREFS_MARKER);
    let cleared = remove_marker(data_dir, STORAGE_RESET_PREFS_CLEARED_MARKER);
    notice
        .and(prefs)
        .and(cleared)
        .map_err(|()| "failed to forget the storage reset".to_string())
}

fn remove_marker(data_dir: &Path, marker: &str) -> Result<(), ()> {
    match remove_file(&data_dir.join(marker)) {
        Removal::Removed | Removal::Absent => Ok(()),
        Removal::Failed => Err(()),
    }
}

fn user_files_remain(data_dir: &Path) -> bool {
    PRE_V2_USER_FILES.iter().any(|name| {
        SIDECARS
            .iter()
            .any(|suffix| data_dir.join(format!("{name}{suffix}")).exists())
    })
}

/// Records that the user has seen the reset notice, which lets relay-list
/// publishing resume.
///
/// # Errors
///
/// Returns an opaque error when the marker exists and cannot be removed; the
/// notice then shows again on the next launch.
pub fn acknowledge_storage_reset(data_dir: &Path) -> Result<(), String> {
    remove_marker(data_dir, STORAGE_RESET_NOTICE_MARKER)
        .map_err(|()| "failed to record the storage reset acknowledgement".to_string())
}

fn remove_file(path: &Path) -> Removal {
    match std::fs::remove_file(path) {
        Ok(()) => Removal::Removed,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Removal::Absent,
        Err(_) => Removal::Failed,
    }
}

fn remove_key(key_id: &str) -> Removal {
    let entry = match keyring_core::Entry::new(SERVICE_ID, key_id) {
        Ok(entry) => entry,
        Err(keyring_core::Error::NoEntry) => return Removal::Absent,
        // No store means the old key cannot be proven gone: retried next open.
        Err(_) => return Removal::Failed,
    };
    match entry.delete_credential() {
        Ok(()) => Removal::Removed,
        Err(keyring_core::Error::NoEntry) => Removal::Absent,
        Err(_) => Removal::Failed,
    }
}
