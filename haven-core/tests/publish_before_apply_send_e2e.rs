//! Send-side publish-before-apply (Rule 13 / security F13).
//!
//! Rule 13: NEVER confirm a staged MLS commit before at least one relay has
//! returned an OK-ack. Confirming a merely-*sent* commit advances the local
//! epoch while every peer is still at the old one — the group is stranded, and
//! no later message decrypts on either side. "Sent" and "acked" are different
//! facts, and only the relay can supply the second one.
//!
//! # What is under test, and what is not
//!
//! The decision itself is [`publish_then_resolve`]: publish through the injected
//! relay plane ([`AutoCommitPublisher`], which production's `RelayManager` and
//! the live-sync `nostr_sdk::Client` both implement), then confirm iff that
//! plane reports a ≥1-relay OK-ack, else roll back.
//!
//! Two tiers, because the two halves fail in different ways:
//!
//! 1. **The wire tells the truth** — the production `RelayManager` plane is
//!    driven against real in-process relays that ack / reject / swallow / break
//!    the connection, pinning the boolean it reports for each. The third of
//!    those is the whole rule: an event the relay accepted onto the socket but
//!    never acknowledged must NOT count.
//! 2. **The decision follows the truth** — the four outcomes crossed with the
//!    four publish-bearing send operations, asserting what the engine actually
//!    did: an epoch/roster that moved only on an ack, and no staged remnant left
//!    behind when it did not.
//!
//! Boundary worth stating plainly: the FFI callers that drive these four ops in
//! the shipped app live in Dart (`nostr_circle_service.dart`), so this file pins
//! the Rust decision and its engine consequences, not the Dart call sites.

use std::future::Future;
use std::net::SocketAddr;
use std::pin::Pin;
use std::sync::Mutex;
use std::time::Duration;

use haven_core::circle::{CircleConfig, CircleManager, MemberKeyPackage};
use haven_core::nostr::mls::types::{GroupId, PendingStateRef};
use haven_core::relay::maintenance::build_kp_maintenance_events;
use haven_core::relay::{allow_ws_loopback_for_test, publish_then_resolve, AutoCommitPublisher};
use haven_core::relay::{RelayManager, RelayResult};
use nostr::util::BoxedFuture;
use nostr::{Event, Keys};
use nostr_relay_builder::builder::{PolicyResult, WritePolicy};
use nostr_relay_builder::{LocalRelay, MockRelay, RelayBuilder};
use tempfile::TempDir;

/// What a relay did with an event we put on its socket.
///
/// The four are exhaustive over what a publish can observe: an acknowledgement,
/// a refusal, silence, or a transport that broke. Only the first is an ack.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum WireOutcome {
    /// The relay answered `OK: true`.
    Acked,
    /// The relay answered `OK: false` (a NAK).
    Nak,
    /// The relay took the event and never answered.
    Timeout,
    /// The transport failed; the relay never got the event.
    Throw,
}

impl WireOutcome {
    const ALL: [Self; 4] = [Self::Acked, Self::Nak, Self::Timeout, Self::Throw];

    /// Rule 13's whole question.
    const fn is_ack(self) -> bool {
        matches!(self, Self::Acked)
    }

    /// Whether the event reached a relay at all. Distinguishes [`Self::Timeout`]
    /// — where the commit IS on the wire and could still land — from
    /// [`Self::Throw`], where nothing was transmitted. Both roll back.
    const fn reached_a_relay(self) -> bool {
        !matches!(self, Self::Throw)
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Tier 1 — the wire tells the truth.
//
// These drive the PRODUCTION relay plane (`RelayManager`, the same one the FFI
// publishes through) against real relays over real sockets. A fake here would
// be asserting the ack rule against itself.
//
// Load cannot flip any of them: three assert the ABSENCE of an ack, and no
// amount of scheduler pressure manufactures an `OK: true` a relay never sent.
// The one positive row is bounded by the production retry budget, not by a
// deadline this file invented.
// ═══════════════════════════════════════════════════════════════════════════

/// A relay that answers every event with `OK: false`.
#[derive(Debug)]
struct RejectEverything;

impl WritePolicy for RejectEverything {
    fn admit_event<'a>(
        &'a self,
        _event: &'a Event,
        _addr: &'a SocketAddr,
    ) -> BoxedFuture<'a, PolicyResult> {
        Box::pin(async { PolicyResult::Reject("test relay refuses this event".to_string()) })
    }
}

