/// Pure screen-space geometry for off-screen circle-member edge indicators
/// ("droplets").
///
/// Every function here operates on plain [Offset]/[Rect]/[Size] values in
/// logical pixels, with no dependency on Flutter widgets or `flutter_map`, so
/// the whole module is unit-testable without a live map. The map layer
/// projects each member's location to a screen point and supplies it here;
/// this module decides whether the member is off-screen, where its droplet
/// clamps to the viewport edge, how large it is, and which way it points.
library;

import 'dart:math' as math;
import 'dart:ui';

/// Diameter, in logical pixels, of a droplet at the instant it hands off to a
/// full on-map marker.
///
/// This MUST equal the marker's ring diameter (`kRingDiameter` in
/// `marker_metrics.dart`) so the swap is seamless; a test guards the match.
const double kDropletFullDiameter = 52;

/// Radius of a droplet at full (hand-off) size.
const double kDropletFullRadius = kDropletFullDiameter / 2;

/// Smallest droplet diameter, used when a member is far off-screen. Kept large
/// enough to still carry a single legible initial.
const double kDropletMinDiameter = 20;

/// Gap, in logical pixels, kept between a droplet's outer rim and the safe
/// viewport edge at every size — so a tiny droplet still "merges" with the
/// border while a full-size one stays wholly on-screen.
const double kDropletEdgeMargin = 4;

/// Minimum interactive target size (Material 48dp / WCAG 2.5.5) for a droplet,
/// honoured even when the droplet itself is far smaller.
const double kMinTapTarget = 48;

/// Clamps [v] to the range spanned by [a] and [b] regardless of their order.
///
/// `num.clamp` asserts `lower <= upper`; this tolerates inverted bounds (which
/// can arise from a degenerate viewport) instead of throwing.
double _clampSafe(double v, double a, double b) =>
    v.clamp(math.min(a, b), math.max(a, b));

/// The pre-computed viewport rectangles a layer needs to project members.
class EdgeViewport {
  /// Creates an [EdgeViewport].
  const EdgeViewport({
    required this.safeRect,
    required this.handoffRect,
    required this.opticalCenter,
    required this.falloff,
  });

  /// The usable map area: the full viewport minus the top safe-area inset and
  /// the bottom inset occluded by the collapsed bottom sheet.
  final Rect safeRect;

  /// Members whose avatar-centre falls inside this rectangle are drawn as
  /// normal markers; those outside become edge droplets. Inset from
  /// [safeRect] so a full-size droplet (and the materialising marker) is
  /// wholly on-screen at the hand-off.
  final Rect handoffRect;

  /// The visual centre of the usable area (biased above the bottom sheet) from
  /// which member directions are measured.
  final Offset opticalCenter;

  /// Distance, in logical pixels, over which a droplet shrinks from full to
  /// minimum size.
  final double falloff;
}

/// Builds the [EdgeViewport] for a [viewport] of the given size, with
/// [topInset] (status bar) and [bottomInset] (collapsed sheet) reserved.
EdgeViewport edgeViewport({
  required Size viewport,
  required double topInset,
  required double bottomInset,
}) {
  final safeRect = Rect.fromLTRB(
    0,
    topInset,
    viewport.width,
    math.max(topInset + 1, viewport.height - bottomInset),
  );
  return EdgeViewport(
    safeRect: safeRect,
    handoffRect: handoffRectFor(safeRect),
    // Bias the optical centre toward the top of the safe area so a member due
    // south reads correctly above the bottom sheet rather than behind it.
    opticalCenter: Offset(
      viewport.width / 2,
      (safeRect.top + safeRect.bottom) / 2,
    ),
    falloff: falloffFor(viewport),
  );
}

/// The off-screen boundary rectangle derived from [safeRect].
Rect handoffRectFor(Rect safeRect) =>
    safeRect.deflate(kDropletFullRadius + kDropletEdgeMargin);

/// The shrink distance for a [viewport], bounded below so very low zoom levels
/// (or near-antipodal members) cannot make the droplet saturate at minimum
/// size the moment it leaves the screen.
double falloffFor(Size viewport) =>
    math.max(160, 0.75 * math.min(viewport.width, viewport.height));

