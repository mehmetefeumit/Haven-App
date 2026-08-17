//! Lifetime-aware `KeyPackage` rotation, end-to-end over in-process relays.
//!
//! These tests mirror the FFI orchestration in `rust_builder`'s
//! `maintain_key_package` (which cannot be compiled from `haven-core`): they
//! mint REAL MLS `KeyPackages` through a real `SessionManager`, read the
//! lifetime off those bytes, run the pure decision core, publish the resulting
//! event to a `MockRelay`, and then re-probe the relay to prove what a peer
//! would actually fetch.
//!
//! # What is being defended
//!
//! An `OpenMLS` `KeyPackage` stops validating at `Lifetime.not_after` — 84 days
//! for the default Haven inherits, which is also the Marmot maximum. Past that
//! instant the kind-30443 is still on the relay, still fetchable, still
//! well-formed, and every `Add` referencing it fails RFC 9420 validation. The
//! account becomes **silently uninvitable** with no error anywhere on the
//! publishing device.
//!
//! The single most important test here is
//! [`heal_does_not_reset_the_rotation_clock`]. Haven's heal path republishes
//! CACHED bytes under a FRESH `created_at`; the reference app ages `KeyPackages`
//! off exactly that event timestamp. Had Haven copied it, one healed flaky relay
//! per week would keep resetting the timer while the real `not_after` ticked
//! down to zero.

mod helpers;

use std::time::Duration;

use haven_core::nostr::mls::SessionManager;
use haven_core::relay::maintenance::{
    build_kp_maintenance_events, build_kp_maintenance_events_reusing, decide_kp_maintenance,
    monotonic_kp_created_at, read_kp_lifetime, KeyPackageLifetime, KpMaintenanceDecision,
    RelayKpEntry, RelayKpPerRelay, RelayKpSnapshot, TrackedKpLifetime,
};
use haven_core::relay::RelayManager;
use nostr::{Keys, Kind};
use nostr_relay_builder::MockRelay;

use helpers::{cleanup_dir, unique_temp_dir};

/// The `OpenMLS`/Marmot maximum lifetime span: 84 days + a 1 h skew margin.
const SPAN: u64 = 7_261_200;

// ---------------------------------------------------------------------------
// Harness — mirrors the FFI's probe → decide → publish → re-probe loop.
// ---------------------------------------------------------------------------

/// A device with a live MLS session, standing in for one Haven install.
struct Device {
    session: SessionManager,
    keys: Keys,
    dir: std::path::PathBuf,
}

impl Device {
    fn new(prefix: &str) -> Self {
        let dir = unique_temp_dir(prefix);
        let keys = Keys::generate();
        let session = SessionManager::new_unencrypted(&dir, &keys).expect("session");
        Self { session, keys, dir }
    }
}

impl Drop for Device {
    fn drop(&mut self) {
        cleanup_dir(&self.dir);
    }
}

/// Extracts a kind-30443 event's NIP-33 `d` tag (mirrors the FFI helper).
fn kp_d_tag(ev: &nostr::Event) -> String {
    ev.tags
        .iter()
        .find_map(|t| {
            let s = t.as_slice();
            (s.len() >= 2 && s[0] == "d").then(|| s[1].clone())
        })
        .unwrap_or_default()
}

/// The FFI's per-relay snapshot construction, verbatim.
async fn kp_snapshot(
    mgr: &RelayManager,
    author: nostr::PublicKey,
    relays: &[String],
) -> RelayKpSnapshot {
    let filter = nostr::Filter::new()
        .kind(Kind::Custom(30443))
        .author(author)
        .limit(64);
    let per_relay = mgr.fetch_events_per_relay(filter, relays).await.unwrap();
    let mut responders = Vec::new();
    for o in &per_relay {
        if !o.responded {
            continue;
        }
        responders.push(RelayKpPerRelay {
            relay_url: o.relay_url.clone(),
            canonical: o
                .events
                .iter()
                .map(|ev| RelayKpEntry {
                    d_tag: kp_d_tag(ev),
                    event_id: ev.id.to_hex(),
                })
                .collect(),
        });
    }
    RelayKpSnapshot { responders }
}

/// Every kind-30443 the relay currently serves for `author`, newest first.
async fn fetch_slot(
    mgr: &RelayManager,
    author: nostr::PublicKey,
    relays: &[String],
    d: &str,
) -> Vec<nostr::Event> {
    let filter = nostr::Filter::new()
        .kind(Kind::Custom(30443))
        .author(author)
        .limit(64);
    let per_relay = mgr.fetch_events_per_relay(filter, relays).await.unwrap();
    let mut events: Vec<nostr::Event> = per_relay
        .into_iter()
        .flat_map(|o| o.events)
        .filter(|e| kp_d_tag(e) == d)
        .collect();
    events.sort_by_key(|e| std::cmp::Reverse(e.created_at.as_secs()));
    events
}

