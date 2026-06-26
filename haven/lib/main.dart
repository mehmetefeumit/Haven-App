/// Haven - Private Family Location Sharing
///
/// This is the main entry point for the Haven Flutter application.
/// It provides a secure, privacy-first location sharing experience
/// using the Marmot Protocol (MLS + Nostr) for end-to-end encryption.
library;

import 'dart:async';
import 'dart:io' show Directory;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/constants/tile_cache_policy.dart';
import 'package:haven/src/constants/tiles.dart';
import 'package:haven/src/licenses/map_licenses.dart';
import 'package:haven/src/network/pinned_tile_client.dart';
import 'package:haven/src/providers/debug_log_provider.dart';
import 'package:haven/src/providers/locale_provider.dart';
import 'package:haven/src/providers/map_style_provider.dart';
import 'package:haven/src/providers/onboarding_provider.dart';
import 'package:haven/src/providers/theme_mode_provider.dart';
import 'package:haven/src/providers/tile_cache_provider.dart';
import 'package:haven/src/providers/tile_http_client_provider.dart';
import 'package:haven/src/rust/api.dart' show tileCacheEvict, tileCacheInit;
import 'package:haven/src/rust/frb_generated.dart';
import 'package:haven/src/services/background_location_manager.dart';
import 'package:haven/src/services/image_cache_guard.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/widgets/app_router.dart';
import 'package:image_picker_android/image_picker_android.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:path_provider/path_provider.dart';
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

  FlutterForegroundTask.initCommunicationPort();
  // Configure the foreground-service notification channel up-front so
  // the channel exists before any `startService` request is issued.
  // Android does not allow modifying a channel's importance after
  // creation, so the channel id needs to match the one used at start
  // time (see `BackgroundLocationManager.init`).
  BackgroundLocationManager.init();
  await RustLib.init();

  // ---------------------------------------------------------------------------
  // Encrypted tile cache — must complete before first render so the map never
  // reads from the old plaintext cache after the migration step below.
  // ---------------------------------------------------------------------------

  // Resolve the data directory once for both the migration and the cache init.
  final appDir = await getApplicationDocumentsDirectory();
  final dataDir = '${appDir.path}/haven';

  // One-time migration: destroy the legacy BuiltInMapCachingProvider plaintext
  // cache so its unencrypted tile files are removed from disk. Gated by a
  // SharedPreferences flag so this runs exactly once per install.
  final prefs = await SharedPreferences.getInstance();
  if (!(prefs.getBool('tile_cache_migrated_v1') ?? false)) {
    try {
      // tileCacheKey is used here only for the migration destroy call;
      // it is retained for this purpose — do not remove it. // retained for migration
      await BuiltInMapCachingProvider.getOrCreateInstance(
        overrideFreshAge: const Duration(days: 7),
        tileKeyGenerator: tileCacheKey,
      ).destroy(deleteCache: true);
      await prefs.setBool('tile_cache_migrated_v1', true);
    } on Object catch (e) {
      debugPrint('[Haven] tile cache migration error: ${e.runtimeType}');
      // Fallback: delete flutter_map's plaintext cache directory directly
      // (getApplicationCacheDirectory()/fm_cache — verified against flutter_map
      // 8.3.0). Without this, a persistently-failing destroy() would leave the
      // pre-encryption plaintext tiles — a map of everywhere the circle has
      // been — at rest forever while the migration flag never flips.
      try {
        final cacheRoot = await getApplicationCacheDirectory();
        final fmCache = Directory('${cacheRoot.path}/fm_cache');
        if (fmCache.existsSync()) {
          await fmCache.delete(recursive: true);
        }
        await prefs.setBool('tile_cache_migrated_v1', true);
      } on Object catch (e2) {
        // Both paths failed — surface a SECURITY-tagged log and leave the flag
        // unset so it retries next launch. Upgraders keep a plaintext fm_cache
        // until one of these succeeds.
        debugPrint(
          '[Haven][SECURITY] legacy plaintext tile cache not removed '
          '(${e2.runtimeType}); will retry next launch',
        );
      }
    }
  }

  // Initialise the encrypted SQLCipher tile cache.
  var tileCacheEnabled = false;
  try {
    await tileCacheInit(dataDir: dataDir);
    tileCacheEnabled = true;
  } on Object catch (e) {
    debugPrint(
      '[Haven] tileCacheInit failed: ${e.runtimeType} — map will fetch live',
    );
  }

  // Startup eviction: purge stale/over-budget tiles on cold start.
  // M-D: warm-resume eviction is wired in _MapPageState (lifecycle handler).
  // (map_page.dart) via _runEviction(), mirroring HavenImageCacheGuard.
  if (tileCacheEnabled) {
    unawaited(
      tileCacheEvict(
        maxBytes: kTileCacheMaxBytes,
        idleAgeSecs: kTileIdlePurgeAge.inSeconds,
        maxRetentionSecs: kTileMaxRetention.inSeconds,
        // Swallow a cache-eviction failure (lock poisoned / SQLite error) so it
        // never surfaces as an unhandled zone error; matches _runEviction in
        // map_page.dart.
      ).catchError((Object _) => BigInt.zero),
    );
  }

  final initialFlags = await _loadInitialOnboardingFlags();
  final initialThemeMode = await loadInitialThemeMode();
  final initialMapStyle = await loadInitialMapStyle();
  // Pre-load the persisted language before the first frame so the UI renders
  // in the chosen language with no flash of the wrong one (like the theme).
  final initialLocale = await loadInitialLocale();

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
    localeControllerProvider.overrideWith(
      (ref) => LocaleController(initialLocale),
    ),
    tileHttpClientProvider.overrideWithValue(tileHttpClient),
    tileCacheEnabledProvider.overrideWithValue(tileCacheEnabled),
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
    final locale = ref.watch(localeControllerProvider);
    return MaterialApp(
      title: 'Haven',
      theme: HavenTheme.light(),
      darkTheme: HavenTheme.dark(),
      themeMode: themeMode,
      // null follows the device locale; a chosen language overrides it. The
      // delegates/supportedLocales come from the generated AppLocalizations.
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const AppRouter(),
    );
  }
}
