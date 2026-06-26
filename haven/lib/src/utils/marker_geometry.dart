/// Pure screen-space geometry for circle-member map markers.
///
/// One continuous model drives a member's marker across its whole journey: a
/// plain circle centred on the member while comfortably in view, growing a
/// joined teardrop tail (pointing at the member's true location) as they near
/// or leave the viewport edge, and shrinking to a tiny edge droplet welded to
/// the border when far off-screen. Everything here operates on plain
/// [Offset]/[Rect]/[Size] values in logical pixels with no Flutter/`flutter_map`
/// dependency, so it is fully unit-testable without a live map.
library;

import 'dart:math' as math;
import 'dart:ui';

/// Diameter, in logical pixels, of a marker bubble while on-screen (and the
/// size it returns to at the viewport edge).
///
/// MUST equal the avatar ring diameter (`kRingDiameter`); a test guards it.
const double kDropletFullDiameter = 52;

/// Radius of a marker bubble at full (on-screen) size.
const double kDropletFullRadius = kDropletFullDiameter / 2;

/// Smallest bubble diameter, used when a member is far off-screen. Large enough
/// to still carry a single legible initial.
const double kDropletMinDiameter = 20;

/// Gap, in logical pixels, kept between a bubble's outer rim and the safe
/// viewport edge — so a small bubble "merges" with the border while a full one
/// stays wholly on-screen.
const double kDropletEdgeMargin = 4;

/// Maximum length of the outward teardrop tail (reached when far off-screen).
const double kDropletMaxNub = 8;

/// Minimum interactive target size (Material 48dp / WCAG 2.5.5).
const double kMinTapTarget = 48;

/// Clamps [v] to the range spanned by [a] and [b] regardless of their order.
double _clampSafe(double v, double a, double b) =>
    v.clamp(math.min(a, b), math.max(a, b));

Offset _clampToRect(Offset p, Rect rect) => Offset(
  _clampSafe(p.dx, rect.left, rect.right),
  _clampSafe(p.dy, rect.top, rect.bottom),
);

/// Viewport rectangles a layer needs to project members.
class EdgeViewport {
  /// Creates an [EdgeViewport].
  const EdgeViewport({required this.safeRect, required this.falloff});

  /// The usable map area: the full viewport minus the top safe-area inset and
  /// the bottom inset occluded by the collapsed bottom sheet. A member whose
  /// projected point is inside this rect is "on-screen" (full-size bubble).
  final Rect safeRect;

  /// Distance, in logical pixels, over which a bubble shrinks from full to
  /// minimum size once the member is off-screen.
  final double falloff;
}

/// Builds the [EdgeViewport] for a [viewport] of the given size, reserving
/// [topInset] (status bar) and [bottomInset] (collapsed sheet).
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
  return EdgeViewport(safeRect: safeRect, falloff: falloffFor(viewport));
}

/// The shrink distance for a [viewport], bounded below so very low zoom levels
/// (or near-antipodal members) cannot saturate the size the moment a member
/// leaves the screen.
double falloffFor(Size viewport) =>
    math.max(160, 0.75 * math.min(viewport.width, viewport.height));

double _easeOutCubic(double t) => 1 - math.pow(1 - t, 3).toDouble();

/// The bubble diameter for a member whose projected point lies [overshoot]
/// pixels outside the safe rect, given [falloff].
///
/// Equals [kDropletFullDiameter] at `overshoot == 0` (the no-pop invariant: a
/// member crossing the edge is full size) and eases to [kDropletMinDiameter]
/// once a full [falloff] off-screen.
double dropletDiameter(double overshoot, double falloff) {
  final s = (overshoot / falloff).clamp(0.0, 1.0);
  return lerpDouble(
    kDropletFullDiameter,
    kDropletMinDiameter,
    _easeOutCubic(s),
  )!;
}

/// The result of projecting one member against the viewport.
class MarkerProjection {
  /// Creates a [MarkerProjection].
  const MarkerProjection({
    required this.bubbleCenter,
    required this.diameter,
    required this.nubLength,
    required this.angle,
    required this.offScreen,
  });

  /// Screen-space centre of the bubble. On-screen and comfortably inside this
  /// equals the projected geo point; near/at the edge it is clamped so the
  /// bubble stays fully visible.
  final Offset bubbleCenter;

  /// Bubble diameter in logical pixels.
  final double diameter;

  /// Length of the outward teardrop tail. `0` while the bubble sits on the
  /// member's true point (a plain circle); grows as the bubble is clamped.
  final double nubLength;

