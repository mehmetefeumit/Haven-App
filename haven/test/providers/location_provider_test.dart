/// Tests for [locationStreamProvider]'s unified-stream wiring.
///
/// The provider owns the SINGLE geolocator position stream (the plugin
/// supports exactly one; a second request silently inherits the first
/// stream's settings — the defect that broke iOS background publishing).
/// These tests pin the load-bearing behaviors:
///
/// 1. The stream's iOS `AppleSettings` follow the background-sharing toggle
///    at subscription time (background-capable when ON, explicitly inert
///    when OFF).
/// 2. Flipping the toggle rebuilds the stream with the new settings (the
///    only way geolocator settings can ever change).
/// 3. A non-[GeolocatorLocationService] implementation falls back to the
///    parameterless interface call.
/// 4. The disabled rebuild clears the service's cached stream position so
///    plaintext coordinates never outlive the consent that produced them.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:haven/src/providers/background_location_provider.dart';
import 'package:haven/src/providers/location_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/background_location_manager.dart';
import 'package:haven/src/services/geolocator_location_service.dart';
import 'package:haven/src/services/location_service.dart';
import 'package:mockito/mockito.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
    late GeolocatorLocationService service;
    late _FakeBackgroundSharingNotifier notifier;

    ProviderContainer containerWith({required bool backgroundSharing}) {
      mockGeolocator = MockGeolocatorWrapper();
      when(
        mockGeolocator.getPositionStream(
          locationSettings: anyNamed('locationSettings'),
        ),
      ).thenAnswer((_) => Stream.fromIterable([mockPosition]));
      service = GeolocatorLocationService(
        geolocator: mockGeolocator,
        isIOS: true,
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

    List<geo.LocationSettings> capturedSettings() => verify(
      mockGeolocator.getPositionStream(
        locationSettings: captureAnyNamed('locationSettings'),
      ),
    ).captured.cast<geo.LocationSettings>();

    test('requests background-capable settings when the toggle is on',
        () async {
      final container = containerWith(backgroundSharing: true);

      await container.read(locationStreamProvider.future);

      final settings = capturedSettings().single as geo.AppleSettings;
      expect(settings.allowBackgroundLocationUpdates, isTrue);
      expect(settings.showBackgroundLocationIndicator, isTrue);
      expect(settings.pauseLocationUpdatesAutomatically, isFalse);
    });

    test('requests explicitly inert settings when the toggle is off',
        () async {
      final container = containerWith(backgroundSharing: false);

      await container.read(locationStreamProvider.future);

      final settings = capturedSettings().single as geo.AppleSettings;
      expect(settings.allowBackgroundLocationUpdates, isFalse);
      expect(settings.showBackgroundLocationIndicator, isFalse);
    });

    test('rebuilds the stream with new settings when the toggle flips',
        () async {
      final container = containerWith(backgroundSharing: false);
      // Hold a permanent listener so the provider stays alive across the
      // flip (mirrors the map UI's permanent watch).
      final sub = container.listen(locationStreamProvider, (_, _) {});
      addTearDown(sub.close);
      await container.read(locationStreamProvider.future);

      notifier.setState(enabled: true);
      // Let the provider rebuild and resubscribe.
      await container.read(locationStreamProvider.future);

      final captured = capturedSettings();
      expect(captured, hasLength(2));
      expect(
        (captured.first as geo.AppleSettings).allowBackgroundLocationUpdates,
        isFalse,
      );
      expect(
        (captured.last as geo.AppleSettings).allowBackgroundLocationUpdates,
        isTrue,
      );
    });

    test('toggle-off rebuild clears the cached stream position', () async {
      final container = containerWith(backgroundSharing: true);
      final sub = container.listen(locationStreamProvider, (_, _) {});
      addTearDown(sub.close);
      // Drain the first emission so the service tee caches it.
      await container.read(locationStreamProvider.future);

      // Sanity: cache is populated → getCurrentLocation serves it without
      // any one-shot request.
      await service.getCurrentLocation();
      verifyNever(
        mockGeolocator.getCurrentPosition(
          locationSettings: anyNamed('locationSettings'),
        ),
      );

      // The post-flip stream must stay silent: a new emission would
      // legitimately re-populate the cache (the tee runs for the
      // foreground stream too), masking what this test pins — that the
      // flip itself dropped the PRE-flip coordinate.
      when(
        mockGeolocator.getPositionStream(
          locationSettings: anyNamed('locationSettings'),
        ),
      ).thenAnswer((_) => StreamController<geo.Position>().stream);
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
}