double _easeOutCubic(double t) => 1 - math.pow(1 - t, 3).toDouble();

/// The droplet diameter for an avatar centre lying [overshoot] pixels beyond
/// the hand-off edge, given [falloff].
///
/// Equals [kDropletFullDiameter] at `overshoot == 0` — the property that makes
/// the marker hand-off seamless — and eases down to [kDropletMinDiameter] once
/// the member is a full [falloff] beyond the edge.
double dropletDiameter(double overshoot, double falloff) {
  final s = (overshoot / falloff).clamp(0.0, 1.0);
  return lerpDouble(
    kDropletFullDiameter,
    kDropletMinDiameter,
    _easeOutCubic(s),
  )!;
}

/// The morph parameter for an avatar centre lying [overshoot] pixels beyond
/// the hand-off edge, given [falloff].
///
/// `1` at the edge (a detached, full bubble) easing to `0` far away (a tiny
/// droplet welded to the border).
double dropletMorph(double overshoot, double falloff) =>
    1 - (overshoot / falloff).clamp(0.0, 1.0);

/// Where the ray from [origin] (assumed inside [rect]) through [through]
/// crosses the boundary of [rect], plus whether that crossing is at a corner.
///
/// Returns `null` when [through] coincides with [origin] (no direction).
({Offset point, bool corner})? _rayExit(
  Offset origin,
  Offset through,
  Rect rect,
) {
  final d = through - origin;
  if (d.distance < 1e-3) return null;
  final tx = d.dx > 0
      ? (rect.right - origin.dx) / d.dx
      : d.dx < 0
      ? (rect.left - origin.dx) / d.dx
      : double.infinity;
  final ty = d.dy > 0
      ? (rect.bottom - origin.dy) / d.dy
      : d.dy < 0
      ? (rect.top - origin.dy) / d.dy
      : double.infinity;
  final t = math.min(tx, ty);
  final corner = (tx - ty).abs() < 1e-3;
  final exit = origin + d * t;
  return (
    point: Offset(
      _clampSafe(exit.dx, rect.left, rect.right),
      _clampSafe(exit.dy, rect.top, rect.bottom),
    ),
    corner: corner,
  );
}

/// The result of projecting one member against the viewport.
class EdgeProjection {
  /// Creates an [EdgeProjection].
  const EdgeProjection({
    required this.offScreen,
    required this.headCenter,
    required this.diameter,
    required this.morph,
    required this.angle,
    required this.isCorner,
  });

  /// Whether the member is outside the hand-off rectangle and should be drawn
  /// as an edge droplet (`true`) rather than a normal marker (`false`).
  final bool offScreen;

  /// Screen-space centre of the droplet head. Meaningful only when
  /// [offScreen] is `true`.
  final Offset headCenter;

  /// Droplet diameter in logical pixels.
  final double diameter;

  /// Morph parameter in `[0, 1]`; see [dropletMorph].
  final double morph;

  /// Direction, in radians, from the optical centre toward the member (screen
  /// space: `+x` east, `+y` south). Drives the droplet's outward-pointing nub.
  final double angle;

  /// Whether the ray exits through (near) a corner of the hand-off rectangle.
  final bool isCorner;

  /// A member that is on-screen (rendered by the normal marker layer).
  static const EdgeProjection onScreen = EdgeProjection(
    offScreen: false,
    headCenter: Offset.zero,
    diameter: kDropletFullDiameter,
    morph: 1,
    angle: 0,
    isCorner: false,
  );
}

