/// Abstract interface for public Nostr profile services.
///
/// Provides a platform-agnostic API for reading and publishing kind-0
/// (NIP-01/NIP-24) public Nostr profile metadata — display name, about
/// text, and profile picture — resolved by Nostr public key. This
/// abstraction allows for easy testing with mock implementations.
///
/// See `docs/PUBLIC_PROFILE_MIGRATION_PLAN.md` (§6.1) for the full design.
/// This migrates Haven away from its previous "no public profiles" model
/// at the owner's explicit direction (CLAUDE.md Rule 10 exception).
/// Publishing is public-by-default and UNCONDITIONAL (owner-directed
/// 2026-07-16, matching the White Noise reference app): there is no consent
/// flag — saving a display name or photo always publishes. That a profile is
/// public is disclosed to the user (onboarding + the Identity settings page),
/// not gated by a toggle in this layer.
///
/// Implementations:
/// - `NostrProfileService` (production, wraps the Rust core) — added in a
///   later wave once the corresponding FFI surface exists.
library;

import 'package:flutter/foundation.dart';

/// Exception thrown when profile operations fail.
class ProfileServiceException implements Exception {
  /// Creates a [ProfileServiceException] with the given message.
  const ProfileServiceException(this.message);

  /// The error message.
  final String message;

  @override
  String toString() => 'ProfileServiceException: $message';
}

/// A public Nostr profile (kind-0 metadata), resolved by public key.
///
/// Mirrors a subset of NIP-01/NIP-24 `kind:0` fields plus a locally
/// cached profile picture. Deliberately has **no picture URL field**: per
/// decision D2 of the migration plan, picture URLs never cross the FFI
/// boundary — only already-downloaded, sha256-verified bytes do. This
/// keeps the `Image.network` ban meaningful (see
/// `test/security/image_network_ban_test.dart`) and never hands Flutter
/// an attacker-controlled URL to fetch.
@immutable
class Profile {
  /// Creates a [Profile].
  const Profile({
    required this.pubkeyHex,
    this.name,
    this.displayName,
    this.about,
    this.pictureBytes,
    this.pictureHash,
    this.knownAt,
  });

  /// The profile owner's Nostr public key (hex format).
  final String pubkeyHex;

  /// Raw NIP-01 `name` field, if set.
  final String? name;

  /// NIP-24 `display_name` field, if set.
  ///
  /// Preferred over [name] for display — see the four-tier precedence
  /// resolver (local nickname → `display_name` → `name` → npub + initials)
  /// added alongside `member_display.dart` in a later wave (D6).
  final String? displayName;

  /// NIP-01 `about` bio text, if set.
  final String? about;

  /// Decoded, re-encoded profile picture bytes, or `null` if none is
  /// cached.
  ///
  /// Already sanitized (EXIF/GPS/XMP stripped, re-encoded) and
  /// sha256-verified by the Rust core before ever reaching Dart. Never a
  /// URL — see the class doc.
  final Uint8List? pictureBytes;

  /// Content hash of [pictureBytes] (matches the Blossom `sha256` of the
  /// downloaded blob).
  ///
  /// Used to key decode caches and detect a picture change without
  /// re-decoding image bytes. `null` when [pictureBytes] is `null`.
  final String? pictureHash;

  /// When this profile snapshot was last resolved from a kind-0 fetch
  /// (the Rust cache row's `fetched_at`), or `null` if this pubkey has
  /// never been fetched (cache state `Unknown`).
  final DateTime? knownAt;

