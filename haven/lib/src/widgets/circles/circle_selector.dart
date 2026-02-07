/// Circle selector widget for Haven.
///
/// A horizontal scrollable list of circle chips for selecting which
/// circle to view in the bottom sheet.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/pages/circles/create_circle_page.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/theme/theme.dart';

/// A horizontal scrollable list of circle selection chips.
///
/// Displays all visible circles as selectable chips. The currently selected
/// circle is highlighted. Includes an "Add" button to create new circles.
class CircleSelector extends ConsumerWidget {
  /// Creates a circle selector.
  const CircleSelector({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final circlesAsync = ref.watch(circlesProvider);
    final selectedCircle = ref.watch(selectedCircleProvider);

    return circlesAsync.when(
      data: (circles) => _buildSelector(context, ref, circles, selectedCircle),
      loading: () => const SizedBox(
        height: 40,
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ),
      error: (error, _) => SizedBox(
        height: 40,
        child: Center(
          child: Text(
            'Failed to load circles',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.error,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSelector(
    BuildContext context,
    WidgetRef ref,
    List<Circle> circles,
    Circle? selectedCircle,
  ) {
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: HavenSpacing.base),
        itemCount: circles.length + 1, // +1 for add button
        separatorBuilder: (_, __) => const SizedBox(width: HavenSpacing.sm),
        itemBuilder: (context, index) {
          // Last item is the add button
          if (index == circles.length) {
            return _AddCircleButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (context) => const CreateCirclePage(),
                  ),
                );
              },
            );
          }

          final circle = circles[index];
          final isSelected = circle == selectedCircle;

          return _CircleChip(
            circle: circle,
            isSelected: isSelected,
            onTap: () {
              ref.read(selectedCircleProvider.notifier).state = isSelected
                  ? null
                  : circle;
            },
          );
        },
      ),
    );
  }
}

/// A chip representing a single circle.
class _CircleChip extends StatelessWidget {
  const _CircleChip({
    required this.circle,
    required this.isSelected,
    required this.onTap,
  });

  final Circle circle;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    // Generate a color from the circle name
    final colorIndex =
        circle.displayName.hashCode.abs() % Colors.primaries.length;
    final circleColor = Colors.primaries[colorIndex];

    return FilterChip(
      selected: isSelected,
      showCheckmark: false,
      avatar: CircleAvatar(
        radius: 12,
        backgroundColor: circleColor.withValues(alpha: 0.2),
        child: Text(
          circle.displayName.isNotEmpty
              ? circle.displayName[0].toUpperCase()
              : '?',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            color: circleColor.shade700,
          ),
        ),
      ),
      label: Text(circle.displayName),
      labelStyle: TextStyle(
        color: isSelected
            ? colorScheme.onSecondaryContainer
            : colorScheme.onSurface,
      ),
      backgroundColor: colorScheme.surface,
      selectedColor: colorScheme.secondaryContainer,
      side: BorderSide(
        color: isSelected ? colorScheme.secondary : colorScheme.outline,
      ),
      onSelected: (_) => onTap(),
    );
  }
}

/// A button to add a new circle.
class _AddCircleButton extends StatelessWidget {
  const _AddCircleButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return ActionChip(
      avatar: Icon(Icons.add, size: 18, color: colorScheme.primary),
      label: Text('New', style: TextStyle(color: colorScheme.primary)),
      backgroundColor: colorScheme.surface,
      side: BorderSide(color: colorScheme.primary, style: BorderStyle.solid),
      onPressed: onPressed,
    );
  }
}
