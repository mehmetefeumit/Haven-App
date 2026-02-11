/// Providers for invitation state management.
///
/// Provides reactive access to pending invitations and a polling mechanism
/// for discovering new gift-wrapped welcome events from relays.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';

/// Default relay URLs for fetching gift-wrapped invitations.
const _defaultRelays = [
  'wss://relay.damus.io',
  'wss://nos.lol',
  'wss://relay.nostr.band',
];

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
    // FFI can throw Error instead of Exception; catch all throwables.
    // ignore: avoid_catches_without_on_clauses
  } catch (e) {
    debugPrint('Failed to load invitations: $e');
    return [];
  }
});

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
/// Designed to be called manually (refresh button, app resume).
final invitationPollerProvider = FutureProvider<int>((ref) async {
  final identity = await ref.read(identityProvider.future);
  if (identity == null) return 0;

  final identityNotifier = ref.read(identityNotifierProvider.notifier);
  final circleService = ref.read(circleServiceProvider);
  final relayService = ref.read(relayServiceProvider);

  try {
    final giftWraps = await relayService.fetchGiftWraps(
      recipientPubkey: identity.pubkeyHex,
      relays: _defaultRelays,
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
      } on CircleServiceException {
        // Already processed or invalid - skip silently
      }
    }

    if (newCount > 0) {
      ref
        ..invalidate(pendingInvitationsProvider)
        ..invalidate(circlesProvider);
    }

    return newCount;
  } on Exception catch (e) {
    debugPrint('Invitation polling failed: $e');
    return 0;
  }
});
