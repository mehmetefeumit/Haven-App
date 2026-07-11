//! Out-of-order commit poison (TEST 1, the regression gate) + mixed-shape plain-observer
//! convergence (TEST 2, green) over the FAITHFUL engine receive path.
//!
//! Both tests drive the exact method the live-sync worker calls in **regime 1**
//! (no locally-staged pending commit): [`CircleManager::decrypt_location_for_engine`]
//! (see `relay/live_sync/processor.rs::process_group_event`, the `REGIME 1` arm).
//! That method wraps `MdkManager::process_message_classified` →
//! `mdk_core::process_message`, so it reproduces MDK's persistent dedup /
//! failure-record behaviour byte-for-byte — but SYNCHRONOUSLY, giving
//! deterministic control over arrival order, re-delivery, and on-disk reopen that
//! a full async `LiveSyncCore` + `MockRelay` (relay-replay / cursor / settle-window
//! non-determinism) would obscure. It is also the ONLY faithful seam reachable
//! here: the `mdk` field is crate-private, so an integration-test crate cannot call
//! `mdk.process_message` directly. The circle is built through the PUBLIC circle
//! API (`create_key_package` → `create_circle` → `process_gift_wrapped_invitation`
//! → `accept_invitation`), mirroring
//! `live_sync_two_engine_converge_e2e.rs::build_two_member_circle`.

use haven_core::circle::{CircleConfig, CircleManager, MemberKeyPackage};
use haven_core::location::LocationMessage;
use haven_core::nostr::mls::types::{GroupId, LocationMessageResult};
use nostr::{Event, EventBuilder, Keys, Kind, PublicKey, Tag};
use tempfile::TempDir;

/// A genuine MLS circle: `admin` (creator) + `members`, each with its own on-disk
/// (unencrypted) MLS store. The `TempDir`s are retained so the receiving member's
/// `SQLite` files survive a manager teardown/reopen (TEST 1's restart proof).
struct BuiltCircle {
    admin: CircleManager,
    admin_keys: Keys,
    members: Vec<CircleManager>,
    member_keys: Vec<Keys>,
    mls_group_id: GroupId,
    nostr_group_id: [u8; 32],
    _admin_dir: TempDir,
    member_dirs: Vec<TempDir>,
}

/// Builds Alice (admin) + `num_members` real co-members via the PUBLIC circle API
/// (create → welcome → accept), so every member is a genuine MLS member whose
/// commits peers can decrypt. Generalises
/// `live_sync_two_engine_converge_e2e.rs::build_two_member_circle` to N members and
/// exposes each member's on-disk dir for restart tests.
async fn build_circle(num_members: usize) -> BuiltCircle {
    // Each member: its own store + identity + published key package.
    let mut members = Vec::with_capacity(num_members);
    let mut member_keys = Vec::with_capacity(num_members);
    let mut member_dirs = Vec::with_capacity(num_members);
    let mut member_kps = Vec::with_capacity(num_members);
    for _ in 0..num_members {
        let dir = TempDir::new().unwrap();
        let mgr = CircleManager::new_unencrypted(dir.path()).unwrap();
        let keys = Keys::generate();
        let bundle = mgr
            .create_key_package(
                &keys.public_key().to_hex(),
                &["wss://kp.example.com".to_string()],
            )
            .expect("member key package");
        let tags: Vec<Tag> = bundle
            .tags_443
            .into_iter()
            .map(|t| Tag::parse(&t).unwrap())
            .collect();
        let kp_event = EventBuilder::new(Kind::MlsKeyPackage, bundle.content)
            .tags(tags)
            .sign_with_keys(&keys)
            .expect("sign member key package");
        member_kps.push(MemberKeyPackage {
            key_package_event: kp_event,
            inbox_relays: vec!["wss://member-inbox.example.com".to_string()],
            nip65_relays: vec![],
        });
        members.push(mgr);
        member_keys.push(keys);
        member_dirs.push(dir);
    }

    // Alice: admin, creates the circle including every member.
    let admin_dir = TempDir::new().unwrap();
    let admin = CircleManager::new_unencrypted(admin_dir.path()).unwrap();
    let admin_keys = Keys::generate();
    let config = CircleConfig::new("Out Of Order Commit Circle")
        .with_relays(vec!["wss://group.example.com".to_string()]);
    let result = admin
        .create_circle(&admin_keys, member_kps, &config, &[])
        .await
        .expect("create circle");
    let mls_group_id = result.circle.mls_group_id.clone();
    let nostr_group_id = result.circle.nostr_group_id;

    // Each member joins from its own gift-wrapped welcome (matched by recipient).
    for (mgr, keys) in members.iter().zip(member_keys.iter()) {
        let my_hex = keys.public_key().to_hex();
        let welcome = result
            .welcome_events
            .iter()
            .find(|w| w.recipient_pubkey == my_hex)
            .expect("welcome addressed to this member");
        let invitation = mgr
            .process_gift_wrapped_invitation(keys, &welcome.event)
            .await
            .expect("member processes welcome");
        mgr.accept_invitation(&invitation.mls_group_id)
            .expect("member accepts");
    }

    BuiltCircle {
        admin,
        admin_keys,
        members,
        member_keys,
        mls_group_id,
        nostr_group_id,
        _admin_dir: admin_dir,
        member_dirs,
    }
}

