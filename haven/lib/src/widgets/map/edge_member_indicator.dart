/// Off-screen circle-member edge indicator — the "droplet".
///
/// A small teardrop clamped to the viewport border that points toward a circle
/// member who is currently off-screen. Far away it is tiny and welded to the
/// edge (its nub merges into the border); as the user pans toward the member
/// it grows, the nub retracts, and at the viewport edge it reaches the full
/// marker size so the on-map [MemberMarker] can take over seamlessly.
///
/// Position, size ([diameter]), [morph], and [angle] are recomputed every frame
/// by the layer directly from the map camera, so the motion tracks the user's
/// drag exactly. Only the brief appear transition is animated here.
library;

import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/utils/edge_indicator_geometry.dart' show kMinTapTarget;
import 'package:haven/src/widgets/map/marker_metrics.dart';

/// A droplet pin marking an off-screen member's direction at the screen edge.
class EdgeMemberIndicator extends StatefulWidget {
  /// Creates an [EdgeMemberIndicator].
  const EdgeMemberIndicator({
    required this.initials,
    required this.publicKey,
    required this.fillColor,
    required this.haloColor,
    required this.diameter,
    required this.morph,
    required this.angle,
    required this.semanticsLabel,
    required this.onTap,
    this.tapOffset = Offset.zero,
    super.key,
  });

  /// Member initials (1–2 characters). A single initial is shown while small;
  /// the second appears once the droplet is large enough to fit it.
  final String initials;

  /// Member pubkey hex — used to key the droplet's painter for tests.
  final String publicKey;

  /// Body colour (the member's per-pubkey hue).
  final Color fillColor;

  /// Halo (outline) colour, normally `colorScheme.surface`.
  final Color haloColor;

  /// Current droplet diameter in logical pixels.
  final double diameter;

  /// Morph parameter in `[0, 1]`: `1` = full detached bubble (at the edge
  /// hand-off), `0` = tiny droplet welded to the border (far away).
  final double morph;

  /// Direction, in radians, from the screen's optical centre toward the
  /// member (screen space, `+x` east / `+y` south). Orients the nub.
  final double angle;

  /// Screen-reader label, e.g. "Jane is off-screen to the north-east".
  final String semanticsLabel;

  /// Called when the droplet is tapped (recenters the map on the member).
  final VoidCallback onTap;

  /// Offset, relative to the droplet head, at which to place the (invisible)
  /// tap target. The layer biases this inward near a screen edge so the full
  /// 48dp target stays on-screen and reachable while the visible droplet
  /// remains welded to the border.
  final Offset tapOffset;

  /// Duration of the appear (fade + scale) transition.
  static const Duration _appearDuration = Duration(milliseconds: 180);

  /// The square paint-box size for a droplet of [diameter] — large enough that
  /// the nub, halo, and shadow never clip. The layer uses this to position the
  /// indicator centred on its head point, so both stay in agreement.
  static double footprintFor(double diameter) =>
      math.max(diameter + 24, 48).toDouble();

  @override
  State<EdgeMemberIndicator> createState() => _EdgeMemberIndicatorState();
}

class _EdgeMemberIndicatorState extends State<EdgeMemberIndicator>
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
      duration: EdgeMemberIndicator._appearDuration,
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
      // Reduce Motion: skip the appear transition and show at rest.
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

  String _glyph() {
    if (widget.initials.isEmpty) return '';
    final upper = widget.initials.toUpperCase();
    // Always keep at least one initial; show the second only when there is
    // room (the droplet has grown past the tiny far-range size).
    final count = widget.diameter >= 40 ? math.min(2, upper.length) : 1;
    return upper.substring(0, count);
  }

  @override
  Widget build(BuildContext context) {
    // The paint box is larger than the droplet so the nub, halo, and shadow
    // never clip; the tap target is the droplet itself (kept >= 48dp) so the
    // surrounding transparent area still pans the map.
    final footprint = EdgeMemberIndicator.footprintFor(widget.diameter);
    final tapSize = math.max(widget.diameter, kMinTapTarget);
    final textScaler = MediaQuery.textScalerOf(
      context,
    ).clamp(maxScaleFactor: 1.3);

    final visual = IgnorePointer(
      child: CustomPaint(
        key: WidgetKeys.edgeIndicatorDroplet(widget.publicKey),
        size: Size.square(footprint),
        painter: _EdgeDropletPainter(
          diameter: widget.diameter,
          morph: widget.morph,
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
      label: widget.semanticsLabel,
      button: true,
      excludeSemantics: true,
      onTap: widget.onTap,
      child: SizedBox(
        width: footprint,
        height: footprint,
        // Clip.none so the inward-biased tap target (near a screen edge) is not
        // clipped by the footprint box.
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
            // Invisible 48dp+ tap target, shifted inward by [tapOffset] so it
            // stays fully on-screen even when the droplet is at the edge.
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

/// Paints a teardrop pin pointing along [angle].
///
/// The shape is a circle (the head) with two tangent lines meeting at a tip
/// [_maxNub] pixels beyond the rim when far ([morph] 0); at the hand-off
/// ([morph] 1) the tip retracts and it becomes a plain circle that matches the
/// on-map marker. Drawn in three passes — shadow, halo stroke, body fill —
/// mirroring the marker's tail painter so the two read as one visual language.
class _EdgeDropletPainter extends CustomPainter {
  const _EdgeDropletPainter({
    required this.diameter,
    required this.morph,
    required this.angle,
    required this.fillColor,
    required this.haloColor,
    required this.glyph,
    required this.glyphColor,
    required this.textScaler,
  });

  final double diameter;
  final double morph;
  final double angle;
  final Color fillColor;
  final Color haloColor;
  final String glyph;
  final Color glyphColor;
  final TextScaler textScaler;

  static const double _haloWidth = 3;

  /// Maximum length of the outward nub (at [morph] 0).
  static const double _maxNub = 7;

  @override
  void paint(Canvas canvas, Size size) {
    final radius = diameter / 2;
    final nub = (_maxNub * (1 - morph)).clamp(0.0, _maxNub);
    final path = _teardropPath(radius, nub);
    final center = Offset(size.width / 2, size.height / 2);

    canvas
      ..save()
      ..translate(center.dx, center.dy)
      ..rotate(angle)
      // 1. Soft drop shadow lifts the droplet off busy tiles.
      ..drawShadow(
        path,
        Colors.black.withValues(alpha: 0.4),
        lerpDouble(1, 2, morph)!,
        false,
      )
      // 2. Halo stroke keeps a crisp edge over dark/saturated tiles.
      ..drawPath(
        path,
        Paint()
          ..color = haloColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = _haloWidth
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
  bool shouldRepaint(_EdgeDropletPainter old) =>
      old.diameter != diameter ||
      old.morph != morph ||
      old.angle != angle ||
      old.fillColor != fillColor ||
      old.haloColor != haloColor ||
      old.glyph != glyph ||
      old.glyphColor != glyphColor;
}

/// Builds a teardrop [Path] in local space — a circle of [radius] centred at
/// the origin with a tip [nub] pixels along `+x`. Degenerates to a plain
/// circle when [nub] is negligible.
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
    // stroke cleanly there (a plain lineTo would leave open stroke caps).
    ..close();
}
