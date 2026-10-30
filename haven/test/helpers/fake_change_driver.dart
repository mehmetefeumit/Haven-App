import 'dart:typed_data';

import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/circle_change_driver.dart';

/// An [EvolutionOutcomeFfi] in [status], with nothing else to report unless
/// given.
EvolutionOutcomeFfi evolutionOutcome(
  PublishStatusFfi status, {
  RefusalFfi? refusal,
  int welcomesDelivered = 0,
  int welcomesTotal = 0,
  bool reinviteOwed = false,
  List<LocationMessageResultFfi> replayed = const [],
}) => EvolutionOutcomeFfi(
  status: status,
  refusal: refusal,
  welcomesDelivered: welcomesDelivered,
  welcomesTotal: welcomesTotal,
  reinviteOwed: reinviteOwed,
  replayed: replayed,
);

/// A [CircleChangeDriver] that records what it is asked and answers what the
/// test sets.
class FakeChangeDriver implements CircleChangeDriver {
  /// What every evolution entry answers.
  EvolutionOutcomeFfi outcome = evolutionOutcome(PublishStatusFfi.confirmed);

  /// What [repairRotation] answers.
  RepairOutcomeFfi repair = RepairOutcomeFfi(
    kind: RepairKindFfi.rotated,
    rotated: evolutionOutcome(PublishStatusFfi.confirmed),
  );

  /// What [reinvite] answers.
  List<ReinviteFfi> reinvites = const [];

  /// The drive [reinvite] answers with.
  ResumeOutcomeFfi reinviteDrive = const ResumeOutcomeFfi(
    withdrawn: [],
    requeued: [],
    replayed: [],
    errored: false,
  );

  /// What [ingest] answers, for each event in turn; once spent, the last.
  List<IngestOutcomeFfi> ingests = const [
    IngestOutcomeFfi(
      verdict: ReceiveVerdictFfi.applied,
      replayed: [],
      errored: false,
    ),
  ];
  int _ingested = 0;

  /// The events [ingest] was handed, in order.
  final List<String> ingestedEvents = [];

  /// What [resume] answers.
  ResumeOutcomeFfi resumeOutcome = const ResumeOutcomeFfi(
    withdrawn: [],
    requeued: [],
    replayed: [],
    errored: false,
  );

  /// What [leave] answers.
  LeaveOutcomeFfi leaveOutcome = const LeaveOutcomeFfi(
    status: LeaveStatusFfi.proposed,
  );

  /// What [resumeLeave] answers for a circle, by its group id's bytes joined;
  /// a circle not named answers [LeaveStatusFfi.notLeaving].
  Map<String, LeaveOutcomeFfi> resumeLeaveOutcomes = {};

  /// When set, every entry throws it.
  Object? throws;

  /// When set, every entry answers only once it completes.
  Future<void>? hold;

  /// The entries called, in order.
  final List<String> calls = [];

  /// The `foreground` word each call carried, in order.
  final List<bool> foregrounds = [];

  /// The circle manager each call was handed, in order.
  final List<CircleManagerFfi> managers = [];

  /// The group id each call named, in order; `null` for a call naming none.
  final List<List<int>?> groupIds = [];

  /// The members the last [addMembers] was handed.
  List<MemberKeyPackageFfi>? members;

  /// The pubkeys the last [removeMembers] was handed.
  List<String>? removed;

  /// The relays the last [updateCircleRelays] was handed.
  List<String>? relays;

  /// The successor the last [adminHandoff] was handed.
  String? successor;

  /// What [createCircle] answers.
  CircleCreationOutcomeFfi creation = CircleCreationOutcomeFfi(
    circle: CircleFfi(
      mlsGroupId: Uint8List.fromList(const [7, 7]),
      nostrGroupId: Uint8List.fromList(List<int>.filled(32, 7)),
      displayName: 'Created',
      circleType: 'location_sharing',
      relays: const ['wss://relay.example'],
      createdAt: 1700000000,
      updatedAt: 1700000000,
    ),
    welcomesSent: 0,
    welcomesTotal: 0,
    unsentRecipients: const [],
  );

  /// What the last [createCircle] was handed.
  ({
    List<int> identitySecretBytes,
    List<MemberKeyPackageFfi> members,
    String name,
    String? description,
    String circleType,
    List<String> relays,
  })?
  created;

  Future<T> _answer<T>(
    String call,
    CircleManagerFfi circle,
    List<int>? mlsGroupId,
    bool foreground,
    T Function() answer,
  ) async {
    calls.add(call);
    foregrounds.add(foreground);
    managers.add(circle);
    groupIds.add(mlsGroupId);
    await hold;
    final error = throws;
    if (error != null) return Future<T>.error(error);
    return answer();
  }

  @override
  Future<CircleCreationOutcomeFfi> createCircle({
    required CircleManagerFfi circle,
    required List<int> identitySecretBytes,
    required List<MemberKeyPackageFfi> members,
    required String name,
    required String circleType,
    required List<String> relays,
    required bool foreground,
    String? description,
  }) {
    created = (
      identitySecretBytes: identitySecretBytes,
      members: members,
      name: name,
      description: description,
      circleType: circleType,
      relays: relays,
    );
    return _answer('createCircle', circle, null, foreground, () => creation);
  }

