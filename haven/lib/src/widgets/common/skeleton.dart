/// Skeleton loading placeholders for Haven.
///
/// Provides shimmer-like loading states without external dependencies.
library;

import 'package:flutter/material.dart';
import 'package:haven/src/theme/theme.dart';

/// A skeleton placeholder for loading content.
///
/// Animates between two shades to indicate loading state.
/// Respects the user's reduced motion preference.
class HavenSkeleton extends StatefulWidget {
  /// Creates a skeleton placeholder.
  const HavenSkeleton({
    super.key,
    this.width,
    this.height = 16,
    this.borderRadius,
  });

  /// Width of the skeleton. If null, fills available width.
  final double? width;

  /// Height of the skeleton.
  final double height;

  /// Border radius of the skeleton.
  final BorderRadius? borderRadius;

  @override
  State<HavenSkeleton> createState() => _HavenSkeletonState();
}

class _HavenSkeletonState extends State<HavenSkeleton>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    )..repeat(reverse: true);

    _animation = CurvedAnimation(parent: _controller, curve: Curves.easeInOut);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Respect reduced motion preference
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    final colorScheme = Theme.of(context).colorScheme;

    final baseColor = colorScheme.surfaceContainerHighest;
    final highlightColor = colorScheme.surfaceContainerLow;

    final defaultRadius = BorderRadius.circular(HavenSpacing.xs);

    if (reduceMotion) {
      return Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          color: baseColor,
          borderRadius: widget.borderRadius ?? defaultRadius,
        ),
      );
    }

    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            color: Color.lerp(baseColor, highlightColor, _animation.value),
            borderRadius: widget.borderRadius ?? defaultRadius,
          ),
        );
      },
    );
  }
}

/// A skeleton card mimicking a list item layout.
///
/// Shows a placeholder for avatar, title, and subtitle.
class HavenSkeletonCard extends StatelessWidget {
  /// Creates a skeleton card.
  const HavenSkeletonCard({super.key});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(
        horizontal: HavenSpacing.base,
        vertical: HavenSpacing.xs,
      ),
      child: Padding(
        padding: const EdgeInsets.all(HavenSpacing.base),
        child: Row(
          children: [
            HavenSkeleton(
              width: 40,
              height: 40,
              borderRadius: BorderRadius.circular(HavenSpacing.sm),
            ),
            const SizedBox(width: HavenSpacing.md),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  HavenSkeleton(width: 150),
                  SizedBox(height: HavenSpacing.sm),
                  HavenSkeleton(height: 12),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A skeleton list showing multiple skeleton cards.
///
/// Useful for showing loading state for list views.
class HavenSkeletonList extends StatelessWidget {
  /// Creates a skeleton list.
  const HavenSkeletonList({super.key, this.itemCount = 5});

  /// Number of skeleton cards to show.
  final int itemCount;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(vertical: HavenSpacing.sm),
      itemCount: itemCount,
      itemBuilder: (context, index) => const HavenSkeletonCard(),
    );
  }
}