/// Waits for the relay to have persisted a write before the next probe.
async fn settle() {
    tokio::time::sleep(Duration::from_millis(250)).await;
}

/// A lifetime whose rotation threshold falls exactly at `now`.
fn lifetime_due_at(now: u64) -> KeyPackageLifetime {
    #[allow(
        clippy::cast_precision_loss,
        clippy::cast_possible_truncation,
        clippy::cast_sign_loss
    )]
    let elapsed = (SPAN as f64 * 0.75) as u64;
    KeyPackageLifetime::new(now - elapsed, now - elapsed + SPAN)
}

// ---------------------------------------------------------------------------
// 1. A past-threshold package is re-minted into the SAME `d`.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn past_threshold_package_is_reminted_into_the_same_slot() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let relay = MockRelay::run().await.expect("relay");
    let url = relay.url().await.to_string();
    let own = vec![url.clone()];

    let dev = Device::new("kprot_remint");
    let mgr = RelayManager::new();

    // Cycle 1: first publish mints material into a fresh slot.
    let first = build_kp_maintenance_events(&dev.session, &dev.keys, &own, None, None)
        .await
        .expect("first publish");
    let slot_d = first.d_tag.clone();
    let first_bytes = first.key_package.bytes().to_vec();
    mgr.publish_event(&first.event, &own)
        .await
        .expect("publish");
    settle().await;

    // The real lifetime of the real package, read off the package itself.
    let TrackedKpLifetime::Known(lifetime) = read_kp_lifetime(&first_bytes) else {
        panic!("a freshly minted KeyPackage must yield a readable lifetime");
    };
    assert_eq!(
        lifetime.not_after - lifetime.not_before,
        SPAN,
        "Haven inherits the spec-maximal OpenMLS lifetime"
    );

    // Cycle 2, simulated at the rotation instant (no 63-day wait: the clock is
    // an argument, the lifetime comes from the package).
    let snapshot = kp_snapshot(&mgr, dev.keys.public_key(), &own).await;
    let decision = decide_kp_maintenance(
        &snapshot,
        Some(&slot_d),
        TrackedKpLifetime::Known(lifetime),
        lifetime.rotate_at(),
    );
    let KpMaintenanceDecision::Rotate {
        existing_d,
        targets,
        lifetime_unreadable,
    } = decision
    else {
        panic!("a package at its rotation threshold must Rotate: {decision:?}");
    };
    assert_eq!(
        existing_d, slot_d,
        "the transport binding requires reusing the SAME `d` for a routine \
         replacement — a fresh slot would orphan the coordinate peers cached"
    );
    assert!(!lifetime_unreadable);
    assert_eq!(targets, own);

    // Perform the rotation: FRESH material, SAME slot.
    let second = build_kp_maintenance_events(
        &dev.session,
        &dev.keys,
        &targets,
        Some(&existing_d),
        Some(i64::try_from(first.event.created_at.as_secs()).unwrap()),
    )
    .await
    .expect("rotate");
    assert_eq!(second.d_tag, slot_d, "rotation must not fork the slot");
    assert_ne!(
        second.key_package.bytes(),
        first_bytes.as_slice(),
        "rotation must mint NEW material, not re-advertise the old package"
    );

    // The replacement carries its OWN, freshly anchored lifetime.
    //
    // `not_after` is `>=` rather than `>` only because both packages are minted
    // milliseconds apart here; `OpenMLS` anchors `not_after` at the mint instant,
    // so in production — where the rotation happens ~63 days after the original
    // mint — this is a strict 63-day extension. What the test CAN prove exactly
    // is that the replacement re-derives its window from scratch and is current.
    let TrackedKpLifetime::Known(new_lifetime) = read_kp_lifetime(second.key_package.bytes())
    else {
        panic!("the replacement must have a readable lifetime");
    };
    assert!(
        new_lifetime.not_after >= lifetime.not_after,
        "the replacement's window must never end EARLIER than the package it \
         supersedes"
    );
    assert_eq!(
        new_lifetime.not_after - new_lifetime.not_before,
        SPAN,
        "the replacement must get a full spec-maximal window, not a remainder \
         of the old one"
    );
    let now = haven_core::relay::maintenance::now_secs();
    assert!(
        !new_lifetime.is_past_rotation_threshold(now),
        "the replacement must NOT itself be immediately due — otherwise every \
         tick would rotate forever"
    );

    mgr.publish_event(&second.event, &targets)
        .await
        .expect("publish rotation");
    settle().await;

    // What a peer now fetches from the slot.
    let served = fetch_slot(&mgr, dev.keys.public_key(), &own, &slot_d).await;
    assert_eq!(
        served.len(),
        1,
        "NIP-33 same-`d` supersession must leave exactly ONE event in the slot, \
         not a pile of orphaned coordinates"
    );
    assert_eq!(
        served[0].id, second.event.id,
        "the relay must serve the REPLACEMENT, not the superseded package"
    );
}

