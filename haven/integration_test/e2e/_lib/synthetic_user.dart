/// An in-process synthetic test peer.
///
/// `SyntheticUser` wraps a [TestUser] (its own `CircleManagerFfi`,
/// `NostrIdentityManager`, and per-user temp directory) and adds
/// thin helpers that drive the same MLS-over-Nostr flows the
/// production UI drives — but *programmatically*, without rendering
/// a second Flutter app.
///
/// ## Why in-process and not multi-AVD
///
/// Multi-user E2E coverage was originally architected as one
/// `flutter drive` process per role across separate AVDs,
/// coordinated through the hermetic strfry. That pattern works on
/// expensive runners (32 GB RAM, 8 vCPU) but thrashes on
/// `ubuntu-latest` (16 GB RAM, 4 vCPU) — three concurrent emulators
/// over-commit memory and the kernel paging cascade balloons EGL
/// frame times into the 1–3 s range, which Flutter's
/// `tester.pump()` cannot compensate for.
///
/// `SyntheticUser` is the industry-standard alternative (the
/// pattern element-web uses for multi-user Matrix tests):
/// **one runner runs one Flutter UI process driving one role
/// through the production UI; other roles participate in-process
/// via their FFI surfaces.** The MLS protocol path stays identical
/// to production — every encrypt / decrypt / publish / commit
/// crosses the same FFI boundary the production app uses. The
/// only thing skipped is the UI-rendering of the synthetic peers,
/// which has its own widget-test coverage under
/// `haven/test/widgets/circles/`.
///
/// ## Privacy
///
/// Synthetic peers are constructed from the same sentinel seeds
/// the multi-AVD architecture used (`aliceSeed`, `bobSeed`,
/// `carolSeed` in `test_user.dart`). The hermetic relay scope
/// guarantees no test pubkey ever reaches a production relay even
/// if the override mechanism were bypassed.
///
/// ## Shared-keyring caveat (test-only)
///
/// Alice, Bob, and Carol each instantiate their own
/// `CircleManagerFfi` against a per-user temp directory, but every
/// `CircleManagerFfi.newInstance` call resolves the same
/// `circles.db.key` entry from the *process-global* in-memory
/// keyring (`useInMemoryKeyringForTest`). Each SQLCipher database
/// is therefore encrypted with the SAME key. Per-peer isolation in
/// the test process comes from the per-user `dataDir`, not from
/// per-peer database keys — pointing one peer's `CircleManagerFfi`
/// at a different peer's `dataDir` would unlock that DB. This is
/// acceptable in the test scope because all three roles run in the
/// same Dart isolate (synthetic peers' state is intentionally
/// inspectable by the test), and the production single-tenant
/// design (one user, one device, one key) is unaffected. Do not
/// extend `SyntheticUser` to a multi-tenant production scenario
/// without first namespacing the keyring entry per `dataDir`.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:haven/src/rust/api.dart';

import 'test_relay.dart';
import 'test_user.dart';

/// The lat/lon pair returned for one successfully-decrypted sender.
///
/// Named record so call sites stay readable without importing a
/// separate class. The fields mirror [DecryptedLocationFfi] exactly.
typedef DecryptedCoords = ({double latitude, double longitude});

/// Outcome of applying a batch of kind-445 events to a synthetic
/// peer's MDK.
///
/// `decryptedLocationSenders` is the set of sender pubkeys whose
/// location decrypted in this batch; kept for back-compat with
/// callers that only need presence (e.g. the convergence loop in
/// `_drainUntilLocationsVisible`).
///
/// `decryptedLocations` provides the actual coordinates per sender
/// (key = lowercase hex pubkey), so assertions can verify that
/// decrypt returned the **correct** coordinates and not merely that
/// it succeeded. Because Rust dedup means a given event only yields
/// a non-null result on the *first* round it decrypts, callers must
/// accumulate this map across drain rounds the same way they
/// accumulate `decryptedLocationSenders` (see
/// [SyntheticUser.drainPendingCommits] for the full rationale).
/// Coordinates are intentionally NOT written to log lines; sentinel
/// values are non-identifying today but may not remain so after a
/// future refactor — keeping them out of CI artifacts is cheap
/// forward defence.
typedef ApplyEventsSummary = ({
  int locationsProcessed,
  int groupUpdatesProcessed,
  int decryptFailed,
  Set<String> decryptedLocationSenders,
  Map<String, DecryptedCoords> decryptedLocations,
});

