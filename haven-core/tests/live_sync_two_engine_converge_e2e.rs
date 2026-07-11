//! Real-MLS-circle engine integration tests over an in-process `MockRelay`.
//!
//! The two-admin / two-party fixtures used by the in-crate convergence suite
//! (`circle/manager.rs`, `relay/live_sync/finalize.rs`) live in `#[cfg(test)]`
//! modules and are therefore NOT reachable from an integration test. So each
//! test here builds a genuine two-member circle through the PUBLIC API
//! (`create_key_package` → `create_circle` → `process_gift_wrapped_invitation`
//! → `accept_invitation`), exactly mirroring `finalize.rs::setup_two_party_core`.
//!
//! Houses:
//! - **R1 (flagship, marmot G1)** — two wired `LiveSyncCore`s over one relay,
//!   both members staging a same-epoch `self_update`; the settle window collects
//!   the peer commit over the relay and both converge bilaterally (one `Merged`,
//!   one `AdoptedWinner`, equal epoch N+1, cross-decrypt BOTH ways — the only
//!   twin-fork detector — and the winner matches the off-wire MIP-03 order key).
//! - **R2 (rust GAP-C)** — a GENUINE same-epoch sibling commit (Bob's real
//!   `self_update`) arriving over the relay while a settle window is open is
//!   BUFFERED via the full receive path (regime 2), never decrypted/applied
//!   (epoch stays N). Because the competitor is a real epoch-advancing commit,
//!   `epoch == N` proves the buffer prevented the fork-inducing blind-apply MDK
//!   would otherwise perform on a same-epoch sibling — not merely that an inert
//!   undecryptable event did nothing.
//! - **R5 (marmot G4 / rust GAP-D)** — concurrent engine-receive + foreground-
//!   converge on ONE circle: while Alice's foreground stages + converges her own
//!   `self_update`, her engine worker CONCURRENTLY buffers Bob's REAL same-epoch
//!   commit; the two converge to the single MIP-03 winner — the epoch advances by
//!   EXACTLY one (never N+2 / a fork) and the group still cross-decrypts BOTH
//!   ways. The DIRECT per-circle-gate mutual-exclusion proof is
//!   `finalize.rs::the_finalize_path_contends_the_engine_per_circle_gate`.

use std::sync::Arc;
use std::time::Duration;

use haven_core::circle::{
    CircleConfig, CircleManager, CommitConvergence, CommitIntent, MemberKeyPackage,
};
use haven_core::location::LocationMessage;
use haven_core::nostr::mls::types::{GroupId, LocationMessageResult};
use haven_core::relay::live_sync::{CircleSpec, LiveSyncCore};
use nostr::{Event, EventBuilder, JsonUtil, Keys, Kind, PublicKey, Tag};
use nostr_relay_builder::MockRelay;
use nostr_sdk::Client;
use tempfile::TempDir;

/// A genuine two-member circle (Alice admin + Bob co-member), each with their
/// own real MLS store, ready to wrap in a [`LiveSyncCore`].
struct TwoMemberCircle {
    alice: Arc<CircleManager>,
    alice_keys: Keys,
    bob: Arc<CircleManager>,
    bob_keys: Keys,
    mls_group_id: GroupId,
    nostr_group_id: [u8; 32],
    _alice_dir: TempDir,
    _bob_dir: TempDir,
}

