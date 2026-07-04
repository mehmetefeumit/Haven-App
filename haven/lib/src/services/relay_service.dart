/// Abstract interface for relay services.
///
/// Provides a platform-agnostic API for Nostr relay operations.
///
/// Implementations:
/// - [NostrRelayService] - Production implementation using Rust core
library;

import 'package:flutter/foundation.dart';

import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/circle_service.dart';

/// Presence-only result of an M7 receive-only catch-up sweep (plain counters,
/// no coordinates/group-ids/secrets — mirrors the Rust `CatchupResultFfi`).
class CatchupResult {
  /// Creates a catch-up result.
  const CatchupResult({
    this.circlesSwept = 0,
    this.locationsApplied = 0,
    this.commitsApplied = 0,
    this.autoCommitsStaged = 0,
    this.cursorsAdvanced = 0,
    this.deadlineHit = false,
    this.relayErrors = 0,
  });

  /// An empty result (e.g. a best-effort sweep that failed / no-op'd).
  const CatchupResult.empty() : this();

  /// Circles whose relays were swept.
  final int circlesSwept;

  /// Location events decrypted + persisted.
  final int locationsApplied;

  /// Already-merged peer commits observed.
  final int commitsApplied;

  /// Peer proposals MDK auto-staged (left for the foreground to converge).
  final int autoCommitsStaged;

  /// Per-circle group cursors advanced.
  final int cursorsAdvanced;

  /// The deadline was reached before every circle was swept.
  final bool deadlineHit;

  /// Relay fetches that returned no response / errored.
  final int relayErrors;
}

/// What an M8 `KeyPackage` maintenance tick did (presence-only, leak-free —
/// mirrors the Rust `KpMaintenanceActionFfi`).
enum KeyPackageMaintenanceAction {
  /// A live-material canonical `KeyPackage` was already reachable — no change.
  alreadyHealthy,

  /// A stable `d` was seeded from an on-relay canonical this tick; no publish.
  seededD,

  /// A `KeyPackage` was (re)published into a reused, tracked/seeded stable `d`.
  republishedStableD,

  /// A `KeyPackage` was published into a freshly-minted `d` (first-ever slot).
  republishedFreshD,
}

/// Presence-only result of an M8 `KeyPackage` maintenance tick.
///
/// Counters + an action enum only — never a relay url, `d`, hex, or group id —
/// so it is leak-free (Security Rule 4/6). Mirrors the Rust
/// `KpMaintenanceOutcomeFfi` without coupling the service interface to the
/// FFI-generated type (so it stays mockable in pure-Dart tests).
@immutable
class KeyPackageMaintenanceResult {
  /// Creates a `KeyPackage` maintenance result.
  const KeyPackageMaintenanceResult({
    this.action = KeyPackageMaintenanceAction.alreadyHealthy,
    this.canonicalOnRelays = 0,
    this.relayErrors = 0,
  });

  /// An empty result (e.g. a best-effort tick that failed / no-op'd).
  const KeyPackageMaintenanceResult.empty() : this();

  /// What the tick did.
  final KeyPackageMaintenanceAction action;

  /// Own-relay canonical (kind 30443) events the probe observed.
  final int canonicalOnRelays;

  /// Relay probes/publishes that errored (tallied, never fatal).
  final int relayErrors;
}

/// What an M8 relay-list maintenance tick did for one category (mirrors the
/// Rust `RelayListActionFfi`).
enum RelayListMaintenanceAction {
  /// Publishing is suppressed by the privacy toggle (or nothing configured).
  suppressed,

  /// A current list was already reachable — no change.
  alreadyCurrent,

  /// The list was (re)published to own relays this tick.
  republished,
}

/// Presence-only per-category tally of an M8 relay-list maintenance tick.
@immutable
class RelayListCategoryResult {
  /// Creates a per-category relay-list result.
  const RelayListCategoryResult({
    this.action = RelayListMaintenanceAction.alreadyCurrent,
    this.relayErrors = 0,
  });

  /// What the tick did for this category.
  final RelayListMaintenanceAction action;

  /// Relay probes/publishes that errored (tallied, never fatal).
  final int relayErrors;
}

