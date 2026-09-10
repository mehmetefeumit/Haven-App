import 'package:flutter/foundation.dart';

import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/fresh_secret.dart';

/// Thrown by the live-sync subscription service for setup/teardown failures.
///
/// Carries a generic message only — never a raw FFI error (which could leak MLS
/// group ids / internal state); details go to `debugPrint` (Security Rule 8).
class SubscriptionServiceException implements Exception {
  /// Creates a subscription service exception.
  const SubscriptionServiceException(this.message);

  /// A generic, user-safe message.
  final String message;

  @override
  String toString() => 'SubscriptionServiceException: $message';
}

/// Whether stopping the live-sync session actually let go of the engine's
/// `Arc<CircleManager>` — and with it the MLS database's Rule-14 guard.
///
/// Returned rather than swallowed because the two failing states are opposite
/// instructions to the caller. A stop that drained means the guard is this
/// isolate's to give away; a stop that did not means the engine's supervisor
/// tasks are STILL ingesting through that manager, and anything the caller does
/// next on the assumption it was released (disposing its own handle, handing
/// the session to the foreground service) frees nothing and leaves the guard
/// owned by a Rust static that no Dart handle in any isolate references.
enum LiveSyncStopOutcome {
  /// No engine was running, so nothing was holding anything.
  idle,

  /// The engine stopped and its handle was released.
  stopped,

  /// The engine reported a timed-out stop on both the attempt and the retry:
  /// its supervisor tasks are still running and still hold the guard.
  stillHolding,
}

/// Consumes the Rust live-sync engine's event stream for the session lifetime.
///
/// Started on login, resumed on app-resume, stopped on logout. Gated behind
/// `liveSyncEnabled` (default OFF) by its callers, so this is inert until M11.
abstract class SubscriptionService {
  /// Builds the engine + starts the session for `groups` (accepted circles) and
  /// the user's `inboxRelays`, then begins consuming `liveEvents()`.
  Future<void> start({
    required List<FfiGroupSpec> groups,
    required List<String> inboxRelays,
  });

  /// Re-anchors the session after a background period / reconnect.
  ///
  /// The FOREGROUND re-anchor (app resume, whole-session repair): it always
  /// carries the inbox REQ, so an open app can always receive an invitation.
  /// A background burst must use [openBackgroundBurst] instead.
  Future<void> resumeAfterBackground();

  /// Opens ONE background burst — the same re-anchor, plus the inbox fold that
  /// puts the inbox REQ on only every k-th burst and advances the counter
  /// deciding it.
  ///
  /// Separate from [resumeAfterBackground] because only a burst may consume a
  /// fold position: routing bursts through the foreground entry point would
  /// leave the fold permanently un-applied, and every burst would re-request
  /// the bounded inbox window.
  ///
  /// THROWS on failure, unlike [resumeAfterBackground].
  ///
  /// The foreground re-anchor is one of several redundant repairs — the health
  /// tick and the next app resume both retry it — so swallowing there costs
  /// nothing. A burst open has no redundancy: a swallowed failure leaves this
  /// burst holding no subscription at all, and a caller that went on to wait
  /// for a backlog would spend its entire budget learning nothing.
  ///
  /// The caller must still pause in its `finally`. The engine clears its
  /// paused flag before it touches a socket and RESTORES it on every failure
  /// exit — the dominant one (a bucket no relay accepted) also sweeps the
  /// registrations the open had already made, drains the publish gauge and
  /// terminates every relay, while the early shutdown exit restores the flag
  /// and deliberately leaves the radio alone. So a failed open leaves a
  /// session that READS paused and may still hold sockets, and which of those
  /// exits it took is not observable from here.
  Future<void> openBackgroundBurst();

  /// Waits for every endpoint the current burst opened to finish its stored
  /// replay, so a peer commit received while paused is APPLIED before the burst
  /// encrypts its location.
  ///
  /// Returns [BacklogOutcomeFfi.timedOut] when the wait's budget elapsed with
  /// an endpoint still silent — a report, not a failure: the burst publishes
  /// anyway, exactly as the foreground does with a slow REQ. With no session it
  /// answers `timedOut`, which is the outcome that makes no promise.
  Future<BacklogOutcomeFfi> waitBacklogSettled();

