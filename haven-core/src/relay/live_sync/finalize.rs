//! The foreground SEND-path convergence orchestration (M6, path A).
//!
//! When the live-sync engine is running, the foreground finalize sites
//! (self-update, add/remove members) must NOT eagerly merge their own commit —
//! two members committing from the same epoch N would each merge their own and
//! fork (the `eager_finalize_then_exchange` bug). Instead they run a
//! *settle-window* convergence, serialized against the always-on engine's MLS
//! writes by the per-circle [`MlsWriteGate`](super::gate::MlsWriteGate):
//!
//! 1. **CS1** ([`LiveSyncCore::stage_self_update_converging`] et al.) — under
//!    the gate: read the staged epoch, OPEN a settle window (so the engine
//!    buffers same-epoch sibling commits instead of blind-applying them — see
//!    [`super::processor`]), then STAGE the pending commit. Returns the commit
//!    JSON + the staged epoch.
//! 2. The caller PUBLISHES the commit (during the window, unconditionally — a
//!    losing commit is harmlessly dropped by peers; see
//!    [`crate::circle::CircleManager::converge_commit`] "Publication ordering"),
//!    then waits [`COMMIT_SETTLE_WINDOW_SECS`].
//! 3. **CS2** ([`LiveSyncCore::converge_after_window`]) — under the gate: TAKE
//!    the buffered competitors and run [`CircleManager::converge_commit`], which
//!    merges ours if we won or adopts the MIP-03 winner if we lost. The gate is
//!    held across take→converge so the engine cannot blind-apply a sibling in
//!    the gap between the window closing and our epoch advancing.
//!
//! On a publish failure between CS1 and CS2 the caller runs
//! [`LiveSyncCore::abort_converging_window`] (clear the pending commit + close
//! the window) so a half-finalized circle is never left in regime 2 forever.
//!
//! # Locking discipline
//!
//! Every critical section holds `gate.for_group(hex).lock().await` (a tokio
//! mutex — fine to hold across `.await`). The settle buffer is a `std::Mutex`;
//! its guard is ALWAYS taken inside a `{ }` block that contains NO `.await`
//! (else the future would be non-`Send` / trip `await_holding_lock`), and is
//! recovered with `PoisonError::into_inner` (never `.unwrap()`) so a panic
//! cannot brick every future converge. The lock order is uniformly
//! gate → settle, matching [`super::supervisor::run_worker`], so no inversion
//! exists.
//!
//! The window/gate are keyed by `hex(nostr_group_id)` — the `#h` routing key the
//! engine processor uses — NOT the MLS group id. Callers pass both: the MLS
//! group id for the `CircleManager` operations and the `nostr_group_id` for the
//! gate/settle key (the foreground sites have both from the `Circle`).

use std::sync::{Mutex, PoisonError};

use nostr::{Event, JsonUtil, Keys};

use crate::circle::{
    CircleManager, CommitConvergence, CommitIntent, GiftWrappedWelcome, MemberKeyPackage,
};
use crate::nostr::mls::types::GroupId;

use super::config::COMMIT_SETTLE_WINDOW_SECS;
use super::error::{LiveSyncError, LiveSyncResult};
use super::gate::MlsWriteGate;
use super::session::LiveSyncCore;
use super::settle::CommitSettleBuffer;

/// A staged commit awaiting publication + convergence (self-update / remove).
///
/// `Debug` is presence-only: `commit_json` is a `kind:445` whose `h` tag carries
/// the `nostr_group_id`, so it is redacted (Security Rule 4/8).
pub struct StagedCommit {
    /// The staged commit `kind:445` JSON — the caller publishes it during the
    /// window, then passes it back to [`LiveSyncCore::converge_after_window`].
    pub commit_json: String,
    /// The epoch the commit was built from (the window's staged epoch).
    pub staged_epoch: u64,
}

