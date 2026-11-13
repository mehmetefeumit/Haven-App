/// Unit tests for [OwnProfileSyncController] / [ownProfileSyncProvider].
///
/// Verifies:
/// - build() makes no service call at all: it neither reads the outbox nor
///   syncs (the cold-start trigger lives in `map_shell.dart`).
/// - retryIfPending() syncs ONLY when a save is pending AND the backoff is
///   due, and is a true no-op (no `syncOwnProfile` call) when the outbox is
///   clean or the backoff is not due.
/// - sync() coalesces overlapping calls to exactly one queued follow-up, and
///   a pass never starts an immediate follow-up of its own.
/// - a failed sync never escapes, never leaks error text and is retriable;
///   a throw that leaves the ladder due arms ONE 30 s fallback per failure
///   streak (reset by a completed pass or a resume), only while resumed; one
///   that fires while a pass is running is honoured when that pass settles.
/// - the foreground retry timer: ONE timer, armed to `max(nextRetryInSecs, 1)`
///   seconds only when the state is pending and not due AND the app is
///   resumed; checked again when it fires and after every pass; never
///   re-armed from a pass that left the state due; cancelled on pause and on
///   an identity-scope reset; re-armed on resume.
///
/// Timer tests are `testWidgets` so the fake clock advances with
/// `tester.pump(Duration)` instead of sleeping, and each dispatches
/// `resumed` FIRST: the test binding resets the lifecycle state to null
/// between tests, so without it no timer would ever arm and the assertions
/// would pass without proving anything. Each also disposes its container in
/// the body, because `addTearDown` runs after flutter_test's pending-timer
/// check.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/profile_sync_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/profile_service.dart';

import '../mocks/mock_profile_service.dart';

/// Drains pending microtasks so fire-and-forget work settles. Deterministic —
/// no wall-clock waiting, so this cannot flake under parallel load (mirrors
/// `member_profile_refresh_provider_test.dart`'s `settle()`).
Future<void> _settle() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

ProviderContainer _makeContainer(MockProfileService svc) {
  return ProviderContainer(
    overrides: [profileServiceProvider.overrideWithValue(svc)],
  );
}

/// Reads the notifier (triggering build()) and drains microtasks, so callers
/// start from a settled state.
Future<OwnProfileSyncController> _anchor(ProviderContainer container) async {
  final notifier = container.read(ownProfileSyncProvider.notifier);
  await _settle();
  return notifier;
}

int _syncCalls(MockProfileService svc) => svc.syncOwnProfileCalls;

const _cleanState = ProfilePendingState(pending: false, retryDue: false);

const _dueState = ProfilePendingState(pending: true, retryDue: true);

ProfilePendingState _waitingState(int? nextRetryInSecs) => ProfilePendingState(
  pending: true,
  retryDue: false,
  nextRetryInSecs: nextRetryInSecs,
);

const _publishedResult = ProfileSyncResult(
  outcome: ProfileSyncOutcome.published,
  stillPending: false,
);

const _publishedStillPendingResult = ProfileSyncResult(
  outcome: ProfileSyncOutcome.published,
  stillPending: true,
);

/// Lets the fake clock run [by] and then drains the microtasks the timer's
/// callback started.
Future<void> _elapse(WidgetTester tester, Duration by) async {
  await tester.pump(by);
  await tester.pump();
}

