/// Relay status provider for the relay settings check.
///
/// Per relay of the user's own inbox and `KeyPackage` lists, and per lookup
/// relay, what it serves of the kinds expected there — kind 30443 on an own
/// `KeyPackage` relay, kind 10002 there and on a lookup relay, kind 10050 on
/// an own inbox relay and on a lookup relay — judged as maintenance judges
/// them (`RelayService.checkOwnReachability`).
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/constants/relays.dart';
import 'package:haven/src/models/relay_ring_slot.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/own_reachability_provider.dart';
import 'package:haven/src/providers/relay_preferences_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/rust/api.dart'
    show OwnEventPresenceFfi, OwnRelayPresenceFfi;

/// What one relay serves of one expected kind.
enum KindPresence {
  /// Not checked yet.
  notChecked,

  /// The check is running.
  checking,

  /// It serves what maintenance would leave in place.
  current,

  /// It serves an older event of this account that maintenance would
  /// replace — for a `KeyPackage`, one this device cannot open.
  outdated,

  /// It answered in full and holds nothing of this account's.
  missing,

  /// It could not be reached, or did not finish its answer.
  noAnswer,
}

/// One relay's row: which lists it is on and, per expected kind, what it
/// serves. A `null` kind is not expected on this relay and is never asked.
@immutable
class RelayPresence {
  /// Creates a [RelayPresence].
  const RelayPresence({
    required this.relayUrl,
    required this.own,
    required this.lookup,
    this.keyPackage,
    this.relayList,
    this.inboxRelayList,
  });

  /// The configured or lookup entry, verbatim.
  final String relayUrl;

  /// On the user's own inbox or `KeyPackage` list.
  final bool own;

  /// A lookup (discovery) relay.
  final bool lookup;

  /// Kind 30443, if expected here.
  final KindPresence? keyPackage;

  /// Kind 10002, if expected here.
  final KindPresence? relayList;

  /// Kind 10050, if expected here.
  final KindPresence? inboxRelayList;

  /// Every expected kind's presence.
  List<KindPresence> get expected => [?keyPackage, ?relayList, ?inboxRelayList];

  /// This row with every expected kind set to [presence].
  RelayPresence withEvery(KindPresence presence) => RelayPresence(
    relayUrl: relayUrl,
    own: own,
    lookup: lookup,
    keyPackage: keyPackage == null ? null : presence,
    relayList: relayList == null ? null : presence,
    inboxRelayList: inboxRelayList == null ? null : presence,
  );
}

/// The one summary of a set of kinds, shared by the app-bar ring and each
/// row's dot: `ok` only when every kind is current.
RelayRingSlotState summarizePresence(Iterable<KindPresence> kinds) {
  if (kinds.isEmpty) return RelayRingSlotState.pending;
  if (kinds.any((k) => k == KindPresence.checking)) {
    return RelayRingSlotState.checking;
  }
  if (kinds.every((k) => k == KindPresence.current)) {
    return RelayRingSlotState.ok;
  }
  if (kinds.any(
    (k) =>
        k == KindPresence.outdated ||
        k == KindPresence.missing ||
        k == KindPresence.noAnswer,
  )) {
    return RelayRingSlotState.error;
  }
  return RelayRingSlotState.pending;
}

/// What a Republish achieved, for its fixed SnackBar copy.
enum RepublishOutcome {
  /// Every own relay answered serving every expected kind, and no lookup
  /// relay that answered misses one or serves an old one.
  allCurrent,

  /// An own relay did not answer, or a relay that answered still misses an
  /// expected kind or serves an old one.
  incomplete,

  /// The relay lists and KeyPackage are held until the storage-reset notice
  /// is answered.
  heldForReset,
}

/// Overall relay status state.
@immutable
class RelayStatusState {
  /// Creates a [RelayStatusState].
  const RelayStatusState({
    required this.relays,
    this.isRefreshing = false,
    this.isRepublishing = false,
    this.lastChecked,
  });

  /// One row per relay: the inbox list, then the `KeyPackage` list, then
  /// the lookup relays.
  final List<RelayPresence> relays;

  /// Whether a check is running.
  final bool isRefreshing;

  /// Whether a Republish is running.
  final bool isRepublishing;

  /// When the last check completed.
  final DateTime? lastChecked;

  /// Creates a copy with the given fields replaced.
  RelayStatusState copyWith({
    List<RelayPresence>? relays,
    bool? isRefreshing,
    bool? isRepublishing,
    DateTime? lastChecked,
  }) {
    return RelayStatusState(
      relays: relays ?? this.relays,
      isRefreshing: isRefreshing ?? this.isRefreshing,
      isRepublishing: isRepublishing ?? this.isRepublishing,
      lastChecked: lastChecked ?? this.lastChecked,
    );
  }

  /// One ring slot per relay, from [summarizePresence] over its expected
  /// kinds — the same summary each row's dot shows.
  List<RelayRingSlotState> get ringSlots =>
      relays.map((r) => summarizePresence(r.expected)).toList(growable: false);

  /// Whether a relay that answered misses an expected kind or serves an old
  /// one: what a Republish can fix.
  bool get needsRepublish => relays.any(
    (r) => r.expected.any(
      (k) => k == KindPresence.missing || k == KindPresence.outdated,
    ),
  );
}

/// Provider for relay event publication status.
final relayStatusProvider =
    AsyncNotifierProvider<RelayStatusNotifier, RelayStatusState>(
      RelayStatusNotifier.new,
    );

