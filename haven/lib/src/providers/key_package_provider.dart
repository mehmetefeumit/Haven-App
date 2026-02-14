/// Provider for publishing key packages (kind 443) and relay lists
/// (kind 10051) to relays.
///
/// Signs and publishes the user's MLS key package so other users
/// can discover their key material and invite them to circles.
/// Also publishes a relay list so clients know where to find key packages.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:haven/src/constants/relays.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/service_providers.dart';

/// Signs and publishes a key package event (kind 443) and relay list
/// event (kind 10051) to relays.
///
/// This provider:
/// 1. Gets the user's identity and secret bytes
/// 2. Signs a kind 443 key package event via the circle service
/// 3. Publishes the signed event to default relays
/// 4. Signs and publishes a kind 10051 relay list event
///
/// Returns `true` if at least one relay accepted the kind 443 event.
/// Kind 10051 failure is non-fatal (retries on next invocation).
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
      relays: defaultRelays,
    );
    final result = await relayService.publishEvent(
      eventJson: signedEvent.eventJson,
      relays: signedEvent.relays,
    );
    debugPrint('KeyPackage published: ${result.acceptedBy.length} accepted');

    // Publish kind 10051 (relay list) so other clients can discover
    // where our key packages are. Failure is non-fatal.
    try {
      final relayListSecretBytes = await identityNotifier.getSecretBytes();
      final relayListEventJson = await circleService.signRelayListEvent(
        identitySecretBytes: relayListSecretBytes,
        relays: defaultRelays,
      );
      await relayService.publishEvent(
        eventJson: relayListEventJson,
        relays: defaultRelays,
      );
    } on Object catch (e) {
      debugPrint('RelayList publication failed: $e');
    }

    return result.isSuccess;
  } on Object catch (e) {
    debugPrint('KeyPackage publication failed: $e');
    return false;
  }
});
