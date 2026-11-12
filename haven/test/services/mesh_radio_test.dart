// The Android mesh radio's platform channels
// (`docs/BLUETOOTH_MESH_M3_DESIGN.md` §C.1).
//
// Three promises:
//
//  * each entry asks the method the native end answers, with the notices'
//    words where it takes them, and reads the answer as its own type;
//  * whatever the platform does instead of answering — no native end, an
//    exception, an answer of another shape — is `failed` for a start and one
//    fixed-text exception for everything else, with nothing of it shown or
//    logged (Security Rules 8 and 15);
//  * the one state channel carries statuses and notice taps, and a message
//    that is neither reaches nobody.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/services/mesh_radio.dart';

import '../helpers/fake_mesh.dart';
import '../helpers/log_capture.dart';

/// A peer's Bluetooth address, as a platform error might carry one.
const _address = 'AA:BB:CC:DD:EE:FF';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const radio = AndroidMeshRadio();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final asked = <MethodCall>[];

  /// The native end: [answer] for every method.
  void native(Object? Function(MethodCall call) answer) {
    messenger.setMockMethodCallHandler(AndroidMeshRadio.channel, (call) async {
      asked.add(call);
      return answer(call);
    });
  }

  tearDown(() {
    messenger.setMockMethodCallHandler(AndroidMeshRadio.channel, null);
    asked.clear();
  });

  /// Delivers [event] on the state channel, as the engine would.
  Future<void> emit(Object? event) => messenger.handlePlatformMessage(
    AndroidMeshRadio.stateChannel.name,
    AndroidMeshRadio.stateChannel.codec.encodeMessage(event),
    null,
  );

  test('the channels are named as the native end names them', () {
    expect(AndroidMeshRadio.channel.name, 'haven.app/mesh_radio');
    expect(AndroidMeshRadio.stateChannel.name, 'haven.app/mesh_radio_state');
  });

  group('each entry asks its method and reads its answer', () {
    test('the permission, asked for and not', () async {
      for (final permission in MeshRadioPermission.values) {
        native((_) => permission.name);

        expect(await radio.permission(), permission);
        expect(await radio.requestPermission(), permission);
      }
      expect(asked.map((call) => call.method).toSet(), {
        'permission',
        'requestPermission',
      });
    });

    test('whether Bluetooth is on, its name, and its settings', () async {
      native(
        (call) => switch (call.method) {
          'bluetoothOn' => true,
          'bluetoothName' => 'a phone',
          _ => null,
        },
      );

      expect(await radio.bluetoothOn(), isTrue);
      expect(await radio.bluetoothName(), 'a phone');
      await radio.openBluetoothSettings();

      expect(asked.map((call) => call.method), [
        'bluetoothOn',
        'bluetoothName',
        'openBluetoothSettings',
      ]);
    });

    test('a Bluetooth name that cannot be read is none', () async {
      native((_) => null);

      expect(await radio.bluetoothName(), isNull);
    });

    test("a start and a sync carry the notices' six strings", () async {
      for (final started in MeshRadioStart.values) {
        native((_) => started.name);

        expect(
          await radio.start(meshCopy(const Duration(minutes: 5))),
          started,
        );
      }
      native((_) => null);
      await radio.sync(meshCopy(const Duration(minutes: 7)));

      const words = {
        'channel': 'channel',
        'on': 'on',
        'paused': 'paused',
        'keepOn': 'keep on',
        'stopped': 'stopped',
      };
      expect(asked.last.method, 'sync');
      expect(asked.last.arguments, {...words, 'reminder': 'off in 420000'});
      expect(asked.first.method, 'start');
      expect(asked.first.arguments, {...words, 'reminder': 'off in 300000'});
    });

    test('a stop, and the status with each of its three words', () async {
      for (final state in MeshRadioState.values) {
        native(
          (call) => call.method == 'status'
              ? {'state': state.name, 'wanted': true, 'canSearch': false}
              : null,
        );

        await radio.stop();
        final status = await radio.status();

        expect(status.state, state);
        expect(status.wanted, isTrue);
        expect(status.canSearch, isFalse);
      }
      expect(asked.map((call) => call.method).toSet(), {'stop', 'status'});
    });
  });

  group('a platform that does not answer', () {
    /// Every entry but `start`, each made once.
    Map<String, Future<Object?> Function()> entries() => {
      'permission': radio.permission,
      'requestPermission': radio.requestPermission,
      'bluetoothOn': radio.bluetoothOn,
      'bluetoothName': radio.bluetoothName,
      'openBluetoothSettings': radio.openBluetoothSettings,
      'sync': () => radio.sync(meshCopy(Duration.zero)),
      'stop': radio.stop,
      'status': radio.status,
    };

    Future<void> failsFixed({required String reason}) async {
      final logs = LogCapture.install();

      expect(
        await radio.start(meshCopy(Duration.zero)),
        MeshRadioStart.failed,
        reason: reason,
      );
      for (final MapEntry(key: name, value: entry) in entries().entries) {
        await expectLater(
          entry(),
          throwsA(
            isA<MeshRadioException>().having(
              (e) => '$e',
              'text',
              'MeshRadioException: the mesh radio did not answer',
            ),
          ),
          reason: '$reason: $name',
        );
      }
      expect(logs.lines, isEmpty, reason: reason);
    }

    test('with no native end: a start is failed, every other entry one '
        'fixed-text exception', () async {
      // No handler: every call is a `MissingPluginException`.
      await failsFixed(reason: 'no native end');
    });

    test('with an exception that names a peer: the same, and nothing of it '
        'is shown or logged', () async {
      native(
        (_) => throw PlatformException(
          code: _address,
          message: 'link to $_address lost',
          details: _address,
        ),
      );

      await failsFixed(reason: 'platform exception');
    });

    test('with an answer of another shape: the same, for every entry that '
        'reads one', () async {
      Future<void> unread(Object? Function(MethodCall call) answer) async {
        native(answer);
        for (final entry in [
          radio.permission,
          radio.requestPermission,
          radio.bluetoothOn,
          radio.status,
        ]) {
          await expectLater(entry(), throwsA(isA<MeshRadioException>()));
        }
        expect(
          await radio.start(meshCopy(Duration.zero)),
          MeshRadioStart.failed,
        );
      }

      await unread((_) => 7);
      await expectLater(
        radio.bluetoothName(),
        throwsA(isA<MeshRadioException>()),
      );
      // The right type, and a word nobody knows.
      await unread(
        (call) => switch (call.method) {
          'status' => {'state': 'sideways', 'wanted': true, 'canSearch': true},
          'bluetoothOn' => null,
          _ => 'sideways',
        },
      );
    });
  });

  group('the state channel', () {
    test('carries statuses to `changes` and taps to `actions`, each to its '
        'own, and what is neither to nobody', () async {
      final logs = LogCapture.install();
      final changes = <MeshRadioStatus>[];
      final actions = <MeshRadioAction>[];
      final listening = [
        radio.changes.listen(changes.add),
        radio.actions.listen(actions.add),
      ];
      addTearDown(() => Future.wait([for (final l in listening) l.cancel()]));

      await emit({'state': 'running', 'wanted': true, 'canSearch': true});
      await emit('keepOn');
      await emit({'state': 'paused', 'wanted': true, 'canSearch': false});
      await emit('openStats');
      // Neither a status nor a tap, in five shapes.
      await emit({'state': 'sideways', 'wanted': true, 'canSearch': true});
      await emit({'state': 'running'});
      await emit('sideways');
      await emit(7);
      await emit(null);
      await emit({'state': 'stopped', 'wanted': false, 'canSearch': true});
      await pumpEventQueue();

      expect(changes.map((status) => status.state), [
        MeshRadioState.running,
        MeshRadioState.paused,
        MeshRadioState.stopped,
      ]);
      expect(changes.map((status) => status.wanted), [true, true, false]);
      expect(changes.map((status) => status.canSearch), [true, false, true]);
      expect(actions, [MeshRadioAction.keepOn, MeshRadioAction.openStats]);
      expect(logs.lines, isEmpty);
    });

    test('with nobody listening a message is dropped, and reaches no later '
        'listener', () async {
      final first = radio.changes.listen((_) {});
      await first.cancel();

      await emit({'state': 'running', 'wanted': true, 'canSearch': true});
      final changes = <MeshRadioStatus>[];
      final later = radio.changes.listen(changes.add);
      addTearDown(later.cancel);
      await emit({'state': 'paused', 'wanted': true, 'canSearch': true});
      await pumpEventQueue();

      expect(changes.map((status) => status.state), [MeshRadioState.paused]);
    });
  });
}
