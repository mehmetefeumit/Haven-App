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
import 'package:meta/meta.dart' show useResult;

/// Presence-only result of an M7 receive-only catch-up sweep (plain counters,
/// no coordinates/group-ids/secrets — mirrors the Rust `CatchupResultFfi`).
class CatchupResult {
  /// Creates a catch-up result.
  const CatchupResult({
    this.circlesSwept = 0,
    this.eventsApplied = 0,
    this.eventsDeferred = 0,
    this.cursorsAdvanced = 0,
    this.deadlineHit = false,
    this.relayErrors = 0,
  });

  /// An empty result (e.g. a best-effort sweep that failed / no-op'd).
  const CatchupResult.empty() : this();

  /// Circles whose relays were swept.
  final int circlesSwept;

  /// Events the engine applied / terminally handled (Dark Matter taxonomy:
  /// locations, commits, and state changes are all engine-internal now, so
  /// this single counter replaces the pre-migration
  /// locations/commits/auto-commits-staged split).
  final int eventsApplied;

  /// Events the engine durably buffered for a FUTURE epoch (the cursor
  /// stopped so they are re-fetched + re-surfaced once the gap fills).
  final int eventsDeferred;

  /// Per-circle group cursors advanced.
  final int cursorsAdvanced;

  /// The deadline was reached before every circle was swept.
  final bool deadlineHit;

  /// Relay fetches that returned no response / errored.
  final int relayErrors;
}

/// Why a `KeyPackage` maintenance tick left the account without confirmed
/// reachable init-key material.
///
/// Presence-only (a closed token, never relay text) — Security Rule 8.
enum KeyPackageFailureKind {
  /// Relays WERE configured and none of them answered the probe, so the tick
  /// neither confirmed a canonical nor published one.
  ///
  /// Transient by construction — the account's own `KeyPackage` relays exist,
  /// they were simply unreachable this tick — so it retries on the prompt
  /// ladder. Told apart from [noRelaysConfigured] purely by the FFI's
  /// `relaysTargeted` count; every other field of the tick is identical in the
  /// two cases (see [RelayService.maintainKeyPackage]).
  noRelayResponded,

  /// The account has **no own `KeyPackage` relays configured at all**, so the
  /// tick returned before contacting anything.
  ///
  /// Not a network condition and not retryable: the Rust tick's early return
  /// is deterministic until the user adds a relay, so escalating the retry
  /// ladder against it only burns wakeups. Distinct from [noRelayResponded]
  /// because the remedies are opposite — wait for the network vs. change a
  /// setting — and both were one value until the FFI started reporting
  /// `relaysTargeted`.
  noRelaysConfigured,

  /// A `KeyPackage` was built and sent, and **no relay acknowledged it**. The
  /// account is not invitable until a later tick lands one. This is the case
  /// the pre-fix result type reported as a successful republish.
  publishNotAcked,

  /// The tick deleted the tracked package's private `init_key` because it
  /// reached its MLS `Lifetime.not_after`, and no replacement was published in
  /// the same tick.
  ///
  /// The strongest form of "not invitable": whatever is still on the relays,
  /// the engine no longer holds the private half of it, so a peer that fetches
  /// it cannot produce a Welcome this device can process. Distinct from
  /// [publishNotAcked] because the account is *known* to be unreachable rather
  /// than merely unconfirmed.
  initKeyPurgedUnreplaced,

  /// The identity secret could not be resolved (logged out, secure storage
  /// unavailable), so the tick could not sign anything.
  identityUnavailable,

  /// The tick itself errored — FFI, MLS storage, or the circle-manager handle.
  tickErrored,
}

/// What a caller should do about a [KeyPackageMaintenanceFailed].
///
/// Derived from [KeyPackageFailureKind] so the retry policy has exactly one
/// definition and a caller never re-derives it from the kind by hand.
enum KeyPackageRetryDisposition {
  /// A transient relay/network condition. Retry sooner than the nominal
  /// cadence — until this lands, nobody can invite the user.
  retryPromptly,

