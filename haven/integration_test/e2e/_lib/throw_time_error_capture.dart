/// Recovers throw-time widget attribution for `FlutterError`s raised inside
/// an integration `testWidgets` body.
///
/// ## The gap this closes
///
/// `IntegrationTestWidgetsFlutterBinding.reportExceptionNoticed` — the SDK's
/// only *immediate* hook for a caught `FlutterError` — is overridden with an
/// EMPTY body (`package:integration_test/integration_test.dart`), commented
/// "they will also be eventually logged again at the end of the tests"
/// (upstream TODO flutter#81534). That deferred report is lossy for exactly
/// the errors that matter most here: a layout overflow.
///
/// `RenderFlex` embeds the causing `Element` as a live `debugCreator`
/// property, not a pre-rendered string (`package:flutter/src/rendering/
/// flex.dart`). `FlutterErrorDetails.toString()` re-resolves that property on
/// every call — `_FlutterErrorDetailsNode.builder`
/// (`package:flutter/src/foundation/assertions.dart`) re-runs
/// `FlutterErrorDetails.propertiesTransformers` (which includes
/// `debugTransformDebugCreator`, registered by `WidgetsBinding.initInstances`
/// in `package:flutter/src/widgets/binding.dart`) fresh each time, and that
/// transformer walks `element.widget` / `element.visitAncestorElements`
/// (`_describeRelevantUserCode`, `package:flutter/src/widgets/
/// widget_inspector.dart`) on the LIVE `Element`. `Element.deactivate` nulls
/// `_parent` and `Element.unmount` nulls `_widget`
/// (`package:flutter/src/widgets/framework.dart`), so once the test has
/// finished pumping and the offending element has been torn down, that same
/// `.toString()` call silently drops the "The relevant error-causing widget
/// was: …" block and its file:line — leaving only the bare "A RenderFlex
/// overflowed by…" sentence in the `flutter drive` log. Rendering
/// `.toString()` synchronously, at throw time, while the element is still
/// live, recovers it.
///
/// ## Why this must be installed inside the test body
///
/// `testWidgets` wraps every variant as
/// `test(description, () => binding.runTest(callback, ...))`
/// (`package:flutter_test/src/widget_tester.dart`). `package:test`'s
/// `setUp`/`setUpAll` hooks run BEFORE that closure — i.e. before
/// `binding.runTest` starts. `runTest`'s private `_runTest`
/// (`package:flutter_test/src/binding.dart`) unconditionally stashes
/// whatever `FlutterError.onError` is *currently* installed into a private
/// `_oldExceptionHandler` and replaces it with its own bookkeeping handler —
/// which does not call the previous handler, only `reportExceptionNoticed`
/// (the no-op above) and its own pending-exception tracking. The stashed
/// handler is restored exactly once, in `postTest()`, after the test body has
/// already finished — so a handler installed in `setUp` or `setUpAll` is
/// captured as dead storage and never runs DURING the test. The only point
/// that runs after `_runTest` has already swapped its handler in is the
/// `WidgetTesterCallback` itself — the body of the individual `testWidgets`
/// call.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// Swaps in a chained `FlutterError.onError` that logs
/// [FlutterErrorDetails.toString] synchronously (at throw time) before
/// calling through to whatever handler was already installed, and returns a
/// callback that restores that previous handler.
///
/// This is the pure, directly-testable mechanism;
/// [installThrowTimeErrorLogging] below is the convenience wrapper every
/// `testWidgets` body calls.
VoidCallback installChainedThrowTimeHandler() {
  final previousOnError = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {
    debugPrint('[throw-time attribution] $details');
    previousOnError?.call(details);
  };
  return () => FlutterError.onError = previousOnError;
}

/// Installs [installChainedThrowTimeHandler] for the remainder of the
/// current test, restoring the previous handler via [addTearDown] — which
/// runs whether the test body passes or fails, and (having been registered
/// after `testWidgets`'s own `addTearDown(binding.postTest)`) runs before it,
/// so `postTest()` still restores the handler that predates this test.
///
/// Call this as the first statement of every integration `testWidgets` body
/// — see `test/lints/throw_time_error_logging_reachable_test.dart`, which
/// fails the build if any body omits it.
void installThrowTimeErrorLogging() {
  addTearDown(installChainedThrowTimeHandler());
}
