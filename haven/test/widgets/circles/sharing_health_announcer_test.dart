/// What a screen reader hears while Circle details is closed.
///
/// The sharing card and the change card live only in Circle details (OD-1),
/// and a live region speaks only while it is mounted, so with the sheet closed
/// a fault, its end and a note would otherwise be silent (WCAG 2.1 SC 4.1.3).
/// The announcer says only that there is something to read, and where; with
/// the sheet open it is silent, because the card's own live region speaks.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/location_access_provider.dart';
import 'package:haven/src/providers/location_sharing_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/providers/sharing_health_provider.dart';
import 'package:haven/src/rust/api.dart' show ChangeNoteFfi;
import 'package:haven/src/services/change_notices.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/widgets/circles/circles_bottom_sheet.dart';

import '../../helpers/accessibility_announcements.dart';
import '../../helpers/fake_change_notices.dart';
import '../../helpers/sheet_health_overrides.dart';
import '../../mocks/mock_circle_service.dart';

const _selfPubkey =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
final _t0 = DateTime.utc(2026, 8, 28, 12);

/// A verdict the test moves by hand.
class _Health extends SharingHealthNotifier {
  _Health(this._initial);

  final SharingHealth _initial;

  @override
  SharingHealth build() => _initial;

  @override
  Future<void> refresh() async {}

  SharingHealth get verdict => state;
  set verdict(SharingHealth next) => state = next;
}

Circle _circle(int id, String name) => TestCircleFactory.createCircle(
  mlsGroupId: [id],
  nostrGroupId: [id],
  displayName: name,
  members: [TestCircleFactory.createMember(pubkey: _selfPubkey, isAdmin: true)],
);

final Circle _home = _circle(1, 'Home');
final Circle _work = _circle(2, 'Work');

/// The circles sheet with [_home] selected and [_work] beside it.
class _Harness {
  late _Health health;
  late FixedLocationAccess access;
  late List<String> said;
  late ProviderContainer container;
  final notices = FakeNoticeManager();
  final foreground = ValueNotifier<bool>(true);
  final selected = StateProvider<Circle?>((ref) => _home);
  Completer<void>? repairGate;

