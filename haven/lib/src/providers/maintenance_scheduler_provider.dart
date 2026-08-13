/// M8 scheduled-resilience maintenance driver (M8-0 / M8-4 / M8-5).
///
/// Owns four self-rescheduling timers that periodically ask the Rust core to
/// keep the user reachable:
///
/// - **`KeyPackage`** (kinds 30443 + 443) — republish-if-missing so a peer can
///   always fetch fresh init-key material to invite the user. Nominal 10 min.
/// - **Relay list** (kind 10050 inbox + kind 10002 NIP-65 `KeyPackage`) — republish-if-
///   drifted so the user's own relays keep advertising where to reach them.
///   Nominal 30 min.
/// - **Subscription health** (M8-4) — heal dropped live-sync relay connections
///   by re-anchoring subscriptions at their cursors. Nominal 15 min. Engine-
///   coupled: its FFI self-gates on the engine `SESSION`, so it is an inert
///   no-op while `liveSyncEnabled` is off (the engine is never started).
/// - **Public-profile anti-entropy** — bound how stale a co-member's kind-0
///   name/photo can get in a long session where no resume or circle-select
///   ever fires. Nominal 45 min, and the only task gated on the app being
///   foregrounded (see `_appIsForegrounded`). Unlike the other three, this one
///   *dispatches* work rather than awaiting it: overlap protection lives in
///   `MemberProfileRefreshNotifier`, so `_profileAntiEntropyInFlight` does not
///   bound the fetch's duration the way the other in-flight flags do.
///
/// ## Why Dart-timer-driven (not a Rust cron)
///
/// The identity secret lives only in Dart (Flutter secure storage) and the two
/// publishing tasks must sign (10050/10002/30443). A core-resident
/// scheduler cannot sign, and threading the secret into a long-lived Rust task
/// would violate Security Rule 9. So Dart owns the *cadence + secret*; Rust
/// owns the *logic* (probe, live-material gate, stable-`d` seeding, sign,
/// publish). Each publishing tick re-fetches the secret and scrubs it — see
/// `MaintenanceService`. (The health tick needs no secret.)
///
/// ## Engine-independence
///
/// The `KeyPackage` + relay-list tasks fix reachability on today's short-poll
/// receive path, so they run whenever an identity is present, regardless of
/// `liveSyncEnabled`. The subscription-health task is engine-COUPLED but ships
/// **inert**: its FFI reads the engine `SESSION` and no-ops (`engineOff`) while
/// the engine is off, so the timer runs but does nothing until
/// `liveSyncEnabled` flips (M11) and the engine is started.
///
/// ## Fire-on-start + a causal handoff off the login publish
///
/// The first tick of each task fires after a short *initial settle* delay
/// rather than waiting a full interval — prompt enough to be a real startup
/// safety net, but not racing the app's first frames. In addition, the first
/// `KeyPackage` tick performs a **causal handoff**: it `await`s the login-time
/// publish (`keyPackagePublisherProvider`, read in `MapShell.initState`) to
/// *settle* (timeout-capped, best-effort) before probing. This closes a
/// NIP-33 fragmentation edge: if maintenance probed before the login publish
/// landed, it would find no canonical and mint a *fresh* `d` slot competing
/// with the login publish's slot. Waiting for the publish to settle lets
/// maintenance instead **seed** its stable `d` from the just-published
/// canonical (or, if the login publish genuinely failed, publish the first
/// KeyPackage with no rival). The initial delay is a best-effort settle, NOT
/// a protocol guarantee — the `await` is what makes the ordering causal.
///
/// ## Jitter (privacy)
///
/// Each recurring interval is sampled uniformly in `[interval*0.75,
/// interval*1.25]` via `Random.secure`, so the per-tick relay probe is not on
/// a fixed cadence (a weak but free anti-fingerprinting measure). This is an
/// intentional improvement over the plan's literal `Timer.periodic`.
///
/// ## Lifetime + teardown
///
/// Anchored once in `MapShell` via `ref.read(maintenanceSchedulerProvider
/// .notifier)`. All timers are cancelled on dispose ([Ref.onDispose]) and the
/// provider is explicitly invalidated in `IdentityNotifier.deleteIdentity`, so
/// no *new* secret-bearing republish tick is armed after logout. A tick that is
/// already mid-FFI when logout fires completes with its already-scrubbed secret
/// buffer (bounded, publishes only the user's own public 30443/10050/10002 to
/// their own relays — no secret survives).
///
/// Riverpod reuses the *same* notifier instance across an `invalidate`+re-read
/// (verified), so a delete→re-login re-runs [build] on this instance while a
/// prior tick may still be settling. A monotonic generation counter fences each
/// lifecycle: a stale tick from a superseded generation never reschedules or
/// arms a timer, so it cannot orphan or double the new generation's timers.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:haven/src/services/mls_session_handover.dart';
import 'package:haven/src/constants/profile_refresh_tiers.dart';
import 'package:haven/src/providers/key_package_provider.dart';
import 'package:haven/src/providers/member_profile_refresh_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/relay_service.dart';

