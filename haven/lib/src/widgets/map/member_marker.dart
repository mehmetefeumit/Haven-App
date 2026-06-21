/// Unified circle-member map marker for Haven.
///
/// One continuous teardrop: a plain circular avatar bubble centred on the
/// member while comfortably in view, growing a joined tail (pointing at the
/// member's true location) as they near or leave the viewport edge, and
/// shrinking to a tiny edge droplet welded to the border when far off-screen.
/// Position, [diameter], [nubLength], and [angle] are recomputed every frame
/// by the layer directly from the map camera, so the motion tracks the user's
/// pan exactly; only the brief appear transition is animated here.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/utils/marker_geometry.dart'
    show kDropletFullDiameter, kMinTapTarget, offScreenSemanticsLabel;
import 'package:haven/src/widgets/map/marker_metrics.dart';

/// Formats a [Duration] into a compact age string for the visible pill.
///
/// Returns `null` for ages under one minute — fresh data reads as "no pill"
/// rather than "just now", which would be visual noise on the common case.
String? _formatAge(Duration age) {
  if (age.inMinutes < 1) return null;
  if (age.inMinutes < 60) return '${age.inMinutes}m';
  if (age.inHours < 24) return '${age.inHours}h';
  return '${age.inDays}d';
}

/// Formats a [Duration] into an expanded age string for screen readers, so
/// VoiceOver/TalkBack read "5 minutes ago" rather than "five em".
String? _formatAgeForSemantics(Duration age) {
  if (age.inMinutes < 1) return null;
  if (age.inMinutes < 60) {
    return age.inMinutes == 1
        ? '1 minute ago'
        : '${age.inMinutes} minutes ago';
  }
  if (age.inHours < 24) {
    return age.inHours == 1 ? '1 hour ago' : '${age.inHours} hours ago';
  }
  return age.inDays == 1 ? '1 day ago' : '${age.inDays} days ago';
}

/// A circle member's marker — the unified teardrop (see the library doc).
class MemberMarker extends StatefulWidget {
  /// Creates a member marker.
  const MemberMarker({
    required this.initials,
    required this.publicKey,
    required this.fillColor,
    required this.haloColor,
    required this.diameter,
    required this.nubLength,
    required this.angle,
    required this.offScreen,
    super.key,
    this.displayName,
    this.lastSeen,
    this.onTap,
    this.tapOffset = Offset.zero,
  });

  /// Initials to display (1-2 characters).
  final String initials;

  /// Member pubkey hex — keys the teardrop painter for tests and seeds the hue.
  final String publicKey;

  /// Local contact display name, used for the off-screen semantics label.
  final String? displayName;

  /// Body colour (the member's per-pubkey hue).
  final Color fillColor;

  /// Halo (outline) colour, normally `colorScheme.surface`.
  final Color haloColor;

  /// Current bubble diameter in logical pixels.
  final double diameter;

  /// Current outward tail length (`0` ⇒ a plain circle on the member's spot).
  final double nubLength;

  /// Direction, in radians, from the bubble centre toward the member's true
  /// location (screen space: `+x` east / `+y` south). Orients the tail.
  final double angle;

  /// Whether the member is truly off-screen — drives the semantics label, the
  /// age-pill gate, and (with [nubLength]) the visual nub.
  final bool offScreen;

  /// Timestamp the location was originally recorded — drives the age pill and
  /// the "last seen" clause for on-screen markers.
  final DateTime? lastSeen;

  /// Callback when the marker is tapped. Null ⇒ not interactive (taps fall
  /// through to the map).
  final VoidCallback? onTap;

  /// Offset, relative to the bubble centre, at which to place the (invisible)
  /// tap target. The layer biases this inward for off-screen markers so the
  /// full 48dp target stays on-screen while the visible bubble hugs the edge.
  final Offset tapOffset;

  /// Duration of the appear (fade + scale) transition.
  static const Duration _appearDuration = Duration(milliseconds: 180);

  /// The square paint-box size for a bubble of [diameter] — large enough that
  /// the tail, halo, and shadow never clip. The layer positions the marker
  /// centred on its bubble point using this, so the two stay in agreement.
  static double footprintFor(double diameter) =>
      math.max(diameter + 24, 48).toDouble();

  @override
  State<MemberMarker> createState() => _MemberMarkerState();
}