// ---------------------------------------------------------------------------
// 2. THE test: a heal must not reset the rotation clock.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn heal_does_not_reset_the_rotation_clock() {
    // The trap this whole design exists to avoid.
    //
    // The reference app rotates on `now - event.created_at > 30 days`, which is
    // honest FOR IT because every publish there mints fresh material. Haven's
    // heal path republishes CACHED bytes under a FRESH `created_at`. Keying
    // rotation on the event timestamp would therefore let a device that heals a
    // flaky relay every few days push its rotation deadline out indefinitely,
    // while `not_after` — the only thing an inviter actually checks — kept
    // counting down to a hard cliff.
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let relay_a = MockRelay::run().await.expect("relay a");
    let relay_b = MockRelay::run().await.expect("relay b");
    let url_a = relay_a.url().await.to_string();
    let url_b = relay_b.url().await.to_string();
    let own = vec![url_a.clone(), url_b.clone()];

    let dev = Device::new("kprot_heal_clock");
    let mgr = RelayManager::new();

    // Publish to A only; B is the relay that will later "drop" the package.
    let first = build_kp_maintenance_events(
        &dev.session,
        &dev.keys,
        std::slice::from_ref(&url_a),
        None,
        None,
    )
    .await
    .expect("first publish");
    let slot_d = first.d_tag.clone();
    let cached_bytes = first.key_package.bytes().to_vec();
    mgr.publish_event(&first.event, std::slice::from_ref(&url_a))
        .await
        .expect("publish to A");
    settle().await;

    let lifetime_before = read_kp_lifetime(&cached_bytes);
    let TrackedKpLifetime::Known(before) = lifetime_before else {
        panic!("expected a readable lifetime");
    };

    // HEAL: B does not serve the slot, so the decision republishes the CACHED
    // bytes there, stamped with a brand-new `created_at`.
    let snapshot = kp_snapshot(&mgr, dev.keys.public_key(), &own).await;
    let decision = decide_kp_maintenance(
        &snapshot,
        Some(&slot_d),
        lifetime_before,
        // A clock comfortably short of the threshold, so this really is a heal.
        before.not_before + 1,
    );
    let KpMaintenanceDecision::Republish {
        existing_d,
        targets,
    } = decision
    else {
        panic!("a fresh package missing from one relay must HEAL: {decision:?}");
    };
    assert_eq!(targets, vec![url_b.clone()], "heal B only");

    let healed = build_kp_maintenance_events_reusing(
        &dev.keys,
        &cached_bytes,
        &targets,
        existing_d.as_deref().unwrap(),
        Some(i64::try_from(first.event.created_at.as_secs()).unwrap()),
    )
    .expect("heal");
    mgr.publish_event(&healed.event, &targets)
        .await
        .expect("publish heal");
    settle().await;

    // The heal DID move the event timestamp forward…
    assert!(
        healed.event.created_at.as_secs() > first.event.created_at.as_secs(),
        "precondition: the heal must republish under a strictly newer \
         `created_at`, or this test proves nothing"
    );
    // …and republished byte-identical material.
    assert_eq!(
        healed.key_package.bytes(),
        cached_bytes.as_slice(),
        "a heal must re-advertise the SAME package, not mint a new one"
    );

    // THE ASSERTION: the rotation clock did not move.
    let lifetime_after = read_kp_lifetime(healed.key_package.bytes());
    assert_eq!(
        lifetime_after, lifetime_before,
        "the heal must NOT have moved the package's lifetime — if this fails, \
         the rotation clock is being read from the event and a heal loop can \
         defer rotation past `not_after` forever"
    );
    let TrackedKpLifetime::Known(after) = lifetime_after else {
        unreachable!("equality with a Known value was just asserted")
    };
    assert_eq!(
        after.rotate_at(),
        before.rotate_at(),
        "the rotation instant must be identical before and after the heal"
    );

    // And the consequence: at the ORIGINAL rotation instant the package is due,
    // no matter how many heals refreshed its `created_at` in between.
    let post_heal_snapshot = kp_snapshot(&mgr, dev.keys.public_key(), &own).await;
    let post_heal = decide_kp_maintenance(
        &post_heal_snapshot,
        Some(&slot_d),
        lifetime_after,
        before.rotate_at(),
    );
    assert!(
        matches!(post_heal, KpMaintenanceDecision::Rotate { .. }),
        "after a heal, the package must STILL rotate at its original threshold \
         — got {post_heal:?}"
    );
}

