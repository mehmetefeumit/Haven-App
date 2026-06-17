/// Riverpod providers for user-configurable relay preferences.
///
/// Exposes the user's two relay lists ([`inboxRelaysProvider`],
/// [`keyPackageRelaysProvider`]) as `AsyncNotifier`s so the UI can call
/// mutation methods directly on the notifier rather than juggling
/// separate service + invalidate calls.
///
/// All notifiers self-heal: their `build()` calls
/// `seedDefaultsIfUnseeded` if the storage is empty, so upgrade users who
/// never went through onboarding still get a populated list on first
/// read.
library;

import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/constants/relays.dart';
// Intentional 2-file import cycle with key_package_provider.dart: a relay
// add/remove must DRIVE the republish (read keyPackagePublisherProvider),
// not merely mark it dirty via a marker. Dart resolves the cycle fine —
// both providers are lazily initialised top-level finals — and the read is
// the same pattern every other republish call site uses.
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/key_package_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/nostr_circle_service.dart';
import 'package:haven/src/services/nostr_relay_preferences_service.dart';
import 'package:haven/src/services/relay_preferences_service.dart';

/// Provides the [`RelayPreferencesService`] singleton.
///
/// Production binding lazily wraps the existing [`circleServiceProvider`]'s
/// [`CircleManagerFfi`] handle so all relay-preference operations go
/// through the same authoritative SQLCipher connection used by the
/// circle storage. Tests override this with a mock.
final relayPreferencesServiceProvider = FutureProvider<RelayPreferencesService>(
  (ref) async {
    final circleService = ref.read(circleServiceProvider);
    if (circleService is! NostrCircleService) {
      throw StateError(
        'relayPreferencesServiceProvider requires a NostrCircleService '
        'in production. In tests, override this provider with a mock.',
      );
    }
    final manager = await circleService.getCircleManagerFfi();
    final service = NostrRelayPreferencesService(manager: manager);
    // Publishing of kind 10050 / 10051 is always on. Force-enable the
    // underlying FFI toggle so the build path never returns suppressed.
    for (final category in RelayCategory.values) {
      try {
        await service.setPublishRelayList(category, value: true);
      } on Object catch (e) {
        debugPrint(
          'force-enable publish(${category.name}) failed (non-fatal): '
          '${e.runtimeType}',
        );
      }
    }
    return service;
  },
);

/// Common surface implemented by [InboxRelaysNotifier] and
/// [KeyPackageRelaysNotifier] so UI helpers can dispatch on
/// [RelayCategory] without losing static typing.
abstract interface class RelayCategoryNotifier {
  /// Adds a relay to this category.
  Future<void> addRelay(String url);

  /// Removes a relay from this category. Returns whether a row was
  /// actually removed.
  Future<bool> removeRelay(String url);

  /// Adds any missing default relays without removing custom entries.
  Future<void> restoreDefaults();

  /// Destructively resets the list to exactly the defaults.
  Future<void> wipeAndReset();
}

/// Best-effort two-plane removal hygiene.
///
/// When [url] is removed from [category], publishes a NIP-09 deletion of the
/// user's last relay-list event to [url] so that relay stops serving a list
/// that may still name a private relay the user is now keeping private.
///
/// MUST run BEFORE the new (smaller) list is republished — so the scrubbed
/// event is the stale one, not the new one — and before [url] is
/// disconnected, so the deletion can still be delivered. Never throws:
/// relay removal must not be blocked by a relay that ignores NIP-09 or is
/// unreachable; the corrected list on the kept relays still reflects the
/// truth globally via its newer `created_at`.
Future<void> _scrubDroppedRelay(
  Ref ref,
  RelayCategory category,
  String url,
) async {
  // Zeroed on every exit path (success, early return, catch) — mirrors the
  // secret-lifetime convention in key_package_provider / background_location_task
  // (Security Rule #9: minimize the lifetime of the Dart heap copy).
  Uint8List? secretBuffer;
  try {
    final service = await ref.read(relayPreferencesServiceProvider.future);
    final identityNotifier = ref.read(identityNotifierProvider.notifier);
    secretBuffer = Uint8List.fromList(await identityNotifier.getSecretBytes());
    final scrub = await service.buildRelayRemovalScrub(
      identitySecretBytes: secretBuffer,
      category: category,
      droppedRelays: [url],
    );
    final deletion = scrub.deletionEventJson;
    if (scrub.suppressed || deletion == null || scrub.targets.isEmpty) {
      return;
    }
    await ref
        .read(relayServiceProvider)
        .publishEvent(eventJson: deletion, relays: scrub.targets);
  } on Object catch (e) {
    debugPrint('Relay removal scrub failed (best-effort): ${e.runtimeType}');
  } finally {
    secretBuffer?.fillRange(0, secretBuffer.length, 0);
  }
}

