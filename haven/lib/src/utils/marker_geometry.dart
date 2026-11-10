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

/// Tail length, measured from the rim, of a marker free on screen.
const double kDropletOnScreenTail = 10;

/// Tail cap while the marker clings at full size to an edge, wide enough that
/// the tip stays on the point for every on-screen point at the side and bottom
/// edges (a head held 30 px in needs 20.9 px at the worst).
const double kDropletMaxTailOnScreen = 22;

/// Tail cap at the far bead.
const double kDropletMaxTailFar = 8;

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

/// The shrink progress, `0` at the safe rect's edge to `1` a full [falloff]
/// beyond it, eased with smoothstep.
///
/// Smoothstep has zero slope at both ends, so the drop clings at full size as
/// it meets the edge; an ease-out curve is steepest exactly at the crossing.
double dropletProgress(double overshoot, double falloff) {
  final s = (overshoot / falloff).clamp(0.0, 1.0);
  return s * s * (3 - 2 * s);
}

/// The bubble diameter for a member whose projected point lies [overshoot]
/// pixels outside the safe rect, given [falloff].
///
/// Equals [kDropletFullDiameter] at `overshoot == 0` (the no-pop invariant: a
/// member crossing the edge is full size) and eases to [kDropletMinDiameter]
/// once a full [falloff] off-screen.
double dropletDiameter(double overshoot, double falloff) => lerpDouble(
  kDropletFullDiameter,
  kDropletMinDiameter,
  dropletProgress(overshoot, falloff),
)!;

/// The longest tail a marker may grow at shrink [progress] (see
/// [dropletProgress]).
double tailCapFor(double progress) =>
    lerpDouble(kDropletMaxTailOnScreen, kDropletMaxTailFar, progress)!;

/// Aims a tail from a head at [center] with [radius] toward [point].
///
/// The length is measured from the rim and limited to [cap]; the angle is
/// `π/2` (down, the free-on-screen direction) when the two coincide, so the
/// degenerate case continues the normal one.
({double nubLength, double angle}) aimTail({
  required Offset point,
  required Offset center,
  required double radius,
  required double cap,
}) {
  final delta = point - center;
  final d = delta.distance;
  return (
    nubLength: (d - radius).clamp(0.0, cap),
    angle: d < 1e-3 ? math.pi / 2 : delta.direction,
  );
}

/// The result of projecting one member against the viewport.
class MarkerProjection {
  /// Creates a [MarkerProjection].
  const MarkerProjection({
    required this.bubbleCenter,
    required this.diameter,
    required this.nubLength,
    required this.angle,
    required this.bearing,
    required this.tailCap,
    required this.offScreen,
  });

  /// Screen-space centre of the bubble head: above the projected point while
  /// free on screen, clamped so the head stays fully visible near the edge.
  final Offset bubbleCenter;

  /// Bubble diameter in logical pixels.
  final double diameter;

  /// Length of the tail, measured from the rim toward the member's point. `0`
  /// when the point lies inside the head (a plain circle).
  final double nubLength;

  /// Direction, in radians, from [bubbleCenter] toward the member's true
  /// projected point (screen space: `+x` east, `+y` south). Meaningful only
  /// when [nubLength] > 0. Drives the tail only, never the spoken direction.
  final double angle;

  /// Direction, in radians, of the point's overshoot past the safe rect (`0`
  /// when on-screen): orthogonal at an edge, diagonal only in a corner. This,
  /// not [angle], drives the spoken compass direction: the tail of a member
  /// due east just past the edge leans toward the south-east.
  final double bearing;

  /// The longest tail this marker may grow ([tailCapFor] at its shrink
  /// progress), kept so the layer re-aims a spread head with the same limit.
  final double tailCap;

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
      nubLength: kDropletMaxTailFar,
      angle: 0,
      bearing: 0,
      tailCap: kDropletMaxTailFar,
      offScreen: true,
    );
  }

  // Size from how far the true point lies OUTSIDE the safe rect, so every
  // on-screen member is full size and only off-screen ones shrink.
  final overshootVector = point - _clampToRect(point, safeRect);
  final overshoot = overshootVector.distance;
  final s = dropletProgress(overshoot, viewport.falloff);
  final diameter = dropletDiameter(overshoot, viewport.falloff);
  final radius = diameter / 2;

  // The head floats above the point so the tail's tip is the coordinate; the
  // lift fades out with the shrink so the far bead sits on the member's
  // bearing. The inset shrinks with the bubble so a small one's rim sits
  // `kDropletEdgeMargin` from the border while a full one is wholly on-screen.
  // _clampToRect tolerates an inverted rect, so no lower guard is needed for a
  // degenerate (tiny) viewport.
  //
  // Top edge, unavoidable: around the safe rect's boundary the head must lie
  // above the point at the bottom, inward at the sides and below it at the top
  // corners, one full turn, so any continuous placement puts the head over the
  // point somewhere inside. That is a ~52 px band under the top inset, where
  // the tail shrinks to 0 and regrows pointing up. Do not try to remove it.
  final lifted = Offset(
    point.dx,
    point.dy - (1 - s) * (kDropletFullRadius + kDropletOnScreenTail),
  );
  final maxInset = math.min(safeRect.width, safeRect.height) / 2 - 1;
  final inset = math.min(radius + kDropletEdgeMargin, maxInset);
  final bubbleCenter = _clampToRect(lifted, safeRect.deflate(inset));

  final tailCap = tailCapFor(s);
  final tail = aimTail(
    point: point,
    center: bubbleCenter,
    radius: radius,
    cap: tailCap,
  );
  return MarkerProjection(
    bubbleCenter: bubbleCenter,
    diameter: diameter,
    nubLength: tail.nubLength,
    angle: tail.angle,
    bearing: overshoot < 1e-3 ? 0 : overshootVector.direction,
    tailCap: tailCap,
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
