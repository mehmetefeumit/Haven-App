/// Riverpod providers for user-configurable relay preferences.
///
/// Exposes the user's two relay lists ([`inboxRelaysProvider`],
/// [`keyPackageRelaysProvider`]) and the publish-toggle state
/// ([`publishKpRelayListProvider`], [`publishInboxRelayListProvider`]) as
/// `AsyncNotifier`s so the UI can call mutation methods directly on the
/// notifier rather than juggling separate service + invalidate calls.
///
/// All notifiers self-heal: their `build()` calls
/// `seedDefaultsIfUnseeded` if the storage is empty, so upgrade users who
/// never went through onboarding still get a populated list on first
/// read.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/constants/relays.dart';
import 'package:haven/src/providers/identity_provider.dart';
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
    return NostrRelayPreferencesService(manager: manager);
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

/// Notifier for the kind 10051 publish privacy toggle.
class PublishKpRelayListNotifier extends AsyncNotifier<bool> {
  @override
  Future<bool> build() async {
    final service = await ref.read(relayPreferencesServiceProvider.future);
    return service.getPublishRelayList(RelayCategory.keyPackage);
  }

  /// Sets the toggle and propagates to the publisher.
  ///
  /// On OFF transitions, also publishes an empty-replacement event +
  /// best-effort NIP-09 deletion for the previously-published kind 10051
  /// so the user's relay list is actually retracted from relays — not
  /// just no longer republished.
  ///
  /// Returns the [`RetractOutcome`] for the OFF path so the UI can warn
  /// the user when the empty-replacement failed to land. ON transitions
  /// always return [`RetractOutcome.nothingToRetract`].
  Future<RetractOutcome> setEnabled({required bool enabled}) async {
    final service = await ref.read(relayPreferencesServiceProvider.future);
    await service.setPublishRelayList(RelayCategory.keyPackage, value: enabled);
    state = AsyncValue.data(enabled);
    var outcome = RetractOutcome.nothingToRetract;
    if (!enabled) {
      outcome = await _retractPublication(ref, RelayCategory.keyPackage);
    }
    ref.invalidate(keyPackagePublisherInvalidatorProvider);
    return outcome;
  }
}

/// Notifier for the kind 10050 publish privacy toggle.
class PublishInboxRelayListNotifier extends AsyncNotifier<bool> {
  @override
  Future<bool> build() async {
    final service = await ref.read(relayPreferencesServiceProvider.future);
    return service.getPublishRelayList(RelayCategory.inbox);
  }

  /// Sets the toggle and propagates to the publisher.
  ///
  /// On OFF transitions, also publishes an empty-replacement event +
  /// best-effort NIP-09 deletion for the previously-published kind 10050.
  /// Returns the [`RetractOutcome`] so the UI can warn on failure.
  Future<RetractOutcome> setEnabled({required bool enabled}) async {
    final service = await ref.read(relayPreferencesServiceProvider.future);
    await service.setPublishRelayList(RelayCategory.inbox, value: enabled);
    state = AsyncValue.data(enabled);
    var outcome = RetractOutcome.nothingToRetract;
    if (!enabled) {
      outcome = await _retractPublication(ref, RelayCategory.inbox);
    }
    // Inbox list affects which relays the gift-wrap poller queries.
    ref.invalidate(invitationInvalidatorProvider);
    return outcome;
  }
}

/// Outcome of [`_retractPublication`].
///
/// Surfaced to the calling toggle notifier so the UI can be honest with
/// the user about whether the prior published list was actually retracted
/// from relays — toggling the switch only persists the local preference;
/// the network round-trip can still fail.
enum RetractOutcome {
  /// At least the empty-replacement event was accepted by one relay
  /// in the publish-target union (best-effort NIP-09 may also have been
  /// sent). The user can reasonably believe the prior list is retracted.
  retracted,

  /// Nothing to do — either the toggle was already off (suppressed)
  /// or no prior publication was on record.
  nothingToRetract,

  /// Empty-replacement publish failed on every targeted relay. The
  /// user's toggle is OFF locally but their previously-published list
  /// is likely still discoverable on at least one default relay until
  /// it ages out.
  failed,
}

/// Builds the empty-replacement event + best-effort NIP-09 deletion via
/// the toggle-aware Rust path and publishes both to the resolved targets.
///
/// Returns a [`RetractOutcome`] so the calling toggle notifier can
/// inform the user when the network retraction failed — the local
/// toggle is persisted regardless, so a silent failure would mislead
/// the user about whether their published list was actually withdrawn.
///
/// All thrown errors are caught and logged with only the runtime type
/// per the project's "no raw errors to UI" rule.
Future<RetractOutcome> _retractPublication(
  Ref ref,
  RelayCategory category,
) async {
  // Hold the secret-bytes copy in a typed buffer so we can `fillRange`
  // it on exit. Dart has no `Zeroize` equivalent; this best-effort
  // overwrite mirrors `background_location_task.dart:172-174` and
  // shrinks the window the secret sits in managed memory after the FFI
  // has consumed it.
  Uint8List? secretBuffer;
  try {
    final service = await ref.read(relayPreferencesServiceProvider.future);
    final identityNotifier = ref.read(identityNotifierProvider.notifier);
    final raw = await identityNotifier.getSecretBytes();
    secretBuffer = Uint8List.fromList(raw);
    final built = await service.buildUnpublishRelayList(
      identitySecretBytes: secretBuffer,
      category: category,
    );
    if (built.suppressed || built.replacementEventJson == null) {
      return RetractOutcome.nothingToRetract;
    }
    final relayService = ref.read(relayServiceProvider);
    // Empty-replacement first — canonical NIP-01 retraction. If this
    // throws, the user's prior list is still on relays.
    var replacementOk = false;
    try {
      await relayService.publishEvent(
        eventJson: built.replacementEventJson!,
        relays: built.targets,
      );
      replacementOk = true;
    } on Object catch (e) {
      debugPrint('Retract: empty-replacement publish failed: ${e.runtimeType}');
    }
    // NIP-09 deletion (best-effort): only sent when a prior publication
    // is on record. Outcome is independent of the empty-replacement
    // result — many relays don't honor NIP-09 of replaceable events.
    final deletion = built.deletionEventJson;
    if (deletion != null) {
      try {
        await relayService.publishEvent(
          eventJson: deletion,
          relays: built.targets,
        );
      } on Object catch (e) {
        debugPrint('Retract: NIP-09 deletion publish failed: ${e.runtimeType}');
      }
    }
    return replacementOk ? RetractOutcome.retracted : RetractOutcome.failed;
  } on Object catch (e) {
    debugPrint('Retract publication failed: ${e.runtimeType}');
    return RetractOutcome.failed;
  } finally {
    // Best-effort overwrite of the Dart-side secret copy. The Rust FFI
    // already zeroized its input.
    secretBuffer?.fillRange(0, secretBuffer.length, 0);
  }
}

/// Whether the kind 10051 (KeyPackage relay list) publish is enabled.
final publishKpRelayListProvider =
    AsyncNotifierProvider<PublishKpRelayListNotifier, bool>(
      PublishKpRelayListNotifier.new,
    );

/// Whether the kind 10050 (Inbox relay list) publish is enabled.
final publishInboxRelayListProvider =
    AsyncNotifierProvider<PublishInboxRelayListNotifier, bool>(
      PublishInboxRelayListNotifier.new,
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
