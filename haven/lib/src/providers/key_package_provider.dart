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
import 'package:haven/src/services/relay_service.dart';

/// Maximum number of publish attempts before giving up.
const _maxAttempts = 3;

/// Signs and publishes a key package event (kind 443) and relay list
/// event (kind 10051) to relays.
///
/// This provider:
/// 1. Gets the user's identity and secret bytes
/// 2. Signs a kind 443 key package event via the circle service
/// 3. Publishes the signed event to default relays (with retry)
/// 4. Signs and publishes a kind 10051 relay list event (with retry)
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

    // Publish kind 443 with retry and exponential backoff
    final result = await _publishWithRetry(
      () => relayService.publishEvent(
        eventJson: signedEvent.eventJson,
        relays: signedEvent.relays,
      ),
      label: 'KeyPackage (kind 443)',
    );

    if (result == null) return false;

    debugPrint(
      'KeyPackage published: ${result.acceptedBy.length} accepted',
    );

    // Publish kind 10051 (relay list) so other clients can discover
    // where our key packages are. Failure is non-fatal.
    try {
      final relayListSecretBytes = await identityNotifier.getSecretBytes();
      final relayListEventJson = await circleService.signRelayListEvent(
        identitySecretBytes: relayListSecretBytes,
        relays: defaultRelays,
      );
      await _publishWithRetry(
        () => relayService.publishEvent(
          eventJson: relayListEventJson,
          relays: defaultRelays,
        ),
        label: 'RelayList (kind 10051)',
      );
    } on Object catch (e) {
      debugPrint('RelayList publication failed after retries: $e');
    }

    return result.isSuccess;
  } on Object catch (e) {
    debugPrint('KeyPackage publication failed: $e');
    return false;
  }
});

/// Attempts [publish] up to [_maxAttempts] times with exponential backoff.
///
/// Returns the [PublishResult] on the first successful attempt, or `null`
/// if all attempts fail.
Future<PublishResult?> _publishWithRetry(
  Future<PublishResult> Function() publish, {
  required String label,
}) async {
  for (var attempt = 0; attempt < _maxAttempts; attempt++) {
    if (attempt > 0) {
      final delay = Duration(seconds: 1 << attempt); // 2s, 4s
      debugPrint('$label: retrying in ${delay.inSeconds}s '
          '(attempt ${attempt + 1}/$_maxAttempts)');
      await Future<void>.delayed(delay);
    }

    try {
      return await publish();
    } on Object catch (e) {
      debugPrint('$label: attempt ${attempt + 1} failed: $e');
    }
  }

  debugPrint('$label: all $_maxAttempts attempts failed');
  return null;
}
