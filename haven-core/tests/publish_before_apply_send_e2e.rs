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
//! Two tiers, because the two halves fail in different ways:
//!
//! 1. **The wire tells the truth** — the production `RelayManager` plane, which
//!    publishes what has no record ([`UnrecordedPublisher`]: Welcomes and
//!    proposals), is driven against real in-process relays that ack / reject /
//!    swallow / break the connection, pinning the boolean it reports for each.
//!    The third of those is the whole rule: an event the relay accepted onto
//!    the socket but never acknowledged must NOT count. The fanout transport a
//!    commit is sent through is pinned the same way in
//!    `fanout_transport_matrix.rs`.
//! 2. **The decision follows the truth** — the fanout driver's three
//!    commit-bearing changes, each crossed with the four outcomes, asserting
//!    what the engine actually did: an epoch, roster or relay list that moved
//!    only on an ack, a commit discarded only when its relay proved it refused
//!    it, and one that may have landed kept. The founding create is crossed
//!    with the same four outcomes to pin the opposite promise: it has no
//!    commit to confirm, so no outcome rolls it back.

mod helpers;

use std::future::Future;
use std::net::SocketAddr;
use std::pin::Pin;

use haven_core::circle::{CircleConfig, CircleManager, MemberKeyPackage};
use haven_core::nostr::mls::types::{EpochState, GroupId};
use haven_core::relay::allow_ws_loopback_for_test;
use haven_core::relay::fanout::scripted::{Answer, ScriptedFanout};
use haven_core::relay::fanout::{
    DriveMode, EvolutionOutcome, EvolutionStatus, UnrecordedPublisher,
};
use haven_core::relay::maintenance::build_kp_maintenance_events;
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

    /// Whether the relay's answer settles the commit: an ack applies it and a
    /// proven refusal discards it. Silence may hide a landed commit, and a
    /// relay never reached proves nothing, so either leaves it staged.
    const fn settles(self) -> bool {
        matches!(self, Self::Acked | Self::Nak)
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
/// withheld, which is exactly the state Rule 13 forbids confirming on. The
/// pending future never resolves, so the OK is withheld BY CONSTRUCTION rather
/// than by out-sleeping the publish budget: no margin to get wrong, and no
/// wall-clock race for the verdict to run against.
#[derive(Debug)]
struct NeverAnswer;

impl WritePolicy for NeverAnswer {
    fn admit_event<'a>(
        &'a self,
        _event: &'a Event,
        _addr: &'a SocketAddr,
    ) -> BoxedFuture<'a, PolicyResult> {
        Box::pin(async {
            std::future::pending::<()>().await;
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
    let publisher: &dyn UnrecordedPublisher = &manager;
    publisher.publish_unrecorded(event, relays).await
}

/// A real staged `kind:445` commit, so the relays see the event shape this path
/// actually carries rather than a synthetic note.
async fn a_real_commit_event() -> Event {
    let fx = TwoPartyCircle::build(&["wss://group.example.com".to_string()]).await;
    fx.alice
        .remove_members_for_test(&fx.gid, std::slice::from_ref(&fx.bob_hex))
        .await
        .expect("a removal commit")
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
struct OutcomePublisher(WireOutcome);

impl UnrecordedPublisher for OutcomePublisher {
    fn publish_unrecorded<'a>(
        &'a self,
        _event: &'a Event,
        _relays: &'a [String],
    ) -> Pin<Box<dyn Future<Output = bool> + Send + 'a>> {
        Box::pin(async move { self.0.is_ack() })
    }
}

/// Alice (admin) with Bob on the roster, created (a founding create is canonical).
///
/// Bob never processes his Welcome: the ops under test are all admin-side, and
/// his leaf is on the roster from creation either way, so joining would only add
/// fixture cost.
struct TwoPartyCircle {
    alice: CircleManager,
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
            .create_circle(&alice_keys, vec![bob_member], &config)
            .await
            .expect("create circle");
        // As the app's driven create leaves it: the founding Welcomes sent from
        // their records and acknowledged, so no later drive sends them.
        let _ = alice.land_staged_for_test().await;
        let gid = created.circle.mls_group_id;

        Self {
            alice,
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
        nip65_write_relays: vec![],
    };
    (keys, member, dir)
}

/// What the fanout transport answers for a relay that behaved as `outcome`
/// did — the classification tier 1 and `fanout_transport_matrix.rs` pin.
const fn answer_for(outcome: WireOutcome) -> Answer {
    match outcome {
        WireOutcome::Acked => Answer::Accepted,
        WireOutcome::Nak => Answer::Refused,
        WireOutcome::Timeout => Answer::Silent,
        WireOutcome::Throw => Answer::Unreachable,
    }
}

/// `change` made through the fanout driver in the full mode, every relay
/// answering as `outcome` scripts: what the driver said of it, and whether it
/// put the commit on a relay's socket.
async fn made(
    fx: &TwoPartyCircle,
    outcome: WireOutcome,
    change: impl AsyncFnOnce(
        &haven_core::relay::fanout::Publishing<'_, ScriptedFanout>,
        &CircleManager,
        &GroupId,
    ) -> Result<EvolutionOutcome, haven_core::circle::CircleError>,
) -> (EvolutionStatus, bool) {
    let transport = ScriptedFanout::default();
    for relay in TARGETS {
        transport.answer(relay, [answer_for(outcome)]);
    }
    let outbox = helpers::drive::Recorder::acking(true);
    let clock = helpers::drive::ManualClock::at(0);
    let driver = helpers::drive::through(&transport, &outbox, &clock, &DriveMode::Full);
    let status = change(&driver, &fx.alice, &fx.gid)
        .await
        .expect("the change is made")
        .status;
    (status, !transport.calls().is_empty())
}

/// Every relay a cell's change can be sent to: the circle's own, and the one a
/// relay change moves it to.
const TARGETS: [&str; 2] = ["wss://group.example.com", "wss://replacement.example.com"];

/// The half of every cell that does not depend on which operation made the
/// commit: the commit was put to its relays before anything applied it, it
/// is applied if and only if a relay acknowledged it, it is discarded only
/// when its relay proved it refused it, and a commit that may have landed —
/// or was never sent — is kept staged for the next drive.
async fn assert_resolution_contract(
    fx: &TwoPartyCircle,
    outcome: WireOutcome,
    (status, sent): (EvolutionStatus, bool),
) {
    assert!(
        sent,
        "{outcome:?}: the commit was not put to its relays — publish-BEFORE-apply"
    );
    let expected = match outcome {
        WireOutcome::Acked => EvolutionStatus::Confirmed,
        WireOutcome::Nak => EvolutionStatus::RolledBack,
        WireOutcome::Timeout | WireOutcome::Throw => EvolutionStatus::Unresolved,
    };
    assert_eq!(
        status, expected,
        "{outcome:?}: the commit must be confirmed if and ONLY if a relay OK-acked \
         it, and rolled back only on a proven refusal"
    );
    assert!(
        !fx.alice
            .session()
            .staged_without_fanout_for_test(&fx.gid)
            .await,
        "{outcome:?}: a commit was left staged with no record",
    );
    assert_eq!(
        matches!(
            fx.alice.session().epoch_state(&fx.gid).await,
            Some(EpochState::PendingPublish(_))
        ),
        !outcome.settles(),
        "{outcome:?}: a commit no relay settled was not kept staged — neither \
         applied nor discarded — or a settled one was",
    );
}

/// Operation 1 of 4 — `create_circle`: a founding create has no group-message
/// obligation, so whatever the wire does with its Welcome, the circle is never
/// rolled back.
///
/// MDK v0.10.4 returns `PublishWork::FoundingGroupCreated` with no pending ref
/// (`cgka-session/src/lib.rs:268-270`): the group is canonical before anything
/// is published, and there is nothing to confirm. A Welcome no relay accepted
/// leaves the invitee not yet joined — it must not take the creator's circle
/// with it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn create_never_rolls_back() {
    for outcome in WireOutcome::ALL {
        let (bob_keys, bob_member, _bob_dir) = mint_member().await;
        let alice_dir = TempDir::new().unwrap();
        let alice_keys = Keys::generate();
        let alice = CircleManager::new_unencrypted(alice_dir.path(), &alice_keys).unwrap();
        let relays = vec!["wss://group.example.com".to_string()];

        let config = CircleConfig::new("Rule 13 Create").with_relays(relays.clone());
        let created = alice
            .create_circle(&alice_keys, vec![bob_member], &config)
            .await
            .expect("create");
        let gid = created.circle.mls_group_id.clone();
        let welcome = created
            .welcome_events
            .first()
            .expect("the invitee's gift-wrapped Welcome");

        let publisher = OutcomePublisher(outcome);
        let acked = publisher
            .publish_unrecorded(&welcome.event, &welcome.recipient_relays)
            .await;
        assert_eq!(
            acked,
            outcome.is_ack(),
            "{outcome:?}: the fake reports its own outcome"
        );

        assert!(
            alice
                .get_circle(&gid)
                .await
                .expect("circle lookup")
                .is_some(),
            "{outcome:?}: a founding create keeps its circle whatever became of its Welcome"
        );
        let roster = alice.session().member_pubkeys(&gid).await.unwrap();
        assert!(
            roster.contains(&bob_keys.public_key().to_hex()),
            "{outcome:?}: the founded group already holds the invitee"
        );
        let staged = alice
            .session()
            .update_relays(&gid, relays.clone())
            .await
            .expect("stage a commit on the founded group");
        assert!(
            staged.publish.iter().any(|work| matches!(
                work,
                haven_core::nostr::mls::types::PublishWork::GroupEvolution { .. }
            )),
            "{outcome:?}: nothing is pending, so the group accepts its next commit at once"
        );
    }
}

