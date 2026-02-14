//! Additional integration tests for relay list event (kind 10051) edge cases.

mod helpers;

use helpers::create_relay_list_event;
use nostr::{Keys, Kind};

#[test]
fn build_relay_list_event_single_relay() {
    let keys = Keys::generate();
    let relays = vec!["wss://relay.example.com".to_string()];

    let event = create_relay_list_event(&keys, &relays);

    // Kind must be 10051
    assert_eq!(event.kind, Kind::MlsKeyPackageRelays);

    // Must have exactly 1 tag
    assert_eq!(
        event.tags.len(),
        1,
        "Relay list event with single relay must have one tag"
    );

    // Tag must be ["relay", url]
    let tag = event.tags.first().expect("should have first tag");
    let parts = tag.as_slice();
    assert_eq!(
        parts.first().map(String::as_str),
        Some("relay"),
        "Tag must have 'relay' as first element"
    );
    assert_eq!(
        parts.get(1).map(String::as_str),
        Some("wss://relay.example.com"),
        "Tag must contain the relay URL"
    );

    // Content must be empty
    assert!(event.content.is_empty());

    // Signature must be valid
    event.verify().expect("Event signature must be valid");
}
