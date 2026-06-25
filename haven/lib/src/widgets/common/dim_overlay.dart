/// Dim overlay widget for Haven.
///
/// Displays a semi-transparent scrim that dims the map behind an expanded
/// bottom sheet and doubles as a one-gesture dismiss surface.
library;

import 'package:flutter/gestures.dart' show kTouchSlop;
import 'package:flutter/material.dart';

/// An animated scrim that dims the map behind an expanded bottom sheet.
///
/// The [opacity] controls how dark the scrim appears, from 0.0 (invisible)
/// to 1.0 (maximum darkness at 50% black). While the scrim is visible it
/// behaves as a one-gesture dismiss surface:
///
/// - A **tap** collapses the sheet (via [onDismiss]) and is shielded from the
///   map, so a dismissing tap never also pokes the map.
/// - A **drag** that starts on the scrim collapses the sheet AND falls through
///   to the map beneath it, so the user pans the map in a single motion
///   instead of first dismissing the scrim and then dragging.
///
/// The drag pass-through is the load-bearing detail: every pointer-handling
/// layer here is [HitTestBehavior.translucent] and the colored fill is wrapped
/// in [IgnorePointer], so the hit-test walk does not stop at the scrim — it
/// continues down the `MapShell` stack to the map, whose own gesture
/// recognizers then handle the pan. The tap-catcher [GestureDetector] still
/// wins a *tap* because, sitting above the map, its tap recognizer enters the
/// gesture arena first; on a drag that recognizer rejects at the touch slop and
/// the map's pan recognizer wins uncontested. The outer [Listener] never joins
/// the arena (listeners only observe), so it can collapse the sheet on a drag
/// without stealing the pointer from the map.
class DimOverlay extends StatefulWidget {
  /// Creates a dim overlay.
  const DimOverlay({required this.opacity, this.onDismiss, super.key});

  /// The opacity of the scrim, from 0.0 to 1.0.
  ///
  /// At 0.0, the scrim is invisible. At 1.0, it is at maximum darkness
  /// (50% black).
  final double opacity;

  /// Called when the user dismisses the scrim, by either tapping it or
  /// starting a drag on it. Typically collapses the expanded bottom sheet.
  ///
  /// Fires at most once per gesture (a pinch's second finger, or a tap that
  /// lands in the same frame a drag already collapsed, cannot fire it again).
  final VoidCallback? onDismiss;

  /// Below this opacity the scrim is visually imperceptible (its black fill is
  /// `opacity * 0.5` alpha, i.e. under 1% here) and the overlay renders nothing
  /// — no scrim, no pointer-handling layers — so every gesture reaches the map
  /// directly.
  ///
  /// This is a correctness guard, not just an optimization: the bottom sheet's
  /// drag-release velocity spring can strand the expansion a hair above its
  /// collapsed snap, and at that sub-perceptual opacity the scrim must not keep
  /// any pointer-handling layer mounted over the map. The threshold absorbs
  /// that worst-case residual. Mirrored by `sheetExpansionForSize` in
  /// `circles_bottom_sheet.dart`, which snaps the same residual band to exactly
  /// 0 — either guard alone keeps the map interactive.
  static const double _kMinVisibleOpacity = 0.02;

  @override
  State<DimOverlay> createState() => _DimOverlayState();
}

class _DimOverlayState extends State<DimOverlay> {
  /// The first pointer to land on the scrim during the current gesture.
  /// Later fingers (e.g. the second finger of a pinch) are ignored so a
  /// multi-touch gesture cannot fire [DimOverlay.onDismiss] more than once.
  int? _activePointer;

  /// Where [_activePointer] went down, so drag distance is measured from the
  /// gesture's true origin rather than per-event deltas — which never
  /// individually exceed the slop on a slow drag.
  Offset? _downPosition;

