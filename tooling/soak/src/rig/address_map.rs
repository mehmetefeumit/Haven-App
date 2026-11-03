//! The address map every send of a device's live plane goes through — its
//! fanout drive and its publish of what has no record — pointing each stored
//! address at the device's own endpoint.
//!
//! # Why the plane needs one at all
//!
//! Every device's pool holds only that device's per-device endpoints
//! (`world.rs`), while the circle row in storage names each plane's canonical
//! address — and must, because `resync_circle_relays_from_mdk` rewrites it from
//! the group's routing component after every group update. A fanout freezes
//! its targets from that routing, and the pool refuses an address it does not
//! hold (`nostr-relay-pool-0.44.3/src/pool/mod.rs:762-765`), so unmapped every
//! commit a device makes — an eviction, a re-proposed leave — would stay unsent
//! for ever: a failure the product, whose pool and storage agree, never has.
//!
//! # An address map, not a fake
//!
//! The seam (`LiveSyncCore::new_local_with_relay_map_for_test`) takes a map
//! from address to address and nothing else: the sends are still the session's
//! own drive pool — its fanout transport and its publisher — so the pool, the
//! socket and the ≥1-relay OK rule (Rule 13) are production's by construction.
//! A fault armed on the device's endpoint (`apply_for`) or plane-wide (`apply`)
//! reaches the send exactly as it reaches the engine's REQs. The pairs are URLs,
//! so nothing here is ever rendered.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, PoisonError};

use haven_core::relay::canonicalize;

/// The endpoints one device holds for addresses no plane serves, and which
/// address each stands for.
///
/// One per device, shared by every map built for it, so an address is the
/// same endpoint whichever of its maps dials it.
pub struct AliasBook {
    endpoints: Vec<String>,
    assigned: Mutex<Vec<String>>,
    overflowed: AtomicBool,
}

impl AliasBook {
    /// A book over `endpoints`, none of them standing for anything yet.
    #[must_use]
    pub fn new(endpoints: Vec<String>) -> Arc<Self> {
        Arc::new(Self {
            endpoints,
            assigned: Mutex::new(Vec::new()),
            overflowed: AtomicBool::new(false),
        })
    }

    /// The endpoint standing for `address` (canonical), the next free one the
    /// first time it is named; `None` once every endpoint stands for another,
    /// or when the plane gave none — a one-endpoint double answers every
    /// address with its own, as it answers every device.
    fn endpoint_for(&self, address: &str) -> Option<String> {
        let index = {
            let mut assigned = self.assigned.lock().unwrap_or_else(PoisonError::into_inner);
            assigned
                .iter()
                .position(|named| named == address)
                .or_else(|| {
                    (assigned.len() < self.endpoints.len()).then(|| {
                        assigned.push(address.to_owned());
                        assigned.len() - 1
                    })
                })
        };
        if index.is_none() && !self.endpoints.is_empty() {
            self.overflowed.store(true, Ordering::Release);
        }
        index.and_then(|index| self.endpoints.get(index).cloned())
    }

    /// The address endpoint `slot` stands for, once one was named there.
    pub fn stands_for(&self, slot: usize) -> Option<String> {
        self.assigned
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(slot)
            .cloned()
    }

    /// Whether an address was named once every endpoint stood for another: the
    /// world named more unserved addresses than it was built for.
    pub fn overflowed(&self) -> bool {
        self.overflowed.load(Ordering::Acquire)
    }
}

/// Maps each stored (canonical) address to the device's own endpoint on the
/// same plane, given `(stored, own)` per plane.
///
/// A `wss` address no plane stored gets an endpoint of its own from `aliases`:
/// a listener of its own in front of the FIRST plane's relay, so it is a relay
/// of its own to the pool, to the driver's per-relay gate and to the count of
/// relays that acknowledged. A scenario moves an epoch by committing a relay
/// list that names such an address, and the product follows its circles to
/// what they list; dialled as written it would leave the host (a DNS query at
/// the least). Past the book's last endpoint it falls back to the first
/// plane's own endpoint and the book records the overflow, which the world's
/// teardown refuses. Any other address passes through unchanged, so the pool
/// refuses it exactly as production's would refuse a relay it never held.
pub fn endpoint_map(
    routes: Vec<(String, String)>,
    aliases: Arc<AliasBook>,
) -> impl Fn(&str) -> String + Send + Sync {
    move |relay| {
        let relay_form = canonicalize(relay);
        let alias = || {
            if !relay_form.starts_with("wss://") {
                return relay.to_owned();
            }
            aliases
                .endpoint_for(&relay_form)
                .or_else(|| routes.first().map(|(_, own)| own.clone()))
                .unwrap_or_else(|| relay.to_owned())
        };
        routes
            .iter()
            .find(|(stored, _)| canonicalize(stored) == relay_form)
            .map_or_else(alias, |(_, own)| own.clone())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn route(aliases: &[&str]) -> (impl Fn(&str) -> String, Arc<AliasBook>) {
        let book = AliasBook::new(aliases.iter().map(|&url| url.to_owned()).collect());
        let route = endpoint_map(
            vec![
                (
                    "ws://127.0.0.1:1".to_owned(),
                    "ws://127.0.0.1:11".to_owned(),
                ),
                (
                    "ws://127.0.0.1:2".to_owned(),
                    "ws://127.0.0.1:22".to_owned(),
                ),
            ],
            Arc::clone(&book),
        );
        (route, book)
    }

    #[test]
    fn a_stored_address_routes_to_its_planes_own_endpoint_and_a_foreign_one_passes_through() {
        let (route, _) = route(&["ws://127.0.0.1:91"]);
        assert!(
            route("ws://127.0.0.1:2/") == "ws://127.0.0.1:22",
            "a stored address, in whichever normal form storage kept it, dials its plane's own endpoint"
        );
        assert!(
            route("ws://127.0.0.1:3") == "ws://127.0.0.1:3",
            "an address no plane stored is not invented a route"
        );
    }

    #[test]
    fn each_unserved_address_gets_an_endpoint_of_its_own_and_keeps_it() {
        let (route, book) = route(&["ws://127.0.0.1:91", "ws://127.0.0.1:92"]);
        let first = route("wss://one.example.com");
        let second = route("wss://two.example.com");
        assert!(
            first == "ws://127.0.0.1:91" && second == "ws://127.0.0.1:92",
            "two unserved addresses are two endpoints, never a plane's own one"
        );
        assert!(
            route("wss://one.example.com/") == first,
            "an address keeps its endpoint in whichever normal form it is named"
        );
        assert!(!book.overflowed());
        assert!(
            book.stands_for(1).as_deref() == Some("wss://two.example.com")
                && book.stands_for(2).is_none(),
            "each slot answers the address it stands for, and a slot nothing named none"
        );
    }

    #[test]
    fn an_address_past_the_last_endpoint_is_recorded_as_an_overflow() {
        let (route, book) = route(&["ws://127.0.0.1:91"]);
        let _ = route("wss://one.example.com");
        assert!(
            route("wss://two.example.com") == "ws://127.0.0.1:11",
            "past the book it names the first plane, never a host off the machine"
        );
        assert!(book.overflowed(), "and the book says so");
    }

    #[test]
    fn a_plane_that_gives_no_alias_endpoint_answers_with_its_own_and_overflows_nothing() {
        let (route, book) = route(&[]);
        assert_eq!(route("wss://one.example.com"), "ws://127.0.0.1:11");
        assert!(!book.overflowed());
    }
}