/// A peer that participates in MLS/Nostr scenarios via direct FFI
/// calls plus a shared [TestRelay], without driving a Flutter UI.
class SyntheticUser {
  SyntheticUser._({required this.user, required this.keyPackageRelays});

  /// Constructs a synthetic identity from [seed] and publishes its
  /// KeyPackage to [relay] before returning.
  ///
  /// The published event uses **both** the canonical kind 30443
  /// (addressable, MIP-00) and the legacy kind 443 — Haven's
  /// [`NostrRelayService.fetchKeyPackage`] queries both kinds, and
  /// publishing both maximises the chance the UI's KP lookup will
  /// succeed regardless of which kind it prefers first.
  ///
  /// Throws if the relay rejects either event (an indicator of a
  /// strfry misconfiguration or a malformed event).
  static Future<SyntheticUser> bootstrap({
    required String label,
    required Uint8List seed,
    required TestRelay relay,
  }) async {
    final user = await TestUser.bootstrap(label: label, seed: seed);
    try {
      final secret = await user.getSecretBytes();
      try {
        final kp = await user.circleManager.signKeyPackageEvent(
          identitySecretBytes: secret,
          relays: <String>[relay.url],
        );

        // Publish kind 30443 (canonical) first.
        final (acceptedCanonical, msgCanonical) = await relay
            .publishAndAwaitOk(kp.eventJson);
        if (!acceptedCanonical) {
          throw StateError(
            "relay rejected $label's kind 30443 KeyPackage: $msgCanonical",
          );
        }

        // Then the legacy kind 443. Some relays might reject duplicates
        // by event id, but the two events have distinct ids (different
        // kind), so both should land.
        final (acceptedLegacy, msgLegacy) = await relay.publishAndAwaitOk(
          kp.legacyEventJson,
        );
        if (!acceptedLegacy) {
          // Non-fatal: production code falls back gracefully to whichever
          // event is present. Log but don't fail the test setup.
          debugPrint(
            '[SyntheticUser:$label] relay rejected legacy kind 443: '
            '$msgLegacy (non-fatal)',
          );
        }

        return SyntheticUser._(
          user: user,
          keyPackageRelays: <String>[relay.url],
        );
      } finally {
        // Best-effort wipe of the local copy of the secret. Rust-side is
        // already Zeroizing-wrapped (see api.rs:load_from_bytes); this
        // covers the Dart-side List<int> that crossed the FFI boundary.
        for (var i = 0; i < secret.length; i++) {
          secret[i] = 0;
        }
      }
    } on Object {
      await user.dispose();
      rethrow;
    }
  }

  /// Convenience: Bob with the canonical sentinel seed, published to
  /// [relay].
  static Future<SyntheticUser> bob(TestRelay relay) =>
      bootstrap(label: 'bob', seed: bobSeed, relay: relay);

  /// Convenience: Carol with the canonical sentinel seed, published to
  /// [relay].
  static Future<SyntheticUser> carol(TestRelay relay) =>
      bootstrap(label: 'carol', seed: carolSeed, relay: relay);

  /// The underlying [TestUser] — exposed so scenarios can read pubkey/npub
  /// or, in edge cases, drive its FFI directly.
  final TestUser user;

  /// Relay URLs the KeyPackage event records as the user's "inbox" for
  /// follow-up Welcome delivery. In the consolidated scenario this is
  /// always `[strfryUrl]`.
  final List<String> keyPackageRelays;

