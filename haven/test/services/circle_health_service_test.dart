/// The receipt a peer's location leaves is told to the isolate that shows the
/// verdict, once it is in the store that verdict reads.
///
/// Without the signal a "not receiving" verdict outlives the delivery that
/// disproves it until the model's next tick. The signal must follow the
/// write: a verdict re-derived before the receipt is stored reads the old
/// one, and nothing would derive it again.
library;

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show PlatformInt64;
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/circle_health_service.dart';

final _at = DateTime.utc(2026, 8, 28, 12);

/// A circle manager that records the receipts stored, in order with [log].
class _Manager implements CircleManagerFfi {
  _Manager(this.log);

  final List<String> log;

  /// When set, the next receipt write throws it.
  Object? error;

  @override
  Future<void> notePeerEvent({
    required List<int> nostrGroupId,
    required PlatformInt64 atMs,
  }) async {
    // A real write completes on a later turn of the event loop.
    await Future<void>.value();
    final failure = error;
    if (failure != null) Error.throwWithStackTrace(failure, StackTrace.current);
    log.add('stored');
  }

  @override
  Future<void> notePublishAcked({
    required List<int> nostrGroupId,
    required PlatformInt64 atMs,
  }) async => log.add('acked');

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected call: ${invocation.memberName}');
}

void main() {
  late List<String> log;
  late _Manager manager;
  late NostrCircleHealthService service;

  setUp(() {
    log = [];
    manager = _Manager(log);
    service = NostrCircleHealthService(
      circleManagerFactory: () async => manager,
      onPeerEvent: () => log.add('told'),
    );
  });

  test('a stored receipt is told, after it is stored', () async {
    await service.notePeerEvent(nostrGroupId: const [9, 9], at: _at);
    expect(log, ['stored', 'told']);
  });

  test('a receipt that was not stored is not told', () async {
    // Nothing new is in the store, so there is nothing to re-derive from.
    manager.error = StateError('store did not answer');
    await service.notePeerEvent(nostrGroupId: const [9, 9], at: _at);
    expect(log, isEmpty);
  });

  test('a publish ack is not a receipt', () async {
    // The publish sites tell the model themselves, with the verdict.
    await service.notePublishAcked(nostrGroupId: const [9, 9], at: _at);
    expect(log, ['acked']);
  });

  test('a service given no listener stores the receipt all the same', () async {
    // The foreground service's isolate shows no verdict and passes none.
    final silent = NostrCircleHealthService(
      circleManagerFactory: () async => manager,
    );
    await silent.notePeerEvent(nostrGroupId: const [9, 9], at: _at);
    expect(log, ['stored']);
  });
}