  Future<AppLocalizations> pump(
    WidgetTester tester, {
    SharingHealth initial = SharingHealth.healthy,
  }) async {
    tester.view.physicalSize = const Size(800, 5000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(foreground.dispose);
    said = captureAccessibilityAnnouncements(tester);
    health = _Health(initial);
    access = FixedLocationAccess();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          locationAccessProvider.overrideWith(() => access),
          circleHealthServiceProvider.overrideWithValue(
            const EmptyCircleHealth(),
          ),
          changeNoticesProvider.overrideWithValue(
            ChangeNotices(manager: () async => notices),
          ),
          sharingHealthProvider.overrideWith(() => health),
          sharingHealthForegroundProvider.overrideWithValue(foreground),
          sharingHealthClockProvider.overrideWithValue(
            () => _t0.add(const Duration(minutes: 9)),
          ),
          sharingRepairProvider.overrideWithValue(() async {
            await repairGate?.future;
            return null;
          }),
          circleServiceProvider.overrideWithValue(
            MockCircleService(circles: [_home, _work]),
          ),
          circlesProvider.overrideWith((ref) async => [_home, _work]),
          selectedCircleProvider.overrideWith((ref) => ref.watch(selected)),
          identityProvider.overrideWith(
            (_) async => Identity(
              pubkeyHex: _selfPubkey,
              npub: 'npub1self',
              createdAt: DateTime(2024),
            ),
          ),
          memberLocationsProvider.overrideWith((_) async => const []),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Stack(
              children: [CirclesBottomSheet(onExpansionChanged: (_) {})],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    container = ProviderScope.containerOf(
      tester.element(find.byType(CirclesBottomSheet)),
    );
    return AppLocalizations.of(tester.element(find.byType(CirclesBottomSheet)));
  }

  Future<void> openDetails(WidgetTester tester) async {
    await tester.tap(find.byKey(WidgetKeys.circleDetailsButton));
    await tester.pumpAndSettle();
  }

  Future<void> closeDetails(WidgetTester tester) async {
    Navigator.of(
      tester.element(find.byKey(WidgetKeys.leaveCircleCta)),
    ).pop();
    await tester.pumpAndSettle();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the selected circle, with the sheet closed', () {
    testWidgets('onset says where to look, once; recovery says so, once; a '
        'return with the fault standing says it again', (tester) async {
      final h = _Harness();
      final l10n = await h.pump(tester);

      h.health.verdict = SharingHealth.publishFailing(_t0);
      await tester.pumpAndSettle();
      expect(h.said, [l10n.sharingHealthAttentionAnnouncement]);
      expect(
        h.said.single,
        isNot(contains(l10n.sharingHealthTitleNotSending)),
        reason: 'it never repeats the message the card says',
      );

      h.foreground.value = false;
      await tester.pump();
      h.foreground.value = true;
      await tester.pump();
      expect(h.said, [
        l10n.sharingHealthAttentionAnnouncement,
        l10n.sharingHealthAttentionAnnouncement,
      ]);

      h.health.verdict = SharingHealth.healthy;
      await tester.pumpAndSettle();
      expect(h.said.last, l10n.sharingHealthResumedAnnouncement);
      expect(h.said, hasLength(3));
    });

    testWidgets('is silent while the sheet is open: the card speaks', (
      tester,
    ) async {
      final h = _Harness();
      final l10n = await h.pump(tester);
      await h.openDetails(tester);

      h.health.verdict = SharingHealth.publishFailing(_t0);
      await tester.pumpAndSettle();
      expect(
        h.said,
        isNot(contains(l10n.sharingHealthAttentionAnnouncement)),
        reason: 'the open card is a live region; saying it here too would '
            'speak it twice',
      );
    });

    testWidgets('a fault a device banner suppresses never ends in "working '
        'again"', (tester) async {
      final h = _Harness();
      final l10n = await h.pump(tester);
      h.health.verdict = SharingHealth.publishFailing(_t0);
      await tester.pumpAndSettle();

      // The user turns location off: the inferred fault is suppressed behind
      // the device banner, and sharing is MORE broken, not resumed.
      h.access.status = LocationAccessStatus.serviceDisabled;
      await tester.pumpAndSettle();
      expect(h.said, isNot(contains(l10n.sharingHealthResumedAnnouncement)));
    });

    testWidgets('switching from a faulty circle to a healthy one is no '
        'recovery', (tester) async {
      final h = _Harness();
      final l10n = await h.pump(tester);
      h.health.verdict = SharingHealth.publishFailing(_t0);
      await tester.pumpAndSettle();

      h.container.read(h.selected.notifier).state = _work;
      await tester.pump();
      h.health.verdict = SharingHealth.healthy;
      await tester.pumpAndSettle();
      expect(h.said, isNot(contains(l10n.sharingHealthResumedAnnouncement)));
    });

    testWidgets('an ended circle is announced once per process, not on every '
        'return', (tester) async {
      final h = _Harness();
      final l10n = await h.pump(tester);
      h.health.verdict = SharingHealth.paused(
        SharingPausedReason.circleDisbanded,
        _t0,
        ageProvable: false,
      );
      await tester.pumpAndSettle();
      expect(h.said, [l10n.sharingHealthAttentionAnnouncement]);

      h.foreground.value = false;
      await tester.pump();
      h.foreground.value = true;
      await tester.pump();
      expect(h.said, hasLength(1));
    });
  });

  group('a verdict about another circle', () {
    testWidgets("is never shown in the selected circle's sheet, and its "
        'circle turning healthy is no recovery', (tester) async {
      final h = _Harness();
      final l10n = await h.pump(
        tester,
        initial: SharingHealth.paused(
          SharingPausedReason.awaitingRelays,
          _t0,
        ).about(sharingCircleKey(_home)),
      );
      // Work is selected before its own verdict lands.
      h.container.read(h.selected.notifier).state = _work;
      await tester.pumpAndSettle();
      h.said.clear();
      await h.openDetails(tester);
      expect(find.text(l10n.sharingHealthBodyAwaitingRelays), findsNothing);
      expect(find.byKey(WidgetKeys.sharingHealthBanner), findsNothing);

      h.health.verdict = SharingHealth.healthy.about(sharingCircleKey(_work));
      await tester.pumpAndSettle();
      expect(h.said, isNot(contains(l10n.sharingHealthResumedAnnouncement)));
    });

    testWidgets('a healthy verdict about another circle is no recovery of the '
        'fault shown', (tester) async {
      final h = _Harness();
      final l10n = await h.pump(
        tester,
        initial: SharingHealth.paused(
          SharingPausedReason.awaitingRelays,
          _t0,
        ).about(sharingCircleKey(_home)),
      );
      await h.openDetails(tester);
      expect(find.text(l10n.sharingHealthBodyAwaitingRelays), findsOneWidget);
      h.said.clear();

      // The selection and the new circle's verdict move in one step.
      h.container.read(h.selected.notifier).state = _work;
      h.health.verdict = SharingHealth.healthy.about(sharingCircleKey(_work));
      await tester.pumpAndSettle();
      expect(h.said, isNot(contains(l10n.sharingHealthResumedAnnouncement)));
    });
  });

  group('a note in any accepted circle', () {
    testWidgets('a note appearing in a circle not selected is announced once, '
        'naming the circle without isolates', (tester) async {
      final h = _Harness()
        ..notices.notesFor = (id) => listEquals(id, _work.mlsGroupId)
            ? const [ChangeNoteFfi.removalUndone]
            : const [];
      final l10n = await h.pump(tester);
      expect(h.said, [l10n.changeNoticeArrivedAnnouncement('Work')]);
      expect(h.said.single, isNot(contains('\u2068')));

      // A refresh of the circle list re-reads the notice: not said again.
      h.container.invalidate(circlesProvider);
      await tester.pumpAndSettle();
      expect(h.said, hasLength(1));
    });

    testWidgets('a notice of level notes alone is not announced', (
      tester,
    ) async {
      final h = _Harness()
        ..notices.notes = const [
          ChangeNoteFfi.unreadLocation,
          ChangeNoteFfi.awaitsForeground,
        ];
      await h.pump(tester);
      expect(h.said, isEmpty);
    });
  });

  group('a repair that outlives the sheet', () {
    testWidgets('still says it did not help when the fault stands', (
      tester,
    ) async {
      final h = _Harness()..repairGate = Completer<void>();
      final l10n = await h.pump(
        tester,
        initial: SharingHealth.publishFailing(_t0),
      );
      h.said.clear();
      await h.openDetails(tester);
      await tester.tap(find.byKey(WidgetKeys.sharingHealthRepairButton));
      await tester.pump();

      await h.closeDetails(tester);
      h.repairGate!.complete();
      await tester.pumpAndSettle();

      expect(
        h.said.where(
          (s) => s == l10n.sharingHealthRepairUnresolvedAnnouncement,
        ),
        hasLength(1),
      );
    });
  });
}
