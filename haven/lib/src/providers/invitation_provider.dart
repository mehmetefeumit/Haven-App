/// Providers for invitation state management.
///
/// Provides reactive access to pending invitations and a polling mechanism
/// for discovering new gift-wrapped welcome events from relays.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:haven/src/constants/relays.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/relay_preferences_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';

/// Provider for the list of pending invitations.
///
/// Fetches invitations from [CircleService] and makes them available
/// reactively throughout the app.
final pendingInvitationsProvider = FutureProvider<List<Invitation>>((
  ref,
) async {
  final circleService = ref.read(circleServiceProvider);
  try {
    return await circleService.getPendingInvitations();
  } on CircleServiceException catch (e) {
    debugPrint('CircleService error: ${e.runtimeType}');
    return [];
  } on Object catch (e) {
    // FFI can throw Error instead of Exception; catch all throwables.
    debugPrint('Failed to load invitations: ${e.runtimeType}');
    return [];
  }
});

/// NIP-59 gift wraps have `created_at` randomized up to 2 days in the past.
/// We must look back at least that far, plus a buffer for clock skew.
const _giftWrapLookback = Duration(days: 2, hours: 1);

/// Extracts a kind:1059 gift-wrap's outer `created_at` (Unix seconds), or
/// `null` if the JSON is unparseable or missing the field.
///
/// Used to advance the persisted `inbox_1059` sync cursor after a wrap is
/// handled. The wrapper timestamp is safe to anchor on because the 7-day inbox
/// lookback applied at REQ time absorbs NIP-59 backdating.
int? _giftWrapCreatedAtSecs(String eventJson) {
  try {
    final decoded = jsonDecode(eventJson);
    if (decoded is Map<String, dynamic>) {
      final createdAt = decoded['created_at'];
      if (createdAt is int) return createdAt;
      if (createdAt is num) return createdAt.toInt();
    }
  } on FormatException {
    // Unparseable wrapper — just skip advancing the cursor for it.
  }
  return null;
}

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
  // who configured only private relays. In practice the Inbox list is never
  // empty here — InboxRelaysNotifier.build() self-heals (it seeds, or on
  // failure falls back to the compile-time default seed). The isEmpty branch
  // below is therefore a defensive dead path; if ever reached (a brand-new
  // account caught mid-seed), fall back to the user's own account-creation
  // SEED relays — NEVER the read-only discovery indexers, so our own pubkey
  // is never broadcast to the discovery plane.
  var pollRelays = await ref.read(inboxRelaysProvider.future);
  if (pollRelays.isEmpty) {
    pollRelays = defaultRelays;
  }

  try {
    // NIP-59 randomizes gift wrap `created_at` up to 2 days in the past,
    // so we must always look back beyond that window. Re-fetching old
    // gift wraps is harmless — process_invitation guards against duplicates.
    final since = DateTime.now().subtract(_giftWrapLookback);

    final giftWraps = await relayService.fetchGiftWraps(
      recipientPubkey: identity.pubkeyHex,
      relays: pollRelays,
      since: since,
    );

    debugPrint(
      '[InvitationPoller] fetched ${giftWraps.length} gift-wrap events',
    );

    // Fetch secret bytes once for the batch — each gift wrap creates
    // an independent MLS group, so parallel processing is safe.
    final secretBytes = await identityNotifier.getSecretBytes();

    // Process all gift wraps in parallel. Each result records whether the
    // wrap was newly accepted (for the count) and the wrapper `created_at`
    // (seconds) when it was HANDLED WITHOUT ERROR (new or dedup) — eligible to
    // advance the inbox cursor. A wrap that threw yields `wrapSecs == null` so
    // the cursor never advances past an un-handled wrap (it retries next poll).
    final results = await Future.wait(
      giftWraps.map((eventJson) async {
        try {
          final invitation = await circleService.processGiftWrappedInvitation(
            identitySecretBytes: secretBytes,
            giftWrapEventJson: eventJson,
          );
          // `null` → already-processed gift wrap (handled by Rust dedup).
          // Silent no-op for the count, but still a handled wrap.
          return (
            isNew: invitation != null,
            wrapSecs: _giftWrapCreatedAtSecs(eventJson),
          );
        } on CircleServiceException catch (e) {
          // Real failure from the service layer (malformed event, MDK
          // error, storage failure). The underlying Rust error has already
          // been logged with sanitized detail by `nostr_circle_service.dart`.
          debugPrint('[InvitationPoller] skipped gift-wrap: ${e.runtimeType}');
          return (isNew: false, wrapSecs: null);
        } on Object catch (e) {
          // FFI Error path. Log only the runtime type — error messages from
          // non-Mls CircleError variants (NotFound, ContactNotFound, etc.)
          // can embed pubkeys or group IDs in their Display output.
          debugPrint(
            '[InvitationPoller] skipped gift-wrap (processing error): '
            '${e.runtimeType}',
          );
          return (isNew: false, wrapSecs: null);
        }
      }),
    );
    final newCount = results.where((r) => r.isNew).length;

    // Advance the persisted inbox cursor to the newest wrapper we handled
    // without error. Best-effort: a write failure must never fail the poll.
    final maxWrapSecs = results
        .map((r) => r.wrapSecs)
        .whereType<int>()
        .fold<int>(0, (max, v) => v > max ? v : max);
    if (maxWrapSecs > 0) {
      try {
        await circleService.advanceInboxCursorToWrapSecs(maxWrapSecs);
      } on Object catch (e) {
        debugPrint(
          '[InvitationPoller] inbox cursor advance failed: ${e.runtimeType}',
        );
      }
    }

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
