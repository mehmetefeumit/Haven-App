/// Tests for the Dark Matter cutover (DM-4c) blocked-circle banner in
/// [CirclesBottomSheet] (Security Rule 8: `CircleService.isCircleBlocked`).
///
/// Verifies that:
/// - A circle marked blocked shows the blocked banner above its (still
///   visible, read-only) member list.
/// - A healthy (not-blocked) circle never shows the blocked banner.
/// - An admin's "Add member" CTA in the circle-details sheet is hidden for a
///   blocked circle (Rule 8: no mutate), even though the cached roster still
///   shows them as admin.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/location_sharing_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/widgets/circles/circles_bottom_sheet.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../mocks/mock_circle_service.dart';

const _selfPubkey =
    'abc123def456abc123def456abc123def456abc123def456abc123def456abcd';

final _testIdentity = Identity(
  pubkeyHex: _selfPubkey,
  npub: 'npub1test',
  createdAt: DateTime(2024),
);

Widget _buildTestWidget({
  required MockCircleService mockService,
  required Circle selectedCircle,
}) {
  return ProviderScope(
    overrides: [
      circleServiceProvider.overrideWithValue(mockService),
      selectedCircleProvider.overrideWith((ref) => selectedCircle),
      identityProvider.overrideWith((_) async => _testIdentity),
      memberLocationsProvider.overrideWith((_) async => const []),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Stack(children: [CirclesBottomSheet(onExpansionChanged: (_) {})]),
      ),
    ),
  );
}

void _setTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 5000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Blocked circle banner (DM-4c, Rule 8)', () {
    testWidgets(
      'a blocked circle shows the blocked banner above its member list',
      (tester) async {
        _setTallViewport(tester);
        final circle = TestCircleFactory.createCircle(
          mlsGroupId: const [7, 7, 7],
          displayName: 'Family',
          members: [
            TestCircleFactory.createMember(
              pubkey: _selfPubkey,
              displayName: 'Alice',
              isAdmin: true,
            ),
          ],
        );
        final mockService = MockCircleService(circles: [circle])
          ..markCircleBlocked(circle.mlsGroupId);

        await tester.pumpWidget(
          _buildTestWidget(mockService: mockService, selectedCircle: circle),
        );
        await tester.pumpAndSettle();

        expect(find.text('This circle can’t be updated'), findsOneWidget);
        // The (read-only) member list is still visible underneath.
        expect(find.text('Alice'), findsOneWidget);
      },
    );

    testWidgets('a healthy circle never shows the blocked banner', (
      tester,
    ) async {
      _setTallViewport(tester);
      final circle = TestCircleFactory.createCircle(
        mlsGroupId: const [8, 8, 8],
        displayName: 'Family',
        members: [
          TestCircleFactory.createMember(
            pubkey: _selfPubkey,
            displayName: 'Alice',
            isAdmin: true,
          ),
        ],
      );
      final mockService = MockCircleService(circles: [circle]);

      await tester.pumpWidget(
        _buildTestWidget(mockService: mockService, selectedCircle: circle),
      );
      await tester.pumpAndSettle();

      expect(find.text('This circle can’t be updated'), findsNothing);
    });

    testWidgets(
      '"Add member" is hidden in the circle-details sheet for a blocked '
      'circle, even for an admin',
      (tester) async {
        _setTallViewport(tester);
        final circle = TestCircleFactory.createCircle(
          mlsGroupId: const [7, 7, 7],
          displayName: 'Family',
          members: [
            TestCircleFactory.createMember(
              pubkey: _selfPubkey,
              displayName: 'Alice',
              isAdmin: true,
            ),
          ],
        );
        final mockService = MockCircleService(circles: [circle])
          ..markCircleBlocked(circle.mlsGroupId);

        await tester.pumpWidget(
          _buildTestWidget(mockService: mockService, selectedCircle: circle),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byIcon(LucideIcons.info));
        await tester.pumpAndSettle();

        expect(find.widgetWithText(OutlinedButton, 'Add member'), findsNothing);
        // The Leave Circle action remains available (exiting a broken
        // circle is not a "send/mutate" of its content).
        expect(
          find.widgetWithText(OutlinedButton, 'Leave Circle'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      '"Add member" IS shown in the circle-details sheet for a healthy '
      'circle with an admin',
      (tester) async {
        _setTallViewport(tester);
        final circle = TestCircleFactory.createCircle(
          mlsGroupId: const [8, 8, 8],
          displayName: 'Family',
          members: [
            TestCircleFactory.createMember(
              pubkey: _selfPubkey,
              displayName: 'Alice',
              isAdmin: true,
            ),
          ],
        );
        final mockService = MockCircleService(circles: [circle]);

        await tester.pumpWidget(
          _buildTestWidget(mockService: mockService, selectedCircle: circle),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byIcon(LucideIcons.info));
        await tester.pumpAndSettle();

        expect(
          find.widgetWithText(OutlinedButton, 'Add member'),
          findsOneWidget,
        );
      },
    );
  });
}
