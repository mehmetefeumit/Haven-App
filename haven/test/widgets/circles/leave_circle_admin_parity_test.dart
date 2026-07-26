/// Tests that a circle's admin gets the SAME Leave Circle affordance as any
/// other member in `CirclesBottomSheet`.
///
/// Verifies that:
/// - An admin's Leave Circle CTA is present and enabled.
/// - A non-admin member's Leave Circle CTA is present and enabled.
/// - Neither viewer is shown a caveat/limitation note beside the CTA.
///
/// Context: Haven previously shipped an admin-only note saying an admin could
/// leave only after every other member had, because
/// `propose_admin_handoff` / `propose_self_demote` were stubbed out on the
/// assumption that MDK exposed no admin-policy component codec. It does — both
/// now ride `UpdateAppComponents(admin-policy.v1)` and `LeavePlan.adminHandoff`
/// completes end-to-end (`haven-core/src/circle/manager.rs`
/// `admin_handoff_end_to_end`). This suite is the UI-side regression pin: an
/// admin must never again be visually gated or warned off the leave flow.
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

/// Fails if any text in the tree warns the viewer that leaving is conditional.
/// Matches on meaning-bearing fragments rather than one exact string, so a
/// reworded caveat cannot slip past the pin.
void _expectNoLeaveCaveat() {
  const forbidden = <String>[
    'only leave once',
    'can only leave',
    'other member has left',
    'hand off',
  ];
  for (final fragment in forbidden) {
    expect(
      find.textContaining(fragment),
      findsNothing,
      reason:
          'The circle-details sheet must not warn any viewer that leaving is '
          'conditional — admin handoff completes end-to-end, so a caveat '
          'containing "$fragment" would be telling the user something false.',
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('admin viewing their own circle gets an enabled Leave CTA', (
    tester,
  ) async {
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

    // The admin's Leave Circle button must be present and ENABLED. A null
    // onPressed here would mean the UI re-introduced a gate that the
    // protocol no longer imposes.
    final leaveButton = tester.widget<OutlinedButton>(
      find.byKey(WidgetKeys.leaveCircleCta),
    );
    expect(leaveButton.onPressed, isNotNull);
    _expectNoLeaveCaveat();
  });

  testWidgets('non-admin member gets the same enabled Leave CTA', (
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

    final leaveButton = tester.widget<OutlinedButton>(
      find.byKey(WidgetKeys.leaveCircleCta),
    );
    expect(leaveButton.onPressed, isNotNull);
    _expectNoLeaveCaveat();
  });
}
