# Dependency Injection Examples for Flutter Services

This document shows how to use dependency injection to test the Haven app services with mocks.

## Overview

All production services now accept optional dependencies via constructor parameters:

1. **NostrIdentityService**: Accepts `FlutterSecureStorage`
2. **NostrRelayService**: Accepts `DataDirectoryProvider`
3. **NostrCircleService**: Accepts `DataDirectoryProvider`
4. **GeolocatorLocationService**: Accepts `GeolocatorWrapper`

## Example: Testing NostrIdentityService with Mock Storage

```dart
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/services/nostr_identity_service.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';

@GenerateMocks([FlutterSecureStorage])
void main() {
  test('NostrIdentityService uses injected storage', () async {
    // Create mock storage
    final mockStorage = MockFlutterSecureStorage();

    // Configure mock behavior
    when(mockStorage.read(key: 'haven.nostr.identity'))
        .thenAnswer((_) async => null);

    // Inject mock into service
    final service = NostrIdentityService(storage: mockStorage);

    // Use the service - it will use the mock storage
    // Note: Full testing requires Rust FFI, this is just for storage layer
    expect(service, isNotNull);
  });
}
```

## Example: Testing NostrRelayService with Mock Directory Provider

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/services/nostr_relay_service.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';

// Create a mock directory provider
class MockDataDirectoryProvider extends Mock implements DataDirectoryProvider {}

void main() {
  test('NostrRelayService uses injected directory provider', () async {
    // Create mock provider
    final mockProvider = MockDataDirectoryProvider();

    // Configure mock behavior - return a test directory
    when(mockProvider.getDataDirectory())
        .thenAnswer((_) async => '/tmp/test-haven');

    // Inject mock into service
    final service = NostrRelayService(dataDirectoryProvider: mockProvider);

    // When initialize() is called, it will use the mock directory
    // Note: Full testing requires Rust FFI
    expect(service, isNotNull);
  });
}
```

## Example: Testing NostrCircleService with Mock Directory Provider

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/services/nostr_circle_service.dart';
import 'package:haven/src/services/nostr_relay_service.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';

class MockDataDirectoryProvider extends Mock implements DataDirectoryProvider {}

void main() {
  test('NostrCircleService uses injected directory provider', () async {
    // Create mock provider
    final mockProvider = MockDataDirectoryProvider();

    // Configure mock behavior
    when(mockProvider.getDataDirectory())
        .thenAnswer((_) async => '/tmp/test-haven');

    // Inject mock into service
    final service = NostrCircleService(dataDirectoryProvider: mockProvider);

    expect(service, isNotNull);
  });
}
```

## Example: Testing GeolocatorLocationService with Mock Geolocator

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:haven/src/services/geolocator_location_service.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';

// Create a mock geolocator wrapper
class MockGeolocatorWrapper extends Mock implements GeolocatorWrapper {}

