/// B9 drive target — proves what Haven's LIVE RECEIVE path does when the
/// device loses the network mid-session and gets it back
/// (`docs/CI_HARDENING_BACKLOG.md`, Workstream B, item B9:
/// "Network loss/reconnect | `adb emu network disable/enable`").
///
/// ## The item's stated MECHANISM does not exist — the lane uses another
///
/// There is no `network disable` / `network enable` in the Android emulator
/// console. The `network` command takes exactly four subcommands —
/// `status`, `speed`, `delay`, `capture` — verified by inspecting the
/// shipped `qemu-system-x86_64` binary's own help strings; the only
/// connectivity kill switch the console offers is `gsm data off`, which
/// reaches the CELLULAR path only, while an API-34 `google_apis` AVD routes
/// over its emulated Wi-Fi. The shell
/// (`tooling/e2e/ci/run-b9-network-reconnect.sh`) therefore drops the
/// network with `cmd connectivity airplane-mode enable` (verified through
/// `settings get global airplane_mode_on`) and additionally rejects the
/// relay port on the runner host, so the outage is immediate rather than
/// waiting out a 55 s WebSocket ping. THIS file never assumes either
/// worked: it proves the outage from inside the app process, and refuses to
/// score the recovery if it could not.
///
/// ## What recovery actually depends on (read from source before writing
/// this)
///
/// Three independent mechanisms can bring live receive back, at very
/// different speeds. The lane's budget is sized to the SLOWEST, because
/// which one fires is not under the test's control:
///
///  1. **The relay pool's own reconnect.** `build_engine_client`
///     (`haven-core/src/relay/live_sync/session.rs`) takes
///     `RelayOptions::default()`, i.e. `reconnect: true` with a 10 s
///     `DEFAULT_RETRY_INTERVAL` adapting up to a 60 s `MAX_RETRY_INTERVAL`
///     (`nostr-relay-pool-0.44`). On reconnect, `post_connection` calls
///     `resubscribe()`, which re-sends every stored filter VERBATIM — same
///     subscription id, same `since` — so the relay replays whatever landed
///     during the gap. `should_resubscribe` returns true after a drop
///     because `connected_at > subscribed_at` once the socket has come back.
///     This is the fast path: seconds to ~a minute.
///  2. **Haven's M8 subscription-health tick.** `maintainSubscriptionHealth`
///     re-anchors every subscription at its persisted cursor via
///     `resume_after_background` when any relay is `Disconnected`
///     (`haven-core/src/relay/live_sync/health.rs`). Scheduled by
///     `maintenanceSchedulerProvider` at +90 s and then every 15 minutes
///     (`subscriptionHealthInterval`).
///  3. **`MapShell`'s self-heal.** If the drop kills the engine outright,
///     `NostrSubscriptionService._onStreamClosed` tears the session down
///     (the handle would otherwise pin the Rule-14 guard), and NOTHING
///     restarts it except `_healLiveSyncIfStopped` →
///     `LiveSyncResubscriber.ensureRunning()`, on a jittered 90–150 s timer
///     that DOUBLES per consecutive failure up to ×8 (`map_shell.dart`).
///     A heal attempt made while the network is still down counts as a
///     failure, so one wasted tick pushes the next one out to 180–300 s.
///
/// [_recoveryBudget] is sized against (3), not against (1): 330 s covers a
/// heal tick that was burned during the outage plus its doubled successor.
/// A lane budgeted for the fast path would report a product defect every
/// time the slow path legitimately ran.
///
/// ## The assertion is a DECRYPTED PEER EVENT, not a reopened socket
///
/// A socket that comes back proves nothing a user cares about. This target
/// requires that a peer location published AFTER the outage reaches
/// `memberLocationsProvider` with the peer's NEW coordinates. The
/// coordinates are the anti-vacuity check and they are load-bearing:
/// `memberLocationsProvider` still holds the peer's PRE-outage entry, so
/// "an entry for Bob exists" is satisfied by the stale baseline and would
/// pass on an app whose receive path never came back at all. [_postLatitude]
/// / [_postLongitude] are therefore deliberately different from
/// [bobFakeLatitude] / [bobFakeLongitude], and the check is on the value.
///
/// ## The gap-stamped first event
///
/// Bob's first post-outage kind-445 is ENCRYPTED while the network is still
/// down (encryption is local MLS work and needs no relay), so its
/// `created_at` falls strictly inside the outage window, and it is published
/// the instant connectivity returns. That is the closest this lane can get
/// to a genuine backlog replay without a second, independently-connected
/// host: Bob and Alice share one emulator, so an outage that stops Alice
/// receiving also stops Bob publishing.
///
/// The re-publish loop that follows exists for a real reason, not for
/// belt-and-braces: the kind-445 wire TTL is a fixed `created_at + 228 s`
/// NIP-40 `expiration` (group component 0x8005), and strfry deletes expired
/// events on its own cron. A recovery that legitimately takes the slow
/// heal path (3) can outlast that, so a single gap-stamped event would make
/// the lane fail on relay retention rather than on app behaviour. Each
/// re-publish carries the SAME new coordinates, so every one of them is
/// still an event Alice has never seen, and the count is reported.
///
/// ## Why the body never throws mid-sequence
///
/// The shell drives the two network toggles from OUTSIDE the process and
/// waits on markers this file prints. A phase that threw would leave the
/// shell waiting for a marker that can never arrive, burning the lane's
/// deadline and reporting a timeout instead of the finding. Every phase
/// therefore RECORDS a verdict and continues; the collected verdicts are
/// asserted once, at the end, after connectivity has been restored and all
/// evidence is in logcat. The shell's oracle re-derives the same verdicts
/// from the markers independently, so a `flutter drive` that exits 0 on a
/// failed body (`drive-log-lib.sh`) cannot hide them.
///
/// ## Markers
///
/// Owned by THIS file. Change here AND in the shell together, or the lane
/// silently stops finding them.
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/main.dart';
import 'package:haven/src/pages/map_shell.dart';
import 'package:haven/src/providers/circles_provider.dart'
    show circlesProvider, selectedCircleIdProvider;
