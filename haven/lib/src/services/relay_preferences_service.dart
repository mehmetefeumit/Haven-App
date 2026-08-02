/// Abstract interface for user-configurable relay preferences.
///
/// Provides a mockable API for managing the user's two relay categories
/// (Inbox / `KeyPackage`) plus the privacy toggles that gate publishing
/// of kind 10050 / 10002 events. The production implementation
/// (`NostrRelayPreferencesService`) delegates to `CircleManagerFfi`'s
/// storage methods; tests inject mocks via Riverpod.
///
/// All write operations are atomic at the Rust storage layer. The Dart
/// surface intentionally returns simple types (`List<String>`, `bool`)
/// and raises typed exceptions ([`RelayValidationError`],
/// [`RelayPreferencesException`]) so the UI never sees raw FFI strings.
library;

import 'package:flutter/foundation.dart';

/// Category of relay preference managed per user.
///
/// Mirrors `RelayType` in haven-core: [`RelayCategory.inbox`] and
/// [`RelayCategory.keyPackage`] each map to a distinct Nostr replaceable
/// event kind (10050 / 10002 respectively); [`RelayCategory.profile`] maps
/// to none — it is a **local-only** policy list that is never published.
/// All three lists are stored independently — adding a relay to one does
/// NOT add it to another.
enum RelayCategory {
  /// Inbox relays (kind 10050, NIP-17) — where Welcomes are delivered.
  inbox,

  /// `KeyPackage` relays (kind 10002, MIP-00) — where this user's MLS
  /// `KeyPackage` events are published.
  keyPackage,

  /// Profile-plane relays (kind-0 lookups + own-profile publish).
  ///
  /// **Local-only — structurally unpublishable.** Disjoint by design from
  /// every relay carrying this account's kind-445/kind-1059 traffic, so a
  /// relay operator who already sees the encrypted location-plane traffic
  /// cannot also be handed a signed pointer to the profile plane. Never
  /// pass this to [`getPublishRelayList`], [`setPublishRelayList`],
  /// [`buildRelayListPublish`], [`buildUnpublishRelayList`], or
  /// [`buildRelayRemovalScrub`] — the Rust side throws for all five.
  profile,
}

/// Thrown when a user-supplied relay URL is invalid.
///
/// The [`message`] is short and presentable in the UI directly. The Rust
/// validator is the authoritative gate; this exception wraps its rejection
/// reason after stripping any internal detail.
@immutable
class RelayValidationError implements Exception {
  /// Creates a [RelayValidationError] with the given user-facing message.
  const RelayValidationError(this.message);

  /// User-facing error text.
  final String message;

  @override
  String toString() => 'RelayValidationError: $message';
}

/// Thrown for non-validation failures of relay preference operations
/// (database errors, FFI failures).
@immutable
class RelayPreferencesException implements Exception {
  /// Creates a [RelayPreferencesException] with the given message.
  const RelayPreferencesException(this.message);

  /// Generic error message safe to display to the user.
  final String message;

  @override
  String toString() => 'RelayPreferencesException: $message';
}

/// Health of the profile-plane relay pool, as **counts only**.
///
/// Mirrors `ProfilePoolStatusFfi` on the Dart side of the service
/// abstraction (this file deliberately does not import `dart:ffi` types —
/// see the library doc). Deliberately carries no relay URLs: a URL list
/// reaching this far up the stack would give the UI layer (and any
/// crash/analytics sink it feeds) a copy of which relays this install
/// resolves profiles from, undoing the point of never publishing that list.
@immutable
class ProfilePoolStatus {
  /// Creates a [ProfilePoolStatus].
  const ProfilePoolStatus({
    required this.configured,
    required this.excluded,
    required this.usable,
    required this.isUnderflow,
  });

  /// Distinct relays configured for the profile category (curated pool
  /// unioned with the user's own additions).
  final int configured;

  /// How many of those are excluded because they also carry this account's
  /// location-plane traffic (the append-only contamination ledger).
  final int excluded;