/// Notifier for the user's Inbox (kind 10050) relay list.
class InboxRelaysNotifier extends AsyncNotifier<List<String>>
    implements RelayCategoryNotifier {
  @override
  Future<List<String>> build() async {
    final service = await ref.read(relayPreferencesServiceProvider.future);
    var list = await service.listRelays(RelayCategory.inbox);
    // Self-heal: cover upgrade users who never went through onboarding.
    // If seeding fails (e.g., a transient SQLite lock at startup), we
    // fall back to the compile-time default constant rather than
    // entering AsyncError. Without the fallback, a single hiccup
    // strands the relay settings page in an error state for the rest
    // of the session — there is no automatic retry.
    if (list.isEmpty) {
      try {
        await service.seedDefaultsIfUnseeded();
        list = await service.listRelays(RelayCategory.inbox);
      } on Object catch (e) {
        debugPrint('Inbox seed failed (using fallback): ${e.runtimeType}');
        list = List<String>.from(fallbackDefaultRelays);
      }
    }
    return list;
  }

  /// Adds a relay and refreshes downstream state.
  ///
  /// Throws [`RelayValidationError`] for malformed URLs.
  @override
  Future<void> addRelay(String url) async {
    final service = await ref.read(relayPreferencesServiceProvider.future);
    await service.addRelay(RelayCategory.inbox, url);
    state = AsyncValue.data(await service.listRelays(RelayCategory.inbox));
    _invalidateDownstream();
  }

  /// Removes a relay and refreshes downstream state. Returns whether a
  /// row was actually removed.
  ///
  /// Throws [`RelayValidationError`] when the URL is invalid OR when
  /// removal would leave the category empty.
  @override
  Future<bool> removeRelay(String url) async {
    final service = await ref.read(relayPreferencesServiceProvider.future);
    final removed = await service.removeRelay(RelayCategory.inbox, url);
    state = AsyncValue.data(await service.listRelays(RelayCategory.inbox));
    if (removed) {
      // Two-plane removal hygiene: scrub the dropped relay's stale copy of
      // our list (which may still name a private relay) BEFORE disconnecting
      // it and BEFORE the downstream republish records a newer event.
      await _scrubDroppedRelay(ref, RelayCategory.inbox, url);
      // Best-effort: tear down the WebSocket on the persistent
      // RelayService client so a removed relay does not continue to
      // receive metadata until process exit. Routed through
      // RelayService — NOT the prefs service — because the persistent
      // nostr_sdk::Client lives there.
      await ref.read(relayServiceProvider).disconnectRelay(url);
    }
    _invalidateDownstream();
    return removed;
  }

  /// Adds any missing default relays without removing the user's
  /// custom ones.
  @override
  Future<void> restoreDefaults() async {
    final service = await ref.read(relayPreferencesServiceProvider.future);
    await service.restoreDefaults(RelayCategory.inbox);
    state = AsyncValue.data(await service.listRelays(RelayCategory.inbox));
    _invalidateDownstream();
  }

  /// Destructively resets the list to exactly the default set. UI MUST
  /// gate behind a confirmation dialog.
  @override
  Future<void> wipeAndReset() async {
    final service = await ref.read(relayPreferencesServiceProvider.future);
    await service.wipeAndResetDefaults(RelayCategory.inbox);
    state = AsyncValue.data(await service.listRelays(RelayCategory.inbox));
    _invalidateDownstream();
  }

  /// Invalidates every other provider that depends on the inbox list.
  void _invalidateDownstream() {
    // Status page reads union(inbox, keyPackage) of relays.
    // Inbox affects the gift-wrap polling target list.
    // KeyPackage publisher also publishes kind 10050 (inbox relay list)
    // — see `_publishRelayListIfEnabled` in `key_package_provider.dart`
    // — so inbox-list mutations must republish it too. Invalidating the
    // marker ALONE is not enough: `keyPackagePublisherProvider` is a
    // listener-less FutureProvider, so a marker change only marks it dirty;
    // the trailing `read` is what actually drives the rebuild that
    // republishes kind 30443/10051/10050 to the updated relay set. Every
    // other republish call site (map_shell, invitation_card,
    // name_circle_page, onboarding) pairs the invalidate with a read for
    // the same reason; without the read, an added inbox relay would not be
    // advertised (no kind 10050 republish) until the next app resume.
    ref
      ..invalidate(relayStatusInvalidatorProvider)
      ..invalidate(invitationInvalidatorProvider)
      ..invalidate(keyPackagePublisherInvalidatorProvider)
      ..read(keyPackagePublisherProvider);
  }
}

