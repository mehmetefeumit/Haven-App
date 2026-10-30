//! `KeyPackage` discovery reads the invitee's NIP-65 WRITE-capable relays and
//! nothing retired (Marmot `transports/nostr.md:293-302`).
//!
//! Every relay here records the REQ filters it is sent, so the assertions are
//! about what Haven ASKED, not merely what came back: the invitee's
//! `KeyPackage` is stored on the read-only relay too, and a fetch that went
//! there would still find it.

use std::sync::{Arc, Mutex, OnceLock};

use haven_core::circle::CircleManager;
use haven_core::relay::maintenance::build_kp_maintenance_events;
use haven_core::relay::{allow_ws_loopback_for_test, set_discovery_relays_for_test, RelayManager};
use nostr::{Event, EventBuilder, Filter, Keys, Kind, PublicKey, Tag};
use nostr_relay_builder::prelude::{
    BoxedFuture, MemoryDatabase, MemoryDatabaseOptions, NostrDatabase, PolicyResult, QueryPolicy,
};
use nostr_relay_builder::{LocalRelay, RelayBuilder};
use tempfile::TempDir;

/// Every REQ filter a relay admitted.
#[derive(Clone, Default)]
struct Queries(Arc<Mutex<Vec<Filter>>>);

impl Queries {
    fn all(&self) -> Vec<Filter> {
        self.0.lock().unwrap().clone()
    }
}

// A filter names authors; nothing here is rendered.
impl std::fmt::Debug for Queries {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Queries").finish_non_exhaustive()
    }
}

impl QueryPolicy for Queries {
    fn admit_query<'a>(
        &'a self,
        query: &'a Filter,
        _addr: &'a std::net::SocketAddr,
    ) -> BoxedFuture<'a, PolicyResult> {
        self.0.lock().unwrap().push(query.clone());
        Box::pin(async { PolicyResult::Accept })
    }
}

struct Relay {
    url: String,
    db: MemoryDatabase,
    queries: Queries,
}

impl Relay {
    async fn run() -> (Self, LocalRelay) {
        let db = MemoryDatabase::with_opts(MemoryDatabaseOptions {
            events: true,
            max_events: None,
        });
        let queries = Queries::default();
        let relay = LocalRelay::new(
            RelayBuilder::default()
                .database(db.clone())
                .query_policy(queries.clone()),
        );
        relay.run().await.expect("relay runs");
        let url = relay.url().await.to_string();
        (Self { url, db, queries }, relay)
    }

    async fn store(&self, event: &Event) {
        assert!(self.db.save_event(event).await.expect("save").is_success());
    }
}

/// The discovery plane is process-wide (`set_discovery_relays_for_test` is
/// one-shot), so its relay runs on a thread of its own and outlives every
/// test's runtime.
fn discovery() -> &'static Relay {
    static DISCOVERY: OnceLock<Relay> = OnceLock::new();
    DISCOVERY.get_or_init(|| {
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .expect("runtime")
                .block_on(async {
                    let (relay, _server) = Relay::run().await;
                    tx.send(relay).expect("hand the relay over");
                    std::future::pending::<()>().await;
                });
        });
        let relay = rx.recv().expect("discovery relay");
        let _ = allow_ws_loopback_for_test();
        set_discovery_relays_for_test(vec![relay.url.clone()]).expect("install discovery");
        relay
    })
}

/// An invitee whose `KeyPackage` sits on both relays, and whose NIP-65 list
/// marks one read-only and the other write-only.
async fn invitee(read: &Relay, write: &Relay) -> (Keys, Event, TempDir) {
    let dir = TempDir::new().unwrap();
    let keys = Keys::generate();
    let manager = CircleManager::new_unencrypted(dir.path(), &keys).unwrap();
    let key_package = build_kp_maintenance_events(
        manager.session(),
        &keys,
        std::slice::from_ref(&write.url),
        None,
        None,
    )
    .await
    .expect("mint a key package")
    .event;
    read.store(&key_package).await;
    write.store(&key_package).await;
    let relay_list = EventBuilder::new(Kind::RelayList, "")
        .tags([
            Tag::parse(["r", read.url.as_str(), "read"]).unwrap(),
            Tag::parse(["r", write.url.as_str(), "write"]).unwrap(),
        ])
        .sign_with_keys(&keys)
        .expect("sign the relay list");
    discovery().store(&relay_list).await;
    (keys, key_package, dir)
}

fn by(filter: &Filter, author: &PublicKey) -> bool {
    filter
        .authors
        .as_ref()
        .is_some_and(|authors| authors.contains(author))
}

fn asks_for(filter: &Filter, kind: u16) -> bool {
    filter
        .kinds
        .as_ref()
        .is_some_and(|kinds| kinds.contains(&Kind::from(kind)))
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn kp_fetch_uses_write_capable_set_only() {
    discovery();
    let (read, _read_server) = Relay::run().await;
    let (write, _write_server) = Relay::run().await;
    let (keys, key_package, _dir) = invitee(&read, &write).await;

    let fetched = RelayManager::new()
        .fetch_keypackage(&keys.public_key().to_hex())
        .await
        .expect("the fetch runs")
        .expect("the key package is found");

    assert_eq!(fetched.id, key_package.id);
    assert!(
        write
            .queries
            .all()
            .iter()
            .any(|filter| by(filter, &keys.public_key()) && asks_for(filter, 30443)),
        "the key package is asked for on the write-capable relay"
    );
    assert!(
        read.queries.all().is_empty(),
        "a read-only relay is never asked for the invitee's key package"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn no_10051_or_443_req_issued() {
    discovery();
    let (read, _read_server) = Relay::run().await;
    let (write, _write_server) = Relay::run().await;
    let (keys, _key_package, _dir) = invitee(&read, &write).await;

    RelayManager::new()
        .fetch_keypackage(&keys.public_key().to_hex())
        .await
        .expect("the fetch runs")
        .expect("the key package is found");

    let asked: Vec<Filter> = [&discovery().queries, &read.queries, &write.queries]
        .iter()
        .flat_map(|queries| queries.all())
        .filter(|filter| by(filter, &keys.public_key()))
        .collect();
    assert!(
        asked.iter().any(|filter| asks_for(filter, 10002))
            && asked.iter().any(|filter| asks_for(filter, 30443)),
        "the relay list and the key package were really asked for"
    );
    for retired in [10051, 443] {
        assert!(
            !asked.iter().any(|filter| asks_for(filter, retired)),
            "kind {retired} is retired and must never be requested"
        );
    }
}
