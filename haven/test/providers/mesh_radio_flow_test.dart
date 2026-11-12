// Turning the Bluetooth mesh on, off and keeping it on where the platform has
// a radio, and the reconcile between the engine and the radio
// (`docs/BLUETOOTH_MESH_M3_DESIGN.md` §C.2–§C.5).
//
// The promises:
//
//  * mesh is on only with both its engine and its radio: nothing is stored
//    before every step that can refuse without it has passed, and a radio
//    that does not start takes the keys back;
//  * turning off stops the radio first and the engine whatever the radio did;
//  * a turn-on, a turn-off, a keep-on and a reconcile run one at a time, in
//    the order asked: a reconcile asked in the middle of one runs behind it,
//    once however often it was asked — so a radio's own report can never
//    undo what the user is doing, and none is lost;
//  * a turn-on and a keep-on answer from what they left, their own closing
//    reconcile included;
//  * no entry of the radio is waited for past its bound: a service that
//    never answers costs a turn-off, a logout and a launch that bound and
//    nothing else;
//  * a reconcile does what its table says from what the two report, asks a
//    radio that will not come back once, and never undoes a stop the service
//    made;
//  * a logout, and the retry of its wipe, stop the radio before the wipe;
//  * with the flag off, or on a platform with no radio, no radio channel is
//    touched and the mesh is driven as it is without one;
//  * nothing of any of it is logged.
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/background_location_provider.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/mesh_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/mesh_radio.dart';
import 'package:haven/src/services/pending_mls_wipe_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_mesh.dart';
import '../helpers/log_capture.dart';
import '../mocks/mock_circle_service.dart';

/// A peer's Bluetooth address and a phone's Bluetooth name, planted where a
/// log line could pick them up.
const _address = 'AA:BB:CC:DD:EE:FF';
const _name = "Ada's Pixel 9";

/// A reconcile that read both and found nothing to do.
const _agreed = ['mesh.stats', 'radio.status'];

/// The state read that ends every turn of the queue.
const _read = ['mesh.stats'];

/// What a turn-on asks before anything is stored.
const _asked = ['radio.requestPermission', 'radio.bluetoothOn'];

class _Mesh {
  _Mesh({bool words = true}) {
    mesh.journal = journal;
    radio.journal = journal;
    container = ProviderContainer(
      overrides: [
        meshServiceProvider.overrideWithValue(mesh),
        meshRadioProvider.overrideWithValue(radio),
        meshNoticeCopyProvider.overrideWithValue(words ? meshCopy : null),
      ],
    );
    addTearDown(container.dispose);
  }

  final journal = <String>[];
  final mesh = FakeMeshService();
  final radio = FakeMeshRadio();
  late final ProviderContainer container;

  MeshNotifier get notifier => container.read(meshProvider.notifier);

  MeshStatsFfi get state => container.read(meshProvider).requireValue!;

  bool get stoppedNotice => container.read(meshStoppedNoticeProvider);

  int count(String call) => journal.where((made) => made == call).length;

  /// The provider built and its first read made, with nothing journalled.
  Future<void> built() async {
    await container.read(meshProvider.future);
    journal.clear();
  }

  /// Mesh on with its radio running, as a turn-on leaves them.
  Future<void> on() async {
    mesh.statsAnswer = meshState(on: true);
    radio.statusAnswer = radioStatus(MeshRadioState.running, wanted: true);
    await built();
  }
}

class _Identity implements IdentityService {
  @override
  Future<Identity?> getIdentity() async => null;

  @override
  Future<void> deleteIdentity() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected call: ${invocation.memberName}');
}

/// A circle service whose wipe, and the first and last of a logout's steps
/// ahead of it, are written into the radio's journal.
class _Circles extends MockCircleService {
  _Circles(this.journal);

  final List<String> journal;

  @override
  Future<void> resetAllSyncCursors() {
    journal.add('cursors');
    return super.resetAllSyncCursors();
  }

  @override
  Future<void> closeAndInvalidate() {
    journal.add('close');
    return super.closeAndInvalidate();
  }