import 'package:haven/src/providers/identity_provider.dart'
    show identityNotifierProvider, identityProvider;
import 'package:haven/src/providers/key_package_provider.dart'
    show keyPackagePublisherProvider;
import 'package:haven/src/providers/live_sync_provider.dart'
    show liveSyncEnabled;
import 'package:haven/src/providers/location_sharing_provider.dart'
    show memberLocationsProvider;
import 'package:haven/src/providers/onboarding_provider.dart'
    show
        OnboardingController,
        OnboardingFlags,
        kOnboardingCompletedKey,
        kOnboardingIntroSeenKey,
        onboardingControllerProvider;
import 'package:haven/src/providers/service_providers.dart'
    show
        circleServiceProvider,
        locationServiceProvider,
        subscriptionServiceProvider;
import 'package:haven/src/rust/api.dart'
    show CircleCreationResultFfi, MemberKeyPackageFfi, RelayManagerFfi;
import 'package:haven/src/services/fresh_secret.dart' show withFreshSecret;
import 'package:haven/src/services/nostr_circle_service.dart'
    show NostrCircleService;
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'e2e/_lib/circle_creation.dart' show createCircleConfirmed;
import 'e2e/_lib/coordination.dart' show waitForKeyPackage;
import 'e2e/_lib/fake_location_service.dart'
    show
        FakeLocationService,
        aliceFakeLatitude,
        aliceFakeLongitude,
        bobFakeLatitude,
        bobFakeLongitude;
import 'e2e/_lib/pump_helpers.dart' show pumpUntilFound;
import 'e2e/_lib/scenario_harness.dart' show ScenarioHarness;
import 'e2e/_lib/synthetic_user.dart' show SyntheticUser;
import 'e2e/_lib/test_relay.dart' show TestRelay, defaultStrfryUrl;
import 'e2e/_lib/test_user.dart' show TestUser, aliceSeed;

/// Printed once identity, a two-member circle and a live engine all exist —
/// i.e. the session this lane is about to disconnect is genuinely live.
const String kArmedMarker = '[b9] ARMED';

