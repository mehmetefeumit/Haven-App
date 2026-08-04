/// Tests for [ClockSkewBanner] — the surface that stops a wrong device clock
/// from being a silent outage.
///
/// The copy-resolution branches are asserted as a pure function, and the widget
/// tests cover the two things a pure test cannot: that the banner is absent
/// while the clock looks fine (so it is safe to place unconditionally), and
/// that the whole status is a single screen-reader live region rather than two
/// orphaned fragments.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/clock_skew_detector.dart';
import 'package:haven/src/widgets/location/clock_skew_banner.dart';

import '../../helpers/localized_app_harness.dart';

void main() {
  late AppLocalizations l10n;

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('en'));
  });

  group('resolveClockSkewCopy', () {
    test('says nothing when the clock looks fine', () {
      expect(resolveClockSkewCopy(ClockSkewStatus.healthy, l10n), isNull);
    });

    test('names the clock, not a generic failure, for a relay rejection', () {
      final copy = resolveClockSkewCopy(
        const ClockSkewStatus(
          signal: ClockSkewSignal.relayRejectedTimestamp,
          complaint: DeviceClockComplaint.ahead,
        ),
        l10n,
      );
      expect(copy, isNotNull);
      expect(copy!.title, l10n.clockSkewTitle);
      expect(copy.message, l10n.clockSkewBodyRejected);
    });

    test('uses different wording for the invisible (behind) failure', () {
      // The two faults are different user experiences: rejected means the
      // location went nowhere, behind means it was sent and quietly discarded.
      // One shared sentence would make the second one a lie.
      final rejected = resolveClockSkewCopy(
        const ClockSkewStatus(
          signal: ClockSkewSignal.relayRejectedTimestamp,
        ),
        l10n,
      );
      final behind = resolveClockSkewCopy(
        const ClockSkewStatus(
          signal: ClockSkewSignal.peersAheadOfDevice,
          complaint: DeviceClockComplaint.behind,
          offsetSecs: 21600,
          corroboratingSources: 2,
        ),
        l10n,
      );
      expect(behind, isNotNull);
      expect(behind!.message, isNot(rejected!.message));
    });

    test('never renders the measured offset', () {
      // A precise-looking magnitude is a claim a handful of samples does not
      // support, and the remedy is identical at every magnitude.
      final copy = resolveClockSkewCopy(
        const ClockSkewStatus(
          signal: ClockSkewSignal.peersAheadOfDevice,
          complaint: DeviceClockComplaint.behind,
          offsetSecs: 21600,
          corroboratingSources: 2,
        ),
        l10n,
      )!;
      expect(copy.message, isNot(contains('21600')));
      expect(copy.message, isNot(contains('6 h')));
    });
  });

  group('ClockSkewBanner', () {
    Future<void> pump(WidgetTester tester, ClockSkewDetector detector) =>
        pumpLocalized(
          tester,
          const Scaffold(body: ClockSkewBanner()),
          overrides: [
            clockSkewDetectorProvider.overrideWithValue(detector),
          ],
        );

    testWidgets('renders nothing while the clock looks fine', (tester) async {
      final detector = ClockSkewDetector();
      addTearDown(detector.dispose);

      await pump(tester, detector);

      expect(find.byType(Card), findsNothing);
      expect(find.text(l10n.clockSkewTitle), findsNothing);
    });

    testWidgets('appears when a relay blames the clock', (tester) async {
      final detector = ClockSkewDetector();
      addTearDown(detector.dispose);

      await pump(tester, detector);
      detector.recordPublishClockRejection('ahead');
      await tester.pumpAndSettle();

      expect(find.text(l10n.clockSkewTitle), findsOneWidget);
      expect(find.text(l10n.clockSkewBodyRejected), findsOneWidget);
    });

    testWidgets('clears when the clock is fixed', (tester) async {
      final detector = ClockSkewDetector();
      addTearDown(detector.dispose);

      await pump(tester, detector);
      detector.recordPublishClockRejection('ahead');
      await tester.pumpAndSettle();
      expect(find.text(l10n.clockSkewTitle), findsOneWidget);

      detector.reset();
      await tester.pumpAndSettle();
      expect(find.text(l10n.clockSkewTitle), findsNothing);
    });

    testWidgets('speaks cause and remedy as one live region', (tester) async {
      final handle = tester.ensureSemantics();
      final detector = ClockSkewDetector();
      addTearDown(detector.dispose);

      await pump(tester, detector);
      detector.recordPublishClockRejection('ahead');
      await tester.pumpAndSettle();

      // A single node carrying BOTH sentences: a screen-reader user must not
      // have to swipe between two fragments to learn why sharing stopped.
      expect(
        find.bySemanticsLabel(
          '${l10n.clockSkewTitle}\n${l10n.clockSkewBodyRejected}',
        ),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('announces the recovery, which a live region cannot', (
      tester,
    ) async {
      // `clockSkewResolvedAnnouncement` exists because a live region announces
      // its APPEARANCE and never its removal: without this a screen-reader
      // user is told their sharing is broken and never told it was fixed.
      // Untested until now, i.e. the key was one refactor away from being as
      // dead as `clockSkewAnnouncement` already is.
      final announcements = <String>[];
      tester.binding.defaultBinaryMessenger
          .setMockDecodedMessageHandler<dynamic>(SystemChannels.accessibility, (
        dynamic message,
      ) async {
        final map = message! as Map<Object?, Object?>;
        if (map['type'] == 'announce') {
          final data = map['data']! as Map<Object?, Object?>;
          announcements.add(data['message']! as String);
        }
        return null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger
            .setMockDecodedMessageHandler<dynamic>(
              SystemChannels.accessibility,
              null,
            ),
      );

      final detector = ClockSkewDetector();
      addTearDown(detector.dispose);

      await pump(tester, detector);
      detector.recordPublishClockRejection('ahead');
      await tester.pumpAndSettle();
      expect(announcements, isEmpty, reason: 'nothing to un-say yet');

      detector.reset();
      await tester.pumpAndSettle();

      expect(announcements, [l10n.clockSkewResolvedAnnouncement]);
    });

    testWidgets('stays on screen at a 200% text scale on the smallest phone', (
      tester,
    ) async {
      // Same unbounded-height shape as the location banner: with only a `top:`
      // in the shell's `PositionedDirectional` the card ran off the viewport in
      // silence — a `RenderFlex` cannot report an overflow it cannot measure.
      // The body scrolls now, so a bounded slot keeps all of it reachable.
      const viewport = Size(320, 568);
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = viewport;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final detector = ClockSkewDetector()
        ..recordPublishClockRejection('ahead');
      addTearDown(detector.dispose);

      await pumpLocalized(
        tester,
        const Scaffold(body: ClockSkewBanner()),
        textScaler: const TextScaler.linear(2),
        overrides: [clockSkewDetectorProvider.overrideWithValue(detector)],
      );

      final card = tester.getRect(find.byType(Card));
      expect(
        card.bottom,
        lessThanOrEqualTo(viewport.height),
        reason: 'the card runs off the bottom of the screen at a 200% text '
            'scale, taking the remedy sentence with it',
      );
      expect(find.byType(SingleChildScrollView), findsOneWidget);
      expect(find.text(l10n.clockSkewBodyRejected), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