/// Projects one member's [avatarCenter] (the screen point its avatar disc
/// would occupy) against [viewport] and produces an [EdgeProjection].
EdgeProjection projectMemberToEdge({
  required Offset avatarCenter,
  required EdgeViewport viewport,
}) {
  final safeRect = viewport.safeRect;
  // Non-finite projection (e.g. a near-antipodal member at very low zoom):
  // treat as far off-screen toward the east rather than crashing.
  if (!avatarCenter.dx.isFinite || !avatarCenter.dy.isFinite) {
    return EdgeProjection(
      offScreen: true,
      headCenter: Offset(
        safeRect.right - kDropletEdgeMargin - kDropletMinDiameter / 2,
        viewport.opticalCenter.dy,
      ),
      diameter: kDropletMinDiameter,
      morph: 0,
      angle: 0,
      isCorner: false,
    );
  }
  // Inside the hand-off rect → a normal marker draws it; no droplet.
  if (viewport.handoffRect.contains(avatarCenter)) {
    return EdgeProjection.onScreen;
  }
  final handoffExit = _rayExit(
    viewport.opticalCenter,
    avatarCenter,
    viewport.handoffRect,
  );
  // Degenerate direction (avatar centre at the optical centre): on-screen.
  if (handoffExit == null) return EdgeProjection.onScreen;

  final overshoot = (avatarCenter - handoffExit.point).distance;
  final diameter = dropletDiameter(overshoot, viewport.falloff);
  final morph = dropletMorph(overshoot, viewport.falloff);

  // Position the head so its outer rim sits `kDropletEdgeMargin` inside the
  // safe edge at this size. At full size this rect equals the hand-off rect,
  // so the head lands exactly on the avatar centre when overshoot is 0 — the
  // no-pop guarantee.
  final headInset = diameter / 2 + kDropletEdgeMargin;
  final maxInset = math.min(safeRect.width, safeRect.height) / 2 - 1;
  final positionRect = safeRect.deflate(
    math.min(headInset, math.max(0, maxInset)),
  );
  final headExit =
      _rayExit(viewport.opticalCenter, avatarCenter, positionRect) ??
      handoffExit;

  return EdgeProjection(
    offScreen: true,
    headCenter: headExit.point,
    diameter: diameter,
    morph: morph,
    angle: (avatarCenter - viewport.opticalCenter).direction,
    isCorner: handoffExit.corner,
  );
}

/// An eight-point compass bearing for a screen-space [angle] in radians, where
/// `+x` is east and `+y` is **south** (screen coordinates are y-down, so due
/// north is `-y`). Used for accessibility labels.
String compassFromAngle(double angle) {
  // Convert to a compass bearing in degrees clockwise from north. Screen +y is
  // south, so north corresponds to angle -pi/2; bearing = angle + 90 degrees.
  // Dart's `%` on a positive divisor already yields a value in [0, 360).
  final deg = (angle * 180 / math.pi + 90) % 360;
  const names = [
    'north',
    'north-east',
    'east',
    'south-east',
    'south',
    'south-west',
    'west',
    'north-west',
  ];
  final index = ((deg + 22.5) ~/ 45) % 8;
  return names[index];
}

/// Builds the screen-reader label for an off-screen member's droplet, e.g.
/// "Jane is off-screen to the north-east, tap to view". Falls back to
/// "A member" when no display name is known.
String offScreenSemanticsLabel(String? displayName, double angle) {
  final trimmed = displayName?.trim();
  final name = (trimmed != null && trimmed.isNotEmpty) ? trimmed : 'A member';
  return '$name is off-screen to the ${compassFromAngle(angle)}, tap to view';
}

/// Returns the centre at which a droplet's tap target should sit so a
/// [kMinTapTarget]-sized (or larger, for big droplets) hit-box stays wholly
/// within [safeRect].
///
/// A droplet welded to the edge has its visible head only a few pixels inside
/// the border, so a tap box centred on [head] would spill off-screen and
/// shrink the reachable area below 48dp. Clamping the tap centre inward keeps
/// the full target on-screen and physically reachable while the visible
/// droplet stays at the edge.
Offset tapTargetCenter({
  required Offset head,
  required double diameter,
  required Rect safeRect,
}) {
  final half = math.max(diameter, kMinTapTarget) / 2;
  return Offset(
    safeRect.right - half > safeRect.left + half
        ? head.dx.clamp(safeRect.left + half, safeRect.right - half)
        : head.dx,
    safeRect.bottom - half > safeRect.top + half
        ? head.dy.clamp(safeRect.top + half, safeRect.bottom - half)
        : head.dy,
  );
}
