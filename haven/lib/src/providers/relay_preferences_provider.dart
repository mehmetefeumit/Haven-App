/// Riverpod providers for user-configurable relay preferences.
///
/// Exposes the user's three relay lists ([`inboxRelaysProvider`],
/// [`keyPackageRelaysProvider`], [`profileRelaysProvider`]) as
/// `AsyncNotifier`s so the UI can call mutation methods directly on the
/// notifier rather than juggling separate service + invalidate calls.
/// [`profileRelaysProvider`] is local-only policy (never published) — see
/// [`ProfileRelaysNotifier`] for how its notifier deliberately diverges from
/// the other two.
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
import 'package:haven/src/providers/circles_provider.dart';
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
import 'package:haven/src/utils/relay_url_validator.dart';

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
    // Publishing of kind 10050 / 10002 is always on. Force-enable the
    // underlying FFI toggle so the build path never returns suppressed.
    await forceEnablePublishToggles(service);
    return service;
  },
);

/// Relay categories the app is allowed to force-enable "publish" for.
///
/// Deliberately an explicit allowlist rather than `RelayCategory.values`:
/// [`RelayCategory.profile`] has no wire kind (it is local-only policy —
/// see its doc comment) and Rust's `setPublishRelayList` throws for it.
/// Iterating `RelayCategory.values` here would attempt — and only silently
/// swallow the failure of — the exact publish this design forbids; keeping
/// this as a positive list instead means a future local-only category can
/// never start being force-published just because it was added to the enum.
@visibleForTesting
const publishableRelayCategories = <RelayCategory>[
  RelayCategory.inbox,
  RelayCategory.keyPackage,
];

/// Force-enables the "publish relay list" toggle for every category in
/// [publishableRelayCategories].
///
/// Extracted out of [relayPreferencesServiceProvider] so the exclusion of
/// [RelayCategory.profile] is directly unit-testable against a mock,
/// without spinning up the real FFI-backed provider chain.
@visibleForTesting
Future<void> forceEnablePublishToggles(RelayPreferencesService service) async {
  for (final category in publishableRelayCategories) {
    try {
      await service.setPublishRelayList(category, value: true);
    } on Object catch (e) {
      debugPrint(
        'force-enable publish(${category.name}) failed (non-fatal): '
        '${e.runtimeType}',
      );
    }
  }
}

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
    // republishes kind 30443/10002/10050 to the updated relay set. Every
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

/// Notifier for the user's `KeyPackage` (kind 10002) relay list.
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
    // KeyPackage list changes affect the kind 30443/10002 publisher.
    // Invalidating the marker ALONE is not enough: keyPackagePublisher
    // Provider is a listener-less FutureProvider, so a marker change only
    // marks it dirty; the trailing `read` is what actually drives the
    // rebuild that republishes the KeyPackage (30443) and its relay list
    // (10002) to the updated relay set — matching every other republish
    // call site. Without the read, an added KeyPackage relay would not
    // receive the user's KeyPackage until the next app resume.
    ref
      ..invalidate(relayStatusInvalidatorProvider)
      ..invalidate(keyPackagePublisherInvalidatorProvider)
      ..read(keyPackagePublisherProvider);
  }
}

