//! Saving a profile while every relay is unreachable.
//!
//! The offline case is the reason the outbox is durable at all, and it is the
//! one where an app is most tempted to lie: the edit is applied locally, so the
//! screen looks right, and it would be easy to report success. These tests pin
//! the opposite — the save survives, the app says it has NOT been published,
//! and the retry paces itself instead of re-dialling the whole pool on every
//! foreground.
//!
//! # Its own binary
//!
//! `set_profile_relays_for_test` writes a process-global `OnceLock`, so a
//! process can hold exactly one pool. This one is entirely unreachable, which
//! is incompatible with the live pool the sibling binary
//! (`profile_local_first_sync_e2e.rs`) needs — hence a second binary, one
//! install each (Check 12 of `check_profile_privacy_boundaries.sh`).
//!
//! The "offline" relays are loopback ports with no listener: a refused
//! connection, the same shape as a host that has left the network, and
//! deterministic rather than dependent on a timeout elapsing.

use haven_core::avatar::{process_own_avatar, StagedPicture};
use haven_core::circle::{CircleManager, ProfileSyncCommit, ProfileSyncOutcome};
use haven_core::profile::{
    allow_private_blossom_for_test, build_metadata_event, set_blossom_server_for_test,
    set_profile_relays_for_test, PendingEdits, ProfileMetadata, PROFILE_SYNC_BACKOFF_SECS,
};
use haven_core::relay::allow_ws_loopback_for_test;
use image::{codecs::jpeg::JpegEncoder, RgbImage};
use nostr::{JsonUtil as _, Keys, Metadata};
use tempfile::TempDir;

/// Exactly `PROFILE_POOL_MIN`, so the pool RESOLVES (this is an offline test,
/// not an underflow test) while none of its relays can answer.
const POOL_SIZE: usize = 3;

/// Injected sync clock (Unix seconds). Only relative ordering matters.
const NOW: i64 = 1_800_000_000;

static PLANE: std::sync::OnceLock<()> = std::sync::OnceLock::new();

/// A loopback URL that refuses every connection: bind an ephemeral port to
/// reserve it, then drop the listener before returning.
fn dead_relay_url() -> String {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind ephemeral port");
    let port = listener.local_addr().expect("local addr").port();
    drop(listener);
    format!("ws://127.0.0.1:{port}")
}

/// Installs (once) a pool of the right SIZE whose every relay is unreachable.
fn offline_plane() {
    PLANE.get_or_init(|| {
        let _ = allow_ws_loopback_for_test();
        let urls: Vec<String> = (0..POOL_SIZE).map(|_| dead_relay_url()).collect();
        set_profile_relays_for_test(urls).expect("install the pool override once per process");
    });
}

/// A fresh identity plus its own manager, over the offline pool.
fn account() -> (TempDir, CircleManager, Keys, String) {
    offline_plane();
    let dir = TempDir::new().expect("temp dir");
    let keys = Keys::generate();
    let manager = CircleManager::new_unencrypted(dir.path(), &keys).expect("manager opens");
    let own_hex = keys.public_key().to_hex();
    (dir, manager, keys, own_hex)
}

