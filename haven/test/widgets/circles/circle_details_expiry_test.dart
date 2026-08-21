/// Tests for the relay-expiry segment on the _CircleDetailsSheet
/// member-count line.
///
/// Haven asks relays to drop location messages after a retention window. In a
/// circle Haven created that window is its own 228 s ("about four minutes"),
/// and the segment is pure noise. In a circle created by another Marmot client
/// the creator declares the window and Haven honours a SHORTER one — so a
/// creator declaring seconds has every Haven member's location dropped by
/// relays almost immediately. Without this segment that failure is invisible
/// and indistinguishable from a bug.
///
/// The segment must therefore be *visible* without *costing space*: it rides
/// the same dim subtitle as the epoch, and whenever the window cannot be read
/// it disappears without leaving a separator or moving the line.
///
/// Verifies that:
/// 1. A Haven-created circle reads "· expiry 4 min".
/// 2. A foreign circle's seconds-long window is shown as seconds, and is
///    visibly distinguishable from the common case.
/// 3. Unit and rounding boundaries.
/// 4. An unreadable window leaves no segment, no orphan separator, and does
///    not move the line.
/// 5. A failed read leaks no error text (Security Rule 8).
/// 6. The real provider yields null for a non-Nostr-backed circle service.
/// 7. What a screen reader is actually given.
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/location.dart';
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

/// Haven's own window (`LOCATION_MESSAGE_RETENTION_SECS`), which every circle
/// Haven created declares and which caps every longer foreign declaration.
///
/// Derived from the two constants the app itself derives it from, never
/// re-typed: a third copy of `228` would keep this file green against its own
/// stale literal while the sheet rendered a different number. The rendered
/// "4 min" below is left literal on purpose — moving the window must fail
/// here loudly, because "about four minutes" is also a privacy-copy claim.
final int _havensOwnWindowSecs =
    kLocationPublishMaxInterval.inSeconds + 2 * kTtlNetworkBufferSeconds;

class _StubInboxRelays extends InboxRelaysNotifier {
  @override
  Future<List<String>> build() async => ['wss://relay.example'];
}

Identity _identity(String pubkeyHex) => Identity(
  pubkeyHex: pubkeyHex,
  npub: 'npub1test',
  createdAt: DateTime(2024),
);

/// A two-member circle, so the plural branch of `commonMemberCount` is used.
Circle _makeCircle() => TestCircleFactory.createCircle(
  displayName: 'Family',
  members: [
    TestCircleFactory.createMember(pubkey: _selfPubkey, isAdmin: true),
    TestCircleFactory.createMember(pubkey: _otherPubkey),
  ],
);

/// Pumps [CirclesBottomSheet] with [circle] selected and opens the details
/// modal.
///
/// [expiryOverride] replaces the expiry read for exactly this circle; passing
/// none leaves the real provider in place, which resolves to `null` because
/// [MockCircleService] is not a `NostrCircleService`. The epoch is pinned to
/// 14 throughout so every assertion below is about the expiry segment and not
/// about the epoch's own degradation, and the locale is the harness default
/// (English) because these tests read the copy itself.
Future<void> _pumpAndOpenDetails(
  WidgetTester tester, {
  required Circle circle,
  required MockCircleService mockService,
  Override? expiryOverride,
}) async {
  tester.view.physicalSize = const Size(800, 5000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await pumpLocalized(
    tester,
    Scaffold(
      body: Stack(children: [CirclesBottomSheet(onExpansionChanged: (_) {})]),
    ),
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
      circleEpochProvider(circle).overrideWith((_) async => 14),
      if (expiryOverride != null) expiryOverride,
    ],
  );

  await tester.tap(find.byKey(WidgetKeys.circleDetailsButton));
  await tester.pumpAndSettle();
}

/// Override resolving the expiry for [circle] to [secs].
Override _expiry(Circle circle, int? secs) =>
    circleLocationExpiryProvider(circle).overrideWith((_) async => secs);

