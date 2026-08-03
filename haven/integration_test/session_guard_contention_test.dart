/// The forced-contention negative control for Security Rule 14.
///
/// # Why this lane exists
///
/// Rule 14 — exactly one live MLS session per `session.sqlite` per process — is
/// a confidentiality control, not a tidiness one. Two live sessions would each
/// run their own in-memory epoch state and reuse an AES-GCM key and nonce at
/// the same `(epoch, leaf, generation)` over location payloads.
///
/// A week of work now sits on top of that guard: the background service's
/// reclaim, the UI isolate's handover, and the liveness query both consult. The
/// steady state after all of it is that NEITHER isolate gets stuck — which is
/// the goal, and also the problem. Nothing routinely drives a contended
/// acquire any more, so the fail-closed behaviour every one of those mechanisms
/// assumes could stop holding and every suite would stay green.
///
/// This forces the contention deliberately, against the real registry through
/// the real FFI on a real device — the layer host tests cannot reach, since
/// `LIVE_SESSIONS` is a Rust static shared by every isolate in the loaded `.so`.
///
/// # What is asserted, and what is deliberately not
///
/// The property is EXCLUSION: a second open of the same database must fail
/// while the first handle lives, and must succeed once it is released. This
/// does not assert anything about which isolate wins — that is a race by
/// design, and the recovery paths exist precisely because either can.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/rust/frb_generated.dart';
import 'package:haven/src/services/circle_service.dart'
    show CircleServiceException;
import 'package:haven/src/services/mls_session_handover.dart';
import 'package:haven/src/services/nostr_circle_service.dart';
import 'package:haven/src/services/nostr_relay_service.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

/// Pins the service to this lane's dedicated directory instead of the app's
/// real one, so nothing here can contend with a session another target holds.
class _FixedDataDirectory implements DataDirectoryProvider {
  const _FixedDataDirectory(this.path);

  final String path;

  @override
  Future<String> getDataDirectory() async => path;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late String dataDir;

  setUpAll(() async {
    await RustLib.init();
    await initKeyringStore();
    // A dedicated directory so this never contends with a real session that
    // another test in the same run may hold.
    final base = await getApplicationSupportDirectory();
    dataDir = '${base.path}/rule14_contention';
  });

  Future<CircleManagerFfi> open() async {
    final identity = await NostrIdentityManager.newInstance();
    await identity.createIdentity();
    final secret = await identity.getSecretBytes();
    try {
      return await CircleManagerFfi.newInstance(
        dataDir: dataDir,
        identitySecretBytes: secret,
      );
    } finally {
      // Security Rule 9: Dart has no zeroize, so scrub the copy we made.
      secret.fillRange(0, secret.length, 0);
    }
  }

