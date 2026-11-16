/// Providers for invitation state management.
///
/// Provides reactive access to pending invitations and a polling mechanism
/// for discovering new gift-wrapped welcome events from relays.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/relay_preferences_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/rust/api.dart' as rust;
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/utils/log_alias.dart';

/// Provider for the list of pending invitations.
///
/// Fetches invitations from [CircleService] and makes them available
/// reactively throughout the app. A failed read is an error, never an empty
/// list: "no invitations" would be a claim the read did not make.
final pendingInvitationsProvider = FutureProvider<List<Invitation>>((
  ref,
) async {
  final circleService = ref.read(circleServiceProvider);
  try {
    return await circleService.getPendingInvitations();
  } on Object catch (e) {
    // FFI can throw Error instead of Exception; catch all throwables.
    debugPrint('Failed to load invitations: ${e.runtimeType}');
    throw const CircleServiceException('Failed to load invitations');
  }
});

/// [inboxGiftWrapLookback] when the Rust bridge is not loaded (unit tests).
/// Mirrors `INBOX_GIFTWRAP_LOOKBACK_SECS`, held equal by a test.
const fallbackInboxGiftWrapLookback = Duration(days: 7);

/// How far back a read of the user's inbox asks for gift wraps — the
/// engine's own inbox lookback (`INBOX_GIFTWRAP_LOOKBACK_SECS`): NIP-59's two
/// days of backdating plus the 72-hour hold on an unanswered invitation.
///
/// The poll's and the manual refresh's REQ floor is derived from the wall
/// clock alone — never from the persisted `inbox_1059` cursor, and never from
/// anything a fetched wrap carries. See [invitationPollerProvider].
Duration get inboxGiftWrapLookback {
  try {
    return Duration(seconds: rust.inboxGiftWrapLookbackSecs());
  } on Object catch (_) {
    return fallbackInboxGiftWrapLookback;
  }
}

/// Clock the gift-wrap REQ floor is taken from, by the poller and by the
/// manual refresh. Injectable so the floor can be checked at an exact instant.
final invitationClockProvider = Provider<DateTime Function()>(
  (_) => DateTime.now,
);

/// Polls relays for new gift-wrapped invitations and processes them.
///
/// This provider:
/// 1. Gets the user's identity and secret bytes
/// 2. Fetches kind 1059 gift wrap events from the user's own inbox relays
/// 3. Processes each through the circle service (duplicates are rejected)
/// 4. Invalidates [pendingInvitationsProvider] and [circlesProvider]
///
/// Returns the number of new invitations discovered.
///
/// Designed to be called periodically (every 2 minutes), on app resume,
/// and manually (refresh button).
///
/// # No sync-cursor write
///
/// This poller advances NO persisted cursor. It used to raise `inbox_1059` to
/// the newest handled gift wrap's outer `created_at` — a field chosen by
/// whoever built the wrap, on an event that anyone who knows this user's
/// published npub can mint (see `CircleService`). Its own REQ floor is the
/// fixed [inboxGiftWrapLookback], which never reads that cursor either, so
/// this path is cursor-free end to end. The one consumer of `inbox_1059` is the
/// live-sync engine's inbox REQ, which anchors it in Rust on that REQ's own
/// local open time.
final invitationPollerProvider = FutureProvider<int>((ref) async {
  // Coupling to the relay-preferences invalidator: when the user changes
  // their inbox relay list, the next poll picks up the new relays.
  ref.watch(invitationInvalidatorProvider);

  final identity = await ref.read(identityProvider.future);
  if (identity == null) return 0;

  final identityNotifier = ref.read(identityNotifierProvider.notifier);
  final circleService = ref.read(circleServiceProvider);
  final relayService = ref.read(relayServiceProvider);

  // Two-plane model: poll ONLY the user's own Inbox relays (kind 10050) —
  // where they advertise as receiving gift wraps. We deliberately do NOT
  // union public defaults/indexers: that would keep a connection open to
  // public relays (revealing our pubkey via the #p filter) even for a user
  // who configured only private relays. An empty list (InboxRelaysNotifier
  // self-heals, so a brand-new account caught mid-seed at most) polls
  // nothing: with no 10050 advertised, no inviter sends a Welcome (NIP-17),
  // and a `#p` REQ elsewhere would only tell those relays this npub.
  final pollRelays = await ref.read(inboxRelaysProvider.future);
  if (pollRelays.isEmpty) return 0;

  try {
    // NIP-59 randomizes gift wrap `created_at` up to 2 days in the past,
    // so we must always look back beyond that window. Re-fetching old
    // gift wraps is harmless — process_invitation guards against duplicates.
    final since = ref.read(invitationClockProvider)().subtract(
      inboxGiftWrapLookback,
    );

    final giftWraps = await relayService.fetchGiftWraps(
      recipientPubkey: identity.pubkeyHex,
      relays: pollRelays,
      since: since,
    );

    debugPrint(
      '[InvitationPoller] fetched ${magnitudeBucket(giftWraps.length)} '
      'gift-wrap events',
    );

    // Fetch secret bytes once for the batch — each gift wrap creates
    // an independent MLS group, so parallel processing is safe. Scrubbed in
    // `finally` the instant the whole batch is done (Security Rule 9: Dart
    // has no `zeroize`, so a shared fetch must not outlive its last use).
    final secretBytes = await identityNotifier.getSecretBytes();

    final List<bool> results;
    try {
      // Process all gift wraps in parallel. Each result records only whether
      // the wrap was newly accepted (for the count). Nothing a wrap carries is
      // read beyond its own payload — in particular its outer `created_at` is
      // not extracted at all, because the only thing it was ever used for was
      // a cursor advance this path no longer performs.
      results = await Future.wait(
        giftWraps.map((eventJson) async {
          try {
            final invitation = await circleService
                .processGiftWrappedInvitation(
                  identitySecretBytes: secretBytes,
                  giftWrapEventJson: eventJson,
                );
            // `null` → already processed, or no invitation this device can
            // open. Silent no-op for the count.
            return invitation != null;
          } on CircleServiceException catch (e) {
            // Real failure from the service layer (storage failure, MDK
            // error). The page's own refresh tells the user about a wrap that
            // was not saved; a background poll only skips it, unmarked, so
            // the next fetch asks again.
            debugPrint(
              '[InvitationPoller] skipped gift-wrap: ${e.runtimeType}',
            );
            return false;
          } on Object catch (e) {
            // FFI Error path. Log only the runtime type — error messages from
            // non-Mls CircleError variants (NotFound, ContactNotFound, etc.)
            // can embed pubkeys or group IDs in their Display output.
            debugPrint(
              '[InvitationPoller] skipped gift-wrap (processing error): '
              '${e.runtimeType}',
            );
            return false;
          }
        }),
      );
    } finally {
      secretBytes.fillRange(0, secretBytes.length, 0);
    }
    final newCount = results.where((isNew) => isNew).length;

    if (newCount > 0) {
      ref
        ..invalidate(pendingInvitationsProvider)
        ..invalidate(circlesProvider);
    }

    return newCount;
  } on Object catch (e) {
    debugPrint('Invitation polling failed: ${e.runtimeType}');
    return 0;
  }
});
