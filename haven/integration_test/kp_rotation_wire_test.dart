/// KPR drive target — KeyPackage rotation, proven from a SECOND PARTY's side.
///
/// # What this proves that nothing else does
///
/// `decide_kp_maintenance` (`haven-core/src/relay/maintenance/key_package.rs`)
/// re-mints a KeyPackage once it passes 0.75 of its own MLS `Lifetime`. Every
/// existing test — 21 unit tests on the lifetime reader,
/// `haven-core/tests/kp_rotation_e2e.rs`, the `rust_builder` FFI tests —
/// observes that from the PUBLISHER's side: it asserts what the decision
/// returned and what the publisher published.
///
/// None of that answers the question a user actually hits: can somebody else,
/// fetching the rotated package off a relay, still add me? A rotation that
/// publishes successfully but produces material an inviter rejects at Add time
/// (RFC 9420 §7.2 requires the inviter to validate `not_before`/`not_after`)
/// passes every publisher-side test in the tree.
///
/// So this target asserts the receiving half, end to end and in this order:
///
///   1. Alice mints and publishes her FIRST KeyPackage while the device clock
///      is 70 days in the past (the shell moved it before the drive started).
///   2. The clock is restored to true time — Alice's on-relay package is now
///      genuinely ~83% through its own 84-day `Lifetime`, past the 0.75
///      rotation point and still 14 days short of expiry.
///   3. BOB — a separate participant, own identity, own SQLCipher DB, own MLS
///      state — fetches Alice's package OFF THE RELAY through the production
///      discovery cascade. This is the BASELINE: the lane is watching a real
///      transition, not a fresh account.
///   4. Alice runs the PRODUCTION maintenance tick. The real
///      `decide_kp_maintenance` reads the real `not_before`/`not_after` off
///      the real wire bytes at the real `now`, and rotates.
///   5. Bob re-fetches and gets DIFFERENT material in the SAME `d` slot — the
///      transport binding makes slot reuse a MUST, and the addressable
///      replacement rule means the old package is gone from a fetcher's view.
///   6. Bob adds Alice to a circle USING THE ROTATED PACKAGE, Alice accepts,
///      Bob publishes a location, and ALICE DECRYPTS IT. That last step is the
///      point: a Welcome that is accepted but yields an unusable group is
///      exactly what a "did the Add succeed" check would miss.
///   7. A relay that does not yet serve the slot is added. The tick HEALS —
///      republishing the SAME material under a NEW `created_at`. That pair is
///      the direct wire evidence that the rotation clock lives in the
///      package's `not_before` and not in any event timestamp.
///
/// # Why the device clock, and not a shorter lifetime or a test-only knob
///
/// The 84-day span is not configurable anywhere Haven can reach: `cgka-engine`
/// mints through `MlsKeyPackage::builder()` without ever calling
/// `.key_package_lifetime(...)`, so OpenMLS's `Lifetime::default()` applies,
/// and the engine additionally REJECTS any package whose range exceeds that
/// same maximum. A short-lifetime package would therefore have to be
/// hand-built outside the real mint path — which is the one thing this lane
/// must not do, because the material Bob validates has to be material the
/// production minter produced.
///
/// A test-only rotation-threshold override was rejected on repo precedent
/// (`scripts/ci/check_no_exporter_label_override.sh`): a lever in production
/// code that changes a security-relevant decision is a liability, and one that
/// could make this lane green while the shipped decision never rotated would
/// make the lane worthless.
///
/// Moving the device clock BACKWARDS before the first mint leaves every part
/// of the production path real — the mint, the `Lifetime` it stamps, the
/// lifetime reader, the 0.75 arithmetic, `now`, the publish, and the relay.
/// The only fiction is when the first package was minted, which is precisely
/// the variable under test. A FORWARD jump was not an option: the hermetic
/// strfry sets `rejectEventsNewerThanSeconds = 900` (`tooling/e2e/strfry.conf`,
/// and the B8 lane leans on it), so a device 70 days ahead cannot publish at
/// all.
///
/// Nothing here can go green without the production code rotating: the
/// pre-fix `decide_kp_maintenance` had no time awareness, so with every
/// responder already serving the slot it returned `NoOp` — the tick reports
/// `alreadyHealthy`, no new event reaches the relay, and Bob's re-fetch
/// returns the byte-identical package he already had. Steps 4 and 5 are
/// independent: one reads the decision, the other reads the relay.
library;

