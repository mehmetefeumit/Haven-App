/// A circle list emptied by a failed open of the MLS session is read again
/// once the session opens.
///
/// The real [NostrCircleService] and the real [circlesProvider], over a
/// scripted bridge: only the Rust open (`CircleManagerFfi.newInstance`) and
/// the manager it hands back are fakes. A separate file because
/// `RustLib.initMock` replaces the bridge for the whole isolate, and the
/// service tests elsewhere rely on an open that cannot succeed.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/rust/frb_generated.dart';
import 'package:haven/src/services/data_directory_provider.dart';
import 'package:haven/src/services/mls_session_handover.dart';
import 'package:haven/src/services/nostr_circle_service.dart';

import '../mocks/background_task_fakes.dart';

/// The bridge's open, scripted: refused while [guardHeld], as the Rule-14
/// guard refuses a second session, and otherwise handing back [manager].
class _ScriptedBridge implements RustLibApi {
  _ScriptedBridge(this.manager);

  final _CountingManager manager;
  bool guardHeld = false;
  int opens = 0;

  @override
  Future<CircleManagerFfi> crateApiCircleManagerFfiNew({
    required String dataDir,
    required List<int> identitySecretBytes,
  }) async {
    opens++;
    if (guardHeld) throw StateError('an MLS session is already open');
    return manager;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected call: ${invocation.memberName}');
}

class _CountingManager extends FakeCircleManager {
  _CountingManager({super.circles});

  int reads = 0;
  Object? readError;

  @override
  Future<List<CircleWithMembersFfi>> getVisibleCircles() {
    reads++;
    final error = readError;
    if (error != null) return Future.error(error);
    return super.getVisibleCircles();
  }
}

class _FixedDataDirectory implements DataDirectoryProvider {
  @override
  Future<String> getDataDirectory() async => '/haven-test-data';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _ScriptedBridge bridge;
  final circle = circleFixture(seed: 1);

  setUpAll(() {
    bridge = _ScriptedBridge(_CountingManager(circles: [circle]));
    RustLib.initMock(api: bridge);
  });

  setUp(() {
    bridge
      ..guardHeld = false
      ..opens = 0
      ..manager.reads = 0
      ..manager.readError = null;
  });

  /// The service the app builds, with the handover the UI isolate is wired
  /// with. [handover] answers what the foreground service did when asked to
  /// let go of the guard.
  NostrCircleService service({HandoverOutcome? handover}) => NostrCircleService(
    relayService: FakeNostrRelayService(),
    dataDirectoryProvider: _FixedDataDirectory(),
    keyringInitializer: () async {},
    // A fresh buffer per open: `withFreshSecret` scrubs what it is given.
    identitySecretBytesProvider: () async => List<int>.filled(32, 7),
    sessionHandover: handover == null ? null : (_) async => handover,
    isForegrounded: () => true,
  );

  /// A container whose [circlesProvider] is watched, as the map's sheet
  /// watches it, so an invalidation rebuilds it rather than waiting for a
  /// read.
  ProviderContainer watching(NostrCircleService service) {
    final container = ProviderContainer(
      overrides: [circleServiceProvider.overrideWithValue(service)],
    );
    addTearDown(container.dispose);
    container.listen(circlesProvider, (_, _) {});
    return container;
  }

  List<List<int>> groupIds(ProviderContainer container) => [
    for (final c in container.read(circlesProvider).requireValue) c.mlsGroupId,
  ];

  test(
    'a list emptied by a lost handover is read again once the session opens',
    () async {
      // The Android resume: the foreground service let go of the guard
      // (`released`) and was restarted, and the restarted service took the
      // guard back before the single retry — so the retry fails too.
      bridge.guardHeld = true;
      final svc = service(handover: HandoverOutcome.released);
      final container = watching(svc);

      expect(await container.read(circlesProvider.future), isEmpty);
      expect(bridge.opens, 2, reason: 'the first open and its one retry');

      // Any later opener — the heal backstop, a publish tick — gets the
      // session once the guard is free.
      bridge.guardHeld = false;
      await svc.initialize();
      // The re-read is scheduled by the open, not awaited by its caller.
      await pumpEventQueue();
      await container.read(circlesProvider.future);

      expect(
        groupIds(container),
        [circle.circle.mlsGroupId],
        reason:
            'the empty list was a failed read, not an answer: once the '
            'session opens the circles the user is in must come back without '
            'a process restart',
      );
    },
  );

  test(
    'a failed read waits for the session to open rather than retrying',
    () async {
      bridge.guardHeld = true;
      final svc = service();
      final container = watching(svc);

      expect(await container.read(circlesProvider.future), isEmpty);
      await pumpEventQueue();

      expect(
        bridge.opens,
        1,
        reason:
            'a retry here would be another handover — on Android a stop and '
            'restart of the foreground service — for a guard nothing has freed',
      );
      expect(container.read(circlesProvider).requireValue, isEmpty);
    },
  );

  test(
    'reads superseded while the session was closed re-read it once',
    () async {
      bridge.guardHeld = true;
      final svc = service();
      final container = watching(svc);

      expect(await container.read(circlesProvider.future), isEmpty);
      // A second failed read before the open: each one waits on the open, and
      // only the current one may act on it.
      container.invalidate(circlesProvider);
      expect(await container.read(circlesProvider.future), isEmpty);

      bridge.guardHeld = false;
      await svc.initialize();
      await container.read(circlesProvider.future);
      await pumpEventQueue();

      expect(groupIds(container), [circle.circle.mlsGroupId]);
      expect(
        bridge.manager.reads,
        1,
        reason: 'the superseded read must not re-read on its own',
      );
    },
  );

  test(
    'a read that fails over an open session retries once, not forever',
    () async {
      // The open succeeds and the read behind it fails: the session the read
      // waited for is already open, so it is asked once more — and a second
      // failure waits for the next open instead of rebuilding in a loop.
      bridge.manager.readError = StateError('database is locked');
      final container = watching(service());

      expect(await container.read(circlesProvider.future), isEmpty);
      await pumpEventQueue();
      await container.read(circlesProvider.future);
      await pumpEventQueue();

      expect(bridge.opens, 1);
      expect(bridge.manager.reads, 2);
      expect(container.read(circlesProvider).requireValue, isEmpty);
    },
  );
}
