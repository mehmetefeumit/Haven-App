/// Tests for the discreet MLS-epoch suffix on the _CircleDetailsSheet
/// member-count line.
///
/// The epoch exists so members can compare two devices when messages stop
/// decrypting. It must be *available* without being *intrusive*: it rides the
/// existing dim member-count subtitle, and whenever it cannot be read the line
/// must degrade silently to a bare member count — never a spinner, an error
/// string, or a layout shift (Security Rule 8: no raw errors in the UI).
///
/// Verifies that:
/// 1. A resolved epoch is appended to the member count.
/// 2. A null epoch (no live MLS group) leaves the bare member count.
/// 3. A never-completing read leaves the bare member count (no spinner).
/// 4. A failed read leaves the bare member count and leaks no error text.
/// 5. The real provider yields null for a non-Nostr-backed circle service.
/// 6. The epoch stays on the subtitle line — it never reaches the sheet title.
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
import 'package:haven/src/theme/app_theme.dart';
import 'package:haven/src/widgets/circles/circles_bottom_sheet.dart';

import '../../mocks/mock_circle_service.dart';
import '../../mocks/mock_relay_service.dart';

const _selfPubkey =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _otherPubkey =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

/// Stub for [inboxRelaysProvider] — returns a fixed list without SQLite.
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

