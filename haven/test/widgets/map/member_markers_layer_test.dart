/// Tests for [MemberMarkersLayer] — avatar wiring via [_AvatarLoader].
///
/// The layer is a screen-space overlay that lives inside FlutterMap; for unit
/// tests we exercise it without a real map by supplying a fake [MapCamera] via
/// [MockMapCamera] / a simplified projection setup.  The focus here is the
/// avatar-provider wiring, not the teardrop geometry (covered in
/// member_marker_test.dart and marker_metrics_test.dart).
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/member_avatar_provider.dart';
import 'package:haven/src/services/location_sharing_service.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/widgets/map/avatar_image_cache.dart';
import 'package:haven/src/widgets/map/member_marker.dart';
import 'package:haven/src/widgets/map/member_markers_layer.dart';
import 'package:latlong2/latlong.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// A [MemberLocation] factory that keeps tests concise.
MemberLocation _loc({
  String pubkey = 'aabbccdd',
  String? displayName,
  String? avatarContentHash,
  double lat = 51.5,
  double lng = -0.1,
}) => MemberLocation(
  pubkey: pubkey,
  latitude: lat,
  longitude: lng,
  geohash: 'gcpvh',
  timestamp: DateTime(2026),
  expiresAt: DateTime(2026).add(const Duration(hours: 1)),
  displayName: displayName,
  avatarContentHash: avatarContentHash,
);

/// The minimal MLS group ID used by tests.
final _groupId = <int>[1, 2, 3];

