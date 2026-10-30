//! A scenario both refused-redelivery ledgers must pass: the in-memory one a
//! bare session keeps and the one on `circles-v2.db`.

use super::types::GroupId;
use super::{
    max_rewind_commits, refetch_spacing_secs, RangePass, RefusedRedeliveryLedger,
    MAX_REFUSED_IDS_PER_GROUP, REFETCH_SPACING_BASE_SECS, REFETCH_SPACING_CAP_SECS,
};

/// A pass that found nothing still owed.
const WHOLE: RangePass = RangePass::Whole { owing: false };

/// `count` distinct ids, from `from`.
fn seeded(from: u32, count: u32) -> Vec<nostr::EventId> {
    (from..from + count)
        .map(|seed| {
            let mut bytes = [0u8; 32];
            bytes[..4].copy_from_slice(&seed.to_be_bytes());
            nostr::EventId::from_byte_array(bytes)
        })
        .collect()
}

/// A range ends only when a WHOLE walk of it left nothing owed (Security
/// Rule 12): past the cap an event is on record as part of the range alone.
///
/// The ceiling only rises. A halted pass carries the walk down and never
/// lowers the ceiling; a pass that reaches the bottom ends the range only
/// if no pass of the walk left an event the engine holds nothing of, and no
/// refusal was recorded since the walk began — otherwise the next pass
/// begins again at the ceiling. Shared by both ledgers' tests.
pub fn assert_a_range_ends_only_when_a_whole_walk_owes_nothing(
    ledger: &dyn RefusedRedeliveryLedger,
) {
    let circle = GroupId::new(vec![6; 32]);
    let cap = u32::try_from(MAX_REFUSED_IDS_PER_GROUP).unwrap();
    assert!(ledger.record(&circle, &seeded(0, cap), 1_000));
    assert!(
        ledger.owed_range(&circle).is_none(),
        "at the cap, still by id"
    );
    assert!(ledger.record(&circle, &seeded(cap, 2), 1_005));
    assert!(
        ledger.owed(&circle, usize::MAX, i64::MAX) == seeded(0, cap),
        "an id owed before the cap was dropped, or the ledger grew past it",
    );
    let range = || ledger.owed_range(&circle).expect("the range is owed");
    assert!(range().until_secs == 1_005 && range().walk_secs == 1_005);
    assert!(ledger.record(&circle, &seeded(cap + 2, 1), 1_001));
    assert!(range().until_secs == 1_005, "a range's ceiling fell");

    // No walk is under way: nothing is recorded for a pass that began none.
    ledger.settle_owed_range(&circle, range(), WHOLE);
    assert!(ledger.owed_range(&circle).is_some());

    // A refusal recorded while the walk's only pass ran is not ended by it.
    ledger.range_tried(&circle, 2_000);
    let read = range();
    assert!(ledger.record(&circle, &seeded(cap + 3, 1), 2_001));
    ledger.settle_owed_range(&circle, read, WHOLE);
    assert!(
        range().until_secs == 2_001 && range().walk_secs == 2_001,
        "a refusal recorded after a pass read the range was discharged by that pass",
    );

    // A pass in which the engine took nothing of an event ends nothing,
    // however whole the relays' answer.
    ledger.range_tried(&circle, 3_000);
    ledger.settle_owed_range(&circle, range(), RangePass::Whole { owing: true });
    assert!(
        ledger.owed_range(&circle).is_some(),
        "a range was ended by a pass that left an event owed",
    );

    // A halted pass carries the walk down, not the ceiling; and what an
    // earlier pass of the walk left owed still stands at the bottom.
    ledger.range_tried(&circle, 4_000);
    let halted = RangePass::Halted {
        at_secs: 900,
        owing: true,
    };
    ledger.settle_owed_range(&circle, range(), halted);
    assert!(
        range().until_secs == 2_001 && range().walk_secs == 900,
        "a halted pass lowered the ceiling, or did not carry the walk down",
    );
    ledger.range_tried(&circle, 4_001);
    ledger.settle_owed_range(&circle, range(), WHOLE);
    assert!(
        ledger
            .owed_range(&circle)
            .is_some_and(|range| range.walk_secs == range.until_secs),
        "a walk ended a range one of its passes had left an event owed in, or did not begin \
         again at the ceiling",
    );

    // A walk that leaves nothing owed ends the range.
    ledger.range_tried(&circle, 5_000);
    let halted = RangePass::Halted {
        at_secs: 900,
        owing: false,
    };
    ledger.settle_owed_range(&circle, range(), halted);
    ledger.range_tried(&circle, 5_001);
    ledger.settle_owed_range(&circle, range(), WHOLE);
    assert!(
        ledger.owed_range(&circle).is_none(),
        "a whole walk that owed nothing did not end the range",
    );
}

