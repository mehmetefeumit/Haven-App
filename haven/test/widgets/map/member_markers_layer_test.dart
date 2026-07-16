/// Tests for [MemberMarkersLayer] — avatar wiring via [_AvatarLoader].
///
/// The layer is a screen-space overlay that lives inside FlutterMap; for unit
/// tests we exercise it without a real map by supplying a fake [MapCamera] via
/// [MockMapCamera] / a simplified projection setup.  The focus here is the
/// avatar-provider wiring, not the teardrop geometry (covered in
/// member_marker_test.dart and marker_metrics_test.dart).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/providers/member_profile_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/location_sharing_service.dart';
import 'package:haven/src/services/profile_service.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/widgets/map/avatar_image_cache.dart';
import 'package:haven/src/widgets/map/member_marker.dart';
import 'package:haven/src/widgets/map/member_markers_layer.dart';
import 'package:latlong2/latlong.dart';

import '../../mocks/mock_profile_service.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// A [MemberLocation] factory that keeps tests concise.
///
/// [displayName] models the effective name `memberLocationsProvider` already
/// resolved cache-only into `MemberLocation.displayName` (plan §6.3 Flutter
/// review F4) — the marker layer itself never re-resolves names.
MemberLocation _loc({
  String pubkey = 'aabbccdd',
  String? displayName,
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
);

/// Wraps [child] in a [ProviderScope] with the given [overrides].
///
/// Always includes a safe-default `profileServiceProvider` override (a bare
/// [MockProfileService], no profiles/pictures) so every member's
/// `memberProfileProvider` avatar lookup — always watched by
/// [MemberMarkersLayer] now — resolves off real FFI, even for tests that
/// don't care about avatars at all. Callers needing specific per-pubkey
/// profile data override the `memberProfileProvider(pubkey)` family member
/// directly, which takes precedence.
Widget _wrap(
  Widget child, {
  List<Override> overrides = const [],
}) {
  return ProviderScope(
    overrides: [
      profileServiceProvider.overrideWithValue(MockProfileService()),
      ...overrides,
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
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

  group('MemberMarkersLayer — basic rendering', () {
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

  group('MemberMarkersLayer — fade-out on leaving the circle', () {
    testWidgets(
        'a departed member stays mounted then is removed after its fade-out', (
      tester,
    ) async {
      final a = _loc(pubkey: 'aa');
      final b = _loc(pubkey: 'bb');
      await tester.pumpWidget(
        _wrap(
          MemberMarkersLayer(
            members: [a, b],
            bottomInset: 0,
            onFocusMember: (_) {},
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(MemberMarker), findsNWidgets(2));

      // Member b leaves the list — it must linger, fading out, not vanish.
      await tester.pumpWidget(
        _wrap(
          MemberMarkersLayer(
            members: [a],
            bottomInset: 0,
            onFocusMember: (_) {},
          ),
        ),
      );
      await tester.pump(); // kick off the reverse transition
      expect(
        find.byType(MemberMarker),
        findsNWidgets(2),
        reason: 'departed marker is still fading out',
      );
      expect(find.byKey(WidgetKeys.memberMarker('bb')), findsOneWidget);

      // After the fade-out completes the marker is dropped.
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(); // process the removal setState
      expect(find.byType(MemberMarker), findsOneWidget);
      expect(find.byKey(WidgetKeys.memberMarker('bb')), findsNothing);
      expect(find.byKey(WidgetKeys.memberMarker('aa')), findsOneWidget);
    });

    testWidgets(
        'circle switch fades old members out while the new one fades in', (
      tester,
    ) async {
      final old1 = _loc(pubkey: 'aa');
      final old2 = _loc(pubkey: 'bb');
      await tester.pumpWidget(
        _wrap(
          MemberMarkersLayer(
            members: [old1, old2],
            bottomInset: 0,
            onFocusMember: (_) {},
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(MemberMarker), findsNWidgets(2));

      // Switch to a circle with an entirely different membership.
      final fresh = _loc(pubkey: 'cc');
      await tester.pumpWidget(
        _wrap(
          MemberMarkersLayer(
            members: [fresh],
            bottomInset: 0,
            onFocusMember: (_) {},
          ),
        ),
      );
      await tester.pump();
      // Both old markers fade out (still mounted) alongside the new one.
      expect(find.byType(MemberMarker), findsNWidgets(3));
      expect(find.byKey(WidgetKeys.memberMarker('aa')), findsOneWidget);
      expect(find.byKey(WidgetKeys.memberMarker('bb')), findsOneWidget);
      expect(find.byKey(WidgetKeys.memberMarker('cc')), findsOneWidget);

      // Once the fade-out settles only the new circle's marker remains.
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();
      expect(find.byType(MemberMarker), findsOneWidget);
      expect(find.byKey(WidgetKeys.memberMarker('cc')), findsOneWidget);
    });

    testWidgets('a member removed then re-added before the fade is not '
        'drawn twice', (tester) async {
      final a = _loc(pubkey: 'aa');
      final b = _loc(pubkey: 'bb');
      await tester.pumpWidget(
        _wrap(
          MemberMarkersLayer(
            members: [a, b],
            bottomInset: 0,
            onFocusMember: (_) {},
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));

      // Remove b, then re-add it mid-fade (e.g. a quick circle switch back).
      await tester.pumpWidget(
        _wrap(
          MemberMarkersLayer(
            members: [a],
            bottomInset: 0,
            onFocusMember: (_) {},
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 60));
      await tester.pumpWidget(
        _wrap(
          MemberMarkersLayer(
            members: [a, b],
            bottomInset: 0,
            onFocusMember: (_) {},
          ),
        ),
      );
      await tester.pump();
      // Exactly one marker for b — the live one — never a live+exiting pair
      // (which would also trip Flutter's duplicate-key assertion).
      expect(find.byKey(WidgetKeys.memberMarker('bb')), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();
      expect(find.byType(MemberMarker), findsNWidgets(2));
    });

    testWidgets('reduce motion: a departed member is dropped without a fade', (
      tester,
    ) async {
      Widget build(List<MemberLocation> members) => ProviderScope(
            overrides: [
              profileServiceProvider.overrideWithValue(MockProfileService()),
            ],
            child: MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: MediaQuery(
                data: const MediaQueryData(disableAnimations: true),
                child: Scaffold(
                  body: FlutterMap(
                    options: const MapOptions(
                      initialCenter: LatLng(51.5, -0.1),
                      initialZoom: 13,
                    ),
                    children: [
                      MemberMarkersLayer(
                        members: members,
                        bottomInset: 0,
                        onFocusMember: (_) {},
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );

      final a = _loc(pubkey: 'aa');
      final b = _loc(pubkey: 'bb');
      await tester.pumpWidget(build([a, b]));
      await tester.pump();
      expect(find.byType(MemberMarker), findsNWidgets(2));

      // b leaves: with animations disabled it must vanish promptly, not linger.
      await tester.pumpWidget(build([a]));
      await tester.pump(); // post-frame exit-complete fires
      await tester.pump(); // process the removal setState
      expect(find.byType(MemberMarker), findsOneWidget);
      expect(find.byKey(WidgetKeys.memberMarker('bb')), findsNothing);
    });
  });

  group('MemberMarkersLayer — avatar wiring (memberProfileProvider)', () {
    testWidgets(
        'shows initials fallback while the profile provider returns loading', (
      tester,
    ) async {
      // Provider that stays in loading state (never resolves within the test).
      // Using a Completer avoids leaving a pending Timer in the test framework.
      final member = _loc(pubkey: 'cc');

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            memberProfileProvider(member.pubkey).overrideWith(
              (ref) => Completer<Profile?>().future,
            ),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
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
          reason: 'avatar should be null while the profile is loading');
    });

    testWidgets(
        'background cache clear does not paint a disposed image (regression)', (
      tester,
    ) async {
      // Seed the cache with a decoded image for the member's picture hash, as
      // a completed decode would. createTestImage must run in the real-async
      // zone (it never completes inside testWidgets' fake-async).
      final img = (await tester.runAsync(
        () => createTestImage(width: 8, height: 8),
      ))!;
      AvatarImageCache.instance.put('hash-evict', img);

      final member = _loc(pubkey: 'ev');
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            // No bytes available: the loader must still paint the cached image
            // (the cache is the single source of truth).
            memberProfileProvider(member.pubkey).overrideWith(
              (ref) async => Profile(
                pubkeyHex: member.pubkey,
                pictureHash: 'hash-evict',
              ),
            ),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
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
        'shows initials fallback when the profile has no picture', (
      tester,
    ) async {
      final member = _loc(pubkey: 'dd');

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            memberProfileProvider(member.pubkey).overrideWith(
              (ref) async => Profile(pubkeyHex: member.pubkey),
            ),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
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
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      // Let the provider resolve (returns immediately).
      await tester.pumpAndSettle();

      final marker = tester.widget<MemberMarker>(
        find.byKey(WidgetKeys.memberMarker(member.pubkey)),
      );
      expect(marker.avatarImage, isNull,
          reason: 'no pictureHash must leave avatarImage null (initials '
              'fallback)');
    });

    testWidgets(
        'shows initials fallback when the profile is Unknown (null)', (
      tester,
    ) async {
      final member = _loc(pubkey: 'ee');

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            memberProfileProvider(
              member.pubkey,
            ).overrideWith((ref) async => null),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
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
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(MemberMarker), findsOneWidget);
      final marker = tester.widget<MemberMarker>(
        find.byKey(WidgetKeys.memberMarker(member.pubkey)),
      );
      expect(marker.avatarImage, isNull);
    });
  });
}
