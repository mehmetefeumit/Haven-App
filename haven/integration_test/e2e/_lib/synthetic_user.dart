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
///
/// `publishedCommitEventIds` and `withheldPendingCommit` are VESTIGIAL
/// under Dark Matter — always empty / `false`, respectively. They backed
/// the pre-migration receiver-side auto-commit publish/finalize dance and
/// the single-committer election built on top of it; the Dark Matter
/// engine now owns publish-before-apply AND commit-ordering/convergence
/// entirely internally, so there is nothing left for a Dart-side decrypt
/// loop to publish, finalize, or withhold. See [applyArrivalOrdered]'s
/// `finalizeAutoCommit` doc.
typedef ApplyEventsSummary = ({
  int locationsProcessed,
  int groupUpdatesProcessed,
  int decryptFailed,
  Set<String> decryptedLocationSenders,
  Map<String, DecryptedCoords> decryptedLocations,
  List<String> publishedCommitEventIds,
  bool withheldPendingCommit,
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
      // Dark Matter (DM-4): `maintain_key_package` is now the ONE publish
      // path for `KeyPackage` material (kind 30443 only — the legacy kind
      // 443 twin is retired) — there is no longer a bare "sign, don't
      // publish" FFI call. It probes/publishes to the account's OWN NIP-65
      // relays (never a directly-passed relay list), so this synthetic
      // peer's NIP-65 relay list must include the hermetic relay FIRST —
      // mirrors the production relay-preferences seeding an onboarding
      // identity goes through before its first KeyPackage publish.
      await user.circleManager.addUserRelay(
        url: relay.url,
        relayType: RelayTypeFfi.nip65,
      );

      final secret = await user.getSecretBytes();
      final relayManager = await RelayManagerFfi.newInstance();
      try {
        final outcome = await relayManager.maintainKeyPackage(
          circle: user.circleManager,
          identitySecretBytes: secret,
        );
        if (outcome.relaysHealed < 1) {
          throw StateError(
            "$label's KeyPackage maintenance did not reach the hermetic "
            'relay (action=${outcome.action.name}, '
            'errors=${outcome.relayErrors})',
          );
        }
        debugPrint(
          '[SyntheticUser:$label] KeyPackage published '
          '(action=${outcome.action.name})',
        );

        return SyntheticUser._(
          user: user,
          keyPackageRelays: <String>[relay.url],
        );
      } finally {
        await relayManager.shutdown();
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
  ///
  /// [seedOffset] deterministically varies Bob's trailing seed byte so
  /// callers that construct many short-lived Bobs on the SAME shared relay
  /// (the M11 group) get a DISTINCT identity per caller instead of reusing
  /// `bobSeed` outright. Kind-1059 gift-wraps are not replaceable, so a
  /// fixed seed reused across scenarios keeps accumulating gift-wraps for
  /// the same recurring pubkey and degrades `acceptInvitationViaRelay`'s
  /// `#p` lookup from O(1) to a growing scan. `0` (the default) reproduces
  /// the original canonical seed unchanged, so every other existing caller
  /// is unaffected.
  static Future<SyntheticUser> bob(TestRelay relay, {int seedOffset = 0}) =>
      bootstrap(
        label: 'bob',
        seed: _seedWithOffset(bobSeed, seedOffset),
        relay: relay,
      );

  /// Convenience: Carol with the canonical sentinel seed, published to
  /// [relay]. See [bob]'s [seedOffset] doc for the rationale.
  static Future<SyntheticUser> carol(TestRelay relay, {int seedOffset = 0}) =>
      bootstrap(
        label: 'carol',
        seed: _seedWithOffset(carolSeed, seedOffset),
        relay: relay,
      );

  /// Convenience: Dave with the canonical sentinel seed, published to
  /// [relay].
  ///
  /// Dave is the fourth sentinel role, used primarily by the
  /// FE-2 "decline/ignore invitation" scenario where a peer receives a
  /// gift-wrapped Welcome but never calls `acceptInvitation`.
  static Future<SyntheticUser> dave(TestRelay relay) =>
      bootstrap(label: 'dave', seed: daveSeed, relay: relay);

  /// Returns [base] unchanged when [offset] is `0`; otherwise a 32-byte
  /// copy with its trailing byte shifted by [offset] (wrapping mod 256).
  /// Keeps the seed the same recognizable length and "family" (the leading
  /// 31 bytes, e.g. all `0x02` for Bob) while deriving a pubkey distinct
  /// from every other offset used on the same relay.
  static Uint8List _seedWithOffset(Uint8List base, int offset) {
    if (offset == 0) return base;
    final seed = Uint8List.fromList(base);
    seed[seed.length - 1] = (seed[seed.length - 1] + offset) & 0xFF;
    return seed;
  }

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
    // Wait for the first gift-wrap addressed to us.
    final first = await relay.firstWhere(
      filter: <String, dynamic>{
        'kinds': <int>[1059],
        '#p': <String>[pubkeyHex],
        'limit': 50,
      },
      timeout: timeout,
    );

    // Fast path: apply the first gift-wrap. With a unique invitee pubkey this
    // is the only `#p` match and applies on the first try (identical to the
    // historical behaviour). The fallback below only matters when a `#p`
    // matches MORE than one gift-wrap — e.g. a pubkey reused across subtests
    // on a shared, not-yet-wiped relay, where NIP-59's randomized `created_at`
    // makes delivery order nondeterministic and `firstWhere` could surface a
    // STALE Welcome whose single-use KeyPackage is absent from this fresh
    // keystore. Trying each candidate until one applies closes that race
    // structurally rather than relying on the unique-pubkey convention.
    final firstResult = await _tryApplyGiftWrap(first);
    if (firstResult != null) return firstResult;

    debugPrint(
      '[SyntheticUser:$label] first gift-wrap did not apply (likely stale); '
      'scanning for other gift-wraps addressed to us',
    );
    final others = await relay.collectN(
      count: 50,
      filter: <String, dynamic>{
        'kinds': <int>[1059],
        '#p': <String>[pubkeyHex],
        'limit': 50,
      },
      timeout: const Duration(seconds: 5),
    );
    for (final gw in others) {
      if (gw.id == first.id) continue;
      final result = await _tryApplyGiftWrap(gw);
      if (result != null) return result;
    }
    throw StateError(
      '[SyntheticUser:$label] no gift-wrap addressed to '
      '${_redactPk(pubkeyHex)} yielded an applicable Welcome',
    );
  }

  /// Decrypts [giftWrap] and applies its Welcome, returning the joined circle.
  ///
  /// Returns `null` (rather than throwing) when this particular gift-wrap is
  /// not applicable — malformed, already accepted, or its single-use
  /// KeyPackage is absent from the keystore — so [acceptInvitationViaRelay]
  /// can fall through to the next candidate. Re-fetches and zeroes the
  /// identity secret per attempt (Security Rule #9: minimize exposure).
  Future<CircleWithMembersFfi?> _tryApplyGiftWrap(
    TestRelayEvent giftWrap,
  ) async {
    final giftWrapJson = jsonEncode(giftWrap.raw);
    final secret = await user.getSecretBytes();
    InvitationFfi? invitation;
    try {
      invitation = await user.circleManager.processGiftWrappedInvitation(
        identitySecretBytes: secret,
        giftWrapEventJson: giftWrapJson,
      );
    } on Object catch (e) {
      debugPrint(
        '[SyntheticUser:$label] gift-wrap ${_redactPk(giftWrap.id)} did not '
        'process (${e.runtimeType}); trying another',
      );
    } finally {
      for (var i = 0; i < secret.length; i++) {
        secret[i] = 0;
      }
    }
    if (invitation == null) return null;

    try {
      // `invitation.mlsGroupId` is the pre-join stand-in id — actually the
      // gift-wrap event id the invitation was keyed by; `acceptInvitation`
      // accepts by that same id.
      final accepted = await user.circleManager.acceptInvitation(
        giftWrapId: invitation.mlsGroupId,
      );
      debugPrint(
        '[SyntheticUser:$label] acceptInvitation OK '
        '(circleName="${invitation.circleName}", '
        'inviter=${_redactPk(invitation.inviterPubkey)}, '
        'members=${accepted.members.length})',
      );
      return accepted;
    } on Object catch (e) {
      debugPrint(
        '[SyntheticUser:$label] acceptInvitation did not apply '
        '(${e.runtimeType}); trying another gift-wrap',
      );
      return null;
    }
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
  }) async {
    final encrypted = await user.circleManager.encryptLocation(
      mlsGroupId: circle.circle.mlsGroupId,
      senderPubkeyHex: pubkeyHex,
      latitude: latitude,
      longitude: longitude,
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
  /// `LocationEventKind` discriminator (mirrors the FFI
  /// `LocationMessageResultKindFfi`). This drainer surfaces both via
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
  /// [finalizeAutoCommit] is VESTIGIAL under Dark Matter — kept only so
  /// existing call sites across the E2E suite do not all need to change
  /// their signature at once — and has NO effect. The pre-migration MDK
  /// stack staged a receiver-side auto-commit in Dart-visible pending
  /// state that a caller could choose to leave uncommitted (the
  /// single-committer election `_reconcileHandoff` used to referee a
  /// concurrent admin-handoff leave). The Dark Matter engine now owns
  /// publish-before-apply AND commit-ordering/convergence entirely
  /// internally — there is no Dart-visible pending receiver-side commit
  /// left to withhold, publish, or clear. [ApplyEventsSummary
  /// .withheldPendingCommit] is therefore always `false` and
  /// [ApplyEventsSummary.publishedCommitEventIds] is always empty; any
  /// scenario that relied on the old election (checking those fields, or
  /// clearing a "loser" peer's withheld commit) needs the engine's own
  /// convergence to settle instead — see `MDK_DARKMATTER_MIGRATION_PLAN.md`
  /// §2.1/§2.2 (out-of-order-commit / concurrent-commit-fork handling
  /// moves into the engine).
  Future<ApplyEventsSummary> applyArrivalOrdered(
    List<TestRelayEvent> events, {
    required TestRelay relay,
    bool finalizeAutoCommit = true,
  }) {
    return _applyEventsInOrder(
      events,
      relay: relay,
      context: 'applyArrivalOrdered',
    );
  }

  /// Shared decrypt-and-apply loop for [drainPendingCommits] and
  /// [applyArrivalOrdered]. Processes [events] in the exact order
  /// given (the caller owns ordering policy); the engine applies any
  /// resulting group state change internally.
  Future<ApplyEventsSummary> _applyEventsInOrder(
    List<TestRelayEvent> events, {
    required TestRelay relay,
    required String context,
  }) async {
    var locationsProcessed = 0;
    var groupUpdatesProcessed = 0;
    var decryptFailed = 0;
    final decryptedSenders = <String>{};
    // Coordinates per sender (lowercase hex key). Only the first
    // successful decrypt for a given sender is recorded per the
    // [drainPendingCommits] contract: Rust dedup means repeat calls on
    // the same event return an empty result, so callers must accumulate
    // across drain rounds.
    final decryptedLocations = <String, DecryptedCoords>{};
    // Dark Matter: the engine owns publish-before-apply for every commit
    // internally, so a decrypt/ingest never hands back an outbound event
    // for a receiver to publish/finalize — these stay permanently empty/
    // false. See [ApplyEventsSummary]'s field docs and
    // [applyArrivalOrdered]'s `finalizeAutoCommit` doc.
    const publishedCommitEventIds = <String>[];
    const withheldPendingCommit = false;
    for (final event in events) {
      final eventJson = jsonEncode(event.raw);
      try {
        final results = await user.circleManager.decryptLocation(
          eventJson: eventJson,
        );
        for (final result in results) {
          switch (result.kind) {
            case LocationMessageResultKindFfi.location:
              final location = result.location;
              if (location == null) continue;
              locationsProcessed++;
              final senderKey = location.senderPubkey.toLowerCase();
              decryptedSenders.add(senderKey);
              // Only store the first successful result; subsequent drains
              // for the same event return no result (dedup), so this map
              // entry is stable.
              decryptedLocations[senderKey] = (
                latitude: location.latitude,
                longitude: location.longitude,
              );
            case LocationMessageResultKindFfi.joined:
            case LocationMessageResultKindFfi.groupUpdate:
            case LocationMessageResultKindFfi.invalidated:
              groupUpdatesProcessed++;
            case LocationMessageResultKindFfi.unrecoverable:
              debugPrint(
                '[SyntheticUser:$label] $context: group entered '
                'Unrecoverable state for evt=${_redactPk(event.id)}',
              );
          }
        }
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
      'distinctSenders=${decryptedSenders.length} '
      'publishedCommits=${publishedCommitEventIds.length} '
      'withheldPendingCommit=$withheldPendingCommit',
    );
    return (
      locationsProcessed: locationsProcessed,
      groupUpdatesProcessed: groupUpdatesProcessed,
      decryptFailed: decryptFailed,
      decryptedLocationSenders: decryptedSenders,
      decryptedLocations: decryptedLocations,
      publishedCommitEventIds: publishedCommitEventIds,
      withheldPendingCommit: withheldPendingCommit,
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

    // `propose_leave` returns a bare SelfRemove *proposal* event JSON — a
    // remaining member commits it later (RFC 9420 §12.1.2), so there is no
    // `PendingStateRef` here to confirm or roll back on publish failure.
    final proposalEventJson = await user.circleManager.proposeLeave(
      mlsGroupId: circle.circle.mlsGroupId,
    );
    final (accepted, msg) = await relay.publishAndAwaitOk(proposalEventJson);
    if (!accepted) {
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

  // NOTE: `clearPendingCommit(Uint8List mlsGroupId)` was removed (Dark
  // Matter DM-4b). It backed the handoff single-committer election's
  // "loser drops its withheld receiver-side auto-commit" step — the Dark
  // Matter engine now owns publish-before-apply AND commit-ordering /
  // convergence entirely internally (via typed `PendingStateRef` tokens
  // scoped to a single publish call, not a Dart-visible per-group pending
  // commit), so there is no longer a Dart-side "pending commit for this
  // group" to discard. See `applyArrivalOrdered`'s `finalizeAutoCommit` doc.

  /// Reads the current MLS epoch for [mlsGroupId] from this peer's local
  /// MDK instance.
  ///
  /// The epoch counter is an unsigned integer that advances by exactly 1 for
  /// every committed MLS operation (Add, Remove, Update, or a receiver-side
  /// auto-commit). It is NOT on the wire (it lives inside the NIP-44-encrypted
  /// kind-445 payload), so reading it per-manager here is the only way to
  /// assert key-rotation progress without decrypting group messages.
  ///
  /// Compiled out of release builds by the debug-assertions gate on the Rust
  /// side. Throws if the group does not exist in this peer's MDK instance.
  ///
  /// Returns an [int] rather than [BigInt] for ergonomic arithmetic in
  /// assertion helpers; MLS epochs are unsigned 64-bit but realistic test
  /// groups stay well within 2^53 (Dart's safe integer range).
  Future<int> currentEpoch(List<int> mlsGroupId) async {
    final epoch = await user.circleManager.groupEpochForTest(
      mlsGroupId: mlsGroupId,
    );
    return epoch.toInt();
  }

  // NOTE: `stageAndFinalizeSelfUpdate` was removed (Dark Matter DM-4b). It
  // called the legacy-path `self_update` FFI method to manufacture racing /
  // out-of-order commits for the M11 concurrent-commit-convergence proxy
  // scenarios in `e2e_combined.dart` — `self_update` (and
  // `finalizePendingCommit`) no longer exist: MIP-02/03 leaf-key rotation
  // is engine-internal under Dark Matter (see `self_update_provider.dart`),
  // and the engine now owns commit-ordering/convergence for concurrent
  // commits internally rather than exposing a Dart-visible stage-then-
  // finalize-without-publish seam to manufacture them. There is no
  // equivalent FFI call left to build this specific race with. The
  // M11-scenario call sites in `e2e_combined.dart` that depended on this
  // (and on the now-removed `clearPendingCommit` election helper) test the
  // concurrent-commit-fork problem class Dark Matter's engine is adopted
  // specifically to own — re-designing that coverage against the new
  // engine belongs with the Rust-side black-box convergence e2e the
  // migration plan calls for (`MDK_DARKMATTER_MIGRATION_PLAN.md` §5.7),
  // not a mechanical Dart port.

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
