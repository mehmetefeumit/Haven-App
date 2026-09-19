//! `HAVEN_TEST_WAIT_SCALE`, and the windows it may never touch.
//!
//! # Why this is a test binary of its own
//!
//! The scale is process-wide by design — a scale that moved mid-run would make
//! two arms of one run answer to different budgets — so installing one poisons
//! every other bound assertion in the same process. `cargo test` gives each
//! integration target its own process, which is the only way to assert the
//! installed behaviour without weakening the default-scale assertions that live
//! in the library's own tests.

use std::time::Duration;

use haven_soak::oracle::bounds::{self, WaitScale};
use haven_soak::oracle::Recovery;
use haven_soak::scenarios::Absence;

/// A tick period; the stability term of a quiescence bound is counted in these.
const TICK: Duration = Duration::from_millis(250);

/// The scale this file installs.
const SCALE: u32 = 2;

#[test]
fn a_scale_stretches_a_delivery_budget_and_leaves_every_absence_window_alone() {
    // Read BEFORE the install, so the comparison is against this machine's own
    // unscaled values rather than against numbers written here.
    let round_trip = bounds::round_trip(Recovery::Undisturbed);
    let reconnect = bounds::round_trip(Recovery::Reconnect);
    let quiescence = bounds::quiescence(Recovery::Reconnect, TICK);
    let floor = bounds::throttled_backoff_floor();
    let silence = bounds::silence_window();
    let settle = bounds::settle();
    let backoff = bounds::throttled_backoff();
    let ladder = bounds::subscribe_ladder();
    let reconnect_term = bounds::pool_reconnect();
    let backlog = bounds::burst_backlog_wait();
    let horizon = bounds::unresolvable_input_max_age();
    let withheld = bounds::withheld_publish_ladder();
    let throttled_absence = Absence::ThrottledBackoffFloor.window();
    let silence_absence = Absence::DeliverySilenceWindow.window();

    assert!(
        bounds::wait_scale() == WaitScale::ONE,
        "a process starts unscaled, so a local run and a lane derive the same bounds"
    );
    bounds::install_wait_scale(WaitScale::new(SCALE).expect("a whole scale"));
    assert!(
        bounds::wait_scale().factor() == SCALE,
        "the installed scale is what every delivery budget is paid at"
    );

    // The delivery side stretches, exactly and only by the factor.
    assert!(
        bounds::round_trip(Recovery::Undisturbed) == round_trip * SCALE,
        "a round trip is a transition budget: a larger one can only remove a false negative"
    );
    assert!(
        bounds::round_trip(Recovery::Reconnect) == reconnect * SCALE,
        "and so is the same budget for a world coming out of a reconnect"
    );
    assert!(
        bounds::quiescence(Recovery::Reconnect, TICK) == quiescence + reconnect,
        "quiescence stretches by exactly its round-trip term, never by its stability window"
    );

    // Everything an absence is measured against is untouched.
    assert!(
        bounds::throttled_backoff_floor() == floor,
        "the backoff floor is the earliest a throttled REQ may be re-issued: scaling it would \
         assert an absence the product never promised"
    );
    assert!(
        bounds::silence_window() == silence,
        "the delivery-silence window is the same: its expiry is the success path"
    );
    assert!(
        Absence::ThrottledBackoffFloor.window() == throttled_absence,
        "and an arm's absence window reads the unscaled term"
    );
    assert!(
        Absence::DeliverySilenceWindow.window() == silence_absence,
        "both of them"
    );

    // Every leaf stays where it was: the scale is applied at one composite, so
    // a leaf that moved would mean it had leaked.
    assert!(bounds::settle() == settle, "the settle window is a leaf");
    assert!(
        bounds::throttled_backoff() == backoff,
        "the backoff ceiling is a leaf"
    );
    assert!(
        bounds::subscribe_ladder() == ladder,
        "the subscribe ladder is a leaf"
    );
    assert!(
        bounds::pool_reconnect() == reconnect_term,
        "the pool's reconnect ladder is a leaf"
    );
    assert!(
        bounds::burst_backlog_wait() == backlog,
        "the backlog wait is a leaf"
    );
    assert!(
        bounds::unresolvable_input_max_age() == horizon,
        "the sweep horizon is a leaf"
    );
    assert!(
        bounds::withheld_publish_ladder() == withheld,
        "the withheld-publish ladder is a leaf"
    );

    // And the re-derivation cases still hold under a scale, which is what says
    // the scale did not reach any of them.
    assert!(
        bounds::self_check().is_ok(),
        "every bound still re-derives from its source constant with a scale installed"
    );
}

#[test]
fn a_scale_below_one_is_refused_rather_than_clamped() {
    assert!(
        WaitScale::new(0).is_none(),
        "a scale that SHRANK a budget would turn a bound into something a slow machine fails \
         and a fast one passes"
    );
    assert!(
        WaitScale::new(1) == Some(WaitScale::ONE),
        "one is the default"
    );
    assert!(
        WaitScale::new(4).map(WaitScale::factor) == Some(4),
        "and the coverage lane's own scale is a whole multiplier"
    );
}
