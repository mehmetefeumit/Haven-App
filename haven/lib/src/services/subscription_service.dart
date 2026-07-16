import 'package:flutter/foundation.dart';

import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/circle_service.dart';

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
  Future<void> resumeAfterBackground();

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
  Future<void> stop();

  /// Whether a live session is currently running.
  bool get isRunning;
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

  /// Circle service (for invitation processing + cursor advance) — mockable.
  final CircleService circleService;

  /// Snapshot of the user's joined circles (to resolve a `nostr_group_id`).
  final Future<List<Circle>> Function() circlesSnapshot;

  /// Provides the identity secret bytes for invitation unwrapping (copied into
  /// a `Uint8List` and zeroized after use by this router — Security Rule 9).
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
        _handleStatus(event);
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

  Future<void> _handleWelcome(FfiRelayEvent event) async {
    final giftWrapJson = event.giftWrapJson;
    if (giftWrapJson == null) return;
    final wrapSecs = event.wrapCreatedAtSecs;

    Uint8List? secret;
    try {
      secret = Uint8List.fromList(await secretBytes());
      final invitation = await circleService.processGiftWrappedInvitation(
        identitySecretBytes: secret,
        giftWrapEventJson: giftWrapJson,
      );
      if (wrapSecs != null) {
        await circleService.advanceInboxCursorToWrapSecs(wrapSecs);
      }
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

  void _handleStatus(FfiRelayEvent event) {
    final reason = event.statusReason;
    if (reason == null) return;
    try {
      onStatus(reason);
    } on Object catch (e) {
      debugPrint('[Subscription] status callback failed: ${e.runtimeType}');
    }
  }
}
