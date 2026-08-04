/// B8 drive target — publishes and receives across a +/-6 h device clock
/// jump (`docs/CI_HARDENING_BACKLOG.md`, Workstream B, item B8:
/// "Clock jump +/-6h ... exercises `created_at`, the 228 s TTL,
/// `since`-cursor catch-up").
///
/// ## What is actually clock-dependent (verified from source, not assumed)
///
/// Every wall-clock dependency on the send and receive paths bottoms out in
/// one unguarded `SystemTime::now()` / `Timestamp::now()`:
///
///   * **`created_at`** — the MDK peeler stamps the inner app event with
///     `now_unix_seconds()` (`transport-nostr-peeler/src/event.rs:180,217`)
///     and BINDS the outer kind-445 `created_at` to it
///     (`peeler.rs:169`, Package E). No monotonic source, no relay-time
///     correction, and nothing anywhere in `haven-core` or `haven/lib`
///     compares the device clock against any external reference.
///   * **The 228 s TTL** — Haven stamps every circle with the Dark Matter
///     `message-retention.v1` component
///     (`LOCATION_MESSAGE_RETENTION_SECS = 228`,
///     `haven-core/src/location/ttl.rs:80`), and the engine derives the
///     outer NIP-40 `expiration` as `inner_created_at + retention` for
///     APPLICATION messages. So the TTL rides the same skewed clock as
///     `created_at` — a backdated event is born already expired.
///   * **The receiver gate** — `SessionManager::process_event`
///     (`haven-core/src/nostr/mls/manager.rs:594-624`) drops any event whose
///     expiration is more than `RECEIVER_EXPIRATION_GRACE_SECS = 60` s in the
///     receiver's past, BEFORE any decryption, and reports it as `Stale`.
///   * **The `since` cursor** — `run_catchup_all_circles`
///     (`haven-core/src/relay/catchup.rs:288-349`) advances the persisted
///     cursor to the SENDER's `created_at`, and `since_for_stream`
///     (`haven-core/src/relay/cursor.rs:114-130`) re-derives the next REQ
///     floor as `cursor - GROUP_RESUBSCRIBE_BUFFER_SECS` (60 s), capped to
///     the receiver's `now`.
///
/// ## What this target proves, and why one device is enough
///
/// The publisher and the receiver share this device's wall clock, so a
/// naive "jump the clock and have a peer decrypt" scenario is VACUOUS: both
/// sides move together and every comparison stays self-consistent. The
/// asymmetry this target uses instead is asymmetry in TIME, plus the one
/// genuinely independent clock in the lane — the hermetic strfry relay,
/// which runs on the CI host and never moves:
///
///   * a publish issued while the device runs FAST is judged by the relay's
///     own `rejectEventsNewerThanSeconds` (`tooling/e2e/strfry.conf:16`),
///     i.e. by a correctly-clocked observer;
///   * a publish issued while the device runs SLOW is READ BACK after the
///     clock is restored, so the receiver-side gate and the `since` floor
///     are evaluated at TRUE time against an event minted at skewed time.
///
/// The clock itself is moved by the shell
/// (`tooling/e2e/ci/run-b8-clock-skew.sh`) on cue: this body prints
/// `[b8] REQ_CLOCK <seq> <offsetSecs>` and then POLLS its own wall clock
/// against a monotonic [Stopwatch] until it observes the jump, so the
/// rendezvous is an observation rather than a blind sleep. A jump that never
/// arrives is reported as a HARNESS failure, never as a product finding.
///
/// ## Findings are accumulated, not thrown
///
/// Every oracle records into `findings` and the body runs to completion, so
/// ONE run reports every defect rather than stopping at the first. Genuine
/// harness failures (the clock never moved, the baseline never worked, the
/// premise no longer holds) still throw immediately — a run whose machinery
/// is broken must not be readable as a product verdict.
///
/// EXPECT THIS LANE TO FAIL until the skew defects it names are fixed. That
/// is the deliverable, exactly as for B1. Do not relax an assertion to make
/// it green (CLAUDE.md, Testing Requirements #5).
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/rust/api.dart'
    show
        CircleCreationResultFfi,
        CircleFfi,
        LocationMessageResultKindFfi,
        MemberKeyPackageFfi,
        RelayManagerFfi;
import 'package:integration_test/integration_test.dart';

