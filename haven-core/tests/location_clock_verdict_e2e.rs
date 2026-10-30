//! The device-clock verdict and the location path (tracker `T-CLOCK-SKEW`).
//!
//! A relay that refuses an event for its timestamp says so in words. MDK's
//! relay client, which a commit's fanout is sent through, keeps a category
//! and drops the words, so a commit refused for the device's clock is an
//! ordinary proven refusal. Haven's own transport, which a location is sent
//! through, keeps them and reads the verdict from them.
//!
//! Real engines, Haven's real publish pool and transports, and a loopback
//! relay scripted to refuse every event for its timestamp.

#![allow(clippy::unwrap_used, clippy::expect_used)]

mod helpers;

use haven_core::location::LocationMessage;
use haven_core::relay::fanout::{
    DriveMode, EvolutionStatus, LocationPublish, LocationSeal, Publishing, SendHeld,
};
use haven_core::relay::scripted_relay::{ScriptedRelay, Verdict};
use haven_core::relay::{RelayError, RelayManager};
use helpers::drive::{
    leave_of, make_a_departure_due, roster, staged_ref, wait_out_the_engine, ManualClock, Recorder,
    MINUTE_MS,
};
use helpers::setup_circle;
use helpers::stranded::split;

/// What a relay answers an event dated too far from its own clock.
const RELAY_TEXT: &str = "invalid: event creation date is too far off from the current time";
const FULL: DriveMode = DriveMode::Full;

fn fix() -> LocationMessage {
    LocationMessage::new(51.5, -0.12)
}

/// A relay that refuses every event as one whose timestamp is wrong.
fn a_relay_that_blames_the_clock() -> ScriptedRelay {
    assert!(
        haven_core::relay::classify_relay_rejection(RELAY_TEXT).is_some(),
        "premise: the relay's text is one Haven's clock classifier knows",
    );
    let relay = ScriptedRelay::start();
    relay.on_publish(|_| Verdict::Refuse(RELAY_TEXT.to_string()));
    relay
}

/// With the device's clock wrong, a change of the circle is refused by its
/// relay and undone — the commit's transport says "refused" and nothing of
/// why — and the next location, sealed and sent to the same relay, is
/// answered with the device-clock verdict, unchanged, by the driver's own
/// location send.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_skewed_clock_still_raises_the_device_clock_verdict_through_the_location_send_when_commits_are_rejected(
) {
    let relay = a_relay_that_blames_the_clock();
    let fx = setup_circle(3, &[relay.url()]).await;
    let (admin, others, group) = split(fx);
    let pool = RelayManager::new();
    let transport = pool.fanout_transport();
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = Publishing {
        fanout: &transport,
        publisher: &outbox,
        clock: &*clock,
        deadline_ms: None,
        mode: &FULL,
    };

    let removed = driver
        .remove_members(&admin.circle, &group, &[others[1].pubkey_hex()])
        .await
        .expect("the removal is accepted");
    assert!(
        removed.status == EvolutionStatus::RolledBack
            && staged_ref(&admin, &group).await.is_none()
            && roster(&admin, &group)
                .await
                .contains(&others[1].pubkey_hex()),
        "premise: the relay refused the commit for its timestamp, and it was undone",
    );
    let refused = relay.offers();
    assert!(refused > 0, "premise: the commit reached the relay");

    let sealed = driver
        .seal_location(&admin.circle, &group, &fix())
        .await
        .expect("the seal runs");
    let LocationSeal::Sealed { event, .. } = sealed.seal else {
        panic!("premise: with the commit undone the circle's next location is sealed");
    };
    let sent = driver.publish_location(&admin.circle, &event).await;
    assert!(
        relay.offers() == refused + 1,
        "premise: the location was offered to the relay once",
    );
    assert!(
        matches!(
            sent,
            LocationPublish::Sent(Err(RelayError::DeviceClockRejected { .. }))
        ),
        "the location's send did not come back with the device-clock verdict: the user is \
         told sharing failed and never that the clock is why",
    );
}

