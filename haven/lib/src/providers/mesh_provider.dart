/// The Bluetooth mesh's build flag, service and state.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/live_sync_provider.dart';
import 'package:haven/src/providers/location_sharing_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/background_burst_coordinator.dart';
import 'package:haven/src/services/circle_change_driver.dart';
import 'package:haven/src/services/mesh_service.dart';
import 'package:haven/src/services/nostr_circle_service.dart';

/// Master switch for the Bluetooth mesh (`docs/BLUETOOTH_MESH_PLAN.md`): an
/// opt-in second carrier for the location events the relay path seals.
///
/// Off unless a build passes `--dart-define=HAVEN_MESH=true`. With it off no
/// Dart code calls a mesh entry, so mesh cannot be turned on, no mesh key is
/// stored and nothing is passed on to a relay. No radio is built yet: with it
/// on, no packet moves between phones either.
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
class MeshNotifier extends AsyncNotifier<MeshStatsFfi?> implements BurstMesh {
  @override
  Future<MeshStatsFfi?> build() async =>
      ref.watch(meshServiceProvider)?.stats();

  /// Turns mesh on for twelve hours from now. Answers whether it is on.
  Future<bool> turnOn() => _started((mesh) => mesh.start());

  /// Restarts the twelve hours. Answers whether mesh is on: after the
  /// deadline it is not, and the only way back is [turnOn].
  Future<bool> keepOn() => _started((mesh) => mesh.keepOn());

  /// Turns mesh off.
  Future<void> turnOff() => _then((mesh) => mesh.stop());

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

  Future<bool> _started(
    Future<MeshStartFfi> Function(MeshService mesh) entry,
  ) async {
    MeshStartFfi? started;
    await _then((mesh) async => started = await entry(mesh));
    return switch (started) {
      MeshStartFfi.started || MeshStartFfi.alreadyOn => true,
      MeshStartFfi.off || null => false,
    };
  }

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
