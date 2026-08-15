// Behavioural proof for `installChainedThrowTimeHandler` /
// `installThrowTimeErrorLogging`
// (`integration_test/e2e/_lib/throw_time_error_capture.dart`).
//
// Not itself a lint, but it lives here rather than under `integration_test/`
// because the mechanism is a plain synchronous handler swap — provable on
// the host with `flutter test`, with no Rust bridge, device or emulator
// needed. `test/lints/throw_time_error_logging_reachable_test.dart` proves
// every integration test *calls* the helper; this proves the helper itself
// does what calling it promises: chains rather than replaces, restores
// rather than leaks, and renders at throw time rather than deferring.
@TestOn('vm')
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../integration_test/e2e/_lib/throw_time_error_capture.dart';

/// An exception whose `toString()` reflects a field that can be mutated
/// AFTER construction — standing in for the real defect this file guards
/// against, where an `Element`'s resolved diagnostics change (specifically:
/// go missing) once it is deactivated after the exception is thrown but
/// before a deferred report reads `FlutterErrorDetails.toString()`.
class _MutableException implements Exception {
  String state = 'live-at-throw-time';

  @override
  String toString() => 'MutableException(state: $state)';
}

void main() {
  group('installChainedThrowTimeHandler', () {
    test('chains to the previously-installed handler, does not replace it', () {
      final seen = <FlutterErrorDetails>[];
      final priorHandler = FlutterError.onError;
      FlutterError.onError = seen.add;
      addTearDown(() => FlutterError.onError = priorHandler);
      final handlerBeforeInstall = FlutterError.onError;

      final restore = installChainedThrowTimeHandler();
      addTearDown(restore);

      expect(
        FlutterError.onError,
        isNot(same(handlerBeforeInstall)),
        reason: 'installing must swap in a new handler',
      );

      final details = FlutterErrorDetails(
        exception: Exception('boom'),
        library: 'throw_time_error_capture_behavior_test',
      );
      FlutterError.onError!(details);

      expect(
        seen,
        [same(details)],
        reason: 'the previously-installed handler must still run on every '
            'call — chaining, not replacing, is the whole point: losing the '
            "binding's own pending-exception bookkeeping would change test "
            'pass/fail behaviour',
      );
    });

    test('restores exactly the handler that predated it', () {
      final trueOriginalHandler = FlutterError.onError;
      addTearDown(() => FlutterError.onError = trueOriginalHandler);

      FlutterErrorDetails? placeholder;
      FlutterError.onError = (d) => placeholder = d;
      final handlerBeforeInstall = FlutterError.onError;

      final restore = installChainedThrowTimeHandler();
      expect(FlutterError.onError, isNot(same(handlerBeforeInstall)));

      restore();

      expect(
        FlutterError.onError,
        same(handlerBeforeInstall),
        reason: 'restore must put back exactly the handler installed before '
            'it, including when the test that installed it failed — a '
            'leaked handler would silently affect every later test in the '
            'same isolate',
      );
      // Prove the restored handler is genuinely the live one, not merely
      // `same()`-equal to a stale reference.
      FlutterError.onError!(
        FlutterErrorDetails(exception: Exception('after-restore')),
      );
      expect(placeholder, isNotNull);
    });

    test(
      'renders FlutterErrorDetails.toString() synchronously, before any '
      'later mutation of the thrown object',
      () {
        final captured = <String>[];
        final priorDebugPrint = debugPrint;
        debugPrint = (String? message, {int? wrapWidth}) {
          if (message != null) captured.add(message);
        };
        addTearDown(() => debugPrint = priorDebugPrint);

        final priorHandler = FlutterError.onError;
        FlutterError.onError = (_) {};
        addTearDown(() => FlutterError.onError = priorHandler);
        final restore = installChainedThrowTimeHandler();
        addTearDown(restore);

        final exception = _MutableException();
        final details = FlutterErrorDetails(exception: exception);

        FlutterError.onError!(details);
        // Simulate the real defect this helper defeats: the underlying
        // object changes AFTER the throw (an Element deactivating once the
        // test tears down its widget tree) but before any deferred report
        // would have called `.toString()` again.
        exception.state = 'deactivated-after-throw';

        expect(
          captured,
          isNotEmpty,
          reason: 'the handler must log synchronously inside onError, not '
              'defer to end-of-test',
        );
        expect(
          captured.single,
          contains('live-at-throw-time'),
          reason: 'must have rendered the details at throw time — before '
              'the later mutation — proving a deferred .toString() call '
              'would have produced a different, degraded message',
        );
        expect(captured.single, isNot(contains('deactivated-after-throw')));
      },
    );
  });

  group('installThrowTimeErrorLogging', () {
    test(
      'installs immediately and restores via addTearDown when the test ends',
      () {
        final priorHandler = FlutterError.onError;

        // Registered BEFORE installThrowTimeErrorLogging(), so by
        // addTearDown's documented LIFO ordering this runs AFTER the restore
        // that installThrowTimeErrorLogging() registers — i.e. once the
        // handler has already been put back. Deterministic teardown
        // ordering, not a timing race: package:test guarantees LIFO, not
        // "eventually".
        addTearDown(() {
          expect(
            FlutterError.onError,
            same(priorHandler),
            reason: 'installThrowTimeErrorLogging must restore the prior '
                'handler via its own addTearDown before this outer teardown '
                'runs — a handler left installed here would leak into every '
                'later test in the same isolate',
          );
        });

        installThrowTimeErrorLogging();

        expect(
          FlutterError.onError,
          isNot(same(priorHandler)),
          reason: 'installThrowTimeErrorLogging must swap in a new handler '
              'immediately, not defer installation',
        );
      },
    );
  });
}
