/// Providers for invitation state management.
///
/// Provides reactive access to pending invitations and a polling mechanism
/// for discovering new gift-wrapped welcome events from relays.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:haven/src/constants/relays.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/identity_provider.dart';
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
    debugPrint('CircleService error: $e');
    return [];
  } on Object catch (e) {
    // FFI can throw Error instead of Exception; catch all throwables.
    debugPrint('Failed to load invitations: $e');
    return [];
  }
});

/// NIP-59 gift wraps have `created_at` randomized up to 2 days in the past.
/// We must look back at least that far, plus a buffer for clock skew.
const _giftWrapLookback = Duration(days: 2, hours: 1);

/// Polls relays for new gift-wrapped invitations and processes them.
///
/// This provider:
/// 1. Gets the user's identity and secret bytes
/// 2. Fetches kind 1059 gift wrap events from default relays
/// 3. Processes each through the circle service (duplicates are rejected)
/// 4. Invalidates [pendingInvitationsProvider] and [circlesProvider]
///
/// Returns the number of new invitations discovered.
///
/// Designed to be called periodically (every 2 minutes), on app resume,
/// and manually (refresh button).
final invitationPollerProvider = FutureProvider<int>((ref) async {
  final identity = await ref.read(identityProvider.future);
  if (identity == null) return 0;

  final identityNotifier = ref.read(identityNotifierProvider.notifier);
  final circleService = ref.read(circleServiceProvider);
  final relayService = ref.read(relayServiceProvider);

  try {
    // NIP-59 randomizes gift wrap `created_at` up to 2 days in the past,
    // so we must always look back beyond that window. Re-fetching old
    // gift wraps is harmless — process_invitation guards against duplicates.
    final since = DateTime.now().subtract(_giftWrapLookback);

    final giftWraps = await relayService.fetchGiftWraps(
      recipientPubkey: identity.pubkeyHex,
      relays: defaultRelays,
      since: since,
    );

    debugPrint(
      '[InvitationPoller] fetched ${giftWraps.length} gift-wrap events',
    );

    // Fetch secret bytes once for the batch — each gift wrap creates
    // an independent MLS group, so parallel processing is safe.
    final secretBytes = await identityNotifier.getSecretBytes();

    // Process all gift wraps in parallel.
    final results = await Future.wait(
      giftWraps.map((eventJson) async {
        try {
          await circleService.processGiftWrappedInvitation(
            identitySecretBytes: secretBytes,
            giftWrapEventJson: eventJson,
          );
          return 1;
        } on CircleServiceException catch (e) {
          // Expected for already-processed or invalid events.
          debugPrint('[InvitationPoller] skipped gift-wrap: $e');
          return 0;
        } on Object {
          // FFI Error — log generic message to avoid leaking unredacted
          // MLS error strings (group IDs, internal state).
          debugPrint('[InvitationPoller] skipped gift-wrap (processing error)');
          return 0;
        }
      }),
    );
    final newCount = results.fold(0, (sum, v) => sum + v);

    if (newCount > 0) {
      ref
        ..invalidate(pendingInvitationsProvider)
        ..invalidate(circlesProvider);
    }

    return newCount;
  } on Object catch (e) {
    debugPrint('Invitation polling failed: $e');
    return 0;
  }
});
