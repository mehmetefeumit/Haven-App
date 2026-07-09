/// Service providers for dependency injection.
///
/// These providers expose singleton instances of services throughout the app.
/// Override these in tests with mock implementations using ProviderScope.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/invitation_provider.dart';
import 'package:haven/src/providers/live_sync_provider.dart';
import 'package:haven/src/providers/location_sharing_provider.dart';
import 'package:haven/src/providers/member_avatar_provider.dart';
import 'package:haven/src/providers/own_avatar_provider.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/catchup_service.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/geolocator_location_service.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/ios_location_auth_service.dart';
import 'package:haven/src/services/location_service.dart';
import 'package:haven/src/services/location_sharing_service.dart';
import 'package:haven/src/services/maintenance_service.dart';
import 'package:haven/src/services/nostr_circle_service.dart';
import 'package:haven/src/services/nostr_identity_service.dart';
import 'package:haven/src/services/nostr_relay_service.dart';
import 'package:haven/src/services/nostr_subscription_service.dart';
import 'package:haven/src/services/relay_service.dart';
import 'package:haven/src/services/subscription_service.dart';

/// Provides the identity service singleton.
///
/// Uses [NostrIdentityService] in production.
/// Override with a mock in tests:
/// ```dart
/// ProviderScope(
///   overrides: [
///     identityServiceProvider.overrideWithValue(mockIdentityService),
///   ],
///   child: MyWidget(),
/// )
/// ```
final identityServiceProvider = Provider<IdentityService>((ref) {
  return NostrIdentityService();
});

/// Provides the location service singleton.
///
/// Uses [GeolocatorLocationService] in production.
final locationServiceProvider = Provider<LocationService>((ref) {
  return GeolocatorLocationService();
});

/// Provides the iOS CoreLocation "Always" authorization bridge.
///
/// Real `MethodChannel`-backed implementation on iOS; a no-op reporting
/// [IosAuthStatus.always] on every other platform. Override in tests with a
/// fake to exercise the iOS authorization branches.
final iosLocationAuthServiceProvider = Provider<IosLocationAuthService>((ref) {
  return createIosLocationAuthService();
});

/// Exposes the current iOS location authorization status.
///
/// Drives the "background sharing is limited to while-in-use" guidance in the
/// location settings page. Returns [IosAuthStatus.always] on non-iOS platforms
/// (no limitation). Invalidate this provider after changing the authorization
/// (e.g. right after enabling background sharing) to refresh the reading.
final iosLocationPermissionProvider = FutureProvider<IosAuthStatus>((ref) {
  return ref.read(iosLocationAuthServiceProvider).checkStatus();
});

/// Provides the circle service singleton.
///
/// Uses [NostrCircleService] in production.
final circleServiceProvider = Provider<CircleService>((ref) {
  return NostrCircleService(
    relayService: ref.read(relayServiceProvider),
    // REV-1 leaver backstop (driver 2): the foreground service authors leaves,
    // so it runs the bounded SelfRemove re-issue loop. No identity secret is
    // wired — the re-issue publishes under an ephemeral key (Rule 9: nothing to
    // materialise), and a concurrent-logout abort is enforced by the service's
    // own `_wiped` latch, not an identity fetch.
    enableLeaverBackstop: true,
  );
});

/// Provides the relay service singleton.
///
/// Uses [NostrRelayService] in production.
final relayServiceProvider = Provider<RelayService>((ref) {
  return NostrRelayService();
});

/// Provides the location sharing service singleton.
///
/// Uses [LocationSharingService] for encrypt-publish-fetch-decrypt pipeline.
///
/// The `onAvatarComplete` callback is wired here so that when the service's
/// avatar reassembler finishes ingesting a complete avatar (M2 receive path),
/// the [memberAvatarThumbnailProvider] for that (circle, member) pair is
/// immediately invalidated. This causes any member tile that is currently
/// mounted — e.g. a bottom sheet open — to re-fetch the new bytes without
/// waiting for a dispose/rebuild cycle.
final locationSharingServiceProvider = Provider<LocationSharingService>((ref) {
  return LocationSharingService(
    circleService: ref.read(circleServiceProvider),
    relayService: ref.read(relayServiceProvider),
    identityService: ref.read(identityServiceProvider),
    onAvatarComplete: (mlsGroupId, pubkeyHex) {
      try {
        ref.invalidate(
          memberAvatarThumbnailProvider(
            MemberAvatarKey(mlsGroupId: mlsGroupId, pubkeyHex: pubkeyHex),
          ),
        );
        debugPrint(
          '[ServiceProvider] invalidated memberAvatarThumbnailProvider '
          'for sender prefix',
        );
      } on Object catch (e) {
        // Best-effort: invalidation failures must not disrupt the location loop.
        debugPrint(
          '[ServiceProvider] memberAvatarThumbnail invalidation error: '
          '${e.runtimeType}',
        );
      }
    },
  );
});

/// Helper: invalidate a provider, swallowing any failure (Security/robustness —
/// an invalidation throw must never break the stream loop).
void _safeInvalidate(void Function() invalidate, String label) {
  try {
    invalidate();
  } on Object catch (e) {
    debugPrint('[ServiceProvider] $label invalidation error: ${e.runtimeType}');
  }
}