import 'e2e/_lib/circle_creation.dart' show createCircleConfirmed;
import 'e2e/_lib/coordination.dart' show waitForKeyPackage;
import 'e2e/_lib/scenario_harness.dart';
import 'e2e/_lib/synthetic_user.dart' show SyntheticUser;
import 'e2e/_lib/test_relay.dart'
    show TestRelay, TestRelayEvent, defaultStrfryUrl;
import 'e2e/_lib/test_user.dart' show TestUser, bytesToHex;

// ---------------------------------------------------------------------------
// Markers. Every literal here is matched by `run-b8-clock-skew.sh`; changing
// one without changing the shell silently disarms the lane's oracle.
// ---------------------------------------------------------------------------

/// Asks the shell to set the device wall clock to `true_now + offsetSecs`.
const String kReqClockMarker = '[b8] REQ_CLOCK';

/// Emitted once this process has OBSERVED the requested jump on its own
/// clock. The shell asserts one of these per request.
const String kClockObservedMarker = '[b8] CLOCK_OBSERVED';

/// Emitted when a requested jump never arrived. A harness failure.
const String kClockTimeoutMarker = '[b8] CLOCK_TIMEOUT';

/// One recorded defect. The shell fails the lane if any appears.
const String kFindingMarker = '[b8] FINDING';

/// Terminal marker. Its ABSENCE means the body died early, which invalidates
/// every negative result above it.
const String kAllPhasesMarker = '[b8] ALL_PHASES_COMPLETE';

// ---------------------------------------------------------------------------
// Timings
// ---------------------------------------------------------------------------

/// The skew magnitude the backlog item specifies.
const Duration _skew = Duration(hours: 6);

/// How long to wait for the shell to land a requested jump. Generous: the
/// servo polls logcat, shells out to `adb`, and re-verifies the read-back.
const Duration _clockJumpTimeout = Duration(seconds: 150);

/// Poll interval while watching for the jump.
const Duration _clockPollInterval = Duration(milliseconds: 500);

/// Tolerance when matching an observed jump against the requested delta.
/// `date` sets whole seconds and the servo re-verifies before returning, so
/// a few seconds of slop is normal; 90 s is far below the 6 h signal and far
/// above any plausible latency.
const Duration _clockMatchTolerance = Duration(seconds: 90);

/// Deadline for one `runCatchupAllCircles` sweep.
const int _sweepSecs = 30;

/// The retention the circle is stamped with. Mirrors
/// `LOCATION_MESSAGE_RETENTION_SECS` — asserted, not assumed, in phase 1.
const int _expectedRetentionSecs = 228;

