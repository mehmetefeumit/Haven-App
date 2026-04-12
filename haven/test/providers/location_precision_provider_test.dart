import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:haven/src/providers/location_precision_provider.dart';
import 'package:haven/src/widgets/security/privacy_chip.dart';

void main() {
  // Reset the mock keystore before each test so state does not leak
  // between tests (e.g. a value written in one test being loaded by
  // the async _load() of a notifier constructed in a later test).
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  group('LocationPrecisionNotifier', () {
    test('default value is neighborhood', () {
      final notifier = LocationPrecisionNotifier();
      expect(notifier.debugState, PrivacyLevel.neighborhood);
    });

    test('setPrecision updates state', () async {
      final notifier = LocationPrecisionNotifier();
      await notifier.setPrecision(PrivacyLevel.exact);
      expect(notifier.debugState, PrivacyLevel.exact);
    });

    test('setPrecision persists value', () async {
      const storage = FlutterSecureStorage();
      final notifier = LocationPrecisionNotifier(storage: storage);
      await notifier.setPrecision(PrivacyLevel.city);

      final stored = await storage.read(key: 'haven.location_precision');
      expect(stored, 'city');
    });

    test('loads persisted value on construction', () async {
      const storage = FlutterSecureStorage();
      // Pre-populate secure storage with a persisted value.
      await storage.write(key: 'haven.location_precision', value: 'exact');

      final notifier = LocationPrecisionNotifier(storage: storage);
      // Give the async _load() time to complete.
      await Future<void>.delayed(Duration.zero);

      expect(notifier.debugState, PrivacyLevel.exact);
    });

    test('falls back to default for invalid stored value', () async {
      const storage = FlutterSecureStorage();
      await storage.write(
        key: 'haven.location_precision',
        value: 'invalid_garbage',
      );

      final notifier = LocationPrecisionNotifier(storage: storage);
      await Future<void>.delayed(Duration.zero);

      expect(notifier.debugState, PrivacyLevel.neighborhood);
    });

    test('resetToDefault restores default and clears storage', () async {
      const storage = FlutterSecureStorage();
      final notifier = LocationPrecisionNotifier(storage: storage);
      await notifier.setPrecision(PrivacyLevel.city);
      expect(notifier.debugState, PrivacyLevel.city);

      await notifier.resetToDefault();
      expect(notifier.debugState, PrivacyLevel.neighborhood);

      final stored = await storage.read(key: 'haven.location_precision');
      expect(stored, isNull);
    });

    test('hidden level can be persisted and loaded', () async {
      const storage = FlutterSecureStorage();
      final notifier = LocationPrecisionNotifier(storage: storage);
      await notifier.setPrecision(PrivacyLevel.hidden);
      expect(notifier.debugState, PrivacyLevel.hidden);

      // Verify round-trip.
      final notifier2 = LocationPrecisionNotifier(storage: storage);
      await Future<void>.delayed(Duration.zero);
      expect(notifier2.debugState, PrivacyLevel.hidden);
    });
  });

  group('PrivacyLevelFfi', () {
    test('exact maps to Enhanced', () {
      expect(PrivacyLevel.exact.ffiLabel, 'Enhanced');
    });

    test('neighborhood maps to Standard', () {
      expect(PrivacyLevel.neighborhood.ffiLabel, 'Standard');
    });

    test('city maps to Private', () {
      expect(PrivacyLevel.city.ffiLabel, 'Private');
    });

    test('hidden maps to null', () {
      expect(PrivacyLevel.hidden.ffiLabel, isNull);
    });

    test('all non-hidden levels produce non-null labels', () {
      for (final level in PrivacyLevel.values) {
        if (level == PrivacyLevel.hidden) continue;
        expect(
          level.ffiLabel,
          isNotNull,
          reason: '$level must have an ffiLabel',
        );
      }
    });
  });

  group('locationPrecisionProvider', () {
    test('provides the default precision', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(
        container.read(locationPrecisionProvider),
        PrivacyLevel.neighborhood,
      );
    });

    test('reflects setPrecision changes', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container
          .read(locationPrecisionProvider.notifier)
          .setPrecision(PrivacyLevel.city);
      expect(container.read(locationPrecisionProvider), PrivacyLevel.city);
    });
  });
}
