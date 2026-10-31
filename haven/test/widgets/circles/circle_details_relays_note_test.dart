/// The circle-details relay note must stay true for every circle it renders
/// under.
///
/// The sheet shows `circle.relays` for circles created by older Haven
/// versions (the invited members' inbox relays), circles joined from another
/// app (that app's choice) and new circles (Haven's own pick), and the circle
/// records none of these. A note naming any one derivation is false for the
/// others, so these tests pin the claims known to be false, not the wording.
library;

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/join_watcher_provider.dart';
import 'package:haven/src/providers/location_sharing_provider.dart';
import 'package:haven/src/providers/relay_preferences_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/providers/sharing_health_provider.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/widgets/circles/circles_bottom_sheet.dart';

import '../../helpers/localized_app_harness.dart';
import '../../mocks/mock_circle_service.dart';
import '../../mocks/mock_relay_service.dart';

const _selfPubkey =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

class _StubInboxRelays extends InboxRelaysNotifier {
  @override
  Future<List<String>> build() async => ['wss://relay.example'];
}

/// Opens the circle-details modal for a circle with three relays, in English.
Future<void> _openDetails(WidgetTester tester) async {
  // The collapsed sheet's info button is hittable only on a tall surface.
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(800, 5000);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final circle = TestCircleFactory.createCircle(
    displayName: 'Family',
    relays: const [
      'wss://relay-one.example',
      'wss://relay-two.example',
      'wss://relay-three.example',
    ],
    members: [
      TestCircleFactory.createMember(pubkey: _selfPubkey, isAdmin: true),
    ],
  );

  await pumpLocalized(
    tester,
    Scaffold(
      body: Stack(children: [CirclesBottomSheet(onExpansionChanged: (_) {})]),
    ),
    overrides: [
      circleServiceProvider.overrideWithValue(
        MockCircleService(circles: [circle]),
      ),
      selectedCircleProvider.overrideWith((ref) => circle),
      identityProvider.overrideWith(
        (_) async => Identity(
          pubkeyHex: _selfPubkey,
          npub: 'npub1test',
          createdAt: DateTime(2024),
        ),
      ),
      memberLocationsProvider.overrideWith((_) async => const []),
      relayServiceProvider.overrideWithValue(MockRelayService()),
      inboxRelaysProvider.overrideWith(_StubInboxRelays.new),
      joinWatcherProvider.overrideWith(
        (ref) => JoinWatcherNotifier(ref, rng: Random(0)),
      ),
      circleEpochProvider(circle).overrideWith((_) async => 1),
      circleLocationExpiryProvider(
        circle,
      ).overrideWith((_) async => kLocationMessageRetention.inSeconds),
    ],
  );

  await tester.tap(find.byKey(WidgetKeys.circleDetailsButton));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the relay note renders under a circle with three relays', (
    tester,
  ) async {
    await _openDetails(tester);
    final l10n = l10nOf(tester, CirclesBottomSheet);

    expect(find.text('relay-one.example'), findsOneWidget);
    expect(find.text('relay-two.example'), findsOneWidget);
    expect(find.text('relay-three.example'), findsOneWidget);
    expect(find.text(l10n.circleDetailsRelaysNote), findsOneWidget);
  });

  testWidgets('the English relay note names no derivation that is false for '
      'some circle', (tester) async {
    await _openDetails(tester);
    final note = l10nOf(
      tester,
      CirclesBottomSheet,
    ).circleDetailsRelaysNote.toLowerCase();

    for (final claim in const [
      'invited members',
      'inbox relays',
      'random',
      'pool',
      'never your profile',
    ]) {
      expect(note, isNot(contains(claim)), reason: claim);
    }
  });
}
