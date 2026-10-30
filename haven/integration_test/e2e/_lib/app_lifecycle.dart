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
