//! A device far behind its circle, with no room left for what it cannot yet
//! open, still catches up (Security Rule 12): what the engine refused is owed
//! its refetch — by id, or past the ledger's cap as a range of the circle's
//! history — for as long as it takes, and every new epoch asks for it again.
//! Nobody outside the circle can keep a genuine event from being fetched,
//! however many of their own they have had refused.
//!
//! Real MDK engines over `SQLCipher` stores and an in-process relay. Nothing
//! in a ledger is written by a test: every owed id is one the engine itself
//! refused, handed a real event.

#![allow(clippy::unwrap_used, clippy::expect_used)]

mod helpers;

use std::sync::Arc;

use base64::Engine as _;
use haven_core::nostr::mls::types::{GroupId, SendIntent};
use haven_core::nostr::mls::{
    max_rewind_commits, HAND_BACK_SLICE, HAND_BACK_WHOLE, MAX_REFUSED_IDS_PER_GROUP,
};
use haven_core::relay::catchup::{
    run_refused_refetch, CATCHUP_MAX_EVENTS_PER_PAGE, REFETCH_REQS_PER_SWEEP,
};
use haven_core::relay::{allow_ws_loopback_for_test, RelayManager};
use helpers::drive::{epoch, sealed_by, sealed_in_front_by};
use helpers::stranded::{
    answer, confirm_and_die, fill_the_deferral_store, held, parks, split, staged, unopenable,
    unopenable_at, unopened_retryable,
};
use helpers::{setup_circle, CircleMember};
use nostr::{Event, EventId};
use nostr_relay_builder::prelude::{
    BoxedFuture, MemoryDatabase, MemoryDatabaseOptions, PolicyResult, QueryPolicy, RateLimit,
};
use nostr_relay_builder::{LocalRelay, RelayBuilder};

/// Counts the REQs a relay is asked: those that name ids, and the rest.
#[derive(Debug, Clone, Default)]
struct Asked {
    by_id: Arc<std::sync::atomic::AtomicUsize>,
    other: Arc<std::sync::atomic::AtomicUsize>,
}

impl Asked {
    fn by_id(&self) -> usize {
        self.by_id.load(std::sync::atomic::Ordering::SeqCst)
    }

    fn other(&self) -> usize {
        self.other.load(std::sync::atomic::Ordering::SeqCst)
    }
}

impl QueryPolicy for Asked {
    fn admit_query<'a>(
        &'a self,
        query: &'a nostr::Filter,
        _addr: &'a std::net::SocketAddr,
    ) -> BoxedFuture<'a, PolicyResult> {
        Box::pin(async move {
            let counter = if query.ids.is_some() {
                &self.by_id
            } else {
                &self.other
            };
            counter.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            PolicyResult::Accept
        })
    }
}

async fn counting_relay() -> (LocalRelay, String, Asked) {
    let _ = allow_ws_loopback_for_test();
    let asked = Asked::default();
    let relay = LocalRelay::new(
        RelayBuilder::default()
            .query_policy(asked.clone())
            // A flood is published here faster than a relay's default allows.
            .rate_limit(RateLimit {
                max_reqs: 500,
                notes_per_minute: u32::MAX,
            })
            .database(MemoryDatabase::with_opts(MemoryDatabaseOptions {
                events: true,
                max_events: None,
            })),
    );
    relay.run().await.expect("an in-process relay");
    let url = relay.url().await.to_string();
    (relay, url, asked)
}

/// `count` commits of `member`'s own, each confirmed, oldest first.
async fn commits_by(member: &CircleMember, group: &GroupId, count: usize) -> Vec<Event> {
    let mut commits = Vec::new();
    for _ in 0..count {
        let effects = member
            .session()
            .send(SendIntent::SelfUpdate {
                group_id: group.clone(),
            })
            .await
            .expect("the member commits");
        let (commit, pending) = staged(&effects);
        member
            .session()
            .confirm_published(pending)
            .await
            .expect("and its relays took the commit");
        commits.push(commit);
    }
    commits
}

