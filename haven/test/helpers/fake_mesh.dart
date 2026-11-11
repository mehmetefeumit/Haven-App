import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/mesh_service.dart';

/// A mesh state with nothing counted.
MeshStatsFfi meshState({
  bool on = false,
  bool linked = false,
  int onForMs = 0,
}) => MeshStatsFfi(
  on_: on,
  linked: linked,
  onForMs: BigInt.from(onForMs),
  fromCirclesSinceOn: BigInt.zero,
  passedOnSinceOn: BigInt.zero,
  fromCirclesTotal: BigInt.zero,
  passedOnTotal: BigInt.zero,
);

/// A circle manager handle for a fake to be asked with; it opens nothing.
class FakeMeshSession implements CircleManagerFfi {
  @override
  void dispose() {}

  @override
  bool get isDisposed => false;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected call: ${invocation.memberName}');
}

/// The bridge's free mesh entries, recorded: every call made, in order, with
/// the session it was asked with.
class RecordingMeshBridge implements MeshBridge {
  /// The entries called, in order.
  final List<String> calls = [];

  /// The session each call was asked with, in order.
  final List<CircleManagerFfi> sessions = [];

  /// What [start] answers.
  MeshStartFfi startAnswer = MeshStartFfi.started;

  /// What [resume] answers.
  MeshStartFfi resumeAnswer = MeshStartFfi.off;

  /// What [keepOn] answers.
  MeshStartFfi keepOnAnswer = MeshStartFfi.alreadyOn;

  /// What [stats] answers.
  MeshStatsFfi statsAnswer = meshState();

  /// When set, the entry of that name throws it.
  final Map<String, Object> throws = {};

  T _called<T>(String call, CircleManagerFfi circle, T answer) {
    calls.add(call);
    sessions.add(circle);
    final boom = throws[call];
    if (boom != null) Error.throwWithStackTrace(boom, StackTrace.current);
    return answer;
  }

  @override
  Future<MeshStartFfi> start(CircleManagerFfi circle) async =>
      _called('start', circle, startAnswer);

  @override
  Future<MeshStartFfi> resume(CircleManagerFfi circle) async =>
      _called('resume', circle, resumeAnswer);

  @override
  Future<MeshStartFfi> keepOn(CircleManagerFfi circle) async =>
      _called('keepOn', circle, keepOnAnswer);

  @override
  Future<void> stop(CircleManagerFfi circle) async =>
      _called('stop', circle, null);

  @override
  void sharingStopped(CircleManagerFfi circle) =>
      _called('sharingStopped', circle, null);

  @override
  Future<MeshStatsFfi> stats(CircleManagerFfi circle) async =>
      _called('stats', circle, statsAnswer);

  @override
  Future<void> resetCounts(CircleManagerFfi circle) async =>
      _called('resetCounts', circle, null);
}

/// A [MeshService] that records what it is asked and answers what the test
/// sets.
class FakeMeshService implements MeshService {
  /// The entries called, in order.
  final List<String> calls = [];

  /// What [start] answers.
  MeshStartFfi startAnswer = MeshStartFfi.started;

  /// What [keepOn] answers.
  MeshStartFfi keepOnAnswer = MeshStartFfi.alreadyOn;

  /// What [stats] answers.
  MeshStatsFfi statsAnswer = meshState();

  /// What [drive] hands back.
  List<LocationEventResult> driveAnswer = const [];

  /// When set, the entry of that name throws it.
  final Map<String, Object> throws = {};

  /// Runs as each [drive] begins.
  void Function()? onDrive;

  /// When set, a [drive] answers only once it completes.
  Future<void>? driveGate;

  Future<T> _called<T>(String call, T Function() answer) async {
    calls.add(call);
    final boom = throws[call];
    if (boom != null) Error.throwWithStackTrace(boom, StackTrace.current);
    return answer();
  }

  @override
  Future<MeshStartFfi> start() => _called('start', () {
    statsAnswer = meshState(on: startAnswer != MeshStartFfi.off);
    return startAnswer;
  });

  @override
  Future<MeshStartFfi> keepOn() => _called('keepOn', () => keepOnAnswer);

  @override
  Future<void> stop() => _called('stop', () {
    statsAnswer = meshState();
  });

  @override
  Future<void> sharingStopped() => _called('sharingStopped', () {});

  @override
  Future<MeshStatsFfi> stats() => _called('stats', () => statsAnswer);

  @override
  Future<void> resetCounts() => _called('resetCounts', () {});

  @override
  Future<List<LocationEventResult>> drive() async {
    onDrive?.call();
    await driveGate;
    return _called('drive', () => driveAnswer);
  }
}