// ---------------------------------------------------------------------------
// Sentinel coordinates — one per publish, so a snapshot read can tell which
// location it is holding. Public landmarks, deliberately not anyone's real
// position; the kind-445 carrying them is MLS-encrypted on the wire and they
// are never written to a log line.
// ---------------------------------------------------------------------------
const ({double lat, double lon}) _coordsBaseline = (lat: 52.3702, lon: 4.8952);
const ({double lat, double lon}) _coordsFast = (lat: 48.8584, lon: 2.2945);
const ({double lat, double lon}) _coordsSlow = (lat: 41.9028, lon: 12.4964);
const ({double lat, double lon}) _coordsRestored = (lat: 59.9139, lon: 10.7522);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // testWidgets, not bare `test`: only a testWidgets body's failure is
  // recorded by the integration binding and can turn `flutter drive` red
  // (drive-log-lib.sh). This body pumps no widget tree — it drives the FFI
  // and the relay directly, like m7_worker_setup_test.dart — so `tester` is
  // intentionally unused.
  testWidgets(
    'B8: location survives a +/-6h device clock jump',
    (tester) async {
      final findings = <String>[];
      final clock = _ClockServo();

      void record(String phase, String detail) {
        final line = '$kFindingMarker $phase: $detail';
        debugPrint(line);
        findings.add('$phase: $detail');
      }

      final ctx = await ScenarioHarness.bootstrap();
      final relay = ctx.relay;
      final relayManager = await RelayManagerFfi.newInstance();

      // Alice publishes; Bob receives. Two CircleManagerFfi instances over
      // two temp data dirs (the standard SyntheticUser arrangement), so
      // Bob's cursor store and MLS state are genuinely his own.
      final alice = await TestUser.alice();
      final bob = await SyntheticUser.bob(relay);
      await waitForKeyPackage(relay: relay, authorPubkeyHex: bob.pubkeyHex);

      final bobKp = await relayManager.fetchMemberKeypackage(
        pubkey: bob.pubkeyHex,
      );
      if (bobKp == null) {
        throw StateError(
          '[b8] fetchMemberKeypackage returned null for Bob — his KeyPackage '
          'never reached the hermetic relay. Harness failure, not a finding.',
        );
      }

      final aliceSecret = await alice.getSecretBytes();
      final CircleCreationResultFfi creation;
      try {
        creation = await createCircleConfirmed(
          manager: alice.circleManager,
          relay: relay,
          identitySecretBytes: aliceSecret,
          members: <MemberKeyPackageFfi>[bobKp],
          name: 'B8 Clock Skew Circle',
          circleType: 'location_sharing',
          relays: <String>[defaultStrfryUrl],
          creatorFallbackRelays: <String>[defaultStrfryUrl],
          label: 'b8',
        );
      } finally {
        // Security Rule 9: minimise the Dart-side secret's lifetime.
        for (var i = 0; i < aliceSecret.length; i++) {
          aliceSecret[i] = 0;
        }
      }
      if (creation.welcomeEvents.isEmpty) {
        throw StateError('[b8] createCircle produced no Welcome for Bob.');
      }

      final bobCircle = await bob.acceptInvitationViaRelay(relay: relay);
      final ngidHex = bytesToHex(bobCircle.circle.nostrGroupId);
      // Mirrors haven_core::relay::live_sync::group_cursor_stream: the
      // per-circle group stream key is "<STREAM_GROUP_445>:<ngid hex>".
      final groupStream = 'group_445:$ngidHex';
      final aliceCircle = creation.circle;

      debugPrint('[b8] phase 0/4 complete — 2-member circle at a shared epoch');

      // ---------------------------------------------------------------------
      // Phase 1 — baseline at TRUE time. Positive control AND premise pin.
      //
      // A failure here is a harness failure, not a product finding: every
      // later negative is only meaningful against a working baseline.
      // ---------------------------------------------------------------------
      final baseline = await _publishLocation(
        alice: alice,
        circle: aliceCircle,
        relay: relay,
        coords: _coordsBaseline,
      );
      if (!baseline.accepted) {
        throw StateError(
          '[b8] the hermetic relay rejected the BASELINE publish at true time '
          '("${baseline.rejection}"). The lane is unusable — fix the harness '
          'before reading any finding below.',
        );
      }

      // Premise pin. The whole item rests on "expiration = created_at + 228".
      // Assert it from the wire so the lane cannot quietly keep testing a
      // constant that moved (this backlog has been wrong before).
      final baselineOnWire = await _fetchById(relay, ngidHex, baseline.eventId);
      if (baselineOnWire == null) {
        throw StateError(
          '[b8] the baseline kind-445 never appeared on the relay. Harness '
          'failure.',
        );
      }
      final baselineTtl = _ttlSecs(baselineOnWire);
      if (baselineTtl == null) {
        throw StateError(
          '[b8] the baseline kind-445 carries no NIP-40 expiration tag. The '
          'premise of this lane (a retention-derived TTL on application '
          'messages) no longer holds — re-derive B8 before trusting it.',
        );
      }
      expect(
        baselineTtl,
        _expectedRetentionSecs,
        reason:
            'B8 asserts behaviour around LOCATION_MESSAGE_RETENTION_SECS. The '
            'wire says $baselineTtl s, haven-core/src/location/ttl.rs says '
            '$_expectedRetentionSecs s. One of them moved; reconcile before '
            'reading this lane.',
      );
      debugPrint('[b8] premise pinned: outer TTL = ${baselineTtl}s');

      final sweep1 = await _sweep(relayManager, bob, _sweepSecs);
      final gotBaseline = await _snapshotHas(
        bob,
        bobCircle.circle.nostrGroupId,
        alice.pubkeyHex,
        _coordsBaseline,
      );
      if (!gotBaseline) {
        throw StateError(
          '[b8] the BASELINE location never reached Bob at true time '
          '(sweep: ${_describe(sweep1)}). The lane is unusable — this is a '
          'harness failure, not a clock-skew finding.',
        );
      }
      debugPrint('[b8] phase 1/4 complete — baseline delivered at true time');

      // ---------------------------------------------------------------------
      // Phase 2 — device clock runs FAST (+6 h).
      //
      // Oracle: a location published by a fast-clocked device must still be
      // deliverable. The relay is the correctly-clocked observer here: it
      // judges `created_at` against its own (host) clock.
      // ---------------------------------------------------------------------
      await clock.request(1, _skew.inSeconds);
      final fast = await _publishLocation(
        alice: alice,
        circle: aliceCircle,
        relay: relay,
        coords: _coordsFast,
      );
      if (!fast.accepted) {
        record(
          'forward-skew-publish',
          'a device whose clock is +${_skew.inHours}h could not publish at '
          'all: the correctly-clocked relay refused the kind-445 '
          '("${fast.rejection}"). Every event this device signs carries a '
          'future `created_at` (peeler event.rs:180), and a spec-conformant '
          'relay bounds that (strfry rejectEventsNewerThanSeconds). Nothing '
          'in haven-core or haven/lib checks the device clock against any '
          'external reference, and publishLocation only debugPrints the '
          'rejection — so location sharing is dead for the session with no '
          'user-visible signal.',
        );
      }

      await clock.request(2, 0);

      if (fast.accepted) {
        // The relay took it, so delivery is now purely a receiver question.
        await _sweep(relayManager, bob, _sweepSecs);
        final gotFast = await _snapshotHas(
          bob,
          bobCircle.circle.nostrGroupId,
          alice.pubkeyHex,
          _coordsFast,
        );
        if (!gotFast) {
          record(
            'forward-skew-receive',
            'the relay accepted a location published +${_skew.inHours}h in '
            'the future, but the peer never surfaced it.',
          );
        }
      }
      debugPrint('[b8] phase 2/4 complete');

      // ---------------------------------------------------------------------
      // Phase 3 — device clock runs SLOW (-6 h).
      //
      // Three oracles, deliberately ordered so each is independently
      // meaningful (see the per-probe notes):
      //   3a  the relay must still hold the event once we are back at true
      //       time (a born-expired event is a NIP-40 delete candidate);
      //   3b  the natural cursor's catch-up must not skip it;
      //   3c  the receiver must still decrypt it.
      // ---------------------------------------------------------------------
      await clock.request(3, -_skew.inSeconds);
      final slow = await _publishLocation(
        alice: alice,
        circle: aliceCircle,
        relay: relay,
        coords: _coordsSlow,
      );
      if (!slow.accepted) {
        record(
          'backward-skew-publish',
          'the relay refused a kind-445 from a device whose clock is '
          '-${_skew.inHours}h ("${slow.rejection}").',
        );
      }
      // Back to true time BEFORE reading: this is the whole point. The event
      // was minted at skewed time; every gate below now evaluates it against
      // a correct clock, which is what a real peer would do.
      await clock.request(4, 0);

      if (slow.accepted) {
        // --- 3a: is it still on the relay at all? --------------------------
        // Its NIP-40 expiration is `created_at + 228`, i.e. ~6 h in the past
        // the moment it was written. A relay that honours NIP-40 (strfry
        // does) is entitled to drop it. Distinguishing "the relay GC'd it"
        // from "the client skipped it" is the difference between two
        // completely different fixes, so it is measured, not assumed.
        final slowOnWire = await _fetchById(relay, ngidHex, slow.eventId);
        if (slowOnWire == null) {
          record(
            'backward-skew-retention',
            'a location published by a -${_skew.inHours}h device is already '
            'expired the instant it is written (NIP-40 expiration = '
            'created_at + ${_expectedRetentionSecs}s, both from the skewed '
            'clock) and the relay no longer serves it. The publisher saw a '
            'successful OK-ack and reported success, so the loss is total '
            'and silent.',
          );
        } else {
          // --- 3b: does the cursor-anchored catch-up still fetch it? -------
          //
          // Bob's cursor now sits at the BASELINE event's `created_at`
          // (~true now), and `since_for_stream` subtracts only
          // GROUP_RESUBSCRIBE_BUFFER_SECS = 60 s. The slow event's
          // `created_at` is 6 h below that floor.
          //
          // Measured WITHOUT reimplementing the `since` formula: run the
          // real sweep on the real cursor, then run it again on a
          // deliberately widened window (cursor reset -> the unseeded
          // default of now-24h) and compare how many events the engine saw.
          // A wider window that sees MORE events is proof that the natural
          // floor excluded backlog the relay was still holding.
          final natural = await _sweep(relayManager, bob, _sweepSecs);

          // --- 3c: does the receiver decrypt it? ---------------------------
          //
          // Runs BEFORE the widened sweep and is not poisoned by it: the
          // expiration gate in `SessionManager::process_event` returns
          // *before* `ingest`, so a gated event leaves no dedup entry and a
          // later sweep still classifies it identically.
          final decrypted = await _decryptOne(bob, slowOnWire);
          if (!decrypted) {
            record(
              'backward-skew-receive',
              'a correctly-clocked peer discards the location entirely: the '
              'outer NIP-40 expiration is ~${_skew.inHours}h in the past, so '
              'SessionManager::process_event drops it before decryption '
              '(RECEIVER_EXPIRATION_GRACE_SECS = 60 s) and reports it as '
              'Stale, which also lets the cursor advance past it.',
            );
          }

          await bob.user.circleManager.cursorReset(stream: groupStream);
          final widened = await _sweep(relayManager, bob, _sweepSecs);

          if (natural.deadlineHit || widened.deadlineHit) {
            throw StateError(
              '[b8] a catch-up sweep hit its ${_sweepSecs}s deadline '
              '(natural=${_describe(natural)} widened=${_describe(widened)}). '
              'The window comparison below would be meaningless — harness '
              'failure, not a finding.',
            );
          }
          if (widened.eventsApplied > natural.eventsApplied) {
            record(
              'backward-skew-catchup',
              'catch-up silently skipped backlog the relay still holds: the '
              'natural cursor window reached ${natural.eventsApplied} '
              'event(s), a widened window reached ${widened.eventsApplied}. '
              "The cursor advances to the SENDER's created_at "
              '(catchup.rs::cursor_advance_ms) and the next REQ floor is only '
              'GROUP_RESUBSCRIBE_BUFFER_SECS = 60 s below it (cursor.rs), so '
              'anything minted further back — clock skew here, but equally a '
              'peer whose clock is behind — is outside every subsequent '
              'window, permanently. The saturation guard does not cover this: '
              'the window was never full, it simply never contained the '
              'event. A dropped COMMIT on this path strands the epoch chain.',
            );
          }
        }
      }
      debugPrint('[b8] phase 3/4 complete');

      // ---------------------------------------------------------------------
      // Phase 4 — restored clock. The closing positive control.
      //
      // Without this, every finding above is indistinguishable from "the
      // harness broke somewhere in the middle". A failure here is therefore
      // a harness failure and throws.
      // ---------------------------------------------------------------------
      final restored = await _publishLocation(
        alice: alice,
        circle: aliceCircle,
        relay: relay,
        coords: _coordsRestored,
      );
      if (!restored.accepted) {
        throw StateError(
          '[b8] the relay rejected a publish AFTER the clock was restored '
          '("${restored.rejection}") — the device clock never came back, so '
          'nothing above is attributable. Harness failure.',
        );
      }
      await _sweep(relayManager, bob, _sweepSecs);
      final gotRestored = await _snapshotHas(
        bob,
        bobCircle.circle.nostrGroupId,
        alice.pubkeyHex,
        _coordsRestored,
      );
      if (!gotRestored) {
        throw StateError(
          '[b8] the post-restore location never reached Bob. The lane cannot '
          'attribute its earlier negatives to clock skew — harness failure.',
        );
      }
      debugPrint('[b8] phase 4/4 complete — delivery restored with the clock');

      // Terminal marker FIRST: the shell needs to know the body ran to the
      // end even (especially) on a red run.
      debugPrint('$kAllPhasesMarker findings=${findings.length}');

      try {
        await relayManager.shutdown();
        await bob.dispose();
        await alice.dispose();
        await relay.dispose();
      } on Object catch (_) {
        // Best-effort teardown; the process is about to exit.
      }

      expect(
        findings,
        isEmpty,
        reason:
            'B8 requires that a +/-${_skew.inHours}h device clock jump leave '
            'location delivery intact: events stay publishable and '
            'decryptable by a correctly-clocked peer, and catch-up does not '
            'skip backlog the relay still holds. Findings:\n'
            '${findings.map((f) => '  - $f').join('\n')}',
      );
    },
    timeout: const Timeout(Duration(minutes: 15)),
  );
}

