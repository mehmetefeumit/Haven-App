// Source lint: every circle the E2E scenario creates announces its real MLS
// group id to the recording proxy.
//
// The wire-correlation oracle's C5.8 asserts Security Rule 4 — the real MLS
// group id never appears on the wire. It can only assert the absence of values
// it was GIVEN, and it is given exactly the ids `e2e_combined.dart` announces.
// So a deleted announce does not weaken the check visibly; it narrows the
// needle set while every verdict stays green.
//
// The runtime floor in the scenario is `_announcedMlsGroupIds > 0`, which only
// catches "every call site was removed". It cannot catch the removal of ONE —
// and one is enough to matter: `_m11AliceCreatesCircle` covers every
// Alice-created M11 circle, including the two-circle decorrelation scenario
// whose application kind-445s are the only ones satisfying C5.1's
// two-distinct-group precondition on the live-sync lane. Delete that single
// announce and C5.8 still reports clean over a set missing the ids that
// actually ride those circles' `h` tags.
//
// This pins the count by EQUALITY, so adding a circle-creating scenario
// without announcing its id is as loud as deleting one. Update the number in
// the same commit that changes the sites, and say why.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Call sites of `_announceMlsGroupId(` in the scenario, excluding its own
/// declaration. Each corresponds to a distinct circle-creation path:
///   1. the core-flow family circle (Bob's accepted view of Alice's UI create)
///   2. FE-2's circle
///   3. `_m11AliceCreatesCircle` (every Alice-created M11 circle)
///   4. M11:f — Bob-created
///   5. M11:g — Bob-created
const int kExpectedAnnounceCallSites = 5;

void main() {
  test('every circle-creation path announces its MLS group id', () {
    final source = File(
      'integration_test/e2e/e2e_combined.dart',
    ).readAsStringSync();

    // The declaration is `Future<void> _announceMlsGroupId({`; call sites are
    // `_announceMlsGroupId(` preceded by `await `.
    final calls = RegExp(
      r'await\s+_announceMlsGroupId\(',
    ).allMatches(source).length;

    expect(
      calls,
      kExpectedAnnounceCallSites,
      reason:
          'the number of MLS-group-id announce call sites changed. C5.8 can '
          'only assert the absence of ids it was handed, so a REMOVED call '
          'site silently narrows the needle set while every wire verdict '
          'stays green — the runtime `> 0` floor cannot see it. An ADDED '
          'circle-creation path that does not announce is the same defect. '
          'Update kExpectedAnnounceCallSites in the same commit and state '
          'which path changed.',
    );
  });

  test('the announce helper is gated on a declared recorder', () {
    final source = File(
      'integration_test/e2e/e2e_combined.dart',
    ).readAsStringSync();

    expect(
      source.contains('if (!wireRecorderDeclared)'),
      isTrue,
      reason:
          'the announce helper must skip when the build declares no recording '
          'proxy. e2e-flakiness-stress.yml drives this scenario straight at '
          'strfry, and an unconditional announce would put the REAL MLS group '
          'id on a relay socket nightly — Security Rule 4.',
    );
  });
}
