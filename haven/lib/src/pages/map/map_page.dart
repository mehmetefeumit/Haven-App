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
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/location_service.dart';
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
  final MapController _mapController = MapController();

  // Default to a neutral location until GPS is available
  static const _defaultLocation = LatLng(51.5074, -0.1278); // London
  static const _defaultZoom = 15.0;

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

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
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
    } on Exception catch (e) {
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
    final topPadding = MediaQuery.of(context).padding.top;

    // Count stale markers currently visible so we can render the
    // "cached locations" pill.
    final memberLocations = ref.watch(memberLocationsProvider);
    final staleCount = memberLocations.maybeWhen(
      data: (locs) => locs.where((l) => l.isStale).length,
      orElse: () => 0,
    );

    return Stack(
      children: [
        // Map
        _buildMap(),

        // Stale-location pill (top center, below status bar + any
        // top-left/top-right floating buttons).
        if (staleCount > 0)
          Positioned(
            top: topPadding + HavenSpacing.sm + 56, // below settings btn
            left: 0,
            right: 0,
            child: Center(child: StaleLocationPill(staleCount: staleCount)),
          ),

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

        // Loading indicator overlay
        if (_isLoadingLocation && _obfuscatedLocation == null)
          ColoredBox(
            color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.8),
            child: const HavenLoadingIndicator(label: 'Getting location...'),
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

        // Member location markers. Stale entries (hydrated from the
        // persistent cache without a fresh relay confirmation this
        // session) render with reduced opacity and a clock badge.
        // Eviction of truly expired rows is enforced by the SQLCipher
        // `purge_after` column, so we do not filter here.
        memberLocations.when(
          data: (locations) => MarkerLayer(
            markers: locations
                .map(
                  (loc) => Marker(
                    point: LatLng(loc.latitude, loc.longitude),
                    width: 56,
                    height: 56,
                    child: MemberMarker(
                      initials: _getInitials(loc.displayName, loc.pubkey),
                      publicKey: loc.pubkey,
                      freshness: loc.freshness,
                      isStale: loc.isStale,
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
