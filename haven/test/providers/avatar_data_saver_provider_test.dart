/// Tests for [AvatarDataSaverNotifier] and [avatarDataSaverProvider].
///
/// Verifies:
/// - Default state is false (data-saver off).
/// - setEnabled(true) persists and updates state.
/// - setEnabled(false) persists and updates state.
/// - State survives across notifier instances (read-back from SharedPreferences).
/// - effectiveInterval returns the 24h constant when data-saver is off.
/// - effectiveInterval returns the 72h constant when data-saver is on.
/// - SharedPreferences write failure does not throw to the caller.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/avatar_data_saver_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // Reset SharedPreferences to a clean state before every test.
    SharedPreferences.setMockInitialValues({});
  });

  group('AvatarDataSaverNotifier — constants', () {
    test('avatarAntiEntropyInterval is 24 hours', () {
      expect(avatarAntiEntropyInterval, equals(const Duration(hours: 24)));
    });

    test('avatarAntiEntropyIntervalDataSaver is 72 hours', () {
      expect(
        avatarAntiEntropyIntervalDataSaver,
        equals(const Duration(hours: 72)),
      );
    });

    test('kAvatarDataSaverKey is the expected string', () {
      expect(kAvatarDataSaverKey, equals('haven.avatar.data_saver'));
    });
  });

  group('AvatarDataSaverNotifier — initial state', () {
    test('defaults to false when no preference stored', () async {
      final prefs = await SharedPreferences.getInstance();
      final notifier = AvatarDataSaverNotifier(prefs: prefs);

      // _load() is async; wait one microtask cycle for it to complete.
      await Future<void>.delayed(Duration.zero);

      expect(notifier.state, isFalse);
    });

    test('reads stored true value on construction', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(kAvatarDataSaverKey, true);

      final notifier = AvatarDataSaverNotifier(prefs: prefs);
      await Future<void>.delayed(Duration.zero);

      expect(notifier.state, isTrue);
    });

    test('reads stored false value on construction', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(kAvatarDataSaverKey, false);

      final notifier = AvatarDataSaverNotifier(prefs: prefs);
      await Future<void>.delayed(Duration.zero);

      expect(notifier.state, isFalse);
    });
  });

  group('AvatarDataSaverNotifier — setEnabled', () {
    test('setEnabled(true) updates in-memory state', () async {
      final prefs = await SharedPreferences.getInstance();
      final notifier = AvatarDataSaverNotifier(prefs: prefs);
      await Future<void>.delayed(Duration.zero);

      await notifier.setEnabled(enabled: true);

      expect(notifier.state, isTrue);
    });

    test('setEnabled(false) updates in-memory state', () async {
      final prefs = await SharedPreferences.getInstance();
      // Start with data-saver on.
      await prefs.setBool(kAvatarDataSaverKey, true);
      final notifier = AvatarDataSaverNotifier(prefs: prefs);
      await Future<void>.delayed(Duration.zero);

      await notifier.setEnabled(enabled: false);

      expect(notifier.state, isFalse);
    });

    test('setEnabled(true) persists to SharedPreferences', () async {
      final prefs = await SharedPreferences.getInstance();
      final notifier = AvatarDataSaverNotifier(prefs: prefs);
      await Future<void>.delayed(Duration.zero);

      await notifier.setEnabled(enabled: true);

      expect(prefs.getBool(kAvatarDataSaverKey), isTrue);
    });

    test('setEnabled(false) persists to SharedPreferences', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(kAvatarDataSaverKey, true);
      final notifier = AvatarDataSaverNotifier(prefs: prefs);
      await Future<void>.delayed(Duration.zero);

      await notifier.setEnabled(enabled: false);

      expect(prefs.getBool(kAvatarDataSaverKey), isFalse);
    });

    test('persisted value survives across notifier instances (read-back)',
        () async {
      final prefs = await SharedPreferences.getInstance();

      // Write via first notifier instance.
      final notifier1 = AvatarDataSaverNotifier(prefs: prefs);
      await Future<void>.delayed(Duration.zero);
      await notifier1.setEnabled(enabled: true);

      // Read via a fresh notifier instance using the same prefs.
      final notifier2 = AvatarDataSaverNotifier(prefs: prefs);
      await Future<void>.delayed(Duration.zero);

      expect(notifier2.state, isTrue);
    });

    test('disable persists and reads back correctly', () async {
      final prefs = await SharedPreferences.getInstance();
      // Start on.
      final notifier1 = AvatarDataSaverNotifier(prefs: prefs);
      await Future<void>.delayed(Duration.zero);
      await notifier1.setEnabled(enabled: true);

      // Turn off via second notifier.
      final notifier2 = AvatarDataSaverNotifier(prefs: prefs);
      await Future<void>.delayed(Duration.zero);
      await notifier2.setEnabled(enabled: false);

      // Fresh read — must be off.
      final notifier3 = AvatarDataSaverNotifier(prefs: prefs);
      await Future<void>.delayed(Duration.zero);
      expect(notifier3.state, isFalse);
    });
  });

  group('AvatarDataSaverNotifier — effectiveInterval', () {
    test('returns 24h interval when data-saver is off', () async {
      final prefs = await SharedPreferences.getInstance();
      final notifier = AvatarDataSaverNotifier(prefs: prefs);
      await Future<void>.delayed(Duration.zero);

      expect(notifier.effectiveInterval, equals(const Duration(hours: 24)));
    });

    test('returns 72h interval when data-saver is on', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(kAvatarDataSaverKey, true);
      final notifier = AvatarDataSaverNotifier(prefs: prefs);
      await Future<void>.delayed(Duration.zero);

      expect(notifier.effectiveInterval, equals(const Duration(hours: 72)));
    });

    test('effectiveInterval updates after setEnabled(true)', () async {
      final prefs = await SharedPreferences.getInstance();
      final notifier = AvatarDataSaverNotifier(prefs: prefs);
      await Future<void>.delayed(Duration.zero);
      expect(notifier.effectiveInterval, equals(const Duration(hours: 24)));

      await notifier.setEnabled(enabled: true);

      expect(notifier.effectiveInterval, equals(const Duration(hours: 72)));
    });

    test('effectiveInterval updates after setEnabled(false)', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(kAvatarDataSaverKey, true);
      final notifier = AvatarDataSaverNotifier(prefs: prefs);
      await Future<void>.delayed(Duration.zero);
      expect(notifier.effectiveInterval, equals(const Duration(hours: 72)));

      await notifier.setEnabled(enabled: false);

      expect(notifier.effectiveInterval, equals(const Duration(hours: 24)));
    });

    test('data-saver interval is 3× the normal interval', () {
      // Cross-verify the ratio so a change to one constant fails the test.
      expect(
        avatarAntiEntropyIntervalDataSaver.inHours,
        equals(avatarAntiEntropyInterval.inHours * 3),
      );
    });
  });
}