  /// Something local is broken. Retrying helps eventually, but hammering does
  /// not; back off.
  retryLater,

  /// Nothing to retry until the user acts (log back in, configure a relay).
  /// Keep the ordinary cadence; do not escalate.
  awaitUserAction,
}

/// Presence-only outcome of an M8 `KeyPackage` maintenance tick.
///
/// **Sealed on purpose.** The type this replaced
/// (`KeyPackageMaintenanceResult`) had an `.empty()` constructor whose `action`
/// defaulted to `alreadyHealthy`, so every best-effort failure path — a
/// throwing FFI call, an unresolvable identity, and (via the dropped
/// `relaysHealed` counter) a publish no relay ever acknowledged — produced a
/// value byte-identical to "nothing needed doing". A failure was spellable as
/// health by *omission*, and that is how a `KeyPackage` that was never
/// re-minted stayed invisible.
///
/// Three states, and no way to land in one by defaulting into it:
///
/// - [KeyPackageMaintenanceHealthy] — a canonical was confirmed reachable.
/// - [KeyPackageMaintenancePublished] — material was written and **at least one
///   relay acked it** (the constructor asserts it).
/// - [KeyPackageMaintenanceFailed] — work was needed and did not land.
///
/// There is no default constructor, no `empty()`, and no field on the base
/// class that answers "was this fine?" — a caller that wants to know must
/// `switch`, and a `switch` that omits a variant does not compile. The methods
/// returning it are `@useResult`, so discarding it entirely is an analyzer
/// warning (a CI failure under `flutter analyze`), not a silent read of failure
/// as health.
///
/// Counters + closed tokens only — never a relay url, `d`, hex, or group id —
/// so it stays leak-free (Security Rule 4/6/8).
@immutable
sealed class KeyPackageMaintenanceOutcome {
  /// Creates an outcome carrying the tick's relay-error tally.
  const KeyPackageMaintenanceOutcome({
    required this.relayErrors,
    required this.expiredInitKeyPurged,
  });

  /// Relay probes/publishes/record-writes that errored (tallied, never fatal).
  ///
  /// Non-zero on a healthy or published tick too: a partial failure is not the
  /// same thing as an overall one.
  final int relayErrors;

  /// Whether this tick deleted the tracked package's private `init_key`
  /// because it reached its MLS `Lifetime.not_after`.
  ///
  /// Orthogonal to the three-way verdict — it can arrive on a tick that then
  /// published a replacement (fine) or on one that did not
  /// ([KeyPackageFailureKind.initKeyPurgedUnreplaced]) — and it is carried on
  /// the base class so it cannot be dropped by whichever variant the tick
  /// happens to produce. Dropping a counter on the way out of the FFI is the
  /// original defect; this is the same counter class as `relaysHealed`.
  final bool expiredInitKeyPurged;
}

/// Nothing needed doing: the probe reached at least one of the user's own
/// relays and found the tracked canonical `KeyPackage` slot served there.
final class KeyPackageMaintenanceHealthy extends KeyPackageMaintenanceOutcome {
  /// Creates a healthy outcome.
  ///
  /// [respondersProbed] must be non-zero: "no relay answered" is *not* health,
  /// it is [KeyPackageFailureKind.noRelayResponded].
  const KeyPackageMaintenanceHealthy({
    required this.canonicalOnRelays,
    required this.respondersProbed,
    this.seededStableSlot = false,
    super.relayErrors = 0,
  }) : assert(
         respondersProbed > 0,
         'health requires a relay to have answered — an unprobed tick is a '
         'KeyPackageMaintenanceFailed(noRelayResponded)',
       ),
       assert(
         canonicalOnRelays > 0,
         'health requires an observed canonical — zero is not "nothing to do"',
       ),
       super(expiredInitKeyPurged: false);

