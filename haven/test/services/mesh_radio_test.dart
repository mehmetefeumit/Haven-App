// The Android mesh radio's platform channels
// (`docs/BLUETOOTH_MESH_M3_DESIGN.md` §C.1).
//
// Four promises:
//
//  * each entry asks the method the native end answers, with the notices'
//    words where it takes them, and reads the answer as its own type;
//  * the channels' names, the methods and the words of every answer are the
//    native end's own, read from its source (`ChannelWords.kt`): one side
//    renamed alone is a call nobody answers;
//  * whatever the platform does instead of answering — no native end, an
//    exception, an answer of another shape — is `failed` for a start and one
//    fixed-text exception for everything else, with nothing of it shown or
//    logged (Security Rules 8 and 15);
//  * the one state channel carries statuses and notice taps, and a message
//    that is neither reaches nobody.
import 'dart:io';

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

  group("the native end's words are this side's", () {
    final words = File(
      'android/app/src/main/kotlin/com/oblivioustech/haven/mesh/core/'
      'ChannelWords.kt',
    ).readAsStringSync();

    /// The value of the Kotlin constant [name].
    String constant(String name) =>
        RegExp('const val $name = "([^"]+)"').firstMatch(words)!.group(1)!;

    /// The strings of the Kotlin list or set [name], or of the enum's
    /// entries where [name] is a class.
    List<String> strings(String name) {
      final body = RegExp(
        '(?:val $name = (?:listOf|setOf)\\(|enum class $name\\b[^{]*\\{)'
        r'([^;]*?)[)}]\s*\n',
        dotAll: true,
      ).firstMatch(words)!.group(1)!;
      return [
        for (final word in RegExp(
          r'"([^"]+)"|\b([A-Z_]{2,})\b(?!\()',
        ).allMatches(body))
          word.group(1) ?? constant(word.group(2)!),
      ];
    }

    test('both channels, and every method the Dart side asks: each is one '
        'the native end lists, and it lists no other', () async {
      expect(constant('METHOD_CHANNEL'), AndroidMeshRadio.channel.name);
      expect(constant('STATE_CHANNEL'), AndroidMeshRadio.stateChannel.name);

      native(
        (call) => switch (call.method) {
          'status' => {'state': 'stopped', 'wanted': false, 'canSearch': true},
          'permission' || 'requestPermission' => 'granted',
          'bluetoothOn' || 'supported' => true,
          'start' => 'started',
          _ => null,
        },
      );
      await radio.supported();
      await radio.permission();
      await radio.requestPermission();
      await radio.bluetoothOn();
      await radio.bluetoothName();
      await radio.openBluetoothSettings();
      await radio.start(meshCopy(Duration.zero));
      await radio.sync(meshCopy(Duration.zero));
      await radio.stop();
      await radio.status();
      final listening = radio.actions.listen((_) {});
      await pumpEventQueue();
      await listening.cancel();

      expect(
        asked.map((call) => call.method).toSet(),
        strings('METHODS').toSet(),
      );
      expect(strings('METHODS'), hasLength(11));
      // The six strings of a start and a sync, by the native end's keys.
      expect(
        (asked.firstWhere((call) => call.method == 'start').arguments as Map)
            .keys,
        unorderedEquals(strings('COPY')),
      );
    });

    test('every word of an answer and of a tap', () {
      expect(
        strings('MeshStart'),
        MeshRadioStart.values.map((start) => start.name),
      );
      expect([
        constant('OPEN_STATS'),
        constant('KEEP_ON'),
      ], MeshRadioAction.values.map((action) => action.name));
      for (final permission in MeshRadioPermission.values) {
        expect(words, contains('"${permission.name}"'));
      }
      for (final state in MeshRadioState.values) {
        expect(words, contains('"${state.name}"'));
      }
      for (final key in ['state', 'wanted', 'canSearch']) {
        expect(words, contains('"$key" to'));
      }
    });
  });

  group('each entry asks its method and reads its answer', () {
    test('whether this phone can run the mesh', () async {
      for (final can in [true, false]) {
        native((_) => can);

        expect(await radio.supported(), can);
      }
      expect(asked.map((call) => call.method).toSet(), {'supported'});
    });

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
      'supported': radio.supported,
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
          radio.supported,
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
          'bluetoothOn' || 'supported' => null,
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

    test('a tap that opened the app reaches the first listener, once, '
        'ahead of the taps that follow', () async {
      final logs = LogCapture.install();
      // The native end: what it holds is handed over once.
      Object? held = 'keepOn';
      native((call) {
        if (call.method != 'takeAction') return null;
        final handed = held;
        held = null;
        return handed;
      });

      final first = <MeshRadioAction>[];
      final listening = [radio.actions.listen(first.add)];
      addTearDown(() => Future.wait([for (final l in listening) l.cancel()]));
      // Sent while the question is still on its way: behind its answer.
      await emit('openStats');
      await pumpEventQueue();

      expect(first, [MeshRadioAction.keepOn, MeshRadioAction.openStats]);

      final second = <MeshRadioAction>[];
      listening.add(radio.actions.listen(second.add));
      await pumpEventQueue();
      await emit('keepOn');
      await pumpEventQueue();

      expect(second, [MeshRadioAction.keepOn]);
      expect(first, [
        MeshRadioAction.keepOn,
        MeshRadioAction.openStats,
        MeshRadioAction.keepOn,
      ]);
      expect(asked.map((call) => call.method), ['takeAction', 'takeAction']);
      expect(logs.lines, isEmpty);
    });

    test(
      'a held tap that cannot be asked for, or is no tap, is none: the '
      'taps that follow still arrive, and nothing is thrown or logged',
      () async {
        for (final answer in <Object? Function(MethodCall)>[
          (_) => throw PlatformException(code: _address, message: _address),
          (_) => 'sideways',
          (_) => 7,
        ]) {
          final logs = LogCapture.install();
          native(answer);
          final actions = <MeshRadioAction>[];
          final listening = radio.actions.listen(actions.add);

          await pumpEventQueue();
          await emit('openStats');
          await pumpEventQueue();

          expect(actions, [MeshRadioAction.openStats]);
          expect(logs.lines, isEmpty);
          await listening.cancel();
          logs.restore();
        }
      },
    );

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
