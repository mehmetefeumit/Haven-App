import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/catchup_service.dart';
import 'package:haven/src/services/relay_service.dart';

import '../mocks/mock_relay_service.dart';

/// A relay service that records `runCatchup` and returns a known result.
class _RecordingRelay extends MockRelayService {
  int calls = 0;
  String? seenPubkey;
  int? seenMaxSecs;

  @override
  Future<CatchupResult> runCatchup({
    required CircleManagerFfi circle,
    required String ownPubkeyHex,
    int maxDurationSecs = 20,
  }) async {
    calls++;
    seenPubkey = ownPubkeyHex;
    seenMaxSecs = maxDurationSecs;
    return const CatchupResult(eventsApplied: 3, cursorsAdvanced: 1);
  }
}

/// A fake circle-manager FFI handle (never invoked by the fake relay).
class _FakeCircleManager implements CircleManagerFfi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected: ${invocation.memberName}');
}

void main() {
  group('CatchupService', () {
    test(
      'forwards to relay.runCatchup with the own pubkey + duration',
      () async {
        final relay = _RecordingRelay();
        final service = CatchupService(
          relayService: relay,
          circleManagerFactory: () async => _FakeCircleManager(),
          ownPubkeyHex: () async => 'deadbeef_pubkey',
        );

        final result = await service.runCatchup(maxDurationSecs: 15);

        expect(relay.calls, 1);
        expect(relay.seenPubkey, 'deadbeef_pubkey');
        expect(relay.seenMaxSecs, 15);
        expect(result.eventsApplied, 3);
        expect(result.cursorsAdvanced, 1);
      },
    );

    test('no-ops (no relay call) when there is no identity', () async {
      final relay = _RecordingRelay();
      final service = CatchupService(
        relayService: relay,
        circleManagerFactory: () async => _FakeCircleManager(),
        ownPubkeyHex: () async => null,
      );

      final result = await service.runCatchup();

      expect(relay.calls, 0, reason: 'no sweep without an identity');
      expect(result.eventsApplied, 0);
    });

    test('returns empty (never throws) when a dependency throws', () async {
      final relay = _RecordingRelay();
      final service = CatchupService(
        relayService: relay,
        circleManagerFactory: () async =>
            throw StateError('manager unavailable'),
        ownPubkeyHex: () async => 'pk',
      );

      final result = await service.runCatchup();

      expect(result.eventsApplied, 0);
      expect(relay.calls, 0);
    });
  });
}