  /// Returns a copy of this profile with the given fields overridden.
  ///
  /// Following this class's existing value-class convention (see
  /// `MemberLocation.copyWith` in `location_sharing_service.dart`), a
  /// `null` argument means "keep the current value" — pass an empty
  /// string to clear a text field. This cannot null out [pictureBytes] /
  /// [pictureHash]; construct a new [Profile] directly for that case
  /// (e.g. an avatar-removal result).
  Profile copyWith({
    String? name,
    String? displayName,
    String? about,
    Uint8List? pictureBytes,
    String? pictureHash,
    DateTime? knownAt,
  }) {
    return Profile(
      pubkeyHex: pubkeyHex,
      name: name ?? this.name,
      displayName: displayName ?? this.displayName,
      about: about ?? this.about,
      pictureBytes: pictureBytes ?? this.pictureBytes,
      pictureHash: pictureHash ?? this.pictureHash,
      knownAt: knownAt ?? this.knownAt,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Profile &&
          runtimeType == other.runtimeType &&
          pubkeyHex == other.pubkeyHex &&
          name == other.name &&
          displayName == other.displayName &&
          about == other.about &&
          pictureHash == other.pictureHash &&
          knownAt == other.knownAt &&
          listEquals(pictureBytes, other.pictureBytes);

  @override
  int get hashCode =>
      Object.hash(pubkeyHex, name, displayName, about, pictureHash, knownAt);

  @override
  String toString() =>
      'Profile(pubkeyHex: ${pubkeyHex.substring(0, 8)}..., '
      'hasPicture: ${pictureBytes != null})';
}

/// Abstract interface for public Nostr profile services.
///
/// Manages the user's own public profile (kind-0 name/about/photo) and
/// resolves other circle members' public profiles by pubkey.
///
/// **Publishing is unconditional**: [updateOwnProfile] and [setOwnAvatar] are
/// the methods that author a NEW public event, and neither is gated — there
/// is no consent flag to check (public-by-default, owner-directed
/// 2026-07-16). Every method's allow-status:
/// - Reads ([getOwnProfile], [getMemberProfile], [refreshMemberProfiles])
///   are always allowed — another client's already-published data is
///   public regardless of anything Haven does.
/// - Writes ([updateOwnProfile], [setOwnAvatar]) always publish.
/// - Retraction ([removeOwnAvatar]) is always allowed, but is a no-op
///   unless something was actually published; it must never create a
///   public footprint for a pubkey that never published.
abstract class ProfileService {
  /// Returns the user's own profile, or `null` if never fetched/published.
  ///
  /// Resolves from the local cache first. Per decision D7, this should
  /// never throw purely because the network is unavailable when a cached
  /// value exists — pass [forceRefresh] to force a network re-fetch; a
  /// background refresh augments the cache and callers should
  /// invalidate/re-read afterward rather than await a slow network
  /// round-trip inline.
  ///
  /// Always allowed (a read).
  ///
  /// Throws [ProfileServiceException] on a genuine failure.
  Future<Profile?> getOwnProfile({bool forceRefresh = false});

  /// Fetch-merge-publishes the user's own display name and about text.
  ///
  /// Fetches the freshest known kind-0 metadata, mutates only
  /// [displayName] and [about] — leaving every other field (including any
  /// `custom` NIP-24 field set by another client, e.g. `lud16`) untouched
  /// — and republishes the full object under the identity key. Pass
  /// `about: null` to leave the existing about text unchanged, or
  /// `about: ''` to clear it.
  ///
  /// Always publishes — there is no consent gate (see class doc).
  ///
  /// Throws [ProfileServiceException] if the fetch/merge/publish pipeline
  /// fails, or the relay rejects the event (`OK=false`).
  Future<Profile> updateOwnProfile({
    required String displayName,
    String? about,
  });

  /// Sanitizes, uploads (to Blossom), and publishes [raw] as the user's
  /// own profile picture.
  ///
  /// EXIF/GPS/XMP metadata is stripped and the image re-encoded before
  /// upload. The returned [Profile.pictureBytes] are the re-encoded,
  /// locally cached bytes — never the raw input bytes.
  ///
  /// Always publishes — there is no consent gate (see class doc).
  ///
  /// Throws [ProfileServiceException] if sanitization fails, the Blossom
  /// upload fails, or the kind-0 republish fails.
  Future<Profile> setOwnAvatar(Uint8List raw);

  /// Removes the user's own published profile picture.
  ///
  /// Always allowed — a no-op (returns the current profile unchanged)
  /// unless a picture was actually published; must never mint a first
  /// public kind-0 event for a pubkey that never published.
  ///
  /// Throws [ProfileServiceException] on a genuine failure.
  Future<Profile> removeOwnAvatar();

  /// Returns a single circle member's profile, resolved by [pubkeyHex],
  /// or `null` if never fetched.
  ///
  /// Resolves from the local cache; pass [forceRefresh] to force a
  /// network re-fetch for just this pubkey. To refresh many members at
  /// once (e.g. on circle open), prefer [refreshMemberProfiles], which
  /// batches into a single relay request instead of one per member.
  ///
  /// Always allowed (a read) — another pubkey's already-published data is
  /// public regardless of anything Haven's own UI does.
  ///
  /// Throws [ProfileServiceException] on a genuine failure.
  Future<Profile?> getMemberProfile(
    String pubkeyHex, {
    bool forceRefresh = false,
  });

  /// Batch-refreshes profiles for [pubkeyHexes] in a single relay fetch.
  ///
  /// Callers should pass the **union** of all known member pubkeys across
  /// every circle — never a clean per-circle roster partition, which
  /// would hand the relay exact co-membership clusters (migration plan
  /// §1.7). Pass [force] to bypass the TTL cache and re-fetch even fresh
  /// entries.
  ///
  /// Returns a map of pubkeyHex to the resolved [Profile] for every
  /// pubkey with a cache entry after the refresh; a pubkey that was never
  /// found on any relay is recorded `Unknown` on the Rust side and is
  /// simply absent from the result — not an error.
  ///
  /// Always allowed (a read).
  ///
  /// Throws [ProfileServiceException] on a genuine failure. Implementations
  /// called from a best-effort background refresh should generally prefer
  /// to swallow partial per-pubkey failures and return whatever resolved.
  Future<Map<String, Profile>> refreshMemberProfiles(
    List<String> pubkeyHexes, {
    bool force = false,
  });
}
