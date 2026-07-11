//! R9 (MUST) — privacy-config regression for the always-on live-sync engine.
//!
//! The engine `Client` is built (see `relay/live_sync/session.rs::build_engine_client`)
//! with two privacy-load-bearing options that this suite guards end-to-end over a
//! real in-process relay:
//!
//! - **`automatic_authentication(false)`** — the engine must NEVER answer a
//!   NIP-42 AUTH challenge with a client AUTH (`kind:22242`). Such an AUTH is a
//!   signed event carrying the user's Nostr identity; sending it to a relay that
//!   also serves the circle's `#h` traffic would let that relay (or a passive
//!   observer) link the nsec ↔ the circle. `engine_never_authenticates_to_an_auth_required_relay`
//!   proves it against a relay that REQUIRES AUTH to read: the engine reads
//!   nothing (it refuses to authenticate) while a control client that DOES
//!   authenticate reads the very same stored event — so the engine's silence is
//!   specifically the AUTH refusal, not a dead relay.
//!
//! - **no gossip (own-relays-only, PSI-8)** — the engine must connect to EXACTLY
//!   the configured circle ∪ inbox relay set and never a NIP-65-discovered relay,
//!   so it cannot silently fan the user's subscriptions out to relays they never
//!   chose. `engine_connects_only_to_configured_relays_never_gossip_discovered`
//!   proves the pool equals the configured union even after a kind:10002 relay
//!   list (authored by the engine's own identity) advertises a phantom relay.

use std::sync::Arc;
use std::time::Duration;

use haven_core::circle::CircleManager;
use haven_core::relay::live_sync::{CircleSpec, LiveSyncCore, LiveSyncEvent, SyncStatusReason};
use nostr::{Alphabet, EventBuilder, Filter, Keys, Kind, SingleLetterTag, Tag, TagKind, Timestamp};
use nostr_relay_builder::builder::{RelayBuilder, RelayBuilderNip42, RelayBuilderNip42Mode};
use nostr_relay_builder::{LocalRelay, MockRelay};
use nostr_sdk::{Client, ClientOptions, RelayPoolNotification};
use tempfile::TempDir;

/// Builds a `kind:445` carrying `#h = group_hex` (opaque ciphertext, random key).
fn kind445_with_h(group_hex: &str) -> nostr::Event {
    EventBuilder::new(Kind::Custom(445), "opaque-ciphertext")
        .tags([Tag::custom(
            TagKind::SingleLetter(SingleLetterTag::lowercase(Alphabet::H)),
            [group_hex.to_string()],
        )])
        .sign_with_keys(&Keys::generate())
        .unwrap()
}

/// R9 (privacy, `automatic_authentication(false)`): against a relay that requires
/// a NIP-42 AUTH to READ, the engine never sends a client AUTH (`kind:22242`) and
/// therefore reads NOTHING — while a control client that authenticates reads the
/// same stored event, proving the engine's silence is the AUTH refusal (no
/// nsec↔circle linkage), not a broken relay.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn engine_never_authenticates_to_an_auth_required_relay() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();

    // A relay that requires NIP-42 AUTH to READ. In Read mode, WRITES need no
    // auth, so the event below is stored and served only to a reader that auths.
    let relay = LocalRelay::new(RelayBuilder::default().nip42(RelayBuilderNip42 {
        mode: RelayBuilderNip42Mode::Read,
    }));
    relay.run().await.expect("run auth-required relay");
    let url = relay.url().await.to_string();

    let group_hex = hex::encode([0x42u8; 32]);

    // Publish the circle's kind:445 WITHOUT authenticating (write is unguarded in
    // Read mode) so a stored, matching event exists behind the read-AUTH gate.
    let publisher = Client::builder().build();
    publisher.add_relay(&url).await.unwrap();
    publisher.connect().await;
    publisher
        .send_event(&kind445_with_h(&group_hex))
        .await
        .expect("publish (a write needs no auth on a read-only-auth relay)");

    // The engine subscribes. Its client has automatic_authentication(false), so on
    // the relay's AUTH challenge it sends NO client AUTH and its REQ is CLOSED
    // (auth-required) — it can never read the stored event.
    let dir = TempDir::new().unwrap();
    let circle = Arc::new(CircleManager::new_unencrypted(dir.path()).unwrap());
    let engine = LiveSyncCore::new_local(circle, Keys::generate().public_key());
    let mut rx = engine.bus().subscribe(); // before start: capture any content emit
    engine
        .start(
            &[CircleSpec {
                group_id_hex: group_hex.clone(),
                relays: vec![url.clone()],
            }],
            &[],
        )
        .await
        .expect("start");

    // Drain a full 8s window — the SAME budget as the authenticating control
    // below — so a slow auto-auth REGRESSION (one that answered the AUTH challenge
    // only after a few seconds) cannot slip past a too-short negative window. The
    // engine must surface NO content (no Location, no Unprocessable); a delivered
    // event would prove it authenticated to read. Connecting/Connected statuses
    // are ignored, and the timeout always elapses (the engine stays silent) —
    // which is the point.
    let mut content_emits = 0usize;
    let _ = tokio::time::timeout(Duration::from_secs(8), async {
        loop {
            match rx.recv().await {
                Ok(
                    LiveSyncEvent::Status {
                        reason: SyncStatusReason::Unprocessable,
                    }
                    | LiveSyncEvent::Location { .. },
                ) => content_emits += 1,
                Ok(_) => {}      // Connecting / Connected / other — keep waiting
                Err(_) => break, // bus closed
            }
        }
    })
    .await;
    assert_eq!(
        content_emits, 0,
        "an engine that refuses NIP-42 AUTH must read NOTHING from an auth-required relay"
    );

    // CONTROL: a client WITH automatic_authentication(true) + a signer DOES send a
    // kind:22242 AUTH, authenticates, resubscribes, and receives the SAME stored
    // event — so the read gate is real and AUTH is the only thing unlocking it.
    let control = Client::builder()
        .signer(Keys::generate())
        .opts(ClientOptions::default().automatic_authentication(true))
        .build();
    control.add_relay(&url).await.unwrap();
    control.connect().await;
    let mut cn = control.notifications();
    control
        .subscribe(Filter::new().kind(Kind::Custom(445)), None)
        .await
        .expect("control subscribes");
    let control_got_event = tokio::time::timeout(Duration::from_secs(8), async {
        loop {
            match cn.recv().await {
                Ok(RelayPoolNotification::Event { event, .. })
                    if event.kind == Kind::Custom(445) =>
                {
                    break true
                }
                Ok(_) => {}
                Err(_) => break false,
            }
        }
    })
    .await;
    assert_eq!(
        control_got_event,
        Ok(true),
        "an authenticating control client reads the stored event — the relay + event are live behind AUTH"
    );

    engine.stop().await;
}