  /// Relays that survive exclusion and may serve kind-0 lookups.
  final int usable;

  /// `true` when too few survive to operate the plane. Profile lookups are
  /// then skipped entirely (fail-closed — never falls back onto a location
  /// relay), so the roster shows cached names only until the user restores
  /// or adds an uncontaminated profile relay.
  final bool isUnderflow;
}

/// Outcome of building a relay-list publish request.
///
/// Returned by [`RelayPreferencesService.buildRelayListPublish`]. When
/// [`suppressed`] is `true`, the user's privacy toggle is OFF for this
/// category and the caller MUST NOT publish anything. When `false`, the
/// caller publishes [`eventJson`] to the [`targets`] returned here and
/// then calls [`RelayPreferencesService.recordPublishedRelayList`] with
/// the corresponding `eventIdHex`, `kind`, and `createdAtSecs`.
@immutable
class BuiltRelayListPublish {
  /// Creates a [BuiltRelayListPublish].
  const BuiltRelayListPublish({
    required this.suppressed,
    this.eventJson,
    this.eventIdHex,
    this.targets = const [],
    this.kind,
    this.createdAtSecs,
  });

  /// `true` when the privacy toggle is OFF — caller must not publish.
  final bool suppressed;

  /// Signed event JSON, ready for `RelayService.publishEvent`. Non-null
  /// only when [`suppressed`] is `false`.
  final String? eventJson;

  /// Hex-encoded event id; pass to [`recordPublishedRelayList`] after
  /// successful publication so the unpublish path can issue NIP-09.
  final String? eventIdHex;

  /// Resolved publish targets — the user's own configured relays only,
  /// deduplicated. Two-plane model: no public-default union, so a private
  /// relay is never published to a public relay.
  final List<String> targets;

  /// Numeric Nostr kind (10050 or 10002).
  final int? kind;

  /// Unix-seconds `created_at` from the signed event. Pass back to
  /// [`recordPublishedRelayList`] so the recorded `published_at` matches
  /// what relays observe — this anchors the next unpublish's clock-skew
  /// arithmetic.
  final int? createdAtSecs;
}

/// Outcome of building an unpublish request for a relay list category.
///
/// Returned by [`RelayPreferencesService.buildUnpublishRelayList`]. The
/// caller publishes [`replacementEventJson`] (always present unless
/// [`suppressed`]) and, if non-null, also publishes
/// [`deletionEventJson`] (NIP-09 best effort).
@immutable
class BuiltUnpublish {
  /// Creates a [BuiltUnpublish].
  const BuiltUnpublish({
    required this.suppressed,
    this.replacementEventJson,
    this.deletionEventJson,
    this.targets = const [],
  });

  /// `true` when nothing needs to be published.
  final bool suppressed;

  /// Empty-replacement event JSON.
  final String? replacementEventJson;

  /// Best-effort NIP-09 (kind 5) deletion event JSON. `null` when no
  /// prior publication is on record.
  final String? deletionEventJson;

  /// Publish targets for both events.
  final List<String> targets;
}

/// Abstract interface for relay preference operations.
///
/// All methods are async and may throw [`RelayValidationError`] or
/// [`RelayPreferencesException`].
abstract class RelayPreferencesService {
  /// Returns the user's relays for one category, in insertion order.
  Future<List<String>> listRelays(RelayCategory category);

  /// Adds a relay to one category. Idempotent: duplicate adds are silent
  /// no-ops. Normalizes the URL.
  ///
  /// Throws [`RelayValidationError`] for malformed URLs and `ws://` input.
  Future<void> addRelay(RelayCategory category, String url);

  /// Removes a relay from one category. Returns `true` when a row was
  /// removed; `false` when the URL was not present.
  ///
  /// Throws [`RelayValidationError`] when the URL is invalid OR when
  /// removal would leave the category empty.
  Future<bool> removeRelay(RelayCategory category, String url);

