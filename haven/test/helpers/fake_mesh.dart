import 'dart:async';

import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/mesh_radio.dart';
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

/// What a fake was asked, and the means to hold one of its calls open while
/// a test does something else.
mixin _Asked {
  /// The entries called, in order.
  final List<String> calls = [];

  /// When set, every call is also written here as `<who>.<call>`: one order
  /// across several fakes.
  List<String>? journal;

  /// When set, the entry of that name throws it.
  final Map<String, Object> throws = {};

  /// When set, the entry of that name answers only once it completes.
  final Map<String, Future<void>> held = {};

  final Map<String, Completer<void>> _reached = {};

  String get _who;

  /// Completes once the entry of that name has been called.
  Future<void> reached(String call) =>
      (_reached[call] ??= Completer<void>()).future;

  Future<T> _called<T>(String call, T Function() answer) async {
    calls.add(call);
    journal?.add('$_who.$call');
    final reached = _reached[call] ??= Completer<void>();
    if (!reached.isCompleted) reached.complete();
    final hold = held[call];
    if (hold != null) await hold;
    final boom = throws[call];
    if (boom != null) Error.throwWithStackTrace(boom, StackTrace.current);
    return answer();
  }
}

/// A [MeshService] that records what it is asked and answers what the test
/// sets.
class FakeMeshService with _Asked implements MeshService {
  @override
  String get _who => 'mesh';

  /// What [start] answers.
  MeshStartFfi startAnswer = MeshStartFfi.started;

  /// The time left a [start] that turned mesh on leaves, milliseconds.
  int startsForMs = 0;

  /// What [keepOn] answers.
  MeshStartFfi keepOnAnswer = MeshStartFfi.alreadyOn;

  /// What [stats] answers.
  MeshStatsFfi statsAnswer = meshState();

  /// What [drive] hands back.
  List<LocationEventResult> driveAnswer = const [];

  /// Runs as each [drive] begins.
  void Function()? onDrive;

  /// When set, a [drive] answers only once it completes.
  Future<void>? driveGate;

  @override
  Future<MeshStartFfi> start() => _called('start', () {
    final on = startAnswer != MeshStartFfi.off;
    statsAnswer = meshState(on: on, onForMs: on ? startsForMs : 0);
    return startAnswer;
  });

  @override
  Future<MeshStartFfi> keepOn() => _called('keepOn', () {
    // As the bridge: a mesh it answers is on reads as on.
    if (keepOnAnswer != MeshStartFfi.off && !statsAnswer.on_) {
      statsAnswer = meshState(on: true, onForMs: startsForMs);
    }
    return keepOnAnswer;
  });

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

/// The radio's notices with a word each, and the time left spelled into the
/// reminder so a test can read which deadline a start or a sync was told.
MeshNoticeCopy meshCopy(Duration left) => MeshNoticeCopy(
  channel: 'channel',
  on: 'on',
  paused: 'paused',
  reminder: 'off in ${left.inMilliseconds}',
  keepOn: 'keep on',
  stopped: 'stopped',
);

/// A radio status.
MeshRadioStatus radioStatus(
  MeshRadioState state, {
  bool wanted = false,
  bool canSearch = true,
}) => MeshRadioStatus(state: state, wanted: wanted, canSearch: canSearch);

/// A [MeshRadio] that records what it is asked, answers what the test sets
/// and behaves as the service does: a start that succeeds leaves it running
/// and wanted, a stop leaves it stopped and not wanted.
class FakeMeshRadio with _Asked implements MeshRadio {
  @override
  String get _who => 'radio';

  /// What [permission] and [requestPermission] answer.
  MeshRadioPermission permissionAnswer = MeshRadioPermission.granted;

  /// What [bluetoothOn] answers.
  bool bluetoothOnAnswer = true;

  /// What [bluetoothName] answers.
  String? bluetoothNameAnswer;

  /// What [start] answers.
  MeshRadioStart startAnswer = MeshRadioStart.started;

  /// What [status] answers.
  MeshRadioStatus statusAnswer = radioStatus(MeshRadioState.stopped);

  /// The words each [start] and [sync] was handed, in order.
  final List<MeshNoticeCopy> copies = [];

  final _changes = StreamController<MeshRadioStatus>.broadcast(sync: true);
  final _actions = StreamController<MeshRadioAction>.broadcast(sync: true);

  /// The service reports [status]: it is what [status] answers from now on,
  /// and every listener of [changes] is told before this returns.
  void emit(MeshRadioStatus status) {
    statusAnswer = status;
    _changes.add(status);
  }

  /// A notice was tapped.
  void tap(MeshRadioAction action) => _actions.add(action);

  @override
  Future<MeshRadioPermission> permission() =>
      _called('permission', () => permissionAnswer);

  @override
  Future<MeshRadioPermission> requestPermission() =>
      _called('requestPermission', () => permissionAnswer);

  @override
  Future<bool> bluetoothOn() => _called('bluetoothOn', () => bluetoothOnAnswer);

  @override
  Future<String?> bluetoothName() =>
      _called('bluetoothName', () => bluetoothNameAnswer);

  @override
  Future<void> openBluetoothSettings() =>
      _called('openBluetoothSettings', () {});

  @override
  Future<MeshRadioStart> start(MeshNoticeCopy copy) => _called('start', () {
    copies.add(copy);
    if (startAnswer == MeshRadioStart.started) {
      statusAnswer = radioStatus(MeshRadioState.running, wanted: true);
    }
    return startAnswer;
  });

  @override
  Future<void> sync(MeshNoticeCopy copy) =>
      _called('sync', () => copies.add(copy));

  @override
  Future<void> stop() => _called('stop', () {
    statusAnswer = radioStatus(MeshRadioState.stopped);
  });

  @override
  Future<MeshRadioStatus> status() => _called('status', () => statusAnswer);

  @override
  Stream<MeshRadioStatus> get changes => _changes.stream;

  @override
  Stream<MeshRadioAction> get actions => _actions.stream;
}
