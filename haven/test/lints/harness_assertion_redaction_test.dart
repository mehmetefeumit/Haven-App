// Static guard: every `debugPrint(`/`print(`/`reason:`/`fail(`/thrown-
// exception-constructor string interpolation under `integration_test/` stays
// inside Security Rule 15 (the Log anonymity pillar) — no bare pubkey/npub,
// group id, event id, member id, coordinate, relay URL, display
// name/petname, absolute instant, millisecond duration, raw exception or
// `.toString()` rendering may reach a harness log line, even one that only
// fires when an `expect()` fails or a scenario throws.
//
// ## Why this exists
//
// `debugPrint`/`reason:`/`fail(`/`StateError(` (and its sibling exception
// constructors) strings are the ONE place ordinary Dart string
// interpolation, not the `logAliasHandle`/`magnitudeBucket`/`relativeSecs`
// helpers, is the natural thing to reach for — and the one place a failing
// assertion, or an uncaught exception's `toString()`, prints its own
// arguments into the `flutter drive` log for a CI reader to see. Phase 0c's
// harness hygiene pass fixed every violation this lint's vocabulary catches
// (see `scratchpad/soak-plan/l0c/H3/report.md` for the file-by-file list);
// this lint is what keeps a new one from being reintroduced.
//
// ## How it works
//
// An AST scan (`package:analyzer`, already a dev dependency — see
// `test/lints/throw_time_error_logging_reachable_test.dart` for the same
// technique), not a line-oriented regex: Dart's adjacent-string-literal
// concatenation (`'a' 'b'` split across lines, the shape almost every
// multi-line `debugPrint`/`reason:` in this tree uses) parses as ONE
// `AdjacentStrings` expression, so finding every `InterpolationExpression`
// in the subtree of a flagged call's argument (or a `reason:` value)
// naturally joins them — no hand-rolled string-literal lexer needed.
//
// For each `InterpolationExpression` found, the ORIGINAL source span from
// its `leftBracket` (`$` or `${`) to its `end` is matched, verbatim
// including the punctuation, against [_vocabulary] — so `$e` and `${e}`
// match their own alternatives directly, and identifier-shaped terms
// (`pubkey`, `Hex`, `groupId`, …) match wherever they appear in the
// embedded expression's own source text. A match is forgiven when the
// embedded expression is a call to [_exemptWrapperNames] (`logAliasHandle(`,
// `magnitudeBucket(`, `relativeSecs(`), ends with `.runtimeType` or `.name`
// (the enum-tag idiom used throughout the harness — `tier.name`,
// `permission.name`), or the flagged line carries a non-empty
// `// harness-log-ok: <reason>` suppression.
//
// ## Exact sizes are deliberately outside [_vocabulary]
//
// `_vocabulary` has no `count`/`length` term. Where an `expect(reason:)`
// literally repeats the exact size the SAME matcher's own `Expected:`/
// `Actual:` failure output already renders (e.g. `expect(x.length,
// equals(2), reason: '... 2 ...')`), the reason adds no exposure a failure
// would not already carry — this lint does not chase that shape, and never
// will, because catching it would only ever flag a number the framework
// prints anyway. That is NOT a license to print an exact count of anything
// outside a synthetic CI roster of this harness's own fixture users
// (Alice/Bob/Carol/…, always a hardcoded, non-secret cast size): any count
// touching a REAL user's data — circles, members, relays, events — still
// goes through `magnitudeBucket`, full stop.
@TestOn('vm')
library;

import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:flutter_test/flutter_test.dart';

/// Bare top-level calls whose string argument(s) are scanned.
///
/// `debugPrint`/`print` name calls with `target == null` only, so a
/// hypothetical `someLogger.print(...)` (a different API entirely) is not
/// mistaken for the top-level function. The exception constructors are
/// unqualified (bare) forms only — `Foo(...)`, never `Foo.value(...)` —
/// because `parseString` (unresolved, syntax-only) represents an unnamed
/// constructor invocation as a plain [MethodInvocation] with `target ==
/// null`, exactly like a top-level function call; a NAMED constructor
/// (`ArgumentError.value(`, `RangeError.range(`) parses with a non-null
/// target and is a known, documented gap — same one
/// `check_no_identifier_logging.sh`'s header names. As of the 2026-09-16 H6
/// pass the tree has NO value-bearing named-constructor call under
/// `integration_test/` (every `.value(` site was converted to the bare
/// form or drops the value), so the gap is empty in practice, not merely
/// unscanned; `findHarnessLogFindings`'s own self-test pins
/// `ArgumentError.value(` as unmatched so a regression is a tested
/// property.
const Set<String> _scannedCallNames = {
  'debugPrint',
  'print',
  'fail',
  'StateError',
  'ArgumentError',
  'FormatException',
  'Exception',
  'UnsupportedError',
  'RangeError',
  'TimeoutException',
};