impl std::fmt::Debug for StagedCommit {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("StagedCommit")
            .field("commit_json", &"<redacted>")
            .field("staged_epoch", &self.staged_epoch)
            .finish()
    }
}

/// A staged Add commit + the gift-wrapped Welcomes for the new members.
///
/// The caller publishes [`Self::welcome_events`] ONLY after the convergence
/// returns [`CommitConvergence::Merged`] — Welcomes for a losing Add reference
/// an epoch that never committed and would strand the invitee.
///
/// `Debug` is presence-only (commit JSON + welcome payloads redacted).
pub struct StagedAdd {
    /// The staged Add commit `kind:445` JSON.
    pub commit_json: String,
    /// The epoch the commit was built from.
    pub staged_epoch: u64,
    /// Gift-wrapped Welcomes — publish only after a `Merged` convergence.
    pub welcome_events: Vec<GiftWrappedWelcome>,
}

impl std::fmt::Debug for StagedAdd {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("StagedAdd")
            .field("commit_json", &"<redacted>")
            .field("staged_epoch", &self.staged_epoch)
            .field("welcome_events_count", &self.welcome_events.len())
            .finish()
    }
}

impl LiveSyncCore {
    /// CS1 (self-update): open the settle window + stage a self-update commit.
    ///
    /// # Errors
    ///
    /// Returns [`LiveSyncError::Mls`] if reading the epoch or staging fails.
    pub async fn stage_self_update_converging(
        &self,
        mls_group_id: &GroupId,
        nostr_group_id: &[u8],
    ) -> LiveSyncResult<StagedCommit> {
        let hex = hex::encode(nostr_group_id);
        let gate = self.gate().for_group(&hex);
        let _guard = gate.lock().await;
        let staged_epoch = self
            .circle()
            .group_epoch_internal(mls_group_id)
            .map_err(LiveSyncError::mls)?;
        self.open_settle_window_locked(&hex, staged_epoch);
        let result = self
            .circle()
            .self_update(mls_group_id)
            .map_err(LiveSyncError::mls)?;
        Ok(StagedCommit {
            commit_json: result.evolution_event.as_json(),
            staged_epoch,
        })
    }

    /// CS1 (remove members): open the settle window + stage a Remove commit.
    ///
    /// # Errors
    ///
    /// Returns [`LiveSyncError::Mls`] if reading the epoch or staging fails.
    pub async fn stage_remove_members_converging(
        &self,
        mls_group_id: &GroupId,
        nostr_group_id: &[u8],
        member_pubkeys: &[String],
    ) -> LiveSyncResult<StagedCommit> {
        let hex = hex::encode(nostr_group_id);
        let gate = self.gate().for_group(&hex);
        let _guard = gate.lock().await;
        let staged_epoch = self
            .circle()
            .group_epoch_internal(mls_group_id)
            .map_err(LiveSyncError::mls)?;
        self.open_settle_window_locked(&hex, staged_epoch);
        let result = self
            .circle()
            .remove_members(mls_group_id, member_pubkeys)
            .map_err(LiveSyncError::mls)?;
        Ok(StagedCommit {
            commit_json: result.evolution_event.as_json(),
            staged_epoch,
        })
    }

    /// CS1 (add members): open the settle window + stage an Add commit and build
    /// its gift-wrapped Welcomes.
    ///
    /// # Errors
    ///
    /// Returns [`LiveSyncError::Mls`] if reading the epoch, staging, or
    /// gift-wrapping fails.
    pub async fn stage_add_members_converging(
        &self,
        sender_keys: &Keys,
        mls_group_id: &GroupId,
        nostr_group_id: &[u8],
        members: Vec<MemberKeyPackage>,
        fallback_relays: &[String],
    ) -> LiveSyncResult<StagedAdd> {
        let hex = hex::encode(nostr_group_id);
        let gate = self.gate().for_group(&hex);
        let _guard = gate.lock().await;
        let staged_epoch = self
            .circle()
            .group_epoch_internal(mls_group_id)
            .map_err(LiveSyncError::mls)?;
        self.open_settle_window_locked(&hex, staged_epoch);
        // `add_members_with_welcomes` is genuinely async; the settle guard is
        // already dropped (inside `open_settle_window_locked`), so only the tokio
        // gate guard is held across this `.await` — never the std settle guard.
        let result = self
            .circle()
            .add_members_with_welcomes(sender_keys, mls_group_id, members, fallback_relays)
            .await
            .map_err(LiveSyncError::mls)?;
        Ok(StagedAdd {
            commit_json: result.evolution_event.as_json(),
            staged_epoch,
            welcome_events: result.welcome_events,
        })
    }

