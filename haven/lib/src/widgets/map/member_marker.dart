/// Unified circle-member map marker for Haven.
///
/// One continuous pin: an avatar head floating above the member's coordinate
/// on a short tail whose tip IS the coordinate, stretching and tilting as the
/// head is held at the viewport edge, and shrinking to a tiny edge droplet
/// welded to the border when far off-screen. Position, `diameter`,
/// `nubLength`, and `angle` are recomputed every frame by the layer directly
/// from the map camera, so the motion tracks the user's pan exactly; only the
/// brief appear transition is animated here.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/utils/marker_geometry.dart'
    show
        CompassDirection,
        compassDirectionFromAngle,
        kDropletFullDiameter,
        kDropletMaxTailOnScreen,
        kMinTapTarget;
import 'package:haven/src/utils/reduce_motion.dart';
import 'package:haven/src/widgets/map/marker_metrics.dart';

/// Maps a [CompassDirection] to its localized name for accessibility labels.
///
/// [l10n] is threaded in because this top-level helper has no [BuildContext].
/// The bearing itself is real geography (never mirrored under RTL); only the
/// word changes per language.
String _compassDirectionLabel(AppLocalizations l10n, CompassDirection d) {
  switch (d) {
    case CompassDirection.north:
      return l10n.compassNorth;
    case CompassDirection.northEast:
      return l10n.compassNorthEast;
    case CompassDirection.east:
      return l10n.compassEast;
    case CompassDirection.southEast:
      return l10n.compassSouthEast;
    case CompassDirection.south:
      return l10n.compassSouth;
    case CompassDirection.southWest:
      return l10n.compassSouthWest;
    case CompassDirection.west:
      return l10n.compassWest;
    case CompassDirection.northWest:
      return l10n.compassNorthWest;
  }
}

/// How stale a member's last fix must be before the marker is tagged with its
/// age.
///
/// Owner-chosen (2026-08-24), and it must stay clear of the publish cadence:
/// a healthy peer's freshest fix is already up to `kLocationPublishMaxInterval`
/// (168 s) old before propagation, so anything near that tags nearly every
/// marker nearly all the time and a pill that is always there stops reading as
/// "this one is behind". Both the visible pill and the spoken age share this
/// bound, so a screen reader never announces an age a sighted user cannot see.
///
/// Public because the members list gates its own "last seen" line on the SAME
/// bound (`CircleMemberTile`). Two independently-chosen thresholds would let
/// the roster and the map disagree about whether a member is stale, which is
/// worse than either answer on its own.
const Duration kMemberAgePillThreshold = Duration(minutes: 5);

/// Formats a [Duration] into a compact age string for the visible pill.
///
/// Returns `null` below [kMemberAgePillThreshold] — recent data reads as "no
/// pill" rather than "just now", which would be visual noise on the common
/// case.
/// [l10n] is threaded in because this top-level helper has no [BuildContext].
/// Minutes are the ONLY unit: a marker is evicted once it passes
/// `expiresAt + cacheEvictionGrace` (~45 minutes), so an hours- or days-old
/// marker cannot reach the screen. The former `<24h` and `>=24h` branches were
/// dead code, and their four l10n keys were dead strings in 13 locales.
/// Reporting minutes without an upper bound also degrades gracefully: if the
/// eviction window is ever widened, a stale marker reads "90m" rather than
/// silently losing its age pill.
///
/// The bound is a LOWER one too, and deliberately: a peer whose clock runs
/// fast stamps a fix in the future, whose age is negative, and that falls in
/// the same no-pill bucket as a fresh fix — never a "-59m" pill. Any branch
/// added here must stay BELOW this gate, or a future timestamp starts
/// rendering as a negative age (pinned in `member_marker_test.dart`).
String? _formatAge(AppLocalizations l10n, Duration age) {
  if (age < kMemberAgePillThreshold) return null;
  return l10n.memberMarkerMinutesShort(age.inMinutes);
}

