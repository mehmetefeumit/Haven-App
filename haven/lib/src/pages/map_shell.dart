/// Map shell for Haven.
///
/// The main container view that displays the map with a draggable bottom
/// sheet for circles and a floating settings button. Replaces the traditional
/// tab-based navigation with a map-centric interface.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/pages/map/map_page.dart';
import 'package:haven/src/providers/debug_log_provider.dart';
import 'package:haven/src/providers/invitation_provider.dart';
import 'package:haven/src/providers/key_package_provider.dart';
import 'package:haven/src/providers/location_sharing_provider.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/widgets/circles/circles_bottom_sheet.dart';
import 'package:haven/src/widgets/common/dim_overlay.dart';
import 'package:haven/src/widgets/common/invitations_button.dart';
import 'package:haven/src/widgets/common/settings_button.dart';
import 'package:haven/src/widgets/debug/debug_log_overlay.dart';

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
    // Fire-and-forget startup tasks: publish key package, location, and
    // poll invitations. read() is required for unwatched FutureProviders.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref
        ..read(keyPackagePublisherProvider)
        ..read(locationPublisherProvider)
        ..read(invitationPollerProvider);
    });
  }

  void _startTimers() {
    // Publish location every 5 minutes.
    // invalidate() clears the cached value; read() forces re-execution.
    // Without read(), unwatched FutureProviders won't run.
    _sendTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      ref
        ..invalidate(locationPublisherProvider)
        ..read(locationPublisherProvider);
    });

    // Fetch member locations every 30 seconds
    _receiveTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      ref.invalidate(memberLocationsProvider);
    });

    // Poll for new invitations every 2 minutes.
    // invalidate() clears the cached value; read() forces re-execution.
    // Without read(), fire-and-forget FutureProviders won't run since
    // nothing watches them.
    _invitationTimer = Timer.periodic(const Duration(minutes: 2), (_) {
      ref
        ..invalidate(invitationPollerProvider)
        ..read(invitationPollerProvider);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Immediate send + receive on app resume.
      // invalidate() clears cached values, read() triggers re-execution.
      // Without read(), fire-and-forget providers won't run since nothing
      // watches them.
      ref
        ..invalidate(locationPublisherProvider)
        ..invalidate(memberLocationsProvider)
        ..invalidate(keyPackagePublisherProvider)
        ..invalidate(invitationPollerProvider)
        ..read(locationPublisherProvider)
        ..read(memberLocationsProvider)
        ..read(keyPackagePublisherProvider)
        ..read(invitationPollerProvider);
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

            // Invitations button (top-left, respects safe area)
            Positioned(
              top: topPadding + HavenSpacing.sm,
              left: HavenSpacing.base,
              child: const InvitationsFloatingButton(),
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

            // Debug log overlay (debug builds only)
            if (kDebugMode)
              Consumer(
                builder: (context, ref, _) {
                  final logState = ref.watch(debugLogProvider);
                  if (!logState.isVisible) return const SizedBox.shrink();
                  return const DebugLogOverlay();
                },
              ),
          ],
        ),
      ),
    );
  }
}
