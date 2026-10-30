// Every driver entry hands what its drives' relays blamed on this device's
// clock to the clock check, by variant. That the core reports it only when no
// relay accepted, and how each outcome carries it across the bridge, is
// Rust's (`rust_builder` api.rs
// `a_seal_and_a_leave_carry_their_drives_clock_evidence`,
// `a_change_an_ingest_and_a_drive_carry_their_drives_clock_evidence`).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/clock_skew_detector.dart';
import 'package:haven/src/services/nostr_relay_service.dart';

import '../helpers/log_capture.dart';

/// A pool whose every driver entry answers with [clock].
class _Pool implements RelayManagerFfi {
  DeviceClockComplaintFfi? clock;
  bool sealThrows = false;

  PublishStatusFfi status = PublishStatusFfi.unresolved;
  bool? alreadySo;

  EvolutionOutcomeFfi get _change => EvolutionOutcomeFfi(
    status: status,
    alreadySo: alreadySo,
    welcomesDelivered: 0,
    welcomesTotal: 0,
    reinviteOwed: false,
    replayed: const [],
    clockRejected: clock,
  );

  LeaveOutcomeFfi get _leave =>
      LeaveOutcomeFfi(status: LeaveStatusFfi.proposed, clockRejected: clock);

  @override
  Future<EvolutionOutcomeFfi> addMembersDriven({
    required CircleManagerFfi circle,
    required List<int> mlsGroupId,
    required List<MemberKeyPackageFfi> members,
    required bool foreground,
  }) async => _change;

  @override
  Future<EvolutionOutcomeFfi> removeMembersDriven({
    required CircleManagerFfi circle,
    required List<int> mlsGroupId,
    required List<String> memberPubkeys,
    required bool foreground,
  }) async => _change;

  @override
  Future<EvolutionOutcomeFfi> updateCircleRelaysDriven({
    required CircleManagerFfi circle,
    required List<int> mlsGroupId,
    required List<String> relays,
    required bool foreground,
  }) async => _change;

  @override
  Future<EvolutionOutcomeFfi> adminHandoffDriven({
    required CircleManagerFfi circle,
    required List<int> mlsGroupId,
    required String successor,
    required bool foreground,
  }) async => _change;

  @override
  Future<EvolutionOutcomeFfi> selfDemoteDriven({
    required CircleManagerFfi circle,
    required List<int> mlsGroupId,
    required bool foreground,
  }) async => _change;

  @override
  Future<RepairOutcomeFfi> repairRotationDriven({
    required CircleManagerFfi circle,
    required List<int> mlsGroupId,
    required bool foreground,
  }) async => RepairOutcomeFfi(kind: RepairKindFfi.rotated, rotated: _change);

  @override
  Future<IngestOutcomeFfi> ingestDriven({
    required CircleManagerFfi circle,
    required String eventJson,
    required bool foreground,
  }) async => IngestOutcomeFfi(
    verdict: ReceiveVerdictFfi.applied,
    replayed: const [],
    errored: false,
    clockRejected: clock,
  );

  @override
  Future<ResumeOutcomeFfi> resumeDriven({
    required CircleManagerFfi circle,
    required bool foreground,
  }) async => ResumeOutcomeFfi(
    withdrawn: const [],
    requeued: const [],
    replayed: const [],
    errored: false,
    clockRejected: clock,
  );

  @override
  Future<SealOutcomeFfi> sealLocationDriven({
    required CircleManagerFfi circle,
    required List<int> mlsGroupId,
    required LocationMessage location,
    required bool foreground,
  }) async {
    if (sealThrows) throw StateError('seal failed');
    return SealOutcomeFfi(
      replayed: const [],
      errored: false,
      clockRejected: clock,
    );
  }

  @override
  Future<LeaveOutcomeFfi> leaveDriven({
    required CircleManagerFfi circle,
    required List<int> mlsGroupId,
    required bool foreground,
  }) async => _leave;

  @override
  Future<LeaveOutcomeFfi> resumeLeaveDriven({
    required CircleManagerFfi circle,
    required List<int> mlsGroupId,
    required bool foreground,
  }) async => _leave;

  @override
  void dispose() {}

  @override
  bool get isDisposed => false;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected call: ${invocation.memberName}');
}

class _Manager implements CircleManagerFfi {
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
  late List<DeviceClockComplaintFfi> heard;
  late int accepted;
  late _Fix fix;
  late NostrRelayService service;
  final m = _Manager();
  const g = [1, 2];

  setUp(() {
    pool = _Pool();
    heard = [];
    accepted = 0;
    fix = _Fix();
    service = NostrRelayService(
      openPool: () async => pool,
      onClockRejected: heard.add,
      onRelayAccepted: () => accepted++,
      fixOf: (_, _) async => fix,
    );
  });