  // testWidgets, not bare test: only a testWidgets body's failure is recorded
  // in the integration binding's results map, so only it can turn the drive
  // red. See test/lints/integration_test_propagation_test.dart.
  group('Rule 14 under forced contention', () {
    testWidgets('a second open fails closed while the first handle lives', (
      tester,
    ) async {
      final first = await open();
      try {
        // The property the reclaim, the handover, and the liveness query all
        // rest on. If this ever succeeds, two sessions hydrate from one
        // database and location payloads lose confidentiality.
        await expectLater(open(), throwsA(isA<Object>()));

        // And the registry agrees — this is what both recovery paths read to
        // decide whether recovery is even applicable.
        expect(
          await isSessionLive(dataDir: dataDir),
          isTrue,
          reason: 'the query must see the contention it exists to report',
        );
      } finally {
        first.dispose();
      }
    });

    testWidgets('releasing the handle frees the database', (tester) async {
      // The other half. Without this, "fails closed" could be satisfied by a
      // guard that never releases — which would lock the app out of its own
      // database for the life of the process rather than protecting it.
      final first = await open();
      first.dispose();

      expect(await isSessionLive(dataDir: dataDir), isFalse);
      final second = await open();
      second.dispose();
    });

    testWidgets('the handover observes a real release through the registry', (
      tester,
    ) async {
      // Drives the UI isolate's recovery against the REAL guard and the REAL
      // registry, rather than the injected doubles its unit tests use. The
      // "service" here is a stub that releases the handle when asked to stop,
      // which is exactly what the foreground service's onDestroy does.
      final held = await open();
      var stopped = false;
      var restarted = false;

      final outcome = await requestSessionHandover(
        dataDir: dataDir,
        isSessionLive: (dir) => isSessionLive(dataDir: dir),
        stopService: () async {
          stopped = true;
          held.dispose();
        },
        restartService: () async => restarted = true,
        backgroundSharingEnabled: true,
      );

      expect(stopped, isTrue);
      expect(
        outcome,
        HandoverOutcome.released,
        reason: 'the handover must detect the release through the registry, '
            'not assume it from the stop call returning',
      );
      expect(
        restarted,
        isTrue,
        reason: 'background sharing is the user setting, not the recovery\'s '
            'to change',
      );

      // The point of the whole exercise: the database is now openable.
      final recovered = await open();
      recovered.dispose();
    });

    testWidgets('a handed-off session is not taken back while backgrounded', (
      tester,
    ) async {
      // The other direction of the same guard, and the one that had no
      // coverage: handing the session DOWN to the foreground service.
      //
      // Releasing frees the guard for an instant. Keeping it free is a separate
      // property, and it is the one that was missing — a paused main isolate is
      // not a dead one, so its suspended publish chains, its live-sync
      // re-subscriber and its maintenance ticks all call back into the service
      // and simply re-open. The service's next 72-second tick then finds the
      // guard held by a provably-alive owner, its reclaim correctly declines,
      // and background publishing stays dead through the very handoff meant to
      // enable it (`e2e-fgs-publish`, run 30792258968).
      //
      // Real FFI and real registry: `LIVE_SESSIONS` is a Rust static that host
      // tests cannot reach, and "the guard is genuinely free AND this isolate
      // still refuses to take it" is only observable against the real one.
      final identity = await NostrIdentityManager.newInstance();
      await identity.createIdentity();
      final service = NostrCircleService(
        relayService: NostrRelayService(),
        dataDirectoryProvider: _FixedDataDirectory(dataDir),
        identitySecretBytesProvider: identity.getSecretBytes,
        // The app is backgrounded — the state a pause-time handoff lives in.
        isForegrounded: () => false,
      );

      await service.initialize();
      expect(
        await isSessionLive(dataDir: dataDir),
        isTrue,
        reason: 'the service must hold the guard before it can hand it over',
      );

      expect(service.releaseForHandoff(), isTrue);
      expect(
        await isSessionLive(dataDir: dataDir),
        isFalse,
        reason: 'the handoff is worthless if the guard is not actually free',
      );

      // THE assertion. The guard is free and this open would succeed on Rule 14
      // alone — it must be refused anyway, because the free guard belongs to
      // the foreground service now.
      await expectLater(
        service.getCircleManagerFfi(),
        throwsA(isA<CircleServiceException>()),
      );
      expect(
        await isSessionLive(dataDir: dataDir),
        isFalse,
        reason: 'a refused open must not have opened anything',
      );

      // So the service isolate can take it — the outcome the whole handoff
      // exists for.
      final fgs = await open();
      fgs.dispose();
    });

    testWidgets('the handover declines when the guard is free', (tester) async {
      // A failure with a free guard is something a handover cannot fix — a
      // locked keyring, a full disk. Stopping the service then would cost the
      // user background sharing for nothing.
      var stopped = false;
      final outcome = await requestSessionHandover(
        dataDir: dataDir,
        isSessionLive: (dir) => isSessionLive(dataDir: dir),
        stopService: () async => stopped = true,
        restartService: () async {},
        backgroundSharingEnabled: true,
      );

      expect(outcome, HandoverOutcome.notHeld);
      expect(stopped, isFalse, reason: 'the service must not be touched');
    });
  });
}