/// A relay that reads the event off the socket and never answers.
///
/// The policy is awaited inside the connection's own message loop, so the EVENT
/// has provably been transmitted — this is "sent", with the acknowledgement
/// withheld, which is exactly the state Rule 13 forbids confirming on. The sleep
/// outlives the publish budget by a wide margin; it is never a race, because the
/// assertion is on the verdict and not on when it arrives.
#[derive(Debug)]
struct NeverAnswer;

impl WritePolicy for NeverAnswer {
    fn admit_event<'a>(
        &'a self,
        _event: &'a Event,
        _addr: &'a SocketAddr,
    ) -> BoxedFuture<'a, PolicyResult> {
        Box::pin(async {
            tokio::time::sleep(Duration::from_secs(600)).await;
            PolicyResult::Accept
        })
    }
}

/// Runs an in-process relay with `policy` and returns its `ws://` URL.
async fn relay_with(policy: impl WritePolicy + 'static) -> (LocalRelay, String) {
    let relay = LocalRelay::new(RelayBuilder::default().write_policy(policy));
    relay.run().await.expect("local relay runs");
    let url = relay.url().await.to_string();
    (relay, url)
}

/// A TCP endpoint that accepts the connection and drops it before the WebSocket
/// handshake completes — a genuine transport failure.
///
/// A closed port would do the same job but would rely on nothing else having
/// grabbed it; holding the socket open keeps the outcome ours to control, and
/// costs no timeout to observe.
async fn broken_transport() -> (String, tokio::task::JoinHandle<()>) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind loopback");
    let addr = listener.local_addr().expect("local addr");
    let handle = tokio::spawn(async move {
        while let Ok((stream, _)) = listener.accept().await {
            drop(stream);
        }
    });
    (format!("ws://{addr}"), handle)
}

/// The verdict the production send plane reports for `event` → `relays`.
async fn relay_manager_verdict(event: &Event, relays: &[String]) -> bool {
    let manager = RelayManager::new();
    let publisher: &dyn AutoCommitPublisher = &manager;
    publisher.publish_auto_commit(event, relays).await
}

