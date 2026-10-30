//! A commit whose publish failed stays unapplied (Security Rule 13).
//!
//! MDK v0.10.4's `publish_failed` rewinds the staged commit but keeps the
//! commit's `Sent` message row, and a later convergence pass selects that row
//! as a candidate edge and merges the commit — locally, with nothing published:
//! this device alone moves to an epoch no peer can reach
//! (`docs/MDK_UPSTREAM_TRACKER.md` T-ROLLBACK-RESURRECT). Haven retires the row
//! when the rewind completes; this pins that no convergence afterwards, however
//! long it is served, brings the commit back.

mod helpers;

use haven_core::nostr::mls::storage::set_stored_message_write_fault_for_test;
use haven_core::nostr::mls::types::{EpochState, PublishWork};
use haven_core::nostr::mls::StorageConfig;
use helpers::{assert_no_needles, capture_haven_log};

#[tokio::test]
async fn a_rolled_back_commit_is_never_merged_by_a_later_convergence() {
    let g = helpers::setup_two_party_group("rewind_stays").await;
    let before = g.alice.epoch(&g.group_id).await.expect("epoch");
    let relays_before = g.alice.group_routing(&g.group_id).await.expect("routing").1;

    let effects = g
        .alice
        .update_relays(
            &g.group_id,
            vec!["wss://never-acked.example.com".to_string()],
        )
        .await
        .expect("alice stages a relay-list commit");
    let pending = effects
        .publish
        .iter()
        .find_map(|work| match work {
            PublishWork::GroupEvolution { pending, .. } => Some(*pending),
            _ => None,
        })
        .expect("a relay-list update stages one group evolution");
    g.alice
        .publish_failed(pending)
        .await
        .expect("no relay acked, so the commit is rolled back");

    // Serve every deadline the engine announces, exactly as a receive plane
    // would, then advance once more for good measure.
    for _ in 0..4 {
        let Some(after) = g.alice.receive_retick_after(&g.group_id).await else {
            break;
        };
        tokio::time::sleep(after).await;
        g.alice
            .advance_convergence(&g.group_id)
            .await
            .expect("advance");
    }
    let last = g
        .alice
        .advance_convergence(&g.group_id)
        .await
        .expect("advance");

    assert_eq!(
        g.alice.epoch(&g.group_id).await.expect("epoch"),
        before,
        "the rolled-back commit must never be merged: no relay has it, so no \
         peer will ever reach the epoch it would move this device to"
    );
    assert_eq!(
        g.alice.group_routing(&g.group_id).await.expect("routing").1,
        relays_before,
        "and its change must not take effect"
    );
    assert!(
        last.events.is_empty() && last.publish.is_empty(),
        "nothing is left for a later advance to apply"
    );
    g.cleanup();
}

/// When the row cannot be retired the rewind still stands, and the failure is
/// reported — by its kind alone.
#[tokio::test]
async fn a_failed_row_retirement_says_so_without_an_identifier() {
    let g = helpers::setup_two_party_group("rewind_log").await;
    let effects = g
        .alice
        .update_relays(
            &g.group_id,
            vec!["wss://never-acked.example.com".to_string()],
        )
        .await
        .expect("alice stages a relay-list commit");
    let pending = effects
        .publish
        .iter()
        .find_map(|work| match work {
            PublishWork::GroupEvolution { pending, .. } => Some(*pending),
            _ => None,
        })
        .expect("a relay-list update stages one group evolution");

    let key = StorageConfig::test_sqlcipher_key().expect("test key");
    let db = StorageConfig::new(&g.alice_dir).database_path();
    set_stored_message_write_fault_for_test(&db, &key, true).expect("arm the write fault");
    let lines = capture_haven_log(async {
        let _ = g.alice.publish_failed(pending).await;
    })
    .await;
    set_stored_message_write_fault_for_test(&db, &key, false).expect("disarm the write fault");

    assert!(
        matches!(
            g.alice.epoch_state(&g.group_id).await,
            Some(EpochState::Stable { .. })
        ),
        "premise: the engine's rewind completed; only Haven's retirement failed"
    );
    let warning = lines
        .iter()
        .find(|line| {
            line.message
                .contains("retiring the rewound commit's row failed")
        })
        .expect("a retirement that failed must be reported, not swallowed");
    assert_no_needles(
        std::slice::from_ref(warning),
        &[
            &hex::encode(g.group_id.as_slice()),
            &hex::encode(g.nostr_group_id),
            &g.alice_keys.public_key().to_hex(),
            &g.bob_keys.public_key().to_hex(),
            "never-acked.example.com",
        ],
    );
    g.cleanup();
}

/// The same promise when the rollback is the fanout driver's: MDK's fanout
/// rollback rewinds the commit and stores the fanout `RolledBack`, and it
/// too leaves the commit's own row `Sent` (v0.10.4 `cgka-engine/src/publish.rs`
/// 371-537). The driver retires that row by the id the fanout names.
#[tokio::test]
async fn a_commit_rolled_back_through_its_fanout_is_never_merged_by_a_later_convergence() {
    use haven_core::relay::fanout::scripted::{Answer, ScriptedFanout};
    use haven_core::relay::fanout::{drive_one, DriveMode, FanoutStatus, WallClock};

    const RELAY: &str = "wss://never-acked.example.com";
    let fx = helpers::setup_circle(2, &[RELAY]).await;
    let session = fx.admin().session();
    let before = session.epoch(&fx.group).await.expect("epoch");
    let relays_before = session.group_relays(&fx.group).await.expect("relays");

    let staged = session
        .update_relays_staging(&fx.group, vec!["wss://moved.example.com".to_string()], 0)
        .await
        .expect("the relay-list commit is staged");
    let [id] = <[_; 1]>::try_from(staged.fanouts)
        .unwrap_or_else(|_| panic!("the call staged exactly one commit"));
    let refusing = ScriptedFanout::default();
    refusing.answer(RELAY, [Answer::Refused]);
    let outcome = drive_one(
        &fx.admin().circle,
        &refusing,
        &WallClock,
        &id,
        &DriveMode::Full,
    )
    .await
    .expect("the drive runs");
    assert_eq!(outcome.status, FanoutStatus::RolledBack);

    for _ in 0..4 {
        let Some(after) = session.receive_retick_after(&fx.group).await else {
            break;
        };
        tokio::time::sleep(after).await;
        session
            .advance_convergence(&fx.group)
            .await
            .expect("advance");
    }
    let last = session
        .advance_convergence(&fx.group)
        .await
        .expect("advance");

    assert_eq!(
        session.epoch(&fx.group).await.expect("epoch"),
        before,
        "the rolled-back commit must never be merged: every relay refused it",
    );
    assert_eq!(
        session.group_relays(&fx.group).await.expect("relays"),
        relays_before,
        "and its change must not take effect"
    );
    assert!(
        last.events.is_empty() && last.publish.is_empty(),
        "nothing is left for a later advance to apply"
    );
}