  /// Holds the engine's sockets open until this burst's commit traffic has
  /// quiesced, so the [pauseSubscriptions] that follows cannot cut a commit
  /// between SEND and OK (Security Rule 13).
  ///
  /// A burst that saw no commit activity returns immediately.
  ///
  /// NEVER throws, and never carries a timeout. It sits immediately before the
  /// pause on the same `finally` path, and both properties protect the same
  /// thing: a throw here would skip the pause and leave the burst's sockets
  /// open for the whole gap to the next one, while a caller-side bound would
  /// let the process suspend with a commit still between SEND and OK — the
  /// engine's own wait is bounded by the traffic it is settling, not by a
  /// clock. Pinned by `test/lints/commit_critical_no_timeout_test.dart`.
  Future<void> settleBeforePause();

  /// Closes the burst: drops every standing REQ and disconnects the engine's
  /// sockets, leaving the session alive and re-openable by the next burst.
  ///
  /// Call from a `finally`, after [settleBeforePause]. Never wrap it in a
  /// `.timeout(` — its marker drain is bounded by backlog size, not by a clock,
  /// and cutting it would leave the pause half-done: the Dart future would
  /// complete, the caller would return, and the process could suspend with the
  /// Rust future still holding a commit between SEND and OK (Security Rule
  /// 13), which is a roster fork rather than a lost sample. A `.timeout(` here
  /// does not even cancel that future. Pinned by
  /// `test/lints/commit_critical_no_timeout_test.dart`.
  Future<void> pauseSubscriptions();

  /// Subscribes the running session to ONE additional circle incrementally
  /// (delta only), without re-anchoring any other circle's subscription. Used
  /// by the live-sync resubscriber to re-anchor an added / relay-rotated
  /// circle without a full stop+start.
  ///
  /// Throws if there is no active session (the caller falls back to a full
  /// restart) or on a hard error.
  Future<void> subscribeCircle(FfiGroupSpec spec);

  /// Unsubscribes the running session from ONE circle (delta only).
  /// Idempotent for an unknown circle (the engine no-ops). Throws if there is
  /// no active session (the caller falls back to a full restart) or on a hard
  /// error.
  Future<void> unsubscribeCircle(Uint8List nostrGroupId);

  /// Stops + drops the session (logout / teardown). Idempotent.
  ///
  /// Reports whether the engine actually released its manager `Arc` — see
  /// [LiveSyncStopOutcome]. Callers that only tear down may ignore it; the
  /// pause-time handoff must not.
  Future<LiveSyncStopOutcome> stop();

  /// Whether a live session is currently running.
  bool get isRunning;

  /// Whether the session has ENTERED the paused state.
  ///
  /// Orthogonal to [isRunning], which stays `true` across a pause: the session
  /// is alive. A caller deciding whether to re-anchor must read this —
  /// re-anchoring a paused engine would re-open standing REQs in the
  /// background and undo the pause.
  ///
  /// Deliberately NOT "holds no REQ and no socket". The engine raises this
  /// flag as the FIRST statement of its pause — before it drops the standing
  /// REQs, before the router drain, before the publish-drain wait and before
  /// the disconnect — so it reads `true` while every one of those steps is
  /// still running or timing out.
  ///
  /// It is one bit and it cannot say how it got there: a completed pause, a
  /// pause still draining, a burst that is part way through opening, and a
  /// failed FFI read (which answers `false`) are indistinguishable. Read it as
  /// "the engine has entered its paused state", never as "the radio is off" —
  /// and never as an instruction, because the two production readers take
  /// OPPOSITE actions from the same `true`. Backgrounded, a re-anchor would
  /// undo the pause and must not happen (the engine's own health tick refuses
  /// for that reason). On resume, [MapShell.reanchorOnResume] re-anchors
  /// PRECISELY because it is `true`: a burst paused the engine behind the
  /// foreground's first re-anchor, and nothing else recovers that.
  bool get isPaused;
}

/// The pure, FFI-free router that maps one [FfiRelayEvent] to provider/persist
/// side effects. Extracted from the FFI lifecycle so it is unit-testable: feed
/// constructed [FfiRelayEvent]s and assert the injected ops/callbacks fire.
///
/// Every side effect is individually `try/on Object catch`-guarded so one bad
/// event (an invalidation throw, an unparseable payload) can never break the
/// stream loop.
class LiveEventRouter {
  /// Creates a router over its injected dependencies.
  LiveEventRouter({
    required this.circleService,
    required this.circlesSnapshot,
    required this.secretBytes,
    required this.parseLocation,
    required this.ingestLocation,
    required this.reconcileRoster,
    required this.onLocationsChanged,
    required this.onGroupUpdated,
    required this.onInvitationReceived,
    required this.onStatus,
  });