import 'dart:convert' show jsonDecode;
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/rust/api.dart'
    show
        CircleCreationResultFfi,
        CircleWithMembersFfi,
        KpMaintenanceActionFfi,
        KpMaintenanceOutcomeFfi,
        MemberKeyPackageFfi,
        RelayManagerFfi,
        RelayTypeFfi;
import 'package:integration_test/integration_test.dart';

import 'e2e/_lib/circle_creation.dart' show createCircleConfirmed;
import 'e2e/_lib/coordination.dart' show waitForKeyPackage;
import 'e2e/_lib/fake_location_service.dart'
    show bobFakeLatitude, bobFakeLongitude;
import 'e2e/_lib/scenario_harness.dart' show ScenarioHarness;
import 'e2e/_lib/synthetic_user.dart' show SyntheticUser;
import 'e2e/_lib/test_relay.dart'
    show TestRelay, TestRelayEvent, defaultStrfryUrl, secondStrfryUrl;
import 'e2e/_lib/test_user.dart' show aliceSeed;
import 'e2e/_lib/throw_time_error_capture.dart';

// ===========================================================================
// Markers — owned by THIS file. Every literal below is matched, verbatim and
// as a FIXED STRING, by tooling/e2e/ci/run-kp-rotation.sh. Change one without
// changing the other and the lane silently stops finding its own evidence.
//
// Every negative twin is a DISTINCT string rather than a suffix or prefix of
// its positive (`ROTATED` is not a substring of `ROTATION_DECLINED`), so a
// substring match can never read one as the other.
//
// Markers carry booleans, counts and DELTAS — never a `d` slot, an event id,
// a pubkey or a coordinate. The drive log is uploaded as a CI artifact.
// ===========================================================================

/// Asks the shell's clock servo for a wall-clock offset: `<seq> <offsetSecs>`.
const String kReqClockMarker = '[kpr] REQ_CLOCK';

/// Alice's FIRST KeyPackage reached the relay under the backdated clock.
const String kBaselineMintedMarker = '[kpr] BASELINE_MINTED';

/// Nothing of Alice's ever reached the relay — there is nothing to rotate.
const String kBaselineMintFailedMarker = '[kpr] BASELINE_MINT_FAILED';

/// The drive OBSERVED the wall clock jump forward (independent of the servo).
const String kClockRestoredMarker = '[kpr] CLOCK_RESTORED';

/// The wall clock never moved — every phase below would run at the wrong time.
const String kClockRestoreTimeoutMarker = '[kpr] CLOCK_RESTORE_TIMEOUT';

/// Bob fetched the PRE-rotation package off the relay. The lane's baseline.
const String kBaselineFetchedMarker = '[kpr] BASELINE_FETCHED';

/// Bob could not fetch anything for Alice before the rotation.
const String kBaselineUnfetchableMarker = '[kpr] BASELINE_UNFETCHABLE';

/// The production maintenance tick rotated the expiring material.
const String kRotatedMarker = '[kpr] ROTATED';

/// The production tick did NOT rotate — the pre-fix behaviour.
const String kRotationDeclinedMarker = '[kpr] ROTATION_DECLINED';

/// Bob's re-fetch returned new material in the same slot.
const String kSupersededMarker = '[kpr] SUPERSEDED';

/// Bob's re-fetch did not show a clean supersession.
const String kSupersedeFailedMarker = '[kpr] SUPERSEDE_FAILED';

/// Alice applied the Welcome Bob built from the ROTATED package.
const String kWelcomeAcceptedMarker = '[kpr] WELCOME_ACCEPTED';

/// Alice could not join the circle Bob created from the rotated package.
const String kWelcomeFailedMarker = '[kpr] WELCOME_FAILED';

/// Alice DECRYPTED a location Bob sent into that group.
const String kPeerDecryptMatchMarker = '[kpr] PEER_DECRYPT_MATCH';

/// Alice joined but never decrypted anything — an accepted-but-dead group.
const String kPeerDecryptDeadMarker = '[kpr] PEER_DECRYPT_DEAD';

/// A relay that does not serve Alice's slot is now in her KeyPackage set.
const String kHealTargetAddedMarker = '[kpr] HEAL_TARGET_ADDED';

/// The tick healed the under-served relay.
const String kHealedMarker = '[kpr] HEALED';

