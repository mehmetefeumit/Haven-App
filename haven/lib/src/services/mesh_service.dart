/// The Bluetooth mesh's entries: an opt-in second carrier for the location
/// events the relay path seals (`docs/BLUETOOTH_MESH_PLAN.md` §5, §7.5–§7.7).
library;

import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/circle_change_driver.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/nostr_circle_service.dart'
    show locationEventResultFromFfi;

/// How many times one [MeshService.drive] asks while packets still wait.
/// The bridge reads 256 packets a time, so a drive that rides a receive
/// stays a bounded piece of local work whatever the mesh carried meanwhile;
/// what is left waits for the next drive.
const int kMeshDriveRounds = 4;

/// Thrown when a mesh entry could not be made. Fixed text: what the bridge
/// threw is neither shown nor logged (Security Rules 8 and 15).
class MeshServiceException implements Exception {
  /// Creates a mesh service exception.
  const MeshServiceException(this.message);

  /// A generic, user-safe message.
  final String message;

  @override
  String toString() => 'MeshServiceException: $message';
}

/// The Bluetooth mesh as the app drives it.
///
/// Every entry throws [MeshServiceException] when it could not be made.
abstract interface class MeshService {
  /// Turns mesh on for twelve hours from now; asked while it is on, restarts
  /// them. [MeshStartFfi.off] when the store did not take it: nothing is on.
  Future<MeshStartFfi> start();

  /// Restarts the twelve hours if mesh is on. After the deadline it answers
  /// [MeshStartFfi.off] and turns nothing on.
  Future<MeshStartFfi> keepOn();

  /// Turns mesh off: its engine goes with every packet it carried, and every
  /// stored key and the deadline are deleted.
  Future<void> stop();

  /// The user stopped sharing: every location waiting to go out by mesh is
  /// withdrawn. Mesh stays on and still receives and carries.
  Future<void> sharingStopped();

  /// Whether mesh is on, whether a phone is linked, the time left and the
  /// four counts, as the bridge reports them.
  Future<MeshStatsFfi> stats();

  /// Forgets all four counts.
  Future<void> resetCounts();

  /// Takes in what the mesh received: the results of the locations members
  /// of this device's circles sent, each stored already. Calls no relay; with
  /// mesh off, nothing.
  Future<List<LocationEventResult>> drive();
}

/// The bridge's mesh entries that are free functions: a seam, so
/// [NostrMeshService] runs against a fake where there is no bridge.
class MeshBridge {
  /// The bridge itself.
  const MeshBridge();

  /// `mesh_start`.
  Future<MeshStartFfi> start(CircleManagerFfi circle) =>
      meshStart(circle: circle);

  /// `mesh_resume`.
  Future<MeshStartFfi> resume(CircleManagerFfi circle) =>
      meshResume(circle: circle);

  /// `mesh_keep_on`.
  Future<MeshStartFfi> keepOn(CircleManagerFfi circle) =>
      meshKeepOn(circle: circle);

  /// `mesh_stop`.
  Future<void> stop(CircleManagerFfi circle) => meshStop(circle: circle);

  /// `mesh_sharing_stopped`.
  void sharingStopped(CircleManagerFfi circle) =>
      meshSharingStopped(circle: circle);

  /// `mesh_stats`.
  Future<MeshStatsFfi> stats(CircleManagerFfi circle) =>
      meshStats(circle: circle);

  /// `mesh_reset_counts`.
  Future<void> resetCounts(CircleManagerFfi circle) =>
      meshResetCounts(circle: circle);
}

/// [MeshService] over the Rust bridge.
class NostrMeshService implements MeshService {
  /// [circleManager] hands back the one manager this isolate's circle
  /// service opened, never a second one over the same database (Security
  /// Rule 14). [driver] makes the two entries that are the relay manager's,
  /// in the registry every other driven entry is in.
  NostrMeshService({
    required Future<CircleManagerFfi> Function() circleManager,
    required CircleChangeDriver driver,
    MeshBridge bridge = const MeshBridge(),
  }) : _circleManager = circleManager,
       _driver = driver,
       _bridge = bridge;

  final Future<CircleManagerFfi> Function() _circleManager;
  final CircleChangeDriver _driver;
  final MeshBridge _bridge;

  /// The resume made for each session this service was handed. Keyed weakly:
  /// a manager's handle is released by its owner alone, and nothing here
  /// keeps one reachable past that.
  final Expando<Future<MeshStartFfi>> _resumed = Expando();

  /// The open session, with the engine of a mesh an earlier process left on
  /// brought back first, under the deadline that process stored — once a
  /// session, and never before its manager exists, since the manager is what
  /// the resume is asked with. A process that opens a session without this
  /// leaves that mesh's keys kept and its hand-off filling with no engine to
  /// take from it. A resume that failed is asked again by the next entry:
  /// remembered, it would refuse every later one, turning mesh off included.
  Future<CircleManagerFfi> _session() async {
    final circle = await _circleManager();
    try {
      await (_resumed[circle] ??= _bridge.resume(circle));
    } on Object {
      _resumed[circle] = null;
      rethrow;
    }
    return circle;
  }

  Future<T> _entry<T>(
    String failure,
    Future<T> Function(CircleManagerFfi circle) entry,
  ) async {
    try {
      return await entry(await _session());
    } on Object catch (_) {
      throw MeshServiceException(failure);
    }
  }

  @override
  Future<MeshStartFfi> start() =>
      _entry('Failed to turn mesh on', _bridge.start);

  @override
  Future<MeshStartFfi> keepOn() =>
      _entry('Failed to keep mesh on', _bridge.keepOn);

  @override
  Future<void> stop() => _entry('Failed to turn mesh off', _bridge.stop);

  @override
  Future<void> sharingStopped() => _entry(
    'Failed to withdraw from mesh',
    (circle) async => _bridge.sharingStopped(circle),
  );

  @override
  Future<MeshStatsFfi> stats() => _entry('Failed to read mesh', _bridge.stats);

  @override
  Future<void> resetCounts() =>
      _entry('Failed to reset mesh counts', _bridge.resetCounts);

  @override
  Future<List<LocationEventResult>> drive() =>
      _entry('Failed to drive mesh', (circle) async {
        final replayed = <LocationEventResult>[];
        for (var round = 0; round < kMeshDriveRounds; round++) {
          final drive = await _driver.meshDrive(circle: circle);
          replayed.addAll(drive.replayed.map(locationEventResultFromFfi));
          if (!drive.more) break;
        }
        return replayed;
      });
}
