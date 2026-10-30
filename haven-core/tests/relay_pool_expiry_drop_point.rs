//! The clock-skew total-loss point is where Haven's relay pool really drops a
//! location, proved through `RelayManager::fetch_events` rather than through
//! the pool's predicate alone (`clock_skew::tests::total_loss_point_is_the_relay_pools_drop_point`).
//!
//! A NIP-40 relay refuses to store or serve an expired event, and so does
//! `nostr-relay-builder`'s database, so the relay here is a bare WebSocket
//! server that answers the REQ with whatever it is given, then EOSE. Every
//! frame goes out on one socket in order, so the fence that follows the
//! lagging location proves the socket delivered: a missing location was
//! dropped by the receiver, not lost in transit.

use std::time::Duration;

use futures::{SinkExt, StreamExt};
use haven_core::location::LOCATION_MESSAGE_RETENTION_SECS;
use haven_core::relay::{RelayManager, TOTAL_LOSS_SKEW_SECS};
use nostr::{Event, EventBuilder, Filter, Keys, Kind, Tag, Timestamp};
use tokio::net::TcpListener;
use tokio_tungstenite::tungstenite::Message;

/// Serves `events` to the first REQ on the first connection, then EOSE.
async fn serve_once(listener: TcpListener, events: Vec<Event>) {
    let (tcp, _) = listener.accept().await.expect("the pool connects");
    let mut ws = tokio_tungstenite::accept_async(tcp)
        .await
        .expect("websocket handshake");
    while let Some(Ok(frame)) = ws.next().await {
        let Message::Text(text) = frame else { continue };
        let msg: serde_json::Value = serde_json::from_str(&text).expect("client JSON");
        if msg[0] != "REQ" {
            continue;
        }
        let sub = msg[1].clone();
        for event in &events {
            let out = serde_json::json!(["EVENT", sub, event]).to_string();
            ws.send(Message::text(out)).await.expect("send EVENT");
        }
        let eose = serde_json::json!(["EOSE", sub]).to_string();
        ws.send(Message::text(eose)).await.expect("send EOSE");
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_location_lagging_past_the_total_loss_point_is_dropped_by_the_relay_pool() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let author = Keys::generate();
    let now = Timestamp::now();
    // Stamped as the engine stamps a location: expiration = created_at +
    // retention, both from the publisher's clock.
    let sent_lagging_by = |lag: u64, content: &str| {
        let created_at = Timestamp::from(now.as_secs() - lag);
        EventBuilder::new(Kind::Custom(445), content)
            .tag(Tag::expiration(
                created_at + LOCATION_MESSAGE_RETENTION_SECS,
            ))
            .custom_created_at(created_at)
            .sign_with_keys(&author)
            .expect("a locally built event signs")
    };
    // Expired one second before it is even sent, so no delivery latency can
    // save it: the drop needs no race to win.
    let lagging = sent_lagging_by(TOTAL_LOSS_SKEW_SECS + 1, "lagging");
    // A whole retention of residency, far beyond the fetch's own 30 s bound.
    let fence = sent_lagging_by(0, "fence");

    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let url = format!("ws://{}", listener.local_addr().expect("local addr"));
    let relay = tokio::spawn(serve_once(listener, vec![lagging.clone(), fence.clone()]));

    let received = RelayManager::new()
        .fetch_events(
            Filter::new()
                .author(author.public_key())
                .kind(Kind::Custom(445)),
            std::slice::from_ref(&url),
            Some(Duration::from_secs(30)),
        )
        .await
        .expect("fetch through the pool");
    relay.abort();

    assert!(
        received.iter().any(|e| e.id == fence.id),
        "the fence sent after the lagging location never arrived, so the socket \
         did not deliver and the absence below would prove nothing"
    );
    assert!(
        received.iter().all(|e| e.id != lagging.id),
        "the relay pool delivered a location whose publisher lagged past \
         TOTAL_LOSS_SKEW_SECS: the pool now tolerates expired events, so the \
         total-loss point and every threshold and banner derived from it are wrong"
    );
}
