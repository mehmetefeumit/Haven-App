/// Tests for [`themeModeControllerProvider`] — persistence and state.
///
/// Asserts the same invariant as the onboarding controller: every mutation
/// must complete the [SharedPreferences] write *before* updating in-memory
/// state, and the persisted value must round-trip back to the same
/// [ThemeMode] through [loadInitialThemeMode].
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/theme_mode_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('loadInitialThemeMode', () {
    test('returns system when nothing is stored', () async {
      SharedPreferences.setMockInitialValues({});

      expect(await loadInitialThemeMode(), ThemeMode.system);
    });

    test('returns the persisted mode for each known value', () async {
      for (final entry in {
        'system': ThemeMode.system,
        'light': ThemeMode.light,
        'dark': ThemeMode.dark,
      }.entries) {
        SharedPreferences.setMockInitialValues({kThemeModeKey: entry.key});

        expect(await loadInitialThemeMode(), entry.value);
      }
    });

    test('falls back to system on an unrecognised stored value', () async {
      SharedPreferences.setMockInitialValues({kThemeModeKey: 'sepia'});

      expect(await loadInitialThemeMode(), ThemeMode.system);
    });
  });

  group('ThemeModeController.setMode', () {
    test('writes through to SharedPreferences and updates state', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container
          .read(themeModeControllerProvider.notifier)
          .setMode(ThemeMode.dark);

      expect(container.read(themeModeControllerProvider), ThemeMode.dark);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kThemeModeKey), 'dark');
    });

    test('persists before mutating in-memory state', () async {
      // Mirrors the onboarding controller invariant: a process kill between
      // the storage write and the state mutation must not leave the two
      // out of sync. Synchronously after kicking off the write, no state
      // change can have been observed — the controller never publishes a
      // value it has not yet persisted.
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);

      var stateChangeFired = false;
      container.listen<ThemeMode>(
        themeModeControllerProvider,
        (_, _) => stateChangeFired = true,
      );

      final future = container
          .read(themeModeControllerProvider.notifier)
          .setMode(ThemeMode.dark);

      expect(stateChangeFired, isFalse);

      await future;

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kThemeModeKey), 'dark');
      expect(stateChangeFired, isTrue);
    });

    test('round-trips every ThemeMode value', () async {
      for (final mode in ThemeMode.values) {
        SharedPreferences.setMockInitialValues({});
        final container = ProviderContainer();
        addTearDown(container.dispose);

        await container
            .read(themeModeControllerProvider.notifier)
            .setMode(mode);

        expect(await loadInitialThemeMode(), mode);
      }
    });

    test('is a no-op when the selected mode is already active', () async {
      SharedPreferences.setMockInitialValues({kThemeModeKey: 'light'});
      final container = ProviderContainer(
        overrides: [
          themeModeControllerProvider.overrideWith(
            (ref) => ThemeModeController(ThemeMode.light),
          ),
        ],
      );
      addTearDown(container.dispose);

      var notified = 0;
      container.listen<ThemeMode>(
        themeModeControllerProvider,
        (_, _) => notified++,
      );

      await container
          .read(themeModeControllerProvider.notifier)
          .setMode(ThemeMode.light);

      expect(notified, 0, reason: 'no state change should be emitted');
    });
  });
}