// ---------------------------------------------------------------------------
// Interval constants
// ---------------------------------------------------------------------------

/// Nominal `KeyPackage` maintenance interval (jittered ±25 % per tick).
const Duration keyPackageMaintenanceInterval = Duration(minutes: 10);

/// First retry delay after a `KeyPackage` tick reported a *transient* failure
/// ([KeyPackageRetryDisposition.retryPromptly]) — a relay that did not answer,
/// or a publish no relay acknowledged.
///
/// Doubles per consecutive failure up to [keyPackageRetryMaxDelay]. The whole
/// ladder sits strictly inside the nominal interval's jitter floor (see that
/// constant), so a failing tick always comes back sooner than a healthy one —
/// which is the entire point: between the failed publish and the next
/// successful one, nobody can invite this account.
const Duration keyPackageRetryPromptDelay = Duration(seconds: 60);

/// Flat retry delay after a `KeyPackage` tick reported a *local* failure
/// ([KeyPackageRetryDisposition.retryLater]) — a broken FFI call or MLS store.
///
/// Not laddered: repeating a broken local call faster buys nothing, and the
/// condition does not heal on a relay's timescale.
const Duration keyPackageRetryLaterDelay = Duration(minutes: 5);

/// Cap on the `KeyPackage` retry ladder.
///
/// Chosen so the jittered retry (max `5 min × 1.25` = 6 min 15 s) stays below
/// the jittered nominal floor (`10 min × 0.75` = 7 min 30 s). A retry that can
/// land later than the ordinary cadence is not a retry.
const Duration keyPackageRetryMaxDelay = Duration(minutes: 5);

/// Nominal relay-list maintenance interval (jittered ±25 % per tick).
const Duration relayListMaintenanceInterval = Duration(minutes: 30);

/// Nominal subscription-health interval (jittered ±25 % per tick). Engine-
/// coupled; a cheap `SESSION`-read no-op while the live-sync engine is off.
const Duration subscriptionHealthInterval = Duration(minutes: 15);

/// Initial settle delay before the first `KeyPackage` tick. Best-effort only —
/// the causal `await` on the login publish (see [_awaitLoginPublishSettled]) is
/// what actually orders maintenance after the login-time publish.
const Duration _keyPackageInitialDelay = Duration(minutes: 2);

/// Initial settle delay before the first relay-list tick.
const Duration _relayListInitialDelay = Duration(minutes: 1);

/// Initial settle delay before the first subscription-health tick.
const Duration _healthInitialDelay = Duration(seconds: 90);

/// Initial settle delay before the first public-profile anti-entropy tick.
///
/// Deliberately later than the other tasks: `MapShell` already fires a
/// cold-start profile refresh ~5 s in, so an early tick here would be a
/// guaranteed no-op. This is the *idle-session* safety net.
const Duration _profileAntiEntropyInitialDelay = Duration(minutes: 10);

/// Cap on how long the first `KeyPackage` tick waits for the login publish to
/// settle before proceeding regardless (a wedged publish must not stall
/// maintenance forever).
const Duration _loginPublishSettleTimeout = Duration(seconds: 60);

// ---------------------------------------------------------------------------
// Notifier
// ---------------------------------------------------------------------------

