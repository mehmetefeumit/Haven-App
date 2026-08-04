/// Tests for `LocationPublishSchedulerNotifier` — the foreground per-circle
/// location-publish scheduler that decorrelates a device's circles (each
/// publishes on its OWN independent jittered cadence instead of one shared tick
/// that fires them all in lockstep).
///
/// Verifies: one independent scheduler per eligible circle; a per-circle tick
/// publishes ONLY that circle; the FIFO chain serializes concurrent ticks
/// (Rule 14 single-writer); ineligible circles (orphaned / blocked) are never
/// scheduled; the disclosure gate blocks publishing; add/remove on circle-set
/// changes; and stop/start across the background handoff.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/location_publish_scheduler_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/location_service.dart';
import 'package:haven/src/services/location_sharing_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../mocks/mock_circle_service.dart';
import '../mocks/mock_relay_service.dart';

const _selfPubkey =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final identity = Identity(
    pubkeyHex: _selfPubkey,
    npub: 'npub1self',
    createdAt: DateTime(2025),
  );

  /// Builds a container whose scheduler publishes through a
  /// [MockCircleService] (returns [circles] from getVisibleCircles and records
  /// encryptLocation calls). The jitter sampler is deterministic. Disclosure is
  /// accepted unless [disclosureAccepted] is false.
  ({ProviderContainer container, MockCircleService mock}) build(
    List<Circle> circles, {
    bool disclosureAccepted = true,
    int sample = 120,
    LocationService? locationService,
  }) {
    SharedPreferences.setMockInitialValues({
      if (disclosureAccepted) kLocationDisclosureAcceptedKey: true,
    });
    final mock = MockCircleService(circles: circles);
    final sharing = LocationSharingService(
      circleService: mock,
      relayService: MockRelayService(),
    );
    final container = ProviderContainer(
      overrides: [
        identityServiceProvider.overrideWithValue(
          _MockIdentityService(identity: identity),
        ),
        locationServiceProvider.overrideWithValue(
          locationService ?? _FixedLocationService(),
        ),
        circleServiceProvider.overrideWithValue(mock),
        locationSharingServiceProvider.overrideWithValue(sharing),
        locationPublishJitterSamplerProvider.overrideWithValue((_) => sample),
      ],
    );
    addTearDown(container.dispose);
    return (container: container, mock: mock);
  }

  /// Reads the notifier and lets its `circlesProvider` listen resolve so the
  /// per-circle schedulers are armed.
  Future<LocationPublishSchedulerNotifier> ready(
    ProviderContainer container,
  ) async {
    final notifier =
        container.read(locationPublishSchedulerProvider.notifier);
    // circlesProvider is async (reads getVisibleCircles); pump until the
    // listen callback has synced the schedulers.
    await container.read(circlesProvider.future);
    await pumpEventQueue();
    return notifier;
  }

  group('LocationPublishSchedulerNotifier', () {
    test('one independent scheduler per eligible circle', () async {
      final a = TestCircleFactory.createCircle(
        mlsGroupId: const [1],
        nostrGroupId: const [10],
        members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
      );
      final b = TestCircleFactory.createCircle(
        mlsGroupId: const [2],
        nostrGroupId: const [20],
        members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
      );
      final env = build([a, b]);
      final notifier = await ready(env.container);

      expect(
        notifier.trackedCircleKeysForTest,
        {_hex(const [10]), _hex(const [20])},
        reason: 'each eligible circle gets its own scheduler',
      );
    });

    test('a per-circle tick publishes ONLY that circle', () async {
      final a = TestCircleFactory.createCircle(
        mlsGroupId: const [1],
        nostrGroupId: const [10],
        members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
      );
      final b = TestCircleFactory.createCircle(
        mlsGroupId: const [2],
        nostrGroupId: const [20],
        members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
      );
      final env = build([a, b]);
      final notifier = await ready(env.container);

      await notifier.triggerTickForTest(_hex(const [10]));

      expect(
        env.mock.encryptedMlsGroupIds,
        [const [1]],
        reason: 'firing circle A must publish A only — never its siblings '
            '(the whole point of decorrelation)',
      );
    });

    test('concurrent ticks are FIFO-serialized (Rule 14 single-writer)',
        () async {
      final a = TestCircleFactory.createCircle(
        mlsGroupId: const [1],
        nostrGroupId: const [10],
        members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
      );
      final b = TestCircleFactory.createCircle(
        mlsGroupId: const [2],
        nostrGroupId: const [20],
        members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
      );
      final env = build([a, b]);
      final notifier = await ready(env.container);

      // Hold every encryptLocation open at its start.
      final gate = Completer<void>();
      env.mock.encryptGate = gate;

      // Enqueue both circles' ticks without awaiting.
      notifier.triggerTickForTest(_hex(const [10]));
      final second = notifier.triggerTickForTest(_hex(const [20]));
      await pumpEventQueue();

      // Only the FIRST publish has started — the second is queued behind it.
      expect(
        env.mock.encryptedMlsGroupIds.length,
        1,
        reason: 'the FIFO chain must not start a second encryptLocation while '
            'the first is in flight (no two concurrent session writers)',
      );

      gate.complete();
      await second;

      expect(
        env.mock.encryptedMlsGroupIds,
        [const [1], const [2]],
        reason: 'both publish, in enqueue order, once the first releases',
      );
    });

    test('a HUNG publish does not wedge the chain for every other circle',
        () async {
      // The FIFO chain's structural failure mode: a link that never
      // completes raises no error, so `catchError` cannot see it, every
      // later tick for EVERY circle queues behind it, and only `build()`
      // resets the chain — neither stop/startScheduling does. One hung
      // await therefore ends location sharing for the rest of the process,
      // silently. The route that made this reachable was a backgrounded
      // iOS permission prompt that iOS defers and geolocator never
      // resolves.
      final a = TestCircleFactory.createCircle(
        mlsGroupId: const [1],
        nostrGroupId: const [10],
        members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
      );
      final b = TestCircleFactory.createCircle(
        mlsGroupId: const [2],
        nostrGroupId: const [20],
        members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
      );
      final wedging = _WedgingLocationService();
      addTearDown(wedging.release);
      final env = build([a, b], locationService: wedging);
      final notifier = await ready(env.container);
      notifier.publishLinkTimeoutForTest = const Duration(milliseconds: 50);

      // A's tick hangs inside getCurrentLocation; B's queues behind it.
      unawaited(notifier.triggerTickForTest(_hex(const [10])));
      final second = notifier.triggerTickForTest(_hex(const [20]));

      await second.timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail(
          'the chain never advanced past the wedged link — one hung publish '
          'kills location sharing for the whole process lifetime',
        ),
      );

      expect(
        env.mock.encryptedMlsGroupIds,
        [const [2]],
        reason: 'B must still publish; A never got a fix, so it must not',
      );
    });

    test('a legacy-orphaned circle is never scheduled', () async {
      final healthy = TestCircleFactory.createCircle(
        mlsGroupId: const [1],
        nostrGroupId: const [10],
        members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
      );
      // Default factory circle: accepted + no members == legacy-orphaned.
      final orphan = TestCircleFactory.createCircle(
        mlsGroupId: const [2],
        nostrGroupId: const [20],
      );
      final env = build([healthy, orphan]);
      final notifier = await ready(env.container);

      expect(notifier.trackedCircleKeysForTest, {_hex(const [10])});
    });

    test('a blocked (Unrecoverable) circle is never scheduled', () async {
      final healthy = TestCircleFactory.createCircle(
        mlsGroupId: const [1],
        nostrGroupId: const [10],
        members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
      );
      final blocked = TestCircleFactory.createCircle(
        mlsGroupId: const [3],
        nostrGroupId: const [30],
        members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
      );
      final env = build([healthy, blocked])
        ..mock.markCircleBlocked(const [3]);
      final notifier = await ready(env.container);

      expect(notifier.trackedCircleKeysForTest, {_hex(const [10])});
    });

    test('the disclosure gate blocks per-circle publishing', () async {
      final a = TestCircleFactory.createCircle(
        mlsGroupId: const [1],
        nostrGroupId: const [10],
        members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
      );
      final env = build([a], disclosureAccepted: false);
      final notifier = await ready(env.container);

      await notifier.triggerTickForTest(_hex(const [10]));

      expect(
        env.mock.encryptedMlsGroupIds,
        isEmpty,
        reason: 'no publish before the foreground disclosure is accepted',
      );
    });

    test('stopScheduling cancels all schedulers; startScheduling re-arms',
        () async {
      final a = TestCircleFactory.createCircle(
        mlsGroupId: const [1],
        nostrGroupId: const [10],
        members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
      );
      final env = build([a]);
      final notifier = await ready(env.container);
      expect(notifier.trackedCircleKeysForTest, isNotEmpty);

      notifier.stopScheduling();
      expect(notifier.isActiveForTest, isFalse);
      expect(
        notifier.trackedCircleKeysForTest,
        isEmpty,
        reason: 'paused (backgrounded): no live foreground timers',
      );

      notifier.startScheduling();
      await pumpEventQueue();
      expect(notifier.isActiveForTest, isTrue);
      expect(
        notifier.trackedCircleKeysForTest,
        {_hex(const [10])},
        reason: 'resumed: schedulers re-armed from the current roster',
      );
    });
  });
}

