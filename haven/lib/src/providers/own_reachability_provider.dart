/// Whether others can invite this account right now: its current
/// `KeyPackage` and both relay lists, where an inviter looks for them.
///
/// A fold over the typed outcomes the publisher (`keyPackagePublisherProvider`)
/// and the maintenance scheduler already produce — nothing here contacts a
/// relay. Identity-scoped: a logout drops it, and every writer is fenced by
/// its own lifecycle (the publisher's `ref.onDispose`, the scheduler's
/// generation), so a tick of a logged-out identity never writes here.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:haven/src/providers/key_package_provider.dart';
import 'package:haven/src/services/relay_service.dart';

/// What the readiness row and onboarding show.
enum OwnReachability {
  /// No verdict yet, or a Retry is running.
  checking,

  /// An own relay serves this device's current `KeyPackage`, and both relay
  /// lists are confirmed on an own relay.
  ready,

  /// Nothing was reached, so nothing is proven either way. Never an alarm: an
  /// offline phone is not an uninvitable account.
  cantCheck,

  /// Proven: a relay was reached and what an inviter needs is not served —
  /// no relay accepted the publish, the package is gone, or the only package
  /// out there is one this device cannot open (an adopted slot).
  notReady,

  /// A category has no relay to publish to.
  noRelaysConfigured,

  /// Nothing is published until the storage-reset notice is answered, so a
  /// Retry would do nothing.
  awaitingReset,
}

/// The latest outcome of each component, and what they add up to.
@immutable
class OwnReachabilityState {
  /// Creates a readiness state.
  const OwnReachabilityState({
    this.status = OwnReachability.checking,
    this.keyPackage,
    this.relayLists,
  });

  /// What the outcomes add up to (see [reachabilityOf]); `ready` holds until
  /// an outcome proves otherwise.
  final OwnReachability status;

  /// The latest `KeyPackage` tick, if one has reported.
  final KeyPackageMaintenanceOutcome? keyPackage;

  /// The latest relay-list tick (kind 10002 and kind 10050), if one has
  /// reported.
  final RelayListMaintenanceResult? relayLists;
}

/// What [keyPackage] and [relayLists] prove about inviting this account.
///
/// The states that wait on the user come first: a Retry cannot change them.
@visibleForTesting
OwnReachability reachabilityOf(
  KeyPackageMaintenanceOutcome? keyPackage,
  RelayListMaintenanceResult? relayLists,
) {
  if (keyPackage == null || relayLists == null) return OwnReachability.checking;
  final lists = [relayLists.keyPackage, relayLists.inbox];
  if (_failedWith(
        keyPackage,
        KeyPackageFailureKind.awaitingResetAcknowledgement,
      ) ||
      lists.any(
        (c) =>
            c.action == RelayListMaintenanceAction.awaitingResetAcknowledgement,
      )) {
    return OwnReachability.awaitingReset;
  }
  if (_failedWith(keyPackage, KeyPackageFailureKind.noRelaysConfigured) ||
      lists.any(
        (c) => c.action == RelayListMaintenanceAction.nothingConfigured,
      )) {
    return OwnReachability.noRelaysConfigured;
  }
  final packageServed =
      keyPackage is! KeyPackageMaintenanceFailed && keyPackage.publishedCurrent;
  // A suppressed list is the stored setting's choice, not a failure to wait on.
  if (packageServed &&
      lists.every(
        (c) =>
            c.ownConfirmed || c.action == RelayListMaintenanceAction.suppressed,
      )) {
    return OwnReachability.ready;
  }
  return _packageProvenMissing(keyPackage) || lists.any(_listProvenMissing)
      ? OwnReachability.notReady
      : OwnReachability.cantCheck;
}

bool _failedWith(KeyPackageMaintenanceOutcome o, KeyPackageFailureKind kind) =>
    o is KeyPackageMaintenanceFailed && o.kind == kind;

