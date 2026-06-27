/// Status of an inbox refresh, surfaced by the Invitations "Settle Pill".
///
/// Drives the small pill under the Invitations app bar that tells the user
/// whether tapping refresh actually reached their inbox relays: how many
/// were pinged, how many answered, and whether anything new arrived.
///
/// Unlike [invitationPollerProvider] (one merged fetch with no per-relay
/// attribution, used for silent background polling), this notifier fans a
/// fetch out to each inbox relay independently so the counts shown are exact:
/// a relay that completes the WebSocket handshake is counted as answered
/// (even with zero events), and one that cannot be reached is counted as not
/// answered.
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
import 'package:haven/src/services/relay_service.dart';

/// NIP-59 gift wraps randomize `created_at` up to 2 days in the past, so the
/// fetch must always look back beyond that window (plus a clock-skew buffer).
/// Re-fetching old wraps is harmless — Rust dedups already-processed ones.
const _giftWrapLookback = Duration(days: 2, hours: 1);

/// Lifecycle phase of an inbox refresh.
enum InvitationPollPhase {
  /// No refresh has run yet; the pill is hidden.
  idle,

  /// A refresh is in flight (pinging inbox relays).
  checking,

  /// Every relay has settled (answered or not).
  settled,
}

/// The settled outcome of an inbox refresh, chosen for the pill's copy.
///
/// Exactly one applies once [InvitationPollPhase.settled] is reached. The
/// ordering is deliberate (see
/// [InvitationPollStatusNotifier.categorizeOutcome]): reaching nobody is the
/// headline, then new invitations, then a partial result, then the calm
/// "nothing new" case.
enum InvitationPollOutcome {
  /// Every relay answered and at least one new invitation arrived.
  newInvites,

  /// Every relay answered; nothing new.
  upToDate,

  /// Some relays answered, some did not.
  partial,

  /// No relay answered (offline / all unreachable).
  offline,

  /// No inbox relays are configured.
  noInbox,
}

/// Immutable snapshot of an inbox refresh, shown by the Settle Pill.
@immutable
class InvitationPollStatus {
  /// Creates an [InvitationPollStatus].
  const InvitationPollStatus({
    required this.phase,
    this.total = 0,
    this.responded = 0,
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
  /// [RelayRingSlotState.checking] → [RelayRingSlotState.ok] /
  /// [RelayRingSlotState.error] as that relay resolves. Relay URLs are never
  /// stored here (two-plane privacy).
  final List<RelayRingSlotState> slots;

  /// Number of inbox relays pinged this refresh.
  final int total;

  /// Number of relays that answered.
  final int responded;

  /// Number of genuinely new invitations processed this refresh.
  final int newCount;

  /// The settled outcome; non-null only when [phase] is
  /// [InvitationPollPhase.settled].
  final InvitationPollOutcome? outcome;

  /// Relays that did not answer.
  int get notReturned => total - responded;

  /// The idle (hidden) status.
  static const idle = InvitationPollStatus(phase: InvitationPollPhase.idle);
}

/// Provider for the Invitations refresh status (Settle Pill state).
final invitationPollStatusProvider =
    NotifierProvider<InvitationPollStatusNotifier, InvitationPollStatus>(
      InvitationPollStatusNotifier.new,
    );

/// Notifier that pings inbox relays per-relay and reports an accurate tally.
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
  /// directly. Order matters: no inbox configured, then nobody reached, then
  /// new invitations, then a partial answer, else everyone answered with
  /// nothing new.
  static InvitationPollOutcome categorizeOutcome({
    required int total,
    required int responded,
    required int newCount,
  }) {
    if (total == 0) return InvitationPollOutcome.noInbox;
    if (responded == 0) return InvitationPollOutcome.offline;
    if (newCount > 0) return InvitationPollOutcome.newInvites;
    if (responded < total) return InvitationPollOutcome.partial;
    return InvitationPollOutcome.upToDate;
  }

  /// Pings the user's inbox relays and updates [state] with the result.
  ///
  /// Sets [InvitationPollPhase.checking] while in flight, then
  /// [InvitationPollPhase.settled] with exact answered/total counts and the
  /// number of new invitations discovered. Never throws.
  Future<void> refresh() async {
    final myGeneration = ++_generation;

    final identity = await ref.read(identityProvider.future);
    if (myGeneration != _generation) return;
    if (identity == null) {
      // No identity yet — nothing to poll; leave the pill as-is.
      return;
    }

    // Two-plane model: ping ONLY the user's own inbox relays. Never fall back
    // to public/discovery relays for the count display — that would broadcast
    // the user's pubkey to the discovery plane. In practice the inbox list
    // self-heals to the user's own default inbox relays, so `noInbox` is a
    // defensive state; the invariant that matters is that an empty list must
    // NOT trigger a ping of public defaults.
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
    var responded = 0;
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
        responded: responded,
        slots: List<RelayRingSlotState>.unmodifiable(slots),
      );
    }

    // Per-relay fan-out: each inbox relay is queried independently so its ring
    // segment flips to ok/error the instant it resolves. Dart is
    // single-threaded, so the index-based mutation of `slots`/`responded`
    // inside these closures is race-free (one microtask runs at a time).
    final since = DateTime.now().subtract(_giftWrapLookback);
    // Only responding relays carry events to de-duplicate; an unreachable
    // relay yields nothing, so there is no reason to collect it here.
    final responding = <RelayGiftWrapFetch>[];

    await Future.wait(
      List<Future<void>>.generate(relays.length, (i) async {
        try {
          final outcomes = await relayService.fetchGiftWrapsPerRelay(
            recipientPubkey: identity.pubkeyHex,
            relays: [relays[i]],
            since: since,
          );
          // Guard before every state write: a superseded refresh must not
          // touch state.
          if (myGeneration != _generation) return;
          // A single-URL query returns exactly one outcome by contract; guard
          // defensively against a stub/mock that violates it.
          final fetch = outcomes.isEmpty ? null : outcomes.first;
          if (fetch != null && fetch.responded) {
            responding.add(fetch);
            responded++;
            slots[i] = RelayRingSlotState.ok;
          } else {
            slots[i] = RelayRingSlotState.error;
          }
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

    // Union events across every answering relay and de-duplicate by event id:
    // the same gift wrap commonly arrives on multiple inbox relays, and
    // processing one twice concurrently could race the Rust dedup table.
    // `processGiftWrappedInvitation` returns null for an already-processed
    // wrap, so newCount is the count of genuinely new invitations.
    var newCount = 0;
    final seen = <String>{};
    final uniqueEvents = <String>[];
    for (final fetch in responding) {
      for (final eventJson in fetch.events) {
        if (seen.add(_dedupKey(eventJson))) uniqueEvents.add(eventJson);
      }
    }

    if (uniqueEvents.isNotEmpty) {
      // Fetch secret bytes once for the batch and only when there is work,
      // minimising secret exposure. Dart has no zeroize, so copy into a buffer
      // we control and scrub it in `finally` (Rule #9).
      final secretBytes = Uint8List.fromList(
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
              return invitation == null ? 0 : 1;
            } on Object catch (e) {
              debugPrint(
                '[InvitationPollStatus] skipped gift-wrap: ${e.runtimeType}',
              );
              return 0;
            }
          }),
        );
        newCount = results.fold(0, (sum, v) => sum + v);
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

    state = InvitationPollStatus(
      phase: InvitationPollPhase.settled,
      total: relays.length,
      responded: responded,
      newCount: newCount,
      slots: List<RelayRingSlotState>.unmodifiable(slots),
      outcome: categorizeOutcome(
        total: relays.length,
        responded: responded,
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
