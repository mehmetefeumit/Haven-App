/// The M7 catch-up service: a thin orchestrator that runs a fork-safe,
/// receive-only catch-up sweep over every visible circle.
///
/// Used on foreground resume and by the background wake paths. Best-effort — it
/// never throws into its caller. The heavy lifting (relay fetch, marker-gated
/// decrypt, cursor advance) happens in Rust; this only resolves the FFI handles
/// + own pubkey and forwards to [RelayService.runCatchup].
library;

import 'package:flutter/foundation.dart';

import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/background_location_manager.dart';
import 'package:haven/src/services/relay_service.dart';

/// Runs receive-only catch-up sweeps.
class CatchupService {
  /// Creates a catch-up service over its injected dependencies (so it is
  /// unit-testable without the FFI bridge).
  CatchupService({
    required Future<CircleManagerFfi> Function() circleManagerFactory,
    required Future<String?> Function() ownPubkeyHex,
    required RelayService relayService,
    Future<bool> Function()? isBackgroundSharingEnabled,
  }) : _circleManagerFactory = circleManagerFactory,
       _ownPubkeyHex = ownPubkeyHex,
       _relayService = relayService,
       _isBackgroundSharingEnabled =
           isBackgroundSharingEnabled ??
           BackgroundLocationManager.isBackgroundSharingEnabled;

  final Future<CircleManagerFfi> Function() _circleManagerFactory;
  final Future<String?> Function() _ownPubkeyHex;
  final RelayService _relayService;

  /// Returns whether the user has enabled background sharing.
  ///
  /// Overridable in tests via the constructor parameter so tests can run
  /// without SharedPreferences plugin setup.
  final Future<bool> Function() _isBackgroundSharingEnabled;

  /// Runs a bounded, receive-only catch-up sweep. Returns
  /// [CatchupResult.empty] on any failure (no identity, uninitialized manager,
  /// FFI error) — a background/resume sweep must never throw.
  ///
  /// ## `isBackgroundWake` parameter (C3 chokepoint — read carefully)
  ///
  /// Pass `isBackgroundWake: true` **only** from background wake paths (e.g.
  /// the iOS ~90 s background receive timer, future WorkManager/SLC/BGTask
  /// handlers). When `true`, this method checks
  /// [BackgroundLocationManager.isBackgroundSharingEnabled] and hard-returns
  /// [CatchupResult.empty] — without any FFI or relay call — if the user has
  /// disabled background sharing.
  ///
  /// Pass the default `isBackgroundWake: false` (or omit) from **foreground**
  /// call sites (e.g. [JoinWatcherNotifier.requestCatchUp], on-resume sweeps).
  /// Foreground receive is intentionally NOT gated on the background-sharing
  /// toggle: a user who turns off *background* sharing must still receive
  /// peer updates while the app is open and visible. The toggle controls what
  /// happens when the app is backgrounded, not what the foreground can do.
  ///
  /// This asymmetry is the correct privacy model: the "background sharing"
  /// feature is about what the OS can do on the user's behalf when the app is
  /// not in use, not about silencing the app while the user is actively using
  /// it.
  Future<CatchupResult> runCatchup({
    int maxDurationSecs = 20,
    bool isBackgroundWake = false,
  }) async {
    // C3 chokepoint: hard-return before any FFI/relay call if this is a
    // background wake AND the user has disabled background sharing.
    // This is a third backstop (after scheduler cancellation in
    // disableBackgroundScheduling() and the OS re-check at wake entry), so
    // that even a leaked/OS-queued wake cannot reach the relay.
    //
    // Foreground callers (isBackgroundWake == false) intentionally bypass this
    // gate — see method doc above.
    if (isBackgroundWake) {
      try {
        final enabled = await _isBackgroundSharingEnabled();
        if (!enabled) {
          debugPrint(
            '[Catchup] background wake suppressed: background sharing disabled',
          );
          return const CatchupResult.empty();
        }
      } on Object catch (e) {
        // Fail-safe: if we cannot read the pref, treat as disabled so a
        // corrupt SharedPreferences cannot accidentally enable background
        // activity after opt-out.
        debugPrint(
          '[Catchup] background-sharing check failed, treating as disabled: '
          '${e.runtimeType}',
        );
        return const CatchupResult.empty();
      }
    }

    try {
      final pubkey = await _ownPubkeyHex();
      if (pubkey == null || pubkey.isEmpty) {
        return const CatchupResult.empty();
      }
      final circle = await _circleManagerFactory();
      return await _relayService.runCatchup(
        circle: circle,
        ownPubkeyHex: pubkey,
        maxDurationSecs: maxDurationSecs,
      );
    } on Object catch (e) {
      debugPrint('[Catchup] service sweep failed: ${e.runtimeType}');
      return const CatchupResult.empty();
    }
  }
}
