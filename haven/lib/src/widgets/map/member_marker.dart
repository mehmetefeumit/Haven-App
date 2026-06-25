/// Unified circle-member map marker for Haven.
///
/// One continuous teardrop: a plain circular avatar bubble centred on the
/// member while comfortably in view, growing a joined tail (pointing at the
/// member's true location) as they near or leave the viewport edge, and
/// shrinking to a tiny edge droplet welded to the border when far off-screen.
/// Position, `diameter`, `nubLength`, and `angle` are recomputed every frame
/// by the layer directly from the map camera, so the motion tracks the user's
/// pan exactly; only the brief appear transition is animated here.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/utils/marker_geometry.dart'
    show kDropletFullDiameter, kMinTapTarget, offScreenSemanticsLabel;
import 'package:haven/src/widgets/map/marker_metrics.dart';

/// Formats a [Duration] into a compact age string for the visible pill.
///
/// Returns `null` for ages under one minute — fresh data reads as "no pill"
/// rather than "just now", which would be visual noise on the common case.
/// [l10n] is threaded in because this top-level helper has no [BuildContext].
String? _formatAge(AppLocalizations l10n, Duration age) {
  if (age.inMinutes < 1) return null;
  if (age.inMinutes < 60) return l10n.memberMarkerMinutesShort(age.inMinutes);
  if (age.inHours < 24) return l10n.memberMarkerHoursShort(age.inHours);
  return l10n.memberMarkerDaysShort(age.inDays);
}

/// Formats a [Duration] into an expanded age string for screen readers, so
/// VoiceOver/TalkBack read "5 minutes ago" rather than "five em".
/// [l10n] is threaded in because this top-level helper has no [BuildContext].
String? _formatAgeForSemantics(AppLocalizations l10n, Duration age) {
  if (age.inMinutes < 1) return null;
  if (age.inMinutes < 60) {
    return l10n.memberMarkerMinutesAgoSemantics(age.inMinutes);
  }
  if (age.inHours < 24) {
    return l10n.memberMarkerHoursAgoSemantics(age.inHours);
  }
  return l10n.memberMarkerDaysAgoSemantics(age.inDays);
}

