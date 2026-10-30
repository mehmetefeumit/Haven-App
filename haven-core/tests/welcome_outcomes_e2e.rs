//! What accepting a Welcome can answer at MDK v0.10.4, end to end.
//!
//! MDK turns every terminal Welcome failure into an `Ignored` outcome rather
//! than an error, and a Welcome that would replace a group this device still
//! holds into `RejoinConfirmationRequired` (`cgka-engine/src/message_processor/ingest.rs:282-341`).
//! Haven must answer each with a typed outcome the UI can route on, never a
//! generic failure that leaves the invitation stuck.

mod helpers;

use haven_core::nostr::mls::types::{PublishWork, WelcomeAcceptance};
use haven_core::nostr::mls::SessionManager;

use helpers::{create_key_package_event, setup_two_party_group_capturing_welcome};

/// The one staged group evolution in `work`, with its Welcomes.
fn evolution(
    work: &[PublishWork],
) -> (
    nostr::Event,
    Vec<nostr::Event>,
    haven_core::nostr::mls::types::PendingStateRef,
) {
    work.iter()
        .find_map(|work| match work {
            PublishWork::GroupEvolution {
                msg,
                welcomes,
                pending,
            } => Some((
                SessionManager::transport_message_to_event(msg).expect("commit event"),
                welcomes
                    .iter()
                    .map(|w| SessionManager::transport_message_to_event(w).expect("welcome"))
                    .collect(),
                *pending,
            )),
            _ => None,
        })
        .expect("one group evolution")
}

/// A repeat of a Welcome this device already processed names the group it
/// joined while the device still holds it — an accept whose circle rows never
/// committed, which Haven records instead of asking for a new invite — and is
/// terminal once the device no longer does.
#[tokio::test]
async fn a_repeated_welcome_names_its_group_while_held_and_is_terminal_once_left() {
    let g = setup_two_party_group_capturing_welcome("welcome_twice").await;
    let tp = &g.group;
    match tp.bob.accept_welcome(&g.bob_welcome_gift_wrap).await {
        Ok(WelcomeAcceptance::AlreadyJoined { group_id, .. }) => assert_eq!(
            group_id, tp.group_id,
            "the repeat names the group the first accept joined"
        ),
        other => panic!("a repeat of a held join is not a dead invitation: {other:?}"),
    }

    let removal = tp
        .alice
        .remove_members(&tp.group_id, &[tp.bob_keys.public_key().to_hex()])
        .await
        .expect("alice removes bob");
    let (commit, _, pending) = evolution(&removal.publish);
    tp.alice.confirm_published(pending).await.expect("confirm");
    tp.bob
        .process_event(&commit)
        .await
        .expect("bob sees his removal");
    tp.bob
        .settle_receive_for_test(&tp.group_id)
        .await
        .expect("bob applies it");
    assert!(
        !tp.bob.group_is_live(&tp.group_id).await,
        "precondition: bob no longer holds the group"
    );

    assert!(
        matches!(
            tp.bob.accept_welcome(&g.bob_welcome_gift_wrap).await,
            Ok(WelcomeAcceptance::NeedsNewInvite)
        ),
        "once the group is gone, only a new invitation can add this device"
    );
    g.cleanup();
}

/// MDK asks for explicit consent before a Welcome replaces a group this device
/// still holds (`cgka-engine/src/group_lifecycle.rs:1172-1197`): here Bob never
/// saw his removal, so his copy still lists him, and the new Welcome would
/// replace it.
#[tokio::test]
async fn a_welcome_for_a_group_this_device_still_holds_waits_for_consent() {
    let g = setup_two_party_group_capturing_welcome("welcome_rejoin").await;
    let tp = &g.group;
    let relays = vec!["wss://relay.test.com".to_string()];

    let removal = tp
        .alice
        .remove_members(&tp.group_id, &[tp.bob_keys.public_key().to_hex()])
        .await
        .expect("alice removes bob");
    let (_, _, pending) = evolution(&removal.publish);
    tp.alice.confirm_published(pending).await.expect("confirm");

    let fresh = create_key_package_event(&tp.bob, &tp.bob_keys, &relays).await;
    let readd = tp
        .alice
        .add_members(
            &tp.group_id,
            vec![SessionManager::key_package_from_event(&fresh).expect("kp")],
        )
        .await
        .expect("alice invites bob back");
    let (_, welcomes, pending) = evolution(&readd.publish);
    tp.alice.confirm_published(pending).await.expect("confirm");

    assert!(
        matches!(
            tp.bob.accept_welcome(&welcomes[0]).await,
            Ok(WelcomeAcceptance::RejoinConfirmationRequired)
        ),
        "a Welcome that would replace a held group waits for the user's consent"
    );
    g.cleanup();
}
