/// B8 drive target — device-clock skew: what Haven now DETECTS, and what a
/// +/-6 h jump still costs (`docs/CI_HARDENING_BACKLOG.md`, Workstream B,
/// item B8: "Clock jump +/-6h ... exercises `created_at`, the 228 s TTL,
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
///     (`peeler.rs:169`, Package E).
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
///     receiver's past, BEFORE any decryption.
///   * **The `since` cursor** — `run_catchup_all_circles`
///     (`haven-core/src/relay/catchup.rs:288-349`) advances the persisted
///     cursor to the SENDER's `created_at`, and `since_for_stream`
///     (`haven-core/src/relay/cursor.rs:114-130`) re-derives the next REQ
///     floor as `cursor - GROUP_RESUBSCRIBE_BUFFER_SECS` (60 s).
///
/// ## What this lane GATES, and what it merely RECORDS
///
/// Haven does not rewrite `created_at`, deliberately: the TTL, the `since`
/// cursor floor and the peeler's inner/outer timestamp binding all ride that
/// value, so correcting it needs its own security analysis and is out of
/// scope here. Everything above therefore still costs a skewed device real
/// delivery, and this target MEASURES that cost and reports it as EVIDENCE —
/// a standing record of a live residual defect, not a gate (the same
/// evidence-vs-finding split B1, B5, B6 and B9 use).
///
/// What IS gated is the behaviour that landed instead: **the failure is no
/// longer silent.** A fast clock's relay refusal is classified into a typed
/// `RelayError::DeviceClockRejected` rather than collapsed into a generic
/// failure, and a slow clock is inferred from peers' own timestamps read from
/// INSIDE the MLS ciphertext, keyed by authenticated member id and requiring
/// two distinct members to agree. Both raise a user-visible banner, and the
/// two faults say different things. Those SEVEN properties — the seven
/// `[b8] OK <name>` markers run-b8-clock-skew.sh requires, enumerated in its
/// header — are this lane's gate; each one goes red if the corresponding piece
/// of the fix is reverted.
///
/// One nuance on the recording side, because getting it wrong cost this lane a
/// CI run: the two skew DIRECTIONS are symmetric and both are EVIDENCE. A fast
/// clock's event is refused as too-far-future; a slow clock's is refused as
/// already-expired, because Haven stamps `expiration = created_at + retention`
/// with both values from the skewed clock. Neither has a local lever short of
/// clock correction, so neither is gated. What IS still gated on the slow side
/// is the refusal being the born-expired one: any OTHER rejection reason is a
/// regression and fails the lane.
///
/// ## Why one device is enough, and what breaks the clock symmetry
///
/// The publisher and the receiver share this device's wall clock, so a naive
/// "jump the clock and have a peer decrypt" scenario is VACUOUS: both sides
/// move together and every comparison stays self-consistent. Every oracle
/// below therefore names the thing that does NOT move with the device:
///
///   * **The hermetic strfry relay.** It runs on the CI host, its clock never
///     moves, and its `rejectEventsNewerThanSeconds = 900`
///     (`tooling/e2e/strfry.conf`) judges a `created_at` 21 600 s in its
///     future exactly as a correctly-clocked peer would. Every fast-clock
///     oracle bottoms out in its refusal, which the device cannot produce by
///     moving both of its own roles together.
///   * **A timestamp frozen at a DIFFERENT offset.** The peer samples are
///     minted at true time, sealed inside the MLS ciphertext, and only then
///     is the clock moved and the sample READ. The sender's reading cannot
///     follow the reader's clock — it is ciphertext by then — so the observed
///     offset is a genuine discontinuity. Had the jump silently no-opped, the
///     offsets would be ~0 s and the corroboration oracle would go red.
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
/// Every gating oracle records into `findings` and the body runs to
/// completion, so ONE run reports every defect rather than stopping at the
/// first. Genuine harness failures (the clock never moved, the baseline never
/// worked, the premise no longer holds) still throw immediately — a run whose
/// machinery is broken must not be readable as a product verdict.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/constants/location.dart'
    show kClockSkewAlertThreshold;
import 'package:haven/src/providers/service_providers.dart'
    show clockSkewDetectorProvider;
import 'package:haven/src/rust/api.dart'
    show
        CircleCreationResultFfi,
        CircleFfi,
        LocationMessageResultKindFfi,
        MemberKeyPackageFfi,
        RelayManagerFfi;