/// Provides the live-sync subscription service (M6-3).
///
/// Builds a [LiveSyncFfi] engine (via the single authoritative MLS manager +
/// the own pubkey) and routes its `liveEvents()` stream into the same providers
/// + persistence the pollers feed. Inert until `liveSyncEnabled` is flipped on
/// and a caller invokes `start()`; until then nothing constructs the engine.
final subscriptionServiceProvider = Provider<SubscriptionService>((ref) {
  final router = LiveEventRouter(
    circleService: ref.read(circleServiceProvider),
    circlesSnapshot: () => ref.read(circlesProvider.future),
    secretBytes: () =>
        ref.read(identityNotifierProvider.notifier).getSecretBytes(),
    parseLocation: (content, sender) async {
      // Reuse the Rust serde schema (no Dart duplication); null = not a
      // parseable LocationMessage (e.g. an avatar chunk — deferred to a
      // follow-up; the engine delivers avatars as Location-kind events whose
      // content is not a LocationMessage, so they are skipped here).
      try {
        final ffi = await parseEngineLocation(
          contentJson: content,
          senderPubkey: sender,
        );
        return DecryptedLocation(
          senderPubkey: ffi.senderPubkey,
          latitude: ffi.latitude,
          longitude: ffi.longitude,
          geohash: ffi.geohash,
          timestamp: DateTime.fromMillisecondsSinceEpoch(ffi.timestamp * 1000),
          expiresAt: DateTime.fromMillisecondsSinceEpoch(ffi.expiresAt * 1000),
          displayName: ffi.displayName,
        );
      } on Object catch (e) {
        debugPrint(
          '[ServiceProvider] parseEngineLocation skipped: ${e.runtimeType}',
        );
        return null;
      }
    },
    ingestLocation: (circle, decrypted) => ref
        .read(locationSharingServiceProvider)
        .ingestStreamedLocation(circle: circle, decrypted: decrypted),
    reconcileRoster: (circle) =>
        ref.read(locationSharingServiceProvider).reconcileRoster(circle),
    onLocationsChanged: () => _safeInvalidate(
      () => ref.invalidate(memberLocationsProvider),
      'memberLocations',
    ),
    onGroupUpdated: (circle) {
      _safeInvalidate(() => ref.invalidate(circlesProvider), 'circles');
      _safeInvalidate(
        () => ref.invalidate(memberLocationsProvider),
        'memberLocations',
      );
      // Re-share the own avatar to the new epoch (a member joined/left).
      _safeInvalidate(
        () => ref
            .read(ownAvatarControllerProvider.notifier)
            .epochReshareForCircle(circle.mlsGroupId),
        'avatarReshare',
      );
    },
    onInvitationReceived: () {
      _safeInvalidate(
        () => ref.invalidate(pendingInvitationsProvider),
        'pendingInvitations',
      );
      _safeInvalidate(() => ref.invalidate(circlesProvider), 'circles');
    },
    onStatus: (reason) => _safeInvalidate(
      () => ref.read(syncStatusProvider.notifier).onStatus(reason),
      'syncStatus',
    ),
  );

  return NostrSubscriptionService(
    router: router,
    engineFactory: () async {
      final circleService = ref.read(circleServiceProvider);
      if (circleService is! NostrCircleService) {
        throw const SubscriptionServiceException(
          'circle service is not Nostr-backed',
        );
      }
      // Check identity BEFORE opening the circle manager. `getCircleManagerFfi`
      // would SQLite-create circles.db + a keyring key on a fresh (post-logout)
      // service — so a live-sync restart racing an identity delete must bail
      // here, not re-create state the M10 wipe removed (defence-in-depth atop
      // the `_wiped` latch, which the delete flow keeps active across logout).
      final identity = await ref.read(identityProvider.future);
      if (identity == null) {
        throw const SubscriptionServiceException('no active identity');
      }
      final manager = await circleService.getCircleManagerFfi();
      return LiveSyncFfi.newInstance(
        circle: manager,
        ownPubkeyHex: identity.pubkeyHex,
      );
    },
  );
});

/// Provides the M7 catch-up service (fork-safe receive-only sweep) used on
/// foreground resume and by the background wake paths.
final catchupServiceProvider = Provider<CatchupService>((ref) {
  return CatchupService(
    relayService: ref.read(relayServiceProvider),
    circleManagerFactory: () async {
      final circleService = ref.read(circleServiceProvider);
      if (circleService is! NostrCircleService) {
        throw StateError('circle service is not Nostr-backed');
      }
      return circleService.getCircleManagerFfi();
    },
    ownPubkeyHex: () async =>
        (await ref.read(identityProvider.future))?.pubkeyHex,
  );
});

/// Provides the M8 maintenance service (scheduled `KeyPackage` + relay-list
/// republish-if-missing) driven by the [`maintenanceSchedulerProvider`] timers.
///
/// Engine-independent — it fixes reachability on today's poll path and is
/// active whenever an identity is present, regardless of `liveSyncEnabled`.
final maintenanceServiceProvider = Provider<MaintenanceService>((ref) {
  return MaintenanceService(
    relayService: ref.read(relayServiceProvider),
    circleManagerFactory: () async {
      final circleService = ref.read(circleServiceProvider);
      if (circleService is! NostrCircleService) {
        throw StateError('circle service is not Nostr-backed');
      }
      return circleService.getCircleManagerFfi();
    },
    // Resolved per tick (not at construction): if `identityNotifierProvider`
    // is disposed by a concurrent logout when a tick fires, this `ref.read`
    // may throw — that is caught by `MaintenanceService._withSecret`, which
    // fails closed (returns an empty outcome, no publish).
    identitySecretBytes: () =>
        ref.read(identityNotifierProvider.notifier).getSecretBytes(),
  );
});