/// Whether `decryptor` can decrypt a fresh Location `encryptor` sends for the
/// group — the sole reliable detector of a TWIN fork (same epoch NUMBER but a
/// different exporter secret). Mirrors `circle/manager.rs::cross_decrypts` and the
/// twin-engine suite's helper.
fn cross_decrypts(
    encryptor: &CircleManager,
    encryptor_pubkey: &PublicKey,
    decryptor: &CircleManager,
    gid: &GroupId,
) -> bool {
    let location = LocationMessage::new(40.12, -74.34);
    let Ok((event, _, _)) = encryptor.encrypt_location(gid, encryptor_pubkey, &location, 300)
    else {
        return false;
    };
    matches!(
        decryptor.decrypt_location(&event),
        Ok(LocationMessageResult::Location { .. })
    )
}

/// The MIP-03 order key `(created_at seconds, lowercase-hex id)` computed off-wire
/// from a published commit — the winner is the global minimum. Byte-for-byte the
/// rule MDK's native `epoch_snapshots::is_better_candidate` applies internally
/// (earliest ts wins; smallest `id.to_hex()` breaks ties), so the winner computed
/// here is the SAME branch MDK's native rollback converges observers onto.
fn order_key(e: &Event) -> (u64, String) {
    (e.created_at.as_secs(), e.id.to_hex())
}

/// The current roster pubkeys (lowercase hex) as `member` sees them.
fn roster_hex(member: &CircleManager, gid: &GroupId) -> Vec<String> {
    member
        .get_members(gid)
        .expect("roster read")
        .into_iter()
        .map(|m| m.pubkey)
        .collect()
}

