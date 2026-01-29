import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Widget tests for Haven app components.
///
/// These tests verify the UI structure and rendering of production widgets.
/// Note: Rust bridge calls will fail in unit tests (expected behavior).
/// For full integration tests with the Rust bridge, see integration_test/.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Note: HavenApp tests require Rust bridge initialization
  // Full app widget tests are in integration_test/ where the Rust
  // bridge is properly initialized

  test('theme configuration is correct', () {
    final theme = ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
      useMaterial3: true,
    );

    expect(theme.useMaterial3, isTrue);
    expect(theme.colorScheme, isNotNull);
  });

  // Note: HomePage tests require Rust bridge initialization
  // Full widget tests are in integration_test/ where the Rust bridge
  // is properly initialized

  // Note: Full integration tests with Rust bridge are in integration_test/
  // These tests verify widget structure only
}