  /// Short label used in log lines ("bob", "carol", …).
  String get label => user.label;

  /// The user's pubkey in NIP-19 bech32 form.
  String get npub => user.npub;

  /// The user's pubkey as lowercase hex.
  String get pubkeyHex => user.pubkeyHex;

  // ===========================================================================
  // Phase A — accept gift-wrapped invitation (Welcome → MDK state)
  // ===========================================================================

  /// Waits on [relay] for the kind-1059 gift-wrap addressed to this
  /// peer, decrypts it through `CircleManagerFfi.processGiftWrappedInvitation`,
  /// then applies the wrapped Welcome via `acceptInvitation`. Returns
  /// the resulting [CircleWithMembersFfi].
  ///
  /// Mirrors the production InvitationPoller + accept_invitation
  /// orchestration without the UI: same FFI calls, same epoch advance,
  /// same persistence side-effects. The only thing skipped is the
  /// InvitationsPage rebuild.
  ///
  /// Throws on timeout, on a gift-wrap that fails to decrypt, or on a
  /// Welcome that fails to apply.
  Future<CircleWithMembersFfi> acceptInvitationViaRelay({
    required TestRelay relay,
    Duration timeout = const Duration(seconds: 90),
  }) async {
    debugPrint(
      '[SyntheticUser:$label] waiting for gift-wrap addressed to '
      '${_redactPk(pubkeyHex)}',
    );
    final giftWrap = await relay.firstWhere(
      filter: <String, dynamic>{
        'kinds': <int>[1059],
        '#p': <String>[pubkeyHex],
        'limit': 50,
      },
      timeout: timeout,
    );
    final giftWrapJson = jsonEncode(giftWrap.raw);

    final secret = await user.getSecretBytes();
    final InvitationFfi? invitation;
    try {
      invitation = await user.circleManager.processGiftWrappedInvitation(
        identitySecretBytes: secret,
        giftWrapEventJson: giftWrapJson,
      );
    } finally {
      for (var i = 0; i < secret.length; i++) {
        secret[i] = 0;
      }
    }
    if (invitation == null) {
      throw StateError(
        '[SyntheticUser:$label] processGiftWrappedInvitation returned null '
        '— gift-wrap was malformed or already accepted',
      );
    }
    debugPrint(
      '[SyntheticUser:$label] processed gift-wrap '
      '(circleName="${invitation.circleName}", '
      'inviter=${_redactPk(invitation.inviterPubkey)})',
    );

    final accepted = await user.circleManager.acceptInvitation(
      mlsGroupId: invitation.mlsGroupId,
    );
    debugPrint(
      '[SyntheticUser:$label] acceptInvitation OK '
      '(members=${accepted.members.length})',
    );
    return accepted;
  }

  // ===========================================================================
  // Phase B — publish a peer location
  // ===========================================================================

