/// Abstract interface for user-configurable relay preferences.
///
/// Provides a mockable API for managing the user's two relay categories
/// (Inbox / `KeyPackage`) plus the privacy toggles that gate publishing
/// of kind 10050 / 10051 events. The production implementation
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
/// Mirrors `RelayType` in haven-core: each variant maps to a distinct
/// Nostr replaceable event kind (10050 for [`RelayCategory.inbox`],
/// 10051 for [`RelayCategory.keyPackage`]). The two lists are stored
/// independently — adding a relay to one does NOT add it to the other.
enum RelayCategory {
  /// Inbox relays (kind 10050, NIP-17) — where Welcomes are delivered.
  inbox,

  /// `KeyPackage` relays (kind 10051, MIP-00) — where this user's MLS
  /// `KeyPackage` events are published.
  keyPackage,
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

  /// Resolved publish targets (deduplicated user list ∪ defaults).
  final List<String> targets;

  /// Numeric Nostr kind (10050 or 10051).
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

  /// Returns the deduplicated union of the user's list and
  /// `defaultRelays` for the given category. UI-only — to publish, use
  /// [`buildRelayListPublish`] which performs the same union internally
  /// and bakes in the toggle check.
  Future<List<String>> publishTargets(RelayCategory category);

  /// Atomically reads the privacy toggle, signs a kind 10050/10051
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
}
