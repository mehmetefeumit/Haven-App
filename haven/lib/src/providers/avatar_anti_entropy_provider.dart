/// Periodic avatar anti-entropy scheduler (M3 §5.7).
///
/// Re-shares the own avatar into every accepted circle at a jittered
/// interval (24 h normal / 72 h data-saver) to heal dropped chunks,
/// relay churn, and late joiners the epoch trigger missed.
///
/// ## Design
///
/// This provider is intentionally a side-effect provider (returns `void`)
/// anchored in `MapShell` via a simple `ref.read`. It mirrors the pattern
/// used for `selfUpdateProvider` and `evolutionPollerProvider` — invalidate
/// then read to trigger a one-shot run. The periodic timer lives inside
/// [AvatarAntiEntropyNotifier] so its lifetime matches `MapShell`'s.
///
/// ## Jitter
///
/// To prevent a fixed-cadence relay fingerprint, the actual fire time is
/// sampled uniformly in `[interval * 0.75, interval * 1.25]` using
/// [dart:math.Random.secure()]. This matches the invitation-poll jitter
/// pattern in `map_shell.dart`.
///
/// ## Privacy
///
/// The anti-entropy re-share emits at a cadence matched to the location
/// cadence (same kind-445 outer wrapper, same DEC-4 TTL). It is not
/// a distinct un-jittered heartbeat. Do NOT change the timer to a fixed
/// period without re-evaluating relay-fingerprinting risk.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/providers/avatar_data_saver_provider.dart';
import 'package:haven/src/providers/own_avatar_provider.dart';

// ---------------------------------------------------------------------------
// Notifier
// ---------------------------------------------------------------------------

/// Notifier that owns the periodic anti-entropy timer.
///
/// Created once and kept alive for the foreground session. On dispose the
/// timer is cancelled (e.g. app backgrounded / MapShell disposed).
class AvatarAntiEntropyNotifier extends Notifier<void> {
  Timer? _timer;

  // Secure CSPRNG — shared across ticks to avoid per-tick allocation.
  final math.Random _rng = math.Random.secure();

  @override
  void build() {
    // Cancel any previous timer on rebuild (e.g. data-saver toggle).
    _timer?.cancel();
    _timer = null;

    // Auto-dispose: cancel when the notifier is torn down.
    ref.onDispose(() {
      _timer?.cancel();
      _timer = null;
    });

    // Arm the first tick. Subsequent ticks self-rearm after each fire.
    _scheduleNext();
  }

  /// Arms the next timer tick at a jittered interval.
  ///
  /// Jitter range: ±25 % of the effective interval (same fraction as the
  /// invitation-poll jitter in `map_shell.dart`). Sampled fresh on every
  /// reschedule so successive fires are not on a fixed cadence.
  void _scheduleNext() {
    final base = ref.read(avatarDataSaverProvider)
        ? avatarAntiEntropyIntervalDataSaver
        : avatarAntiEntropyInterval;

    final minMs = (base.inMilliseconds * 0.75).round();
    final maxMs = (base.inMilliseconds * 1.25).round();
    final delayMs = minMs + _rng.nextInt(maxMs - minMs + 1);

    _timer = Timer(Duration(milliseconds: delayMs), _onTick);
    debugPrint(
      '[AvatarAntiEntropy] next reshare in '
      '${Duration(milliseconds: delayMs).inMinutes} min',
    );
  }

  void _onTick() {
    // Fire the reshare (best-effort — never throws).
    try {
      ref.read(ownAvatarControllerProvider.notifier).reshareToAllCircles();
      debugPrint('[AvatarAntiEntropy] reshare triggered');
    } on Object catch (e) {
      debugPrint('[AvatarAntiEntropy] reshare error: ${e.runtimeType}');
    }

    // Rearm for the next tick (self-rescheduling timer pattern — mirrors
    // `_scheduleInvitationPoll` in `map_shell.dart`).
    _scheduleNext();
  }

  /// Cancels and immediately re-arms the timer with the current interval.
  ///
  /// Called when the data-saver toggle changes so the new cadence takes
  /// effect on the next tick rather than at the previously scheduled time.
  void reschedule() {
    _timer?.cancel();
    _scheduleNext();
  }

  /// [visibleForTesting] — fires the anti-entropy action immediately.
  ///
  /// Used by unit tests to trigger the action without waiting for a real timer.
  @visibleForTesting
  void triggerForTest() {
    _onTick();
  }

  /// [visibleForTesting] — returns the effective interval for the current
  /// data-saver state, before jitter is applied.
  @visibleForTesting
  Duration get effectiveIntervalForTest =>
      ref.read(avatarDataSaverProvider)
          ? avatarAntiEntropyIntervalDataSaver
          : avatarAntiEntropyInterval;
}

/// Provider owning the periodic anti-entropy timer.
///
/// Anchor this in `MapShell` (or the root widget) by reading it once:
/// ```dart
/// ref.read(avatarAntiEntropyProvider.notifier);
/// ```
/// The notifier's lifetime mirrors the widget tree that holds the reference.
/// On dispose (background / logout) the timer is cancelled automatically.
final avatarAntiEntropyProvider =
    NotifierProvider<AvatarAntiEntropyNotifier, void>(
      AvatarAntiEntropyNotifier.new,
    );