/// Presence-only result of an M8 relay-list maintenance tick (both categories).
///
/// Counters + action enums only — leak-free (Security Rule 4/6). Mirrors the
/// Rust `RelayListMaintenanceOutcomeFfi`.
@immutable
class RelayListMaintenanceResult {
  /// Creates a relay-list maintenance result.
  const RelayListMaintenanceResult({
    this.inbox = const RelayListCategoryResult(),
    this.keyPackage = const RelayListCategoryResult(),
  });

  /// An empty result (e.g. a best-effort tick that failed / no-op'd).
  const RelayListMaintenanceResult.empty() : this();

  /// The inbox (kind 10050) category outcome.
  final RelayListCategoryResult inbox;

  /// The `KeyPackage` (kind 10051) category outcome.
  final RelayListCategoryResult keyPackage;
}

/// What an M8 subscription-health tick did (presence-only, mirrors the Rust
/// `SubscriptionHealthActionFfi`).
enum SubscriptionHealthAction {
  /// No live engine session — the inert no-op that ships while the live-sync
  /// engine is off.
  engineOff,

  /// The engine is running and every relay is connected — nothing to do.
  healthy,

  /// A relay had dropped; every subscription was re-anchored at its cursor.
  resubscribed,
}

/// Presence-only result of an M8 subscription-health maintenance tick.
///
/// Counters + an action enum only — never a relay url, group id, or pubkey — so
/// it is leak-free (Security Rule 4/6). Mirrors the Rust
/// `SubscriptionHealthOutcomeFfi`.
@immutable
class SubscriptionHealthResult {
  /// Creates a subscription-health result.
  const SubscriptionHealthResult({
    this.action = SubscriptionHealthAction.engineOff,
    this.relaysTotal = 0,
    this.relaysDisconnected = 0,
  });

  /// An empty (engine-off) result — the best-effort failure fallback.
  const SubscriptionHealthResult.empty() : this();

  /// What the tick did.
  final SubscriptionHealthAction action;

  /// Relays in the engine pool at check time (0 when engine off).
  final int relaysTotal;

  /// Relays found dropped at check time (0 when engine off).
  final int relaysDisconnected;
}

/// Exception thrown when relay operations fail.
class RelayServiceException implements Exception {
  /// Creates a [RelayServiceException] with the given message.
  const RelayServiceException(this.message);

  /// The error message.
  final String message;

  @override
  String toString() => 'RelayServiceException: $message';
}

/// Result of publishing an event to relays.
@immutable
class PublishResult {
  /// Creates a new [PublishResult].
  const PublishResult({
    required this.eventId,
    required this.acceptedBy,
    required this.rejectedBy,
    required this.failed,
  });

  /// The event ID that was published.
  final String eventId;

  /// Relay URLs that accepted the event.
  final List<String> acceptedBy;

  /// Relay URLs that rejected the event with reasons.
  final List<RelayRejection> rejectedBy;

  /// Relay URLs that failed to respond.
  final List<String> failed;

  /// Whether the publish was successful (at least one relay accepted).
  bool get isSuccess => acceptedBy.isNotEmpty;

  @override
  String toString() =>
      'PublishResult(accepted: ${acceptedBy.length}, '
      'rejected: ${rejectedBy.length}, failed: ${failed.length})';
}

/// Represents a relay rejection with reason.
@immutable
class RelayRejection {
  /// Creates a new [RelayRejection].
  const RelayRejection({required this.relay, required this.reason});

  /// The relay URL that rejected.
  final String relay;

  /// The reason for rejection.
  final String reason;
}

/// Result of checking whether events exist on a specific relay.
@immutable
class RelayEventCheck {
  /// Creates a [RelayEventCheck].
  const RelayEventCheck({
    required this.relayUrl,
    required this.found,
    required this.eventCount,
    this.newestTimestamp,
  });

  /// The relay URL that was checked.
  final String relayUrl;

  /// Whether at least one matching event was found.
  final bool found;

  /// Number of matching events found.
  final int eventCount;

  /// Newest event timestamp, if any.
  final DateTime? newestTimestamp;
}

