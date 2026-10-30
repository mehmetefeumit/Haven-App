import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/subscription_service.dart';
import 'package:haven/src/utils/log_alias.dart';

/// Mirror of `RELAY_LIFECYCLE_OP_TIMEOUT_SECS` in
/// `haven-core/src/relay/live_sync/config.rs` — the engine's own bound on ONE
/// relay control-plane op. Pinned across the language boundary by
/// `scripts/ci/check_live_sync_restart_budget.sh`.
const int _kRelayLifecycleOpTimeoutSecs = 10;

/// Mirror of `SUBSCRIBE_CONNECT_WAIT_SECS` in the same Rust module — the
/// early-returning handshake grace a `start` waits before its first REQ.
/// Pinned by the same guard.
const int _kSubscribeConnectWaitSecs = 5;

/// How many [_kRelayLifecycleOpTimeoutSecs]-bounded ops one full restart can
/// spend.
///
/// `LiveSyncCore::stop_inner` bounds three (`unsubscribe_all`,
/// `client.shutdown`, the router clear) and `NostrSubscriptionService.stop`
/// retries a failed `stopSession()` once against the core that Rust reinstalls
/// into `SESSION` — so the stop half is six. The start half adds no
/// lifecycle-timeout op of its own, only [_kSubscribeConnectWaitSecs].
const int _kLifecycleOpsPerRestart = 6;

/// Upper bound on one [LiveSyncResubscriber.ensureRunning] call.
///
/// DERIVED, not chosen: it is exactly what the Rust engine allows ITSELF to
/// spend on a stop + start, so Dart gives up only once the engine provably
/// has. Every await inside a full restart is an FFI round-trip with no
/// Dart-side bound, and this is driven from `MapShell`'s periodic backstop
/// whose next tick is armed from THIS future's completion — so a hang here
/// used to kill the only recovery path there is, permanently, for the rest of
/// the process.
///
/// Comfortably under the backstop's own 90 s jitter floor, so a bounded-out
/// restart always re-arms before the next tick rather than stacking.
///
/// Two waits in front of and behind the engine's stop + start are NOT inside
/// it. The engine factory opens the MLS database, which in a foregrounded
/// Android app can wait up to twenty seconds for the foreground service to
/// release the session (`handoverTimeout`); and the start's own foreground
/// claim waits for the engine's lifecycle lock (for no relay). A restart
/// that runs past the budget for either is answered
/// [LiveSyncHealOutcome.failed] while its leg runs on: the leg still ends in
/// a session that is wanted or in none, and the next heal finds which.
const Duration kLiveSyncRestartBudget = Duration(
  seconds:
      _kLifecycleOpsPerRestart * _kRelayLifecycleOpTimeoutSecs +
      _kSubscribeConnectWaitSecs,
);

/// What a [LiveSyncResubscriber.ensureRunning] call found or did.
///
/// Three answers, because "not running" has two causes a caller must not
/// treat alike: one is a fault worth backing off from, the other is the app
/// having asked for nothing.
enum LiveSyncHealOutcome {
  /// The engine is running.
  running,

  /// Nothing was attempted, or what was attempted was called off: no session
  /// is wanted, a stop somebody asked for ended the start, or this
  /// re-subscriber is disposed. Not a failure.
  stoodDown,

  /// A restart was attempted and the engine is not running — a start that
  /// failed, one the engine's own death ended while a session is still
  /// wanted, or one that did not answer within [kLiveSyncRestartBudget].
  failed,
}

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
    required this.byCircle,
    required this.signature,
  });

  /// Whether the effective subscription set differs from the running one.
  final bool changed;

  /// The accepted circles' engine subscription specs, keyed by hex
  /// `mls_group_id` ([LiveSyncResubscriber.specsByCircle]).
  final Map<String, FfiGroupSpec> byCircle;

  /// The accepted circles mapped to engine subscription specs.
  List<FfiGroupSpec> get groups => byCircle.values.toList();

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
    required this.nextRunning,
  });

  /// Circles in the next set but not the running one — need `subscribeCircle`.
  final List<FfiGroupSpec> added;

  /// The `nostr_group_id`s of circles in the running set but not the next
  /// one — need `unsubscribeCircle`.
  final List<Uint8List> removed;

  /// The full next running set, keyed by hex `mls_group_id`. Embeds the
  /// pseudonymous `nostr_group_id`s — an in-memory value only, NEVER log it
  /// (Security Rules 4/6/8).
  final Map<String, FfiGroupSpec> nextRunning;

  /// Whether no circle joins or leaves the set — no engine op to make.
  bool get isEmpty => added.isEmpty && removed.isEmpty;
}

