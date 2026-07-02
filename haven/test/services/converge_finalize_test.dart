import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/converge_finalize.dart';

ConvergeResultFfi _result(ConvergeResultKind kind, {bool pending = false}) =>
    ConvergeResultFfi(kind: kind, intentStillPending: pending);

/// Records the ops the loop invoked, for assertions.
class _Ops {
  int publishes = 0;
  int waits = 0;
  int converges = 0;
  int aborts = 0;
  int merges = 0;
  int reStages = 0;
}

/// Sentinel thrown by the injected `onHardError` so tests can pin that the
/// hard-error path fired (an `Exception`, not an `Error`, to keep the
/// `avoid_catching_errors` lint happy).
class _HardError implements Exception {}

void main() {
  group('runConvergeFinalize', () {
    test('Merged → onMerged, single publish, no re-stage/abort', () async {
      final ops = _Ops();
      final outcome = await runConvergeFinalize(
        label: 't',
        commitJson: 'c',
        stagedEpoch: BigInt.zero,
        publish: (c) async {
          ops.publishes++;
          return true;
        },
        waitWindow: () async => ops.waits++,
        converge: (c, e) async {
          ops.converges++;
          return _result(ConvergeResultKind.merged);
        },
        abort: () async => ops.aborts++,
        onHardError: () => throw _HardError(),
        onMerged: () async => ops.merges++,
        reStage: (a) async {
          ops.reStages++;
          return null;
        },
      );
      expect(outcome, ConvergeFinalizeOutcome.merged);
      expect(ops.publishes, 1);
      expect(ops.merges, 1);
      expect(ops.reStages, 0);
      expect(ops.aborts, 0);
    });

    test(
      'AdoptedWinner with intent satisfied → adoptedSatisfied, no welcomes',
      () async {
        final ops = _Ops();
        final outcome = await runConvergeFinalize(
          label: 't',
          commitJson: 'c',
          stagedEpoch: BigInt.zero,
          publish: (c) async {
            ops.publishes++;
            return true;
          },
          waitWindow: () async => ops.waits++,
          converge: (c, e) async => _result(ConvergeResultKind.adoptedWinner),
          abort: () async => ops.aborts++,
          onHardError: () => throw _HardError(),
          onMerged: () async => ops.merges++,
          reStage: (a) async {
            ops.reStages++;
            return null;
          },
        );
        // The winner made our change — no welcomes published, no re-stage.
        expect(outcome, ConvergeFinalizeOutcome.adoptedSatisfied);
        expect(ops.merges, 0);
        expect(ops.reStages, 0);
      },
    );

    test(
      'AdoptedWinner{pending} re-stages, then Merged publishes welcomes',
      () async {
        final ops = _Ops();
        final outcome = await runConvergeFinalize(
          label: 't',
          commitJson: 'c0',
          stagedEpoch: BigInt.zero,
          publish: (c) async {
            ops.publishes++;
            return true;
          },
          waitWindow: () async => ops.waits++,
          converge: (c, e) async {
            ops.converges++;
            return ops.converges == 1
                ? _result(ConvergeResultKind.adoptedWinner, pending: true)
                : _result(ConvergeResultKind.merged);
          },
          abort: () async => ops.aborts++,
          onHardError: () => throw _HardError(),
          onMerged: () async => ops.merges++,
          reStage: (a) async {
            ops.reStages++;
            return (commitJson: 'c${a + 1}', stagedEpoch: BigInt.from(a + 1));
          },
        );
        expect(outcome, ConvergeFinalizeOutcome.merged);
        expect(ops.publishes, 2, reason: 'initial + re-staged commit');
        expect(ops.reStages, 1);
        expect(ops.merges, 1);
        expect(ops.aborts, 0);
      },
    );

    test('RolledBack re-stages up to the bound, then gives up', () async {
      final ops = _Ops();
      final outcome = await runConvergeFinalize(
        label: 't',
        commitJson: 'c',
        stagedEpoch: BigInt.zero,
        publish: (c) async {
          ops.publishes++;
          return true;
        },
        waitWindow: () async => ops.waits++,
        converge: (c, e) async => _result(ConvergeResultKind.rolledBack),
        abort: () async => ops.aborts++,
        onHardError: () => throw _HardError(),
        onMerged: () async => ops.merges++,
        reStage: (a) async {
          ops.reStages++;
          return (commitJson: 'c', stagedEpoch: BigInt.zero);
        },
      );
      // attempts 0,1,2 each publish; re-stage after 0 and 1; attempt 2 hits the
      // bound (maxReStage=2) and stops without a 3rd re-stage. The change was
      // never applied.
      expect(outcome, ConvergeFinalizeOutcome.notApplied);
      expect(ops.publishes, 3);
      expect(ops.reStages, 2);
      expect(ops.merges, 0);
      expect(
        ops.aborts,
        0,
        reason:
            'clean bound exhaustion returns notApplied without aborting — '
            'the window already settled via converge',
      );
    });

    test(
      'AdoptedWinner{pending} re-stages up to the bound, then gives up',
      () async {
        // Distinct trigger from RolledBack, same bounded-stop behavior — the
        // winner keeps NOT making our change on every attempt.
        final ops = _Ops();
        final outcome = await runConvergeFinalize(
          label: 't',
          commitJson: 'c',
          stagedEpoch: BigInt.zero,
          publish: (c) async {
            ops.publishes++;
            return true;
          },
          waitWindow: () async => ops.waits++,
          converge: (c, e) async =>
              _result(ConvergeResultKind.adoptedWinner, pending: true),
          abort: () async => ops.aborts++,
          onHardError: () => throw _HardError(),
          onMerged: () async => ops.merges++,
          reStage: (a) async {
            ops.reStages++;
            return (commitJson: 'c', stagedEpoch: BigInt.zero);
          },
        );
        expect(outcome, ConvergeFinalizeOutcome.notApplied);
        expect(ops.publishes, 3);
        expect(ops.reStages, 2);
        expect(ops.merges, 0);
        expect(ops.aborts, 0, reason: 'bound exhaustion never aborts');
      },
    );

    test('publish failure aborts + hard-errors (L1)', () async {
      final ops = _Ops();
      var threw = false;
      try {
        await runConvergeFinalize(
          label: 't',
          commitJson: 'c',
          stagedEpoch: BigInt.zero,
          publish: (c) async {
            ops.publishes++;
            return false;
          },
          waitWindow: () async => ops.waits++,
          converge: (c, e) async => _result(ConvergeResultKind.merged),
          abort: () async => ops.aborts++,
          onHardError: () => throw _HardError(),
        );
      } on _HardError {
        threw = true;
      }
      expect(threw, isTrue);
      expect(ops.aborts, 1, reason: 'L1: abort before the hard error');
      expect(ops.converges, 0, reason: 'never converged after a publish fail');
    });

    test('a converge throw aborts + hard-errors (L1)', () async {
      final ops = _Ops();
      var threw = false;
      try {
        await runConvergeFinalize(
          label: 't',
          commitJson: 'c',
          stagedEpoch: BigInt.zero,
          publish: (c) async {
            ops.publishes++;
            return true;
          },
          waitWindow: () async => ops.waits++,
          converge: (c, e) async => throw StateError('converge boom'),
          abort: () async => ops.aborts++,
          onHardError: () => throw _HardError(),
        );
      } on _HardError {
        threw = true;
      }
      expect(threw, isTrue);
      expect(ops.aborts, 1, reason: 'L1: abort on ANY converge error');
    });

    test(
      'converge null (engine stopped mid-flow) aborts + notApplied',
      () async {
        final ops = _Ops();
        final outcome = await runConvergeFinalize(
          label: 't',
          commitJson: 'c',
          stagedEpoch: BigInt.zero,
          publish: (c) async {
            ops.publishes++;
            return true;
          },
          waitWindow: () async => ops.waits++,
          converge: (c, e) async => null,
          abort: () async => ops.aborts++,
          onHardError: () => throw _HardError(),
        );
        // No throw — best-effort cleanup of the dangling commit; not applied.
        expect(outcome, ConvergeFinalizeOutcome.notApplied);
        expect(ops.aborts, 1);
      },
    );

    test('re-stage null on first attempt aborts + notApplied', () async {
      final ops = _Ops();
      final outcome = await runConvergeFinalize(
        label: 't',
        commitJson: 'c',
        stagedEpoch: BigInt.zero,
        publish: (c) async {
          ops.publishes++;
          return true;
        },
        waitWindow: () async => ops.waits++,
        converge: (c, e) async => _result(ConvergeResultKind.rolledBack),
        abort: () async => ops.aborts++,
        onHardError: () => throw _HardError(),
        reStage: (a) async {
          ops.reStages++;
          return null;
        },
      );
      expect(outcome, ConvergeFinalizeOutcome.notApplied);
      expect(ops.aborts, 1);
      expect(ops.reStages, 1);
      expect(
        ops.publishes,
        1,
        reason: 'no second publish after a null re-stage',
      );
    });

    test(
      're-stage null on the SECOND attempt (mid-loop) aborts + notApplied',
      () async {
        // attempt 0: publish c0, converge RolledBack, reStage → valid c1.
        // attempt 1: publish c1, converge RolledBack, reStage → null (engine
        // stopped after a second publish already happened).
        final ops = _Ops();
        final outcome = await runConvergeFinalize(
          label: 't',
          commitJson: 'c0',
          stagedEpoch: BigInt.zero,
          publish: (c) async {
            ops.publishes++;
            return true;
          },
          waitWindow: () async => ops.waits++,
          converge: (c, e) async => _result(ConvergeResultKind.rolledBack),
          abort: () async => ops.aborts++,
          onHardError: () => throw _HardError(),
          reStage: (a) async {
            ops.reStages++;
            return a == 0 ? (commitJson: 'c1', stagedEpoch: BigInt.one) : null;
          },
        );
        expect(outcome, ConvergeFinalizeOutcome.notApplied);
        expect(ops.publishes, 2, reason: 'c0 then the re-staged c1');
        expect(
          ops.reStages,
          2,
          reason: 'valid on attempt 0, null on attempt 1',
        );
        expect(ops.aborts, 1, reason: 'abort on the mid-loop null re-stage');
      },
    );

    test(
      'self-update (no reStage) on non-Merged → notApplied, benign',
      () async {
        final ops = _Ops();
        final outcome = await runConvergeFinalize(
          label: 'self-update',
          commitJson: 'c',
          stagedEpoch: BigInt.zero,
          publish: (c) async {
            ops.publishes++;
            return true;
          },
          waitWindow: () async => ops.waits++,
          converge: (c, e) async => _result(ConvergeResultKind.rolledBack),
          abort: () async => ops.aborts++,
          onHardError: () => throw _HardError(),
          // no reStage → self-update never re-stages.
        );
        // notApplied, but the caller (self-update) ignores it — the hourly
        // scheduler retries a rolled-back rotation.
        expect(outcome, ConvergeFinalizeOutcome.notApplied);
        expect(ops.publishes, 1);
        expect(ops.aborts, 0, reason: 'a rolled-back self-update is benign');
      },
    );
  });
}
