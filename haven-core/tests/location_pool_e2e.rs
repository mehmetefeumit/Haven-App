//! A create the caller names no relays for draws three of them from the
//! curated location pool: never a relay that carries the account's own identity
//! traffic, and avoiding the invitees' relays while enough others remain.
//!
//! The production pool is live here: this binary never installs the override
//! (`tests/location_pool_override.rs` does, in a process of its own), and a
//! create publishes nothing, so no pool relay is dialled.

mod helpers;

use std::collections::BTreeSet;

use haven_core::circle::{
    production_location_relays, Circle, CircleConfig, CircleError, MemberKeyPackage, RelayType,
    RELAYS_PER_NEW_CIRCLE,
};
use helpers::{create_key_package_event, CircleMember};

/// An invitee inbox outside the pool, on a host that never resolves.
const INVITEE_INBOX: &str = "wss://invitee-inbox.invalid";

/// How many creates a randomised assertion is held over. With one relay an
/// invitee lists wrongly preferred, each create would pick it with
/// probability 3/4, so a broken exclusion passes all of them with 4^-16.
const CREATES: usize = 16;

fn owned(relays: &[&str]) -> Vec<String> {
    relays.iter().map(ToString::to_string).collect()
}

/// An invitee whose relay lists are `inbox`, `read` and `write` (NIP-65).
async fn invitee(inbox: &[&str], read: &[&str], write: &[&str]) -> MemberKeyPackage {
    let member = CircleMember::new();
    MemberKeyPackage {
        key_package_event: create_key_package_event(
            member.session(),
            &member.keys,
            &owned(&[INVITEE_INBOX]),
        )
        .await,
        inbox_relays: owned(inbox),
        nip65_relays: owned(read),
        nip65_write_relays: owned(write),
    }
}

/// A create that names no relays.
async fn create(
    device: &CircleMember,
    members: Vec<MemberKeyPackage>,
) -> Result<Circle, CircleError> {
    device
        .circle
        .create_circle(&device.keys, members, &CircleConfig::new("Pool"))
        .await
        .map(|created| created.circle)
}

fn add(device: &CircleMember, relay: &str, category: RelayType) {
    device
        .circle
        .add_user_relay(relay, category)
        .expect("the relay is stored");
}

/// A device seeded as a new install is: inbox and key-package relays from the
/// account seed, profile relays from the profile pool.
fn seeded() -> CircleMember {
    let device = CircleMember::new();
    device
        .circle
        .seed_relay_defaults_if_unseeded()
        .expect("the relay lists are seeded");
    device
}

fn sorted(relays: &[&String]) -> Vec<String> {
    let mut relays: Vec<String> = relays.iter().map(|relay| (*relay).clone()).collect();
    relays.sort();
    relays
}

#[tokio::test]
async fn create_with_no_relays_named_picks_three_distinct_relays_from_the_location_pool() {
    let pool = production_location_relays();
    let device = seeded();
    // More creates than the pool holds three times over: a circle's own relays
    // are not the account's identity, so earlier circles never shrink it.
    for _ in 0..4 {
        let circle = create(&device, vec![invitee(&[INVITEE_INBOX], &[], &[]).await])
            .await
            .expect("the circle is created");
        assert_eq!(circle.relays.len(), RELAYS_PER_NEW_CIRCLE);
        let distinct: BTreeSet<&String> = circle.relays.iter().collect();
        assert_eq!(
            distinct.len(),
            circle.relays.len(),
            "a relay was picked twice"
        );
        for relay in &circle.relays {
            assert!(pool.contains(relay), "a relay outside the pool was picked");
        }
        assert_eq!(
            device
                .session()
                .group_relays(&circle.mls_group_id)
                .await
                .expect("the routing component is read"),
            circle.relays,
            "the routing component names other relays than the circle's row",
        );
        assert_eq!(
            device
                .circle
                .get_circle(&circle.mls_group_id)
                .await
                .expect("the circle is read")
                .expect("the circle is stored")
                .circle
                .relays,
            circle.relays,
            "the stored circle names other relays than the create returned",
        );
    }
}

#[tokio::test]
async fn create_never_picks_a_relay_the_account_uses_for_its_identity() {
    let pool = production_location_relays();
    let host = |i: usize| pool[i].trim_start_matches("wss://").to_string();
    let device = seeded();
    // Each server under a spelling other than the pool's.
    add(
        &device,
        &format!("WSS://{}/", host(0).to_uppercase()),
        RelayType::Inbox,
    );
    add(
        &device,
        &format!("wss://{}/inbox", host(1)),
        RelayType::Inbox,
    );
    add(
        &device,
        &format!("wss://{}:443", host(2)),
        RelayType::KeyPackage,
    );
    add(&device, &pool[3], RelayType::KeyPackage);
    add(&device, &pool[4], RelayType::Profile);
    // An inbox relay the user removed has still seen the pubkey.
    add(&device, &pool[5], RelayType::Inbox);
    assert!(device
        .circle
        .remove_user_relay(&pool[5], RelayType::Inbox)
        .expect("the relay is removed"));

    let circle = create(&device, Vec::new())
        .await
        .expect("the circle is created");
    assert_eq!(circle.relays, sorted(&[&pool[6], &pool[7]]));

    add(
        &device,
        &format!("wss://{}/kp", host(6)),
        RelayType::KeyPackage,
    );
    let circle = create(&device, Vec::new())
        .await
        .expect("the circle is created");
    assert_eq!(circle.relays, vec![pool[7].clone()]);

    add(&device, &pool[7], RelayType::Profile);
    let circles = device
        .circle
        .get_circles()
        .await
        .expect("the circles")
        .len();
    let groups = device
        .session()
        .live_group_ids()
        .await
        .expect("the groups")
        .len();
    let ledger = device
        .circle
        .list_contaminated_relays()
        .expect("the ledger");
    assert!(matches!(
        create(&device, vec![invitee(&[INVITEE_INBOX], &[], &[]).await]).await,
        Err(CircleError::NoLocationRelay)
    ));
    assert_eq!(
        device
            .circle
            .get_circles()
            .await
            .expect("the circles")
            .len(),
        circles,
        "a refused create stored a circle",
    );
    assert_eq!(
        device
            .session()
            .live_group_ids()
            .await
            .expect("the groups")
            .len(),
        groups,
        "a refused create made an MLS group",
    );
    assert_eq!(
        device
            .circle
            .list_contaminated_relays()
            .expect("the ledger"),
        ledger,
        "a refused create recorded a relay",
    );
}

