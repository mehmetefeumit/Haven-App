//! The live plane never puts a departed member's fix on the map.
//!
//! A fix sealed before its sender's removal still decrypts after the removal
//! lands (MDK keeps past epochs for in-flight traffic). The shared persist site
//! refuses to store it — the sender is off the circle's roster — and the plane
//! that routes per event must refuse to route it by the same decision, or the
//! map shows someone the user just removed.

mod helpers;

use std::sync::Arc;

use haven_core::circle::{CircleConfig, CircleManager, MemberKeyPackage};
use haven_core::location::LocationMessage;
use haven_core::nostr::mls::types::LocationMessageResult;
use haven_core::relay::live_sync::{EngineProcessor, EventBus, LiveSyncEvent};
use haven_core::relay::maintenance::build_kp_maintenance_events;
use nostr::{Event, Keys};
use tempfile::TempDir;

fn senders(rx: &mut tokio::sync::broadcast::Receiver<LiveSyncEvent>) -> Vec<String> {
    let mut out = Vec::new();
    while let Ok(event) = rx.try_recv() {
        if let LiveSyncEvent::Location { sender_pubkey, .. } = event {
            out.push(sender_pubkey);
        }
    }
    out
}

/// Alice's circle with Bob in it and two fixes Bob sealed while a member: one
/// to read before Alice removes him, one still in flight when she does.
struct InFlightFromRemoved {
    alice: Arc<CircleManager>,
    group: haven_core::nostr::mls::types::GroupId,
    bob_hex: String,
    ngid: [u8; 32],
    member_fix: Event,
    in_flight: Event,
    _dirs: Vec<TempDir>,
}

async fn a_fix_in_flight_from_a_removed_member() -> InFlightFromRemoved {
    let relays = vec!["wss://group.example.com".to_string()];
    let bob_dir = TempDir::new().unwrap();
    let bob_keys = Keys::generate();
    let bob = CircleManager::new_unencrypted(bob_dir.path(), &bob_keys).unwrap();
    let key_package_event = build_kp_maintenance_events(
        bob.session(),
        &bob_keys,
        &["wss://kp.example.com".to_string()],
        None,
        None,
    )
    .await
    .expect("bob's key package")
    .event;
    let alice_dir = TempDir::new().unwrap();
    let alice_keys = Keys::generate();
    let alice = Arc::new(CircleManager::new_unencrypted(alice_dir.path(), &alice_keys).unwrap());
    let created = alice
        .create_circle(
            &alice_keys,
            vec![MemberKeyPackage {
                key_package_event,
                inbox_relays: vec!["wss://inbox.example.com".to_string()],
                nip65_relays: vec![],
            }],
            &CircleConfig::new("Roster Circle").with_relays(relays.clone()),
        )
        .await
        .expect("create");
    let welcome = &created.welcome_events[0];
    bob.process_gift_wrapped_invitation(&bob_keys, &welcome.event)
        .await
        .expect("welcome");
    bob.accept_invitation(&welcome.event.id)
        .await
        .expect("join");
    let group = created.circle.mls_group_id.clone();
    let seal = |lat: f64| {
        let bob = &bob;
        let group = group.clone();
        async move {
            bob.seal_location_for_test(&group, &LocationMessage::new(lat, 4.89))
                .await
                .expect("bob seals a fix")
                .0
        }
    };
    let member_fix = seal(52.37).await;
    let in_flight = seal(52.38).await;
    InFlightFromRemoved {
        alice,
        group,
        bob_hex: bob_keys.public_key().to_hex(),
        ngid: created.circle.nostr_group_id,
        member_fix,
        in_flight,
        _dirs: vec![alice_dir, bob_dir],
    }
}

impl InFlightFromRemoved {
    /// Alice removes Bob, and a relay acks it.
    async fn remove_bob(&self) {
        self.alice
            .remove_members_for_test(&self.group, std::slice::from_ref(&self.bob_hex))
            .await
            .expect("alice removes bob");
    }

    /// Whether Alice's store holds Bob's in-flight fix (sealed at latitude
    /// 52.38).
    fn stores_the_in_flight_fix(&self) -> bool {
        self.alice
            .snapshot_last_known_for_circle(&self.ngid, chrono::Utc::now().timestamp())
            .expect("snapshot")
            .iter()
            .any(|row| row.sender_pubkey == self.bob_hex && (row.latitude - 52.38).abs() < 1e-9)
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_fix_from_a_member_removed_since_never_reaches_the_bus() {
    let fx = a_fix_in_flight_from_a_removed_member().await;
    let bus = EventBus::new();
    let mut rx = bus.subscribe();
    let processor = EngineProcessor::new(Arc::clone(&fx.alice), bus);
    let _ = processor
        .process_group_event(&fx.member_fix, &fx.ngid)
        .await;
    assert!(
        senders(&mut rx).contains(&fx.bob_hex),
        "anti-vacuity: a member's fix is routed"
    );

    fx.remove_bob().await;
    let _ = processor.process_group_event(&fx.in_flight, &fx.ngid).await;

    assert!(
        !senders(&mut rx).contains(&fx.bob_hex),
        "a removed member's fix is not shown"
    );
    assert!(!fx.stores_the_in_flight_fix(), "nor stored");
}

/// The poll and background planes (`Publishing::ingest_for_poll`, which the
/// FGS cycle calls) hand their results across the FFI, where Dart writes them
/// to its own store: a removed member's fix must be in neither the results
/// nor the core's store.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_poll_plane_returns_and_stores_no_fix_from_a_removed_member() {
    let fx = a_fix_in_flight_from_a_removed_member().await;
    let bob_fix = |results: &[LocationMessageResult]| {
        results.iter().any(|result| {
            matches!(
                result,
                LocationMessageResult::Location { sender_pubkey, .. } if *sender_pubkey == fx.bob_hex
            )
        })
    };
    let member = fx
        .alice
        .ingest_for_test(&fx.member_fix)
        .await
        .expect("alice reads");
    assert!(bob_fix(&member), "anti-vacuity: a member's fix is returned");

    fx.remove_bob().await;
    let ingest = fx
        .alice
        .ingest_for_test(&fx.in_flight)
        .await
        .expect("alice reads");

    assert!(
        !bob_fix(&ingest),
        "a removed member's fix is not handed to the app"
    );
    assert!(!fx.stores_the_in_flight_fix(), "nor stored");
}
