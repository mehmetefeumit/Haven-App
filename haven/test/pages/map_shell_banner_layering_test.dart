/// Pins that the map's status banner is actually USABLE where it is placed —
/// visible, on-screen and hit-testable — rather than merely present in the
/// widget tree.
///
/// ## The defect these exist to close
///
/// The banner was placed in `MapShell`'s `Stack` BEFORE `CirclesBottomSheet`,
/// so the sheet painted and hit-tested above it. The sheet's snap ladder tops
/// out at 0.85 and its builder returns an opaque `colorScheme.surface`, so on a
/// 390 x 844 phone (safe-area top 47) the sheet's top edge rests at y = 126.6
/// while the banner spans y = 111 to 319: fifteen of its 208 dp were visible,
/// and the remedy button — which sits at the BOTTOM of the card — was neither
/// visible nor tappable. 0.85 is a resting detent, so a user browsing their
/// member list was told nothing at all about their sharing being dead.
///
/// The second defect was height. `PositionedDirectional` with `top`/`start`/
/// `end` and no `bottom` leaves the max height unbounded, so the card could
/// never overflow — it simply ran off the viewport, with no exception and no
/// overflow stripe. At a 200 % text scale it is 652 dp on a 390 dp-wide phone
/// and 788 dp at 320 dp, putting the remedy hundreds of dp below the fold.
///
/// ## Why these assertions are shaped the way they are
///
/// `find.text(...).evaluate().isNotEmpty` — which is what the B6 CI lane's
/// `surfacingVisible()` uses — matches a fully occluded widget, so the entire
/// first defect was structurally invisible to it. Presence is therefore never
/// what is asserted here. Every check is either a hit test at the widget's own
/// centre or a rectangle compared against the viewport.
///
/// ## Why a composed harness rather than pumping MapShell
///
/// `MapPage` calls `HavenCore.newInstance()` across the Rust FFI in
/// `initState`, so `MapShell` cannot be pumped in `flutter test` (CLAUDE.md).
/// The layering is therefore expressed as `MapShell.buildLayers`, a pure static
/// that `MapShell.build` itself calls, and these tests hand it the REAL banner
/// slot and the REAL `CirclesBottomSheet` at the REAL offsets. Only the map
/// gets a stand-in, and it is the one layer whose paint order nothing here
/// depends on. A hand-rolled replica of the stack would prove only that the
/// replica is correct.
library;

import 'package:flutter/gestures.dart' show HitTestResult;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/pages/map_shell.dart';
import 'package:haven/src/providers/location_access_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/location_settings_launcher.dart';
import 'package:haven/src/widgets/circles/circles_bottom_sheet.dart';
import 'package:haven/src/widgets/common/dim_overlay.dart';
import 'package:haven/src/widgets/map/map_status_banners.dart';

import '../mocks/mock_circle_service.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

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

/// A [LocationAccessNotifier] with the platform wiring removed, so the layering
/// can be driven without a location service.
class _StubAccessNotifier extends LocationAccessNotifier {
  _StubAccessNotifier(this._initial);

  final LocationAccessStatus _initial;

  @override
  LocationAccessStatus build() => _initial;

