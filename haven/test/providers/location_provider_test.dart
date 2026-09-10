/// Tests for [locationStreamProvider]'s unified-stream wiring.
///
/// The provider owns the SINGLE geolocator position stream (the plugin
/// supports exactly one; a second request silently inherits the first
/// stream's settings — the defect that broke iOS background publishing).
/// These tests pin the load-bearing behaviors:
///
/// 1. The user's background-sharing intent reaches the platform router at
///    subscription time — on iOS, Haven's own CoreLocation session, whose
///    `allowsBackgroundLocationUpdates` it becomes.
/// 2. Flipping the toggle rebuilds the stream with the new intent (on
///    Android, the only way geolocator settings can ever change).
/// 3. A non-[GeolocatorLocationService] implementation falls back to the
///    parameterless interface call.
/// 4. The disabled rebuild clears the service's cached stream position so
///    plaintext coordinates never outlive the consent that produced them.
/// 5. A build that happens while the app is NOT foregrounded starts nothing
///    (a background launch must never open a background-capable session) and
///    surfaces neither data nor an error, and the running foreground build
///    never watches the foreground state.
///
/// The placeholder's other two properties — that it is a per-build controller
/// and never `Stream.empty()` — are pinned structurally in
/// `test/lints/location_stream_fail_closed_test.dart`: Riverpod exposes no
/// completion signal, so a completed stream and a never-completing one have
/// the same `AsyncValue` here and no runtime assertion can tell them apart.
library;

import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/providers/background_location_provider.dart';
import 'package:haven/src/providers/location_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/background_location_manager.dart';
import 'package:haven/src/services/geolocator_location_service.dart';
import 'package:haven/src/services/location_service.dart';
import 'package:mockito/mockito.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../mocks/fake_ios_location_source.dart';
import '../services/geolocator_location_service_test.mocks.dart';

/// A [BackgroundSharingNotifier] stand-in with a synchronously settable
/// state and none of the platform side effects.
class _FakeBackgroundSharingNotifier extends BackgroundSharingNotifier {
  _FakeBackgroundSharingNotifier({required bool initial})
    : super(
        ensurePermissions: () async => const EnsurePermissionsGranted(),
        isAndroid: false,
        isIOS: false,
      ) {
    state = initial;
  }

  void setState({required bool enabled}) => state = enabled;
}

/// Minimal fake proving the interface fallback path.
class _FakeLocationService implements LocationService {
  int streamCalls = 0;

  @override
  Stream<Position> getLocationStream() {
    streamCalls++;
    return const Stream<Position>.empty();
  }

  @override
  Future<Position> getCurrentLocation() => throw UnimplementedError();

  @override
  Future<Position> getCurrentLocationFresh() => throw UnimplementedError();

  @override
  Future<bool> isLocationServiceEnabled() async => true;

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<LocationPermissionStatus> checkPermission() async =>
      LocationPermissionStatus.whileInUse;
}

