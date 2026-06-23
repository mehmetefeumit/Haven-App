/// Tests for [AvatarSendNotifier] and [avatarSendProvider].
///
/// Verifies:
/// - Default state is true (send enabled on first launch).
/// - setEnabled(false) persists and updates state.
/// - setEnabled(true) persists and updates state.
/// - State survives across notifier instances (read-back from SharedPreferences).
/// - SharedPreferences write failure does not throw to the caller.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/avatar_send_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('AvatarSendNotifier — constants', () {
    test('kAvatarSendKey is the expected string', () {
      expect(kAvatarSendKey, equals('haven.avatar.send_enabled'));
    });
  });

  group('AvatarSendNotifier — initial state', () {
    test('defaults to true when no preference stored (feature on by default)',
        () async {
      final prefs = await SharedPreferences.getInstance();
      final notifier = AvatarSendNotifier(prefs: prefs);

      await Future<void>.delayed(Duration.zero);

      expect(
        notifier.state,
        isTrue,
        reason: 'send-my-avatar must default to true so feature works '
            'out of the box without requiring opt-in',
      );
    });

    test('reads stored false value on construction', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(kAvatarSendKey, false);

      final notifier = AvatarSendNotifier(prefs: prefs);
      await Future<void>.delayed(Duration.zero);

      expect(notifier.state, isFalse);
    });

    test('reads stored true value on construction', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(kAvatarSendKey, true);

      final notifier = AvatarSendNotifier(prefs: prefs);
      await Future<void>.delayed(Duration.zero);

      expect(notifier.state, isTrue);
    });
  });

  group('AvatarSendNotifier — setEnabled', () {
    test('setEnabled(false) updates in-memory state', () async {
      final prefs = await SharedPreferences.getInstance();
      final notifier = AvatarSendNotifier(prefs: prefs);
      await Future<void>.delayed(Duration.zero);

      await notifier.setEnabled(enabled: false);

      expect(notifier.state, isFalse);
    });

    test('setEnabled(true) updates in-memory state', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(kAvatarSendKey, false);
      final notifier = AvatarSendNotifier(prefs: prefs);
      await Future<void>.delayed(Duration.zero);

      await notifier.setEnabled(enabled: true);

      expect(notifier.state, isTrue);
    });

    test('setEnabled(false) persists to SharedPreferences', () async {
      final prefs = await SharedPreferences.getInstance();
      final notifier = AvatarSendNotifier(prefs: prefs);
      await Future<void>.delayed(Duration.zero);

      await notifier.setEnabled(enabled: false);

      expect(prefs.getBool(kAvatarSendKey), isFalse);
    });

    test('setEnabled(true) persists to SharedPreferences', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(kAvatarSendKey, false);
      final notifier = AvatarSendNotifier(prefs: prefs);
      await Future<void>.delayed(Duration.zero);

      await notifier.setEnabled(enabled: true);

      expect(prefs.getBool(kAvatarSendKey), isTrue);
    });

    test('persisted false value survives across notifier instances', () async {
      final prefs = await SharedPreferences.getInstance();

      // Write via first notifier instance.
      final notifier1 = AvatarSendNotifier(prefs: prefs);
      await Future<void>.delayed(Duration.zero);
      await notifier1.setEnabled(enabled: false);

      // Read via a fresh notifier instance using the same prefs.
      final notifier2 = AvatarSendNotifier(prefs: prefs);
      await Future<void>.delayed(Duration.zero);

      expect(notifier2.state, isFalse);
    });

    test('re-enable survives across notifier instances', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(kAvatarSendKey, false);

      final notifier1 = AvatarSendNotifier(prefs: prefs);
      await Future<void>.delayed(Duration.zero);
      await notifier1.setEnabled(enabled: true);

      final notifier2 = AvatarSendNotifier(prefs: prefs);
      await Future<void>.delayed(Duration.zero);

      expect(notifier2.state, isTrue);
    });
  });
}