/// Owns the four maintenance timers for the foreground session.
///
/// Created once and kept alive for the session; on dispose all timers are
/// cancelled. Each task self-reschedules after every fire (one-shot timers, so
/// the next tick is only armed once the current one settles — the no-overlap
/// guard additionally protects against any external/concurrent trigger).
class MaintenanceSchedulerNotifier extends Notifier<void> {
  Timer? _keyPackageTimer;
  Timer? _relayListTimer;
  Timer? _healthTimer;
  Timer? _profileAntiEntropyTimer;

  bool _keyPackageInFlight = false;
  bool _relayListInFlight = false;
  bool _healthInFlight = false;
  bool _profileAntiEntropyInFlight = false;
  bool _disposed = false;

  /// Whether the first `KeyPackage` tick of the current generation still owes
  /// the login-publish causal handoff. Reset per generation in [build].
  bool _awaitedLoginPublish = false;

  /// Consecutive `KeyPackage` ticks that reported a retryable failure. Drives
  /// the retry ladder; reset to 0 by any tick that did not. Reset per
  /// generation in [build].
  int _keyPackageFailureStreak = 0;

  /// Monotonic lifecycle counter. Riverpod reuses this notifier instance across
  /// an `invalidate`+re-read, so a settling tick from a superseded lifecycle
  /// must not touch the current one — every tick captures its generation and
  /// bails (no reschedule, no state mutation) once it is stale.
  int _generation = 0;

  // Secure CSPRNG — shared across ticks to avoid per-tick allocation.
  final math.Random _rng = math.Random.secure();

  /// Test-only tally of how many times the `KeyPackage` timer has been armed
  /// (build + every reschedule). Lets a regression test prove that a stale tick
  /// from a superseded generation does NOT re-arm.
  int _keyPackageArmCount = 0;

  @override
  void build() {
    // Start a fresh lifecycle: cancel any prior timers, reset all per-lifecycle
    // state, and bump the generation so any in-flight tick from the prior
    // lifecycle fences itself out.
    _cancelAll();
    _disposed = false;
    _keyPackageInFlight = false;
    _relayListInFlight = false;
    _healthInFlight = false;
    _profileAntiEntropyInFlight = false;
    _awaitedLoginPublish = false;
    _keyPackageFailureStreak = 0;
    final generation = ++_generation;

    ref.onDispose(() {
      _disposed = true;
      _cancelAll();
    });

    // Fire-on-start: arm each task's first tick at its initial settle delay.
    _armKeyPackage(_keyPackageInitialDelay, generation);
    _armRelayList(_relayListInitialDelay, generation);
    // M8-4 subscription health: engine-coupled but ships inert (its FFI
    // self-gates on the engine SESSION), so the timer is always armed — the
    // tick is a cheap no-op while `liveSyncEnabled` is off.
    _armHealth(_healthInitialDelay, generation);
    // Public-profile anti-entropy: the only trigger that bounds staleness in a
    // long foreground session where no resume or circle-select ever fires.
    // The tick itself checks the app lifecycle (see `_appIsForegrounded`) —
    // widget lifetime is NOT a foreground proxy, since `MapShell` survives
    // backgrounding while location sharing keeps the isolate alive.
    _armProfileAntiEntropy(_profileAntiEntropyInitialDelay, generation);
  }

  void _cancelAll() {
    _keyPackageTimer?.cancel();
    _keyPackageTimer = null;
    _relayListTimer?.cancel();
    _relayListTimer = null;
    _healthTimer?.cancel();
    _healthTimer = null;
    _profileAntiEntropyTimer?.cancel();
    _profileAntiEntropyTimer = null;
  }

  /// Whether [generation] is still the live lifecycle and we are not disposed.
  bool _isCurrent(int generation) => !_disposed && generation == _generation;

  /// Arms (or re-arms) the `KeyPackage` timer for [generation], cancelling any
  /// prior one first so the single [Timer] field is always the sole live timer
  /// — no orphan can leak even if a tick is ever driven out-of-band.
  void _armKeyPackage(Duration delay, int generation) {
    _keyPackageTimer?.cancel();
    _keyPackageArmCount++;
    _keyPackageTimer = Timer(delay, () => _runKeyPackageTick(generation));
  }