/// TEST 1 (HEADLINE) — regression GATE for a confirmed Phase-B
/// BLOCKER: the out-of-order-commit MDK sticky-`Unprocessable` poison (now FIXED
/// by `MdkManager::retry_failed_future_epoch_messages`).
///
/// # The bug (verdict: REAL-PRODUCTION-BLOCKER)
///
/// The live engine feeds MDK commits in **relay-arrival order with no `created_at`
/// sort** (`relay/live_sync/processor.rs` → `decrypt_location_for_engine`), unlike
/// the catch-up path which sorts oldest-first (`relay/catchup.rs:189`,
/// `events.sort_by(created_at.then(id))`). So a successor commit can reach a member
/// before its predecessor:
///
/// - Alice, alone, commits `C1` (epoch `N → N+1`) then `C2` (epoch `N+1 → N+2`),
///   finalising each. `C2`'s outer `kind:445` layer is sealed with the epoch-`N+1`
///   exporter secret.
/// - `C2` arrives at Bob while he is still at epoch `N` (before `C1`). Bob lacks
///   the `N+1` exporter secret, so MDK's **outer decrypt fails**
///   (`mdk-core/messages/process.rs`, Step 2) and it writes a **persistent**
///   `processed_messages` row `state = Failed, epoch = NULL`
///   (`record_failure(.., epoch = None)`, `process.rs:449` /
///   `error_handling.rs:57`) — `epoch` is NULL precisely because decryption failed
///   before the message's epoch could be learned.
/// - `C1` later applies normally (`N → N+1`). This is an ordinary forward
///   `process_commit`, **not** an `is_better_candidate` same-epoch rollback, so the
///   ONE site that would rescue the stuck row —
///   `find_failed_messages_for_retry` + `mark_processed_message_retryable`
///   (`error_handling.rs:369-388`, scoped `Failed AND epoch IS NULL`) — is never
///   reached. `C2`'s poisoned row is never swept to `Retryable`.
/// - `C2` re-delivered (resubscribe / cursor replay): MDK's Step-0 dedup
///   (`process.rs:368-392`) sees the `Failed` row and returns a cached
///   `Unprocessable` for that `event_id` **forever**. Bob is permanently stuck at
///   `N+1`, unable to decrypt `N+2`+ — and because the row lives in the on-disk
///   `processed_messages` table, the wedge **survives every restart**.
///
/// # The fix (when the owner approves it)
///
/// After an epoch-advancing apply (or on resubscribe), sweep the group's
/// `Failed AND epoch IS NULL` rows to `Retryable` — `find_failed_messages_for_retry`
/// is scoped to exactly that set. It is fork-safe: a same-epoch race LOSER is
/// recorded with `epoch = Some(N)` (`fail_unprocessable`, `error_handling.rs:120`),
/// so the `epoch IS NULL` filter excludes it; only a genuinely out-of-order commit
/// (decrypt failed before the epoch was known) is swept.
///
/// # What this test asserts
///
/// The DESIRED post-fix behaviour: after `C1` applies and `C2` is re-fetched, Bob
/// reaches epoch `N+2` and can decrypt a location published on `N+2`, AND this
/// holds after tearing his `CircleManager` (the state a `LiveSyncCore` wraps) down
/// and rebuilding it against the SAME on-disk dir — proving the recovery is
/// durable, not an in-memory artifact. This is the REGRESSION GATE for the M11
/// `MdkManager::retry_failed_future_epoch_messages` sweep (MDK #633 workaround):
/// BEFORE that fix it failed (Bob stuck at `N+1`, the re-delivered `C2` was sticky
/// `Unprocessable`); it now passes. If it reds, the un-poison sweep regressed.
#[tokio::test]
async fn out_of_order_commit_recovers_after_predecessor_arrives() {
    let mut circle = build_circle(1).await;
    let gid = circle.mls_group_id.clone();
    let ngid = circle.nostr_group_id;
    let alice_pk = circle.admin_keys.public_key();

    // Bob is the receiver; own him (remove from the Vec, keeping his dir in
    // `member_dirs`) so we can later drop + reopen his store against the same files.
    let bob = circle.members.remove(0);
    let alice = &circle.admin;

    let n = alice.group_epoch(&gid).unwrap();
    assert_eq!(
        bob.group_epoch(&gid).unwrap(),
        n,
        "Alice and Bob both start at N"
    );

    // Alice, alone, builds two GENUINE sequential commits and finalises each so
    // she advances N -> N+1 -> N+2. C1 is framed at N, C2 at N+1.
    let c1 = alice.self_update(&gid).unwrap().evolution_event;
    alice.finalize_pending_commit(&gid).unwrap();
    assert_eq!(alice.group_epoch(&gid).unwrap(), n + 1);
    let c2 = alice.self_update(&gid).unwrap().evolution_event;
    alice.finalize_pending_commit(&gid).unwrap();
    assert_eq!(
        alice.group_epoch(&gid).unwrap(),
        n + 2,
        "Alice authored C1 (N->N+1) then C2 (N+1->N+2)"
    );

    // ---- Phase A: out-of-order arrival poisons the on-disk processed_messages ----
    // C2 arrives FIRST, while Bob is still at N. He lacks the N+1 exporter secret,
    // so MDK's outer decrypt fails and writes Failed(epoch=NULL) to Bob's SQLite.
    let out_c2_early = bob.decrypt_location_for_engine(&c2, &ngid);
    assert_eq!(
        bob.group_epoch(&gid).unwrap(),
        n,
        "an out-of-order successor commit must NOT apply (Bob still at N); got {out_c2_early:?}"
    );

    // C1 then applies normally (N -> N+1). A plain forward process_commit — NOT an
    // is_better_candidate rollback — so nothing sweeps C2's poisoned row.
    let _out_c1 = bob.decrypt_location_for_engine(&c1, &ngid);
    assert_eq!(
        bob.group_epoch(&gid).unwrap(),
        n + 1,
        "C1 (the legitimate predecessor) applies and advances Bob to N+1"
    );

    // ---- Phase B: teardown + reopen against the SAME on-disk dir ----
    // Prove the poison lives on disk, not in memory: drop Bob's manager entirely
    // (closing his SQLite connection) and rebuild a fresh one over the same files.
    drop(bob);
    let bob = CircleManager::new_unencrypted(circle.member_dirs[0].path())
        .expect("reopen Bob's on-disk store");
    assert_eq!(
        bob.group_epoch(&gid).unwrap(),
        n + 1,
        "Bob's N+1 state persisted across the restart"
    );

    // ---- Phase C: recovery after restart (the re-fetch / resubscribe delivers C2) ----
    // DESIRED (post-fix): the Failed(epoch=NULL) row was swept to Retryable, so the
    // re-delivered C2 reprocesses and Bob reaches N+2.
    // TODAY (pre-fix): Step-0 dedup returns the cached Unprocessable for C2's
    // event_id, so Bob is stuck at N+1 and the epoch assertion below FAILS — the
    // exact "member stuck at N+1 / C2 Unprocessable" signature of the blocker.
    let out_c2_redelivered = bob.decrypt_location_for_engine(&c2, &ngid);
    let bob_epoch = bob.group_epoch(&gid).unwrap();
    assert_eq!(
        bob_epoch,
        n + 2,
        "post-fix: after C1 applies and C2 is re-fetched across a restart, Bob must reach N+2 \
         (out-of-order recovery). Observed epoch {bob_epoch}, re-delivered-C2 outcome {out_c2_redelivered:?}"
    );

    // The recovered N+2 state is un-forked: Alice (at N+2) and the restarted Bob
    // share the epoch-N+2 exporter secret.
    assert!(
        cross_decrypts(alice, &alice_pk, &bob, &gid),
        "post-fix: the restarted Bob decrypts a location Alice publishes on N+2"
    );
}