  @override
  Future<void> wipeAllMlsState() {
    journal.add('wipe');
    return super.wipeAllMlsState();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('turning on', () {
    test('mesh is on only when both started: the engine, then the radio '
        "under the engine's deadline", () async {
      final t = _Mesh()..mesh.startsForMs = 43200000;
      await t.built();

      expect(await t.notifier.turnOn(), MeshTurnOn.on);

      expect(t.journal, [
        ..._asked,
        'mesh.start',
        'mesh.stats',
        'radio.start',
        ..._agreed,
        ..._read,
      ]);
      expect(t.radio.copies.single.reminder, 'off in 43200000');
      expect(t.state.on_, isTrue);
      expect(t.radio.statusAnswer.state, MeshRadioState.running);
      expect(t.stoppedNotice, isFalse);
    });

    test('a refused permission stores nothing', () async {
      for (final (refusal, ended) in [
        (MeshRadioPermission.denied, MeshTurnOn.noPermission),
        (MeshRadioPermission.deniedForGood, MeshTurnOn.noPermissionForGood),
      ]) {
        final t = _Mesh()..radio.permissionAnswer = refusal;
        await t.built();

        expect(await t.notifier.turnOn(), ended);

        expect(t.journal, [
          'radio.requestPermission',
          ..._agreed,
          ..._read,
        ], reason: '$refusal');
        expect(t.state.on_, isFalse);
      }
    });

    test('backing out, once the permission is held and before Bluetooth is '
        'asked, stores nothing', () async {
      final t = _Mesh();
      await t.built();

      final ended = await t.notifier.turnOn(
        confirm: () async {
          t.journal.add('confirm');
          return false;
        },
      );

      expect(ended, MeshTurnOn.cancelled);
      expect(t.journal, [
        'radio.requestPermission',
        'confirm',
        ..._agreed,
        ..._read,
      ]);
    });

    test('a confirmation given goes on to turn mesh on', () async {
      final t = _Mesh();
      await t.built();

      expect(await t.notifier.turnOn(confirm: () async => true), MeshTurnOn.on);
      expect(t.journal, containsAllInOrder(['mesh.start', 'radio.start']));
    });

    test('Bluetooth off stores nothing', () async {
      final t = _Mesh()..radio.bluetoothOnAnswer = false;
      await t.built();

      expect(await t.notifier.turnOn(), MeshTurnOn.bluetoothOff);

      expect(t.journal, [..._asked, ..._agreed, ..._read]);
      expect(t.state.on_, isFalse);
    });

    test('a radio that cannot be asked, or a confirmation that throws, '
        'stores nothing', () async {
      for (final entry in ['requestPermission', 'bluetoothOn', 'confirm']) {
        final t = _Mesh()..radio.throws[entry] = StateError(_address);
        await t.built();

        final ended = await t.notifier.turnOn(
          confirm: () async =>
              entry == 'confirm' ? throw StateError(_name) : true,
        );

        expect(ended, MeshTurnOn.failed, reason: entry);
        expect(t.journal, isNot(contains('mesh.start')), reason: entry);
        expect(t.journal, isNot(contains('radio.start')), reason: entry);
      }
    });

    test('with no words for its notices, nothing is asked and nothing '
        'stored', () async {
      final t = _Mesh(words: false);
      await t.built();

      expect(await t.notifier.turnOn(), MeshTurnOn.failed);

      expect(t.journal, [..._agreed, ..._read]);
    });

    test('an engine that does not start leaves the radio unasked', () async {
      final refused = _Mesh()..mesh.startAnswer = MeshStartFfi.off;
      await refused.built();

      expect(await refused.notifier.turnOn(), MeshTurnOn.failed);
      expect(refused.journal, [..._asked, 'mesh.start', ..._agreed, ..._read]);

      final threw = _Mesh()..mesh.throws['start'] = StateError('group 0xdead');
      await threw.built();

      expect(await threw.notifier.turnOn(), MeshTurnOn.failed);
      expect(threw.journal, [..._asked, 'mesh.start', ..._agreed]);
      expect(threw.container.read(meshProvider).hasError, isTrue);
    });

    test('a radio that does not start takes the keys back: the radio is '
        'stopped, then the engine, once', () async {
      for (final (answer, ended) in [
        (MeshRadioStart.noPermission, MeshTurnOn.noPermission),
        (MeshRadioStart.unsupported, MeshTurnOn.unsupported),
        (MeshRadioStart.failed, MeshTurnOn.failed),
      ]) {
        final t = _Mesh()..radio.startAnswer = answer;
        await t.built();

        expect(await t.notifier.turnOn(), ended);

        expect(t.journal, [
          ..._asked,
          'mesh.start',
          'mesh.stats',
          'radio.start',
          'radio.stop',
          'mesh.stop',
          ..._agreed,
          ..._read,
        ], reason: '$answer');
        expect(t.state.on_, isFalse, reason: '$answer');
        expect(t.stoppedNotice, isFalse, reason: 'the user saw it fail');
      }
    });

    test('a start that throws, and a deadline that cannot be read for its '
        'notices, take the keys back too', () async {
      final threw = _Mesh()..radio.throws['start'] = StateError(_address);
      await threw.built();

      expect(await threw.notifier.turnOn(), MeshTurnOn.failed);
      expect(threw.count('mesh.stop'), 1);
      expect(threw.state.on_, isFalse);

      final unread = _Mesh();
      await unread.built();
      final start = Completer<void>();
      unread.mesh.held['start'] = start.future;
      final turnOn = unread.notifier.turnOn();
      await unread.mesh.reached('start');
      unread.mesh.throws['stats'] = StateError('group 0xdead');
      start.complete();

      expect(await turnOn, MeshTurnOn.failed);
      expect(unread.journal, isNot(contains('radio.start')));
      expect(unread.count('mesh.stop'), 1);
    });

    test('an unwind that failed leaves the keys to the next reconcile, '
        'which takes them and says so', () async {
      final t = _Mesh()
        ..radio.startAnswer = MeshRadioStart.failed
        ..mesh.throws['stop'] = StateError('group 0xdead');
      await t.built();

      expect(await t.notifier.turnOn(), MeshTurnOn.failed);

      // The unwind, and the reconcile the turn-on ended with, both failed.
      expect(t.count('mesh.stop'), 2);
      expect(t.state.on_, isTrue);
      expect(t.stoppedNotice, isFalse, reason: 'mesh is not off yet');
      expect(t.count('radio.start'), 1);

      t.mesh.throws.clear();
      await t.notifier.reconcile();

      expect(t.count('mesh.stop'), 3);
      expect(t.count('radio.start'), 1);
      expect(t.state.on_, isFalse);
      expect(t.stoppedNotice, isTrue);
    });
  });

  group('turning off', () {
    test('stops the radio first, and the engine regardless', () async {
      final t = _Mesh();
      await t.on();

      await t.notifier.turnOff();

      expect(t.journal, ['radio.stop', 'mesh.stop', ..._agreed, ..._read]);
      expect(t.state.on_, isFalse);
      expect(t.stoppedNotice, isFalse, reason: "the user's own stop");

      final deaf = _Mesh()..radio.throws['stop'] = StateError(_address);
      await deaf.on();

      await deaf.notifier.turnOff();

      expect(deaf.journal.take(2), ['radio.stop', 'mesh.stop']);
      expect(deaf.state.on_, isFalse);
    });

    test('an engine that would not stop is the state, and the keys are left '
        'to a reconcile', () async {
      final t = _Mesh()..mesh.throws['stop'] = StateError('group 0xdead');
      await t.on();

      await t.notifier.turnOff();

      expect(t.container.read(meshProvider).hasError, isTrue);
      expect(t.stoppedNotice, isFalse);

      t.mesh.throws.clear();
      await t.notifier.reconcile();

      expect(t.state.on_, isFalse);
      expect(t.journal, isNot(contains('radio.start')));
    });
  });

  group('keeping on', () {
    test('tells the service the new deadline, after the engine took '
        'it', () async {
      final t = _Mesh();
      await t.on();
      t.mesh.statsAnswer = meshState(on: true, onForMs: 43200000);

      expect(await t.notifier.keepOn(), isTrue);

      expect(t.journal, [
        'mesh.keepOn',
        'mesh.stats',
        'radio.sync',
        ..._agreed,
        ..._read,
      ]);
      expect(t.radio.copies.single.reminder, 'off in 43200000');
    });

    test('after the deadline tells the service nothing, and the radio left '
        'running is stopped', () async {
      final t = _Mesh()..mesh.keepOnAnswer = MeshStartFfi.off;
      await t.on();
      t.mesh.statsAnswer = meshState();

      expect(await t.notifier.keepOn(), isFalse);

      expect(t.journal, [
        'mesh.keepOn',
        'mesh.stats',
        'radio.status',
        'radio.stop',
        'mesh.stop',
        ..._read,
      ]);
    });

    test('a service that could not be told costs the keep-on '
        'nothing', () async {
      final t = _Mesh()..radio.throws['sync'] = StateError(_address);
      await t.on();

      expect(await t.notifier.keepOn(), isTrue);
      expect(t.state.on_, isTrue);
      expect(t.journal, isNot(contains('mesh.stop')));
    });
  });

  group('one at a time', () {
    test('a stopped event in the middle of a turn-off starts '
        'nothing', () async {
      final t = _Mesh();
      await t.on();
      final stop = Completer<void>();
      t.mesh.held['stop'] = stop.future;

      final turnOff = t.notifier.turnOff();
      await t.mesh.reached('stop');
      // The radio has stopped and the engine has not: read now, this is an
      // engine on beside a radio that stopped and is still wanted.
      t.radio.emit(radioStatus(MeshRadioState.stopped, wanted: true));
      await pumpEventQueue();

      expect(t.journal, ['radio.stop', 'mesh.stop']);

      stop.complete();
      await turnOff;
      await pumpEventQueue();

      // The turn-off's own reconcile, then the one the report asked for:
      // both find the two agreed.
      expect(t.journal, [
        'radio.stop',
        'mesh.stop',
        ..._agreed,
        ..._read,
        ..._agreed,
        ..._read,
      ]);
      expect(t.state.on_, isFalse);
      expect(t.stoppedNotice, isFalse);
    });

    test('a running event in the middle of a turn-on stops nothing', () async {
      final t = _Mesh();
      await t.built();
      final start = Completer<void>();
      t.mesh.held['start'] = start.future;

      final turnOn = t.notifier.turnOn();
      await t.mesh.reached('start');
      // The engine is not on yet: read now, this is a radio running beside
      // an engine that is off.
      t.radio.emit(radioStatus(MeshRadioState.running, wanted: true));
      await pumpEventQueue();

      expect(t.journal, [..._asked, 'mesh.start']);

      start.complete();
      expect(await turnOn, MeshTurnOn.on);
      await pumpEventQueue();

      expect(t.journal, isNot(contains('radio.stop')));
      expect(t.journal, isNot(contains('mesh.stop')));
      expect(t.state.on_, isTrue);
    });

    test('a reconcile asked while a transition waits its turn runs behind '
        'it, once however often it was asked', () async {
      final t = _Mesh();
      await t.on();
      final status = Completer<void>();
      t.radio.held['status'] = status.future;

      final reconcile = t.notifier.reconcile();
      await t.radio.reached('status');
      final turnOff = t.notifier.turnOff();
      t.radio.emit(radioStatus(MeshRadioState.running, wanted: true));
      final asked = t.notifier.reconcile();
      status.complete();
      await Future.wait([reconcile, turnOff, asked]);
      await pumpEventQueue();

      expect(t.journal, [
        ..._agreed,
        ..._read,
        'radio.stop',
        'mesh.stop',
        ..._agreed,
        ..._read,
        ..._agreed,
        ..._read,
      ]);
      expect(t.journal, isNot(contains('radio.start')));
    });

    test("a report that lands behind a transition's own closing reconcile "
        'is not lost: a service that stopped itself behind a start that '
        'answered takes the engine with it, with the notice', () async {
      final t = _Mesh();
      await t.built();
      final turnOn = t.notifier.turnOn();
      // The closing reconcile has read the radio: what it reports from here
      // on, that reconcile does not see.
      await t.radio.reached('status');
      final released = Completer<void>();
      t.mesh.held['stats'] = released.future;
      t.radio.emit(radioStatus(MeshRadioState.stopped));
      await pumpEventQueue();
      expect(t.journal, isNot(contains('mesh.stop')));

      released.complete();
      unawaited(t.mesh.held.remove('stats'));
      await turnOn;
      await pumpEventQueue();

      expect(t.count('mesh.stop'), 1);
      expect(t.count('radio.start'), 1);
      expect(t.state.on_, isFalse);
      expect(t.stoppedNotice, isTrue);
    });

    test('a turn-on answers from what it left: one whose radio had stopped '
        'by its own closing reconcile did not turn mesh on', () async {
      final t = _Mesh();
      await t.built();
      final turnOn = t.notifier.turnOn();
      await t.radio.reached('start');
      // The start answers, and the service then stops itself.
      t.radio.statusAnswer = radioStatus(MeshRadioState.stopped);

      expect(await turnOn, MeshTurnOn.failed);
      expect(t.state.on_, isFalse);
      expect(t.count('mesh.stop'), 1);
    });

    test('a turn-on that started and then cannot be read turns mesh off '
        'again, so that "it failed" is true: never a failure beside a radio '
        'that runs', () async {
      final t = _Mesh();
      await t.built();
      final turnOn = t.notifier.turnOn();
      // The closing reconcile has read both; the read that ends the turn
      // fails, and so does every one after it.
      await t.radio.reached('status');
      t.mesh.throws['stats'] = StateError('link to $_address lost');

      expect(await turnOn, MeshTurnOn.failed);

      expect(t.journal, containsAllInOrder(['radio.start', 'radio.stop']));
      expect(t.count('mesh.stop'), 1);
      expect(t.radio.statusAnswer.state, MeshRadioState.stopped);
      t.mesh.throws.clear();
      await t.notifier.refresh();
      expect(t.state.on_, isFalse);
    });

    test('a keep-on that cannot be read afterwards was kept all the '
        'same', () async {
      final t = _Mesh();
      await t.on();
      final keepOn = t.notifier.keepOn();
      await t.radio.reached('status');
      t.mesh.throws['stats'] = StateError('link to $_address lost');

      expect(await keepOn, isTrue);
      expect(t.journal, isNot(contains('mesh.stop')));
    });

    test('a keep-on answers from what it left', () async {
      final t = _Mesh();
      await t.on();
      final keepOn = t.notifier.keepOn();
      await t.radio.reached('sync');
      t.radio.statusAnswer = radioStatus(MeshRadioState.stopped);

      expect(await keepOn, isFalse);
      expect(t.state.on_, isFalse);
    });

    test('transitions run in the order asked, each whole before the '
        'next', () async {
      final t = _Mesh();
      await t.built();
      final start = Completer<void>();
      t.mesh.held['start'] = start.future;

      final turnOn = t.notifier.turnOn();
      final keepOn = t.notifier.keepOn();
      final turnOff = t.notifier.turnOff();
      await t.mesh.reached('start');
      await pumpEventQueue();
      expect(t.journal, [..._asked, 'mesh.start']);
      start.complete();

      expect(await turnOn, MeshTurnOn.on);
      expect(await keepOn, isTrue);
      await turnOff;

      expect(t.journal, [
        ..._asked,
        'mesh.start',
        'mesh.stats',
        'radio.start',
        ..._agreed,
        ..._read,
        'mesh.keepOn',
        'mesh.stats',
        'radio.sync',
        ..._agreed,
        ..._read,
        'radio.stop',
        'mesh.stop',
        ..._agreed,
        ..._read,
      ]);
    });

    test('a rebuilt provider listens to the radio once', () async {
      final t = _Mesh();
      await t.on();
      t.container.invalidate(meshProvider);
      await t.built();

      t.radio.emit(radioStatus(MeshRadioState.running, wanted: true));
      await pumpEventQueue();

      expect(t.journal, [..._agreed, ..._read]);
    });
  });

  group('a reconcile', () {
    const on = true;
    const off = false;
    const granted = MeshRadioPermission.granted;
    const denied = MeshRadioPermission.denied;
    const stopped = MeshRadioState.stopped;
    const running = MeshRadioState.running;
    const paused = MeshRadioState.paused;
    const restart = ['radio.permission', 'mesh.stats', 'radio.start'];
    const turnOff = ['radio.stop', 'mesh.stop'];

    test('is this table', () async {
      for (final (store, radio, wanted, permission, does, notice) in [
        (on, running, true, granted, <String>[], false),
        (on, paused, true, granted, <String>[], false),
        (on, stopped, true, granted, restart, false),
        (on, stopped, true, denied, ['radio.permission', ...turnOff], true),
        (on, stopped, false, granted, turnOff, true),
        (off, running, true, granted, turnOff, false),
        (off, paused, true, granted, turnOff, false),
        (off, stopped, true, granted, <String>[], false),
        (off, stopped, false, granted, <String>[], false),
      ]) {
        final row = '$store, $radio, wanted $wanted, $permission';
        final t = _Mesh()
          ..mesh.statsAnswer = meshState(on: store)
          ..radio.statusAnswer = radioStatus(radio, wanted: wanted)
          ..radio.permissionAnswer = permission;
        await t.built();

        await t.notifier.reconcile();

        expect(t.journal, [..._agreed, ...does, ..._read], reason: row);
        expect(t.stoppedNotice, notice, reason: row);
        expect(t.state.on_, store && !notice, reason: row);
      }
    });

    test('of an engine that cannot be read does nothing, whatever the radio '
        'says', () async {
      for (final radio in MeshRadioState.values) {
        final t = _Mesh()
          ..radio.statusAnswer = radioStatus(radio, wanted: true);
        await t.built();
        t.mesh.throws['stats'] = StateError('group 0xdead');

        await t.notifier.reconcile();

        expect(t.journal, ['mesh.stats', 'mesh.stats'], reason: '$radio');
        expect(t.stoppedNotice, isFalse, reason: '$radio');
      }
    });

    test('of a radio that cannot be asked turns an engine that is on off, '
        'and leaves one that is off alone', () async {
      final t = _Mesh()
        ..mesh.statsAnswer = meshState(on: true)
        ..radio.throws['status'] = StateError(_address);
      await t.built();

      await t.notifier.reconcile();

      expect(t.journal, [..._agreed, 'radio.stop', 'mesh.stop', ..._read]);
      expect(t.stoppedNotice, isTrue);

      final quiet = _Mesh()..radio.throws['status'] = StateError(_address);
      await quiet.built();

      await quiet.notifier.reconcile();

      expect(quiet.journal, [..._agreed, ..._read]);
    });

    test('runs on every report of the radio', () async {
      final t = _Mesh()..mesh.statsAnswer = meshState(on: true);
      await t.built();

      t.radio.emit(radioStatus(MeshRadioState.running, wanted: true));
      await pumpEventQueue();
      t.radio.emit(radioStatus(MeshRadioState.paused, wanted: true));
      await pumpEventQueue();

      expect(t.journal, [..._agreed, ..._read, ..._agreed, ..._read]);
    });

    test('asks a radio that will not come back once, and mesh goes off with '
        'one notice, whatever reports follow', () async {
      final t = _Mesh()
        ..mesh.statsAnswer = meshState(on: true)
        ..radio.startAnswer = MeshRadioStart.failed;
      await t.built();
      final notices = <bool>[];
      t.container.listen(meshStoppedNoticeProvider, (_, set) {
        notices.add(set);
      });

      for (var report = 0; report < 4; report++) {
        t.radio.emit(radioStatus(MeshRadioState.stopped, wanted: true));
        await pumpEventQueue();
      }

      expect(t.count('radio.start'), 1);
      expect(t.count('mesh.stop'), 1);
      expect(notices, [true]);
      expect(t.state.on_, isFalse);
    });

    test('gives back a radio the service still wants, under the '
        "engine's deadline", () async {
      final t = _Mesh()
        ..mesh.statsAnswer = meshState(on: true, onForMs: 600000)
        ..radio.statusAnswer = radioStatus(
          MeshRadioState.stopped,
          wanted: true,
        );
      await t.built();

      await t.notifier.reconcile();

      expect(t.radio.copies.single.reminder, 'off in 600000');
      expect(t.radio.statusAnswer.state, MeshRadioState.running);
      expect(t.journal, isNot(contains('mesh.stop')));
      expect(t.state.on_, isTrue);
    });

    test('does not undo a stop the service made', () async {
      final t = _Mesh()..mesh.statsAnswer = meshState(on: true);
      await t.built();

      t.radio.emit(radioStatus(MeshRadioState.stopped));
      await pumpEventQueue();

      expect(t.journal, isNot(contains('radio.start')));
      expect(t.count('mesh.stop'), 1);
      expect(t.state.on_, isFalse);
      expect(t.stoppedNotice, isTrue);
    });

    test('takes the keys of an engine that went, with its radio', () async {
      final t = _Mesh()
        ..radio.statusAnswer = radioStatus(
          MeshRadioState.running,
          wanted: true,
        );
      await t.built();

      await t.notifier.reconcile();

      expect(t.journal, [..._agreed, 'radio.stop', 'mesh.stop', ..._read]);
      expect(t.stoppedNotice, isFalse);
    });

    test('with no words for the notices cannot give a radio back, and mesh '
        'goes off', () async {
      final t = _Mesh(words: false)
        ..mesh.statsAnswer = meshState(on: true)
        ..radio.statusAnswer = radioStatus(
          MeshRadioState.stopped,
          wanted: true,
        );
      await t.built();

      await t.notifier.reconcile();

      expect(t.journal, isNot(contains('radio.start')));
      expect(t.state.on_, isFalse);
      expect(t.stoppedNotice, isTrue);
    });
  });

  group('a logout', () {
    test('stops the radio first, ahead of everything that takes time, and a '
        'radio that cannot be asked costs the wipe nothing', () async {
      SharedPreferences.setMockInitialValues({});
      for (final deaf in [false, true]) {
        final journal = <String>[];
        final radio = FakeMeshRadio()..journal = journal;
        if (deaf) radio.throws['stop'] = StateError(_address);
        final container = ProviderContainer(
          overrides: [
            identityServiceProvider.overrideWithValue(_Identity()),
            circleServiceProvider.overrideWithValue(_Circles(journal)),
            meshRadioProvider.overrideWithValue(radio),
          ],
        );
        addTearDown(container.dispose);

        await container
            .read(identityNotifierProvider.notifier)
            .deleteIdentity();

        expect(journal, [
          'radio.stop',
          'cursors',
          'close',
          'wipe',
        ], reason: 'deaf: $deaf');
      }
    });

    test("takes the disclosure's read flag and an owed stop notice with it: "
        'the next identity reads the disclosure for itself', () async {
      SharedPreferences.setMockInitialValues({kMeshIntroSeenKey: true});
      final container = ProviderContainer(
        overrides: [
          identityServiceProvider.overrideWithValue(_Identity()),
          circleServiceProvider.overrideWithValue(_Circles([])),
          meshRadioProvider.overrideWithValue(FakeMeshRadio()),
        ],
      );
      addTearDown(container.dispose);
      container.read(meshStoppedNoticeProvider.notifier).state = true;

      await container.read(identityNotifierProvider.notifier).deleteIdentity();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey(kMeshIntroSeenKey), isFalse);
      expect(container.read(meshStoppedNoticeProvider), isFalse);
    });

    test("a notice the radio's own stop raises late in a logout is not the "
        "next identity's", () async {
      SharedPreferences.setMockInitialValues({});
      final mesh = FakeMeshService()..statsAnswer = meshState(on: true);
      final radio = FakeMeshRadio()
        ..statusAnswer = radioStatus(MeshRadioState.running, wanted: true);
      final container = ProviderContainer(
        overrides: [
          identityServiceProvider.overrideWithValue(_Identity()),
          circleServiceProvider.overrideWithValue(_Circles([])),
          meshServiceProvider.overrideWithValue(mesh),
          meshRadioProvider.overrideWithValue(radio),
          meshNoticeCopyProvider.overrideWithValue(meshCopy),
        ],
      );
      addTearDown(container.dispose);
      await container.read(meshProvider.future);
      // The engine's stop answers only once the logout has ended.
      final stop = Completer<void>();
      mesh.held['stop'] = stop.future;

      final logout = container
          .read(identityNotifierProvider.notifier)
          .deleteIdentity();
      await radio.reached('stop');
      // The service reports the stop the logout asked for: to the reconcile
      // it is a radio that stopped beside an engine still on.
      radio.emit(radioStatus(MeshRadioState.stopped));
      await logout;
      stop.complete();
      await pumpEventQueue();
      expect(
        container.read(meshStoppedNoticeProvider),
        isTrue,
        reason: 'premise: the notice was raised behind the logout',
      );

      // The next identity is set up: the import fails on the fake, behind
      // the point where what the last identity left is dropped.
      await container
          .read(identityNotifierProvider.notifier)
          .importFromNsec('nsec1')
          .then<void>((_) {}, onError: (Object _) {});

      expect(container.read(meshStoppedNoticeProvider), isFalse);
    });

    test('the retry of its wipe stops the radio before the wipe; with no '
        'wipe owed the radio is not asked', () async {
      for (final (owed, made) in [
        (true, ['radio.stop', 'wipe']),
        (false, <String>[]),
      ]) {
        SharedPreferences.setMockInitialValues({kPendingMlsWipeKey: owed});
        final journal = <String>[];
        final retry = PendingMlsWipeService(
          prefs: await SharedPreferences.getInstance(),
          circleService: _Circles(journal),
          meshRadio: FakeMeshRadio()..journal = journal,
        );

        await retry.retryWipeIfPending();

        expect(journal, made, reason: 'owed: $owed');
      }
    });

    test('a retry whose radio cannot be asked still wipes', () async {
      SharedPreferences.setMockInitialValues({kPendingMlsWipeKey: true});
      final journal = <String>[];
      final prefs = await SharedPreferences.getInstance();
      final retry = PendingMlsWipeService(
        prefs: prefs,
        circleService: _Circles(journal),
        meshRadio: FakeMeshRadio()
          ..journal = journal
          ..throws['stop'] = StateError(_address),
      );

      await retry.retryWipeIfPending();

      expect(journal, ['radio.stop', 'wipe']);
      expect(prefs.getBool(kPendingMlsWipeKey), isFalse);
    });

    test('the retry made before a new identity stops the radio the '
        'providers hold', () async {
      SharedPreferences.setMockInitialValues({kPendingMlsWipeKey: true});
      final journal = <String>[];
      final container = ProviderContainer(
        overrides: [
          identityServiceProvider.overrideWithValue(_Identity()),
          circleServiceProvider.overrideWithValue(_Circles(journal)),
          meshRadioProvider.overrideWithValue(
            FakeMeshRadio()..journal = journal,
          ),
        ],
      );
      addTearDown(container.dispose);

      // The import fails on the fake identity; the reconcile ran before it.
      await container
          .read(identityNotifierProvider.notifier)
          .importFromNsec('nsec1')
          .then<void>((_) {}, onError: (Object _) {});

      expect(journal.take(2), ['radio.stop', 'wipe']);
    });
  });