    /// CS2: take the buffered competitors and converge the staged commit.
    ///
    /// Holds the gate across `take_competitors → converge_commit → close_window`
    /// so the engine cannot blind-apply a sibling between the window closing and
    /// our epoch advancing. `our_commit_json` is the JSON returned by CS1 (the
    /// caller already published it). A competitor whose JSON cannot be re-parsed
    /// is surfaced as a hard error — never silently dropped, since dropping the
    /// MIP-03 winner would degrade convergence to the eager-merge fork leg.
    ///
    /// # Errors
    ///
    /// Returns [`LiveSyncError::Mls`] if the staged commit JSON is invalid or
    /// convergence fails, or [`LiveSyncError::InvalidCompetitor`] if a buffered
    /// competitor cannot be parsed.
    pub async fn converge_after_window(
        &self,
        mls_group_id: &GroupId,
        nostr_group_id: &[u8],
        our_commit_json: &str,
        staged_epoch: u64,
        intent: &CommitIntent,
    ) -> LiveSyncResult<CommitConvergence> {
        gated_converge(
            self.gate(),
            self.settle(),
            self.circle(),
            mls_group_id,
            nostr_group_id,
            our_commit_json,
            staged_epoch,
            intent,
        )
        .await
    }

    /// Publish-failure cleanup: clear any staged pending commit and close the
    /// settle window, under the gate. Idempotent.
    ///
    /// Call this when the publish between CS1 and CS2 fails, OR when
    /// `converge_after_window` itself errors (an unparseable competitor / bad
    /// commit JSON leaves the window open + a pending commit), so the circle is
    /// not left wedged in regime 2.
    ///
    /// # Errors
    ///
    /// Never returns an error today (best-effort); the `Result` is kept for FFI
    /// uniformity and future-proofing.
    pub async fn abort_converging_window(
        &self,
        mls_group_id: &GroupId,
        nostr_group_id: &[u8],
    ) -> LiveSyncResult<()> {
        gated_abort(
            self.gate(),
            self.settle(),
            self.circle(),
            mls_group_id,
            nostr_group_id,
        )
        .await;
        Ok(())
    }

    /// The configured settle-window duration (seconds) the caller waits between
    /// CS1 and CS2.
    #[must_use]
    pub const fn settle_window_secs() -> u64 {
        COMMIT_SETTLE_WINDOW_SECS
    }

    /// Opens (or re-opens) the settle window for `hex` (carrying forward any
    /// displaced competitors). The caller MUST already hold `gate.for_group(hex)`.
    fn open_settle_window_locked(&self, hex: &str, staged_epoch: u64) {
        open_window_carrying_displaced(self.settle(), hex, staged_epoch);
    }
}

/// The settle-window deadline (unix ms) = now + [`COMMIT_SETTLE_WINDOW_SECS`].
fn settle_deadline_ms() -> i64 {
    let now_ms = i64::try_from(nostr::Timestamp::now().as_secs())
        .unwrap_or(i64::MAX)
        .saturating_mul(1000);
    let window_ms = i64::try_from(COMMIT_SETTLE_WINDOW_SECS)
        .unwrap_or(i64::MAX)
        .saturating_mul(1000);
    now_ms.saturating_add(window_ms)
}