/// Printed with `ms=<n>` once Alice has DECRYPTED a peer location over the
/// live engine BEFORE the outage. The shell parses it; without a baseline,
/// "the peer location did not arrive after the outage" is unattributable.
const String kBaselineReceivedMarker = '[b9] BASELINE_RECEIVED';

/// The negative twin of [kBaselineReceivedMarker].
const String kBaselineDeadMarker = '[b9] BASELINE_DEAD';

/// Printed with `running=<bool>`: the live-sync engine's own liveness before
/// the drop. `false` makes the whole lane vacuous — nothing was connected to
/// disconnect — so the shell fails on it.
const String kEngineBaselineMarker = '[b9] ENGINE_BASELINE';

/// The shell's cue to drop the network.
const String kAwaitingDownMarker = '[b9] AWAITING_NETWORK_DOWN';

/// Printed with `ms=<n>` once the APP PROCESS ITSELF could no longer open a
/// socket to the relay — proof the drop reached the process under test, not
/// merely that adb accepted a command.
const String kOutageObservedMarker = '[b9] OUTAGE_OBSERVED';

/// The negative twin: connectivity never went away, so nothing that follows
/// says anything about reconnect.
const String kOutageNotObservedMarker = '[b9] OUTAGE_NOT_OBSERVED';

/// Evidence (never asserted) with `running=<bool>`: whether the engine
/// survived the outage or was torn down by
/// `NostrSubscriptionService._onStreamClosed`. Decides which recovery
/// mechanism the run actually exercised.
const String kEngineDuringOutageMarker = '[b9] ENGINE_DURING_OUTAGE';

/// The shell's cue to restore the network.
const String kAwaitingUpMarker = '[b9] AWAITING_NETWORK_UP';

/// Printed with `ms=<n>` once the app process could reach the relay again.
const String kNetworkRestoredMarker = '[b9] NETWORK_RESTORED';

/// The negative twin of [kNetworkRestoredMarker] — a harness failure, since
/// the shell was asked to restore connectivity and it did not come back.
const String kNetworkNotRestoredMarker = '[b9] NETWORK_NOT_RESTORED';

/// Printed once the peer's post-outage kind-445 has been OK-acked by the
/// relay. Publishing is a precondition for receiving; without this line a
/// silent receive path and a silent send path are indistinguishable.
const String kPeerPublishedMarker = '[b9] PEER_PUBLISHED_POST_OUTAGE';

/// The negative twin of [kPeerPublishedMarker].
const String kPeerPublishFailedMarker = '[b9] PEER_PUBLISH_FAILED';

/// THE HEADLINE. Printed with `ms=<n> republishes=<n>` once
/// `memberLocationsProvider` surfaces the peer's POST-OUTAGE coordinates —
/// a peer event decrypted after the reconnect, not a socket that reopened.
const String kReceiveResumedMarker = '[b9] RECEIVE_RESUMED';

/// The negative twin, and the REAL FINDING case: connectivity came back, the
/// peer published, and live receive never recovered.
const String kReceiveDeadMarker = '[b9] RECEIVE_DEAD';

/// Evidence with `running=<bool>`: engine liveness after the recovery window.
const String kEngineRecoveredMarker = '[b9] ENGINE_AFTER_RECOVERY';

/// Closes the capture. Printed unconditionally, before the final assertion,
/// so the shell's oracle always reads a complete window.
const String kSequenceCompleteMarker = '[b9] SEQUENCE_COMPLETE';

/// The peer's POST-OUTAGE coordinates.
///
/// Deliberately distinct from [bobFakeLatitude] / [bobFakeLongitude]: the
/// pre-outage entry is still in `memberLocationsProvider`, so a presence
/// check would be satisfied by stale state on an app whose receive path
/// never came back. Same obviously-synthetic shape as the sentinels in
/// `fake_location_service.dart`.
const double _postLatitude = 15.678901;

/// Longitude twin of [_postLatitude].
const double _postLongitude = 93.210987;