// ---------------------------------------------------------------------------
// 3. A same-second replacement really does supersede on the relay.
// ---------------------------------------------------------------------------

/// A `created_at` tie in one addressable slot leaves the winner up to the
/// RELAY, not the publisher — and relays disagree.
///
/// NIP-01 and the Marmot Nostr binding both say a relay SHOULD keep the newest
/// `created_at` and break a tie on the lowest event id. `MockRelay` does NOT
/// implement that tie-break: it takes the last write. Both behaviours are
/// reachable in the wild, which is exactly the problem — a replacement that
/// ties is decided by whichever rule its relay happens to implement, silently,
/// and a publisher fanning out to several relays can end up with the slot
/// resolving DIFFERENTLY on each one.
///
/// This test pins the observed behaviour so the divergence is visible in the
/// suite rather than assumed. If it ever fails because `MockRelay` gained the
/// NIP-01 tie-break, that is good news: update the expectation to `lower id`.
/// Either way the conclusion for Haven is unchanged, and it is proved by
/// [`monotonic_floor_makes_a_same_second_replacement_win_the_slot`]: never emit
/// a tie in the first place.
///
/// Deterministic by construction — both stamps are pinned to a fixed future
/// second via the monotonic floor's `max(now, prev + 1)`, so nothing here
/// depends on how the wall clock falls.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_created_at_tie_leaves_the_slot_winner_up_to_the_relay() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let relay = MockRelay::run().await.expect("relay");
    let url = relay.url().await.to_string();
    let own = vec![url.clone()];

    let dev = Device::new("kprot_tie");
    let mgr = RelayManager::new();
    let slot_d = "aa".repeat(16);

    // A fixed second in the near future, so `max(now, prev + 1)` resolves to it
    // exactly for both events regardless of when the test runs.
    let base = haven_core::relay::maintenance::now_secs() + 100;
    let floor = Some(i64::try_from(base).unwrap() - 1);

    // Two DIFFERENT real packages (different bytes ⇒ different event ids),
    // stamped at the IDENTICAL second.
    let a_bytes = dev
        .session
        .fresh_key_package()
        .await
        .expect("mint a")
        .bytes()
        .to_vec();
    let b_bytes = dev
        .session
        .fresh_key_package()
        .await
        .expect("mint b")
        .bytes()
        .to_vec();
    let a =
        build_kp_maintenance_events_reusing(&dev.keys, &a_bytes, &own, &slot_d, floor).expect("a");
    let b =
        build_kp_maintenance_events_reusing(&dev.keys, &b_bytes, &own, &slot_d, floor).expect("b");
    assert_eq!(
        a.event.created_at, b.event.created_at,
        "precondition: the two events must genuinely tie"
    );
    assert_ne!(a.event.id, b.event.id);

    // Publish the LOWER-id event FIRST, then the higher one. Now the two rules
    // disagree: NIP-01's tie-break keeps the lower id (the first write), while
    // last-write-wins keeps the higher id (the second).
    let (lower_id, higher_id) = if a.event.id.to_hex() < b.event.id.to_hex() {
        (&a, &b)
    } else {
        (&b, &a)
    };
    mgr.publish_event(&lower_id.event, &own)
        .await
        .expect("lower id first");
    settle().await;
    mgr.publish_event(&higher_id.event, &own)
        .await
        .expect("higher id second");
    settle().await;

    let served = fetch_slot(&mgr, dev.keys.public_key(), &own, &slot_d).await;
    assert_eq!(served.len(), 1, "one addressable slot, one event");
    assert_eq!(
        served[0].id, higher_id.event.id,
        "THE HAZARD, observed: this relay let the LAST tying write take the \
         slot, where NIP-01 says the LOWER event id should have kept it. On a \
         tie the survivor is decided by the relay's implementation, not by the \
         publisher — and a client fanning out to several relays can have the \
         same slot resolve differently on each. So a replacement must never \
         share a `created_at` with the package it supersedes. (If this starts \
         failing with the lower id, the relay gained the NIP-01 tie-break; the \
         conclusion for Haven is unchanged.)"
    );
}

