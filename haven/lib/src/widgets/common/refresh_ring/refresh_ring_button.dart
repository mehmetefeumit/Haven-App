/// The shared "segmented refresh ring" — one app-bar control used by both the
/// Invitations page and the Relay Settings page.
///
/// Tapping the control morphs the refresh icon into a ring of independent arc
/// segments, one per relay being contacted. Each arc animates gray (not yet
/// contacted) → amber (in flight) → green (responded with its data) / red
/// (unreachable or missing data), so the user watches the refresh fill in,
/// relay by relay. A successful all-green result holds briefly, then fades
/// back to the calm icon; a result with any problem stays put until the next
/// refresh so it is never missed.
///
/// The widget is intentionally page-agnostic: it speaks only the shared
/// [RelayRingSlotState] vocabulary and never sees a relay URL, so it can drive
/// both flows and can never leak relay identities into the semantics tree.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/models/relay_ring_slot.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/theme/colors.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Diameter of the painted ring (the icon is sized to match).
const double _kRingDiameter = 22;

/// Size of the idle / no-inbox icon, matched to the ring diameter.
const double _kIconSize = 20;

/// Minimum touch target (WCAG 2.5.5); the visual sits centered inside it.
const double _kTapTarget = 48;

/// Stroke width of an arc segment.
const double _kStrokeWidth = 3;

/// Stroke width of the contrast halo painted behind each solid arc.
const double _kHaloWidth = 5;

/// Angular gap between adjacent arc segments, in degrees.
const double _kGapDegrees = 6;

/// Crossfade between the icon and the ring (and between ring states).
const Duration _kCrossfadeDuration = Duration(milliseconds: 180);

/// Per-arc color transition (gray→amber→green/red).
const Duration _kColorDuration = Duration(milliseconds: 300);

/// Stagger between adjacent arcs lighting up as the ring first appears, so the
/// segments sweep on clockwise rather than all at once.
const Duration _kStaggerStep = Duration(milliseconds: 60);

/// How long an all-green result holds before fading back to the icon.
const Duration _kHoldDuration = Duration(milliseconds: 2500);

/// Thinner stroke for a not-yet-contacted (pending) arc, so it reads as quiet
/// and "not active" by shape — a non-color cue distinct from the solid active
/// arcs (WCAG 1.4.1).
const double _kPendingStrokeWidth = 2;

/// The accessibility vocabulary a host flow uses for the ring's outcome.
///
/// The painter and geometry are identical across flows; only the spoken /
/// labelled meaning of a green vs red segment differs, so each call site picks
/// the wording that is factually correct for it.
enum RefreshRingVocabulary {
  /// Invitations inbox poll: green = the relay answered, red = unreachable.
  responded,

  /// Relay-event check: green = the relay holds the user's data, red = it does
  /// not (missing events) or could not be reached.
  hasData,
}

/// An app-bar refresh control that visualizes a per-relay refresh as a ring of
/// independent arc segments.
class RefreshRingButton extends StatefulWidget {
  /// Creates a [RefreshRingButton].
  const RefreshRingButton({
    required this.slots,
    required this.onPressed,
    required this.tooltip,
    this.noInbox = false,
    this.onNoInbox,
    this.vocabulary = RefreshRingVocabulary.responded,
    super.key,
  });

  /// Per-relay arc states for the current refresh.
  ///
  /// An empty list — or a list whose every element is
  /// [RelayRingSlotState.pending] — is treated as idle and renders the plain
  /// refresh icon.
  final List<RelayRingSlotState> slots;

  /// Called when the control is tapped to start (or restart) a refresh.
  final VoidCallback onPressed;

  /// Tooltip shown on hover / long-press, and the idle accessibility label.
  final String tooltip;

  /// Whether the owning flow has confirmed there is no inbox to refresh.
  ///
  /// When `true`, the control shows a distinct inbox icon and a tap routes to
  /// [onNoInbox] instead of [onPressed]. Only the Invitations page sets this.
  final bool noInbox;

  /// Destination for a tap while [noInbox] is `true` (opens relay settings).
  final VoidCallback? onNoInbox;

  /// The wording used for the screen-reader label and announcements, so the
  /// spoken outcome is accurate for the flow (see [RefreshRingVocabulary]).
  final RefreshRingVocabulary vocabulary;

