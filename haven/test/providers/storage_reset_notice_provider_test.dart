/// Tests for [decideStorageResetNotice].
///
/// The promises: the notice is owed exactly when the core reset says so; a
/// reset that throws falls back to whether the marker stands — a held
/// relay-list publish is never left with no notice to release it — and never
/// crashes startup; its log lines carry the error's type only, never the data
/// directory (it can contain the user's account name) or the error's text; and
/// the preferences naming deleted circles are cleared once per reset; and
/// MapShell's half shows the notice only when owed, at most once a session,
/// and re-runs the KeyPackage publisher only after the reset is acknowledged.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/providers/key_package_provider.dart';
import 'package:haven/src/providers/onboarding_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/providers/storage_reset_notice_provider.dart';
import 'package:haven/src/services/pending_leave_service.dart';
import 'package:haven/src/services/relay_service.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/widgets/common/storage_reset_notice_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/localized_app_harness.dart';
import '../helpers/log_capture.dart';
import '../mocks/mock_circle_service.dart';

const _dataDir = '/data/user/0/quiet.wanderer.home/app_flutter';
const _relayPage = 'relay settings page';

void main() {
  test('owes the notice exactly when the reset reports it', () {
    final seen = <String>[];

    expect(
      decideStorageResetNotice(
        _dataDir,
        reset: (dir) {
          seen.add(dir);
          return true;
        },
      ),
      isTrue,
    );
    expect(decideStorageResetNotice(_dataDir, reset: (_) => false), isFalse);
    expect(seen, [_dataDir], reason: 'the reset runs on the directory given');
  });

  test('a reset that throws falls back to the marker and logs only the error '
      'type', () {
    final logs = LogCapture.install();

    bool throwingReset(String dir) =>
        throw StateError('could not open $dir/mls.db');
    expect(
      decideStorageResetNotice(
        _dataDir,
        reset: throwingReset,
        owed: (_) => true,
      ),
      isTrue,
      reason: 'a marker another opener wrote still owes the notice, or '
          'relay-list publishing stays held with nothing on screen to '
          'release it',
    );
    expect(
      decideStorageResetNotice(
        _dataDir,
        reset: throwingReset,
        owed: (_) => false,
      ),
      isFalse,
    );
    expect(
      decideStorageResetNotice(
        _dataDir,
        reset: throwingReset,
        owed: (dir) => throw StateError('no marker read at $dir'),
      ),
      isFalse,
      reason: 'startup never crashes on it',
    );
    logs
      ..assertContains('StateError')
      ..assertNoNeedles([_dataDir, 'quiet.wanderer', 'mls.db']);
  });

  test('the preferences naming deleted circles are cleared once, by the '
      'launch the reset owes it to', () async {
    Future<SharedPreferences> seeded() async {
      SharedPreferences.setMockInitialValues({
        kPendingLeaveKey: ['ab' * 32],
        kBackgroundLastPublishMsKey: 1756468800000,
        kBackgroundSessionReclaimAtMsKey: 1756468800000,
        kOnboardingCompletedKey: true,
      });
      return SharedPreferences.getInstance();
    }

    final prefs = await seeded();
    final recorded = <String>[];
    var owed = true;
    await clearCircleScopedPrefsIfResetOwes(
      prefs,
      _dataDir,
      owed: (_) => owed,
      cleared: (dir) {
        recorded.add(dir);
        owed = false;
      },
    );
    expect(prefs.containsKey(kPendingLeaveKey), isFalse);
    expect(prefs.containsKey(kBackgroundLastPublishMsKey), isFalse);
    expect(prefs.containsKey(kBackgroundSessionReclaimAtMsKey), isFalse);
    expect(
      prefs.getBool(kOnboardingCompletedKey),
      isTrue,
      reason: 'device preferences survive: the identity is unchanged',
    );
    expect(recorded, [_dataDir], reason: 'and the debt is recorded as paid');

    // A later launch while the notice still waits: the app has been making
    // new circle-scoped preferences since, and they stay.
    final later = await seeded();
    await clearCircleScopedPrefsIfResetOwes(
      later,
      _dataDir,
      owed: (_) => owed,
      cleared: recorded.add,
    );
    expect(later.containsKey(kPendingLeaveKey), isTrue);
    expect(recorded, hasLength(1));
  });

  test('an unreadable prefs marker clears nothing and logs only the error '
      'type', () async {
    SharedPreferences.setMockInitialValues({
      kPendingLeaveKey: ['ab' * 32],
    });
    final prefs = await SharedPreferences.getInstance();
    final logs = LogCapture.install();
    // Collected, not `fail`ed in the callback: production calls `cleared`
    // inside a catch-all, which would swallow the failure.
    final recorded = <String>[];
    await clearCircleScopedPrefsIfResetOwes(
      prefs,
      _dataDir,
      owed: (dir) => throw StateError('no marker at $dir'),
      cleared: recorded.add,
    );
    expect(prefs.containsKey(kPendingLeaveKey), isTrue);
    expect(
      recorded,
      isEmpty,
      reason: 'nothing was cleared, so nothing is recorded',
    );
    logs
      ..assertContains('StateError')
      ..assertNoNeedles([_dataDir, 'quiet.wanderer']);
  });

  test('a clear that fails stops nothing, is not recorded, and logs only its '
      'type', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final logs = LogCapture.install();
    final recorded = <String>[];
    await expectLater(
      clearCircleScopedPrefsIfResetOwes(
        prefs,
        _dataDir,
        owed: (_) => true,
        cleared: recorded.add,
        clear: (_) async => throw StateError('prefs at $_dataDir'),
      ),
      completes,
      reason: 'runs before runApp: a throw here would keep the app from '
          'starting',
    );
    expect(recorded, isEmpty, reason: 'a clear that failed is still owed');
    logs
      ..assertContains('storage reset prefs not cleared: StateError')
      ..assertNoNeedles([_dataDir]);
  });

  group('showStorageResetNoticeIfOwed', () {
    const opener = Key('run_startup_notice');
    late int publisherRuns;
    late MockCircleService circles;

    Future<void> pumpShell(
      WidgetTester tester, {
      required bool owed,
      bool viaRelaySettingsPage = false,
    }) async {
      publisherRuns = 0;
      circles = MockCircleService();
      await pumpLocalized(
        tester,
        Scaffold(
          body: Consumer(
            builder: (context, ref, _) => TextButton(
              key: opener,
              onPressed: () {
                final navigator = Navigator.of(context);
                showStorageResetNoticeIfOwed(
                  context,
                  ref,
                  openRelaySettings: viaRelaySettingsPage
                      ? () => openRelaySettingsForNotice(
                          navigator,
                          (_) => Scaffold(
                            appBar: AppBar(),
                            body: const Text(_relayPage),
                          ),
                        )
                      : () async {},
                );
              },
              child: const Text('startup'),
            ),
          ),
        ),
        overrides: [
          storageResetNoticeProvider.overrideWith((ref) => owed),
          circleServiceProvider.overrideWithValue(circles),
          keyPackagePublisherProvider.overrideWith((ref) {
            publisherRuns++;
            return Completer<KeyPackageMaintenanceOutcome>().future;
          }),
        ],
      );
    }

    Future<void> runStartup(WidgetTester tester) async {
      await tester.tap(find.byKey(opener));
      await tester.pumpAndSettle();
    }

    testWidgets('an owed notice is shown once a session, and the KeyPackage '
        'publisher re-runs only after it is answered', (tester) async {
      await pumpShell(tester, owed: true);

      await runStartup(tester);
      expect(find.byType(StorageResetNoticeDialog), findsOneWidget);
      expect(publisherRuns, 0, reason: 'nothing may run before the answer');

      await tester.tap(find.byKey(WidgetKeys.storageResetContinue));
      await tester.pumpAndSettle();
      expect(circles.methodCalls, contains('acknowledgeStorageReset'));
      expect(publisherRuns, 1);

      await runStartup(tester);
      expect(
        find.byType(StorageResetNoticeDialog),
        findsNothing,
        reason: 'a rebuild never shows it twice in one session',
      );
    });

    testWidgets('a fresh install is shown nothing', (tester) async {
      await pumpShell(tester, owed: false);

      await runStartup(tester);

      expect(find.byType(StorageResetNoticeDialog), findsNothing);
      expect(circles.methodCalls, isNot(contains('acknowledgeStorageReset')));
      expect(publisherRuns, 0);
    });

    testWidgets('a failed answer says so and does not re-run the publisher '
        'until Try Again saves it', (tester) async {
      await pumpShell(tester, owed: true);
      circles.shouldThrowOnAcknowledgeStorageReset = true;

      await runStartup(tester);
      await tester.tap(find.byKey(WidgetKeys.storageResetContinue));
      await tester.pumpAndSettle();

      final l10n = l10nOf(tester, Scaffold);
      expect(find.text(l10n.storageResetAcknowledgeFailed), findsOneWidget);
      expect(
        publisherRuns,
        0,
        reason: 'the core still holds the KeyPackage publish',
      );

      circles.shouldThrowOnAcknowledgeStorageReset = false;
      await tester.tap(find.text(l10n.commonTryAgain));
      await tester.pumpAndSettle();
      expect(
        publisherRuns,
        1,
        reason: 'publishing is released this session, not next launch',
      );
    });

    testWidgets('the answer waits until the user comes back from Relay '
        'settings', (tester) async {
      await pumpShell(tester, owed: true, viaRelaySettingsPage: true);

      await runStartup(tester);
      await tester.tap(find.byKey(WidgetKeys.storageResetOpenRelaySettings));
      await tester.pumpAndSettle();
      expect(find.text(_relayPage), findsOneWidget);
      expect(
        circles.methodCalls,
        isNot(contains('acknowledgeStorageReset')),
        reason: 'no relay list or KeyPackage is published while the user adds '
            'their own relays',
      );
      expect(publisherRuns, 0);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(circles.methodCalls, contains('acknowledgeStorageReset'));
      expect(publisherRuns, 1);
    });
  });
}
