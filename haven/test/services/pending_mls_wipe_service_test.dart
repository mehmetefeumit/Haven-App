/// Tests for [PendingMlsWipeService] — the M10.1 durable pending-wipe marker.
///
/// Covers:
/// (a) marker SET before wipe is attempted
/// (b) marker CLEARED after a successful wipe
/// (c) marker PERSISTS when the wipe throws
/// (d) launch-retry with marker set → calls wipeAllMlsState → clears on success
/// (e) launch-retry with marker set → wipe throws again → marker stays set
/// (f) normal launch, marker absent → no wipe call
/// (g) marker never stores any secret/id — assert the stored value is a plain bool
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/pending_mls_wipe_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../mocks/mock_circle_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Sets up fake [SharedPreferences] with the given initial values, then
  /// constructs a [PendingMlsWipeService] with the provided [circleService].
  Future<({PendingMlsWipeService service, SharedPreferences prefs})> makeService({
    Map<String, Object> prefsValues = const {},
    CircleService? circleService,
  }) async {
    SharedPreferences.setMockInitialValues(prefsValues);
    final prefs = await SharedPreferences.getInstance();
    final service = PendingMlsWipeService(
      prefs: prefs,
      circleService: circleService ?? MockCircleService(),
    );
    return (service: service, prefs: prefs);
  }

  // ---------------------------------------------------------------------------
  // Marker access — isPending
  // ---------------------------------------------------------------------------

  group('isPending', () {
    test('returns false when key is absent', () async {
      final (:service, prefs: _) = await makeService();
      expect(service.isPending, isFalse);
    });

    test('returns false when key is explicitly false', () async {
      final (:service, prefs: _) = await makeService(
        prefsValues: {kPendingMlsWipeKey: false},
      );
      expect(service.isPending, isFalse);
    });

    test('returns true when key is true', () async {
      final (:service, prefs: _) = await makeService(
        prefsValues: {kPendingMlsWipeKey: true},
      );
      expect(service.isPending, isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // (a) setPending sets the marker to true BEFORE any wipe attempt
  // ---------------------------------------------------------------------------

  group('setPending', () {
    test('(a) writes true to SharedPreferences under kPendingMlsWipeKey',
        () async {
      final (:service, :prefs) = await makeService();

      expect(prefs.getBool(kPendingMlsWipeKey), isNull,
          reason: 'key absent before setPending');

      await service.setPending();

      expect(prefs.getBool(kPendingMlsWipeKey), isTrue,
          reason: 'marker must be true after setPending');
    });

    test('(a) isPending is true after setPending', () async {
      final (:service, prefs: _) = await makeService();
      await service.setPending();
      expect(service.isPending, isTrue);
    });

    test(
        '(g) stored value is a plain bool — not a pubkey, group-id, or secret',
        () async {
      final (:service, :prefs) = await makeService();
      await service.setPending();

      final stored = prefs.getBool(kPendingMlsWipeKey);
      // The value must be a bool and must equal true — never a String, List, etc.
      expect(stored, isA<bool>(), reason: 'must be a plain bool, not a string');
      expect(stored, isTrue);
      // Negative assertion: the key must not exist under ANY other key name that
      // could encode identifying data.  Only kPendingMlsWipeKey should be written.
      final keys = prefs.getKeys();
      expect(keys, equals({kPendingMlsWipeKey}),
          reason: 'setPending must write exactly one key with no identifying data');
    });
  });

  // ---------------------------------------------------------------------------
  // (b) clearPending clears the marker after a successful wipe
  // ---------------------------------------------------------------------------

  group('clearPending', () {
    test('(b) sets key to false in SharedPreferences', () async {
      final (:service, :prefs) = await makeService(
        prefsValues: {kPendingMlsWipeKey: true},
      );

      expect(prefs.getBool(kPendingMlsWipeKey), isTrue,
          reason: 'marker is set before clearPending');

      await service.clearPending();

      expect(prefs.getBool(kPendingMlsWipeKey), isFalse,
          reason: 'marker must be false after clearPending');
    });

    test('(b) isPending is false after clearPending', () async {
      final (:service, prefs: _) = await makeService(
        prefsValues: {kPendingMlsWipeKey: true},
      );
      await service.clearPending();
      expect(service.isPending, isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // (c) marker PERSISTS when the wipe throws (logout path via retryWipeIfPending)
  // ---------------------------------------------------------------------------

  group('retryWipeIfPending — wipe throws', () {
    test('(c)(e) marker stays set when wipeAllMlsState throws', () async {
      final throwingCircle = _ThrowingWipeMockCircleService();
      final (:service, :prefs) = await makeService(
        prefsValues: {kPendingMlsWipeKey: true},
        circleService: throwingCircle,
      );

      await service.retryWipeIfPending();

      expect(prefs.getBool(kPendingMlsWipeKey), isTrue,
          reason:
              '(c) marker must persist when the wipe throws so the next '
              'launch retries');
      expect(throwingCircle.wipeCallCount, 1,
          reason: 'wipeAllMlsState must have been attempted once');
    });
  });

  // ---------------------------------------------------------------------------
  // (d) launch-retry: marker set + wipe succeeds → clears marker
  // ---------------------------------------------------------------------------

  group('retryWipeIfPending — wipe succeeds', () {
    test('(d) calls wipeAllMlsState and clears marker on success', () async {
      final mockCircle = MockCircleService();
      final (:service, :prefs) = await makeService(
        prefsValues: {kPendingMlsWipeKey: true},
        circleService: mockCircle,
      );

      await service.retryWipeIfPending();

      expect(
        mockCircle.methodCalls,
        contains('wipeAllMlsState'),
        reason: '(d) wipeAllMlsState must be called when marker is set',
      );
      expect(prefs.getBool(kPendingMlsWipeKey), isFalse,
          reason: '(d) marker must be cleared after a successful wipe');
    });

    test('(d) isPending is false after a successful retry', () async {
      final (:service, prefs: _) = await makeService(
        prefsValues: {kPendingMlsWipeKey: true},
      );

      await service.retryWipeIfPending();

      expect(service.isPending, isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // (f) normal launch — marker absent → no wipe call
  // ---------------------------------------------------------------------------

  group('retryWipeIfPending — marker absent', () {
    test('(f) does NOT call wipeAllMlsState when marker is absent', () async {
      final mockCircle = MockCircleService();
      final (:service, prefs: _) = await makeService(
        circleService: mockCircle,
      );

      await service.retryWipeIfPending();

      expect(
        mockCircle.methodCalls,
        isNot(contains('wipeAllMlsState')),
        reason:
            '(f) no wipe must occur on a normal launch when the marker is absent',
      );
    });

    test('(f) does NOT call wipeAllMlsState when marker is explicitly false',
        () async {
      final mockCircle = MockCircleService();
      final (:service, prefs: _) = await makeService(
        prefsValues: {kPendingMlsWipeKey: false},
        circleService: mockCircle,
      );

      await service.retryWipeIfPending();

      expect(mockCircle.methodCalls, isNot(contains('wipeAllMlsState')));
    });
  });

  // ---------------------------------------------------------------------------
  // SET before / CLEAR after ordering (mirrors the deleteIdentity contract)
  // ---------------------------------------------------------------------------

  group('ordering contract', () {
    test(
        'setPending writes the marker; clearPending written only after success',
        () async {
      final mockCircle = MockCircleService();
      final (:service, :prefs) = await makeService(circleService: mockCircle);

      // (a) SET before calling wipe.
      await service.setPending();
      expect(prefs.getBool(kPendingMlsWipeKey), isTrue,
          reason: 'marker must be true before wipe attempt');

      // Simulate the wipe (mocked, always succeeds).
      await mockCircle.wipeAllMlsState();

      // (b) CLEAR only after success.
      await service.clearPending();
      expect(prefs.getBool(kPendingMlsWipeKey), isFalse,
          reason: 'marker must be false after successful wipe');
    });

    test('setPending before wipe; marker survives a simulated crash (no clear)',
        () async {
      final (:service, :prefs) = await makeService();

      // (a) SET the marker.
      await service.setPending();

      // Simulate a crash: the wipe never runs and clearPending is never called.
      // The marker must still be true (surviving across re-instantiation).

      // Re-create the service with the same prefs to simulate a relaunch.
      final service2 = PendingMlsWipeService(
        prefs: prefs,
        circleService: MockCircleService(),
      );
      expect(service2.isPending, isTrue,
          reason:
              '(c) marker must survive a crash (no clearPending call) and '
              'be visible on the next launch');
    });
  });
}

// =============================================================================
// Test helpers
// =============================================================================

/// A [CircleService] whose [wipeAllMlsState] always throws a
/// [CircleServiceException], simulating a persistent wipe failure.
///
/// Extends [MockCircleService] so all other methods are inherited.
class _ThrowingWipeMockCircleService extends MockCircleService {
  int wipeCallCount = 0;

  @override
  Future<void> wipeAllMlsState() async {
    wipeCallCount++;
    throw const CircleServiceException('simulated wipe failure');
  }
}