/// Builds Alice + Bob as real co-members via the PUBLIC circle API (create →
/// welcome → accept), so Bob is a genuine member whose location Alice can
/// cross-decrypt. Mirrors `finalize.rs::setup_two_party_core`.
async fn build_two_member_circle() -> TwoMemberCircle {
    // Bob: a real manager whose own key package lets him actually join.
    let bob_dir = TempDir::new().unwrap();
    let bob = CircleManager::new_unencrypted(bob_dir.path()).unwrap();
    let bob_keys = Keys::generate();
    let bundle = bob
        .create_key_package(
            &bob_keys.public_key().to_hex(),
            &["wss://kp.example.com".to_string()],
        )
        .expect("bob key package");
    let tags: Vec<Tag> = bundle
        .tags_443
        .into_iter()
        .map(|t| Tag::parse(&t).unwrap())
        .collect();
    let bob_kp_event = EventBuilder::new(Kind::MlsKeyPackage, bundle.content)
        .tags(tags)
        .sign_with_keys(&bob_keys)
        .expect("sign bob key package");
    let bob_member = MemberKeyPackage {
        key_package_event: bob_kp_event,
        inbox_relays: vec!["wss://member-inbox.example.com".to_string()],
        nip65_relays: vec![],
    };

    // Alice: admin, creates the circle including Bob.
    let alice_dir = TempDir::new().unwrap();
    let alice = CircleManager::new_unencrypted(alice_dir.path()).unwrap();
    let alice_keys = Keys::generate();
    let config = CircleConfig::new("Two Engine Converge Circle")
        .with_relays(vec!["wss://group.example.com".to_string()]);
    let result = alice
        .create_circle(&alice_keys, vec![bob_member], &config, &[])
        .await
        .expect("create circle");
    let mls_group_id = result.circle.mls_group_id.clone();
    let nostr_group_id = result.circle.nostr_group_id;

    // Bob joins from the gift-wrapped welcome.
    let welcome = &result.welcome_events[0];
    let invitation = bob
        .process_gift_wrapped_invitation(&bob_keys, &welcome.event)
        .await
        .expect("bob processes welcome");
    bob.accept_invitation(&invitation.mls_group_id)
        .expect("bob accepts");

    TwoMemberCircle {
        alice: Arc::new(alice),
        alice_keys,
        bob: Arc::new(bob),
        bob_keys,
        mls_group_id,
        nostr_group_id,
        _alice_dir: alice_dir,
        _bob_dir: bob_dir,
    }
}

/// Whether `decryptor` can decrypt a fresh Location `encryptor` sends for the
/// group — the sole reliable detector of a TWIN fork (same epoch number but a
/// different exporter secret). Mirrors `circle/manager.rs::cross_decrypts`.
fn cross_decrypts(
    encryptor: &CircleManager,
    encryptor_pubkey: &PublicKey,
    decryptor: &CircleManager,
    gid: &GroupId,
) -> bool {
    let location = LocationMessage::new(40.12, -74.34);
    let Ok((event, _, _)) = encryptor.encrypt_location(gid, encryptor_pubkey, &location, 300)
    else {
        return false;
    };
    matches!(
        decryptor.decrypt_location(&event),
        Ok(LocationMessageResult::Location { .. })
    )
}

/// The MIP-03 order key `(created_at seconds, lowercase-hex id)` computed
/// off-wire from a published commit — the winner is the global minimum.
fn order_key(e: &Event) -> (u64, String) {
    (e.created_at.as_secs(), e.id.to_hex())
}

/// Publishes an already-built commit event to `url`.
async fn publish_event(url: &str, event: &Event) {
    let publisher = Client::builder().build();
    publisher.add_relay(url).await.unwrap();
    publisher.connect().await;
    publisher.send_event(event).await.expect("publish commit");
}

