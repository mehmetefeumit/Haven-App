/// Circles bottom sheet widget for Haven.
///
/// A draggable bottom sheet that displays circles and their members,
/// replacing the traditional tab-based navigation.
library;

import 'dart:async';

import 'package:flutter/gestures.dart' show VelocityTracker;
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/pages/circles/create_circle_page.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/location_sharing_provider.dart';
import 'package:haven/src/providers/map_controller_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/location_sharing_service.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/utils/member_display.dart';
import 'package:haven/src/widgets/circles/circle_member_tile.dart';
import 'package:haven/src/widgets/circles/circle_selector.dart';
import 'package:haven/src/widgets/common/empty_state.dart';
import 'package:latlong2/latlong.dart' show LatLng;
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Minimum snap point (collapsed state).
const double _kMinChildSize = 0.12;

/// Middle snap point (half expanded).
const double _kMidChildSize = 0.5;

/// Maximum snap point (fully expanded).
const double _kMaxChildSize = 0.85;

/// Ordered snap points the sheet rests at.
const List<double> _kSnapSizes = [
  _kMinChildSize,
  _kMidChildSize,
  _kMaxChildSize,
];

/// Above this fling speed (logical px/s), release projects past the
/// nearest snap to the next snap in the direction of motion. Matches
/// Material's `BottomSheetBehavior` shipping value of 500 px/s.
const double _kFlickVelocityPxPerSec = 500;

/// Above this fling speed, release skips intermediate snaps entirely
/// and travels to the extreme in the direction of motion. 2000 px/s
/// roughly matches `UIScrollView`'s "fast" deceleration threshold —
/// on a ~660-pt small-phone viewport, this is reachable with a firm
/// thumb flick without requiring an unrealistic gesture.
const double _kBallisticVelocityPxPerSec = 2000;

/// Spring shape used by the drag-release snap. iOS 17 `.snappy` preset:
/// perceptual duration 0.5s, slight overshoot (bounce 0.15) so the
/// arrival reads as intentional rather than dead-stop linear.
final SpringDescription _kSnapSpring = SpringDescription.withDurationAndBounce(
  bounce: 0.15,
);

/// Minimum sheet-size delta during a gesture for the release to be
/// treated as a sheet drag (vs. an inner-list scroll that the velocity
/// tracker happened to pick up). Below this, release is a no-op.
const double _kSheetMovedThreshold = 0.005;

/// Debounce window for the snap-arrival haptic. Prevents a buzz when
/// rapid flicks chain into back-to-back snap completions.
const Duration _kHapticDebounce = Duration(milliseconds: 250);

/// A draggable bottom sheet displaying circles and their members.
///
/// The sheet has three snap points:
/// - Collapsed (12%): Shows drag handle and circle selector chips
/// - Half (50%): Shows selector and member preview
/// - Expanded (85%): Full member list with actions
///
/// Notifies the parent of expansion changes via [onExpansionChanged] for
/// coordinating the map dim overlay. When a member tile is tapped and
/// the map is recentered on them, [onMemberFocused] fires so the parent
/// can partially collapse the sheet to reveal the map.
class CirclesBottomSheet extends ConsumerStatefulWidget {
  /// Creates a circles bottom sheet.
  const CirclesBottomSheet({
    required this.onExpansionChanged,
    this.controller,
    this.onMemberFocused,
    super.key,
  });

  /// Called when the sheet expansion changes.
  ///
  /// The value ranges from 0.0 (collapsed) to 1.0 (fully expanded).
  final ValueChanged<double> onExpansionChanged;

  /// Optional controller to programmatically control the sheet.
  final DraggableScrollableController? controller;

  /// Called after the map has been recentered on a member, so the parent
  /// can collapse the sheet to a smaller snap point and reveal the map.
  final VoidCallback? onMemberFocused;

  @override
  ConsumerState<CirclesBottomSheet> createState() => _CirclesBottomSheetState();
}