  /// Set once [DimOverlay.onDismiss] has fired for the active gesture, so
  /// neither a later move nor the tap-catcher can fire it a second time.
  /// Cleared on a fresh pointer-down, on pointer-cancel, and on scrim
  /// teardown — but deliberately NOT on pointer-up, because the tap-catcher's
  /// `onTap` resolves *after* the up event and relies on this flag to know a
  /// drag already collapsed; clearing it on up would reopen the double-fire
  /// window.
  bool _dismissed = false;

  @override
  void didUpdateWidget(DimOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    // When the scrim fades below the visible threshold mid-collapse, its
    // pointer-handling layers unmount (build returns SizedBox.shrink), so a
    // pointer still down when that happens never delivers its up event here
    // and [_activePointer] would stay set. Left stale, the `!= null` guard in
    // [_onPointerDown] would swallow the first pointer of the *next* drag once
    // the scrim reappears. Clear the in-flight gesture as soon as the scrim is
    // gone — any tracking is moot without a scrim to dismiss.
    if (widget.opacity < DimOverlay._kMinVisibleOpacity) {
      _resetGesture();
    }
  }

  void _onPointerDown(PointerDownEvent event) {
    if (_activePointer != null) return;
    _activePointer = event.pointer;
    // Track the local position (relative to this overlay) so the slop check
    // stays correct even under a transformed ancestor — global `position`
    // would measure distance in the wrong space.
    _downPosition = event.localPosition;
    _dismissed = false;
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (event.pointer != _activePointer || _dismissed) return;
    final origin = _downPosition;
    if (origin == null) return;
    // A drag — collapse the sheet. The same pointer stream also reaches the
    // map (every layer here is translucent and the fill is hit-invisible), so
    // the map pans in this very gesture.
    if ((event.localPosition - origin).distance > kTouchSlop) {
      _dismissed = true;
      widget.onDismiss?.call();
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    if (event.pointer != _activePointer) return;
    // Deliberately do not clear [_dismissed] here: the tap-catcher's `onTap`
    // resolves after this up event, and it relies on [_dismissed] to know a
    // drag already collapsed. The next pointer-down clears it.
    _activePointer = null;
    _downPosition = null;
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (event.pointer != _activePointer) return;
    // A cancel aborts the gesture entirely (the tap-catcher cancels too, so no
    // `onTap` will fire after this) — clear the whole gesture, including
    // [_dismissed], so the next gesture starts clean.
    _resetGesture();
  }

  void _resetGesture() {
    _activePointer = null;
    _downPosition = null;
    _dismissed = false;
  }

  void _onTap() {
    // The tap recognizer rejects once the drag slop is crossed, so this only
    // fires for a genuine tap. The guard covers the rare frame where a drag
    // already collapsed via [_onPointerMove] within the same gesture.
    if (_dismissed) return;
    _dismissed = true;
    widget.onDismiss?.call();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.opacity < DimOverlay._kMinVisibleOpacity) {
      return const SizedBox.shrink();
    }

    return Listener(
      // Translucent: observe the pointer stream for drag-to-dismiss without
      // joining the gesture arena or blocking the map below.
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      child: GestureDetector(
        // Translucent so a drag falls through to the map; the tap recognizer
        // still wins a tap (this layer is hit-tested above the map) and so
        // shields the map from a dismissing tap.
        behavior: HitTestBehavior.translucent,
        onTap: _onTap,
        // IgnorePointer keeps the colored fill out of hit-testing. Without it
        // the fill (a ColoredBox, which is hit-opaque) would absorb the hit and
        // stop the stack walk before it reached the map — freezing the map.
        child: IgnorePointer(
          child: AnimatedContainer(
            // Honor reduce-motion: skip the scrim crossfade when the user has
            // asked the OS to disable animations, matching how `MapShell`
            // gates the sheet's own collapse.
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 150),
            color: Colors.black.withValues(alpha: widget.opacity * 0.5),
          ),
        ),
      ),
    );
  }
}
