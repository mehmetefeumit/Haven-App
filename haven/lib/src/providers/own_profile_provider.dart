/// Read-side provider for the user's own public Nostr profile (M8 F2).
///
/// Replaces `own_avatar_provider.dart` (deleted at the Wave 6 cutover, D11).
/// The mutation side (`OwnProfileController`, deleted — profile-latency
/// migration) is gone: local saves now go straight through
/// [ProfileService.updateOwnProfile] / [ProfileService.setOwnAvatar] /
/// [ProfileService.removeOwnAvatar] from the widget layer (they return in
/// milliseconds, so an `AsyncNotifier` loading wrapper added nothing), and
/// publishing is triggered separately via
/// `providers/profile_sync_provider.dart`.
///
/// Security design:
/// - [ownProfileProvider] is cache-first and NEVER throws on connectivity
///   (D7): [ProfileService.getOwnProfile] itself only touches the network
///   when explicitly asked (`forceRefresh`), and this provider additionally
///   swallows any failure — a relay hiccup must never surface as an error
///   state on the Identity page.
/// - Local saves publish UNCONDITIONALLY — there is no consent gate
///   (public-by-default, owner-directed 2026-07-16, matching the White Noise
///   reference app). Retraction ([ProfileService.removeOwnAvatar]) is, as
///   before, always allowed.
/// - Bytes are re-fetched per use from the encrypted Rust store (Rule 9);
///   this provider holds no long-lived secret material.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/profile_service.dart';

/// Resolves the user's own public profile.
///
/// Returns `null` before an identity exists, when no profile has ever been
/// fetched/published, or on ANY failure (including a genuine
/// [ProfileServiceException]) — connectivity must never surface as an error
/// state here (D7). autoDispose releases the cached bytes when unwatched.
///
/// Callers that mutate the profile (`updateOwnProfile`/`setOwnAvatar`/
/// `removeOwnAvatar`) must `ref.invalidate(ownProfileProvider)` themselves on
/// success so watchers re-read the refreshed value — there is no controller
/// to do it for them.
final AutoDisposeFutureProvider<Profile?> ownProfileProvider =
    FutureProvider.autoDispose<Profile?>((ref) async {
  final identity = await ref.watch(identityProvider.future);
  if (identity == null) return null;

  final service = ref.watch(profileServiceProvider);
  try {
    return await service.getOwnProfile();
  } on Object catch (e) {
    debugPrint('[Profile] ownProfileProvider: ${e.runtimeType}');
    return null;
  }
});
