/// Unit tests for [OwnProfileSyncController] / [ownProfileSyncProvider].
///
/// Verifies:
/// - build() starts at `unknown` (renders nothing) and, when the local
///   outbox is clean, settles to `synced` WITHOUT ever calling
///   [ProfileService.syncOwnProfile] (no network for a clean install).
/// - build() resumes a save a prior session left pending, via
///   [ProfileService.pendingSyncState]'s `retryDue`.
/// - retryIfPending() is a true no-op (no `syncOwnProfile` call) both when
///   the outbox is clean AND when it is pending but the backoff is not due.
/// - sync() coalesces overlapping calls to exactly one queued follow-up.
/// - a failed sync is retriable (state resets so a later `sync()` runs again).
/// - no raw error text ever reaches `state` (it is a plain enum).
/// - a partial acknowledgement resolves to `partial`, not `synced`/`failed`.
/// - a fully-acked pass that is still pending (a newer edit landed mid-flight)
///   queues exactly one immediate follow-up sync.
///
/// Every test first anchors the notifier and drains its build()-time
/// `retryIfPending()` call BEFORE taking any further action — build() always
/// starts that call unawaited, and racing a second call against it would
/// make assertions depend on microtask scheduling order rather than on the
/// behavior under test.
library;

import 'dart:async';

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

/// Reads the notifier (triggering build()) and drains its internal
/// `retryIfPending()` call, so callers start from a settled state.
Future<OwnProfileSyncController> _anchor(ProviderContainer container) async {
  final notifier = container.read(ownProfileSyncProvider.notifier);
  await _settle();
  return notifier;
}

int _syncCalls(MockProfileService svc) =>
    svc.methodCalls.where((c) => c.method == 'syncOwnProfile').length;

const _cleanState = ProfilePendingState(
  pending: false,
  partial: false,
  retryDue: false,
);

const _partialResult = ProfileSyncResult(
  outcome: ProfileSyncOutcome.published,
  relaysAcked: 1,
  relaysAttempted: 3,
  stillPending: true,
);

const _fullyAckedStillPendingResult = ProfileSyncResult(
  outcome: ProfileSyncOutcome.published,
  relaysAcked: 3,
  relaysAttempted: 3,
  stillPending: true,
);

const _fullyAckedResult = ProfileSyncResult(
  outcome: ProfileSyncOutcome.published,
  relaysAcked: 3,
  relaysAttempted: 3,
  stillPending: false,
);

