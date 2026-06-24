/// Haven - Private Family Location Sharing
///
/// This is the main entry point for the Haven Flutter application.
/// It provides a secure, privacy-first location sharing experience
/// using the Marmot Protocol (MLS + Nostr) for end-to-end encryption.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:haven/src/constants/tiles.dart';
import 'package:haven/src/licenses/map_licenses.dart';
import 'package:haven/src/network/pinned_tile_client.dart';
import 'package:haven/src/providers/debug_log_provider.dart';
import 'package:haven/src/providers/map_style_provider.dart';
import 'package:haven/src/providers/onboarding_provider.dart';
import 'package:haven/src/providers/theme_mode_provider.dart';
import 'package:haven/src/providers/tile_http_client_provider.dart';
import 'package:haven/src/rust/frb_generated.dart';
import 'package:haven/src/services/background_location_manager.dart';
import 'package:haven/src/services/image_cache_guard.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/widgets/app_router.dart';
import 'package:image_picker_android/image_picker_android.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Process-lifetime owner of the decoded-image-cache eviction guard.
///
/// Held in a top-level final so its lifetime/ownership is explicit (it is also
/// retained by the `WidgetsBinding` observer list once [HavenImageCacheGuard.install]
/// runs). Installed from [main].
final HavenImageCacheGuard _imageCacheGuard = HavenImageCacheGuard();

/// Main entry point for the Haven application.
///
/// Initializes Flutter bindings and the Rust FFI bridge, then loads
/// first-run onboarding flags before rendering the widget tree. In debug
/// mode, installs a zone interceptor to capture print output for the debug
/// overlay.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Force the Android system Photo Picker (scoped, permission-free, per-item
  // access) instead of image_picker's default ACTION_GET_CONTENT document
  // browser. The user picks one photo and the app receives only that image —
  // no whole-library permission is ever requested or held. The `is` guard
  // makes this a no-op on iOS/web/desktop, where the gallery picker
  // (PHPickerViewController on iOS) is already scoped and permission-free.
  final imagePickerPlatform = ImagePickerPlatform.instance;
  if (imagePickerPlatform is ImagePickerAndroid) {
    imagePickerPlatform.useAndroidPhotoPicker = true;
  }

  // Defense-in-depth: silence debugPrint in release builds so any future
  // log regression cannot leak to Android logcat / iOS device console.
  if (kReleaseMode) {
    debugPrint = (String? message, {int? wrapWidth}) {};
  }

  // Privacy: bound the decoded-image cache and evict it when backgrounded so
  // avatar pixels do not linger in memory while Haven is not in the
  // foreground (see HavenImageCacheGuard / SECURITY.md).
  _imageCacheGuard.install();

  // Surface the map-data licences (OSM/ODbL, Stadia, OpenMapTiles) in the
  // "Open-source licenses" page.
  registerMapLicenses();

  // Create the tile cache singleton up-front with a >=7-day freshness floor
  // (OSM tile usage policy) and an api_key-stripping cache key (keeps the
  // Stadia secret out of on-disk cache entries and survives key rotation).
  // getOrCreateInstance is a singleton, so the map's later no-arg call reuses
  // this configuration rather than racing to create a default one.
  BuiltInMapCachingProvider.getOrCreateInstance(
    overrideFreshAge: const Duration(days: 7),
    tileKeyGenerator: tileCacheKey,
  );

  FlutterForegroundTask.initCommunicationPort();
  // Configure the foreground-service notification channel up-front so
  // the channel exists before any `startService` request is issued.
  // Android does not allow modifying a channel's importance after
  // creation, so the channel id needs to match the one used at start
  // time (see `BackgroundLocationManager.init`).
  BackgroundLocationManager.init();
  await RustLib.init();

  final initialFlags = await _loadInitialOnboardingFlags();
  final initialThemeMode = await loadInitialThemeMode();
  final initialMapStyle = await loadInitialMapStyle();

  // Build the tile HTTP client once at startup (TLS certificate-pinned in
  // release; its CA bundle loads asynchronously). Injected via a provider so
  // the map reuses this single long-lived client for every tile request.
  final tileHttpClient = await createTileHttpClient();

  final overrides = [
    onboardingControllerProvider.overrideWith(
      (ref) => OnboardingController(initialFlags),
    ),
    themeModeControllerProvider.overrideWith(
      (ref) => ThemeModeController(initialThemeMode),
    ),
    mapStyleControllerProvider.overrideWith(
      (ref) => MapStyleController(initialMapStyle),
    ),
    tileHttpClientProvider.overrideWithValue(tileHttpClient),
  ];

  if (kDebugMode) {
    final container = ProviderContainer(overrides: overrides);
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
    runApp(ProviderScope(overrides: overrides, child: const HavenApp()));
  }
}

/// Loads the initial [OnboardingFlags] synchronously before `runApp`.
///
/// Handles a one-time migration for users upgrading from versions that
/// predate the onboarding feature: if no `completed` value is stored but
/// the secure-storage identity key is present, the user already has an
/// identity and should not be routed back into onboarding. All flags are
/// flipped to `true` in that case.
Future<OnboardingFlags> _loadInitialOnboardingFlags() async {
  final prefs = await SharedPreferences.getInstance();

  final storedCompleted = prefs.getBool(kOnboardingCompletedKey);
  if (storedCompleted == null) {
    // Migration path for pre-onboarding installs.
    const storage = FlutterSecureStorage(
      iOptions: IOSOptions(
        accessibility: KeychainAccessibility.first_unlock_this_device,
      ),
    );
    var hasIdentity = false;
    try {
      final existing = await storage.read(key: 'haven.nostr.identity');
      hasIdentity = existing != null;
    } on Object catch (e) {
      debugPrint(
        '[Haven] secure storage probe failed during onboarding migration: '
        '${e.runtimeType}',
      );
    }

    if (hasIdentity) {
      // Existing users have already onboarded — flip every flag so they skip
      // straight to the main shell.
      await prefs.setBool(kOnboardingIntroSeenKey, true);
      await prefs.setBool(kOnboardingDisplayNameSetKey, true);
      await prefs.setBool(kOnboardingCompletedKey, true);
      return const OnboardingFlags(
        introSeen: true,
        displayNameSet: true,
        completed: true,
      );
    }
  }

  return OnboardingFlags(
    introSeen: prefs.getBool(kOnboardingIntroSeenKey) ?? false,
    displayNameSet: prefs.getBool(kOnboardingDisplayNameSetKey) ?? false,
    completed: storedCompleted ?? false,
  );
}

/// Root widget for the Haven application.
///
/// Configures Material Design 3 theming with light and dark variants and
/// delegates routing to [AppRouter]. The active [ThemeMode] is watched from
/// [themeModeControllerProvider] so user-selected light/dark/system choices
/// take effect immediately without an app restart.
class HavenApp extends ConsumerWidget {
  /// Creates the root Haven app widget.
  const HavenApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeControllerProvider);
    return MaterialApp(
      title: 'Haven',
      theme: HavenTheme.light(),
      darkTheme: HavenTheme.dark(),
      themeMode: themeMode,
      home: const AppRouter(),
    );
  }
}
