/// Widget tests for [ProfileSyncStatusLine].
///
/// Covers every [ProfileSyncStatus] rendering (`unknown` renders nothing;
/// `syncing`/`partial`/`synced`/`failed` each show their icon + text), that
/// the passive status is one screen-reader live region (`clock_skew_banner`
/// precedent), that the Retry action only appears in `failed`, and that
/// tapping Retry re-calls `ProfileService.syncOwnProfile` via the shared
/// [ownProfileSyncProvider] controller (not a copy of its logic).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/providers/profile_sync_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/widgets/identity/profile_sync_status_line.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../helpers/localized_app_harness.dart';
import '../../mocks/mock_profile_service.dart';

/// A fixed-status fake controller so each rendering test is independent of
/// [OwnProfileSyncController]'s own resolution logic (that logic has its own
/// full coverage in `test/providers/profile_sync_provider_test.dart`) —
/// build() overrides the base class entirely (never calls `super.build()`),
/// so no network/local read happens on mount.
class _FixedSyncController extends OwnProfileSyncController {
  _FixedSyncController(this._fixed);

  final ProfileSyncStatus _fixed;

  @override
  ProfileSyncStatus build() => _fixed;
}

/// A controller whose status can change mid-test (by assigning [status]),
/// for the S6 announce-transitions tests — [_FixedSyncController] cannot
/// represent a real transition within one mount.
class _MutableSyncController extends OwnProfileSyncController {
  _MutableSyncController(this._initial);

  final ProfileSyncStatus _initial;

  @override
  ProfileSyncStatus build() => _initial;

  /// The controller's current resting state; assigning transitions it
  /// exactly as [OwnProfileSyncController.sync] would.
  ProfileSyncStatus get status => state;
  set status(ProfileSyncStatus value) => state = value;
}

Future<void> _pumpStatus(
  WidgetTester tester,
  ProfileSyncStatus status, {
  MockProfileService? profileService,
}) async {
  await pumpLocalized(
    tester,
    const Scaffold(body: ProfileSyncStatusLine()),
    overrides: [
      profileServiceProvider.overrideWithValue(
        profileService ?? MockProfileService(),
      ),
      ownProfileSyncProvider.overrideWith(
        () => _FixedSyncController(status),
      ),
    ],
    // `syncing` renders an indeterminate `CircularProgressIndicator`, which
    // schedules a new frame forever and would hang `pumpAndSettle`.
    settle: status != ProfileSyncStatus.syncing,
  );
}

