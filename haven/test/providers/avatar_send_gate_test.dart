/// Tests for the §7.5 "Send my avatar" privacy gate in [OwnAvatarController].
///
/// Verifies:
/// - When send is disabled, pickAndSet does NOT call buildAvatarShareEvents
///   (the publish-on-change path is suppressed).
/// - When send is disabled, reshareToAllCircles (anti-entropy) does NOT
///   call buildAvatarShareEvents.
/// - When send is disabled, epochReshareForCircle does NOT publish.
/// - When send is enabled, all publish paths proceed as normal.
/// - The stored blob is kept even when send is off (no tombstone).
library;

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/avatar_send_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/own_avatar_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/identity_service.dart';

import '../mocks/mock_circle_service.dart';
import '../mocks/mock_relay_service.dart';

// ---------------------------------------------------------------------------
// Fake identity service.
// ---------------------------------------------------------------------------

class _FakeIdentityService implements IdentityService {
  static final _identity = Identity(
    pubkeyHex:
        'aabb1234aabb1234aabb1234aabb1234aabb1234aabb1234aabb1234aabb1234',
    npub: 'npub1test',
    createdAt: DateTime(2025),
  );

  @override
  Future<bool> hasIdentity() async => true;

  @override
  Future<Identity?> getIdentity() async => _identity;

  @override
  Future<Identity> createIdentity() => throw UnimplementedError();

  @override
  Future<Identity> importFromNsec(String nsec) => throw UnimplementedError();

  @override
  Future<String> exportNsec() => throw UnimplementedError();

  @override
  Future<String> sign(Uint8List messageHash) => throw UnimplementedError();

  @override
  Future<String> getPubkeyHex() async => _identity.pubkeyHex;

  @override
  Future<List<int>> getSecretBytes() => throw UnimplementedError();

  @override
  Future<void> deleteIdentity() async {}

  @override
  Future<String?> getDisplayName() async => null;

  @override
  Future<void> setDisplayName(String? name) async {}

  @override
  Future<void> clearCache() async {}
}

// ---------------------------------------------------------------------------
// Seeded send-notifier test seam — no real SharedPreferences IO.
// ---------------------------------------------------------------------------

class _SeededSendNotifier extends AvatarSendNotifier {
  _SeededSendNotifier({required bool enabled})
    : super(prefs: _DummyPrefs(seeded: enabled)) {
    // Set state synchronously so gate reads don't race against async _load().
    // _load() will also complete with the same value (from _DummyPrefs).
    state = enabled;
  }
}