/// Stages a change of `admin`'s that leaves the circle's relays as they are
/// — both members become admins — and returns it with its pending state.
async fn stage_a_change(
    admin: &CircleMember,
    peer: &CircleMember,
    group: &GroupId,
) -> (Event, haven_core::nostr::mls::types::PendingStateRef) {
    let effects = admin
        .session()
        .update_admin_policy(
            group,
            &[
                admin.keys.public_key().to_bytes(),
                peer.keys.public_key().to_bytes(),
            ],
        )
        .await
        .expect("the change is staged");
    staged(&effects)
}

/// Makes every call it takes for `member` to have been handed back all it
/// holds stranded in `group`, and then serves the engine's deadlines.
async fn hand_back_everything(member: &CircleMember, group: &GroupId, parked: usize) {
    for _ in 0..=parked.div_ceil(HAND_BACK_WHOLE) {
        if unopened_retryable(&held(member.session(), group).await) == 0 {
            break;
        }
        let _ = member.session().advance_for_receive(group).await;
    }
    assert_eq!(
        unopened_retryable(&held(member.session(), group).await),
        0,
        "premise: everything stranded was handed back",
    );
}

/// Serves the deadlines the engine announces for `group` until `member`
/// stands on an epoch `reached` accepts, or the engine owes nothing soon,
/// and returns the epoch it then stands on. No relay is asked.
///
/// Not a count of advances: one advance works to a budget of wall time
/// (MDK's `BACKGROUND_CONVERGENCE_BUDGET_MS`) and, with the deferral store
/// full, spends it on rows nothing opens before it closes a pass — so how
/// many a commit takes is the machine's, and a test that counted them would
/// pass or fail by its load.
async fn served_until(
    member: &CircleMember,
    group: &GroupId,
    reached: impl Fn(u64) -> bool,
) -> u64 {
    let session = member.session();
    let _ = session.advance_for_receive(group).await;
    loop {
        let at = epoch(member, group).await;
        if reached(at) {
            return at;
        }
        let Some(after) = session.receive_retick_after(group).await else {
            return at;
        };
        tokio::time::sleep(after).await;
        let _ = session.advance_for_receive(group).await;
    }
}

/// Sets `member`'s clock `days` days past the real one.
fn a_day_later(member: &CircleMember, days: usize) {
    let now = u64::try_from(chrono::Utc::now().timestamp_millis()).expect("after 1970");
    member
        .session()
        .set_legacy_clock_for_test(now + u64::try_from(days).expect("small") * 24 * 3_600 * 1_000);
}

/// The ids `member` owes a refetch of in `group` that are due now.
fn owed(member: &CircleMember, group: &GroupId) -> Vec<EventId> {
    member.session().refused_redeliveries(group, usize::MAX)
}

/// Every id `member` owes a refetch of in `group`, whatever wait it is
/// serving: read with its clock `days` days on, which is past the longest
/// wait an id asked for before then can have earned.
fn on_record(member: &CircleMember, group: &GroupId, days: usize) -> Vec<EventId> {
    a_day_later(member, days);
    owed(member, group)
}

