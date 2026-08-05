/// Production implementation of [RelayService] using Rust core.
///
/// This implementation:
/// - Uses haven-core for relay connections (via flutter_rust_bridge)
/// - Direct WSS connections to Nostr relays
///
/// # Architecture
///
/// ```text
/// Flutter App
///     |
///     +-- NostrRelayService (this class)
///             |
///             +-- RelayManagerFfi (Rust via FFI)
///                     |
///                     +-- Nostr Relay Pool (WSS)
/// ```
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'package:haven/src/rust/api.dart';
// Prefixed alias so the top-level `maintainSubscriptionHealth` FRB free
// function can be called from the identically-named method below without
// shadowing/recursion.
import 'package:haven/src/rust/api.dart' as rust_ffi;
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/clock_skew_detector.dart';
import 'package:haven/src/services/relay_service.dart';
import 'package:meta/meta.dart' show useResult;

// Re-exported for backward compatibility: `DataDirectoryProvider` +
// `PathProviderDataDirectory` moved to `data_directory_provider.dart` (the
// single-source-of-truth resolver, M7-6). Existing importers of this file
// keep resolving them.
export 'package:haven/src/services/data_directory_provider.dart'
    show DataDirectoryProvider, PathProviderDataDirectory;

/// Turns a Rust `KeyPackage` maintenance tick's counters into the three-way
/// [KeyPackageMaintenanceOutcome].
///
/// A top-level function rather than a private method because it is the whole
/// of the health verdict, and it must stay provable without an FFI bridge:
/// `KpMaintenanceOutcomeFfi` is a plain generated value type, so every branch
/// here is reachable from a host `flutter test`.
///
/// **The Rust action alone is NOT the verdict.** It names the branch the tick
/// took, not what that branch achieved, and several of its values are
/// ambiguous about whether anything actually landed. Before this function
/// existed, every one of those ambiguities resolved to "healthy":
///
/// - `alreadyHealthy` is also what the tick reports when it probed nothing.
///   `decide_kp_maintenance` fails closed on an empty responder set ("we cannot
///   confirm a drop, so do nothing"), which is right as a *decision* and wrong
///   as a *verdict*: a tick that reached no relay confirmed no canonical
///   either. Only `respondersProbed > 0` makes it health. The same shape is
///   returned when the account has no `KeyPackage` relays configured at all —
///   `relaysTargeted` is the only field that separates those two, and their
///   remedies are opposite (retry the network vs. add a relay), so the split
///   is made here rather than left to each caller.
/// - `republishedStableD` / `republishedFreshD` / the two `rotated*` values are
///   all picked by `RelayManagerFfi::republish_key_package` *before* it knows
///   whether the write was acked; the ack is reported separately, through
///   `relaysHealed` — which is `0` when `publish_event` returned
///   `AllRelaysFailed`. That counter is the one the pre-fix Dart result type
///   dropped, so a `KeyPackage` that reached no relay arrived in Dart labelled
///   "republished" and the login publisher scored it as success.
/// - `expiredInitKeyPurged` is set on any tick that deleted the tracked
///   package's private `init_key` at `Lifetime.not_after`. It fires
///   independently of the action — including on ticks where no relay was even
///   contacted — and once it is set the account cannot be invited through that
///   package at all, whatever else the tick reports.
///
/// Reads only counters, booleans and a closed enum; carries nothing that could
/// leak (Security Rule 4/6/8).
@visibleForTesting
KeyPackageMaintenanceOutcome classifyKeyPackageMaintenance(
  KpMaintenanceOutcomeFfi r,
) {
  switch (r.action) {
    case KpMaintenanceActionFfi.republishedStableD:
    case KpMaintenanceActionFfi.republishedFreshD:
    // A lifetime rotation is a publish like any other, so it reads the same
    // way: the action names the branch that ran, `relaysHealed` says whether a
    // relay acked it. `mintedFreshSlot` stays false below — a rotation re-mints
    // the MATERIAL into the SAME `d` (the transport binding forbids a fresh
    // slot for a routine replacement), so it is not a new slot.
    case KpMaintenanceActionFfi.rotatedExpiringMaterial:
    case KpMaintenanceActionFfi.rotatedUnreadableLifetime:
      // "Sent" is not "acked" (Security Rule 13's principle, applied to the
      // reachability plane).
      if (r.relaysHealed == 0) {
        return KeyPackageMaintenanceFailed(
          // A rotation that did not land is the worse of the two: the old
          // material is on its way out (and may already be purged) with no
          // replacement advertised.
          r.expiredInitKeyPurged
              ? KeyPackageFailureKind.initKeyPurgedUnreplaced
              : KeyPackageFailureKind.publishNotAcked,
          relayErrors: r.relayErrors,
          expiredInitKeyPurged: r.expiredInitKeyPurged,
        );
      }
      return KeyPackageMaintenancePublished(
        relaysAcked: r.relaysHealed,
        mintedFreshSlot: r.action == KpMaintenanceActionFfi.republishedFreshD,
        respondersProbed: r.respondersProbed,
        relayErrors: r.relayErrors,
        expiredInitKeyPurged: r.expiredInitKeyPurged,
      );
    case KpMaintenanceActionFfi.alreadyHealthy:
    case KpMaintenanceActionFfi.seededD:
      // The purge bound fires ahead of (and independently of) the relay work,
      // so it can arrive on a no-publish action — including the
      // no-relays-configured early return. The engine no longer holds the
      // private half of whatever is on those relays, so nothing here can be
      // health, however many canonicals the probe saw.
      if (r.expiredInitKeyPurged) {
        return KeyPackageMaintenanceFailed(
          KeyPackageFailureKind.initKeyPurgedUnreplaced,
          relayErrors: r.relayErrors,
          expiredInitKeyPurged: true,
        );
      }
      // Nothing was probed, or nothing was found: either way this tick has no
      // evidence the account is reachable, and absence of evidence must not be
      // reported as evidence of health.
      if (r.respondersProbed == 0 || r.canonicalOnRelays == 0) {
        // WHICH failure it is comes from `relaysTargeted` — the configured
        // own-relay count, taken before any relay is contacted — and from
        // nothing else: an account with no relays and an account whose every
        // relay is down report the same action and the same zero counters.
        // `respondersProbed == 0` is implied by `relaysTargeted == 0` on any
        // coherent tick (responders are a subset of the targets), and is
        // re-stated so a contradictory shape — a relay answered, yet the count
        // says none were targeted — falls to the transient reading instead of
        // telling the user to configure a relay that evidently exists.
        final nothingConfigured =
            r.relaysTargeted == 0 && r.respondersProbed == 0;
        return KeyPackageMaintenanceFailed(
          nothingConfigured
              ? KeyPackageFailureKind.noRelaysConfigured
              : KeyPackageFailureKind.noRelayResponded,
          relayErrors: r.relayErrors,
        );
      }
      return KeyPackageMaintenanceHealthy(
        canonicalOnRelays: r.canonicalOnRelays,
        respondersProbed: r.respondersProbed,
        seededStableSlot: r.action == KpMaintenanceActionFfi.seededD,
        relayErrors: r.relayErrors,
      );
  }
}

