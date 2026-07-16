/// Circle selector dropdown widget for Haven.
///
/// An inline expanding dropdown for selecting which circle to view
/// in the bottom sheet. Replaces the horizontal chip list with a
/// vertically expanding section that works within the sliver layout.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/pages/circles/create_circle_page.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/utils/profile_refresh_trigger.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// M3 `motionDurationMedium2` (300 ms) bumped to 320 ms to land at the
/// perceptual midpoint between Material's 300 ms expand+cross-fade and
/// Linear/Notion's 350 ms disclosure timing — long enough to read as
/// intentional, short enough to never drag.
const Duration _kExpandDuration = Duration(milliseconds: 320);

/// Collapse is shorter than expand by design: per M3, accelerate-out
/// curves should resolve quickly so the user perceives "this is gone"
/// rather than "this is still going."
const Duration _kCollapseDuration = Duration(milliseconds: 240);

/// M3 `motionEasingEmphasizedDecelerate`. The panel arrives with most of
/// its motion in the first 60% of the timeline.
const Cubic _kExpandCurve = Cubic(0.05, 0.7, 0.1, 1);

/// M3 `motionEasingEmphasizedAccelerate`. Departures accelerate.
const Cubic _kCollapseCurve = Cubic(0.3, 0, 0.8, 0.15);

/// Inner-content fade interval. Items fade in only after the panel reaches
/// ~40% of its target height, so the surface arrives first and the
/// contents follow — reads as "the surface produced the contents."
const Interval _kContentFadeInterval = Interval(0.4, 1, curve: Curves.easeOut);

/// On collapse, fade content out faster than the surface contracts so
/// items disappear before the bottom edge passes through them.
const Interval _kContentFadeReverseInterval = Interval(
  0,
  0.55,
  curve: Curves.easeIn,
);

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
            AppLocalizations.of(context).circleSelectorLoadError,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.error,
            ),
          ),
        ),
      ),
    );
  }
}

class _DropdownBody extends ConsumerStatefulWidget {
  const _DropdownBody({
    required this.circles,
    required this.selectedCircle,
    required this.isOpen,
  });

  final List<Circle> circles;
  final Circle? selectedCircle;
  final bool isOpen;

  @override
  ConsumerState<_DropdownBody> createState() => _DropdownBodyState();
}