/// A device that is more commits behind its circle than the engine rewinds,
/// with no room left for anything it cannot open, reaches the circle's
/// epoch — and on the way no commit it still needs stops being owed.
///
/// The commits arrive newest first while a commit of the device's own is
/// pending, and are stranded behind it by a kill. Handed back, every one but
/// the oldest is from an epoch the device has not reached: the engine can
/// only keep such an event to open later, has no room to, and refuses it.
/// From then on each is on record only as an id owed its refetch — FIRST
/// refused at the epoch the device stood on then. An id that ended once its
/// circle had moved some number of epochs past that would be exactly the
/// commit the device needs next, deleted as it reaches it: it would stop
/// there for good and go on sealing for an epoch the rest have left.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_device_far_behind_with_no_room_reaches_its_circles_epoch_and_no_owed_commit_ends_on_the_way(
) {
    let behind = usize::try_from(max_rewind_commits()).expect("a small number") + 2;
    let (_relay, url, asked) = counting_relay().await;
    let relays = RelayManager::new();
    let fx = setup_circle(2, &[&url]).await;
    let (admin, others, group) = split(fx);
    let peer = &others[0];
    fill_the_deferral_store(&admin, &group, &sealed_by(peer, &group, 0.5).await).await;
    let source = epoch(&admin, &group).await;
    let (mine, pending) = stage_a_change(&admin, peer, &group).await;
    peer.session()
        .process_event_settled_for_test(&mine)
        .await
        .expect("the circle applies this device's commit");
    let commits = commits_by(peer, &group, behind).await;
    for commit in commits.iter().rev() {
        assert!(
            parks(admin.session(), commit).await,
            "premise: parked unread"
        );
        relays
            .publish_event(commit, std::slice::from_ref(&url))
            .await
            .expect("the relay holds the commit");
    }
    let admin = confirm_and_die(admin, pending, source + 1).await.reopen();
    hand_back_everything(&admin, &group, behind).await;
    let tip = epoch(peer, &group).await;
    let needed = |at: u64| -> Vec<EventId> {
        let applied = usize::try_from(at - (source + 1)).expect("small");
        commits[applied..].iter().map(|commit| commit.id).collect()
    };
    let reached = served_until(&admin, &group, |at| at == source + 2).await;
    // `assert!`, not `assert_eq!`: an id is never formatted (Security Rule 15).
    assert!(
        reached == source + 2
            && needed(reached).len() == behind - 1
            && needed(reached)
                .iter()
                .all(|id| owed(&admin, &group).contains(id)),
        "premise: the oldest commit was applied, and every later one — refused for want of \
         room — is owed its refetch by id",
    );

    let mut at = reached;
    for sweep in 1..=behind {
        if at == tip {
            break;
        }
        // A day on: whatever wait the last sweep earned an id is over.
        a_day_later(&admin, sweep);
        let before = asked.by_id();
        let _ = run_refused_refetch(&admin.circle, &relays, 120).await;
        let now = served_until(&admin, &group, |now| now > at).await;
        assert!(
            now > at,
            "a sweep that asked for the commits the device still needs brought it no nearer \
             its circle's epoch",
        );
        assert!(
            asked.by_id() - before <= REFETCH_REQS_PER_SWEEP,
            "a sweep asked a relay for refused ids more often than its share",
        );
        at = now;
        // On record, due or not: a commit the sweep asked for and the engine
        // refused again may be serving the wait that earned.
        let still = on_record(&admin, &group, sweep + 1);
        // Or the engine's: an id is discharged once the engine holds its event.
        assert!(
            needed(at)
                .iter()
                .all(|id| still.contains(id) || admin.session().engine_processed(id)),
            "a commit the device has not reached yet is neither owed its refetch nor held by \
             the engine: it was ended by how far the circle had moved since it was first refused",
        );
    }
    assert!(at == tip, "the device did not reach its circle's epoch");
    // A commit the engine held when its refetch was answered, and applied
    // after, is discharged by the next sweep that asks for it.
    a_day_later(&admin, behind + 1);
    let _ = run_refused_refetch(&admin.circle, &relays, 120).await;
    assert!(
        on_record(&admin, &group, behind + 2).is_empty(),
        "a commit the device applied is still owed its refetch",
    );
    let sealed = sealed_in_front_by(&admin, &group, 12.0).await;
    assert!(
        matches!(
            answer(peer.session(), &sealed).await,
            haven_core::nostr::mls::types::IngestOutcome::Processed
        ),
        "the circle cannot read what the device seals once it has caught up",
    );
}

