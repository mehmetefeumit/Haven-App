/// Where the mesh button sits and how far, how long and how wide the mesh
/// aura runs, each from the window's current size alone
/// (`docs/BLUETOOTH_MESH_AURA_DESIGN.md` §2). Logical pixels throughout, so
/// the aura is as soft on one pixel density as on another.
library;

import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/painting.dart' show EdgeInsets;
import 'package:haven/src/constants/map_layout.dart';

/// The mesh button's side: the minimum touch target.
const double kMeshButtonSize = 48;

const double _kMargin = 16;

/// The mesh button's rect in a shell of [shell]: the bottom-left corner above
/// the collapsed sheet, level with the map controls opposite. A fixed corner,
/// the same in a right-to-left language, as theirs is; held clear of a
/// landscape sensor housing by [viewPadding].
Rect meshButtonRect(Size shell, EdgeInsets viewPadding) => Rect.fromLTWH(
  _kMargin + viewPadding.left,
  shell.height * (1 - kCollapsedSheetFraction) - _kMargin - kMeshButtonSize,
  kMeshButtonSize,
  kMeshButtonSize,
);

/// How far the wave runs: from [origin] to the farthest corner of [size].
double waveReach(Size size, Offset origin) => [
  Offset.zero,
  Offset(size.width, 0),
  Offset(0, size.height),
  Offset(size.width, size.height),
].map((corner) => (corner - origin).distance).reduce(math.max);

/// How long the wave takes to run [reach]: longer on a larger window, by less
/// than its size — one speed would take two seconds across a tablet, one
/// duration would race across it.
Duration waveDuration(double reach) =>
    Duration(milliseconds: (600 + 0.5 * reach).clamp(900, 1400).round());

/// How wide the wave's band is for a run of [reach].
double waveBand(double reach) => (0.28 * reach).clamp(160, 320);

/// How far the hue reaches in from the edges of a window of [size].
double hueWidth(Size size) => (0.06 * size.shortestSide).clamp(20, 32);
