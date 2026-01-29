/// Haven - Private Family Location Sharing
///
/// This is the main entry point for the Haven Flutter application.
/// It demonstrates the integration between Flutter UI and the Rust core
/// for privacy-focused location sharing.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/rust/frb_generated.dart';
import 'package:haven/src/services/geolocator_location_service.dart';
import 'package:haven/src/services/location_service.dart';

/// Main entry point for the Haven application.
///
/// Initializes Flutter bindings and the Rust FFI bridge
/// before launching the app.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(const HavenApp());
}

/// Root widget for the Haven application.
///
/// Configures the Material Design theme and sets up the home page.
class HavenApp extends StatelessWidget {
  /// Creates the root Haven app widget.
  const HavenApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Haven',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

/// Home page demonstrating location tracking with privacy-focused obfuscation.
///
/// This page:
/// - Initializes the Rust core for location processing
/// - Requests location permissions
/// - Displays real-time obfuscated location data
/// - Shows the privacy features (coordinate obfuscation, geohash encoding)
class HomePage extends StatefulWidget {
  /// Creates the home page widget.
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool? _isInitialized;
  LocationMessage? _obfuscatedLocation;
  String? _errorMessage;
  bool _isLoadingLocation = false;
  HavenCore? _core;
  StreamSubscription<Position>? _locationSubscription;
  late final LocationService _locationService;

  @override
  void initState() {
    super.initState();
    _locationService = GeolocatorLocationService();
    _initializeAndGetLocation();
  }

  @override
  void dispose() {
    _locationSubscription?.cancel();
    _locationSubscription = null;
    super.dispose();
  }

  /// Initializes the Rust core and starts location tracking.
  ///
  /// This method:
  /// 1. Creates and initializes the HavenCore instance
  /// 2. Gets the initial location
  /// 3. Sets up a stream for continuous location updates
  ///
  /// Errors are handled and displayed to the user.
  Future<void> _initializeAndGetLocation() async {
    try {
      // Initialize Rust core
      _core = await HavenCore.newInstance();
      final initialized = _core!.isInitialized();

      if (mounted) {
        setState(() {
          _isInitialized = initialized;
        });
      }

      // Get initial location
      await _getLocation();

      if (!mounted) return; // Exit if disposed during async operation

      // Start listening to location stream for continuous updates
      _locationSubscription = _locationService.getLocationStream().listen(
        _updateLocationFromPosition,
        onError: (Object error) {
          debugPrint('Location stream error: $error');
          if (mounted) {
            setState(() {
              _errorMessage = error.toString();
              _isLoadingLocation = false;
            });
          }
        },
        cancelOnError: false, // Continue listening after errors
      );
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
  ///
  /// Sends raw coordinates to the Rust core for privacy-focused obfuscation
  /// (reduces precision, generates geohash, strips metadata).
  void _updateLocationFromPosition(Position position) {
    if (_core == null || !mounted) return;

    // SECURITY: Do NOT log raw GPS coordinates - they are sensitive PII
    // Apps with READ_LOGS permission could capture unobfuscated location data
    // Only log for development if absolutely necessary, never in production

    // Send to Rust for obfuscation
    final obfuscated = _core!.updateLocation(
      latitude: position.latitude,
      longitude: position.longitude,
    );

    // Safe to log obfuscated data (already privacy-protected)
    debugPrint(
      'Obfuscated: ${obfuscated.latitude()}, ${obfuscated.longitude()}',
    );
    debugPrint('Geohash: ${obfuscated.geohash()}');

    setState(() {
      _obfuscatedLocation = obfuscated;
      _isLoadingLocation = false;
    });
  }

  /// Gets the current location once (for initial display).
  ///
  /// Checks location service availability and permissions before requesting
  /// the current position. Errors are displayed to the user.
  Future<void> _getLocation() async {
    if (_core == null) return;

    if (mounted) {
      setState(() {
        _isLoadingLocation = true;
        _errorMessage = null;
      });
    }

    try {
      // Check if location services are enabled
      final serviceEnabled = await _locationService.isLocationServiceEnabled();
      if (!serviceEnabled) {
        throw Exception('Location services are disabled');
      }

      // Get current location
      final position = await _locationService.getCurrentLocation();

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Haven - Location Demo'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text(
                'Welcome to Haven',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 32),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Rust Core: ${_isInitialized == null
                            ? 'Loading...'
                            : _isInitialized!
                            ? 'Initialized ✓'
                            : 'Not initialized ✗'}',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Divider(),
                      const SizedBox(height: 16),
                      if (_isLoadingLocation)
                        const Row(
                          children: [
                            SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            SizedBox(width: 12),
                            Text('Getting location...'),
                          ],
                        )
                      else if (_errorMessage != null)
                        Text(
                          'Error: $_errorMessage',
                          style: const TextStyle(color: Colors.red),
                        )
                      else if (_obfuscatedLocation != null)
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Obfuscated Location:',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 12),
                            _buildLocationRow(
                              'Latitude',
                              _obfuscatedLocation!.latitude().toStringAsFixed(
                                5,
                              ),
                            ),
                            _buildLocationRow(
                              'Longitude',
                              _obfuscatedLocation!.longitude().toStringAsFixed(
                                5,
                              ),
                            ),
                            _buildLocationRow(
                              'Geohash',
                              _obfuscatedLocation!.geohash(),
                            ),
                            _buildLocationRow(
                              'Precision',
                              _obfuscatedLocation!.precision().toString(),
                            ),
                            const SizedBox(height: 8),
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: Colors.green.shade50,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Row(
                                children: [
                                  Icon(
                                    Icons.shield,
                                    color: Colors.green,
                                    size: 16,
                                  ),
                                  SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      'Precision: ~1.1m radius (5 decimals)',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.green,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        )
                      else
                        const Text('Waiting for location...'),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Builds a labeled row displaying a location data field.
  Widget _buildLocationRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              '$label:',
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
          ),
          Expanded(
            child: Text(value, style: const TextStyle(fontFamily: 'monospace')),
          ),
        ],
      ),
    );
  }
}