/// Production implementation of [RelayService].
///
/// Uses the Rust core for direct WSS relay connections.
class NostrRelayService implements RelayService {
  /// Creates a new [NostrRelayService].
  ///
  /// The service must be initialized with [initialize] before use.
  NostrRelayService();

  RelayManagerFfi? _manager;
  bool _initialized = false;
  Completer<void>? _initCompleter;

  /// Initializes the relay manager.
  ///
  /// Must be called before any other methods.
  /// Thread-safe: concurrent calls will wait for the first initialization.
  Future<void> initialize() async {
    if (_initialized) return;

    // If initialization is in progress, wait for it
    if (_initCompleter != null) {
      await _initCompleter!.future;
      return;
    }

    // Start initialization
    _initCompleter = Completer<void>();
    try {
      _manager = await RelayManagerFfi.newInstance();
      _initialized = true;
      _initCompleter!.complete();
      _initCompleter = null;
    } on Object catch (e, stackTrace) {
      _initCompleter!.completeError(e, stackTrace);
      _initCompleter = null;
      rethrow;
    }
  }

  /// Ensures the manager is initialized.
  Future<RelayManagerFfi> _ensureInitialized() async {
    if (!_initialized || _manager == null) {
      await initialize();
    }
    return _manager!;
  }

  /// Converts FFI RelayRejection to service RelayRejection.
  RelayRejection _convertRejection(RelayRejectionFfi ffiRejection) {
    return RelayRejection(relay: ffiRejection.url, reason: ffiRejection.reason);
  }

  /// Converts FFI PublishResult to service PublishResult.
  PublishResult _convertPublishResult(PublishResultFfi ffiResult) {
    return PublishResult(
      eventId: ffiResult.eventId,
      acceptedBy: ffiResult.acceptedBy,
      rejectedBy: ffiResult.rejectedBy.map(_convertRejection).toList(),
      failed: ffiResult.failed,
    );
  }

