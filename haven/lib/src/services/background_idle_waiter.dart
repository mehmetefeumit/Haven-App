/// Polls `SharedPreferences` until the background isolate marks itself idle.
///
/// Extracted from `_MapShellState._waitForBackgroundIdle` in `map_shell.dart`
/// so that the polling/timeout logic can be unit-tested independently of the
/// widget tree (Phase 5 test target).
library;

import 'package:flutter/foundation.dart';
import 'package:haven/src/constants/location.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Polls `SharedPreferences` until [kBackgroundIdleKey] is `true`.
///
/// Inject the `clock` and `prefsGetter` parameters in tests to control time
/// and prefs state without a real platform channel.
class BackgroundIdleWaiter {
  /// Creates a [BackgroundIdleWaiter].
  const BackgroundIdleWaiter();

  /// Waits until the background isolate has become idle or [maxWait] elapses.
  ///
  /// Returns `true` when [kBackgroundIdleKey] is observed as `true` (or
  /// absent, which means the background never started — treated as idle by
  /// convention, matching cold-start behaviour). Returns `false` on timeout.
  ///
  /// The [clock] and [prefsGetter] parameters exist as test seams; production
  /// callers may omit them and receive the real-time defaults.
  Future<bool> waitUntilIdle({
    Duration maxWait = const Duration(seconds: 5),
    Duration pollInterval = const Duration(milliseconds: 250),
    DateTime Function()? clock,
    Future<SharedPreferences> Function()? prefsGetter,
  }) async {
    final now = clock ?? DateTime.now;
    final getPrefs = prefsGetter ?? SharedPreferences.getInstance;

    final prefs = await getPrefs();
    final deadline = now().add(maxWait);

    while (now().isBefore(deadline)) {
      await prefs.reload();
      if (prefs.getBool(kBackgroundIdleKey) ?? true) return true;
      await Future<void>.delayed(pollInterval);
    }

    // Timed out — caller receives false; the overlap guard provides
    // defence-in-depth.
    debugPrint(
      '[BackgroundIdleWaiter] Background idle wait timed out after '
      '${maxWait.inSeconds} s',
    );
    return false;
  }
}