class _CirclesBottomSheetState extends ConsumerState<CirclesBottomSheet>
    with SingleTickerProviderStateMixin {
  late DraggableScrollableController _controller;

  /// Drives the spring-based snap-on-release. `unbounded` because the
  /// spring may transiently overshoot the [_kMinChildSize, _kMaxChildSize]
  /// range; we clamp on each tick before forwarding to the sheet
  /// controller (which asserts a valid size).
  late AnimationController _snapController;

  /// Tracks pointer velocity across the active drag so we can read it
  /// at release. Replaces Flutter's built-in `_SnappingSimulation` —
  /// which is purely linear and ignores release velocity — with a
  /// spring driven by the actual flick speed.
  VelocityTracker? _velocityTracker;
  int? _activePointer;
  double? _sizeAtPointerDown;

  /// Last time the snap-arrival haptic fired. See [_kHapticDebounce].
  DateTime? _lastHapticAt;

  /// `true` while a release-driven spring snap is in flight; gates
  /// firing the snap-arrival haptic so programmatic `animateTo`
  /// (e.g. tap-to-focus collapse) stays silent.
  bool _hapticPendingAtSettle = false;

  /// Snap point the active spring is targeting; read on completion to
  /// announce the new state to assistive technology. Cleared when the
  /// announcement fires or the spring is cancelled.
  double? _pendingSnapTarget;

  @override
  void initState() {
    super.initState();
    _controller = widget.controller ?? DraggableScrollableController();
    _controller.addListener(_onSheetChanged);
    _snapController = AnimationController.unbounded(vsync: this)
      ..addListener(_onSnapTick)
      ..addStatusListener(_onSnapStatus);
  }

  @override
  void dispose() {
    _snapController
      ..removeListener(_onSnapTick)
      ..removeStatusListener(_onSnapStatus)
      ..dispose();
    // Always remove our listener: when `widget.controller` is owned by
    // the parent it will outlive this state, and a stale listener would
    // call `widget.onExpansionChanged` on an unmounted widget.
    _controller.removeListener(_onSheetChanged);
    if (widget.controller == null) {
      _controller.dispose();
    }
    super.dispose();
  }

  void _onSheetChanged() {
    if (!_controller.isAttached) return;

    final size = _controller.size;

    // Close dropdown when sheet collapses near minimum
    if (size <= _kMinChildSize + 0.02) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ref.read(circleDropdownOpenProvider.notifier).state = false;
        }
      });
    }

    // Normalize expansion from 0.0 to 1.0
    final expansion =
        ((size - _kMinChildSize) / (_kMaxChildSize - _kMinChildSize)).clamp(
          0.0,
          1.0,
        );
    widget.onExpansionChanged(expansion);
  }

  // ---- Spring-snap pipeline ------------------------------------------------

  void _onPointerDown(PointerDownEvent event) {
    if (!_controller.isAttached) return;
    if (_activePointer != null) return;
    _activePointer = event.pointer;
    _sizeAtPointerDown = _controller.size;
    _velocityTracker = VelocityTracker.withKind(event.kind)
      ..addPosition(event.timeStamp, event.position);
    // Cancel any in-flight spring so the user can grab the sheet
    // mid-animation without it fighting the new gesture.
    if (_snapController.isAnimating) {
      _snapController.stop();
      _hapticPendingAtSettle = false;
      _pendingSnapTarget = null;
    }
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (event.pointer != _activePointer) return;
    _velocityTracker?.addPosition(event.timeStamp, event.position);
  }

  void _onPointerUp(PointerUpEvent event) {
    if (event.pointer != _activePointer) return;
    final velocityPxPerSec =
        _velocityTracker?.getVelocity().pixelsPerSecond.dy ?? 0.0;
    final startSize = _sizeAtPointerDown;
    _activePointer = null;
    _velocityTracker = null;
    _sizeAtPointerDown = null;
    if (!_controller.isAttached) return;
    // Filter out inner-list scrolls: only run snap if the drag actually
    // moved the sheet. Without this check, a fast list scroll (which
    // bubbles up as pointer velocity here) could project the sheet
    // past its current snap.
    if (startSize == null) return;
    if ((_controller.size - startSize).abs() < _kSheetMovedThreshold) return;
    // Defer to a post-frame callback so the underlying
    // `DraggableScrollableSheet`'s `goBallistic` runs first; we then
    // override its linear simulation with our spring.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _runSnap(velocityPxPerSec);
    });
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (event.pointer != _activePointer) return;
    _activePointer = null;
    _velocityTracker = null;
    _sizeAtPointerDown = null;
  }

  void _runSnap(double pixelsPerSecondY) {
    if (!_controller.isAttached) return;
    final size = _controller.size;
    final target = _selectSnapTarget(size, pixelsPerSecondY);
    if ((target - size).abs() < 0.001) return;

    // Honor reduce-motion: instant snap, still fire the arrival haptic
    // so the interaction is acknowledged without animation.
    if (mounted && MediaQuery.disableAnimationsOf(context)) {
      _controller.jumpTo(target);
      _announceSnapArrival(target);
      _maybeFireHaptic();
      return;
    }

    // Halt any default ballistic the underlying scroll position started
    // when the gesture ended, then drive our own spring per-tick.
    _controller.jumpTo(size);

    // Convert pixel velocity into size-fraction velocity. Sheet size
    // grows as the user drags upward (negative dy), so the sign flips.
    final viewportHeight = _viewportHeight();
    final sizeVelocityPerSec = viewportHeight > 0
        ? -pixelsPerSecondY / viewportHeight
        : 0.0;

    _snapController.value = size;
    final simulation = SpringSimulation(
      _kSnapSpring,
      size,
      target,
      sizeVelocityPerSec,
    );
    _hapticPendingAtSettle = true;
    _pendingSnapTarget = target;
    _snapController.animateWith(simulation);
  }

  void _onSnapTick() {
    if (!_controller.isAttached) return;
    final clamped = _snapController.value.clamp(_kMinChildSize, _kMaxChildSize);
    _controller.jumpTo(clamped);
  }

  void _onSnapStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && _hapticPendingAtSettle) {
      _hapticPendingAtSettle = false;
      final target = _pendingSnapTarget;
      _pendingSnapTarget = null;
      if (target != null) _announceSnapArrival(target);
      _maybeFireHaptic();
    } else if (status == AnimationStatus.dismissed) {
      _hapticPendingAtSettle = false;
      _pendingSnapTarget = null;
    }
  }

  void _maybeFireHaptic() {
    final now = DateTime.now();
    final last = _lastHapticAt;
    if (last != null && now.difference(last) < _kHapticDebounce) return;
    _lastHapticAt = now;
    unawaited(HapticFeedback.selectionClick());
  }

  /// Announces the new snap state to assistive technology. Shares the
  /// haptic-debounce window so chained flicks (e.g. flick-up then
  /// flick-up again before the first lands) don't spam VoiceOver /
  /// TalkBack with stacked utterances. WCAG 4.1.3 — Status Messages.
  void _announceSnapArrival(double target) {
    if (!mounted) return;
    final now = DateTime.now();
    final last = _lastHapticAt;
    if (last != null && now.difference(last) < _kHapticDebounce) return;
    final String message;
    if (target <= _kMinChildSize + 0.001) {
      message = 'Circles panel collapsed';
    } else if (target >= _kMaxChildSize - 0.001) {
      message = 'Circles panel expanded';
    } else {
      message = 'Circles panel half open';
    }
    unawaited(
      SemanticsService.sendAnnouncement(
        View.of(context),
        message,
        Directionality.of(context),
      ),
    );
  }

  /// Picks the snap point the sheet should land on given the current
  /// position and release velocity. Mirrors Apple Maps / Material's
  /// projection rule:
  /// - slow release (< [_kFlickVelocityPxPerSec]): nearest snap.
  /// - flick (≥ flick threshold): next snap in direction of motion.
  /// - hard fling (≥ [_kBallisticVelocityPxPerSec]): extreme in
  ///   direction of motion, skipping intermediates.
  static double _selectSnapTarget(double current, double pxPerSecondY) {
    final speed = pxPerSecondY.abs();
    // Positive dy = downward = closing; negative = upward = opening.
    final goingUp = pxPerSecondY < 0;

    if (speed >= _kBallisticVelocityPxPerSec) {
      return goingUp ? _kMaxChildSize : _kMinChildSize;
    }

    if (speed >= _kFlickVelocityPxPerSec) {
      if (goingUp) {
        return _kSnapSizes.firstWhere(
          (s) => s > current + 0.001,
          orElse: () => _kMaxChildSize,
        );
      }
      return _kSnapSizes.lastWhere(
        (s) => s < current - 0.001,
        orElse: () => _kMinChildSize,
      );
    }

    // Slow release: snap to geometrically nearest.
    return _kSnapSizes.reduce(
      (a, b) => (a - current).abs() < (b - current).abs() ? a : b,
    );
  }

  double _viewportHeight() {
    final mq = MediaQuery.maybeOf(context);
    if (mq == null) return 0;
    return mq.size.height;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Listener(
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      // `behavior: deferToChild` (default) means we only see pointer
      // events that hit a descendant — drags on the map background
      // bypass us entirely.
      // `snap` defaults to false here on purpose: Flutter's built-in
      // snap simulation is purely linear (see `_SnappingSimulation` in
      // the SDK) and ignores release velocity, which is exactly the
      // problem `_runSnap` solves with a velocity-aware spring.
      child: DraggableScrollableSheet(
        controller: _controller,
        initialChildSize: _kMinChildSize,
        minChildSize: _kMinChildSize,
        maxChildSize: _kMaxChildSize,
        builder: (context, scrollController) {
          return Container(
            // hardEdge clips children to the rounded top corners. Without
            // this, child surfaces (e.g. the dropdown panel below the
            // selector) paint over the rounded corner area because
            // BoxDecoration's borderRadius rounds the *paint* but does
            // not clip child widgets by default. hardEdge is preferred
            // over antiAlias here: the perceptual difference at the
            // sheet's corner radius is nil, and hardEdge avoids a
            // saveLayer cost on every repaint inside the sheet.
            clipBehavior: Clip.hardEdge,
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
            // Material(transparency) provides a Material ancestor for any
            // ListTile rendered inside the sheet (CircleMemberTile,
            // _CircleListItem). Without it, ListTile's debug check walks
            // past the surrounding decoration and trips on the sheet's
            // own DecoratedBox/BoxShadow (Flutter 3.42+ assertion). The
            // sheet's visual surface still comes from the outer
            // Container's BoxDecoration — Material here only contributes
            // to ink splashes and ancestor lookup.
            child: Material(
              type: MaterialType.transparency,
              child: _SheetContent(
                scrollController: scrollController,
                onMemberFocused: widget.onMemberFocused,
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Duration of the content dim/scrim cross-fade when the circle
/// dropdown opens or closes. Shorter than the dropdown's own expand
/// timing (320 ms) so the dim resolves before the panel finishes
/// arriving — the user reads "this is now muted" before the eye lands
/// on the new surface.
const Duration _kDimDuration = Duration(milliseconds: 220);

/// M3 emphasized-decelerate. Matches the dropdown panel's expand
/// curve so the two animations feel like one motion.
const Cubic _kDimCurve = Cubic(0.05, 0.7, 0.1, 1);

/// The content of the bottom sheet.
class _SheetContent extends ConsumerWidget {
  const _SheetContent({required this.scrollController, this.onMemberFocused});

  final ScrollController scrollController;
  final VoidCallback? onMemberFocused;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final circlesAsync = ref.watch(circlesProvider);
    final selectedCircle = ref.watch(selectedCircleProvider);
    final isDropdownOpen = ref.watch(circleDropdownOpenProvider);

    void closeDropdown() {
      ref.read(circleDropdownOpenProvider.notifier).state = false;
    }

    return CustomScrollView(
      controller: scrollController,
      slivers: [
        // Drag handle
        const SliverToBoxAdapter(child: _DragHandle()),

        // Circle selector
        const SliverToBoxAdapter(child: CircleSelector()),

        // Content stays mounted across dropdown open/close so the empty
        // state and no-selection hint don't pop out abruptly. While the
        // dropdown is open the content fades and becomes non-interactive;
        // single-child cases (empty / no-selection / loading / error)
        // additionally get a tappable scrim layered over them so the
        // user can dismiss by tapping the dimmed area. The members case
        // uses sliver-level dim (no scrim — sliver-on-sliver overlay
        // would require a new dependency).
        circlesAsync.when(
          data: (circles) => _buildContent(
            context,
            ref,
            circles,
            selectedCircle,
            isDropdownOpen,
            closeDropdown,
          ),
          loading: () => SliverFillRemaining(
            hasScrollBody: false,
            child: _DimmableBox(
              isDimmed: isDropdownOpen,
              onDimTap: closeDropdown,
              child: const Center(child: CircularProgressIndicator()),
            ),
          ),
          error: (error, _) {
            debugPrint('Error loading circles: ${error.runtimeType}');
            return SliverFillRemaining(
              hasScrollBody: false,
              child: _DimmableBox(
                isDimmed: isDropdownOpen,
                onDimTap: closeDropdown,
                child: Center(
                  child: Text(
                    'Could not load circles',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildContent(
    BuildContext context,
    WidgetRef ref,
    List<Circle> circles,
    Circle? selectedCircle,
    bool isDropdownOpen,
    VoidCallback closeDropdown,
  ) {
    // No circles - show empty state
    if (circles.isEmpty) {
      return SliverFillRemaining(
        hasScrollBody: false,
        child: _DimmableBox(
          isDimmed: isDropdownOpen,
          onDimTap: closeDropdown,
          child: HavenEmptyState(
            icon: LucideIcons.users,
            title: 'No Circles Yet',
            message:
                'Create a circle to start sharing your location '
                'with trusted contacts.',
            actionLabel: 'Create Circle',
            actionKey: WidgetKeys.circlesCreateCta,
            onAction: () {
              Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (context) => const CreateCirclePage(),
                ),
              );
            },
          ),
        ),
      );
    }

    // No circle selected - show hint
    if (selectedCircle == null) {
      return SliverFillRemaining(
        hasScrollBody: false,
        child: _DimmableBox(
          isDimmed: isDropdownOpen,
          onDimTap: closeDropdown,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(HavenSpacing.xl),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    LucideIcons.pointer,
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
        ),
      );
    }

    // Resolve per-member location availability for tap-to-focus. We watch
    // the provider so the tile updates to "tappable" as soon as a new
    // location arrives on a polling cycle. `valueOrNull` keeps the tile
    // interactive-or-not deterministic during the provider's loading
    // transitions: before any fetch completes the list is `null` and
    // every non-self tile renders as no-location until the first refresh.
    final memberLocations =
        ref.watch(memberLocationsProvider).valueOrNull ??
        const <MemberLocation>[];
    final selfPubkey = ref.watch(identityProvider).valueOrNull?.pubkeyHex;

    // Circle selected - show header and members. The SliverIgnorePointer
    // + SliverAnimatedOpacity wrap dims and disables the whole group
    // while the dropdown is open. Sliver groups can't host a tappable
    // scrim overlay without a third-party sliver-stack; the trigger row
    // remains tappable to close.
    return SliverIgnorePointer(
      ignoring: isDropdownOpen,
      sliver: SliverAnimatedOpacity(
        opacity: isDropdownOpen ? 0.35 : 1.0,
        duration: _kDimDuration,
        curve: _kDimCurve,
        sliver: SliverMainAxisGroup(
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
                  final isSelf =
                      selfPubkey != null && member.pubkey == selfPubkey;
                  final memberLocation = isSelf
                      ? null
                      : memberLocations
                            .where((l) => l.pubkey == member.pubkey)
                            .firstOrNull;
                  final selfLatLng = isSelf
                      ? ref.watch(obfuscatedLocationProvider)
                      : null;
                  final hasLocation = isSelf
                      ? selfLatLng != null
                      : memberLocation != null;

                  return Builder(
                    builder: (tileContext) => CircleMemberTile(
                      key: WidgetKeys.memberTile(member.pubkey),
                      member: member,
                      hasLocation: hasLocation,
                      onTap: hasLocation
                          ? () => _focusMember(
                              context: tileContext,
                              ref: ref,
                              target: isSelf
                                  ? selfLatLng!
                                  : LatLng(
                                      memberLocation!.latitude,
                                      memberLocation.longitude,
                                    ),
                              announcementName: _announcementNameFor(
                                ref: ref,
                                member: member,
                                isSelf: isSelf,
                              ),
                            )
                          : null,
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  /// Resolves the name used in screen-reader announcements when the map
  /// recenters on [member]. Falls back to a truncated pubkey if no
  /// display name is available.
  String _announcementNameFor({
    required WidgetRef ref,
    required CircleMember member,
    required bool isSelf,
  }) {
    final selfName = ref.read(displayNameProvider).valueOrNull;
    final selfPubkey = ref.read(identityProvider).valueOrNull?.pubkeyHex;
    final resolved = resolveMemberDisplayName(
      member,
      currentUserPubkey: selfPubkey,
      currentUserDisplayName: selfName,
    );
    if (resolved != null && resolved.isNotEmpty) return resolved;
    if (isSelf) return 'you';
    return 'member';
  }

  /// Moves the map camera to [target] at a zoom floor of 14, never zooming
  /// out, then notifies the parent to collapse the sheet and announces
  /// the action to assistive technology.
  void _focusMember({
    required BuildContext context,
    required WidgetRef ref,
    required LatLng target,
    required String announcementName,
  }) {
    const minFocusZoom = 14.0;
    final controller = ref.read(mapControllerProvider);
    final currentZoom = controller.camera.zoom;
    final zoom = currentZoom < minFocusZoom ? minFocusZoom : currentZoom;
    controller.move(target, zoom);

    // `lightImpact` maps to `UIImpactFeedbackGenerator(.light)` on iOS and
    // conveys "action completed" rather than "value changing" (which is
    // what `selectionClick` signals on scroll-wheel pickers).
    unawaited(HapticFeedback.lightImpact());
    unawaited(
      SemanticsService.sendAnnouncement(
        View.of(context),
        "Map centered on $announcementName's location",
        Directionality.of(context),
      ),
    );
    onMemberFocused?.call();
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

/// Header showing circle member count and an info button that opens the
/// circle details sheet. The Leave Circle action lives inside that sheet.
class _CircleHeader extends StatelessWidget {
  const _CircleHeader({required this.circle});

  final Circle circle;

  Future<void> _showCircleDetails(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(HavenSpacing.base),
        ),
      ),
      builder: (sheetCtx) => _CircleDetailsSheet(circle: circle),
    );
  }

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
            child: Text(
              '${circle.members.length} '
              'member${circle.members.length == 1 ? '' : 's'}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Circle details',
            icon: const Icon(LucideIcons.info),
            onPressed: () => _showCircleDetails(context),
          ),
        ],
      ),
    );
  }
}

/// Wraps a single-child sheet content area so it stays mounted while
/// the circle dropdown is open. When [isDimmed] is true the child fades
/// to a muted state and stops receiving pointer input, and a tappable
/// scrim layer fades in over it; tapping the scrim invokes [onDimTap]
/// (typically to close the dropdown). Reduce-motion is honored through
/// [AnimatedOpacity], which respects the platform animation scale.
class _DimmableBox extends StatelessWidget {
  const _DimmableBox({
    required this.child,
    required this.isDimmed,
    required this.onDimTap,
  });

  final Widget child;
  final bool isDimmed;
  final VoidCallback onDimTap;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        IgnorePointer(
          ignoring: isDimmed,
          child: AnimatedOpacity(
            opacity: isDimmed ? 0.35 : 1.0,
            duration: _kDimDuration,
            curve: _kDimCurve,
            child: child,
          ),
        ),
        Positioned.fill(
          child: IgnorePointer(
            ignoring: !isDimmed,
            child: GestureDetector(
              onTap: onDimTap,
              behavior: HitTestBehavior.opaque,
              child: AnimatedOpacity(
                opacity: isDimmed ? 1.0 : 0.0,
                duration: _kDimDuration,
                curve: _kDimCurve,
                child: ColoredBox(color: Colors.black.withValues(alpha: 0.18)),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Read-only details view for a circle, presented as a bottom sheet
/// from the circle header's info button. Owns the destructive
/// Leave Circle action: button sits below the relay list and closes
/// the sheet on success.
class _CircleDetailsSheet extends ConsumerStatefulWidget {
  const _CircleDetailsSheet({required this.circle});

  final Circle circle;

  @override
  ConsumerState<_CircleDetailsSheet> createState() =>
      _CircleDetailsSheetState();
}

class _CircleDetailsSheetState extends ConsumerState<_CircleDetailsSheet> {
  /// True while the confirmation dialog is open. Disables the leave
  /// button so a rapid dismiss-and-retap cannot open a second dialog and
  /// race on the same MLS group.
  bool _dialogOpen = false;

  /// True while the leave FFI work is running. Swaps the button label
  /// for a progress indicator.
  bool _isLeaving = false;

  Future<void> _confirmLeaveCircle() async {
    if (_dialogOpen || _isLeaving) return;
    setState(() => _dialogOpen = true);

    bool confirmed;
    try {
      confirmed =
          await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Leave Circle'),
              content: const Text(
                'Are you sure you want to leave this circle? '
                'You will no longer receive location updates from its members. '
                'This action cannot be undone.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  style: TextButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.error,
                  ),
                  child: const Text('Leave'),
                ),
              ],
            ),
          ) ??
          false;
    } finally {
      if (mounted) setState(() => _dialogOpen = false);
    }

    if (!confirmed || !mounted) return;

    setState(() => _isLeaving = true);
    final sheetNavigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final selfPubkey = ref.read(identityProvider).valueOrNull?.pubkeyHex;
      if (selfPubkey == null) {
        throw const CircleServiceException('Identity unavailable');
      }
      final circleService = ref.read(circleServiceProvider);
      final locationSharing = ref.read(locationSharingServiceProvider);
      final nostrGroupId = widget.circle.nostrGroupId;
      await circleService.leaveCircle(
        mlsGroupId: widget.circle.mlsGroupId,
        selfPubkeyHex: selfPubkey,
      );
      await locationSharing.removeCircle(nostrGroupId);

      if (!mounted) return;

      ref.read(selectedCircleIdProvider.notifier).state = null;
      ref.invalidate(circlesProvider);

      // Close the details sheet itself — the circle no longer exists.
      sheetNavigator.pop();
      messenger.showSnackBar(
        const SnackBar(content: Text('Left circle successfully')),
      );
    } on Object catch (e) {
      debugPrint('[Leave] UI caught failure: $e');
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('Failed to leave circle')),
      );
    } finally {
      if (mounted) {
        setState(() => _isLeaving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final circle = widget.circle;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        HavenSpacing.base,
        HavenSpacing.sm,
        HavenSpacing.base,
        HavenSpacing.lg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: HavenSpacing.md),
              decoration: BoxDecoration(
                color: scheme.onSurfaceVariant.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Text('Circle details', style: theme.textTheme.titleMedium),
          const SizedBox(height: HavenSpacing.sm),
          Text(
            '${circle.members.length} '
            'member${circle.members.length == 1 ? '' : 's'}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: HavenSpacing.lg),
          Text(
            'Relays for this circle',
            style: theme.textTheme.titleSmall?.copyWith(color: scheme.primary),
          ),
          const SizedBox(height: HavenSpacing.sm),
          if (circle.relays.isEmpty)
            Text('(none recorded)', style: theme.textTheme.bodySmall)
          else
            Card(
              child: Column(
                children: [
                  for (var i = 0; i < circle.relays.length; i++)
                    Column(
                      children: [
                        ListTile(
                          leading: Icon(
                            LucideIcons.cloud,
                            color: scheme.onSurfaceVariant,
                            size: 20,
                          ),
                          title: Text(
                            circle.relays[i].replaceFirst('wss://', ''),
                            style: theme.textTheme.bodyMedium,
                          ),
                        ),
                        if (i < circle.relays.length - 1)
                          const Divider(height: 1, indent: HavenSpacing.base),
                      ],
                    ),
                ],
              ),
            ),
          const SizedBox(height: HavenSpacing.md),
          Text(
            'These relays were chosen when this circle was created and '
            'are not user-editable yet. Independent from your personal '
            'relay settings.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: HavenSpacing.lg),
          const Divider(height: 1),
          const SizedBox(height: HavenSpacing.md),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              key: WidgetKeys.leaveCircleCta,
              onPressed: (_isLeaving || _dialogOpen)
                  ? null
                  : _confirmLeaveCircle,
              style: OutlinedButton.styleFrom(
                foregroundColor: scheme.error,
                side: BorderSide(color: scheme.error.withValues(alpha: 0.5)),
                padding: const EdgeInsets.symmetric(vertical: HavenSpacing.md),
              ),
              icon: _isLeaving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(LucideIcons.logOut),
              label: const Text('Leave Circle'),
            ),
          ),
        ],
      ),
    );
  }
}
