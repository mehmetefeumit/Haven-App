/// Comprehensive tests for GeolocatorLocationService.
///
/// These tests verify the service logic using a mocked GeolocatorWrapper,
/// ensuring proper error handling, permission flows, and fallback behavior.
///
/// Test coverage:
/// - Permission checking and requesting
/// - Location service availability checks
/// - Position retrieval with fallback to last known position
/// - Fresh position retrieval without fallback
/// - Position streaming
/// - Error scenarios and edge cases
/// - The access gate: no stored coordinate may outlive the user's location
///   access (see the `access gate` group)
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/services/geolocator_location_service.dart';
import 'package:haven/src/services/location_service.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';

import 'geolocator_location_service_test.mocks.dart';

/// Generate mocks for GeolocatorWrapper.
///
/// Run: dart run build_runner build --delete-conflicting-outputs
@GenerateMocks([GeolocatorWrapper])
void main() {
  group('GeolocatorLocationService', () {
    late MockGeolocatorWrapper mockGeolocator;
    late GeolocatorLocationService service;

    setUp(() {
      mockGeolocator = MockGeolocatorWrapper();
      // The access gate reads the granted ACCURACY on its granted arm.
      // Default every test to the undowngraded state so only the tests
      // that are about precision have to say anything about it; the
      // mock is `throwOnMissingStub`, so this is a default, never a
      // relaxation of an assertion.
      when(
        mockGeolocator.getLocationAccuracy(),
      ).thenAnswer((_) async => geo.LocationAccuracyStatus.precise);
      service = GeolocatorLocationService(geolocator: mockGeolocator);
    });

    group('checkPermission', () {
      test('returns denied status', () async {
        when(
          mockGeolocator.checkPermission(),
        ).thenAnswer((_) async => geo.LocationPermission.denied);

        final result = await service.checkPermission();

        expect(result, LocationPermissionStatus.denied);
        verify(mockGeolocator.checkPermission()).called(1);
      });

      test('returns deniedForever status', () async {
        when(
          mockGeolocator.checkPermission(),
        ).thenAnswer((_) async => geo.LocationPermission.deniedForever);

        final result = await service.checkPermission();

        expect(result, LocationPermissionStatus.deniedForever);
      });

      test('returns whileInUse status', () async {
        when(
          mockGeolocator.checkPermission(),
        ).thenAnswer((_) async => geo.LocationPermission.whileInUse);

        final result = await service.checkPermission();

        expect(result, LocationPermissionStatus.whileInUse);
      });

      test('returns always status', () async {
        when(
          mockGeolocator.checkPermission(),
        ).thenAnswer((_) async => geo.LocationPermission.always);

        final result = await service.checkPermission();

        expect(result, LocationPermissionStatus.always);
      });

      test('returns notDetermined for unableToDetermine', () async {
        when(
          mockGeolocator.checkPermission(),
        ).thenAnswer((_) async => geo.LocationPermission.unableToDetermine);

        final result = await service.checkPermission();

        expect(result, LocationPermissionStatus.notDetermined);
      });
    });

    group('requestPermission', () {
      test('returns true for whileInUse permission', () async {
        when(
          mockGeolocator.requestPermission(),
        ).thenAnswer((_) async => geo.LocationPermission.whileInUse);

        final result = await service.requestPermission();

        expect(result, isTrue);
        verify(mockGeolocator.requestPermission()).called(1);
      });

      test('returns true for always permission', () async {
        when(
          mockGeolocator.requestPermission(),
        ).thenAnswer((_) async => geo.LocationPermission.always);

        final result = await service.requestPermission();

        expect(result, isTrue);
      });

      test('returns false for denied permission', () async {
        when(
          mockGeolocator.requestPermission(),
        ).thenAnswer((_) async => geo.LocationPermission.denied);

        final result = await service.requestPermission();

        expect(result, isFalse);
      });

      test('returns false for deniedForever permission', () async {
        when(
          mockGeolocator.requestPermission(),
        ).thenAnswer((_) async => geo.LocationPermission.deniedForever);

        final result = await service.requestPermission();

        expect(result, isFalse);
      });

      test('returns false for unableToDetermine', () async {
        when(
          mockGeolocator.requestPermission(),
        ).thenAnswer((_) async => geo.LocationPermission.unableToDetermine);

        final result = await service.requestPermission();

        expect(result, isFalse);
      });
    });

    group('isLocationServiceEnabled', () {
      test('returns true when location services are enabled', () async {
        when(
          mockGeolocator.isLocationServiceEnabled(),
        ).thenAnswer((_) async => true);

        final result = await service.isLocationServiceEnabled();

        expect(result, isTrue);
        verify(mockGeolocator.isLocationServiceEnabled()).called(1);
      });

      test('returns false when location services are disabled', () async {
        when(
          mockGeolocator.isLocationServiceEnabled(),
        ).thenAnswer((_) async => false);

        final result = await service.isLocationServiceEnabled();

        expect(result, isFalse);
      });
    });

    group('getCurrentLocation', () {
      final mockPosition = geo.Position(
        latitude: 37.7749,
        longitude: -122.4194,
        timestamp: DateTime(2024),
        accuracy: 10.0,
        altitude: 100.0,
        altitudeAccuracy: 5.0,
        heading: 270.0,
        headingAccuracy: 2.0,
        speed: 5.5,
        speedAccuracy: 1.0,
      );

      test('throws when location services are disabled', () async {
        when(
          mockGeolocator.isLocationServiceEnabled(),
        ).thenAnswer((_) async => false);

        await expectLater(
          service.getCurrentLocation(),
          throwsA(
            isA<LocationServiceException>().having(
              (e) => e.message,
              'message',
              contains('Location services are disabled'),
            ),
          ),
        );

        verify(mockGeolocator.isLocationServiceEnabled()).called(1);
        verifyNever(mockGeolocator.checkPermission());
      });

      test('requests permission when denied and user grants it', () async {
        when(
          mockGeolocator.isLocationServiceEnabled(),
        ).thenAnswer((_) async => true);
        when(
          mockGeolocator.checkPermission(),
        ).thenAnswer((_) async => geo.LocationPermission.denied);
        when(
          mockGeolocator.requestPermission(),
        ).thenAnswer((_) async => geo.LocationPermission.whileInUse);
        when(
          mockGeolocator.getCurrentPosition(
            locationSettings: anyNamed('locationSettings'),
          ),
        ).thenAnswer((_) async => mockPosition);

        final result = await service.getCurrentLocation();

        expect(result.latitude, 37.7749);
        expect(result.longitude, -122.4194);
        verify(mockGeolocator.requestPermission()).called(1);
        verify(
          mockGeolocator.getCurrentPosition(
            locationSettings: anyNamed('locationSettings'),
          ),
        ).called(1);
      });

      test('throws when permission is denied after request', () async {
        when(
          mockGeolocator.isLocationServiceEnabled(),
        ).thenAnswer((_) async => true);
        when(
          mockGeolocator.checkPermission(),
        ).thenAnswer((_) async => geo.LocationPermission.denied);
        when(
          mockGeolocator.requestPermission(),
        ).thenAnswer((_) async => geo.LocationPermission.denied);

        await expectLater(
          service.getCurrentLocation(),
          throwsA(
            isA<LocationServiceException>().having(
              (e) => e.message,
              'message',
              equals('Location permission denied'),
            ),
          ),
        );

        verify(mockGeolocator.requestPermission()).called(1);
        verifyNever(
          mockGeolocator.getCurrentPosition(
            locationSettings: anyNamed('locationSettings'),
          ),
        );
      });

      test('throws when permission is deniedForever', () async {
        when(
          mockGeolocator.isLocationServiceEnabled(),
        ).thenAnswer((_) async => true);
        when(
          mockGeolocator.checkPermission(),
        ).thenAnswer((_) async => geo.LocationPermission.denied);
        when(
          mockGeolocator.requestPermission(),
        ).thenAnswer((_) async => geo.LocationPermission.deniedForever);

        await expectLater(
          service.getCurrentLocation(),
          throwsA(
            isA<LocationServiceException>().having(
              (e) => e.message,
              'message',
              contains('denied forever'),
            ),
          ),
        );
      });

      test('succeeds when permission is already granted', () async {
        when(
          mockGeolocator.isLocationServiceEnabled(),
        ).thenAnswer((_) async => true);
        when(
          mockGeolocator.checkPermission(),
        ).thenAnswer((_) async => geo.LocationPermission.whileInUse);
        when(
          mockGeolocator.getCurrentPosition(
            locationSettings: anyNamed('locationSettings'),
          ),
        ).thenAnswer((_) async => mockPosition);

        final result = await service.getCurrentLocation();

        expect(result.latitude, 37.7749);
        expect(result.longitude, -122.4194);
        expect(result.timestamp, DateTime(2024));
        expect(result.accuracy, 10.0);
        expect(result.altitude, 100.0);
        expect(result.speed, 5.5);
        expect(result.heading, 270.0);
        verifyNever(mockGeolocator.requestPermission());
      });

      test('falls back to last known position on error', () async {
        final lastPosition = geo.Position(
          latitude: 37.7750,
          longitude: -122.4195,
          timestamp: DateTime(2024).subtract(const Duration(minutes: 5)),
          accuracy: 15.0,
          altitude: 95.0,
          altitudeAccuracy: 5.0,
          heading: 180.0,
          headingAccuracy: 2.0,
          speed: 0.0,
          speedAccuracy: 1.0,
        );

        when(
          mockGeolocator.isLocationServiceEnabled(),
        ).thenAnswer((_) async => true);
        when(
          mockGeolocator.checkPermission(),
        ).thenAnswer((_) async => geo.LocationPermission.whileInUse);
        when(
          mockGeolocator.getCurrentPosition(
            locationSettings: anyNamed('locationSettings'),
          ),
        ).thenThrow(Exception('GPS timeout'));
        when(
          mockGeolocator.getLastKnownPosition(),
        ).thenAnswer((_) async => lastPosition);

        final result = await service.getCurrentLocation();

        expect(result.latitude, 37.7750);
        expect(result.longitude, -122.4195);
        verify(
          mockGeolocator.getCurrentPosition(
            locationSettings: anyNamed('locationSettings'),
          ),
        ).called(1);
        verify(mockGeolocator.getLastKnownPosition()).called(1);
      });

      test('throws when both current and last known position fail', () async {
        when(
          mockGeolocator.isLocationServiceEnabled(),
        ).thenAnswer((_) async => true);
        when(
          mockGeolocator.checkPermission(),
        ).thenAnswer((_) async => geo.LocationPermission.whileInUse);
        when(
          mockGeolocator.getCurrentPosition(
            locationSettings: anyNamed('locationSettings'),
          ),
        ).thenThrow(Exception('GPS timeout'));
        when(
          mockGeolocator.getLastKnownPosition(),
        ).thenAnswer((_) async => null);

        await expectLater(
          service.getCurrentLocation(),
          throwsA(
            isA<LocationServiceException>().having(
              (e) => e.message,
              'message',
              contains('Failed to get location'),
            ),
          ),
        );

        verify(mockGeolocator.getLastKnownPosition()).called(1);
      });

      test('throws when last known position also throws exception', () async {
        when(
          mockGeolocator.isLocationServiceEnabled(),
        ).thenAnswer((_) async => true);
        when(
          mockGeolocator.checkPermission(),
        ).thenAnswer((_) async => geo.LocationPermission.whileInUse);
        when(
          mockGeolocator.getCurrentPosition(
            locationSettings: anyNamed('locationSettings'),
          ),
        ).thenThrow(Exception('GPS timeout'));
        when(
          mockGeolocator.getLastKnownPosition(),
        ).thenThrow(Exception('No cached position'));

        await expectLater(
          service.getCurrentLocation(),
          throwsA(isA<LocationServiceException>()),
        );

        verify(mockGeolocator.getLastKnownPosition()).called(1);
      });

      test('uses AndroidSettings with correct configuration', () async {
        when(
          mockGeolocator.isLocationServiceEnabled(),
        ).thenAnswer((_) async => true);
        when(
          mockGeolocator.checkPermission(),
        ).thenAnswer((_) async => geo.LocationPermission.whileInUse);
        when(
          mockGeolocator.getCurrentPosition(
            locationSettings: anyNamed('locationSettings'),
          ),
        ).thenAnswer((_) async => mockPosition);

        await service.getCurrentLocation();

        final captured = verify(
          mockGeolocator.getCurrentPosition(
            locationSettings: captureAnyNamed('locationSettings'),
          ),
        ).captured.single;

        expect(captured, isA<geo.AndroidSettings>());
        final settings = captured as geo.AndroidSettings;
        expect(settings.forceLocationManager, isTrue);
        expect(settings.timeLimit, const Duration(seconds: 30));
      });
    });

    group('getCurrentLocationFresh', () {
      final mockPosition = geo.Position(
        latitude: 37.7749,
        longitude: -122.4194,
        timestamp: DateTime(2024),
        accuracy: 10.0,
        altitude: 100.0,
        altitudeAccuracy: 5.0,
        heading: 270.0,
        headingAccuracy: 2.0,
        speed: 5.5,
        speedAccuracy: 1.0,
      );

      test('throws when location services are disabled', () async {
        when(
          mockGeolocator.isLocationServiceEnabled(),
        ).thenAnswer((_) async => false);

        await expectLater(
          service.getCurrentLocationFresh(),
          throwsA(
            isA<LocationServiceException>().having(
              (e) => e.message,
              'message',
              contains('Location services are disabled'),
            ),
          ),
        );
      });

      test('throws when permission is denied', () async {
        when(
          mockGeolocator.isLocationServiceEnabled(),
        ).thenAnswer((_) async => true);
        when(
          mockGeolocator.checkPermission(),
        ).thenAnswer((_) async => geo.LocationPermission.denied);
        when(
          mockGeolocator.requestPermission(),
        ).thenAnswer((_) async => geo.LocationPermission.denied);

        await expectLater(
          service.getCurrentLocationFresh(),
          throwsA(isA<LocationServiceException>()),
        );
      });

      test('succeeds with fresh position', () async {
        when(
          mockGeolocator.isLocationServiceEnabled(),
        ).thenAnswer((_) async => true);
        when(
          mockGeolocator.checkPermission(),
        ).thenAnswer((_) async => geo.LocationPermission.whileInUse);
        when(
          mockGeolocator.getCurrentPosition(
            locationSettings: anyNamed('locationSettings'),
          ),
        ).thenAnswer((_) async => mockPosition);

        final result = await service.getCurrentLocationFresh();

        expect(result.latitude, 37.7749);
        expect(result.longitude, -122.4194);
        verify(
          mockGeolocator.getCurrentPosition(
            locationSettings: anyNamed('locationSettings'),
          ),
        ).called(1);
      });

      test('does NOT fall back to last known position on error', () async {
        when(
          mockGeolocator.isLocationServiceEnabled(),
        ).thenAnswer((_) async => true);
        when(
          mockGeolocator.checkPermission(),
        ).thenAnswer((_) async => geo.LocationPermission.whileInUse);
        when(
          mockGeolocator.getCurrentPosition(
            locationSettings: anyNamed('locationSettings'),
          ),
        ).thenThrow(Exception('GPS timeout'));

        await expectLater(
          service.getCurrentLocationFresh(),
          throwsA(
            isA<LocationServiceException>().having(
              (e) => e.message,
              'message',
              contains('Failed to get fresh location'),
            ),
          ),
        );

        verify(
          mockGeolocator.getCurrentPosition(
            locationSettings: anyNamed('locationSettings'),
          ),
        ).called(1);
        verifyNever(mockGeolocator.getLastKnownPosition());
      });

      test('requests permission when needed', () async {
        when(
          mockGeolocator.isLocationServiceEnabled(),
        ).thenAnswer((_) async => true);
        when(
          mockGeolocator.checkPermission(),
        ).thenAnswer((_) async => geo.LocationPermission.denied);
        when(
          mockGeolocator.requestPermission(),
        ).thenAnswer((_) async => geo.LocationPermission.whileInUse);
        when(
          mockGeolocator.getCurrentPosition(
            locationSettings: anyNamed('locationSettings'),
          ),
        ).thenAnswer((_) async => mockPosition);

        final result = await service.getCurrentLocationFresh();

        expect(result.latitude, 37.7749);
        verify(mockGeolocator.requestPermission()).called(1);
      });
    });

    group('getLocationStream', () {
      final mockPosition1 = geo.Position(
        latitude: 37.7749,
        longitude: -122.4194,
        timestamp: DateTime(2024),
        accuracy: 10.0,
        altitude: 100.0,
        altitudeAccuracy: 5.0,
        heading: 270.0,
        headingAccuracy: 2.0,
        speed: 5.5,
        speedAccuracy: 1.0,
      );

      final mockPosition2 = geo.Position(
        latitude: 37.7750,
        longitude: -122.4195,
        timestamp: DateTime(2024).add(const Duration(seconds: 1)),
        accuracy: 8.0,
        altitude: 101.0,
        altitudeAccuracy: 5.0,
        heading: 275.0,
        headingAccuracy: 2.0,
        speed: 6.0,
        speedAccuracy: 1.0,
      );

      test('returns stream of positions', () async {
        when(
          mockGeolocator.getPositionStream(
            locationSettings: anyNamed('locationSettings'),
          ),
        ).thenAnswer(
          (_) => Stream.fromIterable([mockPosition1, mockPosition2]),
        );

        final stream = service.getLocationStream();
        final positions = await stream.toList();

        expect(positions, hasLength(2));
        expect(positions[0].latitude, 37.7749);
        expect(positions[0].longitude, -122.4194);
        expect(positions[1].latitude, 37.7750);
        expect(positions[1].longitude, -122.4195);
      });

      test('converts geo.Position to Position correctly', () async {
        when(
          mockGeolocator.getPositionStream(
            locationSettings: anyNamed('locationSettings'),
          ),
        ).thenAnswer((_) => Stream.fromIterable([mockPosition1]));

        final stream = service.getLocationStream();
        final position = await stream.first;

        expect(position.latitude, 37.7749);
        expect(position.longitude, -122.4194);
        expect(position.timestamp, DateTime(2024));
        expect(position.accuracy, 10.0);
        expect(position.altitude, 100.0);
        expect(position.speed, 5.5);
        expect(position.heading, 270.0);
      });

      test('uses AndroidSettings with distance filter and interval', () async {
        when(
          mockGeolocator.getPositionStream(
            locationSettings: anyNamed('locationSettings'),
          ),
        ).thenAnswer((_) => Stream.fromIterable([mockPosition1]));

        service.getLocationStream();

        final captured = verify(
          mockGeolocator.getPositionStream(
            locationSettings: captureAnyNamed('locationSettings'),
          ),
        ).captured.single;

        expect(captured, isA<geo.AndroidSettings>());
        final settings = captured as geo.AndroidSettings;
        expect(settings.forceLocationManager, isTrue);
        expect(settings.distanceFilter, 1);
        expect(settings.intervalDuration, const Duration(seconds: 1));
      });

      test('handles empty stream', () async {
        when(
          mockGeolocator.getPositionStream(
            locationSettings: anyNamed('locationSettings'),
          ),
        ).thenAnswer((_) => const Stream.empty());

        final stream = service.getLocationStream();
        final positions = await stream.toList();

        expect(positions, isEmpty);
      });

      test('propagates stream errors', () async {
        when(
          mockGeolocator.getPositionStream(
            locationSettings: anyNamed('locationSettings'),
          ),
        ).thenAnswer((_) => Stream.error(Exception('GPS lost')));

        final stream = service.getLocationStream();

        await expectLater(stream.toList(), throwsA(isA<Exception>()));
      });
    });

    group('platform-specific location settings', () {
      final mockPosition = geo.Position(
        latitude: 51.5,
        longitude: -0.12,
        timestamp: DateTime(2024),
        accuracy: 5,
        altitude: 0,
        altitudeAccuracy: 1,
        heading: 0,
        headingAccuracy: 1,
        speed: 0,
        speedAccuracy: 1,
      );

      GeolocatorLocationService serviceFor({required bool isIOS}) =>
          GeolocatorLocationService(geolocator: mockGeolocator, isIOS: isIOS);

      void stubReadyForOneShot() {
        when(
          mockGeolocator.isLocationServiceEnabled(),
        ).thenAnswer((_) async => true);
        when(
          mockGeolocator.checkPermission(),
        ).thenAnswer((_) async => geo.LocationPermission.whileInUse);
        when(
          mockGeolocator.getCurrentPosition(
            locationSettings: anyNamed('locationSettings'),
          ),
        ).thenAnswer((_) async => mockPosition);
      }

      void stubStream() {
        when(
          mockGeolocator.getPositionStream(
            locationSettings: anyNamed('locationSettings'),
          ),
        ).thenAnswer((_) => Stream.fromIterable([mockPosition]));
      }

      Object captureCurrentPositionSettings() => verify(
        mockGeolocator.getCurrentPosition(
          locationSettings: captureAnyNamed('locationSettings'),
        ),
      ).captured.single as Object;

      Object captureStreamSettings() => verify(
        mockGeolocator.getPositionStream(
          locationSettings: captureAnyNamed('locationSettings'),
        ),
      ).captured.single as Object;

      test('getCurrentLocation uses AppleSettings on iOS', () async {
        stubReadyForOneShot();

        await serviceFor(isIOS: true).getCurrentLocation();

        final captured = captureCurrentPositionSettings();
        expect(captured, isA<geo.AppleSettings>());
        expect(
          (captured as geo.AppleSettings).timeLimit,
          const Duration(seconds: 30),
        );
      });

      test('getCurrentLocation uses AndroidSettings off iOS', () async {
        stubReadyForOneShot();

        await serviceFor(isIOS: false).getCurrentLocation();

        final captured = captureCurrentPositionSettings();
        expect(captured, isA<geo.AndroidSettings>());
        expect((captured as geo.AndroidSettings).forceLocationManager, isTrue);
      });

      test('getCurrentLocationFresh uses AppleSettings on iOS', () async {
        stubReadyForOneShot();

        await serviceFor(isIOS: true).getCurrentLocationFresh();

        expect(captureCurrentPositionSettings(), isA<geo.AppleSettings>());
      });

      test(
        'getLocationStream(backgroundSharingEnabled: true) sets '
        'background-capable AppleSettings on iOS',
        () {
          stubStream();

          serviceFor(
            isIOS: true,
          ).getLocationStream(backgroundSharingEnabled: true).listen((_) {});

          final captured = captureStreamSettings();
          expect(captured, isA<geo.AppleSettings>());
          final settings = captured as geo.AppleSettings;
          expect(settings.distanceFilter, 1);
          expect(settings.allowBackgroundLocationUpdates, isTrue);
          expect(settings.showBackgroundLocationIndicator, isTrue);
          expect(settings.pauseLocationUpdatesAutomatically, isFalse);
        },
      );

      test(
        'getLocationStream(backgroundSharingEnabled: false) sets background '
        'flags explicitly false on iOS (no accidental keep-alive)',
        () {
          stubStream();

          serviceFor(
            isIOS: true,
          ).getLocationStream(backgroundSharingEnabled: false).listen((_) {});

          final captured = captureStreamSettings();
          expect(captured, isA<geo.AppleSettings>());
          final settings = captured as geo.AppleSettings;
          // AppleSettings DEFAULTS allowBackgroundLocationUpdates to true;
          // the service must override it to false for opt-out users.
          expect(settings.allowBackgroundLocationUpdates, isFalse);
          expect(settings.showBackgroundLocationIndicator, isFalse);
          expect(settings.pauseLocationUpdatesAutomatically, isFalse);
        },
      );

      test('getLocationStream defaults to backgroundSharingEnabled: false',
          () {
        stubStream();

        serviceFor(isIOS: true).getLocationStream().listen((_) {});

        final captured = captureStreamSettings();
        expect(
          (captured as geo.AppleSettings).allowBackgroundLocationUpdates,
          isFalse,
        );
      });

      test('getLocationStream ignores backgroundSharingEnabled on Android',
          () {
        stubStream();

        serviceFor(
          isIOS: false,
        ).getLocationStream(backgroundSharingEnabled: true).listen((_) {});

        final captured = captureStreamSettings();
        expect(captured, isA<geo.AndroidSettings>());
        expect((captured as geo.AndroidSettings).forceLocationManager, isTrue);
      });
    });

    group('stream-position cache (getCurrentLocation)', () {
      geo.Position positionAt(DateTime timestamp) => geo.Position(
        latitude: 51.5,
        longitude: -0.12,
        timestamp: timestamp,
        accuracy: 5,
        altitude: 0,
        altitudeAccuracy: 1,
        heading: 0,
        headingAccuracy: 1,
        speed: 0,
        speedAccuracy: 1,
      );

      GeolocatorLocationService serviceFor({required bool isIOS}) =>
          GeolocatorLocationService(geolocator: mockGeolocator, isIOS: isIOS);

      /// Stubs the access gate as "provider on, permission granted" and
      /// nothing else, so a test can prove where a returned position came
      /// from (cache vs one-shot vs last-known).
      void stubAccessGranted() {
        when(
          mockGeolocator.isLocationServiceEnabled(),
        ).thenAnswer((_) async => true);
        when(
          mockGeolocator.checkPermission(),
        ).thenAnswer((_) async => geo.LocationPermission.whileInUse);
      }

      void stubOneShot(geo.Position position) {
        stubAccessGranted();
        when(
          mockGeolocator.getCurrentPosition(
            locationSettings: anyNamed('locationSettings'),
          ),
        ).thenAnswer((_) async => position);
      }

      /// Pushes [position] through the service's unified stream so the tee
      /// populates the cache, and leaves the cache warm.
      ///
      /// Deliberately an OPEN [StreamController] rather than
      /// `Stream.fromIterable`: a real geolocator position stream is
      /// unbounded, and the service treats a CLOSED stream as "no further
      /// fix will arrive" and drops the cache. Cancelling the subscription
      /// (what a settings rebuild does) raises no done event, so the warm
      /// fix survives — which is the state these tests are about.
      Future<void> seedCache(
        GeolocatorLocationService service,
        geo.Position position,
      ) async {
        final controller = StreamController<geo.Position>();
        when(
          mockGeolocator.getPositionStream(
            locationSettings: anyNamed('locationSettings'),
          ),
        ).thenAnswer((_) => controller.stream);
        final sub = service.getLocationStream().listen((_) {});
        controller.add(position);
        await Future<void>.delayed(Duration.zero);
        await sub.cancel();
      }

      test(
        'returns the cached stream position without a one-shot when fresh',
        () async {
          final service = serviceFor(isIOS: true);
          await seedCache(service, positionAt(DateTime.now()));
          stubAccessGranted();

          final result = await service.getCurrentLocation();

          expect(result.latitude, 51.5);
          expect(result.longitude, -0.12);
          verifyNever(
            mockGeolocator.getCurrentPosition(
              locationSettings: anyNamed('locationSettings'),
            ),
          );
        },
      );

      test(
        'falls through to the one-shot when the cache is older than '
        'kStreamPositionMaxAge',
        () async {
          final service = serviceFor(isIOS: true);
          final stale = DateTime.now().subtract(
            kStreamPositionMaxAge + const Duration(seconds: 1),
          );
          await seedCache(service, positionAt(stale));
          stubOneShot(positionAt(DateTime.now()));

          await service.getCurrentLocation();

          verify(
            mockGeolocator.getCurrentPosition(
              locationSettings: anyNamed('locationSettings'),
            ),
          ).called(1);
        },
      );

      test('falls through to the one-shot when no stream position exists',
          () async {
        final service = serviceFor(isIOS: true);
        stubOneShot(positionAt(DateTime.now()));

        await service.getCurrentLocation();

        verify(
          mockGeolocator.getCurrentPosition(
            locationSettings: anyNamed('locationSettings'),
          ),
        ).called(1);
      });

      test('a stream error does not populate the cache', () async {
        final service = serviceFor(isIOS: true);
        when(
          mockGeolocator.getPositionStream(
            locationSettings: anyNamed('locationSettings'),
          ),
        ).thenAnswer(
          (_) => Stream<geo.Position>.error(Exception('gps failure')),
        );
        await expectLater(
          service.getLocationStream().drain<void>(),
          throwsA(isA<Exception>()),
        );
        stubOneShot(positionAt(DateTime.now()));

        await service.getCurrentLocation();

        // Cache stayed empty → the one-shot ran.
        verify(
          mockGeolocator.getCurrentPosition(
            locationSettings: anyNamed('locationSettings'),
          ),
        ).called(1);
      });

      test('clearCachedPosition drops the cache', () async {
        final service = serviceFor(isIOS: true);
        await seedCache(service, positionAt(DateTime.now()));
        stubOneShot(positionAt(DateTime.now()));

        service.clearCachedPosition();
        await service.getCurrentLocation();

        verify(
          mockGeolocator.getCurrentPosition(
            locationSettings: anyNamed('locationSettings'),
          ),
        ).called(1);
      });

      test(
        'backgrounded on iOS with no cache: uses getLastKnownPosition and '
        'never attempts the one-shot',
        () async {
          final service = serviceFor(isIOS: true)..foregroundActive = false;
          stubAccessGranted();
          when(
            mockGeolocator.getLastKnownPosition(),
          ).thenAnswer((_) async => positionAt(DateTime.now()));

          final result = await service.getCurrentLocation();

          expect(result.latitude, 51.5);
          verifyNever(
            mockGeolocator.getCurrentPosition(
              locationSettings: anyNamed('locationSettings'),
            ),
          );
        },
      );

      test(
        'backgrounded on iOS with no last-known fix: falls through to the '
        'foreground chain as a final attempt',
        () async {
          final service = serviceFor(isIOS: true)..foregroundActive = false;
          when(
            mockGeolocator.getLastKnownPosition(),
          ).thenAnswer((_) async => null);
          stubOneShot(positionAt(DateTime.now()));

          await service.getCurrentLocation();

          verify(
            mockGeolocator.getCurrentPosition(
              locationSettings: anyNamed('locationSettings'),
            ),
          ).called(1);
        },
      );

      test('foregroundActive=false has no effect on Android', () async {
        final service = serviceFor(isIOS: false)..foregroundActive = false;
        stubOneShot(positionAt(DateTime.now()));

        await service.getCurrentLocation();

        verify(
          mockGeolocator.getCurrentPosition(
            locationSettings: anyNamed('locationSettings'),
          ),
        ).called(1);
        verifyNever(mockGeolocator.getLastKnownPosition());
      });

      test('getCurrentLocationFresh ignores the cache entirely', () async {
        final service = serviceFor(isIOS: true);
        await seedCache(service, positionAt(DateTime.now()));
        stubOneShot(positionAt(DateTime.now()));

        await service.getCurrentLocationFresh();

        verify(
          mockGeolocator.getCurrentPosition(
            locationSettings: anyNamed('locationSettings'),
          ),
        ).called(1);
      });
    });

    // -----------------------------------------------------------------
    // Access gate.
    //
    // The cached stream fix (and the iOS-backgrounded last-known read)
    // used to be served BEFORE the service-enabled and permission checks,
    // and nothing dropped the cache when access ended. Wherever the
    // process survives losing location access — an iOS app that keeps
    // running while backgrounded, an Android app-op flip — that published
    // the user's last position to their circles for up to
    // `kStreamPositionMaxAge` (168 s) after consent was gone.
    //
    // Two independent properties are pinned here, because either alone
    // leaves a hole: every position-producing path is GATED on a live
    // access check, and every observation of lost access CLEARS the cache
    // rather than letting it age out.
    // -----------------------------------------------------------------
    group('access gate — no cached fix may outlive location access', () {
      /// The coordinate that reaches the cache through the stream tee.
      geo.Position cachedFix({DateTime? timestamp}) => geo.Position(
        latitude: 51.5,
        longitude: -0.12,
        timestamp: timestamp ?? DateTime.now(),
        accuracy: 5,
        altitude: 0,
        altitudeAccuracy: 1,
        heading: 0,
        headingAccuracy: 1,
        speed: 0,
        speedAccuracy: 1,
      );

      /// Distinct from [cachedFix] so an assertion can tell a one-shot
      /// result apart from a resurrected cache entry.
      final oneShotFix = geo.Position(
        latitude: 10,
        longitude: 20,
        timestamp: DateTime.now(),
        accuracy: 5,
        altitude: 0,
        altitudeAccuracy: 1,
        heading: 0,
        headingAccuracy: 1,
        speed: 0,
        speedAccuracy: 1,
      );

      /// Distinct again, for the iOS-backgrounded branch.
      final lastKnownFix = geo.Position(
        latitude: 30,
        longitude: 40,
        timestamp: DateTime.now(),
        accuracy: 5,
        altitude: 0,
        altitudeAccuracy: 1,
        heading: 0,
        headingAccuracy: 1,
        speed: 0,
        speedAccuracy: 1,
      );

      GeolocatorLocationService serviceFor({bool isIOS = true}) =>
          GeolocatorLocationService(geolocator: mockGeolocator, isIOS: isIOS);

      void stubServiceEnabled({required bool enabled}) {
        when(
          mockGeolocator.isLocationServiceEnabled(),
        ).thenAnswer((_) async => enabled);
      }

      void stubPermission(geo.LocationPermission permission) {
        when(
          mockGeolocator.checkPermission(),
        ).thenAnswer((_) async => permission);
      }

      void stubAccessGranted() {
        stubServiceEnabled(enabled: true);
        stubPermission(geo.LocationPermission.whileInUse);
      }

      void stubAccuracy(geo.LocationAccuracyStatus accuracy) {
        when(
          mockGeolocator.getLocationAccuracy(),
        ).thenAnswer((_) async => accuracy);
      }

      void stubOneShot(geo.Position position) {
        when(
          mockGeolocator.getCurrentPosition(
            locationSettings: anyNamed('locationSettings'),
          ),
        ).thenAnswer((_) async => position);
      }

      /// Subscribes the unified stream, feeds [position] through the tee,
      /// and hands back the still-open controller plus its subscription so
      /// a test can end the stream the way the platform would (error or
      /// close) instead of merely cancelling.
      Future<
        ({
          StreamController<geo.Position> controller,
          StreamSubscription<Position> subscription,
        })
      >
      openStream(
        GeolocatorLocationService service,
        geo.Position position,
      ) async {
        final controller = StreamController<geo.Position>();
        when(
          mockGeolocator.getPositionStream(
            locationSettings: anyNamed('locationSettings'),
          ),
        ).thenAnswer((_) => controller.stream);
        final subscription = service.getLocationStream().listen(
          (_) {},
          onError: (Object _) {},
        );
        addTearDown(subscription.cancel);
        controller.add(position);
        await Future<void>.delayed(Duration.zero);
        return (controller: controller, subscription: subscription);
      }

      /// A service whose cache holds a FRESH [cachedFix] — i.e. one the
      /// pre-fix code would have happily served for the next 168 s.
      ///
      /// The stream subscription is cancelled (not closed) afterwards:
      /// cancellation raises no done event, so this models "the stream ran
      /// and delivered", not "the stream ended".
      Future<GeolocatorLocationService> serviceWithWarmCache({
        bool isIOS = true,
      }) async {
        final service = serviceFor(isIOS: isIOS);
        final handle = await openStream(service, cachedFix());
        await handle.subscription.cancel();
        return service;
      }

      /// Proves the cache is EMPTY by re-granting access and showing the
      /// next call has to go to the one-shot, returning [oneShotFix]
      /// rather than the pre-revocation [cachedFix].
      Future<void> expectCacheDoesNotResurrect(
        GeolocatorLocationService service,
      ) async {
        stubAccessGranted();
        stubOneShot(oneShotFix);

        final result = await service.getCurrentLocation();

        expect(
          result.latitude,
          10,
          reason: 'a re-grant resurrected the pre-revocation cached fix — '
              'the cache was bypassed, not cleared',
        );
        verify(
          mockGeolocator.getCurrentPosition(
            locationSettings: anyNamed('locationSettings'),
          ),
        ).called(1);
      }

      group('the gate runs before any position is produced', () {
        test('a fresh cached fix is not served once permission is denied',
            () async {
          final service = await serviceWithWarmCache();
          stubServiceEnabled(enabled: true);
          stubPermission(geo.LocationPermission.denied);
          when(
            mockGeolocator.requestPermission(),
          ).thenAnswer((_) async => geo.LocationPermission.denied);

          await expectLater(
            service.getCurrentLocation(),
            throwsA(isA<LocationServiceException>()),
          );

          verifyNever(
            mockGeolocator.getCurrentPosition(
              locationSettings: anyNamed('locationSettings'),
            ),
          );
          verifyNever(mockGeolocator.getLastKnownPosition());
        });

        test(
          'a fresh cached fix is not served once permission reads '
          'deniedForever (no prompt, no position)',
          () async {
            final service = await serviceWithWarmCache();
            stubServiceEnabled(enabled: true);
            stubPermission(geo.LocationPermission.deniedForever);

            await expectLater(
              service.getCurrentLocation(),
              throwsA(
                isA<LocationServiceException>().having(
                  (e) => e.message,
                  'message',
                  contains('denied forever'),
                ),
              ),
            );

            // A direct deniedForever read used to fall THROUGH to the
            // one-shot, whose failure path then returned last-known.
            verifyNever(mockGeolocator.requestPermission());
            verifyNever(
              mockGeolocator.getCurrentPosition(
                locationSettings: anyNamed('locationSettings'),
              ),
            );
            verifyNever(mockGeolocator.getLastKnownPosition());
          },
        );

        test(
          'a fresh cached fix is not served once the service reports '
          'disabled',
          () async {
            final service = await serviceWithWarmCache();
            stubServiceEnabled(enabled: false);

            await expectLater(
              service.getCurrentLocation(),
              throwsA(
                isA<LocationServiceException>().having(
                  (e) => e.message,
                  'message',
                  contains('Location services are disabled'),
                ),
              ),
            );

            verifyNever(
              mockGeolocator.getCurrentPosition(
                locationSettings: anyNamed('locationSettings'),
              ),
            );
            verifyNever(mockGeolocator.getLastKnownPosition());
          },
        );

        test(
          'the iOS-backgrounded last-known branch is gated on the service '
          'being enabled',
          () async {
            final service = serviceFor()..foregroundActive = false;
            stubServiceEnabled(enabled: false);
            when(
              mockGeolocator.getLastKnownPosition(),
            ).thenAnswer((_) async => lastKnownFix);

            await expectLater(
              service.getCurrentLocation(),
              throwsA(isA<LocationServiceException>()),
            );

            verifyNever(mockGeolocator.getLastKnownPosition());
          },
        );

        test(
          'the iOS-backgrounded last-known branch is gated on permission',
          () async {
            final service = serviceFor()..foregroundActive = false;
            stubServiceEnabled(enabled: true);
            stubPermission(geo.LocationPermission.deniedForever);
            when(
              mockGeolocator.getLastKnownPosition(),
            ).thenAnswer((_) async => lastKnownFix);

            await expectLater(
              service.getCurrentLocation(),
              throwsA(isA<LocationServiceException>()),
            );

            verifyNever(mockGeolocator.getLastKnownPosition());
          },
        );

        test(
          'the gate is consulted on EVERY call — a warm cache never '
          'memoises it away',
          () async {
            final service = await serviceWithWarmCache();
            stubAccessGranted();

            await service.getCurrentLocation();
            await service.getCurrentLocation();

            verify(mockGeolocator.isLocationServiceEnabled()).called(2);
            verify(mockGeolocator.checkPermission()).called(2);
          },
        );

        test(
          'an `unableToDetermine` gate withholds the warm cache and falls '
          'through to the one-shot',
          () async {
            // Web-only in production, but the arm is reachable in code and
            // returning `true` from it — or dropping the `if (granted)`
            // wrapper the cache read sits inside — would serve a stored
            // coordinate on an authorization nobody could determine.
            final service = await serviceWithWarmCache();
            stubServiceEnabled(enabled: true);
            stubPermission(geo.LocationPermission.unableToDetermine);
            stubOneShot(oneShotFix);

            final result = await service.getCurrentLocation();

            expect(
              result.latitude,
              10,
              reason: 'an undeterminable authorization is not consent — the '
                  'cached fix must be withheld, not served',
            );
            verify(
              mockGeolocator.getCurrentPosition(
                locationSettings: anyNamed('locationSettings'),
              ),
            ).called(1);
          },
        );

        test(
          'an `unableToDetermine` gate also withholds the iOS-backgrounded '
          'last-known shortcut',
          () async {
            // The `if (granted)` wrapper guards the last-known branch as
            // well as the cache read. Without it a backgrounded iOS call
            // would hand back a STORED coordinate on an undeterminable
            // authorization, skipping the one-shot entirely.
            final service = serviceFor()..foregroundActive = false;
            stubServiceEnabled(enabled: true);
            stubPermission(geo.LocationPermission.unableToDetermine);
            stubOneShot(oneShotFix);
            when(
              mockGeolocator.getLastKnownPosition(),
            ).thenAnswer((_) async => lastKnownFix);

            final result = await service.getCurrentLocation();

            expect(result.latitude, 10);
            verify(
              mockGeolocator.getCurrentPosition(
                locationSettings: anyNamed('locationSettings'),
              ),
            ).called(1);
            verifyNever(mockGeolocator.getLastKnownPosition());
          },
        );
      });

      group('the gate never prompts from the background', () {
        test(
          'backgrounded: a denied read is NOT turned into a prompt',
          () async {
            // On iOS `denied` covers `notDetermined`, and a prompt raised
            // while backgrounded is deferred by the OS — geolocator's
            // delegate early-returns on `notDetermined`, so its
            // FlutterResult is never invoked and this await would never
            // return, wedging the per-circle publish chain for the rest of
            // the process.
            final service = await serviceWithWarmCache();
            service.foregroundActive = false;
            stubServiceEnabled(enabled: true);
            stubPermission(geo.LocationPermission.denied);
            // Stubbed to SUCCEED on purpose. Leaving it unstubbed would make
            // this test go red on a MissingStubError if the guard were ever
            // removed — red for the right reason by accident. Stubbing a
            // grant models the real regression instead: the prompt is
            // reached, iOS answers it (here, instantly), and the call
            // returns a position it should never have been able to produce.
            when(
              mockGeolocator.requestPermission(),
            ).thenAnswer((_) async => geo.LocationPermission.whileInUse);
            stubOneShot(oneShotFix);

            await expectLater(
              service.getCurrentLocation(),
              throwsA(isA<LocationServiceException>()),
            );

            verifyNever(mockGeolocator.requestPermission());
          },
        );

        test(
          'the un-prompted background denial fails CLOSED: no position, and '
          'the cache is gone',
          () async {
            // Skipping the prompt must not become a way to skip the denial:
            // the un-prompted read stays `denied` and takes the throwing
            // branch, having dropped the cached fix on the way.
            final service = await serviceWithWarmCache();
            service.foregroundActive = false;
            stubServiceEnabled(enabled: true);
            stubPermission(geo.LocationPermission.denied);
            // See the sibling test: a grant that the prompt WOULD have
            // returned, so removing the foreground guard produces a real
            // coordinate here rather than a MissingStubError.
            when(
              mockGeolocator.requestPermission(),
            ).thenAnswer((_) async => geo.LocationPermission.whileInUse);
            stubOneShot(oneShotFix);
            when(
              mockGeolocator.getLastKnownPosition(),
            ).thenAnswer((_) async => lastKnownFix);

            await expectLater(
              service.getCurrentLocation(),
              throwsA(isA<LocationServiceException>()),
            );

            verifyNever(
              mockGeolocator.getCurrentPosition(
                locationSettings: anyNamed('locationSettings'),
              ),
            );
            verifyNever(mockGeolocator.getLastKnownPosition());

            service.foregroundActive = true;
            await expectCacheDoesNotResurrect(service);
          },
        );

        test(
          'foregrounded: a denied read still prompts (the prompt is not '
          'globally disabled)',
          () async {
            final service = serviceFor();
            stubServiceEnabled(enabled: true);
            stubPermission(geo.LocationPermission.denied);
            when(
              mockGeolocator.requestPermission(),
            ).thenAnswer((_) async => geo.LocationPermission.whileInUse);
            stubOneShot(oneShotFix);

            final result = await service.getCurrentLocation();

            expect(result.latitude, 10);
            verify(mockGeolocator.requestPermission()).called(1);
          },
        );

        test(
          'a re-grant does not resurrect the fix cached before the denial',
          () async {
            // The clear inside the `denied` branch runs BEFORE the prompt,
            // precisely so that saying "Allow" cannot hand back a
            // coordinate captured while the answer was "no". Nothing else
            // covers it: the later `case denied:` clear only fires when the
            // prompt is also refused.
            final service = await serviceWithWarmCache();
            stubServiceEnabled(enabled: true);
            stubPermission(geo.LocationPermission.denied);
            when(
              mockGeolocator.requestPermission(),
            ).thenAnswer((_) async => geo.LocationPermission.whileInUse);
            stubOneShot(oneShotFix);

            final result = await service.getCurrentLocation();

            expect(
              result.latitude,
              10,
              reason: 're-granting permission resurrected the pre-revocation '
                  'cached fix — it was bypassed during the denial, not '
                  'cleared',
            );
            verify(
              mockGeolocator.getCurrentPosition(
                locationSettings: anyNamed('locationSettings'),
              ),
            ).called(1);
          },
        );
      });

      group('a precision downgrade is an access loss too', () {
        /// Runs one gated call under [accuracy] with a COLD cache, so the
        /// service records that authorization as the baseline. Returns a
        /// service whose cache is then warmed from the stream.
        Future<GeolocatorLocationService> serviceBaselinedAt(
          geo.LocationAccuracyStatus accuracy,
        ) async {
          final service = serviceFor();
          stubAccessGranted();
          stubAccuracy(accuracy);
          stubOneShot(oneShotFix);
          await service.getCurrentLocation();

          final handle = await openStream(service, cachedFix());
          await handle.subscription.cancel();
          return service;
        }

        test(
          'precise → reduced drops the cached precise fix',
          () async {
            // iOS: Settings → Privacy → Location Services → Precise
            // Location off. Android: FINE revoked while COARSE remains.
            // `checkPermission()` keeps reporting whileInUse in both, so
            // this transition is the only signal there is.
            final service = await serviceBaselinedAt(
              geo.LocationAccuracyStatus.precise,
            );
            stubAccessGranted();
            stubAccuracy(geo.LocationAccuracyStatus.reduced);
            stubOneShot(oneShotFix);

            final result = await service.getCurrentLocation();

            expect(
              result.latitude,
              10,
              reason: 'a fix captured under a precise grant was served after '
                  'the user downgraded to approximate location',
            );
          },
        );

        test(
          'a warm cache of unknown provenance is dropped the first time the '
          'gate sees `reduced`',
          () async {
            // getLocationStream fills the cache WITHOUT running the gate, so
            // on the first gated call there is no baseline to compare
            // against. Treating that as "it must have been captured under
            // the current reduced grant" is the optimistic reading, and the
            // cache would then be a precise fix from before the downgrade.
            final service = serviceFor();
            final handle = await openStream(service, cachedFix());
            await handle.subscription.cancel();
            stubAccessGranted();
            stubAccuracy(geo.LocationAccuracyStatus.reduced);
            stubOneShot(oneShotFix);

            final result = await service.getCurrentLocation();

            expect(result.latitude, 10);
          },
        );

        test(
          'steady `reduced` still serves the cache (no one-shot per tick)',
          () async {
            final service = await serviceBaselinedAt(
              geo.LocationAccuracyStatus.reduced,
            );
            stubAccessGranted();
            stubAccuracy(geo.LocationAccuracyStatus.reduced);

            final result = await service.getCurrentLocation();

            expect(
              result.latitude,
              51.5,
              reason: 'an approximate-mode user must not be forced onto the '
                  'one-shot on every publish tick — only the TRANSITION is '
                  'an access loss',
            );
          },
        );

        test(
          'reduced → precise is an upgrade and keeps the cache',
          () async {
            final service = await serviceBaselinedAt(
              geo.LocationAccuracyStatus.reduced,
            );
            stubAccessGranted();
            stubAccuracy(geo.LocationAccuracyStatus.precise);

            final result = await service.getCurrentLocation();

            expect(result.latitude, 51.5);
          },
        );

        test(
          'an intervening `unknown` does not destroy a settled `reduced` '
          'baseline',
          () async {
            // `unknown` means "no information", so the baseline must survive
            // it. Recording it cannot create a false NEGATIVE (the
            // comparison is against `reduced`, so an `unknown` baseline
            // still trips the next real downgrade) but it does create a
            // false POSITIVE: the next reduced read would look like a fresh
            // downgrade and drop a cache captured under the very same
            // authorization. That is the direction this pins.
            final service = await serviceBaselinedAt(
              geo.LocationAccuracyStatus.reduced,
            );
            stubAccessGranted();
            stubAccuracy(geo.LocationAccuracyStatus.unknown);

            expect((await service.getCurrentLocation()).latitude, 51.5);

            stubAccuracy(geo.LocationAccuracyStatus.reduced);
            stubOneShot(oneShotFix);

            expect(
              (await service.getCurrentLocation()).latitude,
              51.5,
              reason: 'the `unknown` read was recorded as the baseline, so a '
                  'steady approximate grant now reads as a downgrade and '
                  'costs a one-shot every time the platform is unsure',
            );
          },
        );

        test(
          '`unknown` still lets a later genuine downgrade through',
          () async {
            // The other direction: ignoring `unknown` must not make the
            // service blind to the precise → reduced transition that
            // follows one.
            final service = await serviceBaselinedAt(
              geo.LocationAccuracyStatus.precise,
            );
            stubAccessGranted();
            stubAccuracy(geo.LocationAccuracyStatus.unknown);
            expect((await service.getCurrentLocation()).latitude, 51.5);

            stubAccuracy(geo.LocationAccuracyStatus.reduced);
            stubOneShot(oneShotFix);

            expect((await service.getCurrentLocation()).latitude, 10);
          },
        );

        test(
          'the accuracy read is confined to the granted arm',
          () async {
            // Android answers `getLocationAccuracy` with a permissionDenied
            // platform error when neither FINE nor COARSE is held, which
            // would turn a clean denial into a channel exception.
            final service = serviceFor();
            stubServiceEnabled(enabled: true);
            stubPermission(geo.LocationPermission.deniedForever);

            await expectLater(
              service.getCurrentLocation(),
              throwsA(isA<LocationServiceException>()),
            );

            verifyNever(mockGeolocator.getLocationAccuracy());
          },
        );

        test(
          'getCurrentLocationFresh applies the same downgrade rule',
          () async {
            final service = await serviceBaselinedAt(
              geo.LocationAccuracyStatus.precise,
            );
            stubAccessGranted();
            stubAccuracy(geo.LocationAccuracyStatus.reduced);
            stubOneShot(oneShotFix);

            await service.getCurrentLocationFresh();

            // The fresh path never serves the cache anyway; what matters is
            // that it dropped it, so a later getCurrentLocation cannot.
            stubAccuracy(geo.LocationAccuracyStatus.reduced);
            expect((await service.getCurrentLocation()).latitude, 10);
          },
        );
      });

      group('losing access clears the cache rather than ageing it out', () {
        test('a denied permission read clears it', () async {
          final service = await serviceWithWarmCache();
          stubServiceEnabled(enabled: true);
          stubPermission(geo.LocationPermission.denied);
          when(
            mockGeolocator.requestPermission(),
          ).thenAnswer((_) async => geo.LocationPermission.denied);
          await expectLater(
            service.getCurrentLocation(),
            throwsA(isA<LocationServiceException>()),
          );

          await expectCacheDoesNotResurrect(service);
        });

        test('a disabled location service clears it', () async {
          final service = await serviceWithWarmCache();
          stubServiceEnabled(enabled: false);
          await expectLater(
            service.getCurrentLocation(),
            throwsA(isA<LocationServiceException>()),
          );

          await expectCacheDoesNotResurrect(service);
        });

        test('a denial discovered by getCurrentLocationFresh clears it',
            () async {
          final service = await serviceWithWarmCache();
          stubServiceEnabled(enabled: true);
          stubPermission(geo.LocationPermission.deniedForever);
          await expectLater(
            service.getCurrentLocationFresh(),
            throwsA(isA<LocationServiceException>()),
          );

          await expectCacheDoesNotResurrect(service);
        });

        test('the public checkPermission() read clears it on a denial',
            () async {
          final service = await serviceWithWarmCache();
          stubPermission(geo.LocationPermission.deniedForever);

          expect(
            await service.checkPermission(),
            LocationPermissionStatus.deniedForever,
          );

          await expectCacheDoesNotResurrect(service);
        });

        test(
          'the public isLocationServiceEnabled() read clears it when off',
          () async {
            final service = await serviceWithWarmCache();
            stubServiceEnabled(enabled: false);

            expect(await service.isLocationServiceEnabled(), isFalse);

            await expectCacheDoesNotResurrect(service);
          },
        );

        test('an ungranted requestPermission() clears it', () async {
          final service = await serviceWithWarmCache();
          when(
            mockGeolocator.requestPermission(),
          ).thenAnswer((_) async => geo.LocationPermission.denied);

          expect(await service.requestPermission(), isFalse);

          await expectCacheDoesNotResurrect(service);
        });

        test('a mid-stream error clears it', () async {
          final service = serviceFor();
          final handle = await openStream(service, cachedFix());

          handle.controller.addError(Exception('provider disabled'));
          await Future<void>.delayed(Duration.zero);

          await expectCacheDoesNotResurrect(service);
        });

        test('the stream closing clears it', () async {
          final service = serviceFor();
          final handle = await openStream(service, cachedFix());

          await handle.controller.close();
          await Future<void>.delayed(Duration.zero);

          await expectCacheDoesNotResurrect(service);
        });

        test('a stream error still reaches subscribers', () async {
          final service = serviceFor();
          final controller = StreamController<geo.Position>();
          when(
            mockGeolocator.getPositionStream(
              locationSettings: anyNamed('locationSettings'),
            ),
          ).thenAnswer((_) => controller.stream);
          final errors = <Object>[];
          final sub = service.getLocationStream().listen(
            (_) {},
            onError: errors.add,
          );
          addTearDown(sub.cancel);

          controller.addError(Exception('provider disabled'));
          await Future<void>.delayed(Duration.zero);

          expect(errors, hasLength(1));
        });
      });

      group('granted access still works (the cache exists for a reason)', () {
        test(
          'backgrounded on iOS: a warm cache is still served with no '
          'platform position request',
          () async {
            final service = await serviceWithWarmCache();
            service.foregroundActive = false;
            stubAccessGranted();

            final result = await service.getCurrentLocation();

            expect(result.latitude, 51.5);
            expect(result.longitude, -0.12);
            verifyNever(
              mockGeolocator.getCurrentPosition(
                locationSettings: anyNamed('locationSettings'),
              ),
            );
            verifyNever(mockGeolocator.getLastKnownPosition());
          },
        );

        test(
          'backgrounded on iOS with a cold cache: the last-known fix is '
          'still used instead of the doomed one-shot',
          () async {
            final service = serviceFor()..foregroundActive = false;
            stubAccessGranted();
            when(
              mockGeolocator.getLastKnownPosition(),
            ).thenAnswer((_) async => lastKnownFix);

            final result = await service.getCurrentLocation();

            expect(result.latitude, 30);
            verifyNever(
              mockGeolocator.getCurrentPosition(
                locationSettings: anyNamed('locationSettings'),
              ),
            );
          },
        );

        test(
          'backgrounded on iOS with `always` permission: still served',
          () async {
            final service = await serviceWithWarmCache();
            service.foregroundActive = false;
            stubServiceEnabled(enabled: true);
            stubPermission(geo.LocationPermission.always);

            final result = await service.getCurrentLocation();

            expect(result.latitude, 51.5);
          },
        );

        test(
          'a cache older than kStreamPositionMaxAge still falls through to '
          'the one-shot under a granted gate',
          () async {
            final service = serviceFor();
            final handle = await openStream(
              service,
              cachedFix(
                timestamp: DateTime.now().subtract(
                  kStreamPositionMaxAge + const Duration(seconds: 1),
                ),
              ),
            );
            await handle.subscription.cancel();
            stubAccessGranted();
            stubOneShot(oneShotFix);

            final result = await service.getCurrentLocation();

            expect(result.latitude, 10);
          },
        );
      });
    });

    group('position conversion', () {
      test('converts all position fields correctly', () async {
        final geoPosition = geo.Position(
          latitude: 37.7749,
          longitude: -122.4194,
          timestamp: DateTime(2024, 1, 15, 10, 30),
          accuracy: 10.5,
          altitude: 99.8,
          altitudeAccuracy: 3.2,
          heading: 271.5,
          headingAccuracy: 1.8,
          speed: 5.6,
          speedAccuracy: 0.9,
        );

        when(
          mockGeolocator.isLocationServiceEnabled(),
        ).thenAnswer((_) async => true);
        when(
          mockGeolocator.checkPermission(),
        ).thenAnswer((_) async => geo.LocationPermission.whileInUse);
        when(
          mockGeolocator.getCurrentPosition(
            locationSettings: anyNamed('locationSettings'),
          ),
        ).thenAnswer((_) async => geoPosition);

        final result = await service.getCurrentLocation();

        expect(result.latitude, 37.7749);
        expect(result.longitude, -122.4194);
        expect(result.timestamp, DateTime(2024, 1, 15, 10, 30));
        expect(result.accuracy, 10.5);
        expect(result.altitude, 99.8);
        expect(result.speed, 5.6);
        expect(result.heading, 271.5);
      });

      test('preserves negative coordinates', () async {
        final geoPosition = geo.Position(
          latitude: -33.8688,
          longitude: 151.2093,
          timestamp: DateTime(2024),
          accuracy: 10.0,
          altitude: 50.0,
          altitudeAccuracy: 5.0,
          heading: 0.0,
          headingAccuracy: 2.0,
          speed: 0.0,
          speedAccuracy: 1.0,
        );

        when(
          mockGeolocator.isLocationServiceEnabled(),
        ).thenAnswer((_) async => true);
        when(
          mockGeolocator.checkPermission(),
        ).thenAnswer((_) async => geo.LocationPermission.whileInUse);
        when(
          mockGeolocator.getCurrentPosition(
            locationSettings: anyNamed('locationSettings'),
          ),
        ).thenAnswer((_) async => geoPosition);

        final result = await service.getCurrentLocation();

        expect(result.latitude, -33.8688);
        expect(result.longitude, 151.2093);
      });

      test('preserves extreme coordinate values', () async {
        final geoPosition = geo.Position(
          latitude: 90.0, // North pole
          longitude: 180.0, // International date line
          timestamp: DateTime(2024),
          accuracy: 10.0,
          altitude: 0.0,
          altitudeAccuracy: 5.0,
          heading: 0.0,
          headingAccuracy: 2.0,
          speed: 0.0,
          speedAccuracy: 1.0,
        );

        when(
          mockGeolocator.isLocationServiceEnabled(),
        ).thenAnswer((_) async => true);
        when(
          mockGeolocator.checkPermission(),
        ).thenAnswer((_) async => geo.LocationPermission.whileInUse);
        when(
          mockGeolocator.getCurrentPosition(
            locationSettings: anyNamed('locationSettings'),
          ),
        ).thenAnswer((_) async => geoPosition);

        final result = await service.getCurrentLocation();

        expect(result.latitude, 90.0);
        expect(result.longitude, 180.0);
      });
    });

    group('edge cases', () {
      test('handles multiple sequential getCurrentLocation calls', () async {
        final position1 = geo.Position(
          latitude: 37.7749,
          longitude: -122.4194,
          timestamp: DateTime(2024),
          accuracy: 10.0,
          altitude: 100.0,
          altitudeAccuracy: 5.0,
          heading: 270.0,
          headingAccuracy: 2.0,
          speed: 5.5,
          speedAccuracy: 1.0,
        );

        final position2 = geo.Position(
          latitude: 37.7750,
          longitude: -122.4195,
          timestamp: DateTime(2024).add(const Duration(seconds: 5)),
          accuracy: 8.0,
          altitude: 101.0,
          altitudeAccuracy: 5.0,
          heading: 275.0,
          headingAccuracy: 2.0,
          speed: 6.0,
          speedAccuracy: 1.0,
        );

        when(
          mockGeolocator.isLocationServiceEnabled(),
        ).thenAnswer((_) async => true);
        when(
          mockGeolocator.checkPermission(),
        ).thenAnswer((_) async => geo.LocationPermission.whileInUse);
        when(
          mockGeolocator.getCurrentPosition(
            locationSettings: anyNamed('locationSettings'),
          ),
        ).thenAnswer((_) async => position1);

        final result1 = await service.getCurrentLocation();
        expect(result1.latitude, 37.7749);

        when(
          mockGeolocator.getCurrentPosition(
            locationSettings: anyNamed('locationSettings'),
          ),
        ).thenAnswer((_) async => position2);

        final result2 = await service.getCurrentLocation();
        expect(result2.latitude, 37.7750);
      });

      test('handles permission upgrade from denied to granted', () async {
        final mockPosition = geo.Position(
          latitude: 37.7749,
          longitude: -122.4194,
          timestamp: DateTime(2024),
          accuracy: 10.0,
          altitude: 100.0,
          altitudeAccuracy: 5.0,
          heading: 270.0,
          headingAccuracy: 2.0,
          speed: 5.5,
          speedAccuracy: 1.0,
        );

        when(
          mockGeolocator.isLocationServiceEnabled(),
        ).thenAnswer((_) async => true);

        // First call: denied -> request -> whileInUse
        when(
          mockGeolocator.checkPermission(),
        ).thenAnswer((_) async => geo.LocationPermission.denied);
        when(
          mockGeolocator.requestPermission(),
        ).thenAnswer((_) async => geo.LocationPermission.whileInUse);
        when(
          mockGeolocator.getCurrentPosition(
            locationSettings: anyNamed('locationSettings'),
          ),
        ).thenAnswer((_) async => mockPosition);

        final result = await service.getCurrentLocation();
        expect(result.latitude, 37.7749);
        verify(mockGeolocator.requestPermission()).called(1);
      });

      test('service can be created without providing wrapper', () {
        // This should use DefaultGeolocatorWrapper
        final defaultService = GeolocatorLocationService();
        expect(defaultService, isNotNull);
      });
    });
  });
}
