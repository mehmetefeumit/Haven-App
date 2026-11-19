// The three driver entries the Bluetooth mesh added to `NostrRelayService`
// (`docs/BLUETOOTH_MESH_PLAN.md` §5.2, §5.5, §7.7 R1): the caller's word on
// its receive reaches the bridge as it was given, a seal for the mesh alone
// takes the bridge's mesh-only seal and no other, and a mesh drive is the
// bridge's mesh drive. That each is waited for by a teardown like every
// driver entry is `nostr_relay_service_drive_registry_test.dart`'s.
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/nostr_relay_service.dart';

/// A pool that records which driven entry was made, and with what.
class _Pool implements RelayManagerFfi {
  final List<String> calls = [];
  final List<bool> received = [];
  bool sealThrows = false;

  @override
  Future<SealOutcomeFfi> sealLocationForMeshDriven({
    required CircleManagerFfi circle,
    required List<int> mlsGroupId,
    required LocationMessage location,
  }) async {
    calls.add('sealLocationForMeshDriven');
    if (sealThrows) throw StateError('seal failed');
    return const SealOutcomeFfi(
      replayed: [],
      errored: false,
      // A mesh-only seal asks no relay; a complaint here would be one the
      // service must not act on.
      clockRejected: DeviceClockComplaintFfi.ahead,
    );
  }

  @override
  Future<LocationPublishFfi> publishLocationDriven({
    required CircleManagerFfi circle,
    required SealedLocationFfi sealed,
    required bool received,
  }) async {
    calls.add('publishLocationDriven');
    this.received.add(received);
    return LocationPublishFfi.accepted;
  }

  @override
  Future<MeshDriveFfi> meshDriveDriven({
    required CircleManagerFfi circle,
  }) async {
    calls.add('meshDriveDriven');
    return const MeshDriveFfi(replayed: [], errored: true, more: true);
  }

  @override
  void dispose() {}

  @override
  bool get isDisposed => false;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected call: ${invocation.memberName}');
}

class _Opaque implements CircleManagerFfi, SealedLocationFfi {
  @override
  void dispose() {}

  @override
  bool get isDisposed => false;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected call: ${invocation.memberName}');
}

/// A fix that records its disposal.
class _Fix implements LocationMessage {
  int disposed = 0;

  @override
  void dispose() => disposed++;

  @override
  bool get isDisposed => disposed > 0;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected call: ${invocation.memberName}');
}

void main() {
  late _Pool pool;
  late _Fix fix;
  late List<DeviceClockComplaintFfi> heard;
  late NostrRelayService service;
  final o = _Opaque();

  setUp(() {
    pool = _Pool();
    fix = _Fix();
    heard = [];
    service = NostrRelayService(
      openPool: () async => pool,
      fixOf: (_, _) async => fix,
      onClockRejected: heard.add,
    );
  });

  test(
    "a send carries its caller's word on the receive, as it was given",
    () async {
      await service.publishLocation(circle: o, sealed: o, received: false);
      await service.publishLocation(circle: o, sealed: o, received: true);
      await service.publishLocation(circle: o, sealed: o, received: false);

      expect(pool.received, [false, true, false]);
    },
  );

  test('a seal for the mesh alone takes the mesh-only seal and no other, '
      'and hears no clock evidence', () async {
    final outcome = await service.sealLocationForMesh(
      circle: o,
      mlsGroupId: const [1],
      latitude: 1,
      longitude: 2,
    );

    expect(pool.calls, ['sealLocationForMeshDriven']);
    expect(outcome.sealed, isNull);
    expect(heard, isEmpty, reason: 'no relay was asked');
    expect(fix.disposed, 1);
  });

  test('the fix of a mesh-only seal that failed is still released', () async {
    pool.sealThrows = true;

    await expectLater(
      service.sealLocationForMesh(
        circle: o,
        mlsGroupId: const [1],
        latitude: 1,
        longitude: 2,
      ),
      throwsStateError,
    );
    expect(fix.disposed, 1);
  });

  test(
    "a mesh drive is the bridge's, answered as the bridge answered it",
    () async {
      final drive = await service.meshDrive(circle: o);

      expect(pool.calls, ['meshDriveDriven']);
      expect(drive.more, isTrue);
      expect(drive.errored, isTrue);
    },
  );
}