/// A real staged `kind:445` commit, so the relays see the event shape this path
/// actually carries rather than a synthetic note.
async fn a_real_commit_event() -> Event {
    let fx = TwoPartyCircle::build(&["wss://group.example.com".to_string()]).await;
    let staged = fx
        .alice
        .remove_members(&fx.gid, std::slice::from_ref(&fx.bob_hex))
        .await
        .expect("stage a removal commit");
    staged.commit_event
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_relay_that_ok_acks_is_an_ack() {
    let _ = allow_ws_loopback_for_test();
    let relay = MockRelay::run().await.expect("mock relay");
    let url = relay.url().await.to_string();
    let commit = a_real_commit_event().await;

    assert!(
        relay_manager_verdict(&commit, std::slice::from_ref(&url)).await,
        "a relay that answered OK:true must be reported as an ack — without \
         this the send path could never confirm anything"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_relay_that_returns_ok_false_is_not_an_ack() {
    let _ = allow_ws_loopback_for_test();
    let (_relay, url) = relay_with(RejectEverything).await;
    let commit = a_real_commit_event().await;

    assert!(
        !relay_manager_verdict(&commit, std::slice::from_ref(&url)).await,
        "a relay that answered OK:false rejected the commit; reporting an ack \
         here would confirm an epoch no peer will ever receive"
    );
}

/// The rule's core distinction: the relay took the event and stayed silent.
///
/// Costs the production publish budget (three bounded attempts, ~34 s) because
/// there is no other way to observe a real "sent but not acked" — that wall
/// clock is production's own retry policy, not a sleep this test invented, and
/// the assertion does not depend on when the verdict arrives. It is paid once
/// here rather than per operation below.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_relay_that_takes_the_event_and_never_answers_is_not_an_ack() {
    let _ = allow_ws_loopback_for_test();
    let (_relay, url) = relay_with(NeverAnswer).await;
    let commit = a_real_commit_event().await;

    assert!(
        !relay_manager_verdict(&commit, std::slice::from_ref(&url)).await,
        "the commit was SENT but never acknowledged — treating that as an ack \
         is precisely the Rule 13 violation that strands a group"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_broken_transport_is_not_an_ack() {
    let _ = allow_ws_loopback_for_test();
    let (url, listener) = broken_transport().await;
    let commit = a_real_commit_event().await;

    let verdict = relay_manager_verdict(&commit, std::slice::from_ref(&url)).await;
    listener.abort();

    assert!(
        !verdict,
        "a transport that never completed a handshake acknowledged nothing"
    );
}

/// The publish plane's own error contract, which the FFI relies on: a publish
/// nothing acked surfaces as `Err`, never as an `Ok` a caller could mistake for
/// success.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_unacked_publish_surfaces_as_an_error_not_an_empty_ok() {
    let _ = allow_ws_loopback_for_test();
    let (_relay, url) = relay_with(RejectEverything).await;
    let commit = a_real_commit_event().await;

    let result: RelayResult<_> = RelayManager::new()
        .publish_event(&commit, std::slice::from_ref(&url))
        .await;

    assert!(
        result.is_err(),
        "a zero-ack publish must not return Ok: callers that only check for a \
         thrown error would otherwise read a rejection as a successful send"
    );
}

// ═══════════════════════════════════════════════════════════════════════════
// Tier 2 — the decision follows the truth, for every publish-bearing operation.
// ═══════════════════════════════════════════════════════════════════════════

/// A relay plane pinned to one [`WireOutcome`].
///
/// The verdicts are not invented here: tier 1 pins that the production
/// `RelayManager` plane reports exactly these booleans for exactly these relay
/// behaviours. What the fake adds is determinism and speed — a `Timeout` cell
/// driven through a real socket costs the full production retry budget, so it is
/// paid once above instead of once per operation.
struct OutcomePublisher {
    outcome: WireOutcome,
    sent: Mutex<Vec<Event>>,
}

impl OutcomePublisher {
    const fn new(outcome: WireOutcome) -> Self {
        Self {
            outcome,
            sent: Mutex::new(Vec::new()),
        }
    }

    fn sent(&self) -> Vec<Event> {
        self.sent.lock().unwrap().clone()
    }
}

impl AutoCommitPublisher for OutcomePublisher {
    fn publish_auto_commit<'a>(
        &'a self,
        event: &'a Event,
        _relays: &'a [String],
    ) -> Pin<Box<dyn Future<Output = bool> + Send + 'a>> {
        Box::pin(async move {
            if self.outcome.reached_a_relay() {
                self.sent.lock().unwrap().push(event.clone());
            }
            self.outcome.is_ack()
        })
    }
}

/// Alice (admin) with Bob on the roster, created and confirmed.
///
/// Bob never processes his Welcome: the ops under test are all admin-side, and
/// his leaf is on the roster from creation either way, so joining would only add
/// fixture cost.
struct TwoPartyCircle {
    alice: CircleManager,
    alice_keys: Keys,
    bob_hex: String,
    gid: GroupId,
    _dirs: Vec<TempDir>,
}

impl TwoPartyCircle {
    async fn build(relays: &[String]) -> Self {
        let (bob_keys, bob_member, bob_dir) = mint_member().await;
        let alice_dir = TempDir::new().unwrap();
        let alice_keys = Keys::generate();
        let alice = CircleManager::new_unencrypted(alice_dir.path(), &alice_keys).unwrap();

        let config = CircleConfig::new("Rule 13 Circle").with_relays(relays.to_vec());
        let created = alice
            .create_circle(&alice_keys, vec![bob_member], &config, relays)
            .await
            .expect("create circle");
        let gid = created.circle.mls_group_id.clone();
        alice
            .confirm_published(created.pending)
            .await
            .expect("confirm the create");

        Self {
            alice,
            alice_keys,
            bob_hex: bob_keys.public_key().to_hex(),
            gid,
            _dirs: vec![alice_dir, bob_dir],
        }
    }

    async fn roster(&self) -> Vec<String> {
        self.alice
            .session()
            .member_pubkeys(&self.gid)
            .await
            .unwrap()
    }

    async fn epoch(&self) -> u64 {
        self.alice.session().epoch(&self.gid).await.unwrap()
    }

    async fn group_relays(&self) -> Vec<String> {
        self.alice.session().group_relays(&self.gid).await.unwrap()
    }
}

/// Mints a prospective member: their own store, keys and a real kind-30443
/// `KeyPackage` event.
async fn mint_member() -> (Keys, MemberKeyPackage, TempDir) {
    let dir = TempDir::new().unwrap();
    let keys = Keys::generate();
    let mgr = CircleManager::new_unencrypted(dir.path(), &keys).unwrap();
    let event = build_kp_maintenance_events(
        mgr.session(),
        &keys,
        &["wss://kp.example.com".to_string()],
        None,
        None,
    )
    .await
    .expect("key package")
    .event;
    let member = MemberKeyPackage {
        key_package_event: event,
        inbox_relays: vec!["wss://member-inbox.example.com".to_string()],
        nip65_relays: vec![],
    };
    (keys, member, dir)
}

/// The half of every cell that does not depend on which operation staged the
/// commit: the verdict matches the wire, the transport saw the event exactly
/// when it should have, and the staged reference is spent either way — nothing
/// is left dangling that a later stray confirm could apply.
async fn assert_resolution_contract(
    circle: &CircleManager,
    publisher: &OutcomePublisher,
    outcome: WireOutcome,
    confirmed: bool,
    pending: PendingStateRef,
) {
    assert_eq!(
        confirmed,
        outcome.is_ack(),
        "{outcome:?}: the staged commit must be confirmed if and ONLY if a relay \
         OK-acked it"
    );
    assert_eq!(
        publisher.sent().len(),
        usize::from(outcome.reached_a_relay()),
        "{outcome:?}: the commit must be handed to the transport exactly when the \
         transport was usable — publish-BEFORE-apply, never the reverse"
    );
    assert!(
        circle.confirm_published(pending).await.is_err(),
        "{outcome:?}: the staged reference must be spent, so a stray confirm can \
         never resurrect a commit the relays never took"
    );
}

/// Operation 1 of 4 — `create_circle`: the group-creation state is confirmed
/// only once a Welcome reached a relay, and a rollback leaves NO circle row.
///
/// One invitee, so the op stages exactly one Welcome and "≥1 welcome acked" is
/// the single publish this resolver expresses.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn create_circle_confirms_only_on_an_ack() {
    for outcome in WireOutcome::ALL {
        let (bob_keys, bob_member, _bob_dir) = mint_member().await;
        let alice_dir = TempDir::new().unwrap();
        let alice_keys = Keys::generate();
        let alice = CircleManager::new_unencrypted(alice_dir.path(), &alice_keys).unwrap();
        let relays = vec!["wss://group.example.com".to_string()];

        let config = CircleConfig::new("Rule 13 Create").with_relays(relays.clone());
        let created = alice
            .create_circle(&alice_keys, vec![bob_member], &config, &relays)
            .await
            .expect("stage the create");
        let gid = created.circle.mls_group_id.clone();
        let welcome = created
            .welcome_events
            .first()
            .expect("the invitee's gift-wrapped Welcome");

        let publisher = OutcomePublisher::new(outcome);
        let confirmed = publish_then_resolve(
            &alice,
            &publisher,
            &welcome.event,
            &welcome.recipient_relays,
            created.pending,
        )
        .await;

        assert_resolution_contract(&alice, &publisher, outcome, confirmed, created.pending).await;

        let row = alice.get_circle(&gid).await.expect("circle lookup");
        if outcome.is_ack() {
            assert!(
                row.is_some(),
                "{outcome:?}: an acked create keeps its circle"
            );
            let roster = alice.session().member_pubkeys(&gid).await.unwrap();
            assert!(
                roster.contains(&bob_keys.public_key().to_hex()),
                "{outcome:?}: the confirmed group must hold the invitee"
            );
        } else {
            assert!(
                row.is_none(),
                "{outcome:?}: a create nobody acked must leave no circle row — a \
                 ghost circle backed by no confirmed group is partial state"
            );
        }
    }
}

