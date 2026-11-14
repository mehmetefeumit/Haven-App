// What a teardown that shuts the pool waits for: every driver entry this
// service has in flight (`NostrRelayService.inFlightDrives`). The core forks
// nothing if the pool goes under a drive — a commit no relay acknowledged
// stays recorded and awaiting (`haven-core/tests/fanout_change_e2e.rs`
// `a_change_no_relay_answers_for_is_awaiting_relays_never_failed`) — so the
// wait is what lets a drive finish rather than leave its sends to the next
// wake. Replaces `location_sharing_commit_critical_registry_test.dart`, whose
// registry no path wrote any more.
//
// The contract a drain-until-null reader relies on: non-null while ANY entry
// runs, one future per read covering the entries in flight — the same one
// until another entry joins — and null again on every exit, a failure
// included.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/nostr_relay_service.dart';

/// A pool whose every driver entry parks on a gate of its own.
class _Pool implements RelayManagerFfi {
  final List<Completer<void>> gates = [];

  Future<T> _park<T>(T answer) async {
    final gate = Completer<void>();
    gates.add(gate);
    await gate.future;
    return answer;
  }

  static const _change = EvolutionOutcomeFfi(
    status: PublishStatusFfi.unresolved,
    welcomesDelivered: 0,
    welcomesTotal: 0,
    reinviteOwed: false,
    replayed: [],
  );
  static const _leave = LeaveOutcomeFfi(status: LeaveStatusFfi.proposed);

  @override
  Future<EvolutionOutcomeFfi> addMembersDriven({
    required CircleManagerFfi circle,
    required List<int> mlsGroupId,
    required List<MemberKeyPackageFfi> members,
    required bool foreground,
  }) => _park(_change);

  @override
  Future<EvolutionOutcomeFfi> removeMembersDriven({
    required CircleManagerFfi circle,
    required List<int> mlsGroupId,
    required List<String> memberPubkeys,
    required bool foreground,
  }) => _park(_change);

  @override
  Future<EvolutionOutcomeFfi> updateCircleRelaysDriven({
    required CircleManagerFfi circle,
    required List<int> mlsGroupId,
    required List<String> relays,
    required bool foreground,
  }) => _park(_change);

  @override
  Future<EvolutionOutcomeFfi> adminHandoffDriven({
    required CircleManagerFfi circle,
    required List<int> mlsGroupId,
    required String successor,
    required bool foreground,
  }) => _park(_change);

  @override
  Future<EvolutionOutcomeFfi> selfDemoteDriven({
    required CircleManagerFfi circle,
    required List<int> mlsGroupId,
    required bool foreground,
  }) => _park(_change);

  @override
  Future<RepairOutcomeFfi> repairRotationDriven({
    required CircleManagerFfi circle,
    required List<int> mlsGroupId,
    required bool foreground,
  }) => _park(const RepairOutcomeFfi(kind: RepairKindFfi.rotated));

  @override
  Future<RecoveryCauseFfi?> circleRecovery({
    required CircleManagerFfi circle,
    required List<int> mlsGroupId,
    required bool foreground,
  }) => _park<RecoveryCauseFfi?>(null);

  @override
  Future<IngestOutcomeFfi> ingestDriven({
    required CircleManagerFfi circle,
    required String eventJson,
    required bool foreground,
  }) => _park(
    const IngestOutcomeFfi(
      verdict: ReceiveVerdictFfi.applied,
      replayed: [],
      errored: false,
    ),
  );

  @override
  Future<ResumeOutcomeFfi> resumeDriven({
    required CircleManagerFfi circle,
    required bool foreground,
  }) => _park(
    const ResumeOutcomeFfi(
      withdrawn: [],
      requeued: [],
      replayed: [],
      errored: false,
    ),
  );

  @override
  Future<ReinviteDrivenFfi> reinviteDriven({
    required CircleManagerFfi circle,
    required bool foreground,
  }) => _park(
    const ReinviteDrivenFfi(
      reinvites: [],
      drive: ResumeOutcomeFfi(
        withdrawn: [],
        requeued: [],
        replayed: [],
        errored: false,
      ),
    ),
  );

