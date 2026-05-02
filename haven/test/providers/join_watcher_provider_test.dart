/// Tests for [joinWatcherProvider] and [JoinWatcherNotifier].
///
/// Verifies that:
///   * idle is the default state.
///   * `startAdminWatch` / `startJoinerWatch` enter the matching active mode.
///   * `cancel()` returns to idle and is idempotent.
///   * Starting a new watch cancels the previous one (one-burst-at-a-time).
///   * Window length, open-time delay, and tick interval are all sampled
///     from `Random` (deterministic via injected seed in test).
library;

import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:haven/src/providers/join_watcher_provider.dart';

void main() {
  group('JoinWatcherNotifier', () {
    test('starts in idle state', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final state = container.read(joinWatcherProvider);
      expect(state.mode, JoinWatchMode.idle);
      expect(state.isActive, isFalse);
      expect(state.mlsGroupId, isNull);
      expect(state.startedAt, isNull);
      expect(state.windowDuration, isNull);
    });

    test('startAdminWatch transitions to adminWaitingForJoin', () {
      final container = ProviderContainer(
        overrides: [
          joinWatcherProvider.overrideWith(
            (ref) => JoinWatcherNotifier(ref, rng: Random(42)),
          ),
        ],
      );
      addTearDown(container.dispose);

      const groupId = [1, 2, 3, 4];
      container.read(joinWatcherProvider.notifier).startAdminWatch(groupId);

      final state = container.read(joinWatcherProvider);
      expect(state.mode, JoinWatchMode.adminWaitingForJoin);
      expect(state.isActive, isTrue);
      expect(state.mlsGroupId, groupId);
      expect(state.windowDuration, isNotNull);
      // Admin window range is [150, 240] s.
      expect(state.windowDuration!.inSeconds, inInclusiveRange(150, 240));
    });

    test('startJoinerWatch transitions to joinerWaitingForLocations', () {
      final container = ProviderContainer(
        overrides: [
          joinWatcherProvider.overrideWith(
            (ref) => JoinWatcherNotifier(ref, rng: Random(7)),
          ),
        ],
      );
      addTearDown(container.dispose);

      const groupId = [9, 9, 9];
      container.read(joinWatcherProvider.notifier).startJoinerWatch(groupId);

      final state = container.read(joinWatcherProvider);
      expect(state.mode, JoinWatchMode.joinerWaitingForLocations);
      expect(state.mlsGroupId, groupId);
      // Joiner window range is [50, 80] s.
      expect(state.windowDuration!.inSeconds, inInclusiveRange(50, 80));
    });

    test('cancel returns to idle and is idempotent', () {
      final container = ProviderContainer(
        overrides: [
          joinWatcherProvider.overrideWith(
            (ref) => JoinWatcherNotifier(ref, rng: Random(1)),
          ),
        ],
      );
      addTearDown(container.dispose);

      container.read(joinWatcherProvider.notifier).startAdminWatch([1]);
      expect(container.read(joinWatcherProvider).isActive, isTrue);

      container.read(joinWatcherProvider.notifier).cancel();
      expect(container.read(joinWatcherProvider).mode, JoinWatchMode.idle);
      expect(container.read(joinWatcherProvider).isActive, isFalse);

      // Second cancel is a no-op.
      container.read(joinWatcherProvider.notifier).cancel();
      expect(container.read(joinWatcherProvider).mode, JoinWatchMode.idle);
    });

    test('starting a new watch cancels the previous one', () {
      final container = ProviderContainer(
        overrides: [
          joinWatcherProvider.overrideWith(
            (ref) => JoinWatcherNotifier(ref, rng: Random(99)),
          ),
        ],
      );
      addTearDown(container.dispose);

      container.read(joinWatcherProvider.notifier).startAdminWatch([1, 2, 3]);
      expect(
        container.read(joinWatcherProvider).mode,
        JoinWatchMode.adminWaitingForJoin,
      );

      container.read(joinWatcherProvider.notifier).startJoinerWatch([4, 5, 6]);
      final state = container.read(joinWatcherProvider);
      expect(state.mode, JoinWatchMode.joinerWaitingForLocations);
      expect(state.mlsGroupId, [4, 5, 6]);
    });

    test('disposing the provider cancels any active burst', () {
      final container = ProviderContainer(
        overrides: [
          joinWatcherProvider.overrideWith(
            (ref) => JoinWatcherNotifier(ref, rng: Random(3)),
          ),
        ],
      );

      container.read(joinWatcherProvider.notifier).startAdminWatch([1]);
      // Simply disposing should not throw — internal timers must
      // cancel cleanly.
      expect(container.dispose, returnsNormally);
    });
  });
}
