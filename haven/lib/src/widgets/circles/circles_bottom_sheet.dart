/// Circles bottom sheet widget for Haven.
///
/// A draggable bottom sheet that displays circles and their members,
/// replacing the traditional tab-based navigation.
library;

import 'dart:async';

import 'package:flutter/gestures.dart' show VelocityTracker;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/pages/circles/add_member_page.dart';
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
import 'package:haven/src/utils/map_focus.dart';
import 'package:haven/src/utils/member_display.dart';
import 'package:haven/src/widgets/circles/circle_member_tile.dart';
import 'package:haven/src/widgets/circles/circle_selector.dart';
import 'package:haven/src/widgets/common/empty_state.dart';
import 'package:latlong2/latlong.dart' show LatLng;
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Minimum snap point (collapsed state).
const double _kMinChildSize = 0.12;

/// Low "peek+" snap point. A deliberate resting place between the
/// collapsed peek and the half-open state so the user can park the tray
/// low — showing the drag handle, circle selector, and the top of the
/// member list — without it leaping to half-screen. Also the target
/// `MapShell` collapses to after tap-to-focus, where the map is what the
/// user wants to see.
const double _kPeekChildSize = 0.30;

/// Middle snap point (half expanded). Nudged slightly above one-half so
/// the four snap points are evenly spaced (gaps of 0.18 / 0.25 / 0.30).
const double _kMidChildSize = 0.55;

/// Maximum snap point (fully expanded).
const double _kMaxChildSize = 0.85;

/// Test-only re-export of [_kMaxChildSize] so integration tests can
/// drive the sheet to its maximum snap programmatically (via
/// [CirclesBottomSheetState.controllerForTesting]) without
/// hard-coding the value and risking it drifting from the production
/// constant.
@visibleForTesting
const double kCirclesBottomSheetMaxSizeForTesting = _kMaxChildSize;

/// Ordered snap points the sheet rests at. Must stay sorted ascending —
/// `_selectSnapTarget`'s `firstWhere`/`lastWhere` walk relies on it.
const List<double> _kSnapSizes = [
  _kMinChildSize,
  _kPeekChildSize,
  _kMidChildSize,
  _kMaxChildSize,
];

/// Test-only re-export of [_kSnapSizes] so unit tests assert the
/// snap-selection logic against the production detents without
/// hard-coding values that could drift.
@visibleForTesting
const List<double> kSnapSizesForTesting = _kSnapSizes;

/// Raw expansions within this fraction of the collapsed snap are reported
/// as exactly 0 so the map dim overlay is fully torn down at rest.
///
/// `MapShell`'s programmatic collapse early-returns within 0.01 *size* of
/// [_kMinChildSize], so the sheet can settle a hair above the collapsed
/// snap. The resulting sub-perceptual expansion would
/// otherwise keep an invisible — but pointer-absorbing — scrim over the map,
/// freezing it until the next sheet interaction. 0.02 covers that worst-case
/// ~0.014 residual with margin; at this expansion the scrim alpha
/// (`expansion * 0.5`) is under 0.01, so snapping to 0 has no visible effect.
/// Mirrors `DimOverlay`'s own minimum-visible-opacity guard as defence in
/// depth: either fix alone keeps the map interactive.
const double _kCollapsedExpansionEpsilon = 0.02;

/// Normalizes a raw [DraggableScrollableController.size] to the `[0, 1]`
/// expansion that drives the map dim overlay, snapping residuals within
/// [_kCollapsedExpansionEpsilon] of the collapsed snap to exactly 0.
///
/// Extracted and `@visibleForTesting` so the snap can be unit-tested without
/// reproducing the gesture/animation physics that can strand the residual.
@visibleForTesting
double sheetExpansionForSize(double size) {
  final raw = (size - _kMinChildSize) / (_kMaxChildSize - _kMinChildSize);
  if (raw < _kCollapsedExpansionEpsilon) return 0;
  return raw.clamp(0.0, 1.0);
}

/// Above this fling speed (logical px/s), release projects past the
/// nearest snap to the next snap in the direction of motion. Set well
/// above an unhurried lift (~600-900 px/s) so a casual nudge settles
/// back to the *nearest* snap instead of leaping a whole detent —
/// advancing a detent by flick takes a deliberately firm gesture. 1000
/// px/s on a ~660-pt viewport is ~1.5 screen-heights/sec, hard to reach
/// without meaning to. Material's legacy 500 is tuned for 2-state
/// dismiss sheets, not a multi-detent positioner.
const double _kFlickVelocityPxPerSec = 1000;

