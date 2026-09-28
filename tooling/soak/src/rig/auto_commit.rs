//! The address map the live engine's receive-side auto-commit publish goes
//! through, pointing each stored address at the device's own endpoint.
//!
//! # Why the engine needs one at all
//!
//! Every device's engine pool holds only that device's per-device endpoints
//! (`world.rs`), while the circle row in storage names each plane's canonical
//! address — and must, because `resync_circle_relays_from_mdk` rewrites it from
//! the group's routing component after every group update. The engine
//! publishes an auto-commit to `relays_for_commit_event` (storage), and the
//! pool refuses an address it does not hold
//! (`nostr-relay-pool-0.44.3/src/pool/mod.rs:762-765`), so with production's
//! publisher every receive-side eviction, its foreground redemption and a
//! re-proposed leave would stay unpublished for ever — a failure the product,
//! whose pool and storage agree, never has.
//!
//! # An address map, not a fake
//!
//! The seam (`LiveSyncCore::new_local_with_relay_map_for_test`) takes a map
//! from address to address and nothing else: haven-core wraps the engine's OWN
//! `Client` itself and hands every publish to its own `impl AutoCommitPublisher
//! for nostr_sdk::Client`, so the pool, the socket and the ≥1-relay OK rule
//! (Rule 13) are production's by construction. A fault armed on the device's
//! endpoint (`apply_for`) or plane-wide (`apply`) reaches the publish exactly as
//! it reaches the engine's REQs. The pairs are URLs, so nothing here is ever
//! rendered.

use haven_core::relay::canonicalize;

/// Maps each stored (canonical) address to the device's own endpoint on the
/// same plane, given `(stored, own)` per plane.
///
/// An address no plane stored passes through unchanged, so the pool refuses it
/// exactly as production's would refuse a relay it never held.
pub fn endpoint_map(routes: Vec<(String, String)>) -> impl Fn(&str) -> String + Send + Sync {
    move |relay| {
        let relay_form = canonicalize(relay);
        routes
            .iter()
            .find(|(stored, _)| canonicalize(stored) == relay_form)
            .map_or_else(|| relay.to_owned(), |(_, own)| own.clone())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_stored_address_routes_to_its_planes_own_endpoint_and_a_foreign_one_passes_through() {
        let route = endpoint_map(vec![
            (
                "ws://127.0.0.1:1".to_owned(),
                "ws://127.0.0.1:11".to_owned(),
            ),
            (
                "ws://127.0.0.1:2".to_owned(),
                "ws://127.0.0.1:22".to_owned(),
            ),
        ]);
        assert!(
            route("ws://127.0.0.1:2/") == "ws://127.0.0.1:22",
            "a stored address, in whichever normal form storage kept it, dials its plane's own endpoint"
        );
        assert!(
            route("ws://127.0.0.1:3") == "ws://127.0.0.1:3",
            "an address no plane stored is not invented a route"
        );
    }
}