/// Opens (or re-opens) the settle window for `hex`, carrying forward any
/// competitors displaced from a still-open prior window (a re-stage at the same
/// epoch) so a competing commit is never lost. The caller MUST already hold the
/// per-circle gate. Holds the settle `std::Mutex` only within this synchronous
/// body (no `.await`), recovering a poisoned lock.
///
/// Shared by the foreground finalize site (CS1) and the engine's path-B
/// auto-commit window-open (`EngineProcessor::process_group_event`).
pub(crate) fn open_window_carrying_displaced(
    settle: &Mutex<CommitSettleBuffer>,
    hex: &str,
    staged_epoch: u64,
) {
    let deadline_ms = settle_deadline_ms();
    let mut sb = settle.lock().unwrap_or_else(PoisonError::into_inner);
    let displaced = sb.begin_window(hex, staged_epoch, deadline_ms);
    for c in displaced {
        // Re-insert under the same staged epoch; insert_competitor dedupes by id
        // and bounds the set, so this is safe and lossless.
        sb.insert_competitor(hex, c, staged_epoch);
    }
}

/// CS2 convergence under the per-circle gate, shared by the foreground finalize
/// site ([`LiveSyncCore::converge_after_window`]) and the engine's path-B
/// auto-commit converge task.
///
/// Holds the gate across `take_competitors → converge_commit → close_window` so
/// the engine cannot blind-apply a sibling between the window closing and our
/// epoch advancing. A competitor whose JSON cannot be re-parsed is surfaced as a
/// hard error — never silently dropped, since dropping the MIP-03 winner would
/// degrade convergence to the eager-merge fork leg.
///
/// # Errors
///
/// [`LiveSyncError::Mls`] if the staged commit JSON is invalid or convergence
/// fails; [`LiveSyncError::InvalidCompetitor`] if a buffered competitor cannot be
/// parsed.
// The gate/settle/circle triple + the per-commit inputs are all genuinely needed
// at one call boundary; bundling them would only relocate the parameter list.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn gated_converge(
    gate: &MlsWriteGate,
    settle: &Mutex<CommitSettleBuffer>,
    circle: &CircleManager,
    mls_group_id: &GroupId,
    nostr_group_id: &[u8],
    our_commit_json: &str,
    staged_epoch: u64,
    intent: &CommitIntent,
) -> LiveSyncResult<CommitConvergence> {
    let hex = hex::encode(nostr_group_id);
    let our_commit = Event::from_json(our_commit_json).map_err(LiveSyncError::mls)?;

    let lock = gate.for_group(&hex);
    let _guard = lock.lock().await;

    let competitors_raw = {
        let mut sb = settle.lock().unwrap_or_else(PoisonError::into_inner);
        sb.take_competitors(&hex, staged_epoch)
    };
    // Fail closed on an unparseable competitor (defensive — buffered events
    // arrived through the validating client, so this should be unreachable).
    let mut competitors = Vec::with_capacity(competitors_raw.len());
    for c in &competitors_raw {
        let event =
            Event::from_json(&c.event_json).map_err(|_| LiveSyncError::InvalidCompetitor)?;
        competitors.push(event);
    }

    let result = circle
        .converge_commit(
            mls_group_id,
            &our_commit,
            staged_epoch,
            &competitors,
            intent,
        )
        .map_err(LiveSyncError::mls)?;

    {
        let mut sb = settle.lock().unwrap_or_else(PoisonError::into_inner);
        sb.close_window(&hex); // defensive: take_competitors already removed it on a match
    }
    Ok(result)
}

