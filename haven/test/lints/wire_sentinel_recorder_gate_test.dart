// Source lint: EVERY wire-journal sentinel the E2E scenario emits is emitted
// ONLY when the build declares a recording proxy.
//
// `TestRelay.emitWireJournalSentinel` refuses the compiled-default token, so a
// caller that loses this gate cannot put a harness verb on a real relay — it
// fails instead. And that failure lands in exactly one place: the nightly
// e2e-flakiness-stress lane, which drives this scenario straight at strfry
// (`HAVEN_E2E_RELAY: ws://10.0.2.2:7777`, no proxy in path). An ungated emit
// there reported the scenario as failed on every iteration of every run for a
// month, while the lane's whole purpose — measuring this scenario's flake rate
// — measured nothing. No PR check could see it, because no PR lane runs
// unproxied.
//
// So the gate is pinned HERE, where a plain `flutter test` sees it, exactly as
// the MLS-group-id announce helper's gate is pinned in
// `wire_mls_group_id_announce_sites_test.dart`. It does not duplicate the
// host-side behavioural proof in `test/e2e/test_relay_transport_test.dart`
// (that the default token is refused before anything is written): that one
// pins what the relay does, this one pins that the scenario never asks.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The gate, verbatim as the scenario spells it.
const String kRecorderGate = 'if (wireRecorderDeclared) {';

/// The call the gate has to cover.
const String kSentinelCall = 'emitWireJournalSentinel(';

/// Offsets of every occurrence of [needle] in [source].
///
/// The anti-vacuity primitive: a rule over "the calls" has to be told how many
/// there are, or an emit deleted outright reads the same as one that is gated.
List<int> offsetsOf(String source, String needle) {
  final offsets = <int>[];
  for (var at = source.indexOf(needle);
      at >= 0;
      at = source.indexOf(needle, at + needle.length)) {
    offsets.add(at);
  }
  return offsets;
}

/// Offsets of every [call] in [source] that does NOT sit inside an open
/// [gate] block.
///
/// Brace depth is counted from the gate's own `{` to the call: the block is
/// still open when the depth never returns to 0 on the way. A plain
/// `source.contains(gate)` would pass for a gate that closes two statements
/// above the call, which is precisely the shape this rule has to tell apart —
/// the manifest announce was gated while the sentinel next to it was not.
///
/// EVERY occurrence is graded, not just the first. A second emit added below
/// the gate would otherwise ride on its gated neighbour's verdict and surface
/// only at runtime, on the one nightly lane that drives with no proxy in path
/// — which is the delay this lint exists to remove.
List<int> ungatedCalls(
  String source, {
  required String gate,
  required String call,
}) {
  final ungated = <int>[];
  for (final callAt in offsetsOf(source, call)) {
    final gateAt = source.lastIndexOf(gate, callAt);
    if (gateAt < 0) {
      ungated.add(callAt);
      continue;
    }
    // Start ON the gate's trailing `{`, so the depth is 1 before the scan.
    var depth = 0;
    var covered = true;
    for (var i = gateAt + gate.length - 1; i < callAt; i++) {
      final c = source[i];
      if (c == '{') {
        depth++;
      } else if (c == '}') {
        depth -= 1;
        if (depth == 0) {
          covered = false;
          break;
        }
      }
    }
    if (!covered) ungated.add(callAt);
  }
  return ungated;
}

void main() {
  group('detector self-tests', () {
    const gate = 'if (g) {';
    const call = 'emit(';

    test('offsetsOf finds every occurrence, not just the first', () {
      expect(offsetsOf('emit();\nemit();\n', call), hasLength(2));
      expect(offsetsOf('nothing();\n', call), isEmpty);
    });

    test('a call directly inside the gate is covered', () {
      expect(
        ungatedCalls('if (g) {\n  emit();\n}\n', gate: gate, call: call),
        isEmpty,
      );
    });

    test('a call in a nested block inside the gate is covered', () {
      // The real shape: the emit sits in a try/catch inside the gate.
      expect(
        ungatedCalls(
          'if (g) {\n  try {\n    emit();\n  } on Object {}\n}\n',
          gate: gate,
          call: call,
        ),
        isEmpty,
      );
    });

    test('a call with no gate at all is not covered', () {
      expect(
        ungatedCalls('emit();\n', gate: gate, call: call),
        hasLength(1),
      );
    });

    test('a gate that closes before the call is not covered', () {
      // The defect this lint exists for, in miniature.
      expect(
        ungatedCalls(
          'if (g) {\n  other();\n}\nemit();\n',
          gate: gate,
          call: call,
        ),
        hasLength(1),
      );
    });

    test('a gate that only opens after the call is not covered', () {
      expect(
        ungatedCalls(
          'emit();\nif (g) {\n  other();\n}\n',
          gate: gate,
          call: call,
        ),
        hasLength(1),
      );
    });

    test('a SECOND call outside the gate is caught, not excused by the '
        'first', () {
      // The reason every occurrence is graded: one gated emit must not vouch
      // for an emit added below it.
      const source = 'if (g) {\n  emit();\n}\nemit();\n';
      expect(
        ungatedCalls(source, gate: gate, call: call),
        <int>[source.lastIndexOf(call)],
        reason: 'the verdict must name the UNGATED occurrence — grading only '
            'the first call would report this source clean',
      );
    });

    test('two calls in two separate gates are both covered', () {
      // The other direction, so the rule cannot be satisfied by rejecting
      // every source with more than one call in it.
      expect(
        ungatedCalls(
          'if (g) {\n  emit();\n}\nif (g) {\n  emit();\n}\n',
          gate: gate,
          call: call,
        ),
        isEmpty,
      );
    });
  });

  test('every sentinel emit sits under a declared recorder', () {
    final source = File(
      'integration_test/e2e/e2e_combined.dart',
    ).readAsStringSync();

    expect(
      offsetsOf(source, kSentinelCall),
      isNotEmpty,
      reason:
          'the scenario no longer emits a wire-journal sentinel at all. Every '
          'host oracle anchors its read on that marker and reports META-FLOOR '
          'without one, so this is a deletion to make deliberately, not by '
          'accident.',
    );

    expect(
      ungatedCalls(source, gate: kRecorderGate, call: kSentinelCall),
      isEmpty,
      reason:
          'every sentinel emit must sit inside `$kRecorderGate`. Ungated, it '
          'writes a harness verb to whatever socket the lane opened and then '
          'waits out its whole budget for an ack only a recording proxy can '
          'send — which is how e2e-flakiness-stress, the one lane that drives '
          'this scenario with no proxy in path, spent a month reporting a '
          'failed scenario instead of measuring its flake rate.',
    );
  });
}
