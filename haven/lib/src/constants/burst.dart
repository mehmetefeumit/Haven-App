/// Timing parameters for the post-circle-add burst-poll windows.
///
/// After the admin creates a circle or the joiner accepts an invitation,
/// the app runs a short, jittered burst of fetches against the existing
/// polling pipeline so both sides see each other on the map within a few
/// seconds (instead of waiting for the next 30 s / 60 s / 2 min tick).
///
/// **Connection-privacy rules** (see CLAUDE.md "Metadata & Connection
/// Privacy"):
///
///   * Window length, per-tick interval, and open-time delay are all
///     sampled from distributions — no fixed cadence on the wire.
///   * Reuses the existing relay client connection. No new sockets.
///   * Episodic short fetches only — no long-lived REQ subscriptions.
///   * Bursts are triggered by the user's own local action; no
///     deterministic input→output timing oracle is created.
///   * One concurrent burst at a time (admin OR joiner, not both); the
///     notifier serialises so multiple TLS-fingerprint-linked subs
///     cannot overlap.
library;

import 'dart:math';

/// Parameters of one burst window.
class BurstWindowParams {
  const BurstWindowParams({
    required this.windowMinSecs,
    required this.windowMaxSecs,
    required this.tickMinSecs,
    required this.tickMaxSecs,
    required this.openDelayMaxSecs,
  });

  /// Inclusive lower bound on the total burst-window length.
  final int windowMinSecs;

  /// Inclusive upper bound on the total burst-window length.
  final int windowMaxSecs;

  /// Inclusive lower bound on the inter-tick interval.
  final int tickMinSecs;

  /// Inclusive upper bound on the inter-tick interval.
  final int tickMaxSecs;

  /// Inclusive upper bound on the random delay before the first tick.
  /// Decouples the burst-open from the user-action wire signal that
  /// triggered it (publish welcome → fetch burst).
  final int openDelayMaxSecs;
}

/// Admin-side burst (after `createCircle` success).
///
/// Window 150–240 s — enough to span the joiner's invitation discovery
/// and acceptance, even if the joiner's app was backgrounded during the
/// last invitation-poll tick.
const BurstWindowParams adminBurst = BurstWindowParams(
  windowMinSecs: 150,
  windowMaxSecs: 240,
  tickMinSecs: 4,
  tickMaxSecs: 8,
  openDelayMaxSecs: 3,
);

/// Joiner-side burst (after `acceptInvitation` success).
///
/// Shorter than the admin window — the joiner only needs to catch the
/// next jittered location publish from one peer (~72–168 s for any
/// online publisher), so 50–80 s is enough on the in-person path.
const BurstWindowParams joinerBurst = BurstWindowParams(
  windowMinSecs: 50,
  windowMaxSecs: 80,
  tickMinSecs: 3,
  tickMaxSecs: 6,
  openDelayMaxSecs: 3,
);

/// Samples a uniform integer in `[min, max]` inclusive.
///
/// Returns `min` when `max <= min` so callers can safely pass equal
/// bounds (degenerate "no jitter" case).
int sampleUniformSecs(int min, int max, Random rng) {
  if (max <= min) return min;
  return min + rng.nextInt(max - min + 1);
}
