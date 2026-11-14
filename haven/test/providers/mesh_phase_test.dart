// What the map is told of the Bluetooth mesh: whether its radio runs (signal
// S1 of `docs/BLUETOOTH_MESH_AURA_DESIGN.md` §7), when it turns itself off,
// when the user's own location was handed to it (S2), and the words of its
// notices.
//
// The promises:
//
//  * mesh shows as on only while the radio itself says it runs, the engine
//    was on when last read, and the deadline has not passed by the clock —
//    a report of the radio is taken as it is pushed, and a deadline that
//    passes turns it off with nothing reported and nothing asked;
//  * a question that went unanswered — of the radio or of the engine —
//    changes nothing shown, and an answer that lands behind a later one is
//    dropped;
//  * a hand-off counts only while the radio runs and, read afresh, a phone
//    is linked;
//  * the notices' words are the app's localized strings, with the time mesh
//    turns itself off as a clock time;
//  * with no radio nothing is asked of anything.
import 'dart:async';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations_en.dart';
import 'package:haven/src/providers/mesh_provider.dart';
import 'package:haven/src/services/mesh_radio.dart';
import 'package:intl/date_symbol_data_local.dart';

import '../helpers/english_arb.dart';
import '../helpers/fake_mesh.dart';

class _Mesh {
  _Mesh({bool radio = true}) {
    mesh.journal = journal;
    this.radio.journal = journal;
    container = ProviderContainer(
      overrides: [
        meshServiceProvider.overrideWithValue(radio ? mesh : null),
        meshRadioProvider.overrideWithValue(radio ? this.radio : null),
        meshNoticeCopyProvider.overrideWithValue(meshCopy),
      ],
    );
    addTearDown(container.dispose);
  }

  final journal = <String>[];
  final mesh = FakeMeshService();
  final radio = FakeMeshRadio();
  late final ProviderContainer container;

  MeshPhase get phase => container.read(meshPhaseProvider);

  /// The engine and the radio as set, each read once.
  Future<void> read({
    bool on = true,
    bool linked = false,
    int onForMs = 3600000,
    MeshRadioState state = MeshRadioState.running,
  }) async {
    mesh.statsAnswer = meshState(on: on, linked: linked, onForMs: onForMs);
    radio.statusAnswer = radioStatus(state, wanted: true);
    container.read(meshPhaseProvider);
    await container.read(meshProvider.future);
    await pumpEventQueue();
  }
}

/// A radio whose every status question stays open until the test answers
/// it.
class _SlowRadio extends FakeMeshRadio {
  final asked = <Completer<MeshRadioStatus>>[];