/// The corner `D-Q17` asked about, measured: a member has left and the
/// device owes the circle their removal, with its clock wrong.
///
/// The removal is made, refused by the relay and undone, and from that
/// refusal until the removal lands nothing is sealed for the circle: the
/// member who left is still in it, and a location sealed now is one they
/// could read. So no location is offered to a relay, no relay's words are
/// read, and the clock is not named — inside the wait the refusal earned,
/// after it, and when the engine's own deadline makes the removal again and
/// every relay refuses that too. While every relay refuses the removal, the
/// circle sends nothing (tracker T-OQA, T-CLOCK-SKEW).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_circle_that_owes_a_removal_under_a_skewed_clock_seals_nothing_while_every_relay_refuses_it(
) {
    let relay = a_relay_that_blames_the_clock();
    let fx = setup_circle(3, &[relay.url()]).await;
    let leave = leave_of(&fx, 1).await;
    let (admin, others, group) = split(fx);
    make_a_departure_due(&admin, &others[1], &group, &leave).await;
    let pool = RelayManager::new();
    let transport = pool.fanout_transport();
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = Publishing {
        fanout: &transport,
        publisher: &outbox,
        clock: &*clock,
        deadline_ms: None,
        mode: &FULL,
    };
    let unrecorded = || async {
        admin
            .session()
            .location_records_for_test(&group)
            .await
            .expect("the store is read")
            .is_empty()
    };

    // The first send makes the removal; the relay refuses it; it is undone.
    let first = driver
        .seal_location(&admin.circle, &group, &fix())
        .await
        .expect("the send is answered");
    let offered = relay.offers();
    assert!(
        offered > 0
            && staged_ref(&admin, &group).await.is_none()
            && roster(&admin, &group)
                .await
                .contains(&others[0].pubkey_hex()),
        "premise: the removal was sent, refused for its timestamp and undone",
    );
    assert!(
        matches!(first.seal, LocationSeal::Deferred(SendHeld::DepartureDue)) && unrecorded().await,
        "a location was sealed or recorded by the send that made the removal",
    );

    // Inside the wait: the same answer, nothing sealed, no relay asked.
    clock.set(MINUTE_MS / 2);
    let inside = driver
        .seal_location(&admin.circle, &group, &fix())
        .await
        .expect("the send is answered");
    assert!(
        matches!(inside.seal, LocationSeal::Deferred(SendHeld::DepartureDue))
            && unrecorded().await
            && relay.offers() == offered,
        "inside the wait a refused removal earned, a location was sealed, or a relay asked",
    );

    // After it. MDK re-armed the removal 10–50 ms of monotonic time after the
    // refusal, so this send finds its deadline still ahead (held, no relay
    // asked) or reached (the removal made again and refused again): either
    // way nothing is sealed or recorded, and the member who left is listed.
    clock.set(2 * MINUTE_MS);
    let after = driver
        .seal_location(&admin.circle, &group, &fix())
        .await
        .expect("the send is answered");
    assert!(
        matches!(after.seal, LocationSeal::Deferred(_))
            && unrecorded().await
            && roster(&admin, &group)
                .await
                .contains(&others[0].pubkey_hex()),
        "after the wait, with the departed member still in the circle, a location was \
         sealed or recorded",
    );

    // At the engine's own deadline the send makes the removal again; the
    // relay refuses it for the clock, it is undone, and still nothing is
    // sealed.
    wait_out_the_engine(&admin, &group).await;
    let again = driver
        .seal_location(&admin.circle, &group, &fix())
        .await
        .expect("the send is answered");
    assert!(
        relay.offers() > offered
            && staged_ref(&admin, &group).await.is_none()
            && roster(&admin, &group)
                .await
                .contains(&others[0].pubkey_hex()),
        "premise: the removal was made again, refused for its timestamp and undone",
    );
    assert!(
        matches!(again.seal, LocationSeal::Deferred(SendHeld::DepartureDue)) && unrecorded().await,
        "a location was sealed or recorded beside a removal every relay refuses",
    );
}
