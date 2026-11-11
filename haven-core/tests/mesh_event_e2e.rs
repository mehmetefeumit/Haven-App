//! A location the product seals, through the mesh envelope and back (plan
//! §4.1, gate G-2).
//!
//! `mesh::event`'s unit tests sign their own events in the shape MDK's peeler
//! is read to emit. These seal real ones, in a real circle, through the
//! driver's `seal_location`, so the shape and the size are the engine's.

mod helpers;

use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine as _;
use chrono::{DateTime, Utc};
use haven_core::location::{location_to_geohash, LocationMessage};
use haven_core::mesh::event::{parts_of, rebuild};
use haven_core::mesh::packet::{open, wrap, Format, MeshKey, MAX_CONTENT_LEN};
use helpers::{setup_circle, CircleFixture};
use nostr::{Event, JsonUtil as _};
use rand::rngs::StdRng;
use rand::SeedableRng;

const RELAY: &str = "wss://relay.mesh-event.example.com";

/// What a sealed location's kind-445 content may decode to before this test
/// fails: 181 bytes under the envelope's 881.
const CONTENT_BUDGET: usize = 700;
const _: () = assert!(CONTENT_BUDGET < MAX_CONTENT_LEN);

/// No location the product seals serialises longer than this one.
///
/// - Coordinates: `LocationMessage::new` takes any finite `f64` in range, and
///   no `f64` prints longer than 24 characters; these two do.
/// - Geohash: 12 characters, the most the encoder gives. The product writes 8.
/// - Instants: the latest `chrono` holds, with all nine fractional digits.
///   The product writes the clock's reading, three characters shorter until
///   the year 10000.
/// - `display_name` is never set by this client, and the other fields are not
///   serialised.
fn largest_location() -> LocationMessage {
    let coordinate = -1.234_567_890_123_456_8e-300;
    let mut location = LocationMessage::new(coordinate, coordinate);
    location.geohash = location_to_geohash(coordinate, coordinate, 12);
    location.timestamp = DateTime::<Utc>::MAX_UTC;
    location.expires_at = DateTime::<Utc>::MAX_UTC;
    location
}

/// Every member's seal of `location`, with the routing id its circle is
/// asked for by.
async fn sealed_by_each(
    fixture: &CircleFixture,
    location: &LocationMessage,
) -> Vec<(Event, [u8; 32])> {
    let mut sealed = Vec::new();
    for member in &fixture.members {
        let (event, nostr_group_id, _) = member
            .circle
            .seal_location_for_test(&fixture.group, location)
            .await
            .expect("the member seals a location");
        sealed.push((event, nostr_group_id));
    }
    sealed
}

/// The pin of the tag layout that envelope formats `0x01` and `0x02` mean
/// (plan §4.1), re-run at every MDK bump.
///
/// `parts_of` takes one shape: kind 445, tags `["h", <64 lower-case hex>]`
/// then `["expiration", <decimal>]`, content padded standard base64. A peeler
/// that orders, spells or encodes any of it differently seals locations the
/// mesh cannot carry, and this fails. The fix is then a new format byte for
/// the new layout, never a wider `parts_of`: old phones rebuild `0x01` and
/// `0x02` as the layout above.
#[tokio::test]
async fn a_sealed_location_has_the_layout_the_envelope_formats_mean() {
    let fixture = setup_circle(2, &[RELAY]).await;
    let key = MeshKey::derive(&[0x5a; 32]);
    let mut rng = StdRng::seed_from_u64(1);

    for (event, nostr_group_id) in
        sealed_by_each(&fixture, &LocationMessage::new(48.85, 2.35)).await
    {
        let parts = parts_of(&event, Format::Bridgeable)
            .expect("a sealed location has the layout formats 0x01 and 0x02 mean");
        let rebuilt = rebuild(&parts, &nostr_group_id).expect("the sender's own event");
        assert_eq!(rebuilt.as_json(), event.as_json());

        let packet = wrap(&key, &parts, &mut rng).expect("a sealed location fits a packet");
        let carried = open(&key, &packet).expect("its own key opens it");
        let received = rebuild(&carried, &nostr_group_id).expect("the sender's own event");
        assert_eq!(received.as_json(), event.as_json());

        let mut another_circle = nostr_group_id;
        another_circle[0] ^= 1;
        assert!(rebuild(&parts, &another_circle).is_none());
    }
}

/// Plan gate G-2: a sealed location fits the envelope's 881 content bytes,
/// with headroom.
///
/// Measured 2026-11-11 at MDK v0.10.4, from the creator and the joiner alike:
/// 595 bytes for the location above, 546 for `LocationMessage::new(48.85,
/// 2.35)` — each 399 over its location JSON. The content is that JSON inside
/// an unsigned kind-25442 event, inside an MLS private message, inside the
/// outer AEAD, so three things grow it: a field added to or lengthened in
/// `LocationMessage`, a tag or field added to the inner event, and MLS or
/// outer framing changed by an MDK bump. Past the budget this fails, and the
/// growth is undone or the budget raised knowingly; past 881 a location no
/// longer travels by mesh at all.
#[tokio::test]
async fn g2_the_largest_sealed_location_fits_the_envelope_with_headroom() {
    let fixture = setup_circle(2, &[RELAY]).await;

    for (event, _) in sealed_by_each(&fixture, &largest_location()).await {
        let content = BASE64.decode(&event.content).expect("base64 content");
        assert!(
            content.len() <= CONTENT_BUDGET,
            "a sealed location's content is {} bytes, over the {CONTENT_BUDGET} budgeted",
            content.len()
        );
        assert!(parts_of(&event, Format::Bridgeable).is_some());
    }
}