/// Identifier vocabulary a flagged interpolation's own source text is
/// matched against — exact per the Phase 0c brief (`L0C_BRIEF.md` §6): every
/// shape Security Rule 15 forbids in a log line that this AST-only lint can
/// recognise syntactically (a raw `latitude`/`longitude` read, a `Hex`/
/// `groupId`/`eventId`/`.id` field, a `pubkey`/`npub`, a `Url`/`relay`
/// field or class, a `name`/`petname` field, an absolute `epoch` number, a
/// relay's raw `msg`/`message` reason text, `toIso8601String()` (absolute
/// instant), `inMilliseconds` (elapsed-from-wall-clock), a bare `$e`/`${e}`,
/// or `.toString()`).
final RegExp _vocabulary = RegExp(
  r'pubkey|npub|Hex|groupId|GroupId|eventId|\.id\b|latitude|longitude|'
  r'\blat\b|\blon\b|Url|\burl\b|relay|Relay|\bname\b|petname|[Ee]poch|'
  r'\bmsg\b|\bmessage\b|\brejection\b|'
  r'toIso8601String|inMilliseconds|\$e\b|\$\{e\}|\.toString\(\)',
);

/// Calls whose result an otherwise-matching interpolation is forgiven for —
/// the expression converts the raw value into something Rule 15 already
/// allows (a salted handle, a bucketed magnitude, a relative offset) before
/// it reaches the string.
const Set<String> _exemptWrapperNames = {
  'logAliasHandle',
  'magnitudeBucket',
  'relativeSecs',
};

/// Receiver words `.name` is the Dart enum-tag idiom for (`outcome.name`,
/// `state.mode.name`, `expectedTier.name`) — mirrors
/// `check_no_identifier_logging.sh`'s `SAFE` regex word-for-word, so the two
/// scanners agree on which `.name` accesses are a classification tag rather
/// than user text (`circle.name`, `member.name`).
const Set<String> _safeNameReceiverWords = {
  'kind',
  'mode',
  'status',
  'state',
  'outcome',
  'decision',
  'category',
  'phase',
  'tier',
  'action',
  'policy',
  'verdict',
  'class',
  'variant',
  'level',
};

/// The lowercase parts of a camelCase/PascalCase identifier, split at each
/// lower-to-upper transition — `expectedTier` and `tier` both end in `tier`.
List<String> _decamelParts(String identifier) => [
  for (final part in identifier.split(RegExp('(?=[A-Z])')))
    if (part.isNotEmpty) part.toLowerCase(),
];

/// The identifier immediately to the LEFT of a `.name`/`.runtimeType`
/// access — the receiver whose decamelled tail decides whether `.name` is
/// an enum tag or user text. `state.mode.name` is a chain of two accesses;
/// this reads only the innermost one (`mode`), which is what the tag
/// actually names.
String? _receiverTail(Expression? receiver) => switch (receiver) {
  SimpleIdentifier(:final name) => name,
  PropertyAccess(:final propertyName) => propertyName.name,
  PrefixedIdentifier(:final identifier) => identifier.name,
  _ => null,
};

/// A single flagged interpolation.
class HarnessLogFinding {
  HarnessLogFinding({
    required this.path,
    required this.line,
    required this.snippet,
  });

  final String path;
  final int line;

  /// The exact, ORIGINAL source text of the interpolation (`$e`,
  /// `${nostrGroupIdHex}`, …) — never a description of it, so a failure
  /// message can point at exactly what tripped the rule without needing a
  /// second lookup.
  final String snippet;

  @override
  String toString() => '$path:$line  $snippet';
}

/// Scans [source] for every unredacted, unsuppressed interpolation inside a
/// [_scannedCallNames] call or a `reason:` value, plus the number of
/// candidate string-bearing call sites found — so callers can enforce an
/// anti-vacuity floor the same way the sibling lints in this directory do.
({List<HarnessLogFinding> findings, int sitesScanned}) findHarnessLogFindings(
  String source, {
  String path = '<memory>',
}) {
  final result = parseString(content: source, throwIfDiagnostics: false);
  final exemptNames = _fileLocalExemptNames(result.unit);
  final visitor = _Visitor(source, result.lineInfo, path, exemptNames);
  result.unit.accept(visitor);
  return (findings: visitor.findings, sitesScanned: visitor.sitesScanned);
}