/// Two passes read the same range; one settles it and a later overflow owes a
/// new one. The other's stale read must settle nothing, or the new range is
/// dropped uncovered (Rule 12). Shared by both ledgers' tests.
pub fn assert_a_stale_read_never_settles_a_later_range(ledger: &dyn RefusedRedeliveryLedger) {
    let circle = GroupId::new(vec![9; 32]);
    let ids = |from: u32, to: u32| -> Vec<nostr::EventId> {
        (from..to)
            .map(|seed| {
                let mut bytes = [0u8; 32];
                bytes[..4].copy_from_slice(&seed.to_be_bytes());
                nostr::EventId::from_byte_array(bytes)
            })
            .collect()
    };
    let cap = u32::try_from(MAX_REFUSED_IDS_PER_GROUP).unwrap();
    assert!(ledger.record(&circle, &ids(0, cap + 1), 100));
    ledger.range_tried(&circle, 100);
    let stale = ledger.owed_range(&circle).expect("the overflow is a range");
    ledger.settle_owed_range(&circle, stale, WHOLE);
    assert!(ledger.owed_range(&circle).is_none(), "precondition: ended");

    // The same second, and a walk begun where the stale pass's began.
    assert!(ledger.record(&circle, &ids(cap + 1, cap + 2), 100));
    ledger.range_tried(&circle, 100);
    let next = ledger
        .owed_range(&circle)
        .expect("a later overflow owes a range again");
    assert!(
        next.generation != stale.generation,
        "never a reused generation"
    );

    ledger.settle_owed_range(&circle, stale, WHOLE);
    assert!(
        ledger.owed_range(&circle).is_some(),
        "a pass still holding the old read ended a range it never asked for",
    );
}

fn id(seed: u8) -> nostr::EventId {
    nostr::EventId::from_byte_array([seed; 32])
}

/// One refused id that no sweep can discharge, swept once a minute for forty
/// days: it is asked for after waits that double from a minute to a day and
/// then once a day — a number of requests that grows with the logarithm of
/// the time, then with the days — and it is still owed at the end. A new
/// epoch makes it due at once, and no number of new epochs ends it: what was
/// refused for want of room is as a rule an event from an epoch the device
/// has not reached. It ends when it is discharged. Shared by both ledgers'
/// tests.
pub fn assert_a_refused_id_backs_off_and_is_never_forgotten(ledger: &dyn RefusedRedeliveryLedger) {
    const MINUTE: i64 = 60;
    const DAY: i64 = 24 * 60 * MINUTE;
    let circle = GroupId::new(vec![7; 32]);
    let refused = [id(1)];
    assert!(ledger.record(&circle, &refused, 0));

    let mut asked_at = Vec::new();
    for sweep in 0..=40 * DAY / MINUTE {
        let now = sweep * MINUTE;
        if ledger.owed(&circle, 8, now) == refused {
            asked_at.push(now);
            ledger.tried(&circle, &refused, now, false);
        }
    }
    let waits: Vec<i64> = asked_at.windows(2).map(|pair| pair[1] - pair[0]).collect();
    let doubling: Vec<i64> = (1..=11).map(refetch_spacing_secs).collect();
    assert_eq!(
        (REFETCH_SPACING_BASE_SECS, REFETCH_SPACING_CAP_SECS),
        (MINUTE, DAY)
    );
    assert!(
        waits.iter().take(11).eq(doubling.iter()),
        "the wait between two requests for one refused id does not double from a minute",
    );
    assert!(
        doubling
            .windows(2)
            .all(|pair| pair[1] == (pair[0] * 2).min(DAY))
            && waits.iter().skip(11).all(|wait| *wait == DAY),
        "past its cap the wait is not a day",
    );
    assert!(
        asked_at.iter().filter(|at| **at < DAY).nth(10).is_some()
            && asked_at.iter().filter(|at| **at < DAY).nth(11).is_none(),
        "one refused id was not asked for eleven times in its first day of \
         minute-by-minute sweeps",
    );
    assert!(
        ledger.owed(&circle, 8, i64::MAX) == refused,
        "an id no sweep could discharge was forgotten",
    );

    // A new epoch: what the engine could not take it may take now. And as
    // many of them as it takes: a device this far behind still needs it.
    let now = 41 * DAY;
    for _ in 0..=2 * max_rewind_commits() + 2 {
        ledger.tried(&circle, &refused, now, false);
        assert!(ledger.owed(&circle, 8, now).is_empty(), "premise: waiting");
        ledger.moved(&circle);
        assert!(
            ledger.owed(&circle, 8, now) == refused,
            "a refused id was not due at once when its circle reached a new epoch, or a \
             count of epochs ended it",
        );
    }
    ledger.resolve(&circle, &refused);
    assert!(
        ledger.owed(&circle, 8, i64::MAX).is_empty(),
        "a discharged id is still owed",
    );
}