/// R9 (privacy, no gossip): the engine connects to EXACTLY the configured circle
/// ∪ inbox relay set and never adopts a NIP-65-discovered relay — even after a
/// kind:10002 relay list authored by the engine's own identity advertises a
/// phantom relay. With gossip compiled off (own-relays-only, PSI-8) the pool
/// stays the configured union; a gossip-enabled build could grow it.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn engine_connects_only_to_configured_relays_never_gossip_discovered() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();

    // Three DISTINCT configured relays: two for the circle group + one inbox.
    let r_group1 = MockRelay::run().await.expect("group relay 1");
    let r_group2 = MockRelay::run().await.expect("group relay 2");
    let r_inbox = MockRelay::run().await.expect("inbox relay");
    let g1 = r_group1.url().await.to_string();
    let g2 = r_group2.url().await.to_string();
    let inbox = r_inbox.url().await.to_string();

    let identity = Keys::generate();
    let dir = TempDir::new().unwrap();
    let circle = Arc::new(CircleManager::new_unencrypted(dir.path()).unwrap());
    let engine = LiveSyncCore::new_local(circle, identity.public_key());
    engine
        .start(
            &[CircleSpec {
                group_id_hex: hex::encode([0x33u8; 32]),
                relays: vec![g1.clone(), g2.clone()],
            }],
            std::slice::from_ref(&inbox),
        )
        .await
        .expect("start");

    // Poll until ALL three configured relays are connected.
    let mut ready = false;
    for _ in 0..80 {
        let s = engine.relay_health().await;
        if s.total == 3 && s.connected == 3 {
            ready = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    assert!(
        ready,
        "the engine must connect to EXACTLY the 3 configured (group ∪ inbox) relays"
    );

    // Publish a NIP-65 relay list (kind:10002) authored by OUR identity to g1,
    // advertising a phantom relay the engine was never configured with. A
    // gossip-enabled client could discover + add it; the engine (gossip OFF) must
    // ignore it.
    let publisher = Client::builder().build();
    publisher.add_relay(&g1).await.unwrap();
    publisher.connect().await;
    let relay_list = EventBuilder::new(Kind::RelayList, "")
        .tags([Tag::custom(
            TagKind::SingleLetter(SingleLetterTag::lowercase(Alphabet::R)),
            ["wss://phantom-gossip-relay.invalid".to_string()],
        )])
        .custom_created_at(Timestamp::now())
        .sign_with_keys(&identity)
        .expect("sign nip-65");
    publisher
        .send_event(&relay_list)
        .await
        .expect("publish nip-65 relay list");

    // Over a settling window the pool stays EXACTLY the configured union — the
    // phantom relay is never adopted (no gossip discovery).
    for _ in 0..15 {
        tokio::time::sleep(Duration::from_millis(100)).await;
        let s = engine.relay_health().await;
        assert_eq!(
            s.total, 3,
            "the engine must never adopt a gossip-discovered relay (own-relays-only)"
        );
    }

    // NB (F2): no positive gossip control (a `.gossip(true)` client that DOES
    // adopt the phantom) is included. Reliably driving nostr-sdk's outbox/gossip
    // discovery needs an author-triggered NIP-65 resolution whose timing and
    // pool-add semantics are version-specific, and a non-resolvable `.invalid`
    // phantom is not deterministically pool-added — so a positive control would be
    // flaky and would test the SDK, not Haven. The differential is instead
    // guaranteed structurally: gossip is compiled OFF for the engine client
    // (own-relays-only, PSI-8 — see `session.rs::build_engine_client`), so the
    // `total == 3` invariant above holds by construction, not by chance
    // non-discovery. The NIP-65 event IS live on g1 (the control-authored publish
    // succeeded), so "never adopted" is a genuine refusal, not an unfetched list.
    engine.stop().await;
}
