import 'package:flutter/foundation.dart';

import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/fresh_secret.dart';
import 'package:haven/src/utils/log_alias.dart';

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

/// A [SubscriptionService.start] that a stop ended, and no session is
/// running.
///
/// A type, so that a caller that counts failed starts can tell it apart
/// without reading a message.
class SubscriptionStartEnded extends SubscriptionServiceException {
  /// Creates the exception.
  const SubscriptionStartEnded({this.endedByEngine = false})
    : super('live session start ended by a stop');

  /// The only stop was the one the service made when the engine's event
  /// stream closed under the start: the engine died, nobody asked for no
  /// session. A failure, unlike a stop somebody asked for.
  final bool endedByEngine;
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
/// `liveSyncEnabled` by its callers: on by default since M11, and compiled
/// out — nothing starts it — in the `HAVEN_LIVE_SYNC=false` rollback build.
abstract class SubscriptionService {
  /// Builds the engine + starts the session for `groups` (accepted circles) and
  /// the user's `inboxRelays`, then begins consuming `liveEvents()`.
  ///
  /// A start claims nothing: the engine leaves the session only started.
  /// Once the service holds the engine it claims the foreground itself
  /// ([claimForeground]) if the app is resumed at THAT moment — a start takes
  /// seconds, and the app may have left since it was asked.
  ///
  /// While a start is in flight a second [start] joins it, and a
  /// [pauseSubscriptions] waits for it and then pauses the session it
  /// produced. A [stop] ends it, at any point up to its return — its claim
  /// included: the start throws [SubscriptionStartEnded], and no session is
  /// left running. A start issued while a [stop] is in flight ends the same
  /// way.
  Future<void> start({
    required List<FfiGroupSpec> groups,
    required List<String> inboxRelays,
  });

  /// Re-anchors the session after a background period / reconnect.
  ///
  /// The FOREGROUND re-anchor (app resume, whole-session repair): it always
  /// carries the inbox REQ, so an open app can always receive an invitation.
  /// A background burst must use [openBackgroundBurstWithin] instead.
  ///
  /// The engine refuses it unless the app is resumed at the moment of the
  /// call (`appIsResumed`): a re-anchor issued from a process that has since
  /// gone to the background re-opens nothing.
  Future<void> resumeAfterBackground();

  /// Tells a running session that the app's lifecycle reads `resumed`, when
  /// — and only when — it does (`appIsResumed`).
  ///
  /// For a session that is only started: it enters the engine's foreground
  /// lifecycle and one drive of its stored records is asked for. Nothing is
  /// re-anchored and no relay is contacted unless a stored record is due
  /// one. A no-op for a session already in the foreground, a paused one and
  /// a stopped one, and the engine is not asked at all while the app is not
  /// resumed. Never throws.
  Future<void> claimForeground();

  /// Waits for a start in flight to end, then [claimForeground]s: after it,
  /// the session is in the foreground lifecycle if it is going to be. For a
  /// caller that asks the core for a foreground drive and would otherwise be
  /// refused while the session is still coming up. Does nothing while the app
  /// is not resumed, never throws, and gives up after `kLiveSyncRestartBudget`.
  Future<void> settleForegroundClaim();

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
  ///
  /// [budget] is how long the burst's drives have, from now: no drive the
  /// burst makes begins a relay call it would not have the room to finish.
  ///
  /// No session — none installed, or one that has stopped — answers
  /// [BurstOpenFfi.noSession], typed, and opens nothing.
  Future<BurstOpenFfi> openBackgroundBurstWithin(Duration budget);

  /// Starts a session directly into a background burst (decision 190), for a
  /// burst that finds no session: subscribed, making no commit, claiming no
  /// foreground. The caller then waits out its backlog and pauses it as it
  /// does any burst. [budget] is as [openBackgroundBurstWithin]'s.
  ///
  /// THROWS on failure, as a burst open does; a stop ends it as it ends a
  /// [start] ([SubscriptionStartEnded]).
  Future<void> startIntoBurst({
    required List<FfiGroupSpec> groups,
    required List<String> inboxRelays,
    required Duration budget,
  });

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
  /// by the live-sync resubscriber to listen for an added circle without a
  /// full stop+start.
  ///
  /// Throws if there is no active session (the caller falls back to a full
  /// restart) or on a hard error.
  Future<void> subscribeCircle(FfiGroupSpec spec);

