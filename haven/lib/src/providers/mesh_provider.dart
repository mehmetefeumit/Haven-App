/// The Bluetooth mesh's build flag, service and state.
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:haven/src/providers/background_location_provider.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/live_sync_provider.dart';
import 'package:haven/src/providers/location_sharing_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/background_burst_coordinator.dart';
import 'package:haven/src/services/circle_change_driver.dart';
import 'package:haven/src/services/mesh_radio.dart';
import 'package:haven/src/services/mesh_service.dart';
import 'package:haven/src/services/nostr_circle_service.dart';

/// Master switch for the Bluetooth mesh (`docs/BLUETOOTH_MESH_PLAN.md`): an
/// opt-in second carrier for the location events the relay path seals.
///
/// Off unless a build passes `--dart-define=HAVEN_MESH=true`. With it off no
/// Dart code calls a mesh entry, so mesh cannot be turned on, no mesh key is
/// stored and nothing is passed on to a relay. The radio has no native end
/// yet: with it on, an Android build's turn-on fails and stores nothing, and
/// no packet moves between phones in any build.
const meshEnabled = bool.fromEnvironment('HAVEN_MESH');

/// [meshEnabled], read through a provider so the default test run executes
/// both builds.
final meshEnabledProvider = Provider<bool>((ref) => meshEnabled);

/// The bridge's free mesh entries; overridden where there is no bridge.
final meshBridgeProvider = Provider<MeshBridge>((ref) => const MeshBridge());

/// The mesh's entries, or `null` in a build without the mesh: the one gate
/// every Dart call of a mesh entry sits behind.
///
/// The circle service is read at each use, as every other holder of its
/// manager reads it, and the identity before it: opening the manager of a
/// service that has none would create a database the logout wipe removed.
final meshServiceProvider = Provider<MeshService?>((ref) {
  if (!ref.watch(meshEnabledProvider)) return null;
  return NostrMeshService(
    driver: ref.read(relayServiceProvider) as CircleChangeDriver,
    bridge: ref.watch(meshBridgeProvider),
    circleManager: () async {
      if (await ref.read(identityProvider.future) == null) {
        throw StateError('no active identity');
      }
      final circleService = ref.read(circleServiceProvider);
      if (circleService is! NostrCircleService) {
        throw StateError('circle service is not Nostr-backed');
      }
      return circleService.getCircleManagerFfi();
    },
  );
});

/// The radio, or `null` where there is none: a build without the mesh, and
/// every platform but Android. With `null` no radio channel is touched and
/// the mesh is driven exactly as it is without one.
final meshRadioProvider = Provider<MeshRadio?>((ref) {
  if (!ref.watch(meshEnabledProvider) ||
      !ref.watch(platformIsAndroidProvider)) {
    return null;
  }
  return const AndroidMeshRadio();
});

/// [meshRadioProvider]'s answer where no provider container exists yet: the
/// launch's retry of a logout's wipe.
MeshRadio? platformMeshRadio() =>
    meshEnabled && Platform.isAndroid ? const AndroidMeshRadio() : null;

/// The words of the radio's notices for a mesh that turns itself off in
/// [left].
typedef MeshNoticeCopyOf = MeshNoticeCopy Function(Duration left);

/// The radio's notices in the language the app renders in, or `null` in a
/// build that has no words for them. None exist yet: the strings land with
/// the UI. Without them no radio is started — one whose notices say nothing
/// would run unseen — so a turn-on fails before anything is stored.
final meshNoticeCopyProvider = Provider<MeshNoticeCopyOf?>((ref) => null);

/// Whether mesh was turned off by something other than the user, who has not
/// been told. Set by a reconcile that turned it off; flipped back by whoever
/// shows the notice.
final meshStoppedNoticeProvider = StateProvider<bool>((ref) => false);

/// How a turn-on ended. Each variant but [on] has fixed copy of its own, and
/// is a turn-on that stored nothing or took back what it stored.
enum MeshTurnOn {
  /// Mesh is on, and where the platform has a radio it started.
  on,

  /// The system refused the radio's permission and can be asked again.
  noPermission,

  /// The system refused it, and only its settings can grant it.
  noPermissionForGood,

  /// The user backed out before anything was stored.
  cancelled,

  /// Bluetooth is switched off.
  bluetoothOff,

  /// This phone has no radio the mesh can use.
  unsupported,

  /// It could not be turned on.
  failed,
}

/// The Bluetooth mesh as the bridge reports it — whether it is on, whether a
/// phone is linked, the time left and the four counts — never recomputed
/// here. `null` in a build without the mesh.
///
/// Building it reads the state, which is also what brings back the engine of
/// a mesh an earlier process left on ([NostrMeshService]).
final meshProvider = AsyncNotifierProvider<MeshNotifier, MeshStatsFfi?>(
  MeshNotifier.new,
);