/// [_exemptWrapperNames] plus every file-private top-level function OR
/// class method that is ITSELF nothing but a one-line forward to an
/// already-exempt call (e.g. `synthetic_user.dart`'s
/// `static String _pkHandle(String hex) =>
/// logAliasHandle(LogAliasClass.peer, hex);`) — a naming convention this
/// tree already uses, and one this AST-only lint can verify syntactically
/// (a single arrow/return body, nothing else) rather than trust by name.
/// Iterates to a fixed point so a wrapper defined in terms of another
/// file-local wrapper is recognised regardless of declaration order.
Set<String> _fileLocalExemptNames(CompilationUnit unit) {
  final names = {..._exemptWrapperNames};
  final candidates = <String, FunctionBody>{};
  for (final decl in unit.declarations) {
    if (decl is FunctionDeclaration) {
      candidates[decl.name.lexeme] = decl.functionExpression.body;
    } else if (decl is ClassDeclaration) {
      final body = decl.body;
      if (body is BlockClassBody) {
        for (final member in body.members) {
          if (member is MethodDeclaration) {
            candidates[member.name.lexeme] = member.body;
          }
        }
      }
    }
  }
  for (var pass = 0; pass < 4; pass++) {
    var changed = false;
    for (final entry in candidates.entries) {
      final name = entry.key;
      if (names.contains(name)) continue;
      final body = entry.value;
      Expression? returned;
      if (body is ExpressionFunctionBody) {
        returned = body.expression;
      } else if (body is BlockFunctionBody) {
        final statements = body.block.statements;
        if (statements.length == 1 && statements.single is ReturnStatement) {
          returned = (statements.single as ReturnStatement).expression;
        }
      }
      if (returned is MethodInvocation &&
          returned.target == null &&
          names.contains(returned.methodName.name)) {
        names.add(name);
        changed = true;
      }
    }
    if (!changed) break;
  }
  return names;
}

class _Visitor extends RecursiveAstVisitor<void> {
  _Visitor(this._source, this._lineInfo, this._path, this._exemptNames);

  final Set<String> _exemptNames;

  final String _source;
  final LineInfo _lineInfo;
  final String _path;

  final List<HarnessLogFinding> findings = [];
  int sitesScanned = 0;

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final callName = node.methodName.name;
    final isScannedCall =
        node.target == null && _scannedCallNames.contains(callName);
    if (isScannedCall) {
      sitesScanned++;
      for (final arg in node.argumentList.arguments) {
        // A named `reason:`/`message:` argument is visited separately below
        // via visitNamedExpression (which this recursive walk also reaches),
        // so only positional string arguments are scanned here to avoid
        // double-counting `sitesScanned` for the same call.
        if (arg is! NamedExpression) _scanForInterpolations(arg);
      }
    }
    super.visitMethodInvocation(node);
  }

  @override
  void visitNamedExpression(NamedExpression node) {
    if (node.name.label.name == 'reason') {
      sitesScanned++;
      _scanForInterpolations(node.expression);
    }
    super.visitNamedExpression(node);
  }

  void _scanForInterpolations(Expression root) {
    final finder = _InterpolationFinder();
    root.accept(finder);
    for (final interp in finder.found) {
      _checkInterpolation(interp);
    }
  }

  void _checkInterpolation(InterpolationExpression node) {
    final span = _source.substring(node.offset, node.end);
    if (!_vocabulary.hasMatch(span)) return;
    if (_isExempt(node)) return;
    final line = _lineInfo.getLocation(node.offset).lineNumber;
    if (_hasSuppressionOnLine(line)) return;
    findings.add(HarnessLogFinding(path: _path, line: line, snippet: span));
  }

  bool _isExempt(InterpolationExpression node) {
    final expr = node.expression;
    if (expr is MethodInvocation &&
        expr.target == null &&
        _exemptNames.contains(expr.methodName.name)) {
      return true;
    }
    final (property, receiver) = switch (expr) {
      PropertyAccess(:final propertyName, :final target) => (
        propertyName.name,
        target,
      ),
      PrefixedIdentifier(:final identifier, :final prefix) => (
        identifier.name,
        prefix,
      ),
      _ => (null, null),
    };
    if (property == 'runtimeType') return true;
    if (property != 'name') return false;
    // `.name` is the enum-tag idiom ONLY on a classification receiver
    // (`outcome.name`, `expectedTier.name`); on a data receiver
    // (`circle.name`, `member.name`) it is user text.
    final tail = _receiverTail(receiver);
    if (tail == null) return false;
    final parts = _decamelParts(tail);
    return parts.isNotEmpty && _safeNameReceiverWords.contains(parts.last);
  }

  bool _hasSuppressionOnLine(int oneBasedLine) {
    // `LineInfo` is 1-based; `String.split` gives a 0-based list.
    final lines = _source.split('\n');
    if (oneBasedLine - 1 >= lines.length) return false;
    if (_carriesSuppression(lines[oneBasedLine - 1])) return true;
    // A marker on the comment-only line directly above counts too: a flagged
    // interpolation that already fills its line has no room for a trailing
    // reason, and moving the value into a local to make room would hide the
    // site from this lint instead of documenting it.
    if (oneBasedLine < 2) return false;
    final above = lines[oneBasedLine - 2].trimLeft();
    return above.startsWith('//') && _carriesSuppression(above);
  }

  static bool _carriesSuppression(String text) =>
      RegExp(r'//\s*harness-log-ok:\s*(\S.*)$').hasMatch(text);
}