/// Per-relay result of a gift-wrap fetch.
///
/// Distinguishes a relay that answered ([responded] is `true`, even with
/// zero [events]) from one that could not be reached ([responded] is
/// `false`). The WebSocket handshake is the "answered" signal.
@immutable
class RelayGiftWrapFetch {
  /// Creates a [RelayGiftWrapFetch].
  const RelayGiftWrapFetch({
    required this.relayUrl,
    required this.responded,
    required this.events,
  });

  /// The relay URL that was queried.
  final String relayUrl;

  /// Whether the relay answered (completed the WebSocket handshake).
  final bool responded;

  /// Gift-wrap event JSON strings fetched from this relay.
  final List<String> events;
}

/// Abstract interface for relay services.
///
/// Handles fetching KeyPackages and publishing events via Nostr relays.
abstract class RelayService {
  /// Fetches a user's KeyPackage relay list (kind 10051).
  ///
  /// Returns the list of relay URLs where the user publishes KeyPackages.
  /// Returns an empty list if no relay list is found.
  ///
  /// Throws [RelayServiceException] if the fetch fails.
  Future<List<String>> fetchKeyPackageRelays(String pubkey);

  /// Fetches a user's NIP-65 general relay list (kind 10002).
  ///
  /// Returns the relay URLs from the user's general-purpose relay list.
  /// Used as a fallback when inbox relays (kind 10050) are not available.
  ///
  /// Returns an empty list if no relay list is found.
  ///
  /// Throws [RelayServiceException] if the fetch fails.
  Future<List<String>> fetchNip65Relays(String pubkey);

  /// Fetches the latest KeyPackage (kind 443) for a user.
  ///
  /// First fetches the user's KeyPackage relay list (kind 10051),
  /// then fetches the KeyPackage from those relays.
  ///
  /// Returns `null` if no KeyPackage is found (user may not have Haven).
  ///
  /// Throws [RelayServiceException] if the fetch fails.
  Future<KeyPackageData?> fetchKeyPackage(String pubkey);

  /// Publishes a gift-wrapped welcome event.
  ///
  /// The [welcomeEvent] is already gift-wrapped (kind 1059) and ready
  /// to publish. Simply publishes to the recipient's relays.
  ///
  /// Returns the publish result with success/failure per relay.
  ///
  /// Throws [RelayServiceException] if publishing fails completely.
  Future<PublishResult> publishWelcome({
    required GiftWrappedWelcome welcomeEvent,
  });

  /// Publishes a signed event to relays.
  ///
  /// Returns the publish result with success/failure per relay.
  ///
  /// Throws [RelayServiceException] if publishing fails completely.
  Future<PublishResult> publishEvent({
    required String eventJson,
    required List<String> relays,
  });

  /// Publishes a signed event in the background without waiting for
  /// relay acknowledgment.
  ///
  /// Suitable for location updates and key package re-publishes where
  /// periodic timers ensure eventual delivery. NOT for welcome events.
  ///
  /// Throws [RelayServiceException] if relay URL validation fails.
  Future<void> publishEventFireAndForget({
    required String eventJson,
    required List<String> relays,
  });

  /// Fetches gift-wrapped events (kind 1059) for a recipient.
  ///
  /// Queries relays for NIP-59 gift wrap events addressed to the given
  /// public key. Use [since] to restrict results to events after a timestamp.
  ///
  /// Returns a list of gift-wrap event JSON strings.
  ///
  /// Throws [RelayServiceException] if fetching fails.
  Future<List<String>> fetchGiftWraps({
    required String recipientPubkey,
    required List<String> relays,
    DateTime? since,
  });

  /// Fetches gift wraps from each relay independently, reporting which
  /// relays answered.
  ///
  /// Unlike [fetchGiftWraps] (one merged list with no per-relay
  /// attribution), this queries each relay on its own and returns a
  /// per-relay outcome, so callers can show an accurate answered/unanswered
  /// tally. A relay that answers with zero events is reported with
  /// [RelayGiftWrapFetch.responded] `== true` and an empty event list —
  /// distinct from an unreachable relay (`responded == false`).
  ///
  /// Throws [RelayServiceException] only if the call fails entirely (e.g.
  /// URL validation). Per-relay failures are reported as `responded ==
  /// false`, never thrown.
  Future<List<RelayGiftWrapFetch>> fetchGiftWrapsPerRelay({
    required String recipientPubkey,
    required List<String> relays,
    DateTime? since,
  });