void main() {
  group('build()', () {
    test('starts at unknown', () {
      final svc = MockProfileService();
      final container = _makeContainer(svc);
      addTearDown(container.dispose);

      // Checked BEFORE the build()-time retryIfPending() has a chance to
      // run (no await yet) — this is the one assertion that must observe
      // the pre-settle value.
      container.read(ownProfileSyncProvider.notifier);
      expect(
        container.read(ownProfileSyncProvider),
        ProfileSyncStatus.unknown,
      );
    });

    test(
      'a clean outbox settles to synced without ever calling syncOwnProfile',
      () async {
        final svc = MockProfileService()..nextPendingState = _cleanState;
        final container = _makeContainer(svc);
        addTearDown(container.dispose);

        await _anchor(container);

        expect(
          container.read(ownProfileSyncProvider),
          ProfileSyncStatus.synced,
        );
        expect(
          _syncCalls(svc),
          0,
          reason: 'a clean install must never dial a relay just to discover '
              'it had nothing to say',
        );
      },
    );

    test('resumes a save a prior session left pending (retryDue)', () async {
      final svc = MockProfileService()
        ..nextPendingState = const ProfilePendingState(
          pending: true,
          partial: false,
          retryDue: true,
        )
        ..nextSyncResult = _fullyAckedResult;
      final container = _makeContainer(svc);
      addTearDown(container.dispose);

      await _anchor(container);

      expect(
        _syncCalls(svc),
        1,
        reason: 'a pending save with the backoff due must be resumed on '
            'build()',
      );
      expect(
        container.read(ownProfileSyncProvider),
        ProfileSyncStatus.synced,
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
        container.read(ownProfileSyncProvider),
        ProfileSyncStatus.synced,
      );
    });

    test(
      'is a true no-op when pending but the backoff is not due yet',
      () async {
        final svc = MockProfileService()
          ..nextPendingState = const ProfilePendingState(
            pending: true,
            partial: true,
            retryDue: false,
          );
        final container = _makeContainer(svc);
        addTearDown(container.dispose);
        final notifier = await _anchor(container);

        await notifier.retryIfPending();

        expect(
          _syncCalls(svc),
          0,
          reason: 'relay metadata minimization — never dial unconditionally',
        );
        expect(
          container.read(ownProfileSyncProvider),
          ProfileSyncStatus.partial,
          reason: 'the resting state must still be honest even without a '
              'network attempt',
        );
      },
    );

    test(
      'resolves to failed (not partial) when pending, not due, and not '
      'partial',
      () async {
        final svc = MockProfileService()
          ..nextPendingState = const ProfilePendingState(
            pending: true,
            partial: false,
            retryDue: false,
          );
        final container = _makeContainer(svc);
        addTearDown(container.dispose);
        final notifier = await _anchor(container);

        await notifier.retryIfPending();

        expect(
          container.read(ownProfileSyncProvider),
          ProfileSyncStatus.failed,
        );
        expect(_syncCalls(svc), 0);
      },
    );
  });

  group('sync() coalescing', () {
    test(
      'overlapping calls collapse to exactly one queued follow-up',
      () async {
        final svc = MockProfileService()
          ..nextPendingState = _cleanState
          ..nextSyncResult = _fullyAckedResult;
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
        expect(
          container.read(ownProfileSyncProvider),
          ProfileSyncStatus.syncing,
        );

        gate.complete();
        await _settle();

        expect(
          _syncCalls(svc),
          2,
          reason: 'one in-flight publish plus exactly one coalesced '
              'follow-up — never one per queued call',
        );
        expect(
          container.read(ownProfileSyncProvider),
          ProfileSyncStatus.synced,
        );
      },
    );
  });

  group('failure handling', () {
    test(
      'a failed sync never leaks raw error text and is retriable',
      () async {
        final svc = MockProfileService()
          ..nextPendingState = _cleanState
          ..shouldThrowOnSyncOwnProfile = true;
        final container = _makeContainer(svc);
        addTearDown(container.dispose);
        final notifier = await _anchor(container);

        await notifier.sync();

        expect(
          container.read(ownProfileSyncProvider),
          ProfileSyncStatus.failed,
        );
        // The state is a plain enum with no message field at all — the
        // strongest form of "no raw error text": there is no string
        // channel for one to travel through in the first place.
        expect(
          container.read(ownProfileSyncProvider).toString(),
          isNot(contains('generic')),
          reason: "MockProfileService's ProfileServiceException message "
              'must never surface via the sync status',
        );

        // Retriable: a later sync() (e.g. after fixing connectivity) runs
        // again rather than staying wedged in `failed`.
        svc
          ..shouldThrowOnSyncOwnProfile = false
          ..nextSyncResult = _fullyAckedResult;
        await notifier.sync();

        expect(
          container.read(ownProfileSyncProvider),
          ProfileSyncStatus.synced,
        );
        expect(_syncCalls(svc), 2);
      },
    );

    test(
      'uploadFailed/publishFailed/poolUnderflow all resolve to failed',
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
              relaysAcked: 0,
              relaysAttempted: 3,
              stillPending: true,
            );
          final container = _makeContainer(svc);
          addTearDown(container.dispose);
          final notifier = await _anchor(container);

          await notifier.sync();

          expect(
            container.read(ownProfileSyncProvider),
            ProfileSyncStatus.failed,
            reason: '$outcome must resolve to failed',
          );
        }
      },
    );
  });

  group('outcome resolution', () {
    test(
      'a partial acknowledgement resolves to partial, with no immediate '
      'follow-up',
      () async {
        final svc = MockProfileService()
          ..nextPendingState = _cleanState
          ..nextSyncResult = _partialResult;
        final container = _makeContainer(svc);
        addTearDown(container.dispose);
        final notifier = await _anchor(container);

        await notifier.sync();
        await _settle();

        expect(
          container.read(ownProfileSyncProvider),
          ProfileSyncStatus.partial,
        );
        expect(
          _syncCalls(svc),
          1,
          reason: 'partial COVERAGE is left to the persisted backoff, not '
              'an immediate retry (relay metadata minimization)',
        );
      },
    );

    test(
      'a fully-acked pass that is still pending (a newer edit landed '
      'mid-flight) queues exactly one follow-up sync',
      () async {
        final svc = MockProfileService()
          ..nextPendingState = _cleanState
          // First call: fully acked but a newer edit is still pending ->
          // queues the follow-up. Second call (the follow-up): fully
          // synced -> terminates the chain. `syncResultQueue` gives each
          // call its answer deterministically, without racing a shared
          // field mutation against exactly when each call reads it —
          // reusing the still-pending result for both would loop forever,
          // which would be a bug in the controller, not a slow test.
          ..syncResultQueue.addAll([
            _fullyAckedStillPendingResult,
            _fullyAckedResult,
          ]);
        final container = _makeContainer(svc);
        addTearDown(container.dispose);
        final notifier = await _anchor(container);

        await notifier.sync();
        await _settle();

        expect(
          _syncCalls(svc),
          2,
          reason: 'fully-acked-but-still-pending must trigger exactly one '
              'immediate follow-up, distinct from a merely partial pass',
        );
        expect(
          container.read(ownProfileSyncProvider),
          ProfileSyncStatus.synced,
        );
      },
    );

    test(
      'nothingPending resolves the resting state from pendingSyncState',
      () async {
        final svc = MockProfileService()..nextPendingState = _cleanState;
        final container = _makeContainer(svc);
        addTearDown(container.dispose);
        final notifier = await _anchor(container);

        // A later, independent trigger observes new pending work that
        // landed after build() already settled clean.
        svc.nextPendingState = const ProfilePendingState(
          pending: true,
          partial: true,
          retryDue: false,
        );
        // nextSyncResult stays at its nothingPending default.

        await notifier.sync();

        expect(
          container.read(ownProfileSyncProvider),
          ProfileSyncStatus.partial,
        );
      },
    );
  });
}
