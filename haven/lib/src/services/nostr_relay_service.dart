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
import 'package:haven/src/services/circle_change_driver.dart';
import 'package:haven/src/services/circle_service.dart';
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
/// - `retiredMalformedSlot` marks a tick that COMPLETED the one-time retirement
///   of a pre-width-fix `d` slot. It rides on whichever verdict that tick's own
///   relay work earned — a re-point is a publish and reports as one, an
///   adoption or a retraction-only run is health — because completing the
///   migration is not by itself evidence that a relay is serving anything.
///
/// Reads only counters, booleans and a closed enum; carries nothing that could
/// leak (Security Rule 4/6/8).
/// Maps the FFI subscription-health action to the service enum.
///
/// A top-level function rather than a private method for the same reason
/// [classifyKeyPackageMaintenance] is one: `SubscriptionHealthActionFfi` is a
/// plain generated value type, so every branch here stays reachable from a host
/// `flutter test` with no FFI bridge.
///
/// Exhaustive with no `default`, deliberately: a new FFI variant must be a
/// COMPILE error here, not a value that silently falls through to whichever
/// branch happens to be last. The two re-anchor remedies stay separate all the
/// way across the boundary — see [SubscriptionHealthAction.targetedReanchor].
///
/// Reads a closed enum and returns a closed enum; carries nothing that could
/// leak (Security Rule 4/6/8).
@visibleForTesting
SubscriptionHealthAction mapSubscriptionHealthAction(
  SubscriptionHealthActionFfi a,
) {
  switch (a) {
    case SubscriptionHealthActionFfi.engineOff:
      return SubscriptionHealthAction.engineOff;
    case SubscriptionHealthActionFfi.healthy:
      return SubscriptionHealthAction.healthy;
    case SubscriptionHealthActionFfi.resubscribed:
      return SubscriptionHealthAction.resubscribed;
    case SubscriptionHealthActionFfi.targetedReanchor:
      return SubscriptionHealthAction.targetedReanchor;
    case SubscriptionHealthActionFfi.paused:
      return SubscriptionHealthAction.paused;
    case SubscriptionHealthActionFfi.awaitingForeground:
      return SubscriptionHealthAction.awaitingForeground;
  }
}

@visibleForTesting
KeyPackageMaintenanceOutcome classifyKeyPackageMaintenance(
  KpMaintenanceOutcomeFfi r,
) {
  switch (r.action) {
    case KpMaintenanceActionFfi.republishedStableD:
    case KpMaintenanceActionFfi.republishedFreshD:
    // A lifetime rotation is a publish like any other, so it reads the same
    // way: the action names the branch that ran, `relaysHealed` says whether a
    // relay acked it. `isFreshSlotMinted` stays false below — a rotation
    // re-mints the MATERIAL into the SAME `d` (the transport binding forbids a
    // fresh slot for a routine replacement), so it is not a new slot.
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
        isFreshSlotMinted: r.action == KpMaintenanceActionFfi.republishedFreshD,
        respondersProbed: r.respondersProbed,
        relayErrors: r.relayErrors,
        expiredInitKeyPurged: r.expiredInitKeyPurged,
        isMalformedSlotRetired: r.retiredMalformedSlot,
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
        isStableSlotSeeded: r.action == KpMaintenanceActionFfi.seededD,
        relayErrors: r.relayErrors,
        isMalformedSlotRetired: r.retiredMalformedSlot,
      );
    case KpMaintenanceActionFfi.awaitingResetAcknowledgement:
      return KeyPackageMaintenanceFailed(
        KeyPackageFailureKind.awaitingResetAcknowledgement,
        relayErrors: r.relayErrors,
        expiredInitKeyPurged: r.expiredInitKeyPurged,
      );
  }
}

