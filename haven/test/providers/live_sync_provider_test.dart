import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/live_sync_provider.dart';
import 'package:haven/src/rust/api.dart';

void main() {
  group('liveSyncEnabled', () {
    test('defaults ON (M11 Phase B — production ships the engine)', () {
      // Phase B flipped the compile-time default to true, so a production
      // build and the default `flutter test` (no --dart-define) resolve the
      // persistent live-sync engine ON. The retained short-poll receive path
      // is reachable only via `--dart-define=HAVEN_LIVE_SYNC=false` (rollback /
      // flag-off e2e lanes).
      expect(liveSyncEnabled, isTrue);
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

    test('paused → its OWN phase, never disconnected', () {
      // A background burst closes its sockets on purpose. Reporting that as
      // `disconnected` would have the sharing-health model stamp a
      // "disconnected since" and, because a burst interval can be as long as
      // the fault-confirmation window, confirm a relay outage on a healthy
      // pause.
      const connected = SyncStatus(phase: SyncConnectionPhase.connected);
      final next = SyncStatusNotifier.mapReason(
        connected,
        FfiSyncStatusReason.paused,
      );
      expect(next.phase, SyncConnectionPhase.paused);
      expect(next.phase, isNot(SyncConnectionPhase.disconnected));
      expect(next.isConnected, isFalse);
    });

    test('paused keeps a recorded issue — a pause proves no recovery', () {
      const withIssue = SyncStatus(
        phase: SyncConnectionPhase.connected,
        lastIssue: FfiSyncStatusReason.relayError,
      );
      expect(
        SyncStatusNotifier.mapReason(
          withIssue,
          FfiSyncStatusReason.paused,
        ).lastIssue,
        FfiSyncStatusReason.relayError,
      );
    });

    test('every reason maps to exactly one phase, with no default arm', () {
      // Totality: `mapReason`'s switch is exhaustive, so a new FFI reason is a
      // compile error there. This iterates `values` so the mapping is also
      // proven TOTAL at runtime — no reason may throw or return null.
      for (final r in FfiSyncStatusReason.values) {
        expect(
          SyncStatusNotifier.mapReason(SyncStatus.idle, r).phase,
          isA<SyncConnectionPhase>(),
          reason: '$r must map to a phase',
        );
      }
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
