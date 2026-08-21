/// Layout-robustness tests for the circle-details bottom sheet.
///
/// The sheet's body is a single `Column` whose height grows with text scale,
/// translation length and relay count. It previously had no scroll parent, so
/// on a short phone at accessibility text scales it overflowed and clipped the
/// destructive "Leave Circle" action off the bottom — a user at 200% scale
/// could not leave a circle at all.
///
/// This was invisible to the whole suite because every other circles test
/// pumps an 800×5000 viewport (tall enough to expose the collapsed sheet's
/// info button), which no real device has. These tests deliberately constrain
/// the modal to a 360×690 phone *with its system-bar insets*, because
/// `useSafeArea: true` hands the modal the viewport minus the status bar —
/// a test that leaves the insets at zero certifies ~24 px of height the
/// device never gives, which is more than the margin these assertions defend.
///
/// Every check sweeps EVERY shipped locale rather than a hand-picked "longest"
/// sample: which translation is tallest is a property of wrapping at 360 px,
/// not of character count, and a sample that has to be re-justified whenever
/// the ARB changes will quietly stop containing the worst case.
///
/// Verifies, in every locale, that:
/// 1. No overflow at 1.5x.
/// 2. No overflow at 2.0x, and the Leave Circle CTA is still reachable.
/// 3. At normal scale the sheet does not become gratuitously scrollable — so
///    a drag on the body still dismisses it.
library;

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/join_watcher_provider.dart';
import 'package:haven/src/providers/location_sharing_provider.dart';
import 'package:haven/src/providers/relay_preferences_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/widgets/circles/circles_bottom_sheet.dart';

import '../../helpers/localized_app_harness.dart';
import '../../mocks/mock_circle_service.dart';
import '../../mocks/mock_relay_service.dart';

const _selfPubkey =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _otherPubkey =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

/// Every shipped locale, sourced from [AppLocalizations] rather than
/// duplicated here so the sweeps cannot drift from the actual ARB set as
/// locales are added or removed.
final List<String> _allLocaleCodes = AppLocalizations.supportedLocales
    .map((locale) => locale.languageCode)
    .toList();

/// A small phone, and the system-bar insets it reports.
///
/// `showModalBottomSheet(useSafeArea: true)` wraps the sheet in
/// `SafeArea(bottom: false)`, so the status bar — and only the status bar —
/// is taken off the height the modal gets to lay out in. The bottom inset is
/// still declared, because that is what a device reports and because a future
/// change that starts honouring it must be measured against the real value
/// rather than against zero.
const _phoneSize = Size(360, 690);
const _phoneInsets = FakeViewPadding(top: 24, bottom: 48);

class _StubInboxRelays extends InboxRelaysNotifier {
  @override
  Future<List<String>> build() async => ['wss://relay.example'];
}

Identity _identity(String pubkeyHex) => Identity(
  pubkeyHex: pubkeyHex,
  npub: 'npub1test',
  createdAt: DateTime(2024),
);

/// Worst-case content: self is admin (so the extra "Add member" CTA renders)
/// and the circle carries three relays (three `ListTile`s plus dividers).
Circle _makeCircle() => TestCircleFactory.createCircle(
  displayName: 'Family',
  relays: const [
    'wss://relay.damus.io',
    'wss://nos.lol',
    'wss://relay.primal.net',
  ],
  members: [
    TestCircleFactory.createMember(pubkey: _selfPubkey, isAdmin: true),
    TestCircleFactory.createMember(pubkey: _otherPubkey),
  ],
);

