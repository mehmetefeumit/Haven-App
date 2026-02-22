/// Integration tests for keyring store initialization.
///
/// These tests require native library compilation and a platform keyring
/// backend (D-Bus Secret Service on Linux, Keychain on macOS, etc.).
///
/// Run with: flutter test integration_test/keyring_test.dart
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/rust/frb_generated.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  group('Keyring store initialization', () {
    test('keyring store initializes successfully', () async {
      // initKeyringStore should complete without error when a platform
      // keyring backend is available.
      await expectLater(initKeyringStore(), completes);
    });

    test('keyring store initialization is idempotent', () async {
      // Calling initKeyringStore multiple times should succeed — the Rust
      // implementation caches success in a static Mutex<Option<()>>.
      await initKeyringStore();
      await expectLater(initKeyringStore(), completes);
    });
  });
}