/// Coordinate comparison tolerance. The wire carries `f64` through MLS and
/// JSON, so an exact `==` would be brittle; 1e-6 is far tighter than the gap
/// between the baseline and post-outage sentinels.
const double _coordEpsilon = 1e-6;

/// How long the baseline peer location may take to arrive over the live
/// engine before the lane calls the session dead.
///
/// Generous relative to the sub-second delivery the M11 scenarios measure:
/// this runs on a cold, memory-constrained CI emulator, and a slow baseline
/// is still a usable baseline while a premature failure destroys the run.
const Duration _baselineReceiveTimeout = Duration(seconds: 75);

/// How long to wait for the shell's network drop to become observable from
/// inside the app process.
const Duration _outageObserveTimeout = Duration(seconds: 120);

/// How long to wait for the shell's restore to become observable.
const Duration _restoreObserveTimeout = Duration(seconds: 120);

/// How long the outage is held once observed.
///
/// Long enough that the relay pool has certainly failed at least one
/// reconnect attempt (`DEFAULT_RETRY_INTERVAL` 10 s) and that a `PING_INTERVAL`
/// (55 s) has elapsed, so the socket is declared dead by the pool's own
/// liveness path even in the case where the OS did not tear the socket down.
/// Kept short enough that at most ONE `MapShell` heal tick (90–150 s) can be
/// burned inside it, bounding the doubled-backoff worst case
/// [_recoveryBudget] has to cover.
const Duration _outageHold = Duration(seconds: 75);

/// How long live receive gets to come back after connectivity returns.
///
/// Sized to the SLOWEST recovery mechanism, not the fastest — see the class
/// doc. Worst case is a `MapShell` heal tick burned during the outage
/// (marking one consecutive failure) followed by its doubled successor at up
/// to 2 × 150 s = 300 s, plus the engine restart and a relay round trip.
const Duration _recoveryBudget = Duration(seconds: 330);

/// Spacing between the peer's post-outage re-publishes.
///
/// Comfortably inside the fixed 228 s kind-445 NIP-40 expiration, so there
/// is always an unexpired event on the relay for a late reconnect to find.
const Duration _republishSpacing = Duration(seconds: 45);

/// How long a single relay reachability probe may take before it counts as
/// unreachable. Short: with no route the connect fails immediately, and this
/// bound only covers the pathological case where it neither connects nor
/// errors.
const Duration _probeTimeout = Duration(seconds: 6);

/// Opens and immediately closes a WebSocket to the hermetic relay from
/// INSIDE the app process, returning whether it succeeded.
///
/// This is the lane's outage oracle. It runs in the process under test and
/// over the exact transport the live-sync engine uses, so it cannot report
/// an outage the app is not experiencing, and it validates itself: the same
/// probe must succeed before the drop and after the restore, so a probe that
/// had rotted into always-failing could never satisfy the sequence.
Future<bool> _relayReachable() async {
  TestRelay? probe;
  try {
    probe = await TestRelay.connect().timeout(_probeTimeout);
    return true;
  } on Object catch (_) {
    return false;
  } finally {
    if (probe != null) {
      try {
        await probe.dispose();
      } on Object catch (_) {
        // Best-effort: the probe's only job was to answer reachable/not.
      }
    }
  }
}