/// Notifier for the user's `KeyPackage` (kind 10051) relay list.
class KeyPackageRelaysNotifier extends AsyncNotifier<List<String>>
    implements RelayCategoryNotifier {
  @override
  Future<List<String>> build() async {
    final service = await ref.read(relayPreferencesServiceProvider.future);
    var list = await service.listRelays(RelayCategory.keyPackage);
    // Self-heal: cover upgrade users; fall back to compile-time defaults
    // on storage failure rather than stranding the UI in AsyncError.
    if (list.isEmpty) {
      try {
        await service.seedDefaultsIfUnseeded();
        list = await service.listRelays(RelayCategory.keyPackage);
      } on Object catch (e) {
        debugPrint('KP seed failed (using fallback): ${e.runtimeType}');
        list = List<String>.from(fallbackDefaultRelays);
      }
    }
    return list;
  }

  /// Adds a relay and refreshes downstream state.
  @override
  Future<void> addRelay(String url) async {
    final service = await ref.read(relayPreferencesServiceProvider.future);
    await service.addRelay(RelayCategory.keyPackage, url);
    state = AsyncValue.data(await service.listRelays(RelayCategory.keyPackage));
    _invalidateDownstream();
  }

  /// Removes a relay and refreshes downstream state.
  @override
  Future<bool> removeRelay(String url) async {
    final service = await ref.read(relayPreferencesServiceProvider.future);
    final removed = await service.removeRelay(RelayCategory.keyPackage, url);
    state = AsyncValue.data(await service.listRelays(RelayCategory.keyPackage));
    if (removed) {
      // Two-plane removal hygiene: scrub the dropped relay's stale copy
      // before disconnecting it and before the downstream republish.
      await _scrubDroppedRelay(ref, RelayCategory.keyPackage, url);
      // Tear down the persistent WebSocket via RelayService.
      await ref.read(relayServiceProvider).disconnectRelay(url);
    }
    _invalidateDownstream();
    return removed;
  }

  /// Adds any missing default relays without removing custom ones.
  @override
  Future<void> restoreDefaults() async {
    final service = await ref.read(relayPreferencesServiceProvider.future);
    await service.restoreDefaults(RelayCategory.keyPackage);
    state = AsyncValue.data(await service.listRelays(RelayCategory.keyPackage));
    _invalidateDownstream();
  }

  /// Destructively resets the list. UI MUST gate behind a dialog.
  @override
  Future<void> wipeAndReset() async {
    final service = await ref.read(relayPreferencesServiceProvider.future);
    await service.wipeAndResetDefaults(RelayCategory.keyPackage);
    state = AsyncValue.data(await service.listRelays(RelayCategory.keyPackage));
    _invalidateDownstream();
  }

  void _invalidateDownstream() {
    // KeyPackage list changes affect the kind 30443/10051 publisher.
    // Invalidating the marker ALONE is not enough: keyPackagePublisher
    // Provider is a listener-less FutureProvider, so a marker change only
    // marks it dirty; the trailing `read` is what actually drives the
    // rebuild that republishes the KeyPackage (30443) and its relay list
    // (10051) to the updated relay set — matching every other republish
    // call site. Without the read, an added KeyPackage relay would not
    // receive the user's KeyPackage until the next app resume.
    ref
      ..invalidate(relayStatusInvalidatorProvider)
      ..invalidate(keyPackagePublisherInvalidatorProvider)
      ..read(keyPackagePublisherProvider);
  }
}

/// User's Inbox (kind 10050) relay list.
final inboxRelaysProvider =
    AsyncNotifierProvider<InboxRelaysNotifier, List<String>>(
      InboxRelaysNotifier.new,
    );

/// User's `KeyPackage` (kind 10051) relay list.
final keyPackageRelaysProvider =
    AsyncNotifierProvider<KeyPackageRelaysNotifier, List<String>>(
      KeyPackageRelaysNotifier.new,
    );

// ===================== Invalidator providers =====================
//
// These exist solely so the relay-preference notifiers can invalidate
// downstream state without taking a hard import dependency on those
// modules (which would cause cyclic imports). The downstream providers
// (relay_status_provider.dart, invitation_provider.dart,
// key_package_provider.dart) watch these as plain `Object` markers and
// rebuild when they change.
//
// To couple a downstream provider to one of these, simply
// `ref.watch(relayStatusInvalidatorProvider);` somewhere in its build
// path. Calling `ref.invalidate(relayStatusInvalidatorProvider)` here
// then forces the downstream rebuild.

/// Invalidate marker watched by `relayStatusProvider`.
final relayStatusInvalidatorProvider = StateProvider<int>((ref) => 0);

/// Invalidate marker watched by `invitationProvider`.
final invitationInvalidatorProvider = StateProvider<int>((ref) => 0);

/// Invalidate marker watched by `keyPackagePublisherProvider`.
final keyPackagePublisherInvalidatorProvider = StateProvider<int>((ref) => 0);
