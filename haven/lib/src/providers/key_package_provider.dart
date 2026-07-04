/// Provider for publishing key packages (kinds 30443 + 443) and relay lists
/// (kind 10050 + 10051) to relays.
///
/// Signs and publishes the user's MLS key package so other users can
/// discover their key material and invite them to circles. During the
/// MIP-00 transition window we publish a **pair** of key package events
/// from the same MLS material: the canonical addressable kind 30443
/// (preferred) and the legacy kind 443 twin (best-effort). This mirrors
/// the reference implementation in `whitenoise-rs` so legacy Marmot
/// clients which still query kind 443 can discover this user.
///
/// Also publishes the user's relay lists (kind 10050 inbox per NIP-17,
/// kind 10051 KeyPackage per MIP-00) and deletes the previously consumed
/// `KeyPackage` via NIP-09 after rotation.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:haven/src/constants/relays.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/relay_preferences_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/relay_preferences_service.dart';
import 'package:haven/src/services/relay_service.dart';

/// Maximum number of publish attempts before giving up.
const _maxAttempts = 2;

/// Signs and publishes the kind 30443 + 443 key package pair plus the
/// kind 10050 inbox + kind 10051 KeyPackage relay-list events.
///
/// This provider:
/// 1. Gets the user's identity and secret bytes.
/// 2. Fetches the existing KeyPackage event ID (for later deletion).
/// 3. Sources the user's KeyPackage relays from
///    [`keyPackageRelaysProvider`]. Falls back to [`defaultRelays`] if
///    that list is somehow empty (defensive).
/// 4. Signs a kind 30443 + kind 443 pair via the circle service.
/// 5. Publishes the canonical kind 30443 to the KeyPackage relays
///    (with retry).
/// 6. Publishes the legacy kind 443 twin best-effort.
/// 7. Deletes the old (consumed) KeyPackage via NIP-09 (non-fatal).
/// 8. Publishes the kind 10051 relay list (toggle-aware) to the user's own
///    KeyPackage relays ONLY — no public-default union; see Rust
///    `build_relay_list_publish`. Discovery of others uses the read-only
///    discovery plane, not a publish union.
/// 9. Publishes the kind 10050 inbox relay list (toggle-aware).
///
/// Returns `true` if at least one relay accepted the canonical kind
/// 30443 event. All other publish failures are non-fatal.
///
/// Re-runs whenever the relay-preferences provider invalidates
/// [`keyPackagePublisherInvalidatorProvider`].
final keyPackagePublisherProvider = FutureProvider<bool>((ref) async {
  // Coupling to the relay-preferences invalidator: when the user adds /
  // removes a KP relay or toggles the publish setting, we re-run.
  ref.watch(keyPackagePublisherInvalidatorProvider);

  final identity = await ref.read(identityProvider.future);
  if (identity == null) return false;

  final identityNotifier = ref.read(identityNotifierProvider.notifier);
  final circleService = ref.read(circleServiceProvider);
  final relayService = ref.read(relayServiceProvider);
  final relayPrefs = await ref.read(relayPreferencesServiceProvider.future);

  // Source the KeyPackage destination relays from the user's preferences.
  // This is where 30443/443 will live; the kind 10051 list publishes to this
  // same list ONLY (no public-default union, computed in Rust). A user who
  // configures only private relays therefore never leaks them. The
  // defaultRelays fallback below is the account-creation seed, used only as a
  // last-resort guard against publishing an empty relay-tag set — not a union.
  var keyPackageRelays = await ref.read(keyPackageRelaysProvider.future);
  if (keyPackageRelays.isEmpty) {
    // Defensive: should not happen post-seed. Falls back to defaults so
    // we never publish a 30443 with empty relay tags (which MIP-00
    // would consider malformed).
    debugPrint(
      'KP publisher: keyPackageRelays empty — falling back to defaults',
    );
    keyPackageRelays = defaultRelays;
  }

  try {
    final secretBytes = await identityNotifier.getSecretBytes();

    // Fetch existing KP event ID before publishing the replacement so we
    // can delete it after the new one lands. Publish-first-then-delete
    // ensures the account is never left with zero key packages on relays.
    String? oldKeyPackageEventId;
    try {
      final existingKp = await relayService.fetchKeyPackage(identity.pubkeyHex);
      if (existingKp != null) {
        final eventMap =
            jsonDecode(existingKp.eventJson) as Map<String, dynamic>;
        final id = eventMap['id'] as String?;
        final pubkey = eventMap['pubkey'] as String?;
        // Validate: must be a 64-char hex event ID authored by us.
        // Defense-in-depth against a malicious relay returning someone
        // else's event id we'd then try to delete.
        if (id != null &&
            RegExp(r'^[0-9a-f]{64}$').hasMatch(id) &&
            pubkey == identity.pubkeyHex) {
          oldKeyPackageEventId = id;
        }
      }
    } on Object catch (e) {
      debugPrint(
        'Failed to fetch existing KeyPackage (non-fatal): ${e.runtimeType}',
      );
    }

    // Sign the kind 30443 + 443 pair against the user's KeyPackage relay
    // list. The relays parameter is embedded in the 30443 `relays` tag
    // per MIP-00.
    final signedEvent = await circleService.signKeyPackageEvent(
      identitySecretBytes: secretBytes,
      relays: keyPackageRelays,
    );

    // Publish kind 30443 (canonical) with retry. Gating publish.
    final result = await _publishWithRetry(
      () => relayService.publishEvent(
        eventJson: signedEvent.eventJson,
        relays: signedEvent.relays,
      ),
      label: 'KeyPackage (kind 30443)',
    );
    if (result == null) return false;
    debugPrint('KeyPackage published: ${result.acceptedBy.length} accepted');

    // Publish kind 443 (legacy twin) best-effort.
    try {
      final legacyResult = await _publishWithRetry(
        () => relayService.publishEvent(
          eventJson: signedEvent.legacyEventJson,
          relays: signedEvent.relays,
        ),
        label: 'KeyPackage (legacy kind 443)',
      );
      if (legacyResult != null) {
        debugPrint(
          'Legacy KeyPackage published: '
          '${legacyResult.acceptedBy.length} accepted',
        );
      }
    } on Object catch (e) {
      debugPrint(
        'Legacy KeyPackage publish failed (non-fatal): ${e.runtimeType}',
      );
    }

    // M8-6: record the published KeyPackage pair so the scheduled maintenance
    // live-material gate recognizes THIS (login/onboarding) KeyPackage as live
    // — returning AlreadyHealthy — instead of misreading the untracked primary
    // KP as dead and needlessly force-rotating it on the first cycle. This runs
    // only after the canonical 30443 relay publish succeeded above
    // (publish-first). Best-effort: a record failure just means the next
    // maintenance tick may rotate once, so it must never fail the publish.
    try {
      await circleService.recordPublishedKeyPackages(
        canonicalHashRef: signedEvent.canonicalHashRef,
        dTag: signedEvent.dTag,
        canonicalEventId: signedEvent.canonicalEventId,
        legacyEventId: signedEvent.legacyEventId,
      );
    } on Object catch (e) {
      debugPrint('KeyPackage record failed (non-fatal): ${e.runtimeType}');
    }

    // Delete the old (consumed) KeyPackage from relays via NIP-09.
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
            relays: keyPackageRelays,
          ),
          label: 'KeyPackage deletion (NIP-09)',
        );
      } on Object catch (e) {
        debugPrint(
          'Failed to delete old KeyPackage (non-fatal): ${e.runtimeType}',
        );
      }
    }

    // Publish kind 10051 (KeyPackage relay list) and kind 10050 (Inbox
    // relay list) via the toggle-aware Rust path. Both are best-effort.
    await _publishRelayListIfEnabled(
      ref: ref,
      identityNotifier: identityNotifier,
      relayPrefs: relayPrefs,
      relayService: relayService,
      identityPubkeyHex: identity.pubkeyHex,
      category: RelayCategory.keyPackage,
      label: 'RelayList (kind 10051)',
    );
    await _publishRelayListIfEnabled(
      ref: ref,
      identityNotifier: identityNotifier,
      relayPrefs: relayPrefs,
      relayService: relayService,
      identityPubkeyHex: identity.pubkeyHex,
      category: RelayCategory.inbox,
      label: 'InboxRelayList (kind 10050)',
    );

    return result.isSuccess;
  } on Object catch (e) {
    debugPrint('KeyPackage publication failed: ${e.runtimeType}');
    return false;
  }
});

