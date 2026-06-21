/// Member marker widget for Haven map.
///
/// Displays a circle member's location as a teardrop-style pin: a circular
/// "bubble" with the member's initials and a downward-pointing tail whose
/// sharp tip marks the exact coordinate. An age pill in the bubble's
/// top-right corner shows how long ago the data was recorded, and a soft
/// one-shot pulse fires when a fresher timestamp arrives — a silent "new
/// data" cue that the user reads subconsciously without announcing itself.
library;

import 'dart:math' show max;

import 'package:flutter/material.dart';
import 'package:haven/src/widgets/map/marker_metrics.dart';

/// Formats a [Duration] into a compact age string for the visible pill.
///
/// Returns `null` for ages under one minute — fresh data reads as "no pill"
/// rather than "just now", which would otherwise be visual noise on every
/// marker for the common case.
///
/// Branches:
/// - `< 1 minute` → `null` (no pill rendered)
/// - `< 60 minutes` → `"Xm"`
/// - `< 24 hours` → `"Xh"`
/// - `≥ 24 hours` → `"Xd"`
String? _formatAge(Duration age) {
  if (age.inMinutes < 1) return null;
  if (age.inMinutes < 60) return '${age.inMinutes}m';
  if (age.inHours < 24) return '${age.inHours}h';
  return '${age.inDays}d';
}

/// Formats a [Duration] into an expanded age string for screen readers.
///
/// Returns `null` for ages under one minute so the semantics label omits the
/// "last seen" clause entirely — parity with the visible pill being hidden.
/// Screen readers pronounce "5m" as "five em" and "2h" as "two aitch"; the
/// expanded form reads naturally via VoiceOver/TalkBack. Singular units are
/// handled separately so speech is grammatical ("1 minute ago", not
/// "1 minutes ago").
String? _formatAgeForSemantics(Duration age) {
  if (age.inMinutes < 1) return null;
  if (age.inMinutes < 60) {
    return age.inMinutes == 1 ? '1 minute ago' : '${age.inMinutes} minutes ago';
  }
  if (age.inHours < 24) {
    return age.inHours == 1 ? '1 hour ago' : '${age.inHours} hours ago';
  }
  return age.inDays == 1 ? '1 day ago' : '${age.inDays} days ago';
}

/// A marker showing a circle member's location on the map.
///
/// Features:
/// - Avatar bubble with initials fallback
/// - Neutral outline ring (same color regardless of data age)
/// - Triangular tail whose tip marks the exact coordinate
/// - Age pill in the bubble's top-right corner
/// - Minimum 48dp touch target for accessibility
/// - One-shot pulse when [lastSeen] advances to a newer timestamp
///
/// The widget is laid out so the tip of the tail sits at the bottom-center
/// of its bounding box. Pair with `Marker(alignment: Alignment.topCenter)`
/// so the tip coincides with the geographic point.
class MemberMarker extends StatefulWidget {
  /// Creates a member marker.
  const MemberMarker({
    required this.initials,
    super.key,
    this.imageUrl,
    this.publicKey,
    this.size = 44,
    this.lastSeen,
    this.onTap,
  });

  /// Initials to display (1-2 characters).
  final String initials;

  /// Optional profile image URL.
  final String? imageUrl;

  /// Public key for generating consistent avatar color.
  final String? publicKey;

  /// Size of the marker's avatar disc in logical pixels.
  final double size;

  /// Timestamp the location was originally recorded.
  ///
  /// Used to compute the age pill label ("5m", "2h", etc.) and to detect
  /// "newer data arrived" for the pulse. When null, no pill is rendered
  /// and the pulse never fires.
  final DateTime? lastSeen;

  /// Callback when the marker is tapped.
  final VoidCallback? onTap;

  /// Key on the pulse layer widget. Tests use this to assert pulse
  /// presence/absence without relying on private types.
  @visibleForTesting
  static const Key pulseLayerKey = Key('member_marker_pulse_layer');