#[tokio::test]
async fn create_prefers_relays_no_invitee_lists_including_nip65_write_relays() {
    let pool = production_location_relays();
    let device = seeded();
    add(&device, &pool[0], RelayType::Inbox);
    add(&device, &pool[4], RelayType::KeyPackage);
    // Three unlisted relays remain beside one each from the invitee's inbox,
    // NIP-65 read and NIP-65 write lists: the create takes those three.
    let member = invitee(&[&pool[1]], &[&pool[2]], &[&pool[3]]).await;
    for _ in 0..CREATES {
        let circle = create(&device, vec![member.clone()])
            .await
            .expect("the circle is created");
        assert_eq!(
            circle.relays,
            sorted(&[&pool[5], &pool[6], &pool[7]]),
            "a relay an invitee lists was picked while unlisted ones remained",
        );
    }

    // One unlisted relay remains: it, and two the invitee lists, never the
    // creator's own.
    let device = seeded();
    add(&device, &pool[0], RelayType::Inbox);
    let member = invitee(
        &[&pool[1], &pool[2]],
        &[&pool[3], &pool[4]],
        &[&pool[5], &pool[6]],
    )
    .await;
    for _ in 0..4 {
        let circle = create(&device, vec![member.clone()])
            .await
            .expect("the circle is created");
        assert_eq!(circle.relays.len(), RELAYS_PER_NEW_CIRCLE);
        assert!(
            circle.relays.contains(&pool[7]),
            "the unlisted relay was left out"
        );
        assert!(
            !circle.relays.contains(&pool[0]),
            "the creator's identity relay filled the circle",
        );
    }

    // An invitee whose inbox lists the whole pool has every pool relay take a
    // Welcome, which never names this account's pubkey: a later create still
    // draws from the whole pool. (The first circle names its relays, so no
    // pool relay is this account's circle relay.)
    let device = seeded();
    let everywhere: Vec<&str> = pool.iter().map(String::as_str).collect();
    device
        .circle
        .create_circle(
            &device.keys,
            vec![invitee(&everywhere, &[], &[]).await],
            &CircleConfig::new("Named").with_relays(owned(&[INVITEE_INBOX])),
        )
        .await
        .expect("the circle is created");
    let circle = create(&device, Vec::new())
        .await
        .expect("a create after those Welcomes still finds relays");
    assert_eq!(circle.relays.len(), RELAYS_PER_NEW_CIRCLE);
}

#[tokio::test]
async fn create_is_refused_when_the_accounts_own_lists_cover_the_whole_pool() {
    let pool = production_location_relays();
    let device = seeded();
    for (i, relay) in pool.iter().enumerate() {
        let category = match i % 3 {
            0 => RelayType::Inbox,
            1 => RelayType::KeyPackage,
            _ => RelayType::Profile,
        };
        add(&device, relay, category);
    }
    let ledger = device
        .circle
        .list_contaminated_relays()
        .expect("the ledger");
    let refused = create(&device, vec![invitee(&[INVITEE_INBOX], &[], &[]).await])
        .await
        .expect_err("no pool relay is left");
    assert!(matches!(refused, CircleError::NoLocationRelay));
    assert!(device
        .circle
        .get_circles()
        .await
        .expect("the circles")
        .is_empty());
    assert!(device
        .session()
        .live_group_ids()
        .await
        .expect("the groups")
        .is_empty());
    assert_eq!(
        device
            .circle
            .list_contaminated_relays()
            .expect("the ledger"),
        ledger,
        "a refused create recorded a relay",
    );
    // Never answered with the whole pool or the account seed: relays the
    // caller names are still the circle's.
    let named = device
        .circle
        .create_circle(
            &device.keys,
            vec![invitee(&[INVITEE_INBOX], &[], &[]).await],
            &CircleConfig::new("Named").with_relays(owned(&[INVITEE_INBOX])),
        )
        .await
        .expect("a create naming its relays")
        .circle;
    assert_eq!(named.relays, owned(&[INVITEE_INBOX]));
}

#[tokio::test]
async fn a_picked_circle_relay_never_reaches_a_log_line() {
    let pool = production_location_relays();
    let lines = helpers::capture_haven_log_here(async {
        let device = seeded();
        for _ in 0..3 {
            create(&device, vec![invitee(&[INVITEE_INBOX], &[], &[]).await])
                .await
                .expect("the circle is created");
        }
        let covered = seeded();
        for relay in &pool {
            add(&covered, relay, RelayType::Inbox);
        }
        assert!(matches!(
            create(&covered, Vec::new()).await,
            Err(CircleError::NoLocationRelay)
        ));
    })
    .await;
    helpers::assert_some_line_from(&lines, "haven_core");
    let hosts: Vec<&str> = pool
        .iter()
        .map(|relay| relay.trim_start_matches("wss://"))
        .collect();
    let needles: Vec<&str> = pool.iter().map(String::as_str).chain(hosts).collect();
    helpers::assert_no_needles(&lines, &needles);
}