/// A circle member's marker — the unified teardrop (see the library doc).
///
/// When a decoded [ui.Image] is available for the member (supplied by the
/// layer via [avatarImage]) it is clipped to the head circle and drawn with
/// cover-fit semantics, replacing the initials glyph.  The teardrop tail,
/// halo, shadow, age pill, and tap target are all unaffected; initials remain
/// the fallback when [avatarImage] is null.
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
    this.avatarImage,
    this.exiting = false,
    this.onExitComplete,
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

  /// Pre-decoded avatar image to paint inside the head circle, or `null` to
  /// show the initials glyph fallback.
  ///
  /// Must be decoded outside paint() (e.g. by [_AvatarLoader] in the layer).
  /// The owner retains the [ui.Image] lifetime — this widget neither disposes
  /// nor holds a reference past the current paint pass.
  final ui.Image? avatarImage;

  /// Whether this marker is leaving the map (e.g. the user switched to another
  /// circle). When this flips to `true` the marker plays the appear transition
  /// in reverse — the mirror of the fade/scale-in new markers get — then calls
  /// [onExitComplete] so the layer can remove it from the tree.
  final bool exiting;

  /// Called once the exit transition finishes, signalling the owning layer that
  /// it is safe to drop this marker. Only meaningful while [exiting] is `true`.
  final VoidCallback? onExitComplete;

  /// Duration of the appear/disappear (fade + scale) transition.
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
    _controller.addStatusListener(_onStatusChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (!_appearStarted) {
      _appearStarted = true;
      if (widget.exiting) {
        // Constructed already departing (no live frame to fade from, e.g. the
        // marker's keyed state was not reused). Snap hidden and let the layer
        // drop us on the next frame rather than animating from nothing.
        _controller.value = 0;
        _scheduleExitComplete();
        return;
      }
      _controller.value = _reduceMotion ? 1.0 : 0.0;
      if (!_reduceMotion) _controller.forward();
    }
  }

  @override
  void didUpdateWidget(MemberMarker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.exiting == oldWidget.exiting) return;
    if (widget.exiting) {
      // The member left the circle (e.g. a circle switch): play the appear
      // transition in reverse, then ask the layer to remove us.
      if (_reduceMotion) {
        _scheduleExitComplete();
      } else {
        // Driving the easeOut controller backwards samples the curve on a
        // falling t, which reads as an easeIn (accelerating) exit — the
        // Material-motion convention for a leaving element. Intentional: do
        // not "fix" this to a literal easeIn reverseCurve (double inversion).
        _controller.reverse();
      }
    } else if (!_reduceMotion) {
      // Re-joined mid-fade — reverse course and fade back in.
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.removeStatusListener(_onStatusChanged);
    _fade.dispose();
    _controller.dispose();
    super.dispose();
  }

  /// Fires [MemberMarker.onExitComplete] when the reverse transition settles at
  /// the dismissed (fully faded-out) end, signalling the layer to drop us.
  void _onStatusChanged(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && widget.exiting) {
      widget.onExitComplete?.call();
    }
  }

  /// Reports exit completion after the current frame, used when there is no
  /// transition to wait on (reduce-motion, or a marker born already exiting).
  void _scheduleExitComplete() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.exiting) widget.onExitComplete?.call();
    });
  }

  /// 1-2 initials; a single initial while small, the second once the bubble has
  /// room. Matches the on-map full-size marker, so no glyph pop at hand-off.
  String _glyph() => markerGlyph(widget.initials, widget.diameter);

  String _semanticsLabel(AppLocalizations l10n, String? semanticsAge) {
    if (widget.offScreen) {
      return offScreenSemanticsLabel(widget.displayName, widget.angle);
    }
    // Prefer the friendly name on-screen (parity with the off-screen label).
    // When no name is known use a GENERIC label — never the initials, which
    // can be a pubkey-derived fragment (Semantics must never speak a pubkey).
    final trimmed = widget.displayName?.trim();
    final hasName = trimmed != null && trimmed.isNotEmpty;
    final base = hasName
        ? l10n.memberMarkerNamedSemantics(trimmed)
        : l10n.memberMarkerGenericSemantics;
    return semanticsAge != null
        ? l10n.memberMarkerLastSeenSemantics(base, semanticsAge)
        : base;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
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
    final pillLabel = (showPill && age != null) ? _formatAge(l10n, age) : null;
    final semanticsAge = age != null
        ? _formatAgeForSemantics(l10n, age)
        : null;
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
          avatarImage: widget.avatarImage,
        ),
      ),
    );

    // A departing marker fades out as a sighted-only flourish: expose no label
    // and (via excludeSemantics) drop the age pill while exiting, so a screen
    // reader never announces a member who has already left the selected circle.
    // With an empty label and a null onTap (the layer makes exiting markers
    // non-interactive), this node carries no semantic content and is pruned.
    return Semantics(
      label: widget.exiting ? '' : _semanticsLabel(l10n, semanticsAge),
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
    this.avatarImage,
  });

  final double diameter;
  final double nubLength;
  final double angle;
  final Color fillColor;
  final Color haloColor;
  final String glyph;
  final Color glyphColor;
  final TextScaler textScaler;

  /// Pre-decoded avatar image; when non-null replaces the initials glyph in
  /// the head circle.  Never decoded inside paint() — supplied by the widget.
  final ui.Image? avatarImage;

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

    // Avatar image (when available) is drawn upright at the head centre,
    // clipped to a circle of radius [radius].  Initials are the fallback.
    final image = avatarImage;
    if (image != null) {
      // Clip to the head circle; the canvas is currently in identity transform
      // (we restored after the rotate block above), centred on the footprint.
      final headRect = Rect.fromCircle(center: center, radius: radius);
      final clipPath = Path()..addOval(headRect);
      canvas
        ..save()
        ..clipPath(clipPath);

      // Cover-fit: scale the source so the shortest dimension fills the circle.
      final sw = image.width.toDouble();
      final sh = image.height.toDouble();
      final scale = math.max(headRect.width / sw, headRect.height / sh);
      final dw = sw * scale;
      final dh = sh * scale;
      final dst = Rect.fromCenter(
        center: center,
        width: dw,
        height: dh,
      );

      canvas
        ..drawImageRect(
          image,
          Rect.fromLTWH(0, 0, sw, sh),
          dst,
          Paint()
            ..isAntiAlias = true
            ..filterQuality = FilterQuality.medium,
        )
        ..restore();
    } else if (glyph.isNotEmpty) {
      // Initials are drawn upright (never rotated) at the head centre.
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
      old.textScaler != textScaler ||
      !identical(old.avatarImage, avatarImage);
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
