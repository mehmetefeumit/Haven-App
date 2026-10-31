//! The debug-only location-pool override is what a create that names no relays
//! draws from, and it is not a bypass: an installed entry is still subject to
//! the account's identity exclusion, the invitees' soft exclusion and the
//! public-host rule a relay named to other members must meet.
//!
//! One install per process, so one test per binary (`profile_relay_override_*`
//! follow the same rule). Every host is under `.invalid`, which never
//! resolves, or a non-public literal the pick refuses, so nothing is dialled.

mod helpers;

use haven_core::circle::{
    set_location_relays_for_test, Circle, CircleConfig, CircleError, MemberKeyPackage, RelayType,
};
use haven_core::location::LocationMessage;
use helpers::{create_key_package_event, CircleMember};

const LOC_A: &str = "wss://loc-a.invalid";
const LOC_B: &str = "wss://loc-b.invalid";
const LOC_C: &str = "wss://loc-c.invalid";
const LOC_D: &str = "wss://loc-d.invalid";

/// The override as installed: the four public entries, one spelled twice, and
/// entries on hosts no member may be told to dial.
const INSTALLED: [&str; 9] = [
    LOC_A,
    "wss://LOC-B.invalid/",
    "wss://192.168.1.1",
    "wss://localhost",
    LOC_C,
    "wss://[::1]",
    LOC_D,
    "wss://10.0.0.1",
    "wss://loc-a.invalid:443",
];

/// What no log line may carry: every installed URL and host.
const NEEDLES: [&str; 13] = [
    LOC_A,
    LOC_B,
    LOC_C,
    LOC_D,
    "loc-a.invalid",
    "loc-b.invalid",
    "loc-c.invalid",
    "loc-d.invalid",
    "wss://192.168.1.1",
    "192.168.1.1",
    "localhost",
    "[::1]",
    "10.0.0.1",
];

const INVITEE_INBOX: &str = "wss://invitee-inbox.invalid";

fn owned(relays: &[&str]) -> Vec<String> {
    relays.iter().map(ToString::to_string).collect()
}

async fn invitee(inbox: &[&str], write: &[&str]) -> MemberKeyPackage {
    let member = CircleMember::new();
    MemberKeyPackage {
        key_package_event: create_key_package_event(
            member.session(),
            &member.keys,
            &owned(&[INVITEE_INBOX]),
        )
        .await,
        inbox_relays: owned(inbox),
        nip65_relays: Vec::new(),
        nip65_write_relays: owned(write),
    }
}

async fn create(
    device: &CircleMember,
    members: Vec<MemberKeyPackage>,
) -> Result<Circle, CircleError> {
    device
        .circle
        .create_circle(&device.keys, members, &CircleConfig::new("Override"))
        .await
        .map(|created| created.circle)
}

fn add(device: &CircleMember, relay: &str, category: RelayType) {
    device
        .circle
        .add_user_relay(relay, category)
        .expect("the relay is stored");
}

#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn installed_override_reaches_the_pick_and_stays_subject_to_exclusion_and_the_host_rule() {
    set_location_relays_for_test(owned(&INSTALLED)).expect("the override installs");
    assert!(
        set_location_relays_for_test(owned(&[LOC_A])).is_err(),
        "a second install replaced the pool",
    );
    assert!(set_location_relays_for_test(Vec::new()).is_err());
    let public = owned(&[LOC_A, LOC_B, LOC_C, LOC_D]);

    let lines = helpers::capture_haven_log_here(async {
        // The pick draws from the override: three of its public entries, the
        // same three in the routing component and in what a location is
        // frozen for.
        let device = CircleMember::new();
        for _ in 0..8 {
            let circle = create(&device, Vec::new())
                .await
                .expect("the circle is created");
            assert_eq!(circle.relays.len(), 3);
            for relay in &circle.relays {
                assert!(
                    public.contains(relay),
                    "a non-public override entry was picked"
                );
            }
            assert_eq!(
                device
                    .session()
                    .group_relays(&circle.mls_group_id)
                    .await
                    .expect("the routing component is read"),
                circle.relays,
            );
            let mut targets = device
                .circle
                .seal_location_for_test(&circle.mls_group_id, &LocationMessage::new(1.0, 2.0))
                .await
                .expect("the location is sealed")
                .2;
            targets.sort();
            assert_eq!(
                targets, circle.relays,
                "a location was frozen for other relays"
            );
        }

        // The identity exclusion holds over the override.
        let other = CircleMember::new();
        add(&other, LOC_A, RelayType::Inbox);
        add(&other, "wss://loc-b.invalid/inbox", RelayType::Inbox);
        add(&other, LOC_C, RelayType::Profile);
        let circle = create(&other, Vec::new())
            .await
            .expect("the circle is created");
        assert_eq!(circle.relays, owned(&[LOC_D]));
        add(&other, LOC_D, RelayType::KeyPackage);
        assert!(matches!(
            create(&other, vec![invitee(&[INVITEE_INBOX], &[]).await]).await,
            Err(CircleError::NoLocationRelay)
        ));
        assert_eq!(
            other.circle.get_circles().await.expect("the circles").len(),
            1,
            "a refused create stored a circle",
        );

        // And the invitees' soft exclusion: two unlisted entries are always
        // taken, and the third fills from what the invitee lists.
        let third = CircleMember::new();
        for _ in 0..8 {
            let circle = create(&third, vec![invitee(&[LOC_A], &[LOC_B]).await])
                .await
                .expect("the circle is created");
            assert_eq!(circle.relays.len(), 3);
            assert!(
                circle.relays.contains(&LOC_C.to_string())
                    && circle.relays.contains(&LOC_D.to_string()),
                "an invitee's relay was picked while unlisted ones remained",
            );
        }
    })
    .await;
    helpers::assert_some_line_from(&lines, "haven_core");
    helpers::assert_no_needles(&lines, &NEEDLES);
}