  /// Key on the tail's [CustomPaint]. Tests use this to assert the tail is
  /// drawn at the bottom-center of the marker so it points to the exact
  /// coordinate.
  @visibleForTesting
  static const Key tailKey = Key('member_marker_tail');

  /// Total pulse duration. Short enough to stay in the user's peripheral
  /// vision without registering consciously.
  static const Duration _pulseDuration = Duration(milliseconds: 800);

  /// Alpha at the start of the pulse. Linearly fades to `0` at completion.
  static const double _pulseStartAlpha = 0.35;

  /// How far the tail's base extends *into* the ring's circumference. A
  /// small overlap makes the tail and ring read as a single shape rather
  /// than two adjacent ones with a visible seam.
  static const double _tailRingOverlap = 4;

  @override
  State<MemberMarker> createState() => _MemberMarkerState();
}

class _MemberMarkerState extends State<MemberMarker>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  /// The `lastSeen` value for which we have already rendered (or chosen
  /// not to render) a pulse. Initialized to the widget's initial value so
  /// the first mount does not pulse — a pulse fires only on **strictly
  /// newer** timestamps that arrive while the widget is on screen.
  DateTime? _seenLastSeen;

  /// `MediaQuery.disableAnimations`, resolved in `didChangeDependencies`.
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: MemberMarker._pulseDuration,
      vsync: this,
    );
    _seenLastSeen = widget.lastSeen;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    // If the user enables Reduce Motion mid-pulse, stop the in-flight
    // animation immediately (Apple HIG Motion: honour live toggles).
    if (_reduceMotion && _controller.isAnimating) {
      _controller
        ..stop()
        ..value = 0;
    }
  }

  @override
  void didUpdateWidget(MemberMarker oldWidget) {
    super.didUpdateWidget(oldWidget);
    _maybeFirePulse();
  }

  /// Plays the pulse when [MemberMarker.lastSeen] has advanced past the
  /// most recently seen value. Also absorbs regressions / same-timestamp
  /// rebuilds without firing, and respects reduced-motion.
  void _maybeFirePulse() {
    final lastSeen = widget.lastSeen;
    if (lastSeen == null) return;
    final prev = _seenLastSeen;
    if (prev != null && !lastSeen.isAfter(prev)) return;
    _seenLastSeen = lastSeen;
    if (_reduceMotion) return;
    _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final ringDiameter = widget.size + 8;
    final pulseMaxDiameter = ringDiameter * kPulseMaxScale;

    // Computed once so the avatar disc, the colored tail, and the colored
    // ring all share the same per-member hue — the tail reads as a colored
    // extension of the bubble rather than a detached gray spike. Shared with
    // the off-screen edge droplet (see marker_metrics.dart) so a member is the
    // same colour on the map and at the edge.
    final avatarBg = avatarHue(widget.publicKey, colorScheme);

    // Ensure minimum 48dp touch target for accessibility.
    final touchTargetSize = max<double>(ringDiameter, 48);

    // Compute age once per build so the visible pill and the screen-reader
    // label cannot drift across a minute boundary.
    final age = widget.lastSeen != null
        ? DateTime.now().difference(widget.lastSeen!)
        : null;
    final agePillLabel = age != null ? _formatAge(age) : null;
    final semanticsAge = age != null ? _formatAgeForSemantics(age) : null;
    final semanticsLabel = semanticsAge != null
        ? '${widget.initials} member marker, last seen $semanticsAge'
        : '${widget.initials} member marker';

    // Cap text scaling so Dynamic Type cannot blow the pill label out of
    // the marker footprint. 1.3× still benefits low-vision users.
    final pillTextScaler = MediaQuery.textScalerOf(
      context,
    ).clamp(maxScaleFactor: 1.3);

    // Outer layout —
    // Width: the pulse at its maximum scale defines horizontal extent.
    // Height: half a pulse above the ring centre (so the pulse never
    // clips at the top), the ring's radius, then the tail's visible
    // height below the ring's bottom edge. The bubble's centre sits at
    // y = `pulseMaxDiameter / 2`, and the tail's tip sits at the very
    // bottom of the outer box so it can be anchored to the geographic
    // point via the parent [Marker]'s `alignment: Alignment.topCenter`.
    final outerWidth = pulseMaxDiameter;
    final outerHeight =
        pulseMaxDiameter / 2 + ringDiameter / 2 + kTailVisibleHeight;

    final ringCenterX = outerWidth / 2;
    final ringCenterY = pulseMaxDiameter / 2;
    final ringTopY = ringCenterY - ringDiameter / 2;
    final ringLeftX = ringCenterX - ringDiameter / 2;
    final ringBottomY = ringCenterY + ringDiameter / 2;
    final tailTopY = ringBottomY - MemberMarker._tailRingOverlap;

    final markerBody = SizedBox(
      width: outerWidth,
      height: outerHeight,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Tail — drawn first so the ring and avatar render on top of its
          // overlap region (the 4dp that extends into the ring), giving a
          // clean visual merge between bubble and tail.
          //
          // Fill uses the member's avatar hue so the precision-bearing tip
          // contrasts pale OSM tiles (roads/land), while the white
          // `surface` halo stroke keeps it legible over dark or saturated
          // tiles (water/parks). Together they guarantee the tip stays
          // visible on any basemap — the whole point of the teardrop.
          Positioned(
            left: ringCenterX - kTailBaseWidth / 2,
            top: tailTopY,
            width: kTailBaseWidth,
            height: outerHeight - tailTopY,
            child: CustomPaint(
              key: MemberMarker.tailKey,
              painter: _TailPainter(
                fillColor: avatarBg,
                haloColor: colorScheme.surface,
              ),
            ),
          ),

          // Pulse layer — rendered behind the outline ring, centred on the
          // ring centre. Invisible when the controller is dismissed /
          // completed; only drawn during the 800 ms forward phase.
          Positioned(
            left: ringCenterX - pulseMaxDiameter / 2,
            top: ringCenterY - pulseMaxDiameter / 2,
            width: pulseMaxDiameter,
            height: pulseMaxDiameter,
            child: Center(
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, _) {
                  if (_controller.status != AnimationStatus.forward) {
                    return const SizedBox.shrink();
                  }
                  final t = Curves.easeOut.transform(_controller.value);
                  final scale = 1.0 + t * (kPulseMaxScale - 1.0);
                  final alpha = MemberMarker._pulseStartAlpha * (1 - t);
                  final diameter = ringDiameter * scale;
                  return IgnorePointer(
                    child: Container(
                      key: MemberMarker.pulseLayerKey,
                      width: diameter,
                      height: diameter,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        // Use a neutral outline tone so the pulse reads with
                        // symmetric salience across light and dark themes —
                        // primary inverts brightness between modes and would
                        // make the dark-mode pulse far more attention-grabbing
                        // on the same map tiles.
                        color: colorScheme.outline.withValues(alpha: alpha),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),

          // White halo ring — a `surface`-toned border that wraps the
          // colored avatar disc. Identical appearance regardless of data
          // age. The white halo gives the pin a crisp silhouette against
          // dark/saturated tiles; the colored disc inside carries contrast
          // against pale tiles. One of the two always reads, so the bubble
          // never disappears into the basemap.
          Positioned(
            left: ringLeftX,
            top: ringTopY,
            width: ringDiameter,
            height: ringDiameter,
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: colorScheme.surface, width: 3),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.2),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
            ),
          ),

          // Avatar
          Positioned(
            left: ringCenterX - widget.size / 2,
            top: ringCenterY - widget.size / 2,
            width: widget.size,
            height: widget.size,
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: avatarBg,
                border: Border.all(color: colorScheme.surface, width: 2),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.2),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: _buildAvatarContent(context, avatarBg),
            ),
          ),

          // Age pill — anchored to the bubble's top-right. Bottom-right
          // would collide with the tail, so we move it up.
          if (agePillLabel != null)
            Positioned(
              left: ringLeftX,
              top: ringTopY,
              width: ringDiameter,
              height: ringDiameter,
              child: Align(
                alignment: Alignment.topRight,
                child: Container(
                  decoration: BoxDecoration(
                    color: colorScheme.surface,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: colorScheme.outline),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.2),
                        blurRadius: 4,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 2,
                  ),
                  child: Text(
                    agePillLabel,
                    textScaler: pillTextScaler,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: colorScheme.onSurfaceVariant,
                      height: 1,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );

    // `excludeSemantics: true` prevents the visible initials Text and the
    // age pill Text from being appended to the authored label. Both are
    // already conveyed in `semanticsLabel`, so without this screen readers
    // would announce "<initials> member marker, last seen X. <initials>. X"
    // — redundant and confusing.
    //
    // The outer SizedBox aligns the marker body at the BOTTOM so the
    // tail tip sits at the bottom of whatever box the touch-target
    // expansion produces — preserves the "tip → geographic point"
    // anchor when the touch target dominates.
    return Semantics(
      label: semanticsLabel,
      button: widget.onTap != null,
      excludeSemantics: true,
      onTap: widget.onTap,
      child: GestureDetector(
        onTap: widget.onTap,
        child: SizedBox(
          width: max<double>(touchTargetSize, outerWidth),
          height: max<double>(touchTargetSize, outerHeight),
          child: Align(alignment: Alignment.bottomCenter, child: markerBody),
        ),
      ),
    );
  }

  Widget _buildAvatarContent(BuildContext context, Color avatarBg) {
    final url = widget.imageUrl;
    if (url != null && url.isNotEmpty) {
      return ClipOval(
        child: Image.network(
          url,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) =>
              _buildInitials(avatarBg),
        ),
      );
    }
    return _buildInitials(avatarBg);
  }

  Widget _buildInitials(Color avatarBg) {
    final displayInitials = widget.initials.toUpperCase().substring(
      0,
      widget.initials.length > 2 ? 2 : widget.initials.length,
    );

    return Center(
      child: Text(
        displayInitials,
        style: TextStyle(
          color: onAvatarColor(avatarBg),
          fontSize: widget.size * 0.35,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Paints a downward-pointing isosceles triangle whose apex marks a precise
/// geographic point.
///
/// The triangle's base spans the full width at the top of the canvas; the
/// apex sits at `(width / 2, height)`. It is rendered in three passes so it
/// stays legible over any basemap:
/// 1. a soft drop shadow (lifts the tail off busy tiles),
/// 2. a [haloColor] stroke slightly wider than the body (a crisp outline
///    against dark/saturated tiles),
/// 3. the [fillColor] body (the member's hue, contrasting pale tiles).
///
/// The shadow uses the same 2dp elevation as the avatar so the bubble and
/// tail read as one surface.
class _TailPainter extends CustomPainter {
  const _TailPainter({required this.fillColor, required this.haloColor});

  /// Body colour of the tail — the member's avatar hue, so the tail reads
  /// as a colored extension of the bubble and contrasts pale map tiles.
  final Color fillColor;

  /// Halo (outline) colour, normally `colorScheme.surface`. Drawn as a
  /// stroke under the fill so the tail keeps a crisp edge against dark or
  /// saturated tiles where the body colour alone might blend in.
  final Color haloColor;

  /// Stroke width of the halo outline in logical pixels.
  static const double _haloWidth = 3;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width / 2, size.height)
      ..close();

    // 1. Drop shadow first so later passes cover its top edge cleanly.
    canvas.drawShadow(path, Colors.black.withValues(alpha: 0.4), 2, false);

    // 2. Halo: a stroke centred on the path edge. Half its width spills
    // outside the triangle, forming the visible outline; the inner half is
    // overpainted by the fill. `StrokeJoin.round` keeps the apex from
    // growing a sharp spur that would overshoot the geographic point.
    final halo = Paint()
      ..color = haloColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = _haloWidth
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;
    canvas.drawPath(path, halo);

    // 3. Body fill on top.
    final fill = Paint()
      ..color = fillColor
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
    canvas.drawPath(path, fill);
  }

  @override
  bool shouldRepaint(_TailPainter old) =>
      old.fillColor != fillColor || old.haloColor != haloColor;
}