void main() {
  test('GeolocatorLocationService uses injected geolocator', () async {
    // Create mock wrapper
    final mockGeolocator = MockGeolocatorWrapper();

    // Configure mock behavior - simulate location services enabled
    when(mockGeolocator.isLocationServiceEnabled())
        .thenAnswer((_) async => true);

    // Configure permission check
    when(mockGeolocator.checkPermission())
        .thenAnswer((_) async => geo.LocationPermission.whileInUse);

    // Configure position
    final mockPosition = geo.Position(
      latitude: 37.7749,
      longitude: -122.4194,
      timestamp: DateTime.now(),
      accuracy: 10.0,
      altitude: 0.0,
      heading: 0.0,
      speed: 0.0,
      speedAccuracy: 1.0,
      altitudeAccuracy: 1.0,
      headingAccuracy: 1.0,
    );

    when(mockGeolocator.getCurrentPosition(
      locationSettings: any(named: 'locationSettings'),
    )).thenAnswer((_) async => mockPosition);

    // Inject mock into service
    final service = GeolocatorLocationService(geolocator: mockGeolocator);

    // Use the service - it will use the mock geolocator
    final position = await service.getCurrentLocation();

    expect(position.latitude, 37.7749);
    expect(position.longitude, -122.4194);
  });

  test('GeolocatorLocationService handles location stream', () async {
    final mockGeolocator = MockGeolocatorWrapper();

    // Create a stream of positions
    final positionStream = Stream.fromIterable([
      geo.Position(
        latitude: 37.7749,
        longitude: -122.4194,
        timestamp: DateTime.now(),
        accuracy: 10.0,
        altitude: 0.0,
        heading: 0.0,
        speed: 0.0,
        speedAccuracy: 1.0,
        altitudeAccuracy: 1.0,
        headingAccuracy: 1.0,
      ),
      geo.Position(
        latitude: 37.7750,
        longitude: -122.4195,
        timestamp: DateTime.now(),
        accuracy: 10.0,
        altitude: 0.0,
        heading: 0.0,
        speed: 0.0,
        speedAccuracy: 1.0,
        altitudeAccuracy: 1.0,
        headingAccuracy: 1.0,
      ),
    ]);

    when(mockGeolocator.getPositionStream(
      locationSettings: any(named: 'locationSettings'),
    )).thenAnswer((_) => positionStream);

    final service = GeolocatorLocationService(geolocator: mockGeolocator);

    // Get location stream
    final stream = service.getLocationStream();
    final positions = await stream.take(2).toList();

    expect(positions.length, 2);
    expect(positions[0].latitude, 37.7749);
    expect(positions[1].latitude, 37.7750);
  });
}
```

## Production Usage (No Changes Required)

All existing production code continues to work without changes because the dependencies default to real implementations:

```dart
// Production code - uses real implementations by default
final identityService = NostrIdentityService(); // Uses real FlutterSecureStorage
final relayService = NostrRelayService(); // Uses real path_provider
final circleService = NostrCircleService(); // Uses real path_provider
final locationService = GeolocatorLocationService(); // Uses real Geolocator
```

## Key Benefits

1. **Backward Compatibility**: Existing production code works without changes
2. **Testability**: Tests can inject mocks for isolated unit testing
3. **Flexibility**: Can inject custom implementations for testing edge cases
4. **Type Safety**: All dependencies are strongly typed with abstract interfaces

## Limitations

Note that while these services now support dependency injection for their external dependencies (storage, file system, location), they still have hard dependencies on Rust FFI bridges:

- `NostrIdentityService` → `NostrIdentityManager` (Rust FFI)
- `NostrRelayService` → `RelayManagerFfi` (Rust FFI)
- `NostrCircleService` → `CircleManagerFfi` (Rust FFI)

For full integration testing of these services, use the integration tests in `integration_test/` which properly initialize the Rust bridge.

## Shared Abstractions

### DataDirectoryProvider

Both `NostrRelayService` and `NostrCircleService` share the `DataDirectoryProvider` abstraction, defined in `nostr_relay_service.dart`:

```dart
abstract class DataDirectoryProvider {
  Future<String> getDataDirectory();
}

class PathProviderDataDirectory implements DataDirectoryProvider {
  const PathProviderDataDirectory();

  @override
  Future<String> getDataDirectory() async {
    final appDir = await getApplicationDocumentsDirectory();
    return '${appDir.path}/haven';
  }
}
```

This allows both services to use the same mock in tests.

### GeolocatorWrapper

The `GeolocatorWrapper` abstraction wraps all static methods from the `geolocator` package, making them mockable:

```dart
abstract class GeolocatorWrapper {
  Future<bool> isLocationServiceEnabled();
  Future<LocationPermission> checkPermission();
  Future<LocationPermission> requestPermission();
  Future<Position> getCurrentPosition({required LocationSettings locationSettings});
  Future<Position?> getLastKnownPosition();
  Stream<Position> getPositionStream({required LocationSettings locationSettings});
}
```