  /// Adds any missing default relays for the category (non-destructive).
  /// Existing user-added relays are preserved.
  Future<void> restoreDefaults(RelayCategory category);

  /// Wipes the category and re-inserts defaults. **Destructive** — UI
  /// MUST gate this behind a confirmation dialog.
  Future<void> wipeAndResetDefaults(RelayCategory category);

  /// Seeds default relays into both categories on first launch.
  /// Idempotent — subsequent calls observe the seeding sentinel and
  /// return immediately.
  Future<void> seedDefaultsIfUnseeded();

  /// Returns whether the user wants to publish their relay list for
  /// the given category. Defaults to `true` when never set.
  Future<bool> getPublishRelayList(RelayCategory category);

  /// Sets whether the user wants to publish their relay list for the
  /// given category.
  Future<void> setPublishRelayList(
    RelayCategory category, {
    required bool value,
  });

  /// Returns the deduplicated publish targets for the given category — the
  /// user's own configured relays only (no public-default union, so a
  /// private relay never leaks). UI-only — to publish, use
  /// [`buildRelayListPublish`] which resolves the same targets internally
  /// and bakes in the toggle check.
  Future<List<String>> publishTargets(RelayCategory category);

  /// Atomically reads the privacy toggle, signs a kind 10050/10002
  /// event, and resolves the publish targets. The only path through
  /// which the UI may publish a relay list event.
  Future<BuiltRelayListPublish> buildRelayListPublish({
    required Uint8List identitySecretBytes,
    required RelayCategory category,
  });

  /// Records a successful publication so the unpublish path can later
  /// issue a NIP-09 deletion referencing the event id.
  ///
  /// `publishedAtSecs` MUST be the signed event's `created_at` (i.e.
  /// [`BuiltRelayListPublish.createdAtSecs`]) — using a freshly-fetched
  /// local timestamp instead would weaken the next unpublish's
  /// clock-skew defense.
  Future<void> recordPublishedRelayList({
    required String identityPubkeyHex,
    required int kind,
    required String eventIdHex,
    required int publishedAtSecs,
  });

  /// Builds the events needed to unpublish a relay list category.
  Future<BuiltUnpublish> buildUnpublishRelayList({
    required Uint8List identitySecretBytes,
    required RelayCategory category,
  });

  /// Builds a best-effort NIP-09 deletion to scrub a removed relay's stale
  /// copy of the user's relay list (two-plane removal hygiene).
  ///
  /// When the user removes relay(s) from a category, the new (smaller) list
  /// is republished to the kept relays, but the dropped relays still hold the
  /// previous event — which may name a private relay. The returned deletion
  /// (in [`BuiltUnpublish.deletionEventJson`], with `replacementEventJson`
  /// null) should be published to [`BuiltUnpublish.targets`] (the dropped
  /// relays) so cooperative relays drop that stale copy.
  ///
  /// MUST be called BEFORE republishing the new list. Returns a `suppressed`
  /// result with empty targets when nothing was ever published for this
  /// category (the dropped relays never received the list).
  Future<BuiltUnpublish> buildRelayRemovalScrub({
    required Uint8List identitySecretBytes,
    required RelayCategory category,
    required List<String> droppedRelays,
  });

  /// Health of the profile-plane relay pool, as counts only (never URLs).
  ///
  /// Lets the UI show "profile lookups are paused" instead of a silently
  /// stale roster when contamination and/or removals have eaten the pool.
  Future<ProfilePoolStatus> profilePoolStatus();

  /// Restores the curated profile pool non-destructively (adds back any
  /// missing curated entry; keeps the user's own additions).
  ///
  /// The recovery action for a pool that has underflowed — distinct from
  /// [restoreDefaults], which is the generic per-category top-up used by
  /// this page's section-level "Restore defaults" buttons. Both end up
  /// calling the same Rust storage operation for
  /// [RelayCategory.profile], but this method exists as its own named
  /// entry point so the underflow-recovery call site does not have to
  /// route through the category-generic API.
  Future<void> restoreDefaultProfileRelays();
}
