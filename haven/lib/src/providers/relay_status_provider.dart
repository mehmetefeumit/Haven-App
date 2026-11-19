/// What the own-relay maintenance passes found, per relay of the user's own
/// inbox and `KeyPackage` lists and per lookup relay, for each kind expected
/// there: kind 30443 on an own `KeyPackage` relay, kind 10002 there and on a
/// lookup relay, kind 10050 on an own inbox relay and on a lookup relay — and,
/// per own inbox relay, whether it lets Haven read this account's gift wraps.
///
/// The passes write a Rust-owned board; this reads it — a network-free
/// snapshot — at once and then every [relayBoardPollIntervalProvider], only
/// while the app is in front and something watches. It never runs a pass and
/// never opens a session.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/constants/relays.dart';
import 'package:haven/src/models/own_relay_board.dart';
import 'package:haven/src/providers/location_provider.dart';
import 'package:haven/src/providers/relay_preferences_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/relay_service.dart' show InboxRead;

/// A kind a relay row reports on.
enum RelayKind {
  /// Kind 30443.
  keyPackage,

  /// Kind 10002.
  relayList,

  /// Kind 10050.
  inboxRelayList,
}

/// What one relay holds of one expected kind, or what Haven is doing there.
enum KindPresence {
  /// No pass has reached this relay for this kind in this session.
  notChecked,

  /// The running pass is asking it.
  checking,

  /// Sent to it, waiting for its `OK`.
  publishing,

  /// It has the current version.
  current,

  /// It holds nothing of this account's for the kind.
  missing,

  /// It holds a version maintenance replaces.
  outdated,

  /// It refused what Haven sent.
  refused,

  /// It was missing it or held an old one, and did not confirm what Haven
  /// sent.
  unconfirmed,

  /// It did not answer.
  noAnswer,

  /// Haven publishes nothing of this kind now (see [RelayStatusState.holds]).
  held,
}

/// One relay's row: which lists it is on and, per expected kind, what it
/// holds. A `null` kind is not expected on this relay.
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
    this.inboxRead,
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

  /// How it answered the last read of this account's gift wraps; `null` for
  /// a relay off the inbox list, and while not yet asked.
  ///
  /// Never one of [expected]: no republish changes whether a relay lets Haven
  /// read the inbox, so it is shown as a warning of its own.
  final InboxRead? inboxRead;

  /// This row's [kind], if expected here.
  KindPresence? of(RelayKind kind) => switch (kind) {
    RelayKind.keyPackage => keyPackage,
    RelayKind.relayList => relayList,
    RelayKind.inboxRelayList => inboxRelayList,
  };

  /// Every expected kind's presence.
  List<KindPresence> get expected => [?keyPackage, ?relayList, ?inboxRelayList];

  @override
  bool operator ==(Object other) =>
      other is RelayPresence &&
      other.relayUrl == relayUrl &&
      other.own == own &&
      other.lookup == lookup &&
      other.keyPackage == keyPackage &&
      other.relayList == relayList &&
      other.inboxRelayList == inboxRelayList &&
      other.inboxRead == inboxRead;

  @override
  int get hashCode => Object.hash(
    relayUrl,
    own,
    lookup,
    keyPackage,
    relayList,
    inboxRelayList,
    inboxRead,
  );
}

/// Every row, the kinds Haven holds back, and whether a pass is running.
@immutable
class RelayStatusState {
  /// Creates a [RelayStatusState].
  const RelayStatusState({
    required this.relays,
    this.holds = const {},
    this.running = false,
  });

  /// One row per relay: the inbox list, then the `KeyPackage` list, then the
  /// lookup relays.
  final List<RelayPresence> relays;

  /// Why each held kind is held.
  final Map<RelayKind, OwnPublishHold> holds;

  /// Whether a pass is running or waiting for the one that is.
  final bool running;

  /// Whether a row is being checked or published to.
  bool get busy => relays.any(
    (r) => r.expected.any(
      (k) => k == KindPresence.checking || k == KindPresence.publishing,
    ),
  );

  @override
  bool operator ==(Object other) =>
      other is RelayStatusState &&
      other.running == running &&
      listEquals(other.relays, relays) &&
      mapEquals(other.holds, holds);

  @override
  int get hashCode => Object.hash(
    running,
    Object.hashAll(relays),
    Object.hashAllUnordered(holds.entries.map((e) => (e.key, e.value))),
  );
}

/// How often a watched, foregrounded [relayStatusProvider] reads the board.
final relayBoardPollIntervalProvider = Provider<Duration>(
  (_) => const Duration(milliseconds: 500),
);

/// Every own and lookup relay's row, kept in step with the board while
/// watched.
final AutoDisposeNotifierProvider<RelayStatusNotifier, RelayStatusState>
relayStatusProvider = NotifierProvider.autoDispose(RelayStatusNotifier.new);

/// Reads the board for [relayStatusProvider].
class RelayStatusNotifier extends AutoDisposeNotifier<RelayStatusState> {
  /// The last board read; kept while the app is in the background, where
  /// nothing is read.
  OwnRelayBoard? _board;

