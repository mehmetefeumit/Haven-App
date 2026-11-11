// `NostrMeshService`: the Bluetooth mesh's entries over the bridge
// (`docs/BLUETOOTH_MESH_PLAN.md` §5.2, §7.5, §7.6). Run against a recording
// bridge and a fake driver: what is pinned here is what the service adds —
// the engine's resume once a session, the bounded drive, and that nothing a
// failed entry threw gets out.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/mesh_service.dart';

import '../helpers/fake_change_driver.dart';
import '../helpers/fake_mesh.dart';
import '../helpers/log_capture.dart';

LocationMessageResultFfi _location(int group, String sender) =>
    LocationMessageResultFfi(
      kind: LocationMessageResultKindFfi.location,
      location: DecryptedLocationFfi(
        senderPubkey: sender,
        latitude: 51.5,
        longitude: -0.1,
        geohash: 'gcpvj',
        timestamp: 1700000000,
        expiresAt: 1700000900,
      ),
      mlsGroupId: Uint8List.fromList([group]),
      epoch: BigInt.from(3),
    );

void main() {
  late RecordingMeshBridge bridge;
  late FakeChangeDriver driver;
  late CircleManagerFfi session;
  late NostrMeshService service;

  setUp(() {
    bridge = RecordingMeshBridge();
    driver = FakeChangeDriver();
    session = FakeMeshSession();
    service = NostrMeshService(
      circleManager: () async => session,
      driver: driver,
      bridge: bridge,
    );
  });

  group('the engine of a mesh left on', () {
    test(
      'is resumed before the first entry of a session, and once for it',
      () async {
        await service.stats();
        await service.start();
        await service.drive();
        await service.sharingStopped();

        expect(bridge.calls, ['resume', 'stats', 'start', 'sharingStopped']);
        expect(driver.calls, ['meshDrive']);
        expect(bridge.sessions.toSet(), {session});
      },
    );

    test('is resumed again for a session opened since', () async {
      await service.stats();
      final reopened = session = FakeMeshSession();
      await service.stats();
      await service.stats();

      expect(bridge.calls, ['resume', 'stats', 'resume', 'stats', 'stats']);
      expect(bridge.sessions.sublist(2), [reopened, reopened, reopened]);
    });

    test('is resumed once by entries that race for a session', () async {
      await Future.wait([service.stats(), service.stats(), service.drive()]);

      expect(bridge.calls.where((c) => c == 'resume'), hasLength(1));
      expect(bridge.calls.first, 'resume');
    });

    test('whose resume failed is asked for again by the next entry, which '
        'is then made', () async {
      bridge.throws['resume'] = StateError('boom');
      await expectLater(service.stop(), throwsA(isA<MeshServiceException>()));
      bridge.throws.clear();

      await service.stop();

      expect(bridge.calls, ['resume', 'resume', 'stop']);
    });

    test('is not asked for before a session exists', () async {
      final unopened = NostrMeshService(
        circleManager: () async => throw StateError('no session'),
        driver: driver,
        bridge: bridge,
      );

      await expectLater(unopened.stats(), throwsA(isA<MeshServiceException>()));
      expect(bridge.calls, isEmpty);
      expect(driver.calls, isEmpty);
    });
  });

  group('each entry is the bridge entry of its name', () {
    test(
      'start, keep-on and the state answer what the bridge answered',
      () async {
        bridge
          ..startAnswer = MeshStartFfi.alreadyOn
          ..keepOnAnswer = MeshStartFfi.off
          ..statsAnswer = meshState(on: true, linked: true, onForMs: 42);

        expect(await service.start(), MeshStartFfi.alreadyOn);
        expect(await service.keepOn(), MeshStartFfi.off);
        expect(await service.stats(), same(bridge.statsAnswer));
        await service.stop();
        await service.resetCounts();

        expect(bridge.calls, [
          'resume',
          'start',
          'keepOn',
          'stats',
          'stop',
          'resetCounts',
        ]);
      },
    );
  });

  group('a drive', () {
    test(
      'asks once when nothing waits, and hands back what was read',
      () async {
        driver.meshDrives = [
          MeshDriveFfi(
            replayed: [_location(1, 'aa' * 32), _location(2, 'bb' * 32)],
            errored: false,
            more: false,
          ),
        ];

        final replayed = await service.drive();

        expect(driver.calls, ['meshDrive']);
        expect(driver.managers, [session]);
        expect(replayed.map((r) => r.mlsGroupId), [
          [1],
          [2],
        ]);
        expect(replayed.map((r) => r.kind).toSet(), {
          LocationEventKind.location,
        });
        expect(replayed.first.location!.senderPubkey, 'aa' * 32);
        expect(replayed.first.epoch, 3);
      },
    );

    test('asks again while packets wait, and keeps every round', () async {
      driver.meshDrives = [
        MeshDriveFfi(
          replayed: [_location(1, 'aa' * 32)],
          errored: true,
          more: true,
        ),
        MeshDriveFfi(
          replayed: [_location(2, 'bb' * 32)],
          errored: false,
          more: false,
        ),
      ];

      final replayed = await service.drive();

      expect(driver.calls, ['meshDrive', 'meshDrive']);
      expect(replayed, hasLength(2));
    });

    test('stops at its bound however much still waits', () async {
      driver.meshDrives = List.generate(
        kMeshDriveRounds * 3,
        (_) => const MeshDriveFfi(replayed: [], errored: false, more: true),
      );

      await service.drive();

      expect(driver.calls, List.filled(kMeshDriveRounds, 'meshDrive'));
    });
  });

  group('an entry that could not be made', () {
    test('throws fixed text, and nothing of what the bridge threw is shown '
        'or logged', () async {
      final logs = LogCapture.install();
      const planted = 'group 0xdeadbeefcafe at wss://relay.planted.example';
      bridge.throws['stats'] = StateError(planted);
      driver.throws = StateError(planted);

      Object? fromStats;
      Object? fromDrive;
      try {
        await service.stats();
      } on Object catch (e) {
        fromStats = e;
      }
      try {
        await service.drive();
      } on Object catch (e) {
        fromDrive = e;
      }

      for (final thrown in [fromStats, fromDrive]) {
        expect(thrown, isA<MeshServiceException>());
        expect('$thrown', isNot(contains('deadbeef')));
        expect('$thrown', isNot(contains('planted')));
      }
      expect('$fromStats', 'MeshServiceException: Failed to read mesh');
      expect(logs.lines, isEmpty, reason: 'the mesh service logs nothing');
    });
  });
}
