/// Tests for the admin-only "can only leave last" note next to the Leave
/// Circle button in CirclesBottomSheet.
///
/// Verifies that:
/// - The note IS shown when the viewing user is the circle's admin.
/// - The note is NOT shown to a non-admin member (it would be irrelevant
///   and confusing, since the limitation does not apply to them).
///
/// Context (see `circles_bottom_sheet.dart` and
/// `docs/MDK_DARKMATTER_MIGRATION_PLAN.md`): MDK v0.9.4's public API
/// exposes no admin-policy component codec (upstream mdk#755), so an admin
/// can currently only leave a circle once every other member has already
/// left.
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
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/widgets/circles/circles_bottom_sheet.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../mocks/mock_circle_service.dart';

final _testIdentity = Identity(
  pubkeyHex: 'abc123def456abc123def456abc123def456abc123def456abc123def456abcd',
  npub: 'npub1test',
  createdAt: DateTime(2024),
);

const _otherPubkey =
    'def456abc123def456abc123def456abc123def456abc123def456abc123defg';

/// Builds the test harness with a selected circle and overrides, mirroring
/// `leave_circle_test.dart`'s harness.
Widget _buildTestWidget({
  required MockCircleService mockService,
  required Circle selectedCircle,
}) {
  return ProviderScope(
    overrides: [
      circleServiceProvider.overrideWithValue(mockService),
      selectedCircleProvider.overrideWith((ref) => selectedCircle),
      identityProvider.overrideWith((_) async => _testIdentity),
      // Stub out location fetching — it reaches into Rust FFI which is
      // unavailable in widget tests, and this suite does not exercise
      // location data.
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

/// Makes the viewport tall enough for the collapsed sheet (12%) to show the
/// circle header with the info button.
void _setTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 5000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Opens the circle-details sheet from the info button.
Future<void> _openCircleDetails(WidgetTester tester) async {
  await tester.tap(find.byIcon(LucideIcons.info));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'admin viewing their own circle sees the leave-limitation note',
    (tester) async {
      _setTallViewport(tester);
      final circle = TestCircleFactory.createCircle(
        displayName: 'Family',
        members: [
          // Default pubkey matches _testIdentity.pubkeyHex, so this is
          // "self", and is the admin.
          TestCircleFactory.createMember(displayName: 'Self', isAdmin: true),
          TestCircleFactory.createMember(
            pubkey: _otherPubkey,
            displayName: 'Bob',
          ),
        ],
      );
      final mockService = MockCircleService(circles: [circle]);

      await tester.pumpWidget(
        _buildTestWidget(mockService: mockService, selectedCircle: circle),
      );
      await tester.pumpAndSettle();

      await _openCircleDetails(tester);

      expect(
        find.byKey(WidgetKeys.leaveCircleAdminLimitationNote),
        findsOneWidget,
      );
      expect(
        find.text(
          "As this circle's admin, you can only leave once every other "
          "member has left. We know that's inconvenient — a future "
          'update will let admins hand off and leave directly.',
        ),
        findsOneWidget,
      );

      // The Leave Circle button itself must remain enabled — the note is
      // informational only and must never disable it (the sole-remaining
      // -member "abandon" path still needs to work).
      final leaveButton = tester.widget<OutlinedButton>(
        find.byKey(WidgetKeys.leaveCircleCta),
      );
      expect(leaveButton.onPressed, isNotNull);
    },
  );

  testWidgets('non-admin member does not see the leave-limitation note', (
    tester,
  ) async {
    _setTallViewport(tester);
    final circle = TestCircleFactory.createCircle(
      displayName: 'Family',
      members: [
        // Default pubkey matches _testIdentity.pubkeyHex ("self"), but
        // NOT admin here — Bob is the admin instead.
        TestCircleFactory.createMember(displayName: 'Self'),
        TestCircleFactory.createMember(
          pubkey: _otherPubkey,
          displayName: 'Bob',
          isAdmin: true,
        ),
      ],
    );
    final mockService = MockCircleService(circles: [circle]);

    await tester.pumpWidget(
      _buildTestWidget(mockService: mockService, selectedCircle: circle),
    );
    await tester.pumpAndSettle();

    await _openCircleDetails(tester);

    // The Leave Circle button is still present and enabled for non-admins...
    expect(find.byKey(WidgetKeys.leaveCircleCta), findsOneWidget);
    // ...but the admin-only note must not be shown to them.
    expect(
      find.byKey(WidgetKeys.leaveCircleAdminLimitationNote),
      findsNothing,
    );
  });
}
