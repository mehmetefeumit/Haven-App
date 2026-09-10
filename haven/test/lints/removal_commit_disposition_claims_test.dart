// Guard for a claim about the MLS engine that a probe DISPROVED, and for the
// correction that replaced it.
//
// Three production files used to tell the reader the same false thing: that a
// receive-side auto-commit (a peer's `SelfRemove` eviction) whose publish no
// relay acked is "not lost", because the buffered proposal makes the next poll
// tick / background sweep re-surface a fresh attempt. It does not. At the
// pinned MDK rev the engine drops its in-memory `SelfRemove` auto-commit
// schedule BEFORE staging, `do_publish_failed` does not re-arm it, and a
// redelivered proposal short-circuits to `Buffered` off its durable `Created`
// row. Nothing re-derives the eviction — so a reader who believed the claim
// would reach for the rollback thinking it cheap, and permanently drop a
// removal the departing member asked for.
//
// The claim is a quotable sentence, so it is pinned as one, in BOTH directions:
// the disproved wording must be absent from every production Dart file, and the
// correction must be present at each of the three sites. A one-directional
// guard would pass on a file that simply deleted the explanation, which is how
// the claim came back the last time — the reader is then free to re-derive it.
//
// What this deliberately does NOT do is police the word "rollback". Two of
// these files describe a rollback in order to say it does not happen, and one
// legitimately rolls back a send-side commit; a word-level ban would fail on
// correct prose and teach nothing.
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The disproved wording, quoted from the three files as they stood.
///
/// Matched case-insensitively over whole production files (not per line),
/// because the wrapping of a comment is not part of the claim.
const _disprovedClaims = <String>[
  're-surfaces a fresh jittered attempt',
  "that recurring cadence is this path's retry",
  'leaves the proposal un-seen for retry on the next cycle',
  'stays buffered in the engine, so the next',
];

/// What each site must say instead, keyed by file. The value is the sentence
/// that carries the corrected mechanism; deleting it is as much a regression as
/// restoring the claim.
const _requiredCorrections = <String, String>{
  'lib/src/services/location_auto_commit.dart':
      'It is not re-surfaced by a later tick.',
  'lib/src/services/background_deferred_send.dart':
      'That failure report is NOT a rollback.',
  'lib/src/services/background_location_task.dart':
      'does NOT roll the commit back',
};

/// Every site must point at the Rust symbol that actually keeps the removal, so
/// the correction is checkable rather than merely reassuring.
const _obligationSymbol = 'owe_removal_publish';

/// The scan itself: every pinned claim [source] contains, labelled by [path].
///
/// A named function, and not a loop inside the test, so the self-test below can
/// exercise the REAL predicate. A self-test that re-states the predicate proves
/// only that string concatenation works, and passes just as happily when the
/// pinned list is empty.
List<String> _offendersIn(String path, String source) {
  final src = source.toLowerCase();
  return _disprovedClaims
      .where((claim) => src.contains(claim.toLowerCase()))
      .map((claim) => '$path: "$claim"')
      .toList();
}

List<File> _productionDart() {
  final lib = Directory('lib');
  expect(
    lib.existsSync(),
    isTrue,
    reason: 'run this from the haven/ package root',
  );
  return lib
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();
}

void main() {
  group('the disproved auto-commit retry claim', () {
    test('is absent from every production Dart file', () {
      final offenders = <String>[];
      for (final file in _productionDart()) {
        offenders.addAll(_offendersIn(file.path, file.readAsStringSync()));
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'these files claim an unacked receive-side auto-commit is retried '
            'by a later tick: $offenders. A probe against the engine at the '
            'pinned MDK rev disproved it — the eviction is never re-derived '
            'once the schedule is dropped. What keeps it is the durable '
            'obligation Rust records before the commit crosses the FFI.',
      );
    });

    test('detects the claim when it is present', () {
      // Non-vacuity, in the two ways this guard can go quiet. Emptying either
      // pinned collection makes every assertion here trivially true, and a
      // guard that passes on an empty pin is worse than no guard: it reports a
      // property nobody is checking.
      expect(_disprovedClaims, isNotEmpty);
      expect(_requiredCorrections, isNotEmpty);
      expect(_obligationSymbol, isNotEmpty);

      // And the scanner really fires — driven through the SAME function the
      // sweep above uses, never a re-statement of it, on a source carrying the
      // claim and on one that does not.
      for (final claim in _disprovedClaims) {
        expect(
          _offendersIn('synthetic.dart', 'prose claiming it $claim, allegedly'),
          ['synthetic.dart: "$claim"'],
          reason: 'the scanner must report its own pinned wording, once',
        );
      }
      expect(
        _offendersIn('synthetic.dart', 'prose that says nothing of the kind'),
        isEmpty,
        reason: 'and must stay silent on prose carrying no pinned claim',
      );
    });

    test('is replaced by the corrected mechanism at every site', () {
      for (final entry in _requiredCorrections.entries) {
        final file = File(entry.key);
        expect(
          file.existsSync(),
          isTrue,
          reason:
              '${entry.key} no longer exists; move this pin to whichever '
              "file now resolves that plane's auto-commit, rather than "
              'dropping it',
        );
        final src = file.readAsStringSync();
        expect(
          src,
          contains(entry.value),
          reason:
              '${entry.key} no longer states what happens to an unacked '
              'eviction. Deleting the explanation is how the false one came '
              'back: without it the next reader re-derives "the next tick '
              'retries it" from the fact that nothing else is said.',
        );
        expect(
          src,
          contains(_obligationSymbol),
          reason:
              '${entry.key} must name `$_obligationSymbol`, the Rust symbol '
              'that records the removal as owed. A correction that points at '
              'no mechanism cannot be checked by the next reader.',
        );
      }
    });
  });
}
