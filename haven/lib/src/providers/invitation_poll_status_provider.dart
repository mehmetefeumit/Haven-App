/// Status of an inbox refresh, shown by the Invitations page.
///
/// Drives the app-bar refresh ring (one segment per inbox relay) and the
/// notice above the list: whether a tap actually read the user's inbox
/// relays, and whether anything new arrived.
///
/// Unlike [invitationPollerProvider] (one merged fetch with no per-relay
/// attribution, used for silent background polling), this notifier fans a
/// fetch out to each inbox relay independently so the counts are exact. Only
/// a relay that served the read in full ([InboxRead.served], an `EOSE`) is
/// counted as read: one that refused it, did not finish, or could not be
/// reached is not, whatever it handed back.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:haven/src/models/relay_ring_slot.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/invitation_provider.dart';
import 'package:haven/src/providers/relay_preferences_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/fresh_secret.dart';
import 'package:haven/src/services/relay_service.dart';

/// Lifecycle phase of an inbox refresh.
enum InvitationPollPhase {
  /// No refresh has run yet; the ring shows its idle icon.
  idle,

  /// A refresh is in flight (reading inbox relays).
  checking,

  /// Every relay has settled, however it answered.
  settled,
}

/// The settled outcome of an inbox refresh.
///
/// Exactly one applies once [InvitationPollPhase.settled] is reached, in the
/// order [InvitationPollStatusNotifier.categorizeOutcome] checks them: what
/// the user can fix comes first, and "up to date" only when every relay
/// served the read in full and nothing failed.
enum InvitationPollOutcome {
  /// No inbox relays are configured.
  noInbox,

  /// At least one relay refused the read: an invitation held only there is
  /// never read.
  refused,

  /// At least one invitation opened but could not be saved on this device.
  notSaved,

  /// No relay could be reached.
  offline,

  /// Some relay was not read in full (not finished, or not reached).
  incomplete,

  /// Every relay served the read and at least one new invitation arrived.
  newInvites,

  /// Every relay served the read; nothing new, nothing failed.
  upToDate,
}

/// Immutable snapshot of an inbox refresh.
@immutable
class InvitationPollStatus {
  /// Creates an [InvitationPollStatus].
  const InvitationPollStatus({
    required this.phase,
    this.total = 0,
    this.served = 0,
    this.refused = 0,
    this.unreached = 0,
    this.notSaved = 0,
    this.newCount = 0,
    this.slots = const [],
    this.outcome,
  });

  /// The lifecycle phase.
  final InvitationPollPhase phase;

  /// Per-relay ring segments for the app-bar `RefreshRingButton`.
  ///
  /// Empty while idle. During [InvitationPollPhase.checking] each element
  /// corresponds, by index, to one inbox relay (in the order read from
  /// [inboxRelaysProvider]) and transitions
  /// [RelayRingSlotState.checking] → [RelayRingSlotState.ok] (served in
  /// full) / [RelayRingSlotState.error] (anything else) as that relay
  /// resolves. Relay URLs are never stored here (two-plane privacy).
  final List<RelayRingSlotState> slots;

  /// Number of inbox relays asked this refresh.
  final int total;

  /// Relays that served the read in full.
  final int served;

  /// Relays that refused the read.
  final int refused;

  /// Relays that could not be reached.
  final int unreached;

  /// Invitations that opened but could not be saved on this device.
  final int notSaved;

  /// Number of genuinely new invitations processed this refresh.
  final int newCount;

  /// The settled outcome; non-null only when [phase] is
  /// [InvitationPollPhase.settled].
  final InvitationPollOutcome? outcome;

  /// The idle status.
  static const idle = InvitationPollStatus(phase: InvitationPollPhase.idle);
}

/// Provider for the Invitations refresh status.
final invitationPollStatusProvider =
    NotifierProvider<InvitationPollStatusNotifier, InvitationPollStatus>(
      InvitationPollStatusNotifier.new,
    );

/// Notifier that reads inbox relays per-relay and reports an accurate tally.
class InvitationPollStatusNotifier extends Notifier<InvitationPollStatus> {
  /// Incremented on every [refresh]; an in-flight refresh discards its final
  /// state write if a newer refresh has superseded it. This keeps rapid
  /// refresh taps and page navigation from racing on [state].
  int _generation = 0;