/// Abort/cleanup under the per-circle gate: clear any staged pending commit +
/// close the settle window (idempotent). Shared by the foreground publish-failure
/// path and the engine's path-B publish-failure / converge-error path.
pub(crate) async fn gated_abort(
    gate: &MlsWriteGate,
    settle: &Mutex<CommitSettleBuffer>,
    circle: &CircleManager,
    mls_group_id: &GroupId,
    nostr_group_id: &[u8],
) {
    let hex = hex::encode(nostr_group_id);
    let lock = gate.for_group(&hex);
    let _guard = lock.lock().await;
    let _ = circle.clear_pending_commit(mls_group_id);
    {
        let mut sb = settle.lock().unwrap_or_else(PoisonError::into_inner);
        sb.close_window(&hex);
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::time::Duration;

    use nostr::{EventBuilder, Keys, Kind, Tag, Timestamp};
    use tempfile::TempDir;

    use crate::circle::{CircleConfig, CircleManager, CommitConvergence, CommitIntent};
    use crate::relay::live_sync::settle::BufferedCommit;
    use crate::relay::live_sync::LiveSyncCore;

    use super::*;

    /// A live-sync engine over a freshly-created single-admin circle, plus the
    /// circle's ids — enough to exercise the full stage → converge orchestration
    /// over a REAL MLS group without the network.
    struct Fixture {
        core: LiveSyncCore,
        mls_group_id: GroupId,
        nostr_group_id: [u8; 32],
        _dir: TempDir,
    }

    impl Fixture {
        fn hex(&self) -> String {
            hex::encode(self.nostr_group_id)
        }

        fn has_window(&self) -> bool {
            self.core
                .settle()
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .has_window(&self.hex())
        }

        fn epoch(&self) -> u64 {
            self.core
                .circle()
                .group_epoch_internal(&self.mls_group_id)
                .unwrap()
        }
    }

    /// Builds a member key package via the PUBLIC key-package API (a throwaway
    /// manager the member never joins from), for `create_circle`.
    fn make_member() -> MemberKeyPackage {
        let kp_relays = vec!["wss://kp.example.com".to_string()];
        let member_keys = Keys::generate();
        let kp_dir = TempDir::new().unwrap();
        let kp_manager = CircleManager::new_unencrypted(kp_dir.path()).unwrap();
        let bundle = kp_manager
            .create_key_package(&member_keys.public_key().to_hex(), &kp_relays)
            .expect("create member key package");
        let tags: Vec<Tag> = bundle
            .tags_443
            .into_iter()
            .map(|t| Tag::parse(&t).unwrap())
            .collect();
        let kp_event = EventBuilder::new(Kind::MlsKeyPackage, bundle.content)
            .tags(tags)
            .sign_with_keys(&member_keys)
            .expect("sign member key package");
        MemberKeyPackage {
            key_package_event: kp_event,
            inbox_relays: vec!["wss://member-inbox.example.com".to_string()],
            nip65_relays: vec![],
        }
    }

    async fn setup_solo_circle() -> Fixture {
        let dir = TempDir::new().unwrap();
        let alice = CircleManager::new_unencrypted(dir.path()).unwrap();
        let alice_keys = Keys::generate();
        let config = CircleConfig::new("Finalize Test Circle")
            .with_relays(vec!["wss://group.example.com".to_string()]);
        let result = alice
            .create_circle(&alice_keys, vec![make_member()], &config, &[])
            .await
            .expect("create circle");
        let mls_group_id = result.circle.mls_group_id.clone();
        let nostr_group_id = result.circle.nostr_group_id;
        let core = LiveSyncCore::new_local(Arc::new(alice), alice_keys.public_key());
        Fixture {
            core,
            mls_group_id,
            nostr_group_id,
            _dir: dir,
        }
    }

    /// A synthetic, validly-signed kind:445 at a chosen `created_at` — a stand-in
    /// "competitor" event (NOT a real commit for this group) for exercising the
    /// take→parse→converge plumbing. Inserted directly into the buffer, so no
    /// routing tag is needed.
    fn synthetic_competitor(_nostr_group_id: &[u8; 32], created_at_secs: u64) -> BufferedCommit {
        let event = EventBuilder::new(Kind::Custom(445), "opaque")
            .custom_created_at(Timestamp::from(created_at_secs))
            .sign_with_keys(&Keys::generate())
            .unwrap();
        BufferedCommit {
            event_json: event.as_json(),
            created_at_secs,
            id_hex: event.id.to_hex(),
        }
    }

    #[test]
    fn settle_window_secs_returns_the_config_const() {
        assert_eq!(
            LiveSyncCore::settle_window_secs(),
            COMMIT_SETTLE_WINDOW_SECS
        );
    }

    #[tokio::test]
    async fn stage_self_update_opens_a_window_and_converge_merges_and_closes() {
        let fx = setup_solo_circle().await;
        let epoch_before = fx.epoch();

        let staged = fx
            .core
            .stage_self_update_converging(&fx.mls_group_id, &fx.nostr_group_id)
            .await
            .expect("stage self-update");
        assert_eq!(staged.staged_epoch, epoch_before);
        assert!(fx.has_window(), "CS1 must open the settle window");
        assert!(!staged.commit_json.is_empty());

        let result = fx
            .core
            .converge_after_window(
                &fx.mls_group_id,
                &fx.nostr_group_id,
                &staged.commit_json,
                staged.staged_epoch,
                &CommitIntent::None,
            )
            .await
            .expect("converge");
        assert_eq!(
            result,
            CommitConvergence::Merged,
            "no competitors ⇒ our commit merges"
        );
        assert!(!fx.has_window(), "CS2 must close the window");
        assert!(
            fx.epoch() > epoch_before,
            "a merged self-update advances the epoch"
        );
    }

    #[tokio::test]
    async fn converge_with_a_later_competitor_still_merges_ours() {
        // A competitor with a LATER created_at loses the MIP-03 order key, so
        // our commit wins → Merged. Proves take→parse→pass-to-converge plumbing.
        let fx = setup_solo_circle().await;
        let staged = fx
            .core
            .stage_self_update_converging(&fx.mls_group_id, &fx.nostr_group_id)
            .await
            .unwrap();
        {
            let mut sb = fx
                .core
                .settle()
                .lock()
                .unwrap_or_else(PoisonError::into_inner);
            // created_at far in the future ⇒ loses to ours.
            let c = synthetic_competitor(&fx.nostr_group_id, 4_000_000_000);
            assert!(sb.insert_competitor(&fx.hex(), c, staged.staged_epoch));
        }
        let result = fx
            .core
            .converge_after_window(
                &fx.mls_group_id,
                &fx.nostr_group_id,
                &staged.commit_json,
                staged.staged_epoch,
                &CommitIntent::None,
            )
            .await
            .unwrap();
        assert_eq!(result, CommitConvergence::Merged);
        assert!(!fx.has_window());
    }

    #[tokio::test]
    async fn converge_with_a_winning_non_commit_competitor_rolls_back_without_forking() {
        // Decision C: a competitor that wins the order key but is NOT a real
        // commit (a stray Location, here a synthetic event) cannot advance the
        // epoch, so converge_commit cleanly RolledBack — no fork, no dangle.
        let fx = setup_solo_circle().await;
        let epoch_before = fx.epoch();
        let staged = fx
            .core
            .stage_self_update_converging(&fx.mls_group_id, &fx.nostr_group_id)
            .await
            .unwrap();
        {
            let mut sb = fx
                .core
                .settle()
                .lock()
                .unwrap_or_else(PoisonError::into_inner);
            // created_at = 1 ⇒ wins the order key over our real commit.
            let c = synthetic_competitor(&fx.nostr_group_id, 1);
            assert!(sb.insert_competitor(&fx.hex(), c, staged.staged_epoch));
        }
        let result = fx
            .core
            .converge_after_window(
                &fx.mls_group_id,
                &fx.nostr_group_id,
                &staged.commit_json,
                staged.staged_epoch,
                &CommitIntent::None,
            )
            .await
            .unwrap();
        assert_eq!(
            result,
            CommitConvergence::RolledBack,
            "a non-commit order-key winner must roll back, not fork"
        );
        assert_eq!(
            fx.epoch(),
            epoch_before,
            "a rolled-back convergence leaves the epoch unchanged"
        );
        assert!(!fx.has_window());
    }

    #[tokio::test]
    async fn converge_fails_closed_on_an_unparseable_competitor() {
        // A buffered competitor whose JSON cannot be parsed must be a HARD error
        // (never a silent drop, which could drop the winner → fork).
        let fx = setup_solo_circle().await;
        let staged = fx
            .core
            .stage_self_update_converging(&fx.mls_group_id, &fx.nostr_group_id)
            .await
            .unwrap();
        {
            let mut sb = fx
                .core
                .settle()
                .lock()
                .unwrap_or_else(PoisonError::into_inner);
            let garbage = BufferedCommit {
                event_json: "not json".to_string(),
                created_at_secs: 10,
                id_hex: "deadbeef".to_string(),
            };
            assert!(sb.insert_competitor(&fx.hex(), garbage, staged.staged_epoch));
        }
        let err = fx
            .core
            .converge_after_window(
                &fx.mls_group_id,
                &fx.nostr_group_id,
                &staged.commit_json,
                staged.staged_epoch,
                &CommitIntent::None,
            )
            .await
            .expect_err("unparseable competitor must hard-error");
        assert!(matches!(err, LiveSyncError::InvalidCompetitor));
    }

    #[tokio::test]
    async fn open_window_carries_forward_displaced_competitors() {
        // Decision E: re-opening a still-open window (a re-stage at the same
        // epoch) must NOT drop the prior window's buffered competitors.
        let fx = setup_solo_circle().await;
        let hex = fx.hex();
        let epoch = 5;
        {
            let mut sb = fx
                .core
                .settle()
                .lock()
                .unwrap_or_else(PoisonError::into_inner);
            let displaced = sb.begin_window(&hex, epoch, 1_000);
            assert!(displaced.is_empty());
            assert!(sb.insert_competitor(
                &hex,
                synthetic_competitor(&fx.nostr_group_id, 100),
                epoch
            ));
        }
        // Re-open at the same epoch via the orchestration helper.
        fx.core.open_settle_window_locked(&hex, epoch);
        let count = fx
            .core
            .settle()
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .competitor_count(&hex);
        assert_eq!(count, 1, "the displaced competitor must be carried forward");
    }

    #[tokio::test]
    async fn abort_clears_pending_and_closes_the_window() {
        let fx = setup_solo_circle().await;
        let epoch_before = fx.epoch();
        let _staged = fx
            .core
            .stage_self_update_converging(&fx.mls_group_id, &fx.nostr_group_id)
            .await
            .unwrap();
        assert!(fx.has_window());

        fx.core
            .abort_converging_window(&fx.mls_group_id, &fx.nostr_group_id)
            .await
            .unwrap();
        assert!(!fx.has_window(), "abort must close the window");
        assert_eq!(
            fx.epoch(),
            epoch_before,
            "abort must clear the staged pending commit (epoch unchanged)"
        );
    }

    #[tokio::test]
    async fn the_finalize_path_contends_the_engine_per_circle_gate() {
        // The foreground orchestration MUST acquire the SAME per-circle gate the
        // engine worker holds, so the two MDK writers serialize. Hold the gate
        // and assert a finalize op blocks until it is released.
        let fx = setup_solo_circle().await;
        let hex = fx.hex();
        let gate = fx.core.gate().for_group(&hex);
        let guard = gate.lock().await;

        let blocked = tokio::time::timeout(
            Duration::from_millis(200),
            fx.core
                .abort_converging_window(&fx.mls_group_id, &fx.nostr_group_id),
        )
        .await;
        assert!(
            blocked.is_err(),
            "a finalize op must block while the per-circle gate is held by the engine"
        );

        drop(guard);
        // Now it proceeds.
        fx.core
            .abort_converging_window(&fx.mls_group_id, &fx.nostr_group_id)
            .await
            .unwrap();
    }
}
