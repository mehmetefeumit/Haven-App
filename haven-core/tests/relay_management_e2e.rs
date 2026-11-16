//! The own-relay board over real sockets: what a maintenance pass shows for
//! each relay and kind, in the order it learns it, for every answer a relay
//! can give.
//!
//! Each scenario drives the board's pass the way the two maintenance passes
//! do — begin, the per-relay probe, judge, offer — against scripted relays.
//! The passes' own orchestration (holds, triggers, the lock, what is sent
//! where) is proved through the FFI in `haven/rust_builder`. No test waits on
//! time: a relay's answer is released by a switch the test opens, and only an
//! answer that never comes is bounded, by a deadline nothing can beat.

mod helpers;

use std::time::Duration;

use haven_core::relay::maintenance::{
    names_configured_list, probe_verdict, OfferMode, OwnCell, OwnKind, OwnPass, OwnRelayBoard,
    Probed,
};
use haven_core::relay::scripted_relay::{Frame, ScriptedRelay, Verdict};
use haven_core::relay::{DeviceClockComplaint, RelayManager, OFFER_ACK_TIMEOUT};
use helpers::{assert_no_needles, assert_some_line_from, capture_haven_log_here, haven_core_lines};
use nostr::nips::nip19::ToBech32 as _;
use nostr::{Event, EventBuilder, Filter, JsonUtil as _, Keys, Kind, Tag};
use OwnCell::{Checking, Current, Missing, NoAnswer, Outdated, Publishing, Refused, Unconfirmed};

/// Bounds the wait for an `OK` only where none can come.
const NEVER: Duration = Duration::from_millis(300);

/// `keys`' inbox relay list naming `relays`, signed now.
fn inbox_list(keys: &Keys, relays: &[String]) -> Event {
    let tags = relays
        .iter()
        .map(|url| Tag::parse(["relay", url]).expect("a relay tag"));
    EventBuilder::new(Kind::InboxRelays, "")
        .tags(tags)
        .sign_with_keys(keys)
        .expect("a locally built event signs")
}

fn urls(relays: &[&ScriptedRelay]) -> Vec<String> {
    relays.iter().map(|relay| relay.url().to_owned()).collect()
}

/// The inbox relay-list pass's probe and judge, written to `pass`.
async fn probe(pass: &mut OwnPass<'_>, manager: &RelayManager, own: &Keys, configured: &[String]) {
    let answers = manager
        .fetch_events_per_relay(
            Filter::new()
                .kind(Kind::InboxRelays)
                .author(own.public_key())
                .limit(4),
            configured,
        )
        .await
        .expect("the per-relay read never fails as a whole");
    pass.judge(&answers, |answer| {
        probe_verdict(answer, &own.public_key(), Kind::InboxRelays, &|mine| {
            names_configured_list(mine, configured)
        })
    });
}

fn inbox_cells(board: &OwnRelayBoard) -> Vec<(String, OwnCell)> {
    board
        .snapshot()
        .inbox_relay_list
        .cells
        .into_iter()
        .map(|cell| (cell.relay_url, cell.status))
        .collect()
}

/// Yields until the board's inbox cells read `want`: a condition, never a
/// time.
async fn until(board: &OwnRelayBoard, want: &[(String, OwnCell)]) {
    while inbox_cells(board) != want {
        tokio::task::yield_now().await;
    }
}

