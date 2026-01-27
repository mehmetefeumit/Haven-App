import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/main.dart';

/// Widget tests for Haven app components.
///
/// These tests verify the UI structure and rendering of production widgets.
/// Note: Rust bridge calls will fail in unit tests (expected behavior).
/// For full integration tests with the Rust bridge, see integration_test/.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('HavenApp', () {
    testWidgets('creates MaterialApp with correct configuration',
        (tester) async {
      await tester.pumpWidget(const HavenApp());

      // Verify MaterialApp exists
      final materialApp = tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(materialApp.title, 'Haven');
      expect(materialApp.theme?.useMaterial3, isTrue);
      expect(materialApp.theme?.colorScheme.primary, isNotNull);
    });

    testWidgets('uses blue color scheme', (tester) async {
      await tester.pumpWidget(const HavenApp());

      final materialApp = tester.widget<MaterialApp>(find.byType(MaterialApp));
      final seedColor =
          materialApp.theme?.colorScheme.primary ?? Colors.transparent;

      // Blue seed color results in blue-ish primary color
      expect(seedColor.blue, greaterThan(100));
    });

    testWidgets('sets HomePage as home screen', (tester) async {
      await tester.pumpWidget(const HavenApp());

      // HomePage should be present
      expect(find.byType(HomePage), findsOneWidget);
    });
  });

  group('HomePage', () {
    testWidgets('renders AppBar with correct title', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: HomePage()));

      // Initial render
      await tester.pump();

      expect(find.widgetWithText(AppBar, 'Haven'), findsOneWidget);
    });

    testWidgets('renders welcome message', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: HomePage()));

      await tester.pump();

      expect(find.text('Welcome to Haven'), findsOneWidget);
    });

    testWidgets('shows loading or error state', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: HomePage()));

      // First frame - initial state before async completes
      // Since _isInitialized starts as null, it should show Loading
      // But in tests the async might complete instantly, showing "Not initialized"
      final rustStatusFinder = find.textContaining('Rust Core:');
      expect(rustStatusFinder, findsOneWidget);
    });

    testWidgets('handles Rust bridge initialization failure gracefully',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(home: HomePage()));

      // Wait for async initialization to complete (will fail in test environment)
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Should show either loading or not initialized state
      // The Rust bridge will fail, so it should eventually show "Not initialized"
      final rustStatusFinder = find.textContaining('Rust Core:');
      expect(rustStatusFinder, findsOneWidget);
    });

    testWidgets('uses correct layout structure', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: HomePage()));

      await tester.pump();

      // Verify Scaffold structure
      expect(find.byType(Scaffold), findsOneWidget);
      expect(find.byType(AppBar), findsOneWidget);
      expect(find.byType(Center), findsOneWidget);
      expect(find.byType(Column), findsOneWidget);
    });

    testWidgets('column has correct alignment', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: HomePage()));

      await tester.pump();

      final column = tester.widget<Column>(find.byType(Column));
      expect(column.mainAxisAlignment, MainAxisAlignment.center);
    });

    testWidgets('has SizedBox spacing between elements', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: HomePage()));

      await tester.pump();

      final sizedBoxes = find.byType(SizedBox);
      expect(sizedBoxes, findsOneWidget);

      final sizedBox = tester.widget<SizedBox>(sizedBoxes.first);
      expect(sizedBox.height, 16);
    });

    testWidgets('AppBar uses theme color', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
          ),
          home: const HomePage(),
        ),
      );

      await tester.pump();

      final appBar = tester.widget<AppBar>(find.byType(AppBar));
      expect(appBar.backgroundColor, isNotNull);
    });
  });

  group('HavenApp Integration', () {
    testWidgets('full app renders without crashing', (tester) async {
      await tester.pumpWidget(const HavenApp());

      // Let the app initialize
      await tester.pump();
      await tester.pumpAndSettle();

      // Verify basic structure is present
      expect(find.byType(MaterialApp), findsOneWidget);
      expect(find.byType(HomePage), findsOneWidget);
      expect(find.text('Welcome to Haven'), findsOneWidget);
    });

    testWidgets('app has consistent theme throughout', (tester) async {
      await tester.pumpWidget(const HavenApp());
      await tester.pump();

      final materialApp = tester.widget<MaterialApp>(find.byType(MaterialApp));
      final theme = materialApp.theme!;

      expect(theme.useMaterial3, isTrue);
      expect(theme.colorScheme, isNotNull);
    });
  });
}