// ---------------------------------------------------------------------------
// Local mocks
// ---------------------------------------------------------------------------

class _MockIdentityService implements IdentityService {
  _MockIdentityService({required this.identity});
  final Identity? identity;

  @override
  Future<Identity?> getIdentity() async => identity;
  @override
  Future<bool> hasIdentity() async => identity != null;
  @override
  Future<Identity> createIdentity() async => throw UnimplementedError();
  @override
  Future<Identity> importFromNsec(String nsec) async =>
      throw UnimplementedError();
  @override
  Future<void> deleteIdentity() async {}
  @override
  Future<String> exportNsec() async => throw UnimplementedError();
  @override
  Future<String> sign(Uint8List messageHash) async =>
      throw UnimplementedError();
  @override
  Future<String> getPubkeyHex() async =>
      identity?.pubkeyHex ?? (throw UnimplementedError());
  @override
  Future<List<int>> getSecretBytes() async => throw UnimplementedError();
  @override
  Future<String?> getDisplayName() async => null;
  @override
  Future<void> setDisplayName(String? name) async {}
  @override
  Future<void> clearCache() async {}
}

/// Hangs the FIRST `getCurrentLocation()` forever and serves every later one
/// normally — the shape of a backgrounded iOS permission prompt that the OS
/// defers and geolocator never resolves.
class _WedgingLocationService extends _FixedLocationService {
  final Completer<Position> _wedge = Completer<Position>();
  bool _wedged = false;

  /// Frees the abandoned link at teardown so the test isolate does not exit
  /// with a future nobody will ever complete.
  void release() {
    if (!_wedge.isCompleted) _wedge.completeError(StateError('test teardown'));
  }

  @override
  Future<Position> getCurrentLocation() {
    if (_wedged) return super.getCurrentLocation();
    _wedged = true;
    return _wedge.future;
  }
}

class _FixedLocationService implements LocationService {
  @override
  Future<Position> getCurrentLocation() async => Position(
    latitude: 37,
    longitude: -122,
    timestamp: DateTime.now(),
  );
  @override
  Future<Position> getCurrentLocationFresh() async => getCurrentLocation();
  @override
  Stream<Position> getLocationStream() async* {
    yield await getCurrentLocation();
  }
  @override
  Future<bool> isLocationServiceEnabled() async => true;
  @override
  Future<bool> requestPermission() async => true;
  @override
  Future<LocationPermissionStatus> checkPermission() async =>
      LocationPermissionStatus.always;
}