  @override
  Future<EvolutionOutcomeFfi> addMembers({
    required CircleManagerFfi circle,
    required List<int> mlsGroupId,
    required List<MemberKeyPackageFfi> members,
    required bool foreground,
  }) {
    this.members = members;
    return _answer('addMembers', circle, mlsGroupId, foreground, () => outcome);
  }

  @override
  Future<EvolutionOutcomeFfi> removeMembers({
    required CircleManagerFfi circle,
    required List<int> mlsGroupId,
    required List<String> memberPubkeys,
    required bool foreground,
  }) {
    removed = memberPubkeys;
    return _answer(
      'removeMembers',
      circle,
      mlsGroupId,
      foreground,
      () => outcome,
    );
  }

  @override
  Future<EvolutionOutcomeFfi> updateCircleRelays({
    required CircleManagerFfi circle,
    required List<int> mlsGroupId,
    required List<String> relays,
    required bool foreground,
  }) {
    this.relays = relays;
    return _answer(
      'updateCircleRelays',
      circle,
      mlsGroupId,
      foreground,
      () => outcome,
    );
  }

  @override
  Future<EvolutionOutcomeFfi> adminHandoff({
    required CircleManagerFfi circle,
    required List<int> mlsGroupId,
    required String successor,
    required bool foreground,
  }) {
    this.successor = successor;
    return _answer(
      'adminHandoff',
      circle,
      mlsGroupId,
      foreground,
      () => outcome,
    );
  }

  @override
  Future<EvolutionOutcomeFfi> selfDemote({
    required CircleManagerFfi circle,
    required List<int> mlsGroupId,
    required bool foreground,
  }) => _answer('selfDemote', circle, mlsGroupId, foreground, () => outcome);

  @override
  Future<RepairOutcomeFfi> repairRotation({
    required CircleManagerFfi circle,
    required List<int> mlsGroupId,
    required bool foreground,
  }) => _answer(
    'repairRotation',
    circle,
    mlsGroupId,
    foreground,
    () => repair,
  );

  @override
  Future<ReinviteDrivenFfi> reinvite({
    required CircleManagerFfi circle,
    required bool foreground,
  }) => _answer(
    'reinvite',
    circle,
    null,
    foreground,
    () => ReinviteDrivenFfi(reinvites: reinvites, drive: reinviteDrive),
  );

  /// What [circleRecovery] answers.
  RecoveryCauseFfi? recovery;

  @override
  Future<RecoveryCauseFfi?> circleRecovery({
    required CircleManagerFfi circle,
    required List<int> mlsGroupId,
    required bool foreground,
  }) => _answer(
    'circleRecovery',
    circle,
    mlsGroupId,
    foreground,
    () => recovery,
  );

  @override
  Future<IngestOutcomeFfi> ingest({
    required CircleManagerFfi circle,
    required String eventJson,
    required bool foreground,
  }) {
    ingestedEvents.add(eventJson);
    final i = _ingested < ingests.length ? _ingested : ingests.length - 1;
    _ingested++;
    return _answer('ingest', circle, null, foreground, () => ingests[i]);
  }

  @override
  Future<ResumeOutcomeFfi> resume({
    required CircleManagerFfi circle,
    required bool foreground,
  }) => _answer('resume', circle, null, foreground, () => resumeOutcome);

  @override
  Future<LeaveOutcomeFfi> leave({
    required CircleManagerFfi circle,
    required List<int> mlsGroupId,
    required bool foreground,
  }) => _answer('leave', circle, mlsGroupId, foreground, () => leaveOutcome);

  @override
  Future<LeaveOutcomeFfi> resumeLeave({
    required CircleManagerFfi circle,
    required List<int> mlsGroupId,
    required bool foreground,
  }) => _answer(
    'resumeLeave',
    circle,
    mlsGroupId,
    foreground,
    () =>
        resumeLeaveOutcomes[mlsGroupId.join(',')] ??
        const LeaveOutcomeFfi(status: LeaveStatusFfi.notLeaving),
  );

  /// What [sealLocation] answers.
  SealOutcomeFfi sealOutcome = const SealOutcomeFfi(
    replayed: [],
    errored: false,
  );

  /// The fixes [sealLocation] was handed, in order.
  final List<({double latitude, double longitude})> sealedFixes = [];

  /// What [publishLocation] answers.
  LocationPublishFfi publishAnswer = LocationPublishFfi.accepted;

  /// The sealed locations [publishLocation] was handed, in order.
  final List<SealedLocationFfi> publishedSeals = [];

  @override
  Future<SealOutcomeFfi> sealLocation({
    required CircleManagerFfi circle,
    required List<int> mlsGroupId,
    required double latitude,
    required double longitude,
    required bool foreground,
  }) {
    sealedFixes.add((latitude: latitude, longitude: longitude));
    return _answer(
      'sealLocation',
      circle,
      mlsGroupId,
      foreground,
      () => sealOutcome,
    );
  }

  @override
  Future<LocationPublishFfi> publishLocation({
    required CircleManagerFfi circle,
    required SealedLocationFfi sealed,
  }) {
    publishedSeals.add(sealed);
    return _answer(
      'publishLocation',
      circle,
      null,
      false,
      () => publishAnswer,
    );
  }
}

/// A sealed location for a fake to hand round; it holds nothing.
class FakeSealedLocation implements SealedLocationFfi {
  @override
  void dispose() {}

  @override
  bool get isDisposed => false;
}
