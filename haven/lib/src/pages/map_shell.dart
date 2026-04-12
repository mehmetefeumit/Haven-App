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
import 'package:haven/src/providers/self_update_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/nostr_relay_service.dart';
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
  Timer? _pruneTimer;
  Timer? _selfUpdateTimer;
  DateTime? _lastPublishTime;
  DateTime? _lastLocationFetchTime;
  DateTime? _lastInvitationPollTime;
  DateTime? _lastSelfUpdateTime;
  final _resumeStopwatch = Stopwatch();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startTimers();
    // Pre-warm relay service, then fire startup tasks.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final relay = ref.read(relayServiceProvider);
      if (relay is NostrRelayService) {
        await relay.initialize();
      }
      ref
        ..read(keyPackagePublisherProvider)
        ..read(locationPublisherProvider)
        ..read(invitationPollerProvider)
        ..read(selfUpdateProvider);
      // Startup sweep: prune any expired last-known-location rows so the
      // sender-controlled retention contract is honoured on disk.
      unawaited(_runPrune());
    });
  }

  Future<void> _runPrune() async {
    try {
      await ref.read(circleServiceProvider).pruneExpiredLastKnown();
      // Widget may have been disposed while the FFI call was in flight;
      // nothing to do here if so, but the guard prevents any follow-up
      // state access from racing with dispose.
      if (!mounted) return;
    } on Object catch (e) {
      debugPrint('[MapShell] pruneExpiredLastKnown failed: $e');
    }
  }

  void _startTimers() {
    // Publish location every 5 minutes, with overlap guard.
    _sendTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      final now = DateTime.now();
      if (_lastPublishTime == null ||
          now.difference(_lastPublishTime!) >
              const Duration(minutes: 4, seconds: 30)) {
        _lastPublishTime = now;
        ref
          ..invalidate(locationPublisherProvider)
          ..read(locationPublisherProvider);
      }
    });

    // Fetch member locations every 30 seconds, with overlap guard.
    _receiveTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      final now = DateTime.now();
      if (_lastLocationFetchTime == null ||
          now.difference(_lastLocationFetchTime!) >
              const Duration(seconds: 25)) {
        _lastLocationFetchTime = now;
        ref.invalidate(memberLocationsProvider);
      }
    });

    // Prune expired last-known locations every hour. The Timer.periodic
    // cadence already caps how often this fires; a redundant minute-based
    // guard here only adds confusion.
    _pruneTimer = Timer.periodic(const Duration(hours: 1), (_) {
      unawaited(_runPrune());
    });

    // Rotate stale MLS leaf node keys every hour (MIP-03 SHOULD).
    // Also catches any post-join self-updates that failed on the initial
    // attempt (MIP-02 MUST, 24h window).
    _selfUpdateTimer = Timer.periodic(const Duration(hours: 1), (_) {
      final now = DateTime.now();
      if (_lastSelfUpdateTime == null ||
          now.difference(_lastSelfUpdateTime!) > const Duration(minutes: 55)) {
        _lastSelfUpdateTime = now;
        ref
          ..invalidate(selfUpdateProvider)
          ..read(selfUpdateProvider);
      }
    });

    // Poll for new invitations every 2 minutes, with overlap guard.
    _invitationTimer = Timer.periodic(const Duration(minutes: 2), (_) {
      final now = DateTime.now();
      if (_lastInvitationPollTime == null ||
          now.difference(_lastInvitationPollTime!) >
              const Duration(minutes: 1, seconds: 50)) {
        _lastInvitationPollTime = now;
        ref
          ..invalidate(invitationPollerProvider)
          ..read(invitationPollerProvider);
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      // Cancel timers and disconnect WSS to save battery while backgrounded.
      _sendTimer?.cancel();
      _receiveTimer?.cancel();
      _invitationTimer?.cancel();
      _pruneTimer?.cancel();
      _selfUpdateTimer?.cancel();
      final relay = ref.read(relayServiceProvider);
      if (relay is NostrRelayService) {
        relay.shutdown();
      }
    } else if (state == AppLifecycleState.resumed) {
      // Debounce rapid resume cycles (e.g. notification shade pull on Android).
      if (_resumeStopwatch.isRunning &&
          _resumeStopwatch.elapsed < const Duration(seconds: 30)) {
        return;
      }
      _resumeStopwatch
        ..reset()
        ..start();

      // Restart timers (cancelled on pause).
      _startTimers();

      // Immediate send + receive on app resume.
      ref
        ..invalidate(locationPublisherProvider)
        ..invalidate(memberLocationsProvider)
        ..invalidate(keyPackagePublisherProvider)
        ..invalidate(invitationPollerProvider)
        ..read(locationPublisherProvider)
        ..read(memberLocationsProvider)
        ..read(keyPackagePublisherProvider)
        ..read(invitationPollerProvider)
        ..invalidate(selfUpdateProvider)
        ..read(selfUpdateProvider);

      // Prune on resume in case the device slept past the hourly tick.
      unawaited(_runPrune());
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
    _pruneTimer?.cancel();
    _selfUpdateTimer?.cancel();
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
