/// User location marker widget for Haven map.
///
/// Displays the current user's location with accuracy circle and pulse.
library;

import 'package:flutter/material.dart';
import 'package:haven/src/theme/theme.dart';

/// A marker showing the user's current location on the map.
///
/// Features:
/// - Pulsing dot indicating live location
/// - Optional accuracy circle showing GPS precision
/// - Customizable colors based on freshness
class UserLocationMarker extends StatefulWidget {
  /// Creates a user location marker.
  const UserLocationMarker({
    super.key,
    this.size = defaultSize,
    this.showAccuracyCircle = true,
    this.accuracyRadius = 50,
    this.freshness = LocationFreshness.live,
    this.showPulse = true,
  });

  /// Minimum recommended marker size for visibility.
  static const double minimumSize = 24;

  /// Default marker size for good visibility.
  static const double defaultSize = 32;

  /// Size of the marker dot in logical pixels.
  final double size;

  /// Whether to show the accuracy circle.
  final bool showAccuracyCircle;

  /// Radius of the accuracy circle in logical pixels.
  final double accuracyRadius;

  /// How fresh the location data is.
  final LocationFreshness freshness;

  /// Whether to show the pulse animation.
  final bool showPulse;

  @override
  State<UserLocationMarker> createState() => _UserLocationMarkerState();
}

class _UserLocationMarkerState extends State<UserLocationMarker>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _pulseAnimation;
  bool _reduceMotion = false;

  /// Determines if animations should run based on widget state and
  /// accessibility preferences.
  bool get _shouldAnimate =>
      widget.showPulse &&
      widget.freshness == LocationFreshness.live &&
      !_reduceMotion;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    );

    _pulseAnimation = Tween<double>(
      begin: 1,
      end: 1.8,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Check reduced motion preference from MediaQuery
    final mediaQuery = MediaQuery.maybeOf(context);
    _reduceMotion = mediaQuery?.disableAnimations ?? false;
    _updateAnimationState();
  }

  @override
  void didUpdateWidget(UserLocationMarker oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateAnimationState();
  }

  void _updateAnimationState() {
    if (_shouldAnimate) {
      if (!_controller.isAnimating) {
        _controller.repeat();
      }
    } else {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Color get _markerColor => switch (widget.freshness) {
    LocationFreshness.live => HavenFreshnessColors.live,
    LocationFreshness.recent => HavenFreshnessColors.recent,
    LocationFreshness.stale => HavenFreshnessColors.stale,
    LocationFreshness.old => HavenFreshnessColors.old,
  };

  String get _freshnessLabel => switch (widget.freshness) {
    LocationFreshness.live => 'live',
    LocationFreshness.recent => 'recent',
    LocationFreshness.stale => 'stale',
    LocationFreshness.old => 'outdated',
  };

  @override
  Widget build(BuildContext context) {
    final accuracyInfo = widget.showAccuracyCircle
        ? '. Accuracy: ${widget.accuracyRadius.toInt()} meters'
        : '';
    return Semantics(
      label: 'Your location marker, $_freshnessLabel$accuracyInfo',
      child: SizedBox(
        width: widget.showAccuracyCircle
            ? widget.accuracyRadius * 2
            : widget.size * 2,
        height: widget.showAccuracyCircle
            ? widget.accuracyRadius * 2
            : widget.size * 2,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Accuracy circle
            if (widget.showAccuracyCircle)
              Container(
                width: widget.accuracyRadius * 2,
                height: widget.accuracyRadius * 2,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _markerColor.withValues(alpha: 0.1),
                  border: Border.all(
                    color: _markerColor.withValues(alpha: 0.3),
                    width: 2,
                  ),
                ),
              ),

            // Pulse effect (respects reduced motion preference)
            if (_shouldAnimate)
              AnimatedBuilder(
                animation: _pulseAnimation,
                builder: (context, child) {
                  return Container(
                    width: widget.size * _pulseAnimation.value,
                    height: widget.size * _pulseAnimation.value,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _markerColor.withValues(
                        alpha: 0.3 * (1 - (_pulseAnimation.value - 1) / 0.8),
                      ),
                    ),
                  );
                },
              ),

            // Main dot
            Container(
              width: widget.size,
              height: widget.size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _markerColor,
                border: Border.all(color: Colors.white, width: 3),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.2),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// How fresh the location data is.
enum LocationFreshness {
  /// Location updated within the last minute.
  live,

  /// Location updated within the last 5 minutes.
  recent,

  /// Location updated within the last 15 minutes.
  stale,

  /// Location older than 15 minutes.
  old,
}
