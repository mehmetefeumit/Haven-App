/// Provider for publishing key packages (kind 443) and relay lists
/// (kind 10051) to relays.
///
/// Signs and publishes the user's MLS key package so other users
/// can discover their key material and invite them to circles.
/// Also publishes a relay list so clients know where to find key packages,
/// and deletes the previous (consumed) KeyPackage via NIP-09 after rotation.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:haven/src/constants/relays.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/relay_service.dart';

/// Maximum number of publish attempts before giving up.
const _maxAttempts = 2;

/// Signs and publishes a key package event (kind 30443) and relay list
/// event (kind 10051) to relays.
///
/// This provider:
/// 1. Gets the user's identity and secret bytes
/// 2. Fetches the existing KeyPackage event ID (for later deletion)
/// 3. Signs a kind 30443 key package event via the circle service
/// 4. Publishes the signed event to default relays (with retry)
/// 5. Deletes the old (consumed) KeyPackage via NIP-09 (non-fatal)
/// 6. Signs and publishes a kind 10051 relay list event (with retry)
///
/// Returns `true` if at least one relay accepted the kind 30443 event.
/// Old KeyPackage deletion and kind 10051 failure are non-fatal.
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

    // Fetch existing KP event ID before publishing replacement.
    // If this fails (network error, no existing KP), proceed with
    // publishing — deletion is best-effort, not blocking.
    String? oldKeyPackageEventId;
    try {
      final existingKp = await relayService.fetchKeyPackage(identity.pubkeyHex);
      if (existingKp != null) {
        final eventMap =
            jsonDecode(existingKp.eventJson) as Map<String, dynamic>;
        final id = eventMap['id'] as String?;
        final pubkey = eventMap['pubkey'] as String?;
        // Validate: must be a 64-char hex event ID authored by us.
        // Guards against malicious relay responses that could cause
        // us to delete someone else's event (relays enforce author
        // matching, but defense-in-depth).
        if (id != null &&
            RegExp(r'^[0-9a-f]{64}$').hasMatch(id) &&
            pubkey == identity.pubkeyHex) {
          oldKeyPackageEventId = id;
        }
      }
    } on Object catch (e) {
      debugPrint('Failed to fetch existing KeyPackage (non-fatal): ${e.runtimeType}');
    }

    // Sign and publish new key package
    final signedEvent = await circleService.signKeyPackageEvent(
      identitySecretBytes: secretBytes,
      relays: defaultRelays,
    );

    // Publish kind 30443 with retry and exponential backoff
    final result = await _publishWithRetry(
      () => relayService.publishEvent(
        eventJson: signedEvent.eventJson,
        relays: signedEvent.relays,
      ),
      label: 'KeyPackage (kind 30443)',
    );

    if (result == null) return false;

    debugPrint('KeyPackage published: ${result.acceptedBy.length} accepted');

    // Delete the old (consumed) KeyPackage from relays via NIP-09.
    // Publish-first-then-delete ensures the account is never left with
    // zero key packages on relays.
    if (oldKeyPackageEventId != null) {
      try {
        final deletionSecretBytes = await identityNotifier.getSecretBytes();
        final deletionEventJson = await circleService.signDeletionEvent(
          identitySecretBytes: deletionSecretBytes,
          eventIds: [oldKeyPackageEventId],
        );
        await _publishWithRetry(
          () => relayService.publishEvent(
            eventJson: deletionEventJson,
            relays: defaultRelays,
          ),
          label: 'KeyPackage deletion (NIP-09)',
        );
      } on Object catch (e) {
        debugPrint('Failed to delete old KeyPackage (non-fatal): ${e.runtimeType}');
      }
    }

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
      debugPrint('RelayList publication failed after retries: ${e.runtimeType}');
    }

    return result.isSuccess;
  } on Object catch (e) {
    debugPrint('KeyPackage publication failed: ${e.runtimeType}');
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
      final delay = Duration(seconds: attempt); // 1s, 2s, ...
      debugPrint(
        '$label: retrying in ${delay.inSeconds}s '
        '(attempt ${attempt + 1}/$_maxAttempts)',
      );
      await Future<void>.delayed(delay);
    }

    try {
      return await publish();
    } on Object catch (e) {
      debugPrint('$label: attempt ${attempt + 1} failed: ${e.runtimeType}');
    }
  }

  debugPrint('$label: all $_maxAttempts attempts failed');
  return null;
}