/// Test-only re-export so unit tests can probe just-below / just-above
/// the flick gate without hard-coding the value.
@visibleForTesting
const double kFlickVelocityForTesting = _kFlickVelocityPxPerSec;

/// Above this fling speed, release skips intermediate snaps entirely
/// and travels to the extreme in the direction of motion. 2000 px/s
/// roughly matches `UIScrollView`'s "fast" deceleration threshold —
/// on a ~660-pt small-phone viewport, this is reachable with a firm
/// thumb flick without requiring an unrealistic gesture. Left at 2000
/// so a genuine "throw it fully open/closed" still lands reliably.
const double _kBallisticVelocityPxPerSec = 2000;

/// Test-only re-export of the ballistic gate.
@visibleForTesting
const double kBallisticVelocityForTesting = _kBallisticVelocityPxPerSec;

/// Minimum sheet-size delta during a gesture for the release to be
/// treated as a sheet drag (vs. an inner-list scroll that the velocity
/// tracker happened to pick up). Below this, release is a no-op.
const double _kSheetMovedThreshold = 0.005;

/// Debounce window for the snap-arrival accessibility announcement.
/// Prevents stacked utterances when rapid flicks chain into back-to-back
/// snap completions.
const Duration _kSnapDebounce = Duration(milliseconds: 250);

/// Test-only access to the pure snap-target selection logic so the
/// "more intention" thresholds stay locked by unit tests without
/// reproducing the gesture/animation pipeline. Production code calls the
/// private static directly. Mirrors [sheetExpansionForSize].
@visibleForTesting
double selectSnapTargetForTesting(double current, double pxPerSecondY) =>
    CirclesBottomSheetState._selectSnapTarget(current, pxPerSecondY);

/// A draggable bottom sheet displaying circles and their members.
///
/// The sheet has four snap points:
/// - Collapsed (12%): Shows drag handle and circle selector chips
/// - Peek (30%): Selector plus the top of the member list
/// - Half (55%): Selector and member preview
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
  ConsumerState<CirclesBottomSheet> createState() => CirclesBottomSheetState();
}

/// State for [CirclesBottomSheet].
///
/// Public so integration tests can reach the internal
/// [DraggableScrollableController] via [controllerForTesting]; that
/// is the deterministic alternative to `tester.dragFrom`, which is
/// not reliable against the velocity-aware physics pipeline below
/// on slow CI emulators. The class would otherwise be private —
/// production code does not (and should not) reference it.
class CirclesBottomSheetState extends ConsumerState<CirclesBottomSheet> {
  late DraggableScrollableController _controller;

  /// Exposes the internal [DraggableScrollableController] for tests
  /// to drive the sheet's snap position via
  /// [DraggableScrollableController.animateTo] (e.g., to expand the
  /// sheet to [kCirclesBottomSheetMaxSizeForTesting] before tapping
  /// a CTA inside it). Bypasses the synthetic-gesture path used by
  /// `tester.dragFrom`, which doesn't always trigger the
  /// velocity-aware snap.
  ///
  /// Production callers must not use this — pass `widget.controller`
  /// at construction time instead.
  @visibleForTesting
  DraggableScrollableController get controllerForTesting => _controller;

  /// Tracks pointer velocity across the active drag so we can read it at
  /// release. The release velocity selects the snap *target* (see
  /// [_selectSnapTarget]); it deliberately does not drive the arrival
  /// speed, so a fast flick no longer rockets the sheet into place.
  VelocityTracker? _velocityTracker;
  int? _activePointer;
  double? _sizeAtPointerDown;

  /// Last time a snap-arrival announcement fired. See [_kSnapDebounce].
  DateTime? _lastSnapAt;

  /// Monotonic token identifying the active drag-release snap. Bumped
  /// when a new snap starts ([_runSnap]) and when the user grabs the
  /// sheet mid-animation ([_onPointerDown]); the awaited `animateTo`
  /// continuation checks it before firing the haptic/announcement so an
  /// interrupted or superseded snap stays silent.
  int _snapToken = 0;

  /// `true` while a drag-release `animateTo` glide is running, so a fresh
  /// pointer-down knows to interrupt it.
  bool _snapInFlight = false;

  @override
  void initState() {
    super.initState();
    _controller = widget.controller ?? DraggableScrollableController();
    _controller.addListener(_onSheetChanged);
  }