/// A cell turns as its own relay answers: one relay's `OK` paints it current
/// while another's cell, sent the same event and holding it already, reads
/// publishing until that relay's `OK` comes. The order is checking, judged,
/// publishing, settled, and nothing sent to the relay that served it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_cell_waits_for_its_own_relays_ok_after_checking_and_judging() {
    let own = Keys::generate();
    let (served, prompt, held) = (
        ScriptedRelay::start(),
        ScriptedRelay::start(),
        ScriptedRelay::start(),
    );
    let configured = urls(&[&served, &prompt, &held]);
    let current = inbox_list(&own, &configured);
    served.answer(|_| true, vec![Frame::Event(current.clone()), Frame::Eose]);
    let (release, released) = tokio::sync::watch::channel(false);
    held.on_publish(move |_| Verdict::HoldThen(released.clone(), Box::new(Verdict::Keep)));
    let manager = RelayManager::new();
    let board = OwnRelayBoard::default();
    let [a, b, c] = [0, 1, 2].map(|i| configured[i].clone());

    let mut pass = board.begin(OwnKind::InboxRelayList, &configured);
    assert_eq!(
        inbox_cells(&board),
        [
            (a.clone(), Checking),
            (b.clone(), Checking),
            (c.clone(), Checking)
        ]
    );
    probe(&mut pass, &manager, &own, &configured).await;
    assert_eq!(
        inbox_cells(&board),
        [
            (a.clone(), Current),
            (b.clone(), Missing),
            (c.clone(), Missing)
        ]
    );

    let targets = [b.clone(), c.clone()];
    let offer = pass.offer(
        &manager,
        &current,
        &targets,
        OfferMode::Heal,
        OFFER_ACK_TIMEOUT,
    );
    let watch = async {
        while !held.published().iter().any(|event| event.id == current.id) {
            tokio::task::yield_now().await;
        }
        until(
            &board,
            &[
                (a.clone(), Current),
                (b.clone(), Current),
                (c.clone(), Publishing),
            ],
        )
        .await;
        // The held relay has had the event a while: only its OK is missing.
        release.send(true).expect("the relay listens");
    };
    let (offered, ()) = tokio::join!(offer, watch);
    drop(pass);

    assert_eq!(
        inbox_cells(&board),
        [(a, Current), (b, Current), (c, Current)]
    );
    assert_eq!(offered.accepted, targets);
    assert_eq!(
        served.offers(),
        0,
        "a relay that serves the list is sent nothing"
    );
}

/// What a scripted relay does with the event a pass offers it.
#[derive(Clone, Copy, Debug)]
enum Answer {
    Keep,
    Duplicate,
    Refuse(&'static str),
    Silence,
    HangUp,
}

impl Answer {
    fn verdict(self) -> Verdict {
        match self {
            Self::Keep => Verdict::Keep,
            Self::Duplicate => Verdict::KeepSaying("duplicate: already have it".into()),
            Self::Refuse(text) => Verdict::Refuse(text.into()),
            Self::Silence => Verdict::KeepSilently,
            Self::HangUp => Verdict::HangUp,
        }
    }
}

/// Every answer a relay can give, from every verdict the probe can reach:
/// only an `OK true` reads current, only an `OK false` reads refused, and a
/// relay that never answered keeps what the probe proved.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn every_answer_settles_its_cell_by_what_the_probe_proved() {
    let own = Keys::generate();
    let manager = RelayManager::new();
    let event = inbox_list(&own, &["wss://inbox.example.com".to_owned()]);
    let mut cases = vec![
        (Answer::Keep, Probed::Missing, Current),
        (Answer::Keep, Probed::Outdated, Current),
        (Answer::Keep, Probed::NoAnswer, Current),
        (Answer::Duplicate, Probed::Outdated, Current),
        (Answer::Silence, Probed::Missing, Unconfirmed),
        (Answer::Silence, Probed::Outdated, Unconfirmed),
        (Answer::Silence, Probed::NoAnswer, NoAnswer),
        (Answer::HangUp, Probed::Missing, Unconfirmed),
        (Answer::HangUp, Probed::NoAnswer, NoAnswer),
    ];
    for prefix in [
        "blocked: not here",
        "restricted: members only",
        "auth-required: sign in",
        "invalid: bad event",
        "pow: difficulty 30 required",
        "rate-limited: slow down",
        "error: could not store",
    ] {
        cases.push((Answer::Refuse(prefix), Probed::Missing, Refused));
        cases.push((Answer::Refuse(prefix), Probed::NoAnswer, Refused));
    }

    for (case, probed, expected) in cases {
        let relay = ScriptedRelay::start();
        relay.on_publish(move |_| case.verdict());
        let board = OwnRelayBoard::default();
        let target = [relay.url().to_owned()];
        let mut pass = board.begin(OwnKind::InboxRelayList, &target);
        pass.judge(&[relay_answer(relay.url())], |_| probed);
        let offered = pass
            .offer(&manager, &event, &target, OfferMode::Heal, NEVER)
            .await;
        drop(pass);
        assert_eq!(
            inbox_cells(&board),
            [(target[0].clone(), expected)],
            "{case:?} after {probed:?}"
        );
        assert_eq!(offered.accepted.is_empty(), expected != Current, "{case:?}");
        assert_eq!(
            relay.offers(),
            1,
            "{case:?}: offered once, never again in the pass"
        );
    }

    // A relay that refuses the connection never answered the event.
    let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind");
    let dead = [format!(
        "ws://127.0.0.1:{}",
        listener.local_addr().expect("addr").port()
    )];
    drop(listener);
    let board = OwnRelayBoard::default();
    let mut pass = board.begin(OwnKind::InboxRelayList, &dead);
    pass.judge(&[relay_answer(&dead[0])], |_| Probed::Missing);
    pass.offer(&manager, &event, &dead, OfferMode::Heal, NEVER)
        .await;
    drop(pass);
    assert_eq!(inbox_cells(&board), [(dead[0].clone(), Unconfirmed)]);
}