  @override
  Future<List<String>> fetchKeyPackageRelays(String pubkey) async {
    final manager = await _ensureInitialized();

    try {
      return await manager.fetchKeypackageRelays(pubkey: pubkey);
    } on Object catch (e) {
      debugPrint('Failed to fetch KeyPackage relays: ${e.runtimeType}');
      throw const RelayServiceException('Failed to fetch KeyPackage relays');
    }
  }

  @override
  Future<List<String>> fetchNip65Relays(String pubkey) async {
    final manager = await _ensureInitialized();

    try {
      return await manager.fetchNip65Relays(pubkey: pubkey);
    } on Object catch (e) {
      debugPrint('Failed to fetch NIP-65 relays: ${e.runtimeType}');
      throw const RelayServiceException('Failed to fetch NIP-65 relays');
    }
  }

  @override
  Future<KeyPackageData?> fetchKeyPackage(String pubkey) async {
    final manager = await _ensureInitialized();

    try {
      // Use the convenience method that fetches both key package and relays
      final result = await manager.fetchMemberKeypackage(pubkey: pubkey);

      if (result == null) {
        return null;
      }

      return KeyPackageData(
        pubkey: pubkey,
        eventJson: result.keyPackageJson,
        relays: result.inboxRelays,
        nip65Relays: result.nip65Relays,
      );
    } on Object catch (e) {
      debugPrint('Failed to fetch KeyPackage: ${e.runtimeType}');
      throw const RelayServiceException('Failed to fetch KeyPackage');
    }
  }

  @override
  Future<PublishResult> publishWelcome({
    required GiftWrappedWelcome welcomeEvent,
  }) async {
    final manager = await _ensureInitialized();

    try {
      final ffiResult = await manager.publishEvent(
        eventJson: welcomeEvent.eventJson,
        relays: welcomeEvent.recipientRelays,
      );

      return _convertPublishResult(ffiResult);
    } on Object catch (e) {
      debugPrint('Failed to publish welcome event: ${e.runtimeType}');
      throw const RelayServiceException('Failed to publish welcome event');
    }
  }

  @override
  Future<void> publishEventFireAndForget({
    required String eventJson,
    required List<String> relays,
  }) async {
    final manager = await _ensureInitialized();

    try {
      manager.publishEventFireAndForget(eventJson: eventJson, relays: relays);
    } on Object catch (e) {
      debugPrint('Failed to publish fire-and-forget event: ${e.runtimeType}');
      throw const RelayServiceException(
        'Failed to publish fire-and-forget event',
      );
    }
  }

  @override
  Future<List<String>> fetchGiftWraps({
    required String recipientPubkey,
    required List<String> relays,
    DateTime? since,
  }) async {
    final manager = await _ensureInitialized();

    try {
      final sinceTimestamp = since != null
          ? since.millisecondsSinceEpoch ~/ 1000
          : null;

      return await manager.fetchGiftWraps(
        recipientPubkey: recipientPubkey,
        relays: relays,
        since: sinceTimestamp,
      );
    } on Object catch (e) {
      debugPrint('Failed to fetch gift wraps: ${e.runtimeType}');
      throw const RelayServiceException('Failed to fetch gift wraps');
    }
  }

  @override
  Future<List<RelayGiftWrapFetch>> fetchGiftWrapsPerRelay({
    required String recipientPubkey,
    required List<String> relays,
    DateTime? since,
  }) async {
    final manager = await _ensureInitialized();

    try {
      final sinceTimestamp = since != null
          ? since.millisecondsSinceEpoch ~/ 1000
          : null;

      final ffiResults = await manager.fetchGiftWrapsPerRelay(
        recipientPubkey: recipientPubkey,
        relays: relays,
        since: sinceTimestamp,
      );

      return ffiResults
          .map(
            (r) => RelayGiftWrapFetch(
              relayUrl: r.relayUrl,
              responded: r.responded,
              events: r.events,
            ),
          )
          .toList();
    } on Object catch (e) {
      debugPrint('Failed to fetch gift wraps per relay: ${e.runtimeType}');
      throw const RelayServiceException('Failed to fetch gift wraps per relay');
    }
  }