/// Operation 2 of 4 — an invite: the Add commit is confirmed only on an ack,
/// so a new member joins the roster only at an epoch the group actually
/// received.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn add_members_confirms_only_on_an_ack() {
    for outcome in WireOutcome::ALL {
        let fx = TwoPartyCircle::build(&[TARGETS[0].to_string()]).await;
        let (carol_keys, carol_member, _carol_dir) = mint_member().await;
        let carol_hex = carol_keys.public_key().to_hex();
        let epoch_before = fx.epoch().await;

        let made = made(&fx, outcome, async |driver, circle, group| {
            driver
                .add_members(circle, group, std::slice::from_ref(&carol_member))
                .await
        })
        .await;
        assert_resolution_contract(&fx, outcome, made).await;
        if !outcome.settles() {
            continue;
        }

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

/// Operation 3 of 4 — a removal: an eviction is applied only on an ack.
///
/// The failure direction is the dangerous one: a local epoch past an eviction no
/// peer received means the removed member still holds the key material every
/// remaining member is using.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn remove_members_confirms_only_on_an_ack() {
    for outcome in WireOutcome::ALL {
        let fx = TwoPartyCircle::build(&[TARGETS[0].to_string()]).await;
        let epoch_before = fx.epoch().await;
        assert!(fx.roster().await.contains(&fx.bob_hex));

        let bob = fx.bob_hex.clone();
        let made = made(&fx, outcome, async |driver, circle, group| {
            driver
                .remove_members(circle, group, std::slice::from_ref(&bob))
                .await
        })
        .await;
        assert_resolution_contract(&fx, outcome, made).await;
        if !outcome.settles() {
            continue;
        }

        assert_eq!(
            fx.roster().await.contains(&fx.bob_hex),
            !outcome.is_ack(),
            "{outcome:?}: the member leaves the roster only on an acked commit"
        );
        assert_eq!(
            fx.epoch().await,
            epoch_before + u64::from(outcome.is_ack()),
            "{outcome:?}: an unacked eviction must leave the group at its prior \
             epoch, not advance past a commit the evicted member never saw"
        );
    }
}

/// Operation 4 of 4 — a relay change: the routing component moves only on an
/// ack, so the group never starts publishing to a relay set its members were
/// never told about.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn update_circle_relays_confirms_only_on_an_ack() {
    for outcome in WireOutcome::ALL {
        let relays = vec![TARGETS[0].to_string()];
        let fx = TwoPartyCircle::build(&relays).await;
        let epoch_before = fx.epoch().await;
        let new_relays = vec![TARGETS[1].to_string()];

        let made = made(&fx, outcome, async |driver, circle, group| {
            driver.update_relays(circle, group, &new_relays).await
        })
        .await;
        assert_resolution_contract(&fx, outcome, made).await;
        if !outcome.settles() {
            continue;
        }

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