  @override
  Future<SealOutcomeFfi> sealLocationDriven({
    required CircleManagerFfi circle,
    required List<int> mlsGroupId,
    required LocationMessage location,
    required bool foreground,
  }) => _park(const SealOutcomeFfi(replayed: [], errored: false));

  @override
  Future<SealOutcomeFfi> sealLocationForMeshDriven({
    required CircleManagerFfi circle,
    required List<int> mlsGroupId,
    required LocationMessage location,
  }) => _park(const SealOutcomeFfi(replayed: [], errored: false));

  @override
  Future<LocationPublishFfi> publishLocationDriven({
    required CircleManagerFfi circle,
    required SealedLocationFfi sealed,
    required bool received,
  }) => _park(LocationPublishFfi.accepted);

  @override
  Future<MeshDriveFfi> meshDriveDriven({required CircleManagerFfi circle}) =>
      _park(const MeshDriveFfi(replayed: [], errored: false, more: false));

  @override
  Future<LeaveOutcomeFfi> leaveDriven({
    required CircleManagerFfi circle,
    required List<int> mlsGroupId,
    required bool foreground,
  }) => _park(_leave);

  @override
  Future<LeaveOutcomeFfi> resumeLeaveDriven({
    required CircleManagerFfi circle,
    required List<int> mlsGroupId,
    required bool foreground,
  }) => _park(_leave);

  @override
  void dispose() {}

  @override
  bool get isDisposed => false;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected call: ${invocation.memberName}');
}

class _Opaque implements CircleManagerFfi, SealedLocationFfi, LocationMessage {
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
  final o = _Opaque();
  const g = [1, 2];

  setUp(() {
    pool = _Pool();
    service = NostrRelayService(
      openPool: () async => pool,
      fixOf: (_, _) async => o,
    );
  });

  /// Whether [future] has completed, decided by a listener rather than by
  /// elapsed time. Read it only after [pumpEventQueue].
  bool Function() watch(Future<void> future) {
    var done = false;
    unawaited(future.whenComplete(() => done = true));
    return () => done;
  }

  final entries = <String, Future<Object?> Function(NostrRelayService)>{
    'addMembers': (s) => s.addMembers(
      circle: o,
      mlsGroupId: g,
      members: const [],
      foreground: true,
    ),
    'removeMembers': (s) => s.removeMembers(
      circle: o,
      mlsGroupId: g,
      memberPubkeys: const [],
      foreground: true,
    ),
    'updateCircleRelays': (s) => s.updateCircleRelays(
      circle: o,
      mlsGroupId: g,
      relays: const [],
      foreground: true,
    ),
    'adminHandoff': (s) => s.adminHandoff(
      circle: o,
      mlsGroupId: g,
      successor: 'a',
      foreground: true,
    ),
    'selfDemote': (s) =>
        s.selfDemote(circle: o, mlsGroupId: g, foreground: true),
    'repairRotation': (s) =>
        s.repairRotation(circle: o, mlsGroupId: g, foreground: true),
    // A read, but through the driver's publishing half: a teardown waits it
    // out like every entry.
    'circleRecovery': (s) =>
        s.circleRecovery(circle: o, mlsGroupId: g, foreground: true),
    'ingest': (s) => s.ingest(circle: o, eventJson: '{}', foreground: true),
    'resume': (s) => s.resume(circle: o, foreground: true),
    'reinvite': (s) => s.reinvite(circle: o, foreground: true),
    'sealLocation': (s) => s.sealLocation(
      circle: o,
      mlsGroupId: g,
      latitude: 1,
      longitude: 2,
      foreground: true,
    ),
    'sealLocationForMesh': (s) => s.sealLocationForMesh(
      circle: o,
      mlsGroupId: g,
      latitude: 1,
      longitude: 2,
    ),
    'publishLocation': (s) =>
        s.publishLocation(circle: o, sealed: o, received: false),
    'meshDrive': (s) => s.meshDrive(circle: o),
    'leave': (s) => s.leave(circle: o, mlsGroupId: g, foreground: true),
    'resumeLeave': (s) =>
        s.resumeLeave(circle: o, mlsGroupId: g, foreground: true),
  };

