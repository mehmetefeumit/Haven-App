/// Pins what `MapShell` does when it is MOUNTED under a lifecycle that is not
/// `resumed`.
///
/// The binding dispatches only changes. A shell mounted under a binding that
/// already reads `paused` — on Android, an activity stopped during `main()`'s
/// awaits, the warm-up frame still building the tree — is dispatched no pause.
/// It used to stamp "foreground active" and arm the 72 s heartbeat that only a
/// pause cancels, so a foreground service alive in the process deferred to a
/// UI nobody could see, and nobody published until the next real resume and
/// pause. Such a shell now takes the pause it missed, and its start-up
/// contacts no relay until the app is in front.
///
/// What the gate does is driven through the binding in
/// `foreground_start_up_gate_test.dart`. That `MapShell` wires it — and which
/// of its start-up steps it holds back — is inside a `ConsumerState` that
/// cannot be pumped without the Rust bridge (CLAUDE.md), so it is pinned over
/// the source, comments stripped.
library;

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/pages/foreground_start_up_gate.dart';

import 'map_shell_burst_collaborators_test.dart' show methodSource;

String _flat(String source) => source.replaceAll(RegExp(r'\s+'), ' ');

void main() {
  group('pausedAtMount', () {
    test('a mount under paused takes the pause it missed', () {
      expect(pausedAtMount(AppLifecycleState.paused), isTrue);
    });

    test('a mount under any other state does not', () {
      for (final state in [
        // A launch dialog is a visible app; if the app leaves `inactive` for
        // the background, `paused` is dispatched then.
        AppLifecycleState.inactive,
        // Sent by neither the Android nor the iOS embedder; only ever
        // synthesised between two states.
        AppLifecycleState.hidden,
        AppLifecycleState.resumed,
        // The seed: the first message after the mount is dispatched `resumed`
        // first, and for `paused` the pause right behind it.
        AppLifecycleState.detached,
        null,
      ]) {
        expect(pausedAtMount(state), isFalse, reason: '$state');
      }
    });
  });

  group('the mount', () {
    late String source;
    setUpAll(
      () => source = File('lib/src/pages/map_shell.dart').readAsStringSync(),
    );

    test('the mount goes through the gate, with the pause handler, the '
        'stamp and the consent it waits for', () {
      final init = _flat(
        methodSource(source, className: '_MapShellState', method: 'initState'),
      );
      expect(init, contains('gateMount();'));
      expect(
        init,
        isNot(contains('markForegroundActive(')),
        reason: 'a stamp outside the gate is made under `paused` too',
      );
      final flat = _flat(source);
      expect(
        flat,
        contains(
          'void takePause() => '
          'didChangeAppLifecycleState(AppLifecycleState.paused);',
        ),
      );
      expect(
        flat,
        contains(
          'Future<void> beforeMissedPause() => '
          'ref.read(backgroundSharingProvider.notifier).loaded;',
        ),
        reason: 'a pause that read the consent still loading takes the '
            'sharing-off branch: on Android nothing is handed to the service',
      );
    });

    test("the start-up's relay contact is held back until the app is in "
        'front, and paid at the first resume', () {
      final startUp = _flat(
        methodSource(
          source,
          className: '_MapShellState',
          method: '_runStartupTasks',
        ),
      );
      final contact = _flat(
        methodSource(
          source,
          className: '_MapShellState',
          method: 'startUpRelayContact',
        ),
      );
      expect(startUp, contains('await gateStartUp();'));
      for (final step in [
        '.initialize()',
        'keyPackagePublisherProvider',
        'locationPublisherProvider',
        'invitationPollerProvider',
        'evolutionPollerProvider',
        '_coldStartProfileRefreshTimer = Timer(',
        // Carrying a leave on can publish a `SelfRemove` and opens the pool:
        // not urgent enough to contact relays from a paused process.
        '_carryOnLeaves()',
      ]) {
        expect(contact, contains(step), reason: '$step is gone');
        expect(
          startUp,
          isNot(contains(step)),
          reason: '$step runs at a start-up taken while the app is away',
        );
      }
      final resumed = _flat(
        methodSource(source, className: '_MapShellState', method: '_onResumed'),
      );
      expect(
        resumed.trimRight(),
        endsWith('unawaited(payOwedStartUp());}'),
        reason: 'what a paused start-up skipped is never done',
      );
      // What a debounced resume does with an owed start-up is the gate's,
      // driven through the real code (`foreground_start_up_gate_test.dart`).
      expect(
        resumed,
        contains('if (!resumeExtrasDue()) return;'),
        reason: "the resume debounce is the gate's, which pays an owed "
            'start-up at a resume it debounces',
      );
      expect(
        contact,
        contains('await _publishPool?.initialize(); '
            'if (!mounted || !stillInFront()) return;'),
        reason: 'a pause landing during the pool open did not stop the rest '
            'of the contact',
      );
      expect(
        resumed,
        contains('unawaited(_carryOnLeaves());'),
        reason: 'a leave this device asked for is carried on by nothing '
            'until the next launch',
      );
    });

    test("the resume's wait for the service to go idle cannot abort it", () {
      // The same platform channel as the guarded stamp before it: a throw
      // used to skip the end of the hand-off, the heal and every timer.
      final resumed = _flat(
        methodSource(source, className: '_MapShellState', method: '_onResumed'),
      );
      expect(
        resumed,
        contains(
          [
            'await MapShell._handoffWrite(() => const BackgroundIdleWaiter()',
            '.waitUntilIdle());',
          ].join(),
        ),
      );
      expect(
        'waitUntilIdle()'.allMatches(resumed),
        hasLength(1),
        reason: 'an unguarded second wait',
      );
    });

    test("the pause's local teardown runs before its first await", () {
      // The Android hand-off awaits the engine's stop, which can take as long
      // as the relays take: a one-shot publish burst, the join watcher and the
      // foreground timers must not run on behind it.
      final paused = _flat(
        methodSource(source, className: '_MapShellState', method: '_onPaused'),
      );
      final firstAwait = paused.indexOf('await ');
      expect(firstAwait, greaterThan(0), reason: 'anti-vacuity');
      for (final step in [
        'ref.invalidate(locationPublisherProvider);',
        'ref.read(joinWatcherProvider.notifier).cancel();',
        '_receiveTimer?.cancel();',
        '_invitationTimer?.cancel();',
        '_pruneTimer?.cancel();',
        '_evolutionTimer?.cancel();',
      ]) {
        final at = paused.indexOf(step);
        expect(at, greaterThan(0), reason: '$step is gone');
        expect(
          at,
          lessThan(firstAwait),
          reason: '$step waits for the hand-off',
        );
      }
    });
  });
}
