/// Map controls widget for Haven.
///
/// Provides zoom and recenter controls for the map.
library;

import 'package:flutter/material.dart';
import 'package:haven/src/theme/theme.dart';

/// Vertical stack of map control buttons.
///
/// Includes zoom in, zoom out, and recenter controls with
/// proper touch targets (48dp minimum).
class MapControls extends StatelessWidget {
  /// Creates map controls.
  const MapControls({
    super.key,
    this.onZoomIn,
    this.onZoomOut,
    this.onRecenter,
    this.showRecenter = true,
  });

  /// Callback when zoom in is pressed.
  final VoidCallback? onZoomIn;

  /// Callback when zoom out is pressed.
  final VoidCallback? onZoomOut;

  /// Callback when recenter is pressed.
  final VoidCallback? onRecenter;

  /// Whether to show the recenter button.
  final bool showRecenter;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Zoom controls
        Container(
          decoration: BoxDecoration(
            color: colorScheme.surface,
            borderRadius: BorderRadius.circular(HavenSpacing.sm),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.1),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _MapControlButton(
                icon: Icons.add,
                onPressed: onZoomIn,
                tooltip: 'Zoom in',
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(HavenSpacing.sm),
                ),
              ),
              Container(
                height: 1,
                width: 32,
                color: colorScheme.outlineVariant,
              ),
              _MapControlButton(
                icon: Icons.remove,
                onPressed: onZoomOut,
                tooltip: 'Zoom out',
                borderRadius: const BorderRadius.vertical(
                  bottom: Radius.circular(HavenSpacing.sm),
                ),
              ),
            ],
          ),
        ),

        if (showRecenter) ...[
          const SizedBox(height: HavenSpacing.sm),

          // Recenter button
          Container(
            decoration: BoxDecoration(
              color: colorScheme.surface,
              borderRadius: BorderRadius.circular(HavenSpacing.sm),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.1),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: _MapControlButton(
              icon: Icons.my_location,
              onPressed: onRecenter,
              tooltip: 'Recenter',
              borderRadius: BorderRadius.circular(HavenSpacing.sm),
            ),
          ),
        ],
      ],
    );
  }
}

class _MapControlButton extends StatelessWidget {
  const _MapControlButton({
    required this.icon,
    required this.tooltip,
    required this.borderRadius,
    this.onPressed,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String tooltip;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: borderRadius,
          child: Container(
            width: 48,
            height: 48,
            alignment: Alignment.center,
            child: Icon(
              icon,
              size: 24,
              color: onPressed != null
                  ? colorScheme.onSurface
                  : colorScheme.onSurface.withValues(alpha: 0.38),
            ),
          ),
        ),
      ),
    );
  }
}

/// A floating action button for recenter functionality.
///
/// Alternative to the vertical controls, placed at bottom right.
class RecenterFAB extends StatelessWidget {
  /// Creates a recenter FAB.
  const RecenterFAB({super.key, this.onPressed, this.isLoading = false});

  /// Callback when pressed.
  final VoidCallback? onPressed;

  /// Whether to show a loading indicator.
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    return FloatingActionButton(
      onPressed: isLoading ? null : onPressed,
      tooltip: 'Recenter on my location',
      child: isLoading
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.my_location),
    );
  }
}