fn name_edit(display_name: &str) -> PendingEdits {
    PendingEdits {
        display_name: Some(display_name.to_string()),
        ..PendingEdits::default()
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_unreachable_pool_leaves_the_edit_pending_with_a_backoff() {
    let (_dir, manager, keys, own_hex) = account();
    assert_eq!(
        manager
            .usable_profile_relays()
            .expect("pool resolves")
            .len(),
        POOL_SIZE,
        "the pool must RESOLVE — this is an offline test, not an underflow one",
    );

    manager
        .stage_own_profile_edits(&own_hex, &name_edit("Saved Offline"), NOW)
        .expect("stage");
    let version = manager
        .pending_profile_sync(&own_hex)
        .unwrap()
        .expect("pending")
        .local_version;
    let report = manager
        .sync_own_profile(&keys.public_key(), Some(&keys), || NOW)
        .await
        .expect("a failed publish is an outcome, never an error");

    assert_eq!(report.outcome, ProfileSyncOutcome::PublishFailed);
    assert!(
        manager
            .profile_publish_debt(&keys.public_key(), version)
            .unwrap()
            .is_none(),
        "no relay took an event, so none is owed and the next pass signs afresh",
    );
    assert!(
        report.still_pending,
        "the save must survive the failure — that is what the outbox is for",
    );

    let state = manager.profile_pending_state(&own_hex, NOW).unwrap();
    assert!(state.pending);
    assert!(
        !manager.has_published_profile(&keys.public_key()).unwrap(),
        "nothing reached any relay, so nothing may be reported as published",
    );
    assert!(
        !state.retry_due,
        "the failure must arm the ladder rather than leave every foreground \
         trigger free to re-dial the whole pool",
    );
    assert_eq!(
        manager
            .pending_profile_sync(&own_hex)
            .unwrap()
            .expect("still queued")
            .edits,
        name_edit("Saved Offline"),
        "the pending set must be intact for the retry to carry",
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_local_row_still_shows_the_edit_while_it_is_pending() {
    let (_dir, manager, keys, own_hex) = account();

    manager
        .stage_own_profile_edits(&own_hex, &name_edit("Offline Name"), NOW)
        .expect("stage");
    let report = manager
        .sync_own_profile(&keys.public_key(), Some(&keys), || NOW)
        .await
        .expect("sync");
    assert_eq!(report.outcome, ProfileSyncOutcome::PublishFailed);

    let stored = manager
        .get_profile(&own_hex)
        .unwrap()
        .expect("the local row exists");
    assert_eq!(
        stored.metadata.display_name(),
        Some("Offline Name"),
        "a failed publish must never roll the user's own edit back on screen",
    );
    assert_eq!(
        stored.event_created_at, 0,
        "and it must not claim a supersede floor no relay ever saw — that would \
         make the eventual republish tie the event it is meant to replace",
    );
    assert!(
        !manager.has_published_profile(&keys.public_key()).unwrap(),
        "nothing public exists yet, so a retraction must still be a no-op",
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_auto_retry_is_gated_until_the_ladder_says_so() {
    let (_dir, manager, keys, own_hex) = account();

    manager
        .stage_own_profile_edits(&own_hex, &name_edit("Waiting"), NOW)
        .expect("stage");
    assert!(
        manager
            .profile_pending_state(&own_hex, NOW)
            .unwrap()
            .retry_due,
        "a fresh save is due immediately — nothing has failed yet",
    );

    let report = manager
        .sync_own_profile(&keys.public_key(), Some(&keys), || NOW)
        .await
        .expect("sync");
    assert_eq!(report.outcome, ProfileSyncOutcome::PublishFailed);

    let rung = PROFILE_SYNC_BACKOFF_SECS[0];
    assert!(
        !manager
            .profile_pending_state(&own_hex, NOW + rung - 1)
            .unwrap()
            .retry_due,
        "one second early is still backed off",
    );
    assert!(
        manager
            .profile_pending_state(&own_hex, NOW + rung)
            .unwrap()
            .retry_due,
        "at the scheduled instant the retry is due",
    );

    // A fresh user action outranks the ladder: making someone's new name wait
    // out a backoff earned by an earlier failure is the app refusing to do what
    // it was just told.
    manager
        .stage_own_profile_edits(&own_hex, &name_edit("Waiting v2"), NOW + 1)
        .expect("stage again");
    let state = manager.profile_pending_state(&own_hex, NOW + 1).unwrap();
    assert!(state.pending);
    assert!(state.retry_due, "a save resets the ladder");
}

/// A distinct 96x96 JPEG per `seed`.
fn jpeg(seed: u8) -> Vec<u8> {
    let mut img = RgbImage::new(96, 96);
    for (x, y, px) in img.enumerate_pixels_mut() {
        let r = u8::try_from(x % 256).unwrap_or(0);
        let g = u8::try_from(y % 256).unwrap_or(0);
        *px = image::Rgb([r, g, seed]);
    }
    let mut out = Vec::new();
    JpegEncoder::new_with_quality(std::io::Cursor::new(&mut out), 88)
        .encode_image(&img)
        .expect("encode jpeg");
    out
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
// The mock server and its guard must live for the whole test.
#[allow(clippy::significant_drop_tightening)]
async fn a_picture_whose_publish_no_relay_took_is_uploaded_once_per_pass_and_stays_staged() {
    let (_dir, manager, keys, own_hex) = account();
    let _ = allow_private_blossom_for_test();
    let mut blossom = mockito::Server::new_async().await;
    let staged = StagedPicture::from_processed(&process_own_avatar(&jpeg(30)).expect("sanitize"));
    let sha_hex = hex::encode(staged.sha256());
    let descriptor = format!(
        r#"{{"url":"{}/{sha_hex}","sha256":"{sha_hex}","size":{},"type":"image/jpeg","uploaded":1700000000}}"#,
        blossom.url(),
        staged.canonical().len(),
    );
    // A Blossom re-upload of the same bytes is idempotent, so a pass that finds
    // the photo still staged uploads it again instead of persisting a URL a
    // server may since have collected: exactly one PUT per pass.
    let upload = blossom
        .mock("PUT", "/upload")
        .with_status(201)
        .with_body(descriptor)
        .expect(2)
        .create_async()
        .await;
    set_blossom_server_for_test(blossom.url()).expect("install the Blossom override once");

    manager
        .stage_own_profile_picture(&own_hex, &staged, NOW)
        .expect("stage the picture");
    for (pass, now) in [NOW, NOW + PROFILE_SYNC_BACKOFF_SECS[1] + 1]
        .into_iter()
        .enumerate()
    {
        let report = manager
            .sync_own_profile(&keys.public_key(), Some(&keys), move || now)
            .await
            .expect("sync");
        assert_eq!(
            report.outcome,
            ProfileSyncOutcome::PublishFailed,
            "pass {pass}"
        );
        assert!(report.still_pending);
        assert!(
            manager.profile_picture_is_staged(&own_hex).unwrap(),
            "no relay took the publish, so the photo is still owed",
        );
    }
    upload.assert_async().await;
    assert!(!manager.has_published_profile(&keys.public_key()).unwrap());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_photo_removal_offline_is_instant_and_stays_owed() {
    let (_dir, manager, keys, own_hex) = account();
    let pool = manager.usable_profile_relays().expect("pool resolves");

    // An account that published a profile with a photo earlier.
    manager
        .stage_own_profile_edits(&own_hex, &name_edit("Has A Photo"), NOW)
        .expect("stage");
    let version = manager
        .pending_profile_sync(&own_hex)
        .unwrap()
        .expect("pending")
        .local_version;
    let merged = ProfileMetadata::from_metadata(
        Metadata::from_json(
            r#"{"display_name":"Has A Photo","picture":"https://blossom.example/abc"}"#,
        )
        .expect("metadata"),
    );
    let published = build_metadata_event(&keys, &merged, None).expect("builds");
    manager
        .commit_profile_sync(&ProfileSyncCommit {
            pubkey: &keys.public_key(),
            version,
            merged: &merged,
            event: &published,
            uploaded_picture: None,
            covered: &pool,
            pool: &pool,
            complete: true,
            now: NOW,
        })
        .expect("the earlier publish");
    assert!(manager.has_published_profile(&keys.public_key()).unwrap());
    assert!(
        !manager
            .profile_pending_state(&own_hex, NOW)
            .unwrap()
            .pending
    );

    let row = manager
        .stage_own_picture_removal(&own_hex, NOW + 1)
        .expect("remove the photo while offline");
    assert_eq!(row.metadata.picture(), None, "the photo is gone at once");
    assert_eq!(row.metadata.display_name(), Some("Has A Photo"));

    let report = manager
        .sync_own_profile(&keys.public_key(), Some(&keys), || NOW + 2)
        .await
        .expect("sync");
    assert_eq!(report.outcome, ProfileSyncOutcome::PublishFailed);
    assert!(report.still_pending, "the removal is owed, not dropped");
    assert!(
        manager
            .pending_profile_sync(&own_hex)
            .unwrap()
            .expect("owed")
            .edits
            .clear_picture
    );
    assert_eq!(
        manager
            .get_profile(&own_hex)
            .unwrap()
            .unwrap()
            .metadata
            .picture(),
        None,
        "a failed publish never brings the photo back on screen",
    );
    assert!(
        !manager
            .profile_pending_state(&own_hex, NOW + 2)
            .unwrap()
            .retry_due,
        "and the failure armed the ladder",
    );
}