fn relay_answer(relay_url: &str) -> haven_core::relay::RelayFetchOutcome {
    haven_core::relay::RelayFetchOutcome {
        relay_url: relay_url.to_owned(),
        responded: true,
        drained: true,
        events: Vec::new(),
    }
}

/// A replacement: a relay that served the package it replaces reads
/// publishing until the pass knows whether it replaced it, and then never
/// current without an `OK`. A relay proven not to serve it settles at once.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_replacement_settles_what_turns_on_the_promotion_only_after_it() {
    let own = Keys::generate();
    let manager = RelayManager::new();
    let event = inbox_list(&own, &["wss://inbox.example.com".to_owned()]);
    for superseded in [true, false] {
        let (serving, lacking) = (ScriptedRelay::start(), ScriptedRelay::start());
        serving.on_publish(|_| Verdict::KeepSilently);
        lacking.on_publish(|_| Verdict::Refuse("blocked: no".into()));
        let targets = urls(&[&serving, &lacking]);
        let board = OwnRelayBoard::default();
        let mut pass = board.begin(OwnKind::KeyPackage, &targets);
        pass.judge(
            &[relay_answer(&targets[0]), relay_answer(&targets[1])],
            |answer| {
                if answer.relay_url == targets[0] {
                    Probed::Current
                } else {
                    Probed::Missing
                }
            },
        );
        let offered = pass
            .offer(&manager, &event, &targets, OfferMode::Mint, NEVER)
            .await;
        assert!(offered.accepted.is_empty());
        let cells = |board: &OwnRelayBoard| {
            board
                .snapshot()
                .key_package
                .cells
                .into_iter()
                .map(|cell| cell.status)
                .collect::<Vec<_>>()
        };
        assert_eq!(cells(&board), [Publishing, Refused]);
        pass.settle_rest(superseded);
        assert_eq!(
            cells(&board),
            [if superseded { Unconfirmed } else { Current }, Refused],
            "superseded={superseded}"
        );
        drop(pass);
    }
}

/// A pass dropped while a relay's `OK` is outstanding paints nothing current:
/// the cell is settled as if replaced, and nothing is left publishing.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_pass_dropped_mid_offer_leaves_nothing_checking_or_publishing() {
    let own = Keys::generate();
    let manager = RelayManager::new();
    let (held, unprobed) = (ScriptedRelay::start(), ScriptedRelay::start());
    let (_release, released) = tokio::sync::watch::channel(false);
    held.on_publish(move |_| Verdict::HoldThen(released.clone(), Box::new(Verdict::Keep)));
    let targets = urls(&[&held, &unprobed]);
    let event = inbox_list(&own, &targets);
    let board = OwnRelayBoard::default();
    {
        let mut pass = board.begin(OwnKind::KeyPackage, &targets);
        pass.judge(&[relay_answer(&targets[0])], |_| Probed::Current);
        let offer = pass.offer(
            &manager,
            &event,
            &targets[..1],
            OfferMode::Mint,
            OFFER_ACK_TIMEOUT,
        );
        tokio::pin!(offer);
        while board.snapshot().key_package.cells[0].status != Publishing || held.offers() == 0 {
            tokio::select! {
                biased;
                _ = &mut offer => panic!("the relay's OK is held"),
                () = tokio::task::yield_now() => {}
            }
        }
    }
    let after = board.snapshot().key_package;
    assert_eq!(
        after
            .cells
            .iter()
            .map(|cell| (cell.relay_url.as_str(), cell.status))
            .collect::<Vec<_>>(),
        [(targets[0].as_str(), Unconfirmed)],
        "the unprobed relay is forgotten and the held one is never current",
    );
    assert!(after.checked_secs_ago.is_some());
}

/// A refusal that blames this device's clock is reported when no relay
/// accepted, as a ladder publish reports it; one acceptance clears it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_clock_refusal_is_reported_only_when_no_relay_accepted() {
    let own = Keys::generate();
    let manager = RelayManager::new();
    let event = inbox_list(&own, &["wss://inbox.example.com".to_owned()]);
    let (clock, keeping) = (ScriptedRelay::start(), ScriptedRelay::start());
    clock.on_publish(|_| {
        Verdict::Refuse("invalid: event creation date is too far off from the current time".into())
    });
    for (relays, expected) in [
        (vec![&clock], Some(DeviceClockComplaint::Unspecified)),
        (vec![&clock, &keeping], None),
    ] {
        let targets = urls(&relays);
        let board = OwnRelayBoard::default();
        let mut pass = board.begin(OwnKind::KeyPackage, &targets);
        let offered = pass
            .offer(&manager, &event, &targets, OfferMode::Mint, NEVER)
            .await;
        assert_eq!(offered.clock, expected, "{} relay(s)", targets.len());
        assert_eq!(board.snapshot().key_package.cells[0].status, Refused);
    }
}