// ---------------------------------------------------------------------------
// Clock rendezvous
// ---------------------------------------------------------------------------

/// Requests wall-clock jumps from the shell and waits until this process has
/// actually observed them.
///
/// The measurement is `wall delta - monotonic delta`, so the request/apply
/// latency cancels out and only a genuine discontinuity registers. That
/// matters more than it looks: a timer-based "sleep then assume" rendezvous
/// would pass on a run where the clock never moved at all, which is the
/// vacuity mode this lane most needs to avoid.
class _ClockServo {
  /// Current offset from true time, in seconds, as last requested.
  int _offsetSecs = 0;

  /// Asks the shell to set the device clock to `true_now + offsetSecs` and
  /// blocks until the jump is observed.
  ///
  /// Throws a [StateError] (a HARNESS failure, never a product finding) if
  /// the jump does not arrive within [_clockJumpTimeout].
  Future<void> request(int seq, int offsetSecs) async {
    final delta = offsetSecs - _offsetSecs;
    if (delta == 0) return;

    final monotonic = Stopwatch()..start();
    final wallStart = DateTime.now();
    debugPrint('$kReqClockMarker $seq $offsetSecs');

    final deadline = Stopwatch()..start();
    while (deadline.elapsed < _clockJumpTimeout) {
      await Future<void>.delayed(_clockPollInterval);
      final observed =
          DateTime.now().difference(wallStart).inSeconds -
          monotonic.elapsed.inSeconds;
      if ((observed - delta).abs() <= _clockMatchTolerance.inSeconds) {
        debugPrint('$kClockObservedMarker $seq $observed');
        _offsetSecs = offsetSecs;
        return;
      }
    }
    debugPrint('$kClockTimeoutMarker $seq');
    throw StateError(
      '[b8] requested a ${delta}s clock jump (seq $seq) and never observed '
      'it within ${_clockJumpTimeout.inSeconds}s. The shell servo did not '
      'move the device clock — HARNESS failure, not a product finding. Check '
      'the clock-jumps log for the adb read-back.',
    );
  }
}