import 'package:haven/src/services/clock_skew_detector.dart'
    show ClockSkewDetector, DeviceClockComplaint;
import 'package:haven/src/services/nostr_relay_service.dart'
    show NostrRelayService;
import 'package:haven/src/widgets/location/clock_skew_banner.dart'
    show ClockSkewBanner;
import 'package:integration_test/integration_test.dart';

import 'e2e/_lib/circle_creation.dart' show createCircleConfirmed;
import 'e2e/_lib/clock_skew_oracles.dart';
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

/// One recorded defect in the behaviour this lane GATES. The shell fails the
/// lane if any appears.
const String kFindingMarker = '[b8] FINDING';

/// One recorded MEASUREMENT of the delivery cost a skewed clock still
/// imposes. Printed by the shell, never gating — closing it needs clock
/// correction, which is deliberately out of scope (see the library doc).
const String kEvidenceMarker = '[b8] EVIDENCE';

/// Terminal marker. Its ABSENCE means the body died early, which invalidates
/// every negative result above it.
const String kAllPhasesMarker = '[b8] ALL_PHASES_COMPLETE';

// --- Gating oracles. The shell requires EVERY one of these to be present. ---

/// A fast clock's relay refusal reached Dart CLASSIFIED as a device-clock
/// fault instead of collapsed into a generic publish failure.
const String kOkRejectionClassified = '[b8] OK rejection-classified';

/// …and reached a consumer that can act on it, raising its verdict.
const String kOkRejectionVerdict = '[b8] OK rejection-verdict';

/// ONE member reporting a future time does NOT accuse this device's clock.
const String kOkPeerSingleSourceSilent = '[b8] OK peer-single-source-silent';

/// TWO distinct MLS-authenticated members agreeing DOES raise the verdict.
const String kOkPeerCorroborated = '[b8] OK peer-corroborated';

/// The fast-clock fault reaches the user, in its own words.
const String kOkSurfaceRejected = '[b8] OK surface-rejected';

/// The slow-clock fault reaches the user, in its own words.
const String kOkSurfaceBehind = '[b8] OK surface-behind';