/// The tick did not heal the under-served relay.
const String kHealDeclinedMarker = '[kpr] HEAL_DECLINED';

/// The heal republished IDENTICAL material under a NEWER `created_at`.
const String kHealMaterialStableMarker = '[kpr] HEAL_MATERIAL_STABLE';

/// The heal re-minted instead of republishing — the rotation clock moved.
const String kHealMaterialRotatedMarker = '[kpr] HEAL_MATERIAL_ROTATED';

/// The drive reached the end of its own sequence.
const String kSequenceCompleteMarker = '[kpr] SEQUENCE_COMPLETE';

// ===========================================================================
// Protocol constants mirrored from outside Dart.
// ===========================================================================

/// The MLS `Lifetime` span OpenMLS stamps on a freshly minted KeyPackage:
/// 84 days plus the 1-hour `not_before` margin
/// (`openmls-0.8.1/src/key_packages/lifetime.rs`), which is also the maximum
/// `cgka-engine` accepts on receive.
///
/// Hardcoded here because no FFI exposes it, and deliberately so: if the
/// upstream default ever moves, this lane fails on its own `elapsedPct`
/// assertion with a named reason rather than quietly becoming vacuous.
const int kMlsKeyPackageLifetimeSpanSecs = 7261200;

/// `KP_ROTATE_AT_LIFETIME_FRACTION`, as a percentage — mirrored from
/// `haven-core/src/relay/maintenance/kp_lifetime.rs`.
const int kRotationThresholdPct = 75;

/// A wall-clock discontinuity this large cannot be ordinary drive latency, so
/// observing one is proof the servo really moved the device clock.
const Duration kMinObservableClockJump = Duration(days: 1);

// ===========================================================================
// A KeyPackage as a FETCHER sees it: the four wire fields that distinguish
// "the same package again" from "new material in the same slot".
// ===========================================================================

/// The four kind-30443 wire fields this lane compares across a rotation.
class _WirePackage {
  const _WirePackage({
    required this.eventId,
    required this.dSlot,
    required this.material,
    required this.createdAt,
  });

  /// Parses the four fields out of a kind-30443 event JSON object.
  ///
  /// Throws [StateError] when the payload is not a well-formed addressable
  /// KeyPackage event, because every comparison below would otherwise silently
  /// compare two empty strings and pass.
  factory _WirePackage.fromEventJson(String eventJson, String label) {
    final Object? decoded = jsonDecode(eventJson);
    if (decoded is! Map<String, dynamic>) {
      throw StateError('[kpr] $label: KeyPackage event is not a JSON object.');
    }
    final Object? id = decoded['id'];
    final Object? content = decoded['content'];
    final Object? createdAt = decoded['created_at'];
    if (id is! String || content is! String || createdAt is! int) {
      throw StateError(
        '[kpr] $label: KeyPackage event is missing id/content/created_at.',
      );
    }
    if (content.isEmpty) {
      throw StateError('[kpr] $label: KeyPackage event carries no material.');
    }
    return _WirePackage(
      eventId: id,
      dSlot: _dTagOf(decoded['tags'], label),
      material: content,
      createdAt: createdAt,
    );
  }

  /// Builds from an event already observed through [TestRelay].
  factory _WirePackage.fromRelayEvent(TestRelayEvent event, String label) {
    final Object? content = event.raw['content'];
    if (content is! String || content.isEmpty) {
      throw StateError('[kpr] $label: on-relay KeyPackage carries no content.');
    }
    final d = event.tag('d');
    if (d == null || d.length < 2 || d[1].isEmpty) {
      throw StateError('[kpr] $label: on-relay KeyPackage has no `d` tag.');
    }
    return _WirePackage(
      eventId: event.id,
      dSlot: d[1],
      material: content,
      createdAt: event.createdAt,
    );
  }

  static String _dTagOf(Object? tags, String label) {
    if (tags is List) {
      for (final dynamic tag in tags) {
        if (tag is List && tag.length >= 2) {
          final key = tag[0];
          final value = tag[1];
          if (key == 'd' && value is String && value.isNotEmpty) return value;
        }
      }
    }
    throw StateError(
      '[kpr] $label: KeyPackage event has no `d` tag. The transport binding '
      'makes the addressable slot a MUST, so this is a protocol violation, '
      'not a test-harness problem.',
    );
  }