/// R1 (FLAGSHIP, marmot G1): TWO wired engines over ONE relay converge
/// bilaterally on concurrent same-epoch commits — the real acceptance proof
/// that the settle window + `converge_commit` prevent the two-admin twin fork.
// The end-to-end acceptance flow (build → start → stage → publish → collect →
// converge → assert both branches) is one linear narrative; splitting it would
// scatter the proof across helpers and obscure the sequencing that is the point.
#[allow(clippy::too_many_lines)]
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn two_engines_converge_bilaterally_over_one_relay() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let relay = MockRelay::run().await.expect("mock relay");
    let url = relay.url().await.to_string();

    let fx = build_two_member_circle().await;
    let hex = hex::encode(fx.nostr_group_id);

    // One engine per member, both over the SAME relay, both subscribed to the
    // circle's #h (distinct ephemeral salts ⇒ distinct sub-ids; PSI-2).
    let alice_engine = LiveSyncCore::new_local(Arc::clone(&fx.alice), fx.alice_keys.public_key());
    let bob_engine = LiveSyncCore::new_local(Arc::clone(&fx.bob), fx.bob_keys.public_key());
    let spec = CircleSpec {
        group_id_hex: hex.clone(),
        relays: vec![url.clone()],
    };
    alice_engine
        .start(std::slice::from_ref(&spec), &[])
        .await
        .expect("alice engine starts");
    bob_engine
        .start(std::slice::from_ref(&spec), &[])
        .await
        .expect("bob engine starts");
    tokio::time::sleep(Duration::from_millis(500)).await; // both REQs register

    let n = fx.alice.group_epoch(&fx.mls_group_id).unwrap();
    assert_eq!(
        n,
        fx.bob.group_epoch(&fx.mls_group_id).unwrap(),
        "both members start at the shared epoch N"
    );

    // Each opens a settle window + stages a same-epoch self_update (needs no
    // admin). Both windows open BEFORE either commit is published, so each engine
    // BUFFERS the peer's commit (regime 2) rather than blind-applying it.
    let staged_a = alice_engine
        .stage_self_update_converging(&fx.mls_group_id, &fx.nostr_group_id)
        .await
        .expect("alice stages");
    let staged_b = bob_engine
        .stage_self_update_converging(&fx.mls_group_id, &fx.nostr_group_id)
        .await
        .expect("bob stages");
    assert_eq!(staged_a.staged_epoch, n);
    assert_eq!(staged_b.staged_epoch, n);
    let alice_commit = Event::from_json(&staged_a.commit_json).unwrap();
    let bob_commit = Event::from_json(&staged_b.commit_json).unwrap();

    // Publish both commits to the shared relay; each engine receives BOTH.
    publish_event(&url, &alice_commit).await;
    publish_event(&url, &bob_commit).await;

    // Wait until BOTH engines have collected BOTH commits (own + peer). Exactly
    // two matching 445s are published, so each open window fills to 2 competitors.
    let both_buffered = |engine: &LiveSyncCore| -> bool {
        engine.settle().lock().unwrap().competitor_count(&hex) >= 2
    };
    let mut ready = false;
    for _ in 0..100 {
        if both_buffered(&alice_engine) && both_buffered(&bob_engine) {
            ready = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    assert!(
        ready,
        "both engines must collect both same-epoch commits over the relay before converging"
    );

    // CS2 on both sides: take the collected competitors and converge.
    let alice_out = alice_engine
        .converge_after_window(
            &fx.mls_group_id,
            &fx.nostr_group_id,
            &staged_a.commit_json,
            n,
            &CommitIntent::None,
        )
        .await
        .expect("alice converges");
    let bob_out = bob_engine
        .converge_after_window(
            &fx.mls_group_id,
            &fx.nostr_group_id,
            &staged_b.commit_json,
            n,
            &CommitIntent::None,
        )
        .await
        .expect("bob converges");

    // Exactly one Merged (the MIP-03 order-key winner) + one AdoptedWinner. The
    // winner is computed OFF-WIRE from the two published commits.
    let winner_is_alice = order_key(&alice_commit) < order_key(&bob_commit);
    if winner_is_alice {
        assert_eq!(
            alice_out,
            CommitConvergence::Merged,
            "alice (min order key) merges her own commit"
        );
        assert!(
            matches!(bob_out, CommitConvergence::AdoptedWinner { .. }),
            "bob adopts alice's winning commit; got {bob_out:?}"
        );
    } else {
        assert_eq!(
            bob_out,
            CommitConvergence::Merged,
            "bob (min order key) merges his own commit"
        );
        assert!(
            matches!(alice_out, CommitConvergence::AdoptedWinner { .. }),
            "alice adopts bob's winning commit; got {alice_out:?}"
        );
    }

    // Both land on the SAME N+1 branch: equal epoch AND cross-decrypt BOTH ways
    // (equal epoch NUMBER alone cannot detect a twin fork — only the shared
    // exporter secret can).
    assert_eq!(fx.alice.group_epoch(&fx.mls_group_id).unwrap(), n + 1);
    assert_eq!(fx.bob.group_epoch(&fx.mls_group_id).unwrap(), n + 1);
    assert!(
        cross_decrypts(
            &fx.alice,
            &fx.alice_keys.public_key(),
            &fx.bob,
            &fx.mls_group_id
        ),
        "bilateral convergence: bob must decrypt alice's post-converge location"
    );
    assert!(
        cross_decrypts(
            &fx.bob,
            &fx.bob_keys.public_key(),
            &fx.alice,
            &fx.mls_group_id
        ),
        "bilateral convergence BOTH ways: alice must decrypt bob's post-converge location"
    );

    alice_engine.stop().await;
    bob_engine.stop().await;
}

/// R2 (rust GAP-C): a GENUINE same-epoch sibling commit (Bob's real
/// `self_update`) arriving over the relay while a settle window is open is
/// BUFFERED via the full receive path (regime 2), never decrypted/applied — the
/// epoch stays N. Using a real epoch-advancing commit (not an inert synthetic)
/// makes the "epoch unchanged" assertion LOAD-BEARING: a same-epoch sibling
/// commit blind-applied while we hold our own pending commit is precisely what
/// MDK *would* apply (it surfaces as `Ok(Commit)`, not an error), forking the
/// group — so `epoch == N` here proves the regime-2 buffer prevented that
/// fork-inducing blind-apply, not merely that an undecryptable event was inert.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn regime2_competitor_is_buffered_over_the_relay_without_advancing_epoch() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let relay = MockRelay::run().await.expect("mock relay");
    let url = relay.url().await.to_string();

    let fx = build_two_member_circle().await;
    let hex = hex::encode(fx.nostr_group_id);
    let engine = LiveSyncCore::new_local(Arc::clone(&fx.alice), fx.alice_keys.public_key());
    engine
        .start(
            &[CircleSpec {
                group_id_hex: hex.clone(),
                relays: vec![url.clone()],
            }],
            &[],
        )
        .await
        .expect("start");
    tokio::time::sleep(Duration::from_millis(500)).await;

    let epoch_before = fx.alice.group_epoch(&fx.mls_group_id).unwrap();

    // CS1: Alice opens the window at epoch N and stages her own pending commit
    // (the gate is released on return).
    let _staged = engine
        .stage_self_update_converging(&fx.mls_group_id, &fx.nostr_group_id)
        .await
        .expect("stage opens the window");

    // Bob (a real co-member) stages a GENUINE same-epoch self_update; its commit
    // is framed from epoch N — the exact same-epoch sibling that would fork Alice
    // if blind-applied while she holds her own pending commit. Staging a pending
    // commit does not advance Bob's epoch.
    let bob_commit = fx
        .bob
        .self_update(&fx.mls_group_id)
        .expect("bob stages a real self_update")
        .evolution_event;
    assert_eq!(
        fx.bob.group_epoch(&fx.mls_group_id).unwrap(),
        epoch_before,
        "a staged pending commit does not advance the epoch (bob is still at N)"
    );
    publish_event(&url, &bob_commit).await;

    // The FULL receive path must BUFFER it (regime 2), never decrypt/apply it.
    let mut buffered = false;
    for _ in 0..50 {
        if engine.settle().lock().unwrap().competitor_count(&hex) >= 1 {
            buffered = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    assert!(
        buffered,
        "an in-window REAL same-epoch competitor must be buffered via the full \
         relay→receiver→worker path"
    );
    assert_eq!(
        fx.alice.group_epoch(&fx.mls_group_id).unwrap(),
        epoch_before,
        "regime 2 must NOT decrypt/apply a real same-epoch sibling commit while \
         buffering — a blind-apply here would fork the group (the epoch would advance)"
    );

    engine
        .abort_converging_window(&fx.mls_group_id, &fx.nostr_group_id)
        .await
        .unwrap();
    engine.stop().await;
}

/// R5 (marmot G4 / rust GAP-D): concurrent engine-receive + foreground-converge
/// on the SAME circle converge to a single correct epoch (no double-advance /
/// corruption). Alice's foreground stages her own `self_update` (opening the
/// window) while her always-on engine worker CONCURRENTLY receives and buffers
/// Bob's GENUINE same-epoch `self_update` over the relay (regime 2). The buffer
/// holds the real sibling out of a blind-apply (epoch stays N); CS2 then
/// converges the two same-epoch commits to the single MIP-03 winner, so BOTH
/// members land on the winner's branch — the epoch advances by EXACTLY one (never
/// N+2 or a fork) and the group still cross-decrypts BOTH ways.
///
/// Because the competitor is a REAL epoch-advancing commit, the asserts are
/// sensitive to a broken buffer/regime path (a blind-apply would advance Alice
/// mid-window; skipping convergence would strand the two on divergent N+1 twins
/// that fail cross-decrypt) — not to inert far-future data.
///
/// The DIRECT proof that the foreground and the engine worker take the SAME
/// per-circle `MlsWriteGate` (mutual exclusion) is
/// `finalize.rs::the_finalize_path_contends_the_engine_per_circle_gate`; this
/// test proves the end-to-end convergence OUTCOME under that concurrency.
// The stage → buffer → converge (both sides) → assert flow is one linear
// narrative; splitting it would scatter the proof across helpers.
#[allow(clippy::too_many_lines)]
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn write_gate_serializes_concurrent_engine_and_foreground_writes() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let relay = MockRelay::run().await.expect("mock relay");
    let url = relay.url().await.to_string();

    let fx = build_two_member_circle().await;
    let hex = hex::encode(fx.nostr_group_id);
    let engine = LiveSyncCore::new_local(Arc::clone(&fx.alice), fx.alice_keys.public_key());
    engine
        .start(
            &[CircleSpec {
                group_id_hex: hex.clone(),
                relays: vec![url.clone()],
            }],
            &[],
        )
        .await
        .expect("start");
    tokio::time::sleep(Duration::from_millis(500)).await;

    let n = fx.alice.group_epoch(&fx.mls_group_id).unwrap();

    // Bob (a real co-member) stages a GENUINE same-epoch self_update — a real
    // epoch-advancing competitor, NOT inert data. Published AFTER Alice's window
    // opens (below) so it arrives while the window is open and is buffered.
    let bob_commit = fx
        .bob
        .self_update(&fx.mls_group_id)
        .expect("bob stages a real self_update")
        .evolution_event;

    // CS1: Alice's foreground opens the window at N and stages her own pending
    // commit. Alice's own commit is passed directly to Bob's converge below, so it
    // need not be published — keeping the buffered-competitor count == exactly
    // Bob's one real commit (an unambiguous "the real sibling was buffered" probe).
    let staged = engine
        .stage_self_update_converging(&fx.mls_group_id, &fx.nostr_group_id)
        .await
        .expect("alice stages");
    let alice_commit = Event::from_json(&staged.commit_json).unwrap();

    // Bob's real commit lands over the relay; the engine worker buffers it
    // concurrently with the foreground flow (regime 2).
    publish_event(&url, &bob_commit).await;
    let mut buffered = false;
    for _ in 0..100 {
        if engine.settle().lock().unwrap().competitor_count(&hex) >= 1 {
            buffered = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    assert!(
        buffered,
        "the engine worker must buffer Bob's real same-epoch commit before converge"
    );
    // Load-bearing (regime 2): the real sibling was BUFFERED, not blind-applied —
    // Alice is still at N with her own pending commit intact.
    assert_eq!(
        fx.alice.group_epoch(&fx.mls_group_id).unwrap(),
        n,
        "a buffered real competitor must NOT advance the epoch mid-window (no blind-apply)"
    );

    // CS2: Alice converges over the buffered competitor; Bob converges over the
    // same two commits. Both pick the SAME MIP-03 winner (a total order over the
    // identical {alice_commit, bob_commit} set), so both land on the winner's
    // branch — one Merged, one AdoptedWinner.
    let alice_conv = engine
        .converge_after_window(
            &fx.mls_group_id,
            &fx.nostr_group_id,
            &staged.commit_json,
            n,
            &CommitIntent::None,
        )
        .await
        .expect("alice converges");
    let bob_conv = fx
        .bob
        .converge_commit(
            &fx.mls_group_id,
            &bob_commit,
            n,
            std::slice::from_ref(&alice_commit),
            &CommitIntent::None,
        )
        .expect("bob converges");

    // Exactly one Merged + one AdoptedWinner over the concurrent commit pair.
    let outcomes = [&alice_conv, &bob_conv];
    assert_eq!(
        outcomes
            .iter()
            .filter(|o| matches!(o, CommitConvergence::Merged))
            .count(),
        1,
        "exactly one side merges its own commit: alice={alice_conv:?} bob={bob_conv:?}"
    );
    assert!(
        outcomes
            .iter()
            .any(|o| matches!(o, CommitConvergence::AdoptedWinner { .. })),
        "the other side adopts the winner: alice={alice_conv:?} bob={bob_conv:?}"
    );

    // Let the worker settle any last queued processing (defensive: a late
    // double-advance would be caught by the N+1 assertion below).
    tokio::time::sleep(Duration::from_millis(300)).await;

    // EXACTLY N+1 on BOTH sides — never N+2 / corrupt — and a SHARED branch: the
    // concurrent receive + foreground converge produced one correct epoch, and the
    // two members converged rather than forking into same-number twins.
    assert_eq!(
        fx.alice.group_epoch(&fx.mls_group_id).unwrap(),
        n + 1,
        "concurrent worker receive must not corrupt or double-advance the epoch"
    );
    assert_eq!(fx.bob.group_epoch(&fx.mls_group_id).unwrap(), n + 1);
    assert!(
        cross_decrypts(
            &fx.alice,
            &fx.alice_keys.public_key(),
            &fx.bob,
            &fx.mls_group_id
        ),
        "the converged N+1 state is un-corrupted: bob decrypts alice"
    );
    assert!(
        cross_decrypts(
            &fx.bob,
            &fx.bob_keys.public_key(),
            &fx.alice,
            &fx.mls_group_id
        ),
        "the converged N+1 state is un-corrupted BOTH ways: alice decrypts bob"
    );

    engine.stop().await;
}
