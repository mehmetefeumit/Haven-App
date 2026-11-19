/// What the own-relay maintenance passes found and did, per relay and kind,
/// and how each own inbox relay answered their read of this account's gift
/// wraps: the Dart side of the Rust-owned board
/// (`CircleManagerFfi.ownRelayBoard`), read as a network-free snapshot.
library;

import 'package:flutter/foundation.dart';
import 'package:haven/src/services/relay_service.dart' show InboxRead;

/// One relay's state for one kind, as the last or running pass left it.
enum OwnRelayStatus {
  /// In the running pass's probe set, its answer not judged yet.
  checking,

  /// Its answer was judged current, or it accepted what this pass sent.
  current,

  /// Sent to it; its `OK` not received yet.
  publishing,

  /// Answered in full and holds nothing of this account's for the kind.
  missing,

  /// Answered with an event maintenance replaces.
  outdated,

  /// Answered `OK false`.
  refused,

  /// Proven missing or old, then sent, and no `OK` came.
  unconfirmed,

  /// Did not answer, or did not finish answering.
  noAnswer,
}

/// Why Haven publishes nothing of a kind now.
enum OwnPublishHold {
  /// The storage-reset notice is not answered yet.
  awaitingResetAcknowledgement,

  /// The list this kind is published to has no relays.
  noRelaysConfigured,

  /// The list's stored publish setting is off: one stored before publishing
  /// became unconditional, until opening the relay settings turns it on.
  publishingSuppressed,
}

/// One relay's cell for one kind.
@immutable
class OwnRelayCell {
  /// Creates a cell.
  const OwnRelayCell({required this.relayUrl, required this.status});

  /// The relay, as the pass's target list spells it.
  final String relayUrl;

  /// What the pass found or did there.
  final OwnRelayStatus status;
}

/// How one own inbox relay answered the last read of this account's gift
/// wraps.
@immutable
class OwnInboxRead {
  /// Creates an answer.
  const OwnInboxRead({required this.relayUrl, required this.read});

  /// The relay, as the inbox list spells it.
  final String relayUrl;

  /// How it answered.
  final InboxRead read;
}

/// One kind's half of the board.
@immutable
class OwnKindBoard {
  /// Creates a kind's board.
  const OwnKindBoard({this.hold, this.checkedSecsAgo, this.cells = const []});

  /// Set while Haven publishes nothing of this kind; its cells are empty.
  final OwnPublishHold? hold;

  /// Seconds since this kind's last finished pass, or `null` when none has
  /// finished in this session.
  final int? checkedSecsAgo;

  /// One cell per relay the pass reached.
  final List<OwnRelayCell> cells;
}

/// The whole board.
@immutable
class OwnRelayBoard {
  /// Creates a board.
  const OwnRelayBoard({
    this.running = false,
    this.lookupRelays = const [],
    this.keyPackage = const OwnKindBoard(),
    this.relayList = const OwnKindBoard(),
    this.inboxRelayList = const OwnKindBoard(),
    this.inboxReads = const [],
  });

  /// Whether a pass is running or waiting for the one that is.
  final bool running;

  /// The lookup relays the passes copy the relay lists to.
  final List<String> lookupRelays;

  /// Kind 30443.
  final OwnKindBoard keyPackage;

  /// Kind 10002.
  final OwnKindBoard relayList;

  /// Kind 10050.
  final OwnKindBoard inboxRelayList;

  /// Each own inbox relay's answer to the last gift-wrap read; empty before
  /// one in this session, and after an edit of the inbox list.
  final List<OwnInboxRead> inboxReads;
}
