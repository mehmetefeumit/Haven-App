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

/// Tracks the timestamp of the last successful gift-wrap fetch.
///
/// Used to pass a `since` parameter to avoid re-fetching old gift wraps
/// on every poll cycle. Resets on app restart (acceptable because the Rust
/// guard in `process_invitation` prevents overwriting existing memberships).
DateTime? _lastPollTimestamp;

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
    final giftWraps = await relayService.fetchGiftWraps(
      recipientPubkey: identity.pubkeyHex,
      relays: defaultRelays,
      since: _lastPollTimestamp,
    );

    // Record the fetch time BEFORE processing so that the next poll
    // picks up from this point. Subtract a small buffer (30s) to
    // account for clock skew between client and relays.
    _lastPollTimestamp = DateTime.now().subtract(const Duration(seconds: 30));

    debugPrint(
      '[InvitationPoller] fetched ${giftWraps.length} gift-wrap events',
    );

    var newCount = 0;
    for (final eventJson in giftWraps) {
      try {
        // Fetch secret bytes per iteration to minimize exposure window.
        // Dart has no zeroize; re-fetching allows earlier GC of prior copies.
        final secretBytes = await identityNotifier.getSecretBytes();
        await circleService.processGiftWrappedInvitation(
          identitySecretBytes: secretBytes,
          giftWrapEventJson: eventJson,
        );
        newCount++;
      } on CircleServiceException catch (e) {
        // Expected for already-processed or invalid events.
        debugPrint('[InvitationPoller] skipped gift-wrap: $e');
      } on Object {
        // FFI Error — log generic message to avoid leaking unredacted
        // MLS error strings (group IDs, internal state).
        debugPrint('[InvitationPoller] skipped gift-wrap (processing error)');
      }
    }

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