/// Production implementation of [RelayService].
///
/// Uses the Rust core for direct WSS relay connections.
class NostrRelayService implements RelayService, CircleChangeDriver {
  /// Creates a new [NostrRelayService].
  ///
  /// The service must be initialized with [initialize] before use.
  ///
  /// [circleManagerFactory] hands back the circle manager the circle service
  /// already opened (never a second one over the same database). Only
  /// [fetchKeyPackage] needs it: the package is chosen by what the inviter's
  /// own circle can admit.
  ///
  /// [openPool] opens a pool; a test seam, [RelayManagerFfi.newInstance]
  /// unless given.
  ///
  /// [onClockRejected] hears every driver entry's clock evidence: what the
  /// relays of the drives it made blamed on this device's clock;
  /// [onRelayAccepted], each change a relay acknowledged.
  ///
  /// [fixOf] builds the fix a seal takes; a test seam, built through
  /// [HavenCore] unless given.
  NostrRelayService({
    Future<CircleManagerFfi> Function()? circleManagerFactory,
    Future<RelayManagerFfi> Function()? openPool,
    void Function(DeviceClockComplaintFfi complaint)? onClockRejected,
    void Function()? onRelayAccepted,
    Future<LocationMessage> Function(double latitude, double longitude)? fixOf,
  }) : _circleManagerFactory = circleManagerFactory,
       _openPool = openPool ?? RelayManagerFfi.newInstance,
       _onClockRejected = onClockRejected,
       _onRelayAccepted = onRelayAccepted,
       _fixOf = fixOf;

  /// Creates a [NostrRelayService] over an already-built [manager], so the
  /// service's handling of FFI results can be tested against a fake.
  @visibleForTesting
  NostrRelayService.withInjectedManager(
    RelayManagerFfi manager, {
    Future<CircleManagerFfi> Function()? circleManagerFactory,
  }) : _manager = manager,
       _circleManagerFactory = circleManagerFactory,
       _openPool = RelayManagerFfi.newInstance,
       _onClockRejected = null,
       _onRelayAccepted = null,
       _fixOf = null,
       _initialized = true;

  final Future<CircleManagerFfi> Function()? _circleManagerFactory;
  final Future<RelayManagerFfi> Function() _openPool;
  final void Function(DeviceClockComplaintFfi complaint)? _onClockRejected;
  final void Function()? _onRelayAccepted;
  final Future<LocationMessage> Function(double latitude, double longitude)?
  _fixOf;

  /// Hands a drive's clock evidence to [_onClockRejected], then [outcome].
  T _heard<T>(T outcome, DeviceClockComplaintFfi? complaint) {
    if (complaint != null) _onClockRejected?.call(complaint);
    return outcome;
  }

  /// As [_heard], for a change: one a relay acknowledged (`confirmed`) also
  /// tells [_onRelayAccepted], since a relay took this device's timestamp —
  /// not one the core found already so, which no relay was asked about.
  T _heardChange<T>(T outcome, EvolutionOutcomeFfi? change) {
    if (change?.status == PublishStatusFfi.confirmed &&
        change?.alreadySo != true) {
      _onRelayAccepted?.call();
    }
    return _heard(outcome, change?.clockRejected);
  }

  final _DriveRegistry _drives = _DriveRegistry();
  final _DriveRegistry _nonLocationDrives = _DriveRegistry();

  /// The driver entries this service has in flight, or `null` when it has
  /// none: what the iOS burst teardown awaits before it shuts this service's
  /// pool (the Android service awaits [inFlightNonLocationDrives] instead).
  ///
  /// Every `*Driven` entry sends what its circle owes, waits for a relay's
  /// acknowledgement and resolves it inside the one call. A pool shut under
  /// one forks nothing — the core keeps a commit whose acknowledgement it
  /// never saw recorded and awaiting, applies it only on an ack and undoes it
  /// only on every relay's refusal (`fanout_change_e2e`
  /// `a_change_no_relay_answers_for_is_awaiting_relays_never_failed`) — but
  /// it cuts the drive short and leaves its sends to the next wake. Waiting
  /// lets it finish; each drive is bounded by the core's own budget.
  ///
  /// Non-null while any is in flight: the drives in flight at the read, as
  /// one future — the same one on every read until another drive joins —
  /// and `null` once every one has ended, those that threw included. A
  /// reader waits out what it saw, never a chain growing behind it, so each
  /// read is bounded by the longest of those drives' own budgets: the burst
  /// adopts later work for a capped number of rounds, and the Android
  /// service reads once, after the latch that keeps any later drive from
  /// taking the pool.
  Future<void>? get inFlightDrives => _drives.quiescent;

  /// As [inFlightDrives], without a location's seal and send: what the
  /// Android service's teardown awaits past its one bounded drain, which a
  /// location drive stays inside. One cut at that bound loses a sample and
  /// leaves what it carried recorded for the next wake; waiting it out would
  /// outlast the UI's handover budget and push a resume into a force-release.
  Future<void>? get inFlightNonLocationDrives => _nonLocationDrives.quiescent;