/// And the fix: with the monotonic floor applied, the replacement wins
/// deterministically even though it is built in the same second.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn monotonic_floor_makes_a_same_second_replacement_win_the_slot() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let relay = MockRelay::run().await.expect("relay");
    let url = relay.url().await.to_string();
    let own = vec![url.clone()];

    let dev = Device::new("kprot_same_second");
    let mgr = RelayManager::new();
    let slot_d = "bb".repeat(16);

    let base = haven_core::relay::maintenance::now_secs() + 100;
    let base_i64 = i64::try_from(base).unwrap();

    // Repeat until the replacement is the HIGHER-id event, so a regression that
    // drops the floor cannot pass by accidentally winning the id tie-break.
    // Bounded, and each round is cheap.
    let mut attempt = 0;
    let (old, new) = loop {
        attempt += 1;
        assert!(attempt < 32, "could not construct a higher-id replacement");
        let old_bytes = dev
            .session
            .fresh_key_package()
            .await
            .expect("mint old")
            .bytes()
            .to_vec();
        let new_bytes = dev
            .session
            .fresh_key_package()
            .await
            .expect("mint new")
            .bytes()
            .to_vec();
        // `old` lands exactly on `base`; `new` is floored to `base + 1`.
        let old = build_kp_maintenance_events_reusing(
            &dev.keys,
            &old_bytes,
            &own,
            &slot_d,
            Some(base_i64 - 1),
        )
        .expect("old");
        let new = build_kp_maintenance_events_reusing(
            &dev.keys,
            &new_bytes,
            &own,
            &slot_d,
            Some(base_i64),
        )
        .expect("new");
        assert_eq!(old.event.created_at.as_secs(), base);
        assert_eq!(
            new.event.created_at.as_secs(),
            base + 1,
            "the floor must lift the replacement strictly above its predecessor"
        );
        if new.event.id.to_hex() > old.event.id.to_hex() {
            break (old, new);
        }
    };

    mgr.publish_event(&old.event, &own).await.expect("old");
    settle().await;
    mgr.publish_event(&new.event, &own).await.expect("new");
    settle().await;

    let served = fetch_slot(&mgr, dev.keys.public_key(), &own, &slot_d).await;
    assert_eq!(served.len(), 1, "one addressable slot, one event");
    assert_eq!(
        served[0].id, new.event.id,
        "the replacement must win on `created_at` alone — it deliberately has \
         the HIGHER event id, so without the +1 floor it would LOSE the tie"
    );
}

/// The floor's arithmetic contract, stated where the relay proof can point at
/// it: with a floor the stamp steps past a collision, without one it lands on it.
#[test]
fn without_the_floor_a_rebuild_lands_on_the_identical_stamp() {
    let t = 1_800_000_000_u64;
    assert_eq!(
        monotonic_kp_created_at(None, t).as_secs(),
        t,
        "no floor ⇒ a same-second rebuild ties"
    );
    assert_eq!(
        monotonic_kp_created_at(Some(i64::try_from(t).unwrap()), t).as_secs(),
        t + 1,
        "floor ⇒ the tie is removed by construction"
    );
}

// ---------------------------------------------------------------------------
// 4. No churn: a fresh package is not re-minted.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_fresh_package_is_not_reminted_and_its_bytes_are_untouched() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let relay = MockRelay::run().await.expect("relay");
    let url = relay.url().await.to_string();
    let own = vec![url.clone()];

    let dev = Device::new("kprot_nochurn");
    let mgr = RelayManager::new();

    let first = build_kp_maintenance_events(&dev.session, &dev.keys, &own, None, None)
        .await
        .expect("first");
    let slot_d = first.d_tag.clone();
    let bytes = first.key_package.bytes().to_vec();
    let event_id = first.event.id;
    mgr.publish_event(&first.event, &own)
        .await
        .expect("publish");
    settle().await;

    let lifetime = read_kp_lifetime(&bytes);
    let TrackedKpLifetime::Known(l) = lifetime else {
        panic!("readable lifetime expected");
    };

    // Ten ticks spread across the package's whole pre-threshold life. Every one
    // must be a NoOp: rotation churn is not free — each rotation is a fresh
    // 30443 publish to the account's own relays, i.e. an observable liveness
    // beacon, plus a new init key in the engine.
    for i in 0..10 {
        let now = l.not_before + (l.rotate_at() - l.not_before) * i / 10;
        let snap = kp_snapshot(&mgr, dev.keys.public_key(), &own).await;
        assert_eq!(
            decide_kp_maintenance(&snap, Some(&slot_d), lifetime, now),
            KpMaintenanceDecision::NoOp,
            "tick {i} (at {now}, threshold {}) must not rotate",
            l.rotate_at()
        );
    }

    // Nothing was published, nothing changed on the relay, and the bytes are
    // identical — the strongest form of "no churn".
    let served = fetch_slot(&mgr, dev.keys.public_key(), &own, &slot_d).await;
    assert_eq!(served.len(), 1);
    assert_eq!(
        served[0].id, event_id,
        "the relay must serve the SAME event"
    );
    let served_bytes = SessionManager::key_package_from_event(&served[0])
        .expect("parse")
        .bytes()
        .to_vec();
    assert_eq!(
        served_bytes, bytes,
        "the on-relay KeyPackage bytes must be byte-for-byte unchanged"
    );
}