/// The rendered text of the keyed subtitle in the details sheet.
String _subtitle(WidgetTester tester) {
  final finder = find.byKey(WidgetKeys.circleDetailsMembers);
  expect(
    finder,
    findsOneWidget,
    reason: 'the details sheet must render exactly one subtitle',
  );
  final text = tester.widget<Text>(finder);
  expect(
    text.data,
    isNotNull,
    reason:
        'the subtitle must stay a plain Text: splitting it into a Text.rich '
        'would break the single-l10n-key contract that lets each locale '
        'choose its own separator and word order',
  );
  return text.data!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('_CircleDetailsSheet — relay-expiry segment', () {
    // -----------------------------------------------------------------------
    // 1. The common case: a circle Haven created.
    // -----------------------------------------------------------------------
    testWidgets('1. a Haven-created circle reads "expiry 4 min"', (
      tester,
    ) async {
      final circle = _makeCircle();

      await _pumpAndOpenDetails(
        tester,
        circle: circle,
        mockService: MockCircleService(circles: [circle]),
        expiryOverride: _expiry(circle, _havensOwnWindowSecs),
      );

      // 228 s is not four minutes exactly; "about four minutes" is what the
      // privacy copy states and 4 min is what the user must read here.
      expect(_subtitle(tester), '2 members · epoch 14 · expiry 4 min');
    });

    testWidgets('2. the segment rides the subtitle, never a row of its own', (
      tester,
    ) async {
      final circle = _makeCircle();

      await _pumpAndOpenDetails(
        tester,
        circle: circle,
        mockService: MockCircleService(circles: [circle]),
        expiryOverride: _expiry(circle, _havensOwnWindowSecs),
      );

      // The owner's constraint is that this costs no space. If it ever became
      // a row, a card or a section, "4 min" would appear somewhere that is not
      // the one dim subtitle — so exactly one widget in the whole sheet may
      // carry it, and it must be that subtitle.
      expect(find.textContaining('4 min'), findsOneWidget);
      expect(
        tester.widget<Text>(find.textContaining('4 min')).key,
        WidgetKeys.circleDetailsMembers,
      );
      expect(find.text('Circle details'), findsWidgets);
    });

    // -----------------------------------------------------------------------
    // 3. The case the feature exists for: a foreign circle declaring seconds.
    // -----------------------------------------------------------------------
    testWidgets('3. a seconds-long foreign window is shown, not rounded away', (
      tester,
    ) async {
      final circle = _makeCircle();

      await _pumpAndOpenDetails(
        tester,
        circle: circle,
        mockService: MockCircleService(circles: [circle]),
        expiryOverride: _expiry(circle, 1),
      );

      expect(_subtitle(tester), '2 members · epoch 14 · expiry 1 sec');
    });

    testWidgets('4. the short window is distinguishable from the usual one', (
      tester,
    ) async {
      final circle = _makeCircle();

      await _pumpAndOpenDetails(
        tester,
        circle: circle,
        mockService: MockCircleService(circles: [circle]),
        expiryOverride: _expiry(circle, 1),
      );
      final short = _subtitle(tester);

      // The whole point is that a user can TELL the two apart at a glance. A
      // renderer that collapsed everything under a minute to "under a minute",
      // or that rounded 1 s up to a minute, would pass test 3's shape but
      // fail here against the number a healthy circle shows.
      expect(short, isNot(contains('4 min')));
      expect(short, contains('1 sec'));
    });

    // -----------------------------------------------------------------------
    // 5. Unit and rounding boundaries.
    // -----------------------------------------------------------------------
    for (final (secs, expected) in [
      (1, 'expiry 1 sec'),
      (30, 'expiry 30 sec'),
      (59, 'expiry 59 sec'),
      (60, 'expiry 1 min'),
      (89, 'expiry 1 min'),
      (90, 'expiry 2 min'),
      (_havensOwnWindowSecs, 'expiry 4 min'),
    ]) {
      testWidgets('5. $secs s renders as "$expected"', (tester) async {
        final circle = _makeCircle();

        await _pumpAndOpenDetails(
          tester,
          circle: circle,
          mockService: MockCircleService(circles: [circle]),
          expiryOverride: _expiry(circle, secs),
        );

        expect(_subtitle(tester), endsWith(expected));
      });
    }

    // -----------------------------------------------------------------------
    // 6. Unreadable window: no segment, no orphan separator, no layout shift.
    // -----------------------------------------------------------------------
    testWidgets('6. an unreadable window leaves no segment and no separator', (
      tester,
    ) async {
      final circle = _makeCircle();

      await _pumpAndOpenDetails(
        tester,
        circle: circle,
        mockService: MockCircleService(circles: [circle]),
        expiryOverride: _expiry(circle, null),
      );

      // Exact equality is the orphan-separator assertion: a trailing " · " or
      // an "expiry" with nothing after it would both fail here.
      expect(_subtitle(tester), '2 members · epoch 14');
      expect(find.textContaining('expiry'), findsNothing);
    });

    testWidgets('7. resolving to no window does not move the line', (
      tester,
    ) async {
      final circle = _makeCircle();
      final pending = Completer<int?>();

      await _pumpAndOpenDetails(
        tester,
        circle: circle,
        mockService: MockCircleService(circles: [circle]),
        expiryOverride: circleLocationExpiryProvider(
          circle,
        ).overrideWith((_) => pending.future),
      );

      final whileLoading = tester.getSize(
        find.byKey(WidgetKeys.circleDetailsMembers),
      );
      // No spinner and no reserved space while the read is in flight — the
      // leave button owns the only legitimate indicator in this sheet and it
      // is idle here.
      expect(find.byType(CircularProgressIndicator), findsNothing);

      pending.complete(null);
      await tester.pumpAndSettle();

      expect(
        tester.getSize(find.byKey(WidgetKeys.circleDetailsMembers)),
        whileLoading,
        reason:
            'a window that turns out to be unreadable must not reflow the '
            'subtitle: nothing may be reserved for it and nothing may be '
            'given back',
      );
    });

    testWidgets('8. a resolved window does change the line (anti-vacuity)', (
      tester,
    ) async {
      final circle = _makeCircle();
      final pending = Completer<int?>();

      await _pumpAndOpenDetails(
        tester,
        circle: circle,
        mockService: MockCircleService(circles: [circle]),
        expiryOverride: circleLocationExpiryProvider(
          circle,
        ).overrideWith((_) => pending.future),
      );

      final whileLoading = tester.getSize(
        find.byKey(WidgetKeys.circleDetailsMembers),
      );

      pending.complete(_havensOwnWindowSecs);
      await tester.pumpAndSettle();

      // Without this, test 7 would pass for a build that never renders the
      // segment at all — the measurement has to be able to see the segment.
      expect(
        tester.getSize(find.byKey(WidgetKeys.circleDetailsMembers)).width,
        greaterThan(whileLoading.width),
      );
    });

    // -----------------------------------------------------------------------
    // 9. Failure paths (Security Rule 8: no raw errors in the UI).
    // -----------------------------------------------------------------------
    testWidgets('9. a failed read leaks no error text', (tester) async {
      final circle = _makeCircle();

      await _pumpAndOpenDetails(
        tester,
        circle: circle,
        mockService: MockCircleService(circles: [circle]),
        expiryOverride: circleLocationExpiryProvider(circle).overrideWith(
          (_) => Future<int?>.error(StateError('mls group 0xdeadbeef missing')),
        ),
      );

      expect(_subtitle(tester), '2 members · epoch 14');
      expect(find.textContaining('expiry'), findsNothing);
      expect(find.textContaining('deadbeef'), findsNothing);
      expect(find.textContaining('StateError'), findsNothing);
    });

    testWidgets('10. the real provider yields null without a Nostr service', (
      tester,
    ) async {
      final circle = _makeCircle();

      // No override: circleLocationExpiryProvider runs for real.
      // MockCircleService is not a NostrCircleService, so it must short-circuit
      // rather than reach for an FFI handle that does not exist under
      // `flutter test`.
      await _pumpAndOpenDetails(
        tester,
        circle: circle,
        mockService: MockCircleService(circles: [circle]),
      );

      expect(_subtitle(tester), '2 members · epoch 14');
      expect(find.textContaining('expiry'), findsNothing);
    });

    // -----------------------------------------------------------------------
    // 11. Accessibility. "· 4 min" spoken aloud is meaningless, so the terse
    //     line is replaced wholesale rather than annotated segment by segment.
    // -----------------------------------------------------------------------
    testWidgets('11. a screen reader hears what the number means and whose '
        'messages it governs', (tester) async {
      final handle = tester.ensureSemantics();
      final circle = _makeCircle();

      await _pumpAndOpenDetails(
        tester,
        circle: circle,
        mockService: MockCircleService(circles: [circle]),
        expiryOverride: _expiry(circle, _havensOwnWindowSecs),
      );

      final spoken = tester
          .getSemantics(find.byKey(WidgetKeys.circleDetailsMembers))
          .label;

      expect(
        spoken,
        '2 members · epoch 14. Haven asks relays to drop, after about 4 minutes, '
        'the location updates you send to this circle.',
      );
      // The three things the label may not lose. The unit must be spoken in
      // full (an abbreviation is what the label exists to expand); the expiry
      // must stay a REQUEST to relays, never a promise of deletion; and it
      // must name whose messages the window governs, because a number on a
      // circle's sheet otherwise reads as a property of the circle.
      expect(spoken, contains('minutes'));
      expect(spoken, isNot(contains('4 min.')));
      expect(spoken, contains('asks relays'));
      expect(spoken, contains('you send'));

      handle.dispose();
    });

    testWidgets('12. a seconds-long window is spoken exactly, without hedging',
        (tester) async {
      final handle = tester.ensureSemantics();
      final circle = _makeCircle();

      await _pumpAndOpenDetails(
        tester,
        circle: circle,
        mockService: MockCircleService(circles: [circle]),
        expiryOverride: _expiry(circle, 30),
      );

      final spoken = tester
          .getSemantics(find.byKey(WidgetKeys.circleDetailsMembers))
          .label;

      // Only the minutes form is rounded, so only it is hedged: saying "about
      // 30 seconds" about an exact 30 s would be less accurate, not more.
      expect(
        spoken,
        '2 members · epoch 14. Haven asks relays to drop, after 30 seconds, '
        'the location updates you send to this circle.',
      );
      expect(spoken, isNot(contains('about')));

      handle.dispose();
    });

    testWidgets('13. without a window the announcement is the plain line', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final circle = _makeCircle();

      await _pumpAndOpenDetails(
        tester,
        circle: circle,
        mockService: MockCircleService(circles: [circle]),
        expiryOverride: _expiry(circle, null),
      );

      // No stale sentence about a window that could not be read, and no empty
      // annotation swallowing the subtitle a screen reader would otherwise
      // announce.
      expect(
        tester.getSemantics(find.byKey(WidgetKeys.circleDetailsMembers)).label,
        '2 members · epoch 14',
      );

      handle.dispose();
    });

    testWidgets('14. the annotated line is still announced as plain text', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final circle = _makeCircle();

      await _pumpAndOpenDetails(
        tester,
        circle: circle,
        mockService: MockCircleService(circles: [circle]),
        expiryOverride: _expiry(circle, _havensOwnWindowSecs),
      );

      final data = tester
          .getSemantics(find.byKey(WidgetKeys.circleDetailsMembers))
          .getSemanticsData();
      // The wrapper exists only to re-word a dim metadata line. Announcing it
      // as a button or a link — or giving it a tap action — would promise an
      // interaction this line does not have, and a screen-reader user would
      // hunt for it among the controls this sheet really does offer.
      expect(data.flagsCollection.isButton, isFalse);
      expect(data.flagsCollection.isLink, isFalse);
      expect(data.hasAction(SemanticsAction.tap), isFalse);

      handle.dispose();
    });

    // -----------------------------------------------------------------------
    // 15. A circle that cannot send has no window to report (Rule 8).
    // -----------------------------------------------------------------------
    testWidgets('15. a blocked circle reports no window, seen or spoken', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final circle = _makeCircle();

      // An `Unrecoverable` circle still HAS an MLS group, so the accessor
      // happily returns Haven's own window for it — the exact "about four
      // minutes for a circle that cannot send" this segment must never
      // report. The override supplies that value so the assertion is about
      // the sheet's gate and not about how the read happens to fail.
      await _pumpAndOpenDetails(
        tester,
        circle: circle,
        mockService: MockCircleService(circles: [circle])
          ..markCircleBlocked(circle.mlsGroupId),
        expiryOverride: _expiry(circle, _havensOwnWindowSecs),
      );

      expect(_subtitle(tester), '2 members · epoch 14');
      expect(find.textContaining('4 min'), findsNothing);
      // A screen-reader user gets the whole sentence read out, so a stale
      // window is worse here than on screen, not better.
      expect(
        tester.getSemantics(find.byKey(WidgetKeys.circleDetailsMembers)).label,
        '2 members · epoch 14',
      );

      handle.dispose();
    });
  });
}
