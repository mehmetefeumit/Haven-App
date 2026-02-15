/// Haven - Private Family Location Sharing
///
/// This is the main entry point for the Haven Flutter application.
/// It provides a secure, privacy-first location sharing experience
/// using the Marmot Protocol (MLS + Nostr) for end-to-end encryption.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/pages/map_shell.dart';
import 'package:haven/src/providers/debug_log_provider.dart';
import 'package:haven/src/rust/frb_generated.dart';
import 'package:haven/src/theme/theme.dart';

/// Main entry point for the Haven application.
///
/// Initializes Flutter bindings and the Rust FFI bridge
/// before launching the app. In debug mode, installs a zone
/// interceptor to capture print output for the debug overlay.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();

  if (kDebugMode) {
    final container = ProviderContainer();
    runZoned(
      () => runApp(
        UncontrolledProviderScope(
          container: container,
          child: const HavenApp(),
        ),
      ),
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) {
          parent.print(zone, line);
          // Defer state mutation to avoid modifying the provider while
          // the widget tree is building (e.g. debugPrint inside build()).
          scheduleMicrotask(
            () => container.read(debugLogProvider.notifier).addLog(line),
          );
        },
      ),
    );
  } else {
    runApp(const ProviderScope(child: HavenApp()));
  }
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
