/// Tests for the admin "Remove from circle" affordance in the member list.
///
/// Three things are being pinned, and they fail differently:
///
/// 1. WHO is offered the action. A viewer who is not an admin of this
///    circle, a row that is the viewer's own, and a circle the engine has
///    blocked must each be offered nothing — an affordance that appears and
///    then fails is worse than one that never appeared.
/// 2. WHAT the confirmation says before anything is staged. The dialog is
///    the only guard on an irreversible action, so its body has to state
///    the consequence rather than ask a bare "are you sure".
/// 3. WHAT the user is told afterwards, in both directions, including that
///    a failure says nothing changed — which is true, and is what stops an
///    admin from removing someone twice.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
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

import '../../helpers/localized_app_harness.dart';
import '../../mocks/mock_circle_service.dart';

const _selfPubkey =
    'aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111';
const _otherPubkey =
    'bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222';
const _thirdPubkey =
    'cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333';

Identity _identity() => Identity(
  pubkeyHex: _selfPubkey,
  npub: 'npub1self',
  createdAt: DateTime(2025),
);

CircleMember _member(String pubkey, {bool isAdmin = false, String? name}) =>
    TestCircleFactory.createMember(
      pubkey: pubkey,
      npub: 'npub1${pubkey.substring(0, 20)}',
      displayName: name,
      isAdmin: isAdmin,
    );

