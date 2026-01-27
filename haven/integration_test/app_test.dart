import 'package:flutter_test/flutter_test.dart';
import 'package:haven/main.dart';
import 'package:haven/src/rust/frb_generated.dart';
import 'package:integration_test/integration_test.dart';

/// Integration tests for Haven app with the actual Rust bridge.
///
/// These tests require native library compilation and run on a device/emulator.
/// Run with: flutter test integration_test/app_test.dart
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  group('App initialization', () {
    testWidgets('app starts and shows welcome message', (tester) async {
      await tester.pumpWidget(const HavenApp());
      await tester.pumpAndSettle();

      expect(find.text('Welcome to Haven'), findsOneWidget);
    });

    testWidgets('shows Rust core initialization status', (tester) async {
      await tester.pumpWidget(const HavenApp());
      await tester.pumpAndSettle();

      // Should show initialized status after async operations complete
      expect(find.text('Rust Core: Initialized'), findsOneWidget);
    });

    testWidgets('AppBar displays correct title', (tester) async {
      await tester.pumpWidget(const HavenApp());
      await tester.pump();

      // AppBar title and app title
      expect(find.text('Haven'), findsNWidgets(2));
    });
  });
}