// ---------------------------------------------------------------------------
// Probes
// ---------------------------------------------------------------------------

/// The outcome of one publish attempt, including a relay refusal.
typedef _PublishOutcome = ({bool accepted, String rejection, String eventId});

/// Encrypts a location for [circle] and offers it to [relay], returning the
/// relay's verdict instead of throwing on refusal.
///
/// `SyntheticUser.publishLocation` throws when the relay says no, which is
/// right for every other scenario and wrong here: a refusal IS one of this
/// lane's measurements.
Future<_PublishOutcome> _publishLocation({
  required TestUser alice,
  required CircleFfi circle,
  required TestRelay relay,
  required ({double lat, double lon}) coords,
}) async {
  final encrypted = await alice.circleManager.encryptLocation(
    mlsGroupId: circle.mlsGroupId,
    senderPubkeyHex: alice.pubkeyHex,
    latitude: coords.lat,
    longitude: coords.lon,
    // Matches the production call site
    // (kLocationPublishMaxInterval 168 s + kTtlNetworkBufferSeconds 30 s).
    // Under Dark Matter the outer TTL comes from the group's retention
    // component, not from this value, but passing the production number
    // keeps the inner message identical to a real send.
    updateIntervalSecs: BigInt.from(198),
  );
  final (accepted, msg) = await relay.publishAndAwaitOk(encrypted.eventJson);
  final decoded = jsonDecode(encrypted.eventJson);
  final id = decoded is Map<String, dynamic>
      ? (decoded['id'] as String? ?? '')
      : '';
  debugPrint(
    '[b8] publish accepted=$accepted evt=${_short(id)} '
    '${accepted ? '' : 'relay="$msg"'}',
  );
  return (accepted: accepted, rejection: msg, eventId: id);
}