  /// Own-relay canonical (kind 30443) events the probe observed.
  final int canonicalOnRelays;

  /// Responding own relays the probe reached (non-responders excluded).
  final int respondersProbed;

  /// Whether this tick adopted an on-relay `d` into the local stable slot.
  ///
  /// Local bookkeeping only — no relay write happens, and the canonical it
  /// adopted was observed on a relay *this tick*, so the account is reachable
  /// either way. Surfaced because it is the one healthy tick that changed
  /// local state.
  /// [expiredInitKeyPurged] is fixed at `false` here rather than being a
  /// parameter: a tick that deleted the tracked package's private `init_key`
  /// without replacing it is not health, and is classified as
  /// [KeyPackageFailureKind.initKeyPurgedUnreplaced] instead of arriving here.
  final bool seededStableSlot;

  @override
  String toString() =>
      'KeyPackageMaintenanceHealthy(canonical: $canonicalOnRelays, '
      'responders: $respondersProbed, seeded: $seededStableSlot, '
      'relayErrors: $relayErrors)';
}

/// Work was done: a `KeyPackage` was (re)published and **acknowledged** by at
/// least one relay.
final class KeyPackageMaintenancePublished
    extends KeyPackageMaintenanceOutcome {
  /// Creates a published outcome.
  ///
  /// [relaysAcked] must be non-zero — a publish nobody acked is a
  /// [KeyPackageFailureKind.publishNotAcked], never this. Enforced here rather
  /// than left to the mapping layer so the invariant cannot be lost by a
  /// future edit to the mapper (Security Rule 13's "acked means acked, never
  /// merely sent", applied to the reachability plane).
  const KeyPackageMaintenancePublished({
    required this.relaysAcked,
    required this.mintedFreshSlot,
    this.respondersProbed = 0,
    super.relayErrors = 0,
    super.expiredInitKeyPurged = false,
  }) : assert(
         relaysAcked > 0,
         'a publish no relay acked is a failure, not a publish',
       );

  /// Relays that acknowledged the write (always >= 1).
  final int relaysAcked;

  /// Whether the material went into a freshly-minted `d` slot (first publish
  /// or a rotation) rather than the tracked stable one.
  final bool mintedFreshSlot;

  /// Responding own relays the probe reached this tick.
  final int respondersProbed;

  @override
  String toString() =>
      'KeyPackageMaintenancePublished(acked: $relaysAcked, '
      'freshSlot: $mintedFreshSlot, responders: $respondersProbed, '
      'relayErrors: $relayErrors, initKeyPurged: $expiredInitKeyPurged)';
}

/// Work was needed and did not land: after this tick the account may not be
/// invitable, and nothing about the tick says otherwise.
final class KeyPackageMaintenanceFailed extends KeyPackageMaintenanceOutcome {
  /// Creates a failed outcome.
  const KeyPackageMaintenanceFailed(
    this.kind, {
    super.relayErrors = 0,
    super.expiredInitKeyPurged = false,
  });

  /// Why the tick failed (a closed token — never relay-supplied text).
  final KeyPackageFailureKind kind;

  /// What a caller should do about it. One definition, so two callers cannot
  /// disagree about whether a given kind is worth retrying.
  KeyPackageRetryDisposition get disposition => switch (kind) {
    // The relays are the problem and the user is uninvitable meanwhile —
    // the cases worth escalating above the nominal cadence.
    KeyPackageFailureKind.noRelayResponded ||
    KeyPackageFailureKind.publishNotAcked ||
    KeyPackageFailureKind.initKeyPurgedUnreplaced =>
      KeyPackageRetryDisposition.retryPromptly,
    // Local breakage: retry, but a tight loop over a broken FFI/store buys
    // nothing but wakeups.
    KeyPackageFailureKind.tickErrored => KeyPackageRetryDisposition.retryLater,
    // Nothing a timer can fix. No secret to sign with (re-login re-arms
    // maintenance anyway), or no relay to publish to — the Rust tick returns
    // before any network work until the user adds one, so every "retry" would
    // be the same early return at a faster cadence.
    KeyPackageFailureKind.identityUnavailable ||
    KeyPackageFailureKind.noRelaysConfigured =>
      KeyPackageRetryDisposition.awaitUserAction,
  };