  /// Encrypts a location into a kind-445 event via the production FFI
  /// and publishes it to [relay].
  ///
  /// Returns the published event id (from the OK frame match), so
  /// scenarios can correlate the publish with later assertions.
  ///
  /// [updateInterval] is the publish-cadence hint the receiver-side
  /// MLS state uses to compute the location's TTL. Must lie within
  /// `[60, 3600]` seconds — the Rust FFI rejects anything outside
  /// that range with `update_interval_secs out of range`. The
  /// default matches the production app
  /// (`kLocationPublishMaxInterval` 168 s + `kTtlNetworkBufferSeconds`
  /// 30 s = 198 s; see `haven/lib/src/constants/location.dart`).
  Future<String> publishLocation({
    required CircleWithMembersFfi circle,
    required double latitude,
    required double longitude,
    required TestRelay relay,
    Duration updateInterval = const Duration(seconds: 198),
    String? displayName,
  }) async {
    final encrypted = await user.circleManager.encryptLocation(
      mlsGroupId: circle.circle.mlsGroupId,
      senderPubkeyHex: pubkeyHex,
      latitude: latitude,
      longitude: longitude,
      displayName: displayName,
      updateIntervalSecs: BigInt.from(updateInterval.inSeconds),
    );
    final (accepted, msg) = await relay.publishAndAwaitOk(
      encrypted.eventJson,
    );
    if (!accepted) {
      throw StateError(
        '[SyntheticUser:$label] relay rejected location event: $msg',
      );
    }
    final decoded = jsonDecode(encrypted.eventJson);
    final id = decoded is Map<String, dynamic>
        ? decoded['id'] as String?
        : null;
    // Coordinates are intentionally NOT logged here. The kind-445
    // published to strfry is encrypted at MLS; the surrounding
    // logcat is uploaded as a CI failure artifact and printing
    // plaintext lat/lon there would defeat the encryption we just
    // performed. Sentinel coords are not personally identifying
    // today, but a future change that wires a real geofix into
    // this helper would silently regress the privacy posture.
    debugPrint(
      '[SyntheticUser:$label] published location evt='
      '${id == null ? "?" : _redactPk(id)}',
    );
    return id ?? '<unknown>';
  }

  // ===========================================================================
  // Phase C — drain pending kind-445 commits / location messages
  // ===========================================================================

  /// Fetches every kind-445 event on [relay] tagged with this circle's
  /// `nostrGroupId`, decrypts each via the synthetic peer's
  /// `CircleManagerFfi`, and returns a summary of what was processed.
  ///
  /// The production `LocationSharingService` distinguishes between
  /// location messages and group-update commits via the
  /// `DecryptResult` discriminator. This drainer surfaces both via
  /// the returned record so scenarios can assert on the
  /// MLS-protocol-level outcome (e.g., a non-zero
  /// `groupUpdatesProcessed` after Alice's AdminHandoff).
  ///
  /// ## Why the return record includes `decryptedLocationSenders`
  ///
  /// The Rust-side dedup (`_seenEventIds` + MDK's own
  /// `PreviouslyFailed` skip path) means that calling this method
  /// twice on the same relay state returns events the second time
  /// too — the relay filter has no cursor of its own — but those
  /// events `decryptLocation` returns null for (Rust says
  /// "already-seen"). Counting `locationsProcessed` across
  /// successive drains would inflate vacuously, so scenarios that
  /// gate on "all expected peers have been observed" must compare
  /// the *identity set* across drains, not the raw count. The
  /// returned `decryptedLocationSenders` is the union of sender
  /// pubkeys observed in this one drain call; the caller is
  /// responsible for accumulating across calls.
  ///
  /// Decrypt failures are logged but not thrown — events sent BEFORE
  /// this peer's MLS epoch caught up may legitimately fail to decrypt;
  /// the test should retry after waiting for relevant commits to land.
  Future<ApplyEventsSummary> drainPendingCommits({
    required TestRelay relay,
    required CircleWithMembersFfi circle,
    DateTime? since,
    Duration collectTimeout = const Duration(seconds: 5),
    int maxEvents = 200,
  }) async {
    final nostrGroupIdHex = _bytesToHex(circle.circle.nostrGroupId);
    final filter = <String, dynamic>{
      'kinds': const <int>[445],
      '#h': <String>[nostrGroupIdHex],
      'limit': maxEvents,
    };
    if (since != null) {
      filter['since'] = since.millisecondsSinceEpoch ~/ 1000;
    }

    // collectN returns whatever's accumulated when the timeout fires
    // (it doesn't throw on partial collection), so a short timeout is
    // the right shape for "drain what's available right now".
    final events = await relay.collectN(
      count: maxEvents,
      filter: filter,
      timeout: collectTimeout,
    );

    // Sort ascending by `created_at` as a best-effort ordering for
    // independent application messages (locations) and single-commit
    // transitions. This is sufficient for Phase 4 (locations are
    // order-independent) and Phase 6 (a non-admin leave is a single
    // commit). It is NOT sufficient for a multi-commit epoch sequence
    // like `LeavePlan::AdminHandoff` — Nostr `created_at` is 1-second
    // resolution and cannot order commits published within the same
    // second, and one out-of-order submission permanently poisons
    // MDK's sticky `Unprocessable` cache (see
    // docs/E2E_TROUBLESHOOTING.md). For that case the caller must use
    // [applyArrivalOrdered] with events captured live in publish
    // order. Dart's `List.sort` is stable, so equal-`created_at`
    // events keep their relay-arrival order.
    final ordered = events
        .map(
          (e) =>
              (createdAt: (e.raw['created_at'] as int?) ?? 0, event: e),
        )
        .toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

    return _applyEventsInOrder(
      [for (final entry in ordered) entry.event],
      relay: relay,
      context: 'drainPendingCommits',
    );
  }