// ---------------------------------------------------------------------------
// 5. Migration is free — no special-case path.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_account_published_before_the_feature_rotates_on_its_next_check() {
    // Keying on `not_after` means there is nothing to migrate: the deciding
    // value was stamped into the package when it was minted, long before this
    // code existed. An old install reads as past-threshold on the very next
    // tick; a young one is left alone. Both are proved here against a REAL
    // package, with only the CLOCK moved.
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let relay = MockRelay::run().await.expect("relay");
    let url = relay.url().await.to_string();
    let own = vec![url.clone()];

    let dev = Device::new("kprot_migration");
    let mgr = RelayManager::new();

    let published = build_kp_maintenance_events(&dev.session, &dev.keys, &own, None, None)
        .await
        .expect("legacy publish");
    let slot_d = published.d_tag.clone();
    mgr.publish_event(&published.event, &own)
        .await
        .expect("publish");
    settle().await;

    let lifetime = read_kp_lifetime(published.key_package.bytes());
    let TrackedKpLifetime::Known(l) = lifetime else {
        panic!("readable lifetime expected");
    };
    let snap = kp_snapshot(&mgr, dev.keys.public_key(), &own).await;

    // Day 70 of an 84-day package: due, with no migration step of any kind.
    let day_70 = l.not_before + 70 * 86_400;
    assert!(
        matches!(
            decide_kp_maintenance(&snap, Some(&slot_d), lifetime, day_70),
            KpMaintenanceDecision::Rotate { .. }
        ),
        "a package minted 70 days ago must rotate immediately"
    );

    // Day 10: left alone, so shipping the feature does not stampede every
    // existing install into a simultaneous republish.
    let day_10 = l.not_before + 10 * 86_400;
    assert_eq!(
        decide_kp_maintenance(&snap, Some(&slot_d), lifetime, day_10),
        KpMaintenanceDecision::NoOp,
        "a young package must not be churned just because the check is new"
    );
}

// ---------------------------------------------------------------------------
// 6. Rotation beats heal when both apply.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn past_threshold_plus_partial_drop_remints_once_to_every_relay() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let relay_a = MockRelay::run().await.expect("relay a");
    let relay_b = MockRelay::run().await.expect("relay b");
    let url_a = relay_a.url().await.to_string();
    let url_b = relay_b.url().await.to_string();
    let own = vec![url_a.clone(), url_b.clone()];

    let dev = Device::new("kprot_rotate_beats_heal");
    let mgr = RelayManager::new();

    // A serves the slot; B never received it.
    let first = build_kp_maintenance_events(
        &dev.session,
        &dev.keys,
        std::slice::from_ref(&url_a),
        None,
        None,
    )
    .await
    .expect("first");
    let slot_d = first.d_tag.clone();
    let old_bytes = first.key_package.bytes().to_vec();
    mgr.publish_event(&first.event, std::slice::from_ref(&url_a))
        .await
        .expect("publish A");
    settle().await;

    let now = haven_core::relay::maintenance::now_secs();
    let due = lifetime_due_at(now);
    let snap = kp_snapshot(&mgr, dev.keys.public_key(), &own).await;
    assert_eq!(snap.responders.len(), 2, "both relays must respond");

    let decision = decide_kp_maintenance(&snap, Some(&slot_d), TrackedKpLifetime::Known(due), now);
    let KpMaintenanceDecision::Rotate { targets, .. } = decision else {
        panic!(
            "past-threshold must dominate the heal branch — healing first would \
             re-advertise expiring bytes to B and only then rotate: {decision:?}"
        );
    };
    assert_eq!(
        targets, own,
        "rotation must reach A too: A is serving material that is about to stop \
         validating, so it needs the replacement most"
    );

    // ONE re-mint, published everywhere.
    let rotated = build_kp_maintenance_events(
        &dev.session,
        &dev.keys,
        &targets,
        Some(&slot_d),
        Some(i64::try_from(first.event.created_at.as_secs()).unwrap()),
    )
    .await
    .expect("rotate");
    assert_ne!(rotated.key_package.bytes(), old_bytes.as_slice());
    mgr.publish_event(&rotated.event, &targets)
        .await
        .expect("publish rotation");
    settle().await;

    for relay_url in &own {
        let served = fetch_slot(
            &mgr,
            dev.keys.public_key(),
            std::slice::from_ref(relay_url),
            &slot_d,
        )
        .await;
        assert_eq!(
            served.len(),
            1,
            "each relay must hold exactly one event in the slot"
        );
        assert_eq!(
            served[0].id, rotated.event.id,
            "every relay must serve the freshly minted replacement"
        );
    }
}

