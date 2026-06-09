/// Tests for CirclesBottomSheet widget.
///
/// Verifies that:
/// - Sheet displays circle selector dropdown
/// - Empty state is shown when no circles
/// - Members are displayed when circle is selected
/// - Dim overlay appears when dropdown is open
/// - Expansion callback is triggered correctly
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/location_sharing_provider.dart';
import 'package:haven/src/providers/map_controller_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/location_sharing_service.dart';
import 'package:haven/src/widgets/circles/circle_member_tile.dart';
import 'package:haven/src/widgets/circles/circles_bottom_sheet.dart';
import 'package:latlong2/latlong.dart' hide Circle;

import '../../mocks/mock_circle_service.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CirclesBottomSheet', () {
    testWidgets('renders without errors', (tester) async {
      final mockService = MockCircleService();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [circleServiceProvider.overrideWithValue(mockService)],
          child: MaterialApp(
            home: Scaffold(
              body: Stack(
                children: [CirclesBottomSheet(onExpansionChanged: (_) {})],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(DraggableScrollableSheet), findsOneWidget);
    });

    testWidgets('shows empty state when no circles exist', (tester) async {
      final mockService = MockCircleService(circles: []);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [circleServiceProvider.overrideWithValue(mockService)],
          child: MaterialApp(
            home: Scaffold(
              body: Stack(
                children: [CirclesBottomSheet(onExpansionChanged: (_) {})],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('No Circles Yet'), findsOneWidget);
      expect(find.text('Create Circle'), findsOneWidget);
    });

    testWidgets('shows circle selector when circles exist', (tester) async {
      final testCircles = [
        TestCircleFactory.createCircle(displayName: 'Family'),
      ];
      final mockService = MockCircleService(circles: testCircles);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [circleServiceProvider.overrideWithValue(mockService)],
          child: MaterialApp(
            home: Scaffold(
              body: Stack(
                children: [CirclesBottomSheet(onExpansionChanged: (_) {})],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // No circle selected — should show placeholder text
      expect(find.text('Select a circle'), findsOneWidget);
    });

    testWidgets('shows hint when circles exist but none selected', (
      tester,
    ) async {
      final testCircles = [
        TestCircleFactory.createCircle(displayName: 'Family'),
      ];
      final mockService = MockCircleService(circles: testCircles);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [circleServiceProvider.overrideWithValue(mockService)],
          child: MaterialApp(
            home: Scaffold(
              body: Stack(
                children: [CirclesBottomSheet(onExpansionChanged: (_) {})],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Select a circle to view members'), findsOneWidget);
    });

    testWidgets('shows circle header when circle is selected', (tester) async {
      final testMembers = [
        TestCircleFactory.createMember(
          pubkey:
              'abc123def456abc123def456abc123def456abc123def456abc123def456abcd',
          displayName: 'Alice',
          isAdmin: true,
        ),
        TestCircleFactory.createMember(
          pubkey:
              'def456abc123def456abc123def456abc123def456abc123def456abc123defg',
          displayName: 'Bob',
        ),
      ];
      final testCircle = TestCircleFactory.createCircle(
        displayName: 'Family',
        members: testMembers,
      );
      final mockService = MockCircleService(circles: [testCircle]);
      final sheetController = DraggableScrollableController();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            circleServiceProvider.overrideWithValue(mockService),
            selectedCircleProvider.overrideWith((ref) => testCircle),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Stack(
                children: [
                  CirclesBottomSheet(
                    onExpansionChanged: (_) {},
                    controller: sheetController,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Expand the sheet so header content is visible
      sheetController.jumpTo(0.5);
      await tester.pumpAndSettle();

      // Circle name appears only in the dropdown trigger (not duplicated in header)
      expect(find.text('Family'), findsOneWidget);

      // Should show member count in header
      expect(find.text('2 members'), findsOneWidget);
    });

    testWidgets('shows dim overlay when dropdown is open', (tester) async {
      final testCircles = [
        TestCircleFactory.createCircle(displayName: 'Family'),
      ];
      final mockService = MockCircleService(circles: testCircles);
      final sheetController = DraggableScrollableController();
      addTearDown(sheetController.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            circleServiceProvider.overrideWithValue(mockService),
            circleDropdownOpenProvider.overrideWith((ref) => true),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Stack(
                children: [
                  CirclesBottomSheet(
                    onExpansionChanged: (_) {},
                    controller: sheetController,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Expand the sheet so SliverFillRemaining has room to lay out
      // its child — at the 0.12 collapsed default the remaining
      // viewport is too small to render the hint.
      sheetController.jumpTo(0.5);
      await tester.pumpAndSettle();

      // Dim scrim is layered over the content (ColoredBox with
      // semi-transparent black inside the _DimmableBox stack).
      expect(find.byType(ColoredBox), findsWidgets);

      // The "select to view members" hint stays mounted underneath the
      // scrim — preserves its widget identity across dropdown toggles
      // and avoids the abrupt pop-out that the previous if/else swap
      // produced. Visually it's covered by the scrim's 0.18 alpha
      // overlay; structurally it's still in the tree.
      expect(find.text('Select a circle to view members'), findsOneWidget);
    });

    testWidgets('tapping the dim scrim closes the dropdown', (tester) async {
      final testCircles = [
        TestCircleFactory.createCircle(displayName: 'Family'),
      ];
      final mockService = MockCircleService(circles: testCircles);
      final sheetController = DraggableScrollableController();
      addTearDown(sheetController.dispose);

      late WidgetRef testRef;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            circleServiceProvider.overrideWithValue(mockService),
            circleDropdownOpenProvider.overrideWith((ref) => true),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Stack(
                children: [
                  Consumer(
                    builder: (context, ref, _) {
                      testRef = ref;
                      return CirclesBottomSheet(
                        onExpansionChanged: (_) {},
                        controller: sheetController,
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      sheetController.jumpTo(0.5);
      await tester.pumpAndSettle();

      expect(testRef.read(circleDropdownOpenProvider), isTrue);

      // Tap somewhere on the dimmed area — anywhere in the lower half
      // of the sheet hits the scrim layer inside _DimmableBox.
      final size = tester.getSize(find.byType(CirclesBottomSheet));
      await tester.tapAt(Offset(size.width / 2, size.height * 0.7));
      await tester.pumpAndSettle();

      expect(testRef.read(circleDropdownOpenProvider), isFalse);
    });

    testWidgets('handles service errors gracefully', (tester) async {
      final mockService = MockCircleService(
        shouldThrowOnGetCircles: true,
        errorMessage: 'Storage error',
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [circleServiceProvider.overrideWithValue(mockService)],
          child: MaterialApp(
            home: Scaffold(
              body: Stack(
                children: [CirclesBottomSheet(onExpansionChanged: (_) {})],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // With graceful degradation, should show empty state
      expect(find.text('No Circles Yet'), findsOneWidget);
    });
  });

  // ---------------------------------------------------------------------------
  // Tap-to-focus flow: tapping a circle member with a known last-known
  // location must move the shared MapController to that position and fire
  // [CirclesBottomSheet.onMemberFocused] so the parent shell can collapse
  // the sheet. Members without a cached location must be inert.
  // ---------------------------------------------------------------------------

  group('CirclesBottomSheet — tap-to-focus', () {
    const selfPubkey =
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    const bobPubkey =
        'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
    const carolPubkey =
        'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';

    MemberLocation makeLoc({
      required String pubkey,
      required double latitude,
      required double longitude,
    }) {
      return MemberLocation(
        pubkey: pubkey,
        latitude: latitude,
        longitude: longitude,
        geohash: '9q8',
        timestamp: DateTime.now(),
        expiresAt: DateTime.now().add(const Duration(hours: 23)),
      );
    }

    Identity buildIdentity() => Identity(
      pubkeyHex: selfPubkey,
      npub: 'npub1self',
      createdAt: DateTime(2025),
    );

    // Set up platform-channel capture for haptic feedback so the tap path
    // doesn't log a "no implementation" warning in tests. We don't assert
    // on the haptic call itself — it's a UX sprinkle, not a contract.
    setUp(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            SystemChannels.platform,
            (call) async => null,
          );
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    Future<_FakeMapController> pumpSheetWith(
      WidgetTester tester, {
      required Circle circle,
      required List<MemberLocation> locations,
      LatLng? selfLatLng,
      Identity? identity,
      VoidCallback? onMemberFocused,
    }) async {
      final mockService = MockCircleService(circles: [circle]);
      final sheetController = DraggableScrollableController();
      final fakeController = _FakeMapController();
      addTearDown(sheetController.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            circleServiceProvider.overrideWithValue(mockService),
            selectedCircleProvider.overrideWith((ref) => circle),
            memberLocationsProvider.overrideWith((_) async => locations),
            obfuscatedLocationProvider.overrideWith((_) => selfLatLng),
            identityProvider.overrideWith((_) async => identity),
            displayNameProvider.overrideWith((_) async => null),
            mapControllerProvider.overrideWithValue(fakeController),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Stack(
                children: [
                  CirclesBottomSheet(
                    onExpansionChanged: (_) {},
                    controller: sheetController,
                    onMemberFocused: onMemberFocused,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Expand the sheet to 0.85 so member tiles are laid out and tappable.
      sheetController.jumpTo(0.85);
      await tester.pumpAndSettle();

      return fakeController;
    }

    testWidgets('tapping a member with a known location moves the shared map '
        'controller to their coordinates', (tester) async {
      final bob = TestCircleFactory.createMember(
        pubkey: bobPubkey,
        displayName: 'Bob',
      );
      final circle = TestCircleFactory.createCircle(members: [bob]);
      final fake = await pumpSheetWith(
        tester,
        circle: circle,
        locations: [
          makeLoc(pubkey: bobPubkey, latitude: 37.42, longitude: -122.08),
        ],
        identity: buildIdentity(),
      );

      await tester.tap(find.byType(CircleMemberTile).first);
      await tester.pumpAndSettle();

      expect(fake.moveCalls, hasLength(1));
      final call = fake.moveCalls.single;
      expect(call.center.latitude, closeTo(37.42, 1e-9));
      expect(call.center.longitude, closeTo(-122.08, 1e-9));
    });

    testWidgets(
      'zoom floor of 14 applies when current zoom is below the threshold',
      (tester) async {
        final bob = TestCircleFactory.createMember(
          pubkey: bobPubkey,
          displayName: 'Bob',
        );
        final circle = TestCircleFactory.createCircle(members: [bob]);
        final fake = await pumpSheetWith(
          tester,
          circle: circle,
          locations: [
            makeLoc(pubkey: bobPubkey, latitude: 37.42, longitude: -122.08),
          ],
          identity: buildIdentity(),
        );
        fake.fakeCamera = fake.fakeCamera.withPosition(zoom: 10);
        // sanity — confirm our fake zoom is actually below the floor
        expect(fake.fakeCamera.zoom, lessThan(14));

        await tester.tap(find.byType(CircleMemberTile).first);
        await tester.pumpAndSettle();

        expect(fake.moveCalls.single.zoom, 14.0);
      },
    );

    testWidgets('existing zoom is preserved when already above the floor', (
      tester,
    ) async {
      final bob = TestCircleFactory.createMember(
        pubkey: bobPubkey,
        displayName: 'Bob',
      );
      final circle = TestCircleFactory.createCircle(members: [bob]);
      final fake = await pumpSheetWith(
        tester,
        circle: circle,
        locations: [
          makeLoc(pubkey: bobPubkey, latitude: 37.42, longitude: -122.08),
        ],
        identity: buildIdentity(),
      );
      fake.fakeCamera = fake.fakeCamera.withPosition(zoom: 17);

      await tester.tap(find.byType(CircleMemberTile).first);
      await tester.pumpAndSettle();

      expect(fake.moveCalls.single.zoom, 17.0);
    });

    testWidgets('tapping self uses obfuscatedLocationProvider', (tester) async {
      final self = TestCircleFactory.createMember(pubkey: selfPubkey);
      final circle = TestCircleFactory.createCircle(members: [self]);
      const selfLatLng = LatLng(51.5074, -0.1278);
      final fake = await pumpSheetWith(
        tester,
        circle: circle,
        // memberLocations never contains self (filtered upstream), but the
        // tile must still be tappable because the self path reads
        // obfuscatedLocationProvider.
        locations: const [],
        selfLatLng: selfLatLng,
        identity: buildIdentity(),
      );

      await tester.tap(find.byType(CircleMemberTile).first);
      await tester.pumpAndSettle();

      expect(fake.moveCalls, hasLength(1));
      expect(fake.moveCalls.single.center.latitude, closeTo(51.5074, 1e-9));
      expect(fake.moveCalls.single.center.longitude, closeTo(-0.1278, 1e-9));
    });

    testWidgets('tapping a member without a cached location is a no-op', (
      tester,
    ) async {
      final bob = TestCircleFactory.createMember(
        pubkey: bobPubkey,
        displayName: 'Bob',
      );
      final circle = TestCircleFactory.createCircle(members: [bob]);
      var collapseCount = 0;
      final fake = await pumpSheetWith(
        tester,
        circle: circle,
        locations: const [],
        identity: buildIdentity(),
        onMemberFocused: () => collapseCount++,
      );

      // The tile is still in the tree and still responds to hit-tests, but
      // the disabled ListTile must not invoke onTap.
      await tester.tap(find.byType(CircleMemberTile).first);
      await tester.pumpAndSettle();

      expect(fake.moveCalls, isEmpty);
      expect(collapseCount, 0);
      expect(find.text('No recent location'), findsOneWidget);
    });

    testWidgets('tapping self without an obfuscated fix yet is a no-op', (
      tester,
    ) async {
      final self = TestCircleFactory.createMember(pubkey: selfPubkey);
      final circle = TestCircleFactory.createCircle(members: [self]);
      final fake = await pumpSheetWith(
        tester,
        circle: circle,
        locations: const [],
        identity: buildIdentity(),
      );

      await tester.tap(find.byType(CircleMemberTile).first);
      await tester.pumpAndSettle();

      expect(fake.moveCalls, isEmpty);
    });

    testWidgets('onMemberFocused fires after a successful tap-to-focus', (
      tester,
    ) async {
      final bob = TestCircleFactory.createMember(
        pubkey: bobPubkey,
        displayName: 'Bob',
      );
      final circle = TestCircleFactory.createCircle(members: [bob]);
      var collapseCount = 0;
      await pumpSheetWith(
        tester,
        circle: circle,
        locations: [
          makeLoc(pubkey: bobPubkey, latitude: 37.42, longitude: -122.08),
        ],
        identity: buildIdentity(),
        onMemberFocused: () => collapseCount++,
      );

      await tester.tap(find.byType(CircleMemberTile).first);
      await tester.pumpAndSettle();

      expect(collapseCount, 1);
    });

    testWidgets(
      'my_location icon renders for tappable members and is absent for '
      'members without a location',
      (tester) async {
        final bob = TestCircleFactory.createMember(
          pubkey: bobPubkey,
          displayName: 'Bob',
        );
        final carol = TestCircleFactory.createMember(
          pubkey: carolPubkey,
          displayName: 'Carol',
        );
        final circle = TestCircleFactory.createCircle(members: [bob, carol]);
        await pumpSheetWith(
          tester,
          circle: circle,
          // Only Bob has a cached location.
          locations: [
            makeLoc(pubkey: bobPubkey, latitude: 37.42, longitude: -122.08),
          ],
          identity: buildIdentity(),
        );

        // Bob's row shows the locator icon; Carol's row shows the
        // no-location hint.
        expect(find.byIcon(LucideIcons.locateFixed), findsOneWidget);
        expect(find.text('No recent location'), findsOneWidget);
      },
    );

    testWidgets(
      'memberLocationsProvider loading state renders tiles as no-location '
      'and swallows taps without crashing',
      (tester) async {
        final bob = TestCircleFactory.createMember(
          pubkey: bobPubkey,
          displayName: 'Bob',
        );
        final circle = TestCircleFactory.createCircle(members: [bob]);
        final mockService = MockCircleService(circles: [circle]);
        final sheetController = DraggableScrollableController();
        final fakeController = _FakeMapController();
        addTearDown(sheetController.dispose);

        // Never-completing future — the provider stays in AsyncLoading for
        // the duration of the test so we exercise the `valueOrNull ?? []`
        // branch in circles_bottom_sheet.dart.
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              circleServiceProvider.overrideWithValue(mockService),
              selectedCircleProvider.overrideWith((ref) => circle),
              memberLocationsProvider.overrideWith(
                (_) => Completer<List<MemberLocation>>().future,
              ),
              obfuscatedLocationProvider.overrideWith((_) => null),
              identityProvider.overrideWith((_) async => buildIdentity()),
              displayNameProvider.overrideWith((_) async => null),
              mapControllerProvider.overrideWithValue(fakeController),
            ],
            child: MaterialApp(
              home: Scaffold(
                body: Stack(
                  children: [
                    CirclesBottomSheet(
                      onExpansionChanged: (_) {},
                      controller: sheetController,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        // pump (not pumpAndSettle — future never completes).
        await tester.pump();
        sheetController.jumpTo(0.85);
        await tester.pump();

        // Tile renders with the no-location subtitle while the provider
        // is still loading; tapping it must be inert.
        expect(find.text('No recent location'), findsOneWidget);
        expect(find.byIcon(LucideIcons.locateFixed), findsNothing);

        await tester.tap(find.byType(CircleMemberTile).first);
        await tester.pump();

        expect(fakeController.moveCalls, isEmpty);
      },
    );
  });

  // ---------------------------------------------------------------------------
  // sheetExpansionForSize: the normalization that drives the map dim overlay.
  // A residual a hair above the collapsed snap (left by the drag-release
  // velocity spring, or by MapShell's programmatic collapse) must report as
  // exactly 0 so the overlay is torn down and the map stays interactive — the
  // root-cause half of the "map frozen until I touch the panel" fix. The
  // overlay's matching pointer-routing guard lives in
  // test/widgets/common/dim_overlay_test.dart.
  // ---------------------------------------------------------------------------
  group('sheetExpansionForSize', () {
    test('reports exactly 0 at the collapsed snap', () {
      expect(sheetExpansionForSize(0.12), 0.0);
    });

    test('snaps a velocity-spring residual just above the snap to 0', () {
      // SpringSimulation completion tolerance can leave ~1e-3 of size.
      expect(sheetExpansionForSize(0.1209), 0.0);
    });

    test('snaps the worst-case programmatic-collapse residual to 0', () {
      // MapShell._animateSheetTo early-returns within 0.01 *size* of the min
      // snap, so the sheet can rest as high as 0.13 (raw expansion ~0.0137)
      // — still imperceptible, still must read as collapsed.
      expect(sheetExpansionForSize(0.13), 0.0);
    });

    test('treats sizes below the min snap as fully collapsed', () {
      // Transient spring undershoot before _onSnapTick clamps to the min.
      expect(sheetExpansionForSize(0.10), 0.0);
    });

    test('does not snap when raw expansion exceeds the epsilon band', () {
      // Just past the 0.02 epsilon band — must report the real value, not 0.
      const size = 0.12 + 0.03 * (0.85 - 0.12); // raw ≈ 0.03
      expect(sheetExpansionForSize(size), closeTo(0.03, 1e-9));
    });

    test('reports a real expansion at the mid snap', () {
      // (0.5 - 0.12) / (0.85 - 0.12) ≈ 0.5205.
      expect(sheetExpansionForSize(0.5), closeTo(0.5205, 1e-3));
    });

    test('reports 1.0 at the fully expanded snap', () {
      expect(sheetExpansionForSize(0.85), 1.0);
    });

    test('clamps oversize values to 1.0', () {
      expect(sheetExpansionForSize(0.95), 1.0);
    });
  });
}

/// Minimal test fake for flutter_map's [MapController]. Only [move] and
/// [camera] are exercised by the tap-to-focus path; everything else
/// inherits `Fake`'s `noSuchMethod` so an accidental new call in the
/// production code immediately surfaces as a test failure instead of
/// silently succeeding.
class _FakeMapController extends Fake implements MapController {
  final List<({LatLng center, double zoom})> moveCalls = [];

  MapCamera fakeCamera = MapCamera(
    crs: const Epsg3857(),
    center: const LatLng(0, 0),
    zoom: 15,
    rotation: 0,
    nonRotatedSize: const Size(400, 800),
  );

  @override
  MapCamera get camera => fakeCamera;

  @override
  bool move(
    LatLng center,
    double zoom, {
    Offset offset = Offset.zero,
    String? id,
  }) {
    moveCalls.add((center: center, zoom: zoom));
    fakeCamera = fakeCamera.withPosition(center: center, zoom: zoom);
    return true;
  }
}