  /// Applies [events] to this peer's MDK **in the given order**,
  /// without re-sorting.
  ///
  /// Use this for a multi-commit MLS epoch sequence (e.g.
  /// `LeavePlan::AdminHandoff`'s AdminHandoff → SelfDemote →
  /// SelfRemove) where [events] were captured live via
  /// [TestRelay.events] *before* the publisher acted, so their list
  /// order is wire-arrival order — which, for a single publisher
  /// emitting commits sequentially (awaiting each relay OK), is
  /// exactly MLS-epoch order. This is the only reliable epoch
  /// ordering available to a receiver: the alternative,
  /// [drainPendingCommits], sorts by Nostr `created_at`, which has
  /// 1-second resolution and cannot order same-second commits — and
  /// a single out-of-order submission permanently poisons MDK's
  /// sticky `Unprocessable` cache.
  ///
  /// Re-applying already-processed events is harmless (MDK's dedup
  /// returns `Ok(None)`), so callers may re-pass a growing buffer
  /// across retry rounds.
  ///
  /// [finalizeAutoCommit] controls what happens when MDK auto-stages a
  /// receiver-side commit (e.g. each remaining member auto-commits a
  /// SelfRemove proposal). When `true` (default) the commit is
  /// published and finalized. When `false` the commit is left PENDING
  /// in MDK (not published, not finalized, not cleared) so the caller
  /// can `clearPendingCommit` it and adopt a different (winning)
  /// commit instead — the single-committer election that avoids the
  /// multi-committer fork an admin handoff would otherwise produce in
  /// a 3+-member residual (see `_reconcileHandoff`). This mirrors the
  /// canonical `concurrent_admin_remove_member_converges_after_clear_pending`
  /// recipe in `haven-core/src/circle/manager.rs`.
  Future<ApplyEventsSummary> applyArrivalOrdered(
    List<TestRelayEvent> events, {
    required TestRelay relay,
    bool finalizeAutoCommit = true,
  }) {
    return _applyEventsInOrder(
      events,
      relay: relay,
      context: 'applyArrivalOrdered',
      finalizeAutoCommit: finalizeAutoCommit,
    );
  }