  /// Circle service (for invitation processing) — mockable.
  final CircleService circleService;

  /// Snapshot of the user's joined circles (to resolve a `nostr_group_id`).
  final Future<List<Circle>> Function() circlesSnapshot;

  /// Provides the identity secret bytes for invitation unwrapping. Ownership
  /// of each fetched buffer transfers to this router, which zeroizes it after
  /// use rather than copying it (Security Rule 9 — see `takeSecretOwnership`).
  final Future<List<int>> Function() secretBytes;

  /// Parses an engine Location `content` + sender into a [DecryptedLocation],
  /// or returns `null` if the content is not a parseable `LocationMessage`
  /// (e.g. a legacy `haven-avatar-*` chunk from a pre-migration client —
  /// silently skipped, not retried). The default impl wraps the Rust
  /// `parseEngineLocation` helper; tests inject a fake.
  final Future<DecryptedLocation?> Function(String content, String senderPubkey)
  parseLocation;

  /// Persists one streamed location into the location cache + store.
  final Future<void> Function(Circle circle, DecryptedLocation decrypted)
  ingestLocation;

  /// Reconciles a circle's cached members against the current MLS roster
  /// (evicts a departed member) on a group update.
  final Future<void> Function(Circle circle) reconcileRoster;

  /// Invalidate the member-locations provider (a new location landed).
  final void Function() onLocationsChanged;

  /// A circle's roster changed — invalidate circles + locations.
  final void Function(Circle circle) onGroupUpdated;

  /// A new invitation was processed — invalidate invitations + circles.
  final void Function() onInvitationReceived;

  /// A non-content status/lifecycle signal from the engine.
  final void Function(FfiSyncStatusReason reason) onStatus;

  /// Routes one engine event to its side effects. Never throws.
  /// First 4 bytes of a nostr-group-id as hex (8 chars) — matches the Rust
  /// engine's `[live_sync::worker] group=…` prefix for cross-log correlation.
  /// The `nostr_group_id` is pseudonymous (Protocol Rule 4), never the real MLS
  /// group id — safe to log.
  static String _shortGroupHex(Uint8List g) =>
      g.take(4).map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// Full hex of a `nostr_group_id`, for map keys (`Uint8List` has identity
  /// equality, so the bytes themselves cannot key a map).
  static String _groupKey(Uint8List g) =>
      g.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// Circles that have produced ONE unconfirmed wedge verdict, keyed by
  /// [_groupKey], valued by the [_reanchorGeneration] it arrived in. Bounded by
  /// the circle roster, and an entry leaves the moment its circle is blocked.
  /// See [_handleUnrecoverable].
  final Map<String, int> _unconfirmedWedges = {};

  /// Counts engine re-anchors seen on this stream. Two wedge verdicts for one
  /// circle only agree if they land in DIFFERENT generations.
  int _reanchorGeneration = 0;

  Future<void> handleEvent(FfiRelayEvent event) async {
    // Diagnostic (M11 e2e triage): confirm the engine's bus event actually
    // reaches the Dart consumer (the Rust side logs `process_group_event …
    // Processed`; this proves the FFI stream → router hop). Group prefix only.
    if (kDebugMode) {
      final g = event.nostrGroupId;
      debugPrint(
        '[Subscription] stream event kind=${event.kind}'
        '${g == null ? '' : ' group=${_shortGroupHex(g)}…'}',
      );
    }
    switch (event.kind) {
      case FfiRelayEventKind.location:
        await _handleLocation(event);
      case FfiRelayEventKind.groupUpdate:
        await _handleGroupUpdate(event);
      case FfiRelayEventKind.welcome:
        await _handleWelcome(event);
      case FfiRelayEventKind.status:
        await _handleStatus(event);
    }
  }

  Future<Circle?> _resolveCircle(Uint8List nostrGroupId) async {
    try {
      final circles = await circlesSnapshot();
      return circles
          .where((c) => listEquals(c.nostrGroupId, nostrGroupId))
          .firstOrNull;
    } on Object catch (e) {
      debugPrint('[Subscription] circle resolve failed: ${e.runtimeType}');
      return null;
    }
  }

