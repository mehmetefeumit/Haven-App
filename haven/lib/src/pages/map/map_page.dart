/// Map page for Haven.
///
/// Primary view showing the user's location and circle members on a map.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/providers/location_provider.dart';
import 'package:haven/src/providers/location_sharing_provider.dart';
import 'package:haven/src/providers/map_controller_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/location_service.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/widgets/widgets.dart';
import 'package:latlong2/latlong.dart';

/// Map page displaying user location and circle members.
///
/// Uses OpenStreetMap tiles for privacy (no Google tracking).
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

    final locationService = ref.read(locationServiceProvider);

    if (mounted) {
      setState(() {
        _isLoadingLocation = true;
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

        // Loading indicator overlay. `liveRegion` ensures VoiceOver /
        // TalkBack announces the state change when the overlay appears
        // (WCAG 2.1 SC 4.1.3 Status Messages).
        if (_isLoadingLocation && _obfuscatedLocation == null)
          Semantics(
            liveRegion: true,
            container: true,
            child: ColoredBox(
              color: Theme.of(
                context,
              ).colorScheme.surface.withValues(alpha: 0.8),
              child: const HavenLoadingIndicator(label: 'Getting location...'),
            ),
          ),

        // Error banner
        if (_errorMessage != null && _obfuscatedLocation == null)
          Positioned.fill(
            child: HavenErrorDisplay(
              title: 'Location Error',
              message: _errorMessage!,
              onRetry: _getLocation,
            ),
          ),
      ],
    );
  }

  Widget _buildMap() {
    final memberLocations = ref.watch(memberLocationsProvider);

    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        initialCenter: _currentLatLng,
        initialZoom: _defaultZoom,
        minZoom: 3,
        maxZoom: 18,
      ),
      children: [
        // OSM tile layer (privacy-friendly, no Google tracking)
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.haven.app',
          maxZoom: 19,
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
