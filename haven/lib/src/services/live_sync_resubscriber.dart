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

/// The incremental engine ops [LiveSyncResubscriber.computeDelta] derives from
/// diffing a running group set against a fresh one, plus the [nextRunning] map
/// to adopt once every op below applies successfully.
@immutable
class Delta {
  /// Creates a delta.
  const Delta({
    required this.added,
    required this.removed,
    required this.relayChanged,
    required this.nextRunning,
  });

  /// Circles in the next set but not the running one — need `subscribeCircle`.
  final List<FfiGroupSpec> added;

  /// `nostr_group_id`s in the running set but not the next one — need
  /// `unsubscribeCircle`.
  final List<Uint8List> removed;

  /// Circles present in both sets under the same `nostr_group_id` but a
  /// rotated relay set — need `unsubscribeCircle` then `subscribeCircle`.
  final List<FfiGroupSpec> relayChanged;

  /// The full next running set, keyed by hex `nostr_group_id`. Embeds the
  /// pseudonymous `nostr_group_id`s — an in-memory value only, NEVER log it
  /// (Security Rules 4/6/8).
  final Map<String, FfiGroupSpec> nextRunning;

  /// Whether the running and next sets are identical — nothing to apply.
  bool get isEmpty => added.isEmpty && removed.isEmpty && relayChanged.isEmpty;
}

/// Re-subscribes the live-sync engine when the user's accepted-circle set
/// changes mid-session (create a circle, accept an invitation, leave / be
/// removed).
///
/// Without this, a circle created or joined after the session started would
/// silently receive NO live locations until a full app relaunch. On a real
/// change to the subscribed `(nostr_group_id, relays)` set, this issues
/// INCREMENTAL delta ops on the running session — `subscribeCircle` for an
/// added circle, `unsubscribeCircle` for a removed one, and an
/// unsubscribe-then-subscribe pair for a relay rotation — leaving every
/// unrelated circle's subscription untouched (the `subscribe_circle` /
/// `unsubscribe_circle` FFI that the M3 StreamSink engine's "Deferred: dynamic
/// subscription" note deferred; see `docs/WN_RELAY_EPOCH_SYNC_MIGRATION.md` Appendix M3). If a
/// delta op fails (e.g. the session dropped), it falls back to the old
/// whole-set STOP then START ("stop+new_local+start") so an engine hiccup can
/// never leave the app worse off than before this change.
///
/// FFI-free and widget-free so the delta / full-restart + debounce +
/// lifecycle behaviour is unit-testable with a mock [SubscriptionService].
/// Owned by `MapShell`, which feeds it `circlesProvider` snapshots and
/// disposes it.
class LiveSyncResubscriber {
  /// Creates a re-subscriber over the already-started [engine].
  ///
  /// [initialGroups] is the group set [engine] was started with — the seed
  /// for the incremental `_running` map [computeDelta] diffs a fresh snapshot
  /// against. [initialSignature] is its [signatureForGroups]; a later
  /// snapshot with the same signature is a no-op.
  /// [inboxRelays] re-reads the user's inbox relays for the full-restart
  /// fallback. [debounce] coalesces a burst of changes into a single apply.
  LiveSyncResubscriber({
    required SubscriptionService engine,
    required Future<List<String>> Function() inboxRelays,
    required String initialSignature,
    required List<FfiGroupSpec> initialGroups,
    Duration debounce = const Duration(milliseconds: 500),
  }) : _engine = engine,
       _inboxRelays = inboxRelays,
       _signature = initialSignature,
       _running = _toMap(initialGroups),
       _debounce = debounce;

  final SubscriptionService _engine;
  final Future<List<String>> Function() _inboxRelays;
  final Duration _debounce;

  /// Signature of the group set the engine is currently running with. Advanced
  /// only after a delta or full restart applies successfully, in lockstep with
  /// [_running].
  String _signature;