  /// Shared decrypt-and-apply loop for [drainPendingCommits] and
  /// [applyArrivalOrdered]. Processes [events] in the exact order
  /// given (the caller owns ordering policy) and handles the
  /// receiver-side auto-commit.
  Future<ApplyEventsSummary> _applyEventsInOrder(
    List<TestRelayEvent> events, {
    required TestRelay relay,
    required String context,
    bool finalizeAutoCommit = true,
  }) async {
    var locationsProcessed = 0;
    var groupUpdatesProcessed = 0;
    var decryptFailed = 0;
    final decryptedSenders = <String>{};
    // Coordinates per sender (lowercase hex key). Only the first
    // successful decrypt for a given sender is recorded per the
    // [drainPendingCommits] contract: Rust dedup means repeat calls on
    // the same event return null, so callers must accumulate across
    // drain rounds.
    final decryptedLocations = <String, DecryptedCoords>{};
    for (final event in events) {
      final eventJson = jsonEncode(event.raw);
      try {
        final result = await user.circleManager.decryptLocation(
          eventJson: eventJson,
        );
        if (result == null) {
          // Already-seen / not for us — Rust's dedup absorbed it.
          continue;
        }
        final location = result.location;
        if (location != null) {
          locationsProcessed++;
          final senderKey = location.senderPubkey.toLowerCase();
          decryptedSenders.add(senderKey);
          // Only store the first successful result; subsequent drains for
          // the same event return null (dedup), so this map entry is stable.
          decryptedLocations[senderKey] = (
            latitude: location.latitude,
            longitude: location.longitude,
          );
        }
        if (result.groupUpdated) {
          groupUpdatesProcessed++;
        }
        // Receiver-side auto-commit: when MDK stages an outbound
        // commit as a side effect of receiving this event, the FFI
        // surfaces it via `evolutionEventJson` and we must publish +
        // finalize it. Lives OUTSIDE the `result.groupUpdated`
        // branch to mirror the production location-sharing service
        // (`lib/src/services/location_sharing_service.dart:741-779`):
        // a SelfRemove proposal received on the admin side often
        // returns `groupUpdated=false` with a non-null
        // `evolutionEventJson` — the receiver's auto-commit applying
        // the leave. Gating on `groupUpdated` here would silently
        // drop those commits, leaving a dangling pending commit that
        // can brick subsequent decrypts.
        final evolutionEventJson = result.evolutionEventJson;
        final evolutionMlsGroupId = result.evolutionMlsGroupId;
        if (evolutionEventJson != null &&
            evolutionMlsGroupId != null &&
            finalizeAutoCommit) {
          final (ok, _) = await relay.publishAndAwaitOk(evolutionEventJson);
          if (ok) {
            await user.circleManager.finalizePendingCommit(
              mlsGroupId: evolutionMlsGroupId,
            );
          } else {
            await user.circleManager.clearPendingCommit(
              mlsGroupId: evolutionMlsGroupId,
            );
          }
        }
        // When finalizeAutoCommit is false, the auto-staged commit is
        // deliberately LEFT PENDING in MDK (not published/finalized/
        // cleared). The caller (`_reconcileHandoff`'s loser path) will
        // `clearPendingCommit` it and adopt the winner's commit.
      } on Object catch (e) {
        decryptFailed++;
        debugPrint(
          '[SyntheticUser:$label] decrypt failed for evt='
          '${_redactPk(event.id)}: ${e.runtimeType}',
        );
      }
    }
    debugPrint(
      '[SyntheticUser:$label] $context: '
      'events=${events.length} '
      'locations=$locationsProcessed '
      'groupUpdates=$groupUpdatesProcessed '
      'decryptFailed=$decryptFailed '
      'distinctSenders=${decryptedSenders.length}',
    );
    return (
      locationsProcessed: locationsProcessed,
      groupUpdatesProcessed: groupUpdatesProcessed,
      decryptFailed: decryptFailed,
      decryptedLocationSenders: decryptedSenders,
      decryptedLocations: decryptedLocations,
    );
  }

  // ===========================================================================
  // Phase D — leave the circle (non-admin path only)
  // ===========================================================================

