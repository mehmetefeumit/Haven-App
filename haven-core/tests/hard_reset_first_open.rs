//! The one-time MDK v0.10.4 storage reset (owner decision D1: wipe everything),
//! driven through the production store opener, `CircleManager::new`.
//!
//! Every pre-migration store — the MLS session, the circle metadata, the tile
//! cache and the pre-Dark-Matter `haven_mdk.db` — is planted as garbage bytes
//! with its sidecars, and every retired keyring id is planted in the fake
//! keyring. A migrated build must delete all of it before any store opens,
//! open fresh stores under the new names and keyring ids, leave the reset
//! notice marker, do nothing more on the next open, and say nothing that names
//! a path, a key id or a count.
//!
//! The keyring store is process-global, so every test here takes `KEYRING` for
//! its whole body.

mod helpers;

use std::path::Path;

use haven_core::avatar::{process_own_avatar, StagedPicture};
use haven_core::circle::{CircleManager, CircleStorage, CIRCLES_DB_FILENAME};
use haven_core::nostr::mls::storage::session_db_path;
use haven_core::profile::{CachedProfile, PendingEdits, ProfileMetadata, ProfileState};
use haven_core::storage_reset::{
    acknowledge_storage_reset, forget_storage_reset, reset_pre_v2_storage,
    storage_reset_acknowledged, storage_reset_prefs_cleared, storage_reset_prefs_owed,
    STORAGE_RESET_NOTICE_MARKER, STORAGE_RESET_PREFS_MARKER,
};
use nostr::{Keys, Metadata};
use tempfile::TempDir;

use helpers::{assert_no_needles, capture_haven_log, haven_core_lines};

static KEYRING: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

const SERVICE: &str = "com.oblivioustech.haven";
const OLD_FILES: [&str; 4] = ["session.sqlite", "circles.db", "tiles.db", "haven_mdk.db"];
const OLD_KEY_IDS: [&str; 4] = [
    "mls.session.key.default",
    "circles.db.key",
    "tiles.db.key",
    "mdk.db.key.default",
];
const SIDECARS: [&str; 4] = ["", "-wal", "-shm", "-journal"];
/// Hex key for the circle-metadata store; the FFI mints it from the keyring,
/// which is not what is under test here.
const CIRCLES_KEY_HEX: &str = "4f1c2e3d5a6b7c8d9e0f1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f";

fn install_fake_keyring() {
    keyring_core::set_default_store(
        keyring_core::mock::Store::new().expect("mock store creation never fails"),
    );
}

fn key_present(key_id: &str) -> bool {
    keyring_core::Entry::new(SERVICE, key_id)
        .and_then(|entry| entry.get_secret())
        .is_ok()
}

fn plant_pre_v2_state(dir: &Path) {
    for name in OLD_FILES {
        for suffix in SIDECARS {
            std::fs::write(
                dir.join(format!("{name}{suffix}")),
                b"not a database, garbage bytes",
            )
            .expect("plant an old store file");
        }
    }
    plant_old_keys();
}

/// Every retired keyring id with its iOS access-policy companions — the
/// migration marker and the backup, which is a full copy of the key.
fn old_key_entries() -> Vec<String> {
    OLD_KEY_IDS
        .iter()
        .flat_map(|id| {
            [
                (*id).to_string(),
                format!("{id}.afu.v1"),
                format!("{id}.afu.bak"),
            ]
        })
        .collect()
}

fn plant_old_keys() {
    for key_id in old_key_entries() {
        keyring_core::Entry::new(SERVICE, &key_id)
            .expect("keyring entry")
            .set_secret(&[0x42; 32])
            .expect("plant an old keyring key");
    }
}

fn old_files_left(dir: &Path) -> Vec<String> {
    OLD_FILES
        .iter()
        .flat_map(|name| SIDECARS.iter().map(move |suffix| format!("{name}{suffix}")))
        .filter(|file| dir.join(file).exists())
        .collect()
}

