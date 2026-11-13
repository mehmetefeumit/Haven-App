/// The sharing card's home: Circle details, opened from the circles sheet.
///
/// Retargets the map-slot layering promise (the card must be readable and its
/// remedy reachable wherever it lives) to the sheet that now hosts it (OD-1).
/// For every snap detent the circles sheet rests at, on a common phone and the
/// smallest supported one, at 1.0× and 2.0× text, left-to-right and Arabic:
/// the details open from the circle's details button — the attention cue,
/// while the circle needs attention — nothing throws, the card is met first
/// after the title, its remedy is hit-testable and inside the viewport once
/// scrolled to, and Leave is still reachable below it.
library;

import 'dart:math';

import 'package:flutter/gestures.dart' show HitTestResult;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/join_watcher_provider.dart';
import 'package:haven/src/providers/location_sharing_provider.dart';
import 'package:haven/src/providers/relay_preferences_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/providers/sharing_health_provider.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/widgets/circles/circles_bottom_sheet.dart';

import '../../helpers/localized_app_harness.dart';
import '../../helpers/sheet_health_overrides.dart';
import '../../mocks/mock_circle_service.dart';
import '../../mocks/mock_relay_service.dart';

const _selfPubkey =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

class _StubInboxRelays extends InboxRelaysNotifier {
  @override
  Future<List<String>> build() async => ['wss://relay.example'];
}

/// A fault with a body, an age and the Repair remedy: the tallest card.
class _Fault extends SharingHealthNotifier {
  @override
  SharingHealth build() => SharingHealth.paused(
    SharingPausedReason.awaitingRelays,
    DateTime.utc(2026, 8, 28, 12),
  );

  @override
  Future<void> refresh() async {}
}

final Circle _circle = TestCircleFactory.createCircle(
  displayName: 'Family',
  relays: const ['wss://relay.damus.io', 'wss://nos.lol'],
  members: [TestCircleFactory.createMember(pubkey: _selfPubkey, isAdmin: true)],
);

/// Whether a hit test at [finder]'s centre reaches it.
bool _hitTestReaches(WidgetTester tester, Finder finder) {
  final centre = tester.getCenter(finder);
  final target = tester.renderObject(finder);
  final result = HitTestResult();
  WidgetsBinding.instance.hitTestInView(result, centre, tester.view.viewId);
  return result.path.any((entry) => entry.target == target);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final detent in kSnapSizesForTesting) {
    for (final viewport in const [Size(390, 844), Size(320, 568)]) {
      for (final scale in const [1.0, 2.0]) {
        for (final locale in const [Locale('en'), Locale('ar')]) {
          final name =
              'detent $detent, ${viewport.width.toInt()}x'
              '${viewport.height.toInt()}, ${scale}x, ${locale.languageCode}';
          testWidgets(name, (tester) async {
            tester.view
              ..devicePixelRatio = 1
              ..physicalSize = viewport;
            addTearDown(tester.view.reset);
            final controller = DraggableScrollableController();
            addTearDown(controller.dispose);

            await pumpLocalized(
              tester,
              Scaffold(
                body: Stack(
                  children: [
                    CirclesBottomSheet(
                      controller: controller,
                      onExpansionChanged: (_) {},
                    ),
                  ],
                ),
              ),
              locale: locale,
              textScaler: TextScaler.linear(scale),
              overrides: [
                ...sheetHealthOverrides(),
                sharingHealthProvider.overrideWith(_Fault.new),
                circleServiceProvider.overrideWithValue(
                  MockCircleService(circles: [_circle]),
                ),
                circlesProvider.overrideWith((ref) async => [_circle]),
                selectedCircleProvider.overrideWith((ref) => _circle),
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
                circleEpochProvider(_circle).overrideWith((_) async => 7),
              ],
            );
            if (detent != kSnapSizesForTesting.first) {
              controller.jumpTo(detent);
              await tester.pumpAndSettle();
            }

            // The header's one details button, here the cue. Where a detent
            // leaves it below the fold the sheet is pulled up first, as a
            // user must.
            final details = find.byKey(WidgetKeys.circleDetailsButton);
            if (details.evaluate().isEmpty ||
                tester.getRect(details).bottom > viewport.height) {
              await tester.drag(find.text('Family'), const Offset(0, -300));
              await tester.pumpAndSettle();
            }
            expect(
              tester.getRect(details).bottom,
              lessThanOrEqualTo(viewport.height),
            );
            await tester.tap(details);
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);

            final l10n = AppLocalizations.of(
              tester.element(find.byKey(WidgetKeys.sharingHealthBanner)),
            );
            final title = tester.getRect(find.text(l10n.circleDetailsTitle));
            final card = tester.getRect(
              find.byKey(WidgetKeys.sharingHealthBanner),
            );
            final leave = find.byKey(WidgetKeys.leaveCircleCta);
            expect(
              card.top,
              greaterThanOrEqualTo(title.bottom),
              reason: 'the card follows the title',
            );
            expect(
              card.bottom,
              lessThanOrEqualTo(tester.getRect(leave).top),
              reason: 'and comes before everything else, Leave included',
            );

            final repair = find.byKey(WidgetKeys.sharingHealthRepairButton);
            await tester.ensureVisible(repair);
            await tester.pumpAndSettle();
            final rect = tester.getRect(repair);
            expect(rect.top, greaterThanOrEqualTo(0));
            expect(rect.bottom, lessThanOrEqualTo(viewport.height));
            expect(_hitTestReaches(tester, repair), isTrue);

            await tester.ensureVisible(leave);
            await tester.pumpAndSettle();
            expect(
              tester.getRect(leave).bottom,
              lessThanOrEqualTo(viewport.height),
            );
            expect(_hitTestReaches(tester, leave), isTrue);
            expect(tester.takeException(), isNull);
          });
        }
      }
    }
  }
}