// ---------------------------------------------------------------------------
// 7. Reading the lifetime off real material.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_real_minted_package_yields_a_spec_maximal_lifetime() {
    let dev = Device::new("kprot_read");
    let kp = dev.session.fresh_key_package().await.expect("mint");

    let TrackedKpLifetime::Known(l) = read_kp_lifetime(kp.bytes()) else {
        panic!("a freshly minted KeyPackage must yield a readable lifetime");
    };
    // `foundation/key-packages.md`: "MUST have `not_after - not_before <=
    // 7,261,200` seconds. The range is 84 days plus a one-hour clock-skew
    // margin." OpenMLS's default IS that maximum, so the threshold — not a
    // shorter lifetime — is what has to do the work.
    assert_eq!(l.not_after - l.not_before, SPAN);
    let now = haven_core::relay::maintenance::now_secs();
    assert!(
        l.not_before <= now && now < l.not_after,
        "a fresh package must be current at validation time"
    );
    assert!(
        !l.is_past_rotation_threshold(now),
        "a package minted seconds ago must not already be due for rotation"
    );
    // ~21 days of slack between rotation and the cliff.
    assert_eq!((l.not_after - l.rotate_at()) / 86_400, 21);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_tampered_key_package_reads_as_unreadable_and_forces_a_rotation() {
    // The unreadable branch, exercised on real-shaped input rather than random
    // bytes: a valid package whose signature no longer verifies.
    let dev = Device::new("kprot_tampered");
    let kp = dev.session.fresh_key_package().await.expect("mint");
    let mut bytes = kp.bytes().to_vec();
    // Flip a byte deep in the payload — enough to break the signature without
    // truncating the TLS framing.
    let mid = bytes.len() / 2;
    bytes[mid] ^= 0xFF;

    let tracked = read_kp_lifetime(&bytes);
    assert!(
        matches!(
            tracked,
            TrackedKpLifetime::Unreadable | TrackedKpLifetime::NotCurrent
        ),
        "tampered bytes must never yield a Known lifetime: {tracked:?}"
    );
    assert!(
        tracked.is_rotation_due(haven_core::relay::maintenance::now_secs()),
        "an unusable tracked package must force a rotation, not be assumed fresh"
    );
}

// ---------------------------------------------------------------------------
// 8. The security oracle: deleting an init key really does destroy the ability
//    to process Welcomes encrypted to that KeyPackage.
// ---------------------------------------------------------------------------