#[tokio::test]
async fn the_migrated_build_never_opens_a_pre_migration_store() {
    let _keyring = KEYRING.lock().await;
    install_fake_keyring();
    let dir = TempDir::new().expect("temp dir");
    plant_pre_v2_state(dir.path());
    let keys = Keys::generate();

    // Garbage in every old file: an opener that touched one would fail here.
    let manager = CircleManager::new(dir.path(), &keys, Some(CIRCLES_KEY_HEX))
        .expect("the first open of a migrated install succeeds on fresh stores");

    assert!(
        old_files_left(dir.path()).is_empty(),
        "every pre-migration store and sidecar is deleted: {:?}",
        old_files_left(dir.path())
    );
    for key_id in old_key_entries() {
        assert!(
            !key_present(&key_id),
            "the retired keyring entry {key_id} is destroyed — the practical secure erase"
        );
    }
    assert!(
        session_db_path(dir.path()).exists() && dir.path().join(CIRCLES_DB_FILENAME).exists(),
        "the fresh stores live under the new names"
    );
    assert!(
        key_present("mls.session.key.v2"),
        "the fresh MLS store is keyed under the new keyring id"
    );
    assert!(
        manager
            .get_circles()
            .await
            .expect("read circles")
            .is_empty(),
        "a fresh schema: nothing survives the reset"
    );
    assert!(
        !manager.storage_reset_acknowledged(),
        "the reset leaves its notice owed"
    );
    assert!(dir.path().join(STORAGE_RESET_NOTICE_MARKER).exists());

    // The second open finds nothing old: it deletes nothing, keeps the notice
    // owed until the user acknowledges it, and reopens the SAME fresh stores.
    drop(manager);
    let reopened = CircleManager::new(dir.path(), &keys, Some(CIRCLES_KEY_HEX))
        .expect("a second open reuses the fresh stores");
    assert!(!reopened.storage_reset_acknowledged());
    acknowledge_storage_reset(dir.path()).expect("acknowledge");
    assert!(reopened.storage_reset_acknowledged());
    drop(reopened);
    CircleManager::new(dir.path(), &keys, Some(CIRCLES_KEY_HEX)).expect("third open");
    assert!(
        storage_reset_acknowledged(dir.path()),
        "an open after the acknowledgement finds nothing to reset and owes no notice"
    );
}

#[tokio::test]
async fn a_fresh_install_owes_no_reset_notice() {
    let _keyring = KEYRING.lock().await;
    install_fake_keyring();
    let dir = TempDir::new().expect("temp dir");

    assert!(
        !reset_pre_v2_storage(dir.path()),
        "nothing was deleted, so no notice is owed"
    );
    CircleManager::new(dir.path(), &Keys::generate(), Some(CIRCLES_KEY_HEX)).expect("open");
    assert!(storage_reset_acknowledged(dir.path()));
    assert!(!dir.path().join(STORAGE_RESET_NOTICE_MARKER).exists());
}

#[tokio::test]
async fn the_reset_deletes_sidecars_and_is_idempotent() {
    let _keyring = KEYRING.lock().await;
    install_fake_keyring();
    let dir = TempDir::new().expect("temp dir");
    // Sidecars alone, as a crash between a checkpoint and the unlink leaves them.
    for name in OLD_FILES {
        for suffix in ["-wal", "-shm", "-journal"] {
            std::fs::write(
                dir.path().join(format!("{name}{suffix}")),
                b"orphaned sidecar",
            )
            .expect("plant a sidecar");
        }
    }

    assert!(
        reset_pre_v2_storage(dir.path()),
        "the first pass owes the notice"
    );
    assert!(old_files_left(dir.path()).is_empty());
    assert!(
        reset_pre_v2_storage(dir.path()),
        "while the marker stands the notice stays owed, whichever opener asks"
    );
    std::fs::remove_file(dir.path().join(STORAGE_RESET_NOTICE_MARKER)).expect("clear marker");

    assert!(
        !reset_pre_v2_storage(dir.path()),
        "a second pass deletes nothing, so it writes no new notice"
    );
    assert!(!reset_pre_v2_storage(dir.path()));
}

#[tokio::test]
async fn the_reset_logs_no_path() {
    let _keyring = KEYRING.lock().await;
    install_fake_keyring();
    let parent = TempDir::new().expect("temp dir");
    let dir = parent.path().join("NeedleDataDirQuux7");
    std::fs::create_dir_all(&dir).expect("data dir");
    plant_pre_v2_state(&dir);

    let lines = capture_haven_log(async {
        assert!(reset_pre_v2_storage(&dir));
    })
    .await;
    let ours = haven_core_lines(&lines);
    assert!(
        ours.iter()
            .any(|l| l.message.contains("pre-migration storage reset ran")),
        "anti-vacuity: the reset's one line was captured"
    );
    let dir_display = dir.display().to_string();
    let mut needles = vec![
        dir_display.as_str(),
        "NeedleDataDirQuux7",
        "sqlite",
        "haven_mdk",
    ];
    needles.extend(OLD_KEY_IDS);
    assert_no_needles(&ours, &needles);
    for line in &ours {
        assert!(
            !line.message.chars().any(|c| c.is_ascii_digit()),
            "the reset reports a boolean, never a count: {}",
            line.message
        );
    }
}

