/// Service providers for dependency injection.
///
/// These providers expose singleton instances of services throughout the app.
/// Override these in tests with mock implementations using ProviderScope.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/providers/member_avatar_provider.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/geolocator_location_service.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/location_service.dart';
import 'package:haven/src/services/location_sharing_service.dart';
import 'package:haven/src/services/nostr_circle_service.dart';
import 'package:haven/src/services/nostr_identity_service.dart';
import 'package:haven/src/services/nostr_relay_service.dart';
import 'package:haven/src/services/relay_service.dart';

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

/// Provides the circle service singleton.
///
/// Uses [NostrCircleService] in production.
final circleServiceProvider = Provider<CircleService>((ref) {
  return NostrCircleService(relayService: ref.read(relayServiceProvider));
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
