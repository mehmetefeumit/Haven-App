/// Tests for [MemberMarkersLayer] — avatar wiring via [_AvatarLoader].
///
/// The layer is a screen-space overlay that lives inside FlutterMap; for unit
/// tests we exercise it without a real map by supplying a fake [MapCamera] via
/// [MockMapCamera] / a simplified projection setup.  The focus here is the
/// avatar-provider wiring, not the teardrop geometry (covered in
/// member_marker_test.dart and marker_metrics_test.dart).
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

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
import 'package:haven/src/utils/marker_geometry.dart';
import 'package:haven/src/utils/marker_glide.dart';
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
  receivedAt: null,
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

/// A solid-colour PNG of [width]x[height]; must run in the real-async zone.
Future<Uint8List> _png(int width, int height) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = const ui.Color(0xFF3366CC),
  );
  final image = await recorder.endRecording().toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Waits on real time for the engine to have decoded [count] pictures; the
/// decode runs off the test's fake clock, and a miss fails loudly at the bound.
Future<void> _awaitDecodes(WidgetTester tester, int count) async {
  await tester.runAsync(() async {
    final watch = Stopwatch()..start();
    while (AvatarImageCache.instance.length < count &&
        watch.elapsed < const Duration(seconds: 10)) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  });
}

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

    testWidgets('reduce motion: a departed member fades out, without scale, '
        'then is dropped', (tester) async {
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
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(MemberMarker), findsNWidgets(2));

      // b leaves: it fades (opacity still falling at 90 ms), never scales, and
      // is dropped once the 180 ms fade has finished.
      await tester.pumpWidget(build([a]));
      await tester.pump(const Duration(milliseconds: 90));
      final leaving = find.byKey(WidgetKeys.memberMarker('bb'));
      expect(leaving, findsOneWidget, reason: 'still fading out');
      expect(
        find.descendant(
          of: leaving,
          matching: find.byType(ScaleTransition),
        ),
        findsNothing,
      );
      final fade = tester.widget<FadeTransition>(
        find.descendant(of: leaving, matching: find.byType(FadeTransition)),
      );
      expect(fade.opacity.value, inExclusiveRange(0, 1));

      await tester.pump(const Duration(milliseconds: 120));
      await tester.pump(); // process the removal setState
      expect(find.byType(MemberMarker), findsOneWidget);
      expect(leaving, findsNothing);
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
      // The loader looks up the entry under its display-size key; the test
      // view's default 3x ratio gives 156 px.
      AvatarImageCache.instance.put(
        AvatarImageCache.keyFor('hash-evict', 156),
        img,
      );

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

    testWidgets(
      'a name the refresh resolves after the location fetch reaches the '
      'marker without waiting for the next fetch',
      (tester) async {
        const pubkey = 'f1f2';
        final svc = MockProfileService();
        await tester.pumpWidget(
          _wrap(
            MemberMarkersLayer(
              members: [_loc(pubkey: pubkey)],
              bottomInset: 0,
              onFocusMember: (_) {},
            ),
            overrides: [profileServiceProvider.overrideWithValue(svc)],
          ),
        );
        await tester.pumpAndSettle();
        MemberMarker marker() => tester.widget<MemberMarker>(
          find.byKey(WidgetKeys.memberMarker(pubkey)),
        );
        String label() => tester
            .getSemantics(find.byKey(WidgetKeys.markerSemantics(pubkey)))
            .label;
        expect(marker().initials, 'f1');
        expect(label(), isNot(contains('Jane Doe')));

        svc.memberProfiles[pubkey] = const Profile(
          pubkeyHex: pubkey,
          displayName: 'Jane Doe',
        );
        ProviderScope.containerOf(
          tester.element(find.byType(MemberMarker)),
        ).invalidate(memberProfileProvider);
        await tester.pumpAndSettle();

        expect(marker().initials, 'JD');
        expect(marker().displayName, 'Jane Doe');
        expect(label(), contains('Jane Doe'));
      },
    );

    testWidgets('a fetch-time name keeps winning over a different profile '
        'name', (tester) async {
      const pubkey = 'f3f4';
      final svc = MockProfileService(
        memberProfiles: {
          pubkey: const Profile(pubkeyHex: pubkey, displayName: 'Jane Doe'),
        },
      );
      await tester.pumpWidget(
        _wrap(
          MemberMarkersLayer(
            members: [_loc(pubkey: pubkey, displayName: 'Mum')],
            bottomInset: 0,
            onFocusMember: (_) {},
          ),
          overrides: [profileServiceProvider.overrideWithValue(svc)],
        ),
      );
      await tester.pumpAndSettle();

      final marker = tester.widget<MemberMarker>(
        find.byKey(WidgetKeys.memberMarker(pubkey)),
      );
      expect(marker.displayName, 'Mum');
      expect(marker.initials, 'M');
      final label = tester
          .getSemantics(find.byKey(WidgetKeys.markerSemantics(pubkey)))
          .label;
      expect(label, contains('Mum'));
      expect(label, isNot(contains('Jane')));
    });
  });

  group('MemberMarkersLayer — avatar decode at display size', () {
    const hash = 'hash-size';
    final member = _loc(pubkey: 'ff');

    Future<void> pumpWithBytes(WidgetTester tester, Uint8List bytes) {
      return tester.pumpWidget(
        _wrap(
          MemberMarkersLayer(
            members: [member],
            bottomInset: 0,
            onFocusMember: (_) {},
          ),
          overrides: [
            memberProfileProvider(member.pubkey).overrideWith(
              (ref) async => Profile(
                pubkeyHex: member.pubkey,
                pictureHash: hash,
                pictureBytes: bytes,
              ),
            ),
          ],
        ),
      );
    }

    Future<void> decoded(WidgetTester tester, String key) async {
      await _awaitDecodes(tester, 1);
      expect(AvatarImageCache.instance.get(key), isNotNull);
    }

    testWidgets('decodes the short side to the display size', (tester) async {
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetDevicePixelRatio);
      final bytes = (await tester.runAsync(() => _png(400, 300)))!;

      await pumpWithBytes(tester, bytes);
      await tester.pump();
      await decoded(tester, AvatarImageCache.keyFor(hash, 104));

      final image = AvatarImageCache.instance.get(
        AvatarImageCache.keyFor(hash, 104),
      )!;
      expect(image.height, 104);
      expect(image.width, (400 * 104 / 300).round());
      expect(AvatarImageCache.instance.get(hash), isNull);
      await tester.pump();
      expect(
        tester
            .widget<MemberMarker>(
              find.byKey(WidgetKeys.memberMarker(member.pubkey)),
            )
            .avatarImage,
        same(image),
      );
    });

    testWidgets('never upscales a source smaller than the display size', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetDevicePixelRatio);
      final bytes = (await tester.runAsync(() => _png(40, 40)))!;

      await pumpWithBytes(tester, bytes);
      await tester.pump();
      await decoded(tester, AvatarImageCache.keyFor(hash, 104));

      final image = AvatarImageCache.instance.get(
        AvatarImageCache.keyFor(hash, 104),
      )!;
      expect(image.width, 40);
      expect(image.height, 40);
    });

    testWidgets('a pixel-ratio change decodes again under the new key', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetDevicePixelRatio);
      final bytes = (await tester.runAsync(() => _png(400, 300)))!;

      await pumpWithBytes(tester, bytes);
      await tester.pump();
      await decoded(tester, AvatarImageCache.keyFor(hash, 104));

      tester.view.devicePixelRatio = 3;
      await tester.pump();
      await _awaitDecodes(tester, 2);

      final image = AvatarImageCache.instance.get(
        AvatarImageCache.keyFor(hash, 156),
      );
      expect(image, isNotNull);
      expect(image!.height, 156);
      expect(
        AvatarImageCache.instance.get(AvatarImageCache.keyFor(hash, 104)),
        isNotNull,
      );
    });
  });

  group('MemberMarkersLayer — pin geometry', () {
    // Screen position of the layer's map, and a way to place members at
    // chosen screen points through the camera the layer itself reads.
    Future<MapCamera> pumpCamera(
      WidgetTester tester, {
      double topInset = 0,
      double bottomInset = 0,
    }) async {
      await tester.pumpWidget(
        _wrap(
          MediaQuery(
            data: MediaQueryData(viewPadding: EdgeInsets.only(top: topInset)),
            child: MemberMarkersLayer(
              members: const [],
              bottomInset: bottomInset,
              onFocusMember: (_) {},
            ),
          ),
        ),
      );
      // The map learns its size on the first frame; read the camera after it.
      await tester.pump();
      return MapCamera.of(tester.element(find.byType(MemberMarkersLayer)));
    }

    MemberLocation at(MapCamera camera, String pubkey, Offset screen) {
      final ll = camera.screenOffsetToLatLng(screen);
      return _loc(pubkey: pubkey, lat: ll.latitude, lng: ll.longitude);
    }

    Future<void> pumpMembers(
      WidgetTester tester,
      List<MemberLocation> members, {
      double topInset = 0,
      double bottomInset = 0,
    }) async {
      await tester.pumpWidget(
        _wrap(
          MediaQuery(
            data: MediaQueryData(viewPadding: EdgeInsets.only(top: topInset)),
            child: MemberMarkersLayer(
              members: members,
              bottomInset: bottomInset,
              onFocusMember: (_) {},
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
    }

    List<String> paintOrder(WidgetTester tester) => [
      for (final c in tester
          .widget<Stack>(find.byKey(WidgetKeys.memberMarkersLayer))
          .children)
        (c.key! as ValueKey<String>).value.replaceFirst('marker_pos_', ''),
    ];

    testWidgets('clips the overlay to the safe rect', (tester) async {
      const topInset = 40.0;
      const bottomInset = 90.0;
      final camera = await pumpCamera(
        tester,
        topInset: topInset,
        bottomInset: bottomInset,
      );
      await pumpMembers(
        tester,
        [at(camera, 'aa', const Offset(400, 300))],
        topInset: topInset,
        bottomInset: bottomInset,
      );
      final clip = tester.widget<ClipRect>(
        find
            .ancestor(
              of: find.byKey(WidgetKeys.memberMarkersLayer),
              matching: find.byType(ClipRect),
            )
            .first,
      );
      final size = camera.nonRotatedSize;
      expect(
        clip.clipper!.getClip(size),
        Rect.fromLTRB(0, topInset, size.width, size.height - bottomInset),
        reason: 'a tail poking above the top inset is cut flat at it',
      );
    });

    testWidgets('paints a southern pin over a northern one of equal size', (
      tester,
    ) async {
      final camera = await pumpCamera(tester);
      // Pubkey order would put the southern member FIRST; position must win.
      final north = at(camera, 'zz', const Offset(400, 200));
      final south = at(camera, 'aa', const Offset(400, 320));
      await pumpMembers(tester, [south, north]);
      expect(paintOrder(tester), ['zz', 'aa']);
    });

    testWidgets('co-located members paint in a stable pubkey order', (
      tester,
    ) async {
      final camera = await pumpCamera(tester);
      final a = at(camera, 'bb', const Offset(400, 300));
      final b = at(camera, 'aa', const Offset(400, 300));
      await pumpMembers(tester, [a, b]);
      expect(paintOrder(tester), ['aa', 'bb']);
      await pumpMembers(tester, [b, a]);
      expect(paintOrder(tester), ['aa', 'bb']);
    });

    testWidgets('an on-screen member is a pin: head above, tip on the point', (
      tester,
    ) async {
      final camera = await pumpCamera(tester);
      const point = Offset(400, 300);
      await pumpMembers(tester, [at(camera, 'aa', point)]);
      final marker = tester.widget<MemberMarker>(
        find.byKey(WidgetKeys.memberMarker('aa')),
      );
      final head = tester.getCenter(find.byKey(WidgetKeys.memberMarker('aa')));
      final reach = marker.diameter / 2 + marker.nubLength;
      final tip = head + Offset.fromDirection(marker.angle, reach);
      expect((tip - point).distance, lessThan(1e-3));
      expect(marker.offScreen, isFalse);
    });

    testWidgets('a spread head is re-aimed with its projection cap', (
      tester,
    ) async {
      final camera = await pumpCamera(tester);
      final size = camera.nonRotatedSize;
      // Three members 2 px apart, 10 px past the right edge: one head is held
      // at the edge and the spread pushes the others 52 px apart along it.
      final points = [
        for (var i = 0; i < 3; i++) Offset(size.width + 10, 300.0 + 2 * i),
      ];
      await pumpMembers(tester, [
        for (var i = 0; i < 3; i++) at(camera, 'm$i', points[i]),
      ]);

      final viewport = edgeViewport(
        viewport: size,
        topInset: 0,
        bottomInset: 0,
      );
      var moved = 0;
      var longest = 0.0;
      for (var i = 0; i < 3; i++) {
        final key = WidgetKeys.memberMarker('m$i');
        final marker = tester.widget<MemberMarker>(find.byKey(key));
        final proj = projectMarker(point: points[i], viewport: viewport);
        final head = tester.getCenter(find.byKey(key));
        final tail = aimTail(
          point: points[i],
          center: head,
          radius: proj.diameter / 2,
          cap: proj.tailCap,
        );
        expect(marker.nubLength, closeTo(tail.nubLength, 1e-6));
        expect(marker.nubLength, lessThanOrEqualTo(proj.tailCap + 1e-9));
        expect(marker.angle, closeTo(tail.angle, 1e-6));
        // The tail points at the TRUE point from wherever the head ended up.
        final toPoint = points[i] - head;
        expect(
          Offset.fromDirection(marker.angle).dx * toPoint.distance,
          closeTo(toPoint.dx, 1e-3),
        );
        if ((head - proj.bubbleCenter).distance > 1) {
          moved++;
          longest = math.max(longest, marker.nubLength);
        }
      }
      expect(moved, greaterThan(0), reason: 'the spread moved a head');
      expect(
        longest,
        greaterThan(8),
        reason: 'near the edge the on-screen cap applies, not the far one',
      );
    });

    testWidgets('bearing reaches the marker: east is spoken for a diagonal '
        'tail', (tester) async {
      final camera = await pumpCamera(tester);
      final size = camera.nonRotatedSize;
      final member = at(camera, 'aa', Offset(size.width + 10, 300));
      await pumpMembers(tester, [member]);
      final marker = tester.widget<MemberMarker>(
        find.byKey(WidgetKeys.memberMarker('aa')),
      );
      expect(marker.offScreen, isTrue);
      expect(marker.bearing, closeTo(0, 1e-9));
      expect(
        marker.angle.abs(),
        greaterThan(0.5),
        reason: 'the tail leans well off east',
      );
      expect(
        tester
            .getSemantics(find.byKey(WidgetKeys.markerSemantics('aa')))
            .label,
        contains('east'),
      );
    });
  });

  group('MemberMarkersLayer — glide between fixes', () {
    const start = Offset(200, 300);
    const end = Offset(500, 300);
    const glideTime = Duration(milliseconds: 200);

    Widget app(
      List<MemberLocation> members, {
      MapController? controller,
      bool disableAnimations = false,
      void Function(MemberLocation member)? onFocusMember,
    }) {
      return ProviderScope(
        overrides: [
          profileServiceProvider.overrideWithValue(MockProfileService()),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: FlutterMap(
              mapController: controller,
              options: const MapOptions(
                initialCenter: LatLng(51.5, -0.1),
              ),
              children: [
                Builder(
                  builder: (context) => MediaQuery(
                    data: MediaQuery.of(
                      context,
                    ).copyWith(disableAnimations: disableAnimations),
                    child: MemberMarkersLayer(
                      members: members,
                      bottomInset: 0,
                      onFocusMember: onFocusMember ?? (_) {},
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    MapCamera cameraOf(WidgetTester tester) =>
        MapCamera.of(tester.element(find.byType(MemberMarkersLayer)));

    Future<MapCamera> pumpEmpty(
      WidgetTester tester, {
      MapController? controller,
    }) async {
      await tester.pumpWidget(app(const [], controller: controller));
      await tester.pump();
      return cameraOf(tester);
    }

    MemberLocation at(MapCamera camera, String pubkey, Offset screen) {
      final ll = camera.screenOffsetToLatLng(screen);
      return _loc(pubkey: pubkey, lat: ll.latitude, lng: ll.longitude);
    }

    LatLng fix(MemberLocation m) => LatLng(m.latitude, m.longitude);

    /// Where the pin's tip is, which for an on-screen member is its point.
    Offset tip(WidgetTester tester, String pubkey) {
      final finder = find.byKey(WidgetKeys.memberMarker(pubkey));
      final marker = tester.widget<MemberMarker>(finder);
      return tester.getCenter(finder) +
          Offset.fromDirection(
            marker.angle,
            marker.diameter / 2 + marker.nubLength,
          );
    }

    /// Shows [from] as a first appearance and lets the appear transition end.
    Future<void> settleAt(
      WidgetTester tester,
      List<MemberLocation> from, {
      MapController? controller,
      bool disableAnimations = false,
    }) async {
      await tester.pumpWidget(
        app(from, controller: controller, disableAnimations: disableAnimations),
      );
      await tester.pump(const Duration(milliseconds: 300));
    }

    /// Delivers a new fix and runs the frame whose elapsed time is zero.
    Future<void> deliver(
      WidgetTester tester,
      List<MemberLocation> members, {
      MapController? controller,
      bool disableAnimations = false,
    }) async {
      await tester.pumpWidget(
        app(
          members,
          controller: controller,
          disableAnimations: disableAnimations,
        ),
      );
      await tester.pump();
    }

    testWidgets('a new fix glides through easeOutCubic and lands exactly on '
        'it at 400 ms', (tester) async {
      final camera = await pumpEmpty(tester);
      await settleAt(tester, [at(camera, 'aa', start)]);
      await deliver(tester, [at(camera, 'aa', end)]);
      expect((tip(tester, 'aa') - start).distance, lessThan(1e-3));

      await tester.pump(glideTime);
      final progress = (tip(tester, 'aa').dx - start.dx) / (end.dx - start.dx);
      // easeOutCubic(0.5) = 0.875: between the ends, and past linear's 0.5.
      expect(progress, inExclusiveRange(0.8, 0.95));
      expect(tester.hasRunningAnimations, isTrue);

      await tester.pump(glideTime);
      expect((tip(tester, 'aa') - end).distance, lessThan(1e-3));
    });

    testWidgets('every later fix glides as promptly as the first', (
      tester,
    ) async {
      final camera = await pumpEmpty(tester);
      await settleAt(tester, [at(camera, 'aa', start)]);
      await deliver(tester, [at(camera, 'aa', end)]);
      await tester.pump(glideTime);
      await tester.pump(glideTime);
      await tester.pump();

      var from = end;
      var to = start;
      for (var fixNumber = 2; fixNumber <= 3; fixNumber++) {
        await deliver(tester, [at(camera, 'aa', to)]);
        await tester.pump(glideTime);
        final progress = (tip(tester, 'aa').dx - from.dx) / (to.dx - from.dx);
        // easeOutCubic(0.5) = 0.875: under way, and nearer the new fix.
        expect(progress, inExclusiveRange(0.8, 0.95), reason: 'fix $fixNumber');

        await tester.pump(glideTime);
        expect(
          (tip(tester, 'aa') - to).distance,
          lessThan(1e-3),
          reason: 'fix $fixNumber',
        );
        await tester.pump();
        expect(tester.hasRunningAnimations, isFalse, reason: 'fix $fixNumber');
        final swap = from;
        from = to;
        to = swap;
      }
    });

    testWidgets('a retarget mid-glide continues from where the pin is', (
      tester,
    ) async {
      final camera = await pumpEmpty(tester);
      await settleAt(tester, [at(camera, 'aa', start)]);
      await deliver(tester, [at(camera, 'aa', end)]);
      await tester.pump(glideTime);
      final before = tip(tester, 'aa');

      const retarget = Offset(500, 340);
      await tester.pumpWidget(app([at(camera, 'aa', retarget)]));
      expect(
        (tip(tester, 'aa') - before).distance,
        lessThan(1e-3),
        reason: 'the retarget frame draws the pin where it already was',
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        (tip(tester, 'aa') - before).distance,
        lessThan(10),
        reason: 'one frame on it has moved a few px, not back to the start',
      );

      await tester.pump(const Duration(milliseconds: 400));
      expect((tip(tester, 'aa') - retarget).distance, lessThan(1e-3));
    });

    testWidgets('a move longer than the viewport long side snaps', (
      tester,
    ) async {
      tester.view
        ..physicalSize = const Size(400, 300)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final camera = await pumpEmpty(tester);
      const from = Offset(20, 20);
      const to = Offset(380, 280);
      expect((to - from).distance, greaterThan(400));
      await settleAt(tester, [at(camera, 'aa', from)]);
      await deliver(tester, [at(camera, 'aa', to)]);
      expect((tip(tester, 'aa') - to).distance, lessThan(1e-3));
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('a first appearance snaps', (tester) async {
      final camera = await pumpEmpty(tester);
      await deliver(tester, [at(camera, 'aa', start)]);
      await tester.pump(const Duration(milliseconds: 300));
      await deliver(tester, [at(camera, 'aa', start), at(camera, 'bb', end)]);
      expect((tip(tester, 'bb') - end).distance, lessThan(1e-3));
      expect((tip(tester, 'aa') - start).distance, lessThan(1e-3));
    });

    for (final flag in [
      'MediaQuery.disableAnimations',
      'engine reduceMotion',
    ]) {
      testWidgets('reduce motion ($flag) alone snaps', (tester) async {
        final viaMediaQuery = flag.startsWith('MediaQuery');
        if (!viaMediaQuery) {
          tester.platformDispatcher.accessibilityFeaturesTestValue =
              const FakeAccessibilityFeatures(reduceMotion: true);
          addTearDown(
            tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
          );
        }
        final camera = await pumpEmpty(tester);
        await settleAt(
          tester,
          [at(camera, 'aa', start)],
          disableAnimations: viaMediaQuery,
        );
        await deliver(
          tester,
          [at(camera, 'aa', end)],
          disableAnimations: viaMediaQuery,
        );
        expect((tip(tester, 'aa') - end).distance, lessThan(1e-3));
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.hasRunningAnimations, isFalse);
      });
    }

    testWidgets('a camera pan mid-glide keeps the pin on its geo point', (
      tester,
    ) async {
      final controller = MapController();
      addTearDown(controller.dispose);
      final camera = await pumpEmpty(tester, controller: controller);
      final from = at(camera, 'aa', start);
      final to = at(camera, 'aa', end);
      await settleAt(tester, [from], controller: controller);
      await deliver(tester, [to], controller: controller);
      await tester.pump(glideTime);

      controller.move(
        controller.camera.screenOffsetToLatLng(const Offset(500, 300)),
        controller.camera.zoom,
      );
      await tester.pump();
      final expected = glideLerp(
        fix(from),
        fix(to),
        Curves.easeOutCubic.transform(0.5),
      );
      final onScreen = cameraOf(tester).latLngToScreenOffset(expected);
      expect(onScreen.dx, lessThan(450), reason: 'the pan really moved it');
      expect((tip(tester, 'aa') - onScreen).distance, lessThan(1e-3));
    });

    testWidgets('a member that departs mid-glide fades out where it was', (
      tester,
    ) async {
      final camera = await pumpEmpty(tester);
      final other = at(camera, 'bb', const Offset(300, 450));
      await settleAt(tester, [at(camera, 'aa', start), other]);
      await deliver(tester, [at(camera, 'aa', end), other]);
      await tester.pump(glideTime);
      final before = tip(tester, 'aa');
      expect((before - end).distance, greaterThan(20));

      await tester.pumpWidget(app([other]));
      expect(find.byKey(WidgetKeys.memberMarker('aa')), findsOneWidget);
      expect((tip(tester, 'aa') - before).distance, lessThan(1e-3));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        (tip(tester, 'aa') - before).distance,
        lessThan(1e-3),
        reason: 'the fade-out neither jumps to the true fix nor keeps gliding',
      );
    });

    testWidgets('a move between two off-screen points snaps', (tester) async {
      final camera = await pumpEmpty(tester);
      final size = camera.nonRotatedSize;
      final viewport = edgeViewport(
        viewport: size,
        topInset: 0,
        bottomInset: 0,
      );
      final from = Offset(size.width + 100, 300);
      final to = Offset(size.width + 100, 420);
      await settleAt(tester, [at(camera, 'aa', from)]);
      await deliver(tester, [at(camera, 'aa', to)]);
      final head = tester.getCenter(find.byKey(WidgetKeys.memberMarker('aa')));
      expect(
        (head - projectMarker(point: to, viewport: viewport).bubbleCenter)
            .distance,
        lessThan(1e-3),
      );
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('a move from on-screen to off-screen still glides', (
      tester,
    ) async {
      final camera = await pumpEmpty(tester);
      final size = camera.nonRotatedSize;
      final viewport = edgeViewport(
        viewport: size,
        topInset: 0,
        bottomInset: 0,
      );
      final from = Offset(size.width - 20, 300);
      final to = Offset(size.width + 100, 300);
      await settleAt(tester, [at(camera, 'aa', from)]);
      await deliver(tester, [at(camera, 'aa', to)]);
      final head = tester.getCenter(find.byKey(WidgetKeys.memberMarker('aa')));
      expect(
        (head - projectMarker(point: from, viewport: viewport).bubbleCenter)
            .distance,
        lessThan(1e-3),
        reason: 'the glide starts from the old point rather than snapping',
      );
      expect(tester.hasRunningAnimations, isTrue);
    });

    testWidgets('the focus callback receives the true fix mid-glide', (
      tester,
    ) async {
      MemberLocation? focused;
      final camera = await pumpEmpty(tester);
      final size = camera.nonRotatedSize;
      final from = at(camera, 'aa', Offset(size.width - 20, 300));
      final to = at(camera, 'aa', Offset(size.width + 100, 300));
      await tester.pumpWidget(app([from], onFocusMember: (m) => focused = m));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpWidget(app([to], onFocusMember: (m) => focused = m));
      await tester.pump();
      await tester.pump(glideTime);
      expect(
        tester.widget<MemberMarker>(
          find.byKey(WidgetKeys.memberMarker('aa')),
        ).offScreen,
        isTrue,
        reason: 'mid-glide the pin has already crossed the edge',
      );

      await tester.tap(find.byKey(WidgetKeys.memberMarker('aa')));
      expect(focused?.latitude, to.latitude);
      expect(focused?.longitude, to.longitude);
    });

    testWidgets('nothing runs at rest after the glide lands', (tester) async {
      final camera = await pumpEmpty(tester);
      await settleAt(tester, [at(camera, 'aa', start)]);
      expect(tester.hasRunningAnimations, isFalse);
      await deliver(tester, [at(camera, 'aa', end)]);
      expect(tester.hasRunningAnimations, isTrue);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.hasRunningAnimations, isFalse);
    });
  });
}