#[tokio::test]
async fn only_the_users_data_owes_the_notice() {
    let _keyring = KEYRING.lock().await;
    install_fake_keyring();

    // An iOS keychain outlives an uninstall, so a fresh install can find the
    // old keys; a never-onboarded upgrader can have only the tile cache. Both
    // are deleted, and neither has anything to tell the user about.
    let keys_only = TempDir::new().expect("temp dir");
    plant_old_keys();
    assert!(
        !reset_pre_v2_storage(keys_only.path()),
        "orphaned keys alone owe no notice"
    );
    for key_id in old_key_entries() {
        assert!(!key_present(&key_id), "{key_id} is still destroyed");
    }
    let tiles_only = TempDir::new().expect("temp dir");
    std::fs::write(tiles_only.path().join("tiles.db"), b"cache").expect("plant");
    assert!(
        !reset_pre_v2_storage(tiles_only.path()),
        "a tile cache alone owes no notice"
    );
    assert!(!tiles_only.path().join("tiles.db").exists());

    for name in ["session.sqlite", "circles.db", "haven_mdk.db"] {
        let dir = TempDir::new().expect("temp dir");
        std::fs::write(dir.path().join(format!("{name}-wal")), b"pages").expect("plant");
        assert!(
            reset_pre_v2_storage(dir.path()),
            "{name} held the user's circles, so its deletion owes the notice"
        );
    }
}

#[cfg(unix)]
#[tokio::test]
async fn no_circle_is_deleted_without_the_notice_recorded_first() {
    let _keyring = KEYRING.lock().await;
    install_fake_keyring();
    let dir = TempDir::new().expect("temp dir");
    plant_pre_v2_state(dir.path());
    // A marker that cannot be written: a link into a directory that does not
    // exist, which `exists()` also reports as absent.
    let marker = dir.path().join(STORAGE_RESET_NOTICE_MARKER);
    std::os::unix::fs::symlink(dir.path().join("missing").join("marker"), &marker)
        .expect("plant an unwritable marker path");

    let lines = capture_haven_log(async {
        assert!(
            reset_pre_v2_storage(dir.path()),
            "a pass that could not record the notice still owes it"
        );
    })
    .await;
    let ours = haven_core_lines(&lines);
    assert!(
        ours.iter()
            .any(|l| l.message.contains("storage reset ran; complete=false")),
        "a pass that stopped short says so"
    );
    let dir_display = dir.path().display().to_string();
    let mut needles = vec![dir_display.as_str(), "missing", "sqlite", "haven_mdk"];
    needles.extend(OLD_KEY_IDS);
    assert_no_needles(&ours, &needles);
    assert_eq!(
        old_files_left(dir.path()).len(),
        OLD_FILES.len() * SIDECARS.len(),
        "a pass that cannot record the notice deletes nothing, or the user's \
         circles vanish without ever being explained"
    );
    assert!(
        !storage_reset_acknowledged(dir.path()),
        "and nothing publishes the defaults the reset is about to restore"
    );

    std::fs::remove_file(&marker).expect("clear the unwritable marker");
    assert!(
        reset_pre_v2_storage(dir.path()),
        "the next opener records the notice and deletes, in that order"
    );
    assert!(old_files_left(dir.path()).is_empty());
}

#[tokio::test]
async fn nothing_publishes_while_an_old_user_store_survives_the_reset() {
    let _keyring = KEYRING.lock().await;
    install_fake_keyring();
    let dir = TempDir::new().expect("temp dir");
    // A directory where the old store was: no unlink can remove it.
    std::fs::create_dir(dir.path().join("circles.db")).expect("plant an undeletable store");

    assert!(reset_pre_v2_storage(dir.path()));
    assert!(dir.path().join("circles.db").exists());
    acknowledge_storage_reset(dir.path()).expect("the user answers");
    assert!(
        !storage_reset_acknowledged(dir.path()),
        "the reset the user was told about has not finished, so the publish \
         gate stays shut"
    );
    assert!(
        reset_pre_v2_storage(dir.path()),
        "and the next opener owes the notice again"
    );

    std::fs::remove_dir(dir.path().join("circles.db")).expect("the store goes");
    acknowledge_storage_reset(dir.path()).expect("answered");
    assert!(storage_reset_acknowledged(dir.path()));
}