void _lifecycle(WidgetTester tester, AppLifecycleState state) =>
    tester.binding.handleAppLifecycleStateChanged(state);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('build()', () {
    test('makes no service call: it neither reads the outbox nor syncs',
        () async {
      final svc = MockProfileService()..nextPendingState = _dueState;
      final container = _makeContainer(svc);
      addTearDown(container.dispose);

      await _anchor(container);

      expect(
        svc.methodCalls,
        isEmpty,
        reason: 'cold start and resume are triggered from map_shell.dart; a '
            'second read here would be a second publish trigger',
      );
    });
  });

  group('retryIfPending()', () {
    test('is a true no-op when the outbox is clean', () async {
      final svc = MockProfileService()..nextPendingState = _cleanState;
      final container = _makeContainer(svc);
      addTearDown(container.dispose);
      final notifier = await _anchor(container);

      await notifier.retryIfPending();

      expect(_syncCalls(svc), 0);
      expect(
        svc.pendingSyncStateCalls,
        1,
        reason: 'anti-vacuity: the outbox was consulted',
      );
    });

    test('resumes a save a prior session left pending (retryDue)', () async {
      final svc = MockProfileService()
        ..nextPendingState = _dueState
        ..nextSyncResult = _publishedResult;
      final container = _makeContainer(svc);
      addTearDown(container.dispose);
      final notifier = await _anchor(container);
      expect(_syncCalls(svc), 0, reason: 'build() syncs nothing by itself');

      await notifier.retryIfPending();

      expect(
        _syncCalls(svc),
        1,
        reason: 'a pending save with the backoff due must be resumed when '
            'the cold-start / resume trigger asks',
      );
    });

    test(
      'is a true no-op when pending but the backoff is not due yet',
      () async {
        final svc = MockProfileService()
          ..nextPendingState = _waitingState(null);
        final container = _makeContainer(svc);
        addTearDown(container.dispose);
        final notifier = await _anchor(container);

        await notifier.retryIfPending();

        expect(
          _syncCalls(svc),
          0,
          reason: 'relay metadata minimization — never dial unconditionally',
        );
        expect(svc.pendingSyncStateCalls, 1);
      },
    );

    test(
      'neither starts nor queues a sync while one is in flight',
      () async {
        final svc = MockProfileService()
          ..nextPendingState = _cleanState
          ..nextSyncResult = _publishedStillPendingResult;
        final container = _makeContainer(svc);
        addTearDown(container.dispose);
        final notifier = await _anchor(container);

        final gate = Completer<void>();
        svc.syncOwnProfileGate = gate;
        unawaited(notifier.sync());
        await _settle();
        expect(_syncCalls(svc), 1, reason: 'anti-vacuity: a sync is in flight');

        // A resume lands while that sync is publishing, and the outbox
        // still says a retry is due.
        svc.nextPendingState = _dueState;
        await notifier.retryIfPending();
        expect(
          _syncCalls(svc),
          1,
          reason: 'the in-flight sync is already publishing what is pending',
        );

        gate.complete();
        await _settle();

        expect(
          _syncCalls(svc),
          1,
          reason: 'a follow-up queued here would publish again at once, '
              'past the backoff the in-flight sync has just recorded',
        );
      },
    );
  });

  group('sync() coalescing', () {
    test(
      'overlapping calls collapse to exactly one queued follow-up',
      () async {
        final svc = MockProfileService()
          ..nextPendingState = _cleanState
          ..nextSyncResult = _publishedResult;
        final container = _makeContainer(svc);
        addTearDown(container.dispose);
        final notifier = await _anchor(container);

        final gate = Completer<void>();
        svc.syncOwnProfileGate = gate;

        unawaited(notifier.sync());
        unawaited(notifier.sync());
        unawaited(notifier.sync());
        unawaited(notifier.sync());
        await _settle();

        expect(
          _syncCalls(svc),
          1,
          reason: 'every call while in flight must queue, not start a '
              'parallel publish',
        );

        gate.complete();
        await _settle();

        expect(
          _syncCalls(svc),
          2,
          reason: 'one in-flight publish plus exactly one coalesced '
              'follow-up — never one per queued call',
        );
      },
    );

    test(
      'a pass that is still pending starts no immediate follow-up of its own',
      () async {
        final svc = MockProfileService()
          ..nextPendingState = _cleanState
          ..nextSyncResult = _publishedStillPendingResult;
        final container = _makeContainer(svc);
        addTearDown(container.dispose);
        final notifier = await _anchor(container);

        await notifier.sync();
        await _settle();

        expect(
          _syncCalls(svc),
          1,
          reason: 'what a relay missed is left to the persisted backoff, not '
              'an immediate retry (relay metadata minimization)',
        );
      },
    );
  });

  group('failure handling', () {
    test(
      'a failed sync never escapes, never leaks raw error text and is '
      'retriable',
      () async {
        final svc = MockProfileService()
          ..nextPendingState = _cleanState
          ..shouldThrowOnSyncOwnProfile = true;
        final container = _makeContainer(svc);
        addTearDown(container.dispose);
        final notifier = await _anchor(container);

        final logged = <String>[];
        final original = debugPrint;
        debugPrint = (message, {wrapWidth}) {
          if (message != null) logged.add(message);
        };
        addTearDown(() => debugPrint = original);

        await notifier.sync();

        expect(_syncCalls(svc), 1);
        expect(
          logged,
          isNotEmpty,
          reason: 'anti-vacuity: the failure is logged',
        );
        expect(
          logged.join('\n'),
          isNot(contains('generic')),
          reason: "MockProfileService's ProfileServiceException message "
              'must never reach a log line (Rule 8)',
        );

        // Retriable: a later sync() (e.g. after fixing connectivity) runs
        // again rather than staying wedged.
        svc
          ..shouldThrowOnSyncOwnProfile = false
          ..nextSyncResult = _publishedResult;
        await notifier.sync();

        expect(_syncCalls(svc), 2);
      },
    );

    test(
      'uploadFailed/publishFailed/poolUnderflow complete without escaping '
      'and start no follow-up',
      () async {
        for (final outcome in [
          ProfileSyncOutcome.uploadFailed,
          ProfileSyncOutcome.publishFailed,
          ProfileSyncOutcome.poolUnderflow,
        ]) {
          final svc = MockProfileService()
            ..nextPendingState = _cleanState
            ..nextSyncResult = ProfileSyncResult(
              outcome: outcome,
              stillPending: true,
            );
          final container = _makeContainer(svc);
          addTearDown(container.dispose);
          final notifier = await _anchor(container);

          await notifier.sync();
          await _settle();

          expect(_syncCalls(svc), 1, reason: '$outcome must not loop');
        }
      },
    );
  });

  group('a pass that throws', () {
    testWidgets(
      'with the ladder still due retries once after 30 s, and never again '
      'while it keeps throwing',
      (tester) async {
        _lifecycle(tester, AppLifecycleState.resumed);
        final svc = MockProfileService()
          ..nextPendingState = _dueState
          ..shouldThrowOnSyncOwnProfile = true;
        final container = _makeContainer(svc);
        final notifier = container.read(ownProfileSyncProvider.notifier);

        await notifier.sync();
        expect(_syncCalls(svc), 1);

        await _elapse(tester, const Duration(seconds: 29));
        expect(_syncCalls(svc), 1);
        await _elapse(tester, const Duration(seconds: 1));
        expect(
          _syncCalls(svc),
          2,
          reason: 'a throw before Rust recorded an attempt leaves nothing '
              'else to retry before the next resume',
        );

        await _elapse(tester, const Duration(hours: 1));
        expect(
          _syncCalls(svc),
          2,
          reason: 'a persistent local fault must not loop',
        );
        container.dispose();
      },
    );

    testWidgets(
      'a queued pass that throws too keeps the one fallback retry',
      (tester) async {
        _lifecycle(tester, AppLifecycleState.resumed);
        final svc = MockProfileService()
          ..nextPendingState = _dueState
          ..shouldThrowOnSyncOwnProfile = true;
        final container = _makeContainer(svc);
        final notifier = container.read(ownProfileSyncProvider.notifier);

        final gate = Completer<void>();
        svc.syncOwnProfileGate = gate;
        unawaited(notifier.sync());
        unawaited(notifier.sync());
        await tester.pump();
        expect(_syncCalls(svc), 1, reason: 'anti-vacuity: the second queued');
        gate.complete();
        await tester.pump();
        expect(_syncCalls(svc), 2, reason: 'anti-vacuity: both passes threw');

        await _elapse(tester, const Duration(seconds: 29));
        expect(_syncCalls(svc), 2);
        await _elapse(tester, const Duration(seconds: 1));
        expect(
          _syncCalls(svc),
          3,
          reason: 'the second failure must not cancel the retry the first '
              'armed: nothing else retries before the next resume',
        );

        await _elapse(tester, const Duration(hours: 1));
        expect(_syncCalls(svc), 3, reason: 'still one fallback per streak');
        container.dispose();
      },
    );

    testWidgets(
      'a fallback that fires while a pass is still running is honoured when '
      'that pass throws too',
      (tester) async {
        _lifecycle(tester, AppLifecycleState.resumed);
        final svc = MockProfileService()
          ..nextPendingState = _dueState
          ..shouldThrowOnSyncOwnProfile = true;
        final container = _makeContainer(svc);
        final notifier = container.read(ownProfileSyncProvider.notifier);

        await notifier.sync();
        await _elapse(tester, const Duration(seconds: 20));
        final gate = Completer<void>();
        svc.syncOwnProfileGate = gate;
        unawaited(notifier.sync());
        await tester.pump();
        expect(_syncCalls(svc), 2, reason: 'anti-vacuity: a pass is running');

        await _elapse(tester, const Duration(seconds: 10));
        expect(
          _syncCalls(svc),
          2,
          reason: 'the fallback fired into a running pass, so starts nothing',
        );
        gate.complete();
        await tester.pump();
        expect(
          _syncCalls(svc),
          3,
          reason: 'that pass threw too: without the fallback nothing retries '
              'before the next resume',
        );

        await _elapse(tester, const Duration(hours: 1));
        expect(_syncCalls(svc), 3, reason: 'still one fallback per streak');
        container.dispose();
      },
    );

    testWidgets(
      'a fallback held for a running pass is dropped if the app is paused '
      'before that pass settles',
      (tester) async {
        _lifecycle(tester, AppLifecycleState.resumed);
        final svc = MockProfileService()
          ..nextPendingState = _dueState
          ..shouldThrowOnSyncOwnProfile = true;
        final container = _makeContainer(svc);
        final notifier = container.read(ownProfileSyncProvider.notifier);

        await notifier.sync();
        await _elapse(tester, const Duration(seconds: 20));
        final gate = Completer<void>();
        svc.syncOwnProfileGate = gate;
        unawaited(notifier.sync());
        await _elapse(tester, const Duration(seconds: 10));
        expect(_syncCalls(svc), 2, reason: 'anti-vacuity: a pass is running');

        _lifecycle(tester, AppLifecycleState.paused);
        gate.complete();
        await _elapse(tester, const Duration(hours: 1));

        expect(
          _syncCalls(svc),
          2,
          reason: 'a backgrounded process must not dial relays on a timer',
        );
        container.dispose();
      },
    );

    testWidgets(
      'a fallback whose read is still out when the app is paused is dropped '
      'too',
      (tester) async {
        _lifecycle(tester, AppLifecycleState.resumed);
        final svc = MockProfileService()
          ..nextPendingState = _dueState
          ..shouldThrowOnSyncOwnProfile = true;
        final container = _makeContainer(svc);
        final notifier = container.read(ownProfileSyncProvider.notifier);

        await notifier.sync();
        await _elapse(tester, const Duration(seconds: 20));
        final syncGate = Completer<void>();
        svc.syncOwnProfileGate = syncGate;
        unawaited(notifier.sync());
        await _elapse(tester, const Duration(seconds: 1));
        final readGate = Completer<void>();
        svc.pendingSyncStateGate = readGate;
        final readsBefore = svc.pendingSyncStateCalls;
        await _elapse(tester, const Duration(seconds: 9));
        expect(
          svc.pendingSyncStateCalls,
          readsBefore + 1,
          reason: 'anti-vacuity: the fallback fired and its read is out',
        );

        _lifecycle(tester, AppLifecycleState.paused);
        readGate.complete();
        await tester.pump();
        svc.pendingSyncStateGate = null;
        syncGate.complete();
        await _elapse(tester, const Duration(hours: 1));

        expect(
          _syncCalls(svc),
          2,
          reason: 'a backgrounded process must not dial relays on a timer',
        );
        container.dispose();
      },
    );

    testWidgets(
      'a pass that completes ends the streak: its fallback is dropped and a '
      'later throw arms a fresh one',
      (tester) async {
        _lifecycle(tester, AppLifecycleState.resumed);
        final svc = MockProfileService()
          ..nextPendingState = _dueState
          ..shouldThrowOnSyncOwnProfile = true;
        final container = _makeContainer(svc);
        final notifier = container.read(ownProfileSyncProvider.notifier);

        await notifier.sync();
        await _elapse(tester, const Duration(seconds: 10));

        svc
          ..shouldThrowOnSyncOwnProfile = false
          ..nextSyncResult = _publishedStillPendingResult;
        await notifier.sync();
        await _elapse(tester, const Duration(seconds: 10));

        svc.shouldThrowOnSyncOwnProfile = true;
        await notifier.sync();
        expect(_syncCalls(svc), 3);

        await _elapse(tester, const Duration(seconds: 29));
        expect(
          _syncCalls(svc),
          3,
          reason: "the first failure's fallback, due by now, went with its "
              'streak',
        );
        await _elapse(tester, const Duration(seconds: 1));
        expect(_syncCalls(svc), 4, reason: 'the fresh fallback fired');

        await _elapse(tester, const Duration(hours: 1));
        expect(_syncCalls(svc), 4);
        container.dispose();
      },
    );

    testWidgets('with an attempt on the ladder waits out the ladder', (
      tester,
    ) async {
      _lifecycle(tester, AppLifecycleState.resumed);
      final svc = MockProfileService()
        ..nextPendingState = _waitingState(60)
        ..shouldThrowOnSyncOwnProfile = true;
      final container = _makeContainer(svc);
      final notifier = container.read(ownProfileSyncProvider.notifier);

      await notifier.sync();
      svc.nextPendingState = _dueState;
      await _elapse(tester, const Duration(seconds: 59));
      expect(_syncCalls(svc), 1, reason: 'not the 30 s fallback');
      await _elapse(tester, const Duration(seconds: 1));
      expect(_syncCalls(svc), 2);
      container.dispose();
    });

    testWidgets('a resume allows exactly one more fallback', (tester) async {
      _lifecycle(tester, AppLifecycleState.resumed);
      final svc = MockProfileService()
        ..nextPendingState = _dueState
        ..shouldThrowOnSyncOwnProfile = true;
      final container = _makeContainer(svc);
      final notifier = container.read(ownProfileSyncProvider.notifier);
      await notifier.sync();
      await _elapse(tester, const Duration(minutes: 10));
      expect(_syncCalls(svc), 2, reason: 'anti-vacuity: the streak is spent');

      _lifecycle(tester, AppLifecycleState.paused);
      _lifecycle(tester, AppLifecycleState.resumed);
      await tester.pump();
      expect(_syncCalls(svc), 3, reason: 'the resume syncs a due save');

      await _elapse(tester, const Duration(seconds: 30));
      expect(_syncCalls(svc), 4);
      await _elapse(tester, const Duration(hours: 1));
      expect(_syncCalls(svc), 4);
      container.dispose();
    });

    testWidgets('while paused arms nothing', (tester) async {
      _lifecycle(tester, AppLifecycleState.resumed);
      final svc = MockProfileService()
        ..nextPendingState = _dueState
        ..shouldThrowOnSyncOwnProfile = true;
      final container = _makeContainer(svc);
      final notifier = container.read(ownProfileSyncProvider.notifier);
      _lifecycle(tester, AppLifecycleState.paused);

      await notifier.sync();
      await _elapse(tester, const Duration(hours: 1));

      expect(_syncCalls(svc), 1);
      container.dispose();
    });

    testWidgets('dispose cancels the fallback', (tester) async {
      _lifecycle(tester, AppLifecycleState.resumed);
      final svc = MockProfileService()
        ..nextPendingState = _dueState
        ..shouldThrowOnSyncOwnProfile = true;
      final container = _makeContainer(svc);
      await container.read(ownProfileSyncProvider.notifier).sync();

      container.dispose();
      await _elapse(tester, const Duration(minutes: 5));

      expect(_syncCalls(svc), 1);
    });
  });

  group('foreground retry timer', () {
    testWidgets(
      'a pending save that is not yet due arms exactly one timer and syncs '
      'nothing until it fires',
      (tester) async {
        _lifecycle(tester, AppLifecycleState.resumed);
        final svc = MockProfileService()
          ..nextPendingState = _waitingState(30)
          ..nextSyncResult = _publishedResult;
        final container = _makeContainer(svc);
        final notifier = container.read(ownProfileSyncProvider.notifier);

        // Two reads arm twice; a second live timer would sync twice below.
        await notifier.retryIfPending();
        await notifier.retryIfPending();
        expect(_syncCalls(svc), 0);

        await _elapse(tester, const Duration(seconds: 29));
        expect(
          _syncCalls(svc),
          0,
          reason: 'nothing syncs before nextRetryInSecs elapses',
        );

        svc.nextPendingState = _dueState;
        await _elapse(tester, const Duration(seconds: 1));
        expect(_syncCalls(svc), 1, reason: 'the timer fired and synced');

        await _elapse(tester, const Duration(hours: 1));
        expect(
          _syncCalls(svc),
          1,
          reason: 'exactly one timer ever existed, and the due pass armed '
              'no other',
        );
        container.dispose();
      },
    );

    testWidgets(
      'a pass that ends pending and not due arms the retry timer',
      (tester) async {
        _lifecycle(tester, AppLifecycleState.resumed);
        final svc = MockProfileService()
          ..nextPendingState = _waitingState(30)
          ..nextSyncResult = _publishedStillPendingResult;
        final container = _makeContainer(svc);
        final notifier = container.read(ownProfileSyncProvider.notifier);

        await notifier.sync();
        expect(_syncCalls(svc), 1);

        await _elapse(tester, const Duration(seconds: 29));
        expect(_syncCalls(svc), 1);

        svc.nextPendingState = _dueState;
        await _elapse(tester, const Duration(seconds: 1));
        expect(
          _syncCalls(svc),
          2,
          reason: 'the pass left a save waiting on the ladder, so the timer '
              'retries it when the rung is due',
        );
        container.dispose();
      },
    );

    testWidgets('the timer syncs only if the state is due when it fires', (
      tester,
    ) async {
      _lifecycle(tester, AppLifecycleState.resumed);
      final svc = MockProfileService()..nextPendingState = _waitingState(30);
      final container = _makeContainer(svc);
      final notifier = container.read(ownProfileSyncProvider.notifier);
      await notifier.retryIfPending();
      final readsBefore = svc.pendingSyncStateCalls;

      // Another path published everything while the timer was waiting.
      svc.nextPendingState = _cleanState;
      await _elapse(tester, const Duration(seconds: 31));

      expect(
        svc.pendingSyncStateCalls,
        greaterThan(readsBefore),
        reason: 'anti-vacuity: the timer fired and asked',
      );
      expect(_syncCalls(svc), 0);
      container.dispose();
    });

    testWidgets('a pass that leaves the state due does not re-arm a timer', (
      tester,
    ) async {
      _lifecycle(tester, AppLifecycleState.resumed);
      final svc = MockProfileService()
        ..nextPendingState = _dueState
        ..nextSyncResult = const ProfileSyncResult(
          outcome: ProfileSyncOutcome.poolUnderflow,
          stillPending: true,
        );
      final container = _makeContainer(svc);
      final notifier = container.read(ownProfileSyncProvider.notifier);

      await notifier.retryIfPending();
      expect(_syncCalls(svc), 1);

      await _elapse(tester, const Duration(hours: 1));

      expect(
        _syncCalls(svc),
        1,
        reason: 'a state that is still due after a pass waits for the next '
            'resume or cold start, never a tight loop',
      );
      container.dispose();
    });

    testWidgets(
      'backgrounding cancels the retry timer and resuming re-arms it through '
      'retryIfPending',
      (tester) async {
        _lifecycle(tester, AppLifecycleState.resumed);
        final svc = MockProfileService()
          ..nextPendingState = _waitingState(30)
          ..nextSyncResult = _publishedResult;
        final container = _makeContainer(svc);
        final notifier = container.read(ownProfileSyncProvider.notifier);
        await notifier.retryIfPending();

        _lifecycle(tester, AppLifecycleState.paused);
        svc.nextPendingState = _dueState;
        await _elapse(tester, const Duration(minutes: 5));
        expect(
          _syncCalls(svc),
          0,
          reason: 'a backgrounded process must not dial relays on a timer',
        );

        svc.nextPendingState = _waitingState(20);
        _lifecycle(tester, AppLifecycleState.resumed);
        await notifier.retryIfPending();
        expect(_syncCalls(svc), 0);

        svc.nextPendingState = _dueState;
        await _elapse(tester, const Duration(seconds: 20));
        expect(
          _syncCalls(svc),
          1,
          reason: 'one timer, re-armed by the resume, fired',
        );
        container.dispose();
      },
    );

    testWidgets(
      'hidden and detached cancel the retry timer like paused',
      (tester) async {
        for (final away in [
          AppLifecycleState.hidden,
          AppLifecycleState.detached,
        ]) {
          _lifecycle(tester, AppLifecycleState.resumed);
          final svc = MockProfileService()
            ..nextPendingState = _waitingState(30);
          final container = _makeContainer(svc);
          final notifier = container.read(ownProfileSyncProvider.notifier);
          await notifier.retryIfPending();

          _lifecycle(tester, away);
          svc.nextPendingState = _dueState;
          await _elapse(tester, const Duration(minutes: 5));

          expect(_syncCalls(svc), 0, reason: '$away must cancel the timer');
          container.dispose();
        }
      },
    );

    testWidgets('a pass that ends while the app is paused arms no timer', (
      tester,
    ) async {
      _lifecycle(tester, AppLifecycleState.resumed);
      final svc = MockProfileService()
        ..nextPendingState = _waitingState(30)
        ..nextSyncResult = _publishedStillPendingResult;
      final container = _makeContainer(svc);
      final notifier = container.read(ownProfileSyncProvider.notifier);

      final gate = Completer<void>();
      svc.syncOwnProfileGate = gate;
      unawaited(notifier.sync());
      await tester.pump();
      expect(_syncCalls(svc), 1, reason: 'anti-vacuity: the pass is running');

      _lifecycle(tester, AppLifecycleState.paused);
      gate.complete();
      await tester.pump();

      svc.nextPendingState = _dueState;
      await _elapse(tester, const Duration(hours: 1));

      expect(
        _syncCalls(svc),
        1,
        reason: 'the main isolate stays alive under the foreground service '
            'and the iOS location session; a pass ending there must not '
            'start the ladder',
      );
      container.dispose();
    });

    testWidgets(
      'a resume within the map-shell debounce window still re-arms the timer',
      (tester) async {
        _lifecycle(tester, AppLifecycleState.resumed);
        final svc = MockProfileService()
          ..nextPendingState = _waitingState(30)
          ..nextSyncResult = _publishedResult;
        final container = _makeContainer(svc);
        final notifier = container.read(ownProfileSyncProvider.notifier);
        await notifier.retryIfPending();

        _lifecycle(tester, AppLifecycleState.paused);
        await tester.pump();
        final readsBefore = svc.pendingSyncStateCalls;

        // Only the lifecycle event: map_shell's resume handler returns on
        // its 30 s debounce before it reaches its own retry trigger.
        _lifecycle(tester, AppLifecycleState.resumed);
        await tester.pump();
        expect(
          svc.pendingSyncStateCalls,
          greaterThan(readsBefore),
          reason: "the controller's own observer re-read the outbox",
        );

        svc.nextPendingState = _dueState;
        await _elapse(tester, const Duration(seconds: 30));

        expect(
          _syncCalls(svc),
          1,
          reason: 'a brief app switch must not strand a pending save',
        );
        container.dispose();
      },
    );

    testWidgets('a resume with a due save syncs it at once', (tester) async {
      _lifecycle(tester, AppLifecycleState.resumed);
      final svc = MockProfileService()
        ..nextPendingState = _cleanState
        ..nextSyncResult = _publishedResult;
      final container = _makeContainer(svc);
      container.read(ownProfileSyncProvider.notifier);

      _lifecycle(tester, AppLifecycleState.paused);
      await tester.pump();
      svc.nextPendingState = _dueState;
      _lifecycle(tester, AppLifecycleState.resumed);
      await tester.pump();

      expect(_syncCalls(svc), 1);
      container.dispose();
    });

    testWidgets(
      'invalidating the provider (identity-scope reset) cancels the timer',
      (tester) async {
        _lifecycle(tester, AppLifecycleState.resumed);
        final svc = MockProfileService()..nextPendingState = _waitingState(30);
        final container = _makeContainer(svc);
        final notifier = container.read(ownProfileSyncProvider.notifier);
        await notifier.retryIfPending();

        container.invalidate(ownProfileSyncProvider);
        // Re-read so the rebuilt notifier is live and registered.
        container.read(ownProfileSyncProvider.notifier);
        svc.nextPendingState = _dueState;
        await _elapse(tester, const Duration(minutes: 5));
        expect(
          _syncCalls(svc),
          0,
          reason: 'the old controller\'s timer fired nothing',
        );

        // One resume reaches exactly the new observer: it is registered once
        // and the old one is gone. A not-due save keeps it to the one read.
        svc.nextPendingState = _waitingState(30);
        final readsBefore = svc.pendingSyncStateCalls;
        _lifecycle(tester, AppLifecycleState.paused);
        _lifecycle(tester, AppLifecycleState.resumed);
        await tester.pump();
        expect(svc.pendingSyncStateCalls, readsBefore + 1);
        expect(_syncCalls(svc), 0);
        container.dispose();
      },
    );

    testWidgets(
      'a pendingSyncState that throws or fails closed never arms a timer',
      (tester) async {
        _lifecycle(tester, AppLifecycleState.resumed);

        final throwing = MockProfileService()
          ..shouldThrowOnPendingSyncState = true;
        final throwingContainer = _makeContainer(throwing);
        await throwingContainer
            .read(ownProfileSyncProvider.notifier)
            .retryIfPending();

        final failedClosed = MockProfileService()
          ..nextPendingState = _waitingState(null);
        final closedContainer = _makeContainer(failedClosed);
        await closedContainer
            .read(ownProfileSyncProvider.notifier)
            .retryIfPending();

        throwing
          ..shouldThrowOnPendingSyncState = false
          ..nextPendingState = _dueState;
        failedClosed.nextPendingState = _dueState;
        await _elapse(tester, const Duration(hours: 7));

        expect(_syncCalls(throwing), 0);
        expect(_syncCalls(failedClosed), 0);
        throwingContainer.dispose();
        closedContainer.dispose();
      },
    );

    testWidgets(
      'nextRetryInSecs of zero or a negative value waits at least one second',
      (tester) async {
        _lifecycle(tester, AppLifecycleState.resumed);
        for (final secs in [0, -5]) {
          final svc = MockProfileService()
            ..nextPendingState = _waitingState(secs)
            ..nextSyncResult = _publishedResult;
          final container = _makeContainer(svc);
          await container
              .read(ownProfileSyncProvider.notifier)
              .retryIfPending();

          svc.nextPendingState = _dueState;
          await _elapse(tester, const Duration(milliseconds: 900));
          expect(
            _syncCalls(svc),
            0,
            reason: '$secs must not become an immediate (tight-loop) timer',
          );

          await _elapse(tester, const Duration(milliseconds: 200));
          expect(_syncCalls(svc), 1, reason: '$secs waits one second');
          container.dispose();
        }
      },
    );
  });
}