  /// The group set the engine is currently running with, keyed by hex
  /// `nostr_group_id` — the base [computeDelta] diffs a fresh snapshot
  /// against. Advanced only after a delta or full restart applies
  /// successfully, in lockstep with [_signature]. Embeds the pseudonymous
  /// `nostr_group_id`s — NEVER log it (Security Rules 4/6/8).
  Map<String, FfiGroupSpec> _running;

  Timer? _timer;

  /// Serializes applies so two rapid changes can never interleave their
  /// engine calls (mirrors `NostrSubscriptionService`'s `_processing`).
  Future<void> _chain = Future<void>.value();

  bool _disposed = false;

  static Map<String, FfiGroupSpec> _toMap(List<FfiGroupSpec> groups) => {
    for (final g in groups) _hex(g.nostrGroupId): g,
  };

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

  static String _entryForGroup(FfiGroupSpec g) =>
      '${_hex(g.nostrGroupId)}|${_relaysKey(g)}';

  /// Canonical, order-independent key for one group's relay set — used both by
  /// [signatureForGroups] and [computeDelta]'s relay-rotation comparison.
  static String _relaysKey(FfiGroupSpec g) =>
      (List<String>.of(g.relays)..sort()).join(',');

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

  /// Diffs [running] (keyed by hex `nostr_group_id`) against [next] (a fresh
  /// accepted-circle snapshot) into the incremental ops the engine needs:
  /// circles to [Delta.added], `nostr_group_id`s to [Delta.removed], and
  /// circles whose relay set rotated to [Delta.relayChanged] (dropped then
  /// re-subscribed under the new relays). Pure — no FFI, no engine — so every
  /// combination is unit-testable directly.
  static Delta computeDelta(
    Map<String, FfiGroupSpec> running,
    List<FfiGroupSpec> next,
  ) {
    final nextByHex = {for (final g in next) _hex(g.nostrGroupId): g};
    final added = <FfiGroupSpec>[];
    final relayChanged = <FfiGroupSpec>[];
    for (final entry in nextByHex.entries) {
      final prior = running[entry.key];
      if (prior == null) {
        added.add(entry.value);
      } else if (_relaysKey(prior) != _relaysKey(entry.value)) {
        relayChanged.add(entry.value);
      }
    }
    final removed = <Uint8List>[
      for (final entry in running.entries)
        if (!nextByHex.containsKey(entry.key)) entry.value.nostrGroupId,
    ];
    return Delta(
      added: added,
      removed: removed,
      relayChanged: relayChanged,
      nextRunning: nextByHex,
    );
  }

  /// Feeds a fresh accepted-circle snapshot. On a real change to the subscribed
  /// set, (re)arms the debounce; an unchanged snapshot cancels any pending
  /// apply (the net set is back to what is already running). No-op once
  /// [dispose]d.
  void onCirclesChanged(List<Circle> circles) {
    if (_disposed) return;
    final decision = decide(circles: circles, runningSignature: _signature);
    // Diagnostic (M11 e2e triage): reveal what the resubscribe path SEES and
    // DECIDES, so we can tell whether a newly-created circle reached the engine
    // subscribe set. `changed=false` here means the engine will NOT re-anchor.
    if (kDebugMode) {
      final accepted =
          circles.where((c) => c.membershipStatus.name == 'accepted').length;
      debugPrint(
        '[LiveSyncResubscriber] onCirclesChanged: ${circles.length} circles '
        '($accepted accepted) → ${decision.groups.length} group(s), '
        'changed=${decision.changed}',
      );
    }
    // Reset the debounce on every relevant event so a burst coalesces into one
    // apply, and an unchanged snapshot drops any pending apply.
    _timer?.cancel();
    if (!decision.changed) {
      _timer = null;
      return;
    }
    _timer = Timer(_debounce, () {
      _timer = null;
      final delta = computeDelta(_running, decision.groups);
      // Diagnostic (M11 e2e triage): the debounce fired and this is what the
      // engine is about to be re-anchored to. If this never logs after a
      // mid-session circle-create, the debounce/decide never scheduled it.
      if (kDebugMode) {
        debugPrint(
          '[LiveSyncResubscriber] delta → +${delta.added.length} added, '
          '-${delta.removed.length} removed, ~${delta.relayChanged.length} '
          'relay-rotated',
        );
      }
      // Serialize behind any in-flight apply so engine calls never interleave.
      _chain = _chain.then((_) => _applyDelta(delta));
    });
  }

