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
    // testWidgets (not bare test): only a testWidgets body's failure is
    // recorded in the integration binding's results map, so only it can turn
    // the `flutter drive` build red. A bare test() failure is silently
    // swallowed by integrationDriver. See test/lints/
    // integration_test_propagation_test.dart. The `tester` is unused — these
    // exercise the FFI directly and never pump a widget tree.
    testWidgets('keyring store initializes successfully', (tester) async {
      // initKeyringStore should complete without error when a platform
      // keyring backend is available.
      await expectLater(initKeyringStore(), completes);
    });

    testWidgets('keyring store initialization is idempotent', (tester) async {
      // Calling initKeyringStore multiple times should succeed — the Rust
      // implementation caches success in a static Mutex<Option<()>>.
      await initKeyringStore();
      await expectLater(initKeyringStore(), completes);
    });
  });
}