class _DropdownBodyState extends ConsumerState<_DropdownBody>
    with SingleTickerProviderStateMixin {
  /// Single timeline for height, content fade, and chevron rotation. A
  /// shared controller is what makes the open feel like one motion
  /// rather than several near-synchronized ones.
  late final AnimationController _controller;
  late final Animation<double> _expandAnimation;
  late final Animation<double> _fadeAnimation;
  late final Animation<double> _chevronAnimation;

  /// True while the panel content should be in the widget tree. Stays
  /// true during the entire collapse animation and is cleared on
  /// `dismissed`, which fully unmounts the panel — important so that
  /// (a) accessibility tools don't read out hidden circle names,
  /// (b) widget tests can assert collapsed-state by widget presence,
  /// (c) dropdown items can't be tab-focused when off-screen.
  bool _isPanelMounted = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: _kExpandDuration,
      reverseDuration: _kCollapseDuration,
      value: widget.isOpen ? 1.0 : 0.0,
    );
    _controller.addStatusListener(_onAnimationStatus);
    _expandAnimation = CurvedAnimation(
      parent: _controller,
      curve: _kExpandCurve,
      reverseCurve: _kCollapseCurve,
    );
    _fadeAnimation = CurvedAnimation(
      parent: _controller,
      curve: _kContentFadeInterval,
      reverseCurve: _kContentFadeReverseInterval,
    );
    _chevronAnimation = Tween<double>(
      begin: 0,
      end: 0.5,
    ).animate(_expandAnimation);
    _isPanelMounted = widget.isOpen;
  }

  @override
  void didUpdateWidget(_DropdownBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isOpen != oldWidget.isOpen) {
      _animateTo(widget.isOpen);
      _fireHaptic();
      _announce(widget.isOpen);
    }
  }

  @override
  void dispose() {
    _controller
      ..removeStatusListener(_onAnimationStatus)
      ..dispose();
    super.dispose();
  }

  void _onAnimationStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && _isPanelMounted) {
      setState(() => _isPanelMounted = false);
    }
  }

  void _animateTo(bool open) {
    // Mount before animating forward so the first frame already has
    // the panel in the tree (would otherwise pop in late). On reverse
    // we keep it mounted until `dismissed` fires.
    if (open && !_isPanelMounted) {
      setState(() => _isPanelMounted = true);
    }
    // Reduce-motion: skip the timeline entirely. Haptic + semantic
    // announcement still fire so the interaction is acknowledged.
    // Manually drive _isPanelMounted since the dismissed status
    // listener fires synchronously here and a no-op transition won't.
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.value = open ? 1.0 : 0.0;
      if (!open && _isPanelMounted) {
        setState(() => _isPanelMounted = false);
      }
      return;
    }
    if (open) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  void _fireHaptic() {
    unawaited(HapticFeedback.selectionClick());
  }

  void _announce(bool open) {
    if (!mounted) return;
    final view = View.maybeOf(context);
    if (view == null) return;
    final l10n = AppLocalizations.of(context);
    unawaited(
      SemanticsService.sendAnnouncement(
        view,
        open
            ? l10n.circleSelectorExpandedAnnouncement
            : l10n.circleSelectorCollapsedAnnouncement,
        Directionality.of(context),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _TriggerRow(
          selectedCircle: widget.selectedCircle,
          isOpen: widget.isOpen,
          chevronAnimation: _chevronAnimation,
          onTap: () {
            ref.read(circleDropdownOpenProvider.notifier).state =
                !widget.isOpen;
          },
        ),
        // ClipRRect outside SizeTransition: the bottom corners stay
        // rounded throughout the expansion (the clip rect tracks the
        // animated child size), matching the sheet's top-corner radius.
        // SizeTransition's axisAlignment = -1 anchors the top edge so
        // the panel grows downward from the trigger row. The panel
        // unmounts after the collapse animation completes — see
        // [_isPanelMounted] for why.
        if (_isPanelMounted)
          ClipRRect(
            borderRadius: const BorderRadius.vertical(
              bottom: Radius.circular(HavenSpacing.base),
            ),
            child: SizeTransition(
              axisAlignment: -1,
              sizeFactor: _expandAnimation,
              child: FadeTransition(
                opacity: _fadeAnimation,
                child: _ExpandedPanel(
                  circles: widget.circles,
                  selectedCircle: widget.selectedCircle,
                  colorScheme: colorScheme,
                  onSelected: (circle, {required isSelected}) {
                    ref.read(selectedCircleIdProvider.notifier).state =
                        isSelected ? null : circle.mlsGroupId;
                    ref.read(circleDropdownOpenProvider.notifier).state = false;
                    // §6.2: refresh member/own public profiles on
                    // circle-select (a no-op when re-selecting the same
                    // circle to close the dropdown).
                    if (!isSelected) {
                      triggerProfileRefresh(ref, widget.circles);
                    }
                  },
                  onNewCircle: () {
                    ref.read(circleDropdownOpenProvider.notifier).state = false;
                    Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (context) => const CreateCirclePage(),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _ExpandedPanel extends StatelessWidget {
  const _ExpandedPanel({
    required this.circles,
    required this.selectedCircle,
    required this.colorScheme,
    required this.onSelected,
    required this.onNewCircle,
  });

  final List<Circle> circles;
  final Circle? selectedCircle;
  final ColorScheme colorScheme;
  final void Function(Circle circle, {required bool isSelected}) onSelected;
  final VoidCallback onNewCircle;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Divider(
          height: 1,
          indent: HavenSpacing.base,
          endIndent: HavenSpacing.base,
          color: colorScheme.outlineVariant,
        ),
        Material(
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
                  onTap: () => onSelected(circle, isSelected: isSelected),
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
        _NewCircleTile(onTap: onNewCircle),
      ],
    );
  }
}

class _TriggerRow extends StatelessWidget {
  const _TriggerRow({
    required this.selectedCircle,
    required this.isOpen,
    required this.chevronAnimation,
    required this.onTap,
  });

  final Circle? selectedCircle;
  final bool isOpen;
  final Animation<double> chevronAnimation;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Semantics(
      button: true,
      expanded: isOpen,
      label: l10n.circleSelectorLabel,
      child: InkWell(
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
                  key: WidgetKeys.circleSelectorActive(
                    selectedCircle!.nostrGroupId
                        .map(
                          (b) => b.toRadixString(16).padLeft(2, '0'),
                        )
                        .join(),
                  ),
                  child: Text(
                    selectedCircle!.displayName,
                    style: textTheme.titleSmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ] else ...[
                Icon(LucideIcons.users, color: colorScheme.onSurfaceVariant),
                const SizedBox(width: HavenSpacing.md),
                Expanded(
                  child: Text(
                    l10n.circleSelectorPlaceholder,
                    style: textTheme.titleSmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
              RotationTransition(
                turns: chevronAnimation,
                child: Icon(
                  LucideIcons.chevronDown,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
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
    final colorScheme = Theme.of(context).colorScheme;
    // Desaturated HSL hue derived from the circle name keeps each circle
    // visually distinct without the loud Colors.primaries palette.
    final hue = (circle.displayName.hashCode.abs() % 360).toDouble();
    final tint = HSLColor.fromAHSL(1, hue, 0.30, 0.55).toColor();

    return CircleAvatar(
      radius: 16,
      backgroundColor: tint.withValues(alpha: 0.18),
      child: Text(
        circle.displayName.isNotEmpty
            ? circle.displayName.characters.first.toUpperCase()
            : '?',
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.bold,
          color: colorScheme.onSurface,
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
    final memberText = AppLocalizations.of(
      context,
    ).commonMemberCount(circle.members.length);

    // Material(transparency) shields ListTile from Flutter's
    // intermediate-ColoredBox/DecoratedBox assertion (3.42+). The Material
    // painted by _ExpandedPanel's `surfaceContainerLow` is rendered via a
    // ColoredBox inside the Material widget; without this transparent
    // Material directly above ListTile, the ancestor walk hits that
    // ColoredBox before reaching a Material and trips the assertion.
    return Material(
      key: WidgetKeys.circleTile(
        circle.nostrGroupId
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join(),
      ),
      type: MaterialType.transparency,
      child: ListTile(
        dense: true,
        leading: _CircleAvatar(circle: circle),
        title: Text(circle.displayName),
        subtitle: Text(memberText),
        trailing: isSelected
            ? Icon(LucideIcons.check, color: colorScheme.primary)
            : null,
        onTap: onTap,
      ),
    );
  }
}

class _NewCircleTile extends StatelessWidget {
  const _NewCircleTile({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Material(
      type: MaterialType.transparency,
      child: ListTile(
        dense: true,
        leading: CircleAvatar(
          radius: 16,
          backgroundColor: colorScheme.primaryContainer,
          child: Icon(
            LucideIcons.plus,
            size: 18,
            color: colorScheme.onPrimaryContainer,
          ),
        ),
        title: Text(
          AppLocalizations.of(context).circleSelectorNewCircle,
          style: TextStyle(color: colorScheme.primary),
        ),
        onTap: onTap,
      ),
    );
  }
}