#[tokio::test]
async fn only_the_pass_that_removed_the_users_data_owes_clearing_the_app_preferences() {
    let _keyring = KEYRING.lock().await;
    install_fake_keyring();
    let dir = TempDir::new().expect("temp dir");
    std::fs::write(dir.path().join("tiles.db"), b"cache").expect("plant");
    let _ = reset_pre_v2_storage(dir.path());
    assert!(
        !storage_reset_prefs_owed(dir.path()),
        "a tile cache names no circle"
    );

    plant_pre_v2_state(dir.path());
    assert!(reset_pre_v2_storage(dir.path()));
    assert!(storage_reset_prefs_owed(dir.path()));
    let _ = reset_pre_v2_storage(dir.path());
    assert!(
        storage_reset_prefs_owed(dir.path()),
        "still owed to whichever launch clears them first"
    );

    storage_reset_prefs_cleared(dir.path()).expect("cleared");
    assert!(
        reset_pre_v2_storage(dir.path()),
        "the notice is a separate debt"
    );
    assert!(
        !storage_reset_prefs_owed(dir.path()),
        "a later pass that removed nothing never clears them again"
    );
}

#[tokio::test]
async fn preferences_cleared_once_are_never_owed_again_until_logout() {
    let _keyring = KEYRING.lock().await;
    install_fake_keyring();
    let dir = TempDir::new().expect("temp dir");
    // A directory where a store was: the pass sees the user's data and cannot
    // delete it, so every later opener retries.
    std::fs::create_dir(dir.path().join("circles.db")).expect("plant a store it cannot delete");
    assert!(reset_pre_v2_storage(dir.path()));
    assert!(storage_reset_prefs_owed(dir.path()), "precondition");

    storage_reset_prefs_cleared(dir.path()).expect("cleared");
    assert!(
        reset_pre_v2_storage(dir.path()),
        "the surviving store still owes the notice"
    );
    assert!(
        !storage_reset_prefs_owed(dir.path()),
        "a retry would otherwise clear preferences naming circles made since the reset"
    );

    forget_storage_reset(dir.path()).expect("the logout wipe forgets");
    assert!(
        !dir.path().join(STORAGE_RESET_NOTICE_MARKER).exists(),
        "the notice was this identity's"
    );
    assert!(reset_pre_v2_storage(dir.path()));
    assert!(
        storage_reset_prefs_owed(dir.path()),
        "the next identity is owed the clearing again"
    );
}

#[tokio::test]
async fn a_marker_a_failed_removal_left_behind_owes_nothing_once_clearing_is_recorded() {
    let _keyring = KEYRING.lock().await;
    install_fake_keyring();
    let dir = TempDir::new().expect("temp dir");
    plant_pre_v2_state(dir.path());
    assert!(reset_pre_v2_storage(dir.path()));
    storage_reset_prefs_cleared(dir.path()).expect("cleared");
    // What a removal that failed after the record was written leaves.
    std::fs::write(dir.path().join(STORAGE_RESET_PREFS_MARKER), []).expect("marker");

    assert!(
        !storage_reset_prefs_owed(dir.path()),
        "clearing again would wipe pending leaves made since the update"
    );

    forget_storage_reset(dir.path()).expect("the logout wipe forgets");
    assert!(
        !dir.path().join(STORAGE_RESET_PREFS_MARKER).exists(),
        "the leftover marker goes with the identity, or the next one is owed a \
         clear of preferences it has only just made"
    );
}

fn sample_jpeg() -> Vec<u8> {
    let mut img = image::RgbImage::new(96, 96);
    for (x, y, px) in img.enumerate_pixels_mut() {
        let r = u8::try_from(x % 256).unwrap_or(0);
        let g = u8::try_from(y % 256).unwrap_or(0);
        *px = image::Rgb([r, g, 42]);
    }
    let mut out = Vec::new();
    image::codecs::jpeg::JpegEncoder::new_with_quality(std::io::Cursor::new(&mut out), 88)
        .encode_image(&img)
        .expect("encode jpeg");
    out
}