  final entries = <String, Future<Object?> Function(NostrRelayService)>{
    'addMembers': (s) => s.addMembers(
      circle: m,
      mlsGroupId: g,
      members: const [],
      foreground: true,
    ),
    'removeMembers': (s) => s.removeMembers(
      circle: m,
      mlsGroupId: g,
      memberPubkeys: const [],
      foreground: true,
    ),
    'updateCircleRelays': (s) => s.updateCircleRelays(
      circle: m,
      mlsGroupId: g,
      relays: const [],
      foreground: true,
    ),
    'adminHandoff': (s) => s.adminHandoff(
      circle: m,
      mlsGroupId: g,
      successor: 'a',
      foreground: true,
    ),
    'selfDemote': (s) =>
        s.selfDemote(circle: m, mlsGroupId: g, foreground: true),
    'repairRotation': (s) =>
        s.repairRotation(circle: m, mlsGroupId: g, foreground: true),
    'ingest': (s) => s.ingest(circle: m, eventJson: '{}', foreground: true),
    'resume': (s) => s.resume(circle: m, foreground: true),
    'sealLocation': (s) => s.sealLocation(
      circle: m,
      mlsGroupId: g,
      latitude: 1,
      longitude: 2,
      foreground: true,
    ),
    'leave': (s) => s.leave(circle: m, mlsGroupId: g, foreground: true),
    'resumeLeave': (s) =>
        s.resumeLeave(circle: m, mlsGroupId: g, foreground: true),
  };

  for (final MapEntry(key: name, value: call) in entries.entries) {
    test("$name hands its drives' clock evidence over, each direction as "
        'itself, and nothing when they blamed nothing', () async {
      for (final complaint in DeviceClockComplaintFfi.values) {
        pool.clock = complaint;
        await call(service);
      }
      pool.clock = null;
      await call(service);

      expect(heard, DeviceClockComplaintFfi.values);
    });
  }

  const changes = {
    'addMembers',
    'removeMembers',
    'updateCircleRelays',
    'adminHandoff',
    'selfDemote',
    'repairRotation',
  };
  test('a change a relay acknowledged says so, and nothing else does',
      () async {
    for (final MapEntry(key: name, value: call) in entries.entries) {
      for (final status in PublishStatusFfi.values) {
        pool.status = status;
        accepted = 0;
        await call(service);
        expect(
          accepted,
          changes.contains(name) && status == PublishStatusFfi.confirmed
              ? 1
              : 0,
          reason: '$name answering ${status.name}',
        );
      }
    }
  });

  test('a change the core found already so is no relay acknowledgement',
      () async {
    pool
      ..status = PublishStatusFfi.confirmed
      ..alreadySo = true;
    for (final name in changes) {
      await entries[name]!(service);
    }
    expect(accepted, 0, reason: 'no relay was asked, so none took the clock');

    pool.alreadySo = false;
    for (final name in changes) {
      await entries[name]!(service);
    }
    expect(accepted, changes.length);
  });

  test('a seal holds its fix no longer than the seal that reads it', () async {
    await entries['sealLocation']!(service);
    expect(fix.disposed, 1);

    fix = _Fix();
    pool.sealThrows = true;
    await expectLater(entries['sealLocation']!(service), throwsStateError);
    expect(fix.disposed, 1, reason: 'a seal that failed kept the fix');
  });

  test("the app's relay service hands its drives' clock evidence to the "
      'clock check', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    (container.read(relayServiceProvider) as NostrRelayService)
        .hearClockEvidenceForTest(DeviceClockComplaintFfi.behind);

    expect(
      container.read(clockSkewDetectorProvider).status.complaint,
      DeviceClockComplaint.behind,
    );
  });

  test('a clock check the live router cannot reach says so with fixed text, '
      'naming nothing', () async {
    final logs = LogCapture.install();
    final container = ProviderContainer(
      overrides: [
        clockSkewDetectorProvider.overrideWithValue(_UnreachableDetector()),
      ],
    );
    addTearDown(container.dispose);

    await container.read(liveEventRouterProvider).handleEvent(
      const FfiRelayEvent(
        kind: FfiRelayEventKind.status,
        clockRejected: DeviceClockComplaintFfi.ahead,
      ),
    );

    logs
      ..assertContains('[ServiceProvider] clockSkew invalidation error')
      ..assertNoNeedles(['cd' * 32, 'wss://planted.example']);
  });

  test("the app's live router hands a live drive's clock verdict to the "
      'clock check', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await container.read(liveEventRouterProvider).handleEvent(
      const FfiRelayEvent(
        kind: FfiRelayEventKind.status,
        clockRejected: DeviceClockComplaintFfi.behind,
      ),
    );

    expect(
      container.read(clockSkewDetectorProvider).status.complaint,
      DeviceClockComplaint.behind,
    );
  });

  test("the app's relay service clears the clock check on an acknowledged "
      'change', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final relay = container.read(relayServiceProvider) as NostrRelayService
      ..hearClockEvidenceForTest(DeviceClockComplaintFfi.ahead);
    expect(container.read(clockSkewDetectorProvider).status.isSkewed, isTrue);

    relay.hearRelayAcceptedForTest();

    expect(container.read(clockSkewDetectorProvider).status.isSkewed, isFalse);
  });
}

/// A clock check that cannot take a verdict: the throw carries a group id and
/// a relay URL, which no log line may repeat.
class _UnreachableDetector extends ClockSkewDetector {
  @override
  void recordDriveClockRejection(DeviceClockComplaintFfi complaint) =>
      throw StateError('group ${'cd' * 32} at wss://planted.example');
}