/// Fetches one kind-445 by id, with NO `since` bound, so the answer is
/// "does the relay still hold this event" and nothing else.
Future<TestRelayEvent?> _fetchById(
  TestRelay relay,
  String ngidHex,
  String eventId,
) async {
  if (eventId.isEmpty) return null;
  final events = await relay.collectN(
    count: 1,
    filter: <String, dynamic>{
      'ids': <String>[eventId],
      'kinds': <int>[445],
      '#h': <String>[ngidHex],
      'limit': 1,
    },
    timeout: const Duration(seconds: 10),
  );
  return events.isEmpty ? null : events.first;
}

/// The `expiration - created_at` delta of an outer kind-445, or `null` when
/// the event carries no NIP-40 expiration tag.
int? _ttlSecs(TestRelayEvent event) {
  final tag = event.tag('expiration');
  if (tag == null || tag.length < 2) return null;
  final expires = int.tryParse(tag[1]);
  if (expires == null) return null;
  return expires - event.createdAt;
}

/// Runs one real receive-only catch-up sweep on [bob]'s manager.
Future<_SweepResult> _sweep(
  RelayManagerFfi relayManager,
  SyntheticUser bob,
  int maxSecs,
) async {
  final r = await relayManager.runCatchupAllCircles(
    circle: bob.user.circleManager,
    ownPubkeyHex: bob.pubkeyHex,
    maxDurationSecs: BigInt.from(maxSecs),
  );
  final result = (
    circlesSwept: r.circlesSwept,
    eventsApplied: r.eventsApplied,
    eventsDeferred: r.eventsDeferred,
    cursorsAdvanced: r.cursorsAdvanced,
    deadlineHit: r.deadlineHit,
    relayErrors: r.relayErrors,
  );
  debugPrint('[b8] sweep ${_describe(result)}');
  return result;
}