/// Pumps [CirclesBottomSheet] with [circle] selected and opens the
/// circle-details modal sheet.
///
/// [epochOverride] replaces the epoch read for exactly this circle. Passing
/// `null` leaves the real provider in place, which resolves to `null` because
/// [MockCircleService] is not a `NostrCircleService`.
Future<void> _pumpAndOpenDetails(
  WidgetTester tester, {
  required Circle circle,
  required MockCircleService mockService,
  Override? epochOverride,
  ThemeData? theme,
}) async {
  tester.view.physicalSize = const Size(800, 5000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
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
        if (epochOverride != null) epochOverride,
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme:
            theme ??
            ThemeData(
              useMaterial3: false,
              splashFactory: InkSplash.splashFactory,
            ),
        home: Scaffold(
          body: Stack(
            children: [CirclesBottomSheet(onExpansionChanged: (_) {})],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();

  await tester.tap(find.byKey(WidgetKeys.circleDetailsButton));
  await tester.pumpAndSettle();
}

/// The rendered text of the keyed member-count subtitle in the details sheet.
String _membersLine(WidgetTester tester) {
  final finder = find.byKey(WidgetKeys.circleDetailsMembers);
  expect(
    finder,
    findsOneWidget,
    reason: 'the details sheet must render exactly one member-count subtitle',
  );
  final text = tester.widget<Text>(finder);
  expect(
    text.data,
    isNotNull,
    reason:
        'the subtitle must stay a plain Text: splitting it into a Text.rich '
        '/ TextSpan would break the single-l10n-key contract that lets each '
        'locale choose its own separator and word order',
  );
  return text.data!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('_CircleDetailsSheet — MLS epoch suffix', () {
    // -----------------------------------------------------------------------
    // 1. Resolved epoch is appended to the member count.
    // -----------------------------------------------------------------------
    testWidgets('1. resolved epoch is appended to the member count', (
      tester,
    ) async {
      final circle = _makeCircle();

      await _pumpAndOpenDetails(
        tester,
        circle: circle,
        mockService: MockCircleService(circles: [circle]),
        epochOverride: circleEpochProvider(
          circle,
        ).overrideWith((_) async => 14),
      );

      expect(_membersLine(tester), '2 members · epoch 14');
    });

    // -----------------------------------------------------------------------
    // 2. Null epoch (no live MLS group) → bare member count.
    // -----------------------------------------------------------------------
    testWidgets('2. null epoch degrades to a bare member count', (
      tester,
    ) async {
      final circle = _makeCircle();

      await _pumpAndOpenDetails(
        tester,
        circle: circle,
        mockService: MockCircleService(circles: [circle]),
        epochOverride: circleEpochProvider(
          circle,
        ).overrideWith((_) async => null),
      );

      expect(_membersLine(tester), '2 members');
      expect(find.textContaining('epoch'), findsNothing);
    });

    // -----------------------------------------------------------------------
    // 3. Still loading → bare member count, and no progress indicator.
    // -----------------------------------------------------------------------
    testWidgets('3. pending epoch read shows no spinner and no epoch', (
      tester,
    ) async {
      final circle = _makeCircle();
      // Never completes: models a slow MLS/SQLCipher read.
      final pending = Completer<int?>();
      addTearDown(() => pending.complete(null));

      await _pumpAndOpenDetails(
        tester,
        circle: circle,
        mockService: MockCircleService(circles: [circle]),
        epochOverride: circleEpochProvider(
          circle,
        ).overrideWith((_) => pending.future),
      );

      expect(_membersLine(tester), '2 members');
      // The leave button owns the only legitimate spinner in this sheet, and
      // it is idle here — so any indicator would be the epoch's.
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    // -----------------------------------------------------------------------
    // 4. Failed read → bare member count, no error text (Security Rule 8).
    // -----------------------------------------------------------------------
    testWidgets('4. failed epoch read leaks no error text', (tester) async {
      final circle = _makeCircle();

      await _pumpAndOpenDetails(
        tester,
        circle: circle,
        mockService: MockCircleService(circles: [circle]),
        epochOverride: circleEpochProvider(circle).overrideWith(
          (_) => Future<int?>.error(StateError('mls group 0xdeadbeef missing')),
        ),
      );

      expect(_membersLine(tester), '2 members');
      expect(find.textContaining('epoch'), findsNothing);
      // The raw failure must never reach the widget tree.
      expect(find.textContaining('deadbeef'), findsNothing);
      expect(find.textContaining('StateError'), findsNothing);
    });

    // -----------------------------------------------------------------------
    // 5. The real provider yields null when the service is not Nostr-backed.
    // -----------------------------------------------------------------------
    testWidgets('5. real provider yields null for a non-Nostr circle service', (
      tester,
    ) async {
      final circle = _makeCircle();

      // No epochOverride: circleEpochProvider runs for real. MockCircleService
      // is not a NostrCircleService, so it must short-circuit to null rather
      // than reaching for an FFI handle that does not exist under `flutter
      // test`.
      await _pumpAndOpenDetails(
        tester,
        circle: circle,
        mockService: MockCircleService(circles: [circle]),
      );

      expect(_membersLine(tester), '2 members');
      expect(find.textContaining('epoch'), findsNothing);
    });

    // -----------------------------------------------------------------------
    // 6. The epoch stays subordinate: it never reaches the sheet title.
    // -----------------------------------------------------------------------
    testWidgets('6. epoch rides the subtitle, not the sheet title', (
      tester,
    ) async {
      final circle = _makeCircle();

      await _pumpAndOpenDetails(
        tester,
        circle: circle,
        mockService: MockCircleService(circles: [circle]),
        epochOverride: circleEpochProvider(circle).overrideWith((_) async => 7),
      );

      // The title is still the plain, untouched heading.
      expect(find.text('Circle details'), findsWidgets);
      // 'epoch 7' appears exactly once in the whole sheet.
      expect(find.textContaining('epoch 7'), findsOneWidget);
      expect(_membersLine(tester), '2 members · epoch 7');
    });

    // -----------------------------------------------------------------------
    // 7. Discreetness is a contract, not a comment.
    // -----------------------------------------------------------------------
    testWidgets('7. epoch keeps the muted subtitle style, never emphasis', (
      tester,
    ) async {
      final circle = _makeCircle();

      await _pumpAndOpenDetails(
        tester,
        circle: circle,
        mockService: MockCircleService(circles: [circle]),
        epochOverride: circleEpochProvider(
          circle,
        ).overrideWith((_) async => 21),
        // Pin against the real app theme, not a bare ThemeData, so the
        // assertion below reflects what ships.
        theme: HavenTheme.light(),
      );

      expect(_membersLine(tester), '2 members · epoch 21');

      // The owner's requirement is that the epoch is "very not attention
      // grabbing". That is guarded here rather than by a comment: the line
      // must stay at the 12sp muted-subtitle style and must never be
      // promoted to a larger size, a heavier weight, or an accent colour.
      // Note it also must not be dimmed *further* — onSurfaceVariant at 12sp
      // is 7.81:1 on the light surface, and any added translucency drops it
      // under the WCAG AA 4.5:1 floor for body text.
      final style = tester
          .widget<Text>(find.byKey(WidgetKeys.circleDetailsMembers))
          .style!;
      expect(style.fontSize, 12);
      expect(style.color, HavenTheme.light().colorScheme.onSurfaceVariant);
      expect(style.fontWeight, isNot(FontWeight.bold));
      expect(style.fontWeight, isNot(FontWeight.w600));
    });
  });
}
