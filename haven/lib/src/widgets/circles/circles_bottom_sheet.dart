/// Circles bottom sheet widget for Haven.
///
/// A draggable bottom sheet that displays circles and their members,
/// replacing the traditional tab-based navigation.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/pages/circles/create_circle_page.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/widgets/circles/circle_member_tile.dart';
import 'package:haven/src/widgets/circles/circle_selector.dart';
import 'package:haven/src/widgets/common/empty_state.dart';

/// Minimum snap point (collapsed state).
const double _kMinChildSize = 0.12;

/// Middle snap point (half expanded).
const double _kMidChildSize = 0.5;

/// Maximum snap point (fully expanded).
const double _kMaxChildSize = 0.85;

/// A draggable bottom sheet displaying circles and their members.
///
/// The sheet has three snap points:
/// - Collapsed (12%): Shows drag handle and circle selector chips
/// - Half (50%): Shows selector and member preview
/// - Expanded (85%): Full member list with actions
///
/// Notifies the parent of expansion changes via [onExpansionChanged] for
/// coordinating the map dim overlay.
class CirclesBottomSheet extends ConsumerStatefulWidget {
  /// Creates a circles bottom sheet.
  const CirclesBottomSheet({
    required this.onExpansionChanged,
    this.controller,
    super.key,
  });

  /// Called when the sheet expansion changes.
  ///
  /// The value ranges from 0.0 (collapsed) to 1.0 (fully expanded).
  final ValueChanged<double> onExpansionChanged;

  /// Optional controller to programmatically control the sheet.
  final DraggableScrollableController? controller;

  @override
  ConsumerState<CirclesBottomSheet> createState() => _CirclesBottomSheetState();
}

class _CirclesBottomSheetState extends ConsumerState<CirclesBottomSheet> {
  late DraggableScrollableController _controller;

  @override
  void initState() {
    super.initState();
    _controller = widget.controller ?? DraggableScrollableController();
    _controller.addListener(_onSheetChanged);
  }

  @override
  void dispose() {
    if (widget.controller == null) {
      _controller.dispose();
    }
    super.dispose();
  }

  void _onSheetChanged() {
    if (!_controller.isAttached) return;

    // Normalize expansion from 0.0 to 1.0
    final size = _controller.size;
    final expansion =
        ((size - _kMinChildSize) / (_kMaxChildSize - _kMinChildSize)).clamp(
          0.0,
          1.0,
        );
    widget.onExpansionChanged(expansion);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return DraggableScrollableSheet(
      controller: _controller,
      initialChildSize: _kMinChildSize,
      minChildSize: _kMinChildSize,
      maxChildSize: _kMaxChildSize,
      snap: true,
      snapSizes: const [_kMinChildSize, _kMidChildSize, _kMaxChildSize],
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: colorScheme.surface,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(HavenSpacing.base),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.15),
                blurRadius: 10,
                offset: const Offset(0, -2),
              ),
            ],
          ),
          child: _SheetContent(scrollController: scrollController),
        );
      },
    );
  }
}

/// The content of the bottom sheet.
class _SheetContent extends ConsumerWidget {
  const _SheetContent({required this.scrollController});

  final ScrollController scrollController;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final circlesAsync = ref.watch(circlesProvider);
    final selectedCircle = ref.watch(selectedCircleProvider);

    return CustomScrollView(
      controller: scrollController,
      slivers: [
        // Drag handle
        const SliverToBoxAdapter(child: _DragHandle()),

        // Circle selector
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.only(bottom: HavenSpacing.sm),
            child: CircleSelector(),
          ),
        ),

        // Content based on selection and circles state
        circlesAsync.when(
          data: (circles) =>
              _buildContent(context, ref, circles, selectedCircle),
          loading: () => const SliverFillRemaining(
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (error, _) => SliverFillRemaining(
            child: Center(
              child: Text(
                'Error loading circles: $error',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildContent(
    BuildContext context,
    WidgetRef ref,
    List<Circle> circles,
    Circle? selectedCircle,
  ) {
    // No circles - show empty state
    if (circles.isEmpty) {
      return SliverFillRemaining(
        child: HavenEmptyState(
          icon: Icons.groups_outlined,
          title: 'No Circles Yet',
          message:
              'Create a circle to start sharing your location '
              'with trusted contacts.',
          actionLabel: 'Create Circle',
          onAction: () {
            Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (context) => const CreateCirclePage(),
              ),
            );
          },
        ),
      );
    }

    // No circle selected - show hint
    if (selectedCircle == null) {
      return SliverFillRemaining(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(HavenSpacing.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.touch_app_outlined,
                  size: 48,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                const SizedBox(height: HavenSpacing.base),
                Text(
                  'Select a circle to view members',
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      );
    }

    // Circle selected - show header and members
    return SliverMainAxisGroup(
      slivers: [
        // Circle header
        SliverToBoxAdapter(child: _CircleHeader(circle: selectedCircle)),

        // Members list
        if (selectedCircle.members.isEmpty)
          const SliverFillRemaining(
            child: Center(child: Text('No members in this circle')),
          )
        else
          SliverList.builder(
            itemCount: selectedCircle.members.length,
            itemBuilder: (context, index) {
              final member = selectedCircle.members[index];
              return CircleMemberTile(member: member);
            },
          ),
      ],
    );
  }
}

/// The drag handle at the top of the sheet.
class _DragHandle extends StatelessWidget {
  const _DragHandle();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: HavenSpacing.sm),
        child: Container(
          width: 32,
          height: 4,
          decoration: BoxDecoration(
            color: Theme.of(
              context,
            ).colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    );
  }
}

/// Header showing circle information.
class _CircleHeader extends StatelessWidget {
  const _CircleHeader({required this.circle});

  final Circle circle;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: HavenSpacing.base,
        vertical: HavenSpacing.sm,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  circle.displayName,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: HavenSpacing.xs),
                Text(
                  '${circle.members.length} member${circle.members.length == 1 ? '' : 's'}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          // Encryption indicator
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: HavenSpacing.sm,
              vertical: HavenSpacing.xs,
            ),
            decoration: BoxDecoration(
              color: HavenSecurityColors.encrypted.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(HavenSpacing.sm),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.lock,
                  size: 14,
                  color: HavenSecurityColors.encrypted,
                ),
                const SizedBox(width: HavenSpacing.xs),
                Text(
                  'E2E',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: HavenSecurityColors.encrypted,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