/// Counter view of one catch-up sweep. Mirrors `CatchupResultFfi`; note that
/// `windows_truncated` (the Rule-12 saturation flag) is NOT exposed across
/// the FFI, so this lane cannot read it and instead rules saturation out by
/// construction — the hermetic relay holds a handful of events, far under
/// `CATCHUP_MAX_EVENTS_PER_CIRCLE`.
typedef _SweepResult = ({
  int circlesSwept,
  int eventsApplied,
  int eventsDeferred,
  int cursorsAdvanced,
  bool deadlineHit,
  int relayErrors,
});

String _describe(_SweepResult r) =>
    'circles=${r.circlesSwept} applied=${r.eventsApplied} '
    'deferred=${r.eventsDeferred} cursors=${r.cursorsAdvanced} '
    'deadlineHit=${r.deadlineHit} relayErrors=${r.relayErrors}';

/// Whether [bob]'s persisted last-known table holds [coords] for [sender].
///
/// `now_unix_secs: 0` deliberately disables the purge filter: this asks "did
/// the row land", not "is it currently fresh", and a purge-window false
/// negative would be indistinguishable from a delivery failure.
///
/// NOTE the upsert is `WHERE excluded.timestamp > existing.timestamp`
/// (`storage.rs:1631`), so a location minted at a time EARLIER than one
/// already stored for the same sender is correctly discarded. That is why
/// the backward-skew phase reads its verdict from the decrypt result rather
/// than from this snapshot.
Future<bool> _snapshotHas(
  SyntheticUser bob,
  List<int> nostrGroupId,
  String sender,
  ({double lat, double lon}) coords,
) async {
  final rows = await bob.user.circleManager.snapshotLastKnownForCircle(
    nostrGroupId: nostrGroupId,
    nowUnixSecs: 0,
  );
  for (final row in rows) {
    if (row.senderPubkey.toLowerCase() != sender.toLowerCase()) continue;
    if ((row.latitude - coords.lat).abs() < 1e-5 &&
        (row.longitude - coords.lon).abs() < 1e-5) {
      return true;
    }
  }
  return false;
}

/// Feeds one raw relay event through the production receive API and reports
/// whether a location surfaced.
///
/// Uses `decryptLocationCollectingCommits` — never `decryptLocation`, which
/// rolls back any receive-side auto-commit the engine staged.
Future<bool> _decryptOne(SyntheticUser bob, TestRelayEvent event) async {
  try {
    final outcome = await bob.user.circleManager
        .decryptLocationCollectingCommits(eventJson: jsonEncode(event.raw));
    for (final r in outcome.results) {
      if (r.kind == LocationMessageResultKindFfi.location &&
          r.location != null) {
        return true;
      }
    }
    return false;
  } on Object catch (e) {
    // Security Rule 8: runtimeType only — a raw error can carry MLS state.
    debugPrint('[b8] direct decrypt threw: ${e.runtimeType}');
    return false;
  }
}

/// First 8 hex chars of an event id — enough to correlate a publish with a
/// later log line, far too little to be a tracking vector.
String _short(String hex) => hex.length <= 8 ? hex : hex.substring(0, 8);