void main() {
  late AppLocalizations l10n;

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('en'));
  });

  group('ProfileSyncStatusLine — rendering per state', () {
    testWidgets('unknown renders nothing', (tester) async {
      await _pumpStatus(tester, ProfileSyncStatus.unknown);

      expect(find.byType(SizedBox), findsOneWidget);
      expect(find.text(l10n.profileSyncStatusSyncing), findsNothing);
      expect(find.text(l10n.profileSyncStatusPartial), findsNothing);
      expect(find.text(l10n.profileSyncStatusSynced), findsNothing);
      expect(find.text(l10n.profileSyncStatusFailed), findsNothing);
      expect(find.byKey(WidgetKeys.profileSyncRetryButton), findsNothing);
    });

    testWidgets('syncing shows a spinner and the syncing text', (
      tester,
    ) async {
      await _pumpStatus(tester, ProfileSyncStatus.syncing);

      expect(find.text(l10n.profileSyncStatusSyncing), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byKey(WidgetKeys.profileSyncRetryButton), findsNothing);
    });

    testWidgets(
      'the syncing spinner is 14dp at strokeWidth 2, matching the row`s '
      'other 14dp icons so row height stays stable across states (N5)',
      (tester) async {
        await _pumpStatus(tester, ProfileSyncStatus.syncing);

        final spinner = tester.widget<CircularProgressIndicator>(
          find.byType(CircularProgressIndicator),
        );
        expect(spinner.strokeWidth, 2);
        final box = tester.widget<SizedBox>(
          find.ancestor(
            of: find.byType(CircularProgressIndicator),
            matching: find.byType(SizedBox),
          ),
        );
        expect(box.width, 14);
        expect(box.height, 14);
      },
    );

    testWidgets('partial shows the partial text and no Retry', (
      tester,
    ) async {
      await _pumpStatus(tester, ProfileSyncStatus.partial);

      expect(find.text(l10n.profileSyncStatusPartial), findsOneWidget);
      expect(find.byKey(WidgetKeys.profileSyncRetryButton), findsNothing);
    });

    testWidgets(
      'partial uses the pending-glyph clock icon, not the info glyph '
      '(N1 — avoids colliding with HavenInfoNote)',
      (tester) async {
        await _pumpStatus(tester, ProfileSyncStatus.partial);

        expect(find.byIcon(LucideIcons.clock), findsOneWidget);
        expect(find.byIcon(LucideIcons.info), findsNothing);
      },
    );

    testWidgets('synced shows the synced text and no Retry', (tester) async {
      await _pumpStatus(tester, ProfileSyncStatus.synced);

      expect(find.text(l10n.profileSyncStatusSynced), findsOneWidget);
      expect(find.byKey(WidgetKeys.profileSyncRetryButton), findsNothing);
    });

    testWidgets(
      'synced uses the circleCheck glyph, not the bare check used by the '
      'save button (N2)',
      (tester) async {
        await _pumpStatus(tester, ProfileSyncStatus.synced);

        expect(find.byIcon(LucideIcons.circleCheck), findsOneWidget);
        expect(find.byIcon(LucideIcons.check), findsNothing);
      },
    );

    testWidgets('failed shows the failed text AND a Retry action', (
      tester,
    ) async {
      await _pumpStatus(tester, ProfileSyncStatus.failed);

      expect(find.text(l10n.profileSyncStatusFailed), findsOneWidget);
      expect(find.byKey(WidgetKeys.profileSyncRetryButton), findsOneWidget);
      expect(find.text(l10n.commonRetry), findsOneWidget);
    });
  });

  group('ProfileSyncStatusLine — semantics', () {
    testWidgets(
      'the passive status is a single live-region node carrying the '
      'status text',
      (tester) async {
        final handle = tester.ensureSemantics();
        await _pumpStatus(tester, ProfileSyncStatus.partial);

        expect(
          find.bySemanticsLabel(l10n.profileSyncStatusPartial),
          findsOneWidget,
        );
        handle.dispose();
      },
    );

    testWidgets(
      'Retry carries its own, more descriptive accessible label, distinct '
      'from the live-region status node',
      (tester) async {
        final handle = tester.ensureSemantics();
        await _pumpStatus(tester, ProfileSyncStatus.failed);

        expect(
          find.bySemanticsLabel(l10n.profileSyncStatusRetrySemantics),
          findsOneWidget,
        );
        // The two nodes are genuinely separate: the failed status text
        // itself is still independently discoverable.
        expect(
          find.bySemanticsLabel(l10n.profileSyncStatusFailed),
          findsOneWidget,
        );
        handle.dispose();
      },
    );

    testWidgets(
      'mounting directly in synced (never anything else) is NOT a live '
      'region — opening the page must not announce the resting state (S6)',
      (tester) async {
        final handle = tester.ensureSemantics();
        await _pumpStatus(tester, ProfileSyncStatus.synced);

        final node = tester.getSemantics(
          find.bySemanticsLabel(l10n.profileSyncStatusSynced),
        );
        expect(node.flagsCollection.isLiveRegion, isFalse);
        handle.dispose();
      },
    );

    testWidgets(
      'syncing -> synced IS a live region — a real transition is always '
      'announced (S6)',
      (tester) async {
        final handle = tester.ensureSemantics();
        final controller = _MutableSyncController(ProfileSyncStatus.syncing);
        final container = ProviderContainer(
          overrides: [
            profileServiceProvider.overrideWithValue(MockProfileService()),
            ownProfileSyncProvider.overrideWith(() => controller),
          ],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(body: ProfileSyncStatusLine()),
            ),
          ),
        );
        // `syncing` renders an indeterminate spinner — bounded pump only.
        await tester.pump();

        controller.status = ProfileSyncStatus.synced;
        await tester.pumpAndSettle();

        final node = tester.getSemantics(
          find.bySemanticsLabel(l10n.profileSyncStatusSynced),
        );
        expect(node.flagsCollection.isLiveRegion, isTrue);
        handle.dispose();
      },
    );
  });

  group('ProfileSyncStatusLine — Retry', () {
    testWidgets('tapping Retry re-calls syncOwnProfile', (tester) async {
      final svc = MockProfileService();
      await _pumpStatus(tester, ProfileSyncStatus.failed, profileService: svc);

      await tester.tap(find.byKey(WidgetKeys.profileSyncRetryButton));
      // Deliberately NOT pumpAndSettle — a successful retry flips the
      // controller to `syncing` (indeterminate spinner) before resolving,
      // which would hang it.
      await tester.pump();
      await tester.pump();

      expect(
        svc.methodCalls.map((c) => c.method),
        contains('syncOwnProfile'),
      );
    });

    testWidgets(
      'Retry has an at-least-48dp tap target despite its compact chrome '
      '(S4, WCAG 2.5.5)',
      (tester) async {
        await _pumpStatus(tester, ProfileSyncStatus.failed);

        final size = tester.getSize(
          find.byKey(WidgetKeys.profileSyncRetryButton),
        );
        expect(size.height, greaterThanOrEqualTo(48));
      },
    );
  });

  group('ProfileSyncStatusLine — AnimatedSize (S2)', () {
    testWidgets(
      'animates state changes with a 200ms easeInOut AnimatedSize by '
      'default',
      (tester) async {
        await _pumpStatus(tester, ProfileSyncStatus.synced);

        final animatedSize = tester.widget<AnimatedSize>(
          find.byType(AnimatedSize),
        );
        expect(animatedSize.duration, const Duration(milliseconds: 200));
        expect(animatedSize.curve, Curves.easeInOut);
      },
    );

    testWidgets('collapses to a zero-duration AnimatedSize under reduced '
        'motion', (tester) async {
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: ProviderScope(
            overrides: [
              profileServiceProvider.overrideWithValue(MockProfileService()),
              ownProfileSyncProvider.overrideWith(
                () => _FixedSyncController(ProfileSyncStatus.synced),
              ),
            ],
            child: const MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(body: ProfileSyncStatusLine()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final animatedSize = tester.widget<AnimatedSize>(
        find.byType(AnimatedSize),
      );
      expect(animatedSize.duration, Duration.zero);
    });
  });
}