  @override
  String toString() =>
      'KeyPackageMaintenanceFailed(${kind.name}, ${disposition.name}, '
      'relayErrors: $relayErrors, initKeyPurged: $expiredInitKeyPurged)';
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

  /// The `KeyPackage`-discovery (kind 10002 NIP-65) category outcome.
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
    this.relaysStillConnecting = 0,
    this.relaysDisconnected = 0,
  });

  /// An empty (engine-off) result — the best-effort failure fallback.
  const SubscriptionHealthResult.empty() : this();

  /// What the tick did.
  final SubscriptionHealthAction action;

  /// Relays in the engine pool at check time (0 when engine off).
  final int relaysTotal;

  /// Relays still coming up at check time — `Initialized`/`Pending`/
  /// `Connecting` (0 when engine off). A transient state that never triggers a
  /// resubscribe; surfaced so a caller can tell "all healthy" from "some still
  /// connecting".
  final int relaysStillConnecting;

  /// Relays found dropped at check time (0 when engine off).
  final int relaysDisconnected;
}

/// Presence-only result of the one-time legacy KeyPackage retraction
/// (Dark Matter cutover, security F10a). Counters only — no relay urls,
/// event ids, or `d` values — mirrors the Rust `LegacyRetractionOutcomeFfi`.
@immutable
class LegacyRetractionResult {
  /// Creates a legacy-retraction result.
  const LegacyRetractionResult({
    this.alreadyDone = false,
    this.legacy443Scrubbed = 0,
    this.relayListRetracted = false,
    this.relayErrors = 0,
  });

  /// An empty result (e.g. a best-effort call that failed / no-op'd).
  const LegacyRetractionResult.empty() : this();

  /// `true` when the sentinel was already set (no work done this call).
  final bool alreadyDone;

  /// Stale legacy kind-443 KeyPackage twins scrubbed (kind-5 deletions ACKed).
  final int legacy443Scrubbed;

  /// `true` when the kind-10051 KeyPackage-relay list was retracted (≥1 ACK).
  final bool relayListRetracted;

  /// Relay probes / publishes that errored (tallied, never fatal).
  final int relayErrors;
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

/// Thrown when no relay accepted an event and at least one blamed this
/// device's clock.
///
/// A distinct type rather than a flag on [RelayServiceException] because the
/// two demand different handling and different words: an ordinary publish
/// failure is transient and worth retrying, whereas this one persists until
/// the user fixes their clock. A user told "location sharing is failing"
/// cannot act; a user told "this phone's clock is wrong" can.
///
/// Carries no relay-controlled text. The direction is classified in Rust
/// (`haven_core::relay::clock_skew`) and crosses the FFI as a closed token;
/// the relay's own words are discarded there and never reach a log line or a
/// UI string (Security Rule 8).
class RelayClockRejectionException implements Exception {
  /// Creates a clock-rejection exception.
  ///
  /// [complaintToken] is the wire token (`ahead` / `behind` / `unspecified`)
  /// carried by `RelayError::DeviceClockRejected`. It is kept as a plain
  /// string so this layer stays free of a dependency on the detector, which
  /// owns the enum.
  const RelayClockRejectionException(this.complaintToken);

  /// The direction the relays reported, as a wire token.
  final String complaintToken;