/// Opens the circle-details modal and leaves it laid out on a 360×690 phone.
///
/// The collapsed sheet sits at 12% of the viewport, so its info button is only
/// hittable on a tall surface. This opens the modal at 800×5000 and *then*
/// shrinks the view to phone size, so the modal re-lays out against the
/// constrained height — the same condition a real 360×690 device imposes,
/// reached deterministically instead of by dragging the sheet open.
Future<void> _openDetailsOnPhone(
  WidgetTester tester, {
  required Circle circle,
  required MockCircleService mockService,
  required String localeCode,
  TextScaler textScaler = TextScaler.noScaling,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(800, 5000);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPadding);
  addTearDown(tester.view.resetViewPadding);

  await pumpLocalized(
    tester,
    Scaffold(
      body: Stack(children: [CirclesBottomSheet(onExpansionChanged: (_) {})]),
    ),
    locale: Locale(localeCode),
    textScaler: textScaler,
    overrides: [
      circleServiceProvider.overrideWithValue(mockService),
      selectedCircleProvider.overrideWith((ref) => circle),
      identityProvider.overrideWith((_) async => _identity(_selfPubkey)),
      memberLocationsProvider.overrideWith((_) async => const []),
      relayServiceProvider.overrideWithValue(MockRelayService()),
      inboxRelaysProvider.overrideWith(_StubInboxRelays.new),
      joinWatcherProvider.overrideWith(
        (ref) => JoinWatcherNotifier(ref, rng: Random(0)),
      ),
      // Resolve the epoch so the subtitle is at its longest.
      circleEpochProvider(circle).overrideWith((_) async => 1408),
      // ...and the expiry. What costs this line a second row at 360 px is the
      // segment being present at all, not which unit it renders in: the
      // seconds and minutes forms measure identically here in every shipped
      // locale (they differ by at most one character, and neither fits). So
      // the sweep pins the window every Haven-created circle actually shows
      // rather than a hand-picked "widest" unit that buys nothing.
      circleLocationExpiryProvider(circle).overrideWith((_) async => 228),
    ],
  );

  await tester.tap(find.byKey(WidgetKeys.circleDetailsButton));
  await tester.pumpAndSettle();

  // Now squeeze the open modal onto a real phone surface, insets included.
  tester.view.physicalSize = _phoneSize;
  tester.view.padding = _phoneInsets;
  tester.view.viewPadding = _phoneInsets;
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('_CircleDetailsSheet — layout robustness', () {
    for (final code in _allLocaleCodes) {
      testWidgets('1. "$code" at 1.5x lays out without overflow', (
        tester,
      ) async {
        final circle = _makeCircle();

        await _openDetailsOnPhone(
          tester,
          circle: circle,
          mockService: MockCircleService(circles: [circle]),
          localeCode: code,
          textScaler: const TextScaler.linear(1.5),
        );

        expect(tester.takeException(), isNull);
      });
    }

    for (final code in _allLocaleCodes) {
      testWidgets('2. "$code" at 2.0x keeps the Leave Circle CTA reachable', (
        tester,
      ) async {
        final circle = _makeCircle();

        await _openDetailsOnPhone(
          tester,
          circle: circle,
          mockService: MockCircleService(circles: [circle]),
          localeCode: code,
          textScaler: const TextScaler.linear(2),
        );

        expect(tester.takeException(), isNull);

        // The regression guard. `ensureVisible` needs a Scrollable ancestor,
        // so it fails outright if the sheet body ever loses its scroll parent
        // — and it proves the destructive action can actually be brought on
        // screen rather than being clipped off the bottom.
        await tester.ensureVisible(find.byKey(WidgetKeys.leaveCircleCta));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.byKey(WidgetKeys.leaveCircleCta), findsOneWidget);
      });
    }

    // -----------------------------------------------------------------------
    // 3. Every locale: not gratuitously scrollable, so drag-to-dismiss works.
    //
    // Nesting a Scrollable inside a modal bottom sheet can hand the vertical
    // drag to the inner scroll view and kill drag-to-dismiss. It does not
    // here: `mainAxisSize.min` content-sizes the sheet, so at 1.0x this
    // content fits a 690px phone, maxScrollExtent is 0, the scroll physics
    // decline the drag, and it bubbles to the modal. A translation that is
    // merely long enough to avoid the 1.5x overflow checked above can still
    // be long enough to make the sheet scrollable at *normal* scale — this
    // sweeps every shipped locale so that failure mode is caught here rather
    // than silently shipping a broken dismiss gesture in one language.
    // -----------------------------------------------------------------------
    for (final code in _allLocaleCodes) {
      testWidgets(
        '3. "$code" at normal scale the sheet is not gratuitously '
        'scrollable, so dragging the body still dismisses it',
        (tester) async {
          final circle = _makeCircle();

          await _openDetailsOnPhone(
            tester,
            circle: circle,
            mockService: MockCircleService(circles: [circle]),
            localeCode: code,
          );

          expect(tester.takeException(), isNull);

          // Diagnostic: pinpoints "the sheet became scrollable" as the exact
          // defect when the behavioural drag assertion below fails.
          final position = tester
              .widget<Scrollable>(
                find
                    .ancestor(
                      of: find.byKey(WidgetKeys.leaveCircleCta),
                      matching: find.byType(Scrollable),
                    )
                    .first,
              )
              .controller
              ?.position;
          expect(
            position?.maxScrollExtent ?? 0,
            0,
            reason:
                '"$code" makes the sheet body scrollable at 1.0x scale — a '
                'translation is too long for this sheet',
          );

          // The behaviour that actually matters, proven directly rather than
          // inferred from the scroll-extent proxy above: a downward drag on
          // the body must still dismiss the modal.
          await tester.drag(
            find.byKey(WidgetKeys.leaveCircleCta),
            const Offset(0, 600),
          );
          await tester.pumpAndSettle();

          expect(
            find.byKey(WidgetKeys.leaveCircleCta),
            findsNothing,
            reason:
                '"$code" leaves the sheet body scrollable at 1.0x, so the '
                'drag scrolled instead of dismissing the modal',
          );
        },
      );
    }
  });
}