  /// Runs an M7 receive-only catch-up sweep over every visible circle.
  ///
  /// Fork-safe by construction (the Rust sweep gates every decrypt on the
  /// persisted staged-commit marker and never authors/merges/converges a
  /// commit). Best-effort — returns a [CatchupResult.empty] on failure rather
  /// than throwing. `circle` is the circle-manager FFI handle (from
  /// [CircleService.getCircleManagerFfi]) and `ownPubkeyHex` is the user's
  /// public key (to drop self-echoes).
  Future<CatchupResult> runCatchup({
    required CircleManagerFfi circle,
    required String ownPubkeyHex,
    int maxDurationSecs = 20,
  });

  /// Runs an M8 `KeyPackage` maintenance tick (kinds 30443 + 443).
  ///
  /// Probes the user's OWN `KeyPackage` relays for a live-material canonical
  /// and republishes into a stable NIP-33 `d` slot only when none is
  /// reachable — the Rust core owns the whole decision (live-material gate +
  /// stable-`d` seeding). `circle` is the circle-manager FFI handle (from
  /// [CircleService.getCircleManagerFfi]); the secret bytes are consumed by
  /// the FFI and zeroized Rust-side.
  ///
  /// Best-effort — returns a [KeyPackageMaintenanceResult.empty] on failure
  /// rather than throwing (a background/timer tick must never throw).
  Future<KeyPackageMaintenanceResult> maintainKeyPackage({
    required CircleManagerFfi circle,
    required List<int> identitySecretBytes,
  });

  /// Runs an M8 relay-list maintenance tick (kind 10050 inbox + 10051
  /// `KeyPackage`).
  ///
  /// Network-probes the user's OWN relays for each list and republishes to
  /// own relays only when missing/drifted, honoring the per-category privacy
  /// toggle. Never NIP-65/kind-10002. `circle` is the circle-manager FFI
  /// handle; the secret bytes are consumed by the FFI and zeroized Rust-side.
  ///
  /// Best-effort — returns a [RelayListMaintenanceResult.empty] on failure
  /// rather than throwing.
  Future<RelayListMaintenanceResult> maintainRelayList({
    required CircleManagerFfi circle,
    required List<int> identitySecretBytes,
  });

  /// Runs an M8 subscription-health maintenance tick (engine-coupled).
  ///
  /// Reads the live-sync engine's session: with no running engine it returns
  /// the inert [SubscriptionHealthAction.engineOff] no-op (so it ships inert
  /// while the engine is off). When the engine is live it snapshots relay
  /// connectivity and re-anchors every subscription at its persisted cursor if
  /// any relay has dropped. Takes no secret and no circle handle.
  ///
  /// Best-effort — returns a [SubscriptionHealthResult.empty] on failure rather
  /// than throwing.
  Future<SubscriptionHealthResult> maintainSubscriptionHealth();

  /// Fetches MLS group messages (kind 445) from relays.
  ///
  /// Queries relays for encrypted group messages using h-tag routing.
  ///
  /// Returns a list of event JSON strings.
  ///
  /// Throws [RelayServiceException] if fetching fails.
  Future<List<String>> fetchGroupMessages({
    required List<int> nostrGroupId,
    required List<String> relays,
    DateTime? since,
    int? limit,
  });

  /// Checks whether events of a given kind by an author exist on a relay.
  ///
  /// Queries a single relay for events matching the given kind and author.
  ///
  /// Throws [RelayServiceException] if the check fails.
  Future<RelayEventCheck> checkEventOnRelay({
    required String relayUrl,
    required String authorPubkey,
    required int eventKind,
  });

  /// Removes a single relay from the persistent connection pool by URL.
  ///
  /// Used by the relay-preferences UI when the user explicitly removes
  /// a relay so the app does not continue leaking metadata via an idle
  /// WebSocket. Routed through the same `nostr_sdk::Client` used by all
  /// other relay operations so removal is symmetric with addition.
  ///
  /// Best-effort: returns successfully even when the relay was never
  /// connected. Failures are logged, never rethrown.
  Future<void> disconnectRelay(String url);
}