/// Establishes that `delete_key_package` is not bookkeeping — it destroys the
/// private HPKE `init_key`, and with it the ability to join through any Welcome
/// already encrypted to that package.
///
/// This is both the point of the `not_after` deletion bound (spec: compromising
/// a retained `init_key` "lets an attacker decrypt every recorded Welcome
/// encrypted to that `KeyPackage` and recover the join secrets carried by those
/// Welcomes") and the OBSERVABLE ORACLE the publish-before-delete proof needs:
/// without it, "was the old material deleted?" has no answer from outside the
/// engine, because `delete_key_package` is idempotent and silent.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn deleting_an_init_key_makes_welcomes_to_that_package_undecryptable() {
    use haven_core::nostr::mls::types::{LocationGroupConfig, PublishWork};

    let alice = Device::new("kprot_oracle_alice");
    let bob = Device::new("kprot_oracle_bob");
    let relays = vec!["wss://relay.test.com".to_string()];

    // Bob publishes a KeyPackage; Alice invites him with it TWICE, so we get two
    // Welcomes to the SAME package — one used while the key lives, one after it
    // is deleted. (A last-resort package serves unlimited joins, which is why
    // retaining its init key is the exposure the spec warns about.)
    let bob_kp_event = build_kp_maintenance_events(&bob.session, &bob.keys, &relays, None, None)
        .await
        .expect("bob kp")
        .event;
    let bob_kp = SessionManager::key_package_from_event(&bob_kp_event).expect("parse");

    let make_welcome = |kp: haven_core::nostr::mls::types::KeyPackage, name: &'static str| {
        let alice_session = &alice.session;
        let alice_keys = &alice.keys;
        async move {
            let config = LocationGroupConfig::new(name)
                .with_relay("wss://relay.test.com")
                .with_admin(alice_keys.public_key().to_hex());
            let created = alice_session
                .create_group(vec![kp], config)
                .await
                .expect("create group");
            let mut welcome = None;
            for work in &created.effects.publish {
                if let PublishWork::GroupCreated { welcomes, pending } = work {
                    alice_session
                        .confirm_published(*pending)
                        .await
                        .expect("confirm");
                    welcome = Some(
                        SessionManager::transport_message_to_event(&welcomes[0])
                            .expect("welcome event"),
                    );
                }
            }
            welcome.expect("a welcome was produced")
        }
    };

    let welcome_before = make_welcome(bob_kp.clone(), "Before").await;
    let welcome_after = make_welcome(bob_kp.clone(), "After").await;

    // While the init key lives, Bob can join.
    bob.session
        .accept_welcome(&welcome_before)
        .await
        .expect("bob must be able to join while his init key lives");

    // Delete the init key — exactly what the `not_after` bound does.
    bob.session
        .delete_key_package(&bob_kp)
        .await
        .expect("delete init key");

    // The second Welcome — already minted, already encrypted to that package —
    // is now undecryptable. This is the deliberate confidentiality-over-
    // availability trade the spec names, and the oracle the publish-before-
    // delete test relies on.
    let err = bob.session.accept_welcome(&welcome_after).await.expect_err(
        "after the init key is deleted, a Welcome encrypted to that \
             KeyPackage MUST no longer be processable — if this succeeds, \
             `delete_key_package` is not actually destroying the private half \
             and the `not_after` bound is cosmetic",
    );
    // Redaction check while we are here (Security Rules 6/8).
    let text = format!("{err:?}");
    assert!(
        !text.contains(&hex::encode(bob_kp.bytes())),
        "an MLS error must never echo raw KeyPackage bytes"
    );
}

// ---------------------------------------------------------------------------
// 9. The slot id a first publish mints is the shape the binding fixes.
// ---------------------------------------------------------------------------

/// The Nostr transport binding does not leave the `d` value free: it is "exactly
/// one tag, exactly one 64-character lowercase hex value decoding to 32 bytes",
/// generated "once from 32 random bytes". An event that misses that shape is
/// malformed, and an inviter "MUST reject malformed or incompatible candidates"
/// — so a mis-sized slot id costs the account exactly what an expired package
/// does: invitations that never happen, with nothing to see on this device.
///
/// The assertions read the SIGNED event, because the `d` a peer resolves is the
/// one on the wire, not the field the builder happens to return.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_first_publish_mints_a_binding_shaped_random_slot_id() {
    let dev = Device::new("kprot_slot_id");
    let own = vec!["wss://own.example.com".to_string()];

    let first = build_kp_maintenance_events(&dev.session, &dev.keys, &own, None, None)
        .await
        .expect("first publish");
    let d = kp_d_tag(&first.event);
    assert_eq!(d, first.d_tag, "the wire `d` must be the recorded slot id");

    assert_eq!(d.len(), 64, "slot id must be 64 characters: {d}");
    assert!(
        d.chars()
            .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()),
        "slot id must be LOWERCASE hex: {d}"
    );
    assert_eq!(
        hex::decode(&d).expect("slot id must be hex").len(),
        32,
        "slot id must decode to 32 bytes: {d}"
    );

    // Same device, same account, same session: a second slot id that matched
    // would mean the id is derived from identity or device material, which the
    // binding forbids outright.
    let second = build_kp_maintenance_events(&dev.session, &dev.keys, &own, None, None)
        .await
        .expect("second mint");
    assert_ne!(
        kp_d_tag(&second.event),
        d,
        "each fresh slot must be independently random, never derived"
    );
}
