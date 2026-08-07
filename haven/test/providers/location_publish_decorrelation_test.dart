/// Cross-circle `created_at` decorrelation on the FOREGROUND publish paths.
///
/// ## What is being proven, and why it is a timing assertion
///
/// The MDK engine binds the OUTER kind-445 `created_at` to the INNER
/// application event's `created_at`, and that inner stamp is
/// `nostr::Timestamp::now()` — a u64 of WHOLE SECONDS. Two circles whose
/// `encryptLocation` calls land in the same wall-clock second therefore emit
/// two kind-445 events carrying a byte-identical `created_at`, inside the
/// signed event, visible to anyone holding both events from any relay or
/// archive. That equality links two otherwise-unlinkable pseudonymous circles
/// to one device.
///
/// So the property is not "the code calls things in a loop" — it is that the
/// instants at which `encryptLocation` is entered are more than one second
/// apart. Every assertion here is on [MockCircleService.encryptCallTimes],
/// which records exactly that. A reintroduced `Future.wait` over the publish
/// fails these tests because its calls land microseconds apart, no matter how
/// the call is spelled.
library;

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/location_publish_scheduler_provider.dart';
import 'package:haven/src/providers/location_sharing_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/location_service.dart';
import 'package:haven/src/services/location_sharing_service.dart';
import 'package:haven/src/services/publish_stagger.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../mocks/mock_circle_service.dart';
import '../mocks/mock_relay_service.dart';

const _selfPubkey =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

final _identity = Identity(
  pubkeyHex: _selfPubkey,
  npub: 'npub1self',
  createdAt: DateTime(2025),
);

