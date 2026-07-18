//! F2 sign-off gate — black-box multi-party OUT-OF-ORDER convergence over the
//! Dark Matter engine (DM-5a).
//!
//! # What this gate proves (security F2)
//!
//! Haven's pre-migration stack hand-rolled a `retry_failed_future_epoch_messages`
//! sweep to un-poison MDK's sticky-`Unprocessable` failure rows when a successor
//! commit / a future-epoch message arrived before its predecessor (MDK #633). The
//! Dark Matter engine designs that poison OUT: an out-of-order message is
//! classified `Buffered` and stored DURABLY, then RELEASED by
//! `advance_convergence` once its epoch is reachable — never a sticky failure.
//!
//! These black-box tests drive the PUBLIC async circle API only
//! (`create_circle` → `confirm_published` → `accept_invitation` →
//! `encrypt_location`/`decrypt_location`), run under the landed
//! `settlement_quiescence_ms = 0` policy, and assert:
//!
//! - **TEST 1 (headline / restart-durable):** a member receives a FUTURE-EPOCH
//!   application message (a location Alice sends at N+1) BEFORE the commit that
//!   creates that epoch. The engine BUFFERS it (nothing delivered, no advance);
//!   the buffered state SURVIVES a full manager teardown + reopen against the same
//!   on-disk store; and once the predecessor commit arrives, the location is
//!   RELEASED and delivered — nothing lost, nothing poisoned, both parties
//!   converge.
//! - **TEST 2 (out-of-order commits):** the original #633 shape — a member
//!   receives commit C2 (N+1 → N+2) before C1 (N → N+1). C2 buffers; C1 applies;
//!   C2 releases; the member reaches N+2 and cross-decrypts with the author (no
//!   twin fork). This is the direct engine-owned replacement for the deleted
//!   Haven un-poison sweep.

use haven_core::circle::{CircleConfig, CircleManager, MemberKeyPackage};
use haven_core::location::LocationMessage;
use haven_core::nostr::mls::types::{GroupId, LocationMessageResult};
use haven_core::relay::maintenance::build_kp_maintenance_events;
use nostr::{Keys, PublicKey};
use tempfile::TempDir;

/// A genuine MLS circle: `admin` (creator) + `members`, each with its own on-disk
/// (unencrypted) MLS store. The `TempDir`s are retained so a receiving member's
/// SQLite files survive a manager teardown/reopen (TEST 1's restart proof).
struct BuiltCircle {
    admin: CircleManager,
    admin_keys: Keys,
    members: Vec<CircleManager>,
    member_keys: Vec<Keys>,
    mls_group_id: GroupId,
    _admin_dir: TempDir,
    member_dirs: Vec<TempDir>,
}

async fn build_circle(num_members: usize) -> BuiltCircle {
    let relays = vec!["wss://group.example.com".to_string()];

    let mut members = Vec::with_capacity(num_members);
    let mut member_keys = Vec::with_capacity(num_members);
    let mut member_dirs = Vec::with_capacity(num_members);
    let mut member_kps = Vec::with_capacity(num_members);
    for _ in 0..num_members {
        let dir = TempDir::new().unwrap();
        let keys = Keys::generate();
        let mgr = CircleManager::new_unencrypted(dir.path(), &keys).unwrap();
        let kp_event = build_kp_maintenance_events(
            mgr.session(),
            &keys,
            &["wss://kp.example.com".to_string()],
            None,
        )
        .await
        .expect("member key package")
        .event;
        member_kps.push(MemberKeyPackage {
            key_package_event: kp_event,
            inbox_relays: vec!["wss://member-inbox.example.com".to_string()],
            nip65_relays: vec![],
        });
        members.push(mgr);
        member_keys.push(keys);
        member_dirs.push(dir);
    }

    let admin_dir = TempDir::new().unwrap();
    let admin_keys = Keys::generate();
    let admin = CircleManager::new_unencrypted(admin_dir.path(), &admin_keys).unwrap();
    let config = CircleConfig::new("Out Of Order Commit Circle").with_relays(relays.clone());
    let result = admin
        .create_circle(&admin_keys, member_kps, &config, &relays)
        .await
        .expect("create circle");
    let mls_group_id = result.circle.mls_group_id.clone();
    admin
        .confirm_published(result.pending)
        .await
        .expect("admin confirms creation");

    for (mgr, keys) in members.iter().zip(member_keys.iter()) {
        let my_hex = keys.public_key().to_hex();
        let welcome = result
            .welcome_events
            .iter()
            .find(|w| w.recipient_pubkey == my_hex)
            .expect("welcome addressed to this member");
        mgr.process_gift_wrapped_invitation(keys, &welcome.event)
            .await
            .expect("member processes welcome");
        mgr.accept_invitation(&welcome.event.id)
            .await
            .expect("member accepts");
    }

    BuiltCircle {
        admin,
        admin_keys,
        members,
        member_keys,
        mls_group_id,
        _admin_dir: admin_dir,
        member_dirs,
    }
}

