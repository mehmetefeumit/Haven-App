/// Map page for Haven.
///
/// Primary view showing the user's location and circle members on a map.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/constants/tile_cache_policy.dart';
import 'package:haven/src/constants/tile_prefetch_policy.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/location_disclosure_provider.dart';
import 'package:haven/src/providers/location_provider.dart';
import 'package:haven/src/providers/location_sharing_provider.dart';
import 'package:haven/src/providers/map_controller_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/providers/tile_cache_provider.dart';
import 'package:haven/src/providers/tile_http_client_provider.dart';
import 'package:haven/src/providers/tile_prefetch_provider.dart';
import 'package:haven/src/providers/tile_provider_config_provider.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/location_service.dart';
import 'package:haven/src/services/location_sharing_service.dart';
import 'package:haven/src/services/tile_key.dart';
import 'package:haven/src/services/tile_prefetch_service.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/utils/map_focus.dart';
import 'package:haven/src/utils/prefetch_scope.dart';
import 'package:haven/src/utils/tile_coordinates.dart';
import 'package:haven/src/widgets/widgets.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

/// Map page displaying user location and circle members.
///
/// Renders map tiles from the active provider (Stadia Maps by default; see
/// `constants/tiles.dart`) with on-map attribution. No Google services.
class MapPage extends ConsumerStatefulWidget {
  /// Creates the map page.
  const MapPage({super.key});

  @override
  ConsumerState<MapPage> createState() => _MapPageState();
}