  @override
  String toString() =>
      'RelayClockRejectionException(device clock $complaintToken)';
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
  /// Fetches a user's KeyPackage relay list.
  ///
  /// Resolves through the Dark Matter discovery cascade: the legacy kind-10051
  /// list first, then the kind-10002 NIP-65 list that replaced it. Both tiers
  /// are still consulted so an account that has not re-published since the
  /// cutover stays reachable.
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
  /// First resolves the user's KeyPackage relay list through the discovery
  /// cascade (legacy kind 10051, then kind-10002 NIP-65, then defaults), then
  /// fetches the KeyPackage from those relays.
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
  /// Best-effort — it does not throw (a background/timer tick must never
  /// throw). It reports failure *as a value*: a
  /// [KeyPackageMaintenanceFailed], which is a distinct variant of the sealed
  /// [KeyPackageMaintenanceOutcome] and therefore cannot be mistaken for
  /// [KeyPackageMaintenanceHealthy].
  ///
  /// ## Two zero-responder cases, separated by `relaysTargeted` (gap closed)
  ///
  /// "No `KeyPackage` relays are configured" and "every configured relay was
  /// unreachable" are reported identically by every OTHER field of
  /// `KpMaintenanceOutcomeFfi` — action `alreadyHealthy`,
  /// `respondersProbed == 0`, `relayErrors == 0` — because the Rust decision
  /// fails closed in both cases. They used to collapse into a single
  /// [KeyPackageFailureKind.noRelayResponded] here, which retried a
  /// misconfigured account forever on the fast ladder and told an offline user
  /// to go change a setting.
  ///
  /// The core now reports `relaysTargeted` (the configured own-relay count,
  /// taken before any relay is contacted) and it is the ONLY field that tells
  /// them apart:
  ///
  /// * `relaysTargeted == 0` → [KeyPackageFailureKind.noRelaysConfigured] →
  ///   [KeyPackageRetryDisposition.awaitUserAction].
  /// * `relaysTargeted > 0` with `respondersProbed == 0` →
  ///   [KeyPackageFailureKind.noRelayResponded] →
  ///   [KeyPackageRetryDisposition.retryPromptly].
  ///
  /// `classifyKeyPackageMaintenance` owns that split; the reasoning is kept
  /// here because the two cases still look identical on the wire, so anything
  /// that drops the field re-collapses them silently.
  @useResult
  Future<KeyPackageMaintenanceOutcome> maintainKeyPackage({
    required CircleManagerFfi circle,
    required List<int> identitySecretBytes,
  });

  /// Runs an M8 relay-list maintenance tick (kind 10050 inbox + kind 10002
  /// NIP-65 `KeyPackage`-discovery list).
  ///
  /// Network-probes the user's OWN relays for each list and republishes to
  /// own relays only when missing/drifted, honoring the per-category privacy
  /// toggle. `circle` is the circle-manager FFI
  /// handle; the secret bytes are consumed by the FFI and zeroized Rust-side.

  ///
  /// Best-effort — returns a [RelayListMaintenanceResult.empty] on failure
  /// rather than throwing.
  Future<RelayListMaintenanceResult> maintainRelayList({
    required CircleManagerFfi circle,
    required List<int> identitySecretBytes,
  });

  /// Once-only Dark Matter cutover cleanup (plan §6 step 5 / security F10a):
  /// retracts this account's stale pre-migration KeyPackage advertisements
  /// (legacy kind-443 twins + the kind-10051 relay list) so an old-stack
  /// client cannot mint a Welcome the new stack can't process.
  ///
  /// Self-gates on a persisted sentinel (`legacy_kp_retraction_done`) so it
  /// fires at most once; a repeat call after the sentinel is set returns
  /// [LegacyRetractionResult.alreadyDone] `== true` with no relay traffic.
  /// `circle` is the circle-manager FFI handle; the secret bytes are
  /// consumed by the FFI and zeroized Rust-side.
  ///
  /// Best-effort — returns a [LegacyRetractionResult.empty] on failure rather
  /// than throwing.
  Future<LegacyRetractionResult> retractLegacyKeyMaterial({
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