  /// Runs [drive] registered in [inFlightDrives], and — unless it is a
  /// [location] seal or send — in [inFlightNonLocationDrives].
  Future<T> _driving<T>(Future<T> Function() drive, {bool location = false}) =>
      _drives.run(location ? drive : () => _nonLocationDrives.run(drive));

  /// Hands [complaint] to where this service's drives' clock evidence goes,
  /// as a drive would: what proves the provider's wiring.
  @visibleForTesting
  void hearClockEvidenceForTest(DeviceClockComplaintFfi complaint) =>
      _heard(null, complaint);

  /// Reports one acknowledged change where this service reports them, as a
  /// change a relay acknowledged would: what proves the provider's wiring.
  @visibleForTesting
  void hearRelayAcceptedForTest() => _heardChange(
    null,
    const EvolutionOutcomeFfi(
      status: PublishStatusFfi.confirmed,
      welcomesDelivered: 0,
      welcomesTotal: 0,
      reinviteOwed: false,
      replayed: [],
    ),
  );

  RelayManagerFfi? _manager;
  bool _initialized = false;
  Completer<void>? _initCompleter;

  /// Whether a pool is open: the next call reuses it rather than open one.
  @visibleForTesting
  bool get poolOpenForTest => _manager != null;

  /// Initializes the relay manager.
  ///
  /// Must be called before any other methods.
  /// Thread-safe: concurrent calls will wait for the first initialization.
  Future<void> initialize() async {
    if (_latched) {
      throw const RelayServiceException('Relay service latched');
    }
    if (_initialized) return;

    // If initialization is in progress, wait for it
    if (_initCompleter != null) {
      await _initCompleter!.future;
      return;
    }

    // Start initialization. The completer's own future is marked handled:
    // the caller that opens hears a failure through the rethrow below, and a
    // waiter through its own await, so nobody else needs it reported.
    _initCompleter = Completer<void>()..future.ignore();
    try {
      _manager = await _openPool();
      _initialized = true;
      _initCompleter!.complete();
      _initCompleter = null;
    } on Object catch (e, stackTrace) {
      _initCompleter!.completeError(e, stackTrace);
      _initCompleter = null;
      rethrow;
    }
  }

  /// Ensures the manager is initialized, and never hands out one a shutdown
  /// is forgetting: a call that waited on the same open as a shutdown waits
  /// for the shutdown to let go of that pool, then opens its own.
  Future<RelayManagerFfi> _ensureInitialized() async {
    while (true) {
      final forgetting = _forgetting;
      if (forgetting != null) {
        await forgetting.future;
        continue;
      }
      await initialize();
      // An open that was under way when the latch landed hands its pool to
      // nobody: the teardown's shutdown closes it.
      if (_latched) throw const RelayServiceException('Relay service latched');
      final manager = _manager;
      if (_forgetting == null && manager != null) return manager;
    }
  }

  /// Set from a [shutdown]'s call until it has forgotten the pool it shuts.
  Completer<void>? _forgetting;

  /// Set by [latch]: this instance hands out no pool again.
  bool _latched = false;

