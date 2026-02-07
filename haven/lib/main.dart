/// Haven - Private Family Location Sharing
///
/// This is the main entry point for the Haven Flutter application.
/// It provides a secure, privacy-first location sharing experience
/// using the Marmot Protocol (MLS + Nostr) for end-to-end encryption.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/pages/map_shell.dart';
import 'package:haven/src/rust/frb_generated.dart';
import 'package:haven/src/theme/theme.dart';

/// Main entry point for the Haven application.
///
/// Initializes Flutter bindings and the Rust FFI bridge
/// before launching the app.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(
    const ProviderScope(
      child: HavenApp(),
    ),
  );
}

/// Root widget for the Haven application.
///
/// Configures Material Design 3 theming with light and dark variants
/// and sets up the main navigation shell.
class HavenApp extends StatelessWidget {
  /// Creates the root Haven app widget.
  const HavenApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Haven',
      theme: HavenTheme.light(),
      darkTheme: HavenTheme.dark(),
      home: const MapShell(),
    );
  }
}