  @override
  Future<CatchupResult> runCatchup({
    required CircleManagerFfi circle,
    required String ownPubkeyHex,
    int maxDurationSecs = 20,
  }) async {
    // Best-effort: a background/resume sweep must never throw into its caller.
    try {
      final manager = await _ensureInitialized();
      final r = await manager.runCatchupAllCircles(
        circle: circle,
        ownPubkeyHex: ownPubkeyHex,
        maxDurationSecs: BigInt.from(maxDurationSecs),
      );
      return CatchupResult(
        circlesSwept: r.circlesSwept,
        eventsApplied: r.eventsApplied,
        eventsDeferred: r.eventsDeferred,
        cursorsAdvanced: r.cursorsAdvanced,
        deadlineHit: r.deadlineHit,
        relayErrors: r.relayErrors,
      );
    } on Object catch (e) {
      debugPrint('[Catchup] sweep failed: ${e.runtimeType}');
      return const CatchupResult.empty();
    }
  }

  @override
  @useResult
  Future<KeyPackageMaintenanceOutcome> maintainKeyPackage({
    required CircleManagerFfi circle,
    required List<int> identitySecretBytes,
  }) async {
    // Best-effort: a scheduled maintenance tick must never throw into its
    // caller. The secret bytes are consumed + zeroized Rust-side.
    try {
      final manager = await _ensureInitialized();
      final r = await manager.maintainKeyPackage(
        circle: circle,
        identitySecretBytes: identitySecretBytes,
      );
      return classifyKeyPackageMaintenance(r);
    } on Object catch (e) {
      debugPrint('[Maintenance] KeyPackage tick failed: ${e.runtimeType}');
      return const KeyPackageMaintenanceFailed(
        KeyPackageFailureKind.tickErrored,
      );
    }
  }

  @override
  Future<RelayListMaintenanceResult> maintainRelayList({
    required CircleManagerFfi circle,
    required List<int> identitySecretBytes,
  }) async {
    // Best-effort: never throws. Secret bytes consumed + zeroized Rust-side.
    try {
      final manager = await _ensureInitialized();
      final r = await manager.maintainRelayList(
        circle: circle,
        identitySecretBytes: identitySecretBytes,
      );
      return RelayListMaintenanceResult(
        inbox: _mapRelayListCategory(r.inbox),
        keyPackage: _mapRelayListCategory(r.keyPackage),
      );
    } on Object catch (e) {
      debugPrint('[Maintenance] relay-list tick failed: ${e.runtimeType}');
      return const RelayListMaintenanceResult.empty();
    }
  }

  @override
  Future<LegacyRetractionResult> retractLegacyKeyMaterial({
    required CircleManagerFfi circle,
    required List<int> identitySecretBytes,
  }) async {
    // Best-effort: a scheduled/cutover tick must never throw into its
    // caller. The secret bytes are consumed + zeroized Rust-side.
    try {
      final manager = await _ensureInitialized();
      final r = await manager.retractLegacyKeyMaterial(
        circle: circle,
        identitySecretBytes: identitySecretBytes,
      );
      return LegacyRetractionResult(
        alreadyDone: r.alreadyDone,
        legacy443Scrubbed: r.legacy443Scrubbed,
        relayListRetracted: r.relayListRetracted,
        relayErrors: r.relayErrors,
      );
    } on Object catch (e) {
      debugPrint('[Cutover] legacy retraction failed: ${e.runtimeType}');
      return const LegacyRetractionResult.empty();
    }
  }

  @override
  Future<SubscriptionHealthResult> maintainSubscriptionHealth() async {
    // Best-effort: never throws. No secret, no circle handle — the FFI reads
    // the live-sync engine's SESSION and self-gates to a no-op when off.
    try {
      final r = await rust_ffi.maintainSubscriptionHealth();
      return SubscriptionHealthResult(
        action: _mapHealthAction(r.action),
        relaysTotal: r.relaysTotal,
        relaysStillConnecting: r.relaysStillConnecting,
        relaysDisconnected: r.relaysDisconnected,
      );
    } on Object catch (e) {
      debugPrint('[Maintenance] health tick failed: ${e.runtimeType}');
      return const SubscriptionHealthResult.empty();
    }
  }

  /// Maps the FFI subscription-health action enum to the service enum.
  SubscriptionHealthAction _mapHealthAction(SubscriptionHealthActionFfi a) {
    switch (a) {
      case SubscriptionHealthActionFfi.engineOff:
        return SubscriptionHealthAction.engineOff;
      case SubscriptionHealthActionFfi.healthy:
        return SubscriptionHealthAction.healthy;
      case SubscriptionHealthActionFfi.resubscribed:
        return SubscriptionHealthAction.resubscribed;
    }
  }

