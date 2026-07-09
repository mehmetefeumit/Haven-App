/// iOS wiring-proof target for the `e2e-ios` lane (D7 / A10).
///
/// Runs on a real iOS simulator runtime (via `flutter test -d <udid>`) as a
/// SECOND scenario after `e2e_combined`, and proves the two M7-E iOS facts a
/// host-side Dart unit test structurally cannot see:
///
///   1. **Mirror true-by-default.** `writeCatchupEnabledMirror()` writes the
///      compile-time `backgroundCatchupEnabled` const to SharedPreferences key
///      `background_catchup_enabled`, which the Swift side reads as
///      `flutter.background_catchup_enabled`. The test writes it to REAL
///      UserDefaults and, after a `reload()`, reads it back as `true` from the
///      NSUserDefaults domain — the authoritative OS-layer proof. (An external
///      post-test plist read is NOT possible on this lane: `flutter test`
///      removes the app (and its data container) on completion, so the former
///      `assert-ios-catchup-mirror.sh` workflow step could never resolve it.)
///   2. **Swift teardown handlers registered + retained.** Invoking the raw
///      `haven.app/ios_slc_teardown`/`stopSLC` and
///      `haven.app/ios_bgtask_teardown`/`cancelAllBGTasks` channels completes
///      WITHOUT a `MissingPluginException` — proving `AppDelegate` wired the
///      handlers and holds strong references to them at runtime (the part a
///      Dart unit test cannot reach).
///
/// The channel-name / mirror-key literals are duplicated here on purpose: they
/// are private in `ios_background_catchup.dart`, and the static guard (check 6)
/// already pins the source values, so drift is caught there.
///
/// A real BGTask/SLC FIRE stays an owner checklist item — the Simulator cannot
/// fire `BGTaskScheduler` (plan §6).
library;

import 'dart:io' show Platform;

import 'package:flutter/services.dart'
    show MethodChannel, MissingPluginException;
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/live_sync_provider.dart'
    show backgroundCatchupEnabled;
import 'package:haven/src/services/ios_background_catchup.dart'
    show writeCatchupEnabledMirror;
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Mirror key written by `writeCatchupEnabledMirror()` (Dart side; Swift reads
/// it prefixed as `flutter.background_catchup_enabled`). Pinned in source by
/// the static guard; duplicated here because the source const is private.
const String _kMirrorKey = 'background_catchup_enabled';

/// Dart → Swift teardown channels + methods (private in the source service;
/// pinned by static-guard check 6).
const String _kSlcTeardownChannel = 'haven.app/ios_slc_teardown';
const String _kSlcTeardownMethod = 'stopSLC';
const String _kBgTaskTeardownChannel = 'haven.app/ios_bgtask_teardown';
const String _kBgTaskTeardownMethod = 'cancelAllBGTasks';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('iOS M7-E wiring', () {
    testWidgets('mirror writes true and Swift teardown channels are reachable',
        (tester) async {
      if (!Platform.isIOS) {
        // This target only proves iOS-specific wiring; it is driven only on the
        // sim. An honest skip (not a failure) elsewhere.
        markTestSkipped('iOS-only wiring proof; skipped on non-iOS runtime.');
        return;
      }

      // --- (1) Mirror is true-by-default at launch ----------------------
      // Do NOT use SharedPreferences.setMockInitialValues here: this must hit
      // REAL UserDefaults, because the read-back below is the authoritative
      // OS-layer proof of the mirror (see class doc). `flutter test` removes
      // the app on completion, so an external post-test plist read can't run
      // on this lane — the in-process reload read-back stands in for it.
      await writeCatchupEnabledMirror();
      // Let the platform flush the write, then reload() so the read-back comes
      // from the NSUserDefaults domain (what Swift reads via
      // `UserDefaults.standard.bool(forKey:)`) not the Dart write-cache,
      // proving the value round-tripped through real UserDefaults.
      await tester.pump(const Duration(seconds: 1));

      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      expect(
        prefs.getBool(_kMirrorKey),
        isTrue,
        reason: 'writeCatchupEnabledMirror() must mirror '
            'backgroundCatchupEnabled ($backgroundCatchupEnabled) to '
            '$_kMirrorKey so the Swift side reads it as '
            'flutter.$_kMirrorKey.',
      );
      expect(backgroundCatchupEnabled, isTrue);

      // --- (2) Swift teardown handlers registered + retained ------------
      // Invoking must NOT throw MissingPluginException. A PlatformException
      // (handler ran and returned an error) would still prove the channel is
      // WIRED, so only a missing handler fails the test.
      await _expectChannelWired(_kSlcTeardownChannel, _kSlcTeardownMethod);
      await _expectChannelWired(
        _kBgTaskTeardownChannel,
        _kBgTaskTeardownMethod,
      );
    });
  });
}

/// Invokes [method] on the [channel] and fails ONLY if the platform reports no
/// handler ([MissingPluginException]) — proving `AppDelegate` registered and
/// retains the Swift handler. Any other completion (a `null` reply or a
/// `PlatformException`) still demonstrates the channel is wired.
Future<void> _expectChannelWired(String channel, String method) async {
  try {
    await MethodChannel(channel).invokeMethod<void>(method);
  } on MissingPluginException {
    fail(
      'Channel "$channel" has no registered handler — AppDelegate did not wire '
      'the Swift teardown handler (or did not retain it). Expected '
      '$method to reach native.',
    );
  } on Object {
    // Handler exists but returned an error / non-null — still proves wiring.
  }
}