class _MapPageState extends ConsumerState<MapPage>
    with WidgetsBindingObserver {
  bool? _isInitialized;
  LocationMessage? _obfuscatedLocation;
  String? _errorMessage;
  HavenCore? _core;

  /// True when the user declined the location prominent-disclosure, so the
  /// empty state reads as a calm "off" choice rather than an error.
  bool _locationDeclined = false;

  /// Ensures the location publisher is kicked exactly once after the user
  /// accepts the disclosure and a first fix is available (the publisher
  /// self-skips until the disclosure flag is set).
  bool _publisherKicked = false;

  /// Whether the camera has been centered on the user's first live GPS fix.
  /// Guards the one-time auto-center so later fixes (and any manual pan) are
  /// never yanked. Kept in memory only: the user's location is never
  /// persisted, so a fresh session always starts from the live fix or the
  /// neutral fallback — never a stored last-known location.
  bool _didCenterOnUser = false;

  /// Whether the [FlutterMap] has completed its first layout, so the shared
  /// [MapController] is attached and `move` is safe to call. If a fix lands
  /// before this, [_onMapReady] performs the initial center instead.
  bool _mapReady = false;

  /// Whether a location fetch is actually in flight (the prominent disclosure
  /// has been accepted and the GPS request is running). Drives only the
  /// loading scrim's *label*, so the UI never claims "Getting location…"
  /// before the user has consented to the disclosure. Scrim *visibility* is
  /// derived from an unresolved location independently of this flag, so a
  /// stale value can never strand the UI on a loading state.
  bool _acquiringLocation = false;

  // M-D: Anticipatory tile prefetch state.

  /// The MLS group ID of the circle whose tiles were last prefetched.
  ///
  /// Guards against re-bursting when the same circle's member locations are
  /// refreshed by the poll timer. A new circle resets this to trigger a fresh
  /// burst.
  List<int>? _lastPrefetchedCircleId;

  /// Debounce timer for the prefetch burst.
  ///
  /// Cancelled on circle-switch and disposed in [dispose] so rapid
  /// circle-selection or poll-driven location refreshes collapse into a single
  /// burst.
  Timer? _prefetchDebounceTimer;

  /// Cached [TilePrefetchService] reference.
  ///
  /// Captured once in [initState] via `ref.read` so [dispose] can cancel any
  /// in-flight burst WITHOUT touching `ref` — Riverpod forbids `ref` use after
  /// the element is disposed, and the widget-dispose cancel is the only thing
  /// that stops a burst when the map is torn down (the provider is an
  /// app-lifetime singleton, so its own `onDispose` does not fire here).
  late final TilePrefetchService _prefetchService;

  // Neutral fallback center used ONLY when the user's live location is
  // unavailable (permission declined or GPS error). When a live fix exists the
  // camera is moved to it on startup, so this is never the resting center for a
  // located user. Not a stored last-known location — Haven never persists one.
  static const _defaultLocation = LatLng(51.5074, -0.1278); // London
  static const _defaultZoom = 15.0;

  /// Fraction of the viewport height occupied by the collapsed bottom sheet.
  /// Shared by the map-controls offset and the off-screen indicator bottom
  /// inset so the two cannot silently desync.
  static const _collapsedSheetFraction = 0.12;

  // The controller's lifetime is owned by [mapControllerProvider] so the
  // circles bottom sheet can call `move` from outside this widget. Keep a
  // locally-cached reference to avoid a provider lookup inside the build
  // path and to keep dispose semantics cheap (the provider scope disposes
  // the controller on shutdown).
  MapController get _mapController => ref.read(mapControllerProvider);

  LatLng get _currentLatLng {
    if (_obfuscatedLocation == null) return _defaultLocation;
    return LatLng(
      _obfuscatedLocation!.latitude(),
      _obfuscatedLocation!.longitude(),
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Capture the prefetch service now (ref.read is valid in initState) so
    // dispose() can cancel without `ref`. The provider is a singleton, so this
    // reference stays valid for the widget's lifetime.
    _prefetchService = ref.read(tilePrefetchServiceProvider);
    _initializeCore();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _prefetchDebounceTimer?.cancel();
    _prefetchService.cancel();
    super.dispose();
  }

  /// Cancels any in-flight prefetch burst when the app moves to the background.
  ///
  /// Mirrors `HavenImageCacheGuard`: background suspension must not continue
  /// writing member-area tiles to the encrypted cache — both for battery
  /// frugality and to avoid extending the at-rest exposure window.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      _prefetchDebounceTimer?.cancel();
      _prefetchService.cancel();
    } else if (state == AppLifecycleState.resumed) {
      // Warm-resume eviction: purge stale/over-budget tiles on foreground
      // return without restarting a prefetch burst (that fires from the
      // memberLocations listener when the UI resumes).
      _runEviction();
    }
  }

  /// Runs tile-cache eviction fire-and-forget, swallowing errors so a
  /// disabled cache never surfaces to the UI.
  void _runEviction() {
    unawaited(
      tileCacheEvict(
        maxBytes: kTileCacheMaxBytes,
        idleAgeSecs: kTileIdlePurgeAge.inSeconds,
        maxRetentionSecs: kTileMaxRetention.inSeconds,
      // tileCacheEvict returns Future<BigInt>; the error handler must also
      // return BigInt to satisfy Dart's Future type constraints.
      ).catchError((Object _) => BigInt.zero),
    );
  }

  /// Initializes the Rust core.
  Future<void> _initializeCore() async {
    try {
      _core = await HavenCore.newInstance();
      final initialized = _core!.isInitialized();

      if (mounted) {
        setState(() {
          _isInitialized = initialized;
        });
      }

      await _getLocation();
    } on Object catch (e) {
      // `on Object` (not `on Exception`) per the project FFI convention: a
      // failure crossing the Rust bridge can surface as an Error
      // (e.g. a late-init/state Error), not just an Exception. Catching only
      // Exception would let those escape as an unhandled async error and strand
      // the UI on the "Initializing…" scrim instead of the retry state.
      debugPrint('Error initializing: ${e.runtimeType}');
      // Read localizations only here — after the await and behind the mounted
      // guard. Reading them at the top of this method (as a pre-await capture)
      // would resolve an inherited widget synchronously while initState() is
      // still on the stack, which Flutter forbids
      // ("dependOnInheritedWidgetOfExactType() ... called before
      // initState() completed"). By the time this catch runs, initState() has
      // long completed, so the lookup is legal and the context is still valid.
      if (!mounted) return;
      final message = AppLocalizations.of(context).mapInitFailedRetry;
      setState(() {
        _isInitialized = false;
        _errorMessage = message;
      });
    }
  }

  /// Processes a GPS position update from the location service.
  void _updateLocationFromPosition(Position position) {
    if (_core == null || !mounted) return;

    final obfuscated = _core!.updateLocation(
      latitude: position.latitude,
      longitude: position.longitude,
    );

    setState(() {
      _obfuscatedLocation = obfuscated;
      _acquiringLocation = false;
      // A live fix supersedes any earlier "location off" / error empty state.
      _errorMessage = null;
      _locationDeclined = false;
    });

    // Publish the obfuscated fix so the circles sheet can recenter on
    // the current user without reaching into this widget's private state.
    ref.read(obfuscatedLocationProvider.notifier).state = LatLng(
      obfuscated.latitude(),
      obfuscated.longitude(),
    );

    // Center the camera on the user's first live fix so startup opens on the
    // user — not on the neutral fallback. Done exactly once; later fixes update
    // only the marker, so a map the user has panned/zoomed is never yanked. If
    // the map has not finished its first layout yet, [_onMapReady] centers
    // instead (covers the rare fix-before-first-frame ordering).
    if (!_didCenterOnUser && _mapReady) {
      _didCenterOnUser = true;
      _mapController.move(_currentLatLng, _defaultZoom);
    }
  }

  /// Called once the map finishes its first layout. If a GPS fix arrived
  /// before the map was ready, perform the one-time center now; otherwise
  /// [_updateLocationFromPosition] handles it when the fix lands.
  void _onMapReady() {
    _mapReady = true;
    if (!_didCenterOnUser && _obfuscatedLocation != null) {
      _didCenterOnUser = true;
      _mapController.move(_currentLatLng, _defaultZoom);
    }
  }

  /// Gets the current location once.
  Future<void> _getLocation() async {
    if (_core == null) return;

    // Capture before any await: the localizations are read off the current
    // context, which must not be touched across an async gap.
    final l10n = AppLocalizations.of(context);

    // Show the in-app prominent disclosure BEFORE any path that triggers the
    // OS location permission prompt (Google Play "disclosure before
    // collection"). `getCurrentLocation()` calls `requestPermission()`
    // internally, so the gate must run first. The accepted flag is persisted,
    // so repeat calls (recenter, re-init) do not re-prompt.
    final disclosed = await ref
        .read(locationDisclosureControllerProvider.notifier)
        .ensureDisclosed(context, includeBackground: false);
    if (!mounted) return;
    if (!disclosed) {
      setState(() {
        _locationDeclined = true;
        _errorMessage = l10n.mapLocationOffMessage;
      });
      return;
    }

    final locationService = ref.read(locationServiceProvider);

    // Disclosure accepted: a fetch is now genuinely in flight. Clear any prior
    // error / declined state so the loading scrim is shown again while this
    // attempt runs (scrim visibility is derived from an unresolved location;
    // `_acquiringLocation` only upgrades its label to "Getting location…").
    if (mounted) {
      setState(() {
        _acquiringLocation = true;
        _locationDeclined = false;
        _errorMessage = null;
      });
    }

    try {
      final serviceEnabled = await locationService.isLocationServiceEnabled();
      if (!serviceEnabled) {
        throw Exception('Location services are disabled');
      }

      final position = await locationService.getCurrentLocation();
      _updateLocationFromPosition(position);

      // Disclosure accepted + first fix obtained → kick the publisher once so
      // the first location share happens promptly instead of waiting for the
      // next periodic tick (the publisher self-skips until disclosure is set).
      if (!_publisherKicked) {
        _publisherKicked = true;
        ref
          ..invalidate(locationPublisherProvider)
          ..read(locationPublisherProvider);
      }
    } on Exception {
      debugPrint('Location error occurred');
      if (mounted) {
        setState(() {
          _acquiringLocation = false;
          _errorMessage = l10n.mapLocationUnavailable;
        });
      }
    }
  }

  void _recenterMap() {
    if (_obfuscatedLocation != null) {
      // Reset to the app's launch view: recenter on the user, restore the
      // default zoom, and clear any manual rotation back to north-up. This
      // makes the button a one-tap "take me home" rather than only nudging
      // the center while leaving a zoomed-out or rotated camera in place.
      resetMapToHome(
        controller: _mapController,
        target: _currentLatLng,
        defaultZoom: _defaultZoom,
      );
    }
    _getLocation();
  }

  void _zoomIn() {
    _mapController.move(
      _mapController.camera.center,
      _mapController.camera.zoom + 1,
    );
  }

  void _zoomOut() {
    _mapController.move(
      _mapController.camera.center,
      _mapController.camera.zoom - 1,
    );
  }

  /// iOS-only: offers an explicit "Open in Apple Maps" action for a member
  /// marker (Apple App Review Guideline 4.0 affordance).
  ///
  /// User-initiated and disclosed: a confirmation sheet states that only the
  /// coordinate is sent. The member's name and pubkey are NOT sent to Apple.
  Future<void> _onMemberMarkerTap({
    required double latitude,
    required double longitude,
    String? name,
  }) async {
    final l10n = AppLocalizations.of(context);
    final label = (name != null && name.isNotEmpty)
        ? name
        : l10n.mapThisLocation;
    final open = await showModalBottomSheet<bool>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                l10n.mapOpenInAppleMapsTitle(label),
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
              subtitle: Text(l10n.mapOpenInAppleMapsBody),
            ),
            ListTile(
              leading: const Icon(Icons.map_outlined),
              title: Text(l10n.mapOpenInAppleMapsConfirm),
              onTap: () => Navigator.of(sheetContext).pop(true),
            ),
            ListTile(
              leading: const Icon(Icons.close),
              title: Text(l10n.commonCancel),
              onTap: () => Navigator.of(sheetContext).pop(false),
            ),
          ],
        ),
      ),
    );
    if ((open ?? false) && mounted) {
      await _openInAppleMaps(latitude: latitude, longitude: longitude);
    }
  }

  /// Opens the given coordinate in Apple Maps via an https universal link.
  ///
  /// Sends only the latitude/longitude — never identity (pubkey) or timestamp.
  Future<void> _openInAppleMaps({
    required double latitude,
    required double longitude,
  }) async {
    final l10n = AppLocalizations.of(context);
    final uri = Uri.https('maps.apple.com', '/', {'ll': '$latitude,$longitude'});
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } on Object catch (e) {
      debugPrint('Open in Apple Maps failed: ${e.runtimeType}');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.mapOpenMapsError)),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Listen to location stream for updates
    ref.listen<AsyncValue<Position>>(locationStreamProvider, (previous, next) {
      next.whenData(_updateLocationFromPosition);
    });

    // M-D: Single listener for anticipatory tile prefetch on circle-selection.
    //
    // Fires when member locations arrive for a newly-selected circle. Scoped
    // to nearest-to-camera members and debounced by [kPrefetchDebounce] so
    // rapid circle-switching or poll-driven refreshes do not spray bursts.
    //
    // Pattern mirrors the locationStreamProvider listener above: one
    // `ref.listen` per provider, no `addPostFrameCallback`, `AsyncData`-gated.
    // ignore: cascade_invocations — ref.listen returns void, cascade not valid.
    ref.listen<AsyncValue<List<MemberLocation>>>(
      memberLocationsProvider,
      (previous, next) {
        final locations = next.valueOrNull;
        if (locations == null || locations.isEmpty) return;

        final circle = ref.read(selectedCircleProvider);
        if (circle == null) return;

        // Skip if we already prefetched for this circle (poll-refresh no-op).
        final lastId = _lastPrefetchedCircleId;
        if (lastId != null && listEquals(lastId, circle.mlsGroupId)) {
          return;
        }

        // Cancel any pending debounce from a previous circle-switch.
        _prefetchDebounceTimer?.cancel();
        _prefetchService.cancel();

        _prefetchDebounceTimer = Timer(kPrefetchDebounce, () {
          if (!mounted) return;
          _triggerPrefetch(locations, circle.mlsGroupId);
        });
      },
    );

    // Make the map extend behind the system status bar
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Theme.of(context).brightness == Brightness.dark
            ? Brightness.light
            : Brightness.dark,
      ),
      child: Scaffold(extendBodyBehindAppBar: true, body: _buildBody()),
    );
  }

  Widget _buildBody() {
    final l10n = AppLocalizations.of(context);
    if (_isInitialized == null) {
      return HavenLoadingIndicator(label: l10n.mapInitializing);
    }

    if (_isInitialized == false) {
      return HavenErrorDisplay(
        title: l10n.mapInitFailedTitle,
        message: _errorMessage ?? l10n.mapInitFailedMessage,
        onRetry: _initializeCore,
      );
    }

    // Calculate bottom offset for map controls (above collapsed sheet)
    final screenHeight = MediaQuery.of(context).size.height;
    final sheetCollapsedHeight = screenHeight * _collapsedSheetFraction;

    return Stack(
      children: [
        // Map. NOTE: the map canvas and everything geographic on it (tiles,
        // north-up orientation, member-marker screen positions, off-screen
        // bearing indicators) must NEVER be mirrored under RTL — geography is
        // not reading-direction. Only the surrounding chrome mirrors.
        _buildMap(),

        // Map controls (positioned above the collapsed bottom sheet).
        // Intentionally pinned bottom-RIGHT in both LTR and RTL: zoom/recenter
        // controls follow the native-map convention (Google/Apple Maps) of a
        // fixed corner rather than mirroring with reading direction.
        Positioned(
          right: HavenSpacing.base,
          bottom: sheetCollapsedHeight + HavenSpacing.base,
          child: MapControls(
            onZoomIn: _zoomIn,
            onZoomOut: _zoomOut,
            onRecenter: _recenterMap,
          ),
        ),

        // Loading scrim. Covers the map from first build until the initial
        // location attempt resolves, so the neutral fallback center (London)
        // is never shown to a user whose live location is moments away. Once a
        // fix lands the camera has already been moved to the user (see
        // [_updateLocationFromPosition]), so lifting the scrim reveals the
        // user's location directly. A declined disclosure or GPS error clears
        // this in favour of the empty-state overlay below.
        // `Positioned.fill` makes the scrim cover the whole viewport (blocking
        // stray taps on the map/controls behind it). `liveRegion` ensures
        // VoiceOver / TalkBack announces the state change when the overlay
        // appears (WCAG 2.1 SC 4.1.3 Status Messages).
        if (_obfuscatedLocation == null &&
            _errorMessage == null &&
            !_locationDeclined)
          Positioned.fill(
            child: Semantics(
              liveRegion: true,
              container: true,
              child: ColoredBox(
                color: Theme.of(
                  context,
                ).colorScheme.surface.withValues(alpha: 0.8),
                // Only claim "Getting location…" once the disclosure is
                // accepted and a fetch is in flight; before consent the scrim
                // is a neutral backdrop behind the disclosure dialog.
                child: HavenLoadingIndicator(
                  label: _acquiringLocation
                      ? l10n.mapGettingLocation
                      : l10n.mapLoadingMap,
                ),
              ),
            ),
          ),

        // Empty state: a declined disclosure is a calm "off" choice, not an
        // error; a real GPS/service failure is shown as an error.
        if (_errorMessage != null && _obfuscatedLocation == null)
          Positioned.fill(
            child: HavenErrorDisplay(
              title: _locationDeclined
                  ? l10n.mapLocationOffTitle
                  : l10n.mapLocationErrorTitle,
              message: _errorMessage!,
              onRetry: _getLocation,
            ),
          ),
      ],
    );
  }

  Widget _buildMap() {
    final memberLocations = ref.watch(memberLocationsProvider);
    // Resolve the active tile style against the live theme brightness, so an
    // "Auto" map-style selection swaps between the light/dark Alidade basemaps
    // as the app theme changes. `_buildMap` depends on `Theme.of(context)`
    // already, so it rebuilds (and re-resolves) on every brightness change.
    final tileConfig = ref.watch(
      tileProviderConfigProvider(Theme.of(context).brightness),
    );
    // Long-lived tile HTTP client (TLS certificate-pinned to Stadia's CA in
    // release builds; see network/pinned_tile_client.dart). Same instance for
    // every tile request, so NetworkTileProvider must not own/close it.
    final tileHttpClient = ref.watch(tileHttpClientProvider);
    // The "Open in Apple Maps" affordance is iOS-only (Apple Review 4.0).
    final isIos = Theme.of(context).platform == TargetPlatform.iOS;

    // Member locations shared by the on-screen marker layer and the
    // off-screen edge-indicator overlay. Loading/error collapse to empty so
    // both layers simply render nothing until data arrives.
    final locations = memberLocations.valueOrNull ?? const <MemberLocation>[];
    // Logical pixels occluded by the collapsed bottom sheet, reserved so
    // droplets and the optical centre stay above it.
    final bottomInset =
        MediaQuery.of(context).size.height * _collapsedSheetFraction;

    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        initialCenter: _currentLatLng,
        initialZoom: _defaultZoom,
        minZoom: 3,
        maxZoom: 18,
        onMapReady: _onMapReady,
      ),
      children: [
        // Base tiles are only fetched when a usable API key is configured.
        // With only the placeholder key (CI / dev) a Stadia request 401s and,
        // in integration tests, the in-flight TLS connect leaks a
        // cancelled-connection SocketException at teardown — so render a
        // neutral surface and never touch the network.
        // Mirrors the map-style-settings preview guard and the prefetch guard
        // in tile_prefetch_service.dart. Users with a real key are unaffected.
        if (tileConfig.apiKeyConfigured)
          TileLayer(
            urlTemplate: tileConfig.urlTemplate,
            additionalOptions: tileConfig.additionalOptions,
            userAgentPackageName: tileConfig.userAgentPackageName,
            maxNativeZoom: tileConfig.maxNativeZoom,
            retinaMode: RetinaMode.isHighDensity(context),
            tileProvider: NetworkTileProvider(
              // Certificate-pinned client (release) shared via the provider.
              // Passed in (not created internally), so NetworkTileProvider
              // will not close it on dispose — correct for an app-lifetime
              // singleton.
              httpClient: tileHttpClient,
              // A contactable User-Agent is set only for endpoints that
              // require one (the OSM dev fallback); flutter_map honours a
              // caller-supplied User-Agent via putIfAbsent. Stadia is
              // api-key authenticated and must NOT receive a Haven string.
              headers: <String, String>{
                if (tileConfig.userAgentHeader != null)
                  'User-Agent': tileConfig.userAgentHeader!,
              },
              // Suppress transient 403/404/429 throws in release (graceful
              // error tiles); debug still surfaces errors for diagnosis.
              // The analyzer evaluates kDebugMode as true and flags this as
              // the default, but the value genuinely differs in release builds.
              // ignore: avoid_redundant_argument_values
              silenceExceptions: !kDebugMode,
              // Use the encrypted SQLCipher tile cache. Initialised at
              // startup in main.dart; falls back to live-only if init failed.
              cachingProvider: ref.watch(tileCachingProviderProvider),
            ),
            // Never log the tile URL (it carries the api_key) — only the type.
            errorTileCallback: (tile, error, stackTrace) =>
                debugPrint('Tile load error: ${error.runtimeType}'),
            evictErrorTileStrategy: EvictErrorTileStrategy.notVisible,
          )
        else
          // No usable API key: render a calm neutral surface so the map still
          // lays out correctly (Positioned.fill is a valid FlutterMap child —
          // the map's internal Stack renders it behind the marker layers).
          const Positioned.fill(
            child: ColoredBox(color: Color(0xFFE0E0E0)),
          ),

        // Unified member markers: one continuous teardrop per member — a
        // centred circle while in view, growing a tail and detaching into a
        // shrinking edge droplet as they leave the viewport, with no swap.
        // Placed below the user-location marker so the user's own dot stays on
        // top. Tapping an off-screen marker recenters the map; an on-screen one
        // opens Apple Maps on iOS (handled per-marker by the layer).
        MemberMarkersLayer(
          members: locations,
          bottomInset: bottomInset,
          onFocusMember: _focusOffScreenMember,
          onMarkerTap: isIos
              ? (member) => _onMemberMarkerTap(
                  latitude: member.latitude,
                  longitude: member.longitude,
                  name: member.displayName,
                )
              : null,
        ),

        // User location marker
        if (_obfuscatedLocation != null)
          MarkerLayer(
            markers: [
              Marker(
                point: _currentLatLng,
                width: 100,
                height: 100,
                child: const UserLocationMarker(accuracyRadius: 40),
              ),
            ],
          ),

        // Attribution is only an obligation when real tiles are shown.
        if (tileConfig.apiKeyConfigured) MapAttribution(config: tileConfig),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // M-D: Anticipatory tile prefetch helpers
  // ---------------------------------------------------------------------------

  /// Fires the prefetch burst for [locations] sorted by distance from the
  /// current camera centre, capped by [kPrefetchMaxTilesTotal].
  ///
  /// Called after the debounce timer fires; safe to call only when [mounted].
  void _triggerPrefetch(
    List<MemberLocation> locations,
    List<int> circleId,
  ) {
    if (!mounted) return;
    if (!_mapReady) return;

    final tileConfig =
        ref.read(tileProviderConfigProvider(Theme.of(context).brightness));

    // Guard: only prefetch hosts the cache will actually store (i.e. ones
    // that TileKey.tryParse can parse). This prevents spurious GETs to the
    // dev OSM fallback, whose apiKeyConfigured is true but whose URL is not
    // cacheable.
    final sampleUrl = expandTileUrl(tileConfig, 0, 0, 0, retina: false);
    if (TileKey.tryParse(sampleUrl) == null) return;

    // Nearest-to-camera scoping (frugal, privacy-preserving).
    // Sort member locations by squared-degree distance from the camera centre.
    final cameraCenter = _mapController.camera.center;
    final points = nearestMemberPoints(locations, cameraCenter);

    // Derive the landing zoom: the zoom the user actually lands on when
    // viewing a member.
    //
    // File:line reference:
    //   map_focus.dart:28 — focusMapOnPoint uses minZoom=14 as the floor.
    //   map_page.dart minZoom=3, maxZoom=18 (MapOptions).
    final landingZoomInt = prefetchLandingZoom(
      _mapController.camera.zoom,
      tileConfig.maxNativeZoom,
    );

    final retina = RetinaMode.isHighDensity(context);

    _lastPrefetchedCircleId = circleId;

    unawaited(
      _prefetchService
          .prefetch(
            points: points,
            config: tileConfig,
            landingZoom: landingZoomInt,
            retina: retina,
          )
          .then((_) => _runEviction()),
    );
  }

  /// Recenters the map on an off-screen [member] when its edge droplet is
  /// tapped, reusing the same camera move, haptic, and screen-reader
  /// announcement as tapping the member in the list.
  void _focusOffScreenMember(MemberLocation member) {
    final name = (member.displayName != null && member.displayName!.isNotEmpty)
        ? member.displayName!
        : AppLocalizations.of(context).mapMemberFallbackName;
    focusMapOnPoint(
      ref: ref,
      context: context,
      target: LatLng(member.latitude, member.longitude),
      announcementName: name,
    );
  }
}