/// Holds the mesh's state and makes its entries. In a build without the mesh
/// every method does nothing.
///
/// Where the platform has a radio, mesh is on only with both its engine and
/// its radio: [turnOn], [turnOff], [keepOn] and [reconcile] run one at a
/// time, in the order asked (`docs/BLUETOOTH_MESH_M3_DESIGN.md` §C.2–§C.4).
class MeshNotifier extends AsyncNotifier<MeshStatsFfi?> implements BurstMesh {
  /// The turn-on, turn-off, keep-on or reconcile asked last: the next one
  /// runs behind it.
  Future<void> _last = Future.value();

  /// The user's transitions asked and not yet finished.
  int _transitions = 0;

  @override
  Future<MeshStatsFfi?> build() async {
    final radio = ref.watch(meshRadioProvider);
    if (radio != null) {
      final changes = radio.changes.listen((_) => unawaited(reconcile()));
      ref.onDispose(changes.cancel);
    }
    return ref.watch(meshServiceProvider)?.stats();
  }

  /// Turns mesh on for twelve hours from now.
  ///
  /// [confirm] runs once the radio's permission is held — which is when the
  /// phone's Bluetooth name can first be read — and before anything is
  /// stored; answering `false` backs out.
  Future<MeshTurnOn> turnOn({Future<bool> Function()? confirm}) async {
    var ended = MeshTurnOn.failed;
    await _transition((mesh, radio) async {
      ended = await _turnOn(mesh, radio, confirm);
    });
    return ended;
  }

  /// Restarts the twelve hours. Answers whether mesh is on: after the
  /// deadline it is not, and the only way back is [turnOn].
  Future<bool> keepOn() async {
    var kept = false;
    await _transition((mesh, radio) async {
      kept = await mesh.keepOn() != MeshStartFfi.off;
      if (!kept || radio == null) return;
      try {
        final copy = await _copy(mesh);
        if (copy != null) await radio.sync(copy);
      } on Object {
        // The engine holds the deadline: a service that was not told reads
        // it there at its next wake.
      }
    });
    return kept;
  }

  /// Turns mesh off.
  Future<void> turnOff() => _transition(_off);

  /// Brings the engine and the radio back to one answer, from what each
  /// reports now: a radio up beside an engine that is off is stopped, and
  /// the keys that engine left are deleted; an engine on beside a radio that
  /// stopped gets the radio back if the service still wants it and may run,
  /// and otherwise goes off, with [meshStoppedNoticeProvider] set. Does
  /// nothing where there is no radio, or while the engine cannot be read.
  ///
  /// Dropped while a transition of the user's is asked or running, since
  /// each ends with a reconcile of its own: one run in the middle of a
  /// turn-off reads an engine still on beside a radio already stopped, and
  /// would start the radio again.
  Future<void> reconcile() async {
    final radio = ref.read(meshRadioProvider);
    if (radio == null || _transitions > 0) return;
    await _inTurn((mesh) => _reconcile(mesh, radio));
  }

  /// Forgets all four counts.
  Future<void> resetCounts() => _then((mesh) => mesh.resetCounts());

  /// Reads the state again.
  Future<void> refresh() => _then((_) async {});

  /// The user stopped sharing: what waits to go out by mesh is withdrawn.
  /// Never throws.
  Future<void> sharingStopped() async {
    try {
      await ref.read(meshServiceProvider)?.sharingStopped();
    } on Object catch (_) {
      // What could not be withdrawn waits no longer than its own event
      // lives: the engine drops it at the event's expiration.
    }
  }

  /// Whether mesh is on, read afresh. Never throws: a state that could not
  /// be read is not on.
  @override
  Future<bool> isOn() async {
    await refresh();
    return switch (state) {
      AsyncData(:final value) => value?.on_ ?? false,
      _ => false,
    };
  }

  /// Takes in what the mesh received, through the funnel a relay receive's
  /// results take. Never throws: the mesh is lossy by design, and a drive
  /// that failed leaves its packets for the next one.
  @override
  Future<void> drive() async {
    try {
      final replayed = await ref.read(meshServiceProvider)?.drive();
      if (replayed == null) return;
      final stored = await ref
          .read(locationSharingServiceProvider)
          .ingestReplayed(replayed);
      // Where the map reads the cache it is told, as the live plane tells
      // it. Where it polls, the next poll shows the cache: invalidating
      // there would ask the relays, and the mesh changes nothing a relay is
      // asked.
      if (stored > 0 && liveSyncEnabled) {
        ref.invalidate(memberLocationsProvider);
      }
    } on Object catch (_) {
      // See above.
    }
  }

  Future<MeshTurnOn> _turnOn(
    MeshService mesh,
    MeshRadio? radio,
    Future<bool> Function()? confirm,
  ) async {
    if (radio != null) {
      final refused = await _refused(radio, confirm);
      if (refused != null) return refused;
    }
    if (await mesh.start() == MeshStartFfi.off) return MeshTurnOn.failed;
    if (radio == null) return MeshTurnOn.on;
    final ended = switch (await _startRadio(mesh, radio)) {
      MeshRadioStart.started => MeshTurnOn.on,
      MeshRadioStart.noPermission => MeshTurnOn.noPermission,
      MeshRadioStart.unsupported => MeshTurnOn.unsupported,
      MeshRadioStart.failed => MeshTurnOn.failed,
    };
    if (ended != MeshTurnOn.on) {
      try {
        await _off(mesh, radio);
      } on Object {
        // The keys remain until a reconcile takes them: the one this
        // transition ends with, and each one after it.
      }
    }
    return ended;
  }