void main() {
  // `appForegroundProvider`'s initial value is read from the binding's
  // lifecycle state, so every test that builds the REAL provider needs a
  // binding; a plain `test()` would throw "Binding has not yet been
  // initialized" out of the initializer.
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  final mockPosition = geo.Position(
    latitude: 51.5,
    longitude: -0.12,
    timestamp: DateTime.now(),
    accuracy: 5,
    altitude: 0,
    altitudeAccuracy: 1,
    heading: 0,
    headingAccuracy: 1,
    speed: 0,
    speedAccuracy: 1,
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('locationStreamProvider unified-stream wiring', () {
    late MockGeolocatorWrapper mockGeolocator;
    late FakeIosLocationSource fakeIos;
    late GeolocatorLocationService service;
    late _FakeBackgroundSharingNotifier notifier;

    /// Feeds one fix into the session the service just opened, so a `.future`
    /// read completes.
    void deliverFirstFix() {
      if (fakeIos.sessions.isEmpty) return;
      fakeIos.session.add(
        Position(
          latitude: mockPosition.latitude,
          longitude: mockPosition.longitude,
          timestamp: mockPosition.timestamp,
          accuracy: mockPosition.accuracy,
        ),
      );
    }

    ProviderContainer containerWith({required bool backgroundSharing}) {
      mockGeolocator = MockGeolocatorWrapper();
      fakeIos = FakeIosLocationSource();
      when(
        mockGeolocator.getPositionStream(
          locationSettings: anyNamed('locationSettings'),
        ),
      ).thenAnswer((_) => Stream.fromIterable([mockPosition]));
      // The access gate reads the granted ACCURACY on its granted arm; the
      // mock is `throwOnMissingStub`. Nothing here is about precision, so
      // pin the undowngraded state.
      when(
        mockGeolocator.getLocationAccuracy(),
      ).thenAnswer((_) async => geo.LocationAccuracyStatus.precise);
      service = GeolocatorLocationService(
        geolocator: mockGeolocator,
        isIOS: true,
        iosSource: fakeIos,
      );
      notifier = _FakeBackgroundSharingNotifier(initial: backgroundSharing);
      final container = ProviderContainer(
        overrides: [
          locationServiceProvider.overrideWithValue(service),
          backgroundSharingProvider.overrideWith((ref) => notifier),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('asks the native session for background capability when the toggle '
        'is on', () async {
      final container = containerWith(backgroundSharing: true);

      final future = container.read(locationStreamProvider.future);
      deliverFirstFix();
      await future;

      expect(fakeIos.listenArguments, [true]);
      verifyNever(
        mockGeolocator.getPositionStream(
          locationSettings: anyNamed('locationSettings'),
        ),
      );
    });

    test('asks for no background capability when the toggle is off', () async {
      final container = containerWith(backgroundSharing: false);

      final future = container.read(locationStreamProvider.future);
      deliverFirstFix();
      await future;

      expect(
        fakeIos.listenArguments,
        [false],
        reason: 'a session that took background capability without the '
            'toggle would keep an opt-out user executable in the background',
      );
    });

    test('rebuilds the stream with the new intent when the toggle flips',
        () async {
      final container = containerWith(backgroundSharing: false);
      // Hold a permanent listener so the provider stays alive across the
      // flip (mirrors the map UI's permanent watch).
      final sub = container.listen(locationStreamProvider, (_, _) {});
      addTearDown(sub.close);
      var future = container.read(locationStreamProvider.future);
      deliverFirstFix();
      await future;

      notifier.setState(enabled: true);
      // Let the provider rebuild and resubscribe.
      future = container.read(locationStreamProvider.future);
      deliverFirstFix();
      await future;

      expect(
        fakeIos.listenArguments,
        [false, true],
        reason: 'settings can only change by a new subscription; a rebuild '
            'that reused the old intent would silently keep the opt-out '
            'session',
      );
    });

    test('toggle-off rebuild clears the cached stream position', () async {
      final container = containerWith(backgroundSharing: true);
      // The fake native session is an OPEN controller by construction: a
      // live platform stream never completes, and the service treats a CLOSED
      // one as "no further fix will arrive" by dropping the cache — which
      // would empty it for the wrong reason and make this pass vacuously.
      final sub = container.listen(locationStreamProvider, (_, _) {});
      addTearDown(sub.close);
      final warmed = container.read(locationStreamProvider.future);
      deliverFirstFix();
      await warmed;

      // Sanity: cache is populated → getCurrentLocation serves it without
      // any one-shot request, once the access gate reads granted.
      when(
        mockGeolocator.isLocationServiceEnabled(),
      ).thenAnswer((_) async => true);
      when(
        mockGeolocator.checkPermission(),
      ).thenAnswer((_) async => geo.LocationPermission.whileInUse);
      await service.getCurrentLocation();
      verifyNever(
        mockGeolocator.getCurrentPosition(
          locationSettings: anyNamed('locationSettings'),
        ),
      );

      // The post-flip session must stay silent: a new emission would
      // legitimately re-populate the cache (the tee runs for the foreground
      // stream too), masking what this test pins — that the flip itself
      // dropped the PRE-flip coordinate. The fake hands out a fresh, empty
      // controller per subscription, so silence is the default.
      notifier.setState(enabled: false);
      // Flush the scheduled rebuild (read() flushes synchronously) and let
      // the new subscription settle.
      container.read(locationStreamProvider);
      await Future<void>.delayed(Duration.zero);

      // Cache must now be empty → getCurrentLocation needs the one-shot.
      when(mockGeolocator.isLocationServiceEnabled())
          .thenAnswer((_) async => true);
      when(
        mockGeolocator.checkPermission(),
      ).thenAnswer((_) async => geo.LocationPermission.whileInUse);
      when(
        mockGeolocator.getCurrentPosition(
          locationSettings: anyNamed('locationSettings'),
        ),
      ).thenAnswer((_) async => mockPosition);
      await service.getCurrentLocation();
      verify(
        mockGeolocator.getCurrentPosition(
          locationSettings: anyNamed('locationSettings'),
        ),
      ).called(1);
    });

    test(
      'falls back to the parameterless call for a non-Geolocator service',
      () async {
        final fake = _FakeLocationService();
        final fakeNotifier = _FakeBackgroundSharingNotifier(initial: true);
        final container = ProviderContainer(
          overrides: [
            locationServiceProvider.overrideWithValue(fake),
            backgroundSharingProvider.overrideWith((ref) => fakeNotifier),
          ],
        );
        addTearDown(container.dispose);

        final sub = container.listen(locationStreamProvider, (_, _) {});
        addTearDown(sub.close);
        await Future<void>.delayed(Duration.zero);

        expect(fake.streamCalls, 1);
      },
    );
  });

  /// The map's registration is a FOREGROUND use case, and stays one.
  ///
  /// `getLocationStream` can now be asked for the Android foreground service's
  /// long-interval profile, and this provider is the only production caller in
  /// the UI isolate. What it asks for is unchanged — 1 m / 1 s — because that
  /// is what a live map needs, and because `b5_permission_revocation_test.dart`
  /// discriminates a revoked permission by the SILENCE of this stream: at a
  /// minute-scale interval a perfectly healthy stream is silent too.
  group('locationStreamProvider Android registration', () {
    test('asks for the foreground profile, never a background-service one',
        () async {
      final mockGeolocator = MockGeolocatorWrapper();
      when(
        mockGeolocator.getPositionStream(
          locationSettings: anyNamed('locationSettings'),
        ),
      ).thenAnswer((_) => Stream.fromIterable([mockPosition]));
      final container = ProviderContainer(
        overrides: [
          locationServiceProvider.overrideWithValue(
            GeolocatorLocationService(geolocator: mockGeolocator, isIOS: false),
          ),
          backgroundSharingProvider.overrideWith(
            (ref) => _FakeBackgroundSharingNotifier(initial: true),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container.read(locationStreamProvider.future);

      final settings = verify(
        mockGeolocator.getPositionStream(
          locationSettings: captureAnyNamed('locationSettings'),
        ),
      ).captured.single;
      expect(settings, isA<geo.AndroidSettings>());
      final android = settings as geo.AndroidSettings;
      expect(android.intervalDuration, const Duration(seconds: 1));
      expect(android.distanceFilter, 1);
      expect(android.forceLocationManager, isTrue);
    });
  });

  /// The fail-closed background-launch guard.
  ///
  /// A watched-provider write cancels the old subscription synchronously but
  /// defers the REBUILD to a frame, and frames are off while the app is
  /// paused — so the only thing a rebuild can honestly do here is refuse to
  /// START anything while the app is not foregrounded. iOS refuses a
  /// background-capable session begun from the background outright.
  group('locationStreamProvider lifecycle gating', () {
    late MockGeolocatorWrapper mockGeolocator;
    late FakeIosLocationSource fakeIos;

    setUp(() {
      // Match the notifier's persisted value so its async `_load()` cannot
      // flip the toggle mid-test and rebuild the stream behind the assertions.
      SharedPreferences.setMockInitialValues({
        kBackgroundSharingKey: true,
        kLocationDisclosureBackgroundAcceptedKey: true,
      });
    });

    ProviderContainer containerWith({required bool foregrounded}) {
      mockGeolocator = MockGeolocatorWrapper();
      // iOS: the CoreLocation session this group is about is Haven's own, so
      // the thing to count is the sessions the native owner handed out.
      fakeIos = FakeIosLocationSource();
      when(
        mockGeolocator.getLocationAccuracy(),
      ).thenAnswer((_) async => geo.LocationAccuracyStatus.precise);
      final container = ProviderContainer(
        overrides: [
          locationServiceProvider.overrideWithValue(
            GeolocatorLocationService(
              geolocator: mockGeolocator,
              isIOS: true,
              iosSource: fakeIos,
            ),
          ),
          backgroundSharingProvider.overrideWith(
            (ref) => _FakeBackgroundSharingNotifier(initial: true),
          ),
          appForegroundProvider.overrideWith((ref) => foregrounded),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test(
      'the provider built while not foregrounded starts nothing and stays '
      'silent, with no error and no data',
      () {
        fakeAsync((async) {
          final container = containerWith(foregrounded: false);
          final states = <AsyncValue<Position>>[];
          final sub = container.listen(
            locationStreamProvider,
            (_, next) => states.add(next),
          );
          addTearDown(sub.close);

          async.elapse(const Duration(minutes: 5));

          verifyNever(
            mockGeolocator.getPositionStream(
              locationSettings: anyNamed('locationSettings'),
            ),
          );
          expect(
            container.read(locationStreamProvider),
            isA<AsyncLoading<Position>>(),
            reason: 'a background launch must neither start a session nor '
                'surface an error to the access watchdog',
          );
          expect(states, isEmpty);
        });
      },
    );

    test('two consecutive not-foregrounded builds never surface an error or '
        'completion', () {
      fakeAsync((async) {
        final container = containerWith(foregrounded: false);
        final sub = container.listen(locationStreamProvider, (_, _) {});
        addTearDown(sub.close);
        async.elapse(const Duration(seconds: 1));

        // A shared placeholder would throw "Stream has already been listened
        // to" here, and Riverpod turns that into the AsyncError the
        // placeholder exists to avoid.
        container.invalidate(locationStreamProvider);
        async.elapse(const Duration(seconds: 1));

        final state = container.read(locationStreamProvider);
        expect(state, isA<AsyncLoading<Position>>());
        expect(state.hasError, isFalse);
      });
    });

    test('the resume write rebuilds a placeholder build into a running stream',
        () {
      fakeAsync((async) {
        final container = containerWith(foregrounded: false);
        final sub = container.listen(locationStreamProvider, (_, _) {});
        addTearDown(sub.close);
        async.elapse(const Duration(seconds: 1));
        expect(fakeIos.sessions, isEmpty);

        // Exactly what `MapShell._setForegroundActive(true)` does on resume.
        container.read(appForegroundProvider.notifier).state = true;
        async.elapse(const Duration(seconds: 1));

        expect(
          fakeIos.sessions,
          hasLength(1),
          reason: 'the placeholder build must watch the foreground state, or '
              'a background launch never acquires a stream at all',
        );
      });
    });

    test('the foreground build does not watch the foreground provider', () {
      fakeAsync((async) {
        final container = containerWith(foregrounded: true);
        final sub = container.listen(locationStreamProvider, (_, _) {});
        addTearDown(sub.close);
        async.elapse(const Duration(seconds: 1));
        expect(fakeIos.sessions, hasLength(1));

        // The pause write. A `watch` in the running build would cancel this
        // subscription now and rebuild into the placeholder at the next
        // frame — i.e. tear down the iOS keep-alive the whole design exists
        // to preserve. The release is the service gate's job, called
        // directly from `_onPaused`.
        container.read(appForegroundProvider.notifier).state = false;
        async.elapse(const Duration(seconds: 1));
        container.read(locationStreamProvider);

        expect(fakeIos.cancels, 0);
        expect(fakeIos.sessions, hasLength(1));
      });
    });
  });

  group('shouldKeepLocationStreamWhilePaused', () {
    // The four cells of the keep rule. `_onPaused` releases the platform
    // subscription on every cell but one, and calls nothing on that one.
    test('keeps the stream only on the iOS background-sharing branch', () {
      expect(
        shouldKeepLocationStreamWhilePaused(
          backgroundSharingEnabled: true,
          isIOS: true,
        ),
        isTrue,
        reason: 'that CLLocationManager session is the keep-alive: releasing '
            'it at pause ends publishing outright',
      );
    });

    test('releases on Android even with background sharing on', () {
      // The foreground service owns background publishing; the UI isolate's
      // 1 Hz / 1 m registration is pure drain once the app is paused.
      expect(
        shouldKeepLocationStreamWhilePaused(
          backgroundSharingEnabled: true,
          isIOS: false,
        ),
        isFalse,
      );
    });

    test('releases on iOS when background sharing is off', () {
      expect(
        shouldKeepLocationStreamWhilePaused(
          backgroundSharingEnabled: false,
          isIOS: true,
        ),
        isFalse,
      );
    });

    test('releases when neither condition holds', () {
      expect(
        shouldKeepLocationStreamWhilePaused(
          backgroundSharingEnabled: false,
          isIOS: false,
        ),
        isFalse,
      );
    });
  });

  group('isIOSProvider', () {
    test('reports the real platform when nothing overrides it', () {
      // The seam exists so tests can reach both arms of the keep rule on a
      // host runner — but a seam that answers a test's own override says
      // nothing. What has to hold is that PRODUCTION, which overrides
      // nothing, gets the platform: an `isIOSProvider` stuck at a constant
      // would either release the iOS keep-alive at every pause (background
      // publishing ends) or hold an Android GPS registration for the whole
      // backgrounded window.
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(isIOSProvider), Platform.isIOS);
    });
  });

  group('appForegroundProvider default', () {
    tearDown(() {
      binding.platformDispatcher.resetInitialLifecycleState();
      // Back to "never dispatched", the state every other test in this file
      // reads — so this group cannot decide what any of them observe.
      binding.resetInternalState();
    });

    test('is true when the binding has dispatched no lifecycle state', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(appForegroundProvider), isTrue);
    });

    test('is false under a paused binding', () {
      binding.platformDispatcher.initialLifecycleStateTestValue =
          'AppLifecycleState.paused';
      binding.readTestInitialLifecycleStateFromNativeWindow();
      expect(binding.lifecycleState, AppLifecycleState.paused);
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(
        container.read(appForegroundProvider),
        isFalse,
        reason: 'a literal `true` default would start a background-capable '
            'session on a background launch',
      );
    });
  });
}
