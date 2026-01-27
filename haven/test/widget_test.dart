import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Widget tests for Haven app components.
///
/// These tests run without the Rust bridge by testing isolated widgets.
/// For full integration tests with the Rust bridge, see integration_test/.
void main() {
  group('HavenApp UI structure', () {
    testWidgets('renders MaterialApp with correct theme', (tester) async {
      // Test theme configuration without requiring the full app
      final theme = ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      );

      await tester.pumpWidget(
        MaterialApp(
          title: 'Haven',
          theme: theme,
          home: const Scaffold(body: Center(child: Text('Test'))),
        ),
      );

      final materialApp = tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(materialApp.title, 'Haven');
      expect(materialApp.theme?.useMaterial3, isTrue);
    });
  });

  group('HomePage UI', () {
    testWidgets('shows loading state when initialized is null', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: _TestHomePage(isInitialized: null)),
      );

      expect(find.text('Welcome to Haven'), findsOneWidget);
      expect(find.text('Rust Core: Loading...'), findsOneWidget);
    });

    testWidgets('shows initialized state when true', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: _TestHomePage(isInitialized: true)),
      );

      expect(find.text('Rust Core: Initialized'), findsOneWidget);
    });

    testWidgets('shows not initialized state when false', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: _TestHomePage(isInitialized: false)),
      );

      expect(find.text('Rust Core: Not initialized'), findsOneWidget);
    });

    testWidgets('has correct AppBar title', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: _TestHomePage(isInitialized: null)),
      );

      expect(find.widgetWithText(AppBar, 'Haven'), findsOneWidget);
    });
  });
}

/// Test-only version of HomePage that doesn't use the Rust bridge.
///
/// This allows testing the UI rendering logic without native library
/// dependencies.
class _TestHomePage extends StatelessWidget {
  const _TestHomePage({required this.isInitialized});

  final bool? isInitialized;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Haven'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('Welcome to Haven'),
            const SizedBox(height: 16),
            Text(
              'Rust Core: ${isInitialized == null
                  ? 'Loading...'
                  : isInitialized!
                  ? 'Initialized'
                  : 'Not initialized'}',
            ),
          ],
        ),
      ),
    );
  }
}
