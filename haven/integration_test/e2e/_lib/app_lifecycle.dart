/// The lifecycle the device lanes launch in.
///
/// Under any test binding the lifecycle is reset to UNSET after every test
/// (`flutter_test`'s `postTest` ends in `ServicesBinding.resetInternalState`,
/// which nulls `SchedulerBinding.lifecycleState`), and the test platform
/// dispatcher's `initialLifecycleState` is empty, so nothing reads it back
/// from the platform. Only the first test of a process can read `resumed`,
/// and only if the engine's own lifecycle message has arrived by then.
///
/// Haven's live-sync session is the foreground's only on a CLAIM, and the
/// claim is the strict read (`appIsResumed`): a session started under an
/// unset lifecycle is never claimed for. It still receives — through the
/// legacy ladder — so every test after the first would pass while exercising
/// a different plane from the one a foregrounded app runs, and no oracle
/// would notice.
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/services/mls_session_handover.dart'
    show appIsResumed;

/// Registers a `setUp` that puts the lifecycle at `resumed` before every test
/// of the file that calls it — from the top of its `main`, so it covers a
/// test's own first pump and every test in every group.
///
/// True to the device on the lanes' own premise: the test activity is in
/// front. A test that drives `paused` itself still does; this runs before its
/// body. Dispatched with no app mounted, so no observer runs a resume.
void resumeAppBeforeEachTest() {
  setUp(() {
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
  });
}

/// Fails unless the lifecycle reads `resumed`.
///
/// Called where a test pumps the app, so a lane whose session would go
/// unclaimed fails by name instead of passing on another plane.
void expectAppResumed() {
  expect(
    appIsResumed(),
    isTrue,
    reason: 'the app is about to be pumped under a lifecycle that does not '
        'read `resumed`: its live-sync session would never be claimed for, '
        'and everything this test asserts would run on the legacy receive '
        'path. The target must call resumeAppBeforeEachTest() from the top '
        'of main(), and nothing may have taken the test activity out of the '
        'foreground',
  );
}

/// How long [awaitPlatformResumed] waits for the platform.
const Duration kPlatformResumedWithin = Duration(seconds: 60);

/// On iOS, waits until the platform itself has the app in front: the view
/// controller has sent `resumed`, and a scene's window has given the implicit
/// view a size. Returns at once elsewhere.
///
/// iOS runs the engine before any scene connects, so a target's first test can
/// start while the scene's own `inactive` and `resumed` are still on their
/// way, and that `inactive`, landing mid-test, takes away the `resumed`
/// [resumeAppBeforeEachTest] set. Call it from `setUpAll`, which runs before
/// that `setUp`: what the binding reads there is the platform's. [isIOS] is
/// a host-test seam.
Future<void> awaitPlatformResumed({bool? isIOS}) async {
  if (!(isIOS ?? Platform.isIOS)) return;
  final binding = WidgetsBinding.instance;
  bool resumed() => binding.lifecycleState == AppLifecycleState.resumed;
  bool sized() =>
      !(binding.platformDispatcher.implicitView?.physicalSize.isEmpty ?? true);
  final observer = _PlatformInFront(() => resumed() && sized());
  binding.addObserver(observer);
  try {
    if (!observer.ready()) {
      await observer.reached.future.timeout(
        kPlatformResumedWithin,
        onTimeout: () => fail(
          'the platform did not put the app in front within '
          '${kPlatformResumedWithin.inSeconds} s (resumed: ${resumed()}, '
          'view sized: ${sized()}): no scene connected, or its view '
          'controller never sent `resumed`',
        ),
      );
    }
  } finally {
    binding.removeObserver(observer);
  }
}

class _PlatformInFront with WidgetsBindingObserver {
  _PlatformInFront(this.ready);

  final bool Function() ready;
  final Completer<void> reached = Completer<void>();

  // Read once the message has been walked whole: one leaving the `detached`
  // seed is dispatched a synthesized `resumed` on its way to `inactive`.
  void _check() => scheduleMicrotask(() {
    if (!reached.isCompleted && ready()) reached.complete();
  });

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _check();

  @override
  void didChangeMetrics() => _check();
}
