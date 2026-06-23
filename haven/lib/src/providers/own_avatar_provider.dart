/// Providers for own-avatar management (M1 — local + M2 — network broadcast
/// + M3 — epoch re-share + periodic anti-entropy).
///
/// Security design:
/// - Notifier state holds the content-hash string only, NOT raw bytes.
/// - Bytes are fetched per use from the encrypted Rust store (CLAUDE Rule 9).
/// - The FutureProvider is autoDispose so bytes are released when unwatched.
/// - No disk cache: Image.memory only.
/// - Publish-on-change (M2): after local store succeeds, best-effort publishes
///   kind-445 avatar events to all accepted circles. Relay failures do NOT
///   block or throw to the UI.
/// - Epoch re-share (M3): when the evolution poller observes groupUpdated==true
///   for a circle, it calls [OwnAvatarController.epochReshareForCircle] which
///   publishes a SHORT BURST (all chunks back-to-back) into that single circle.
///   Only fires when the user has an avatar set. Best-effort; never throws to UI.
/// - Periodic anti-entropy (M3): `reshareToAllCircles` is called by the
///   anti-entropy scheduler every X hours (24 h normal / 72 h data-saver),
///   jittered. Anchored in `avatarAntiEntropyProvider`.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';

/// Fetches the current user's own avatar thumbnail bytes.
///
/// Returns `null` when no avatar is set or the identity is not loaded.
/// autoDispose ensures bytes are released when the provider goes unused.
final AutoDisposeFutureProvider<Uint8List?> ownAvatarProvider =
    FutureProvider.autoDispose<Uint8List?>((ref) async {
  // Get the identity — we need the pubkey to key the avatar store.
  final identityAsync = await ref.watch(identityProvider.future);
  if (identityAsync == null) return null;

  final service = ref.read(circleServiceProvider);
  return service.getMyAvatarThumbnail(identityAsync.pubkeyHex);
});

/// State held by [ownAvatarControllerProvider].
///
/// Holds the content-hash of the currently stored avatar (null = none),
/// NOT the raw bytes. Keeps the notifier memory footprint tiny.
class OwnAvatarState {
  /// Creates [OwnAvatarState].
  const OwnAvatarState({this.contentHashHex, this.isLoading = false});

  /// SHA-256 hex of the current avatar's canonical bytes, or null.
  final String? contentHashHex;

  /// True while a set/remove operation is in progress.
  final bool isLoading;

  /// Returns a copy with the given fields replaced.
  OwnAvatarState copyWith({String? contentHashHex, bool? isLoading}) {
    return OwnAvatarState(
      contentHashHex: contentHashHex ?? this.contentHashHex,
      isLoading: isLoading ?? this.isLoading,
    );
  }
}

/// Notifier that exposes avatar mutations.
///
/// Calls [CircleService] avatar methods, then invalidates
/// [ownAvatarProvider] so the UI refreshes from the encrypted store.
class OwnAvatarController extends AsyncNotifier<OwnAvatarState> {
  @override
  Future<OwnAvatarState> build() async {
    // Nothing to pre-load: the display bytes live in ownAvatarProvider.
    return const OwnAvatarState();
  }

  /// Picks, processes, and stores [raw] bytes as the own avatar.
  ///
  /// All EXIF stripping, downscaling, and encryption happen in Rust.
  /// On success, invalidates [ownAvatarProvider] so watchers refresh,
  /// then best-effort publishes kind-445 avatar-share events to all
  /// accepted circles (M2 on-change trigger). Relay failures do NOT
  /// throw to the UI.
  ///
  /// Throws [CircleServiceException] on failure.
  Future<void> pickAndSet(Uint8List raw) async {
    final identity = await ref.read(identityProvider.future);
    if (identity == null) {
      throw const CircleServiceException('No identity available');
    }

    state = const AsyncLoading();

    state = await AsyncValue.guard(() async {
      final service = ref.read(circleServiceProvider);
      final meta = await service.setMyAvatar(identity.pubkeyHex, raw);
      // Invalidate the display provider so all widgets re-fetch bytes.
      ref.invalidate(ownAvatarProvider);
      debugPrint('[Avatar] set successfully');
      // M2: publish to all circles best-effort (do not await — UI must
      // not block on relay connectivity).
      _publishAvatarShareToAllCircles(identity.pubkeyHex);
      return OwnAvatarState(contentHashHex: meta.contentHashHex);
    });
  }

