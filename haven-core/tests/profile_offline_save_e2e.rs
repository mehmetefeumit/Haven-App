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

use haven_core::circle::{CircleManager, ProfileSyncOutcome};
use haven_core::profile::{set_profile_relays_for_test, PendingEdits, PROFILE_SYNC_BACKOFF_SECS};
use haven_core::relay::allow_ws_loopback_for_test;
use nostr::Keys;
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
        about: None,
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
    let report = manager
        .sync_own_profile(&keys, NOW)
        .await
        .expect("a failed publish is an outcome, never an error");

    assert_eq!(report.outcome, ProfileSyncOutcome::PublishFailed);
    assert_eq!(report.relays_acked, 0);
    assert_eq!(
        report.relays_attempted,
        u32::try_from(POOL_SIZE).unwrap(),
        "the whole pool was tried; reporting 0 attempted would hide that",
    );
    assert!(
        report.still_pending,
        "the save must survive the failure — that is what the outbox is for",
    );

    let state = manager.profile_pending_state(&own_hex, NOW).unwrap();
    assert!(state.pending);
    assert!(
        !state.partial,
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
    let report = manager.sync_own_profile(&keys, NOW).await.expect("sync");
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

    let report = manager.sync_own_profile(&keys, NOW).await.expect("sync");
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
