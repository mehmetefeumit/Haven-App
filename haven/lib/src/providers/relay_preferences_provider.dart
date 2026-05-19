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

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/constants/relays.dart';
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
    // — so inbox-list mutations must invalidate it too. Without this,
    // adding/removing an inbox relay would not republish the kind 10050.
    ref
      ..invalidate(relayStatusInvalidatorProvider)
      ..invalidate(invitationInvalidatorProvider)
      ..invalidate(keyPackagePublisherInvalidatorProvider);
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
    // KeyPackage list changes affect the kind 10051 publisher.
    ref
      ..invalidate(relayStatusInvalidatorProvider)
      ..invalidate(keyPackagePublisherInvalidatorProvider);
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