/// Notifier for the user's Profile-plane (kind-0 lookup/publish) relay list.
///
/// DIVERGES from [InboxRelaysNotifier]/[KeyPackageRelaysNotifier] in ways
/// that matter for the profile/location plane split, not just code shape:
///
/// * Never calls `buildRelayListPublish` / `buildUnpublishRelayList` /
///   `recordPublishedRelayList` / `buildRelayRemovalScrub`. The profile
///   category has no publishable form (Rust throws for it) — there is no
///   relay-list event to build, publish, record, or scrub.
/// * [addRelay] / [removeRelay] are pure local storage writes: no relay-list
///   event is ever built or published for this category, so there is
///   nothing to invalidate `keyPackagePublisherProvider` for — doing so
///   would republish kind 30443/10002/10050 for a change that has nothing
///   to do with any of those lists. Unlike the other two notifiers, this
///   class therefore has no `_invalidateDownstream` step: nothing else
///   currently watches the profile category (`relayStatusProvider` unions
///   only the inbox + KeyPackage lists), and `state = AsyncValue.data(...)`
///   already drives this list's own UI rebuild.
/// * [removeRelay] does NOT run the two-plane NIP-09 removal scrub — that
///   scrub exists to clean up a *published* list's stale copy on a dropped
///   relay, and the profile list is never published anywhere to begin with.
/// * [removeRelay] does NOT call `RelayService.disconnectRelay` — profile
///   lookups/publishes go through a throwaway per-call relay connection
///   (`CircleManagerFfi`'s profile methods), not the persistent
///   `nostr_sdk::Client` the Inbox/KeyPackage categories ride, so there is
///   no long-lived socket to tear down.
class ProfileRelaysNotifier extends AsyncNotifier<List<String>>
    implements RelayCategoryNotifier {
  @override
  Future<List<String>> build() async {
    final service = await ref.read(relayPreferencesServiceProvider.future);
    var list = await service.listRelays(RelayCategory.profile);
    // Self-heal: cover upgrade users who never went through onboarding. On a
    // transient seed failure, fall back to the PROFILE-PLANE compile-time
    // defaults — never `fallbackDefaultRelays` (the account/location-plane
    // list), which would silently reintroduce cross-plane contamination
    // into the very fallback meant to keep the UI usable.
    if (list.isEmpty) {
      try {
        await service.seedDefaultsIfUnseeded();
        list = await service.listRelays(RelayCategory.profile);
      } on Object catch (e) {
        debugPrint('Profile seed failed (using fallback): ${e.runtimeType}');
        list = List<String>.from(fallbackDefaultProfileRelays);
      }
    }
    return list;
  }

  /// Adds a relay and refreshes state.
  ///
  /// Throws [`RelayValidationError`] for malformed URLs. Advisory-only:
  /// succeeds even for a relay already flagged by
  /// [profileRelayContaminationProvider] — the user may have no
  /// uncontaminated alternative, and adding a relay to the profile plane
  /// must never be blocked by a warning.
  @override
  Future<void> addRelay(String url) async {
    final service = await ref.read(relayPreferencesServiceProvider.future);
    await service.addRelay(RelayCategory.profile, url);
    state = AsyncValue.data(await service.listRelays(RelayCategory.profile));
  }

  /// Removes a relay and refreshes state. Returns whether a row was
  /// actually removed. See the class doc for why this skips the scrub and
  /// disconnect steps [InboxRelaysNotifier]/[KeyPackageRelaysNotifier] run.
  @override
  Future<bool> removeRelay(String url) async {
    final service = await ref.read(relayPreferencesServiceProvider.future);
    final removed = await service.removeRelay(RelayCategory.profile, url);
    state = AsyncValue.data(await service.listRelays(RelayCategory.profile));
    return removed;
  }

  /// Adds back any missing curated-pool entries without removing the
  /// user's custom additions.
  @override
  Future<void> restoreDefaults() async {
    final service = await ref.read(relayPreferencesServiceProvider.future);
    await service.restoreDefaults(RelayCategory.profile);
    state = AsyncValue.data(await service.listRelays(RelayCategory.profile));
  }

  /// Destructively resets the list to exactly the curated profile pool. UI
  /// MUST gate behind a confirmation dialog.
  @override
  Future<void> wipeAndReset() async {
    final service = await ref.read(relayPreferencesServiceProvider.future);
    await service.wipeAndResetDefaults(RelayCategory.profile);
    state = AsyncValue.data(await service.listRelays(RelayCategory.profile));
  }
}

/// User's Inbox (kind 10050) relay list.
final inboxRelaysProvider =
    AsyncNotifierProvider<InboxRelaysNotifier, List<String>>(
      InboxRelaysNotifier.new,
    );

/// User's `KeyPackage` (kind 10002) relay list.
final keyPackageRelaysProvider =
    AsyncNotifierProvider<KeyPackageRelaysNotifier, List<String>>(
      KeyPackageRelaysNotifier.new,
    );

/// User's Profile-plane (kind-0 lookup/publish) relay list.
///
/// **Local-only policy** — never published, structurally disjoint from
/// [inboxRelaysProvider] / [keyPackageRelaysProvider]'s relays. See
/// [ProfileRelaysNotifier] and [RelayCategory.profile].
final profileRelaysProvider =
    AsyncNotifierProvider<ProfileRelaysNotifier, List<String>>(
      ProfileRelaysNotifier.new,
    );

