/// Map page for Haven.
///
/// Primary view showing the user's location and circle members on a map.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/providers/location_disclosure_provider.dart';
import 'package:haven/src/providers/location_provider.dart';
import 'package:haven/src/providers/location_sharing_provider.dart';
import 'package:haven/src/providers/map_controller_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/providers/tile_provider_config_provider.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/location_service.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/theme/theme.dart';
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
  bool _isLoadingLocation = false;
  HavenCore? _core;

  /// True when the user declined the location prominent-disclosure, so the
  /// empty state reads as a calm "off" choice rather than an error.
  bool _locationDeclined = false;

  /// Ensures the location publisher is kicked exactly once after the user
  /// accepts the disclosure and a first fix is available (the publisher
  /// self-skips until the disclosure flag is set).
  bool _publisherKicked = false;

  // Default to a neutral location until GPS is available
  static const _defaultLocation = LatLng(51.5074, -0.1278); // London
  static const _defaultZoom = 15.0;

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
          _errorMessage = 'Initialization failed. Please try again.';
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
      _isLoadingLocation = false;
    });

    // Publish the obfuscated fix so the circles sheet can recenter on
    // the current user without reaching into this widget's private state.
    ref.read(obfuscatedLocationProvider.notifier).state = LatLng(
      obfuscated.latitude(),
      obfuscated.longitude(),
    );
  }

  /// Gets the current location once.
  Future<void> _getLocation() async {
    if (_core == null) return;

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
        _isLoadingLocation = false;
        _locationDeclined = true;
        _errorMessage =
            'Turn on location to see yourself and your circles on the map.';
      });
      return;
    }

    final locationService = ref.read(locationServiceProvider);

    if (mounted) {
      setState(() {
        _isLoadingLocation = true;
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
          _errorMessage = 'Location temporarily unavailable';
          _isLoadingLocation = false;
        });
      }
    }
  }

  void _recenterMap() {
    if (_obfuscatedLocation != null) {
      _mapController.move(_currentLatLng, _mapController.camera.zoom);
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
    final label = (name != null && name.isNotEmpty) ? name : 'this location';
    final open = await showModalBottomSheet<bool>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                'Open $label in Apple Maps?',
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
              subtitle: const Text(
                'Only the map coordinate is sent to Apple Maps — never '
                'a name or identity.',
              ),
            ),
            ListTile(
              leading: const Icon(Icons.map_outlined),
              title: const Text('Open in Apple Maps'),
              onTap: () => Navigator.of(sheetContext).pop(true),
            ),
            ListTile(
              leading: const Icon(Icons.close),
              title: const Text('Cancel'),
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
    final uri = Uri.https('maps.apple.com', '/', {'ll': '$latitude,$longitude'});
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } on Object catch (e) {
      debugPrint('Open in Apple Maps failed: ${e.runtimeType}');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open Maps')),
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
    if (_isInitialized == null) {
      return const HavenLoadingIndicator(label: 'Initializing...');
    }

    if (_isInitialized == false) {
      return HavenErrorDisplay(
        title: 'Initialization Failed',
        message: _errorMessage ?? 'Failed to initialize location services.',
        onRetry: _initializeCore,
      );
    }

    // Calculate bottom offset for map controls (above collapsed sheet)
    final screenHeight = MediaQuery.of(context).size.height;
    final sheetCollapsedHeight = screenHeight * 0.12; // 12% of screen

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

        // Loading indicator overlay. `Positioned.fill` makes the scrim cover
        // the whole viewport (blocking stray taps on the map/controls behind
        // it). `liveRegion` ensures VoiceOver / TalkBack announces the state
        // change when the overlay appears (WCAG 2.1 SC 4.1.3 Status Messages).
        if (_isLoadingLocation && _obfuscatedLocation == null)
          Positioned.fill(
            child: Semantics(
              liveRegion: true,
              container: true,
              child: ColoredBox(
                color: Theme.of(
                  context,
                ).colorScheme.surface.withValues(alpha: 0.8),
                child: const HavenLoadingIndicator(
                  label: 'Getting location...',
                ),
              ),
            ),
          ),

        // Empty state: a declined disclosure is a calm "off" choice, not an
        // error; a real GPS/service failure is shown as an error.
        if (_errorMessage != null && _obfuscatedLocation == null)
          Positioned.fill(
            child: HavenErrorDisplay(
              title: _locationDeclined ? 'Location is off' : 'Location Error',
              message: _errorMessage!,
              onRetry: _getLocation,
            ),
          ),
      ],
    );
  }

  Widget _buildMap() {
    final memberLocations = ref.watch(memberLocationsProvider);
    final tileConfig = ref.watch(tileProviderConfigProvider);
    // The "Open in Apple Maps" affordance is iOS-only (Apple Review 4.0).
    final isIos = Theme.of(context).platform == TargetPlatform.iOS;

    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        initialCenter: _currentLatLng,
        initialZoom: _defaultZoom,
        minZoom: 3,
        maxZoom: 18,
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

        // Member location markers — all rendered identically regardless of
        // data age. An age pill computed from [MemberLocation.timestamp] is
        // shown in the bubble's top-right corner of each marker. Eviction
        // of truly expired rows is enforced by the SQLCipher `purge_after`
        // column.
        memberLocations.when(
          data: (locations) => MarkerLayer(
            markers: locations
                .map(
                  (loc) => Marker(
                    point: LatLng(loc.latitude, loc.longitude),
                    // Footprint: width accommodates the pulse at its max
                    // scale (1.4 × 52 dp ≈ 73 dp); height adds the tail's
                    // visible drop (16 dp) plus a small buffer so the
                    // MarkerLayer never clips the pulse or the tail tip.
                    width: 80,
                    height: 96,
                    // `Alignment.topCenter` anchors the marker so the
                    // BOTTOM-centre of its widget — which is exactly where
                    // [MemberMarker] paints the tail's apex — sits on the
                    // geographic point. Removes the ambiguity of a
                    // circle-centre footprint and lets users see precisely
                    // which building / corner the coordinate refers to.
                    alignment: Alignment.topCenter,
                    // `WidgetKeys.memberMarker(pubkey)` ensures the marker's
                    // State (and its AnimationController) reconciles stably
                    // across list rebuilds, so the pulse fires only on real
                    // location updates — not on incidental reorders. Also
                    // used by E2E tests to assert a marker is present for a
                    // given pubkey.
                    child: MemberMarker(
                      key: WidgetKeys.memberMarker(loc.pubkey),
                      initials: _getInitials(loc.displayName, loc.pubkey),
                      publicKey: loc.pubkey,
                      lastSeen: loc.timestamp,
                      onTap: isIos
                          ? () => _onMemberMarkerTap(
                              latitude: loc.latitude,
                              longitude: loc.longitude,
                              name: loc.displayName,
                            )
                          : null,
                    ),
                  ),
                )
                .toList(),
          ),
          loading: () => const MarkerLayer(markers: []),
          error: (_, __) => const MarkerLayer(markers: []),
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

  /// Gets display initials from a name or public key.
  String _getInitials(String? displayName, String pubkey) {
    if (displayName != null && displayName.isNotEmpty) {
      final parts = displayName.trim().split(' ');
      if (parts.length >= 2) {
        return '${parts.first[0]}${parts.last[0]}';
      }
      return displayName[0];
    }
    // Use first 2 characters of pubkey as fallback
    return pubkey.length >= 2 ? pubkey.substring(0, 2) : pubkey;
  }
}
