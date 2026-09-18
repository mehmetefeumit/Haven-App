/// Tests for location services.
///
/// These tests verify the data structures and interfaces.
/// Integration testing requires a device or emulator.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/services/location_service.dart';

void main() {
  group('LocationService', () {
    group('Position', () {
      test('creates position with required fields', () {
        final position = Position(
          latitude: 37.7749,
          longitude: -122.4194,
          timestamp: DateTime(2024),
        );

        expect(position.latitude, 37.7749);
        expect(position.longitude, -122.4194);
        expect(position.timestamp, DateTime(2024));
        expect(position.accuracy, isNull);
        expect(position.altitude, isNull);
        expect(position.speed, isNull);
        expect(position.heading, isNull);
      });

      test('creates position with all fields', () {
        final position = Position(
          latitude: 37.7749,
          longitude: -122.4194,
          timestamp: DateTime(2024),
          accuracy: 10,
          altitude: 100,
          speed: 5.5,
          heading: 270,
        );

        expect(position.latitude, 37.7749);
        expect(position.longitude, -122.4194);
        expect(position.accuracy, 10);
        expect(position.altitude, 100);
        expect(position.speed, 5.5);
        expect(position.heading, 270);
      });

      test('privacy-sensitive fields are nullable', () {
        final position = Position(
          latitude: 37.7749,
          longitude: -122.4194,
          timestamp: DateTime.now(),
        );

        // These fields should be nullable so they can be omitted
        // when sending to Rust core for privacy
        expect(position.accuracy, isNull);
        expect(position.altitude, isNull);
        expect(position.speed, isNull);
        expect(position.heading, isNull);
      });

      test('toString exposes neither coordinates nor a wall-clock fix time',
          () {
        final position = Position(
          latitude: 37.7749,
          longitude: -122.4194,
          timestamp: DateTime.utc(2024, 3, 5, 6, 7, 8),
        );

        final str = position.toString();
        expect(str, contains('Position'));
        // Coordinates must NOT appear in toString (privacy)
        expect(str, isNot(contains('37.7749')));
        expect(str, isNot(contains('-122.4194')));
        // Rule 15: no absolute instant on the location plane — the fix age
        // is rendered as an offset from now instead.
        expect(str, isNot(contains('2024')));
        expect(str, isNot(contains(position.timestamp.toIso8601String())));
        expect(str, matches(RegExp(r'Position\(age: t[+-]\d+s\)')));
      });
    });

    group('LocationServiceException', () {
      test('creates exception with message', () {
        final exception = LocationServiceException('Test error');
        expect(exception.message, 'Test error');
      });

      test('toString includes message', () {
        final exception = LocationServiceException('Test error');
        expect(exception.toString(), contains('LocationServiceException'));
        expect(exception.toString(), contains('Test error'));
      });

      test('is an Exception', () {
        final exception = LocationServiceException('Test error');
        expect(exception, isA<Exception>());
      });
    });

    group('LocationPermissionStatus', () {
      test('has all expected values', () {
        expect(LocationPermissionStatus.notDetermined, isNotNull);
        expect(LocationPermissionStatus.denied, isNotNull);
        expect(LocationPermissionStatus.deniedForever, isNotNull);
        expect(LocationPermissionStatus.whileInUse, isNotNull);
        expect(LocationPermissionStatus.always, isNotNull);
      });

      test('enum values are distinct', () {
        const values = LocationPermissionStatus.values;
        expect(values.length, 5);
        expect(values.toSet().length, 5); // All values are distinct
      });
    });
  });
}
