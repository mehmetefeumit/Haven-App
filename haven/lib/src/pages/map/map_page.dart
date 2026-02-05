/// Map page for Haven.
///
/// Primary view showing the user's location and circle members on a map.
library;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/providers/location_provider.dart';
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
  bool _hasShownPermissionEducation = false;
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

      await _checkPermissionAndGetLocation();
    } on Exception catch (e) {
      debugPrint('Error initializing: $e');
      if (mounted) {
        setState(() {
          _isInitialized = false;
          _errorMessage = 'Initialization failed: $e';
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

  /// Checks permission and gets initial location.
  Future<void> _checkPermissionAndGetLocation() async {
    if (_core == null) return;

    final locationService = ref.read(locationServiceProvider);

    // Check if we need to show permission education first
    if (!_hasShownPermissionEducation) {
      final permissionStatus = await locationService.checkPermission();
      if (permissionStatus == LocationPermissionStatus.notDetermined ||
          permissionStatus == LocationPermissionStatus.denied) {
        final shouldContinue = await _showPermissionEducation();
        if (!shouldContinue) {
          // User declined - don't request permission
          return;
        }
      }
    }

    await _getLocation();
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
      debugPrint('Location error: $e');
      if (mounted) {
        setState(() {
          _errorMessage = e.toString();
          _isLoadingLocation = false;
        });
      }
    }
  }

  /// Shows the permission education dialog and returns whether user
  /// wants to continue with the permission request.
  Future<bool> _showPermissionEducation() async {
    _hasShownPermissionEducation = true;

    if (!mounted) return false;

    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        fullscreenDialog: true,
        builder: (context) => LocationPermissionDialog(
          onContinue: () => Navigator.of(context).pop(true),
          onCancel: () => Navigator.of(context).pop(false),
        ),
      ),
    );

    return result ?? false;
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
    ref.listen<AsyncValue<Position>>(
      locationStreamProvider,
      (previous, next) {
        next.whenData(_updateLocationFromPosition);
      },
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Map'),
        actions: const [
          EncryptionBadge(size: EncryptionBadgeSize.small),
          SizedBox(width: HavenSpacing.base),
        ],
      ),
      body: _buildBody(),
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

    return Stack(
      children: [
        // Map
        _buildMap(),

        // Privacy indicators
        Positioned(
          top: HavenSpacing.base,
          left: HavenSpacing.base,
          right: HavenSpacing.base,
          child: _buildPrivacyBar(),
        ),

        // Map controls
        Positioned(
          right: HavenSpacing.base,
          bottom: HavenSpacing.xl + 80,
          child: MapControls(
            onZoomIn: _zoomIn,
            onZoomOut: _zoomOut,
            onRecenter: _recenterMap,
          ),
        ),

        // Location info card
        if (_obfuscatedLocation != null)
          Positioned(
            left: HavenSpacing.base,
            right: HavenSpacing.base,
            bottom: HavenSpacing.base,
            child: _buildLocationCard(),
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

  Widget _buildPrivacyBar() {
    return SafeArea(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: HavenSpacing.md,
              vertical: HavenSpacing.sm,
            ),
            decoration: BoxDecoration(
              color: Theme.of(
                context,
              ).colorScheme.surface.withValues(alpha: 0.9),
              borderRadius: BorderRadius.circular(HavenSpacing.lg),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.1),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                PrivacyChip(level: PrivacyLevel.exact),
                SizedBox(width: HavenSpacing.sm),
                EncryptionBadge(showLabel: true),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLocationCard() {
    final colorScheme = Theme.of(context).colorScheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(HavenSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(Icons.location_on, color: colorScheme.primary, size: 20),
                const SizedBox(width: HavenSpacing.sm),
                Text(
                  'Your Location',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const Spacer(),
                _buildFreshnessBadge(),
              ],
            ),
            const SizedBox(height: HavenSpacing.sm),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${_obfuscatedLocation!.latitude().toStringAsFixed(5)}, '
                    '${_obfuscatedLocation!.longitude().toStringAsFixed(5)}',
                    style: HavenTypography.monoStyle(
                      context,
                    ).copyWith(fontSize: 12),
                  ),
                ),
                Text(
                  _obfuscatedLocation!.geohash(),
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFreshnessBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: HavenSpacing.sm,
        vertical: HavenSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: HavenFreshnessColors.live.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(HavenSpacing.xs),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: HavenFreshnessColors.live,
            ),
          ),
          const SizedBox(width: HavenSpacing.xs),
          Text(
            'Live',
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: HavenFreshnessColors.live),
          ),
        ],
      ),
    );
  }
}
