/// Map page for Haven.
///
/// Primary view showing the user's location and circle members on a map.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/location_disclosure_provider.dart';
import 'package:haven/src/providers/location_provider.dart';
import 'package:haven/src/providers/location_sharing_provider.dart';
import 'package:haven/src/providers/map_controller_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/providers/tile_http_client_provider.dart';
import 'package:haven/src/providers/tile_provider_config_provider.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/location_service.dart';
import 'package:haven/src/services/location_sharing_service.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/utils/map_focus.dart';
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

class _MapPageState extends ConsumerState<MapPage> {
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
    _initializeCore();
  }

  /// Initializes the Rust core.
  Future<void> _initializeCore() async {
    // Capture before any await: the localizations are read off the current
    // context, which must not be touched across an async gap.
    final l10n = AppLocalizations.of(context);
    try {
      _core = await HavenCore.newInstance();
      final initialized = _core!.isInitialized();

      if (mounted) {
        setState(() {
          _isInitialized = initialized;
        });
      }

      await _getLocation();
    } on Exception catch (e) {
      debugPrint('Error initializing: ${e.runtimeType}');
      if (mounted) {
        setState(() {
          _isInitialized = false;
          _errorMessage = l10n.mapInitFailedRetry;
        });
      }
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
        // Map
        _buildMap(),

        // Map controls (positioned above collapsed bottom sheet)
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
    // MLS group ID for the currently selected circle, forwarded to the marker
    // layer so it can fetch per-member avatar thumbnails.  Null when no circle
    // is selected — the layer falls back to initials in that case.
    final selectedCircle = ref.watch(selectedCircleProvider);
    final mlsGroupId = selectedCircle?.mlsGroupId;
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
        // Tile layer driven by the active provider (Stadia Maps by default;
        // see constants/tiles.dart). Attribution is rendered separately by the
        // MapAttribution overlay below.
        TileLayer(
          urlTemplate: tileConfig.urlTemplate,
          additionalOptions: tileConfig.additionalOptions,
          userAgentPackageName: tileConfig.userAgentPackageName,
          maxNativeZoom: tileConfig.maxNativeZoom,
          retinaMode: RetinaMode.isHighDensity(context),
          tileProvider: NetworkTileProvider(
            // Certificate-pinned client (release) shared via the provider.
            // Passed in (not created internally), so NetworkTileProvider will
            // not close it on dispose — correct for an app-lifetime singleton.
            httpClient: tileHttpClient,
            // A contactable User-Agent is set only for endpoints that require
            // one (the OSM dev fallback); flutter_map honours a caller-supplied
            // User-Agent via putIfAbsent. Stadia is api-key authenticated and
            // must NOT receive a Haven contact string.
            headers: <String, String>{
              if (tileConfig.userAgentHeader != null)
                'User-Agent': tileConfig.userAgentHeader!,
            },
            // Suppress transient 403/404/429 throws in release (graceful error
            // tiles); debug still surfaces errors for diagnosis. The analyzer
            // evaluates kDebugMode as true and flags this as the default, but
            // the value genuinely differs in release builds.
            // ignore: avoid_redundant_argument_values
            silenceExceptions: !kDebugMode,
            // Reuse the startup cache singleton (>=7-day freshness, api_key
            // stripped from cache keys). See main.dart.
            cachingProvider: BuiltInMapCachingProvider.getOrCreateInstance(),
          ),
          // Never log the tile URL (it carries the api_key) — only the type.
          errorTileCallback: (tile, error, stackTrace) =>
              debugPrint('Tile load error: ${error.runtimeType}'),
          evictErrorTileStrategy: EvictErrorTileStrategy.notVisible,
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
          mlsGroupId: mlsGroupId,
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

        // Mandatory provider/OSM attribution + ODbL disclosure. Painted last
        // so it stays on top of the marker layers and remains reachable.
        MapAttribution(config: tileConfig),
      ],
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
