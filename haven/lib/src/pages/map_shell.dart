/// Map shell for Haven.
///
/// The main container view that displays the map with a draggable bottom
/// sheet for circles and a floating settings button. Replaces the traditional
/// tab-based navigation with a map-centric interface.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/pages/map/map_page.dart';
import 'package:haven/src/providers/invitation_provider.dart';
import 'package:haven/src/providers/key_package_provider.dart';
import 'package:haven/src/providers/location_sharing_provider.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/widgets/circles/circles_bottom_sheet.dart';
import 'package:haven/src/widgets/common/dim_overlay.dart';
import 'package:haven/src/widgets/common/settings_button.dart';

/// The main shell containing the map, bottom sheet, and floating controls.
///
/// This widget serves as the primary container for the Haven app, featuring:
/// - A full-screen map that extends edge-to-edge
/// - A draggable bottom sheet for viewing and selecting circles
/// - A dim overlay when the sheet is expanded
/// - A floating settings button in the top-right corner
class MapShell extends ConsumerStatefulWidget {
  /// Creates the map shell.
  const MapShell({super.key});

  @override
  ConsumerState<MapShell> createState() => _MapShellState();
}

class _MapShellState extends ConsumerState<MapShell>
    with WidgetsBindingObserver {
  double _sheetExpansion = 0.0;
  final DraggableScrollableController _sheetController =
      DraggableScrollableController();
  Timer? _sendTimer;
  Timer? _receiveTimer;
  Timer? _invitationTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startTimers();
    // Publish key package and poll invitations on startup (fire-and-forget)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref
        ..read(keyPackagePublisherProvider)
        ..read(invitationPollerProvider);
    });
  }

  void _startTimers() {
    // Publish location every 5 minutes
    _sendTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      ref.invalidate(locationPublisherProvider);
    });

    // Fetch member locations every 30 seconds
    _receiveTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      ref.invalidate(memberLocationsProvider);
    });

    // Poll for new invitations every 2 minutes
    _invitationTimer = Timer.periodic(const Duration(minutes: 2), (_) {
      ref.invalidate(invitationPollerProvider);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Immediate send + receive on app resume
      ref
        ..invalidate(locationPublisherProvider)
        ..invalidate(memberLocationsProvider)
        ..invalidate(keyPackagePublisherProvider)
        ..invalidate(invitationPollerProvider);
    }
  }

  Future<void> _collapseSheet() async {
    await _sheetController.animateTo(
      0.12,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  @override
  void dispose() {
    _sendTimer?.cancel();
    _receiveTimer?.cancel();
    _invitationTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _sheetController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.of(context).padding.top;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Theme.of(context).brightness == Brightness.dark
            ? Brightness.light
            : Brightness.dark,
      ),
      child: Scaffold(
        extendBodyBehindAppBar: true,
        body: Stack(
          children: [
            // Full-screen map (always visible)
            const MapPage(),

            // Dim overlay (animated based on sheet expansion)
            Positioned.fill(
              child: DimOverlay(
                opacity: _sheetExpansion,
                onTap: _collapseSheet,
              ),
            ),

            // Settings button (top-right, respects safe area)
            Positioned(
              top: topPadding + HavenSpacing.sm,
              right: HavenSpacing.base,
              child: const SettingsFloatingButton(),
            ),

            // Circles bottom sheet
            CirclesBottomSheet(
              controller: _sheetController,
              onExpansionChanged: (expansion) {
                setState(() => _sheetExpansion = expansion);
              },
            ),
          ],
        ),
      ),
    );
  }
}