  /// Arms (or re-arms) the relay-list timer for [generation].
  void _armRelayList(Duration delay, int generation) {
    _relayListTimer?.cancel();
    _relayListTimer = Timer(delay, () => _runRelayListTick(generation));
  }

  /// Arms (or re-arms) the subscription-health timer for [generation].
  void _armHealth(Duration delay, int generation) {
    _healthTimer?.cancel();
    _healthTimer = Timer(delay, () => _runHealthTick(generation));
  }

  /// Arms (or re-arms) the public-profile anti-entropy timer for [generation].
  void _armProfileAntiEntropy(Duration delay, int generation) {
    _profileAntiEntropyTimer?.cancel();
    _profileAntiEntropyTimer = Timer(
      delay,
      () => _runProfileAntiEntropyTick(generation),
    );
  }

  /// Samples a jittered delay in `[nominal*0.75, nominal*1.25]`.
  Duration _jittered(Duration nominal) {
    final minMs = (nominal.inMilliseconds * 0.75).round();
    final maxMs = (nominal.inMilliseconds * 1.25).round();
    return Duration(milliseconds: minMs + _rng.nextInt(maxMs - minMs + 1));
  }

  /// Causal handoff for the first `KeyPackage` tick: wait for the login-time
  /// publish to settle (so we seed a stable `d` from its canonical rather than
  /// racing it), timeout-capped and best-effort. A failed/timed-out publish is
  /// fine — maintenance is the safety net and republishes if none is reachable.
  Future<void> _awaitLoginPublishSettled() async {
    try {
      await ref
          .read(keyPackagePublisherProvider.future)
          .timeout(_loginPublishSettleTimeout);
    } on Object catch (e) {
      debugPrint('[Maintenance] login-publish settle wait ended: '
          '${e.runtimeType}');
    }
  }

  // --- KeyPackage task ------------------------------------------------------

  Future<void> _runKeyPackageTick(int generation) async {
    if (!_isCurrent(generation)) return;
    if (_keyPackageInFlight) {
      // No-overlap: a previous run is still in flight. Skip — that run will
      // reschedule, so we never arm a duplicate timer.
      return;
    }
    _keyPackageInFlight = true;
    // Null only while the tick has not produced a verdict yet. Anything that
    // leaves the try block without setting it is a failure by definition, so
    // the reschedule below reads a null as one rather than as "fine".
    KeyPackageMaintenanceOutcome? outcome;
    try {
      if (!_awaitedLoginPublish) {
        _awaitedLoginPublish = true;
        await _awaitLoginPublishSettled();
        // Logout / re-login may have superseded us during the settle wait.
        if (!_isCurrent(generation)) return;
      }
      outcome = await ref.read(maintenanceServiceProvider).maintainKeyPackage();
      debugPrint('[Maintenance] KeyPackage tick: $outcome');
    } on Object catch (e) {
      // Defensive: the service is already best-effort, but a throw here would
      // kill the reschedule and leave the loop dead. Never let a tick throw.
      debugPrint('[Maintenance] KeyPackage tick threw: ${e.runtimeType}');
      outcome = const KeyPackageMaintenanceFailed(
        KeyPackageFailureKind.tickErrored,
      );
    } finally {
      // Reset the in-flight flag ONLY for the current generation. A stale tick
      // (superseded by a re-login rebuild) must NOT clear the flag — doing so
      // would clobber a fresh generation's in-flight guard and could let a
      // second overlapping tick run. For a stale generation this whole block
      // is a no-op (build() already reset the flag for the new lifecycle).
      if (_isCurrent(generation)) {
        _keyPackageInFlight = false;
        _armKeyPackage(_nextKeyPackageDelay(outcome), generation);
      }
    }
  }

