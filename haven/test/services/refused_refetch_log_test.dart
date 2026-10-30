/// The refused-object refetch's two failure log lines name the error's type
/// and nothing a relay, a peer or the engine wrote into it (Security Rule 15).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/catchup_service.dart';
import 'package:haven/src/services/nostr_relay_service.dart';

import '../helpers/log_capture.dart';
import '../mocks/mock_relay_service.dart';

const _groupHex =
    '3f9a1c7e5b2d8f4061a7c3e9b5d1f7a2c8e4b0d6f2a8c4e0b6d2f8a4c0e6b2d8';
const _relay = 'wss://relay.private-host.example';
const _npub = 'npub1qy352euf40x77qfrg4ncn27daqjckzmmaw0ahqqqqqqqqqqqqqqqqqqq';
const _needles = <String>[_groupHex, _relay, _npub];

final StateError _planted = StateError(
  'refetch of $_groupHex at $_relay for $_npub',
);

class _FakeCircleManager implements CircleManagerFfi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected: ${invocation.memberName}');
}

class _ThrowingRelayManager implements RelayManagerFfi {
  @override
  Future<CatchupResultFfi> runRefusedRefetch({
    required CircleManagerFfi circle,
    required BigInt maxDurationSecs,
  }) async => throw _planted;

  @override
  void dispose() {}

  @override
  bool get isDisposed => false;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected: ${invocation.memberName}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a refetch whose circle manager fails logs its type alone', () async {
    final logs = LogCapture.install();
    final service = CatchupService(
      relayService: MockRelayService(),
      circleManagerFactory: () async => throw _planted,
      ownPubkeyHex: () async => 'pk',
    );

    final result = await service.runRefusedRefetch();

    expect(result.eventsApplied, 0);
    logs
      ..assertContains('[Catchup] refetch failed: StateError')
      ..assertNoNeedles(_needles);
  });

  test('a refetch the FFI fails logs its type alone', () async {
    final logs = LogCapture.install();
    final relay = NostrRelayService.withInjectedManager(
      _ThrowingRelayManager(),
    );

    final result = await relay.runRefusedRefetch(circle: _FakeCircleManager());

    expect(result.eventsApplied, 0);
    logs
      ..assertContains('[Catchup] refetch failed: StateError')
      ..assertNoNeedles(_needles);
  });
}