  Future<void> _handleLocation(FfiRelayEvent event) async {
    final content = event.content;
    final sender = event.senderPubkey;
    final nostrGroupId = event.nostrGroupId;
    if (content == null || sender == null || nostrGroupId == null) return;

    final circle = await _resolveCircle(nostrGroupId);
    if (circle == null) {
      // Diagnostic (M11 e2e triage): a live location the engine `Processed` was
      // DROPPED here because its group is not in the circles snapshot — the
      // prime suspect for "engine processed it fast but memberLocationsProvider
      // never surfaces it" after a mid-session circle-create / resubscribe (a
      // stale snapshot). Group prefix only (pseudonymous).
      if (kDebugMode) {
        final g = _shortGroupHex(nostrGroupId);
        debugPrint(
          '[Subscription] location DROPPED — group=$g… '
          'not in the circles snapshot (stale resubscribe?)',
        );
      }
      return; // not a joined circle
    }

    final DecryptedLocation? decrypted;
    try {
      decrypted = await parseLocation(content, sender);
    } on Object catch (e) {
      // Not a parseable LocationMessage (e.g. a legacy avatar chunk).
      debugPrint('[Subscription] location parse skipped: ${e.runtimeType}');
      return;
    }
    if (decrypted == null) return;

    try {
      await ingestLocation(circle, decrypted);
      onLocationsChanged();
      // Diagnostic (M11 e2e triage): the full delivery path completed — engine
      // Processed → stream → router → cache + provider invalidation.
      if (kDebugMode) {
        final g = _shortGroupHex(nostrGroupId);
        debugPrint('[Subscription] location INGESTED — group=$g…');
      }
    } on Object catch (e) {
      debugPrint('[Subscription] location ingest failed: ${e.runtimeType}');
    }
  }

  Future<void> _handleGroupUpdate(FfiRelayEvent event) async {
    final nostrGroupId = event.nostrGroupId;
    if (nostrGroupId == null) return;

    final circle = await _resolveCircle(nostrGroupId);
    if (circle == null) return;

    // Evict a departed member from the cache so the map drops the leaver. The
    // engine already converged the commit in-Rust (M6-2) — no publish/merge owed.
    try {
      await reconcileRoster(circle);
    } on Object catch (e) {
      debugPrint('[Subscription] roster reconcile failed: ${e.runtimeType}');
    }
    // Invalidate circles + locations.
    try {
      onGroupUpdated(circle);
    } on Object catch (e) {
      debugPrint(
        '[Subscription] group-update callback failed: ${e.runtimeType}',
      );
    }
  }

  /// Unwraps one streamed gift wrap.
  ///
  /// Deliberately CURSOR-INERT. This used to advance the persisted
  /// `inbox_1059` cursor to the wrapper's own `created_at` — a number chosen
  /// by whoever built the wrap, and buildable by anyone who knows this user's
  /// published npub. The inbox cursor is advanced in haven-core now, on the
  /// inbox REQ's EOSE, to the local instant that REQ was issued; the wrapper
  /// timestamp is not even carried across the FFI boundary any more. See
  /// `CircleService`.
  Future<void> _handleWelcome(FfiRelayEvent event) async {
    final giftWrapJson = event.giftWrapJson;
    if (giftWrapJson == null) return;

    Uint8List? secret;
    try {
      secret = takeSecretOwnership(await secretBytes());
      final invitation = await circleService.processGiftWrappedInvitation(
        identitySecretBytes: secret,
        giftWrapEventJson: giftWrapJson,
      );
      // A non-null invitation is genuinely new; null = already-processed.
      if (invitation != null) {
        onInvitationReceived();
      }
    } on Object catch (e) {
      debugPrint('[Subscription] welcome processing failed: ${e.runtimeType}');
    } finally {
      // Rule 9: minimize secret lifetime — zeroize the bytes after use.
      if (secret != null) {
        secret.fillRange(0, secret.length, 0);
      }
    }
  }

  Future<void> _handleStatus(FfiRelayEvent event) async {
    // A status event carries EITHER an ordinary session reason OR a terminal
    // per-circle wedge verdict, never both (the FFI mapper's own invariant).
    // The verdict comes first because it is the one that must not be lost: it
    // used to flatten into the per-event, self-clearing `unprocessable`
    // reason, which named no circle, so the one state needing a destructive
    // repair was indistinguishable from a single bad message.
    final wedged = event.unrecoverableNostrGroupId;
    if (wedged != null) {
      await _handleUnrecoverable(wedged);
      return;
    }
    final reason = event.statusReason;
    if (reason == null) return;
    // OUTSIDE the guard below on purpose: a throwing `onStatus` must not cost
    // the re-anchor boundary that `_handleUnrecoverable` counts on.
    if (reason == FfiSyncStatusReason.backgroundResumed) {
      _reanchorGeneration++;
    }
    try {
      onStatus(reason);
    } on Object catch (e) {
      debugPrint('[Subscription] status callback failed: ${e.runtimeType}');
    }
  }