  group('with the flag off, or on a platform with no radio', () {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final touched = <String>[];

    setUp(() {
      messenger.setMockMethodCallHandler(AndroidMeshRadio.channel, (
        call,
      ) async {
        touched.add(call.method);
        return null;
      });
    });

    tearDown(() {
      messenger.setMockMethodCallHandler(AndroidMeshRadio.channel, null);
      touched.clear();
    });

    /// The service reports itself running, on the state channel.
    Future<void> reported() => messenger.handlePlatformMessage(
      AndroidMeshRadio.stateChannel.name,
      AndroidMeshRadio.stateChannel.codec.encodeMessage({
        'state': 'running',
        'wanted': true,
        'canSearch': true,
      }),
      null,
    );

    ProviderContainer built({required bool? flag, required bool android}) {
      final container = ProviderContainer(
        overrides: [
          if (flag != null) meshEnabledProvider.overrideWithValue(flag),
          platformIsAndroidProvider.overrideWithValue(android),
          meshServiceProvider.overrideWith(
            (ref) => ref.watch(meshEnabledProvider) ? FakeMeshService() : null,
          ),
          meshNoticeCopyProvider.overrideWithValue(meshCopy),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('there is no radio, and no radio channel is touched whatever is '
        'asked of the mesh', () async {
      for (final (flag, android) in [
        (null, true),
        (false, true),
        (true, false),
      ]) {
        final row = 'flag $flag, android $android';
        final container = built(flag: flag, android: android);

        expect(container.read(meshRadioProvider), isNull, reason: row);
        await container.read(meshProvider.future);
        final mesh = container.read(meshProvider.notifier);
        await mesh.turnOn(confirm: () async => fail('nothing to confirm'));
        await mesh.reconcile();
        await mesh.keepOn();
        await mesh.turnOff();
        await mesh.reconcile();
        // Nobody listens to the service either: its report asks nothing.
        await reported();
        await pumpEventQueue();

        expect(touched, isEmpty, reason: row);
      }
      expect(platformMeshRadio(), isNull, reason: 'the flag is off');
    });

    test('with the flag on a platform without a radio drives the mesh as it '
        'is without one', () async {
      final container = built(flag: true, android: false);
      final mesh = container.read(meshServiceProvider)! as FakeMeshService;
      await container.read(meshProvider.future);
      final notifier = container.read(meshProvider.notifier);

      expect(await notifier.turnOn(), MeshTurnOn.on);
      await notifier.reconcile();
      expect(await notifier.keepOn(), isTrue);
      await notifier.turnOff();

      expect(mesh.calls, [
        'stats',
        'start',
        'stats',
        'keepOn',
        'stats',
        'stop',
        'stats',
      ]);
    });

    test('with the flag on Android the radio is the platform channel: it is '
        "asked, and the service's report is heard", () async {
      final container = built(flag: true, android: true);

      expect(container.read(meshRadioProvider), isA<AndroidMeshRadio>());
      await container.read(meshProvider.future);
      expect(touched, isEmpty, reason: 'premise: nothing asked yet');

      await reported();
      await pumpEventQueue();

      expect(touched, ['status']);
    });

    test('with no native end a turn-on is the fixed failure and stores '
        'nothing, and nothing of it is logged or reported', () async {
      messenger.setMockMethodCallHandler(AndroidMeshRadio.channel, null);
      final logs = LogCapture.install();
      final reported = <Object>[];
      final report = FlutterError.onError;
      FlutterError.onError = (details) => reported.add(details.exception);
      addTearDown(() => FlutterError.onError = report);
      final container = built(flag: true, android: true);
      final mesh = container.read(meshServiceProvider)! as FakeMeshService;
      await container.read(meshProvider.future);

      expect(
        await container.read(meshProvider.notifier).turnOn(),
        MeshTurnOn.failed,
      );
      await container.read(meshProvider.notifier).reconcile();
      await pumpEventQueue();

      expect(mesh.calls, isNot(contains('start')));
      expect(logs.lines, isEmpty);
      expect(reported, isEmpty);
    });
  });

  group('a radio that never answers', () {
    const bound = Duration(seconds: 3);
    const permissionBound = Duration(seconds: 40);
    const radio = AndroidMeshRadio(
      bound: bound,
      permissionBound: permissionBound,
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final asked = <String>[];

    /// Every entry in [deaf] is never answered; the others answer as a
    /// service that runs would.
    void serviceDeafTo(Set<String> deaf) {
      asked.clear();
      messenger.setMockMethodCallHandler(AndroidMeshRadio.channel, (call) {
        asked.add(call.method);
        if (deaf.contains(call.method)) return Completer<Object?>().future;
        return Future.value(switch (call.method) {
          'permission' || 'requestPermission' => 'granted',
          'bluetoothOn' => true,
          'start' => 'started',
          'status' => {'state': 'running', 'wanted': true, 'canSearch': true},
          _ => null,
        });
      });
      addTearDown(
        () =>
            messenger.setMockMethodCallHandler(AndroidMeshRadio.channel, null),
      );
    }

    /// What [entry] came to once [waited] had passed: `null` while it is
    /// still out.
    Object? after<T>(Duration waited, Future<T> Function() entry) {
      Object? ended;
      fakeAsync((async) {
        unawaited(
          entry().then<void>(
            (answer) => ended = answer ?? 'answered',
            onError: (Object error) => ended = error,
          ),
        );
        async.elapse(waited);
      });
      return ended;
    }

    test('fails each entry at its bound as a platform error would, and not '
        'before', () {
      const all = {
        'permission',
        'requestPermission',
        'bluetoothOn',
        'bluetoothName',
        'openBluetoothSettings',
        'start',
        'sync',
        'stop',
        'status',
      };
      final entries = <String, Future<Object?> Function()>{
        'permission': radio.permission,
        'bluetoothOn': radio.bluetoothOn,
        'bluetoothName': radio.bluetoothName,
        'openBluetoothSettings': radio.openBluetoothSettings,
        'sync': () => radio.sync(meshCopy(Duration.zero)),
        'stop': radio.stop,
        'status': radio.status,
      };
      const justUnder = Duration(milliseconds: 1);
      for (final MapEntry(key: name, value: entry) in entries.entries) {
        serviceDeafTo(all);
        expect(after(bound - justUnder, entry), isNull, reason: name);
        expect(after(bound, entry), isA<MeshRadioException>(), reason: name);
      }

      serviceDeafTo(all);
      Future<Object?> start() => radio.start(meshCopy(Duration.zero));
      expect(after(bound - justUnder, start), isNull);
      expect(after(bound, start), MeshRadioStart.failed);

      // The system's dialog waits on a person: longer, and still not for
      // ever.
      serviceDeafTo(all);
      expect(
        after(permissionBound - justUnder, radio.requestPermission),
        isNull,
      );
      expect(
        after(permissionBound, radio.requestPermission),
        isA<MeshRadioException>(),
      );
    });

    ({ProviderContainer container, FakeMeshService mesh}) on() {
      final mesh = FakeMeshService()..statsAnswer = meshState(on: true);
      final container = ProviderContainer(
        overrides: [
          meshServiceProvider.overrideWithValue(mesh),
          meshRadioProvider.overrideWithValue(radio),
          meshNoticeCopyProvider.overrideWithValue(meshCopy),
        ],
      );
      addTearDown(container.dispose);
      return (container: container, mesh: mesh);
    }

    test('costs a turn-off its bound, and the engine is stopped all the '
        'same', () {
      serviceDeafTo({'stop'});
      final t = on();
      fakeAsync((async) {
        unawaited(t.container.read(meshProvider.notifier).turnOff());
        async.elapse(bound - const Duration(milliseconds: 1));
        expect(t.mesh.calls, isNot(contains('stop')));

        async.elapse(const Duration(milliseconds: 1));
        expect(t.mesh.calls, contains('stop'));
      });
    });

    test('at a keep-on leaves a turn-off asked behind it working', () {
      serviceDeafTo({'sync'});
      final t = on();
      fakeAsync((async) {
        final mesh = t.container.read(meshProvider.notifier);
        unawaited(mesh.keepOn());
        unawaited(mesh.turnOff());
        async.elapse(bound);

        expect(asked, containsAllInOrder(['sync', 'stop']));
        expect(t.mesh.calls, containsAllInOrder(['keepOn', 'stop']));
        expect(t.container.read(meshProvider).requireValue!.on_, isFalse);
      });
    });

    test('costs a logout its bound, and the wipe is made all the same', () {
      SharedPreferences.setMockInitialValues({});
      serviceDeafTo({'stop'});
      final journal = <String>[];
      final container = ProviderContainer(
        overrides: [
          identityServiceProvider.overrideWithValue(_Identity()),
          circleServiceProvider.overrideWithValue(_Circles(journal)),
          meshRadioProvider.overrideWithValue(radio),
        ],
      );
      addTearDown(container.dispose);
      fakeAsync((async) {
        unawaited(
          container.read(identityNotifierProvider.notifier).deleteIdentity(),
        );
        async.elapse(bound - const Duration(milliseconds: 1));
        expect(asked, ['stop']);
        expect(journal, isEmpty);

        async.elapse(const Duration(milliseconds: 1));
        expect(journal, ['cursors', 'close', 'wipe']);
      });
    });

    test('costs the retry of a wipe at a launch its bound, and the wipe is '
        'made all the same', () {
      SharedPreferences.setMockInitialValues({kPendingMlsWipeKey: true});
      serviceDeafTo({'stop'});
      final journal = <String>[];
      fakeAsync((async) {
        late final SharedPreferences prefs;
        unawaited(
          SharedPreferences.getInstance().then((got) async {
            prefs = got;
            await PendingMlsWipeService(
              prefs: prefs,
              circleService: _Circles(journal),
              meshRadio: radio,
            ).retryWipeIfPending();
          }),
        );
        async.elapse(bound - const Duration(milliseconds: 1));
        expect(asked, ['stop']);
        expect(journal, isEmpty);

        async.elapse(const Duration(milliseconds: 1));
        expect(journal, ['wipe']);
        expect(prefs.getBool(kPendingMlsWipeKey), isFalse);
      });
    });
  });

  test('nothing is logged by a start, a stop, a failure or the name, and '
      'nothing thrown reaches the state', () async {
    final logs = LogCapture.install();
    final t = _Mesh()..radio.bluetoothNameAnswer = _name;
    await t.built();

    // On and off, the name read and shown by the caller's confirmation.
    await t.notifier.turnOn(
      confirm: () async => await t.radio.bluetoothName() == _name,
    );
    await t.notifier.keepOn();
    await t.notifier.turnOff();
    // Then every radio entry failing with a peer's address in what it
    // throws, through each transition and a reconcile.
    for (final entry in [
      'permission',
      'requestPermission',
      'bluetoothOn',
      'start',
      'sync',
      'stop',
      'status',
    ]) {
      t.radio.throws[entry] = StateError('link to $_address lost');
      await t.notifier.turnOn();
      await t.notifier.keepOn();
      t.radio.emit(radioStatus(MeshRadioState.stopped, wanted: true));
      await pumpEventQueue();
      await t.notifier.turnOff();
      await t.notifier.reconcile();
      t.radio.throws.clear();

      expect(
        '${t.container.read(meshProvider)}',
        isNot(contains(_address)),
        reason: entry,
      );
    }

    expect(t.journal, contains('radio.bluetoothName'));
    expect(logs.lines, isEmpty);
  });
}
