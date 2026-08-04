/// Tests for [LocationAccessBanner] — the surface that tells the user, while
/// it is happening, that Haven can no longer read this device's location.
///
/// ## Why these assert against l10n getters, never English literals
///
/// The copy is resolved through [AppLocalizations] rather than asserted as
/// literal English. That keeps these tests proving the same thing when the
/// wording is revised or retranslated; asserting the English text would make
/// them break on a copy edit, or — worse — keep passing against a stale copy
/// of it.
library;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/providers/location_access_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/location_settings_launcher.dart';
import 'package:haven/src/widgets/map/location_access_banner.dart';

import '../../helpers/localized_app_harness.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

/// Records which OS screen a remedy button opened. The whole point of
/// distinguishing the causes is that they send the user somewhere different.
class _RecordingLauncher implements LocationSettingsLauncher {
  final List<String> opened = [];

  @override
  Future<bool> openLocationSettings() async {
    opened.add('location');
    return true;
  }

  @override
  Future<bool> openAppSettings() async {
    opened.add('app');
    return true;
  }
}

/// A [LocationAccessNotifier] with the platform wiring removed, so a widget
/// test can hold a status still (and move it) without a location service.
class _StubAccessNotifier extends LocationAccessNotifier {
  _StubAccessNotifier(this._initial);

  final LocationAccessStatus _initial;
  int refreshCalls = 0;

  @override
  LocationAccessStatus build() => _initial;

  @override
  Future<void> refresh() async => refreshCalls++;

