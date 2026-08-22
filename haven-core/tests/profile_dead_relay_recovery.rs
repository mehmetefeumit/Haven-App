//! A dead assigned relay must not permanently hide an author.
//!
//! This is the promise the 2026-08 field incident broke: half the shipped
//! profile pool had died or gone members-only, and a member whose salted
//! rank-1 relay was one of them showed a bare-npub tile on every peer's phone
//! — indistinguishable from "this person never set a name". The client-side
//! half of that promise is the retry ladder: a relay that cannot even be
//! CONNECTED to must surface as a MISS (which advances the author onto its
//! rank-2 relay next cycle), never as an error that leaves the author
//! unattempted at rank 1 forever.
//!
//! Hermetic: the "dead" relay is a loopback port with no listener
//! (connection refused — the same shape as a host that has left the network),
//! and the live relays are in-process. The only waiting is the fetch path's
//! own bounded `PROFILE_AUTHOR_FETCH_TIMEOUT`; there are no sleeps and no
//! timing races — the dead port refuses instantly and deterministically.
//!
//! Lives in `tests/` because it drives `fetch_profiles_assigned` end-to-end
//! over real sockets, like `rate_limited_closed_is_a_miss_not_an_error` does
//! for the CLOSED shape in the lib tests — but with a second cycle, proving
//! the miss actually converts into a rank-2 resolution.

use haven_core::profile::{
    assigned_relay_for_attempt, build_metadata_event, fetch_profiles_assigned, ProfileMetadata,
    ProfileRelaySalt,
};
use haven_core::relay::RelayManager;
use nostr::{Keys, Metadata};
use nostr_relay_builder::prelude::{LocalRelay, RelayBuilder};

/// Fixed salt — assignment must never depend on a random draw, or a failure
/// would be irreproducible.
const fn salt() -> ProfileRelaySalt {
    ProfileRelaySalt::from_bytes([0xAA; 32])
}

/// A loopback URL that refuses every connection: bind an ephemeral port to
/// reserve it, then drop the listener before returning.
fn dead_relay_url() -> String {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind ephemeral port");
    let port = listener.local_addr().expect("local addr").port();
    drop(listener);
    format!("ws://127.0.0.1:{port}")
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn author_on_a_dead_rank1_relay_misses_then_resolves_from_rank2() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();

    // A minimum-size pool: one dead relay and two live in-process ones.
    let live_a = LocalRelay::new(RelayBuilder::default());
    live_a.run().await.expect("local relay a runs");
    let live_b = LocalRelay::new(RelayBuilder::default());
    live_b.run().await.expect("local relay b runs");
    let dead = dead_relay_url();
    let pool = vec![
        dead.clone(),
        live_a.url().await.to_string(),
        live_b.url().await.to_string(),
    ];

    // Find an author whose rank-1 relay is the dead one. The ranking is a
    // salted hash over (author, url), so this is a bounded search (~1/3 odds
    // per draw), and the property is re-verified below rather than assumed.
    let salt = salt();
    let author_keys = loop {
        let keys = Keys::generate();
        if assigned_relay_for_attempt(&salt, &keys.public_key(), &pool, 0).as_deref()
            == Some(dead.as_str())
        {
            break keys;
        }
    };
    let author = author_keys.public_key();
    let rank2 = assigned_relay_for_attempt(&salt, &author, &pool, 1)
        .expect("a 3-relay pool always ranks a second rung");
    assert_ne!(rank2, dead, "rank 2 must be a live relay");

    // The author's kind-0 exists where a publisher would have put it — on the
    // live pool (the publish path fans out to every usable relay; the dead one
    // simply never received anything).
    let event = build_metadata_event(
        &author_keys,
        &ProfileMetadata::from_metadata(Metadata::new().display_name("Reachable After All")),
        None,
    )
    .expect("build kind-0");
    let relay = RelayManager::new();
    relay
        .publish_event(&event, std::slice::from_ref(&rank2))
        .await
        .expect("publish to the live rank-2 relay");

    // Cycle 1, attempt 0: the assigned relay refuses the connection. That MUST
    // be a miss — the outcome that advances the ladder — and never an
    // unattempted drop, which would pin the author to the dead relay forever.
    let first = fetch_profiles_assigned(&relay, &[(author, 0)], &salt, &pool, 1_000)
        .await
        .expect("cycle 1 runs");
    assert!(first.resolved.is_empty(), "nothing lives on the dead relay");
    assert_eq!(
        first.missed,
        vec![author],
        "a connection-refused assigned relay must surface as a MISS",
    );
    assert!(
        first.unattempted.is_empty(),
        "unattempted would freeze the author at rank 1 forever",
    );

    // Cycle 2, attempt 1 (what the recorded miss schedules): the ladder's
    // second rung is the live relay, and the author resolves.
    let second = fetch_profiles_assigned(&relay, &[(author, 1)], &salt, &pool, 2_000)
        .await
        .expect("cycle 2 runs");
    assert_eq!(second.resolved.len(), 1, "rank 2 must resolve the author");
    let profile = &second.resolved[0];
    assert_eq!(profile.pubkey_hex, author.to_hex());
    assert_eq!(
        profile.metadata.display_name(),
        Some("Reachable After All"),
        "the resolved kind-0 must be the one published to the live relay",
    );
}