  /// What keeps the radio from starting, asked before anything is stored: a
  /// refusal then has nothing to unwind, and no key is at rest while a
  /// system dialog is on screen.
  Future<MeshTurnOn?> _refused(
    MeshRadio radio,
    Future<bool> Function()? confirm,
  ) async {
    if (ref.read(meshNoticeCopyProvider) == null) return MeshTurnOn.failed;
    try {
      switch (await radio.requestPermission()) {
        case MeshRadioPermission.granted:
          break;
        case MeshRadioPermission.denied:
          return MeshTurnOn.noPermission;
        case MeshRadioPermission.deniedForGood:
          return MeshTurnOn.noPermissionForGood;
      }
      if (confirm != null && !await confirm()) return MeshTurnOn.cancelled;
      return await radio.bluetoothOn() ? null : MeshTurnOn.bluetoothOff;
    } on Object {
      return MeshTurnOn.failed;
    }
  }

  /// Radio first, so the service's copy of the deadline is gone before the
  /// engine is: a failure between the two leaves keys until a reconcile,
  /// never a radio that would come back by itself with the store saying
  /// off. The engine is stopped whatever the radio did.
  Future<void> _off(MeshService mesh, MeshRadio? radio) async {
    try {
      await radio?.stop();
    } on Object {
      // See above.
    }
    await mesh.stop();
  }

  Future<void> _reconcile(MeshService mesh, MeshRadio radio) async {
    final MeshStatsFfi stats;
    try {
      stats = await mesh.stats();
    } on Object {
      // Nothing is known of the engine, so nothing is done to it.
      return;
    }
    final status = await _status(radio);
    if (stats.on_ == (status.state != MeshRadioState.stopped)) return;
    // A stop the service made cleared `wanted`: it is final, and the notice
    // the service posted stays true.
    if (stats.on_ && status.wanted && await _restarted(mesh, radio)) return;
    try {
      await _off(mesh, radio);
    } on Object {
      // The keys remain and no notice says otherwise: the next reconcile
      // asks again.
      return;
    }
    if (stats.on_) ref.read(meshStoppedNoticeProvider.notifier).state = true;
  }

  /// The radio as it reports itself. One that does not answer is read as
  /// stopped by its own doing: a mesh whose radio cannot be asked goes off
  /// rather than staying on unseen.
  Future<MeshRadioStatus> _status(MeshRadio radio) async {
    try {
      return await radio.status();
    } on Object {
      return const MeshRadioStatus(
        state: MeshRadioState.stopped,
        wanted: false,
        canSearch: false,
      );
    }
  }

  Future<bool> _restarted(MeshService mesh, MeshRadio radio) async {
    try {
      return await radio.permission() == MeshRadioPermission.granted &&
          await _startRadio(mesh, radio) == MeshRadioStart.started;
    } on Object {
      return false;
    }
  }

  Future<MeshRadioStart> _startRadio(MeshService mesh, MeshRadio radio) async {
    try {
      final copy = await _copy(mesh);
      return copy == null ? MeshRadioStart.failed : await radio.start(copy);
    } on Object {
      return MeshRadioStart.failed;
    }
  }

  /// The notices' words under the deadline the engine holds now.
  Future<MeshNoticeCopy?> _copy(MeshService mesh) async {
    final copy = ref.read(meshNoticeCopyProvider);
    if (copy == null) return null;
    final left = (await mesh.stats()).onForMs;
    return copy(Duration(milliseconds: left.toInt()));
  }

  /// Runs a transition of the user's in its turn, then the reconcile that
  /// makes up for every one dropped meanwhile.
  Future<void> _transition(
    Future<void> Function(MeshService mesh, MeshRadio? radio) step,
  ) {
    final radio = ref.read(meshRadioProvider);
    _transitions++;
    return _inTurn((mesh) async {
      try {
        await step(mesh, radio);
      } finally {
        if (radio != null) await _reconcile(mesh, radio);
      }
    }).whenComplete(() => _transitions--);
  }

  Future<void> _inTurn(Future<void> Function(MeshService mesh) step) =>
      _last = _last.then((_) => _then(step));

  /// Makes [entry], then reads the state it left. Never throws: a failure is
  /// the state.
  Future<void> _then(Future<void> Function(MeshService mesh) entry) async {
    // Behind the build's own read, whose answer would otherwise land on top
    // of this one's.
    await future.then<void>((_) {}, onError: (Object _) {});
    state = await AsyncValue.guard(() async {
      final mesh = ref.read(meshServiceProvider);
      if (mesh == null) return null;
      await entry(mesh);
      return mesh.stats();
    });
  }
}