class _MemberMarkerState extends State<MemberMarker>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final CurvedAnimation _fade;
  late final Animation<double> _scale;

  bool _reduceMotion = false;
  bool _appearStarted = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: MemberMarker._appearDuration,
      vsync: this,
    );
    _fade = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _scale = Tween<double>(begin: 0.8, end: 1).animate(_fade);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (!_appearStarted) {
      _appearStarted = true;
      _controller.value = _reduceMotion ? 1.0 : 0.0;
      if (!_reduceMotion) _controller.forward();
    }
  }

  @override
  void dispose() {
    _fade.dispose();
    _controller.dispose();
    super.dispose();
  }

  /// 1-2 initials; a single initial while small, the second once the bubble has
  /// room. Matches the on-map full-size marker, so no glyph pop at hand-off.
  String _glyph() => markerGlyph(widget.initials, widget.diameter);

  String _semanticsLabel(String? semanticsAge) {
    if (widget.offScreen) {
      return offScreenSemanticsLabel(widget.displayName, widget.angle);
    }
    // Prefer the friendly name on-screen too (parity with the off-screen
    // label), falling back to the initials when no name is known.
    final trimmed = widget.displayName?.trim();
    final name = (trimmed != null && trimmed.isNotEmpty)
        ? trimmed
        : widget.initials;
    return semanticsAge != null
        ? '$name member marker, last seen $semanticsAge'
        : '$name member marker';
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final footprint = MemberMarker.footprintFor(widget.diameter);
    final tapSize = math.max(widget.diameter, kMinTapTarget);
    final textScaler = MediaQuery.textScalerOf(
      context,
    ).clamp(maxScaleFactor: 1.3);

    final age = widget.lastSeen != null
        ? DateTime.now().difference(widget.lastSeen!)
        : null;
    // Show the age pill for any on-screen (full-size) marker, including one
    // near an edge with a short tail; hide it only once the bubble shrinks
    // off-screen, where age detail is noise on a direction hint.
    final showPill = !widget.offScreen;
    final pillLabel = (showPill && age != null) ? _formatAge(age) : null;
    final semanticsAge = age != null ? _formatAgeForSemantics(age) : null;
    // Place the pill opposite the tail's vertical direction so a near-edge
    // marker's tail and pill never collide.
    final pillBelow = widget.nubLength >= 0.5 && math.sin(widget.angle) < 0;

    final visual = IgnorePointer(
      child: CustomPaint(
        key: WidgetKeys.markerTeardrop(widget.publicKey),
        size: Size.square(footprint),
        painter: _MarkerTeardropPainter(
          diameter: widget.diameter,
          nubLength: widget.nubLength,
          angle: widget.angle,
          fillColor: widget.fillColor,
          haloColor: widget.haloColor,
          glyph: _glyph(),
          glyphColor: onAvatarColor(widget.fillColor),
          textScaler: textScaler,
        ),
      ),
    );

    return Semantics(
      label: _semanticsLabel(semanticsAge),
      button: widget.onTap != null,
      excludeSemantics: true,
      onTap: widget.onTap,
      child: SizedBox(
        width: footprint,
        height: footprint,
        // Clip.none so the age pill and an inward-biased tap target are not
        // clipped by the footprint box (the layer clips the whole overlay to
        // the viewport instead).
        child: Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: [
            if (_reduceMotion)
              visual
            else
              FadeTransition(
                opacity: _fade,
                child: ScaleTransition(scale: _scale, child: visual),
              ),
            if (pillLabel != null)
              _AgePill(
                label: pillLabel,
                diameter: widget.diameter,
                below: pillBelow,
                colorScheme: colorScheme,
                textScaler: textScaler,
              ),
            if (widget.onTap != null)
              Transform.translate(
                offset: widget.tapOffset,
                child: SizedBox(
                  width: tapSize,
                  height: tapSize,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: widget.onTap,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The age pill anchored to the head's top corner (top by default, bottom when
/// the tail points up so the two never collide).
class _AgePill extends StatelessWidget {
  const _AgePill({
    required this.label,
    required this.diameter,
    required this.below,
    required this.colorScheme,
    required this.textScaler,
  });

  final String label;
  final double diameter;
  final bool below;
  final ColorScheme colorScheme;
  final TextScaler textScaler;

  @override
  Widget build(BuildContext context) {
    // Sit just outside the head's right corner (diameter/2 ≈ head radius).
    final r = diameter / 2;
    return Transform.translate(
      offset: Offset(r * 0.5, below ? r * 0.7 : -r * 0.7),
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
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Text(
          label,
          textScaler: textScaler,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: colorScheme.onSurfaceVariant,
            height: 1,
          ),
        ),
      ),
    );
  }
}

/// Paints the unified teardrop pointing along [angle].
///
/// The shape is a circle (the head) with two tangent lines meeting at a tip
/// [nubLength] beyond the rim; it degenerates to a plain circle when
/// [nubLength] is negligible (the on-screen state). Three paint passes —
/// shadow, halo stroke, body fill — for legibility over any basemap.
class _MarkerTeardropPainter extends CustomPainter {
  const _MarkerTeardropPainter({
    required this.diameter,
    required this.nubLength,
    required this.angle,
    required this.fillColor,
    required this.haloColor,
    required this.glyph,
    required this.glyphColor,
    required this.textScaler,
  });

  final double diameter;
  final double nubLength;
  final double angle;
  final Color fillColor;
  final Color haloColor;
  final String glyph;
  final Color glyphColor;
  final TextScaler textScaler;

  @override
  void paint(Canvas canvas, Size size) {
    final radius = diameter / 2;
    final path = _teardropPath(radius, nubLength);
    final center = Offset(size.width / 2, size.height / 2);

    // Lighten the halo and shadow as the bubble shrinks so a far edge droplet
    // reads daintier than a full on-screen bubble (which keeps 3dp / 2dp).
    final scale = (diameter / kDropletFullDiameter).clamp(0.0, 1.0);
    final haloWidth = 1.5 + 1.5 * scale;
    final elevation = 1.0 + 1.0 * scale;

    canvas
      ..save()
      ..translate(center.dx, center.dy)
      ..rotate(angle)
      // 1. Soft drop shadow lifts the bubble off busy tiles.
      ..drawShadow(path, Colors.black.withValues(alpha: 0.4), elevation, false)
      // 2. Halo stroke keeps a crisp edge over dark/saturated tiles.
      ..drawPath(
        path,
        Paint()
          ..color = haloColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = haloWidth
          ..strokeJoin = StrokeJoin.round
          ..isAntiAlias = true,
      )
      // 3. Body fill in the member's hue.
      ..drawPath(
        path,
        Paint()
          ..color = fillColor
          ..style = PaintingStyle.fill
          ..isAntiAlias = true,
      )
      ..restore();

    // Initials are drawn upright (never rotated) at the head centre.
    if (glyph.isNotEmpty) {
      final tp = TextPainter(
        text: TextSpan(
          text: glyph,
          style: TextStyle(
            color: glyphColor,
            fontSize: diameter * 0.4,
            fontWeight: FontWeight.w600,
            height: 1,
          ),
        ),
        textDirection: TextDirection.ltr,
        textScaler: textScaler,
      )..layout();
      tp.paint(
        canvas,
        Offset(center.dx - tp.width / 2, center.dy - tp.height / 2),
      );
    }
  }

  @override
  bool shouldRepaint(_MarkerTeardropPainter old) =>
      old.diameter != diameter ||
      old.nubLength != nubLength ||
      old.angle != angle ||
      old.fillColor != fillColor ||
      old.haloColor != haloColor ||
      old.glyph != glyph ||
      old.glyphColor != glyphColor ||
      old.textScaler != textScaler;
}

/// Builds a teardrop [Path] in local space — a circle of [radius] centred at
/// the origin with a tip [nub] pixels along `+x`. Degenerates to a plain circle
/// when [nub] is negligible.
Path _teardropPath(double radius, double nub) {
  final path = Path();
  if (nub <= 0.5) {
    return path..addOval(Rect.fromCircle(center: Offset.zero, radius: radius));
  }
  final tipDistance = radius + nub;
  // Tangent point angle: cos(theta) = radius / distance-to-tip.
  final theta = math.acos((radius / tipDistance).clamp(-1.0, 1.0));
  final tangent = Offset(radius * math.cos(theta), radius * math.sin(theta));
  return path
    ..moveTo(tipDistance, 0)
    ..lineTo(tangent.dx, tangent.dy)
    // Arc the long way around the back of the circle to the mirrored tangent
    // point, leaving the front wedge for the two tangent lines and the tip.
    ..arcTo(
      Rect.fromCircle(center: Offset.zero, radius: radius),
      theta,
      2 * math.pi - 2 * theta,
      false,
    )
    // close() draws the second tangent line back to the tip and joins the
    // stroke cleanly there.
    ..close();
}