  @override
  State<RefreshRingButton> createState() => _RefreshRingButtonState();
}

class _RefreshRingButtonState extends State<RefreshRingButton>
    with TickerProviderStateMixin {
  /// One controller per arc, driving that arc's independent color transition.
  /// Independent controllers ensure a settled arc never restarts when a
  /// sibling animates.
  final List<AnimationController> _controllers = [];

  /// One mutable {from,to} color pair per arc, sampled live by the painter.
  final List<_SlotTween> _tweens = [];

  /// One entrance-stagger timer per arc, holding it gray until its turn.
  final List<Timer?> _entranceTimers = [];

  /// Holds a settled all-green result before it fades back to the icon.
  Timer? _dismissTimer;

  /// Set once an all-green result has been held; cleared on the next refresh.
  bool _dismissed = false;

  /// Whether the platform requests reduced motion.
  bool _reducedMotion = false;

  @override
  void initState() {
    super.initState();
    // Park the arcs at their final colors on first mount (no entrance
    // animation): the real flow mounts idle and animates the ring in via
    // didUpdateWidget once a refresh starts.
    _buildControllers(widget.slots, animateEntrance: false);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reducedMotion = MediaQuery.disableAnimationsOf(context);
    // Reconcile here (not in initState) so the dismiss decision is made only
    // once reduced-motion is known — otherwise a reduced-motion mount would
    // schedule a stray hold timer.
    _reconcileDismiss();
  }

  @override
  void didUpdateWidget(RefreshRingButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldSlots = oldWidget.slots;
    final newSlots = widget.slots;

    if (oldSlots.length != newSlots.length) {
      _disposeControllers();
      // Animate the entrance whenever the ring is (re)appearing with relays.
      _buildControllers(newSlots, animateEntrance: !_isIdle(newSlots));
    } else {
      for (var i = 0; i < newSlots.length; i++) {
        if (oldSlots[i] != newSlots[i]) _animateSlot(i, newSlots[i]);
      }
    }

    _maybeAnnounceSettled(oldSlots, newSlots);
    _reconcileDismiss();
  }

  @override
  void dispose() {
    for (final timer in _entranceTimers) {
      timer?.cancel();
    }
    _dismissTimer?.cancel();
    for (final controller in _controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  // --- State helpers -------------------------------------------------------

  bool _isIdle(List<RelayRingSlotState> slots) =>
      slots.isEmpty || slots.every((s) => s == RelayRingSlotState.pending);

  bool _anyChecking(List<RelayRingSlotState> slots) =>
      slots.any((s) => s == RelayRingSlotState.checking);

  bool _settled(List<RelayRingSlotState> slots) =>
      slots.isNotEmpty &&
      slots.every(
        (s) => s == RelayRingSlotState.ok || s == RelayRingSlotState.error,
      );

  bool _allOk(List<RelayRingSlotState> slots) =>
      slots.isNotEmpty && slots.every((s) => s == RelayRingSlotState.ok);

  // --- Animation lifecycle -------------------------------------------------

  AnimationController _newController() =>
      AnimationController(vsync: this, duration: _kColorDuration);

  void _buildControllers(
    List<RelayRingSlotState> slots, {
    required bool animateEntrance,
  }) {
    for (var i = 0; i < slots.length; i++) {
      final controller = _newController();
      _controllers.add(controller);
      _entranceTimers.add(null);

      if (animateEntrance && !_reducedMotion) {
        // Start gray, then sweep to the arc's color, staggered by index.
        _tweens.add(
          _SlotTween(
            from: RelayRingSlotState.pending.color,
            to: slots[i].color,
          ),
        );
        // `controller` is loop-local, so the timer closure captures this arc.
        _entranceTimers[i] = Timer(_kStaggerStep * i, () {
          if (!mounted) return;
          controller.forward(from: 0);
        });
      } else {
        // No entrance animation: park each arc at its final color.
        _tweens.add(_SlotTween(from: slots[i].color, to: slots[i].color));
        controller.value = 1;
      }
    }
  }

  void _animateSlot(int index, RelayRingSlotState next) {
    _entranceTimers[index]?.cancel();
    _entranceTimers[index] = null;
    final controller = _controllers[index];
    // Sample the currently-rendered color so the new transition starts from
    // exactly what is on screen (no flash), even mid-animation.
    final current =
        Color.lerp(_tweens[index].from, _tweens[index].to, controller.value) ??
        _tweens[index].to;
    _tweens[index] = _SlotTween(from: current, to: next.color);
    if (_reducedMotion) {
      controller.value = 1;
    } else {
      controller.forward(from: 0);
    }
  }

  void _disposeControllers() {
    for (final timer in _entranceTimers) {
      timer?.cancel();
    }
    for (final controller in _controllers) {
      controller.dispose();
    }
    _controllers.clear();
    _tweens.clear();
    _entranceTimers.clear();
  }

  void _reconcileDismiss() {
    final slots = widget.slots;
    if (_isIdle(slots) || _anyChecking(slots)) {
      // A fresh (or idle) refresh — drop any earlier settled dismissal.
      _dismissTimer?.cancel();
      _dismissTimer = null;
      _dismissed = false;
      return;
    }
    if (_allOk(slots)) {
      // Hold the success briefly, then return to the calm icon. The hold is a
      // plain Timer (not an animation), so it runs under reduced motion too —
      // only the visual crossfade is skipped there. Otherwise a reduced-motion
      // user would be left with a permanently green ring in the app bar.
      if (!_dismissed && _dismissTimer == null) {
        _dismissTimer = Timer(_kHoldDuration, () {
          _dismissTimer = null;
          if (mounted) setState(() => _dismissed = true);
        });
      }
    } else {
      // Settled with a problem — stay visible (sticky) until the next refresh.
      _dismissTimer?.cancel();
      _dismissTimer = null;
    }
  }

  // --- Interaction & accessibility ----------------------------------------

  void _handleTap() {
    final l10n = AppLocalizations.of(context);
    if (widget.noInbox && widget.onNoInbox != null) {
      widget.onNoInbox!.call();
      _announce(l10n.refreshRingAnnouncementNoInbox);
    } else {
      widget.onPressed();
      _announce(l10n.refreshRingAnnouncementChecking);
    }
  }

  void _maybeAnnounceSettled(
    List<RelayRingSlotState> oldSlots,
    List<RelayRingSlotState> newSlots,
  ) {
    // Fire on ANY transition into a settled state, not just from a checking
    // frame: under reduced motion (or coalesced updates) the widget may never
    // observe an intermediate checking frame, so a checking-gated trigger would
    // drop the outcome announcement.
    if (_settled(oldSlots) || !_settled(newSlots)) return;
    final l10n = AppLocalizations.of(context);
    final hasData = widget.vocabulary == RefreshRingVocabulary.hasData;
    if (_allOk(newSlots)) {
      _announce(
        hasData
            ? l10n.refreshRingAnnouncementAllFound
            : l10n.refreshRingAnnouncementAllOk,
      );
    } else if (newSlots.every((s) => s == RelayRingSlotState.error)) {
      _announce(
        hasData
            ? l10n.refreshRingAnnouncementNoneFound
            : l10n.refreshRingAnnouncementAllError,
      );
    } else {
      final ok = newSlots.where((s) => s == RelayRingSlotState.ok).length;
      _announce(
        hasData
            ? l10n.refreshRingAnnouncementPartialFound(ok, newSlots.length)
            : l10n.refreshRingAnnouncementPartial(ok, newSlots.length),
      );
    }
  }

  void _announce(String message) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      SemanticsService.sendAnnouncement(
        View.of(context),
        message,
        Directionality.of(context),
      );
    });
  }

  String _semanticsLabel(AppLocalizations l10n) {
    final slots = widget.slots;
    final hasData = widget.vocabulary == RefreshRingVocabulary.hasData;
    if (widget.noInbox && widget.onNoInbox != null) {
      return l10n.refreshRingSemanticNoInbox;
    }
    if (_dismissed || _isIdle(slots)) return widget.tooltip;
    if (_anyChecking(slots)) {
      final resolved = slots
          .where(
            (s) => s == RelayRingSlotState.ok || s == RelayRingSlotState.error,
          )
          .length;
      // "checked" is accurate for both flows, so the checking label is shared.
      return l10n.refreshRingSemanticChecking(resolved, slots.length);
    }
    if (_allOk(slots)) {
      return hasData
          ? l10n.refreshRingSemanticAllFound(slots.length)
          : l10n.refreshRingSemanticAllOk(slots.length);
    }
    if (slots.every((s) => s == RelayRingSlotState.error)) {
      return hasData
          ? l10n.refreshRingSemanticNoneFound
          : l10n.refreshRingSemanticAllError;
    }
    final ok = slots.where((s) => s == RelayRingSlotState.ok).length;
    return hasData
        ? l10n.refreshRingSemanticPartialFound(ok, slots.length)
        : l10n.refreshRingSemanticPartial(ok, slots.length);
  }

  _RingGlyph _settledGlyph() {
    final slots = widget.slots;
    if (!_settled(slots)) return _RingGlyph.none;
    return _allOk(slots) ? _RingGlyph.check : _RingGlyph.cross;
  }

  // --- Build ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final showIcon = _dismissed || _isIdle(widget.slots);

    final Widget visual;
    final String childKey;
    // Gate on onNoInbox too, so the inbox icon, the routing label, and the tap
    // target can never desync (they all key off the same condition).
    if (widget.noInbox && widget.onNoInbox != null) {
      visual = const Icon(
        LucideIcons.inbox,
        size: _kIconSize,
        color: HavenSecurityColors.warning,
      );
      childKey = 'noInbox';
    } else if (showIcon) {
      visual = const Icon(LucideIcons.refreshCw, size: _kIconSize);
      childKey = 'icon';
    } else {
      visual = CustomPaint(
        key: WidgetKeys.refreshRingPaint,
        size: const Size(_kRingDiameter, _kRingDiameter),
        painter: _RingPainter(
          slots: List<RelayRingSlotState>.of(widget.slots),
          controllers: _controllers,
          tweens: _tweens,
          glyph: _settledGlyph(),
        ),
      );
      childKey = 'ring';
    }

    return Tooltip(
      message: widget.tooltip,
      child: Semantics(
        button: true,
        label: _semanticsLabel(l10n),
        onTap: _handleTap,
        child: ExcludeSemantics(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _handleTap,
            child: SizedBox(
              width: _kTapTarget,
              height: _kTapTarget,
              child: Center(
                child: RepaintBoundary(
                  child: AnimatedSwitcher(
                    duration: _reducedMotion
                        ? Duration.zero
                        : _kCrossfadeDuration,
                    transitionBuilder: (child, animation) =>
                        FadeTransition(opacity: animation, child: child),
                    child: KeyedSubtree(
                      key: ValueKey<String>(childKey),
                      child: visual,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A mutable from→to color pair for one arc, sampled live by the painter as
/// its controller advances. Mutated only on the single Dart isolate, so the
/// in-place updates from animation callbacks are race-free.
class _SlotTween {
  _SlotTween({required this.from, required this.to});

  Color from;
  Color to;
}

/// The center glyph drawn once a refresh settles: a non-color (shape) cue for
/// the overall outcome, so success/failure is distinguishable without relying
/// on hue (WCAG 1.4.1).
enum _RingGlyph { none, check, cross }

/// Paints the segmented ring: one arc per slot plus an optional center glyph.
///
/// Repaints are driven by [Listenable.merge] over the per-arc controllers, so
/// animation frames never rebuild the widget tree.
class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.slots,
    required this.controllers,
    required this.tweens,
    required this.glyph,
  }) : super(repaint: Listenable.merge(controllers));

  final List<RelayRingSlotState> slots;
  final List<AnimationController> controllers;
  final List<_SlotTween> tweens;
  final _RingGlyph glyph;

  final Paint _arcPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..isAntiAlias = true;

  final Paint _haloPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeWidth = _kHaloWidth
    ..isAntiAlias = true;

  final Paint _glyphPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..strokeWidth = 2
    ..isAntiAlias = true;

  /// Short radial mark drawn across an error arc — a per-segment non-color cue
  /// so a failed relay is distinguishable from a healthy one even before the
  /// settled center glyph appears, and for color-blind users (WCAG 1.4.1).
  final Paint _tickPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeWidth = 2
    ..isAntiAlias = true;

  static const double _degToRad = math.pi / 180;

  /// How far the error tick reaches inward from / outward past the arc
  /// centerline. The outward reach is small (and clamped to the canvas in
  /// [paint]) so the tick never clips at the ring's edge; the visible length
  /// comes from the inward reach.
  static const double _tickInnerExtent = 3.5;
  static const double _tickOuterExtent = 1;

  @override
  void paint(Canvas canvas, Size size) {
    final n = slots.length;
    if (n == 0) return;
    final center = size.center(Offset.zero);
    final radius = (size.shortestSide - _kStrokeWidth) / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final sweepDeg = (360 - n * _kGapDegrees) / n;
    final sweepRad = sweepDeg * _degToRad;

    for (var i = 0; i < n; i++) {
      final state = slots[i];
      final value = i < controllers.length ? controllers[i].value : 1.0;
      final tween = i < tweens.length
          ? tweens[i]
          : _SlotTween(from: state.color, to: state.color);
      final color = Color.lerp(tween.from, tween.to, value) ?? state.color;
      final startRad = (-90 + i * (sweepDeg + _kGapDegrees)) * _degToRad;

      if (state == RelayRingSlotState.pending) {
        // Thin, full-opacity gray arc — a "not yet active" shape cue distinct
        // from the solid active arcs (WCAG 1.4.1). Full alpha keeps it above
        // the 3:1 non-text-contrast floor on both app-bar surfaces (1.4.11).
        _arcPaint
          ..strokeWidth = _kPendingStrokeWidth
          ..color = color;
        canvas.drawArc(rect, startRad, sweepRad, false, _arcPaint);
        continue;
      }

      // The four semantic arc colors already clear the 3:1 graphical-object
      // floor (WCAG 1.4.11) on their own against both app-bar surfaces; this
      // darker translucent halo is supplementary reinforcement (notably for the
      // lower-margin amber), not the sole compliance mechanism.
      _haloPaint.color = _darken(color, 0.15).withValues(alpha: 0.3);
      canvas.drawArc(rect, startRad, sweepRad, false, _haloPaint);

      _arcPaint
        ..strokeWidth = _kStrokeWidth
        ..color = color;
      canvas.drawArc(rect, startRad, sweepRad, false, _arcPaint);

      if (state == RelayRingSlotState.error) {
        // Cross the failed segment with a short radial tick, so error is
        // conveyed by shape (not hue alone) at every phase, not just at settle.
        // Clamp the outer tip to the canvas so it never clips at the edge.
        final midRad = startRad + sweepRad / 2;
        final dir = Offset(math.cos(midRad), math.sin(midRad));
        final outerR = math.min(
          radius + _tickOuterExtent,
          size.shortestSide / 2,
        );
        _tickPaint.color = _darken(color, 0.35);
        canvas.drawLine(
          center + dir * (radius - _tickInnerExtent),
          center + dir * outerR,
          _tickPaint,
        );
      }
    }

    if (glyph != _RingGlyph.none) _paintGlyph(canvas, center, radius);
  }

  void _paintGlyph(Canvas canvas, Offset c, double radius) {
    final s = radius * 0.5;
    if (glyph == _RingGlyph.check) {
      _glyphPaint.color = RelayRingSlotState.ok.color;
      canvas
        ..drawLine(
          c + Offset(-s * 0.62, s * 0.02),
          c + Offset(-s * 0.16, s * 0.46),
          _glyphPaint,
        )
        ..drawLine(
          c + Offset(-s * 0.16, s * 0.46),
          c + Offset(s * 0.64, -s * 0.48),
          _glyphPaint,
        );
    } else {
      _glyphPaint.color = RelayRingSlotState.error.color;
      final d = s * 0.5;
      canvas
        ..drawLine(c + Offset(-d, -d), c + Offset(d, d), _glyphPaint)
        ..drawLine(c + Offset(d, -d), c + Offset(-d, d), _glyphPaint);
    }
  }

  Color _darken(Color color, double amount) {
    final hsl = HSLColor.fromColor(color);
    return hsl
        .withLightness((hsl.lightness - amount).clamp(0.0, 1.0))
        .toColor();
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.glyph != glyph ||
      !listEquals(old.slots, slots) ||
      !identical(old.tweens, tweens) ||
      !identical(old.controllers, controllers);
}