bool _packageProvenMissing(KeyPackageMaintenanceOutcome o) => switch (o) {
  // A healthy tick is a relay that answered; not current there means the
  // package it serves is one this device cannot open.
  KeyPackageMaintenanceHealthy() ||
  KeyPackageMaintenancePublished() => !o.publishedCurrent,
  KeyPackageMaintenanceFailed(:final kind) => switch (kind) {
    // A publish goes only to relays that answered the probe.
    KeyPackageFailureKind.publishNotAcked ||
    KeyPackageFailureKind.initKeyPurgedUnreplaced => true,
    KeyPackageFailureKind.noRelayResponded ||
    KeyPackageFailureKind.tickErrored ||
    KeyPackageFailureKind.identityUnavailable ||
    KeyPackageFailureKind.noRelaysConfigured ||
    KeyPackageFailureKind.awaitingResetAcknowledgement => false,
  },
};

/// A relay answered — so this phone is online — and no own relay serves a
/// current list.
bool _listProvenMissing(RelayListCategoryResult c) => switch (c.action) {
  RelayListMaintenanceAction.alreadyCurrent ||
  RelayListMaintenanceAction.republished ||
  RelayListMaintenanceAction.unacknowledged =>
    c.respondersProbed > 0 && !c.ownConfirmed,
  RelayListMaintenanceAction.suppressed ||
  RelayListMaintenanceAction.awaitingResetAcknowledgement ||
  RelayListMaintenanceAction.nothingConfigured ||
  RelayListMaintenanceAction.failed => false,
};

/// Holds the latest outcome of each component and derives [OwnReachability].
class OwnReachabilityNotifier extends Notifier<OwnReachabilityState> {
  /// Bumped by every [republish] and every [build]: a republish that ends
  /// after a newer one began, or after a logout, leaves the state alone.
  int _republishes = 0;
  bool _retrying = false;

  @override
  OwnReachabilityState build() {
    _republishes++;
    _retrying = false;
    return const OwnReachabilityState();
  }

  /// Records a `KeyPackage` tick's outcome.
  void recordKeyPackage(KeyPackageMaintenanceOutcome outcome) =>
      _settle(keyPackage: outcome, relayLists: state.relayLists);

  /// Records a relay-list tick's outcome.
  void recordRelayLists(RelayListMaintenanceResult result) =>
      _settle(keyPackage: state.keyPackage, relayLists: result);

  /// Runs the publisher again (relay lists, then the `KeyPackage`) and
  /// completes when it has reported; [OwnReachability.checking] meanwhile.
  /// Never throws.
  Future<void> republish() async {
    final republish = ++_republishes;
    _retrying = true;
    _settle(keyPackage: state.keyPackage, relayLists: state.relayLists);
    try {
      // One fresh run. (`invalidate` + `read` from a Ref mounts an unbuilt
      // provider and then rebuilds it: two publishes.)
      final run = ref.refresh(keyPackagePublisherProvider.future);
      await run;
    } on Object catch (e) {
      debugPrint('[Reachability] republish failed: ${e.runtimeType}');
    } finally {
      if (republish == _republishes) {
        _retrying = false;
        _settle(keyPackage: state.keyPackage, relayLists: state.relayLists);
      }
    }
  }

  void _settle({
    required KeyPackageMaintenanceOutcome? keyPackage,
    required RelayListMaintenanceResult? relayLists,
  }) {
    var status = _retrying
        ? OwnReachability.checking
        : reachabilityOf(keyPackage, relayLists);
    // An offline tick proves nothing, so it does not take back a ready.
    if (state.status == OwnReachability.ready &&
        status == OwnReachability.cantCheck) {
      status = OwnReachability.ready;
    }
    state = OwnReachabilityState(
      status: status,
      keyPackage: keyPackage,
      relayLists: relayLists,
    );
  }
}

/// This identity's readiness to be invited.
final ownReachabilityProvider =
    NotifierProvider<OwnReachabilityNotifier, OwnReachabilityState>(
      OwnReachabilityNotifier.new,
    );
