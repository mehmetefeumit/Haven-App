/// Viewport-filling scroll host for intrinsically-sized content.
library;

import 'package:flutter/material.dart';

/// Lays [child] out at least as tall as the viewport, and scrolls it when it
/// is taller.
///
/// Placeholder content — an empty state, an error state — is intrinsically
/// sized and centred, so a host that hands it a TIGHT height clips it the
/// moment a wordier locale, a larger OS text scale or an open keyboard eats
/// the difference. This supplies the min-height-with-unbounded-max contract
/// that content needs: the centring survives when there is room, and the
/// overflow becomes a scroll when there is not.
///
/// The child must support intrinsic sizing, because
/// [SliverFillRemaining.hasScrollBody] `false` measures it. That rules out
/// `LayoutBuilder` and nested viewports — which is why the placeholders
/// themselves stay plain and delegate scrolling here.
class HavenScrollFill extends StatelessWidget {
  /// Creates a viewport-filling scroll host.
  const HavenScrollFill({required this.child, super.key});

  /// The content to fill the viewport with.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      slivers: [SliverFillRemaining(hasScrollBody: false, child: child)],
    );
  }
}