/// Somebody outside the circle who has had more events refused than the
/// ledger holds ids for cannot keep a member's commit from being fetched.
///
/// The outsider needs the circle's routing tag and nothing else: enough
/// events nothing opens to fill the engine's store of what it cannot open,
/// then more than [`MAX_REFUSED_IDS_PER_GROUP`] while a commit of this
/// device's is pending. Handed back, each is refused; the ledger fills with
/// their ids, and the member's commit — from an epoch not reached, refused
/// like them — is on record only as part of the range of history the circle
/// owes. The relay goes on serving the outsider's events, so every request
/// by id comes back with nothing the engine has room for.
///
/// One sweep after the device reaches the epoch that commit leaves has
/// fetched it: the range is asked for on its own account, whatever became
/// of the ids, and the newest of a circle's history is the first page of it.
/// The engine, served its deadlines and handed nothing more, then applies
/// it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_outsiders_refused_flood_cannot_keep_a_members_commit_from_being_fetched() {
    const FLOOD: usize = MAX_REFUSED_IDS_PER_GROUP + 6;
    let (_relay, url, asked) = counting_relay().await;
    let relays = RelayManager::new();
    let fx = setup_circle(2, &[&url]).await;
    let (admin, others, group) = split(fx);
    let peer = &others[0];
    let like = sealed_by(peer, &group, 0.5).await;
    fill_the_deferral_store(&admin, &group, &like).await;
    let source = epoch(&admin, &group).await;
    let (mine, pending) = stage_a_change(&admin, peer, &group).await;
    peer.session()
        .process_event_settled_for_test(&mine)
        .await
        .expect("the circle applies this device's commit");
    // A second below the commits that follow: more than a page of it in a
    // commit's own second is the one-second pile-up no `until` reaches past
    // (`a_pile_up_dated_in_one_second_…`), which a fast machine would mint
    // here by chance.
    let below = nostr::Timestamp::from(nostr::Timestamp::now().as_secs() - 1);
    for index in 0..FLOOD {
        let forged = unopenable_at(
            &like,
            1_000_000 + u32::try_from(index).expect("small"),
            below,
        );
        assert!(
            parks(admin.session(), &forged).await,
            "premise: parked unread"
        );
        relays
            .publish_event(&forged, std::slice::from_ref(&url))
            .await
            .expect("the relay holds the outsider's event");
    }
    let commits = commits_by(peer, &group, 2).await;
    assert!(
        parks(admin.session(), &commits[1]).await,
        "premise: parked unread"
    );
    for commit in &commits {
        relays
            .publish_event(commit, std::slice::from_ref(&url))
            .await
            .expect("the relay holds the commit");
    }
    let admin = confirm_and_die(admin, pending, source + 1).await.reopen();
    hand_back_everything(&admin, &group, FLOOD + 1).await;
    assert!(
        owed(&admin, &group).len() == MAX_REFUSED_IDS_PER_GROUP
            && !owed(&admin, &group).contains(&commits[1].id)
            && admin.session().refused_range(&group).is_some()
            && epoch(&admin, &group).await == source + 1,
        "premise: the ledger is full of the outsider's ids, and the member's commit is owed \
         only as part of the circle's history",
    );

    // The commit before it arrives the ordinary way, and the epoch moves.
    assert!(matches!(
        answer(admin.session(), &commits[0]).await,
        haven_core::nostr::mls::types::IngestOutcome::Processed
            | haven_core::nostr::mls::types::IngestOutcome::Buffered { .. }
    ));
    assert_eq!(
        served_until(&admin, &group, |at| at == source + 2).await,
        source + 2,
        "premise"
    );

    let (by_id, other) = (asked.by_id(), asked.other());
    let _ = run_refused_refetch(&admin.circle, &relays, 300).await;
    assert!(
        asked.by_id() - by_id == REFETCH_REQS_PER_SWEEP && asked.other() > other,
        "the sweep after a new epoch did not ask for its whole share of ids and then for the \
         circle's history: an outsider's ids stood between the circle and its own commit",
    );
    // What that one sweep fetched is all the engine is given: it is served
    // its deadlines, and no relay is asked again.
    let (by_id, other) = (asked.by_id(), asked.other());
    let tip = epoch(peer, &group).await;
    assert_eq!(
        served_until(&admin, &group, |at| at == tip).await,
        tip,
        "a member's commit, refused for want of room and on record only as history, was not \
         fetched by the first sweep after the epoch it follows was reached",
    );
    assert!(
        asked.by_id() == by_id && asked.other() == other,
        "premise: serving the engine's deadlines asked a relay for nothing",
    );
}

/// A device with its engine's deferral store full, a commit of its own
/// stranded behind `flood` events nobody can open and then `behind` — what
/// the test parks after them — and a refused ledger the hand-back has
/// filled: returns the device reopened, with nothing handed back yet.
async fn a_full_ledger_stranded(
    flood: usize,
    relay: &str,
    behind: impl AsyncFnOnce(&CircleMember, &CircleMember, &GroupId) -> Vec<Event>,
) -> (CircleMember, CircleMember, GroupId, u64, Vec<Event>) {
    let fx = setup_circle(2, &[relay]).await;
    let (admin, mut others, group) = split(fx);
    let peer = others.remove(0);
    let like = sealed_by(&peer, &group, 0.5).await;
    fill_the_deferral_store(&admin, &group, &like).await;
    let source = epoch(&admin, &group).await;
    let (mine, pending) = stage_a_change(&admin, &peer, &group).await;
    peer.session()
        .process_event_settled_for_test(&mine)
        .await
        .expect("the circle applies this device's commit");
    for index in 0..flood {
        let forged = unopenable(&like, 2_000_000 + u32::try_from(index).expect("small"));
        assert!(
            parks(admin.session(), &forged).await,
            "premise: parked unread"
        );
    }
    let commits = behind(&admin, &peer, &group).await;
    let admin = confirm_and_die(admin, pending, source + 1).await.reopen();
    (admin, peer, group, source, commits)
}