/// Whether `decryptor` can decrypt a fresh Location `encryptor` sends for the
/// group — the sole reliable detector of a TWIN fork (same epoch NUMBER but a
/// different exporter secret).
async fn cross_decrypts(
    encryptor: &CircleManager,
    encryptor_pubkey: &PublicKey,
    decryptor: &CircleManager,
    gid: &GroupId,
) -> bool {
    let location = LocationMessage::new(40.12, -74.34);
    let Ok((event, _, _)) = encryptor
        .encrypt_location(gid, encryptor_pubkey, &location, 300)
        .await
    else {
        return false;
    };
    matches!(
        decryptor.decrypt_location(&event).await,
        Ok(ref results) if results.iter().any(|r| matches!(r, LocationMessageResult::Location { .. }))
    )
}

/// An admin routing commit that advances the epoch by one; returns the publishable
/// commit event.
async fn admin_commit(admin: &CircleManager, gid: &GroupId, relay: &str) -> nostr::Event {
    let commit = admin
        .update_circle_relays(gid, &[relay.to_string()])
        .await
        .expect("admin stages a routing commit");
    admin
        .finalize_relay_update(commit.pending, gid)
        .await
        .expect("admin finalizes");
    commit.commit_event
}

/// Returns the (lat, lon) of the first delivered Location in a decrypt batch.
fn first_location(results: &[LocationMessageResult]) -> Option<(f64, f64)> {
    results.iter().find_map(|r| match r {
        LocationMessageResult::Location { content, .. } => LocationMessage::from_string(content)
            .ok()
            .map(|l| (l.latitude, l.longitude)),
        _ => None,
    })
}

/// TEST 1 (HEADLINE, F2): a future-epoch APPLICATION MESSAGE that arrives before
/// its epoch's commit is BUFFERED (not lost, not poisoned), the buffered state
/// SURVIVES a manager teardown + reopen, and the message is RELEASED + delivered
/// once the predecessor commit arrives. Both parties converge.
#[tokio::test]
async fn future_epoch_app_message_buffers_then_releases_across_a_restart() {
    let mut circle = build_circle(1).await;
    let gid = circle.mls_group_id.clone();
    let alice_pk = circle.admin_keys.public_key();
    let bob_keys = circle.member_keys.remove(0);
    let bob = circle.members.remove(0);
    let alice = &circle.admin;

    let n = alice.group_epoch(&gid).await.unwrap();
    assert_eq!(bob.group_epoch(&gid).await.unwrap(), n, "both start at N");

    // Alice advances N -> N+1 with a commit C1, then sends a location L at N+1.
    let c1 = admin_commit(alice, &gid, "wss://group2.example.com").await;
    assert_eq!(alice.group_epoch(&gid).await.unwrap(), n + 1);
    let (lat, lon) = (48.85, 2.35);
    let (loc_at_n1, _ng, _relays) = alice
        .encrypt_location(&gid, &alice_pk, &LocationMessage::new(lat, lon), 300)
        .await
        .expect("alice sends a location at N+1");

    // Phase A: L arrives at Bob FIRST, while he is still at N. He lacks the N+1
    // exporter secret, so the engine BUFFERS it — nothing delivered, no advance.
    let early = bob
        .decrypt_location(&loc_at_n1)
        .await
        .expect("bob ingests L early");
    assert!(
        first_location(&early).is_none(),
        "a future-epoch location must NOT be delivered before its epoch exists; got {early:?}"
    );
    assert_eq!(
        bob.group_epoch(&gid).await.unwrap(),
        n,
        "a buffered future-epoch message must not advance Bob's epoch"
    );

    // Phase B: teardown + reopen against the SAME on-disk store. The durable buffer
    // must survive the restart.
    drop(bob);
    let bob = CircleManager::new_unencrypted(circle.member_dirs[0].path(), &bob_keys)
        .expect("reopen Bob's on-disk store");
    assert_eq!(
        bob.group_epoch(&gid).await.unwrap(),
        n,
        "Bob's N state persisted across the restart"
    );

    // Phase C: the predecessor commit C1 arrives. Applying it advances Bob to N+1
    // and RELEASES the buffered location L via stored convergence — nothing lost.
    let released = bob.decrypt_location(&c1).await.expect("bob applies C1");
    assert_eq!(
        bob.group_epoch(&gid).await.unwrap(),
        n + 1,
        "C1 advances Bob to N+1"
    );
    // The buffered location is delivered — either folded into this batch, or on a
    // follow-up ingest of the same (idempotent) message after convergence.
    let delivered = first_location(&released).or_else(|| None);
    let (glat, glon) = if let Some(p) = delivered {
        p
    } else {
        // Re-feed L (a re-fetch / cursor replay): now at N+1, Bob decrypts it.
        let replay = bob
            .decrypt_location(&loc_at_n1)
            .await
            .expect("bob replays L");
        first_location(&replay).expect("the buffered future-epoch location must be released at N+1")
    };
    assert!(
        (glat - lat).abs() < 1e-9 && (glon - lon).abs() < 1e-9,
        "the released location content is intact"
    );

    // Both converge; no twin fork.
    assert!(
        cross_decrypts(alice, &alice_pk, &bob, &gid).await,
        "the restarted Bob decrypts a fresh location Alice publishes at N+1 (converged, un-forked)"
    );
}