  /// Latches this instance: every later call — and one still waiting on an
  /// open — fails with a [RelayServiceException] through its caller's own
  /// failure path before it reaches a relay, the pool already open
  /// included. A call already holding the pool runs on until [shutdown]
  /// closes it. The Android service's stop, so a step that slips past its
  /// stop reads reaches no relay; never the iOS burst plane, which shuts its
  /// pool between bursts and opens it again.
  void latch() => _latched = true;

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
  Future<KeyPackageData?> fetchKeyPackage(
    String pubkey, {
    List<int>? mlsGroupId,
  }) async {
    final manager = await _ensureInitialized();

    try {
      // No inviter, no selection: which package fits depends on the circle
      // the person is being invited into.
      final circleManagerFactory = _circleManagerFactory;
      if (circleManagerFactory == null) {
        throw StateError('no circle manager to select a KeyPackage for');
      }
      // Use the convenience method that fetches both key package and relays
      final result = await manager.fetchMemberKeypackage(
        pubkey: pubkey,
        circle: await circleManagerFactory(),
        mlsGroupId: mlsGroupId == null ? null : Uint8List.fromList(mlsGroupId),
      );

      if (result == null) {
        return null;
      }

      // The verified author Rust returns, never the requested label: that is
      // who the Welcome reaches and whom the confirm screen names.
      return KeyPackageData(
        pubkey: result.authorNpub,
        eventJson: result.keyPackageJson,
        relays: result.inboxRelays,
        nip65Relays: result.nip65Relays,
        nip65WriteRelays: result.nip65WriteRelays,
      );
    } on Object catch (e) {
      debugPrint('Failed to fetch KeyPackage: ${e.runtimeType}');
      throw const RelayServiceException('Failed to fetch KeyPackage');
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
  Future<CatchupResult> runRefusedRefetch({
    required CircleManagerFfi circle,
    int maxDurationSecs = 20,
  }) async {
    try {
      final manager = await _ensureInitialized();
      final r = await manager.runRefusedRefetch(
        circle: circle,
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
      debugPrint('[Catchup] refetch failed: ${e.runtimeType}');
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
  Future<SubscriptionHealthResult> maintainSubscriptionHealth({
    required bool foreground,
  }) async {
    // Best-effort: never throws. No secret, no circle handle — the FFI reads
    // the live-sync engine's SESSION and self-gates to a no-op when off.
    try {
      final r = await rust_ffi.maintainSubscriptionHealth(
        foreground: foreground,
      );
      return SubscriptionHealthResult(
        action: mapSubscriptionHealthAction(r.action),
        relaysTotal: r.relaysTotal,
        relaysStillConnecting: r.relaysStillConnecting,
        relaysDisconnected: r.relaysDisconnected,
        subscriptionsExpected: r.subscriptionsExpected,
        subscriptionsLive: r.subscriptionsLive,
        subscriptionsSilent: r.subscriptionsSilent,
      );
    } on Object catch (e) {
      debugPrint('[Maintenance] health tick failed: ${e.runtimeType}');
      return const SubscriptionHealthResult.empty();
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
      case RelayListActionFfi.awaitingResetAcknowledgement:
        action = RelayListMaintenanceAction.awaitingResetAcknowledgement;
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
    } on PublishFailureFfi catch (failure) {
      // A device-clock rejection must NOT be flattened into the generic
      // failure: it is the one publish error the user can act on. Read by its
      // typed field, never from text (Security Rule 8).
      final verdict = failure.clockRejected;
      if (verdict != null) {
        debugPrint(
          'Publish rejected on timestamp grounds (device clock '
          '${verdict.name})',
        );
        throw RelayClockRejectionException(verdict);
      }
      final refusalKind = failure.refused?.name ?? '-';
      debugPrint('Failed to publish event: refused $refusalKind');
      throw const RelayServiceException('Failed to publish event');
    } on Object catch (e) {
      debugPrint('Failed to publish event: ${e.runtimeType}');
      throw const RelayServiceException('Failed to publish event');
    }
  }

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
  /// Call this when the app is being closed or going to background. The next
  /// call opens a fresh pool. A pool still being opened is waited for and shut
  /// too: left to finish, it would be the one the next call is handed.
  Future<void> shutdown() async {
    final forgotten = _forgetting = Completer<void>();
    final RelayManagerFfi? manager;
    try {
      final opening = _initCompleter?.future;
      if (opening != null) {
        try {
          await opening;
        } on Object catch (_) {
          // Nothing was opened.
        }
      }
      // Forgotten before the disconnect is awaited: a call meanwhile opens a
      // pool of its own rather than ride one going down.
      manager = _manager;
      _manager = null;
      _initialized = false;
    } finally {
      if (identical(_forgetting, forgotten)) _forgetting = null;
      forgotten.complete();
    }
    if (manager != null) {
      try {
        await manager.shutdown();
      } on Object catch (_) {
        // Ignore shutdown errors
      }
    }
  }

  // The fanout driver's change entries. FFI errors propagate to the circle
  // service, which classifies none of them (Rule 8).

  @override
  Future<CircleCreationOutcomeFfi> createCircle({
    required CircleManagerFfi circle,
    required List<int> identitySecretBytes,
    required List<MemberKeyPackageFfi> members,
    required String name,
    required String circleType,
    required List<String> relays,
    required bool foreground,
    String? description,
  }) => _driving(
    () async => (await _ensureInitialized()).createCircleDriven(
      circle: circle,
      identitySecretBytes: identitySecretBytes,
      members: members,
      name: name,
      description: description,
      circleType: circleType,
      relays: relays,
      foreground: foreground,
    ),
  );

  @override
  Future<EvolutionOutcomeFfi> addMembers({
    required CircleManagerFfi circle,
    required List<int> mlsGroupId,
    required List<MemberKeyPackageFfi> members,
    required bool foreground,
  }) => _driving(() async {
    final outcome = await (await _ensureInitialized()).addMembersDriven(
      circle: circle,
      mlsGroupId: mlsGroupId,
      members: members,
      foreground: foreground,
    );
    return _heardChange(outcome, outcome);
  });

  @override
  Future<EvolutionOutcomeFfi> removeMembers({
    required CircleManagerFfi circle,
    required List<int> mlsGroupId,
    required List<String> memberPubkeys,
    required bool foreground,
  }) => _driving(() async {
    final outcome = await (await _ensureInitialized()).removeMembersDriven(
      circle: circle,
      mlsGroupId: mlsGroupId,
      memberPubkeys: memberPubkeys,
      foreground: foreground,
    );
    return _heardChange(outcome, outcome);
  });

  @override
  Future<EvolutionOutcomeFfi> updateCircleRelays({
    required CircleManagerFfi circle,
    required List<int> mlsGroupId,
    required List<String> relays,
    required bool foreground,
  }) => _driving(() async {
    final outcome = await (await _ensureInitialized()).updateCircleRelaysDriven(
      circle: circle,
      mlsGroupId: mlsGroupId,
      relays: relays,
      foreground: foreground,
    );
    return _heardChange(outcome, outcome);
  });

  @override
  Future<EvolutionOutcomeFfi> adminHandoff({
    required CircleManagerFfi circle,
    required List<int> mlsGroupId,
    required String successor,
    required bool foreground,
  }) => _driving(() async {
    final outcome = await (await _ensureInitialized()).adminHandoffDriven(
      circle: circle,
      mlsGroupId: mlsGroupId,
      successor: successor,
      foreground: foreground,
    );
    return _heardChange(outcome, outcome);
  });

  @override
  Future<EvolutionOutcomeFfi> selfDemote({
    required CircleManagerFfi circle,
    required List<int> mlsGroupId,
    required bool foreground,
  }) => _driving(() async {
    final outcome = await (await _ensureInitialized()).selfDemoteDriven(
      circle: circle,
      mlsGroupId: mlsGroupId,
      foreground: foreground,
    );
    return _heardChange(outcome, outcome);
  });

  @override
  Future<RepairOutcomeFfi> repairRotation({
    required CircleManagerFfi circle,
    required List<int> mlsGroupId,
    required bool foreground,
  }) => _driving(() async {
    final outcome = await (await _ensureInitialized()).repairRotationDriven(
      circle: circle,
      mlsGroupId: mlsGroupId,
      foreground: foreground,
    );
    return _heardChange(outcome, outcome.rotated);
  });

  @override
  Future<RecoveryCauseFfi?> circleRecovery({
    required CircleManagerFfi circle,
    required List<int> mlsGroupId,
    required bool foreground,
  }) => _driving(
    () async => (await _ensureInitialized()).circleRecovery(
      circle: circle,
      mlsGroupId: mlsGroupId,
      foreground: foreground,
    ),
  );

  @override
  Future<IngestOutcomeFfi> ingest({
    required CircleManagerFfi circle,
    required String eventJson,
    required bool foreground,
  }) => _driving(() async {
    final outcome = await (await _ensureInitialized()).ingestDriven(
      circle: circle,
      eventJson: eventJson,
      foreground: foreground,
    );
    return _heard(outcome, outcome.clockRejected);
  });

  @override
  Future<ResumeOutcomeFfi> resume({
    required CircleManagerFfi circle,
    required bool foreground,
  }) => _driving(() async {
    final outcome = await (await _ensureInitialized()).resumeDriven(
      circle: circle,
      foreground: foreground,
    );
    return _heard(outcome, outcome.clockRejected);
  });

  @override
  Future<ReinviteDrivenFfi> reinvite({
    required CircleManagerFfi circle,
    required bool foreground,
  }) => _driving(
    () async => (await _ensureInitialized()).reinviteDriven(
      circle: circle,
      foreground: foreground,
    ),
  );

  @override
  Future<SealOutcomeFfi> sealLocation({
    required CircleManagerFfi circle,
    required List<int> mlsGroupId,
    required double latitude,
    required double longitude,
    required bool foreground,
  }) => _driving(location: true, () async {
    final manager = await _ensureInitialized();
    final fix = await (_fixOf ?? _coreFix)(latitude, longitude);
    try {
      final outcome = await manager.sealLocationDriven(
        circle: circle,
        mlsGroupId: mlsGroupId,
        location: fix,
        foreground: foreground,
      );
      return _heard<SealOutcomeFfi>(outcome, outcome.clockRejected);
    } finally {
      // The exact coordinates: held no longer than the seal that read them.
      fix.dispose();
    }
  });

  Future<LocationMessage> _coreFix(double latitude, double longitude) async =>
      (_locationCore ??= await HavenCore.newInstance()).updateLocation(
        latitude: latitude,
        longitude: longitude,
      );

  /// Builds the fix a seal takes; holds no state of its own.
  HavenCore? _locationCore;

  @override
  Future<LocationPublishFfi> publishLocation({
    required CircleManagerFfi circle,
    required SealedLocationFfi sealed,
  }) => _driving(
    location: true,
    () async => (await _ensureInitialized()).publishLocationDriven(
      circle: circle,
      sealed: sealed,
    ),
  );

  /// The leave presses and carry-ons in flight, by MLS group id: one of
  /// each per circle at a time in this isolate. A carry-on landing beside a
  /// press, or beside another carry-on, joins it; a press landing beside a
  /// carry-on runs once that carry-on has ended, since it must write the
  /// intent the carry-on read before it.
  final Map<String, Future<LeaveOutcomeFfi>> _leavePresses = {};
  final Map<String, Future<LeaveOutcomeFfi>> _leaveCarryOns = {};

  @override
  Future<LeaveOutcomeFfi> leave({
    required CircleManagerFfi circle,
    required List<int> mlsGroupId,
    required bool foreground,
  }) {
    final key = mlsGroupId.join(',');
    final carryOn = _leaveCarryOns[key];
    return _leavePresses[key] ??= _driving(() async {
      if (carryOn != null) {
        try {
          await carryOn;
        } on Object catch (_) {
          // That carry-on's failure is its caller's; the press goes on.
        }
      }
      final outcome = await (await _ensureInitialized()).leaveDriven(
        circle: circle,
        mlsGroupId: mlsGroupId,
        foreground: foreground,
      );
      return _heard(outcome, outcome.clockRejected);
    }).whenComplete(() {
      _leavePresses.remove(key);
    });
  }

  @override
  Future<LeaveOutcomeFfi> resumeLeave({
    required CircleManagerFfi circle,
    required List<int> mlsGroupId,
    required bool foreground,
  }) {
    final key = mlsGroupId.join(',');
    final press = _leavePresses[key];
    if (press != null) return press;
    return _leaveCarryOns[key] ??= _driving(() async {
      final outcome = await (await _ensureInitialized()).resumeLeaveDriven(
        circle: circle,
        mlsGroupId: mlsGroupId,
        foreground: foreground,
      );
      return _heard(outcome, outcome.clockRejected);
    }).whenComplete(() {
      _leaveCarryOns.remove(key);
    });
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

/// The driver entries in flight, and one future per read of [quiescent]
/// covering those it saw, until another entry joins.
class _DriveRegistry {
  final Set<Future<void>> _running = {};
  Future<void>? _seen;

  /// The drives in flight at the read, as one future: the same one until
  /// another drive joins.
  Future<void>? get quiescent {
    if (_running.isEmpty) return null;
    return _seen ??= Future.wait(_running.toList());
  }

  /// Runs [drive] registered, rethrowing what it throws. The bookkeeping
  /// stays in the `finally`: a drive that threw and never left the registry
  /// would hold every teardown that reads it forever.
  Future<T> run<T>(Future<T> Function() drive) async {
    final ended = Completer<void>();
    _running.add(ended.future);
    _seen = null;
    try {
      return await drive();
    } finally {
      // Left before it completes, so whatever runs on the completion reads
      // the registry without it.
      _running.remove(ended.future);
      ended.complete();
    }
  }
}
