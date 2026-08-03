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
/// reordered, or widened into something unsafe.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

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

  test('the release stops the live-sync engine', () {
    expect(
      detachedBody.contains('liveSync.stop()'),
      isTrue,
      reason: 'stopping the engine is what releases its Arc on the circle '
          'manager, its supervisor tasks, and the process-global session slot',
    );
  });

  test('the heal timer is cancelled BEFORE the stop', () {
    // A periodic heal landing mid-teardown would restart the engine while this
    // is tearing it down — leaving a FRESH session orphaned instead of
    // releasing the old one, which is strictly worse than doing nothing.
    final cancel = detachedBody.indexOf('_liveSyncHealTimer?.cancel()');
    final stop = detachedBody.indexOf('liveSync.stop()');
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
    // the framework dispatches it without awaiting.
    expect(detachedBody.contains('on Object catch'), isTrue);
    // Anchored on the STATEMENT, not the word: the body's own comment says
    // "never rethrow", and a bare substring match would read that as a
    // violation. Source scans have to match syntax, not prose.
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
    expect(detachedBody.contains(r'${e.runtimeType}'), isTrue);
  });

  test('a resume after detached can restart the engine', () {
    // The release is only safe because coming back is handled: the resume path
    // heals unconditionally, ahead of its own debounce.
    final resume = source.indexOf('Future<void> _onResumed() async {');
    expect(resume, isNonNegative);
    final heal = source.indexOf('_healLiveSyncIfStopped()', resume);
    final debounce = source.indexOf('_resumeStopwatch.elapsed', resume);
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
    test('live-sync is stopped BEFORE the manager is released', () {
      // The engine holds its own Arc on the circle manager, so releasing the
      // manager first leaves the guard held by the engine and hands over
      // nothing — the foreground service still cannot open, and background
      // publishing stays dead for the whole session.
      final src = File('lib/src/pages/map_shell.dart').readAsStringSync();
      final at = src.indexOf('Future<void> _handOffMlsSession() async {');
      expect(at, isNonNegative, reason: 'the handoff must exist');
      // Bounded by the NEXT member's doc, so the ordering below is read from
      // the handoff alone and cannot be satisfied by its mirror underneath it.
      final body = src.substring(
        at,
        src.indexOf('\n  /// Takes the MLS session back', at),
      );

      final stop = body.indexOf('_liveSync?.stop()');
      final release = body.indexOf('releaseForHandoff()');
      expect(stop, isNonNegative);
      expect(release, isNonNegative);
      expect(
        stop,
        lessThan(release),
        reason: 'releasing before the engine stops frees nothing',
      );
    });

    test('the handoff is confined to the Android background-sharing path', () {
      // It is the one configuration where another isolate needs the session
      // while this one is merely paused. On iOS this isolate keeps publishing.
      final src = File('lib/src/pages/map_shell.dart').readAsStringSync();
      // The CALL, not the definition — which appears earlier in the file.
      final call = src.indexOf('await _handOffMlsSession();');
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
      final heal = resumeBody.indexOf('_healLiveSyncIfStopped()');
      final debounce = resumeBody.indexOf('_resumeStopwatch.elapsed');
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
