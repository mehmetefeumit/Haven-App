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
import 'package:haven/src/services/relay_service.dart';

/// Runs receive-only catch-up sweeps.
class CatchupService {
  /// Creates a catch-up service over its injected dependencies (so it is
  /// unit-testable without the FFI bridge).
  CatchupService({
    required Future<CircleManagerFfi> Function() circleManagerFactory,
    required Future<String?> Function() ownPubkeyHex,
    required RelayService relayService,
  }) : _circleManagerFactory = circleManagerFactory,
       _ownPubkeyHex = ownPubkeyHex,
       _relayService = relayService;

  final Future<CircleManagerFfi> Function() _circleManagerFactory;
  final Future<String?> Function() _ownPubkeyHex;
  final RelayService _relayService;

  /// Runs a bounded, receive-only catch-up sweep. Returns
  /// [CatchupResult.empty] on any failure (no identity, uninitialized manager,
  /// FFI error) — a background/resume sweep must never throw.
  Future<CatchupResult> runCatchup({int maxDurationSecs = 20}) async {
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