/// Builds a relay list publish via the toggle-aware Rust path and
/// publishes it. No-op when the user has the privacy toggle off
/// (`suppressed=true`). Records the published event id on success so a
/// subsequent unpublish can issue a NIP-09 deletion referencing it.
Future<void> _publishRelayListIfEnabled({
  required Ref ref,
  required IdentityNotifier identityNotifier,
  required RelayPreferencesService relayPrefs,
  required RelayService relayService,
  required String identityPubkeyHex,
  required RelayCategory category,
  required String label,
}) async {
  // Hold the secret-bytes copy in a typed buffer so we can `fillRange`
  // it on exit. Mirrors `background_location_task.dart:172-174`; reduces
  // the window the secret sits in Dart's managed heap after the FFI has
  // consumed it. Rust-side zeroize is unaffected.
  Uint8List? secretBuffer;
  try {
    final raw = await identityNotifier.getSecretBytes();
    secretBuffer = Uint8List.fromList(raw);
    final built = await relayPrefs.buildRelayListPublish(
      identitySecretBytes: secretBuffer,
      category: category,
    );
    if (built.suppressed ||
        built.eventJson == null ||
        built.eventIdHex == null ||
        built.kind == null) {
      debugPrint('$label: publish suppressed (toggle off)');
      return;
    }
    final published = await _publishWithRetry(
      () => relayService.publishEvent(
        eventJson: built.eventJson!,
        relays: built.targets,
      ),
      label: label,
    );
    if (published != null) {
      // Track the event id + signed created_at so the unpublish flow can
      // later issue a NIP-09 deletion AND build an empty-replacement
      // event whose `created_at` strictly succeeds the prior publication.
      try {
        await relayPrefs.recordPublishedRelayList(
          identityPubkeyHex: identityPubkeyHex,
          kind: built.kind!,
          eventIdHex: built.eventIdHex!,
          // `createdAtSecs` is `Some` whenever `built.suppressed` is
          // false (we just verified that above). Defensive `?? 0` keeps
          // us safe if a stale FFI binding ever returns `null`.
          publishedAtSecs: built.createdAtSecs ?? 0,
        );
      } on Object catch (e) {
        debugPrint(
          '$label: record_published failed (non-fatal): '
          '${e.runtimeType}',
        );
      }
    }
  } on Object catch (e) {
    debugPrint('$label: publication failed: ${e.runtimeType}');
  } finally {
    secretBuffer?.fillRange(0, secretBuffer.length, 0);
  }
}

/// Attempts [publish] up to [_maxAttempts] times with exponential backoff.
Future<PublishResult?> _publishWithRetry(
  Future<PublishResult> Function() publish, {
  required String label,
}) async {
  for (var attempt = 0; attempt < _maxAttempts; attempt++) {
    if (attempt > 0) {
      final delay = Duration(seconds: attempt);
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