  @override
  void dispose() {
    // Invalidate any in-flight snap continuation so its awaited
    // `animateTo` can't touch the controller after disposal.
    _snapToken++;
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

    // Normalize to [0, 1], snapping a sub-snap residual at the collapsed
    // end to exactly 0 so the parent's full-screen dim overlay is fully
    // removed at rest (see [sheetExpansionForSize]). Without this, the
    // drag-release spring can strand a sub-perceptual positive expansion
    // that keeps an invisible but pointer-absorbing scrim over the map.
    final expansion = sheetExpansionForSize(size);
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
    // Cancel any in-flight snap glide so the user can grab the sheet
    // mid-animation without it fighting the new gesture. Bumping the
    // token silences the pending `animateTo` continuation; the jumpTo
    // halts the controller's animation at the current position.
    if (_snapInFlight) {
      _snapToken++;
      _snapInFlight = false;
      _controller.jumpTo(_controller.size);
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
      unawaited(_runSnap(velocityPxPerSec));
    });
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (event.pointer != _activePointer) return;
    _activePointer = null;
    _velocityTracker = null;
    _sizeAtPointerDown = null;
  }

  Future<void> _runSnap(double pixelsPerSecondY) async {
    if (!_controller.isAttached) return;
    final size = _controller.size;
    final target = _selectSnapTarget(size, pixelsPerSecondY);
    // Already at (or imperceptibly close to) the target snap — nothing to
    // animate, and skipping avoids a spurious arrival announcement.
    if ((target - size).abs() < 0.001) return;

    // Honor reduce-motion: instant snap, still announce the arrival so
    // the interaction is acknowledged without animation.
    if (mounted && MediaQuery.disableAnimationsOf(context)) {
      _controller.jumpTo(target);
      _announceSnapArrival(target);
      return;
    }

    // Halt any default ballistic the underlying scroll position started
    // when the gesture ended, then glide to the snap with the same calm
    // decelerating curve the programmatic collapse path uses. The release
    // velocity has already done its job — it chose `target` in
    // `_selectSnapTarget` — and deliberately does NOT drive the arrival
    // speed, which is what made a fast flick feel like it rocketed the
    // sheet into place.
    _controller.jumpTo(size);

    final token = ++_snapToken;
    _snapInFlight = true;
    await _controller.animateTo(
      target,
      duration: _snapDuration(size, target),
      curve: Curves.easeOutCubic,
    );

    // A mid-flight grab ([_onPointerDown]) or a newer snap bumps
    // `_snapToken` and owns `_snapInFlight`; in that case the awaited
    // animation resolved early at a different position, so stay silent.
    if (token != _snapToken) return;
    _snapInFlight = false;
    if (!mounted || !_controller.isAttached) return;
    // Defence in depth: only acknowledge an arrival that actually landed.
    if ((_controller.size - target).abs() > 0.001) return;
    _announceSnapArrival(target);
  }

  /// Maps a snap-travel distance to a glide duration in the M3 200-450 ms
  /// band (longer transitions for bigger jumps), mirroring
  /// `MapShell._animateSheetDuration` so a manual drag-release settles
  /// with exactly the same pace as a programmatic collapse.
  static Duration _snapDuration(double current, double target) {
    const fullRange = _kMaxChildSize - _kMinChildSize;
    final fraction = (target - current).abs() / fullRange;
    final ms = (220 + 350 * fraction).clamp(200.0, 450.0);
    return Duration(milliseconds: ms.round());
  }

  /// Announces the new snap state to assistive technology. Debounces so
  /// chained flicks (e.g. flick-up then flick-up again before the first
  /// lands) don't spam VoiceOver / TalkBack with stacked utterances.
  /// WCAG 4.1.3 — Status Messages.
  void _announceSnapArrival(double target) {
    if (!mounted) return;
    final now = DateTime.now();
    final last = _lastSnapAt;
    if (last != null && now.difference(last) < _kSnapDebounce) return;
    _lastSnapAt = now;
    final l10n = AppLocalizations.of(context);
    final String message;
    if (target <= _kMinChildSize + 0.001) {
      message = l10n.circlesPanelCollapsedAnnouncement;
    } else if (target >= _kMaxChildSize - 0.001) {
      message = l10n.circlesPanelExpandedAnnouncement;
    } else if (target <= _kPeekChildSize + 0.001) {
      // "Slightly open" reads as unambiguously less than "half open" on
      // first listen — a clearer ordinal than the vaguer "partially open".
      message = l10n.circlesPanelSlightlyOpenAnnouncement;
    } else {
      message = l10n.circlesPanelHalfOpenAnnouncement;
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
      // the SDK) and would fight `_runSnap`, which does its own
      // velocity-aware snap-target selection and then settles with a
      // calm decelerating `animateTo` (the same pace as `MapShell`'s
      // programmatic collapse).
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
                    AppLocalizations.of(context).circlesLoadError,
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
    final l10n = AppLocalizations.of(context);
    // No circles - show empty state
    if (circles.isEmpty) {
      return SliverFillRemaining(
        hasScrollBody: false,
        child: _DimmableBox(
          isDimmed: isDropdownOpen,
          onDimTap: closeDropdown,
          child: HavenEmptyState(
            icon: LucideIcons.users,
            title: l10n.circlesEmptyTitle,
            message: l10n.circlesSheetEmptyMessage,
            actionLabel: l10n.circlesCreateCta,
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
                    l10n.circlesSelectToView,
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
              SliverFillRemaining(
                child: Center(child: Text(l10n.circlesNoMembers)),
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
                                l10n: l10n,
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
    required AppLocalizations l10n,
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
    if (isSelf) return l10n.circleMemberAnnouncementSelf;
    return l10n.circleMemberAnnouncementFallback;
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
    focusMapOnPoint(
      ref: ref,
      context: context,
      target: target,
      announcementName: announcementName,
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
    final l10n = AppLocalizations.of(context);
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
              l10n.commonMemberCount(circle.members.length),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          IconButton(
            key: WidgetKeys.circleDetailsButton,
            tooltip: l10n.circleDetailsButtonTooltip,
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
    final l10n = AppLocalizations.of(context);
    setState(() => _dialogOpen = true);

    bool confirmed;
    try {
      confirmed =
          await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text(l10n.leaveCircleDialogTitle),
              content: Text(l10n.leaveCircleDialogBody),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: Text(l10n.commonCancel),
                ),
                TextButton(
                  key: WidgetKeys.leaveCircleConfirm,
                  onPressed: () => Navigator.of(context).pop(true),
                  style: TextButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.error,
                  ),
                  child: Text(l10n.leaveCircleConfirm),
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
        throw CircleServiceException(l10n.leaveCircleIdentityUnavailable);
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
        SnackBar(content: Text(l10n.leaveCircleSuccess)),
      );
    } on Object catch (e) {
      debugPrint('[Leave] UI caught failure: ${e.runtimeType}');
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.leaveCircleError)),
      );
    } finally {
      if (mounted) {
        setState(() => _isLeaving = false);
      }
    }
  }

  Future<void> _openAddMemberPage(BuildContext context) async {
    // Capture the navigator before the async gap so popping the sheet after
    // the page returns does not reach across an unrelated context check.
    final navigator = Navigator.of(context);
    final circle = widget.circle;
    await navigator.push<void>(
      MaterialPageRoute<void>(
        builder: (_) => AddMemberPage(circle: circle),
      ),
    );
    if (mounted) {
      navigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final circle = widget.circle;
    final self = ref.read(identityProvider).valueOrNull?.pubkeyHex;
    final isAdmin =
        self != null &&
        circle.members.any((m) => m.pubkey == self && m.isAdmin);
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
          Text(l10n.circleDetailsTitle, style: theme.textTheme.titleMedium),
          const SizedBox(height: HavenSpacing.sm),
          Text(
            l10n.commonMemberCount(circle.members.length),
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: HavenSpacing.lg),
          Text(
            l10n.circleDetailsRelaysHeading,
            style: theme.textTheme.titleSmall?.copyWith(color: scheme.primary),
          ),
          const SizedBox(height: HavenSpacing.sm),
          if (circle.relays.isEmpty)
            Text(l10n.circleDetailsNoRelays, style: theme.textTheme.bodySmall)
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
            l10n.circleDetailsRelaysNote,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: HavenSpacing.lg),
          if (isAdmin) ...[
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                key: WidgetKeys.addMemberCta,
                onPressed: () => _openAddMemberPage(context),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    vertical: HavenSpacing.md,
                  ),
                ),
                icon: const Icon(LucideIcons.userPlus),
                label: Text(l10n.circleDetailsAddMember),
              ),
            ),
            const SizedBox(height: HavenSpacing.sm),
          ],
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
              label: Text(l10n.circleDetailsLeaveCircle),
            ),
          ),
        ],
      ),
    );
  }
}
