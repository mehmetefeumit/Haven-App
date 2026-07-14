import 'package:flutter/foundation.dart';

import 'package:haven/src/rust/api.dart';

/// A re-staged commit for the converging-finalize loop (CS1 output).
typedef ReStaged = ({String commitJson, BigInt stagedEpoch});

/// The terminal outcome of [runConvergeFinalize].
///
/// Distinguishes the three ways the loop can end without a hard error, so a
/// membership caller can tell "the change was applied" from "the change was
/// NOT applied" — the latter must surface a retryable error rather than a
/// silent success.
enum ConvergeFinalizeOutcome {
  /// Our commit was applied at the staged epoch (intent achieved by us).
  /// [runConvergeFinalize]'s `onMerged` has run.
  merged,

  /// A sibling's commit won and already satisfied our intent — or there was no
  /// intent to satisfy (self-update). The change IS in effect; nothing to do.
  adoptedSatisfied,

  /// The intent could NOT be applied: the bounded re-stage budget was
  /// exhausted, or the engine stopped mid-flow. The MLS group state stays
  /// consistent (no half-applied commit — the window was aborted), but our
  /// change was not made. Membership callers should surface a retryable error;
  /// self-update can ignore it (the periodic scheduler retries the rotation).
  notApplied,
}

/// Runs the settle-window finalize loop after CS1 has staged a commit + opened
/// the window (M6-4, path A): publish the commit DURING the window so a sibling
/// admin can collect it, wait the window, then converge under the gate.
///
/// - `Merged` → runs [onMerged] (e.g. publish Welcomes) and returns
///   [ConvergeFinalizeOutcome.merged].
/// - `AdoptedWinner` with the intent already satisfied → returns
///   [ConvergeFinalizeOutcome.adoptedSatisfied] (the winner made our change;
///   for self-update there is no intent).
/// - `AdoptedWinner{intent_still_pending}` / `RolledBack` → re-stages via
///   [reStage] (bounded by [maxReStage]) and loops; on exhaustion returns
///   [ConvergeFinalizeOutcome.notApplied].
/// - A publish failure OR a converge throw → runs [abort] then [onHardError]
///   (which throws) — the M6-1 QC "abort on ANY error" (L1) contract.
/// - The engine stopping mid-flow ([converge] / [reStage] returns `null`) → runs
///   [abort] and returns [ConvergeFinalizeOutcome.notApplied] (best-effort; the
///   staged commit is cleaned up).
/// - Torn down mid-flow ([isTornDown] returns `true` after the settle wait) →
///   runs [abort] and returns [ConvergeFinalizeOutcome.notApplied] WITHOUT
///   converging, so an MLS write never resurrects state a logout / leave sweep
///   just wiped (M10 no-resurrection). Pair with a [waitWindow] that unblocks
///   on teardown so the loop does not stall for the full window first.
///
/// All FFI/relay operations are injected, so the loop is unit-testable without
/// the bridge, the `liveSyncEnabled` flag, or a real MLS group.
Future<ConvergeFinalizeOutcome> runConvergeFinalize({
  required String label,
  required String commitJson,
  required BigInt stagedEpoch,
  required Future<bool> Function(String commitJson) publish,
  required Future<void> Function() waitWindow,
  required Future<ConvergeResultFfi?> Function(
    String commitJson,
    BigInt stagedEpoch,
  )
  converge,
  required Future<void> Function() abort,
  required Never Function() onHardError,
  Future<void> Function()? onMerged,
  Future<ReStaged?> Function(int attempt)? reStage,
  bool Function()? isTornDown,
  int maxReStage = 2,
}) async {
  var curCommit = commitJson;
  var curEpoch = stagedEpoch;

  for (var attempt = 0; ; attempt++) {
    // Publish the commit DURING the window (Decision A: unconditional — a
    // losing commit is harmlessly dropped by peers via WrongEpoch).
    if (!await publish(curCommit)) {
      await abort();
      onHardError();
    }

    await waitWindow();

    // Torn down (logout / leave / dispose) during the publish or the settle
    // wait: do NOT converge. Converging would issue an MLS write against a
    // wiped group and could re-create decryptable state the M10 logout sweep
    // just deleted (no-resurrection). `abort` is a no-op once wiped, so this
    // only clears a still-live pending commit. Report not-applied.
    if (isTornDown?.call() ?? false) {
      await abort();
      return ConvergeFinalizeOutcome.notApplied;
    }

    // Converge — abort + hard-error on ANY throw (L1 contract).
    final ConvergeResultFfi? result;
    try {
      result = await converge(curCommit, curEpoch);
    } on Object catch (e) {
      // Name the failure (redacted runtime-type only — never the raw string,
      // which could carry a group id): this catch previously swallowed the
      // error silently, which left a converging-membership hard failure
      // undiagnosable from the drive log.
      debugPrint('[converge] $label finalize failed: ${e.runtimeType}');
      await abort();
      onHardError();
    }

    if (result == null) {
      // Engine stopped mid-flow (flag race): clean up the dangling commit. The
      // intent was not applied.
      await abort();
      return ConvergeFinalizeOutcome.notApplied;
    }

    if (result.kind == ConvergeResultKind.merged) {
      if (onMerged != null) await onMerged();
      return ConvergeFinalizeOutcome.merged;
    }
    if (result.kind == ConvergeResultKind.adoptedWinner &&
        !result.intentStillPending) {
      // The winner already made our change (or there was none — self-update).
      return ConvergeFinalizeOutcome.adoptedSatisfied;
    }

    // AdoptedWinner{intent_still_pending} or RolledBack → re-stage (bounded).
    if (reStage == null || attempt >= maxReStage) {
      debugPrint(
        '$label: not merged after ${attempt + 1} attempt(s) — stopping '
        '(bounded re-stage)',
      );
      return ConvergeFinalizeOutcome.notApplied;
    }
    final next = await reStage(attempt);
    if (next == null) {
      await abort();
      return ConvergeFinalizeOutcome.notApplied;
    }
    curCommit = next.commitJson;
    curEpoch = next.stagedEpoch;
  }
}
