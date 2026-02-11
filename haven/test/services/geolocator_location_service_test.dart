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
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart' as geo;
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