/// TEST 2 (GREEN) — pins the mixed-shape plain-observer convergence the Flutter
/// e2e scenario b's "Carol" relies on.
///
/// Carol is a twin-fork detector: a member with NO engine and NO pending commit of
/// her own who receives a same-epoch REMOVE commit AND a same-epoch SELF-UPDATE
/// commit and must converge onto the single MIP-03 winner purely via MDK's native
/// epoch-snapshot / `is_better_candidate` rollback (regime 1 — she gets snapshots
/// because she PROCESSES peer commits, unlike an eager-merger).
///
/// The existing in-crate pin
/// (`no_pending_observers_converge_on_sibling_commits_via_native_rollback`) only
/// covers two SYMMETRIC self-updates. This pins the MIXED remove-vs-self-update
/// shape the e2e actually exercises, and asserts the observer lands on the specific
/// **global MIP-03 winner's** branch (not merely "some shared branch"): two plain
/// observers apply the two commits in OPPOSITE arrival orders and must both reach
/// the winner's N+1 branch — cross-decrypting a follow-up ON the winner's branch,
/// each other (the twin-fork detector), and agreeing on the winner-determined
/// roster (Dave present iff the self-update won).
#[tokio::test]
async fn plain_observer_converges_on_mixed_remove_and_self_update_via_native_rollback() {
    // Alice(admin) + Bob(self_update) + Carol/Eve(plain observers) + Dave(remove target).
    let circle = build_circle(4).await;
    let gid = circle.mls_group_id.clone();
    let ngid = circle.nostr_group_id;

    let alice = &circle.admin;
    let alice_pk = circle.admin_keys.public_key();
    let bob = &circle.members[0];
    let bob_pk = circle.member_keys[0].public_key();
    let carol = &circle.members[1];
    let carol_pk = circle.member_keys[1].public_key();
    let eve = &circle.members[2];
    let eve_pk = circle.member_keys[2].public_key();
    let dave_hex = circle.member_keys[3].public_key().to_hex();

    let n = alice.group_epoch(&gid).unwrap();

    // Two GENUINE same-epoch (N) sibling commits of DIFFERENT shapes: an admin
    // REMOVE (Alice removes Dave) and a member SELF_UPDATE (Bob). Both are staged
    // (pending, not finalised), so neither author's epoch advances yet.
    let remove_commit = alice
        .remove_members(&gid, std::slice::from_ref(&dave_hex))
        .unwrap()
        .evolution_event;
    let self_update_commit = bob.self_update(&gid).unwrap().evolution_event;
    assert_eq!(
        alice.group_epoch(&gid).unwrap(),
        n,
        "a staged remove does not advance the epoch"
    );
    assert_eq!(
        bob.group_epoch(&gid).unwrap(),
        n,
        "a staged self_update does not advance the epoch"
    );

    // The MIP-03 winner, computed off-wire — identical to MDK's internal
    // is_better_candidate ordering.
    let remove_wins = order_key(&remove_commit) < order_key(&self_update_commit);

    // Carol receives [remove, then self_update]; Eve receives [self_update, then
    // remove]. Each is a plain observer with no pending commit, so MDK's native
    // rollback (not any Haven settle buffer) must converge both onto the winner.
    let _ = carol.decrypt_location_for_engine(&remove_commit, &ngid);
    let _ = carol.decrypt_location_for_engine(&self_update_commit, &ngid);
    let _ = eve.decrypt_location_for_engine(&self_update_commit, &ngid);
    let _ = eve.decrypt_location_for_engine(&remove_commit, &ngid);

    // Each observer advanced by EXACTLY one epoch (converged, never double-applied
    // into an N+2 fork).
    assert_eq!(
        carol.group_epoch(&gid).unwrap(),
        n + 1,
        "Carol converges to a single N+1 branch"
    );
    assert_eq!(
        eve.group_epoch(&gid).unwrap(),
        n + 1,
        "Eve converges to a single N+1 branch"
    );

    // Both observers landed on the SAME branch regardless of arrival order — the
    // twin-fork detector (equal epoch NUMBER alone cannot see a twin fork; only the
    // shared exporter secret can).
    assert!(
        cross_decrypts(carol, &carol_pk, eve, &gid),
        "opposite-order observers share one exporter secret (Eve decrypts Carol)"
    );
    assert!(
        cross_decrypts(eve, &eve_pk, carol, &gid),
        "opposite-order observers share one exporter secret BOTH ways (Carol decrypts Eve)"
    );

    // The winner finalises its own commit, landing on the very branch the observers
    // converged onto; assert the observers match the GLOBAL MIP-03 winner (not just
    // each other) by decrypting a follow-up on the winner's branch and agreeing on
    // the winner-determined roster.
    if remove_wins {
        alice.finalize_pending_commit(&gid).unwrap();
        assert_eq!(alice.group_epoch(&gid).unwrap(), n + 1);
        assert!(
            cross_decrypts(alice, &alice_pk, carol, &gid),
            "remove won: Carol is on Alice's remove branch (decrypts Alice's N+1 location)"
        );
        assert!(
            cross_decrypts(alice, &alice_pk, eve, &gid),
            "remove won: Eve is on Alice's remove branch (decrypts Alice's N+1 location)"
        );
        assert!(
            !roster_hex(carol, &gid).contains(&dave_hex),
            "remove won: Dave is gone from Carol's roster (winner's branch, not a twin)"
        );
        assert!(
            !roster_hex(eve, &gid).contains(&dave_hex),
            "remove won: Dave is gone from Eve's roster (winner's branch, not a twin)"
        );
    } else {
        bob.finalize_pending_commit(&gid).unwrap();
        assert_eq!(bob.group_epoch(&gid).unwrap(), n + 1);
        assert!(
            cross_decrypts(bob, &bob_pk, carol, &gid),
            "self_update won: Carol is on Bob's branch (decrypts Bob's N+1 location)"
        );
        assert!(
            cross_decrypts(bob, &bob_pk, eve, &gid),
            "self_update won: Eve is on Bob's branch (decrypts Bob's N+1 location)"
        );
        assert!(
            roster_hex(carol, &gid).contains(&dave_hex),
            "self_update won: Dave is still on Carol's roster (winner's branch, not a twin)"
        );
        assert!(
            roster_hex(eve, &gid).contains(&dave_hex),
            "self_update won: Dave is still on Eve's roster (winner's branch, not a twin)"
        );
    }
}
