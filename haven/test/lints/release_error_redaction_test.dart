/// Proves two things about Flutter's uncaught-error handlers (Security Rule
/// 8/15):
///
/// 1. **Behaviour** — the exact closures this repo installs for
///    `FlutterError.onError` and `PlatformDispatcher.instance.onError` never
///    let an exception's raw message (which could carry an FFI detail
///    string, an MLS group id, anything) reach [debugPrint]; only the
///    failure's TYPE (and, for `FlutterError.onError`, the small fixed
///    `library` name Flutter itself supplies) does.
/// 2. **Reachability** — those exact two statements are actually installed in
///    all three isolate entry points: `main()` (`lib/main.dart`), and the two
///    `@pragma('vm:entry-point')` functions that each run in a SEPARATE
///    isolate and so do not inherit `main()`'s assignment —
///    `callbackDispatcher` (`background_catchup_worker.dart`) and
///    `backgroundCallback` (`background_location_task.dart`).
///
/// Without (2), (1) would only prove a closure that looks like the
/// installed one behaves safely — not that the installed one IS that
/// closure. Both halves are needed, the same reason
/// `throw_time_error_logging_reachable_test.dart` pairs with
/// `throw_time_error_capture_behavior_test.dart`.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/log_capture.dart';

/// An exception whose `toString()` embeds a 64-hex needle — the shape of a
/// real MLS/nostr group id or event id, the value this test proves never
/// reaches a log line via the default/installed error handlers.
class _LeakyException implements Exception {
  const _LeakyException(this._needle);

  final String _needle;

  @override
  String toString() => 'LeakyException: group $_needle failed';
}

const _needle64Hex =
    'deadbeefcafef00d1234567890abcdef1234567890abcdef1234567890abcd';

void main() {
  group('behaviour — the installed FlutterError.onError closure', () {
    test(
      'logs only the exception TYPE + library, never the raw message',
      () {
        final logged = LogCapture.install();
        final priorHandler = FlutterError.onError;
        addTearDown(() => FlutterError.onError = priorHandler);

        // The exact closure installed in main()/callbackDispatcher()/
        // backgroundCallback() — kept as a literal in all four places (here
        // and the three entry points) rather than factored into a shared
        // import, so each entry point's OWN source is what a reader/guard
        // sees; the source-pin tests below tie this copy to those.
        FlutterError.onError = (details) => debugPrint(
          '[FlutterError] ${details.exception.runtimeType} in '
          '${details.library}',
        );

        FlutterError.onError!(
          const FlutterErrorDetails(
            exception: _LeakyException(_needle64Hex),
            library: 'test harness',
          ),
        );

        logged
          ..assertContains('_LeakyException')
          ..assertContains('test harness')
          ..assertNoNeedles([_needle64Hex]);
      },
    );
  });

  group(
    'behaviour — the installed PlatformDispatcher.instance.onError closure',
    () {
      test('logs only the error TYPE, never the raw message', () {
        final logged = LogCapture.install();
        final priorHandler = PlatformDispatcher.instance.onError;
        addTearDown(
          () => PlatformDispatcher.instance.onError = priorHandler,
        );

        PlatformDispatcher.instance.onError = (error, stack) {
          debugPrint('[UncaughtAsync] ${error.runtimeType}');
          return true;
        };

        final handled = PlatformDispatcher.instance.onError!(
          const _LeakyException(_needle64Hex),
          StackTrace.current,
        );

        expect(handled, isTrue);
        logged
          ..assertContains('_LeakyException')
          ..assertNoNeedles([_needle64Hex]);
      });
    },
  );

  group('reachability — installed verbatim in every isolate entry point', () {
    // The exact two statements, as they appear in all three files (modulo
    // leading indentation, which is identical — all three sit at the same
    // one-level-deep indent inside their respective function bodies).
    const flutterErrorAssignment =
        'FlutterError.onError = (details) => debugPrint(\n'
        r"    '[FlutterError] ${details.exception.runtimeType} in "
        r"${details.library}',"
        '\n'
        '  );';
    const platformDispatcherAssignment =
        'PlatformDispatcher.instance.onError = (error, stack) {\n'
        r"    debugPrint('[UncaughtAsync] ${error.runtimeType}');"
        '\n'
        '    return true;\n'
        '  };';

    void expectInstalled(String path) {
      final file = File(path);
      expect(
        file.existsSync(),
        isTrue,
        reason: 'Expected to run from the haven package root '
            '(cwd=${Directory.current.path}).',
      );
      final source = file.readAsStringSync();
      expect(
        source,
        contains(flutterErrorAssignment),
        reason: '$path must install FlutterError.onError with exactly this '
            'body — a reformat here must update this pin, not silently '
            'drop the redaction',
      );
      expect(
        source,
        contains(platformDispatcherAssignment),
        reason: '$path must install PlatformDispatcher.instance.onError '
            'with exactly this body',
      );
    }

    test('lib/main.dart', () => expectInstalled('lib/main.dart'));

    test(
      'lib/src/services/background_catchup_worker.dart (WorkManager isolate)',
      () => expectInstalled(
        'lib/src/services/background_catchup_worker.dart',
      ),
    );

    test(
      'lib/src/services/background_location_task.dart (FGS isolate)',
      () => expectInstalled('lib/src/services/background_location_task.dart'),
    );
  });
}
