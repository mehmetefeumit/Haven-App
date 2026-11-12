/// The Bluetooth mesh's build flag, service and state.
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:clock/clock.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:haven/src/providers/background_location_provider.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/live_sync_provider.dart';
import 'package:haven/src/providers/locale_provider.dart';
import 'package:haven/src/providers/location_sharing_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/background_burst_coordinator.dart';
import 'package:haven/src/services/circle_change_driver.dart';
import 'package:haven/src/services/mesh_radio.dart';
import 'package:haven/src/services/mesh_service.dart';
import 'package:haven/src/services/nostr_circle_service.dart';

export 'package:haven/src/services/mesh_service.dart' show kMeshIntroSeenKey;

/// Master switch for the Bluetooth mesh (`docs/BLUETOOTH_MESH_PLAN.md`): an
/// opt-in second carrier for the location events the relay path seals.
///
/// Off unless a build passes `--dart-define=HAVEN_MESH=true`. With it off no
/// Dart code calls a mesh entry, so mesh cannot be turned on, no mesh key is
/// stored, nothing is passed on to a relay, and the map has no mesh button,
/// sheet or aura. The radio has no native end yet: with it on, an Android
/// build's turn-on fails and stores nothing, and no packet moves between
/// phones in any build.
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

/// The radio's notices in the language the app renders in. `null` only where
/// a test takes the words away: without them no radio is started — one whose
/// notices say nothing would run unseen — so a turn-on fails before anything
/// is stored.
final meshNoticeCopyProvider = Provider<MeshNoticeCopyOf?>((ref) {
  final l10n = ref.watch(appLocalizationsProvider);
  return (left) => MeshNoticeCopy(
    channel: l10n.meshNoticeChannel,
    on: l10n.meshNoticeOn,
    paused: l10n.meshNoticePaused,
    reminder: l10n.meshNoticeReminder(clock.now().add(left)),
    keepOn: l10n.meshNoticeKeepOn,
    stopped: l10n.meshNoticeStopped,
  );
});


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
/// Every entry of the radio is bounded where the radio is asked
/// ([AndroidMeshRadio]), so one that never answers holds the queue no longer
/// than that.
class MeshNotifier extends AsyncNotifier<MeshStatsFfi?> implements BurstMesh {
  /// The turn-on, turn-off, keep-on or reconcile asked last: the next one
  /// runs behind it.
  Future<void> _last = Future.value();

  /// The reconcile asked whose turn has not come: one asked meanwhile is
  /// this one.
  Future<void>? _owed;

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
    if (ended != MeshTurnOn.on) return ended;
    // Answered from what the transition left: its own closing reconcile turns
    // off a mesh whose radio stopped behind a start that answered.
    final on = _reads;
    if (on ?? false) return MeshTurnOn.on;
    // A mesh that started and cannot be read is turned off again: "it
    // failed" is then true, and no radio runs beside a state that says
    // nothing.
    if (on == null) await turnOff();
    return MeshTurnOn.failed;
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
    // Not kept only where the state says so: one that cannot be read took
    // the new deadline all the same.
    return kept && (_reads ?? true);
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
  /// Runs in its turn, so never in the middle of a transition of the
  /// user's: read there, a turn-off is an engine still on beside a radio
  /// already stopped, and would start the radio again. Never dropped: a
  /// report of the radio that lands behind a transition's own closing
  /// reconcile is the only word of a service that stopped itself. Asked again
  /// before its turn comes, it is the one already waiting.
  Future<void> reconcile() {
    final radio = ref.read(meshRadioProvider);
    if (radio == null) return Future.value();
    return _owed ??= _last = _last.then((_) {
      _owed = null;
      return _then((mesh) => _reconcile(mesh, radio));
    });
  }

  /// Forgets all four counts.
  Future<void> resetCounts() => _then((mesh) => mesh.resetCounts());