/// Sweeps until `admin` stands on `tip`, a day apart, serving the engine
/// its deadlines after each: every sweep must bring it at least an epoch
/// nearer.
async fn swept_to(
    admin: &CircleMember,
    group: &GroupId,
    relays: &RelayManager,
    tip: u64,
    sweeps: usize,
) -> u64 {
    let mut at = epoch(admin, group).await;
    for sweep in 1..=sweeps {
        if at == tip {
            break;
        }
        a_day_later(admin, sweep);
        let _ = run_refused_refetch(&admin.circle, relays, 300).await;
        let now = served_until(admin, group, |now| now > at).await;
        assert!(
            now > at,
            "a sweep brought the device no nearer its circle's epoch: what it needs is owed \
             by nothing",
        );
        at = now;
    }
    at
}

/// A range pass ends only what the engine took (Security Rule 12).
///
/// Past the ledger's cap a refused event is on record as part of the range
/// alone, and the engine announces nothing when it refuses one at ingest.
/// Here two commits of a peer are owed that way, the device is a commit
/// short of opening either and has no room to keep them: a refetch brings
/// both back, every relay answers in full, and the engine refuses both
/// again. A pass that ended the range on the relays' word would leave the
/// two commits owed by nothing, below the cursor — the device would stop an
/// epoch behind its circle for good and go on sealing there.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_commit_the_engine_refuses_again_inside_a_range_pass_stays_owed() {
    let (_relay, url, asked) = counting_relay().await;
    let relays = RelayManager::new();
    let (admin, peer, group, source, commits) = a_full_ledger_stranded(
        MAX_REFUSED_IDS_PER_GROUP,
        &url,
        async |admin, peer, group| {
            let commits = commits_by(peer, group, 3).await;
            for commit in &commits[1..] {
                assert!(
                    parks(admin.session(), commit).await,
                    "premise: parked unread"
                );
                RelayManager::new()
                    .publish_event(commit, std::slice::from_ref(&url))
                    .await
                    .expect("the relay holds the commit");
            }
            commits
        },
    )
    .await;
    hand_back_everything(&admin, &group, MAX_REFUSED_IDS_PER_GROUP + 2).await;
    assert!(
        owed(&admin, &group).len() == MAX_REFUSED_IDS_PER_GROUP
            && commits[1..]
                .iter()
                .all(|commit| !owed(&admin, &group).contains(&commit.id))
            && admin.session().refused_range(&group).is_some()
            && epoch(&admin, &group).await == source + 1,
        "premise: the ledger is full, and the peer's last two commits are owed only as part \
         of the circle's history",
    );

    // One refetch before the commit they follow has arrived.
    let other = asked.other();
    let _ = run_refused_refetch(&admin.circle, &relays, 300).await;
    assert!(
        asked.other() > other && epoch(&admin, &group).await == source + 1,
        "premise: the range was asked for, and the engine could open neither commit",
    );
    assert!(
        admin.session().refused_range(&group).is_some(),
        "a range pass every relay answered in full ended the range, though the engine had \
         taken nothing of two commits it brought back: they are owed by nothing",
    );

    // The commit before them arrives the ordinary way; the range brings the
    // other two.
    assert!(matches!(
        answer(admin.session(), &commits[0]).await,
        haven_core::nostr::mls::types::IngestOutcome::Processed
            | haven_core::nostr::mls::types::IngestOutcome::Buffered { .. }
    ));
    assert_eq!(
        served_until(&admin, &group, |at| at == source + 2).await,
        source + 2,
        "premise"
    );
    let tip = epoch(&peer, &group).await;
    assert_eq!(
        swept_to(&admin, &group, &relays, tip, 3).await,
        tip,
        "the device did not reach its circle's epoch",
    );
}