/// A request for which the engine had no room for anything a relay served
/// makes the circle's ids that have ALREADY been asked for wait as long as
/// the soonest of those it has just asked for: nothing says the engine has
/// room for them either. An id that has not had its turn keeps it — it may
/// be the one event the engine can open, among any number it cannot. A new
/// epoch ends every wait. Shared by both ledgers' tests.
pub fn assert_a_wholesale_refusal_makes_only_the_asked_wait(ledger: &dyn RefusedRedeliveryLedger) {
    let circle = GroupId::new(vec![8; 32]);
    let other = GroupId::new(vec![9; 32]);
    let spacing = REFETCH_SPACING_BASE_SECS;
    assert!(ledger.record(&circle, &[id(1), id(2), id(3)], 0));
    assert!(ledger.record(&other, &[id(4)], 0));

    // The first is asked for, plainly, and waits out its own spacing; the
    // second is asked for later and everything served is refused.
    ledger.tried(&circle, &[id(1)], 0, false);
    ledger.tried(&circle, &[id(2)], spacing - 10, true);
    for now in [spacing, 2 * spacing - 11] {
        assert!(
            ledger.owed(&circle, 8, now) == [id(3)],
            "after a wholesale refusal an id already asked for did not wait with the one just \
             asked for, or one that had not had its turn lost it",
        );
    }
    assert!(
        ledger.owed(&other, 8, 0) == [id(4)],
        "another circle waited for a refusal that was not its own",
    );
    let mut due = ledger.owed(&circle, 8, 2 * spacing - 10);
    due.sort_unstable();
    assert!(
        due == [id(1), id(2), id(3)],
        "the wait did not end when it was over"
    );

    ledger.tried(&circle, &[id(1), id(2), id(3)], 2 * spacing, true);
    assert!(
        ledger.owed(&circle, 8, 2 * spacing + 1).is_empty(),
        "premise: every id waits",
    );
    ledger.moved(&circle);
    let mut again = ledger.owed(&circle, 8, 2 * spacing + 1);
    again.sort_unstable();
    assert!(
        again == due,
        "a new epoch did not end the wait a wholesale refusal earned",
    );
}

/// The order owed ids are asked for in is the queue's, whatever the ids are:
/// one joins at the back when it is recorded and goes to the back when it is
/// asked for. So whoever mints ids — low ones, or fresh ones for every sweep
/// — cannot keep theirs ahead of an id that was owed first, and an id that
/// has had its turn is asked for again ahead of every id recorded since.
/// Shared by both ledgers' tests.
pub fn assert_no_id_can_be_minted_to_the_front_of_the_queue(ledger: &dyn RefusedRedeliveryLedger) {
    let circle = GroupId::new(vec![6; 32]);
    let genuine = id(200);
    assert!(ledger.record(&circle, &[genuine], 0));
    assert!(ledger.record(&circle, &[id(3), id(2), id(1)], 0));
    assert!(
        ledger.owed(&circle, 2, 0) == [genuine, id(3)],
        "owed ids were not asked for in the order they were recorded",
    );

    // Its turn taken and still owed, it is behind those that were waiting…
    ledger.tried(&circle, &[genuine, id(3)], 0, false);
    ledger.moved(&circle);
    assert!(
        ledger.owed(&circle, 4, 0) == [id(2), id(1), genuine, id(3)],
        "an id that had its turn was not put behind those still waiting for theirs",
    );
    // …and ahead of whatever is minted afterwards, however low.
    ledger.tried(&circle, &[id(2), id(1)], 0, false);
    ledger.resolve(&circle, &[id(2), id(1)]);
    assert!(ledger.record(&circle, &[nostr::EventId::from_byte_array([0; 32])], 0));
    assert!(
        ledger.owed(&circle, 1, 0) == [genuine],
        "an id minted after one that had already had its turn was asked for ahead of it",
    );
}