  /// The phone's Bluetooth name, to be shown and kept nowhere. `null` where
  /// there is no radio or the name cannot be read. Never throws.
  Future<String?> bluetoothName() async {
    try {
      return await ref.read(meshRadioProvider)?.bluetoothName();
    } on Object {
      return null;
    }
  }

  /// Opens the system's Bluetooth settings. Never throws: settings that did
  /// not open are seen not to have.
  Future<void> openBluetoothSettings() async {
    try {
      await ref.read(meshRadioProvider)?.openBluetoothSettings();
    } on Object catch (_) {
      // See above.
    }
  }

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
    if (ended == MeshTurnOn.unsupported) {
      ref.read(meshUnsupportedProvider.notifier).state = true;
    }
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

  /// Whether mesh is on, as the state reads now; `null` where it does not
  /// read. An error keeps the value of the read before it, which is not a
  /// reading.
  bool? get _reads => switch (state) {
    AsyncData(:final value) => value?.on_ ?? false,
    _ => null,
  };

  /// Runs a transition of the user's in its turn, then a reconcile of its
  /// own: a step that failed half-way reports nothing to bring one.
  Future<void> _transition(
    Future<void> Function(MeshService mesh, MeshRadio? radio) step,
  ) {
    final radio = ref.read(meshRadioProvider);
    return _inTurn((mesh) async {
      try {
        await step(mesh, radio);
      } finally {
        if (radio != null) await _reconcile(mesh, radio);
      }
    });
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

/// Whether this phone's radio answered that it cannot run the mesh. Held
/// for the life of the process and stored nowhere: a phone does not grow the
/// hardware, and a process that forgets asks once more.
final meshUnsupportedProvider = StateProvider<bool>((ref) => false);

/// Whether the mesh is on screen: this build, on this platform, has a radio,
/// and the radio has not answered that this phone cannot use it. Where the
/// mesh button, its sheets, the Settings row and the aura exist.
final meshAvailableProvider = Provider<bool>(
  (ref) =>
      ref.watch(meshRadioProvider) != null &&
      !ref.watch(meshUnsupportedProvider),
);

/// Every tap on one of the radio's notices. One listener takes them all: a
/// second would miss what the service hands over at the first listen.
final meshNoticeTapsProvider = Provider<Stream<MeshRadioAction>>(
  (ref) => ref.watch(meshRadioProvider)?.actions ?? const Stream.empty(),
);

/// The radio as it last reported itself: every report as it is pushed, and a
/// live read beside every read of the engine's state — the shell's start-up,
/// each resume and the end of each transition. `null` where there is no
/// radio and before its first answer.
///
/// A read that fails changes nothing: the map must not say mesh turned off
/// because one question went unanswered. (The reconcile reads the radio for
/// itself, and there a radio that cannot be asked is a radio that stopped.)
/// An answer that lands behind a later read or report is dropped.
final meshRadioStatusProvider =
    NotifierProvider<MeshRadioStatusNotifier, MeshRadioStatus?>(
      MeshRadioStatusNotifier.new,
    );

/// Holds [meshRadioStatusProvider].
class MeshRadioStatusNotifier extends Notifier<MeshRadioStatus?> {
  @override
  MeshRadioStatus? build() {
    final radio = ref.watch(meshRadioProvider);
    if (radio == null) return null;
    // What was asked or reported last: an answer to anything before it is
    // stale. Left past every answer once the provider is rebuilt.
    var latest = 0;
    final changes = radio.changes.listen((status) {
      latest++;
      state = status;
    });
    ref
      ..onDispose(() {
        latest = -1;
        unawaited(changes.cancel());
      })
      ..listen(meshProvider, (_, _) async {
        final asked = ++latest;
        final MeshRadioStatus read;
        try {
          read = await radio.status();
        } on Object {
          return;
        }
        if (asked == latest) state = read;
      }, fireImmediately: true);
    return null;
  }
}

/// When mesh turns itself off, by this device's clock: the time the engine
/// said was left, counted from the read that said it. `null` while the
/// engine is off, and before its first read. A read that fails changes
/// nothing: its state still carries the read before it, whose time left is
/// no longer counted from now.
final meshOnUntilProvider = NotifierProvider<MeshOnUntilNotifier, DateTime?>(
  MeshOnUntilNotifier.new,
);

/// Holds [meshOnUntilProvider].
class MeshOnUntilNotifier extends Notifier<DateTime?> {
  @override
  DateTime? build() {
    ref.listen(meshProvider, (_, read) {
      if (read is AsyncData<MeshStatsFfi?>) state = _until(read.value);
    });
    return switch (ref.read(meshProvider)) {
      AsyncData(:final value) => _until(value),
      _ => null,
    };
  }

  DateTime? _until(MeshStatsFfi? stats) => stats == null || !stats.on_
      ? null
      : clock.now().add(Duration(milliseconds: stats.onForMs.toInt()));
}

/// What the mesh is doing, as the map tells it.
enum MeshPhase {
  /// Off: no radio runs.
  off,

  /// On: the radio is advertising, searching and linking.
  on,

  /// On, with the radio waiting for Bluetooth to be switched back on.
  paused,
}

/// [MeshPhase] now (signal S1 of `docs/BLUETOOTH_MESH_AURA_DESIGN.md` §7).
/// On only while the radio itself reports that it runs, the engine was on
/// when last read, and the deadline has not passed by this device's clock —
/// never inferred from a permission or from Bluetooth being on.
///
/// Nothing pushes a deadline that passes, so a timer of this provider's own
/// reads the clock again then; it asks nothing of the engine. A timer runs
/// late in a process that slept, so the shell invalidates this at a resume:
/// the first frame behind one compares with the clock too.
final meshPhaseProvider = Provider<MeshPhase>((ref) {
  final status = ref.watch(meshRadioStatusProvider);
  if (status == null || status.state == MeshRadioState.stopped) {
    return MeshPhase.off;
  }
  final until = ref.watch(meshOnUntilProvider);
  if (until == null) return MeshPhase.off;
  final left = until.difference(clock.now());
  if (left <= Duration.zero) return MeshPhase.off;
  ref.onDispose(Timer(left, ref.invalidateSelf).cancel);
  return status.state == MeshRadioState.paused
      ? MeshPhase.paused
      : MeshPhase.on;
});

/// How many publish passes handed this device's own location to a mesh that
/// was running with a phone linked (signal S2 of the aura design): what the
/// ripple on the map follows. A count, so that every pass is a change.
final meshHandOffProvider = NotifierProvider<MeshHandOffNotifier, int>(
  MeshHandOffNotifier.new,
);

/// Tells [meshHandOffProvider] that a publish pass handed a location over.
/// Decoration: it is not waited for, and whatever it throws, now or later,
/// stays here — nothing a relay is sent waits on the mesh or fails with it.
void noteMeshHandOff(Ref<Object?> ref) {
  try {
    unawaited(
      ref
          .read(meshHandOffProvider.notifier)
          .handedOff()
          .catchError((Object _) {}),
    );
  } on Object catch (_) {
    // See above.
  }
}

/// Holds [meshHandOffProvider].
class MeshHandOffNotifier extends Notifier<int> {
  @override
  int build() => 0;

  /// A publish pass made a send past the send-time check, where the core
  /// leaves the sealed location for the mesh. It is the hand-off, not the
  /// radio's emission: the packet goes out at the engine's next slot, and
  /// nothing tells Dart which emission was real. Counted only while the
  /// radio runs and, read afresh, a phone is linked. Never throws.
  Future<void> handedOff() async {
    if (ref.read(meshPhaseProvider) != MeshPhase.on) return;
    await ref.read(meshProvider.notifier).refresh();
    if (ref.read(meshProvider).valueOrNull?.linked ?? false) state++;
  }
}
