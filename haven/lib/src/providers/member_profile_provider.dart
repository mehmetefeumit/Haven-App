/// Provider for a single circle member's public Nostr profile (M8 F2).
///
/// Replaces `member_avatar_provider.dart` (deleted at the Wave 6 cutover,
/// D11). Unlike the old avatar provider, this is keyed by a **plain
/// `String pubkeyHex`** —
/// per D6/plan §6.2, public profiles are resolved by pubkey alone, with no
/// `mlsGroupId` component: the same pubkey resolves to the same profile
/// across every circle the user shares with that member.
///
/// Security design:
/// - autoDispose: bytes are released when the provider goes unwatched.
/// - Errors are swallowed (never propagated) — a widget watching a member's
///   profile should degrade to the npub/initials fallback, never show an
///   error state.
/// - Re-fetches bytes from the encrypted Rust store per use (Rule 9).
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/profile_service.dart';

/// autoDispose family provider for a circle member's public profile.
///
/// Returns `null` when the member has never been fetched/published, or on
/// any error. Invalidate the whole family (e.g. via
/// [`memberProfileRefreshProvider`]) after a batch refresh to trigger a
/// re-fetch of every currently-watched member.
///
/// Usage:
/// ```dart
/// final profile = ref.watch(memberProfileProvider(member.pubkey));
/// ```
final AutoDisposeFutureProviderFamily<Profile?, String> memberProfileProvider =
    FutureProvider.autoDispose.family<Profile?, String>((ref, pubkeyHex) async {
  final service = ref.watch(profileServiceProvider);
  try {
    return await service.getMemberProfile(pubkeyHex);
  } on Object catch (e) {
    debugPrint('[Profile] memberProfileProvider: ${e.runtimeType}');
    return null;
  }
});