  @override
  Future<void> refresh() async {}
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

/// An iPhone-13-class viewport: the exact geometry the occlusion was measured
/// on. Logical pixels, so `devicePixelRatio` is pinned to 1.
const Size _kPhone = Size(390, 844);
const double _kTopPadding = 47;

/// An iPhone-SE-class viewport — the smallest Haven supports, and where the
/// 200 % text scale bites hardest.
const Size _kSmallPhone = Size(320, 568);
const double _kSmallTopPadding = 20;

void main() {
  late _RecordingLauncher launcher;

  /// Pumps the REAL shell layer stack with a stand-in for the map only, and
  /// drives the bottom sheet to [sheetSize].
  Future<AppLocalizations> pumpShellLayers(
    WidgetTester tester, {
    required LocationAccessStatus status,
    Size size = _kPhone,
    double topPadding = _kTopPadding,
    double sheetSize = 0.12,
    TextScaler textScaler = TextScaler.noScaling,
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    launcher = _RecordingLauncher();
    final sheetController = DraggableScrollableController();
    addTearDown(sheetController.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          locationAccessProvider.overrideWith(
            () => _StubAccessNotifier(status),
          ),
          locationSettingsLauncherProvider.overrideWithValue(launcher),
          circleServiceProvider.overrideWithValue(MockCircleService()),
        ],
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            // The safe-area inset is supplied explicitly: it is an input to the
            // banner's own offset, so a test that let it default to zero would
            // be measuring a phone that does not exist.
            data: MediaQuery.of(context).copyWith(
              padding: EdgeInsets.only(top: topPadding),
              textScaler: textScaler,
            ),
            child: child!,
          ),
          home: Scaffold(
            body: Stack(
              children: MapShell.buildLayers(
                topPadding: topPadding,
                bottomPadding: 0,
                map: const ColoredBox(
                  color: Color(0xFF102030),
                  child: SizedBox.expand(),
                ),
                dimOverlay: const DimOverlay(opacity: 0),
                invitationsButton: const SizedBox(width: 48, height: 48),
                settingsButton: const SizedBox(width: 48, height: 48),
                statusBanners: const MapStatusBanners(),
                circlesSheet: CirclesBottomSheet(
                  controller: sheetController,
                  onExpansionChanged: (_) {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    if (sheetSize != 0.12) {
      sheetController.jumpTo(sheetSize);
      await tester.pumpAndSettle();
    }

    return AppLocalizations.of(tester.element(find.byType(MapStatusBanners)));
  }

  /// Whether a hit test at [finder]'s centre actually reaches it.
  ///
  /// This — not `find.text(...)` — is the assertion the occlusion defect
  /// needed: the banner was in the tree, laid out, and findable the whole
  /// time. It was simply underneath an opaque sheet.
  bool hitTestReaches(WidgetTester tester, Finder finder) {
    final centre = tester.getCenter(finder);
    final target = tester.renderObject(finder);
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(result, centre, tester.view.viewId);
    return result.path.any((entry) => entry.target == target);
  }

  // -------------------------------------------------------------------------
  // F1 — the occlusion
  // -------------------------------------------------------------------------

  group('the banner is usable at every sheet detent', () {
    testWidgets('its remedy is hit-testable at the 0.85 snap', (tester) async {
      // THE DEFECT, at the exact geometry it was measured on. At this detent
      // the sheet's top edge is at y = 126.6 and the banner spans y = 111-319,
      // so before the reorder the "Open settings" button was under an opaque
      // surface and could not be pressed at all.
      final l10n = await pumpShellLayers(
        tester,
        status: LocationAccessStatus.serviceDisabled,
        sheetSize: kCirclesBottomSheetMaxSizeForTesting,
      );

      final button = find.widgetWithText(TextButton, l10n.commonOpenSettings);
      expect(button, findsOneWidget, reason: 'precondition: the remedy exists');
      expect(
        hitTestReaches(tester, button),
        isTrue,
        reason: 'The remedy button is occluded by the circles sheet at its '
            'maximum snap — a resting detent. `find.text(...).evaluate()` '
            '(what the B6 lane uses) matches it anyway, so nothing else in '
            'this repo can catch this.',
      );
    });

    testWidgets('and the remedy actually fires from there', (tester) async {
      // End to end: a tap at the real coordinates must reach the real handler.
      // `warnIfMissed` is left on deliberately — a miss is the defect.
      final l10n = await pumpShellLayers(
        tester,
        status: LocationAccessStatus.serviceDisabled,
        sheetSize: kCirclesBottomSheetMaxSizeForTesting,
      );

      await tester.tap(find.text(l10n.commonOpenSettings));
      await tester.pumpAndSettle();

      expect(launcher.opened, ['location']);
    });

    testWidgets('the status text is not painted under the sheet either', (
      tester,
    ) async {
      final l10n = await pumpShellLayers(
        tester,
        status: LocationAccessStatus.serviceDisabled,
        sheetSize: kCirclesBottomSheetMaxSizeForTesting,
      );

      expect(
        hitTestReaches(tester, find.text(l10n.mapLocationOffTitle)),
        isTrue,
        reason: 'the headline names which of two settings screens to open; a '
            'remedy button with no visible cause is not a surface',
      );
    });

    // The whole snap ladder, from the production constant — so a future detent
    // is covered the day it is added rather than the day it breaks. One test
    // per detent, so a failure names the snap instead of the loop.
    for (final snap in kSnapSizesForTesting) {
      testWidgets('the remedy is reachable at the $snap detent', (
        tester,
      ) async {
        final l10n = await pumpShellLayers(
          tester,
          status: LocationAccessStatus.permissionPermanentlyDenied,
          sheetSize: snap,
        );
        expect(
          hitTestReaches(
            tester,
            find.widgetWithText(TextButton, l10n.commonOpenSettings),
          ),
          isTrue,
          reason: 'occluded at snap $snap',
        );
      });
    }

    testWidgets('the sheet still paints above the MAP — this was a reorder, '
        'not a promotion of the banner over everything', (tester) async {
      await pumpShellLayers(
        tester,
        status: LocationAccessStatus.serviceDisabled,
        sheetSize: kCirclesBottomSheetMaxSizeForTesting,
      );

      // A point deep inside the expanded sheet, well below the banner: the
      // sheet must still own it. If the reorder had moved the map or the dim
      // overlay instead, this is where it would show.
      final probe = Offset(_kPhone.width / 2, _kPhone.height - 60);
      final result = HitTestResult();
      WidgetsBinding.instance.hitTestInView(result, probe, tester.view.viewId);
      final sheetRender = tester.renderObject(
        find.byType(DraggableScrollableSheet),
      );
      expect(
        result.path.any((entry) => entry.target == sheetRender),
        isTrue,
        reason: 'the circles sheet must still be the top layer over the map '
            'everywhere the banner is not',
      );
    });

    testWidgets('the debug overlay still outranks the banner', (tester) async {
      // The one layer that must stay above the banner. Asserted by paint, not
      // by list position, so it holds however the layers are composed.
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = _kPhone;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const debugKey = Key('debug-overlay-sentinel');
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            locationAccessProvider.overrideWith(
              () => _StubAccessNotifier(LocationAccessStatus.serviceDisabled),
            ),
            locationSettingsLauncherProvider.overrideWithValue(
              _RecordingLauncher(),
            ),
            circleServiceProvider.overrideWithValue(MockCircleService()),
          ],
          child: MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Stack(
                children: MapShell.buildLayers(
                  topPadding: _kTopPadding,
                  bottomPadding: 0,
                  map: const SizedBox.expand(),
                  dimOverlay: const DimOverlay(opacity: 0),
                  invitationsButton: const SizedBox(width: 48, height: 48),
                  settingsButton: const SizedBox(width: 48, height: 48),
                  statusBanners: const MapStatusBanners(),
                  circlesSheet: const SizedBox.shrink(),
                  debugOverlay: const Positioned.fill(
                    child: ColoredBox(
                      key: debugKey,
                      color: Color(0xFF000000),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final bannerCentre = tester.getCenter(find.byType(Card));
      final result = HitTestResult();
      WidgetsBinding.instance.hitTestInView(
        result,
        bannerCentre,
        tester.view.viewId,
      );
      final debugRender = tester.renderObject(find.byKey(debugKey));
      expect(
        result.path.any((entry) => entry.target == debugRender),
        isTrue,
        reason: 'a debug build\'s log overlay must still cover the banner',
      );
    });
  });

  // -------------------------------------------------------------------------
  // F4 — the height bound
  // -------------------------------------------------------------------------

  group('the banner stays on screen at large text scales', () {
    testWidgets('the remedy is within the viewport at 200% on a small phone', (
      tester,
    ) async {
      // Unbounded height meant the card simply ran off the bottom: 788 dp of
      // content on a 568 dp screen, remedy 304 dp below the fold, and NO
      // overflow exception to notice — `RenderFlex` can only report an
      // overflow it can measure, and an unbounded main axis has none.
      final l10n = await pumpShellLayers(
        tester,
        status: LocationAccessStatus.serviceDisabled,
        size: _kSmallPhone,
        topPadding: _kSmallTopPadding,
        textScaler: const TextScaler.linear(2),
      );

      final button = find.widgetWithText(TextButton, l10n.commonOpenSettings);
      final rect = tester.getRect(button);
      expect(
        rect.bottom,
        lessThanOrEqualTo(_kSmallPhone.height),
        reason: 'the remedy button is BELOW the fold at a 200% text scale, on '
            'a surface with no scroll view of its own — it cannot be reached '
            'at all',
      );
      expect(rect.top, greaterThanOrEqualTo(0));
      expect(
        hitTestReaches(tester, button),
        isTrue,
        reason: 'on screen but not hit-testable is the same failure',
      );
    });

    testWidgets('the status text is still readable — it scrolls, not clips', (
      tester,
    ) async {
      // Bounding the height must not have been done by silently cutting the
      // message off: the text is in a scroll view, so all of it is reachable.
      await pumpShellLayers(
        tester,
        status: LocationAccessStatus.serviceDisabled,
        size: _kSmallPhone,
        topPadding: _kSmallTopPadding,
        textScaler: const TextScaler.linear(2),
      );

      expect(
        find.descendant(
          of: find.byType(MapStatusBanners),
          matching: find.byType(SingleChildScrollView),
        ),
        findsOneWidget,
        reason: 'without a scroll view the bound would just truncate the '
            'explanation',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('200% on a large phone also fits', (tester) async {
      final l10n = await pumpShellLayers(
        tester,
        status: LocationAccessStatus.serviceDisabledAndPermissionDenied,
        textScaler: const TextScaler.linear(2),
      );

      final rect = tester.getRect(
        find.widgetWithText(TextButton, l10n.commonOpenSettings),
      );
      expect(rect.bottom, lessThanOrEqualTo(_kPhone.height));
      expect(hitTestReaches(tester, find.byType(TextButton)), isTrue);
    });

    testWidgets('the ordinary scale still shrink-wraps — no stretched card', (
      tester,
    ) async {
      // The bound is a MAXIMUM, not a size. If the card started filling the
      // gap between the floating buttons and the sheet it would cover the map
      // for no reason.
      await pumpShellLayers(
        tester,
        status: LocationAccessStatus.serviceDisabled,
      );

      final height = tester.getSize(find.byType(Card)).height;
      expect(
        height,
        lessThan(300),
        reason: 'the card must still size to its content at 1x (measured 208 '
            'dp at 390 dp wide), not stretch to the bound',
      );
    });
  });
}