/// Formats a [Duration] into an expanded age string for screen readers, so
/// VoiceOver/TalkBack read "5 minutes ago" rather than "five em".
/// [l10n] is threaded in because this top-level helper has no [BuildContext].
/// Minutes-only for the same reason as [_formatAge] — see the note there.
String? _formatAgeForSemantics(AppLocalizations l10n, Duration age) {
  if (age < kMemberAgePillThreshold) return null;
  return l10n.memberMarkerMinutesAgoSemantics(age.inMinutes);
}

/// The hairline outside a marker's white ring, shared with the own dot. It
/// holds 3:1 against the pale default basemap, where the ring cannot.
const Color kMarkerKeyline = Color(0x73000000);

/// A circle member's marker — the unified pin (see the library doc).
///
/// When a decoded [ui.Image] is available for the member (supplied by the
/// layer via [avatarImage]) it is clipped to the head circle and drawn with
/// cover-fit semantics, replacing the initials glyph.  The tail, ring,
/// shadow, age pill, and tap target are all unaffected; initials remain the
/// fallback when [avatarImage] is null.
class MemberMarker extends StatefulWidget {
  /// Creates a member marker.
  const MemberMarker({
    required this.initials,
    required this.publicKey,
    required this.diameter,
    required this.nubLength,
    required this.angle,
    required this.bearing,
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

  /// Member pubkey hex — keys the painter for tests and selects the palette.
  final String publicKey;

  /// Local contact display name, used for the off-screen semantics label.
  final String? displayName;

  /// Current bubble diameter in logical pixels.
  final double diameter;

  /// Current tail length, measured from the rim (`0` ⇒ a plain circle).
  final double nubLength;

  /// Direction, in radians, from the bubble centre toward the member's true
  /// location (screen space: `+x` east / `+y` south). Orients the tail only.
  final double angle;

  /// Direction, in radians, of the member's overshoot past the viewport (`0`
  /// on-screen). Drives the spoken compass word: the tail of a member due east
  /// just past the edge leans south-east, so [angle] would misreport it.
  final double bearing;

  /// Whether the member is truly off-screen — drives the semantics label and
  /// the age-pill gate.
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
  /// the longest tail (reach 22 from the rim), ring, keyline and shadow never
  /// clip. The layer positions the marker centred on its head using this, so
  /// the two stay in agreement.
  static double footprintFor(double diameter) =>
      math.max(diameter + 2 * kDropletMaxTailOnScreen + 24, kMinTapTarget);

  @override
  State<MemberMarker> createState() => _MemberMarkerState();
}

class _MemberMarkerState extends State<MemberMarker>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final CurvedAnimation _fade;
  late final Animation<double> _scale;
  bool _pressed = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: MemberMarker._appearDuration,
      // The fade is the one cue reduce motion still gets, so the OS's
      // disable-animations flag must not shrink it to a single frame.
      animationBehavior: AnimationBehavior.preserve,
      vsync: this,
    );
    _fade = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _scale = Tween<double>(begin: 0.8, end: 1).animate(_fade);
    _controller.addStatusListener(_onStatusChanged);
    if (widget.exiting) {
      // Constructed already departing (no live frame to fade from, e.g. the
      // marker's keyed state was not reused). Stay hidden and let the layer
      // drop us on the next frame rather than animating from nothing.
      _scheduleExitComplete();
    } else {
      _controller.forward();
    }
  }

  @override
  void didUpdateWidget(MemberMarker oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Without a detector there is no `onTapCancel`, so the press would stick.
    if (widget.onTap == null && _pressed) _pressed = false;
    if (widget.exiting == oldWidget.exiting) return;
    if (widget.exiting) {
      // The member left the circle (e.g. a circle switch): play the appear
      // transition in reverse, then ask the layer to remove us. Driving the
      // easeOut controller backwards samples the curve on a falling t, which
      // reads as an easeIn (accelerating) exit — the Material-motion
      // convention for a leaving element. Intentional: do not "fix" this to a
      // literal easeIn reverseCurve (double inversion).
      _controller.reverse();
    } else {
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

  /// Reports exit completion after the current frame, for a marker born
  /// already exiting, which has no transition to wait on.
  void _scheduleExitComplete() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.exiting) widget.onExitComplete?.call();
    });
  }

  void _setPressed(bool pressed) {
    if (_pressed != pressed) setState(() => _pressed = pressed);
  }

  /// The off-screen path's haptic lives in `focusMapOnPoint`; one per tap.
  void _handleTap() {
    _setPressed(false);
    if (!widget.offScreen) unawaited(HapticFeedback.lightImpact());
    widget.onTap?.call();
  }

  /// 1-2 initials; a single initial while small, the second once the bubble has
  /// room. Matches the on-map full-size marker, so no glyph pop at hand-off.
  String _glyph() => markerGlyph(widget.initials, widget.diameter);

  String _semanticsLabel(AppLocalizations l10n, String? semanticsAge) {
    if (widget.offScreen) {
      // The compass bearing is real geography and is never mirrored under RTL;
      // only the direction word is localized. It comes from the overshoot
      // bearing, never the tail angle (see [MemberMarker.bearing]).
      final direction = _compassDirectionLabel(
        l10n,
        compassDirectionFromAngle(widget.bearing),
      );
      final offName = widget.displayName?.trim();
      return (offName != null && offName.isNotEmpty)
          ? l10n.memberMarkerOffScreenSemantics(offName, direction)
          : l10n.memberMarkerOffScreenGenericSemantics(direction);
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

    final paintedVisual = IgnorePointer(
      child: CustomPaint(
        key: WidgetKeys.markerTeardrop(widget.publicKey),
        size: Size.square(footprint),
        painter: _MarkerTeardropPainter(
          diameter: widget.diameter,
          nubLength: widget.nubLength,
          angle: widget.angle,
          palette: avatarPaletteFor(widget.publicKey),
          glyph: _glyph(),
          textScaler: textScaler,
          avatarImage: widget.avatarImage,
        ),
      ),
    );

    // Appear/exit/press scale about the tip, the one point that must not move
    // off the member's coordinate.
    final reach = widget.diameter / 2 + widget.nubLength;
    final tip = Offset(
      footprint / 2 + reach * math.cos(widget.angle),
      footprint / 2 + reach * math.sin(widget.angle),
    );
    final tipAlignment = Alignment(
      tip.dx / footprint * 2 - 1,
      tip.dy / footprint * 2 - 1,
    );
    final visual = widget.onTap == null
        ? paintedVisual
        : AnimatedScale(
            scale: _pressed ? 0.94 : 1,
            // Reduce motion forbids movement, not the press state.
            duration: reduceMotionOf(context)
                ? Duration.zero
                : Duration(milliseconds: _pressed ? 100 : 150),
            curve: Curves.easeOut,
            alignment: tipAlignment,
            child: paintedVisual,
          );
    // Fade-only under reduce motion: it forbids movement, not opacity.
    final Widget transition = reduceMotionOf(context)
        ? FadeTransition(opacity: _fade, child: visual)
        : FadeTransition(
            opacity: _fade,
            child: ScaleTransition(
              scale: _scale,
              alignment: tipAlignment,
              child: visual,
            ),
          );

    // A departing marker fades out as a sighted-only flourish: expose no label
    // while exiting, so a screen reader never announces a member who has
    // already left the selected circle. With an empty label and a null onTap
    // (the layer makes exiting markers non-interactive), this node carries no
    // semantic content and is pruned.
    return SizedBox(
      width: footprint,
      height: footprint,
      // Clip.none so the age pill and an inward-biased tap target are not
      // clipped by the footprint box (the layer clips the whole overlay to
      // the safe rect instead).
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          transition,
          if (pillLabel != null)
            ExcludeSemantics(
              child: _AgePill(
                label: pillLabel,
                diameter: widget.diameter,
                below: pillBelow,
                textScaler: textScaler,
              ),
            ),
          // The semantics node is the tap-sized box, not the 120 px footprint,
          // so a screen reader's focus ring matches what a finger can hit.
          Transform.translate(
            offset: widget.tapOffset,
            child: Semantics(
              key: WidgetKeys.markerSemantics(widget.publicKey),
              container: true,
              label: widget.exiting ? '' : _semanticsLabel(l10n, semanticsAge),
              button: widget.onTap != null,
              excludeSemantics: true,
              onTap: widget.onTap == null ? null : _handleTap,
              child: SizedBox(
                width: tapSize,
                height: tapSize,
                child: widget.onTap == null
                    ? null
                    : GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTapDown: (_) => _setPressed(true),
                        onTapUp: (_) => _setPressed(false),
                        onTapCancel: () => _setPressed(false),
                        onTap: _handleTap,
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The age pill anchored to the head's top corner (top by default, bottom when
/// the tail points up so the two never collide).
///
/// Constant white ink, not theme colours: the basemap is chosen independently
/// of the theme, so a `surface`-coloured pill vanished on a dark basemap.
class _AgePill extends StatelessWidget {
  const _AgePill({
    required this.label,
    required this.diameter,
    required this.below,
    required this.textScaler,
  });

  final String label;
  final double diameter;
  final bool below;
  final TextScaler textScaler;

  @override
  Widget build(BuildContext context) {
    // On the head's frame rather than its face, and far enough in that the pill
    // stays inside the safe rect when the head is held at the right inset.
    final r = diameter / 2;
    return Transform.translate(
      offset: Offset(r * 0.55, below ? r * 0.8 : -r * 0.8),
      child: Container(
        decoration: ShapeDecoration(
          color: const Color(0xFFFFFFFF),
          shape: const StadiumBorder(),
          shadows: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.25),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Text(
          label,
          textScaler: textScaler,
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: Color(0xFF525252),
            fontFeatures: [ui.FontFeature.tabularFigures()],
            height: 1,
          ),
        ),
      ),
    );
  }
}

/// Ring stroke width for a head of [diameter]: 3 px at full size, easing to
/// 1.5 px at the far bead.
@visibleForTesting
double markerRingWidthFor(double diameter) =>
    1.5 + 1.5 * (diameter / kDropletFullDiameter).clamp(0.0, 1.0);

/// Paints the pin pointing along [angle].
///
/// The shape is a circle (the head) with two concave flanks meeting at a tip
/// [nubLength] beyond the rim; it degenerates to a plain circle when
/// [nubLength] is negligible. The canvas stays upright and the PATH is rotated
/// instead, so the shadow always falls from the top of the screen and the
/// gradient never turns with the tail.
class _MarkerTeardropPainter extends CustomPainter {
  const _MarkerTeardropPainter({
    required this.diameter,
    required this.nubLength,
    required this.angle,
    required this.palette,
    required this.glyph,
    required this.textScaler,
    this.avatarImage,
  });

  final double diameter;
  final double nubLength;
  final double angle;
  final AvatarPaletteEntry palette;
  final String glyph;
  final TextScaler textScaler;

  /// Pre-decoded avatar image; when non-null replaces the initials glyph in
  /// the head circle.  Never decoded inside paint() — supplied by the widget.
  final ui.Image? avatarImage;

  @override
  void paint(Canvas canvas, Size size) {
    final radius = diameter / 2;
    final center = Offset(size.width / 2, size.height / 2);
    final scale = (diameter / kDropletFullDiameter).clamp(0.0, 1.0);
    final ringWidth = markerRingWidthFor(diameter);
    final elevation = 1.0 + 1.0 * scale;
    final headRect = Rect.fromCircle(center: center, radius: radius);

    final shape = teardropPath(radius, nubLength, ringWidth / 2).transform(
      (Matrix4.translationValues(center.dx, center.dy, 0)..rotateZ(angle))
          .storage,
    );

    canvas
      // Soft drop shadow lifts the pin off busy tiles.
      ..drawShadow(shape, Colors.black.withValues(alpha: 0.4), elevation, false)
      // A hairline just outside the white ring keeps it, and the tip, readable
      // on a pale basemap and on white roads.
      ..drawPath(
        shape,
        Paint()
          ..color = kMarkerKeyline
          ..style = PaintingStyle.stroke
          ..strokeWidth = ringWidth + 2
          ..strokeJoin = StrokeJoin.round
          ..isAntiAlias = true,
      )
      // The gradient is measured in screen space, so it never turns with the
      // tail.
      ..drawPath(
        shape,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [palette.top, palette.bottom],
          ).createShader(headRect)
          ..style = PaintingStyle.fill
          ..isAntiAlias = true,
      );

    // Avatar (when available) is drawn upright, clipped to the ring's
    // centreline so no hairline of body colour shows inside the ring.
    final image = avatarImage;
    if (image != null) {
      canvas
        ..save()
        ..clipPath(Path()..addOval(headRect));

      // Cover-fit: scale the source so the shortest dimension fills the circle.
      final sw = image.width.toDouble();
      final sh = image.height.toDouble();
      final fit = math.max(headRect.width / sw, headRect.height / sh);
      canvas
        ..drawImageRect(
          image,
          Rect.fromLTWH(0, 0, sw, sh),
          Rect.fromCenter(center: center, width: sw * fit, height: sh * fit),
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
            color: kAvatarInitialsColor,
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

    // The ring goes last: it covers the clip seam and the avatar's edge.
    canvas.drawPath(
      shape,
      Paint()
        ..color = const Color(0xFFFFFFFF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = ringWidth
        ..strokeJoin = StrokeJoin.round
        ..isAntiAlias = true,
    );
  }

  @override
  bool shouldRepaint(_MarkerTeardropPainter old) =>
      old.diameter != diameter ||
      old.nubLength != nubLength ||
      old.angle != angle ||
      old.palette.top != palette.top ||
      old.palette.bottom != palette.bottom ||
      old.glyph != glyph ||
      old.textScaler != textScaler ||
      !identical(old.avatarImage, avatarImage);
}

/// Builds the pin outline in local space — a circle of [radius] centred at the
/// origin with its apex [nub] pixels past the rim along `+x`, pulled back by
/// [apexInset] so a ring stroked on the outline reaches `radius + nub` exactly.
///
/// The flanks are concave: a quadratic from each tangent point whose control
/// sits 30% of the way to the apex and 35% as far from the axis as the tangent
/// point, giving a ~30° apex half-angle at the on-screen tail rather than the
/// stubby ~46° of straight tangents. It is a plain circle when [nub] is
/// negligible, or when the inset leaves no tail to draw.
@visibleForTesting
Path teardropPath(double radius, double nub, double apexInset) {
  final apexX = radius + nub - apexInset;
  if (nub <= 0.5 || apexX - radius <= 0.5) {
    return Path()
      ..addOval(Rect.fromCircle(center: Offset.zero, radius: radius));
  }
  // Tangent point angle: cos(theta) = radius / distance-to-apex.
  final theta = math.acos((radius / apexX).clamp(-1.0, 1.0));
  final tangent = Offset(radius * math.cos(theta), radius * math.sin(theta));
  final control = Offset(
    tangent.dx + 0.3 * (apexX - tangent.dx),
    tangent.dy * 0.35,
  );
  return Path()
    ..moveTo(apexX, 0)
    ..quadraticBezierTo(control.dx, control.dy, tangent.dx, tangent.dy)
    // Arc the long way around the back of the circle to the mirrored tangent
    // point, leaving the front wedge for the two flanks and the tip.
    ..arcTo(
      Rect.fromCircle(center: Offset.zero, radius: radius),
      theta,
      2 * math.pi - 2 * theta,
      false,
    )
    ..quadraticBezierTo(control.dx, -control.dy, apexX, 0)
    ..close();
}
