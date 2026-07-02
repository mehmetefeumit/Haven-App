import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/live_sync_provider.dart';
import 'package:haven/src/rust/api.dart';

void main() {
  group('liveSyncEnabled', () {
    test('defaults OFF (pollers stay active until M11 rollout)', () {
      expect(liveSyncEnabled, isFalse);
    });
  });

  group('SyncStatusNotifier.mapReason', () {
    test('connecting/sessionStarted → connecting phase', () {
      for (final r in [
        FfiSyncStatusReason.connecting,
        FfiSyncStatusReason.sessionStarted,
        FfiSyncStatusReason.reconnecting,
      ]) {
        expect(
          SyncStatusNotifier.mapReason(SyncStatus.idle, r).phase,
          SyncConnectionPhase.connecting,
        );
      }
    });

    test('connected/backgroundResumed → connected + clears the last issue', () {
      const withIssue = SyncStatus(
        phase: SyncConnectionPhase.connecting,
        lastIssue: FfiSyncStatusReason.relayError,
      );
      for (final r in [
        FfiSyncStatusReason.connected,
        FfiSyncStatusReason.backgroundResumed,
      ]) {
        final next = SyncStatusNotifier.mapReason(withIssue, r);
        expect(next.phase, SyncConnectionPhase.connected);
        expect(next.lastIssue, isNull, reason: 'connecting clears prior issue');
        expect(next.isConnected, isTrue);
      }
    });

    test('disconnected → disconnected phase', () {
      const connected = SyncStatus(phase: SyncConnectionPhase.connected);
      expect(
        SyncStatusNotifier.mapReason(
          connected,
          FfiSyncStatusReason.disconnected,
        ).phase,
        SyncConnectionPhase.disconnected,
      );
    });

    test('a non-fatal issue records lastIssue WITHOUT dropping the phase', () {
      const connected = SyncStatus(phase: SyncConnectionPhase.connected);
      for (final r in [
        FfiSyncStatusReason.unprocessable,
        FfiSyncStatusReason.inboxError,
        FfiSyncStatusReason.relayError,
      ]) {
        final next = SyncStatusNotifier.mapReason(connected, r);
        expect(
          next.phase,
          SyncConnectionPhase.connected,
          reason: 'a single undecryptable event is not an outage',
        );
        expect(next.lastIssue, r);
      }
    });

    test('sessionStopped resets to idle', () {
      const connected = SyncStatus(phase: SyncConnectionPhase.connected);
      expect(
        SyncStatusNotifier.mapReason(
          connected,
          FfiSyncStatusReason.sessionStopped,
        ),
        SyncStatus.idle,
      );
    });
  });

  group('syncStatusProvider (runtime notifier)', () {
    test('onStatus transitions the held state through a container', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(syncStatusProvider), SyncStatus.idle);

      container
          .read(syncStatusProvider.notifier)
          .onStatus(FfiSyncStatusReason.connected);
      expect(
        container.read(syncStatusProvider).phase,
        SyncConnectionPhase.connected,
      );

      container
          .read(syncStatusProvider.notifier)
          .onStatus(FfiSyncStatusReason.relayError);
      // A relay error keeps the connected phase but records the issue.
      expect(
        container.read(syncStatusProvider).phase,
        SyncConnectionPhase.connected,
      );
      expect(
        container.read(syncStatusProvider).lastIssue,
        FfiSyncStatusReason.relayError,
      );

      container
          .read(syncStatusProvider.notifier)
          .onStatus(FfiSyncStatusReason.sessionStopped);
      expect(container.read(syncStatusProvider), SyncStatus.idle);
    });
  });
}