KindPresence? _presenceOf(OwnEventPresenceFfi p) => switch (p) {
  OwnEventPresenceFfi.notExpected => null,
  OwnEventPresenceFfi.current => KindPresence.current,
  OwnEventPresenceFfi.outdated => KindPresence.outdated,
  OwnEventPresenceFfi.missing => KindPresence.missing,
  OwnEventPresenceFfi.noAnswer => KindPresence.noAnswer,
};

RelayPresence _rowOf(OwnRelayPresenceFfi r) => RelayPresence(
  relayUrl: r.relayUrl,
  own: r.own,
  lookup: r.lookup,
  keyPackage: _presenceOf(r.keyPackage),
  relayList: _presenceOf(r.relayList),
  inboxRelayList: _presenceOf(r.inboxRelayList),
);

/// Notifier for relay event publication status.
class RelayStatusNotifier extends AsyncNotifier<RelayStatusState> {
  /// Incremented on every [checkAllRelays]: a check superseded by a newer one
  /// writes nothing.
  int _checkGeneration = 0;

  @override
  Future<RelayStatusState> build() async {
    // Coupling to the relay-preferences invalidator: when the user changes
    // their relay lists, the status page rebuilds.
    ref.watch(relayStatusInvalidatorProvider);
    final inbox = await ref.read(inboxRelaysProvider.future);
    final keyPackage = await ref.read(keyPackageRelaysProvider.future);
    // The rows the check will answer for, in its order and by its rules, so
    // each shows the kinds it expects before the first answer. The check's
    // own rows replace these.
    Set<String> keys(List<String> urls) => {
      for (final url in urls) normalizeRelayUrlForComparison(url),
    };
    final inboxKeys = keys(inbox);
    final kpKeys = keys(keyPackage);
    final lookupKeys = keys(discoveryRelays);
    final rows = <String, RelayPresence>{};
    for (final url in [...inbox, ...keyPackage, ...discoveryRelays]) {
      final key = normalizeRelayUrlForComparison(url);
      if (rows.containsKey(key)) continue;
      final inInbox = inboxKeys.contains(key);
      final inKp = kpKeys.contains(key);
      final lookup = lookupKeys.contains(key);
      rows[key] = RelayPresence(
        relayUrl: url,
        own: inInbox || inKp,
        lookup: lookup,
        keyPackage: inKp ? KindPresence.notChecked : null,
        relayList: inKp || lookup ? KindPresence.notChecked : null,
        inboxRelayList: inInbox || lookup ? KindPresence.notChecked : null,
      );
    }
    return RelayStatusState(relays: rows.values.toList());
  }

  /// Checks every row. Each expected kind reads checking until the one
  /// answer arrives; a check superseded meanwhile writes nothing.
  Future<void> checkAllRelays() async {
    final identity = await ref.read(identityProvider.future);
    if (identity == null) return;
    // The page asks on open, often before the rows have loaded.
    final RelayStatusState current;
    try {
      current = state.valueOrNull ?? await future;
    } on Object catch (e) {
      debugPrint('[RelayStatus] no rows to check: ${e.runtimeType}');
      return;
    }

    final generation = ++_checkGeneration;
    state = AsyncData(
      current.copyWith(
        relays: [
          for (final r in current.relays) r.withEvery(KindPresence.checking),
        ],
        isRefreshing: true,
      ),
    );

    List<RelayPresence> checked;
    try {
      final rows = await ref
          .read(relayServiceProvider)
          .checkOwnReachability(ownPubkey: identity.pubkeyHex);
      checked = rows.map(_rowOf).toList();
    } on Object catch (e) {
      debugPrint('[RelayStatus] check failed: ${e.runtimeType}');
      checked = [
        for (final r in current.relays) r.withEvery(KindPresence.noAnswer),
      ];
    }
    if (generation != _checkGeneration) return;
    final latest = state.valueOrNull ?? current;
    state = AsyncData(
      latest.copyWith(
        relays: checked,
        isRefreshing: false,
        lastChecked: DateTime.now(),
      ),
    );
  }

  /// Publishes the relay lists and the `KeyPackage` again, in maintenance's
  /// order, then checks every relay again. Never throws.
  Future<RepublishOutcome> republish() async {
    final current = state.valueOrNull;
    if (current != null) {
      state = AsyncData(current.copyWith(isRepublishing: true));
    }
    try {
      final reachability = ref.read(ownReachabilityProvider.notifier);
      await reachability.republish();
      if (ref.read(ownReachabilityProvider).status ==
          OwnReachability.awaitingReset) {
        return RepublishOutcome.heldForReset;
      }
      await checkAllRelays();
      final relays = state.valueOrNull?.relays ?? const <RelayPresence>[];
      final own = relays.where((r) => r.own);
      // An inviter finds the KeyPackage only on an own relay, so an own relay
      // that did not answer proves nothing; a lookup relay is a fallback that
      // may be down, but one that answered and lacks a list is not "done".
      final ownCurrent =
          own.isNotEmpty &&
          own.expand((r) => r.expected).every((k) => k == KindPresence.current);
      final lookupCurrent = relays
          .where((r) => !r.own)
          .expand((r) => r.expected)
          .every(
            (k) => k == KindPresence.current || k == KindPresence.noAnswer,
          );
      return ownCurrent && lookupCurrent
          ? RepublishOutcome.allCurrent
          : RepublishOutcome.incomplete;
    } finally {
      final latest = state.valueOrNull;
      if (latest != null) {
        state = AsyncData(latest.copyWith(isRepublishing: false));
      }
    }
  }
}
