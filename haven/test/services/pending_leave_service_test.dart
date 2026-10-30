/// Tests for [PendingLeaveService] — the retired leave markers.
///
/// Nothing writes a marker any more: the leave's intent lives in the core,
/// written first and carried on by the leaver backstop
/// (`leaver_backstop_test.dart`). What is left to promise:
/// - a marker an older build left on disk is migrated once — its circle, if
///   still present, is left through the driver (which writes the core's
///   intent), and the key is removed;
/// - a circle already gone needs nothing, and a leave that cannot be asked for
///   keeps the key for the next start-up;
/// - `clearAll` removes the key entirely (logout and the storage reset).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/services/pending_leave_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/log_capture.dart';
import '../mocks/mock_circle_service.dart';

bool _inFront() => true;

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<({PendingLeaveService service, SharedPreferences prefs})> makeService(
    List<List<int>> markers,
  ) async {
    SharedPreferences.setMockInitialValues({
      if (markers.isNotEmpty)
        kPendingLeaveKey: [for (final m in markers) _hex(m)],
    });
    final prefs = await SharedPreferences.getInstance();
    return (service: PendingLeaveService(prefs: prefs), prefs: prefs);
  }

  final present = TestCircleFactory.createCircle(
    mlsGroupId: const [10, 20, 30, 40],
    nostrGroupId: const [50, 60, 70, 80],
  );
  final other = TestCircleFactory.createCircle(
    mlsGroupId: const [11, 21, 31, 41],
    nostrGroupId: const [51, 61, 71, 81],
  );

  test('a marker an older build left is moved onto the core once: its circle '
      'is left through the driver and the key is removed', () async {
    final mock = MockCircleService(circles: [present, other]);
    final (:service, :prefs) = await makeService([present.nostrGroupId]);

    await service.migrateToCore(circleService: mock, inFront: _inFront);

    expect(
      mock.leaveCircleCalledWith,
      [present.mlsGroupId],
      reason: 'the marked circle, and only it, has its leave asked for again',
    );
    expect(prefs.containsKey(kPendingLeaveKey), isFalse);

    await service.migrateToCore(circleService: mock, inFront: _inFront);
    expect(mock.leaveCircleCalledWith, hasLength(1), reason: 'once only');
  });

  test('a migration stops where the app left the front, and keeps the key',
      () async {
    final mock = MockCircleService(circles: [present, other]);
    final (:service, :prefs) = await makeService([
      present.nostrGroupId,
      other.nostrGroupId,
    ]);
    var reads = 0;

    await service.migrateToCore(
      circleService: mock,
      inFront: () => ++reads < 2,
    );

    expect(mock.leaveCircleCalledWith, [present.mlsGroupId]);
    expect(prefs.containsKey(kPendingLeaveKey), isTrue);
  });

  test('a marker whose circle is gone asks nothing and is removed', () async {
    final mock = MockCircleService(circles: [other]);
    final (:service, :prefs) = await makeService([present.nostrGroupId]);

    await service.migrateToCore(circleService: mock, inFront: _inFront);

    expect(mock.leaveCircleCalledWith, isEmpty);
    expect(prefs.containsKey(kPendingLeaveKey), isFalse);
  });

  test('a leave that cannot be asked for keeps the marker for the next '
      'start-up, and its log line names no circle', () async {
    final capture = LogCapture.install();
    final mock = MockCircleService(
      circles: [present],
      errorMessage: 'circle ${_hex(present.mlsGroupId)} at wss://x.example',
    )..shouldThrowOnLeaveCircle = true;
    final (:service, :prefs) = await makeService([present.nostrGroupId]);

    await service.migrateToCore(circleService: mock, inFront: _inFront);

    expect(prefs.getStringList(kPendingLeaveKey), [
      _hex(present.nostrGroupId),
    ]);
    expect(capture.joined, contains('[PendingLeave] migration failed'));
    capture.assertNoNeedles([
      _hex(present.mlsGroupId),
      _hex(present.nostrGroupId),
      'wss://x.example',
    ]);
  });

  test('a roster that cannot be read keeps the marker, and its log line names '
      'no circle', () async {
    final capture = LogCapture.install();
    final mock = MockCircleService(
      circles: [present],
      shouldThrowOnGetCircles: true,
      errorMessage: 'circle ${_hex(present.mlsGroupId)} at wss://x.example',
    );
    final (:service, :prefs) = await makeService([present.nostrGroupId]);

    await service.migrateToCore(circleService: mock, inFront: _inFront);

    expect(prefs.getStringList(kPendingLeaveKey), [
      _hex(present.nostrGroupId),
    ]);
    capture
      ..assertContains('[PendingLeave] migration: could not list circles')
      ..assertNoNeedles([_hex(present.mlsGroupId), 'wss://x.example']);
  });

  test('a marker that cannot be removed says so with its type alone',
      () async {
    final capture = LogCapture.install();
    final (service: _, :prefs) = await makeService([present.nostrGroupId]);
    final service = PendingLeaveService(prefs: _RemoveThrows(prefs));

    await service.migrateToCore(
      circleService: MockCircleService(),
      inFront: _inFront,
    );

    capture
      ..assertContains('[PendingLeave] migration: marker not removed')
      ..assertNoNeedles([
        _hex(present.nostrGroupId),
        _RemoveThrows.planted,
        'wss://x.example',
      ]);
  });

  test('no marker: the migration touches nothing', () async {
    final mock = MockCircleService(circles: [present]);
    final (:service, prefs: _) = await makeService(const []);

    await service.migrateToCore(circleService: mock, inFront: _inFront);

    expect(mock.methodCalls, isEmpty);
  });

  test('clearAll removes the key entirely', () async {
    final (:service, :prefs) = await makeService([present.nostrGroupId]);

    await service.clearAll();

    expect(prefs.containsKey(kPendingLeaveKey), isFalse);
  });
}

/// Preferences whose removal fails with identifiers in its error.
class _RemoveThrows implements SharedPreferences {
  _RemoveThrows(this._inner);

  final SharedPreferences _inner;

  static const planted = 'key 3c3c3c3c at wss://x.example';

  @override
  List<String>? getStringList(String key) => _inner.getStringList(key);

  @override
  Future<bool> remove(String key) async => throw StateError(planted);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected call: ${invocation.memberName}');
}