/// "Any profile change that had not finished saving by then was removed": an
/// unsent name and a staged photo a pre-update build left in its circle store
/// are gone after the reset, and nothing of them reaches the new store.
#[tokio::test]
async fn a_profile_edit_staged_before_the_update_does_not_survive_the_reset() {
    let _keyring = KEYRING.lock().await;
    install_fake_keyring();
    let dir = TempDir::new().expect("temp dir");
    let keys = Keys::generate();
    let me = keys.public_key().to_hex();
    {
        let old = CircleStorage::new(&dir.path().join("circles.db"), Some(CIRCLES_KEY_HEX))
            .expect("the pre-update circle store");
        let edits = PendingEdits {
            display_name: Some("Unsent Pseudonym".to_string()),
            about: None,
        };
        old.stage_own_profile_edits(&me, &edits, 1_700_000_000)
            .expect("stage the name");
        let photo = process_own_avatar(&sample_jpeg()).expect("sanitize");
        old.stage_own_profile_picture(&me, &StagedPicture::from_processed(&photo), 1_700_000_000)
            .expect("stage the photo");
        let staged = old.get_profile(&me).unwrap();
        assert_eq!(
            staged.as_ref().and_then(|p| p.metadata.display_name()),
            Some("Unsent Pseudonym"),
            "anti-vacuity: the name is staged"
        );
        assert!(
            old.get_profile_picture(&me).unwrap().is_some(),
            "and the photo"
        );
    }

    let manager = CircleManager::new(dir.path(), &keys, Some(CIRCLES_KEY_HEX))
        .expect("the first open after the update");

    assert!(
        !dir.path().join("circles.db").exists(),
        "the store that held them is deleted"
    );
    assert!(
        manager.get_profile(&me).unwrap().is_none(),
        "the unsent name is gone"
    );
    assert!(
        manager.get_profile_picture(&me).unwrap().is_none(),
        "the staged photo is gone"
    );
}

/// Before Haven verified relay events itself, a relay could plant a forged
/// profile dated far in the future, and the cache keeps the newer of two — so
/// that row would have outranked every genuine profile for good. The same
/// store held the picture bytes downloaded for it and the sync cursors a
/// forged group message could have moved. The reset deletes that store, so on
/// an updated install each of them is first written from verified events.
#[tokio::test]
async fn nothing_a_relay_planted_before_the_update_outlives_the_reset() {
    let _keyring = KEYRING.lock().await;
    install_fake_keyring();
    let dir = TempDir::new().expect("temp dir");
    let keys = Keys::generate();
    let member = Keys::generate().public_key().to_hex();
    let cursor_stream = "group_445:planted";
    let profile = |name: &str, event_created_at: i64| CachedProfile {
        pubkey_hex: member.clone(),
        metadata: ProfileMetadata::from_metadata(Metadata::new().display_name(name)),
        state: ProfileState::Known,
        event_created_at,
        fetched_at: 1_700_000_000,
    };
    {
        let old = CircleStorage::new(&dir.path().join("circles.db"), Some(CIRCLES_KEY_HEX))
            .expect("the pre-update circle store");
        old.upsert_profile(&profile("Planted", 4_000_000_000))
            .expect("plant the profile");
        old.upsert_profile_picture(
            &member,
            "https://attacker.example.com/a.jpg",
            &[7; 32],
            b"canonical bytes",
            b"thumbnail bytes",
            1_700_000_000,
        )
        .expect("plant its picture");
        old.update_sync_cursor_max(cursor_stream, 4_000_000_000_000)
            .expect("plant a cursor");
        assert!(
            !old.upsert_profile_if_newer(&profile("Genuine", 1_700_000_000))
                .unwrap(),
            "anti-vacuity: in the old store the planted row outranks a genuine one"
        );
    }

    let manager = CircleManager::new(dir.path(), &keys, Some(CIRCLES_KEY_HEX))
        .expect("the first open after the update");

    assert!(
        old_files_left(dir.path()).is_empty(),
        "the store that held them is deleted"
    );
    assert!(manager.get_profile(&member).unwrap().is_none());
    assert!(manager.get_profile_picture(&member).unwrap().is_none());
    assert_eq!(manager.read_sync_cursor(cursor_stream).unwrap(), None);
    assert!(
        manager
            .upsert_profile_if_newer(&profile("Genuine", 1_700_000_000))
            .unwrap(),
        "a genuine profile older than the planted one is accepted"
    );
    assert_eq!(
        manager
            .get_profile(&member)
            .unwrap()
            .and_then(|row| row.metadata.display_name().map(str::to_owned)),
        Some("Genuine".to_owned())
    );
}