  /// Removes the own avatar.
  ///
  /// On success, invalidates [ownAvatarProvider].
  /// Best-effort publishes a tombstone clear event to all circles (M2).
  ///
  /// The clear events are BUILT AND PUBLISHED before `clearMyAvatar` is
  /// called so that Rust can derive the tombstone version from the currently
  /// stored own-avatar version + 1. Relay publish failures are swallowed —
  /// they must not skip the local clear. The build step is awaited inline so
  /// that the ordering invariant is verifiable and testable.
  ///
  /// Throws [CircleServiceException] on failure.
  Future<void> remove() async {
    final identity = await ref.read(identityProvider.future);
    if (identity == null) {
      throw const CircleServiceException('No identity available');
    }

    state = const AsyncLoading();

    state = await AsyncValue.guard(() async {
      final service = ref.read(circleServiceProvider);
      final relayService = ref.read(relayServiceProvider);
      final intervalSecs =
          kLocationPublishMaxInterval.inSeconds + kTtlNetworkBufferSeconds;

      // M2: build + publish tombstone to all circles BEFORE clearing locally
      // so Rust can derive the tombstone version from the stored version + 1.
      // Relay failures are swallowed so the local clear always proceeds.
      // The build+publish loop is awaited inline to enforce ordering.
      try {
        final circles = await ref.read(circlesProvider.future);
        for (final circle in circles) {
          if (circle.membershipStatus != MembershipStatus.accepted) continue;
          try {
            final eventJson = await service.buildAvatarClearEvent(
              mlsGroupId: circle.mlsGroupId,
              senderPubkeyHex: identity.pubkeyHex,
              updateIntervalSecs: intervalSecs,
            );
            await relayService.publishEvent(
              eventJson: eventJson,
              relays: circle.relays,
            );
            debugPrint('[Avatar] published clear to circle');
          } on Object catch (e) {
            // Best-effort: relay/build failures must not block the local clear.
            debugPrint('[Avatar] clear publish failed: ${e.runtimeType}');
          }
        }
      } on Object catch (e) {
        // If the circles fetch itself fails, log and continue to local clear.
        debugPrint('[Avatar] remove: circle fetch failed: ${e.runtimeType}');
      }

      await service.clearMyAvatar(identity.pubkeyHex);
      ref.invalidate(ownAvatarProvider);
      debugPrint('[Avatar] removed');
      return const OwnAvatarState();
    });
  }

  // -------------------------------------------------------------------------
  // M3 — Epoch re-share (§5.6)
  // -------------------------------------------------------------------------