  /// Maps an FFI relay-list per-category outcome to the service type.
  RelayListCategoryResult _mapRelayListCategory(
    RelayListCategoryOutcomeFfi c,
  ) {
    final RelayListMaintenanceAction action;
    switch (c.action) {
      case RelayListActionFfi.suppressed:
        action = RelayListMaintenanceAction.suppressed;
      case RelayListActionFfi.alreadyCurrent:
        action = RelayListMaintenanceAction.alreadyCurrent;
      case RelayListActionFfi.republished:
        action = RelayListMaintenanceAction.republished;
    }
    return RelayListCategoryResult(action: action, relayErrors: c.relayErrors);
  }

  @override
  Future<PublishResult> publishEvent({
    required String eventJson,
    required List<String> relays,
  }) async {
    final manager = await _ensureInitialized();

    try {
      final ffiResult = await manager.publishEvent(
        eventJson: eventJson,
        relays: relays,
      );

      return _convertPublishResult(ffiResult);
    } on Object catch (e) {
      // A device-clock rejection must NOT be flattened into the generic
      // failure: it is the one publish error the user can actually act on, and
      // collapsing it here is what made a fast clock a silent outage. The
      // token is Haven-authored (`RelayError::DeviceClockRejected`), so the
      // match cannot be steered by a hostile relay, and no relay prose is
      // logged or rethrown (Security Rule 8).
      final complaintToken = _deviceClockComplaintToken(e);
      if (complaintToken != null) {
        debugPrint(
          'Publish rejected on timestamp grounds (device clock '
          '$complaintToken)',
        );
        throw RelayClockRejectionException(complaintToken);
      }
      debugPrint('Failed to publish event: ${e.runtimeType}');
      throw const RelayServiceException('Failed to publish event');
    }
  }

  /// Extracts the wire token from a `RelayError::DeviceClockRejected` that the
  /// FFI flattened to a string, or `null` for any other error.
  ///
  /// Delegates to [ClockSkewDetector.complaintFromError] rather than
  /// re-implementing the match: a second copy of the parser is a second thing
  /// that can silently stop recognising the token, and only one of them would
  /// have tests. `DeviceClockComplaint.name` is the wire token by construction
  /// — pinned by `clock_skew_detector_test.dart`.
  static String? _deviceClockComplaintToken(Object error) =>
      ClockSkewDetector.complaintFromError(error)?.name;

  @override
  Future<List<String>> fetchGroupMessages({
    required List<int> nostrGroupId,
    required List<String> relays,
    DateTime? since,
    int? limit,
  }) async {
    final manager = await _ensureInitialized();

    try {
      final sinceTimestamp = since != null
          ? since.millisecondsSinceEpoch ~/ 1000
          : null;

      return await manager.fetchGroupMessages(
        nostrGroupId: Uint8List.fromList(nostrGroupId),
        relays: relays,
        since: sinceTimestamp,
        limit: limit,
      );
    } on Object catch (e) {
      debugPrint('Failed to fetch group messages: ${e.runtimeType}');
      throw const RelayServiceException('Failed to fetch group messages');
    }
  }

  @override
  Future<RelayEventCheck> checkEventOnRelay({
    required String relayUrl,
    required String authorPubkey,
    required int eventKind,
  }) async {
    final manager = await _ensureInitialized();

    try {
      final ffiResult = await manager.checkEventOnRelay(
        relayUrl: relayUrl,
        authorPubkey: authorPubkey,
        eventKind: eventKind,
      );

      return RelayEventCheck(
        relayUrl: ffiResult.relayUrl,
        found: ffiResult.found,
        eventCount: ffiResult.eventCount,
        newestTimestamp: ffiResult.newestTimestamp != null
            ? DateTime.fromMillisecondsSinceEpoch(
                ffiResult.newestTimestamp! * 1000,
              )
            : null,
      );
    } on Object catch (e) {
      debugPrint('Failed to check event on relay: ${e.runtimeType}');
      throw const RelayServiceException('Failed to check event on relay');
    }
  }

  /// Shuts down the relay manager.
  ///
  /// Call this when the app is being closed or going to background.
  Future<void> shutdown() async {
    if (_manager != null) {
      try {
        await _manager!.shutdown();
      } on Exception {
        // Ignore shutdown errors
      }
      _manager = null;
      _initialized = false;
    }
  }

  @override
  Future<void> disconnectRelay(String url) async {
    try {
      final manager = await _ensureInitialized();
      await manager.disconnectRelay(url: url);
    } on Object catch (e) {
      // Best-effort. The relay won't be referenced by storage after this
      // point, so even if the disconnect fails, no further publishes /
      // fetches will target it.
      debugPrint('disconnectRelay failed: ${e.runtimeType}');
    }
  }
}