  /// The kind-30443 event id.
  final String eventId;

  /// The addressable `d` slot the package occupies.
  final String dSlot;

  /// The base64 MLS KeyPackage wire bytes. Identical bytes mean an identical
  /// `Lifetime`, so this doubles as the "was the material re-minted" oracle.
  final String material;

  /// The event's `created_at`, in Unix seconds.
  final int createdAt;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'KPR: a rotated KeyPackage is fetchable, addable and usable by a peer',
    (_) async {
      installThrowTimeErrorLogging();
      // The lane moves the ANDROID emulator wall clock through `adb shell
      // date` under `adb root`. A simulator has no equivalent that survives
      // `simctl`, so there is no iOS twin of this lane.
      if (!Platform.isAndroid) {
        markTestSkipped(
          'kp_rotation_wire_test drives the Android emulator wall clock to '
          'age a KeyPackage past its rotation threshold; skipped on '
          'non-Android runtimes.',
        );
        return;
      }

      final ctx = await ScenarioHarness.bootstrap();
      final relay = ctx.relay;

      // Monotonic reference for the clock-jump observation below. Captured
      // BEFORE anything else so the whole of phase 1 is inside the window.
      final wallClockAtStart = DateTime.now();
      final sinceStart = Stopwatch()..start();

      SyntheticUser? alice;
      SyntheticUser? bob;
      RelayManagerFfi? relayManager;
      TestRelay? healRelay;

      try {
        // -------------------------------------------------------------------
        // Phase 1 — mint the baseline package under the BACKDATED clock.
        //
        // `SyntheticUser.bootstrap` seeds the account's own NIP-65 set with
        // the hermetic relay and then runs the production
        // `maintain_key_package` tick — the ONE publish path for KeyPackage
        // material since Dark Matter. It throws if nothing was acked, so
        // reaching the next line already means a package landed; the relay
        // read below is the independent, wire-side confirmation.
        // -------------------------------------------------------------------
        alice = await SyntheticUser.bootstrap(
          label: 'alice',
          seed: aliceSeed,
          relay: relay,
        );

        final baselineOnRelay = await relay.collectN(
          count: 1,
          filter: <String, dynamic>{
            'kinds': const <int>[30443],
            'authors': <String>[alice.pubkeyHex],
          },
          timeout: const Duration(seconds: 45),
        );
        if (baselineOnRelay.isEmpty) {
          debugPrint(kBaselineMintFailedMarker);
          throw StateError(
            '[kpr] no kind-30443 for Alice reached the hermetic relay under '
            'the backdated clock. Nothing was published, so there is nothing '
            'for the rotation to supersede and every later verdict would be '
            'vacuous.',
          );
        }
        final onRelayBaseline = _WirePackage.fromRelayEvent(
          baselineOnRelay.first,
          'baseline',
        );
        debugPrint('$kBaselineMintedMarker onRelay=${baselineOnRelay.length}');

        // -------------------------------------------------------------------
        // Phase 2 — ask the shell to restore true time, and OBSERVE the jump.
        //
        // The servo's own adb read-back proves the device clock now equals
        // host time; that check lives in the shell. This check is
        // deliberately separate and weaker-but-independent: it proves the
        // clock the APP reads discontinuously moved forward. A servo that
        // set a clock nothing under test could see, and a drive that never
        // asked, are different failures with different fixes.
        // -------------------------------------------------------------------
        final jump = await _awaitClockJump(
          wallClockAtStart: wallClockAtStart,
          sinceStart: sinceStart,
          minJump: kMinObservableClockJump,
          timeout: const Duration(seconds: 180),
        );
        if (jump == null) {
          debugPrint(kClockRestoreTimeoutMarker);
          throw StateError(
            '[kpr] the device wall clock never jumped forward. The shell '
            "servo did not fulfil the REQ_CLOCK request, so Alice's package "
            'is still only seconds old and no rotation is due — the lane '
            'would prove nothing.',
          );
        }
        debugPrint('$kClockRestoredMarker jumpedSecs=${jump.inSeconds}');

        // -------------------------------------------------------------------
        // Phase 3 — Bob, and the BASELINE fetch.
        //
        // Bob is a genuinely separate participant: his own identity, his own
        // temp data dir and therefore his own SQLCipher database, MLS state
        // and cursor store. He reads Alice's package through the PRODUCTION
        // discovery cascade over a real WebSocket, not from a Dart variable.
        // -------------------------------------------------------------------
        bob = await SyntheticUser.bob(relay);
        await waitForKeyPackage(relay: relay, authorPubkeyHex: bob.pubkeyHex);

        relayManager = await RelayManagerFfi.newInstance();

        final fetchedBaseline = await relayManager.fetchMemberKeypackage(
          pubkey: alice.pubkeyHex,
        );
        if (fetchedBaseline == null) {
          debugPrint(kBaselineUnfetchableMarker);
          throw StateError(
            "[kpr] Bob could not fetch Alice's PRE-rotation KeyPackage. "
            'Without it the lane cannot claim to have watched a transition '
            'rather than a fresh account.',
          );
        }
        final baseline = _WirePackage.fromEventJson(
          fetchedBaseline.keyPackageJson,
          'baseline-fetch',
        );

        // How far through its own Lifetime the baseline material is, derived
        // ENTIRELY from the wire: `created_at` is the mint instant (the first
        // publish has no previous stamp for `monotonic_kp_created_at` to
        // raise), and OpenMLS sets `not_before` one hour EARLIER than that,
        // so this understates the true elapsed fraction by ~0.05% — the safe
        // direction for the lower bound below.
        final nowSecs = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        final elapsedSecs = nowSecs - baseline.createdAt;
        final elapsedPct =
            (elapsedSecs * 100) ~/ kMlsKeyPackageLifetimeSpanSecs;
        debugPrint(
          '$kBaselineFetchedMarker elapsedPct=$elapsedPct '
          'ageDays=${elapsedSecs ~/ 86400} '
          'slotStable=${baseline.dSlot == onRelayBaseline.dSlot}',
        );
        expect(
          elapsedPct,
          greaterThan(kRotationThresholdPct),
          reason:
              '[kpr] the baseline material is only $elapsedPct% through its '
              'MLS Lifetime, below the $kRotationThresholdPct% rotation '
              'point. The shell backdated the clock by too little, or the '
              'upstream default Lifetime changed. Nothing below would be a '
              'rotation observation.',
        );
        expect(
          elapsedPct,
          lessThan(100),
          reason:
              '[kpr] the baseline material is $elapsedPct% through its MLS '
              'Lifetime, i.e. EXPIRED. The tick would then re-mint because '
              'the lifetime reads as not-current, which is a different code '
              'path from the 0.75 threshold this lane exists to prove. '
              'Reduce the shell backdate.',
        );

        // -------------------------------------------------------------------
        // Phase 4 — the production rotation decision, on real material.
        // -------------------------------------------------------------------
        final rotation = await _runMaintenance(alice, relayManager);
        if (rotation.action != KpMaintenanceActionFfi.rotatedExpiringMaterial) {
          debugPrint('$kRotationDeclinedMarker action=${rotation.action.name}');
          throw StateError(
            '[kpr] the production maintenance tick returned '
            '${rotation.action.name} for material $elapsedPct% through its '
            'own MLS Lifetime. `alreadyHealthy` here is the pre-fix '
            'behaviour: every responder serves the slot, so a decision with '
            'no time awareness reports nothing to do while the account '
            'silently ages out of being invitable.',
          );
        }
        debugPrint(
          '$kRotatedMarker action=${rotation.action.name} '
          'healed=${rotation.relaysHealed} '
          'probed=${rotation.respondersProbed}',
        );
        expect(
          rotation.relaysHealed,
          greaterThanOrEqualTo(1),
          reason:
              '[kpr] the tick chose to rotate but no relay acked the '
              'publish. The action names the branch that RAN and is chosen '
              'before the write is attempted, so a Rotated* action with zero '
              'heals is a rotation nobody received.',
        );

        // -------------------------------------------------------------------
        // Phase 5 — supersession, from a FETCHER's point of view.
        // -------------------------------------------------------------------
        final rotated = await _awaitDifferentPackage(
          relayManager: relayManager,
          pubkey: alice.pubkeyHex,
          previousEventId: baseline.eventId,
          timeout: const Duration(seconds: 60),
        );
        if (rotated == null) {
          debugPrint('$kSupersedeFailedMarker reason=unchanged');
          throw StateError(
            '[kpr] the tick reported a rotation but Bob keeps fetching the '
            "same event id. From a peer's point of view nothing was "
            'superseded.',
          );
        }
        if (rotated.dSlot != baseline.dSlot) {
          debugPrint('$kSupersedeFailedMarker reason=slot_changed');
          throw StateError(
            '[kpr] the rotated package landed in a DIFFERENT addressable '
            'slot. The transport binding makes reuse of the stable `d` a '
            'MUST: a new slot leaves the old package addressable and live '
            'alongside the new one instead of replacing it.',
          );
        }
        if (rotated.material == baseline.material) {
          debugPrint('$kSupersedeFailedMarker reason=material_reused');
          throw StateError(
            '[kpr] the "rotated" event carries byte-identical KeyPackage '
            'material. That is a HEAL — cached bytes republished under a new '
            'event id — not a re-mint, so the expiring `Lifetime` is '
            'unchanged and the account still ages out.',
          );
        }
        debugPrint(
          '$kSupersededMarker dSame=true idChanged=true '
          'materialChanged=true '
          'dCreatedAt=${rotated.createdAt - baseline.createdAt}',
        );

        // -------------------------------------------------------------------
        // Phase 6 — THE DELIVERABLE. Bob adds Alice with the ROTATED package,
        // and Alice decrypts what follows.
        //
        // Bob is the inviter, so it is BOB's engine that validates Alice's
        // `not_before`/`not_after` at Add time — the check RFC 9420 requires
        // and the one the whole 84-day defect turns on.
        // -------------------------------------------------------------------
        final rotatedKp = await relayManager.fetchMemberKeypackage(
          pubkey: alice.pubkeyHex,
        );
        if (rotatedKp == null) {
          debugPrint('$kSupersedeFailedMarker reason=refetch_null');
          throw StateError(
            "[kpr] Alice's rotated KeyPackage vanished from the relay "
            'between the supersession check and the Add.',
          );
        }

        final CircleCreationResultFfi creation;
        final bobSecret = await bob.user.getSecretBytes();
        try {
          // Rule 13: publishes Alice's Welcome and CONFIRMS the staged
          // create. An unconfirmed create pins the group in MDK
          // PendingPublish, where every inbound kind-445 buffers forever.
          creation = await createCircleConfirmed(
            manager: bob.user.circleManager,
            relay: relay,
            identitySecretBytes: bobSecret,
            members: <MemberKeyPackageFfi>[rotatedKp],
            name: 'KPR Rotation Circle',
            circleType: 'location_sharing',
            relays: <String>[defaultStrfryUrl],
            creatorFallbackRelays: <String>[defaultStrfryUrl],
            label: 'kpr',
          );
        } on Object {
          // The Add itself is the RFC 9420 validation point, so a throw here
          // is the headline failure this lane exists to catch. Name it before
          // rethrowing so the shell attributes it correctly.
          debugPrint(kWelcomeFailedMarker);
          rethrow;
        } finally {
          // Security Rule 9: minimise the Dart-side secret's lifetime.
          for (var i = 0; i < bobSecret.length; i++) {
            bobSecret[i] = 0;
          }
        }

        final CircleWithMembersFfi aliceCircle;
        try {
          aliceCircle = await alice.acceptInvitationViaRelay(relay: relay);
        } on Object {
          debugPrint(kWelcomeFailedMarker);
          rethrow;
        }
        debugPrint(kWelcomeAcceptedMarker);

        final bobCircle = await bob.getCircle(creation.circle.mlsGroupId);
        if (bobCircle == null) {
          debugPrint(kPeerDecryptDeadMarker);
          throw StateError(
            '[kpr] Bob cannot resolve the circle he just created.',
          );
        }
        await bob.publishLocation(
          circle: bobCircle,
          latitude: bobFakeLatitude,
          longitude: bobFakeLongitude,
          relay: relay,
        );

        final decrypted = await _awaitPeerLocation(
          reader: alice,
          relay: relay,
          circle: aliceCircle,
          senderPubkeyHex: bob.pubkeyHex,
          timeout: const Duration(seconds: 120),
        );
        if (decrypted == null) {
          debugPrint(kPeerDecryptDeadMarker);
          throw StateError(
            '[kpr] Alice joined through the rotated KeyPackage but never '
            'decrypted a message in the resulting group. An accepted Welcome '
            'that yields an unusable group is exactly the failure a '
            '"did the Add succeed" check would miss.',
          );
        }
        // Deltas, never coordinates: the drive log is an uploaded artifact
        // and the kind-445 that carried these was encrypted at MLS.
        debugPrint(
          '$kPeerDecryptMatchMarker '
          'dLat=${(decrypted.latitude - bobFakeLatitude).abs()} '
          'dLon=${(decrypted.longitude - bobFakeLongitude).abs()}',
        );

        // -------------------------------------------------------------------
        // Phase 7 — a heal moves the EVENT timestamp and nothing else.
        //
        // Adding a relay that does not yet serve Alice's slot is, to
        // `decide_kp_maintenance`, indistinguishable from a relay that
        // dropped the event: either way a responder does not serve the slot,
        // so the tick republishes the CACHED bytes under a fresh
        // `created_at`. Reading both back off the second relay is the direct
        // wire evidence that a heal advances the event timestamp while
        // leaving the material — and therefore `not_before`, and therefore
        // the rotation clock — exactly where it was.
        //
        // `add_user_relay` is a local DB write with no publish of its own, so
        // the tick below is genuinely the first thing to see the new relay.
        // -------------------------------------------------------------------
        await alice.user.circleManager.addUserRelay(
          url: secondStrfryUrl,
          relayType: RelayTypeFfi.nip65,
        );
        debugPrint(kHealTargetAddedMarker);

        final heal = await _runMaintenance(alice, relayManager);
        if (heal.action != KpMaintenanceActionFfi.republishedStableD) {
          debugPrint('$kHealDeclinedMarker action=${heal.action.name}');
          throw StateError(
            "[kpr] a relay that does not serve Alice's slot was added and "
            'the tick returned ${heal.action.name} instead of '
            'republishedStableD. The freshly rotated material is nowhere '
            'near its rotation point, so the heal branch is the only correct '
            'answer.',
          );
        }
        debugPrint(
          '$kHealedMarker action=${heal.action.name} '
          'healed=${heal.relaysHealed}',
        );
        expect(
          heal.relaysHealed,
          greaterThanOrEqualTo(1),
          reason:
              '[kpr] the tick chose to heal but no relay acked the publish.',
        );

        healRelay = await TestRelay.connect(url: secondStrfryUrl);
        final healedEvents = await healRelay.collectN(
          count: 1,
          filter: <String, dynamic>{
            'kinds': const <int>[30443],
            'authors': <String>[alice.pubkeyHex],
          },
          timeout: const Duration(seconds: 45),
        );
        if (healedEvents.isEmpty) {
          debugPrint('$kHealDeclinedMarker action=nothing_on_second_relay');
          throw StateError(
            '[kpr] the tick reported a heal but the second relay serves no '
            'KeyPackage for Alice.',
          );
        }
        final healed = _WirePackage.fromRelayEvent(
          healedEvents.first,
          'healed',
        );
        if (healed.material != rotated.material) {
          debugPrint(kHealMaterialRotatedMarker);
          throw StateError(
            '[kpr] the heal published DIFFERENT material. A heal must reuse '
            'the cached bytes; re-minting here would restart the Lifetime on '
            'every relay hiccup, which is precisely the reset this lane '
            'exists to rule out.',
          );
        }
        expect(
          healed.createdAt,
          greaterThan(rotated.createdAt),
          reason:
              '[kpr] the healed event does not carry a newer `created_at`. '
              'Without that the pair proves nothing: the whole point is that '
              'the EVENT timestamp moves while the material does not.',
        );
        expect(
          healed.dSlot,
          rotated.dSlot,
          reason: '[kpr] the heal republished into a different `d` slot.',
        );
        debugPrint(
          '$kHealMaterialStableMarker materialSame=true '
          'createdAtAdvanced=true dSame=true '
          'dCreatedAt=${healed.createdAt - rotated.createdAt}',
        );

        debugPrint(kSequenceCompleteMarker);
      } finally {
        // Best-effort teardown. A throw here would replace the real failure
        // with a teardown error and lose the diagnosis.
        try {
          if (relayManager != null) await relayManager.shutdown();
        } on Object catch (e) {
          debugPrint('[kpr] relay-manager shutdown failed: ${e.runtimeType}');
        }
        try {
          if (healRelay != null) await healRelay.dispose();
          await bob?.dispose();
          await alice?.dispose();
          await relay.dispose();
        } on Object catch (e) {
          debugPrint('[kpr] teardown failed: ${e.runtimeType}');
        }
      }
    },
    // Stays BELOW the orchestrator's per-drive KPR_DRIVE_TIMEOUT (24m) so a
    // genuine overrun fails HERE, with a named test and a readable reason,
    // rather than as an anonymous `flutter drive` kill.
    timeout: const Timeout(Duration(minutes: 20)),
  );
}