/// Collects every [InterpolationExpression] in a subtree — reaching through
/// `AdjacentStrings` (multi-line concatenated literals), binary `+`
/// concatenation, ternaries, and nested string interpolations alike, since
/// this is a plain [RecursiveAstVisitor] rather than a single-literal walk.
class _InterpolationFinder extends RecursiveAstVisitor<void> {
  final List<InterpolationExpression> found = [];

  @override
  void visitInterpolationExpression(InterpolationExpression node) {
    found.add(node);
    super.visitInterpolationExpression(node);
  }
}

void main() {
  group('detector self-tests — positive fixtures (must flag)', () {
    void expectFlagged(String label, String source) {
      test(label, () {
        final r = findHarnessLogFindings(source);
        expect(
          r.findings,
          isNotEmpty,
          reason: 'expected a finding for: $source',
        );
      });
    }

    expectFlagged(
      'a suppression two lines above, or after code on the line above, '
      'does not exempt the site',
      'void f() {' '\n'
      '  // harness-log-ok: too far away' '\n'
      '  final x = 1;' '\n'
      r"  debugPrint('gid=$nostrGroupIdHex $x');" '\n}',
    );
    expectFlagged(
      'bare pubkey field in debugPrint',
      r"void f() { debugPrint('peer=$alicePubkeyHex'); }",
    );
    expectFlagged(
      'bare npub field in reason:',
      r"void f() { expect(1, 1, reason: 'npub=${alice.npub}'); }",
    );
    expectFlagged(
      'raw group-id hex field',
      r"void f() { debugPrint('gid=$nostrGroupIdHex'); }",
    );
    expectFlagged(
      'a raw .id field access',
      r"void f() { expect(1, 1, reason: 'id=${event.id}'); }",
    );
    expectFlagged(
      'raw latitude/longitude fields',
      r"void f() { debugPrint('lat=${loc.latitude} lon=${loc.longitude}'); }",
    );
    expectFlagged(
      'bare lat/lon word-boundary identifiers',
      r"void f() { expect(1, 1, reason: 'lat=$lat lon=$lon'); }",
    );
    expectFlagged(
      'a raw relay URL field',
      r"void f() { debugPrint('relay=$relayUrl'); }",
    );
    expectFlagged(
      'a raw Relay-typed value',
      r"void f() { expect(1, 1, reason: 'Relay $someRelay must ack'); }",
    );
    expectFlagged(
      // A bare `$name` identifier, not `${p.name}` — a property access
      // ending in `.name` is the documented enum-tag exemption (see the
      // negative fixture below), so the positive case for this vocabulary
      // term needs a shape that exemption does not reach.
      'a raw display name field',
      r"void f() { debugPrint('name=$name'); }",
    );
    expectFlagged(
      'a raw petname field',
      r"void f() { expect(1, 1, reason: 'petname=$petname'); }",
    );
    expectFlagged(
      // `.name` on a DATA receiver is user text, not the enum-tag idiom —
      // only a receiver whose decamelled tail is a classification word
      // (`outcome`, `tier`, …) is exempt (see the `tier.name` negative
      // fixture below).
      'a circle display name via .name is NOT the enum-tag idiom',
      r"void f() { expect(1, 1, reason: 'joined ${circle.name}'); }",
    );
    expectFlagged(
      'an absolute epoch number',
      r"void f() { debugPrint('epoch=$epoch'); }",
    );
    expectFlagged(
      // Case sensitivity must not create a loophole: `bobEpoch` carries a
      // mid-identifier capital E exactly like every `xEpochBeforeY`/
      // `xEpochAfterY` variable this file's own harness uses.
      'a mid-identifier capital E (bobEpoch) is not a case loophole',
      r"void f() { expect(1, 1, reason: 'e=${bobEpoch}'); }",
    );
    expectFlagged(
      "a relay's raw msg/message reason text",
      r"void f() { expect(1, 1, reason: 'relay said: $msg'); }",
    );
    expectFlagged(
      "a relay's raw rejection reason text",
      r"void f() { debugPrint('rejected: ${sample.rejection}'); }",
    );
    expectFlagged(
      'an absolute instant via toIso8601String()',
      r"void f() { debugPrint('at=${lastPublish.toIso8601String()}'); }",
    );
    expectFlagged(
      'an elapsed-from-wall-clock inMilliseconds read',
      r"void f() { expect(1, 1, reason: 'elapsed=${d.inMilliseconds}'); }",
    );
    expectFlagged(
      r'a bare $e raw-exception interpolation',
      r"void f() { debugPrint('failed: $e'); }",
    );
    expectFlagged(
      r'a braced ${e} raw-exception interpolation',
      r"void f() { expect(1, 1, reason: 'failed: ${e}'); }",
    );
    expectFlagged(
      'a .toString() rendering of an arbitrary object',
      r"void f() { debugPrint('val=${someObj.toString()}'); }",
    );
    expectFlagged(
      'print(...) is scanned the same as debugPrint(...)',
      r"void f() { print('leak: $aliceHex'); }",
    );
    expectFlagged(
      'fail(...) is scanned the same as debugPrint(...)',
      r"void f() { fail('leak: $aliceHex'); }",
    );
    expectFlagged(
      'a thrown StateError(...) is scanned like debugPrint(...) — a '
      "flutter drive log carries an uncaught exception's toString() too",
      r"void f() { throw StateError('relay=$relayUrl'); }",
    );
    expectFlagged(
      'a multi-line adjacent-string literal carries the interpolation in '
      'its second segment',
      r'''
void f() {
  debugPrint(
    'circle relay must observe zero for '
    '$relayUrl',
  );
}
''',
    );
    expectFlagged(
      'a suppression comment with no reason text does not exempt it',
      r"void f() { debugPrint('gid=$nostrGroupIdHex'); // harness-log-ok:" '\n}',
    );
  });

  group('detector self-tests — negative fixtures (must NOT flag)', () {
    void expectClean(String label, String source) {
      test(label, () {
        final r = findHarnessLogFindings(source);
        expect(
          r.findings,
          isEmpty,
          reason: 'unexpected finding(s) in: $source',
        );
      });
    }

    expectClean(
      'a pubkey wrapped in logAliasHandle',
      r"void f() { debugPrint('peer=${logAliasHandle(LogAliasClass.peer, "
      "alicePubkeyHex)}'); }",
    );
    expectClean(
      'an npub wrapped in logAliasHandle',
      'void f() { expect(1, 1, reason: '
      r"'npub=${logAliasHandle(LogAliasClass.peer, aliceNpub)}'); }",
    );
    expectClean(
      'a group id wrapped in logAliasHandle',
      r"void f() { debugPrint('gid=${logAliasHandle(LogAliasClass.circle, "
      "nostrGroupIdHex)}'); }",
    );
    expectClean(
      'an event id wrapped in logAliasHandle',
      'void f() { expect(1, 1, reason: '
      r"'id=${logAliasHandle(LogAliasClass.event, event.id)}'); }",
    );
    expectClean(
      'coordinates never printed — only a boolean tolerance verdict',
      r"void f() { debugPrint('within tolerance: ${diff < eps}'); }",
    );
    expectClean(
      'a relay URL wrapped in logAliasHandle',
      r"void f() { debugPrint('relay=${logAliasHandle(LogAliasClass.relay, "
      "relayUrl)}'); }",
    );
    expectClean(
      'a display name wrapped in logAliasHandle',
      r"void f() { debugPrint('name=${logAliasHandle(LogAliasClass.peer, "
      "displayName)}'); }",
    );
    expectClean(
      'an absolute instant replaced by relativeSecs',
      r"void f() { debugPrint('at=${relativeSecs(origin, lastPublish)}'); }",
    );
    expectClean(
      'a millisecond duration replaced by magnitudeBucket',
      'void f() { expect(1, 1, reason: '
      r"'elapsed=${magnitudeBucket(d.inMilliseconds)}'); }",
    );
    expectClean(
      'a raw exception reduced to its runtimeType',
      r"void f() { debugPrint('failed: ${e.runtimeType}'); }",
    );
    expectClean(
      'an enum tag via .name is the documented exemption',
      r"void f() { debugPrint('tier=${tier.name}'); }",
    );
    expectClean(
      'a count reduced to magnitudeBucket',
      r"void f() { debugPrint('count=${magnitudeBucket(n)}'); }",
    );
    expectClean(
      'an epoch delta reduced to magnitudeBucket',
      r"void f() { debugPrint('delta=${magnitudeBucket(epochDelta)}'); }",
    );
    expectClean(
      'a suppression comment with a reason exempts an otherwise-flagged line',
      r"void f() { debugPrint('gid=$nostrGroupIdHex'); "
      '// harness-log-ok: test fixture, reviewed' '\n}',
    );
    expectClean(
      'a suppression comment on the comment-only line above exempts the site',
      'void f() {' '\n'
      '  // harness-log-ok: test fixture, reviewed' '\n'
      r"  debugPrint('gid=$nostrGroupIdHex');" '\n}',
    );
    expectClean(
      'a message with no interpolation at all',
      "void f() { debugPrint('generic message with no interpolation at "
      "all'); }",
    );
    expectClean(
      'an unrelated word that happens to share no vocabulary substring',
      r"void f() { debugPrint('step=$stepIndex'); }",
    );
    expectClean(
      'a thrown FormatException(...) reduced to runtimeType is clean',
      r"void f() { throw FormatException('failed: ${e.runtimeType}'); }",
    );
    expectClean(
      // The documented named-constructor gap: a NAMED constructor
      // (`Foo.value(`) parses with a non-null target, so it never matches
      // `_scannedCallNames`'s `target == null` check — this pins the gap
      // as empty (never used in the real tree) rather than an assumption.
      'ArgumentError.value( is the documented named-constructor gap',
      "void f() { throw ArgumentError.value(npub, 'npub', 'bad'); }",
    );
  });

  group('the real integration_test/ tree', () {
    test('no harness log site carries an unredacted identifier', () {
      final dir = Directory('integration_test');
      expect(
        dir.existsSync(),
        isTrue,
        reason: 'Expected to run from the haven package root '
            '(cwd=${Directory.current.path}).',
      );

      final findings = <HarnessLogFinding>[];
      var filesScanned = 0;
      var sitesScanned = 0;
      for (final entity in dir.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        filesScanned++;
        final r = findHarnessLogFindings(
          entity.readAsStringSync(),
          path: entity.path,
        );
        findings.addAll(r.findings);
        sitesScanned += r.sitesScanned;
      }

      // Anti-vacuity floor: measured 43 files under `integration_test/` on
      // 2026-09-13 (Phase 0c) — floor = measured − 2, so a moved directory
      // or a silently-broken glob cannot pass by scanning nothing.
      expect(
        filesScanned,
        greaterThanOrEqualTo(41),
        reason: 'Only scanned $filesScanned files — the integration_test/ '
            'glob looks broken.',
      );
      // Re-measured 2026-09-17 (H6 security-review pass): 841 sites;
      // floor(841 × 0.8) = 672, so a regression that stops scanning the
      // constructors does not go undetected.
      expect(
        sitesScanned,
        greaterThanOrEqualTo(672),
        reason: 'Only found $sitesScanned debugPrint/print/fail/reason: '
            'sites — far fewer than expected. Has the call shape changed, '
            'or has the detector gone blind?',
      );

      final bulletList = findings.map((f) => '  • $f').join('\n');
      expect(
        findings,
        isEmpty,
        reason:
            'Harness log site(s) carrying an unredacted identifier '
            '(Security Rule 15):\n$bulletList\n\n'
            'Route the value through '
            'logAliasHandle/magnitudeBucket/relativeSecs, reduce it to '
            '.runtimeType/.name, or add a // harness-log-ok: <reason> '
            'suppression with a real reason.',
      );
    });
  });
}