  /// Decides when the next `KeyPackage` tick should run, given what this one
  /// reported — the point of making the outcome three-way in the first place.
  ///
  /// A failed tick means nobody can invite this account right now, so waiting
  /// out the full nominal interval is the wrong answer; the ladder brings the
  /// next attempt in sooner and widens as the failure persists. A tick that
  /// confirmed health (or landed a publish) clears the streak, so one bad relay
  /// window does not permanently accelerate the loop.
  ///
  /// [outcome] is null only when the tick returned before reaching a verdict,
  /// which is treated as a local failure rather than as success.
  Duration _nextKeyPackageDelay(KeyPackageMaintenanceOutcome? outcome) {
    final disposition = switch (outcome) {
      KeyPackageMaintenanceHealthy() ||
      KeyPackageMaintenancePublished() => null,
      KeyPackageMaintenanceFailed(:final disposition) => disposition,
      null => KeyPackageRetryDisposition.retryLater,
    };

    if (disposition == null ||
        disposition == KeyPackageRetryDisposition.awaitUserAction) {
      // Nothing to escalate: either the account is reachable, or no amount of
      // retrying substitutes for the user logging back in.
      _keyPackageFailureStreak = 0;
      return _jittered(keyPackageMaintenanceInterval);
    }

    _keyPackageFailureStreak++;
    if (disposition == KeyPackageRetryDisposition.retryLater) {
      return _jittered(keyPackageRetryLaterDelay);
    }
    // Doubling ladder, capped. The shift exponent is clamped so a long-lived
    // failure streak cannot overflow it.
    final doublings = math.min(_keyPackageFailureStreak - 1, 16);
    final scaled = keyPackageRetryPromptDelay * (1 << doublings);
    return _jittered(
      scaled > keyPackageRetryMaxDelay ? keyPackageRetryMaxDelay : scaled,
    );
  }

  // --- Relay-list task ------------------------------------------------------

  Future<void> _runRelayListTick(int generation) async {
    if (!_isCurrent(generation)) return;
    if (_relayListInFlight) {
      return;
    }
    _relayListInFlight = true;
    try {
      final result = await ref
          .read(maintenanceServiceProvider)
          .maintainRelayList();
      debugPrint(
        '[Maintenance] relay-list tick: inbox=${result.inbox.action.name}, '
        'keyPackage=${result.keyPackage.action.name}',
      );
    } on Object catch (e) {
      debugPrint('[Maintenance] relay-list tick threw: ${e.runtimeType}');
    } finally {
      // Reset ONLY for the current generation (see the KeyPackage tick's note).
      if (_isCurrent(generation)) {
        _relayListInFlight = false;
        _armRelayList(_jittered(relayListMaintenanceInterval), generation);
      }
    }
  }

  // --- Subscription-health task (M8-4, engine-coupled/inert) ----------------

  Future<void> _runHealthTick(int generation) async {
    if (!_isCurrent(generation)) return;
    if (_healthInFlight) {
      return;
    }
    _healthInFlight = true;
    try {
      // No secret + no circle handle: the FFI reads the engine SESSION and
      // self-gates to `engineOff` when the engine is off (the inert path while
      // `liveSyncEnabled` is false).
      final result = await ref
          .read(maintenanceServiceProvider)
          .maintainSubscriptionHealth();
      debugPrint(
        '[Maintenance] health tick: ${result.action.name} '
        '(relays=${result.relaysTotal}, '
        'stillConnecting=${result.relaysStillConnecting}, '
        'disconnected=${result.relaysDisconnected})',
      );
    } on Object catch (e) {
      debugPrint('[Maintenance] health tick threw: ${e.runtimeType}');
    } finally {
      // Reset ONLY for the current generation (see the KeyPackage tick's note).
      if (_isCurrent(generation)) {
        _healthInFlight = false;
        _armHealth(_jittered(subscriptionHealthInterval), generation);
      }
    }
  }

  // --- Public-profile anti-entropy task -------------------------------------

  /// Whether the app is currently foregrounded.
  ///
  /// `MapShell` (which anchors this scheduler) is NOT disposed when the app is
  /// backgrounded — only on logout/route teardown — and the main isolate stays
  /// alive while background location sharing holds its session. So widget
  /// lifetime is not a foreground proxy: without this check the profile sweep
  /// would fire while backgrounded, contacting the profile relay pool with no
  /// UI to render the result.
  ///
  /// A null `lifecycleState` (before the first lifecycle event, i.e. startup,
  /// and in unit tests) counts as foregrounded.
  static bool _appIsForegrounded() => appIsForegrounded();