  @override
  Future<MeshRadioStatus> status() {
    asked.add(Completer<MeshRadioStatus>());
    return asked.last.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('mesh shows as', () {
    test('what the radio and the engine both say', () async {
      for (final (on, state, phase) in [
        (true, MeshRadioState.running, MeshPhase.on),
        (true, MeshRadioState.paused, MeshPhase.paused),
        (true, MeshRadioState.stopped, MeshPhase.off),
        // A radio up beside an engine that is off is not a mesh that is on.
        (false, MeshRadioState.running, MeshPhase.off),
        (false, MeshRadioState.stopped, MeshPhase.off),
      ]) {
        final t = _Mesh();
        await t.read(on: on, state: state);

        expect(t.phase, phase, reason: 'engine on: $on, radio $state');
      }
    });

    test('off before either has answered, and while the radio cannot be '
        'asked', () async {
      final t = _Mesh();
      expect(t.phase, MeshPhase.off);

      t.radio.throws['status'] = StateError('deaf');
      await t.read();

      expect(t.phase, MeshPhase.off);
    });

    test("the radio's own report, as it is pushed", () async {
      final t = _Mesh();
      await t.read();
      expect(t.phase, MeshPhase.on);
      t.journal.clear();

      t.radio.emit(radioStatus(MeshRadioState.paused, wanted: true));
      expect(t.phase, MeshPhase.paused);
      t.radio.emit(radioStatus(MeshRadioState.stopped));
      expect(t.phase, MeshPhase.off);
      t.radio.emit(radioStatus(MeshRadioState.running, wanted: true));
      expect(t.phase, MeshPhase.on);
    });

    test('off once the deadline has passed, with nothing reported and '
        'nothing asked', () {
      fakeAsync((async) {
        final t = _Mesh();
        unawaited(t.read(onForMs: 60000));
        async.flushMicrotasks();
        expect(t.phase, MeshPhase.on);
        expect(
          t.container.read(meshOnUntilProvider),
          clock.now().add(const Duration(minutes: 1)),
        );
        t.journal.clear();
        final phases = <MeshPhase>[];
        t.container.listen(meshPhaseProvider, (_, now) => phases.add(now));

        async.elapse(const Duration(seconds: 59));
        expect(phases, isEmpty);
        async.elapse(const Duration(seconds: 1));

        expect(phases, [MeshPhase.off]);
        expect(t.journal, isEmpty);
      });
    });

    test('off at the first look behind a deadline that passed while the '
        'process slept, its timer not yet run', () async {
      final t = _Mesh();
      await t.read(onForMs: 60000);
      expect(t.phase, MeshPhase.on);

      withClock(Clock(() => DateTime.now().add(const Duration(hours: 1))), () {
        // What the shell does at a resume.
        t.container.invalidate(meshPhaseProvider);

        expect(t.phase, MeshPhase.off);
      });
    });

    test('on still when a read of the radio fails: a question that went '
        'unanswered is not a radio that stopped', () async {
      final t = _Mesh();
      await t.read();
      final phases = <MeshPhase>[];
      t.container.listen(meshPhaseProvider, (_, now) => phases.add(now));
      t.radio.throws['status'] = StateError('deaf');

      await t.container.read(meshProvider.notifier).refresh();
      await pumpEventQueue();

      expect(t.journal, contains('radio.status'));
      expect(t.phase, MeshPhase.on);
      expect(phases, isEmpty);
    });

    test('on still, and until the same moment, when a read of the engine '
        'fails: the time left it said before is not counted again from '
        'now', () {
      fakeAsync((async) {
        final t = _Mesh();
        unawaited(t.read(onForMs: 60000));
        async.flushMicrotasks();
        final until = t.container.read(meshOnUntilProvider);
        t.mesh.throws['stats'] = StateError('deaf');

        async.elapse(const Duration(seconds: 40));
        unawaited(t.container.read(meshProvider.notifier).refresh());
        async.flushMicrotasks();

        expect(t.container.read(meshProvider).hasError, isTrue);
        expect(t.phase, MeshPhase.on);
        expect(t.container.read(meshOnUntilProvider), until);
        // And the deadline still passes when it was to.
        async.elapse(const Duration(seconds: 20));
        expect(t.phase, MeshPhase.off);
      });
    });

    test('the answer asked last: one that lands behind a later answer, or '
        'behind a report, is dropped', () async {
      final radio = _SlowRadio();
      final mesh = FakeMeshService()
        ..statsAnswer = meshState(on: true, onForMs: 3600000);
      final container = ProviderContainer(
        overrides: [
          meshServiceProvider.overrideWithValue(mesh),
          meshRadioProvider.overrideWithValue(radio),
        ],
      );
      addTearDown(container.dispose);
      MeshRadioState? shown() => container.read(meshRadioStatusProvider)?.state;
      container.read(meshPhaseProvider);
      await container.read(meshProvider.future);
      await pumpEventQueue();
      await container.read(meshProvider.notifier).refresh();
      await pumpEventQueue();
      expect(radio.asked.length, greaterThanOrEqualTo(2));
      final older = radio.asked[radio.asked.length - 2];

      // The later question is answered first.
      radio.asked.last.complete(
        radioStatus(MeshRadioState.running, wanted: true),
      );
      await pumpEventQueue();
      older.complete(radioStatus(MeshRadioState.stopped));
      await pumpEventQueue();
      expect(shown(), MeshRadioState.running);

      // And an answer to a question asked before a report came is stale.
      await container.read(meshProvider.notifier).refresh();
      await pumpEventQueue();
      radio.emit(radioStatus(MeshRadioState.paused, wanted: true));
      radio.asked.last.complete(
        radioStatus(MeshRadioState.running, wanted: true),
      );
      await pumpEventQueue();
      expect(shown(), MeshRadioState.paused);
    });

    test(
      'whatever the engine last said, read beside every read of it',
      () async {
        final t = _Mesh();
        await t.read();
        t.journal.clear();
        t.radio.statusAnswer = radioStatus(MeshRadioState.stopped);

        await t.container.read(meshProvider.notifier).refresh();
        await pumpEventQueue();

        expect(t.journal, ['mesh.stats', 'radio.status']);
        expect(t.phase, MeshPhase.off);
      },
    );
  });

  group('a hand-off of the own location', () {
    Future<int> counted(_Mesh t) async {
      await t.container.read(meshHandOffProvider.notifier).handedOff();
      return t.container.read(meshHandOffProvider);
    }

    test('counts while the radio runs and a phone is linked, and at no other '
        'time', () async {
      for (final (state, linked, count) in [
        (MeshRadioState.running, true, 1),
        (MeshRadioState.running, false, 0),
        (MeshRadioState.paused, true, 0),
        (MeshRadioState.stopped, true, 0),
      ]) {
        final t = _Mesh();
        await t.read(state: state, linked: linked);

        expect(await counted(t), count, reason: '$state, linked: $linked');
      }
    });

    test('reads afresh whether a phone is linked', () async {
      final t = _Mesh();
      await t.read();
      t.mesh.statsAnswer = meshState(on: true, linked: true, onForMs: 3600000);

      expect(await counted(t), 1);
      // And a link that went is not counted on the strength of the last one.
      t.mesh.statsAnswer = meshState(on: true, onForMs: 3600000);
      expect(await counted(t), 1);
    });

    test('every one counted is a change', () async {
      final t = _Mesh();
      await t.read(linked: true);
      final counts = <int>[];
      t.container.listen(meshHandOffProvider, (_, now) => counts.add(now));

      await counted(t);
      await counted(t);

      expect(counts, [1, 2]);
    });
  });

  test("a radio that answered that this phone can't use mesh takes the mesh "
      'off the screen for as long as the process lives', () async {
    final t = _Mesh()..radio.startAnswer = MeshRadioStart.unsupported;
    await t.read(on: false, state: MeshRadioState.stopped);
    expect(await t.container.read(meshSupportedProvider.future), isTrue);
    expect(t.container.read(meshAvailableProvider), isTrue);

    expect(
      await t.container.read(meshProvider.notifier).turnOn(),
      MeshTurnOn.unsupported,
    );

    expect(t.container.read(meshAvailableProvider), isFalse);
    // Not the identity's: a logout does not ask the phone again.
    t.container.invalidate(meshProvider);
    expect(t.container.read(meshAvailableProvider), isFalse);
  });

  group('nothing of the mesh is on screen until the radio says this phone '
      'can run it', () {
    test('not while the question is open, and from its "yes" on; asked '
        'once', () async {
      final t = _Mesh();
      final answer = Completer<void>();
      t.radio.held['supported'] = answer.future;
      final shown = <bool>[];
      t.container.listen(
        meshAvailableProvider,
        (_, now) => shown.add(now),
        fireImmediately: true,
      );

      await pumpEventQueue();
      expect(shown, [false]);

      answer.complete();
      await pumpEventQueue();
      expect(shown, [false, true]);

      // What reads it later asks nothing again.
      t.container.read(meshAvailableProvider);
      await t.read();
      expect(t.radio.supportedAsked, 1);
      expect(shown, [false, true]);
    });

    test('never for a "no", nor for a question that fails', () async {
      final refused = _Mesh()..radio.supportedAnswer = false;
      final deaf = _Mesh()..radio.throws['supported'] = StateError('deaf');
      for (final t in [refused, deaf]) {
        final shown = <bool>[];
        t.container.listen(
          meshAvailableProvider,
          (_, now) => shown.add(now),
          fireImmediately: true,
        );

        expect(await t.container.read(meshSupportedProvider.future), isFalse);
        await pumpEventQueue();

        expect(shown, [false]);
      }
    });
  });

  test('with no radio there is nothing on the map, and nothing is asked of '
      'the engine', () async {
    final t = _Mesh(radio: false);

    expect(t.container.read(meshAvailableProvider), isFalse);
    expect(t.phase, MeshPhase.off);
    await t.container.read(meshHandOffProvider.notifier).handedOff();
    await pumpEventQueue();

    expect(t.container.read(meshHandOffProvider), 0);
    expect(t.journal, isEmpty);
  });

  test("the notices' words are the app's strings, and the reminder tells "
      'the clock time mesh turns itself off', () async {
    await initializeDateFormatting();
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final at = DateTime(2026, 11, 12, 15, 5);

    final copy = withClock(
      Clock.fixed(at.subtract(const Duration(hours: 12))),
      () => container.read(meshNoticeCopyProvider)!(const Duration(hours: 12)),
    );

    expect(copy.channel, englishArb('meshNoticeChannel'));
    expect(copy.on, englishArb('meshNoticeOn'));
    expect(copy.paused, englishArb('meshNoticePaused'));
    expect(copy.keepOn, englishArb('meshNoticeKeepOn'));
    expect(copy.stopped, englishArb('meshNoticeStopped'));
    expect(copy.reminder, 'Bluetooth mesh turns off at 3:05\u202fPM');
    expect(copy.reminder, AppLocalizationsEn().meshNoticeReminder(at));
  });
}