/// The same, when the engine was never asked: the circle still holds more
/// stranded input than one call hands back, so the pass's first ingest is
/// answered held by the hand-back and the event it carried goes nowhere.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_range_pass_the_hand_back_held_ends_nothing() {
    const LEFT: usize = HAND_BACK_WHOLE + 44;
    let (_relay, url, _asked) = counting_relay().await;
    let relays = RelayManager::new();
    // Five calls' worth: the ledger's fill, the peer's commit, and what
    // makes the fifth call's room up; then more than a call hands back.
    let (admin, peer, group, source, commits) = a_full_ledger_stranded(
        MAX_REFUSED_IDS_PER_GROUP,
        &url,
        async |admin, peer, group| {
            let commits = commits_by(peer, group, 2).await;
            assert!(
                parks(admin.session(), &commits[1]).await,
                "premise: parked unread"
            );
            RelayManager::new()
                .publish_event(&commits[1], std::slice::from_ref(&url))
                .await
                .expect("the relay holds the commit");
            let like = sealed_by(peer, group, 0.25).await;
            for index in 0..HAND_BACK_WHOLE - 1 + LEFT {
                let forged = unopenable(&like, 3_000_000 + u32::try_from(index).expect("small"));
                assert!(
                    parks(admin.session(), &forged).await,
                    "premise: parked unread"
                );
            }
            commits
        },
    )
    .await;
    for _ in 0..(MAX_REFUSED_IDS_PER_GROUP + HAND_BACK_WHOLE) / HAND_BACK_WHOLE {
        let _ = admin.session().advance_for_receive(&group).await;
    }
    assert!(
        unopened_retryable(&held(admin.session(), &group).await) == LEFT
            && !owed(&admin, &group).contains(&commits[1].id)
            && admin.session().refused_range(&group).is_some()
            && epoch(&admin, &group).await == source + 1,
        "premise: the peer's commit is owed only as part of the circle's history, and more \
         than one call hands back is still stranded",
    );

    // The refetch makes no commit, so its call hands back a slice.
    let _ = run_refused_refetch(&admin.circle, &relays, 300).await;
    assert!(
        unopened_retryable(&held(admin.session(), &group).await) == LEFT - HAND_BACK_SLICE,
        "premise: the pass's ingest was answered held by the hand-back",
    );
    assert!(
        admin.session().refused_range(&group).is_some(),
        "a range pass ended the range over a commit the engine was never asked about",
    );

    hand_back_everything(&admin, &group, LEFT).await;
    assert!(matches!(
        answer(admin.session(), &commits[0]).await,
        haven_core::nostr::mls::types::IngestOutcome::Processed
            | haven_core::nostr::mls::types::IngestOutcome::Buffered { .. }
    ));
    assert_eq!(
        served_until(&admin, &group, |at| at == source + 2).await,
        source + 2,
        "premise"
    );
    let tip = epoch(&peer, &group).await;
    assert_eq!(
        swept_to(&admin, &group, &relays, tip, 2).await,
        tip,
        "the device did not reach its circle's epoch",
    );
}

/// Sets `member`'s clock `secs` seconds past the real one.
fn ahead_by(member: &CircleMember, secs: u64) {
    let now = u64::try_from(chrono::Utc::now().timestamp_millis()).expect("after 1970");
    member
        .session()
        .set_legacy_clock_for_test(now + secs * 1_000);
}

