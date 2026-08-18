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

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../integration_test/e2e/_lib/throw_time_error_capture.dart';

/// A real, deliberately-triggered `RenderFlex` overflow: a `Row` forced into
/// less width than its one child needs. `Center` gives its child LOOSE
/// constraints, which `SizedBox(width: 50)` narrows to a tight 50 — without
/// `Center` here, the test surface's own tight root constraints would win
/// and no overflow would occur at all.
Widget _overflowingRow() => const Directionality(
  textDirection: TextDirection.ltr,
  child: Center(
    child: SizedBox(
      width: 50,
      child: Row(children: [SizedBox(width: 200, height: 10)]),
    ),
  ),
);

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

  group('a real, deliberately-triggered RenderFlex overflow', () {
    // The groups above prove the mechanism against `_MutableException`, a
    // deliberate stand-in (see its doc comment) for the harder-to-drive real
    // case: an `Element`'s OWN resolved diagnostics going missing once torn
    // down. This group drives the real case directly, so the promise is
    // proven against the actual defect, not only a proxy for it.
    testWidgets(
      'installChainedThrowTimeHandler logs the creator-chain detail (widget '
      'type + file:line) for a genuine overflow, at throw time',
      (tester) async {
        final logged = <String>[];
        final priorDebugPrint = debugPrint;
        debugPrint = (String? message, {int? wrapWidth}) {
          if (message != null) logged.add(message);
        };
        final restoreHandler = installChainedThrowTimeHandler();
        // Restored synchronously here, NOT via addTearDown: `testWidgets`
        // checks `debugPrint` is back to its expected value as part of the
        // test body's own return (`_verifyInvariants`,
        // `package:flutter_test/src/binding.dart`) — before any
        // `addTearDown` callback runs — so an addTearDown-only restore trips
        // that check the moment this test also calls `takeException()`
        // below (which is exactly what unlocks the check: it is skipped
        // outright while an exception is still pending).
        try {
          await tester.pumpWidget(_overflowingRow());

          expect(
            logged,
            isNotEmpty,
            reason: 'the overflow must actually have fired and been logged',
          );
          expect(
            logged.single,
            contains('The relevant error-causing widget was'),
          );
          expect(
            logged.single,
            matches(RegExp(r'\.dart:\d+:\d+')),
            reason: 'must include a file:line, not just the widget name',
          );
        } finally {
          restoreHandler();
          debugPrint = priorDebugPrint;
        }
        // The overflow is a genuine `FlutterError` the SDK's own bookkeeping
        // handler (chained to above) now tracks as pending — acknowledge it
        // the normal way a real test would, rather than letting it surface
        // as an unrelated "leaked exception" failure at teardown. Chaining
        // through to that bookkeeping, not swallowing it, is the point.
        expect(tester.takeException(), isNotNull);
      },
    );

    testWidgets(
      'MUTATION: without installChainedThrowTimeHandler — the previous, '
      'un-patched behaviour — the same genuine overflow produces no '
      'throw-time attribution at all; the fix is the one call site removed '
      'here, and restoring it (test above) recovers the detail',
      (tester) async {
        final logged = <String>[];
        final priorDebugPrint = debugPrint;
        debugPrint = (String? message, {int? wrapWidth}) {
          if (message != null) logged.add(message);
        };

        // Deliberately NOT calling installChainedThrowTimeHandler(): this IS
        // the mutation. `FlutterError.onError` is left exactly as the
        // ambient test binding installs it, so this measures the real
        // un-patched SDK path, not a hand-rolled substitute for it.
        //
        // This does not go on to render the error *after* the Row's Element
        // is torn down — unlike the `_MutableException` proxy above, doing
        // that here, against a REAL Element, provokes
        // `debugTransformDebugCreator`'s own recovery path (a try/catch
        // around `Element.visitAncestorElements` that, on the resulting
        // "deactivated widget" error, schedules a SECOND `FlutterError
        // .reportError` via `scheduleMicrotask` — verified by observation,
        // not just by reading the source) closely enough to destabilize
        // `flutter_test`'s FakeAsync test zone (observed: a 10-minute CI
        // hang). The doc comment atop this file cites the exact SDK
        // mechanism for why that second render is lossy; this test proves
        // the narrower, safe half — no attribution without the fix — and
        // the `_MutableException` group above proves the same-object,
        // two-render-times half without that hazard.
        try {
          await tester.pumpWidget(_overflowingRow());

          expect(
            logged,
            isEmpty,
            reason: 'with the fix removed, the overflow produces no '
                'throw-time attribution',
          );
        } finally {
          debugPrint = priorDebugPrint;
        }
        expect(tester.takeException(), isNotNull);
      },
    );
  });
}
