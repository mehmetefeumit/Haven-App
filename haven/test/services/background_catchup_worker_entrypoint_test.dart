/// Proves `callbackDispatcher`'s uncaught-error redaction actually RUNS.
///
/// The WorkManager isolate never executes `main()`, so `main.dart`'s
/// `FlutterError.onError` / `PlatformDispatcher.instance.onError`
/// installation is not inherited — `callbackDispatcher` installs its own copy
/// (Security Rule 8/15). `test/lints/release_error_redaction_test.dart` pins
/// that the exact statements are present in this file's source, but a source
/// pin cannot prove the statements execute or that nothing between them and
/// `WidgetsFlutterBinding.ensureInitialized()` throws first. This test calls
/// the real, un-mocked `callbackDispatcher()` and drives the two handlers it
/// installs, complementing that source pin with a behavioural one.
///
/// `callbackDispatcher` ends by calling `Workmanager().executeTask(...)`,
/// which assigns a `static late final` field in the `workmanager` package —
/// throwing `LateInitializationError` on a second assignment in the same
/// isolate. `flutter test` gives every test FILE its own isolate, so
/// `callbackDispatcher()` is called exactly ONCE below (in `setUpAll`); do
/// not add a second call anywhere else in this file.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/services/background_catchup_worker.dart';

import '../helpers/log_capture.dart';

/// Mirrors `test/lints/release_error_redaction_test.dart`'s fixture: a
/// `toString()` that embeds a 64-hex needle, the shape of a real MLS/Nostr
/// group id or event id that must never reach a log line.
class _LeakyException implements Exception {
  const _LeakyException(this._needle);

  final String _needle;

  @override
  String toString() => 'LeakyException: group $_needle failed';
}

const _needle64Hex =
    'deadbeefcafef00d1234567890abcdef1234567890abcdef1234567890abcd';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  var priorFlutterErrorHandler = FlutterError.onError;
  var priorDispatcherHandler = PlatformDispatcher.instance.onError;

  // Runs the real entry-point exactly once for this isolate, then restores
  // whatever handlers were in place beforehand (the test binding's own) so
  // this file's teardown leaves no cross-test residue — mirrors how
  // release_error_redaction_test.dart saves/restores both handlers around
  // its own assignments.
  setUpAll(() {
    priorFlutterErrorHandler = FlutterError.onError;
    priorDispatcherHandler = PlatformDispatcher.instance.onError;
    callbackDispatcher();
  });

  tearDownAll(() {
    FlutterError.onError = priorFlutterErrorHandler;
    PlatformDispatcher.instance.onError = priorDispatcherHandler;
  });

  test(
    'callbackDispatcher installs a FlutterError.onError that logs the '
    'exception TYPE and library only',
    () {
      final logged = LogCapture.install();

      FlutterError.onError!(
        const FlutterErrorDetails(
          exception: _LeakyException(_needle64Hex),
          library: 'haven test',
        ),
      );

      logged
        ..assertContains('_LeakyException')
        ..assertContains('haven test')
        ..assertNoNeedles([_needle64Hex]);
    },
  );

  test(
    'callbackDispatcher installs a PlatformDispatcher.onError that logs '
    'the TYPE only and swallows the error',
    () {
      final logged = LogCapture.install();
      final stack = StackTrace.current;

      final handled = PlatformDispatcher.instance.onError!(
        const _LeakyException(_needle64Hex),
        stack,
      );

      expect(handled, isTrue);
      logged
        ..assertContains('_LeakyException')
        // "type only" also means the stack trace text never reaches the log.
        ..assertNoNeedles([_needle64Hex, stack.toString().split('\n').first]);
    },
  );
}