/// A second fuller than a relay's page cannot pin the walk of a circle's
/// history above a genuine event (Security Rule 12).
///
/// Anyone who reads a circle's public routing tag can date a page's worth
/// of events in one second just above a member's commit — whose
/// `created_at` the relay shows them. No `until` reaches past that page:
/// NIP-01's grain is a second. A walk that stopped there would never fetch
/// the commit owed below it, and the device would go on sealing for an
/// epoch the member may have removed somebody from.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_pile_up_dated_in_one_second_cannot_keep_a_commit_below_it_from_being_fetched() {
    const PILE: usize = CATCHUP_MAX_EVENTS_PER_PAGE + 1;
    let (_relay, url, _asked) = counting_relay().await;
    let relays = RelayManager::new();
    let (admin, peer, group, source, commits) = a_full_ledger_stranded(
        MAX_REFUSED_IDS_PER_GROUP,
        &url,
        async |admin, peer, group| {
            let commits = commits_by(peer, group, 2).await;
            assert!(
                parks(admin.session(), &commits[1]).await,
                "premise: parked unread"
            );
            let publisher = RelayManager::new();
            publisher
                .publish_event(&commits[1], std::slice::from_ref(&url))
                .await
                .expect("the relay holds the commit");
            let above = nostr::Timestamp::from(commits[1].created_at.as_secs() + 1);
            for index in 0..PILE {
                let content = base64::engine::general_purpose::STANDARD.encode(
                    u32::try_from(index)
                        .expect("small")
                        .to_be_bytes()
                        .repeat(24),
                );
                let piled = nostr::EventBuilder::new(commits[1].kind, content)
                    .tags(commits[1].tags.iter().cloned())
                    .custom_created_at(above)
                    .sign_with_keys(&nostr::Keys::generate())
                    .expect("sign");
                publisher
                    .publish_event(&piled, std::slice::from_ref(&url))
                    .await
                    .expect("the relay holds the outsider's event");
            }
            commits
        },
    )
    .await;
    // The range's ceiling is the instant it is recorded: a minute on, so
    // the pile-up stands inside the walk.
    ahead_by(&admin, 60);
    hand_back_everything(&admin, &group, MAX_REFUSED_IDS_PER_GROUP + 1).await;
    assert!(
        !owed(&admin, &group).contains(&commits[1].id)
            && admin.session().refused_range(&group).is_some(),
        "premise: the member's commit is owed only as part of the circle's history",
    );
    assert!(matches!(
        answer(admin.session(), &commits[0]).await,
        haven_core::nostr::mls::types::IngestOutcome::Processed
            | haven_core::nostr::mls::types::IngestOutcome::Buffered { .. }
    ));
    assert_eq!(
        served_until(&admin, &group, |at| at == source + 2).await,
        source + 2,
        "premise"
    );

    for day in 1..=3 {
        a_day_later(&admin, day);
        let _ = run_refused_refetch(&admin.circle, &relays, 300).await;
    }
    let tip = epoch(&peer, &group).await;
    assert_eq!(
        served_until(&admin, &group, |at| at == tip).await,
        tip,
        "a page of events dated in one second above a member's commit kept the walk of the \
         circle's history from ever reaching it",
    );
}

/// An event the engine recorded and then erred on is the engine's: a range
/// pass that brought it back is not owed again for it. A former member can
/// mint one such message and date it anywhere; a walk that counted it as
/// owed would re-walk the circle's whole history once a wait, for ever.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_event_the_engine_recorded_and_then_erred_on_keeps_no_range_owed() {
    let (_relay, url, _asked) = counting_relay().await;
    let relays = RelayManager::new();
    let (admin, _peer, group, source, fixes) = a_full_ledger_stranded(
        MAX_REFUSED_IDS_PER_GROUP + 1,
        &url,
        async |_admin, peer, group| {
            let fix = sealed_by(peer, group, 0.75).await;
            RelayManager::new()
                .publish_event(&fix, std::slice::from_ref(&url))
                .await
                .expect("the relay holds the fix");
            vec![fix]
        },
    )
    .await;
    ahead_by(&admin, 60);
    hand_back_everything(&admin, &group, MAX_REFUSED_IDS_PER_GROUP + 1).await;
    assert!(
        admin.session().refused_range(&group).is_some()
            && epoch(&admin, &group).await == source + 1,
        "premise: past the ledger's cap the circle's history is owed",
    );

    admin.session().fail_next_ingest_for_test();
    let _ = run_refused_refetch(&admin.circle, &relays, 300).await;
    assert!(
        !admin.session().ingest_fault_armed_for_test()
            && admin.session().engine_processed(&fixes[0].id),
        "premise: the range pass brought the fix back, and the engine recorded it before its \
         ingest erred",
    );
    assert!(
        admin.session().refused_range(&group).is_none(),
        "a range pass every relay answered in full kept the range owed for an event the \
         engine had recorded",
    );
}
