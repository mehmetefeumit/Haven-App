/// The mesh aura: a wave from the mesh button to the edges of the window when
/// the Bluetooth mesh starts running, and a blue hue round the edges for as
/// long as it runs (`docs/BLUETOOTH_MESH_AURA_DESIGN.md`).
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/providers/mesh_provider.dart';
import 'package:haven/src/theme/colors.dart';
import 'package:haven/src/utils/mesh_aura_geometry.dart';
import 'package:haven/src/utils/reduce_motion.dart';

/// How long the hue takes to leave, and to arrive where motion is reduced.
const Duration kMeshHueFade = Duration(milliseconds: 300);

/// The hue's alpha at the very edge: the one number that decides how strong
/// the hue is, every other stop scaling with it. A glow, for something that
/// may frame the map for twelve hours; at 0.50 it read as a line.
const double kMeshHueEdgeAlpha = 0.35;

/// The radius of the rounded rect the hue glows in from: a typical bezel's,
/// and a square corner is still filled.
const double _kHueCorner = 44;

/// The wave's alpha behind its band, and at the band's peak.
const double _kWaveWash = 0.06;
const double _kWavePeak = 0.22;

/// The aura over the map shell, following the mesh's radio.
///
/// Nothing until the radio and the engine have both answered once: mesh
/// found running when the map opens is then the settled hue, and the wave is
/// kept for the moment it starts.
class MeshAura extends ConsumerStatefulWidget {
  /// Creates the shell's aura.
  const MeshAura({super.key});

  @override
  ConsumerState<MeshAura> createState() => _MeshAuraState();
}

class _MeshAuraState extends ConsumerState<MeshAura> {
  bool _known = false;

  @override
  Widget build(BuildContext context) {
    final running = ref.watch(meshPhaseProvider) == MeshPhase.on;
    _known =
        _known ||
        (ref.watch(meshRadioStatusProvider) != null &&
            ref.watch(meshProvider).hasValue);
    if (!_known) return const SizedBox.shrink();
    return MeshAuraOverlay(running: running);
  }
}

/// Decoration only: it takes no touch and has no semantics — the mesh button
/// tells the state. While mesh is not [running] and nothing is fading it
/// builds nothing; settled on, it holds one static picture and no ticker.
class MeshAuraOverlay extends StatefulWidget {
  /// Creates the aura.
  const MeshAuraOverlay({required this.running, super.key});

  /// Whether the mesh's radio is running now.
  final bool running;

  @override
  State<MeshAuraOverlay> createState() => _MeshAuraOverlayState();
}

class _MeshAuraOverlayState extends State<MeshAuraOverlay>
    with TickerProviderStateMixin {
  /// The wave's run, 0 to 1; 1 at rest.
  late final AnimationController _wave = AnimationController(
    vsync: this,
    value: 1,
  );

  /// How much of the aura is there, 0 to 1: what a turn-off fades.
  late final AnimationController _present =
      AnimationController(
        vsync: this,
        duration: kMeshHueFade,
        // Mesh found running when the map opens is the settled hue: the
        // wave marks the moment it starts.
        value: widget.running ? 1 : 0,
      )..addStatusListener((status) {
        // Back to building nothing once the hue has left.
        if (status == AnimationStatus.dismissed) setState(() {});
      });

  @override
  void didUpdateWidget(MeshAuraOverlay old) {
    super.didUpdateWidget(old);
    if (widget.running == old.running) return;
    if (!widget.running) {
      _present.reverse();
      return;
    }
    // A hue still leaving comes back from where it is: a second wave over it
    // would blank it first.
    if (_present.isDismissed && !reduceMotionOf(context)) {
      final size = MediaQuery.sizeOf(context);
      final origin = meshButtonRect(
        size,
        MediaQuery.viewPaddingOf(context),
      ).center;
      _present.value = 1;
      _wave
        ..duration = waveDuration(waveReach(size, origin))
        ..forward(from: 0);
    } else {
      _present.forward();
    }
  }

  @override
  void dispose() {
    _wave.dispose();
    _present.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.running && _present.isDismissed) return const SizedBox.shrink();
    return IgnorePointer(
      child: ExcludeSemantics(
        // Its own layer: a frame of the wave repaints nothing under it, and
        // the settled hue is repainted by nothing over it.
        child: RepaintBoundary(
          child: CustomPaint(
            size: Size.infinite,
            painter: _AuraPainter(
              wave: _wave,
              present: _present,
              viewPadding: MediaQuery.viewPaddingOf(context),
            ),
          ),
        ),
      ),
    );
  }
}

