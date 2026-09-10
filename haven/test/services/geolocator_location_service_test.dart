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

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/services/geolocator_location_service.dart';
import 'package:haven/src/services/ios_location_source.dart';
import 'package:haven/src/services/location_service.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';

import '../mocks/fake_ios_location_source.dart';
import 'geolocator_location_service_test.mocks.dart';

/// Generate mocks for GeolocatorWrapper.
///
/// Run: dart run build_runner build --delete-conflicting-outputs
@GenerateMocks([GeolocatorWrapper])
void main() {
  // The end-to-end only-Best group drives the platform channels the iOS
  // session runs on, which needs a binding.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('GeolocatorLocationService', () {
    late MockGeolocatorWrapper mockGeolocator;
    late FakeIosLocationSource fakeIos;
    late GeolocatorLocationService service;

    /// The app-wide position the iOS session delivers, from the geolocator
    /// fixture every group already builds.
    Position asPosition(geo.Position p) => Position(
      latitude: p.latitude,
      longitude: p.longitude,
      timestamp: p.timestamp,
      accuracy: p.accuracy,
      altitude: p.altitude,
      speed: p.speed,
      heading: p.heading,
    );

    /// What the native session reports while the app is backgrounded — the
    /// read that decides whether the iOS cold-cache shortcut runs.
    const backgroundedStatus = IosLocationStreamStatus(
      running: true,
      allowsBackgroundLocationUpdates: true,
      showsBackgroundLocationIndicator: false,
      profile: IosLocationProfile.best,
      authorization: 'authorizedAlways',
      backgrounded: true,
    );

    setUp(() {
      mockGeolocator = MockGeolocatorWrapper();
      fakeIos = FakeIosLocationSource();
      // The access gate reads the granted ACCURACY on its granted arm.
      // Default every test to the undowngraded state so only the tests
      // that are about precision have to say anything about it; the
      // mock is `throwOnMissingStub`, so this is a default, never a
      // relaxation of an assertion.
      when(
        mockGeolocator.getLocationAccuracy(),
      ).thenAnswer((_) async => geo.LocationAccuracyStatus.precise);
      service = GeolocatorLocationService(
        geolocator: mockGeolocator,
        iosSource: fakeIos,
      );
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

    group('one permission prompt at a time', () {
      // The platform behaviour these tests are written against: Android's
      // `Activity.requestPermissions` refuses a second request while one is
      // pending — it logs "Can request only one set of permissions at a
      // time" and dispatches an EMPTY grant result, which geolocator drops
      // without invoking any callback. The second call has already
      // overwritten the plugin's single result-callback slot, so the real
      // answer goes to whichever caller asked LAST and the other Dart
      // future is never completed at all.
      //
      // Two callers racing is the normal case, not a corner: a publish tick
      // and a map read both run the access gate, and onboarding calls the
      // public `requestPermission()`.

      /// Every gate call reaches the prompt: services on, permission gone.
      void stubDeniedRead() {
        when(
          mockGeolocator.isLocationServiceEnabled(),
        ).thenAnswer((_) async => true);
        when(
          mockGeolocator.checkPermission(),
        ).thenAnswer((_) async => geo.LocationPermission.denied);
      }

      test('two concurrent gate calls raise one platform prompt', () async {
        stubDeniedRead();
        when(
          mockGeolocator.requestPermission(),
        ).thenAnswer((_) async => geo.LocationPermission.denied);

        final first = service.getCurrentLocation();
        final second = service.getCurrentLocation();

        await expectLater(first, throwsA(isA<LocationServiceException>()));
        await expectLater(second, throwsA(isA<LocationServiceException>()));

        verify(mockGeolocator.requestPermission()).called(1);
      });

      test(
        'the caller that did not get the answer is not left hanging',
        () async {
          stubDeniedRead();

          // Faithful model of the plugin: one callback slot, so only the
          // caller that registered LAST is ever answered.
          final pending = <Completer<geo.LocationPermission>>[];
          when(mockGeolocator.requestPermission()).thenAnswer((_) {
            final completer = Completer<geo.LocationPermission>();
            pending.add(completer);
            return completer.future;
          });

          var gateSettled = false;
          var promptSettled = false;
          unawaited(
            service.getCurrentLocation().then(
              (_) => gateSettled = true,
              onError: (Object _) => gateSettled = true,
            ),
          );
          unawaited(
            service.requestPermission().then(
              (_) => promptSettled = true,
              onError: (Object _) => promptSettled = true,
            ),
          );
          await pumpEventQueue();

          // The user-fixed denial the OS answers with, delivered to the
          // last registrant exactly as the plugin delivers it.
          pending.last.complete(geo.LocationPermission.denied);
          await pumpEventQueue();

          expect(
            gateSettled,
            isTrue,
            reason: 'the access gate never finished — its prompt was '
                'cancelled by the second request and its future can now '
                'never complete, wedging whichever publish cycle or map '
                'read is awaiting it',
          );
          expect(
            promptSettled,
            isTrue,
            reason: 'the onboarding prompt never finished',
          );
          expect(
            pending,
            hasLength(1),
            reason: 'a second simultaneous platform request is what strands '
                'a caller — the two callers must share one request',
          );
        },
      );
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

    /// The two Android platform registrations the ONE plugin boundary can be
    /// asked for.
    ///
    /// They are two USE CASES on the same stream API, never two streams: the
    /// map isolate's live 1 m / 1 s registration, and the foreground
    /// service's single long-interval one. Each isolate owns its own service
    /// instance and its own plugin subscription, and the two are exclusive by
    /// lifecycle — the UI releases at pause, before the FGS registers.
    group('Android stream profiles', () {
      final fix = geo.Position(
        latitude: 51.5,
        longitude: -0.12,
        timestamp: DateTime(2026, 9, 3, 12),
        accuracy: 5,
        altitude: 0,
        altitudeAccuracy: 1,
        heading: 0,
        headingAccuracy: 1,
        speed: 0,
        speedAccuracy: 1,
      );

      GeolocatorLocationService serviceFor({bool isIOS = false}) =>
          GeolocatorLocationService(
            geolocator: mockGeolocator,
            isIOS: isIOS,
            iosSource: fakeIos,
          );

      setUp(() {
        when(
          mockGeolocator.getPositionStream(
            locationSettings: anyNamed('locationSettings'),
          ),
        ).thenAnswer((_) {
          // Open, never finite: a closed stream is an access loss to this
          // service, which would clear the cache the later assertions read.
          final controller = StreamController<geo.Position>()..add(fix);
          addTearDown(controller.close);
          return controller.stream;
        });
      });

      List<geo.LocationSettings> capturedSettings() => verify(
        mockGeolocator.getPositionStream(
          locationSettings: captureAnyNamed('locationSettings'),
        ),
      ).captured.cast<geo.LocationSettings>();

      test(
        'the background-service profile is one long-interval LocationManager '
        'request with no distance filter and NO timeLimit',
        () {
          serviceFor()
              .getLocationStream(
                profile: const AndroidStreamProfile.backgroundService(
                  interval: Duration(seconds: 97),
                ),
              )
              .listen((_) {});

          final settings = capturedSettings().single;
          expect(settings, isA<geo.AndroidSettings>());
          final android = settings as geo.AndroidSettings;
          expect(
            android.intervalDuration,
            const Duration(seconds: 97),
            reason: 'the interval the cycle computed is what reaches '
                'LocationRequest.intervalMillis — the whole GNSS duty cycle',
          );
          expect(
            android.distanceFilter,
            0,
            reason: 'a metre-scale filter suppresses the very fix the cycle '
                'is waiting for while the device sits still, and the publish '
                'is due on TIME, not on displacement',
          );
          expect(
            android.forceLocationManager,
            isTrue,
            reason: 'the platform LocationManager is what duty-cycles GNSS '
                'per the requested interval (and keeps the F-Droid build '
                'free of Play Services)',
          );
          expect(
            android.timeLimit,
            isNull,
            reason: 'timeLimit on a STREAM is an inter-event timeout that '
                'CLOSES the stream, which this service maps to an access '
                'loss and a cleared cache — a silent provider is the '
                "watchdog's job, not a self-inflicted revocation",
          );
        },
      );

      test(
        'the foreground profile is the map stream, unchanged, and is what a '
        'caller that names no profile gets',
        () {
          // Two instances: one service owns one outer stream at a time, and
          // the point is that the DEFAULT and the explicitly-named
          // foreground profile are the same registration.
          serviceFor().getLocationStream().listen((_) {});
          serviceFor()
              .getLocationStream(
                // Naming the default IS the assertion here.
                // ignore: avoid_redundant_argument_values
                profile: const AndroidStreamProfile.foreground(),
              )
              .listen((_) {});

          final captured = capturedSettings();
          expect(captured, hasLength(2));
          for (final settings in captured) {
            final android = settings as geo.AndroidSettings;
            expect(android.distanceFilter, 1);
            expect(android.intervalDuration, const Duration(seconds: 1));
            expect(android.forceLocationManager, isTrue);
          }
        },
      );

      test(
        'each subscription carries its own interval, so a re-registration '
        'moves the cadence',
        () async {
          final service = serviceFor();
          final first = service
              .getLocationStream(
                profile: const AndroidStreamProfile.backgroundService(
                  interval: Duration(seconds: 62),
                ),
              )
              .listen((_) {});
          await first.cancel();
          service
              .getLocationStream(
                profile: const AndroidStreamProfile.backgroundService(
                  interval: Duration(seconds: 158),
                ),
              )
              .listen((_) {});

          expect(
            capturedSettings()
                .map((s) => (s as geo.AndroidSettings).intervalDuration),
            [const Duration(seconds: 62), const Duration(seconds: 158)],
            reason: 'the foreground service re-registers to the next due on '
                'every cycle; a profile that stuck at the first value would '
                'pin the cadence for the life of the service',
          );
        },
      );

      test('a resumed subscription keeps the profile it was created with', () {
        serviceFor()
          ..getLocationStream(
            profile: const AndroidStreamProfile.backgroundService(
              interval: Duration(seconds: 120),
            ),
          ).listen((_) {})
          ..suspendStream()
          ..resumeStream();

        expect(
          capturedSettings()
              .map((s) => (s as geo.AndroidSettings).intervalDuration),
          [const Duration(seconds: 120), const Duration(seconds: 120)],
          reason: 'a restart that silently reverted to the foreground '
              'profile would put a 1 Hz GNSS request behind a paused app',
        );
      });

      test('iOS ignores the profile entirely', () {
        serviceFor(isIOS: true)
            .getLocationStream(
              profile: const AndroidStreamProfile.backgroundService(
                interval: Duration(seconds: 97),
              ),
            )
            .listen((_) {});

        // The iOS session is chosen by the background-sharing intent and
        // nothing else; its shape lives in Swift. An Android cadence that
        // leaked across would either filter out fixes or, as a timeLimit,
        // close the session that keeps the process alive — so the profile has
        // to reach no iOS decision at all, and the way to be sure of that is
        // that nothing Android-shaped is even built.
        verifyNever(
          mockGeolocator.getPositionStream(
            locationSettings: anyNamed('locationSettings'),
          ),
        );
        expect(fakeIos.listenArguments, [false]);
      });
    });

    /// The service-level lifecycle gate.
    ///
    /// A watched-provider write cancels the old subscription synchronously
    /// but defers the REBUILD to a frame, and frames are off while the app
    /// is paused — so releasing the platform subscription at pause time
    /// cannot ride a Riverpod rebuild.
    /// [GeolocatorLocationService.suspendStream] and
    /// [GeolocatorLocationService.resumeStream] are the direct, synchronous
    /// calls `map_shell` makes instead.
    group('stream lifecycle gate', () {
      // Timestamped at delivery: the cache is served only while fresher
      // than kStreamPositionMaxAge, so a fixed date would make the
      // suspend-keeps-the-cache assertion pass for the wrong reason.
      geo.Position freshFix() => geo.Position(
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

      /// Every plugin stream handed out during a test, in creation order,
      /// each counting its own cancellation.
      late List<StreamController<geo.Position>> inners;
      late int innerCancels;

      /// Android by default. The suspend/resume machinery is one code path
      /// for both platforms — it swaps whatever [_listenInner] produced — and
      /// this group counts PLUGIN subscriptions, which only Android has. The
      /// iOS route's own suspend/resume (it must re-listen with the same
      /// background-sharing intent) is pinned in the `iOS stream route` group.
      GeolocatorLocationService serviceFor({bool isIOS = false}) =>
          GeolocatorLocationService(
            geolocator: mockGeolocator,
            isIOS: isIOS,
            iosSource: fakeIos,
          );

      setUp(() {
        inners = [];
        innerCancels = 0;
        when(
          mockGeolocator.getPositionStream(
            locationSettings: anyNamed('locationSettings'),
          ),
        ).thenAnswer((_) {
          // An OPEN controller per call: a real platform stream is
          // unbounded, and the counters are what distinguish "the inner was
          // released" from "the outer was merely rebuilt".
          final controller = StreamController<geo.Position>(
            onCancel: () => innerCancels++,
          );
          inners.add(controller);
          addTearDown(controller.close);
          return controller.stream;
        });
      });

      test(
        'suspendStream cancels the plugin subscription synchronously and '
        'keeps the cached fix',
        () async {
          final service = serviceFor();
          final sub = service.getLocationStream().listen((_) {});
          addTearDown(sub.cancel);
          inners.single.add(freshFix());
          await Future<void>.delayed(Duration.zero);

          service.suspendStream();

          // No pump, no microtask: the release must be complete by the time
          // `_onPaused` returns, because no frame will run to finish it.
          expect(
            innerCancels,
            1,
            reason: 'the platform subscription outlived the pause — on '
                'Android that is the 1 Hz request that never goes away',
          );

          // Cancel is not close: neither the done nor the error handler
          // fired, so the consent-bounded cache survives the pause.
          when(
            mockGeolocator.isLocationServiceEnabled(),
          ).thenAnswer((_) async => true);
          when(
            mockGeolocator.checkPermission(),
          ).thenAnswer((_) async => geo.LocationPermission.whileInUse);
          // The Android cache read is corroborated by a live last-known probe
          // (the only check that can see an app-op denial).
          when(
            mockGeolocator.getLastKnownPosition(),
          ).thenAnswer((_) async => freshFix());
          final served = await service.getCurrentLocation();
          expect(served.latitude, 51.5);
          verifyNever(
            mockGeolocator.getCurrentPosition(
              locationSettings: anyNamed('locationSettings'),
            ),
          );
        },
      );

      test('resumeStream re-subscribes with the current settings exactly once',
          () async {
        final service = serviceFor();
        final sub = service
            .getLocationStream(
              profile: const AndroidStreamProfile.backgroundService(
                interval: Duration(seconds: 97),
              ),
            )
            .listen((_) {});
        addTearDown(sub.cancel);
        // Resumed twice: the second call must find a live inner and do
        // nothing, or every resume would restart the platform session.
        service
          ..suspendStream()
          ..resumeStream()
          ..resumeStream();

        expect(inners, hasLength(2));
        final settings = verify(
          mockGeolocator.getPositionStream(
            locationSettings: captureAnyNamed('locationSettings'),
          ),
        ).captured.cast<geo.LocationSettings>();
        expect(
          (settings.last as geo.AndroidSettings).intervalDuration,
          const Duration(seconds: 97),
          reason: 'the restart must carry the registration the outer was '
              'created with, not the plugin default',
        );
      });

      test('suspend and resume are no-ops when the outer has no listener', () {
        serviceFor()
          ..getLocationStream()
          ..suspendStream()
          ..resumeStream();

        expect(innerCancels, 0);
        expect(inners, hasLength(1));
      });

      test(
        'the outer stream survives a suspend/resume pair without completing '
        'or erroring',
        () async {
          final service = serviceFor();
          final seen = <Position>[];
          var done = false;
          final errors = <Object>[];
          final sub = service.getLocationStream().listen(
            seen.add,
            onError: errors.add,
            onDone: () => done = true,
          );
          addTearDown(sub.cancel);

          service
            ..suspendStream()
            ..resumeStream();
          inners.last.add(freshFix());
          await Future<void>.delayed(Duration.zero);

          expect(seen, hasLength(1));
          expect(errors, isEmpty);
          expect(
            done,
            isFalse,
            reason: 'a completed outer is surfaced as an outage by the '
                'access watchdog — a pause must not look like one',
          );
        },
      );

      test('a toggle rebuild re-listens without error and cancels the '
          'previous inner', () async {
        final service = serviceFor();
        // Exactly what a `locationStreamProvider` rebuild does: Riverpod
        // cancels the outer, then the deferred rebuild asks for a new one.
        final first = service.getLocationStream().listen((_) {});
        await first.cancel();

        final seen = <Position>[];
        final second = service
            .getLocationStream(backgroundSharingEnabled: true)
            .listen(seen.add);
        addTearDown(second.cancel);
        inners.last.add(freshFix());
        await Future<void>.delayed(Duration.zero);

        expect(
          inners,
          hasLength(2),
          reason: 'one outer controller per call — a shared one would throw '
              'StateError on the second listen',
        );
        expect(innerCancels, 1);
        expect(seen, hasLength(1));
      });

      test('resumeStream replaces an inner that errored, without a suspend',
          () async {
        final service = serviceFor();
        final errors = <Object>[];
        final seen = <Position>[];
        final sub = service.getLocationStream().listen(
          seen.add,
          onError: errors.add,
        );
        addTearDown(sub.cancel);
        inners.single.addError(Exception('provider disabled'));
        await Future<void>.delayed(Duration.zero);

        // The access watchdog's recovery `invalidate` is skipped while
        // suspended, so the resume call is the only thing that can revive a
        // dead platform subscription.
        service.resumeStream();
        inners.last.add(freshFix());
        await Future<void>.delayed(Duration.zero);

        expect(errors, hasLength(1));
        expect(inners, hasLength(2));
        expect(seen, hasLength(1));
      });

      test('resumeStream leaves a healthy inner alone', () {
        // The iOS background-sharing branch never suspends: that session IS
        // the keep-alive. `_onResumed` calls resumeStream() unconditionally,
        // so a restart here would tear down the one object the 2026-08-20
        // field failure was fixed by.
        final service = serviceFor();
        final sub = service
            .getLocationStream(backgroundSharingEnabled: true)
            .listen((_) {});
        addTearDown(sub.cancel);

        service.resumeStream();

        expect(inners, hasLength(1));
        expect(innerCancels, 0);
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
          GeolocatorLocationService(
            geolocator: mockGeolocator,
            isIOS: isIOS,
            iosSource: fakeIos,
          );

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
        'both platforms take the one-shot timeLimit from '
        'kOneShotLocationTimeout',
        () async {
          // NOT a restatement of the two 30 s literals above. Those pass just
          // as well against a private constant re-added to this service,
          // which is how this timeout used to be written — and
          // `b5_permission_revocation_test.dart` derives its app-op
          // observation windows from kOneShotLocationTimeout, because an
          // Android app-op denial raises no error and a refused one-shot
          // surfaces only when this timeLimit expires. A window sized from a
          // value the service no longer uses cannot see the refusal it is
          // waiting for.
          stubReadyForOneShot();

          await serviceFor(isIOS: true).getCurrentLocation();
          await serviceFor(isIOS: false).getCurrentLocation();

          final captured = verify(
            mockGeolocator.getCurrentPosition(
              locationSettings: captureAnyNamed('locationSettings'),
            ),
          ).captured.cast<geo.LocationSettings>();

          expect(captured, hasLength(2));
          expect(
            captured.map((s) => s.timeLimit),
            everyElement(kOneShotLocationTimeout),
          );
        },
      );

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

      test(
        'every arm inherits the plugin default accuracy, which is best',
        () async {
          // ONE tripwire, two failure modes, both named.
          //
          // No geolocator arm of the service names an accuracy, so every one
          // of the four inherits `LocationSettings.accuracy`. Asserting `best`
          // four times over therefore restates a geolocator DEFAULT four
          // times and reads like four Haven decisions. The dependency
          // contract is stated once against the plugin's own constructor — a
          // bump that lowers it is a
          // battery/precision change Haven never made, and it lands here.
          //
          // On Android the inherited `best` is what geolocator maps to
          // `LocationRequest.QUALITY_HIGH_ACCURACY`, which is the quality the
          // foreground service's long-interval registration needs just as
          // much as the map's: the interval decides how OFTEN the receiver
          // runs, the quality decides what it runs.
          //
          // Then the arms are compared to that same default rather than to a
          // literal, which is the Haven-side half: a named `accuracy:`
          // argument on any arm — the one unremarkable line that would quietly
          // downgrade the fix a peer receives — makes it differ.
          expect(
            const geo.LocationSettings().accuracy,
            geo.LocationAccuracy.best,
            reason: 'DEPENDENCY DRIFT: geolocator lowered the default accuracy '
                'every Haven location request inherits. Nothing in this repo '
                'changed; decide deliberately whether to name `best` at each '
                'call site or accept the coarser fix',
          );

          stubStream();
          stubReadyForOneShot();

          // The two iOS STREAM arms are gone with the plugin path: that
          // session names its accuracy natively, in exactly two values, and
          // the guard pins those. Both one-shots stay — they are still
          // geolocator's on both platforms.
          serviceFor(isIOS: false).getLocationStream().listen((_) {});
          serviceFor(isIOS: false)
              .getLocationStream(
                profile: const AndroidStreamProfile.backgroundService(
                  interval: Duration(seconds: 120),
                ),
              )
              .listen((_) {});
          await serviceFor(isIOS: true).getCurrentLocation();
          await serviceFor(isIOS: false).getCurrentLocation();

          final streams = verify(
            mockGeolocator.getPositionStream(
              locationSettings: captureAnyNamed('locationSettings'),
            ),
          ).captured.cast<geo.LocationSettings>();
          final oneShots = verify(
            mockGeolocator.getCurrentPosition(
              locationSettings: captureAnyNamed('locationSettings'),
            ),
          ).captured.cast<geo.LocationSettings>();

          // Positional, so a dropped call is a length failure rather than a
          // silently unchecked arm.
          expect(streams, hasLength(2));
          expect(oneShots, hasLength(2));
          final arms = <String, geo.LocationSettings>{
            'the Android foreground stream': streams[0],
            'the Android background-service stream': streams[1],
            'the iOS one-shot': oneShots[0],
            'the Android one-shot': oneShots[1],
          };

          for (final arm in arms.entries) {
            expect(
              arm.value.accuracy,
              const geo.LocationSettings().accuracy,
              reason: '${arm.key} asks the OS for something other than the '
                  'default every other arm inherits. A deliberate accuracy '
                  'profile must be stated arm by arm, never introduced on one',
            );
          }
        },
      );
    });

    /// The iOS stream route: Haven's own CoreLocation session, not the plugin.
    ///
    /// Three promises live here. The stream comes from the native owner and
    /// carries the user's background-sharing intent verbatim; the coordinate
    /// the publish path serves is the native owner's Best-profile fix and
    /// nothing else; and every clear takes both copies of it.
    group('iOS stream route', () {
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

      GeolocatorLocationService serviceFor({bool isIOS = true}) =>
          GeolocatorLocationService(
            geolocator: mockGeolocator,
            isIOS: isIOS,
            iosSource: fakeIos,
          );

      void stubAccessGranted() {
        when(
          mockGeolocator.isLocationServiceEnabled(),
        ).thenAnswer((_) async => true);
        when(
          mockGeolocator.checkPermission(),
        ).thenAnswer((_) async => geo.LocationPermission.whileInUse);
      }

      /// Warms the Dart cache from the native session and leaves it warm
      /// (cancel raises no done event, so nothing clears it).
      Future<void> seedCache(
        GeolocatorLocationService service,
        Position position,
      ) async {
        final sub = service.getLocationStream().listen((_) {});
        fakeIos.session.add(position);
        await Future<void>.delayed(Duration.zero);
        await sub.cancel();
      }

      for (final enabled in [true, false]) {
        test(
          'the stream comes from the native session, carrying '
          'backgroundSharingEnabled: $enabled, and never from the plugin',
          () {
            serviceFor()
                .getLocationStream(backgroundSharingEnabled: enabled)
                .listen((_) {});

            expect(fakeIos.listenArguments, [enabled]);
            verifyNever(
              mockGeolocator.getPositionStream(
                locationSettings: anyNamed('locationSettings'),
              ),
            );
          },
        );
      }

      test('the default asks for no background capability', () {
        serviceFor().getLocationStream().listen((_) {});

        expect(
          fakeIos.listenArguments,
          [false],
          reason: 'a session that took the parameter default as ON would keep '
              'an opt-out user executable in the background',
        );
      });

      test('a resumed iOS session re-listens with the intent the outer was '
          'created with', () {
        final service = serviceFor();
        final sub = service
            .getLocationStream(backgroundSharingEnabled: true)
            .listen((_) {});
        addTearDown(sub.cancel);

        service
          ..suspendStream()
          ..resumeStream();

        expect(
          fakeIos.listenArguments,
          [true, true],
          reason: 'a restart that reverted to the default would drop the '
              'background capability the toggle asked for',
        );
      });

      test('the foreground hint reaches the native session', () {
        serviceFor()
          ..foregroundActive = false
          ..foregroundActive = true;

        expect(
          fakeIos.foregroundCalls,
          [false, true],
          reason: 'the session cannot coarsen its accuracy without knowing '
              'the app went away, nor return to Best without knowing it came '
              'back',
        );
      });

      test('clearCachedPosition clears the native last-Best fix too', () {
        final service = serviceFor();
        fakeIos.nativeLastBestFix = asPosition(positionAt(DateTime.now()));

        service.clearCachedPosition();

        expect(fakeIos.clearCalls, 1);
        expect(fakeIos.nativeLastBestFix, isNull);
      });

      test('an observed access loss clears the native last-Best fix too',
          () async {
        // Logout and opt-out go through clearCachedPosition; a REVOCATION
        // goes through the gate, and the native copy is a full-precision
        // coordinate just the same.
        final service = serviceFor();
        fakeIos.nativeLastBestFix = asPosition(positionAt(DateTime.now()));
        when(
          mockGeolocator.checkPermission(),
        ).thenAnswer((_) async => geo.LocationPermission.deniedForever);

        await service.checkPermission();

        expect(fakeIos.nativeLastBestFix, isNull);
      });

      test('a stale native last-Best fix is not served as last-known',
          () async {
        // The native cache and the Dart cache hold the SAME coordinate — every
        // Best fix is teed into both on one delivery — so an unbounded native
        // read hands back, one line later, exactly the fix the cache read
        // above rejected as too old to publish.
        final service = serviceFor();
        stubAccessGranted();
        fakeIos
          ..statusValue = backgroundedStatus
          ..nativeLastBestFix = asPosition(
            positionAt(
              DateTime.now().subtract(
                kStreamPositionMaxAge + const Duration(seconds: 1),
              ),
            ),
          );

        await expectLater(
          service.getCurrentLocation(),
          throwsA(isA<LocationServiceException>()),
        );
      });

      test('a native last-Best fix inside the freshness bound is served',
          () async {
        // The other direction: the bound is a freshness rule, not a ban. A
        // backgrounded publish tick must still be answered from the native
        // cache without a platform request.
        final service = serviceFor();
        stubAccessGranted();
        fakeIos
          ..statusValue = backgroundedStatus
          ..nativeLastBestFix = asPosition(
            positionAt(
              DateTime.now().subtract(
                kStreamPositionMaxAge - const Duration(seconds: 1),
              ),
            ),
          );

        expect((await service.getCurrentLocation()).latitude, 51.5);
        verifyNever(
          mockGeolocator.getCurrentPosition(
            locationSettings: anyNamed('locationSettings'),
          ),
        );
      });

      test('a CONFIRMED native last-Best fix is served past its own age',
          () async {
        // The bound is the file's ONE freshness rule, confirmation included:
        // while the coarse tier is vouching for the anchor no publishable fix
        // arrives at all, so a raw timestamp bound here would send a
        // motionless backgrounded user to a one-shot that cannot complete.
        final service = serviceFor();
        stubAccessGranted();
        fakeIos
          ..statusValue = backgroundedStatus
          ..confirmedAt = DateTime.now()
          ..nativeLastBestFix = asPosition(
            positionAt(
              DateTime.now().subtract(
                kStreamPositionMaxAge + const Duration(seconds: 30),
              ),
            ),
          );

        expect((await service.getCurrentLocation()).latitude, 51.5);
      });

      test('a confirming fix keeps the cached Best fix servable past its own '
          'age', () async {
        // The point of the stationary profile: while the coarse tier is
        // confirming the anchor no publishable fix arrives at all, so a
        // freshness window measured on the fix alone would expire and send a
        // motionless user to a GPS one-shot every 168 s.
        final service = serviceFor();
        final taken = DateTime.now().subtract(
          kStreamPositionMaxAge + const Duration(seconds: 30),
        );
        await seedCache(service, asPosition(positionAt(taken)));
        fakeIos.confirmedAt = DateTime.now().subtract(
          const Duration(seconds: 10),
        );
        stubAccessGranted();

        final result = await service.getCurrentLocation();

        expect(result.timestamp, taken);
        verifyNever(
          mockGeolocator.getCurrentPosition(
            locationSettings: anyNamed('locationSettings'),
          ),
        );
      });

      test('with no confirmation the cached Best fix still ages out at '
          'kStreamPositionMaxAge', () async {
        final service = serviceFor();
        await seedCache(
          service,
          asPosition(
            positionAt(
              DateTime.now().subtract(
                kStreamPositionMaxAge + const Duration(seconds: 1),
              ),
            ),
          ),
        );
        stubAccessGranted();
        when(
          mockGeolocator.getCurrentPosition(
            locationSettings: anyNamed('locationSettings'),
          ),
        ).thenAnswer((_) async => positionAt(DateTime.now()));

        await service.getCurrentLocation();

        verify(
          mockGeolocator.getCurrentPosition(
            locationSettings: anyNamed('locationSettings'),
          ),
        ).called(1);
      });

      test('a confirmation older than the window does not resurrect the cache',
          () async {
        final service = serviceFor();
        await seedCache(service, asPosition(positionAt(DateTime.now())));
        fakeIos.confirmedAt = DateTime.now().subtract(
          kStreamPositionMaxAge + const Duration(seconds: 1),
        );
        stubAccessGranted();
        when(
          mockGeolocator.getCurrentPosition(
            locationSettings: anyNamed('locationSettings'),
          ),
        ).thenAnswer((_) async => positionAt(DateTime.now()));

        await service.getCurrentLocation();

        verify(
          mockGeolocator.getCurrentPosition(
            locationSettings: anyNamed('locationSettings'),
          ),
        ).called(1);
      });

      test('no confirmation chain serves a fix older than '
          'kStationaryAnchorMaxAge', () async {
        // The ceiling the confirmation chain would otherwise remove. The wire
        // timestamp of a published location is the instant of the PUBLISH, so
        // a peer reads "just now" for whatever this serves; without the cap a
        // stationary device re-publishes the same anchor for as long as coarse
        // fixes keep vouching for it.
        final service = serviceFor();
        await seedCache(
          service,
          asPosition(
            positionAt(
              DateTime.now().subtract(
                kStationaryAnchorMaxAge + const Duration(seconds: 1),
              ),
            ),
          ),
        );
        fakeIos.confirmedAt = DateTime.now();
        stubAccessGranted();
        when(
          mockGeolocator.getCurrentPosition(
            locationSettings: anyNamed('locationSettings'),
          ),
        ).thenAnswer((_) async => positionAt(DateTime.now()));

        await service.getCurrentLocation();

        verify(
          mockGeolocator.getCurrentPosition(
            locationSettings: anyNamed('locationSettings'),
          ),
        ).called(1);
      });

      test('a confirmed fix just inside kStationaryAnchorMaxAge is still '
          'served', () async {
        // The other direction, and the reason the cap is minutes rather than
        // the freshness window: a confirmation still buys the anchor a life
        // well past its own timestamp, or the stationary tier would pay for a
        // GPS acquisition every 168 s to learn the device has not moved.
        final service = serviceFor();
        final taken = DateTime.now().subtract(
          kStationaryAnchorMaxAge - const Duration(seconds: 1),
        );
        await seedCache(service, asPosition(positionAt(taken)));
        fakeIos.confirmedAt = DateTime.now();
        stubAccessGranted();

        final result = await service.getCurrentLocation();

        expect(result.timestamp, taken);
        verifyNever(
          mockGeolocator.getCurrentPosition(
            locationSettings: anyNamed('locationSettings'),
          ),
        );
      });

      test('the cap reaches the native last-Best read too', () async {
        // The backgrounded read goes to the native copy of the SAME
        // coordinate, so a cap enforced only on the Dart cache would hand
        // back, one branch later, exactly the fix the cache read refused.
        final service = serviceFor();
        stubAccessGranted();
        fakeIos
          ..statusValue = backgroundedStatus
          ..confirmedAt = DateTime.now()
          ..nativeLastBestFix = asPosition(
            positionAt(
              DateTime.now().subtract(
                kStationaryAnchorMaxAge + const Duration(seconds: 1),
              ),
            ),
          );

        await expectLater(
          service.getCurrentLocation(),
          throwsA(isA<LocationServiceException>()),
        );
      });

      test('a live confirmation does not survive a revocation', () async {
        // The confirmation extends how long a coordinate may be SERVED, so a
        // revocation has to beat it: the cache goes, and the next call is a
        // fresh read under a re-granted permission — never the coordinate the
        // coarse tier was still busy vouching for.
        final service = serviceFor();
        await seedCache(
          service,
          asPosition(
            positionAt(
              DateTime.now().subtract(
                kStreamPositionMaxAge + const Duration(seconds: 30),
              ),
            ),
          ),
        );
        fakeIos.confirmedAt = DateTime.now();
        when(
          mockGeolocator.checkPermission(),
        ).thenAnswer((_) async => geo.LocationPermission.denied);
        await service.checkPermission();

        stubAccessGranted();
        when(
          mockGeolocator.getCurrentPosition(
            locationSettings: anyNamed('locationSettings'),
          ),
        ).thenAnswer((_) async => positionAt(DateTime.now()));
        await service.getCurrentLocation();

        verify(
          mockGeolocator.getCurrentPosition(
            locationSettings: anyNamed('locationSettings'),
          ),
        ).called(1);
      });

      test('Android is unaffected: nothing confirms, so the fix decides',
          () async {
        // The confirmed age is an iOS concept. If it leaked to Android, a
        // stale native reading would extend the Android freshness window past
        // what any fix supports.
        final service = serviceFor(isIOS: false);
        final controller = StreamController<geo.Position>();
        addTearDown(controller.close);
        when(
          mockGeolocator.getPositionStream(
            locationSettings: anyNamed('locationSettings'),
          ),
        ).thenAnswer((_) => controller.stream);
        final sub = service.getLocationStream().listen((_) {});
        controller.add(
          positionAt(
            DateTime.now().subtract(
              kStreamPositionMaxAge + const Duration(seconds: 1),
            ),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        await sub.cancel();
        fakeIos.confirmedAt = DateTime.now();
        stubAccessGranted();
        when(
          mockGeolocator.getCurrentPosition(
            locationSettings: anyNamed('locationSettings'),
          ),
        ).thenAnswer((_) async => positionAt(DateTime.now()));

        await service.getCurrentLocation();

        verify(
          mockGeolocator.getCurrentPosition(
            locationSettings: anyNamed('locationSettings'),
          ),
        ).called(1);
      });

      test('a backgrounded cold cache never starts the one-shot, even when '
          'the lifecycle hint says foreground', () async {
        // The FA:218-222 hole: a process launched INTO the background (SLC,
        // region, BGTask) builds this service before any lifecycle callback,
        // so the in-memory hint still reads foreground. The native lifecycle
        // is the only honest answer.
        //
        // BOTH caches are empty, which is the state a post-termination
        // relaunch is IN — the native cache does not survive termination and
        // no stream has run in this process. `INV-L-IOS-WAKES-RECEIVE-ONLY`
        // says such a process cannot publish; a branch that falls through to
        // the one-shot when it finds no cached fix made that a coincidence of
        // what happened to be in memory.
        final service = serviceFor()..foregroundActive = true;
        stubAccessGranted();
        fakeIos
          ..statusValue = backgroundedStatus
          ..nativeLastBestFix = null;

        await expectLater(
          service.getCurrentLocation(),
          throwsA(isA<LocationServiceException>()),
        );

        verifyNever(
          mockGeolocator.getCurrentPosition(
            locationSettings: anyNamed('locationSettings'),
          ),
        );
      });

      test('an unreadable native status counts as backgrounded', () async {
        // Fail closed: the shortcut exists to keep a doomed one-shot from
        // stalling a background publish for 30 s, and "I could not tell"
        // must not be read as "foreground".
        final service = serviceFor()..foregroundActive = true;
        stubAccessGranted();
        fakeIos
          ..statusValue = IosLocationStreamStatus.unknown
          ..nativeLastBestFix = asPosition(positionAt(DateTime.now()));

        await service.getCurrentLocation();

        verifyNever(
          mockGeolocator.getCurrentPosition(
            locationSettings: anyNamed('locationSettings'),
          ),
        );
      });

      test('the foreground path is untouched: a cold cache still runs the '
          'one-shot', () async {
        final service = serviceFor();
        stubAccessGranted();
        when(
          mockGeolocator.getCurrentPosition(
            locationSettings: anyNamed('locationSettings'),
          ),
        ).thenAnswer((_) async => positionAt(DateTime.now()));

        await service.getCurrentLocation();

        verify(
          mockGeolocator.getCurrentPosition(
            locationSettings: anyNamed('locationSettings'),
          ),
        ).called(1);
      });
    });

    /// Only-Best, end to end across the channel.
    ///
    /// The other only-Best tests hold one end of the rope each. This one runs
    /// the REAL [MethodChannelIosLocationSource] against a fake native side,
    /// so the assertion covers the whole path a coarse fix would have to
    /// travel to become a published coordinate: native event → source →
    /// service cache → emitted stream (the motion trigger's sole input).
    group('iOS only-Best, end to end', () {
      const eventChannelName = 'haven.app/ios_location_stream/events';
      const codec = StandardMethodCodec();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

      tearDown(() {
        messenger
          ..setMockMethodCallHandler(
            MethodChannelIosLocationSource.methodChannel,
            null,
          )
          ..setMockMethodCallHandler(
            const MethodChannel(eventChannelName),
            null,
          );
      });

      Map<Object?, Object?> wireFix({
        required DateTime timestamp,
        required double latitude,
        required String profile,
        double accuracy = 5,
      }) => <Object?, Object?>{
        'lat': latitude,
        'lon': -0.12,
        'tsMs': timestamp.millisecondsSinceEpoch,
        'acc': accuracy,
        'alt': 0.0,
        'speed': 0.0,
        'course': 0.0,
        'profile': profile,
      };

      test('a HundredMeters fix reaches neither the stream nor the publish '
          'input', () async {
        messenger
          ..setMockMethodCallHandler(
            MethodChannelIosLocationSource.methodChannel,
            (call) async => null,
          )
          ..setMockMethodCallHandler(
            const MethodChannel(eventChannelName),
            (call) async => null,
          );
        final service = GeolocatorLocationService(
          geolocator: mockGeolocator,
          isIOS: true,
          iosSource: MethodChannelIosLocationSource(),
        );
        final seen = <Position>[];
        final sub = service
            .getLocationStream(backgroundSharingEnabled: true)
            .listen(seen.add);
        addTearDown(sub.cancel);
        await pumpEventQueue();

        final now = DateTime.now();
        void emit(Map<Object?, Object?> fix) => unawaited(
          messenger.handlePlatformMessage(
            eventChannelName,
            codec.encodeSuccessEnvelope(fix),
            null,
          ),
        );
        emit(wireFix(timestamp: now, latitude: 51.5, profile: 'best'));
        emit(
          wireFix(
            timestamp: now.add(const Duration(seconds: 1)),
            latitude: 60,
            accuracy: 80,
            profile: 'hundredMeters',
          ),
        );
        await pumpEventQueue();

        expect(
          seen.map((p) => p.latitude),
          [51.5],
          reason: 'the motion trigger reads this stream and nothing else; a '
              'coarse fix on it is a coarse fix published',
        );

        when(
          mockGeolocator.isLocationServiceEnabled(),
        ).thenAnswer((_) async => true);
        when(
          mockGeolocator.checkPermission(),
        ).thenAnswer((_) async => geo.LocationPermission.whileInUse);
        final served = await service.getCurrentLocation();

        expect(
          served.latitude,
          51.5,
          reason: 'the publish input must still be the Best-profile fix',
        );
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
          GeolocatorLocationService(
            geolocator: mockGeolocator,
            isIOS: isIOS,
            iosSource: fakeIos,
          );

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
      /// `Stream.fromIterable`: a real position stream is unbounded, and the
      /// service treats a CLOSED stream as "no further fix will arrive" and
      /// drops the cache. Cancelling the subscription (what a settings rebuild
      /// does) raises no done event, so the warm fix survives — which is the
      /// state these tests are about.
      ///
      /// Fed through whichever source the service actually subscribed to:
      /// Haven's own session on iOS, the plugin's on Android.
      Future<void> seedCache(
        GeolocatorLocationService service,
        geo.Position position,
      ) async {
        final plugin = StreamController<geo.Position>();
        when(
          mockGeolocator.getPositionStream(
            locationSettings: anyNamed('locationSettings'),
          ),
        ).thenAnswer((_) => plugin.stream);
        final sub = service.getLocationStream().listen((_) {});
        if (fakeIos.sessions.isEmpty) {
          plugin.add(position);
        } else {
          fakeIos.session.add(asPosition(position));
        }
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
        final drained = expectLater(
          service.getLocationStream().drain<void>(),
          throwsA(isA<Exception>()),
        );
        fakeIos.session.addError(Exception('gps failure'));
        await fakeIos.session.close();
        await drained;
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
        'backgrounded on iOS with no cache: uses the native last-Best fix and '
        'never attempts the one-shot',
        () async {
          final service = serviceFor(isIOS: true);
          stubAccessGranted();
          fakeIos
            ..statusValue = backgroundedStatus
            ..nativeLastBestFix = asPosition(positionAt(DateTime.now()));

          final result = await service.getCurrentLocation();

          expect(result.latitude, 51.5);
          verifyNever(
            mockGeolocator.getCurrentPosition(
              locationSettings: anyNamed('locationSettings'),
            ),
          );
          verifyNever(mockGeolocator.getLastKnownPosition());
        },
      );

      test(
        'backgrounded on iOS with no last-known fix: refuses instead of '
        'falling through to the one-shot',
        () async {
          // This used to pin the fall-through as "a final attempt". It is the
          // opposite: on a post-termination SLC/region/BGTask relaunch both
          // caches are empty by design, so "no last-known fix" is not an edge
          // case — it is the state the relaunched process is in, and the
          // one-shot the fall-through reached is a publish input
          // INV-L-IOS-WAKES-RECEIVE-ONLY says cannot exist there. It also
          // could never have delivered: its CLLocationManager has no
          // background capability, so the "final attempt" was a 30 s stall
          // ending in the same exception.
          final service = serviceFor(isIOS: true);
          fakeIos.statusValue = backgroundedStatus;
          stubOneShot(positionAt(DateTime.now()));

          await expectLater(
            service.getCurrentLocation(),
            throwsA(isA<LocationServiceException>()),
          );

          verifyNever(
            mockGeolocator.getCurrentPosition(
              locationSettings: anyNamed('locationSettings'),
            ),
          );
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

    /// The predicate the Android foreground service asks BEFORE deciding it
    /// needs a fresh acquisition.
    ///
    /// It answers one question — is the teed stream fix younger than
    /// [kStreamPositionMaxAge], measured on the GPS fix time — and it
    /// answers it without touching the platform and without producing a
    /// coordinate. It is a FRESHNESS predicate and never a consent one: what
    /// may be served is still decided, per call, by the access gate.
    group('hasFreshStreamFix', () {
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

      GeolocatorLocationService serviceFor() =>
          GeolocatorLocationService(
            geolocator: mockGeolocator,
            isIOS: false,
            iosSource: fakeIos,
          );

      /// Delivers [position] through the unified stream so the tee fills the
      /// cache, and leaves it warm (an open controller: a CLOSED stream is
      /// an access loss, which would clear what these tests read).
      Future<void> deliver(
        GeolocatorLocationService service,
        geo.Position position,
      ) async {
        final controller = StreamController<geo.Position>();
        addTearDown(controller.close);
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

      test('is false before any fix has been delivered', () {
        expect(serviceFor().hasFreshStreamFix(), isFalse);
      });

      test(
        'is true at the freshness bound and false one millisecond past it',
        () async {
          final service = serviceFor();
          final fixTime = DateTime.utc(2026, 9, 3, 12);
          await deliver(service, positionAt(fixTime));

          expect(
            service.hasFreshStreamFix(
              now: () => fixTime.add(kStreamPositionMaxAge),
            ),
            isTrue,
          );
          expect(
            service.hasFreshStreamFix(
              now: () => fixTime.add(
                kStreamPositionMaxAge + const Duration(milliseconds: 1),
              ),
            ),
            isFalse,
            reason: 'a predicate that ignored the age bound would tell the '
                'cycle it already has what it needs and publish a coordinate '
                'the user left behind',
          );
        },
      );

      test('measures the GPS fix time, not the moment of delivery', () async {
        final service = serviceFor();
        final now = DateTime.utc(2026, 9, 3, 12);
        // A chipset can hand over a fix it took minutes ago (a queued or
        // replayed delivery). Stamping freshness at DELIVERY would call this
        // fresh; the fix itself says otherwise, and the fix is the thing
        // being published.
        await deliver(
          service,
          positionAt(now.subtract(kStreamPositionMaxAge * 2)),
        );

        expect(service.hasFreshStreamFix(now: () => now), isFalse);
      });

      test('answers without a single platform read', () async {
        final service = serviceFor();
        await deliver(service, positionAt(DateTime.now()));
        clearInteractions(mockGeolocator);

        expect(service.hasFreshStreamFix(), isTrue);

        // Not decoration: a predicate that reached for the platform would be
        // a second, ungated position path — and on iOS a permission read
        // from the background can hang the caller forever.
        verifyZeroInteractions(mockGeolocator);
      });

      test('agrees with the cache getCurrentLocation will serve', () async {
        // The whole point of the predicate: when it says yes, the cycle's
        // getCurrentLocation() is a cache hit; when it says no, the cycle
        // pays for an acquisition. Two bounds that drift apart would either
        // one-shot on every cycle or skip an acquisition it needed.
        final fresh = serviceFor();
        await deliver(fresh, positionAt(DateTime.now()));
        when(
          mockGeolocator.isLocationServiceEnabled(),
        ).thenAnswer((_) async => true);
        when(
          mockGeolocator.checkPermission(),
        ).thenAnswer((_) async => geo.LocationPermission.whileInUse);
        // Android corroborates the cache read against the app-op.
        when(
          mockGeolocator.getLastKnownPosition(),
        ).thenAnswer((_) async => positionAt(DateTime.now()));

        expect(fresh.hasFreshStreamFix(), isTrue);
        await fresh.getCurrentLocation();
        verifyNever(
          mockGeolocator.getCurrentPosition(
            locationSettings: anyNamed('locationSettings'),
          ),
        );

        final stale = serviceFor();
        await deliver(
          stale,
          positionAt(
            DateTime.now().subtract(
              kStreamPositionMaxAge + const Duration(seconds: 1),
            ),
          ),
        );
        when(
          mockGeolocator.getCurrentPosition(
            locationSettings: anyNamed('locationSettings'),
          ),
        ).thenAnswer((_) async => positionAt(DateTime.now()));

        expect(stale.hasFreshStreamFix(), isFalse);
        await stale.getCurrentLocation();
        verify(
          mockGeolocator.getCurrentPosition(
            locationSettings: anyNamed('locationSettings'),
          ),
        ).called(1);
      });

      test(
        'a fresh fix is not consent — the gate still throws, and the loss it '
        'observes clears what the predicate reports',
        () async {
          final service = serviceFor();
          await deliver(service, positionAt(DateTime.now()));
          expect(service.hasFreshStreamFix(), isTrue);

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
            throwsA(isA<LocationServiceException>()),
          );

          expect(
            service.hasFreshStreamFix(),
            isFalse,
            reason: 'freshness is read off the same field the access-loss '
                'invalidation clears, so the predicate can never outlive the '
                'consent for the fix it is reporting on',
          );
        },
      );
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
      ///
      /// A function, not a `final`: the iOS last-known read is age-bounded, so
      /// a fixture stamped once at collection time would make the assertion
      /// depend on how long the suite takes to reach it.
      geo.Position lastKnownFix({DateTime? timestamp}) => geo.Position(
        latitude: 30,
        longitude: 40,
        timestamp: timestamp ?? DateTime.now(),
        accuracy: 5,
        altitude: 0,
        altitudeAccuracy: 1,
        heading: 0,
        headingAccuracy: 1,
        speed: 0,
        speedAccuracy: 1,
      );

      GeolocatorLocationService serviceFor({bool isIOS = true}) =>
          GeolocatorLocationService(
            geolocator: mockGeolocator,
            isIOS: isIOS,
            iosSource: fakeIos,
          );

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
      /// and hands back the still-open PLATFORM source plus the subscription
      /// so a test can end the stream the way the platform would (error or
      /// close) instead of merely cancelling.
      ///
      /// Which source that is depends on the platform the service was built
      /// for — Haven's own iOS session or the geolocator plugin — so the
      /// handle exposes what a test does to it rather than the controller
      /// itself; the two carry different types.
      Future<
        ({
          void Function(Object error) addError,
          Future<void> Function() close,
          StreamSubscription<Position> subscription,
        })
      >
      openStream(
        GeolocatorLocationService service,
        geo.Position position,
      ) async {
        final plugin = StreamController<geo.Position>();
        when(
          mockGeolocator.getPositionStream(
            locationSettings: anyNamed('locationSettings'),
          ),
        ).thenAnswer((_) => plugin.stream);
        final subscription = service.getLocationStream().listen(
          (_) {},
          onError: (Object _) {},
        );
        addTearDown(subscription.cancel);
        final native = fakeIos.sessions.isEmpty ? null : fakeIos.session;
        if (native != null) {
          native.add(asPosition(position));
        } else {
          plugin.add(position);
        }
        await Future<void>.delayed(Duration.zero);
        return (
          addError: native != null ? native.addError : plugin.addError,
          close: native != null ? native.close : plugin.close,
          subscription: subscription,
        );
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
            ).thenAnswer((_) async => lastKnownFix());

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
            ).thenAnswer((_) async => lastKnownFix());

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
            ).thenAnswer((_) async => lastKnownFix());

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
            ).thenAnswer((_) async => lastKnownFix());

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

          handle.addError(Exception('provider disabled'));
          await Future<void>.delayed(Duration.zero);

          await expectCacheDoesNotResurrect(service);
        });

        test('the stream closing clears it', () async {
          final service = serviceFor();
          final handle = await openStream(service, cachedFix());

          await handle.close();
          await Future<void>.delayed(Duration.zero);

          await expectCacheDoesNotResurrect(service);
        });

        test('a stream error still reaches subscribers', () async {
          final service = serviceFor();
          final errors = <Object>[];
          final sub = service.getLocationStream().listen(
            (_) {},
            onError: errors.add,
          );
          addTearDown(sub.cancel);

          // The iOS route: a native refusal or CoreLocation failure arrives
          // through the event sink, and must reach subscribers unchanged.
          fakeIos.session.addError(Exception('provider disabled'));
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
            fakeIos
              ..statusValue = backgroundedStatus
              ..nativeLastBestFix = asPosition(lastKnownFix());

            final result = await service.getCurrentLocation();

            expect(result.latitude, 30);
            verifyNever(
              mockGeolocator.getCurrentPosition(
                locationSettings: anyNamed('locationSettings'),
              ),
            );
            verifyNever(mockGeolocator.getLastKnownPosition());
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

      // ---------------------------------------------------------------
      // The Android app-op: access withdrawn without touching the grant.
      //
      // `cmd appops set PKG android:fine_location deny` removes location
      // access WITHOUT killing the process and WITHOUT changing anything
      // the permission gate reads — `checkPermission()` and
      // `getLocationAccuracy()` both go to `ContextCompat
      // .checkSelfPermission`, which answers "granted, precise" either
      // way. AOSP then drops deliveries silently, so the stream raises
      // neither an error nor a close and nothing clears the cache.
      //
      // Modelled exactly that way here: the gate is stubbed HEALTHY in
      // every test below, because that is what the platform reports. The
      // only thing that changes is `getLastKnownPosition()`, which is the
      // one Dart-reachable read the app-op does gate.
      // ---------------------------------------------------------------
      group('an Android app-op denial is invisible to the permission gate',
          () {
        test(
          'a warm cached fix is not served once the platform stops '
          'answering with a position',
          () async {
            final service = await serviceWithWarmCache(isIOS: false);
            stubAccessGranted();
            when(
              mockGeolocator.getLastKnownPosition(),
            ).thenAnswer((_) async => null);
            when(
              mockGeolocator.getCurrentPosition(
                locationSettings: anyNamed('locationSettings'),
              ),
            ).thenThrow(Exception('platform delivers nothing under the op'));

            await expectLater(
              service.getCurrentLocation(),
              throwsA(isA<LocationServiceException>()),
              reason: 'the cached fix was published for up to '
                  'kStreamPositionMaxAge after the user withdrew location '
                  'access — the permission gate cannot see an app-op, so '
                  'the cache read is the only place this is catchable',
            );
          },
        );

        test('the withheld fix is CLEARED, not merely withheld', () async {
          final service = await serviceWithWarmCache(isIOS: false);
          stubAccessGranted();
          when(
            mockGeolocator.getLastKnownPosition(),
          ).thenAnswer((_) async => null);
          when(
            mockGeolocator.getCurrentPosition(
              locationSettings: anyNamed('locationSettings'),
            ),
          ).thenThrow(Exception('platform delivers nothing under the op'));
          await expectLater(
            service.getCurrentLocation(),
            throwsA(isA<LocationServiceException>()),
          );

          // The op is allowed again. A cache that was merely BYPASSED
          // would resurrect the pre-denial coordinate here.
          when(
            mockGeolocator.getLastKnownPosition(),
          ).thenAnswer((_) async => lastKnownFix());
          stubOneShot(oneShotFix);

          final result = await service.getCurrentLocation();

          expect(
            result.latitude,
            10,
            reason: 'restoring the app-op resurrected the fix cached before '
                'the denial',
          );
        });

        test(
          'a platform that still answers serves the warm cache, with no '
          'one-shot',
          () async {
            // The other direction, and the one that keeps this from being
            // "fixed" by making the cache unusable: the cache exists so
            // publish cycles survive without a GPS acquisition per tick.
            final service = await serviceWithWarmCache(isIOS: false);
            stubAccessGranted();
            when(
              mockGeolocator.getLastKnownPosition(),
            ).thenAnswer((_) async => lastKnownFix());

            final result = await service.getCurrentLocation();

            expect(result.latitude, 51.5, reason: 'the CACHED fix, not the '
                'last-known one the corroboration read returned');
            verifyNever(
              mockGeolocator.getCurrentPosition(
                locationSettings: anyNamed('locationSettings'),
              ),
            );
          },
        );

        test('iOS pays nothing for it — there is no app-op there', () async {
          // `throwOnMissingStub` makes this an assertion, not a hope: an
          // unconditional corroboration would call an unstubbed method.
          final service = await serviceWithWarmCache();
          stubAccessGranted();

          final result = await service.getCurrentLocation();

          expect(result.latitude, 51.5);
          verifyNever(mockGeolocator.getLastKnownPosition());
        });

        test(
          'a failing corroboration withholds the cache without clearing it',
          () async {
            // A broken platform channel is not an observation that the user
            // withdrew anything, so the fix is kept — but it is not consent
            // either, so it may not be served. Same rule the gate applies
            // to `unableToDetermine`.
            final service = await serviceWithWarmCache(isIOS: false);
            stubAccessGranted();
            when(mockGeolocator.getLastKnownPosition()).thenThrow(
              Exception('platform channel failed'),
            );
            stubOneShot(oneShotFix);

            expect((await service.getCurrentLocation()).latitude, 10);

            when(
              mockGeolocator.getLastKnownPosition(),
            ).thenAnswer((_) async => lastKnownFix());

            expect(
              (await service.getCurrentLocation()).latitude,
              51.5,
              reason: 'a channel error destroyed the cached fix — that is a '
                  'GPS acquisition per publish tick for the life of the '
                  'fault, and on iOS a backgrounded publish that cannot be '
                  'served at all',
            );
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