  /// Direction, in radians, from [bubbleCenter] toward the member's true
  /// projected point (screen space: `+x` east, `+y` south). Meaningful only
  /// when [nubLength] > 0.
  final double angle;

  /// Whether the member's true point is outside the safe rect (truly
  /// off-screen). Drives the semantics label, tap behaviour, and edge spread —
  /// NOT the rendering, which is one continuous widget regardless.
  final bool offScreen;
}

/// Projects one member's screen [point] (`camera.latLngToScreenOffset(geo)`)
/// against [viewport] into a continuous [MarkerProjection].
MarkerProjection projectMarker({
  required Offset point,
  required EdgeViewport viewport,
}) {
  final safeRect = viewport.safeRect;
  // Non-finite projection (near-antipodal at very low zoom): a far droplet at
  // the right edge rather than a crash.
  if (!point.dx.isFinite || !point.dy.isFinite) {
    return MarkerProjection(
      bubbleCenter: Offset(
        safeRect.right - kDropletEdgeMargin - kDropletMinDiameter / 2,
        safeRect.center.dy,
      ),
      diameter: kDropletMinDiameter,
      nubLength: kDropletMaxNub,
      angle: 0,
      offScreen: true,
    );
  }

  // Size from how far the true point lies OUTSIDE the safe rect, so every
  // on-screen member is full size and only off-screen ones shrink.
  final overshoot = (point - _clampToRect(point, safeRect)).distance;
  final diameter = dropletDiameter(overshoot, viewport.falloff);

  // Place so the bubble stays fully visible; the inset shrinks with the bubble
  // so a small one's rim sits `kDropletEdgeMargin` from the border (welds to
  // the edge) while a full one is wholly on-screen.
  // _clampToRect tolerates an inverted rect, so no lower guard is needed for a
  // degenerate (tiny) viewport.
  final maxInset = math.min(safeRect.width, safeRect.height) / 2 - 1;
  final inset = math.min(diameter / 2 + kDropletEdgeMargin, maxInset);
  final bubbleCenter = _clampToRect(point, safeRect.deflate(inset));

  final tip = point - bubbleCenter;
  final dist = tip.distance;
  return MarkerProjection(
    bubbleCenter: bubbleCenter,
    diameter: diameter,
    nubLength: math.min(dist, kDropletMaxNub),
    angle: dist < 1e-3 ? 0 : tip.direction,
    offScreen: overshoot > 1e-3,
  );
}

/// One of the eight compass bearings used to describe an off-screen member's
/// direction in accessibility labels.
///
/// Ordered clockwise from north so the ordinal matches the 45-degree sector
/// index returned by [compassDirectionFromAngle]. This is a real-world bearing
/// and is therefore never mirrored under right-to-left layouts — only the
/// localized *word* for it (resolved at the widget layer) changes per language.
enum CompassDirection {
  /// Due north.
  north,

  /// North-east.
  northEast,

  /// Due east.
  east,

  /// South-east.
  southEast,

  /// Due south.
  south,

  /// South-west.
  southWest,

  /// Due west.
  west,

  /// North-west.
  northWest,
}

/// The eight-point [CompassDirection] for a screen-space [angle] in radians,
/// where `+x` is east and `+y` is **south** (screen coords are y-down, so due
/// north is `-y`). Used for accessibility labels.
CompassDirection compassDirectionFromAngle(double angle) {
  // Dart's `%` on a positive divisor already yields a value in [0, 360).
  final deg = (angle * 180 / math.pi + 90) % 360;
  final index = ((deg + 22.5) ~/ 45) % 8;
  return CompassDirection.values[index];
}

/// Returns the centre at which an off-screen marker's tap target should sit so
/// a [kMinTapTarget]-sized (or larger) hit-box stays wholly within [safeRect]
/// while the visible bubble remains welded to the edge.
Offset tapTargetCenter({
  required Offset bubbleCenter,
  required double diameter,
  required Rect safeRect,
}) {
  final half = math.max(diameter, kMinTapTarget) / 2;
  return Offset(
    safeRect.right - half > safeRect.left + half
        ? bubbleCenter.dx.clamp(safeRect.left + half, safeRect.right - half)
        : bubbleCenter.dx,
    safeRect.bottom - half > safeRect.top + half
        ? bubbleCenter.dy.clamp(safeRect.top + half, safeRect.bottom - half)
        : bubbleCenter.dy,
  );
}