/// Paints the wave and the hue from the size it is handed at each frame, so a
/// fold, an unfold or a rotation lands both on the new edges. Repainted by
/// its controllers alone: a frame builds and lays out nothing.
class _AuraPainter extends CustomPainter {
  _AuraPainter({
    required this.wave,
    required this.present,
    required this.viewPadding,
  }) : super(repaint: Listenable.merge([wave, present]));

  final Animation<double> wave;
  final Animation<double> present;
  final EdgeInsets viewPadding;

  static Color _blue(double alpha) =>
      HavenMeshColors.active.withValues(alpha: alpha);

  @override
  void paint(Canvas canvas, Size size) {
    final shown = present.value;
    if (shown == 0 || size.isEmpty) return;
    final t = wave.value;
    if (t < 1) _paintWave(canvas, size, t, shown);
    // The hue arrives over the wave's second half, behind its front.
    final hue = shown * ((t - 0.5) * 2).clamp(0.0, 1.0);
    if (hue > 0) _paintHue(canvas, size, hue);
  }

  void _paintWave(Canvas canvas, Size size, double t, double shown) {
    final origin = meshButtonRect(size, viewPadding).center;
    final reach = waveReach(size, origin);
    final band = waveBand(reach);
    final front = Curves.easeOutSine.transform(t) * (reach + band);
    if (front <= 0) return;
    // The whole wave leaves over the last 30 % of its run.
    final alpha = shown * (t < 0.7 ? 1.0 : (1 - t) / 0.3);
    final wash = _blue(_kWaveWash * alpha);
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = ui.Gradient.radial(
          origin,
          front,
          [wash, wash, _blue(_kWavePeak * alpha), _blue(0)],
          [
            0,
            ((front - band) / front).clamp(0.0, 1.0),
            ((front - 0.35 * band) / front).clamp(0.0, 1.0),
            1,
          ],
        ),
    );
  }

  /// The inner glow of a rounded rect the size of the window: four strips
  /// along the edges and four corners.
  void _paintHue(Canvas canvas, Size size, double hue) {
    final width = hueWidth(size);
    final edge = kMeshHueEdgeAlpha * hue;
    // By distance in from the edge, as a share of [width].
    final colors = [
      _blue(edge),
      _blue(edge * 0.5),
      _blue(edge * 0.15),
      _blue(0),
    ];
    const stops = [0.0, 0.3, 0.65, 1.0];
    const r = _kHueCorner;
    final paint = Paint();

    void strip(Rect rect, Offset from, Offset to) {
      if (rect.width <= 0 || rect.height <= 0) return;
      paint.shader = ui.Gradient.linear(from, to, colors, stops);
      canvas.drawRect(rect, paint);
    }

    strip(
      Rect.fromLTRB(r, 0, size.width - r, width),
      Offset.zero,
      Offset(0, width),
    );
    strip(
      Rect.fromLTRB(r, size.height - width, size.width - r, size.height),
      Offset(0, size.height),
      Offset(0, size.height - width),
    );
    strip(
      Rect.fromLTRB(0, r, width, size.height - r),
      Offset.zero,
      Offset(width, 0),
    );
    strip(
      Rect.fromLTRB(size.width - width, r, size.width, size.height - r),
      Offset(size.width, 0),
      Offset(size.width - width, 0),
    );

    // Round each corner's centre the same stops run outwards, and past the
    // arc the edge's own alpha fills what a square screen corner shows.
    final cornerColors = colors.reversed.toList();
    final cornerStops = [
      for (final stop in stops.reversed) (r - stop * width) / r,
    ];
    for (final centre in [
      const Offset(r, r),
      Offset(size.width - r, r),
      Offset(r, size.height - r),
      Offset(size.width - r, size.height - r),
    ]) {
      paint.shader = ui.Gradient.radial(centre, r, cornerColors, cornerStops);
      canvas.drawRect(
        Rect.fromLTRB(
          centre.dx < size.width / 2 ? 0 : centre.dx,
          centre.dy < size.height / 2 ? 0 : centre.dy,
          centre.dx < size.width / 2 ? centre.dx : size.width,
          centre.dy < size.height / 2 ? centre.dy : size.height,
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_AuraPainter old) =>
      old.wave != wave ||
      old.present != present ||
      old.viewPadding != viewPadding;
}