  /// Drives the non-admin leave flow:
  ///   1. `planLeave` confirms this peer is `LeavePlanKindFfi.nonAdmin`
  ///   2. `proposeLeave` produces the SelfRemove commit
  ///   3. publish the commit to [relay]
  ///   4. `completeLeave` advances local MDK state
  ///
  /// Throws if `planLeave` produces any other variant — the synthetic
  /// peer is expected to be non-admin in the residual two-member group
  /// (admin status moved to the lex-smallest non-self member when
  /// Alice left via UI).
  Future<void> leaveAsNonAdmin({
    required CircleWithMembersFfi circle,
    required TestRelay relay,
  }) async {
    final plan = await user.circleManager.planLeave(
      mlsGroupId: circle.circle.mlsGroupId,
      selfPubkeyHex: pubkeyHex,
    );
    debugPrint(
      '[SyntheticUser:$label] planLeave → ${plan.kind.name}',
    );
    // Exhaustive switch with explicit arms per LeavePlanKindFfi
    // variant. Future variants added to `haven-core`'s LeavePlan
    // surface compile cleanly here (no exhaustiveness enforcement
    // because FRB generates plain enums) but throw a named
    // diagnostic at runtime, making the failure message actionable
    // when the test invariant changes.
    switch (plan.kind) {
      case LeavePlanKindFfi.nonAdmin:
        break; // expected path — fall through to the propose+publish steps
      case LeavePlanKindFfi.adminHandoff:
      case LeavePlanKindFfi.adminDemote:
      case LeavePlanKindFfi.abandon:
      case LeavePlanKindFfi.orphanLocalOnly:
        throw StateError(
          '[SyntheticUser:$label] leaveAsNonAdmin invoked but planLeave '
          'returned ${plan.kind.name}. Test invariant violated: this '
          'synthetic peer should not be admin (or sole-remaining / '
          'orphaned) in the residual group.',
        );
    }

    final result = await user.circleManager.proposeLeave(
      mlsGroupId: circle.circle.mlsGroupId,
    );
    final (accepted, msg) = await relay.publishAndAwaitOk(
      result.evolutionEventJson,
    );
    if (!accepted) {
      // Clear the pending commit so MDK state isn't wedged.
      await user.circleManager.clearPendingCommit(
        mlsGroupId: circle.circle.mlsGroupId,
      );
      throw StateError(
        '[SyntheticUser:$label] relay rejected SelfRemove: $msg',
      );
    }
    await user.circleManager.completeLeave(
      mlsGroupId: circle.circle.mlsGroupId,
    );
    debugPrint(
      '[SyntheticUser:$label] leaveAsNonAdmin complete',
    );
  }

  // ===========================================================================
  // Phase E — read MDK membership state
  // ===========================================================================

  /// Returns the current member list for [mlsGroupId] as MDK sees it
  /// on this synthetic peer.
  Future<List<CircleMemberFfi>> getMembers(Uint8List mlsGroupId) {
    return user.circleManager.getMembers(mlsGroupId: mlsGroupId);
  }

  /// Re-reads the full circle metadata from this peer's local MDK
  /// state — used after a `drainPendingCommits` cycle so scenarios
  /// can assert on the up-to-date membership / admin set.
  Future<CircleWithMembersFfi?> getCircle(Uint8List mlsGroupId) {
    return user.circleManager.getCircle(mlsGroupId: mlsGroupId);
  }

  /// Discards any commit this peer has staged but not yet finalized for
  /// [mlsGroupId]. Used by the handoff single-committer election to
  /// drop the loser's withheld SelfRemove auto-commit before it adopts
  /// the winner's commit (mirrors `clear_pending_commit` in the
  /// canonical Rust convergence test). A no-op when nothing is pending.
  Future<void> clearPendingCommit(Uint8List mlsGroupId) {
    return user.circleManager.clearPendingCommit(mlsGroupId: mlsGroupId);
  }

  /// Releases the underlying [TestUser].
  Future<void> dispose() => user.dispose();

  // ===========================================================================
  // Internal helpers
  // ===========================================================================

  static String _bytesToHex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// Short prefix-and-ellipsis pubkey form for log lines. Pubkeys are
  /// public-by-design Nostr metadata but truncating in CI logs makes
  /// failure artifacts less casually identifying.
  static String _redactPk(String hex) =>
      hex.length <= 8 ? hex : '${hex.substring(0, 8)}…';
}
