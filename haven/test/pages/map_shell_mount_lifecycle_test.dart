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
import 'package:haven/src/pages/map_shell.dart';

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

  // OD-R1 / R-1 / R-2: what MapShell does with a location relaunch. The
  // orderings are driven through the real binding on the gate itself
  // (`foreground_start_up_gate_test.dart`); these pin that MapShell answers
  // its hooks as the gate assumes.
  group('a location relaunch', () {
    late String source;
    setUpAll(
      () => source = File('lib/src/pages/map_shell.dart').readAsStringSync(),
    );
    String method(String name) =>
        _flat(methodSource(source, className: '_MapShellState', method: name));

    test("MapShell answers launchedForLocation from the location service's "
        'native read', () {
      expect(
        _flat(source),
        contains(
          'Future<bool> launchedForLocation() => '
          '_geolocatorService?.launchedForLocation() ?? Future.value(false);',
        ),
      );
    });

    test("MapShell hands the gate the location service's launch reports",
        () {
      expect(
        _flat(source),
        contains(
          'Stream<void> get locationLaunches => '
          '_geolocatorService?.locationLaunches ?? '
          'const Stream<void>.empty();',
        ),
        reason: 'a flag the native side sets after the mount read it would '
            'never be read again in a process no lifecycle message reaches',
      );
    });

    test('the launch may resume only once the consent has loaded, sharing is '
        'on and the CURRENT disclosure is accepted; then it waits for the '
        'roster, bounded', () {
      final body = method('launchMayResume');
      final loaded = body.indexOf(
        'await ref.read(backgroundSharingProvider.notifier).loaded;',
      );
      final sharing = body.indexOf('!ref.read(backgroundSharingProvider)');
      final disclosure = body.indexOf(
        '!backgroundResumeDisclosureAcceptedIn(prefs)',
      );
      final roster = body.indexOf(
        'ref.read(circlesProvider.future).timeout(kConsentArmBound)',
      );
      expect(
        [loaded, sharing, disclosure, roster],
        everyElement(isNonNegative),
      );
      expect(loaded, lessThan(sharing));
      expect(sharing, lessThan(disclosure));
      expect(
        disclosure,
        lessThan(roster),
        reason: 'a burst over an unread roster waits a scheduler tick',
      );
      expect(body, contains('return false;'));
    });

    test('the iOS sharing-on pause takes the launch before installing its '
        'coordinator, and hands it to _payLaunchSession', () {
      final paused = method('_onPaused');
      final take = paused.indexOf('final launch = takeLaunchSession();');
      final install = paused.indexOf(
        'final coordinator = _installBurstCoordinator();',
      );
      expect(take, isNonNegative);
      expect(take, lessThan(install));
      expect(paused, contains('_payLaunchSession(launch, coordinator,'));
      // The second: the consent watcher's false→true edge, for a pause that
      // read the consent still loading (the sharing-off branch takes nothing).
      final edge = paused.indexOf('if (next) {');
      expect(edge, greaterThan(install));
      expect(
        paused.indexOf('final launch = takeLaunchSession();', edge),
        greaterThan(edge),
        reason: 'a relaunch whose pause raced the consent load never starts '
            'its session',
      );
      expect(
        'takeLaunchSession()'.allMatches(_flat(source)),
        hasLength(2),
        reason: 'a consumer of the launch outside the iOS sharing-on pause',
      );
      expect('_payLaunchSession('.allMatches(paused), hasLength(2));
    });

    test('the session starts only for a launch that may resume, with '
        'sharing on, after the turn check and before the burst', () {
      final pay = method('_payLaunchSession');
      final turn = pay.indexOf('turn != _lifecycleTurn) return;');
      final gate = pay.indexOf(
        'if (session == LaunchSession.resume && bgEnabled) {',
      );
      final start = pay.indexOf('startBackgroundLaunchSession(');
      final burst = pay.indexOf('_driveBurstNow(coordinator, circles)');
      expect([turn, gate, start, burst], everyElement(isNonNegative));
      expect(turn, lessThan(gate));
      expect(gate, lessThan(start));
      expect(start, lessThan(burst));
      expect(
        pay,
        contains('session != LaunchSession.receiveOnly'),
        reason: 'an older acceptance must publish nothing from a relaunch',
      );
      expect(
        'startBackgroundLaunchSession('.allMatches(source),
        hasLength(1),
        reason: 'a second start site escapes the current-disclosure gate',
      );
    });

    test('the pause and resume branches go through admitPause / noteResume, '
        'the duplicate pause skipping even the turn', () {
      final lifecycle = method('didChangeAppLifecycleState');
      final admit = lifecycle.indexOf('if (!admitPause()) return;');
      final turn = lifecycle.indexOf('_lifecycleTurn++;');
      expect(admit, isNonNegative);
      expect(admit, lessThan(turn));
      final resumed = lifecycle.indexOf(
        'state == AppLifecycleState.resumed) {noteResume(); _lifecycleTurn++;',
      );
      expect(resumed, isNonNegative);
    });
  });

  // M1: an iOS process no scene has connected to is dispatched no pause, so
  // its mount is the only place the location service learns it is away.
  group('the foreground hint at a mount', () {
    test('an iOS mount under the detached seed clears it', () {
      expect(
        MapShell.foregroundActiveAtMount(
          lifecycle: AppLifecycleState.detached,
          isIOS: true,
        ),
        isFalse,
        reason: 'a background read could raise a permission prompt',
      );
    });

    test('every other mount leaves it to the lifecycle handlers', () {
      for (final lifecycle in <AppLifecycleState?>[
        null,
        ...AppLifecycleState.values,
      ]) {
        for (final isIOS in [true, false]) {
          if (isIOS && lifecycle == AppLifecycleState.detached) continue;
          expect(
            MapShell.foregroundActiveAtMount(
              lifecycle: lifecycle,
              isIOS: isIOS,
            ),
            isTrue,
            reason: '$lifecycle, isIOS=$isIOS',
          );
        }
      }
    });

    test('the mount writes the service alone, from the binding, before the '
        'gate', () {
      final init = _flat(
        methodSource(
          File('lib/src/pages/map_shell.dart').readAsStringSync(),
          className: '_MapShellState',
          method: 'initState',
        ),
      );
      final hint = init.indexOf(
        'if (!MapShell.foregroundActiveAtMount(lifecycle: '
        'WidgetsBinding.instance.lifecycleState, isIOS: Platform.isIOS)) '
        '{_geolocatorService?.foregroundActive = false;}',
      );
      expect(hint, isNonNegative);
      expect(hint, lessThan(init.indexOf('gateMount();')));
      expect(
        init,
        isNot(contains('appForegroundProvider')),
        reason: 'a provider written in initState is written during a build',
      );
      expect(init, isNot(contains('_setForegroundActive(')));
    });
  });

  // R-3: one foreground consent step, behind the storage-reset notice, only
  // while the app reads `resumed`.
  group('the foreground consent step', () {
    late String source;
    setUpAll(
      () => source = File('lib/src/pages/map_shell.dart').readAsStringSync(),
    );
    String method(String name) =>
        _flat(methodSource(source, className: '_MapShellState', method: name));

    test("the start-up gates it, the resume pays it, and it is the gate's "
        'only caller', () {
      final startUp = method('_runStartupTasks');
      expect(startUp, contains('unawaited(gateConsentStep());'));
      expect(
        startUp.indexOf('_storageResetNotice = showStorageResetNoticeIfOwed('),
        lessThan(startUp.indexOf('gateConsentStep()')),
      );
      expect(
        method('_onResumed'),
        contains('unawaited(payOwedConsentStep());'),
      );
      expect(
        'runForegroundConsentStep('.allMatches(source),
        hasLength(1),
        reason: 'a consent dialog shown from somewhere not resumed-gated',
      );
    });

    test('it waits for the storage-reset notice and re-reads the front '
        'before showing anything', () {
      final step = method('foregroundConsentStep');
      expect(
        step.indexOf('await _storageResetNotice;'),
        lessThan(step.indexOf('runForegroundConsentStep(')),
      );
      expect(step, contains('isResumed: () => mounted && appIsResumed()'));
      expect(step, contains('ref.read(androidBackgroundLocationProvider)'));
    });
  });
}