  /// Applies one incremental [delta] to the running session: unsubscribe every
  /// removed circle, drop-then-resubscribe every relay-rotated circle, then
  /// subscribe every added circle. Re-checks [_disposed] between every await so
  /// a mid-flight `dispose()` (logout / unmount) never issues an engine call
  /// after teardown. On success, adopts [Delta.nextRunning] as the new running
  /// set. On ANY failure — a delta op is best-effort against a possibly-gone
  /// session — falls back to the whole-set stop+start ([_fullRestart]) so this
  /// can never leave the app worse off than the old stop+start behaviour.
  ///
  /// If the session is ALREADY not running (stopped between scenarios /
  /// backgrounded / torn down elsewhere), a delta op is guaranteed to fail
  /// with "no active session" — [SubscriptionService.isRunning] reads the
  /// SAME underlying engine state a delta op would hit, so this check never
  /// disagrees with the attempt it replaces. Skip straight to
  /// [_fullRestart] instead of a doomed subscribeCircle/unsubscribeCircle
  /// round-trip; the residual TOCTOU race (stopped between this check and
  /// the loop below) still falls back via the existing `on Object catch`.
  Future<void> _applyDelta(Delta delta) async {
    if (_disposed || delta.isEmpty) return;
    if (!_engine.isRunning) {
      if (kDebugMode) {
        debugPrint(
          '[LiveSyncResubscriber] engine not running — full restart instead '
          'of delta',
        );
      }
      await _fullRestart(delta.nextRunning.values.toList());
      return;
    }
    try {
      for (final id in delta.removed) {
        if (_disposed) return;
        await _engine.unsubscribeCircle(id);
      }
      for (final g in delta.relayChanged) {
        if (_disposed) return;
        await _engine.unsubscribeCircle(g.nostrGroupId);
        if (_disposed) return;
        await _engine.subscribeCircle(g);
      }
      for (final g in delta.added) {
        if (_disposed) return;
        await _engine.subscribeCircle(g);
      }
      if (_disposed) return;
      _adoptRunning(delta.nextRunning);
    } on Object catch (e) {
      // Generic only — never the raw error (could carry a group id).
      debugPrint(
        '[LiveSyncResubscriber] delta failed → full restart: ${e.runtimeType}',
      );
      await _fullRestart(delta.nextRunning.values.toList());
    }
  }

  /// The old whole-set STOP then START, kept as the fallback for a delta-op
  /// failure so a transient engine hiccup can never leave a circle worse off
  /// than the pre-delta behaviour. Re-checks [_disposed] between every await
  /// (no start-after-dispose; a session started after [dispose] is torn down
  /// rather than orphaned).
  Future<void> _fullRestart(List<FfiGroupSpec> groups) async {
    if (_disposed) return;
    if (kDebugMode) {
      debugPrint(
        '[LiveSyncResubscriber] full restart → ${groups.length} group(s)',
      );
    }
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
      _adoptRunning(_toMap(groups));
    } on Object catch (e) {
      // Generic only — never the raw error (could carry a group id). Best
      // effort: the next change (or app resume's resubscribe) retries.
      debugPrint(
        '[LiveSyncResubscriber] full restart failed: ${e.runtimeType}',
      );
    }
  }

  /// Adopts [running] as the new running set, advancing [_signature] in
  /// lockstep so the unchanged-snapshot no-op fast path in [onCirclesChanged]
  /// stays correct.
  void _adoptRunning(Map<String, FfiGroupSpec> running) {
    _running = running;
    _signature = signatureForGroups(running.values.toList());
  }

  /// Cancels any pending / in-flight restart and stops accepting changes.
  /// Idempotent. The owning engine is stopped separately by the caller.
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }
}