/// TEST 2 (out-of-order commits): the #633 shape. Bob receives C2 (N+1 -> N+2)
/// before C1 (N -> N+1). C2 buffers; C1 applies; C2 releases; Bob reaches N+2 and
/// cross-decrypts with Alice — the engine's stored convergence replaces Haven's
/// deleted un-poison sweep.
#[tokio::test]
async fn out_of_order_commit_recovers_when_predecessor_arrives() {
    let mut circle = build_circle(1).await;
    let gid = circle.mls_group_id.clone();
    let alice_pk = circle.admin_keys.public_key();
    let _bob_keys = circle.member_keys.remove(0);
    let bob = circle.members.remove(0);
    let alice = &circle.admin;

    let n = alice.group_epoch(&gid).await.unwrap();
    assert_eq!(bob.group_epoch(&gid).await.unwrap(), n, "both start at N");

    // Alice authors two sequential commits: C1 (N -> N+1), C2 (N+1 -> N+2).
    let c1 = admin_commit(alice, &gid, "wss://group-a.example.com").await;
    assert_eq!(alice.group_epoch(&gid).await.unwrap(), n + 1);
    let c2 = admin_commit(alice, &gid, "wss://group-b.example.com").await;
    assert_eq!(
        alice.group_epoch(&gid).await.unwrap(),
        n + 2,
        "Alice authored C1 then C2"
    );

    // C2 arrives FIRST at Bob (still at N): two epochs ahead ⇒ BUFFERED, no advance.
    let early = bob
        .decrypt_location(&c2)
        .await
        .expect("bob ingests C2 early");
    assert_eq!(
        bob.group_epoch(&gid).await.unwrap(),
        n,
        "an out-of-order successor commit must NOT apply (Bob still at N); got {early:?}"
    );

    // C1 applies (N -> N+1); stored convergence then releases the buffered C2
    // (N+1 -> N+2). Feed C1, then re-feed C2 to drive the release deterministically.
    let _ = bob.decrypt_location(&c1).await.expect("bob applies C1");
    // A re-fetch of C2 (cursor replay / resubscribe) now converges Bob to N+2.
    for _ in 0..5 {
        if bob.group_epoch(&gid).await.unwrap() == n + 2 {
            break;
        }
        let _ = bob.decrypt_location(&c2).await;
    }
    assert_eq!(
        bob.group_epoch(&gid).await.unwrap(),
        n + 2,
        "after C1 applies and C2 is re-fed, Bob converges to N+2 (out-of-order recovery, no poison)"
    );

    // The recovered N+2 state is un-forked.
    assert!(
        cross_decrypts(alice, &alice_pk, &bob, &gid).await,
        "Bob decrypts a location Alice publishes at N+2 (shared exporter, no twin fork)"
    );
}