  /// Routes ONE terminal per-circle wedge verdict to the blocked-circle
  /// marker, which is what stops send/mutate for that circle alone and shows
  /// the user the re-invite (`CircleService.isCircleBlocked`).
  ///
  /// ## Why TWO verdicts and not one
  ///
  /// A single verdict has a documented false positive. The engine reports a
  /// circle whose parked eviction commit a peer has ALREADY healed but whose
  /// next publish — the only thing that discharges the durable row — has not
  /// run yet; the report sweep runs immediately after a re-anchor subscribes,
  /// so it can race that healing commit. Acting on that one report would tell
  /// the user to rebuild a circle that works, which is its own harm: the
  /// repair costs them the whole roster's invitations.
  ///
  /// Two observations SHRINK that false positive; they do not eliminate it.
  /// The row is discharged by a successful send for that circle
  /// (`discharge_removal_deferral_after_send`), so a healed circle is reported
  /// only once WHEN a publish lands between the two re-anchors — which is the
  /// normal case, because `locationPublisherProvider` fires on cold start. It
  /// is not the only case: with sharing off, with no usable fix, or with every
  /// relay refusing, no send happens, the row survives, and a healed circle is
  /// named again on the next foreground open and blocked. Nothing cheaper
  /// closes it — at the pinned MDK rev no accessor reports whether a staged
  /// commit is still present (`report_unrecoverable_circles`) — so the residual
  /// is recorded here rather than described away.
  ///
  /// ## Why a generation counter and not a clock
  ///
  /// The engine emits [FfiSyncStatusReason.backgroundResumed] on THIS stream,
  /// in order, at the head of every re-anchor, and one sweep names any circle
  /// at most once — so "a verdict in a later generation" is exactly "a verdict
  /// from a later re-anchor", with no wall clock, no timer and no ordering
  /// assumption beyond the stream's own.
  ///
  /// ## What it costs
  ///
  /// The second verdict arrives on the next re-anchor: the next app resume for
  /// the parked-eviction case (a healthy foregrounded session does not
  /// re-anchor on its own), or the next background burst for a group the engine
  /// itself declared terminal. So a real wedge can stay unannounced until the
  /// user opens Haven again — which is also how long the state itself takes to
  /// become redeemable, so nothing is lost by waiting for proof.
  Future<void> _handleUnrecoverable(Uint8List nostrGroupId) async {
    final circle = await _resolveCircle(nostrGroupId);
    // Not a joined circle: nothing to block, and nothing to tell the user
    // about. Dropped as quietly as an unknown circle's location is.
    if (circle == null) return;

    final key = _groupKey(nostrGroupId);
    final bool alreadyBlocked;
    try {
      alreadyBlocked = circleService.isCircleBlocked(circle.mlsGroupId);
    } on Object catch (e) {
      debugPrint('[Subscription] blocked read failed: ${e.runtimeType}');
      return;
    }
    if (alreadyBlocked) {
      // Idempotent per circle, never counted: the poll path may have latched
      // this circle already, and a wedge is terminal, so every later verdict
      // for it is inert.
      _unconfirmedWedges.remove(key);
      return;
    }

    final firstSeen = _unconfirmedWedges[key];
    if (firstSeen == null) {
      _unconfirmedWedges[key] = _reanchorGeneration;
      if (kDebugMode) {
        debugPrint(
          '[Subscription] wedge verdict unconfirmed — '
          'group=${_shortGroupHex(nostrGroupId)}…',
        );
      }
      return;
    }
    // A repeat inside the same re-anchor is the SAME observation.
    if (firstSeen == _reanchorGeneration) return;

    _unconfirmedWedges.remove(key);
    try {
      circleService.markCircleBlocked(circle.mlsGroupId);
    } on Object catch (e) {
      debugPrint('[Subscription] wedge mark failed: ${e.runtimeType}');
      return;
    }
    // Rebuilds the circle surfaces that read the marker, so the banner and its
    // re-invite appear without waiting for another user action.
    try {
      onGroupUpdated(circle);
    } on Object catch (e) {
      debugPrint('[Subscription] wedge refresh failed: ${e.runtimeType}');
    }
  }
}