Circle _circle({required bool selfIsAdmin, List<CircleMember>? members}) =>
    TestCircleFactory.createCircle(
      members:
          members ??
          [
            _member(_selfPubkey, isAdmin: selfIsAdmin, name: 'Alice'),
            _member(_otherPubkey, name: 'Bob'),
          ],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // The copy path haptics through Clipboard/HapticFeedback; answer the
    // platform channel so no test logs a missing-implementation warning.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async => null,
        );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  /// Pumps the sheet over [circle] with the member list expanded.
  Future<MockCircleService> pumpSheet(
    WidgetTester tester, {
    required Circle circle,
    MockCircleService? service,
    Identity? identity,
  }) async {
    final mockService = service ?? MockCircleService(circles: [circle]);
    final sheetController = DraggableScrollableController();
    addTearDown(sheetController.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          circleServiceProvider.overrideWithValue(mockService),
          selectedCircleProvider.overrideWith((ref) => circle),
          memberLocationsProvider.overrideWith((_) async => const []),
          identityProvider.overrideWith((_) async => identity ?? _identity()),
          displayNameProvider.overrideWith((_) async => 'Alice'),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Stack(
              children: [
                CirclesBottomSheet(
                  onExpansionChanged: (_) {},
                  controller: sheetController,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    sheetController.jumpTo(0.85);
    await tester.pumpAndSettle();
    return mockService;
  }

  group('who is offered the removal', () {
    testWidgets('an admin gets it on another member’s row', (tester) async {
      await pumpSheet(tester, circle: _circle(selfIsAdmin: true));

      expect(
        find.byKey(WidgetKeys.memberRemoveButton(_otherPubkey)),
        findsOneWidget,
      );
    });

    testWidgets('an admin does NOT get it on their own row', (tester) async {
      await pumpSheet(tester, circle: _circle(selfIsAdmin: true));

      expect(
        find.byKey(WidgetKeys.memberRemoveButton(_selfPubkey)),
        findsNothing,
        reason: 'leaving is the MIP-03 SelfRemove path behind "Leave '
            'circle", and the engine refuses an admin self-remove outright',
      );
    });

    testWidgets('a non-admin gets it on nobody', (tester) async {
      await pumpSheet(tester, circle: _circle(selfIsAdmin: false));

      expect(find.byKey(WidgetKeys.memberRemoveButton(_otherPubkey)),
          findsNothing);
      expect(
        find.byKey(WidgetKeys.memberRemoveButton(_selfPubkey)),
        findsNothing,
      );
    });

    testWidgets('a blocked circle offers it to nobody', (tester) async {
      final circle = _circle(selfIsAdmin: true);
      final service = MockCircleService(circles: [circle])
        ..markCircleBlocked(circle.mlsGroupId);

      await pumpSheet(tester, circle: circle, service: service);

      expect(
        find.byKey(WidgetKeys.memberRemoveButton(_otherPubkey)),
        findsNothing,
        reason: 'a removal stages an MLS commit, and a circle the engine '
            'flagged Unrecoverable must be offered no mutation at all '
            '(Security Rule 8) — the same gate "Add member" is behind',
      );
    });

    testWidgets('the button carries its tooltip as an accessible label',
        (tester) async {
      final handle = tester.ensureSemantics();
      await pumpSheet(tester, circle: _circle(selfIsAdmin: true));

      expect(find.bySemanticsLabel('Remove from circle'), findsOneWidget);
      handle.dispose();
    });
  });

  group('the confirmation', () {
    testWidgets('the dialog states the consequence before anything is staged',
        (tester) async {
      final service = await pumpSheet(
        tester,
        circle: _circle(selfIsAdmin: true),
      );

      await tester.tap(find.byKey(WidgetKeys.memberRemoveButton(_otherPubkey)));
      await tester.pumpAndSettle();

      expect(find.text('Remove Bob?'), findsOneWidget);
      expect(
        find.textContaining('stop being able to read anything new'),
        findsOneWidget,
        reason: 'the dialog is the only guard on an irreversible action; a '
            'bare "are you sure" tells the admin nothing about what removal '
            'does',
      );
      expect(
        find.textContaining('invite them again'),
        findsOneWidget,
        reason: 'there is no undo, and the copy has to say so rather than '
            'imply one',
      );
      expect(
        service.removeMemberCalls,
        isEmpty,
        reason: 'opening the dialog must stage nothing',
      );
    });

    testWidgets('cancelling reaches no service call', (tester) async {
      final service = await pumpSheet(
        tester,
        circle: _circle(selfIsAdmin: true),
      );

      await tester.tap(find.byKey(WidgetKeys.memberRemoveButton(_otherPubkey)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(service.removeMemberCalls, isEmpty);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('confirming removes exactly the member that was tapped',
        (tester) async {
      final circle = _circle(
        selfIsAdmin: true,
        members: [
          _member(_selfPubkey, isAdmin: true, name: 'Alice'),
          _member(_otherPubkey, name: 'Bob'),
          _member(_thirdPubkey, name: 'Carol'),
        ],
      );
      final service = await pumpSheet(tester, circle: circle);

      await tester.tap(find.byKey(WidgetKeys.memberRemoveButton(_thirdPubkey)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(WidgetKeys.memberRemoveConfirm));
      await tester.pumpAndSettle();

      expect(service.removeMemberCalls, hasLength(1));
      expect(service.removeMemberCalls.single.memberPubkeyHex, _thirdPubkey);
      expect(service.removeMemberCalls.single.mlsGroupId, circle.mlsGroupId);
    });
  });

  group('what the admin is told afterwards', () {
    testWidgets('a success names the member it removed', (tester) async {
      await pumpSheet(tester, circle: _circle(selfIsAdmin: true));

      await tester.tap(find.byKey(WidgetKeys.memberRemoveButton(_otherPubkey)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(WidgetKeys.memberRemoveConfirm));
      await tester.pumpAndSettle();

      expect(find.text('Removed Bob from the circle'), findsOneWidget);
    });

    testWidgets('a failure says nothing changed, and the member stays',
        (tester) async {
      final circle = _circle(selfIsAdmin: true);
      final service = MockCircleService(circles: [circle])
        ..shouldThrowOnRemoveMember = true;

      await pumpSheet(tester, circle: circle, service: service);

      await tester.tap(find.byKey(WidgetKeys.memberRemoveButton(_otherPubkey)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(WidgetKeys.memberRemoveConfirm));
      await tester.pumpAndSettle();

      expect(find.textContaining('Nothing changed'), findsOneWidget);
      expect(
        find.byKey(WidgetKeys.memberTile(_otherPubkey)),
        findsOneWidget,
        reason: 'the service rolls its staged commit back on failure, so the '
            'roster the list is rendering is still the true one',
      );
    });

    testWidgets('the failure message never carries the underlying error',
        (tester) async {
      final circle = _circle(selfIsAdmin: true);
      final service = MockCircleService(circles: [circle])
        ..shouldThrowOnRemoveMember = true;

      await pumpSheet(tester, circle: circle, service: service);

      await tester.tap(find.byKey(WidgetKeys.memberRemoveButton(_otherPubkey)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(WidgetKeys.memberRemoveConfirm));
      await tester.pumpAndSettle();

      // Security Rule 8: an FFI error message can name the MLS group id.
      expect(find.textContaining('Mock removeMember error'), findsNothing);
      expect(find.textContaining('CircleServiceException'), findsNothing);
    });
  });

  group('the widest row this can produce still lays out', () {
    // The trailing area now holds an "Admin" chip AND a 40dp button on one
    // row — the widest combination the list can render — while the title
    // beside it grows with text scale and translation length. Swept over
    // every shipped locale, sourced from the enum so it cannot drift from
    // the ARB set, because a trailing overflow is invisible in English and
    // certain in whichever language spells "Admin" longest.
    for (final locale in AppLocalizations.supportedLocales) {
      testWidgets('"${locale.languageCode}" at 2.0x on a narrow phone',
          (tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(360, 690);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final circle = _circle(
          selfIsAdmin: true,
          // The co-admin goes FIRST: a SliverList builds lazily, and at 2.0x
          // on a 360×690 phone the rows below the fold are never built — an
          // assertion about a row that was never built proves nothing about
          // its layout.
          members: [
            // A co-admin: chip and remove button on the same row.
            _member(_otherPubkey, isAdmin: true, name: 'Bartholomew Ashworth'),
            _member(_selfPubkey, isAdmin: true, name: 'Alice'),
            _member(_thirdPubkey, name: 'Carol'),
          ],
        );
        final sheetController = DraggableScrollableController();
        addTearDown(sheetController.dispose);

        await pumpLocalized(
          tester,
          Scaffold(
            body: Stack(
              children: [
                CirclesBottomSheet(
                  onExpansionChanged: (_) {},
                  controller: sheetController,
                ),
              ],
            ),
          ),
          locale: locale,
          textScaler: const TextScaler.linear(2),
          overrides: [
            circleServiceProvider.overrideWithValue(
              MockCircleService(circles: [circle]),
            ),
            selectedCircleProvider.overrideWith((ref) => circle),
            memberLocationsProvider.overrideWith((_) async => const []),
            identityProvider.overrideWith((_) async => _identity()),
            displayNameProvider.overrideWith((_) async => 'Alice'),
          ],
        );
        sheetController.jumpTo(0.85);
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(
          find.byKey(WidgetKeys.memberRemoveButton(_otherPubkey)),
          findsOneWidget,
          reason: 'an overflow that hid the action instead of throwing would '
              'pass a bare no-exception assertion',
        );
      });
    }
  });

  group('the confirmation dialog fits the phone it is shown on', () {
    // `AlertDialog` does NOT scroll its content by default, and this body is
    // four sentences of consequence that every locale renders at a different
    // length. Swept over every shipped locale at 2.0x on a narrow phone,
    // because a dialog that cannot fit the explanation loses the bottom of
    // it on the one screen where the user is deciding.
    //
    // The assertion is NOT "nothing threw". A clipped `Text` throws nothing
    // — no overflow stripe, no exception — so an exception check passes
    // while the copy is invisible, which is exactly what this sweep did
    // before the measurement below replaced it: at 2.0x the German body
    // wanted 1720px and was given 298px, and the sweep was green.
    for (final locale in AppLocalizations.supportedLocales) {
      testWidgets('"${locale.languageCode}" at 2.0x on a narrow phone',
          (tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(360, 690);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final circle = _circle(selfIsAdmin: true);
        final sheetController = DraggableScrollableController();
        addTearDown(sheetController.dispose);

        await pumpLocalized(
          tester,
          Scaffold(
            body: Stack(
              children: [
                CirclesBottomSheet(
                  onExpansionChanged: (_) {},
                  controller: sheetController,
                ),
              ],
            ),
          ),
          locale: locale,
          textScaler: const TextScaler.linear(2),
          overrides: [
            circleServiceProvider.overrideWithValue(
              MockCircleService(circles: [circle]),
            ),
            selectedCircleProvider.overrideWith((ref) => circle),
            memberLocationsProvider.overrideWith((_) async => const []),
            identityProvider.overrideWith((_) async => _identity()),
            displayNameProvider.overrideWith((_) async => 'Alice'),
          ],
        );
        sheetController.jumpTo(0.85);
        await tester.pumpAndSettle();

        await tester.tap(
          find.byKey(WidgetKeys.memberRemoveButton(_otherPubkey)),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);

        // Every line of the body is laid out, not clipped to whatever the
        // dialog had room for.
        final body = tester.renderObject<RenderParagraph>(
          find.byWidgetPredicate(
            (w) =>
                w is Text &&
                w.data != null &&
                w.data!.length > 80 &&
                find
                    .ancestor(
                      of: find.byWidget(w),
                      matching: find.byType(AlertDialog),
                    )
                    .evaluate()
                    .isNotEmpty,
          ),
        );
        expect(
          body.size.height,
          greaterThanOrEqualTo(body.getMaxIntrinsicHeight(body.size.width)),
          reason: 'the confirmation body is clipped: it needs '
              '${body.getMaxIntrinsicHeight(body.size.width)}px at this '
              'width and was given ${body.size.height}px, so the reader '
              'never sees the end of what removal does',
        );

        // And the destructive action is reachable, not merely present.
        await tester.ensureVisible(find.byKey(WidgetKeys.memberRemoveConfirm));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('while a removal is in flight', () {
    testWidgets('the row shows progress and every other row is held',
        (tester) async {
      final circle = _circle(
        selfIsAdmin: true,
        members: [
          _member(_selfPubkey, isAdmin: true, name: 'Alice'),
          _member(_otherPubkey, name: 'Bob'),
          _member(_thirdPubkey, name: 'Carol'),
        ],
      );
      final gate = Completer<void>();
      final service = MockCircleService(circles: [circle])
        ..removeMemberGate = gate.future;

      await pumpSheet(tester, circle: circle, service: service);

      await tester.tap(find.byKey(WidgetKeys.memberRemoveButton(_otherPubkey)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(WidgetKeys.memberRemoveConfirm));
      await tester.pump();

      expect(
        find.byKey(WidgetKeys.memberRemoveButton(_otherPubkey)),
        findsNothing,
        reason: "the removed row's button is replaced by its progress "
            'indicator',
      );
      final carolButton = tester.widget<IconButton>(
        find.byKey(WidgetKeys.memberRemoveButton(_thirdPubkey)),
      );
      expect(
        carolButton.onPressed,
        isNull,
        reason: 'two MLS commits staged on one group race each other, so the '
            'other rows hold rather than queue a second removal',
      );

      gate.complete();
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<IconButton>(
              find.byKey(WidgetKeys.memberRemoveButton(_thirdPubkey)),
            )
            .onPressed,
        isNotNull,
        reason: 'the hold must lift when the removal finishes, or the list '
            'stays frozen for the rest of the session',
      );
    });
  });
}
