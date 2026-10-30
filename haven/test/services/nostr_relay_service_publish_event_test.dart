// What `NostrRelayService.publishEvent` makes of each answer the bridge's
// `publish_event` gives, read by its typed fields only (Security Rule 8). How
// the core fills those fields is Rust's (`rust_builder` api.rs
// `a_clock_refusal_crosses_typed_and_no_other_failure_does`,
// `a_group_message_is_refused_before_any_relay_is_asked_and_nothing_else_is`).
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/nostr_relay_service.dart';
import 'package:haven/src/services/relay_service.dart';

import '../helpers/log_capture.dart';

const _groupHex =
    'cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd';
const _relay = 'wss://planted-relay.example';

/// A pool whose `publishEvent` throws [error], or answers [result].
class _Pool implements RelayManagerFfi {
  Object? error;
  PublishResultFfi? result;

  @override
  Future<PublishResultFfi> publishEvent({
    required String eventJson,
    required List<String> relays,
  }) async {
    final e = error;
    if (e != null) return Future.error(e);
    return result!;
  }

  @override
  void dispose() {}

  @override
  bool get isDisposed => false;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected call: ${invocation.memberName}');
}

void main() {
  late _Pool pool;
  late NostrRelayService service;

  setUp(() {
    pool = _Pool();
    service = NostrRelayService.withInjectedManager(pool);
  });

  Future<PublishResult> publish() => service.publishEvent(
    eventJson: '{"id":"$_groupHex"}',
    relays: const [_relay],
  );

  test("a publish no relay took for this device's clock throws its own type, "
      'in its direction', () async {
    for (final complaint in DeviceClockComplaintFfi.values) {
      pool.error = PublishFailureFfi(clockRejected: complaint);
      await expectLater(
        publish(),
        throwsA(
          isA<RelayClockRejectionException>().having(
            (e) => e.complaint,
            'complaint',
            complaint,
          ),
        ),
      );
    }
  });

  test('a refused publish, a failure that blamed no clock and any other error '
      'are the generic failure', () async {
    for (final error in <Object>[
      for (final refusal in PublishRefusalFfi.values)
        PublishFailureFfi(refused: refusal),
      const PublishFailureFfi(),
      StateError('pool gone'),
    ]) {
      pool.error = error;
      await expectLater(
        publish(),
        throwsA(isA<RelayServiceException>()),
        reason: '$error',
      );
    }
  });

  test('the clock is read from the typed field, never from the text', () async {
    pool.error = StateError('haven.clock.device_clock_rejected:ahead');
    await expectLater(publish(), throwsA(isA<RelayServiceException>()));
  });

  test('an accepted publish is reported relay by relay', () async {
    pool.result = const PublishResultFfi(
      eventId: _groupHex,
      acceptedBy: [_relay],
      rejectedBy: [
        RelayRejectionFfi(url: 'wss://b.example', reason: 'blocked: no'),
      ],
      failed: ['wss://c.example'],
      isSuccess: true,
    );

    final result = await publish();

    expect(result.eventId, _groupHex);
    expect(result.acceptedBy, [_relay]);
    expect(result.rejectedBy.single.relay, 'wss://b.example');
    expect(result.failed, ['wss://c.example']);
    expect(result.isSuccess, isTrue);
  });

  test('every failure logs fixed text and closed names, naming nothing',
      () async {
    final logs = LogCapture.install();
    for (final error in <Object>[
      const PublishFailureFfi(clockRejected: DeviceClockComplaintFfi.behind),
      const PublishFailureFfi(refused: PublishRefusalFfi.invalidRelay),
      StateError('group $_groupHex at $_relay'),
    ]) {
      pool.error = error;
      await expectLater(publish(), throwsA(isA<Exception>()));
    }

    logs
      ..assertContains('device clock behind')
      ..assertContains('refused invalidRelay')
      ..assertContains('Failed to publish event: StateError')
      ..assertNoNeedles([_groupHex, _relay]);
  });
}