  @override
  InvitationPollStatus build() => InvitationPollStatus.idle;

  /// Maps the raw tally to a single settled [InvitationPollOutcome].
  ///
  /// Pure and total so the accuracy-critical categorisation can be tested
  /// directly. [upToDate](InvitationPollOutcome.upToDate) only when every
  /// relay served the read, nothing failed to save and nothing is new.
  static InvitationPollOutcome categorizeOutcome({
    required int total,
    required int served,
    required int refused,
    required int unreached,
    required int notSaved,
    required int newCount,
  }) {
    if (total == 0) return InvitationPollOutcome.noInbox;
    if (refused > 0) return InvitationPollOutcome.refused;
    if (notSaved > 0) return InvitationPollOutcome.notSaved;
    if (unreached == total) return InvitationPollOutcome.offline;
    if (served < total) return InvitationPollOutcome.incomplete;
    if (newCount > 0) return InvitationPollOutcome.newInvites;
    return InvitationPollOutcome.upToDate;
  }

  /// Reads the user's inbox relays and updates [state] with the result.
  ///
  /// Sets [InvitationPollPhase.checking] while in flight, then
  /// [InvitationPollPhase.settled] with exact per-verdict counts and the
  /// number of new invitations discovered. Never throws.
  Future<void> refresh() async {
    final myGeneration = ++_generation;

    final identity = await ref.read(identityProvider.future);
    if (myGeneration != _generation) return;
    if (identity == null) {
      // No identity yet — nothing to read; leave the status as-is.
      return;
    }

    // Two-plane model: read ONLY the user's own inbox relays. Never fall back
    // to public/discovery relays for the count display — that would broadcast
    // the user's pubkey to the discovery plane. In practice the inbox list
    // self-heals to the user's own default inbox relays, so `noInbox` is a
    // defensive state; the invariant that matters is that an empty list must
    // NOT trigger a read of public defaults.
    final relays = await ref.read(inboxRelaysProvider.future);
    if (myGeneration != _generation) return;

    if (relays.isEmpty) {
      state = const InvitationPollStatus(
        phase: InvitationPollPhase.settled,
        outcome: InvitationPollOutcome.noInbox,
      );
      return;
    }

    // All slots start "checking" (amber) the moment the user taps, so the ring
    // fills in from one coherent state rather than popping in mid-progress.
    final slots = List<RelayRingSlotState>.filled(
      relays.length,
      RelayRingSlotState.checking,
    );
    state = InvitationPollStatus(
      phase: InvitationPollPhase.checking,
      total: relays.length,
      slots: List<RelayRingSlotState>.unmodifiable(slots),
    );

    final relayService = ref.read(relayServiceProvider);
    final circleService = ref.read(circleServiceProvider);
    final identityNotifier = ref.read(identityNotifierProvider.notifier);

    void writeChecking() {
      state = InvitationPollStatus(
        phase: InvitationPollPhase.checking,
        total: relays.length,
        slots: List<RelayRingSlotState>.unmodifiable(slots),
      );
    }

    // Per-relay fan-out: each inbox relay is queried independently so its ring
    // segment flips to ok/error the instant it resolves. Dart is
    // single-threaded, so the index-based mutation of `slots`/`reads` inside
    // these closures is race-free (one microtask runs at a time).
    final since = ref.read(invitationClockProvider)().subtract(
      inboxGiftWrapLookback,
    );
    final reads = List<InboxRead>.filled(relays.length, InboxRead.unreached);
    // Every wrap that arrived, whatever its relay's verdict: each passed
    // Haven's id-and-signature check, and a refused or unfinished read can
    // still carry the invitation the user is waiting for.
    final fetched = <RelayGiftWrapFetch>[];

    await Future.wait(
      List<Future<void>>.generate(relays.length, (i) async {
        try {
          final outcomes = await relayService.fetchGiftWrapsPerRelay(
            relays: [relays[i]],
            since: since,
          );
          // Guard before every state write: a superseded refresh must not
          // touch state.
          if (myGeneration != _generation) return;
          // A single-URL query returns exactly one outcome by contract; a
          // stub/mock that violates it reads as unreached.
          final fetch = outcomes.isEmpty ? null : outcomes.first;
          if (fetch != null) {
            fetched.add(fetch);
            reads[i] = fetch.read;
          }
          slots[i] = reads[i] == InboxRead.served
              ? RelayRingSlotState.ok
              : RelayRingSlotState.error;
          writeChecking();
        } on Object catch (e) {
          if (myGeneration != _generation) return;
          slots[i] = RelayRingSlotState.error;
          writeChecking();
          debugPrint(
            '[InvitationPollStatus] relay[$i] failed: ${e.runtimeType}',
          );
        }
      }),
    );

    // Guard before the secret fetch: a superseded refresh must never read
    // secret bytes for a stale generation (Rule #9).
    if (myGeneration != _generation) return;

    // Union events across every relay and de-duplicate by event id: the same
    // gift wrap commonly arrives on multiple inbox relays, and processing one
    // twice concurrently could race the Rust dedup table.
    // `processGiftWrappedInvitation` returns null for an already-processed
    // wrap and for one that is no invitation this device can open (anyone who
    // knows the npub can send one, so it never raises a notice); only a wrap
    // that opened and could not be saved is counted as a failure.
    var newCount = 0;
    var notSaved = 0;
    final seen = <String>{};
    final uniqueEvents = <String>[];
    for (final fetch in fetched) {
      for (final eventJson in fetch.events) {
        if (seen.add(_dedupKey(eventJson))) uniqueEvents.add(eventJson);
      }
    }

    if (uniqueEvents.isNotEmpty) {
      // Fetch secret bytes once for the batch and only when there is work,
      // minimising secret exposure. Dart has no zeroize, so take ownership of
      // the fetched buffer — copying it would leave a second live secret no
      // `fillRange` can reach — and scrub it in `finally` (Rule #9).
      final secretBytes = takeSecretOwnership(
        await identityNotifier.getSecretBytes(),
      );
      try {
        final results = await Future.wait(
          uniqueEvents.map((eventJson) async {
            try {
              final invitation = await circleService
                  .processGiftWrappedInvitation(
                    identitySecretBytes: secretBytes,
                    giftWrapEventJson: eventJson,
                  );
              return invitation == null ? _Intake.skipped : _Intake.added;
            } on InvitationNotSavedException {
              return _Intake.notSaved;
            } on Object catch (e) {
              debugPrint(
                '[InvitationPollStatus] skipped gift-wrap: ${e.runtimeType}',
              );
              return _Intake.skipped;
            }
          }),
        );
        newCount = results.where((r) => r == _Intake.added).length;
        notSaved = results.where((r) => r == _Intake.notSaved).length;
      } finally {
        secretBytes.fillRange(0, secretBytes.length, 0);
      }
    }

    // Drop our result if a newer refresh superseded us — including the
    // downstream invalidations, so a stale refresh can't reload the list
    // mid-flight of a newer one.
    if (myGeneration != _generation) return;

    if (newCount > 0) {
      ref
        ..invalidate(pendingInvitationsProvider)
        ..invalidate(circlesProvider);
    }

    int count(InboxRead read) => reads.where((r) => r == read).length;
    final served = count(InboxRead.served);
    final refused = count(InboxRead.refused);
    final unreached = count(InboxRead.unreached);
    state = InvitationPollStatus(
      phase: InvitationPollPhase.settled,
      total: relays.length,
      served: served,
      refused: refused,
      unreached: unreached,
      notSaved: notSaved,
      newCount: newCount,
      slots: List<RelayRingSlotState>.unmodifiable(slots),
      outcome: categorizeOutcome(
        total: relays.length,
        served: served,
        refused: refused,
        unreached: unreached,
        notSaved: notSaved,
        newCount: newCount,
      ),
    );
  }

  /// Returns a stable de-duplication key for a gift-wrap event JSON.
  ///
  /// Prefers the event `id`; falls back to the raw JSON if it can't be parsed.
  String _dedupKey(String eventJson) {
    try {
      final decoded = jsonDecode(eventJson);
      if (decoded is Map<String, dynamic> && decoded['id'] is String) {
        return decoded['id'] as String;
      }
    } on Object {
      // Malformed or unexpectedly-shaped JSON — fall back to the raw string
      // so a single odd event can never abort the whole batch.
    }
    return eventJson;
  }
}

/// What processing one gift wrap came to.
enum _Intake { added, skipped, notSaved }