/// Relays that already carry this account's location-plane traffic, and are
/// therefore excluded from real profile lookups by the Rust contamination
/// ledger.
///
/// Mirrors the ledger's write sites, one Dart source per Rust
/// `ContaminationSource`:
///
/// * `CircleRouting` — every circle's own kind-445 relay set
///   ([circlesProvider]);
/// * `Inbox` — the Welcome-delivery inbox list (kind 10050,
///   [inboxRelaysProvider]);
/// * `KeyPackage` — the KeyPackage list (kind 30443 plus its kind-10002
///   advertisement, [keyPackageRelaysProvider]);
/// * `Discovery` — the read-only discovery plane ([discoveryRelays]), which
///   serves this account's `KeyPackage` / NIP-65 lookups of *other* users.
///   "This IP asked for pubkey X's KeyPackage" is a stronger co-membership
///   signal than a kind-0 lookup, which is why Rust records it.
///
/// **Advisory only.** Backs the Profile section's per-row contamination
/// warning: a Profile relay whose URL is in this set has already seen this
/// account's encrypted circle traffic, gift wraps or pre-invitation lookups,
/// so adding it to the profile plane too lets that relay's operator join
/// "who this account shares location with" against "whose profile this
/// account looks up" — the exact correlation the profile/location plane
/// split exists to prevent. This provider only ever informs; it never blocks
/// adding or keeping such a relay in [ProfileRelaysNotifier] — the user may
/// have no uncontaminated alternative.
///
/// Deliberately does NOT read the Rust contamination ledger
/// ([`CircleManagerFfi.profilePoolStatus`]'s `excluded` count): that ledger
/// is append-only/historical and — by design — never lets a relay URL cross
/// the FFI boundary (see `ProfilePoolStatusFfi`'s doc), so it cannot back a
/// per-row UI. This provider is therefore a live, Dart-side APPROXIMATION,
/// and it under-warns in exactly two ways:
///
/// 1. **Historical.** A relay that carried this account's traffic in the
///    past but has since been removed from every list above still has a
///    ledger row (contamination is permanent) and no warning here.
/// 2. **Welcome-cascade relays** (`ContaminationSource::Welcome`). The
///    cascade resolves each invitee's delivery relays at send time from
///    *their* inbox / NIP-65 lists and persists the result in no list Dart
///    can read, so there is nothing to union in. This one is unfixable on
///    the Dart side without a new FFI surface that would have to emit relay
///    URLs the ledger deliberately never exports.
///
/// Both asymmetries are safe — they can only under-warn, never over-block —
/// and neither contradicts the fail-closed Rust ledger, which keeps
/// excluding a contaminated relay from real profile lookups regardless of
/// what this provider displays.
///
/// Memoized by Riverpod's `Provider` (recomputed only when [circlesProvider],
/// [inboxRelaysProvider] or [keyPackageRelaysProvider] change, not on every
/// widget build). [discoveryRelays] is not watched because it is a process
/// constant (a shipped list plus an install-once debug override), exactly as
/// on the Rust side.
final profileRelayContaminationProvider = Provider<Set<String>>((ref) {
  final circles = ref.watch(circlesProvider).valueOrNull ?? const [];
  final inbox = ref.watch(inboxRelaysProvider).valueOrNull ?? const [];
  final keyPackage =
      ref.watch(keyPackageRelaysProvider).valueOrNull ?? const [];
  return {
    for (final circle in circles)
      for (final url in circle.relays) normalizeRelayUrlForComparison(url),
    for (final url in inbox) normalizeRelayUrlForComparison(url),
    for (final url in keyPackage) normalizeRelayUrlForComparison(url),
    for (final url in discoveryRelays) normalizeRelayUrlForComparison(url),
  };
});

/// Health of the profile-plane relay pool, as counts only (never URLs).
///
/// Backs the Relay settings page's underflow warning banner: when
/// [ProfilePoolStatus.isUnderflow] is `true`, contamination and/or removals
/// have eaten so many Profile relays that kind-0 lookups are paused
/// fail-closed, and members' cached names/photos stop updating with no
/// other visible signal. Watches [profileRelaysProvider] so editing the
/// Profile relay list (add/remove/restore/wipe, including the banner's own
/// "restore defaults" recovery action) recomputes this immediately, without
/// requiring a manual page refresh.
final profilePoolStatusProvider = FutureProvider<ProfilePoolStatus>((
  ref,
) async {
  // `.future`, not the bare provider: awaiting it means this build doesn't
  // resolve until `profileRelaysProvider` has itself settled, and correctly
  // re-runs whenever that settled value later changes. Watching the bare
  // (`AsyncValue`-typed) provider instead — discarding its "loading" first
  // snapshot — races Riverpod's own dependency tracking: the settle can
  // land *after* this build has already returned its first, stale-input
  // result, and the pending rebuild it schedules then has no listener to
  // drive it (same "listener-less FutureProvider" trap documented on the
  // invalidator providers below), leaving every subsequent
  // `ref.read(profilePoolStatusProvider.future)` hanging forever.
  await ref.watch(profileRelaysProvider.future);
  final service = await ref.read(relayPreferencesServiceProvider.future);
  return service.profilePoolStatus();
});

/// Normalizes a relay URL for set-membership comparison (e.g. the
/// contamination check above).
///
/// Reuses [validateRelayUrl]'s canonicalization — lowercased scheme + host,
/// trailing slash stripped off the root path — the SAME normalization
/// already applied to every relay URL before it is written to storage
/// (`add_relay_sheet.dart` runs it before a URL is ever submitted), so URLs
/// read back from the FFI should already be in this form. Falls through to
/// a bare trim + lowercase for a value [validateRelayUrl] cannot parse (it
/// is a strict *input* validator — e.g. it rejects a bare `wss://` with no
/// host) so comparison stays total instead of silently dropping a malformed
/// stored entry out of the contamination set.
///
/// Public (not `@visibleForTesting`) because `relay_settings_page.dart`
/// calls it directly to key into [profileRelayContaminationProvider]'s set.
String normalizeRelayUrlForComparison(String url) =>
    validateRelayUrl(url).canonicalUrl ?? url.trim().toLowerCase();

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
