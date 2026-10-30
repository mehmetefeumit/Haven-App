/// Integration tests for keyring store initialization.
///
/// These tests require native library compilation and a platform keyring
/// backend (D-Bus Secret Service on Linux, Keychain on macOS, etc.).
///
/// Run with: flutter test integration_test/keyring_test.dart
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/storage_reset_notice_provider.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/rust/frb_generated.dart';
import 'package:integration_test/integration_test.dart';
import 'e2e/_lib/throw_time_error_capture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  group('Keyring store initialization', () {
    // testWidgets (not bare test): only a testWidgets body's failure is
    // recorded in the integration binding's results map, so only it can turn
    // the `flutter drive` build red. A bare test() failure is silently
    // swallowed by integrationDriver. See test/lints/
    // integration_test_propagation_test.dart. The `tester` is unused — these
    // exercise the FFI directly and never pump a widget tree.
    testWidgets('keyring store initializes successfully', (tester) async {
      installThrowTimeErrorLogging();
      // initKeyringStore should complete without error when a platform
      // keyring backend is available.
      await expectLater(initKeyringStore(), completes);
    });

    testWidgets('keyring store initialization is idempotent', (tester) async {
      installThrowTimeErrorLogging();
      // Calling initKeyringStore multiple times should succeed — the Rust
      // implementation caches success in a static Mutex<Option<()>>.
      await initKeyringStore();
      await expectLater(initKeyringStore(), completes);
    });
  });

  // The MDK v0.10.4 storage reset over the real FFI and the platform
  // keyring: every pre-migration store is deleted, the notice stays owed
  // until it is acknowledged, and a fresh install owes nothing. The keyring
  // half (old key ids destroyed, new ones used) is proved against a fake
  // store in haven-core/tests/hard_reset_first_open.rs.
  group('Storage reset', () {
    const preMigration = [
      'session.sqlite',
      'circles.db',
      'tiles.db',
      'haven_mdk.db',
    ];

    Future<Directory> dataDir() async {
      final dir = await Directory.systemTemp.createTemp('haven_reset_');
      addTearDown(() => dir.delete(recursive: true));
      return dir;
    }

    testWidgets('deletes every pre-migration store, and the notice stays '
        'owed until it is acknowledged', (tester) async {
      installThrowTimeErrorLogging();
      await initKeyringStore();
      final dir = await dataDir();
      final planted = [
        for (final name in preMigration)
          for (final suffix in const ['', '-wal', '-shm', '-journal'])
            File('${dir.path}/$name$suffix'),
      ];
      for (final file in planted) {
        file.writeAsBytesSync(List<int>.generate(64, (i) => (i * 37) & 0xff));
      }

      expect(decideStorageResetNotice(dir.path), isTrue);
      expect(
        planted.where((file) => file.existsSync()).map((file) => file.path),
        isEmpty,
        reason: 'no pre-migration store may survive to be opened',
      );
      expect(
        decideStorageResetNotice(dir.path),
        isTrue,
        reason: 'an unanswered notice is owed again on the next launch',
      );

      acknowledgeStorageReset(dataDir: dir.path);
      expect(decideStorageResetNotice(dir.path), isFalse);
    });

    testWidgets('a fresh install owes no notice', (tester) async {
      installThrowTimeErrorLogging();
      await initKeyringStore();
      final dir = await dataDir();

      expect(decideStorageResetNotice(dir.path), isFalse);
    });
  });
}