/// Operation 2 of 4 — `add_members_with_welcomes`: the Add commit is confirmed
/// only on an ack, so a new member joins the roster only at an epoch the group
/// actually received.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn add_members_confirms_only_on_an_ack() {
    for outcome in WireOutcome::ALL {
        let relays = vec!["wss://group.example.com".to_string()];
        let fx = TwoPartyCircle::build(&relays).await;
        let (carol_keys, carol_member, _carol_dir) = mint_member().await;
        let carol_hex = carol_keys.public_key().to_hex();
        let epoch_before = fx.epoch().await;

        let staged = fx
            .alice
            .add_members_with_welcomes(&fx.alice_keys, &fx.gid, vec![carol_member], &relays)
            .await
            .expect("stage the add");

        let publisher = OutcomePublisher::new(outcome);
        let confirmed = publish_then_resolve(
            &fx.alice,
            &publisher,
            &staged.commit_event,
            &relays,
            staged.pending,
        )
        .await;

        assert_resolution_contract(&fx.alice, &publisher, outcome, confirmed, staged.pending).await;

        assert_eq!(
            fx.roster().await.contains(&carol_hex),
            outcome.is_ack(),
            "{outcome:?}: the new member joins the roster only on an acked commit"
        );
        assert_eq!(
            fx.epoch().await,
            epoch_before + u64::from(outcome.is_ack()),
            "{outcome:?}: the epoch may advance only past a commit the relays took"
        );
    }
}

