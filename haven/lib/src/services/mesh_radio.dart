/// The Bluetooth mesh's radio as Dart drives it: the platform service that
/// links the engine to other phones (`docs/BLUETOOTH_MESH_M3_DESIGN.md` §C.1).
///
/// Nothing here names a peer: no Bluetooth address and no count crosses.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Whether the system lets the radio run.
enum MeshRadioPermission {
  /// It does.
  granted,

  /// It does not, and may be asked again.
  denied,

  /// It does not, and only the system's settings can change that.
  deniedForGood,
}

/// What starting the radio did.
enum MeshRadioStart {
  /// The radio is up; with Bluetooth off it waits, paused.
  started,

  /// The system does not let it run.
  noPermission,

  /// This phone cannot run the mesh: it has no radio the mesh can use, or
  /// its Android release is one the mesh does not start on.
  unsupported,

  /// It did not start.
  failed,
}

/// What the radio is doing.
enum MeshRadioState {
  /// Nothing.
  stopped,

  /// Advertising, searching and linking.
  running,

  /// Waiting for Bluetooth to be switched back on.
  paused,
}

/// A tap on one of the radio's notices.
enum MeshRadioAction {
  /// Show what the mesh has done.
  openStats,

  /// Restart the twelve hours.
  keepOn,
}

/// The radio as it reports itself.
class MeshRadioStatus {
  /// A status.
  const MeshRadioStatus({
    required this.state,
    required this.wanted,
    required this.canSearch,
  });

  /// What the radio is doing.
  final MeshRadioState state;

  /// The service's own flag: it was started and has not stopped itself.
  final bool wanted;

  /// `false` where the phone can be found by others and cannot search.
  final bool canSearch;
}

/// The text of the radio's notices, in the language the app renders in: a
/// notice posted while no Dart isolate runs has no other source of words.
class MeshNoticeCopy {
  /// Fixed copy and a time; nothing identifying.
  const MeshNoticeCopy({
    required this.channel,
    required this.on,
    required this.paused,
    required this.reminder,
    required this.keepOn,
    required this.stopped,
  });

  /// The notification channel's name.
  final String channel;

  /// Mesh is on.
  final String on;

  /// Mesh is paused: Bluetooth is off.
  final String paused;

  /// Mesh turns off soon, with the time already formatted.
  final String reminder;

  /// The reminder's action.
  final String keepOn;

  /// Mesh has turned off.
  final String stopped;
}

/// Thrown when the radio could not be asked. Fixed text: what the platform
/// threw is neither shown nor logged (Security Rules 8 and 15).
class MeshRadioException implements Exception {
  /// Creates a mesh radio exception.
  const MeshRadioException();

  @override
  String toString() => 'MeshRadioException: the mesh radio did not answer';
}

/// How long the service is given to answer an entry that asks nobody: a
/// logout, a launch and the mesh's one queue each wait on the radio, and none
/// may wait on a service that never answers.
const Duration kMeshRadioBound = Duration(seconds: 5);

/// How long the system's permission dialog may stay open. A person answers
/// it, so the bound is generous; it exists because an activity recreated
/// under the dialog loses its answer, and the queue would wait for it for the
/// life of the process. Past it the turn-on fails with nothing stored, and
/// what the person then answers is found by the next one.
const Duration kMeshRadioPermissionBound = Duration(minutes: 2);

/// The radio as the app drives it.
///
/// Every entry but [start] throws [MeshRadioException] when it could not be
/// made.
abstract interface class MeshRadio {
  /// Whether this phone can ever run the mesh: asked before anything of the
  /// mesh is drawn, and answered without touching Bluetooth.
  Future<bool> supported();

  /// Whether the system lets the radio run, without asking the user.
  Future<MeshRadioPermission> permission();

  /// Asks the user, through the system's dialog where it still shows one.
  Future<MeshRadioPermission> requestPermission();

  /// Whether Bluetooth is switched on.
  Future<bool> bluetoothOn();

  /// The phone's Bluetooth name, which a linked phone can read. To be shown
  /// to the user and kept nowhere; `null` where it cannot be read.
  Future<String?> bluetoothName();

  /// Opens the system's Bluetooth settings.
  Future<void> openBluetoothSettings();

  /// Starts the radio under the deadline the engine holds. Never throws:
  /// anything that kept it from starting is [MeshRadioStart.failed].
  Future<MeshRadioStart> start(MeshNoticeCopy copy);

  /// The deadline or the language changed: the service reads the deadline
  /// again and takes the new words.
  Future<void> sync(MeshNoticeCopy copy);

  /// Stops the radio and clears what the service kept to come back by
  /// itself.
  Future<void> stop();

  /// The radio now.
  Future<MeshRadioStatus> status();

  /// Every change of [status], as it happens.
  Stream<MeshRadioStatus> get changes;

  /// Every tap on a notice, from the one that opened the app on: the service
  /// holds a tap until it is first listened for here, and hands it to that
  /// listener alone.
  Stream<MeshRadioAction> get actions;
}