/// Runs the production KeyPackage maintenance tick for [user].
///
/// Re-fetches the identity secret per call and scrubs the Dart-side buffer in
/// a `finally` (Security Rule 9) — the same posture `MaintenanceService` uses.
Future<KpMaintenanceOutcomeFfi> _runMaintenance(
  SyntheticUser user,
  RelayManagerFfi relayManager,
) async {
  final secret = await user.user.getSecretBytes();
  try {
    return await relayManager.maintainKeyPackage(
      circle: user.user.circleManager,
      identitySecretBytes: secret,
    );
  } finally {
    for (var i = 0; i < secret.length; i++) {
      secret[i] = 0;
    }
  }
}

/// Asks the shell servo to restore true time and waits for the app-visible
/// wall clock to jump forward by at least [minJump].
///
/// Returns the observed discontinuity, or `null` if none appeared inside
/// [timeout].
///
/// The request is RE-EMITTED while waiting: the servo polls a growing logcat
/// capture, and a single line lost to a truncated read would otherwise wedge
/// the lane for the whole window.
///
/// [sinceStart] must be a monotonic [Stopwatch] started at the same moment
/// [wallClockAtStart] was sampled. The deadline is measured on the stopwatch,
/// never on `DateTime.now()`, because the whole point is that the latter is
/// about to move.
Future<Duration?> _awaitClockJump({
  required DateTime wallClockAtStart,
  required Stopwatch sinceStart,
  required Duration minJump,
  required Duration timeout,
}) async {
  const seq = 1;
  final started = sinceStart.elapsed;
  var lastRequest = Duration.zero;
  while (sinceStart.elapsed - started < timeout) {
    if (lastRequest == Duration.zero ||
        sinceStart.elapsed - lastRequest >= const Duration(seconds: 10)) {
      // Offset 0 == "set the device clock to host time", i.e. undo the
      // backdate the shell applied before the drive.
      debugPrint('$kReqClockMarker $seq 0');
      lastRequest = sinceStart.elapsed;
    }
    final observed =
        DateTime.now().difference(wallClockAtStart) - sinceStart.elapsed;
    if (observed >= minJump) return observed;
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  return null;
}

/// Polls the production discovery cascade until it returns a KeyPackage event
/// whose id differs from [previousEventId].
///
/// Returns `null` when the fetch never changed inside [timeout] — which is
/// the "the tick claimed to rotate but nobody can see it" case, and must stay
/// distinguishable from a fetch that failed outright.
Future<_WirePackage?> _awaitDifferentPackage({
  required RelayManagerFfi relayManager,
  required String pubkey,
  required String previousEventId,
  required Duration timeout,
}) async {
  final sw = Stopwatch()..start();
  while (sw.elapsed < timeout) {
    final fetched = await relayManager.fetchMemberKeypackage(pubkey: pubkey);
    if (fetched != null) {
      final pkg = _WirePackage.fromEventJson(
        fetched.keyPackageJson,
        'rotated-fetch',
      );
      if (pkg.eventId != previousEventId) return pkg;
    }
    await Future<void>.delayed(const Duration(seconds: 2));
  }
  return null;
}

/// Drains kind-445 traffic for [circle] until [reader] decrypts a location
/// from [senderPubkeyHex].
///
/// Returns the decrypted coordinates, or `null` if none arrived inside
/// [timeout].
Future<({double latitude, double longitude})?> _awaitPeerLocation({
  required SyntheticUser reader,
  required TestRelay relay,
  required CircleWithMembersFfi circle,
  required String senderPubkeyHex,
  required Duration timeout,
}) async {
  final sw = Stopwatch()..start();
  while (sw.elapsed < timeout) {
    final summary = await reader.drainPendingCommits(
      relay: relay,
      circle: circle,
    );
    final hit = summary.decryptedLocations[senderPubkeyHex];
    if (hit != null) return hit;
    await Future<void>.delayed(const Duration(seconds: 3));
  }
  return null;
}