  void moveTo(LocationAccessStatus next) => state = next;
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

/// The banner's status node, located by the property that matters rather than
/// by widget type — `ExcludeSemantics` and `Semantics` both appear several
/// times inside Material's own `Card`/`TextButton` internals, so a type finder
/// is ambiguous and would rot the moment Material changes shape.
final Finder _liveRegion = find.byWidgetPredicate(
  (widget) => widget is Semantics && (widget.properties.liveRegion ?? false),
);

void main() {
  late _RecordingLauncher launcher;
  late _StubAccessNotifier notifier;

  Future<AppLocalizations> pumpBanner(
    WidgetTester tester,
    LocationAccessStatus status,
  ) async {
    launcher = _RecordingLauncher();
    notifier = _StubAccessNotifier(status);
    await pumpLocalized(
      tester,
      const Scaffold(body: LocationAccessBanner()),
      overrides: [
        locationAccessProvider.overrideWith(() => notifier),
        locationSettingsLauncherProvider.overrideWithValue(launcher),
      ],
    );
    return AppLocalizations.of(
      tester.element(find.byType(LocationAccessBanner)),
    );
  }

  // -------------------------------------------------------------------------
  // Visibility
  // -------------------------------------------------------------------------

  group('visibility', () {
    testWidgets('renders nothing while access is available', (tester) async {
      final l10n = await pumpBanner(tester, LocationAccessStatus.available);

      expect(find.byType(Card), findsNothing);
      expect(find.text(l10n.mapLocationOffTitle), findsNothing);
      expect(
        find.byType(TextButton),
        findsNothing,
        reason: 'A healthy session must show no surface at all — every '
            '"is shown" assertion below is vacuous otherwise.',
      );
    });

    testWidgets('appears and disappears with the live state', (tester) async {
      final l10n = await pumpBanner(tester, LocationAccessStatus.available);

      notifier.moveTo(LocationAccessStatus.serviceDisabled);
      await tester.pump();
      expect(find.text(l10n.mapLocationOffTitle), findsOneWidget);

      notifier.moveTo(LocationAccessStatus.available);
      await tester.pump();
      expect(
        find.text(l10n.mapLocationOffTitle),
        findsNothing,
        reason: 'It must clear itself in-session, in both directions.',
      );
    });

    testWidgets('offers no dismiss affordance', (tester) async {
      // A dismissible banner would let the user hide a condition that is still
      // true, which is the defect wearing a different hat.
      await pumpBanner(tester, LocationAccessStatus.serviceDisabled);

      expect(find.byIcon(Icons.close), findsNothing);
      expect(find.byType(IconButton), findsNothing);
    });
  });

  // -------------------------------------------------------------------------
  // Cause discrimination, as the user experiences it
  // -------------------------------------------------------------------------

  group('cause discrimination', () {
    testWidgets('service-disabled names the device toggle', (tester) async {
      final l10n = await pumpBanner(
        tester,
        LocationAccessStatus.serviceDisabled,
      );

      expect(find.text(l10n.mapLocationOffTitle), findsOneWidget);
      expect(
        find.text(l10n.mapLocationSharingStoppedServiceOff),
        findsOneWidget,
      );
      expect(find.text(l10n.commonOpenSettings), findsOneWidget);
    });

    testWidgets('permission-denied names the permission', (tester) async {
      final l10n = await pumpBanner(
        tester,
        LocationAccessStatus.permissionDenied,
      );

      expect(find.text(l10n.mapLocationNoPermissionTitle), findsOneWidget);
      expect(find.text(l10n.mapLocationSharingStoppedPermission), findsOneWidget);
      expect(
        find.text(l10n.mapLocationSharingStoppedServiceOff),
        findsNothing,
        reason: 'Telling a user to turn on a location service that is already '
            'on sends them to the wrong screen.',
      );
    });

    testWidgets('service-disabled and permission-denied differ in BOTH title '
        'and message', (tester) async {
      final l10n = await pumpBanner(
        tester,
        LocationAccessStatus.serviceDisabled,
      );
      final serviceCopy = resolveLocationAccessCopy(
        LocationAccessStatus.serviceDisabled,
        l10n,
      )!;
      final permissionCopy = resolveLocationAccessCopy(
        LocationAccessStatus.permissionDenied,
        l10n,
      )!;

      expect(serviceCopy.title, isNot(permissionCopy.title));
      expect(serviceCopy.message, isNot(permissionCopy.message));
    });

    testWidgets('permanently-denied reads differently from denied', (
      tester,
    ) async {
      final l10n = await pumpBanner(
        tester,
        LocationAccessStatus.permissionPermanentlyDenied,
      );

      expect(
        find.text(l10n.mapLocationSharingStoppedPermissionSettings),
        findsOneWidget,
      );
      expect(find.text(l10n.mapLocationSharingStoppedPermission), findsNothing);
    });

    testWidgets('both-blocked names both remedies', (tester) async {
      final l10n = await pumpBanner(
        tester,
        LocationAccessStatus.serviceDisabledAndPermissionDenied,
      );

      expect(find.text(l10n.mapLocationSharingStoppedBoth), findsOneWidget);
    });

    testWidgets('unknown claims no cause and offers a retry', (tester) async {
      // The iOS case the platform genuinely cannot resolve: a denial and a
      // transient GPS failure arrive as the same generic update failure, so if
      // the permission/service reads also fail there is nothing honest to
      // assert.
      final l10n = await pumpBanner(tester, LocationAccessStatus.unknown);

      expect(find.text(l10n.mapLocationErrorTitle), findsOneWidget);
      expect(find.text(l10n.mapLocationSharingStoppedUnknown), findsOneWidget);
      expect(find.text(l10n.commonTryAgain), findsOneWidget);
      expect(find.text(l10n.commonOpenSettings), findsNothing);
    });

    test('every blocked status resolves to distinct, non-empty copy', () async {
      // Guards against a future status quietly reusing another's message,
      // which would silently un-discriminate the causes.
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      final messages = <String>[];
      for (final status in LocationAccessStatus.values) {
        final copy = resolveLocationAccessCopy(status, l10n);
        if (status == LocationAccessStatus.available) {
          expect(copy, isNull, reason: 'nothing to say when access is fine');
          continue;
        }
        expect(copy, isNotNull, reason: '$status must have copy');
        expect(copy!.title, isNotEmpty);
        expect(copy.message, isNotEmpty);
        messages.add(copy.message);
      }
      expect(messages.toSet(), hasLength(messages.length));
    });
  });

  // -------------------------------------------------------------------------
  // Remedies
  // -------------------------------------------------------------------------

  group('remedies', () {
    testWidgets('service-disabled opens the DEVICE location settings', (
      tester,
    ) async {
      final l10n = await pumpBanner(
        tester,
        LocationAccessStatus.serviceDisabled,
      );

      await tester.tap(find.text(l10n.commonOpenSettings));
      await tester.pumpAndSettle();

      expect(launcher.opened, ['location']);
    });

    testWidgets('permission-denied opens the APP settings', (tester) async {
      final l10n = await pumpBanner(
        tester,
        LocationAccessStatus.permissionDenied,
      );

      await tester.tap(find.text(l10n.commonOpenSettings));
      await tester.pumpAndSettle();

      expect(
        launcher.opened,
        ['app'],
        reason: 'The device location toggle is already on in this state; '
            'sending the user there would be a dead end.',
      );
    });

    testWidgets('permanently-denied opens the APP settings', (tester) async {
      final l10n = await pumpBanner(
        tester,
        LocationAccessStatus.permissionPermanentlyDenied,
      );

      await tester.tap(find.text(l10n.commonOpenSettings));
      await tester.pumpAndSettle();

      expect(launcher.opened, ['app']);
    });

    testWidgets('unknown opens nothing and just re-checks', (tester) async {
      final l10n = await pumpBanner(tester, LocationAccessStatus.unknown);

      await tester.tap(find.text(l10n.commonTryAgain));
      await tester.pumpAndSettle();

      expect(launcher.opened, isEmpty);
      expect(notifier.refreshCalls, 1);
    });

    testWidgets('every remedy re-checks afterwards', (tester) async {
      // Some OEM location toggles are reachable from a shade tile without ever
      // pausing Haven, so the resume-driven refresh may never fire.
      final l10n = await pumpBanner(
        tester,
        LocationAccessStatus.serviceDisabled,
      );

      await tester.tap(find.text(l10n.commonOpenSettings));
      await tester.pumpAndSettle();

      expect(notifier.refreshCalls, 1);
    });
  });

  // -------------------------------------------------------------------------
  // Accessibility
  // -------------------------------------------------------------------------

  group('accessibility', () {
    testWidgets('is a live region so it is announced on appearance', (
      tester,
    ) async {
      // WCAG 2.1 SC 4.1.3: a status change a sighted user gets from an overlay
      // has to reach a screen-reader user too. Matches the treatment the map's
      // loading scrim already uses.
      final handle = tester.ensureSemantics();

      final l10n = await pumpBanner(
        tester,
        LocationAccessStatus.serviceDisabled,
      );

      final node = tester.getSemantics(_liveRegion);
      expect(node.hasFlag(SemanticsFlag.isLiveRegion), isTrue);
      expect(
        node.label,
        isNotEmpty,
        reason: 'A live region with no label fires and says nothing.',
      );
      expect(node.label, contains(l10n.mapLocationOffTitle));
      handle.dispose();
    });

    testWidgets('speaks the title and the message together', (tester) async {
      final handle = tester.ensureSemantics();

      final l10n = await pumpBanner(
        tester,
        LocationAccessStatus.serviceDisabled,
      );

      // A single grouped announcement: cause then remedy, not two orphaned
      // fragments the user has to swipe between to make sense of.
      final merged = tester.getSemantics(_liveRegion).label;
      expect(merged, contains(l10n.mapLocationOffTitle));
      expect(merged, contains(l10n.mapLocationSharingStoppedServiceOff));

      // ...but the remedy stays its own actionable node.
      final button = tester.getSemantics(find.byType(TextButton));
      expect(button.label, l10n.commonOpenSettings);
      expect(
        button.getSemanticsData().hasAction(SemanticsAction.tap),
        isTrue,
        reason: 'The remedy must stay independently focusable and tappable.',
      );
      handle.dispose();
    });

    testWidgets('announces recovery, which a live region cannot', (
      tester,
    ) async {
      // A live region announces its APPEARANCE but never its removal, so
      // without an explicit announcement a screen-reader user is told sharing
      // stopped and never told it resumed.
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

      final l10n = await pumpBanner(
        tester,
        LocationAccessStatus.serviceDisabled,
      );
      expect(announcements, isEmpty, reason: 'nothing to announce yet');

      notifier.moveTo(LocationAccessStatus.available);
      await tester.pumpAndSettle();

      expect(announcements, [l10n.mapLocationAccessRestoredAnnouncement]);
    });

    testWidgets('does not announce a change between two blocked causes', (
      tester,
    ) async {
      final announcements = <String>[];
      tester.binding.defaultBinaryMessenger
          .setMockDecodedMessageHandler<dynamic>(SystemChannels.accessibility, (
        dynamic message,
      ) async {
        final map = message! as Map<Object?, Object?>;
        if (map['type'] == 'announce') announcements.add('announced');
        return null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger
            .setMockDecodedMessageHandler<dynamic>(
              SystemChannels.accessibility,
              null,
            ),
      );

      await pumpBanner(tester, LocationAccessStatus.serviceDisabled);
      notifier.moveTo(LocationAccessStatus.permissionDenied);
      await tester.pumpAndSettle();

      expect(
        announcements,
        isEmpty,
        reason: 'Still blocked — claiming recovery here would be a lie, and '
            'the live region already re-announces the new copy.',
      );
    });

    testWidgets('at a 200% text scale the remedy is still ON SCREEN and '
        'tappable on the smallest supported phone', (tester) async {
      // WHAT THIS USED TO ASSERT, AND WHY IT PROVED NOTHING.
      //
      // It pumped at 320 x 900 — taller than any phone ships — and checked
      // only `takeException(), isNull`. Both halves were empty. In the shell
      // the banner sat in a `PositionedDirectional` with no `bottom:`, so its
      // max height was UNBOUNDED and a `RenderFlex` cannot report an overflow
      // it cannot measure: the card simply ran off the viewport in silence. An
      // overflow exception was not merely absent, it was unreachable, so the
      // assertion could never have failed for the defect it was written for.
      //
      // Measured at the time: 652 dp of card at 390 dp wide, 788 dp at 320 dp
      // — against a 568 dp iPhone-SE screen, putting the remedy 304 dp below
      // the fold in a surface with no scroll view of its own.
      //
      // So: a real small-phone viewport, and reachability rather than
      // absence-of-exception.
      const viewport = Size(320, 568);
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = viewport;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      launcher = _RecordingLauncher();
      notifier = _StubAccessNotifier(LocationAccessStatus.serviceDisabled);
      await pumpLocalized(
        tester,
        const Scaffold(body: LocationAccessBanner()),
        textScaler: const TextScaler.linear(2),
        overrides: [
          locationAccessProvider.overrideWith(() => notifier),
          locationSettingsLauncherProvider.overrideWithValue(launcher),
        ],
      );

      final l10n = AppLocalizations.of(
        tester.element(find.byType(LocationAccessBanner)),
      );
      final button = find.widgetWithText(TextButton, l10n.commonOpenSettings);
      final rect = tester.getRect(button);
      expect(
        rect.bottom,
        lessThanOrEqualTo(viewport.height),
        reason: 'the remedy is below the fold at a 200% text scale — the '
            'banner offers no way to scroll to it, so it cannot be used at '
            'all',
      );
      expect(rect.top, greaterThanOrEqualTo(0));

      // On screen is not the same as usable: prove the tap lands.
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(launcher.opened, ['location']);
    });

    testWidgets('the explanation is scrollable rather than truncated', (
      tester,
    ) async {
      // The bound must not be met by cutting the message off. Both sentences
      // stay in the tree, inside a scroll view, so a user at 200% can still
      // read WHY sharing stopped rather than just being offered a button.
      const viewport = Size(320, 568);
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = viewport;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      launcher = _RecordingLauncher();
      notifier = _StubAccessNotifier(LocationAccessStatus.serviceDisabled);
      await pumpLocalized(
        tester,
        const Scaffold(body: LocationAccessBanner()),
        textScaler: const TextScaler.linear(2),
        overrides: [
          locationAccessProvider.overrideWith(() => notifier),
          locationSettingsLauncherProvider.overrideWithValue(launcher),
        ],
      );

      final l10n = AppLocalizations.of(
        tester.element(find.byType(LocationAccessBanner)),
      );
      expect(find.byType(SingleChildScrollView), findsOneWidget);
      expect(find.text(l10n.mapLocationOffTitle), findsOneWidget);
      expect(
        find.text(l10n.mapLocationSharingStoppedServiceOff),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('an ordinary text scale does not scroll or stretch', (
      tester,
    ) async {
      // The scroll view is a ceiling, not a default. If the card started
      // filling its slot, or the body scrolled at 1x, the fix would have cost
      // the ordinary case to save the extreme one.
      const viewport = Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = viewport;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await pumpBanner(tester, LocationAccessStatus.serviceDisabled);

      final card = tester.getSize(find.byType(Card));
      expect(
        card.height,
        lessThan(viewport.height / 2),
        reason: 'the card must still size to its content (measured 208 dp at '
            '390 dp wide), not to the space available',
      );
      final scrollable = tester.state<ScrollableState>(
        find.descendant(
          of: find.byType(SingleChildScrollView),
          matching: find.byType(Scrollable),
        ),
      );
      expect(
        scrollable.position.maxScrollExtent,
        0,
        reason: 'nothing to scroll at 1x — the content fits',
      );
    });
  });
}
