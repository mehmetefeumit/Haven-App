import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/subscription_service.dart';

/// The decision computed from an accepted-circle-set change: whether the
/// live-sync engine must re-subscribe, plus the new subscription [groups] and
/// their canonical [signature] to (re)start it with.
///
/// A pure value produced by [LiveSyncResubscriber.decide] — the extracted
/// "compute new groups + decide-to-restart" seam. Unit-tested directly so the
/// re-subscribe decision is provable WITHOUT the compile-time `liveSyncEnabled`
/// flag (which only gates the widget wiring that CALLS this).
@immutable
class LiveSyncResubscribeDecision {
  /// Creates a decision.
  const LiveSyncResubscribeDecision({
    required this.changed,
    required this.groups,
    required this.signature,
  });

  /// Whether the effective subscription set differs from the running one.
  final bool changed;

  /// The accepted circles mapped to engine subscription specs.
  final List<FfiGroupSpec> groups;

  /// Canonical, order-independent signature of [groups] — an in-memory
  /// comparison key only. It embeds the pseudonymous `nostr_group_id`s, so
  /// hold it in memory and NEVER log it (Security Rules 4/6/8).
  final String signature;
}

/// Re-subscribes the live-sync engine when the user's accepted-circle set
/// changes mid-session (create a circle, accept an invitation, leave / be
/// removed).
///
/// The M3 StreamSink engine subscribes only to the circles present at its
/// `start()` (`docs/M3_STREAMSINK_ENGINE.md` "Deferred: dynamic subscription"
/// deferred a dynamic `subscribe_circle` FFI). Without this, a circle created or joined after the
/// session started would silently receive NO live locations until a full app
/// relaunch. This implements the documented interim: on a real change to the
/// subscribed `(nostr_group_id, relays)` set, STOP then START the engine with
/// the new group set ("stop+new_local+start").
///
/// FFI-free and widget-free so the full stop/start + debounce + lifecycle
/// behaviour is unit-testable with a mock [SubscriptionService]. Owned by
/// `MapShell`, which feeds it `circlesProvider` snapshots and disposes it.
class LiveSyncResubscriber {
  /// Creates a re-subscriber over the already-started [engine].
  ///
  /// [initialSignature] is the [signatureForGroups] of the group set [engine]
  /// was started with; a later snapshot with the same signature is a no-op.
  /// [inboxRelays] re-reads the user's inbox relays for each restart.
  /// [debounce] coalesces a burst of changes into a single restart.
  LiveSyncResubscriber({
    required SubscriptionService engine,
    required Future<List<String>> Function() inboxRelays,
    required String initialSignature,
    Duration debounce = const Duration(milliseconds: 500),
  }) : _engine = engine,
       _inboxRelays = inboxRelays,
       _signature = initialSignature,
       _debounce = debounce;

  final SubscriptionService _engine;
  final Future<List<String>> Function() _inboxRelays;
  final Duration _debounce;

  /// Signature of the group set the engine is currently running with. Advanced
  /// only after a restart's `start()` resolves.
  String _signature;

  Timer? _timer;

  /// Serializes restarts so two rapid changes can never interleave a
  /// stop/start pair (mirrors `NostrSubscriptionService`'s `_processing`).
  Future<void> _chain = Future<void>.value();

  bool _disposed = false;

  /// Filters [circles] to the accepted subset and maps each to the engine's
  /// [FfiGroupSpec] subscription spec. Pure — no `ref`, no FFI, no flag; the
  /// same derivation `MapShell._startLiveSync` uses for the initial start.
  static List<FfiGroupSpec> groupsForCircles(List<Circle> circles) => [
    for (final c in circles)
      if (c.membershipStatus == MembershipStatus.accepted)
        FfiGroupSpec(
          nostrGroupId: Uint8List.fromList(c.nostrGroupId),
          relays: c.relays,
        ),
  ];

  /// Canonical, order-independent signature of a group set: per group, the hex
  /// `nostr_group_id` plus its sorted relay set; the group entries sorted and
  /// joined. Two lists with the same `(nostr_group_id, relays)` members — in
  /// any order, and regardless of a roster/member change to an existing circle
  /// — produce the SAME signature, so only an added/removed circle or a relay
  /// rotation counts as a change.
  ///
  /// The result embeds `nostr_group_id`s: an in-memory comparison key only —
  /// NEVER log it.
  static String signatureForGroups(List<FfiGroupSpec> groups) {
    final entries = groups.map(_entryForGroup).toList()..sort();
    return entries.join(';');
  }

  static String _entryForGroup(FfiGroupSpec g) {
    final relays = (List<String>.of(g.relays)..sort()).join(',');
    return '${_hex(g.nostrGroupId)}|$relays';
  }

  /// Computes the [LiveSyncResubscribeDecision] for a fresh circle snapshot
  /// against [runningSignature] — the extracted "compute new groups +
  /// decide-to-restart" logic the debounced wiring drives and tests exercise
  /// directly, independent of the compile-time flag.
  static LiveSyncResubscribeDecision decide({
    required List<Circle> circles,
    required String? runningSignature,
  }) {
    final groups = groupsForCircles(circles);
    final signature = signatureForGroups(groups);
    return LiveSyncResubscribeDecision(
      changed: signature != runningSignature,
      groups: groups,
      signature: signature,
    );
  }

  static String _hex(Uint8List bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  /// Feeds a fresh accepted-circle snapshot. On a real change to the subscribed
  /// set, (re)arms the debounce; an unchanged snapshot cancels any pending
  /// restart (the net set is back to what is already running). No-op once
  /// [dispose]d.
  void onCirclesChanged(List<Circle> circles) {
    if (_disposed) return;
    final decision = decide(circles: circles, runningSignature: _signature);
    // Reset the debounce on every relevant event so a burst coalesces into one
    // restart, and an unchanged snapshot drops any pending restart.
    _timer?.cancel();
    if (!decision.changed) {
      _timer = null;
      return;
    }
    _timer = Timer(_debounce, () {
      _timer = null;
      // Serialize behind any in-flight restart so stop/start pairs never
      // interleave. `_restart` re-checks the target against the running
      // signature, so a chained restart whose target was already applied is a
      // cheap no-op.
      _chain = _chain.then(
        (_) => _restart(decision.groups, decision.signature),
      );
    });
  }

  Future<void> _restart(List<FfiGroupSpec> groups, String signature) async {
    // Already at this target (an earlier chained restart applied it), or torn
    // down — skip.
    if (_disposed || signature == _signature) return;
    try {
      await _engine.stop();
      // Disposed (logout / unmount) during the stop round-trip — do NOT start a
      // session after teardown (no start-after-dispose).
      if (_disposed) return;
      final inbox = await _inboxRelays();
      if (_disposed) return;
      await _engine.start(groups: groups, inboxRelays: inbox);
      // Disposed during start()'s round-trips — tear the fresh session down so
      // it is not orphaned past teardown.
      if (_disposed) {
        unawaited(_engine.stop());
        return;
      }
      _signature = signature;
    } on Object catch (e) {
      // Generic only — never the raw error (could carry a group id). Best
      // effort: the next change (or app resume's resubscribe) retries.
      debugPrint(
        '[LiveSyncResubscriber] re-subscribe failed: ${e.runtimeType}',
      );
    }
  }

  /// Cancels any pending / in-flight restart and stops accepting changes.
  /// Idempotent. The owning engine is stopped separately by the caller.
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }
}