/// Wraps [child] in a [ProviderScope] with the given [overrides].
Widget _wrap(
  Widget child, {
  List<Override> overrides = const [],
}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      home: Scaffold(
        body: FlutterMap(
          options: const MapOptions(
            initialCenter: LatLng(51.5, -0.1),
            initialZoom: 13,
          ),
          children: [child],
        ),
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  // The avatar image cache is a process singleton; isolate tests so a decoded
  // image from one test cannot leak into another (and dispose seeded images).
  setUp(AvatarImageCache.instance.clear);
  tearDown(AvatarImageCache.instance.clear);

  group('MemberMarkersLayer — no avatar (mlsGroupId null)', () {
    testWidgets('renders one MemberMarker per member', (tester) async {
      final members = [_loc(pubkey: 'aa'), _loc(pubkey: 'bb')];
      await tester.pumpWidget(
        _wrap(
          MemberMarkersLayer(
            members: members,
            bottomInset: 0,
            onFocusMember: (_) {},
          ),
        ),
      );
      await tester.pump();
      // Two markers should be present.
      expect(find.byType(MemberMarker), findsNWidgets(2));
    });

    testWidgets('renders nothing when member list is empty', (tester) async {
      await tester.pumpWidget(
        _wrap(
          MemberMarkersLayer(
            members: const [],
            bottomInset: 0,
            onFocusMember: (_) {},
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(MemberMarker), findsNothing);
    });
  });

  group('MemberMarkersLayer — avatar wiring', () {
    testWidgets(
        'shows initials fallback while avatar provider returns loading', (
      tester,
    ) async {
      // Provider that stays in loading state (never resolves within the test).
      // Using a Completer avoids leaving a pending Timer in the test framework.
      final member = _loc(
        pubkey: 'cc',
        avatarContentHash: 'hash-cc',
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            memberAvatarThumbnailProvider.overrideWith(
              (ref, key) {
                // Return a Future that never completes (via a Completer that
                // is never resolved) so the provider stays in the loading
                // state for the duration of the test.
                return Completer<Uint8List?>().future;
              },
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: FlutterMap(
                options: const MapOptions(
                  initialCenter: LatLng(51.5, -0.1),
                  initialZoom: 13,
                ),
                children: [
                  MemberMarkersLayer(
                    members: [member],
                    bottomInset: 0,
                    onFocusMember: (_) {},
                    mlsGroupId: _groupId,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // Marker is rendered (initials path, no crash).
      expect(find.byType(MemberMarker), findsOneWidget);
      // The MemberMarker has no avatarImage yet — no drawImageRect was called.
      final marker = tester.widget<MemberMarker>(
        find.byKey(WidgetKeys.memberMarker(member.pubkey)),
      );
      expect(marker.avatarImage, isNull,
          reason: 'avatar should be null while provider is loading');
    });

    testWidgets(
        'background cache clear does not paint a disposed image (regression)', (
      tester,
    ) async {
      // Seed the cache with a decoded image for the member's content-hash, as
      // a completed decode would. createTestImage must run in the real-async
      // zone (it never completes inside testWidgets' fake-async).
      final img = (await tester.runAsync(
        () => createTestImage(width: 8, height: 8),
      ))!;
      AvatarImageCache.instance.put('hash-evict', img);

      final member = _loc(pubkey: 'ev', avatarContentHash: 'hash-evict');
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            // No bytes available: the loader must still paint the cached image
            // (the cache is the single source of truth).
            memberAvatarThumbnailProvider.overrideWith((ref, key) async => null),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: FlutterMap(
                options: const MapOptions(
                  initialCenter: LatLng(51.5, -0.1),
                  initialZoom: 13,
                ),
                children: [
                  MemberMarkersLayer(
                    members: [member],
                    bottomInset: 0,
                    onFocusMember: (_) {},
                    mlsGroupId: _groupId,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // The loader reads the decoded image back from the cache.
      final m1 = tester.widget<MemberMarker>(
        find.byKey(WidgetKeys.memberMarker(member.pubkey)),
      );
      expect(m1.avatarImage, same(img),
          reason: 'loader must read the decoded image from the cache');

      // Background eviction disposes the ui.Image. The loader holds NO
      // reference, so the next build reads the now-empty cache and paints
      // initials — never the disposed image (the prior use-after-dispose bug).
      AvatarImageCache.instance.clear();
      await tester.pump();

      final m2 = tester.widget<MemberMarker>(
        find.byKey(WidgetKeys.memberMarker(member.pubkey)),
      );
      expect(m2.avatarImage, isNull,
          reason: 'after cache clear the loader must not paint a disposed '
              'image');
    });

    testWidgets(
        'shows initials fallback when provider returns null bytes', (
      tester,
    ) async {
      final member = _loc(
        pubkey: 'dd',
        avatarContentHash: 'hash-dd',
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            memberAvatarThumbnailProvider.overrideWith(
              (ref, key) async => null,
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: FlutterMap(
                options: const MapOptions(
                  initialCenter: LatLng(51.5, -0.1),
                  initialZoom: 13,
                ),
                children: [
                  MemberMarkersLayer(
                    members: [member],
                    bottomInset: 0,
                    onFocusMember: (_) {},
                    mlsGroupId: _groupId,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      // Let the provider resolve (returns null immediately).
      await tester.pumpAndSettle();

      final marker = tester.widget<MemberMarker>(
        find.byKey(WidgetKeys.memberMarker(member.pubkey)),
      );
      expect(marker.avatarImage, isNull,
          reason: 'null bytes must leave avatarImage null (initials fallback)');
    });

    testWidgets(
        'shows initials fallback when avatarContentHash is null', (
      tester,
    ) async {
      // Member has no avatar hash at all — provider should not be called.
      final member = _loc(pubkey: 'ee'); // avatarContentHash: null

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            memberAvatarThumbnailProvider.overrideWith((ref, key) async {
              // This should never be called because the layer won't watch the
              // provider when contentHash is null.
              fail('provider should not be watched when contentHash is null');
            }),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: FlutterMap(
                options: const MapOptions(
                  initialCenter: LatLng(51.5, -0.1),
                  initialZoom: 13,
                ),
                children: [
                  MemberMarkersLayer(
                    members: [member],
                    bottomInset: 0,
                    onFocusMember: (_) {},
                    mlsGroupId: _groupId,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(MemberMarker), findsOneWidget);
    });

    testWidgets(
        'shows initials fallback when mlsGroupId is null', (
      tester,
    ) async {
      final member = _loc(
        pubkey: 'ff',
        avatarContentHash: 'hash-ff',
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            memberAvatarThumbnailProvider.overrideWith((ref, key) async {
              fail('provider must not be watched when mlsGroupId is null');
            }),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: FlutterMap(
                options: const MapOptions(
                  initialCenter: LatLng(51.5, -0.1),
                  initialZoom: 13,
                ),
                children: [
                  MemberMarkersLayer(
                    members: [member],
                    bottomInset: 0,
                    onFocusMember: (_) {},
                    // mlsGroupId intentionally omitted → null
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(MemberMarker), findsOneWidget);
    });
  });
}