/// Re-subscribes the live-sync engine when the user's accepted-circle set
/// changes mid-session (create a circle, accept an invitation, leave / be
/// removed).
///
/// Without this, a circle created or joined after the session started would
/// silently receive NO live locations until a full app relaunch. When a
/// circle joins or leaves the accepted set, this issues INCREMENTAL delta ops
/// on the running session — `subscribeCircle` for an added circle,
/// `unsubscribeCircle` for a removed one — leaving every unrelated circle's
/// subscription untouched. A circle is one circle by its `mls_group_id`: a
/// new relay set or routing id for it makes no engine op, because the session
/// follows a circle's routing by itself and keeps a rotated circle's prior id
/// listed for a day (`LiveSyncCore::follow_routing`); the new spec is only
/// what a later full start is made from (the `subscribe_circle` /
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
  /// Creates a re-subscriber over [engine].
  ///
  /// [initialCircles]' accepted set is the group set [engine] is running —
  /// or, when this is built before any session exists, the set it is WANTED
  /// to run, which [ensureRunning] then performs the first start from. Either
  /// way it is the seed for the incremental `_running` map [computeDelta]
  /// diffs a fresh snapshot against; a later snapshot with the same
  /// [signatureForGroups] is a no-op.
  /// [inboxRelays] re-reads the user's inbox relays for the full-restart
  /// fallback. [debounce] coalesces a burst of changes into a single apply.
  ///
  /// [sessionWanted] says whether a session may be up at the instant it is
  /// asked — the owner's answer for "the app has not gone away". Every start
  /// this class makes reads it immediately before and immediately after: see
  /// [_fullRestart]. Required, so that whoever builds one has said.
  LiveSyncResubscriber({
    required SubscriptionService engine,
    required Future<List<String>> Function() inboxRelays,
    required List<Circle> initialCircles,
    required bool Function() sessionWanted,
    Duration debounce = const Duration(milliseconds: 500),
  }) : _engine = engine,
       _inboxRelays = inboxRelays,
       _sessionWanted = sessionWanted,
       _running = specsByCircle(initialCircles),
       _debounce = debounce {
    _signature = signatureForGroups(_running.values.toList());
  }

  final SubscriptionService _engine;
  final Future<List<String>> Function() _inboxRelays;
  final bool Function() _sessionWanted;
  final Duration _debounce;

  /// Signature of the group set the engine is currently running with. Advanced
  /// only after a delta or full restart applies successfully, in lockstep with
  /// [_running].
  late String _signature;

  /// The group set the engine is currently running with, keyed by hex
  /// `mls_group_id` — the base [computeDelta] diffs a fresh snapshot
  /// against. Advanced only after a delta or full restart applies
  /// successfully, in lockstep with [_signature]. Embeds the pseudonymous
  /// `nostr_group_id`s — NEVER log it (Security Rules 4/6/8).
  Map<String, FfiGroupSpec> _running;

  /// Whether a session may be started, or left up, right now.
  bool get _mayRun => !_disposed && _sessionWanted();

  Timer? _timer;

  /// Serializes applies so two rapid changes can never interleave their
  /// engine calls (mirrors `NostrSubscriptionService`'s `_processing`).
  Future<void> _chain = Future<void>.value();

  bool _disposed = false;

  /// Filters [circles] to the accepted subset, less the disbanded circles
  /// nothing is received for, and maps each to the engine's [FfiGroupSpec]
  /// subscription spec, keyed by hex `mls_group_id` — the key a routing
  /// rotation leaves alone. Pure — no `ref`, no FFI, no flag.
  static Map<String, FfiGroupSpec> specsByCircle(List<Circle> circles) => {
    for (final c in circles)
      if (c.membershipStatus == MembershipStatus.accepted && !c.isDisbanded)
        _hex(c.mlsGroupId): FfiGroupSpec(
          nostrGroupId: Uint8List.fromList(c.nostrGroupId),
          relays: c.relays,
        ),
  };

  /// [specsByCircle]'s specs: the same derivation `MapShell` seeds this class
  /// with, which is what the initial start then runs from.
  static List<FfiGroupSpec> groupsForCircles(List<Circle> circles) =>
      specsByCircle(circles).values.toList();

  /// Canonical, order-independent signature of a group set: per group, the hex
  /// `nostr_group_id` plus its sorted relay set; the group entries sorted and
  /// joined. Two lists with the same `(nostr_group_id, relays)` members — in
  /// any order, and regardless of a roster/member change to an existing circle
  /// — produce the SAME signature, so only an added/removed circle or a new
  /// routing id or relay set counts as a change (the last two only refresh
  /// what a later start is made from).
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
  /// [signatureForGroups].
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
    final byCircle = specsByCircle(circles);
    final signature = signatureForGroups(byCircle.values.toList());
    return LiveSyncResubscribeDecision(
      changed: signature != runningSignature,
      byCircle: byCircle,
      signature: signature,
    );
  }

  static String _hex(List<int> bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  /// Diffs [running] against [next] (a fresh [specsByCircle] snapshot), both
  /// keyed by hex `mls_group_id`, into the incremental ops the engine needs:
  /// circles to [Delta.added], and the `nostr_group_id` each removed circle
  /// was last known by to [Delta.removed]. A circle in both makes no op
  /// whatever its routing id or relays now are: unsubscribing the id it had
  /// would drop the prior routing the session keeps listed for a day. Pure —
  /// no FFI, no engine — so every combination is unit-testable directly.
  static Delta computeDelta(
    Map<String, FfiGroupSpec> running,
    Map<String, FfiGroupSpec> next,
  ) => Delta(
    added: [
      for (final entry in next.entries)
        if (!running.containsKey(entry.key)) entry.value,
    ],
    removed: [
      for (final entry in running.entries)
        if (!next.containsKey(entry.key)) entry.value.nostrGroupId,
    ],
    nextRunning: next,
  );

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
        '[LiveSyncResubscriber] onCirclesChanged: '
        '${magnitudeBucket(circles.length)} circles '
        '(${magnitudeBucket(accepted)} accepted) → '
        '${magnitudeBucket(decision.groups.length)} group(s), '
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
      final delta = computeDelta(_running, decision.byCircle);
      // Diagnostic (M11 e2e triage): the debounce fired and this is what the
      // engine is about to be re-anchored to. If this never logs after a
      // mid-session circle-create, the debounce/decide never scheduled it.
      if (kDebugMode) {
        debugPrint(
          '[LiveSyncResubscriber] delta → '
          '+${magnitudeBucket(delta.added.length)} added, '
          '-${magnitudeBucket(delta.removed.length)} removed',
        );
      }
      // Serialize behind any in-flight apply so engine calls never interleave.
      _chainNext(() => _applyDelta(delta), 'delta apply');
    });
  }

  /// Appends [body] to the serialized chain, absorbing any error it lets
  /// escape.
  ///
  /// The absorbing is not politeness. `.then` on an ERRORED future skips its
  /// callback and re-propagates, so a single escaped throw would leave `_chain`
  /// permanently errored — silently disabling every later delta apply AND every
  /// later self-heal for the rest of the session, with nothing observable but a
  /// map that stops updating. [legKind] names the leg in the log; the error
  /// type only (Security Rule 8).
  Future<void> _chainNext(Future<void> Function() body, String legKind) {
    return _chain = _chain
        .then((_) => body())
        .catchError((Object e) {
          debugPrint(
            '[LiveSyncResubscriber] $legKind failed: ${e.runtimeType}',
          );
        });
  }

  /// Applies one incremental [delta] to the running session: unsubscribe every
  /// removed circle, then subscribe every added circle; a delta with neither
  /// only adopts the fresh specs. Re-checks [_disposed] between every await so
  /// a mid-flight `dispose()` (logout / unmount) never issues an engine call
  /// after teardown. On success, adopts [Delta.nextRunning] as the new running
  /// set. On ANY failure — a delta op is best-effort against a possibly-gone
  /// session — falls back to the whole-set stop+start ([_fullRestart]) so this
  /// can never leave the app worse off than the old stop+start behaviour, with
  /// the one exception [_fullRestart] documents: a PAUSED engine is left
  /// paused.
  ///
  /// If the session is ALREADY not running (stopped between scenarios /
  /// backgrounded / torn down elsewhere), a delta op is guaranteed to fail
  /// with "no active session" — [SubscriptionService.isRunning] reads the
  /// SAME underlying engine state a delta op would hit, so this check never
  /// disagrees with the attempt it replaces. Skip straight to
  /// [_fullRestart] instead of a doomed subscribeCircle/unsubscribeCircle
  /// round-trip; the residual TOCTOU race (stopped between this check and
  /// the loop below) still falls back via the existing `on Object catch`.
  /// Restarts the engine if it has stopped while a session is still wanted.
  ///
  /// Returns what it found or did — see [LiveSyncHealOutcome].
  ///
  /// # Why this exists
  ///
  /// [_fullRestart] already recovers a stopped engine, but the ONLY thing that
  /// reaches it is [onCirclesChanged] → [_applyDelta], which runs when the
  /// accepted-circle set changes. With a stable set — the normal case — an
  /// engine that dies mid-session is never noticed: the health FFI
  /// reads an empty session and returns the inert `EngineOff`, so the health
  /// tick that exists to catch this is disarmed by the very condition it should
  /// heal, and live location receive stays dead until the app is relaunched.
  ///
  /// Engines die for reasons outside this class: a Rust-side teardown, or
  /// another isolate force-releasing the process-global session to reclaim the
  /// MLS database. That last one is deliberately possible, so an unbounded
  /// consequence for it is not acceptable — this is what bounds it.
  ///
  /// Idempotent and cheap when healthy: on a running engine it costs one
  /// `isRunning` read and one foreground claim, which contacts no relay.
  ///
  /// Serialized on `_chain`, so it can never interleave with an apply — and
  /// bounded by [kLiveSyncRestartBudget], so neither a throw nor a hang inside
  /// the restart can strand the caller.
  Future<LiveSyncHealOutcome> ensureRunning() {
    if (_disposed) {
      return Future<LiveSyncHealOutcome>.value(LiveSyncHealOutcome.stoodDown);
    }
    // Queue behind any in-flight apply or restart, exactly as
    // [onCirclesChanged] does. Calling `_fullRestart` directly — as an earlier
    // version did — is the bug this class's `_chain` exists to prevent:
    //
    //   * two restarts could run `stop()`/`start()` concurrently against the
    //     one shared engine, where the second `start` is silently swallowed by
    //     `NostrSubscriptionService`'s `if (_engine != null) return`, yet its
    //     caller still ran `_adoptRunning` with its own group list; and
    //   * whichever finished LAST won that write, so a heal holding a stale
    //     snapshot could stamp a smaller set over the newer one a concurrent
    //     delta had just started, leaving `_running`/`_signature` permanently
    //     disagreeing with the live engine — which makes the next identical
    //     snapshot look "changed" and re-issue subscribes forever.
    //
    // Two concurrent heals are just as reachable as a heal racing a delta: the
    // periodic timer and the resume-triggered call share no debounce.
    final completer = Completer<LiveSyncHealOutcome>();
    final leg = _chainNext(() async {
      final outcome = await _ensureRunningLocked();
      completer.complete(outcome);
      // Behind any start this heal queued behind, and NOT held on the chain:
      // the engine takes its lifecycle lock for a claim, and a pause holds
      // that lock for as long as its publishes take to drain, so a heal that
      // waited here would hold up every heal and every delta behind it. A
      // session whose own start found the app not resumed (`resumed` arrives
      // after it: a cold launch behind a system dialog, a return through the
      // app switcher) claimed nothing; this is what tells it the app is
      // resumed now. The service hands the engine the claim only if that is
      // true at this instant, and asks nothing of it otherwise.
      if (outcome == LiveSyncHealOutcome.running) {
        unawaited(_claimForeground());
      }
    }, 'self-heal restart');
    // `_chainNext` absorbs a throw to keep the chain usable; this is what still
    // gives the CALLER an answer in that case. Without it a throwing restart
    // left `MapShell._healLiveSyncIfStopped` awaiting a future nothing would
    // ever complete, and its `whenComplete` re-arm therefore never ran — one
    // failure removed the only periodic recovery path there is.
    unawaited(
      leg.whenComplete(() {
        if (!completer.isCompleted) {
          completer.complete(LiveSyncHealOutcome.failed);
        }
      }),
    );
    // A HANG is the other half of the same defect, and no `catchError` catches
    // one. Bounded by what the engine allows itself — see
    // [kLiveSyncRestartBudget]. The chained body is deliberately NOT abandoned:
    // it still holds the chain, so nothing starts a second engine behind its
    // back (Security Rule 14); the caller simply stops waiting and retries on
    // its own cadence.
    return completer.future.timeout(
      kLiveSyncRestartBudget,
      onTimeout: () => LiveSyncHealOutcome.failed,
    );
  }

  /// The service's claim never throws; a double's must not become an
  /// unhandled error of a future nobody awaits.
  Future<void> _claimForeground() async {
    try {
      await _engine.claimForeground();
    } on Object catch (_) {
      // Nothing is lost: the next heal claims again.
    }
  }

  /// The body of [ensureRunning], run only from inside `_chain`.
  ///
  /// An EMPTY running set is still a session worth starting, which is why
  /// there is no "nothing was ever subscribed" early return: the engine's
  /// inbox REQ (kind 1059 gift wraps) is how INVITATIONS arrive and exists
  /// independently of any circle, so refusing to restart an empty set left a
  /// brand-new account — the one account guaranteed to have no circles — with
  /// no live invitation delivery and no way back from a failed start.
  /// `MapShell` now performs its FIRST start through here for exactly that
  /// reason: one start path, serialized on one chain.
  ///
  /// NO circles AND no inbox relays is a REACHABLE state, and it fails safely.
  ///
  /// An earlier version of this comment claimed it was unreachable. That was
  /// wrong on both halves: `relay_settings_page.dart` only marks the PROFILE
  /// pool unremovable, so every inbox row offers removal; and
  /// `seed_defaults_if_unseeded` returns early once its sentinel exists, so it
  /// never re-seeds a list the user has deliberately emptied
  /// (`InboxRelaysNotifier`'s `fallbackDefaultRelays` only covers a seeding
  /// THROW). A user who removes every inbox relay really does leave it empty.
  ///
  /// What saves it is that the engine refuses rather than pretending: with no
  /// relays at all the bucket subscribe never gets a REQ accepted, so
  /// `start_session` tears down and returns an error instead of installing a
  /// session that reports `isRunning` while issuing zero REQs. This therefore
  /// answers `false` and the caller backs off — a visible, honest failure, not
  /// a healthy-looking deaf engine. The residual cost is a repeating heal
  /// failure for an account that has configured no relays, which is a
  /// configuration problem the sharing-health model is the right place to
  /// surface; no branch is added here for it.
  Future<LiveSyncHealOutcome> _ensureRunningLocked() async {
    if (_disposed) return LiveSyncHealOutcome.stoodDown;
    // Re-read under the chain rather than trusting a pre-queue observation: an
    // apply that ran while this was queued may already have restarted it.
    if (_engine.isRunning) return LiveSyncHealOutcome.running;
    debugPrint('[LiveSyncResubscriber] engine stopped — self-heal restart');
    final attempted = await _fullRestart(_running);
    if (_disposed) return LiveSyncHealOutcome.stoodDown;
    if (_engine.isRunning) return LiveSyncHealOutcome.running;
    return attempted
        ? LiveSyncHealOutcome.failed
        : LiveSyncHealOutcome.stoodDown;
  }

  Future<void> _applyDelta(Delta delta) async {
    if (_disposed) return;
    if (delta.isEmpty) {
      _adoptRunning(delta.nextRunning);
      return;
    }
    if (!_engine.isRunning) {
      if (kDebugMode) {
        debugPrint(
          '[LiveSyncResubscriber] engine not running — full restart instead '
          'of delta',
        );
      }
      await _fullRestart(delta.nextRunning);
      return;
    }
    try {
      for (final id in delta.removed) {
        if (_disposed) return;
        await _engine.unsubscribeCircle(id);
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
      await _fullRestart(delta.nextRunning);
    }
  }

  /// The old whole-set STOP then START, kept as the fallback for a delta-op
  /// failure so a transient engine hiccup can never leave a circle worse off
  /// than the pre-delta behaviour. Re-checks [_mayRun] between every await
  /// (no start-after-dispose; a session started after [dispose] is torn down
  /// rather than orphaned).
  ///
  /// Declines outright while the engine is PAUSED. A pause is the state
  /// between background bursts — no standing REQ, no socket — and `start()`
  /// knows nothing about it: it connects the pool and issues every standing
  /// REQ. Restarting from here would therefore put the always-on background
  /// socket back, and nothing would take it away again until some later
  /// burst's `finally` paused it. This is the only re-anchor path with that
  /// reach: [ensureRunning] reads `isRunning`, which stays TRUE across a
  /// pause, so it already does nothing.
  ///
  /// The deferral loses no work. A delta op issued while paused updates the
  /// engine's MODEL only (there is no socket to touch), and the running set is
  /// deliberately left un-adopted, so the same snapshot still reads as changed
  /// and the next apply — or the next burst's own re-anchor — carries it.
  ///
  /// Declines, too, while no session is wanted ([_mayRun]), and this is the
  /// one place that has to: it holds the only `start()` there is, so every
  /// leg that could bring a session up — a heal, a delta for a stopped
  /// engine, a delta whose op failed — ends here. The owner stops the engine
  /// directly when the app goes away, off this chain, and a leg already
  /// queued would otherwise start a session behind that stop: one nobody
  /// claimed, in a backgrounded process, with standing REQs and the MLS
  /// database's single-session guard. Read again before the start — the
  /// owner's stop finds nothing to end while this leg is between its own
  /// stop and its start — and after it, where a session the answer changed
  /// under is stopped again. Nothing is adopted, so the change is still owed
  /// when a session is next wanted.
  ///
  /// Answers whether a restart was ATTEMPTED to its end: `false` where it
  /// declined or was called off, so a caller that counts failed restarts can
  /// leave those out.
  Future<bool> _fullRestart(Map<String, FfiGroupSpec> running) async {
    final groups = running.values.toList();
    if (_disposed) return false;
    if (!_sessionWanted()) {
      debugPrint(
        '[LiveSyncResubscriber] no session is wanted — full restart declined',
      );
      return false;
    }
    if (_engine.isPaused) {
      debugPrint(
        '[LiveSyncResubscriber] engine paused — deferring full restart to the '
        'next burst',
      );
      return false;
    }
    if (kDebugMode) {
      debugPrint(
        '[LiveSyncResubscriber] full restart → '
        '${magnitudeBucket(groups.length)} group(s)',
      );
    }
    try {
      await _engine.stop();
      // Disposed (logout / unmount), or the app gone, during the stop
      // round-trip — do NOT start a session after either.
      if (!_mayRun) return false;
      final inbox = await _inboxRelays();
      if (!_mayRun) return false;
      await _engine.start(groups: groups, inboxRelays: inbox);
      // The same, during start()'s round-trips — tear the fresh session down
      // so it is not orphaned past teardown.
      if (!_mayRun) {
        unawaited(_engine.stop());
        return false;
      }
      _adoptRunning(running);
    } on SubscriptionStartEnded catch (e) {
      // A stop somebody asked for (a pause, a logout) asked for no session.
      // One the engine's own death made is a failure, which the heal backs
      // off from rather than restarting at its base cadence.
      debugPrint('[LiveSyncResubscriber] full restart ended by a stop');
      return e.endedByEngine && _mayRun;
    } on Object catch (e) {
      // Generic only — never the raw error (could carry a group id). Best
      // effort: the next change (or app resume's resubscribe) retries.
      debugPrint(
        '[LiveSyncResubscriber] full restart failed: ${e.runtimeType}',
      );
    }
    return true;
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
