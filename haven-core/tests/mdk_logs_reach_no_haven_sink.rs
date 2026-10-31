//! No MDK log record reaches Haven's log sink (Security Rule 15).
//!
//! MDK logs through `tracing`, whose fields carry values Rule 15 forbids in a
//! log (exact counts at v0.10.4). They reach no sink only because Haven installs
//! no subscriber and `tracing` resolves without its `log` bridge; one dependency
//! enabling `tracing/log` would forward every MDK event into the `log` facade
//! Haven's platform loggers read. This drives a session end to end — open, mint
//! a `KeyPackage`, create, invite, join, send, receive — under the in-process
//! capture and asserts no record came from an MDK crate. Adding
//! `tracing = { version = "0.1", features = ["log"] }` to the dev-dependencies
//! turns it red.
//!
//! openmls is not MDK: it logs through `log` directly
//! (`openmls-0.8.1/src/ciphersuite/secret.rs:81`), so its records do reach this
//! raw capture, and in the app `HavenTargetFilter` drops them
//! (`haven/rust_builder/src/api.rs`). They are this test's anchor: a capture
//! that sees a dependency's debug records is one that would see MDK's.

use haven_core::circle::{CircleConfig, CircleManager, MemberKeyPackage};
use haven_core::location::LocationMessage;
use haven_core::relay::maintenance::build_kp_maintenance_events;
use nostr::Keys;
use tempfile::TempDir;

mod helpers;
use helpers::{assert_no_needles, assert_some_line_from, capture_haven_log};

const MDK_TARGETS: [&str; 4] = ["cgka_", "storage_sqlite", "transport_nostr", "marmot"];
const CIRCLE_NAME: &str = "Needle Circle Quillon";
const RELAY: &str = "wss://needle-relay-quillon.example.com";

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn no_mdk_log_record_reaches_the_haven_log_sink() {
    let alice_dir = TempDir::new().unwrap();
    let bob_dir = TempDir::new().unwrap();
    let alice_keys = Keys::generate();
    let bob_keys = Keys::generate();
    let mut planted = Vec::new();

    let lines = Box::pin(capture_haven_log(async {
        let bob = CircleManager::new_unencrypted(bob_dir.path(), &bob_keys).unwrap();
        let bob_kp =
            build_kp_maintenance_events(bob.session(), &bob_keys, &[RELAY.to_owned()], None, None)
                .await
                .expect("bob mints a key package")
                .event;

        let alice = CircleManager::new_unencrypted(alice_dir.path(), &alice_keys).unwrap();
        let relays = vec![RELAY.to_owned()];
        let created = alice
            .create_circle(
                &alice_keys,
                vec![MemberKeyPackage {
                    key_package_event: bob_kp,
                    inbox_relays: relays.clone(),
                    nip65_relays: vec![],
                    nip65_write_relays: vec![],
                }],
                &CircleConfig::new(CIRCLE_NAME).with_relays(relays.clone()),
            )
            .await
            .expect("alice creates the circle");
        let mls_group_id = created.circle.mls_group_id.clone();
        planted.push(hex::encode(mls_group_id.as_slice()));
        planted.push(hex::encode(created.circle.nostr_group_id));

        let welcome = &created.welcome_events[0].event;
        bob.process_gift_wrapped_invitation(&bob_keys, welcome)
            .await
            .expect("bob peels the welcome");
        bob.accept_invitation(&welcome.id).await.expect("bob joins");

        let (event, _, _) = alice
            .seal_location_for_test(
                &mls_group_id,
                &LocationMessage::new(12.345_678_9, -98.765_432_1),
            )
            .await
            .expect("alice sends a location");
        planted.push(event.id.to_hex());
        let received = bob.ingest_for_test(&event).await.expect("bob receives it");
        assert_eq!(received.len(), 1, "the receive path ran");
    }))
    .await;

    let mdk: Vec<_> = lines
        .iter()
        .filter(|l| MDK_TARGETS.iter().any(|t| l.target.starts_with(t)))
        .map(|l| &l.target)
        .collect();
    assert!(
        mdk.is_empty(),
        "MDK records reached the log sink from {mdk:?}"
    );

    assert_some_line_from(&lines, "openmls");
    planted.extend([
        alice_keys.public_key().to_hex(),
        bob_keys.public_key().to_hex(),
        RELAY.to_owned(),
        CIRCLE_NAME.to_owned(),
    ]);
    let not_openmls: Vec<_> = lines
        .iter()
        .filter(|l| !l.target.starts_with("openmls"))
        .cloned()
        .collect();
    assert_no_needles(
        &not_openmls,
        &planted.iter().map(String::as_str).collect::<Vec<_>>(),
    );
}