  /// Unsubscribes the running session from ONE circle (delta only).
  /// Idempotent for an unknown circle (the engine no-ops). Throws if there is
  /// no active session (the caller falls back to a full restart) or on a hard
  /// error.
  Future<void> unsubscribeCircle(Uint8List nostrGroupId);

  /// Stops + drops the session (logout / teardown). Idempotent, and a stop
  /// issued while another is in flight joins it and reports its outcome.
  ///
  /// Reports whether the engine actually released its manager `Arc` — see
  /// [LiveSyncStopOutcome]. Callers that only tear down may ignore it; the
  /// pause-time handoff must not.
  ///
  /// When [givenUp] completes first, the caller has given up on the stop: it
  /// answers [LiveSyncStopOutcome.stillHolding] at once and the session
  /// delivers nothing more, while the engine's stop runs on and no session is
  /// adopted until it returns. A stop that joins one in flight is given up on
  /// when either deadline completes.
  Future<LiveSyncStopOutcome> stop({Future<void>? givenUp});

  /// Whether a live session is currently running.
  bool get isRunning;

  /// Where the session stands, read from the engine. No engine held, or a
  /// read that fails, answers [LiveLifecycleFfi.noSession] — and the engine
  /// itself reads a poisoned lock that way: never take it as leave to do what
  /// a running session would refuse.
  LiveLifecycleFfi lifecycle();

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
    this.onClockRejected,
  });

  /// The circle service, read at each use (invitation processing, resolving
  /// a circle). Never an instance captured once: a login retires the previous
  /// identity's, wiped and latched, and a router holding it would hand the
  /// next identity's Welcomes to a service that refuses them.
  final CircleService Function() circleService;

  /// Snapshot of the user's joined circles (to resolve a `nostr_group_id`).
  /// It can hold a circle's row from before its routing id rotated; a miss is
  /// asked of [circleService] itself ([_resolveCircle]).
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

  /// A circle's roster or routing changed — invalidate circles + locations.
  final void Function(Circle circle) onGroupUpdated;

  /// A new invitation was processed — invalidate invitations + circles.
  final void Function() onInvitationReceived;

  /// A non-content status/lifecycle signal from the engine.
  final void Function(FfiSyncStatusReason reason) onStatus;

  /// What a live drive's relays blamed on this device's clock: the clock
  /// check's evidence, as a bridge driver entry's outcome carries it.
  final void Function(DeviceClockComplaintFfi complaint)? onClockRejected;

  /// Per-process log-alias handle for a `nostr_group_id` (Security Rule 15 —
  /// even the pseudonymous `nostr_group_id` may not reach a log, full or
  /// truncated; a prefix of an identifier is still an identifier).
  static String _circleHandle(Uint8List g) =>
      logAliasHandle(LogAliasClass.circle, _groupKey(g));

  /// Full hex of a `nostr_group_id`, for map keys (`Uint8List` has identity
  /// equality, so the bytes themselves cannot key a map).
  static String _groupKey(List<int> g) =>
      g.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// How many identities a logout has ended ([forgetIdentity]).
  int _identitiesEnded = 0;

  /// Forgets what was gathered under an identity a logout has deleted: every
  /// location still in a handler is dropped ([identityEndedSince]).
  void forgetIdentity() {
    _identitiesEnded++;
  }

  /// Answers, when called later, whether the identity current NOW has been
  /// forgotten since. Taken when an event ARRIVES: handlers run one after
  /// another, so one can start after the logout that ended its identity.
  bool Function() identityEndedSince() {
    final at = _identitiesEnded;
    return () => at != _identitiesEnded;
  }

  /// Routes one engine event to its side effects. Never throws.
  ///
  /// [identityEnded] answers whether the identity [event] arrived under has
  /// since been forgotten (default: the identity current at this call). A
  /// location its handler had not yet handed to the location service by then
  /// is dropped whole: the service it would reach is the next identity's.
  /// Any other stop — a pause, a detach, a full restart — drops nothing: the
  /// location service's own fences decide: a paused one persists the fix where
  /// it still holds the store (not on Android with background sharing on,
  /// where the store has been handed to the foreground service), and merges
  /// nothing into its closed cache. The other kinds still run — a
  /// status says how the session ended, and a Welcome is persisted, not shown.
  Future<void> handleEvent(
    FfiRelayEvent event, {
    bool Function()? identityEnded,
  }) async {
    final ended = identityEnded ?? identityEndedSince();
    // Diagnostic (M11 e2e triage): confirm the engine's bus event actually
    // reaches the Dart consumer (the Rust side logs `process_group_event …
    // Processed`; this proves the FFI stream → router hop). Circle handle
    // only, never the group id itself (Security Rule 15).
    if (kDebugMode) {
      final g = event.nostrGroupId;
      final suffix = g == null ? '' : ' group=${_circleHandle(g)}';
      debugPrint('[Subscription] stream event kind=${event.kind}$suffix');
    }
    switch (event.kind) {
      case FfiRelayEventKind.location:
        await _handleLocation(event, ended);
      case FfiRelayEventKind.groupUpdate:
        await _handleGroupUpdate(event);
      case FfiRelayEventKind.welcome:
        await _handleWelcome(event);
      case FfiRelayEventKind.status:
        await _handleStatus(event);
    }
  }

  /// The joined circle routed as [nostrGroupId]. A circle's routing id moves
  /// when its routing rotates, and the snapshot keeps the prior row until it
  /// is refreshed: a miss there is asked of the circle service, and a circle
  /// found that way refreshes the snapshot ([onGroupUpdated]).
  Future<Circle?> _resolveCircle(Uint8List nostrGroupId) async {
    Circle? routedAs(List<Circle> circles) => circles
        .where((c) => listEquals(c.nostrGroupId, nostrGroupId))
        .firstOrNull;
    final Circle? moved;
    try {
      final known = routedAs(await circlesSnapshot());
      if (known != null) return known;
      moved = routedAs(await circleService().getVisibleCircles());
    } on Object catch (e) {
      debugPrint('[Subscription] circle resolve failed: ${e.runtimeType}');
      return null;
    }
    if (moved != null) {
      try {
        onGroupUpdated(moved);
      } on Object catch (e) {
        debugPrint(
          '[Subscription] circle refresh failed: ${e.runtimeType}',
        );
      }
    }
    return moved;
  }

  Future<void> _handleLocation(
    FfiRelayEvent event,
    bool Function() identityEnded,
  ) async {
    final content = event.content;
    final sender = event.senderPubkey;
    final nostrGroupId = event.nostrGroupId;
    if (content == null || sender == null || nostrGroupId == null) return;

    final circle = await _resolveCircle(nostrGroupId);
    if (circle == null) {
      // Diagnostic (M11 e2e triage): a live location the engine `Processed` was
      // DROPPED here because neither the circles snapshot nor the circle
      // service knows its group. Circle handle only, never the group id
      // (Rule 15).
      if (kDebugMode) {
        debugPrint(
          '[Subscription] location DROPPED — '
          'group=${_circleHandle(nostrGroupId)} not a joined circle',
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
    // Read in the same turn the ingest is called in: from here the location
    // service's own fence is what holds a pause, or a wipe.
    if (identityEnded()) return;

    try {
      await ingestLocation(circle, decrypted);
      onLocationsChanged();
      // Diagnostic (M11 e2e triage): the full delivery path completed — engine
      // Processed → stream → router → cache + provider invalidation.
      if (kDebugMode) {
        debugPrint(
          '[Subscription] location INGESTED — '
          'group=${_circleHandle(nostrGroupId)}',
        );
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
      final invitation = await circleService().processGiftWrappedInvitation(
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
    // Neither a session reason nor a circle's (it never carries one): it
    // says nothing about the connection.
    final clock = event.clockRejected;
    if (clock != null) {
      try {
        onClockRejected?.call(clock);
      } on Object catch (e) {
        debugPrint('[Subscription] clock callback failed: ${e.runtimeType}');
      }
    }
    final reason = event.statusReason;
    if (reason == null) return;
    try {
      onStatus(reason);
    } on Object catch (e) {
      debugPrint('[Subscription] status callback failed: ${e.runtimeType}');
    }
  }

  /// Refreshes the circle MDK halted, so every surface reading its engine
  /// state follows. MDK's verdict is durable and authoritative, so the first
  /// nudge refreshes.
  Future<void> _handleUnrecoverable(Uint8List nostrGroupId) async {
    final circle = await _resolveCircle(nostrGroupId);
    // Not a joined circle: nothing to refresh, and nothing to tell the user
    // about. Dropped as quietly as an unknown circle's location is.
    if (circle == null) return;
    try {
      onGroupUpdated(circle);
    } on Object catch (e) {
      debugPrint('[Subscription] wedge refresh failed: ${e.runtimeType}');
    }
  }
}
