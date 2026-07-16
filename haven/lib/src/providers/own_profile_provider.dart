/// Providers for the user's own public Nostr profile (M8 F2).
///
/// Replaces `own_avatar_provider.dart` (deleted at the Wave 6 cutover, D11).
///
/// Security design:
/// - [ownProfileProvider] is cache-first and NEVER throws on connectivity
///   (D7): [ProfileService.getOwnProfile] itself only touches the network
///   when explicitly asked (`forceRefresh`), and this provider additionally
///   swallows any failure — a relay hiccup must never surface as an error
///   state on the Identity page.
/// - [OwnProfileController] mutations ([OwnProfileController.saveDisplayName],
///   [OwnProfileController.setAvatar]) publish UNCONDITIONALLY — there is no
///   consent gate (public-by-default, owner-directed 2026-07-16, matching the
///   White Noise reference app). [OwnProfileController.removeAvatar] is,
///   as before, always allowed (retraction is always allowed).
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
/// Call [OwnProfileController.refresh] for an explicit, forced network
/// re-fetch; it invalidates this provider on success so watchers re-read the
/// refreshed value.
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

/// Notifier that exposes own-profile mutations.
///
/// Non-autoDispose: its state tracks in-flight mutation loading/error
/// only — the primary read path is [ownProfileProvider], read separately
/// by the UI.
class OwnProfileController extends AsyncNotifier<Profile?> {
  @override
  Future<Profile?> build() async {
    // Nothing to pre-load: the display value lives in ownProfileProvider.
    return null;
  }

  /// Fetch-merge-publishes [displayName]/[about] as the user's own profile.
  ///
  /// Publishes UNCONDITIONALLY — there is no consent gate (public-by-default,
  /// owner-directed 2026-07-16). On success, invalidates [ownProfileProvider].
  Future<void> saveDisplayName({
    required String displayName,
    String? about,
  }) async {
    final service = ref.read(profileServiceProvider);

    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final updated = await service.updateOwnProfile(
        displayName: displayName,
        about: about,
      );
      ref.invalidate(ownProfileProvider);
      debugPrint('[Profile] own display name saved');
      return updated;
    });
  }

  /// Sanitizes, uploads, and publishes [raw] as the user's own profile
  /// picture.
  ///
  /// Publishes UNCONDITIONALLY (see [saveDisplayName]). On success,
  /// invalidates [ownProfileProvider].
  Future<void> setAvatar(Uint8List raw) async {
    final service = ref.read(profileServiceProvider);

    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final updated = await service.setOwnAvatar(raw);
      ref.invalidate(ownProfileProvider);
      debugPrint('[Profile] own avatar set');
      return updated;
    });
  }

  /// Removes the user's own published profile picture.
  ///
  /// NOT consent-gated — retraction is always allowed (D1); the Rust core
  /// no-ops if nothing was actually published. On success, invalidates
  /// [ownProfileProvider].
  Future<void> removeAvatar() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final service = ref.read(profileServiceProvider);
      final updated = await service.removeOwnAvatar();
      ref.invalidate(ownProfileProvider);
      debugPrint('[Profile] own avatar removed');
      return updated;
    });
  }

  /// Forces a network re-fetch of the user's own profile.
  ///
  /// NOT consent-gated (reading is always allowed). On success, invalidates
  /// [ownProfileProvider] so watchers re-read the refreshed value.
  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final service = ref.read(profileServiceProvider);
      final updated = await service.getOwnProfile(forceRefresh: true);
      ref.invalidate(ownProfileProvider);
      debugPrint('[Profile] own profile refreshed');
      return updated;
    });
  }
}

/// Provider exposing [OwnProfileController].
final ownProfileControllerProvider =
    AsyncNotifierProvider<OwnProfileController, Profile?>(
      OwnProfileController.new,
    );