/// What a heal sent is what the relay then serves: the next pass reads it
/// current and sends that relay nothing more — the very bytes, kept once.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_healed_relay_reads_current_at_the_next_pass_and_is_sent_nothing() {
    let own = Keys::generate();
    let relay = ScriptedRelay::start();
    relay.serve_kept();
    let manager = RelayManager::new();
    let configured = urls(&[&relay]);
    let list = inbox_list(&own, &configured);
    let board = OwnRelayBoard::default();
    // Two passes, each as the relay-list pass runs one.
    for pass_number in 0..2 {
        let mut pass = board.begin(OwnKind::InboxRelayList, &configured);
        probe(&mut pass, &manager, &own, &configured).await;
        let judged = inbox_cells(&board);
        let lacking: Vec<String> = judged
            .iter()
            .filter(|(_, status)| *status != Current)
            .map(|(url, _)| url.clone())
            .collect();
        assert_eq!(
            judged[0].1,
            if pass_number == 0 { Missing } else { Current },
            "pass {pass_number}"
        );
        pass.offer(
            &manager,
            &list,
            &lacking,
            OfferMode::Heal,
            OFFER_ACK_TIMEOUT,
        )
        .await;
        drop(pass);
        assert_eq!(inbox_cells(&board), [(configured[0].clone(), Current)]);
    }
    assert_eq!(
        relay.offers(),
        1,
        "the second pass sent the healthy relay nothing"
    );
    assert_eq!(
        relay
            .published()
            .iter()
            .map(Event::as_json)
            .collect::<Vec<_>>(),
        [list.as_json()],
        "the relay keeps the very event the pass sent",
    );
}

/// A pass names neither a relay, nor this account, nor what a relay said, in
/// any log line; and the board's own rendering names no relay (Rule 15).
#[tokio::test(flavor = "current_thread")]
async fn a_pass_logs_no_relay_no_account_and_no_relay_prose() {
    let own = Keys::generate();
    let npub = own.public_key().to_bech32().expect("an npub");
    let (outdated, refusing) = (ScriptedRelay::start(), ScriptedRelay::start());
    let configured = urls(&[&outdated, &refusing]);
    outdated.answer(
        |_| true,
        vec![
            Frame::Event(inbox_list(&own, &["wss://old.example.com".to_owned()])),
            Frame::Eose,
        ],
    );
    let said = format!("blocked: {npub} is not welcome");
    refusing.on_publish(move |_| Verdict::Refuse(said.clone()));
    let list = inbox_list(&own, &configured);
    let manager = RelayManager::new();
    let board = OwnRelayBoard::default();

    let lines = capture_haven_log_here(async {
        let mut pass = board.begin(OwnKind::InboxRelayList, &configured);
        probe(&mut pass, &manager, &own, &configured).await;
        assert_eq!(
            inbox_cells(&board)
                .iter()
                .map(|(_, s)| *s)
                .collect::<Vec<_>>(),
            [Outdated, Missing]
        );
        pass.offer(
            &manager,
            &list,
            &configured,
            OfferMode::Heal,
            OFFER_ACK_TIMEOUT,
        )
        .await;
    })
    .await;
    assert_eq!(
        inbox_cells(&board)
            .iter()
            .map(|(_, s)| *s)
            .collect::<Vec<_>>(),
        [Current, Refused]
    );
    assert_some_line_from(&lines, "haven_core");
    let ports: Vec<String> = configured
        .iter()
        .map(|url| url.trim_start_matches("ws://").to_owned())
        .collect();
    let hex = own.public_key().to_hex();
    let mut needles: Vec<&str> = ports.iter().map(String::as_str).collect();
    needles.extend([npub.as_str(), hex.as_str(), "not welcome"]);
    assert_no_needles(&haven_core_lines(&lines), &needles);
    let rendered = format!("{:?}", board.snapshot());
    for needle in &ports {
        assert!(
            !rendered.contains(needle.as_str()),
            "the board renders a relay: {rendered}"
        );
    }
}
