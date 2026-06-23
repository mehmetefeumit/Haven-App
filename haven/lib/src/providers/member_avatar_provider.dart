/// Provider for circle-member avatar thumbnails (M2 — encrypted broadcast).
///
/// Security design:
/// - autoDispose: bytes are released when the provider goes unwatched.
/// - Keyed by (mlsGroupId hex, pubkey hex) — the same key Rust uses.
/// - Holds content-hash in the cache entry, NOT bytes.
/// - Re-fetches bytes from the encrypted Rust store per use (CLAUDE Rule 9).
/// - No disk cache: Image.memory only.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/providers/service_providers.dart';

/// Stable key for the member-avatar thumbnail provider family.
///
/// Equality and hashCode are based on circle-id hex + pubkey hex so
/// the provider correctly re-fetches when either changes.
@immutable
class MemberAvatarKey {
  /// Creates a [MemberAvatarKey].
  const MemberAvatarKey({
    required this.mlsGroupId,
    required this.pubkeyHex,
  });

  /// MLS group ID bytes for the circle.
  final List<int> mlsGroupId;

  /// Member pubkey hex.
  final String pubkeyHex;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MemberAvatarKey &&
          runtimeType == other.runtimeType &&
          pubkeyHex == other.pubkeyHex &&
          _listEquals(mlsGroupId, other.mlsGroupId);

  @override
  int get hashCode => Object.hash(
        Object.hashAll(mlsGroupId),
        pubkeyHex,
      );

  static bool _listEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// autoDispose provider family for a circle member's avatar thumbnail bytes.
///
/// Returns `null` when the member has no avatar or on any error.
/// Invalidate this provider (or its family) when a new avatar is received
/// (`AvatarIngestResult.complete == true`) to trigger a re-fetch.
///
/// Usage:
/// ```dart
/// final bytes = ref.watch(
///   memberAvatarThumbnailProvider(
///     MemberAvatarKey(mlsGroupId: circle.mlsGroupId, pubkeyHex: member.pubkey),
///   ),
/// );
/// ```
final AutoDisposeFutureProviderFamily<Uint8List?, MemberAvatarKey>
    memberAvatarThumbnailProvider = FutureProvider.autoDispose
        .family<Uint8List?, MemberAvatarKey>((ref, key) async {
  final service = ref.read(circleServiceProvider);
  try {
    return await service.getMemberAvatarThumbnail(
      mlsGroupId: key.mlsGroupId,
      pubkey: key.pubkeyHex,
    );
  } on Object catch (e) {
    debugPrint('[MemberAvatar] thumbnail fetch failed: ${e.runtimeType}');
    return null;
  }
});