  @override
  RelayStatusState build() {
    final inbox = ref.watch(inboxRelaysProvider).valueOrNull ?? const [];
    final keyPackage =
        ref.watch(keyPackageRelaysProvider).valueOrNull ?? const [];
    if (ref.watch(appForegroundProvider)) {
      _board = _read();
      final timer = Timer.periodic(ref.watch(relayBoardPollIntervalProvider), (
        _,
      ) {
        _board = _read();
        state = relayStatusOf(inbox, keyPackage, _board);
      });
      ref.onDispose(timer.cancel);
    }
    return relayStatusOf(inbox, keyPackage, _board);
  }

  OwnRelayBoard? _read() =>
      ref.read(maintenanceServiceProvider).ownRelayBoard();

  // A fresh board every interval: only a changed one may rebuild the page.
  @override
  bool updateShouldNotify(RelayStatusState previous, RelayStatusState next) =>
      previous != next;
}

/// The rows for [inbox] and [keyPackage] and the lookup relays, each kind
/// joined to its [board] cell by normalized URL, and each inbox row to its
/// relay's gift-wrap read.
///
/// Without a board every expected kind reads not checked: a failed read
/// proves nothing about a relay.
@visibleForTesting
RelayStatusState relayStatusOf(
  List<String> inbox,
  List<String> keyPackage,
  OwnRelayBoard? board,
) {
  final lookups = board?.lookupRelays ?? discoveryRelays;
  Set<String> keys(List<String> urls) => {
    for (final url in urls) normalizeRelayUrlForComparison(url),
  };
  final inboxKeys = keys(inbox);
  final kpKeys = keys(keyPackage);
  final lookupKeys = keys(lookups);

  final holds = <RelayKind, OwnPublishHold>{};
  final cells = <RelayKind, Map<String, OwnRelayStatus>>{};
  for (final kind in RelayKind.values) {
    final kindBoard = switch (kind) {
      RelayKind.keyPackage => board?.keyPackage,
      RelayKind.relayList => board?.relayList,
      RelayKind.inboxRelayList => board?.inboxRelayList,
    };
    if (kindBoard?.hold case final hold?) holds[kind] = hold;
    cells[kind] = {
      for (final cell in kindBoard?.cells ?? const <OwnRelayCell>[])
        normalizeRelayUrlForComparison(cell.relayUrl): cell.status,
    };
  }
  final inboxReads = {
    for (final r in board?.inboxReads ?? const <OwnInboxRead>[])
      normalizeRelayUrlForComparison(r.relayUrl): r.read,
  };
  KindPresence presence(RelayKind kind, String key) {
    if (holds.containsKey(kind)) return KindPresence.held;
    final status = cells[kind]![key];
    return status == null ? KindPresence.notChecked : _presenceOf(status);
  }

  final rows = <String, RelayPresence>{};
  for (final url in [...inbox, ...keyPackage, ...lookups]) {
    final key = normalizeRelayUrlForComparison(url);
    if (rows.containsKey(key)) continue;
    final inInbox = inboxKeys.contains(key);
    final inKp = kpKeys.contains(key);
    final lookup = lookupKeys.contains(key);
    rows[key] = RelayPresence(
      relayUrl: url,
      own: inInbox || inKp,
      lookup: lookup,
      keyPackage: inKp ? presence(RelayKind.keyPackage, key) : null,
      relayList: inKp || lookup ? presence(RelayKind.relayList, key) : null,
      inboxRelayList: inInbox || lookup
          ? presence(RelayKind.inboxRelayList, key)
          : null,
      inboxRead: inInbox ? inboxReads[key] : null,
    );
  }
  return RelayStatusState(
    relays: rows.values.toList(growable: false),
    holds: holds,
    running: board?.running ?? false,
  );
}

KindPresence _presenceOf(OwnRelayStatus status) => switch (status) {
  OwnRelayStatus.checking => KindPresence.checking,
  OwnRelayStatus.current => KindPresence.current,
  OwnRelayStatus.publishing => KindPresence.publishing,
  OwnRelayStatus.missing => KindPresence.missing,
  OwnRelayStatus.outdated => KindPresence.outdated,
  OwnRelayStatus.refused => KindPresence.refused,
  OwnRelayStatus.unconfirmed => KindPresence.unconfirmed,
  OwnRelayStatus.noAnswer => KindPresence.noAnswer,
};

/// Whether opening the Relays page should run a pass: none is running, and a
/// kind has no finished pass in this session, or its last one finished more
/// than [kResumeExtrasMinInterval] ago — the same window a return to the app
/// waits before it runs one. A kind held for the reset notice or an empty
/// list is skipped: a pass would hold it again. One held by a stored publish
/// setting is not, because opening this page turns that setting on. Without
/// a board no session is open: the page opens none, and the open that comes
/// runs its own pass.
bool ownRelayBoardIsStale(OwnRelayBoard? board) {
  if (board == null) return false;
  if (board.running) return false;
  return [board.keyPackage, board.relayList, board.inboxRelayList].any(
    (kind) => switch (kind.hold) {
      OwnPublishHold.awaitingResetAcknowledgement ||
      OwnPublishHold.noRelaysConfigured => false,
      OwnPublishHold.publishingSuppressed => true,
      null =>
        kind.checkedSecsAgo == null ||
            kind.checkedSecsAgo! > kResumeExtrasMinInterval.inSeconds,
    },
  );
}
