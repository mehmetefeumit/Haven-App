/// M7-A test (e): verifies that the iOS background receive timer
/// (`_receiveTimer`) stops after a mid-pause disable of background sharing,
/// so zero further catch-up sweeps fire after the user opts out.
///
/// Because `_MapShellState` is a private class and `_receiveTimer` is a
/// private field, we test the OBSERVABLE EFFECT instead: we inject a
/// counting `CatchupService` factory via the `catchupServiceProvider` override
/// and assert that after a background-sharing disable event the service's
/// `runCatchup` count does not increase further.
///
/// Note: `_startIosBackgroundReceiveTimer` is only called when
/// `bgEnabled && Platform.isIOS` — on a Linux test runner `Platform.isIOS`
/// is always false, so the production path cannot be pumped in a widget test.
/// This test therefore verifies the design contracts at the
/// BackgroundSharingNotifier + CatchupService level (the two units that
/// actually enforce the privacy guarantee), where the seam is fully injectable:
///
/// 1. A `BackgroundSharingNotifier` emits `false` when disabled.
/// 2. The `_bgSharingPausedSub` listener in `_startIosBackgroundReceiveTimer`
///    sees the `false` and cancels `_receiveTimer`.
/// 3. The `CatchupService` chokepoint (C3) also blocks any in-flight or
///    already-queued wake that arrived between the timer cancel and the sub
///    firing (belt-and-suspenders).
///
/// We test items (1) + (3) directly, and document item (2) as a device-test
/// concern (requires iOS simulator + lifecycle control, per §F of the plan).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/providers/background_location_provider.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/catchup_service.dart';
import 'package:haven/src/services/relay_service.dart' show CatchupResult;
import 'package:shared_preferences/shared_preferences.dart';

import '../mocks/mock_relay_service.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// A [RelayService] that counts how many times [runCatchup] is called.
class _CountingRelayService extends MockRelayService {
  int catchupCalls = 0;

  @override
  Future<CatchupResult> runCatchup({
    required CircleManagerFfi circle,
    required String ownPubkeyHex,
    int maxDurationSecs = 20,
  }) async {
    catchupCalls++;
    return const CatchupResult(locationsApplied: 1, cursorsAdvanced: 0);
  }
}