Circle _circle(int id) => TestCircleFactory.createCircle(
  mlsGroupId: [id],
  nostrGroupId: [id],
  members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
);

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Gaps between consecutive `encryptLocation` entries, in milliseconds.
List<int> _separationsMs(MockCircleService mock) => <int>[
  for (var i = 1; i < mock.encryptCallTimes.length; i++)
    mock.encryptCallTimes[i]
        .difference(mock.encryptCallTimes[i - 1])
        .inMilliseconds,
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ({ProviderContainer container, MockCircleService mock}) build(
    List<Circle> circles, {
    PublishStagger? stagger,
  }) {
    SharedPreferences.setMockInitialValues({
      kLocationDisclosureAcceptedKey: true,
    });
    final mock = MockCircleService(circles: circles);
    final container = ProviderContainer(
      overrides: [
        identityServiceProvider.overrideWithValue(
          _MockIdentityService(identity: _identity),
        ),
        locationServiceProvider.overrideWithValue(_FixedLocationService()),
        circleServiceProvider.overrideWithValue(mock),
        locationSharingServiceProvider.overrideWithValue(
          LocationSharingService(
            circleService: mock,
            relayService: MockRelayService(),
          ),
        ),
        if (stagger != null)
          locationPublishStaggerProvider.overrideWithValue(stagger),
      ],
    );
    addTearDown(container.dispose);
    return (container: container, mock: mock);
  }

  // ---------------------------------------------------------------------------
  // The headline property, with the PRODUCTION stagger and no overrides: two
  // circles' kind-445 events cannot share a `created_at`.
  // ---------------------------------------------------------------------------

  group('locationPublisherProvider — the burst does not co-time circles', () {
    test(
      'two circles are published MORE THAN ONE SECOND apart under the real '
      'production stagger',
      () async {
        final env = build([_circle(1), _circle(2)]);

        final count = await env.container.read(
          locationPublisherProvider.future,
        );

        expect(count, 2, reason: 'both circles must still be published to');
        expect(env.mock.encryptCallTimes.length, 2);
        expect(
          _separationsMs(env.mock).single,
          greaterThan(1000),
          reason:
              'the kind-445 created_at is a whole-second u64, so anything at '
              'or under a second leaves both circles stamped identically — '
              'which is the leak, not a hint of it',
        );
      },
      // The production gap is 2-9 s and this deliberately does not shorten it:
      // the point is that the SHIPPING constants produce the separation.
      timeout: const Timeout(Duration(seconds: 90)),
    );

    test(
      'publishes are sequential — never dispatched concurrently, which is how '
      'they landed in one second',
      () async {
        // A short deterministic stagger keeps the test fast; concurrency is
        // structural and shows up regardless of the gap length.
        final env = build(
          [_circle(1), _circle(2), _circle(3), _circle(4)],
          stagger: PublishStagger(
            rng: Random(1),
            minGap: const Duration(milliseconds: 40),
            maxGap: const Duration(milliseconds: 60),
            maxSpread: const Duration(seconds: 1),
          ),
        );
        // Without a real suspension inside the mock the concurrency peak is
        // always 1 — even under `Future.wait` — because the whole mock body
        // runs at call time. The production encrypt is an FFI round trip and
        // always suspends, so the double must too or this assertion is empty.
        env.mock.encryptSuspends = true;

        await env.container.read(locationPublisherProvider.future);

        expect(
          env.mock.encryptCallTimes.length,
          4,
          reason: 'all four circles must still be reached',
        );
        expect(
          env.mock.encryptConcurrencyPeak,
          1,
          reason:
              'Future.wait over the publish puts every circle inside one '
              'wall-clock second by construction — the encrypts must never '
              'overlap',
        );
      },
    );

    test(
      'every consecutive pair in a four-circle burst is separated by at least '
      'the sampled gap',
      () async {
        final env = build(
          [_circle(1), _circle(2), _circle(3), _circle(4)],
          stagger: PublishStagger(
            rng: Random(2),
            minGap: const Duration(milliseconds: 80),
            maxGap: const Duration(milliseconds: 120),
            maxSpread: const Duration(seconds: 1),
          ),
        );

        final count = await env.container.read(
          locationPublisherProvider.future,
        );

        expect(count, 4);
        expect(_separationsMs(env.mock).length, 3);
        for (final gap in _separationsMs(env.mock)) {
          expect(
            gap,
            greaterThanOrEqualTo(80),
            reason: 'a burst must never compress below the sampled floor',
          );
        }
      },
    );

    test(
      'the separations vary — a constant stagger is a fingerprint of its own',
      () async {
        final env = build(
          [for (var i = 1; i <= 8; i++) _circle(i)],
          stagger: PublishStagger(
            rng: Random(3),
            minGap: const Duration(milliseconds: 30),
            maxGap: const Duration(milliseconds: 90),
            maxSpread: const Duration(seconds: 2),
          ),
        );

        await env.container.read(locationPublisherProvider.future);

        // Bucket to 10 ms so scheduler noise cannot manufacture variety.
        final buckets = _separationsMs(env.mock).map((ms) => ms ~/ 10).toSet();
        expect(
          buckets.length,
          greaterThan(1),
          reason:
              'a fixed inter-publish offset would itself link the circles: an '
              'observer who sees the same delta every burst has learned the '
              'schedule',
        );
      },
    );

    test(
      'the publish ORDER is not a fixed property of the circle set',
      () async {
        final firstPublished = <String>{};
        for (var attempt = 0; attempt < 25; attempt++) {
          final env = build(
            [_circle(1), _circle(2), _circle(3)],
            stagger: PublishStagger(
              rng: Random(attempt),
              minGap: const Duration(milliseconds: 5),
              maxGap: const Duration(milliseconds: 10),
              maxSpread: const Duration(milliseconds: 100),
            ),
          );
          await env.container.read(locationPublisherProvider.future);
          firstPublished.add(_hex(env.mock.encryptedMlsGroupIds.first));
        }
        expect(
          firstPublished.length,
          greaterThan(1),
          reason:
              'a stable "circle 1 always goes first" makes the un-delayed '
              'circle a stable marker of the burst',
        );
      },
    );

    test(
      'every eligible circle is still published to — decorrelation must not '
      'cost coverage',
      () async {
        final env = build(
          [_circle(1), _circle(2), _circle(3), _circle(4), _circle(5)],
          stagger: PublishStagger(
            rng: Random(4),
            minGap: const Duration(milliseconds: 5),
            maxGap: const Duration(milliseconds: 10),
            maxSpread: const Duration(milliseconds: 100),
          ),
        );

        final count = await env.container.read(
          locationPublisherProvider.future,
        );

        expect(count, 5);
        expect(
          env.mock.encryptedMlsGroupIds.map(_hex).toSet(),
          {for (var i = 1; i <= 5; i++) _hex([i])},
        );
      },
    );

    test(
      'one failing circle does not abort the rest of the burst',
      () async {
        // Regression guard on the rewrite from `Future.wait` (which isolated
        // failures per element) to a sequential loop.
        final env = build([_circle(1), _circle(2), _circle(3)],
            stagger: PublishStagger.none());
        env.mock.encryptLocationThrowKeys.add(_hex([2]));

        final count = await env.container.read(
          locationPublisherProvider.future,
        );

        expect(count, 2, reason: 'two of three circles still published');
        expect(env.mock.encryptCallTimes.length, 3);
      },
    );

    test(
      'a superseded burst stops instead of publishing behind its replacement',
      () async {
        // A burst now spans tens of seconds, so it can outlive the provider
        // that started it. Every trigger does invalidate + read; without the
        // dispose guard the old burst keeps publishing under the new one.
        final env = build(
          [for (var i = 1; i <= 6; i++) _circle(i)],
          stagger: PublishStagger(
            rng: Random(5),
            minGap: const Duration(milliseconds: 60),
            maxGap: const Duration(milliseconds: 60),
            maxSpread: const Duration(seconds: 2),
          ),
        );

        // Riverpod completes a provider future disposed mid-flight with a
        // StateError; that is its contract, not the behaviour under test, so
        // the burst is observed through the mock rather than through its
        // return value.
        unawaited(
          env.container
              .read(locationPublisherProvider.future)
              .then<void>((_) {}, onError: (Object _) {}),
        );
        // Wait for the burst to be genuinely under way rather than for a fixed
        // wall-clock slice — the identity read, the prefs read and the GPS fix
        // all precede the first publish, and how long they take is a property
        // of the machine, not of the code under test.
        final startedAt = DateTime.now();
        while (env.mock.encryptCallTimes.isEmpty) {
          if (DateTime.now().difference(startedAt) >
              const Duration(seconds: 10)) {
            fail('the burst never reached its first publish');
          }
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        env.container.invalidate(locationPublisherProvider);
        // Long enough for all six to have gone out had nothing stopped them
        // (5 gaps x 60 ms).
        await Future<void>.delayed(const Duration(milliseconds: 700));

        expect(
          env.mock.encryptCallTimes.length,
          lessThan(6),
          reason: 'the superseded burst must stop mid-flight instead of '
              'publishing behind the burst that replaced it',
        );
        expect(env.mock.encryptCallTimes, isNotEmpty);
      },
    );
  });

  // ---------------------------------------------------------------------------
  // The recurring per-circle scheduler. Its per-circle phases are independent,
  // but both are sampled from the same 97-value window, so two ticks can land
  // in one second by chance and the FIFO chain would run them back to back.
  // ---------------------------------------------------------------------------

  group('LocationPublishSchedulerNotifier — chained ticks are spaced', () {
    test(
      'two ticks that fire in the same instant publish more than a second '
      'apart',
      () async {
        SharedPreferences.setMockInitialValues({
          kLocationDisclosureAcceptedKey: true,
        });
        final mock = MockCircleService(circles: [_circle(1), _circle(2)]);
        final container = ProviderContainer(
          overrides: [
            identityServiceProvider.overrideWithValue(
              _MockIdentityService(identity: _identity),
            ),
            locationServiceProvider.overrideWithValue(_FixedLocationService()),
            circleServiceProvider.overrideWithValue(mock),
            locationSharingServiceProvider.overrideWithValue(
              LocationSharingService(
                circleService: mock,
                relayService: MockRelayService(),
              ),
            ),
            locationPublishJitterSamplerProvider.overrideWithValue((_) => 120),
          ],
        );
        addTearDown(container.dispose);

        final notifier = container.read(
          locationPublishSchedulerProvider.notifier,
        );
        await container.read(circlesProvider.future);
        await pumpEventQueue();

        // Fire BOTH circles' ticks in the same instant — the coincidence the
        // chain used to serialise into a single second.
        unawaited(notifier.triggerTickForTest(_hex([1])));
        await notifier.triggerTickForTest(_hex([2]));

        expect(mock.encryptCallTimes.length, 2);
        expect(
          _separationsMs(mock).single,
          greaterThan(1000),
          reason:
              'serialising two coincident ticks is not enough — back-to-back '
              'is still one whole-second created_at for both circles',
        );
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );
  });
}

// =============================================================================
// Local test doubles
// =============================================================================

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

class _FixedLocationService implements LocationService {
  @override
  Future<Position> getCurrentLocation() async =>
      Position(latitude: 37, longitude: -122, timestamp: DateTime.now());

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
