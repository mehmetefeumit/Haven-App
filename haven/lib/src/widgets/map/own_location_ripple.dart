/// The user's own location on the map where the Bluetooth mesh exists: the
/// dot, and a ripple out of it each time their own location is handed to the
/// mesh (`docs/BLUETOOTH_MESH_AURA_DESIGN.md` §1, §3).
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/providers/mesh_provider.dart';
import 'package:haven/src/theme/colors.dart';
import 'package:haven/src/utils/reduce_motion.dart';
import 'package:haven/src/widgets/map/user_location_marker.dart';
import 'package:latlong2/latlong.dart';

/// How long one ripple runs.
const Duration kOwnLocationRippleDuration = Duration(milliseconds: 1600);

/// How far a ripple reaches from the dot's centre.
const double kOwnLocationRippleRadius = 72;

/// The user's own dot at [point], as the map shows it with or without the
/// mesh.
Marker ownLocationMarker(LatLng point, {Key? key}) => Marker(
  key: key,
  point: point,
  width: 32,
  height: 32,
  child: const UserLocationMarker(),
);

/// The own-location marker layer with the ripple: one ripple for each change
/// of [meshHandOffProvider], which counts only hand-offs to a mesh that runs
/// with a phone linked. A hand-off that arrives while a ripple runs is
/// dropped. The ripple's marker exists only while it runs, so at rest the
/// layer is the dot alone and nothing is scheduled.
class OwnLocationLayer extends ConsumerStatefulWidget {
  /// Creates the layer for a dot at [point].
  const OwnLocationLayer({
    required this.point,
    required this.darkBasemap,
    super.key,
  });

  /// Where the user is.
  final LatLng point;

  /// Whether the map under the ripple is a dark one.
  final bool darkBasemap;

  /// The dot's marker. Keyed, so that the ripple's marker coming and going
  /// ahead of it in the layer's list leaves the dot's element — and the node
  /// a screen reader may be on — where it is.
  static const Key dotKey = ValueKey('own-location-dot');

  @override
  ConsumerState<OwnLocationLayer> createState() => _OwnLocationLayerState();
}

class _OwnLocationLayerState extends ConsumerState<OwnLocationLayer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ripple =
      AnimationController(vsync: this, duration: kOwnLocationRippleDuration)
        // The marker comes with the ripple's start and goes with its end.
        ..addStatusListener((_) => setState(() {}));

  @override
  void dispose() {
    _ripple.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(meshHandOffProvider, (_, _) {
      // One told while the app is away is dropped: no frame runs there, and
      // it would play at the return, for a hand-off long past. A state not
      // yet reported is an app in front.
      final lifecycle = WidgetsBinding.instance.lifecycleState;
      if (lifecycle != null && lifecycle != AppLifecycleState.resumed) return;
      if (!_ripple.isAnimating) _ripple.forward(from: 0);
    });
    return MarkerLayer(
      markers: [
        if (_ripple.isAnimating)
          Marker(
            point: widget.point,
            width: kOwnLocationRippleRadius * 2,
            height: kOwnLocationRippleRadius * 2,
            child: OwnLocationRipple(
              progress: _ripple,
              still: reduceMotionOf(context),
              darkBasemap: widget.darkBasemap,
            ),
          ),
        ownLocationMarker(widget.point, key: OwnLocationLayer.dotKey),
      ],
    );
  }
}

/// One ripple: two soft rings that widen and fade. Decoration only — it takes
/// no touch and has no semantics — and repainted by [progress] alone, in a
/// layer of its own: the map's layers share one repaint boundary, and
/// without this each frame would repaint the tiles and every marker.
class OwnLocationRipple extends StatelessWidget {
  /// Creates a ripple that follows [progress].
  const OwnLocationRipple({
    required this.progress,
    required this.still,
    required this.darkBasemap,
    super.key,
  });

  /// The ripple's run, 0 to 1.
  final Animation<double> progress;

  /// Motion is reduced: a halo of one size that only fades in and out.
  final bool still;

  /// Whether the map under it is a dark one.
  final bool darkBasemap;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: ExcludeSemantics(
      child: RepaintBoundary(
        child: CustomPaint(
          size: Size.infinite,
          painter: _RipplePainter(
            progress,
            still: still,
            color: darkBasemap
                ? HavenMeshColors.activeOnDark
                : HavenMeshColors.active,
            // A light ring on a dark ground needs more of itself to read as
            // softly as a dark ring on a light one.
            peak: darkBasemap ? 0.5 : 0.34,
          ),
        ),
      ),
    ),
  );
}

class _RipplePainter extends CustomPainter {
  _RipplePainter(
    this.progress, {
    required this.still,
    required this.color,
    required this.peak,
  }) : super(repaint: progress);

  final Animation<double> progress;
  final bool still;
  final Color color;

  /// A ring's alpha at its strongest.
  final double peak;

  /// The dot's own radius: where a ring starts.
  static const double _dot = 13;

  /// How far behind the first ring the second starts, as a share of the run.
  static const double _lag = 0.25;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = size.center(Offset.zero);
    final reach = size.shortestSide / 2;
    final t = progress.value;
    if (still) {
      _ring(canvas, centre, reach * 0.6, peak * math.sin(math.pi * t));
      return;
    }
    for (final start in [0.0, _lag]) {
      final run = ((t - start) / (1 - start)).clamp(0.0, 1.0);
      if (run == 0) continue;
      _ring(
        canvas,
        centre,
        _dot + Curves.easeOutSine.transform(run) * (reach - _dot),
        peak * (1 - run),
      );
    }
  }

  void _ring(Canvas canvas, Offset centre, double radius, double alpha) {
    if (alpha <= 0) return;
    final clear = color.withValues(alpha: 0);
    canvas.drawCircle(
      centre,
      radius,
      Paint()
        ..shader = ui.Gradient.radial(
          centre,
          radius,
          [clear, color.withValues(alpha: alpha), clear],
          const [0.5, 0.85, 1],
        ),
    );
  }

  @override
  bool shouldRepaint(_RipplePainter old) =>
      old.progress != progress ||
      old.still != still ||
      old.color != color ||
      old.peak != peak;
}