/// Pumps real frames while polling an asynchronous [condition], returning
/// `true` when it held and `false` on timeout.
///
/// Never throws: this target must reach its markers in every outcome (see
/// the class doc), so a timeout is a value, not an exception. Frames are
/// pumped rather than merely awaited because the state under observation
/// (`memberLocationsProvider`) is refreshed by provider invalidations the
/// live-sync router raises, and `MapShell` only rebuilds while a pump is in
/// flight under `LiveTestWidgetsFlutterBinding`.
Future<bool> _pumpUntilAsync(
  WidgetTester tester,
  Future<bool> Function() condition, {
  required Duration timeout,
  Duration probeSpacing = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await condition()) return true;
    final until = DateTime.now().add(probeSpacing);
    while (DateTime.now().isBefore(until)) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  }
  return condition();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'B9: a network drop mid-session must not silently end live location '
    'receive — a peer location published after the reconnect is decrypted',
    (tester) async {
      // The shell drops the network with Android shell commands
      // (`cmd connectivity airplane-mode`), and the recovery paths under
      // test are reached through the Android build. iOS connectivity has no
      // equivalent simctl lever and is out of scope for this item.
      if (!Platform.isAndroid) {
        markTestSkipped(
          'b9_network_reconnect_test drives the Android '
          '`cmd connectivity airplane-mode` toggle; skipped on non-Android '
          'runtimes.',
        );
        return;
      }

      // Verdicts collected across the sequence and asserted ONCE at the end,
      // so a failure never strands the shell mid-toggle (see class doc).
      final failures = <String>[];

      if (!liveSyncEnabled) {
        // Not a skip: the lane's workflow sets HAVEN_LIVE_SYNC=true, so an
        // APK built without it is a wiring defect that must be loud. The
        // 30 s poll path is a different receive mechanism with a different
        // recovery story, and scoring it here would report a result for a
        // subsystem this lane does not name.
        failures.add(
          'this APK was built with liveSyncEnabled=false, so the persistent '
          'relay-subscription engine whose reconnect this lane exists to '
          'prove was never started. Check HAVEN_LIVE_SYNC in '
          '.github/workflows/e2e-network-reconnect.yml',
        );
      }

      // --- Harness: Rust bridge, in-memory keyring, hermetic relay.
      final ctx = await ScenarioHarness.bootstrap();
      var relay = ctx.relay;

      // Alice under the PRODUCTION secure-storage key, onboarding skipped.
      await TestUser.preSeedIdentityAndSkipOnboarding(seed: aliceSeed);

      final prefs = await SharedPreferences.getInstance();
      final introSeen = prefs.getBool(kOnboardingIntroSeenKey) ?? false;
      final completed = prefs.getBool(kOnboardingCompletedKey) ?? false;
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            onboardingControllerProvider.overrideWith(
              (ref) => OnboardingController(
                OnboardingFlags(introSeen: introSeen, completed: completed),
              ),
            ),
            // The RECEIVE path is this lane's subject, so Alice's own
            // position source is deliberately faked: a real GPS dependency
            // would add `adb emu geo fix` re-issue loops and a verified
            // permission gate to the shell for a signal this lane never
            // reads. B3 owns the real-GPS proof.
            locationServiceProvider.overrideWithValue(
              FakeLocationService(
                latitude: aliceFakeLatitude,
                longitude: aliceFakeLongitude,
              ),
            ),
          ],
          child: const HavenApp(),
        ),
      );
      // pumpUntilFound, never pumpAndSettle: MapShell's periodic timers (the
      // heal backstop among them) keep the frame queue non-empty forever.
      await pumpUntilFound(
        tester,
        find.byType(MapShell),
        description: 'MapShell after pumpWidget',
      );

      // The app's OWN container — never a drive-owned second one, or the
      // engine read here would not be the one the UI is running.
      final container = ProviderScope.containerOf(
        tester.element(find.byType(HavenApp)),
        listen: false,
      );

      await container.read(identityProvider.future);
      expect(
        container.read(identityProvider).valueOrNull,
        isNotNull,
        reason: 'identityProvider resolved to null after '
            'preSeedIdentityAndSkipOnboarding — MapShell gates its whole '
            'startup (including _startLiveSync) on it, so there would be no '
            'receive plane to disconnect.',
      );
      await container.read(keyPackagePublisherProvider.future);

      final circleService = container.read(circleServiceProvider);
      if (circleService is! NostrCircleService) {
        throw StateError(
          '[b9] circleServiceProvider is not Nostr-backed in this run — the '
          'production receive path this target exercises was bypassed.',
        );
      }
      final manager = await circleService.getCircleManagerFfi();

      // A real second party is REQUIRED here, unlike B6: the assertion is a
      // decrypted PEER location, and Haven never surfaces its own publishes
      // through memberLocationsProvider.
      final bob = await SyntheticUser.bob(relay);
      await waitForKeyPackage(relay: relay, authorPubkeyHex: bob.pubkeyHex);

      final relayManager = await RelayManagerFfi.newInstance();
      final CircleCreationResultFfi creation;
      try {
        final bobKp = await relayManager.fetchMemberKeypackage(
          pubkey: bob.pubkeyHex,
        );
        if (bobKp == null) {
          throw StateError(
            '[b9] fetchMemberKeypackage returned null for Bob — his '
            'KeyPackage was not found on the relay.',
          );
        }
        creation = await withFreshSecret(
          () => container
              .read(identityNotifierProvider.notifier)
              .getSecretBytes(),
          // Publishes Bob's gift-wrapped Welcome and CONFIRMS the staged
          // create (Security Rule 13). Without the confirm the group stays
          // in MDK's PendingPublish, where every inbound kind-445 returns
          // `Buffered` — the baseline receive would time out and the lane
          // would report a reconnect defect that never happened.
          (aliceSecret) => createCircleConfirmed(
            manager: manager,
            relay: relay,
            identitySecretBytes: aliceSecret,
            members: <MemberKeyPackageFfi>[bobKp],
            name: 'B9 Network Reconnect Circle',
            circleType: 'location_sharing',
            relays: <String>[defaultStrfryUrl],
            // Synthetic peers advertise no inbox relays, so the admin's own
            // relay is the Welcome-delivery fallback (production admin flow).
            creatorFallbackRelays: <String>[defaultStrfryUrl],
            label: 'b9',
          ),
        );
      } finally {
        await relayManager.shutdown();
      }

      final bobCircle = await bob.acceptInvitationViaRelay(relay: relay);

      // Mirror the UI's post-create provider mutation: refresh circlesProvider
      // (so LiveSyncResubscriber's listener re-anchors the engine onto the new
      // circle) and SELECT the circle, because memberLocationsProvider is
      // scoped to the selection and would otherwise never observe Bob at all.
      container.invalidate(circlesProvider);
      await container.read(circlesProvider.future);
      container.read(selectedCircleIdProvider.notifier).state =
          creation.circle.mlsGroupId.toList();

      // Give the debounced LiveSyncResubscriber time to re-anchor the engine
      // onto the new circle's `#h` before the baseline publish.
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }

      final engine = container.read(subscriptionServiceProvider);
      debugPrint(kArmedMarker);

      // ===================================================================
      // Phase 1 — baseline: live receive works before anything is broken.
      // ===================================================================
      final baselineStart = DateTime.now();
      try {
        await bob.publishLocation(
          circle: bobCircle,
          latitude: bobFakeLatitude,
          longitude: bobFakeLongitude,
          relay: relay,
        );
      } on Object catch (e) {
        failures.add(
          "the peer's BASELINE location could not be published "
          '(${e.runtimeType}) — the lane never had a working session to '
          'disconnect',
        );
      }

      final baselineOk = await _pumpUntilAsync(
        tester,
        () async => _hasCoords(
          container,
          senderPubkeyHex: bob.pubkeyHex,
          latitude: bobFakeLatitude,
          longitude: bobFakeLongitude,
        ),
        timeout: _baselineReceiveTimeout,
      );
      if (baselineOk) {
        debugPrint(
          '$kBaselineReceivedMarker '
          'ms=${DateTime.now().difference(baselineStart).inMilliseconds}',
        );
      } else {
        debugPrint(kBaselineDeadMarker);
        failures.add(
          "the peer's BASELINE location never reached "
          'memberLocationsProvider within '
          '${_baselineReceiveTimeout.inSeconds}s. Live receive was already '
          'broken BEFORE the network was touched, so nothing this lane '
          'observes afterwards can be attributed to the drop',
        );
      }

      final engineBaseline = engine.isRunning;
      debugPrint('$kEngineBaselineMarker running=$engineBaseline');
      if (!engineBaseline) {
        failures.add(
          'the live-sync engine was NOT running before the drop, so there '
          'was no standing subscription to disconnect and the reconnect '
          'verdict below is vacuous',
        );
      }

      // Release the harness's own relay socket BEFORE the outage. TestRelay
      // has a bounded 3-attempt reconnect budget and latches `_closed` when
      // it is exhausted, so carrying one through a 75 s blackout would leave
      // a permanently dead handle for the post-outage publish — a harness
      // failure that would present as "the peer could not publish".
      try {
        await relay.dispose();
      } on Object catch (_) {
        // Best-effort; a fresh handle is opened after the restore.
      }

      // ===================================================================
      // Phase 2 — the shell drops the network.
      // ===================================================================
      debugPrint(kAwaitingDownMarker);
      final downStart = DateTime.now();
      final outageObserved = await _pumpUntilAsync(
        tester,
        () async => !await _relayReachable(),
        timeout: _outageObserveTimeout,
        probeSpacing: const Duration(seconds: 3),
      );
      if (outageObserved) {
        debugPrint(
          '$kOutageObservedMarker '
          'ms=${DateTime.now().difference(downStart).inMilliseconds}',
        );
      } else {
        debugPrint(kOutageNotObservedMarker);
        failures.add(
          'the relay stayed reachable from inside the app process for '
          '${_outageObserveTimeout.inSeconds}s after the shell was cued to '
          'drop the network. This is a HARNESS failure, not a product '
          'finding — the app was never disconnected, so anything observed '
          'afterwards says nothing about reconnect',
        );
      }

      // Hold the blackout. Frames keep being pumped so the app's own timers,
      // the engine supervisor and the heal backstop all run inside it — the
      // point is to let the app react to a real, sustained outage.
      if (outageObserved) {
        final holdUntil = DateTime.now().add(_outageHold);
        while (DateTime.now().isBefore(holdUntil)) {
          await tester.pump(const Duration(milliseconds: 250));
        }
      }
      debugPrint('$kEngineDuringOutageMarker running=${engine.isRunning}');

      // Encrypt the peer's post-outage location WHILE STILL OFFLINE, so its
      // `created_at` falls inside the blackout (see the class doc). Purely
      // local MLS work — no relay is involved — and it is published the
      // instant connectivity returns.
      String? gapStampedEventJson;
      try {
        final encrypted = await bob.user.circleManager.encryptLocation(
          mlsGroupId: bobCircle.circle.mlsGroupId,
          senderPubkeyHex: bob.pubkeyHex,
          latitude: _postLatitude,
          longitude: _postLongitude,
          updateIntervalSecs: BigInt.from(198),
        );
        gapStampedEventJson = encrypted.eventJson;
      } on Object catch (e) {
        // Recorded, never fatal: the re-publish loop below produces
        // equivalent events, so losing the gap stamp costs fidelity, not
        // the assertion.
        debugPrint('[b9] gap-stamped encrypt failed: ${e.runtimeType}');
      }

      // ===================================================================
      // Phase 3 — the shell restores the network.
      // ===================================================================
      debugPrint(kAwaitingUpMarker);
      final upStart = DateTime.now();
      final restored = await _pumpUntilAsync(
        tester,
        _relayReachable,
        timeout: _restoreObserveTimeout,
        probeSpacing: const Duration(seconds: 3),
      );
      if (restored) {
        debugPrint(
          '$kNetworkRestoredMarker '
          'ms=${DateTime.now().difference(upStart).inMilliseconds}',
        );
      } else {
        debugPrint(kNetworkNotRestoredMarker);
        failures.add(
          'the relay never became reachable again within '
          '${_restoreObserveTimeout.inSeconds}s of the shell being cued to '
          'restore the network. HARNESS failure — recovery could not be '
          'tested',
        );
      }

      if (restored) {
        final recoveryStart = DateTime.now();
        TestRelay? postRelay;
        var republishes = 0;
        var published = false;
        try {
          postRelay = await TestRelay.connect();
          relay = postRelay;

          // The gap-stamped event first, if we have one.
          if (gapStampedEventJson != null) {
            final (accepted, msg) =
                await postRelay.publishAndAwaitOk(gapStampedEventJson);
            published = accepted;
            if (!accepted) {
              debugPrint('[b9] gap-stamped publish rejected: $msg');
            }
          }
          if (!published) {
            await bob.publishLocation(
              circle: bobCircle,
              latitude: _postLatitude,
              longitude: _postLongitude,
              relay: postRelay,
            );
            published = true;
          }
          debugPrint(kPeerPublishedMarker);
        } on Object catch (e) {
          debugPrint('$kPeerPublishFailedMarker reason=${e.runtimeType}');
          failures.add(
            'the peer could not publish a location after connectivity '
            'returned (${e.runtimeType}) — the receive verdict below cannot '
            'be read, because nothing was sent to receive',
          );
        }

        if (published) {
          var lastRepublish = DateTime.now();
          final resumed = await _pumpUntilAsync(
            tester,
            () async {
              if (_hasCoords(
                container,
                senderPubkeyHex: bob.pubkeyHex,
                latitude: _postLatitude,
                longitude: _postLongitude,
              )) {
                return true;
              }
              // Keep an unexpired event on the relay: the kind-445 NIP-40
              // expiration is a fixed created_at + 228 s and strfry prunes
              // on a cron, so a slow (but correct) heal-path recovery would
              // otherwise arrive to an empty relay and be scored as a
              // product defect.
              if (DateTime.now().difference(lastRepublish) >=
                  _republishSpacing) {
                lastRepublish = DateTime.now();
                republishes++;
                try {
                  await bob.publishLocation(
                    circle: bobCircle,
                    latitude: _postLatitude,
                    longitude: _postLongitude,
                    relay: relay,
                  );
                } on Object catch (e) {
                  debugPrint('[b9] re-publish failed: ${e.runtimeType}');
                }
              }
              return false;
            },
            timeout: _recoveryBudget,
            probeSpacing: const Duration(seconds: 3),
          );

          if (resumed) {
            debugPrint(
              '$kReceiveResumedMarker '
              'ms=${DateTime.now().difference(recoveryStart).inMilliseconds} '
              'republishes=$republishes',
            );
          } else {
            debugPrint('$kReceiveDeadMarker republishes=$republishes');
            failures.add(
              'live location receive did NOT recover within '
              '${_recoveryBudget.inSeconds}s of connectivity returning. The '
              "peer's post-outage location was published and OK-acked by the "
              'relay, and Alice never decrypted it — a network drop '
              'permanently ended live receive for the session. The budget '
              'covers all three recovery paths: the relay pool reconnect '
              '(<=60s), the M8 subscription-health tick, and '
              "MapShell's 90-150s self-heal with one doubled retry",
            );
          }
        }

        debugPrint('$kEngineRecoveredMarker running=${engine.isRunning}');

        if (postRelay != null) {
          try {
            await postRelay.dispose();
          } on Object catch (_) {
            // Best-effort teardown.
          }
        }
      }

      try {
        await bob.dispose();
      } on Object catch (_) {
        // Best-effort teardown; does not affect the verdict.
      }

      debugPrint(kSequenceCompleteMarker);

      // Single terminal assertion. Everything above is already in logcat, so
      // the shell's oracle has a complete window regardless of what happens
      // here.
      expect(
        failures,
        isEmpty,
        reason: 'B9 findings:\n - ${failures.join('\n - ')}',
      );
    },
    timeout: const Timeout(Duration(minutes: 16)),
  );
}

/// Whether `memberLocationsProvider` currently holds an entry for
/// [senderPubkeyHex] at [latitude] / [longitude] (within [_coordEpsilon]).
///
/// The COORDINATES are the check, never mere presence: the peer's pre-outage
/// entry survives the blackout, so a presence test would be satisfied by
/// stale state on an app whose receive path never came back.
bool _hasCoords(
  ProviderContainer container, {
  required String senderPubkeyHex,
  required double latitude,
  required double longitude,
}) {
  final locs = container.read(memberLocationsProvider).valueOrNull;
  if (locs == null) return false;
  final sender = senderPubkeyHex.toLowerCase();
  for (final l in locs) {
    if (l.pubkey.toLowerCase() != sender) continue;
    if ((l.latitude - latitude).abs() < _coordEpsilon &&
        (l.longitude - longitude).abs() < _coordEpsilon) {
      return true;
    }
  }
  return false;
}