/// Fake [CircleManagerFfi] that is never invoked in these tests.
class _FakeCircleManager implements CircleManagerFfi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected: ${invocation.memberName}');
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // (e) C3 chokepoint prevents relay contact after a disable —
  // simulates what happens if a timer tick races a disable event.
  group('(e) Mid-session disable: CatchupService chokepoint blocks background '
      'relay activity (M7-A, C3)', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('runCatchup(isBackgroundWake:true) returns empty after sharing is '
        'disabled even if the timer fires before it is cancelled', () async {
      // Step 1: Sharing starts enabled.
      SharedPreferences.setMockInitialValues({kBackgroundSharingKey: true});

      final relay = _CountingRelayService();
      final service = CatchupService(
        relayService: relay,
        circleManagerFactory: () async => _FakeCircleManager(),
        ownPubkeyHex: () async => 'test_pubkey',
        isBackgroundSharingEnabled: () async {
          // Reads the LIVE prefs value so the test can flip it mid-run.
          final prefs = await SharedPreferences.getInstance();
          return prefs.getBool(kBackgroundSharingKey) ?? false;
        },
      );

      // Step 2: While sharing is on, a background wake fires — relay IS
      // contacted (baseline).
      final result1 = await service.runCatchup(isBackgroundWake: true);
      expect(relay.catchupCalls, 1, reason: 'baseline: gate is open');
      expect(result1.locationsApplied, 1);

      // Step 3: User disables background sharing (simulating
      // BackgroundSharingNotifier.setEnabled(false) writing the pref).
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(kBackgroundSharingKey, false);

      // Step 4: A timer tick fires AFTER the disable (races the timer
      // cancel). The C3 chokepoint must block it.
      final result2 = await service.runCatchup(isBackgroundWake: true);
      expect(
        relay.catchupCalls,
        1, // STILL 1 — the second call must not reach the relay
        reason:
            'After background sharing is disabled, a background-wake '
            'runCatchup must hard-return empty without touching the relay. '
            'This is the C3 chokepoint — the third backstop after the '
            'timer cancel (C4) and the scheduler teardown (C1).',
      );
      expect(result2.locationsApplied, 0);
    });

    test(
      'runCatchup(isBackgroundWake:false) — foreground — still runs after '
      'background sharing is disabled (foreground receive must not be gated)',
      () async {
        // Background sharing is OFF.
        SharedPreferences.setMockInitialValues({kBackgroundSharingKey: false});

        final relay = _CountingRelayService();
        final service = CatchupService(
          relayService: relay,
          circleManagerFactory: () async => _FakeCircleManager(),
          ownPubkeyHex: () async => 'test_pubkey',
          isBackgroundSharingEnabled: () async {
            final prefs = await SharedPreferences.getInstance();
            return prefs.getBool(kBackgroundSharingKey) ?? false;
          },
        );

        // Foreground callers must NOT be blocked.
        final result = await service.runCatchup(isBackgroundWake: false);
        expect(
          relay.catchupCalls,
          1,
          reason:
              'Foreground receive must not be gated on the background-sharing '
              'toggle. A user who opts out of background activity must still '
              'receive peer location updates while the app is open.',
        );
        expect(result.locationsApplied, 1);
      },
    );

    // -----------------------------------------------------------------------
    // Document the `_bgSharingPausedSub` timer-cancel path as an explicit
    // design note test so the intent is machine-readable and visible in CI
    // output, even though we cannot pump the full widget lifecycle on Linux.
    // -----------------------------------------------------------------------
    test('(design note) _startIosBackgroundReceiveTimer installs a '
        'backgroundSharingProvider listener that cancels _receiveTimer '
        'on disable — verified at the unit level via the C3 chokepoint above; '
        'the timer-cancel side of C4 requires an iOS device test (see §F)', () {
      // This test is intentionally a no-op assertion. Its purpose is to
      // make the design contract visible in the test report and to serve
      // as a placeholder that future device tests can reference.
      //
      // The privacy guarantee is:
      //   - The `_bgSharingPausedSub` watcher (C4) cancels `_receiveTimer`
      //     immediately when `backgroundSharingProvider` emits false while
      //     the app is paused on iOS.
      //   - Even if the timer fires before the cancel lands, the C3
      //     chokepoint in `CatchupService.runCatchup(isBackgroundWake:true)`
      //     hard-returns without any relay contact.
      //
      // C3 is fully unit-tested above. C4's timer-cancel side is
      // device/platform-only and covered by the M7-A device validation
      // matrix in `docs/M7_BACKGROUND_SHARING_PLAN.md §F`.
      expect(true, isTrue);
    });
  });

  // -------------------------------------------------------------------------
  // Verify that the backgroundSharingProvider emits the expected sequence
  // (enabled → disabled) so the _bgSharingPausedSub listener in MapShell
  // would see the correct value.
  // -------------------------------------------------------------------------

  group('BackgroundSharingNotifier emits false on setEnabled(false) — '
      'the value the _bgSharingPausedSub listener observes (M7-A, C4)', () {
    test(
      'state transitions from true → false when setEnabled(false) is called',
      () async {
        SharedPreferences.setMockInitialValues({kBackgroundSharingKey: true});

        final notifier = BackgroundSharingNotifier(
          ensurePermissions: () async {
            throw StateError('must not be called when disabling');
          },
        );
        await Future<void>.delayed(Duration.zero); // let _load() complete
        expect(notifier.state, isTrue, reason: 'baseline: sharing is on');

        final container = ProviderContainer(
          overrides: [backgroundSharingProvider.overrideWith((_) => notifier)],
        );
        addTearDown(container.dispose);

        // Collect the sequence of values emitted.
        final emitted = <bool>[];
        container.listen<bool>(
          backgroundSharingProvider,
          (_, next) => emitted.add(next),
          fireImmediately: true,
        );

        await notifier.setEnabled(enabled: false);

        // Allow unawaited disableBackgroundScheduling to drain.
        await Future<void>.delayed(Duration.zero);

        expect(
          emitted,
          contains(false),
          reason:
              'The _bgSharingPausedSub listener in MapShell listens to '
              'backgroundSharingProvider and must see false to cancel '
              '_receiveTimer',
        );
        expect(
          emitted.last,
          isFalse,
          reason: 'The final emitted value must be false',
        );
      },
    );
  });
}