/// [MeshRadio] over the Android mesh service's platform channels.
class AndroidMeshRadio implements MeshRadio {
  /// The channels are the process's, so every instance is the same radio.
  const AndroidMeshRadio({
    this.bound = kMeshRadioBound,
    this.permissionBound = kMeshRadioPermissionBound,
  });

  /// How long an entry waits for the service; one that has not answered by
  /// then failed, as one the platform refused did.
  final Duration bound;

  /// [bound] for [requestPermission], which waits on a person.
  final Duration permissionBound;

  /// What the app asks of the service.
  @visibleForTesting
  static const MethodChannel channel = MethodChannel('haven.app/mesh_radio');

  /// What the service tells the app: a status, or the name of an action.
  ///
  /// A message channel, not an `EventChannel`: the one event-channel
  /// subscription under `lib/` is the iOS position stream's
  /// (`check_ios_background_publish.sh`), and this needs no listen call, so
  /// a native end that is missing has nothing to fail. The handler stays
  /// once set: a message that finds no listener is dropped here.
  @visibleForTesting
  static const BasicMessageChannel<Object?> stateChannel = BasicMessageChannel(
    'haven.app/mesh_radio_state',
    StandardMessageCodec(),
  );

  static final StreamController<Object?> _events =
      StreamController<Object?>.broadcast(
        onListen: () => stateChannel.setMessageHandler((event) async {
          _events.add(event);
          return null;
        }),
      );

  static MeshRadioPermission _permission(Object? answer) =>
      MeshRadioPermission.values.byName(answer! as String);

  static MeshRadioStatus _status(Object? answer) {
    final status = answer! as Map<Object?, Object?>;
    return MeshRadioStatus(
      state: MeshRadioState.values.byName(status['state']! as String),
      wanted: status['wanted']! as bool,
      canSearch: status['canSearch']! as bool,
    );
  }

  static MeshRadioAction _action(Object? answer) =>
      MeshRadioAction.values.byName(answer! as String);

  static Map<String, String> _copy(MeshNoticeCopy copy) => {
    'channel': copy.channel,
    'on': copy.on,
    'paused': copy.paused,
    'reminder': copy.reminder,
    'keepOn': copy.keepOn,
    'stopped': copy.stopped,
  };

  /// An event read as [read] reads it, or nothing: the channel carries two
  /// kinds, and one the app cannot read is not an error of the listener's.
  static Iterable<T> _event<T>(Object? event, T Function(Object?) read) {
    try {
      return [read(event)];
    } on Object {
      return const [];
    }
  }

  Future<T> _ask<T>(
    String method,
    T Function(Object? answer) read, {
    Object? arguments,
    Duration? within,
  }) async {
    try {
      return read(
        await channel
            .invokeMethod<Object?>(method, arguments)
            .timeout(within ?? bound),
      );
    } on Object {
      throw const MeshRadioException();
    }
  }

  @override
  Future<bool> supported() => _ask('supported', (can) => can! as bool);

  @override
  Future<MeshRadioPermission> permission() => _ask('permission', _permission);

  @override
  Future<MeshRadioPermission> requestPermission() =>
      _ask('requestPermission', _permission, within: permissionBound);

  @override
  Future<bool> bluetoothOn() => _ask('bluetoothOn', (on) => on! as bool);

  @override
  Future<String?> bluetoothName() =>
      _ask('bluetoothName', (name) => name as String?);

  @override
  Future<void> openBluetoothSettings() => _ask('openBluetoothSettings', (_) {});

  @override
  Future<MeshRadioStart> start(MeshNoticeCopy copy) async {
    try {
      return await _ask(
        'start',
        (started) => MeshRadioStart.values.byName(started! as String),
        arguments: _copy(copy),
      );
    } on MeshRadioException {
      return MeshRadioStart.failed;
    }
  }

  @override
  Future<void> sync(MeshNoticeCopy copy) =>
      _ask('sync', (_) {}, arguments: _copy(copy));

  @override
  Future<void> stop() => _ask('stop', (_) {});

  @override
  Future<MeshRadioStatus> status() => _ask('status', _status);

  @override
  Stream<MeshRadioStatus> get changes =>
      _events.stream.expand((event) => _event(event, _status));

  @override
  Stream<MeshRadioAction> get actions => Stream.multi((listener) {
    // Listening first: a tap made while the question below is on its way is
    // sent, not held, and arrives behind its answer.
    final taps = _events.stream
        .expand((event) => _event(event, _action))
        .listen(listener.addSync);
    listener.onCancel = taps.cancel;
    unawaited(
      _ask('takeAction', (held) => held == null ? null : _action(held)).then(
        (held) {
          if (held != null) listener.add(held);
        },
        // No tap is told for a question that failed: the app opens as it
        // would have from its icon.
        onError: (Object _) {},
      ),
    );
  });
}