/// Operation 3 of 4 — `remove_members`: an eviction is applied only on an ack.
///
/// The failure direction is the dangerous one: a local epoch past an eviction no
/// peer received means the removed member still holds the key material every
/// remaining member is using.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn remove_members_confirms_only_on_an_ack() {
    for outcome in WireOutcome::ALL {
        let relays = vec!["wss://group.example.com".to_string()];
        let fx = TwoPartyCircle::build(&relays).await;
        let epoch_before = fx.epoch().await;
        assert!(fx.roster().await.contains(&fx.bob_hex));

        let staged = fx
            .alice
            .remove_members(&fx.gid, std::slice::from_ref(&fx.bob_hex))
            .await
            .expect("stage the removal");

        let publisher = OutcomePublisher::new(outcome);
        let confirmed = publish_then_resolve(
            &fx.alice,
            &publisher,
            &staged.commit_event,
            &relays,
            staged.pending,
        )
        .await;

        assert_resolution_contract(&fx.alice, &publisher, outcome, confirmed, staged.pending).await;

        assert_eq!(
            fx.roster().await.contains(&fx.bob_hex),
            !outcome.is_ack(),
            "{outcome:?}: the member leaves the roster only on an acked commit"
        );
        assert_eq!(
            fx.epoch().await,
            epoch_before + u64::from(outcome.is_ack()),
            "{outcome:?}: an unacked eviction must return the group to its prior \
             epoch, not advance past a commit the evicted member never saw"
        );
    }
}

/// Operation 4 of 4 — `update_circle_relays`: the routing component moves only
/// on an ack, so the group never starts publishing to a relay set its members
/// were never told about.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn update_circle_relays_confirms_only_on_an_ack() {
    for outcome in WireOutcome::ALL {
        let relays = vec!["wss://group.example.com".to_string()];
        let fx = TwoPartyCircle::build(&relays).await;
        let epoch_before = fx.epoch().await;
        let new_relays = vec!["wss://replacement.example.com".to_string()];

        let staged = fx
            .alice
            .update_circle_relays(&fx.gid, &new_relays)
            .await
            .expect("stage the relay update");

        // Published to the UNION of old and new, as the caller must: the members
        // still on the old set have to receive the commit that moves them.
        let mut targets = relays.clone();
        targets.extend(new_relays.clone());

        let publisher = OutcomePublisher::new(outcome);
        let confirmed = publish_then_resolve(
            &fx.alice,
            &publisher,
            &staged.commit_event,
            &targets,
            staged.pending,
        )
        .await;

        assert_resolution_contract(&fx.alice, &publisher, outcome, confirmed, staged.pending).await;

        let expected = if outcome.is_ack() {
            &new_relays
        } else {
            &relays
        };
        assert_eq!(
            &fx.group_relays().await,
            expected,
            "{outcome:?}: the group's routing set may change only on an acked commit"
        );
        assert_eq!(
            fx.epoch().await,
            epoch_before + u64::from(outcome.is_ack()),
            "{outcome:?}: the epoch may advance only past a commit the relays took"
        );
    }
}