  const locationDrives = {'sealLocation', 'publishLocation'};
  for (final MapEntry(key: name, value: call) in entries.entries) {
    test('$name is waited for while it is in flight', () async {
      expect(service.inFlightDrives, isNull);
      final running = call(service);
      await pumpEventQueue();
      expect(service.inFlightDrives, isNotNull);
      // A location's seal and send stay inside the Android service's bounded
      // drain; every other entry is waited out past it.
      expect(
        service.inFlightNonLocationDrives,
        locationDrives.contains(name) ? isNull : isNotNull,
      );

      pool.gates.single.complete();
      await running;
      expect(service.inFlightDrives, isNull);
      expect(service.inFlightNonLocationDrives, isNull);
    });
  }

  test('is the same future on every read while a drive runs, and completes '
      'when it ends', () async {
    final running = entries['resume']!(service);
    await pumpEventQueue();
    final tracked = service.inFlightDrives!;
    final done = watch(tracked);
    await pumpEventQueue();
    expect(done(), isFalse);
    expect(
      identical(service.inFlightDrives, tracked),
      isTrue,
      reason: 'a reader drains until the read comes back null, so a future '
          'manufactured per read would never let it finish',
    );

    pool.gates.single.complete();
    await running;
    await pumpEventQueue();
    expect(done(), isTrue);
  });

  test('a drive after quiescence gets a fresh future', () async {
    final first = entries['resume']!(service);
    await pumpEventQueue();
    final firstTracked = service.inFlightDrives;
    pool.gates.single.complete();
    await first;

    final second = entries['ingest']!(service);
    await pumpEventQueue();
    expect(service.inFlightDrives, isNotNull);
    expect(identical(service.inFlightDrives, firstTracked), isFalse);
    pool.gates.last.complete();
    await second;
  });

  test('covers two drives at once, and completes only when the last does',
      () async {
    final a = entries['resume']!(service);
    final b = entries['sealLocation']!(service);
    await pumpEventQueue();
    final tracked = service.inFlightDrives!;
    final done = watch(tracked);

    pool.gates.first.complete();
    await a;
    await pumpEventQueue();
    expect(done(), isFalse);
    expect(identical(service.inFlightDrives, tracked), isTrue);

    pool.gates.last.complete();
    await b;
    await pumpEventQueue();
    expect(done(), isTrue);
    expect(service.inFlightDrives, isNull);
  });

  test('a read waits out the drives it saw, never one that joined after it',
      () async {
    // Overlapping drives once shared one completer, so a stream of them kept
    // a reader waiting with no bound: each drive's own budget capped nothing.
    final first = entries['resume']!(service);
    await pumpEventQueue();
    final done = watch(service.inFlightDrives!);
    final joined = entries['ingest']!(service);
    await pumpEventQueue();

    pool.gates.first.complete();
    await first;
    await pumpEventQueue();
    expect(done(), isTrue, reason: 'the read waited on a drive it never saw');
    expect(service.inFlightDrives, isNotNull, reason: 'one is still running');

    pool.gates.last.complete();
    await joined;
    expect(service.inFlightDrives, isNull);
  });

  test('a drive that throws still leaves it, and does not release a reader '
      'waiting on another', () async {
    final failing = entries['resume']!(service);
    final surviving = entries['ingest']!(service);
    await pumpEventQueue();
    final done = watch(service.inFlightDrives!);

    pool.gates.first.completeError(StateError('drive failed'));
    await expectLater(failing, throwsStateError);
    await pumpEventQueue();
    expect(done(), isFalse);

    pool.gates.last.complete();
    await surviving;
    await pumpEventQueue();
    expect(done(), isTrue);
    expect(service.inFlightDrives, isNull);
  });
}