/// A device's clock can be stepped back. An id last asked for at a later
/// time than the clock now reads would otherwise wait until the clock had
/// caught up with its old self; it is due. Shared by both ledgers' tests.
pub fn assert_a_clock_stepped_back_leaves_nothing_waiting(ledger: &dyn RefusedRedeliveryLedger) {
    const YEAR: i64 = 365 * 24 * 3600;
    let circle = GroupId::new(vec![5; 32]);
    let cap = u32::try_from(MAX_REFUSED_IDS_PER_GROUP).unwrap();
    let ids: Vec<nostr::EventId> = (0..=cap)
        .map(|seed| {
            let mut bytes = [0u8; 32];
            bytes[..4].copy_from_slice(&seed.to_be_bytes());
            nostr::EventId::from_byte_array(bytes)
        })
        .collect();
    assert!(ledger.record(&circle, &ids, YEAR));
    ledger.tried(&circle, &ids[..1], YEAR, false);
    ledger.range_tried(&circle, YEAR);
    assert!(
        !ledger.owed(&circle, 2000, YEAR).contains(&ids[0])
            && !ledger
                .owed_range(&circle)
                .expect("the overflow is a range")
                .is_due(YEAR),
        "premise: both wait",
    );
    assert!(
        ledger.owed(&circle, 2000, YEAR - 1).contains(&ids[0])
            && ledger
                .owed_range(&circle)
                .expect("the range is still owed")
                .is_due(YEAR - 1),
        "an id or a range asked for at a time the clock no longer reaches went on waiting",
    );
}

/// The owed range keeps a schedule of its own: a pass that does not settle
/// it doubles the wait before the next, whatever the ids beside it are
/// waiting for; a new epoch makes it due at once and starts the doubling
/// over; a pass that lowers it has made progress, and the rest is due at
/// once. Shared by both ledgers' tests.
pub fn assert_the_owed_range_keeps_its_own_schedule(ledger: &dyn RefusedRedeliveryLedger) {
    let circle = GroupId::new(vec![4; 32]);
    let cap = u32::try_from(MAX_REFUSED_IDS_PER_GROUP).unwrap();
    let ids: Vec<nostr::EventId> = (0..=cap)
        .map(|seed| {
            let mut bytes = [0u8; 32];
            bytes[..4].copy_from_slice(&seed.to_be_bytes());
            nostr::EventId::from_byte_array(bytes)
        })
        .collect();
    assert!(ledger.record(&circle, &ids, 1_000));
    let range = || ledger.owed_range(&circle).expect("the overflow is a range");
    assert!(range().is_due(1_000), "a range just owed is not due");

    // Every id waits a day; the range is asked on its own clock.
    for _ in 0..12 {
        ledger.tried(&circle, &ids[..ids.len() - 1], 1_000, true);
    }
    assert!(ledger.owed(&circle, 2000, 2_000).is_empty(), "premise");
    assert!(
        range().is_due(1_000),
        "the range waited for ids nothing can discharge",
    );
    let mut now = 1_000;
    for pass in 1..=3 {
        ledger.range_tried(&circle, now);
        let wait = refetch_spacing_secs(pass);
        assert!(
            !range().is_due(now + wait - 1) && range().is_due(now + wait),
            "a pass that left the range unsettled did not double its wait",
        );
        now += wait;
    }
    ledger.range_tried(&circle, now);
    ledger.moved(&circle);
    assert!(
        range().is_due(now),
        "a new epoch did not make the range due"
    );
    ledger.range_tried(&circle, now);
    assert!(
        range().is_due(now + refetch_spacing_secs(1)),
        "a new epoch did not start the range's doubling over",
    );
    let halted = |at_secs| RangePass::Halted {
        at_secs,
        owing: false,
    };
    ledger.settle_owed_range(&circle, range(), halted(500));
    assert!(
        range().walk_secs == 500 && range().is_due(now),
        "a pass that carried the walk down did not leave the rest due at once",
    );
    // A pass halted where it began has asked a relay and got no further: it
    // earns its wait, and so does each one after it, twice as long.
    for pass in 1..=2 {
        ledger.range_tried(&circle, now);
        ledger.settle_owed_range(&circle, range(), halted(500));
        let wait = refetch_spacing_secs(pass);
        assert!(
            !range().is_due(now + wait - 1) && range().is_due(now + wait),
            "a pass that carried the walk no further was due again at once, or did not \
             double its wait",
        );
        now += wait;
    }
    // A walk that reaches the bottom with something still owed begins again
    // at the ceiling after the wait its last pass earned — and the passes
    // that carried it down counted for none.
    ledger.range_tried(&circle, now);
    ledger.settle_owed_range(&circle, range(), halted(400));
    ledger.range_tried(&circle, now);
    ledger.settle_owed_range(&circle, range(), RangePass::Whole { owing: true });
    let wait = refetch_spacing_secs(3);
    assert!(
        range().walk_secs == range().until_secs
            && !range().is_due(now + wait - 1)
            && range().is_due(now + wait),
        "a walk that left something owed began again at once, or after a wait its \
         descending passes had lengthened",
    );
}