  /// Re-shares the own avatar into a SINGLE circle as a SHORT BURST.
  ///
  /// Called by the evolution poller when it observes `groupUpdated == true`
  /// for a specific circle. All chunk events are published back-to-back (not
  /// trickled at location cadence) so that a late-joining member receives the
  /// avatar within one polling window (§5.6 corrected cadence).
  ///
  /// Privacy note: an epoch advance is already a relay-visible commit, so
  /// correlating this burst with it leaks nothing new.
  ///
  /// Only fires when the user has an avatar set. Best-effort; relay failures
  /// are swallowed to [debugPrint] and never propagate to the caller or the UI.
  void epochReshareForCircle(List<int> mlsGroupId) {
    // Fire and forget.
    Future(() async {
      try {
        final identity = await ref.read(identityProvider.future);
        if (identity == null) {
          debugPrint('[Avatar] epochReshare: no identity — skipped');
          return;
        }
        final service = ref.read(circleServiceProvider);

        // Short-circuit if no avatar is stored — do not publish empty/clear.
        // Fetch the thumbnail to check existence; the bytes are not used here
        // but this is the same approach as the anti-entropy path and correctly
        // handles the case where the app was restarted (controller state has
        // no contentHashHex until pickAndSet is called in-session).
        final thumbnail = await service.getMyAvatarThumbnail(
          identity.pubkeyHex,
        );
        if (thumbnail == null) {
          debugPrint('[Avatar] epochReshare: no avatar set — skipped');
          return;
        }

        // Resolve the circle's relay list. Skip if the circle is gone or
        // no longer accepted (user left / was removed mid-poll).
        final List<String> relays;
        try {
          final circles = await ref.read(circlesProvider.future);
          final circle = circles.where(
            (c) =>
                c.membershipStatus == MembershipStatus.accepted &&
                _mlsGroupIdEquals(c.mlsGroupId, mlsGroupId),
          ).firstOrNull;
          if (circle == null) {
            debugPrint(
              '[Avatar] epochReshare: circle not found / not accepted — '
              'skipped',
            );
            return;
          }
          relays = circle.relays;
        } on Object catch (e) {
          debugPrint(
            '[Avatar] epochReshare: circle lookup failed: ${e.runtimeType}',
          );
          return;
        }

        final relayService = ref.read(relayServiceProvider);
        final intervalSecs =
            kLocationPublishMaxInterval.inSeconds + kTtlNetworkBufferSeconds;

        final events = await service.buildAvatarShareEvents(
          mlsGroupId: mlsGroupId,
          senderPubkeyHex: identity.pubkeyHex,
          updateIntervalSecs: intervalSecs,
        );
        if (events.isEmpty) {
          debugPrint('[Avatar] epochReshare: no events built for circle');
          return;
        }
        // Publish back-to-back (burst) — NOT at location cadence.
        for (final eventJson in events) {
          await relayService.publishEvent(eventJson: eventJson, relays: relays);
        }
        debugPrint(
          '[Avatar] epochReshare: published ${events.length} chunk(s) '
          'for circle (burst)',
        );
      } on Object catch (e) {
        // Best-effort: never propagate to caller or evolution poller.
        debugPrint('[Avatar] epochReshare failed: ${e.runtimeType}');
      }
    });
  }

  // -------------------------------------------------------------------------
  // M3 — Periodic anti-entropy (§5.7)
  // -------------------------------------------------------------------------

  /// Re-shares the own avatar into every accepted circle.
  ///
  /// Called by `avatarAntiEntropyProvider` on a jittered periodic timer
  /// (24 h normal / 72 h data-saver). Heals dropped chunks, relay churn,
  /// and any late joiner the epoch trigger missed.
  ///
  /// Circles are processed sequentially (staggered) to avoid MLS lock
  /// contention — the same policy as [_publishAvatarShareToAllCircles].
  /// Skips if no avatar is set. Best-effort; relay failures are swallowed.
  void reshareToAllCircles() {
    // Reuse the M2 publish path with skipIfNoAvatar=true so the anti-entropy
    // scheduler does not publish an empty/clear into circles when the user
    // has no avatar. Identity is fetched inside the helper.
    _publishAvatarShareToAllCirclesWithCheck();
  }

  // -------------------------------------------------------------------------
  // Internal helpers
  // -------------------------------------------------------------------------