class _DummyPrefs implements SharedPreferences {
  _DummyPrefs({required this.seeded});
  final bool seeded;
  @override
  bool? getBool(String key) => seeded;
  @override
  Future<bool> setBool(String key, bool value) async => true;
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

// ---------------------------------------------------------------------------
// Helpers.
// ---------------------------------------------------------------------------

/// Builds a minimal accepted [Circle].
Circle _acceptedCircle({String name = 'TestCircle'}) {
  return TestCircleFactory.createCircle(displayName: name);
}

/// Creates a container with the given send-enabled state.
ProviderContainer _makeContainer({
  required MockCircleService circleService,
  required MockRelayService relayService,
  required bool sendEnabled,
  List<Circle> circles = const [],
}) {
  return ProviderContainer(
    overrides: [
      identityServiceProvider.overrideWithValue(_FakeIdentityService()),
      circleServiceProvider.overrideWithValue(circleService),
      relayServiceProvider.overrideWithValue(relayService),
      circlesProvider.overrideWith((_) async => circles),
      avatarSendProvider.overrideWith(
        (_) => _SeededSendNotifier(enabled: sendEnabled),
      ),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final testBytes = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0]);

  // -----------------------------------------------------------------------
  // send-off: pickAndSet suppresses publish
  // -----------------------------------------------------------------------

  group('OwnAvatarController §7.5 — send disabled', () {
    test(
      'pickAndSet does NOT call buildAvatarShareEvents when send is off',
      () async {
        final svc = MockCircleService()
          ..buildAvatarShareEventsResult = ['{"id":"evt1"}'];
        final relay = MockRelayService();

        final container = _makeContainer(
          circleService: svc,
          relayService: relay,
          sendEnabled: false,
          circles: [_acceptedCircle()],
        );
        addTearDown(container.dispose);

        await container
            .read(ownAvatarControllerProvider.notifier)
            .pickAndSet(testBytes);
        // Drain the fire-and-forget timer.
        await Future<void>.delayed(Duration.zero);

        expect(
          svc.buildAvatarShareEventsCalls,
          isEmpty,
          reason: 'send gate must prevent buildAvatarShareEvents when off',
        );
        expect(
          relay.publishedEvents,
          isEmpty,
          reason: 'no relay publish must occur when send is disabled',
        );
      },
    );

    test(
      'pickAndSet still stores the avatar locally when send is off',
      () async {
        final svc = MockCircleService();
        final relay = MockRelayService();

        final container = _makeContainer(
          circleService: svc,
          relayService: relay,
          sendEnabled: false,
          circles: [_acceptedCircle()],
        );
        addTearDown(container.dispose);

        await container
            .read(ownAvatarControllerProvider.notifier)
            .pickAndSet(testBytes);
        await Future<void>.delayed(Duration.zero);

        // setMyAvatar must still be called — the blob is stored locally.
        expect(
          svc.methodCalls,
          contains('setMyAvatar'),
          reason: 'stored blob must be kept even when send is disabled',
        );
      },
    );

    test(
      'reshareToAllCircles (anti-entropy) does NOT publish when send is off',
      () async {
        final svc = MockCircleService()
          ..avatarThumbnailBytes = testBytes
          ..buildAvatarShareEventsResult = ['{"id":"evt1"}'];
        final relay = MockRelayService();

        final container = _makeContainer(
          circleService: svc,
          relayService: relay,
          sendEnabled: false,
          circles: [_acceptedCircle()],
        );
        addTearDown(container.dispose);

        container
            .read(ownAvatarControllerProvider.notifier)
            .reshareToAllCircles();
        await Future<void>.delayed(Duration.zero);

        expect(
          svc.buildAvatarShareEventsCalls,
          isEmpty,
          reason: 'anti-entropy must be suppressed when send is off',
        );
        expect(relay.publishedEvents, isEmpty);
      },
    );

    test(
      'epochReshareForCircle does NOT publish when send is off',
      () async {
        final svc = MockCircleService()
          ..avatarThumbnailBytes = testBytes
          ..buildAvatarShareEventsResult = ['{"id":"evt1"}'];
        final relay = MockRelayService();

        final container = _makeContainer(
          circleService: svc,
          relayService: relay,
          sendEnabled: false,
          circles: [_acceptedCircle()],
        );
        addTearDown(container.dispose);

        container
            .read(ownAvatarControllerProvider.notifier)
            .epochReshareForCircle([1, 2, 3, 4]);
        await Future<void>.delayed(Duration.zero);

        expect(
          svc.buildAvatarShareEventsCalls,
          isEmpty,
          reason: 'epoch reshare must be suppressed when send is off',
        );
        expect(relay.publishedEvents, isEmpty);
      },
    );
  });

  // -----------------------------------------------------------------------
  // send-on: normal publish behaviour (regression guard)
  // -----------------------------------------------------------------------

  group('OwnAvatarController §7.5 — send enabled', () {
    test(
      'pickAndSet calls buildAvatarShareEvents when send is enabled',
      () async {
        final svc = MockCircleService()
          ..buildAvatarShareEventsResult = ['{"id":"evt1"}'];
        final relay = MockRelayService();

        final container = _makeContainer(
          circleService: svc,
          relayService: relay,
          sendEnabled: true,
          circles: [_acceptedCircle()],
        );
        addTearDown(container.dispose);

        await container
            .read(ownAvatarControllerProvider.notifier)
            .pickAndSet(testBytes);
        await Future<void>.delayed(Duration.zero);

        expect(
          svc.buildAvatarShareEventsCalls,
          hasLength(1),
          reason: 'publish must proceed when send is enabled',
        );
        expect(relay.publishedEvents, hasLength(1));
      },
    );
  });
}
