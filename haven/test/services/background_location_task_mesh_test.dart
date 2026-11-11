// The Android foreground service's cycle and the Bluetooth mesh
// (`docs/BLUETOOTH_MESH_PLAN.md` §5.2, §5.5).
//
// The cycle publishes, THEN fetches. So:
//
//  * every send says "not received" — no relay receive of the circle has
//    completed in the cycle that sends, and a fellow member's mesh update
//    passed on behind such a send could reach a member removed by a commit
//    this cycle has yet to fetch;
//  * the mesh is driven behind the cycle's relay fetch, and what it read is
//    filed where a drive's replay is;
//  * a build without the mesh calls no mesh entry, and the cycle's relay work
//    is the same whatever the mesh does.
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/mesh_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_mesh.dart';
import '../helpers/log_capture.dart';
import '../mocks/background_task_fakes.dart';

LocationEventResult _fixIn(List<int> mlsGroupId) => LocationEventResult(
  kind: LocationEventKind.location,
  mlsGroupId: mlsGroupId,
  epoch: 4,
  location: DecryptedLocation(
    senderPubkey: 'cc' * 32,
    latitude: 48.8566,
    longitude: 2.3522,
    geohash: 'u09tvw',
    timestamp: DateTime.utc(2026, 11, 11, 12),
    expiresAt: DateTime.utc(2026, 11, 11, 12, 15),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(
    () =>
        SharedPreferences.setMockInitialValues(backgroundOwnsPublishingPrefs()),
  );

  test('every send says "not received": the cycle publishes before it '
      'fetches', () async {
    for (final mesh in [null, FakeMeshService()]) {
      final harness = await BackgroundTaskHarness.start(
        circles: [circleFixture(seed: 1), circleFixture(seed: 2)],
        mesh: mesh,
        meshBuild: mesh != null,
      );
      var fetchedBeforeAPublish = 0;
      harness.relay.onPublish = (_) {
        fetchedBeforeAPublish += harness.sharing.fetched.length;
      };

      await harness.tick(DateTime.now());

      expect(harness.relay.publishReceived, [false, false]);
      expect(
        fetchedBeforeAPublish,
        0,
        reason: 'premise: no fetch precedes a send in this cycle',
      );
      expect(harness.sharing.fetched, hasLength(2), reason: 'premise');
    }
  });

  test('the mesh is driven once, behind the relay fetch, and what it read is '
      'filed under its own circle', () async {
    final one = circleFixture(seed: 1);
    final two = circleFixture(seed: 2);
    final mesh = FakeMeshService()
      ..driveAnswer = [_fixIn(two.circle.mlsGroupId)];
    final harness = await BackgroundTaskHarness.start(
      circles: [one, two],
      mesh: mesh,
      meshBuild: true,
    );
    int? fetchedBeforeTheDrive;
    int? publishedBeforeTheDrive;
    mesh.onDrive = () {
      fetchedBeforeTheDrive = harness.sharing.fetched.length;
      publishedBeforeTheDrive = harness.relay.published.length;
    };

    await harness.tick(DateTime.now());

    expect(mesh.calls, ['drive']);
    expect(publishedBeforeTheDrive, 2);
    expect(fetchedBeforeTheDrive, 2);
    final filed = harness.sharing.ingested.single;
    expect(hexOf(filed.circle.nostrGroupId), hexOf(two.circle.nostrGroupId));
    expect(filed.decrypted.senderPubkey, 'cc' * 32);
  });

  test('a build without the mesh calls no mesh entry', () async {
    final mesh = FakeMeshService();
    final harness = await BackgroundTaskHarness.start(
      circles: [circleFixture(seed: 1)],
      mesh: mesh,
    );

    await harness.tick(DateTime.now());

    expect(harness.sharing.fetched, hasLength(1), reason: 'premise');
    expect(mesh.calls, isEmpty);
  });

  test("the cycle's relay work is the same with the mesh absent, on and "
      'failing, and a drive that failed is logged nowhere', () async {
    final logs = LogCapture.install();
    final circles = [circleFixture(seed: 1), circleFixture(seed: 2)];
    final meshes = <String, MeshService? Function()>{
      'absent': () => null,
      'on': FakeMeshService.new,
      'failing': () => FakeMeshService()
        ..throws['drive'] = StateError('group 0xdeadbeefcafe at wss://x.test'),
    };
    final seen = <String, String>{};
    for (final MapEntry(key: name, value: build) in meshes.entries) {
      final mesh = build();
      final harness = await BackgroundTaskHarness.start(
        circles: circles,
        mesh: mesh,
        meshBuild: mesh != null,
      );

      await harness.tick(DateTime.now());

      seen[name] = [
        harness.relay.published.map((p) => p.eventJson).toList()..sort(),
        harness.relay.publishReceived,
        harness.manager.acks.length,
        harness.sharing.fetched.map((c) => hexOf(c.nostrGroupId)).toList(),
        harness.relay.shutdownCalls,
      ].toString();
    }

    expect(seen['on'], seen['absent']);
    expect(seen['failing'], seen['absent']);
    expect(logs.joined, isNot(contains('deadbeef')));
    expect(logs.joined.toLowerCase(), isNot(contains('mesh')));
  });

  test('a cycle whose fetch is not due drives no mesh', () async {
    final circle = circleFixture(seed: 1);
    final mesh = FakeMeshService();
    final harness = await BackgroundTaskHarness.start(
      circles: [circle],
      mesh: mesh,
      meshBuild: true,
    );
    final base = DateTime.now();
    await harness.tick(base);
    expect(mesh.calls, ['drive'], reason: 'premise');

    harness.handler.dueTrackerForTest.markBurstPublished([
      scheduleKeyOf(circle),
    ], DateTime.now());
    await harness.tick(base.add(const Duration(seconds: 60)));

    expect(harness.sharing.fetched, hasLength(1), reason: 'premise');
    expect(mesh.calls, ['drive']);
  });

  test('a stop that lands during the fetch drives no mesh', () async {
    final mesh = FakeMeshService();
    final harness = await BackgroundTaskHarness.start(
      circles: [circleFixture(seed: 1)],
      mesh: mesh,
      meshBuild: true,
    );
    Future<void>? teardown;
    harness.sharing.onFetch = (_) {
      teardown ??= harness.handler.onDestroy(DateTime.now(), false);
    };

    await harness.tick(DateTime.now());
    await teardown;

    expect(mesh.calls, isEmpty);
  });
}