/// …and those words differ: one fault means nothing is shared, the other
/// means the send succeeded and the data was then discarded.
const String kOkSurfaceDistinct = '[b8] OK surface-distinct';

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
const ({double lat, double lon}) _coordsFastProd = (lat: 55.6761, lon: 12.5683);
const ({double lat, double lon}) _coordsPeerA = (lat: 40.4319, lon: 116.5704);
const ({double lat, double lon}) _coordsPeerC = (lat: 37.8199, lon: -122.4783);
const ({double lat, double lon}) _coordsSlow = (lat: 41.9028, lon: 12.4964);
const ({double lat, double lon}) _coordsRestored = (lat: 59.9139, lon: 10.7522);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // testWidgets, not bare `test`: only a testWidgets body's failure is
  // recorded by the integration binding and can turn `flutter drive` red
  // (drive-log-lib.sh). The body drives the FFI and the relay directly, and
  // additionally pumps the clock-skew banner — the one part of the fix that
  // only exists as a widget.
  testWidgets(
    'B8: a +/-6h device clock jump is detected, surfaced, and measured',
    (tester) async {
      final findings = <String>[];
      final evidence = <String>[];
      final clock = _ClockServo();

      /// Records a defect in the behaviour this lane GATES.
      void record(String phase, String detail) {
        final line = '$kFindingMarker $phase: $detail';
        debugPrint(line);
        findings.add('$phase: $detail');
      }

      /// Records a MEASUREMENT of the delivery cost a skewed clock still
      /// imposes. Never gating.
      void note(String phase, String detail) {
        final line = '$kEvidenceMarker $phase: $detail';
        debugPrint(line);
        evidence.add('$phase: $detail');
      }

      /// Emits [okMarker] when an oracle held, or records why it did not.
      void gate(String okMarker, String phase, String? failure) {
        if (failure == null) {
          debugPrint(okMarker);
          return;
        }
        record(phase, failure);
      }

      final ctx = await ScenarioHarness.bootstrap();
      final relay = ctx.relay;
      final relayManager = await RelayManagerFfi.newInstance();

      // The PRODUCTION relay service, used for the fast-clock oracle. The
      // rest of the lane publishes through `TestRelay.publishAndAwaitOk`,
      // which is the right probe for a measurement (it returns the relay's
      // verdict instead of throwing) but bypasses `RelayManager::publish_event`
      // entirely — so it exercises none of the classification under test.
      final relayService = NostrRelayService();
      await relayService.initialize();

      final l10n = await AppLocalizations.delegate.load(const Locale('en'));

      // Two detectors, never one: `_evaluate` lets the relay signal outrank
      // the peer signal, so a single detector carrying phase 2's relay
      // complaint could report `relayRejectedTimestamp` in phase 3 and mask a
      // peer signal that never fired.
      final relayDetector = ClockSkewDetector();
      final peerDetector = ClockSkewDetector();

      // Alice publishes; Bob receives; Carol is the SECOND independent
      // publisher the corroboration rule requires. Three CircleManagerFfi
      // instances over three temp data dirs (the standard SyntheticUser
      // arrangement), so Bob's cursor store and MLS state are genuinely his
      // own and Carol's member id is genuinely distinct from Alice's.
      final alice = await TestUser.alice();
      final bob = await SyntheticUser.bob(relay);
      final carol = await SyntheticUser.carol(relay);
      await waitForKeyPackage(relay: relay, authorPubkeyHex: bob.pubkeyHex);
      await waitForKeyPackage(relay: relay, authorPubkeyHex: carol.pubkeyHex);

      final bobKp = await relayManager.fetchMemberKeypackage(
        pubkey: bob.pubkeyHex,
      );
      final carolKp = await relayManager.fetchMemberKeypackage(
        pubkey: carol.pubkeyHex,
      );
      if (bobKp == null || carolKp == null) {
        throw StateError(
          '[b8] fetchMemberKeypackage returned null for '
          '${bobKp == null ? 'Bob' : 'Carol'} — their KeyPackage never '
          'reached the hermetic relay. Harness failure, not a finding.',
        );
      }

      final aliceSecret = await alice.getSecretBytes();
      final CircleCreationResultFfi creation;
      try {
        creation = await createCircleConfirmed(
          manager: alice.circleManager,
          relay: relay,
          identitySecretBytes: aliceSecret,
          members: <MemberKeyPackageFfi>[bobKp, carolKp],
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
      if (creation.welcomeEvents.length < 2) {
        throw StateError(
          '[b8] createCircle produced ${creation.welcomeEvents.length} '
          'Welcome(s) for two invitees.',
        );
      }

      final bobCircle = await bob.acceptInvitationViaRelay(relay: relay);
      final carolCircle = await carol.acceptInvitationViaRelay(relay: relay);
      final ngidHex = bytesToHex(bobCircle.circle.nostrGroupId);
      // Mirrors haven_core::relay::live_sync::group_cursor_stream: the
      // per-circle group stream key is "<STREAM_GROUP_445>:<ngid hex>".
      final groupStream = 'group_445:$ngidHex';
      final aliceCircle = creation.circle;

      debugPrint('[b8] phase 0/5 complete — 3-member circle at a shared epoch');

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
      debugPrint('[b8] phase 1/5 complete — baseline delivered at true time');

      // ---------------------------------------------------------------------
      // Phase 2 — device clock runs FAST (+6 h).
      //
      // Clock symmetry is broken by the RELAY: strfry runs on the CI host and
      // never moves, so its `rejectEventsNewerThanSeconds = 900` verdict on a
      // `created_at` 21 600 s in its future is the verdict a correctly-clocked
      // peer would give. Nothing the device does to both of its own roles can
      // manufacture that refusal.
      //
      //   * EVIDENCE — the delivery cost: the publish is refused outright.
      //     Clearing this needs the device to stop signing a future
      //     `created_at`, i.e. clock correction (out of scope, see above).
      //   * GATE — the refusal is CLASSIFIED, reaches a consumer, and reaches
      //     the user.
      // ---------------------------------------------------------------------
      await clock.request(1, _skew.inSeconds);

      // (a) The measurement, through the raw probe so a refusal is a value
      //     rather than a throw.
      final fast = await _publishLocation(
        alice: alice,
        circle: aliceCircle,
        relay: relay,
        coords: _coordsFast,
      );
      if (!fast.accepted) {
        note(
          'forward-skew-publish',
          'a device whose clock is +${_skew.inHours}h cannot publish at all: '
          'the correctly-clocked relay refuses the kind-445 '
          '("${fast.rejection}"). Every event this device signs carries a '
          'future `created_at` (peeler event.rs:180) and a spec-conformant '
          'relay bounds that. NOT GATED: the only local lever that clears it '
          'is signing a `created_at` the device clock does not hold, and that '
          'rewrite moves the TTL, the `since` cursor floor and the '
          "peeler's inner/outer binding with it, so it is deferred to its "
          'own security analysis. What IS gated is that the refusal is no '
          'longer silent — '
          'see $kOkRejectionClassified below.',
        );
      }

      // (b) The gate, through the PRODUCTION publish path
      //     (NostrRelayService -> RelayManagerFfi ->
      //     RelayManager::publish_event -> publish_with_retry ->
      //     clock_skew::classify_publish_outcome). A fresh
      //     encrypt, so this is a new event id and cannot come back as a
      //     `duplicate:` from probe (a).
      final prod = await _publishViaProductionPath(
        alice: alice,
        circle: aliceCircle,
        relayService: relayService,
        coords: _coordsFastProd,
      );
      gate(
        kOkRejectionClassified,
        'clock-fault-classification',
        checkFastClockRejectionClassified(prod.error),
      );

      final prodError = prod.error;
      if (prodError != null) {
        // ONE call, no branch — deliberately. `recordPublishError` is total
        // over the error vocabulary the relay layer actually throws: it routes
        // a `RelayClockRejectionException` to `recordPublishClockRejection`
        // using the typed field, and everything else through the text parser.
        // The observable result is identical to production's call site
        // (location_sharing_service.dart, `on RelayClockRejectionException` /
        // `on Object`), which stays pinned by
        // test/services/location_sharing_clock_skew_test.dart.
        //
        // Not a branch, because the branch is what rotted. This line used to be
        // a hand-copy of that call site that read the token out of
        // `complaintFromError(prodError)`. That parser scans
        // `error.toString()` for `haven.clock.device_clock_rejected:`, and
        // `RelayClockRejectionException.toString()` is
        // `'RelayClockRejectionException(device clock <token>)'` — no marker,
        // because the token is a FIELD precisely so the relay layer needs no
        // dependency on the detector's enum. The parse returned null, the
        // fallback ran, the verdict stayed `none`, and this lane reported three
        // findings (verdict, surface, copy) against production code that was
        // correct all along. A call site copied into a test is a call site that
        // can rot away from the original in silence, so there is no longer a
        // copy here to rot.
        relayDetector.recordPublishError(prodError);
      }
      gate(
        kOkRejectionVerdict,
        'clock-fault-verdict',
        checkRelayVerdictRaised(relayDetector.status),
      );

      final rejectedTexts = await _renderBanner(tester, relayDetector);
      gate(
        kOkSurfaceRejected,
        'clock-fault-surface-rejected',
        checkFaultSurfaced(
          fault: 'fast-clock (relay refused the timestamp)',
          renderedTexts: rejectedTexts,
          expectedBody: l10n.clockSkewBodyRejected,
        ),
      );

      await clock.request(2, 0);

      if (fast.accepted) {
        // The relay took it, so delivery is now purely a receiver question —
        // and a receiver that drops it IS a gated defect, because nothing
        // about clock correction is needed to fix it.
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
      debugPrint('[b8] phase 2/5 complete');

      // ---------------------------------------------------------------------
      // Phase 3 — device clock runs SLOW (-6 h).
      //
      // Two independent halves:
      //
      //   GATE — the slow-clock DETECTION. Alice and Carol each publish while
      //   the clock is still true; their readings are sealed inside the MLS
      //   ciphertext at that moment. Only THEN does the clock move, and only
      //   then are the samples read. That is what breaks the symmetry: the
      //   reader's `DateTime.now()` moved by -6 h, the senders' sealed
      //   readings could not follow, so the observed offset is a real
      //   discontinuity. Had the jump silently no-opped, both offsets would be
      //   ~0 s and `peer-corroborated` would go red.
      //
      //   EVIDENCE — the delivery cost of a backdated publish. Measured after
      //   the clock is restored, so every gate is evaluated at TRUE time
      //   against an event minted at skewed time, which is what a real peer
      //   would do.
      // ---------------------------------------------------------------------

      // 3-pre, at TRUE time: two independent members mint a reading each.
      final peerA = await _publishLocation(
        alice: alice,
        circle: aliceCircle,
        relay: relay,
        coords: _coordsPeerA,
      );
      if (!peerA.accepted) {
        throw StateError(
          "[b8] the relay refused Alice's peer-sample publish at TRUE time "
          '("${peerA.rejection}"). Harness failure.',
        );
      }
      final peerCId = await carol.publishLocation(
        circle: carolCircle,
        latitude: _coordsPeerC.lat,
        longitude: _coordsPeerC.lon,
        relay: relay,
      );
      // Fetch both BEFORE the jump: the relay still holds them at true time,
      // and reading them now keeps the sample acquisition independent of
      // whatever the skewed clock does to a later REQ.
      final peerAOnWire = await _fetchById(relay, ngidHex, peerA.eventId);
      final peerCOnWire = await _fetchById(relay, ngidHex, peerCId);
      if (peerAOnWire == null || peerCOnWire == null) {
        throw StateError(
          '[b8] a peer-sample kind-445 never appeared on the relay '
          '(alice=${peerAOnWire != null} carol=${peerCOnWire != null}). '
          'Harness failure.',
        );
      }

      await clock.request(3, -_skew.inSeconds);

      // The samples are read HERE, at -6 h, against readings sealed at true
      // time. Both events' NIP-40 expiration is ~6 h in this device's future,
      // so `SessionManager::process_event` passes them through untouched —
      // the receiver gate only bounds the past.
      final sampleA = await _decryptPeerSample(bob, peerAOnWire);
      final sampleC = await _decryptPeerSample(bob, peerCOnWire);
      if (sampleA == null || sampleC == null) {
        throw StateError(
          '[b8] a peer sample failed to decrypt under a -${_skew.inHours}h '
          'clock (alice=${sampleA != null} carol=${sampleC != null}). The '
          'corroboration oracle is unevaluable without both — HARNESS '
          'failure, not a product finding.',
        );
      }
      if (sampleA.sender.toLowerCase() == sampleC.sender.toLowerCase()) {
        throw StateError(
          '[b8] both peer samples carry the SAME MLS-authenticated member id, '
          'so the corroboration oracle would be testing one member twice. '
          'Harness failure.',
        );
      }

      peerDetector.recordPeerTimestamp(
        senderPubkey: sampleA.sender,
        peerTimestamp: sampleA.timestamp,
      );
      gate(
        kOkPeerSingleSourceSilent,
        'slow-clock-single-source',
        checkSingleSourceStaysSilent(
          peerDetector.status,
          sourcesFed: peerDetector.trackedSourceCountForTest,
        ),
      );

      peerDetector.recordPeerTimestamp(
        senderPubkey: sampleC.sender,
        peerTimestamp: sampleC.timestamp,
      );
      gate(
        kOkPeerCorroborated,
        'slow-clock-corroborated',
        checkPeerSkewCorroborated(
          peerDetector.status,
          thresholdSecs: kClockSkewAlertThreshold.inSeconds,
        ),
      );

      // Rendered while the fault is LIVE. The peer verdict is computed at
      // record time and cached, but rendering it after the clock is restored
      // would be a weaker claim about a state the user never actually saw.
      final behindTexts = await _renderBanner(tester, peerDetector);
      gate(
        kOkSurfaceBehind,
        'clock-fault-surface-behind',
        checkFaultSurfaced(
          fault: 'slow-clock (peers ahead of this device)',
          renderedTexts: behindTexts,
          expectedBody: l10n.clockSkewBodyBehind,
        ),
      );

      // --- the delivery-cost half ------------------------------------------
      final slow = await _publishLocation(
        alice: alice,
        circle: aliceCircle,
        relay: relay,
        coords: _coordsSlow,
      );
      if (!slow.accepted) {
        // REVERSES a recorded owner decision, on evidence that decision did not
        // have. docs/CI_HARDENING_BACKLOG.md (OWNER DECISION, 2026-08-04) kept
        // `backward-skew-publish` as a gate, reasoning that
        // `rejectEventsOlderThanSeconds = 94 608 000` in tooling/e2e/strfry.conf
        // means a -6 h `created_at` is accepted, so a refusal would be a real,
        // fixable regression. That premise is wrong, and CI disproved it twice
        // (runs 30925179141 and 30964250098, both `"invalid: event expired"`):
        // strfry applies TWO independent write-time time checks, and NIP-40
        // expiry is the other one — a separate ingest path with no knob in that
        // config. Haven stamps `expiration = created_at + retention` with BOTH
        // values from the skewed clock, so a -6 h event is born roughly 6 h
        // expired and any NIP-40-honouring relay refuses it at ingest. The only
        // lever is clock correction, exactly as for the +6 h case this lane
        // already records as EVIDENCE. The backlog entry was corrected in the
        // same change; do not re-tighten this from that doc's old text.
        //
        // So classify rather than gate wholesale: the born-expired refusal is
        // the delivery cost, and ANY OTHER refusal (a rate limit, a duplicate,
        // an auth failure, a bad signature, or `rejectEventsOlderThanSeconds`
        // genuinely moving) is still a regression this lane must fail on — an
        // unrecognised reason classifies as null and falls to `record()`, so
        // this narrows the gate, it does not remove it.
        final refusal = ClockSkewDetector.classifyRelayRejection(
          slow.rejection,
        );
        if (refusal == DeviceClockComplaint.behind) {
          note(
            'backward-skew-publish',
            'a device whose clock is -${_skew.inHours}h cannot publish at all: '
            'the event is born already expired (NIP-40 expiration = created_at '
            '+ ${_expectedRetentionSecs}s, both from the skewed clock) and the '
            'relay refuses it at ingest ("${slow.rejection}"). NOT GATED: the '
            'expiration is derived inside the engine from the '
            'message-retention component, so the only local lever is clock '
            'correction, which is deferred.',
          );
        } else {
          record(
            'backward-skew-publish',
            'the relay refused a kind-445 from a device whose clock is '
            '-${_skew.inHours}h for a reason that is NOT the expected '
            'born-expired one ("${slow.rejection}"). The born-expired refusal '
            "is this lane's declared delivery cost; anything else is a real, "
            'fixable regression.',
          );
        }
      }
      // Back to true time BEFORE reading: this is the whole point. The event
      // was minted at skewed time; every gate below now evaluates it against
      // a correct clock, which is what a real peer would do.
      await clock.request(4, 0);

      if (!slow.accepted) {
        // The read-side measurements below all start from an event the relay
        // holds. Against a NIP-40-enforcing relay there is no such event: the
        // refusal above happened at INGEST, so retention, receive and catch-up
        // have nothing to measure. Say that, rather than skipping three
        // EVIDENCE lines in silence and leaving the lane's output looking as
        // though they had been checked and found clean.
        note(
          'backward-skew-readside',
          'retention, receive and catch-up were NOT measured for the '
          '-${_skew.inHours}h event: the relay refused it at ingest, so it '
          'never reached the wire for a reader to miss. These three costs are '
          'only observable against a relay that ACCEPTS a born-expired event '
          'and drops it later; on this hermetic relay the loss happens one '
          'step earlier and is already recorded as backward-skew-publish.',
        );
      }

      if (slow.accepted) {
        // --- 3a: is it still on the relay at all? --------------------------
        final slowOnWire = await _fetchById(relay, ngidHex, slow.eventId);
        if (slowOnWire == null) {
          note(
            'backward-skew-retention',
            'a location published by a -${_skew.inHours}h device is already '
            'expired the instant it is written (NIP-40 expiration = '
            'created_at + ${_expectedRetentionSecs}s, both from the skewed '
            'clock) and the relay accepted it but no longer serves it. The '
            'publisher saw a successful OK-ack and reported success. NOT '
            'GATED: expiration is derived from `created_at` inside the engine, '
            'so the only local lever is clock correction, which is deferred.',
          );
        } else {
          // --- 3b: does the cursor-anchored catch-up still fetch it? -------
          //
          // Measured WITHOUT reimplementing the `since` formula: run the real
          // sweep on the real cursor, then run it again on a deliberately
          // widened window (cursor reset -> the unseeded default of now-24h)
          // and compare how many events the engine saw.
          final natural = await _sweep(relayManager, bob, _sweepSecs);

          // --- 3c: does the receiver decrypt it? ---------------------------
          //
          // Runs BEFORE the widened sweep and is not poisoned by it: the
          // expiration gate in `SessionManager::process_event` returns
          // *before* `ingest`, so a gated event leaves no dedup entry and a
          // later sweep still classifies it identically.
          final decrypted = await _decryptOne(bob, slowOnWire);
          if (!decrypted) {
            note(
              'backward-skew-receive',
              'a correctly-clocked peer discards the location entirely: the '
              'outer NIP-40 expiration is ~${_skew.inHours}h in the past, so '
              'SessionManager::process_event drops it before decryption '
              '(RECEIVER_EXPIRATION_GRACE_SECS = 60 s). NOT GATED: making the '
              'receiver keep it means widening that grace window, which is a '
              'replay defence — the fix is clock correction on the sender, '
              'which is deferred.',
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
            note(
              'backward-skew-catchup',
              'catch-up skipped backlog the relay still holds: the natural '
              'cursor window reached ${natural.eventsApplied} event(s), a '
              'widened window reached ${widened.eventsApplied}. The cursor '
              "advances to the SENDER's created_at "
              '(catchup.rs::cursor_advance_ms) and the next REQ floor is only '
              'GROUP_RESUBSCRIBE_BUFFER_SECS = 60 s below it (cursor.rs), so '
              'anything minted further back is outside every subsequent '
              'window. NOT GATED: this is a property of where the cursor '
              'window sits relative to a skewed `created_at`, which no '
              'detection change moves.',
            );
          }
        }
      }
      debugPrint('[b8] phase 3/5 complete');

      // ---------------------------------------------------------------------
      // Phase 4 — restored clock. The closing positive control.
      //
      // Without this, every measurement above is indistinguishable from "the
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
          'attribute its earlier measurements to clock skew — harness '
          'failure.',
        );
      }
      debugPrint('[b8] phase 4/5 complete — delivery restored with the clock');

      // ---------------------------------------------------------------------
      // Phase 5 — the two faults must not say the same thing.
      //
      // Compared from the copy the two banners ACTUALLY painted in phases 2
      // and 3, not from the l10n bundle: a `resolveClockSkewCopy` that mapped
      // both signals to one string would satisfy a bundle-level check and
      // still show the user one sentence for two different situations.
      // ---------------------------------------------------------------------
      gate(
        kOkSurfaceDistinct,
        'clock-fault-copy',
        checkFaultCopyDistinct(
          rejectedBody: _longest(rejectedTexts),
          behindBody: _longest(behindTexts),
        ),
      );
      debugPrint('[b8] phase 5/5 complete');

      // Terminal marker FIRST: the shell needs to know the body ran to the
      // end even (especially) on a red run.
      debugPrint(
        '$kAllPhasesMarker findings=${findings.length} '
        'evidence=${evidence.length}',
      );

      try {
        // Unmount the banner BEFORE closing the detectors' change streams:
        // `clockSkewStatusProvider` is listening to one of them, and tearing
        // the tree down first keeps that ordering out of the teardown's
        // best-effort catch.
        await tester.pumpWidget(const SizedBox.shrink());
        await relayDetector.dispose();
        await peerDetector.dispose();
        await relayService.shutdown();
        await relayManager.shutdown();
        await carol.dispose();
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
            'B8 gates that a +/-${_skew.inHours}h device clock jump is '
            "DETECTED and SURFACED: a fast clock's refusal is classified "
            'rather than collapsed, a corroborated slow clock raises a '
            'verdict a single peer cannot, and each fault reaches the user in '
            'its own words. (The delivery cost of the jump is recorded as '
            'EVIDENCE, not gated — closing it needs clock correction, which '
            'is deferred.) Findings:\n'
            '${findings.map((f) => '  - $f').join('\n')}',
      );
    },
    // Stays BELOW the orchestrator's per-drive B8_DRIVE_TIMEOUT (20m) so a
    // genuine overrun fails HERE, with a named test and a readable reason,
    // rather than as an anonymous `flutter drive` kill.
    timeout: const Timeout(Duration(minutes: 17)),
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
  final id = _eventIdOf(encrypted.eventJson);
  debugPrint(
    '[b8] publish accepted=$accepted evt=${_short(id)} '
    '${accepted ? '' : 'relay="$msg"'}',
  );
  return (accepted: accepted, rejection: msg, eventId: id);
}

/// Encrypts a location and offers it through the PRODUCTION publish path —
/// `NostrRelayService` -> `RelayManagerFfi` -> `RelayManager::publish_event`
/// -> `publish_with_retry` -> `clock_skew::classify_publish_outcome`.
///
/// Returns whatever that path threw (or `null` on success), because the
/// CLASSIFICATION of the failure is the thing under test. Every other publish
/// in this lane goes through `TestRelay.publishAndAwaitOk`, which speaks to
/// the relay over its own WebSocket and therefore exercises none of it.
Future<({Object? error, String eventId})> _publishViaProductionPath({
  required TestUser alice,
  required CircleFfi circle,
  required NostrRelayService relayService,
  required ({double lat, double lon}) coords,
}) async {
  final encrypted = await alice.circleManager.encryptLocation(
    mlsGroupId: circle.mlsGroupId,
    senderPubkeyHex: alice.pubkeyHex,
    latitude: coords.lat,
    longitude: coords.lon,
    updateIntervalSecs: BigInt.from(198),
  );
  final id = _eventIdOf(encrypted.eventJson);
  Object? error;
  try {
    await relayService.publishEvent(
      eventJson: encrypted.eventJson,
      relays: <String>[defaultStrfryUrl],
    );
  } on Object catch (e) {
    error = e;
  }
  // Security Rule 8: the type, never the message — a publish error can carry
  // relay-controlled prose.
  debugPrint(
    '[b8] production publish evt=${_short(id)} '
    'threw=${error?.runtimeType ?? '-'}',
  );
  return (error: error, eventId: id);
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
/// `windows_truncated` (the Rule-12 incomplete-window flag) is NOT exposed
/// across the FFI, so this lane cannot read it and instead rules truncation out
/// by construction — the hermetic relay holds a handful of events, far under
/// `CATCHUP_MAX_EVENTS_PER_PAGE`, so no page is ever cut short and the backward
/// pager never engages.
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
Future<bool> _decryptOne(SyntheticUser bob, TestRelayEvent event) async =>
    await _decryptPeerSample(bob, event) != null;

/// One MLS-authenticated member's sealed clock reading.
typedef _PeerSample = ({String sender, DateTime timestamp});

/// Decrypts [event] on [bob]'s manager and returns the sender's own reading
/// from INSIDE the MLS ciphertext, attributed to the MLS-authenticated member
/// id that came back with it.
///
/// Never the outer kind-445 `created_at`: that field is unauthenticated and
/// attacker-writable (anyone who has observed one of the circle's events can
/// mint a kind-445 with an `h` tag and a `created_at` of their choosing), so
/// using it would hand a skew verdict to any observer.
Future<_PeerSample?> _decryptPeerSample(
  SyntheticUser bob,
  TestRelayEvent event,
) async {
  try {
    final outcome = await bob.user.circleManager
        .decryptLocationCollectingCommits(eventJson: jsonEncode(event.raw));
    for (final r in outcome.results) {
      final loc = r.location;
      if (r.kind == LocationMessageResultKindFfi.location && loc != null) {
        return (
          sender: loc.senderPubkey,
          timestamp: DateTime.fromMillisecondsSinceEpoch(
            loc.timestamp * 1000,
            isUtc: true,
          ),
        );
      }
    }
    return null;
  } on Object catch (e) {
    // Security Rule 8: runtimeType only — a raw error can carry MLS state.
    debugPrint('[b8] direct decrypt threw: ${e.runtimeType}');
    return null;
  }
}

// ---------------------------------------------------------------------------
// The user-visible surface
// ---------------------------------------------------------------------------

/// Pumps [ClockSkewBanner] over [detector] and returns every string it
/// painted.
///
/// The detector is the REAL one, already carrying a verdict derived from this
/// run's real evidence — so a green result here means the banner responds to
/// the fault, not to a hand-built status object.
Future<List<String>> _renderBanner(
  WidgetTester tester,
  ClockSkewDetector detector,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        clockSkewDetectorProvider.overrideWithValue(detector),
      ],
      child: const MaterialApp(
        locale: Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: ClockSkewBanner()),
      ),
    ),
  );
  await tester.pumpAndSettle();
  final texts = tester
      .widgetList<Text>(
        find.descendant(
          of: find.byType(ClockSkewBanner),
          matching: find.byType(Text),
        ),
      )
      .map((t) => t.data ?? '')
      .where((s) => s.isNotEmpty)
      .toList();
  // The copy itself is never logged — this log line is uploaded as a CI
  // artifact and there is no reason to widen what it carries.
  debugPrint('[b8] banner painted ${texts.length} text(s)');
  return texts;
}

/// The longest painted string, i.e. the body rather than the headline.
///
/// The banner paints a title and a body; the title is shared by both faults
/// by design, so comparing titles would report "distinct" as "identical".
String _longest(List<String> texts) {
  var longest = '';
  for (final t in texts) {
    if (t.length > longest.length) longest = t;
  }
  return longest;
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

/// The `id` field of a signed event JSON, or `''` when it cannot be read.
String _eventIdOf(String eventJson) {
  final decoded = jsonDecode(eventJson);
  return decoded is Map<String, dynamic>
      ? (decoded['id'] as String? ?? '')
      : '';
}

/// First 8 hex chars of an event id — enough to correlate a publish with a
/// later log line, far too little to be a tracking vector.
String _short(String hex) => hex.length <= 8 ? hex : hex.substring(0, 8);