  Future<void> _runProfileAntiEntropyTick(int generation) async {
    if (!_isCurrent(generation)) return;
    if (_profileAntiEntropyInFlight) {
      return;
    }
    if (!_appIsForegrounded()) {
      // Backgrounded: re-arm without contacting any relay. Profile freshness is
      // a foreground concern — app resume already refreshes on the way back in.
      debugPrint(
        '[Maintenance] profile anti-entropy tick skipped (background)',
      );
      _armProfileAntiEntropy(_jittered(profileAntiEntropyInterval), generation);
      return;
    }
    _profileAntiEntropyInFlight = true;
    try {
      // Staleness-gated on the periodic tier, so a tick landing shortly after
      // an interactive refresh costs nothing. The refresh notifier owns the
      // all-circles union, own-pubkey inclusion, and concurrency coalescing.
      await ref
          .read(memberProfileRefreshProvider.notifier)
          .refreshAll(maxAge: profilePeriodicMaxAge);
      debugPrint('[Maintenance] profile anti-entropy tick dispatched');
    } on Object catch (e) {
      debugPrint(
        '[Maintenance] profile anti-entropy tick threw: ${e.runtimeType}',
      );
    } finally {
      // Reset ONLY for the current generation (see the KeyPackage tick's note).
      if (_isCurrent(generation)) {
        _profileAntiEntropyInFlight = false;
        _armProfileAntiEntropy(
          _jittered(profileAntiEntropyInterval),
          generation,
        );
      }
    }
  }

  // --- Test seams -----------------------------------------------------------

  /// [visibleForTesting] — runs a public-profile anti-entropy tick immediately.
  @visibleForTesting
  Future<void> triggerProfileAntiEntropyTickForTest() =>
      _runProfileAntiEntropyTick(_generation);

  /// [visibleForTesting] — whether the anti-entropy timer is currently armed.
  @visibleForTesting
  bool get profileAntiEntropyArmedForTest =>
      _profileAntiEntropyTimer?.isActive ?? false;

  /// [visibleForTesting] — runs a `KeyPackage` tick immediately (incl. the
  /// no-overlap guard + reschedule), without waiting for the real timer.
  @visibleForTesting
  Future<void> triggerKeyPackageTickForTest() =>
      _runKeyPackageTick(_generation);

  /// [visibleForTesting] — runs a relay-list tick immediately.
  @visibleForTesting
  Future<void> triggerRelayListTickForTest() =>
      _runRelayListTick(_generation);

  /// [visibleForTesting] — runs a subscription-health tick immediately.
  @visibleForTesting
  Future<void> triggerHealthTickForTest() => _runHealthTick(_generation);

  /// [visibleForTesting] — whether a `KeyPackage` tick is currently in flight.
  @visibleForTesting
  bool get keyPackageInFlightForTest => _keyPackageInFlight;

  /// [visibleForTesting] — total `KeyPackage` timer arms (build + reschedules).
  @visibleForTesting
  int get keyPackageArmCountForTest => _keyPackageArmCount;

  /// [visibleForTesting] — whether any maintenance timer is currently armed
  /// (only an *active* timer counts — a fired-but-not-yet-rescheduled one-shot
  /// is excluded).
  @visibleForTesting
  bool get hasArmedTimersForTest =>
      (_keyPackageTimer?.isActive ?? false) ||
      (_relayListTimer?.isActive ?? false) ||
      (_healthTimer?.isActive ?? false) ||
      (_profileAntiEntropyTimer?.isActive ?? false);
}

/// Provider owning the M8 maintenance timers.
///
/// Anchor this in `MapShell` by reading it once:
/// ```dart
/// ref.read(maintenanceSchedulerProvider.notifier);
/// ```
/// The notifier's lifetime is bounded by the provider container; all timers
/// are cancelled on dispose and on the explicit invalidate in
/// `IdentityNotifier.deleteIdentity`.
final maintenanceSchedulerProvider =
    NotifierProvider<MaintenanceSchedulerNotifier, void>(
      MaintenanceSchedulerNotifier.new,
    );
