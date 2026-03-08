/// Circle selector dropdown widget for Haven.
///
/// An inline expanding dropdown for selecting which circle to view
/// in the bottom sheet. Replaces the horizontal chip list with a
/// vertically expanding section that works within the sliver layout.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/pages/circles/create_circle_page.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/theme/theme.dart';

/// An inline expanding dropdown for circle selection.
///
/// When collapsed, shows the selected circle name (or a placeholder).
/// When expanded, reveals a vertical list of circles with a
/// "New Circle" action at the bottom.
class CircleSelector extends ConsumerWidget {
  /// Creates a circle selector dropdown.
  const CircleSelector({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final circlesAsync = ref.watch(circlesProvider);
    final selectedCircle = ref.watch(selectedCircleProvider);
    final isOpen = ref.watch(circleDropdownOpenProvider);

    return circlesAsync.when(
      data: (circles) => _DropdownBody(
        circles: circles,
        selectedCircle: selectedCircle,
        isOpen: isOpen,
      ),
      loading: () => const SizedBox(
        height: 48,
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ),
      error: (error, _) => SizedBox(
        height: 48,
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
}

class _DropdownBody extends ConsumerWidget {
  const _DropdownBody({
    required this.circles,
    required this.selectedCircle,
    required this.isOpen,
  });

  final List<Circle> circles;
  final Circle? selectedCircle;
  final bool isOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;

    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
      alignment: Alignment.topCenter,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Trigger row
          _TriggerRow(
            selectedCircle: selectedCircle,
            isOpen: isOpen,
            onTap: () {
              ref.read(circleDropdownOpenProvider.notifier).state = !isOpen;
            },
          ),

          // Expanded list
          if (isOpen) ...[
            Divider(
              height: 1,
              indent: HavenSpacing.base,
              endIndent: HavenSpacing.base,
              color: colorScheme.outlineVariant,
            ),
            Container(
              color: colorScheme.surfaceContainerLow,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 300),
                child: ListView.builder(
                  shrinkWrap: true,
                  physics: circles.length <= 8
                      ? const NeverScrollableScrollPhysics()
                      : null,
                  padding: EdgeInsets.zero,
                  itemCount: circles.length,
                  itemBuilder: (context, index) {
                    final circle = circles[index];
                    final isSelected = circle == selectedCircle;
                    return _CircleListItem(
                      circle: circle,
                      isSelected: isSelected,
                      onTap: () {
                        ref.read(selectedCircleProvider.notifier).state =
                            isSelected ? null : circle;
                        ref.read(circleDropdownOpenProvider.notifier).state =
                            false;
                      },
                    );
                  },
                ),
              ),
            ),
            Divider(
              height: 1,
              indent: HavenSpacing.base,
              endIndent: HavenSpacing.base,
              color: colorScheme.outlineVariant,
            ),
            _NewCircleTile(
              onTap: () {
                ref.read(circleDropdownOpenProvider.notifier).state = false;
                Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (context) => const CreateCirclePage(),
                  ),
                );
              },
            ),
          ],
        ],
      ),
    );
  }
}

class _TriggerRow extends StatelessWidget {
  const _TriggerRow({
    required this.selectedCircle,
    required this.isOpen,
    required this.onTap,
  });

  final Circle? selectedCircle;
  final bool isOpen;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: HavenSpacing.base,
          vertical: HavenSpacing.md,
        ),
        child: Row(
          children: [
            if (selectedCircle != null) ...[
              _CircleAvatar(circle: selectedCircle!),
              const SizedBox(width: HavenSpacing.md),
              Expanded(
                child: Text(
                  selectedCircle!.displayName,
                  style: textTheme.titleSmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ] else ...[
              Icon(Icons.groups_outlined, color: colorScheme.onSurfaceVariant),
              const SizedBox(width: HavenSpacing.md),
              Expanded(
                child: Text(
                  'Select a circle',
                  style: textTheme.titleSmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
            AnimatedRotation(
              turns: isOpen ? 0.5 : 0,
              duration: const Duration(milliseconds: 200),
              child: Icon(
                Icons.keyboard_arrow_down,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CircleAvatar extends StatelessWidget {
  const _CircleAvatar({required this.circle});

  final Circle circle;

  @override
  Widget build(BuildContext context) {
    final colorIndex =
        circle.displayName.hashCode.abs() % Colors.primaries.length;
    final circleColor = Colors.primaries[colorIndex];

    return CircleAvatar(
      radius: 16,
      backgroundColor: circleColor.withValues(alpha: 0.2),
      child: Text(
        circle.displayName.isNotEmpty
            ? circle.displayName[0].toUpperCase()
            : '?',
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.bold,
          color: circleColor.shade700,
        ),
      ),
    );
  }
}

class _CircleListItem extends StatelessWidget {
  const _CircleListItem({
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
    final memberCount = circle.members.length;
    final memberText = memberCount == 1 ? '1 member' : '$memberCount members';

    return ListTile(
      dense: true,
      leading: _CircleAvatar(circle: circle),
      title: Text(circle.displayName),
      subtitle: Text(memberText),
      trailing: isSelected
          ? Icon(Icons.check, color: colorScheme.primary)
          : null,
      onTap: onTap,
    );
  }
}

class _NewCircleTile extends StatelessWidget {
  const _NewCircleTile({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return ListTile(
      dense: true,
      leading: CircleAvatar(
        radius: 16,
        backgroundColor: colorScheme.primaryContainer,
        child: Icon(Icons.add, size: 18, color: colorScheme.onPrimaryContainer),
      ),
      title: Text('New Circle', style: TextStyle(color: colorScheme.primary)),
      onTap: onTap,
    );
  }
}
