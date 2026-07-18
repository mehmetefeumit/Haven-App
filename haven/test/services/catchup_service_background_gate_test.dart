/// M7-A tests for the CatchupService background-wake chokepoint (C3).
///
/// Tests verify:
///
/// (c) `runCatchup(isBackgroundWake: true)` hard-returns empty when
///     `isBackgroundSharingEnabled()` is false — the injected relay service
///     must NOT be called (no relay/FFI activity after opt-out).
/// (d) `runCatchup(isBackgroundWake: false)` (foreground) runs even when
///     background sharing is off — turning off background sharing must NOT
///     silence an open, foreground app.
/// (bonus) The chokepoint also hard-returns empty when the
///     isBackgroundSharingEnabled check itself throws (fail-safe: treat
///     unknown as disabled rather than accidentally enabling background
///     relay activity).
/// (bonus) `isBackgroundWake: true` + sharing enabled → relay IS called
///     (the gate should not block when the user has opted in).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/catchup_service.dart';
import 'package:haven/src/services/relay_service.dart';

import '../mocks/mock_relay_service.dart';

// ---------------------------------------------------------------------------
// Helpers shared by this file
// ---------------------------------------------------------------------------

/// A [MockRelayService] subclass that records how many times [runCatchup] is
/// called so tests can assert it was (or was not) reached.
class _CountingRelay extends MockRelayService {
  int calls = 0;

  @override
  Future<CatchupResult> runCatchup({
    required CircleManagerFfi circle,
    required String ownPubkeyHex,
    int maxDurationSecs = 20,
  }) async {
    calls++;
    return const CatchupResult(eventsApplied: 2, cursorsAdvanced: 1);
  }
}

/// A fake [CircleManagerFfi] that is never expected to be invoked.
class _FakeCircleManager implements CircleManagerFfi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected: ${invocation.memberName}');
}

// ---------------------------------------------------------------------------
// Factory helpers
// ---------------------------------------------------------------------------

/// Creates a [CatchupService] with injected fakes and a configurable
/// `isBackgroundSharingEnabled` return value.
CatchupService _makeService({
  required _CountingRelay relay,
  required bool sharingEnabled,
}) {
  return CatchupService(
    relayService: relay,
    circleManagerFactory: () async => _FakeCircleManager(),
    ownPubkeyHex: () async => 'test_pubkey_hex',
    isBackgroundSharingEnabled: () async => sharingEnabled,
  );
}

/// Creates a [CatchupService] whose `isBackgroundSharingEnabled` throws.
CatchupService _makeServiceWithThrowingCheck(_CountingRelay relay) {
  return CatchupService(
    relayService: relay,
    circleManagerFactory: () async => _FakeCircleManager(),
    ownPubkeyHex: () async => 'test_pubkey_hex',
    isBackgroundSharingEnabled: () async =>
        throw StateError('prefs unavailable'),
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('CatchupService — background-wake chokepoint (C3, M7-A)', () {
    // -----------------------------------------------------------------------
    // (c) Background wake + sharing DISABLED → relay NOT called
    // -----------------------------------------------------------------------
    test('(c) isBackgroundWake:true + sharing disabled → returns empty, '
        'relay.runCatchup NOT called', () async {
      final relay = _CountingRelay();
      final service = _makeService(relay: relay, sharingEnabled: false);

      final result = await service.runCatchup(isBackgroundWake: true);

      expect(
        relay.calls,
        0,
        reason:
            'The relay must NOT be contacted when background sharing is off '
            'and this is a background wake — this is the C3 privacy chokepoint',
      );
      expect(
        result.eventsApplied,
        0,
        reason: 'Must return an empty result when gated',
      );
      expect(result.cursorsAdvanced, 0);
    });

    // -----------------------------------------------------------------------
    // (d) Foreground call + sharing DISABLED → relay IS called
    // -----------------------------------------------------------------------
    test('(d) isBackgroundWake:false (foreground) + sharing disabled → '
        'relay.runCatchup IS called (foreground receive not gated)', () async {
      final relay = _CountingRelay();
      final service = _makeService(relay: relay, sharingEnabled: false);

      // Default isBackgroundWake is false.
      final result = await service.runCatchup();

      expect(
        relay.calls,
        1,
        reason:
            'A user who turns off BACKGROUND sharing must still receive '
            'peer updates while the app is OPEN. The background-sharing toggle '
            "controls only what the OS does on the user's behalf when the "
            'app is not in use.',
      );
      expect(result.eventsApplied, 2);
    });

    // -----------------------------------------------------------------------
    // Background wake + sharing ENABLED → relay IS called (gate is open)
    // -----------------------------------------------------------------------
    test(
      'isBackgroundWake:true + sharing enabled → relay.runCatchup IS called',
      () async {
        final relay = _CountingRelay();
        final service = _makeService(relay: relay, sharingEnabled: true);

        final result = await service.runCatchup(isBackgroundWake: true);

        expect(
          relay.calls,
          1,
          reason: 'The chokepoint must not block when the user has opted in',
        );
        expect(result.eventsApplied, 2);
      },
    );

    // -----------------------------------------------------------------------
    // Background wake + isBackgroundSharingEnabled throws → returns empty
    // (fail-safe: treat unknown as disabled)
    // -----------------------------------------------------------------------
    test('isBackgroundWake:true + isBackgroundSharingEnabled throws → '
        'returns empty, relay NOT called (fail-safe)', () async {
      final relay = _CountingRelay();
      final service = _makeServiceWithThrowingCheck(relay);

      final result = await service.runCatchup(isBackgroundWake: true);

      expect(
        relay.calls,
        0,
        reason:
            'If the sharing-enabled check throws, the chokepoint must '
            'fail SAFE (treat as disabled) so a corrupt SharedPreferences '
            'cannot accidentally enable background relay activity after '
            'an opt-out.',
      );
      expect(result.eventsApplied, 0);
    });

    // -----------------------------------------------------------------------
    // Foreground call + isBackgroundSharingEnabled throws → relay IS called
    // (the check is only performed for background wakes)
    // -----------------------------------------------------------------------
    test('isBackgroundWake:false + isBackgroundSharingEnabled throws → '
        'relay IS called (check is bypassed for foreground)', () async {
      final relay = _CountingRelay();
      final service = _makeServiceWithThrowingCheck(relay);

      // The isBackgroundSharingEnabled fn throws, but because
      // isBackgroundWake defaults to false we never call it — the
      // foreground path proceeds normally.
      final result = await service.runCatchup();

      expect(
        relay.calls,
        1,
        reason:
            'The background-sharing check must NOT be performed for '
            'foreground callers regardless of what the check would return',
      );
      expect(result.eventsApplied, 2);
    });
  });
}
