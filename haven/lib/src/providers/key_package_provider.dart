/// Provider for publishing key packages (kind 443) to relays.
///
/// Signs and publishes the user's MLS key package so other users
/// can discover their key material and invite them to circles.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/service_providers.dart';

/// Default relay URLs for publishing key packages.
const _defaultRelays = [
  'wss://relay.damus.io',
  'wss://nos.lol',
  'wss://relay.nostr.band',
];

/// Signs and publishes a key package event (kind 443) to relays.
///
/// This provider:
/// 1. Gets the user's identity and secret bytes
/// 2. Signs a kind 443 key package event via the circle service
/// 3. Publishes the signed event to default relays
///
/// Returns `true` if at least one relay accepted the event.
///
/// Designed to be triggered on identity creation, app startup,
/// and app resume via `ref.invalidate(keyPackagePublisherProvider)`.
final keyPackagePublisherProvider = FutureProvider<bool>((ref) async {
  final identity = await ref.read(identityProvider.future);
  if (identity == null) return false;

  final identityNotifier = ref.read(identityNotifierProvider.notifier);
  final circleService = ref.read(circleServiceProvider);
  final relayService = ref.read(relayServiceProvider);

  try {
    final secretBytes = await identityNotifier.getSecretBytes();
    final signedEvent = await circleService.signKeyPackageEvent(
      identitySecretBytes: secretBytes,
      relays: _defaultRelays,
    );
    final result = await relayService.publishEvent(
      eventJson: signedEvent.eventJson,
      relays: signedEvent.relays,
    );
    debugPrint('KeyPackage published: ${result.acceptedBy.length} accepted');
    return result.isSuccess;
  } on Object catch (e) {
    debugPrint('KeyPackage publication failed: $e');
    return false;
  }
});
