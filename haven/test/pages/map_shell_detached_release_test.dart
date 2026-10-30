/// Pins `MapShell`'s handling of `AppLifecycleState.detached`.
///
/// `detached` is the only lifecycle signal that says this isolate is going away
/// while it can still act on that. The MLS database allows exactly one live
/// session per process (Rule 14), and the guard enforcing it is a Rust static
/// no Dart finalizer reaches — so an isolate that dies without releasing leaves
/// the background service contending with a session whose owner is gone. The
/// reclaim path exists to recover from that, but it is reactive, gated on
/// inferring the isolate is gone, and destructive if that inference is wrong.
/// Releasing at `detached` avoids needing any of that.
///
/// `_MapShellState`, `_onDetached`, and `_liveSyncHealTimer` are all private,
/// and per CLAUDE.md `MapShell` cannot be widget-tested without the Rust
/// bridge, so these assert over the source — the same fallback used for the
/// session-reclaim gates. They are written to fail if the handling is removed,
/// reordered, or widened into something unsafe. The pause-time handoff's own
/// decisions are a static (`MapShell.handOffMlsSession`) and are exercised.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/pages/map_shell.dart';
import 'package:haven/src/services/subscription_service.dart';

void main() {
  late String source;
  late String detachedBody;

  setUpAll(() {
    source = File('lib/src/pages/map_shell.dart').readAsStringSync();
    final start = source.indexOf('Future<void> _onDetached() async {');
    expect(
      start,
      isNonNegative,
      reason: '_onDetached must exist; if it was renamed, update this guard '
          'rather than deleting it',
    );
    // Bounded by the next member so an assertion about this body can never be
    // satisfied by code elsewhere in a 1000-line file.
    final end = source.indexOf('\n  /// ', start);
    expect(end, greaterThan(start));
    detachedBody = source.substring(start, end);
  });

  test('detached is dispatched, not folded into paused/resumed', () {
    // The lifecycle handler deliberately treats `inactive`/`hidden` as
    // equivalent to paused/resumed. `detached` must NOT be swept into that
    // simplification — it means something categorically different.
    expect(
      source.contains('state == AppLifecycleState.detached'),
      isTrue,
      reason: 'without a branch here the isolate dies holding the session and '
          'the background service is left to infer the orphan',
    );
    final handler = source.indexOf('void didChangeAppLifecycleState(');
    expect(handler, isNonNegative);
    expect(
      source.indexOf('state == AppLifecycleState.detached', handler),
      greaterThan(handler),
      reason: 'the branch must live in the lifecycle handler',
    );
  });

  test('the release stops the live-sync engine, through the shared path', () {
    // Stopping the engine is what releases its Arc on the circle manager, its
    // supervisor tasks, and the process-global session slot.
    //
    // Through `_stopLiveSyncBounded` and never a `stop()` of its own: a second
    // stop path that swallows its outcome reads a timed-out teardown as a
    // release, which orphans the Rule-14 guard — a database no isolate can
    // open until a Force Stop.
    expect(detachedBody.contains('_stopLiveSyncBounded()'), isTrue);
    expect(
      detachedBody.contains('liveSync.stop()'),
      isFalse,
      reason: 'one bounded implementation, one classification of a timeout',
    );
  });

  test('the heal timer is cancelled BEFORE the stop', () {
    // A periodic heal landing mid-teardown would restart the engine while this
    // is tearing it down — leaving a FRESH session orphaned instead of
    // releasing the old one, which is strictly worse than doing nothing.
    final cancel = detachedBody.indexOf('_healBackstop.stop()');
    final stop = detachedBody.indexOf('_stopLiveSyncBounded()');
    expect(cancel, isNonNegative);
    expect(stop, isNonNegative);
    expect(
      cancel,
      lessThan(stop),
      reason: 'cancelling after the stop leaves a window where a tick can '
          'resurrect the session this is trying to release',
    );
  });

  test('it does not dispose the circle manager', () {
    // `detached` can be followed by `resumed` (Android activity recreation).
    // The manager is a provider singleton used across the app; disposing it
    // would leave every circle operation broken on the way back, and the guard
    // it holds is deliberately accepted as the remaining orphan risk.
    // Match a CALL on something, not the bare word — the doc comment above
    // explains why the manager is not disposed, and would otherwise trip this.
    expect(
      RegExp(r'^\s*[A-Za-z_][\w.?!]*\.dispose\(\)', multiLine: true)
          .hasMatch(detachedBody),
      isFalse,
      reason: 'this path may be followed by a resume — it must be recoverable',
    );
  });

  test('it never throws out of the lifecycle callback', () {
    // Runs on a best-effort teardown path with no one to handle a failure, and
    // the framework dispatches it without awaiting. The catch itself lives in
    // the shared `_stopLiveSyncBounded` (pinned in
    // `map_shell_location_access_lifecycle_test.dart`); what this body must
    // not do is add a rethrow of its own.
    //
    // Anchored on the STATEMENT, not the word: a bare substring match would
    // read the prose above as a violation. Source scans have to match syntax.
    expect(
      RegExp(r'\brethrow\s*;').hasMatch(detachedBody),
      isFalse,
      reason: 'nothing upstream can act on a failure here',
    );
  });

  test('the raw error is never logged', () {
    // Security Rule 8: an FFI error string can carry MLS group ids.
    expect(
      RegExp(r'\$e[^a-zA-Z]').hasMatch(detachedBody),
      isFalse,
      reason: 'log the type, never the message',
    );
  });

  test('a resume after detached can restart the engine', () {
    // The release is only safe because coming back is handled: the resume path
    // heals unconditionally, ahead of its own debounce.
    final resume = source.indexOf('Future<void> _onResumed() async {');
    expect(resume, isNonNegative);
    final heal = source.indexOf('_healBackstop.heal()', resume);
    final debounce = source.indexOf('resumeExtrasDue()', resume);
    expect(heal, isNonNegative);
    expect(debounce, isNonNegative);
    expect(
      heal,
      lessThan(debounce),
      reason: 'a resume inside the debounce window must still heal, or a '
          'detached-then-quickly-resumed app comes back with no engine',
    );
  });

  group('the pause-time MLS handoff', () {
    test('live-sync is stopped BEFORE the manager is released', () async {
      // The engine holds its own Arc on the circle manager, so releasing the
      // manager first leaves the guard held by the engine and hands over
      // nothing — the foreground service still cannot open, and background
      // publishing stays dead for the whole session.
      final order = <String>[];
      final stop = Completer<LiveSyncStopOutcome>();
      final handing = MapShell.handOffMlsSession(
        engineStop: stop.future,
        releaseSession: () {
          order.add('release');
          return true;
        },
        announce: ({required handedOff}) => order.add('announce:$handedOff'),
        ownershipWrites: const [],
        superseded: () => false,
      );
      await pumpEventQueue();
      expect(
        order,
        isEmpty,
        reason: 'releasing before the engine stops frees nothing',
      );

      stop.complete(LiveSyncStopOutcome.stopped);
      await handing;
      expect(order, ['release', 'announce:true']);

      // And the shell hands that static its own bounded stop and its own
      // release, which is the one place `releaseForHandoff()` is called.
      final src = File('lib/src/pages/map_shell.dart').readAsStringSync();
      final at = src.indexOf('Future<void> _handOffMlsSession({');
      expect(at, isNonNegative, reason: 'the handoff must exist');
      final wiring = src.substring(at, src.indexOf('\n  /// ', at));
      expect(wiring, contains('MapShell.handOffMlsSession('));
      expect(wiring, contains('engineStop: engineStop,'));
      // The stop it is handed is the pause's own, issued as its first act.
      final paused = src.indexOf('Future<void> _onPaused() async {');
      expect(
        src.indexOf('engineStop = _stopLiveSyncBounded();', paused),
        allOf(
          greaterThan(paused),
          lessThan(src.indexOf('await _handOffMlsSession(', paused)),
        ),
        reason: 'the hand-off must be handed a stop already issued',
      );
      // Through the circle service the pause captured while mounted: the
      // release runs behind the stop, and `ref` may be gone by then.
      expect(
        wiring,
        contains(
          'releaseSession: () => _releaseMlsSessionForHandoff(circleService),',
        ),
      );
      final release = src.indexOf(
        'static bool _releaseMlsSessionForHandoff(CircleService service) {',
      );
      expect(release, isNonNegative);
      expect(
        src.substring(release, src.indexOf('\n  /// ', release)),
        contains('service.releaseForHandoff()'),
      );
      expect(
        RegExp(r'\.releaseForHandoff\(\)').allMatches(src).length,
        1,
        reason: 'a second release site is one the stop outcome does not gate',
      );
    });

    test('a stop that did not drain declines the release entirely', () async {
      // The C1 wedge, from the pause side. When the engine reports
      // `stillHolding`, its supervisor tasks are still running and still hold
      // the `Arc<CircleManager>` — so disposing THIS isolate's handle frees
      // nothing and merely removes the last Dart reference to a guard a Rust
      // static keeps registered. The service then cannot open (held), its
      // reclaim declines (this isolate is provably alive), and the app returns
      // to a database nothing can open until a Force Stop.
      var released = 0;
      final announced = <bool>[];
      await MapShell.handOffMlsSession(
        engineStop: Future.value(LiveSyncStopOutcome.stillHolding),
        releaseSession: () {
          released++;
          return true;
        },
        announce: ({required handedOff}) => announced.add(handedOff),
        ownershipWrites: const [],
        superseded: () => false,
      );

      expect(
        released,
        0,
        reason: 'the refusal must SKIP the release, not merely log beside it',
      );
      expect(
        announced,
        [false],
        reason: 'and the pause must be told the session was not handed over',
      );
    });

    test('a declined handoff does not leave the notification lying', () {
      // The notification is the ONLY thing a backgrounded user can see, and the
      // decline path above is a state this code now creates on purpose: the
      // service will not publish or receive at all until the app is reopened.
      // Leaving "Haven is sending and receiving location information" up there
      // would make the one visible surface assert exactly what is not
      // happening.
      //
      // Source-asserted: which text each result picks is decided where the
      // strings are, in the paused `MapShell` this harness cannot produce.
      final src = File('lib/src/pages/map_shell.dart').readAsStringSync();
      final call = src.indexOf('await _handOffMlsSession(');
      expect(call, isNonNegative);
      // The window from the handoff to the end of the notification call that
      // follows it, so an unrelated `updateNotification` elsewhere in the file
      // (the resume path's `fgsNotificationOpen`) cannot satisfy this.
      final window = src.substring(call, src.indexOf('    } else if', call));

      expect(
        window,
        contains('updateNotification'),
        reason: 'the pause path must still set the notification',
      );
      expect(
        RegExp(r'handedOff\s*\?').hasMatch(window),
        isTrue,
        reason: 'the text must be chosen from the handoff RESULT — an '
            'unconditional string is the claim that was wrong',
      );
      expect(
        window,
        contains('l10n.fgsNotificationSharing'),
        reason: 'the honest text for a handoff that worked',
      );
      expect(
        window,
        contains('l10n.fgsNotificationPaused'),
        reason: 'and an honest one for a handoff that did not, naming the '
            'action that repairs it',
      );
    });

    test('and neither of those two messages softens what it claims', () {
      // The test above pins WHICH message each branch picks. Localizing the
      // pair moved the copy itself out of the call site, so this pins what the
      // two messages say: without it the branch could keep choosing correctly
      // between two strings that no longer distinguish sending from stopped.
      final arb =
          jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync())
              as Map<String, dynamic>;

      expect(
        arb['fgsNotificationSharing'],
        'Haven is sending and receiving location information',
        reason: 'a backgrounded user is told BOTH halves are happening; '
            'shortening this to "sharing" would hide the receive side',
      );
      expect(
        arb['fgsNotificationPaused'],
        allOf(startsWith('Haven is paused'), contains('open the app')),
        reason: 'the declined-handoff text must state that Haven has stopped '
            'AND name the action that repairs it — reopening the app',
      );
    });

    test('the handoff is confined to the Android background-sharing path', () {
      // It is the one configuration where another isolate needs the session
      // while this one is merely paused. On iOS this isolate keeps publishing.
      final src = File('lib/src/pages/map_shell.dart').readAsStringSync();
      // The CALL, not the definition — which appears earlier in the file.
      final call = src.indexOf('await _handOffMlsSession(');
      expect(call, isNonNegative);
      final before = src.substring(0, call);
      final branch = before.lastIndexOf('if (bgEnabled && Platform.isAndroid)');
      expect(
        branch,
        isNonNegative,
        reason: 'the nearest enclosing branch must be the Android handoff',
      );
      expect(
        before.lastIndexOf('} else if'),
        lessThan(branch),
        reason: 'the call must not have drifted into another branch',
      );
    });
  });

  group('taking the session back on resume', () {
    // The handoff latches the circle service closed for the whole backgrounded
    // window (see `nostr_circle_service_test.dart`, "handoff durability"), so
    // the resume path has a hard ordering obligation: end the handoff before
    // anything that needs the manager, or spend the resume failing every open.
    late String resumeBody;

    setUpAll(() {
      final start = source.indexOf('Future<void> _onResumed() async {');
      expect(start, isNonNegative, reason: '_onResumed must exist');
      // Bounded by the next member, so an ordering assertion about the resume
      // can never be satisfied by code elsewhere in a 1300-line file.
      final end = source.indexOf('static const double _kMinSheetSize', start);
      expect(end, greaterThan(start));
      resumeBody = source.substring(start, end);
    });

    test('the handoff ends before the heal and before the debounce', () {
      final end = resumeBody.indexOf('_endMlsSessionHandoff()');
      final heal = resumeBody.indexOf('_healBackstop.heal()');
      final debounce = resumeBody.indexOf('resumeExtrasDue()');
      expect(
        end,
        isNonNegative,
        reason: 'without this the session stays handed off after resume and '
            'the app comes back to a database it refuses to open',
      );
      expect(heal, isNonNegative);
      expect(debounce, isNonNegative);
      expect(
        end,
        lessThan(heal),
        reason: 'the heal restarts the engine, which needs the manager — '
            'running it first burns the resume on a guaranteed failure',
      );
      expect(
        end,
        lessThan(debounce),
        reason: 'a resume inside the debounce window must still take the '
            'session back, or a glance-and-return leaves it handed off',
      );
    });

    test('ending the handoff replays the re-subscriber', () {
      // A circle-set change that arrived while the handoff held could not be
      // applied — the engine restart needs the manager. That failure leaves the
      // re-subscriber's signature un-advanced on purpose, so replaying today's
      // snapshot re-decides it. Without the replay, live receive for that
      // circle stays dead until the set changes AGAIN.
      final at = source.indexOf('void _endMlsSessionHandoff() {');
      expect(at, isNonNegative);
      final body = source.substring(at, source.indexOf('\n  /// ', at));
      expect(
        body.contains('_onLiveSyncCirclesChanged('),
        isTrue,
        reason: 'the deferred re-subscribe must be replayed on the way back',
      );
      expect(
        body.indexOf('if (!ended) return;'),
        lessThan(body.indexOf('_onLiveSyncCirclesChanged(')),
        reason: 'the replay is scoped to a handoff that was really in effect; '
            'firing it on every resume would cancel an unrelated pending '
            'debounce for no reason',
      );
    });

    test('it never throws out of the lifecycle callback', () {
      final at = source.indexOf('void _endMlsSessionHandoff() {');
      final body = source.substring(at, source.indexOf('\n  /// ', at));
      expect(body.contains('on Object catch'), isTrue);
      expect(
        RegExp(r'\$e[^a-zA-Z]').hasMatch(body),
        isFalse,
        reason: 'Security Rule 8: log the type, never the message',
      );
    });
  });
}