  /// Publishes avatar share events to all accepted circles (M2 on-change).
  ///
  /// Used by [pickAndSet]. Best-effort: relay failures are logged and ignored.
  /// Circles are processed sequentially to avoid MLS lock contention.
  ///
  /// The `updateIntervalSecs` reuses the location TTL constant so avatar
  /// events are indistinguishable from location on the wire (DEC-4).
  // M3: epoch-change re-share calls [epochReshareForCircle]; anti-entropy
  // calls [reshareToAllCircles]. Both reuse this pattern.
  void _publishAvatarShareToAllCircles(String pubkeyHex) {
    // Fire and forget — never await.
    Future(() async {
      try {
        final circles = await ref.read(circlesProvider.future);
        final service = ref.read(circleServiceProvider);
        final relayService = ref.read(relayServiceProvider);
        // DEC-4: mirror the location TTL so avatar events are
        // indistinguishable from location on the wire.
        final intervalSecs =
            kLocationPublishMaxInterval.inSeconds + kTtlNetworkBufferSeconds;

        for (final circle in circles) {
          if (circle.membershipStatus != MembershipStatus.accepted) continue;
          try {
            final events = await service.buildAvatarShareEvents(
              mlsGroupId: circle.mlsGroupId,
              senderPubkeyHex: pubkeyHex,
              updateIntervalSecs: intervalSecs,
            );
            if (events.isEmpty) {
              debugPrint('[Avatar] no events to share for circle');
              continue;
            }
            // Publish events sequentially (not parallel) — each is an
            // MLS application message; ordering matters.
            for (final eventJson in events) {
              await relayService.publishEvent(
                eventJson: eventJson,
                relays: circle.relays,
              );
            }
            debugPrint(
              '[Avatar] published ${events.length} chunk(s) to circle',
            );
          } on Object catch (e) {
            // Best-effort: relay failures must not break the UI.
            debugPrint('[Avatar] publish to circle failed: ${e.runtimeType}');
          }
        }
      } on Object catch (e) {
        debugPrint('[Avatar] _publishAvatarShareToAllCircles: ${e.runtimeType}');
      }
    });
  }


  /// Like [_publishAvatarShareToAllCircles] but checks for an existing avatar
  /// first and skips if none is set.
  ///
  /// Used by [reshareToAllCircles] (M3 anti-entropy) to avoid publishing
  /// empty/clear events when the user has no avatar.
  void _publishAvatarShareToAllCirclesWithCheck() {
    Future(() async {
      try {
        final identity = await ref.read(identityProvider.future);
        if (identity == null) {
          debugPrint('[Avatar] antiEntropy: no identity — skipped');
          return;
        }

        final service = ref.read(circleServiceProvider);
        // Short-circuit if no avatar is stored.
        final thumbnail = await service.getMyAvatarThumbnail(
          identity.pubkeyHex,
        );
        if (thumbnail == null) {
          debugPrint('[Avatar] antiEntropy: no avatar set — skipped');
          return;
        }

        final circles = await ref.read(circlesProvider.future);
        final relayService = ref.read(relayServiceProvider);
        final intervalSecs =
            kLocationPublishMaxInterval.inSeconds + kTtlNetworkBufferSeconds;

        for (final circle in circles) {
          if (circle.membershipStatus != MembershipStatus.accepted) continue;
          try {
            final events = await service.buildAvatarShareEvents(
              mlsGroupId: circle.mlsGroupId,
              senderPubkeyHex: identity.pubkeyHex,
              updateIntervalSecs: intervalSecs,
            );
            if (events.isEmpty) continue;
            // Stagger: publish sequentially, one circle at a time.
            for (final eventJson in events) {
              await relayService.publishEvent(
                eventJson: eventJson,
                relays: circle.relays,
              );
            }
            debugPrint(
              '[Avatar] antiEntropy: published ${events.length} chunk(s)',
            );
          } on Object catch (e) {
            // Best-effort: failures in one circle must not stop others.
            debugPrint(
              '[Avatar] antiEntropy: circle publish failed: ${e.runtimeType}',
            );
          }
        }
      } on Object catch (e) {
        debugPrint('[Avatar] antiEntropy: unexpected error: ${e.runtimeType}');
      }
    });
  }

  /// Compares two MLS group ID byte lists for equality.
  static bool _mlsGroupIdEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Provider exposing [OwnAvatarController].
final ownAvatarControllerProvider =
    AsyncNotifierProvider<OwnAvatarController, OwnAvatarState>(
      OwnAvatarController.new,
    );
