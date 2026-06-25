/// Tests for [`localeControllerProvider`] — persistence and state.
///
/// Mirrors the theme-mode provider's invariant: every mutation must complete
/// the [SharedPreferences] write *before* updating in-memory state, the stored
/// value must round-trip through [loadInitialLocale], and an unsupported or
/// garbage stored value must fall back to `null` (follow the device locale).
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/locale_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('loadInitialLocale', () {
    test('returns null (system) when nothing is stored', () async {
      SharedPreferences.setMockInitialValues({});

      expect(await loadInitialLocale(), isNull);
    });

    test('returns the persisted locale for a supported language', () async {
      SharedPreferences.setMockInitialValues({kLocaleKey: 'en'});

      expect(await loadInitialLocale(), const Locale('en'));
    });

    test('keeps only the language subtag of a region-tagged value', () async {
      SharedPreferences.setMockInitialValues({kLocaleKey: 'en-US'});

      expect(await loadInitialLocale(), const Locale('en'));
    });

    test('falls back to null on an unsupported language', () async {
      SharedPreferences.setMockInitialValues({kLocaleKey: 'xx'});

      expect(await loadInitialLocale(), isNull);
    });

    test('falls back to null on a garbage value', () async {
      SharedPreferences.setMockInitialValues({kLocaleKey: '!!!'});

      expect(await loadInitialLocale(), isNull);
    });
  });

  group('LocaleController.setLocale', () {
    test('writes through to SharedPreferences and updates state', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container
          .read(localeControllerProvider.notifier)
          .setLocale(const Locale('en'));

      expect(container.read(localeControllerProvider), const Locale('en'));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kLocaleKey), 'en');
    });

    test('null clears the persisted override', () async {
      SharedPreferences.setMockInitialValues({kLocaleKey: 'en'});
      final container = ProviderContainer(
        overrides: [
          localeControllerProvider.overrideWith(
            (ref) => LocaleController(const Locale('en')),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(localeControllerProvider.notifier)
          .setLocale(null);

      expect(container.read(localeControllerProvider), isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kLocaleKey), isNull);
    });

    test('persists before mutating in-memory state', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);

      var stateChangeFired = false;
      container.listen<Locale?>(
        localeControllerProvider,
        (_, _) => stateChangeFired = true,
      );

      // setLocale suspends at its first `await` (the SharedPreferences write)
      // and only assigns `state` afterwards, so the listener must NOT have
      // fired before the returned future completes.
      final future = container
          .read(localeControllerProvider.notifier)
          .setLocale(const Locale('en'));
      expect(stateChangeFired, isFalse);

      await future;

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kLocaleKey), 'en');
      expect(stateChangeFired, isTrue);
      expect(container.read(localeControllerProvider), const Locale('en'));
    });

    test('re-selecting the current locale is a no-op', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer(
        overrides: [
          localeControllerProvider.overrideWith(
            (ref) => LocaleController(const Locale('en')),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(localeControllerProvider.notifier)
          .setLocale(const Locale('en'));

      // No write happened (state seeded via override, not persisted).
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kLocaleKey), isNull);
      expect(container.read(localeControllerProvider), const Locale('en'));
    });
  });
}
