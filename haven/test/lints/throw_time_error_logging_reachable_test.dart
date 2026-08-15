// Static guard: every integration `testWidgets` body installs throw-time
// `FlutterError` attribution.
//
// ## The defect class this catches
//
// `integration_test/e2e/_lib/throw_time_error_capture.dart` exists because
// `IntegrationTestWidgetsFlutterBinding.reportExceptionNoticed` — the SDK's
// only throw-time hook — is a no-op (upstream flutter#81534), and the
// deferred end-of-test report resolves `FlutterErrorDetails.toString()`
// lazily, after the offending element may already be torn down: a layout
// overflow degrades to the bare "A RenderFlex overflowed by…" sentence with
// no widget name and no file:line (see that file's doc comment for the exact
// SDK mechanism, cited by source file:line). `installThrowTimeErrorLogging`
// recovers the attribution — but only in the tests that actually call it.
// "Written but reached by nothing" is this codebase's most common way for a
// guarantee to quietly stop holding (see
// `test/lints/announcement_keys_reachable_test.dart`,
// `test/lints/integration_test_propagation_test.dart` for the same class of
// bug elsewhere) — so this pins reachability the same way those do: an AST
// scan of the real tree, self-tested against known-bad and known-good
// snippets first, with an anti-vacuity floor so it cannot pass by having
// gone blind.
//
// ## What counts as "installed"
//
// A call to `installThrowTimeErrorLogging` OR `installChainedThrowTimeHandler`
// (the pure mechanism the former wraps) anywhere inside the `testWidgets`
// callback's AST subtree — not necessarily the first statement, so a
// `testWidgets` call whose callback forwards to another closure that installs
// it (see `boundedTestWidgets` in `integration_test/e2e/e2e_combined.dart`,
// which installs once in its own wrapper rather than at each of its 9
// callers) still counts as covered. What does NOT count: the name mentioned
// only in a comment or a string, or a `testWidgets` call whose callback is a
// bare identifier reference with no inline closure to search at all — the
// same two traps `announcement_keys_reachable_test.dart` guards against, plus
// a third specific to this shape.
//
// ## Two more ways to be blind that a rename or a new import can trigger
//
// `testWidgets(...)` reached through an import prefix (`ft.testWidgets(...)`
// for `import 'package:flutter_test/flutter_test.dart' as ft;`) is one
// keystroke away from the bare form above, so [_isTestWidgetsCall] checks it
// the same way rather than treating it as invisible: missing it would not
// just mis-check that one call — `count` never increments for it either, so
// the anti-vacuity floor below could go blind on a whole file without ever
// failing. Separately, [_isUnrecognizedTesterMacro] traps a DIFFERENTLY-NAMED
// test-declaring macro this lint has never heard of (a hypothetical Patrol
// `patrolTest`, say) — narrowly, on purpose; see its doc comment for exactly
// how narrow and why.
@TestOn('vm')
library;

import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:flutter_test/flutter_test.dart';

const Set<String> _installerNames = {
  'installThrowTimeErrorLogging',
  'installChainedThrowTimeHandler',
};

/// True for a call this lint recognises as declaring a widget test: the bare
/// `testWidgets(...)` used throughout this repo today, or the same call
/// reached through an import prefix (`ft.testWidgets(...)`). The two shapes
/// parse identically apart from the target — `null` for the bare call,
/// a bare [SimpleIdentifier] for the prefixed one (never a
/// [PrefixedIdentifier]: that shape is for a TWO-dot target like
/// `frb_api.CircleManagerFfi`, one dot further out than an import prefix
/// directly in front of a call gets).
bool _isTestWidgetsCall(MethodInvocation node) {
  if (node.methodName.name != 'testWidgets') return false;
  final target = node.target;
  return target == null || target is SimpleIdentifier;
}

/// A best-effort, deliberately narrow trap for a DIFFERENTLY-NAMED
/// test-declaring macro this lint has never heard of (a hypothetical Patrol
/// `patrolTest`, say): a call used as its own statement whose sole callback
/// explicitly types its one parameter `WidgetTester` looks like a test
/// declaration structurally, not by name — so unlike [_isTestWidgetsCall]
/// this cannot be defeated by a rename.
///
/// Deliberately narrow, for a reason that cannot be worked around here:
/// `parseString` performs no type INFERENCE, only sees what is written, so
/// this fires only when the annotation is explicit. Every closure literal in
/// this tree today leaves its parameter untyped (`(tester) async {...}`) —
/// including every `boundedTestWidgets` call site, which is a genuine
/// top-level statement with a one-parameter callback and would otherwise be
/// the obvious false positive here — so this cannot misfire on existing code
/// (checked below against the real tree). The flip side is real too: it
/// cannot catch a future macro that follows that same untyped convention, or
/// one typed against a `WidgetTester` SUBTYPE (Patrol's own tester type,
/// concretely) rather than the base class by name. Closing either needs
/// semantic resolution this AST-only lint does not have; closing the
/// explicitly-typed case anyway is still worth it, since it is sound today
/// and costs nothing to keep.
bool _isUnrecognizedTesterMacro(MethodInvocation node) {
  if (node.methodName.name == 'testWidgets') return false;
  if (node.parent is! ExpressionStatement) return false;
  for (final arg in node.argumentList.arguments) {
    if (arg is! FunctionExpression) continue;
    final params = arg.parameters?.parameters;
    if (params == null || params.length != 1) continue;
    final type = switch (params.single) {
      SimpleFormalParameter(:final type?) => type,
      _ => null,
    };
    if (type is NamedType && type.name.lexeme == 'WidgetTester') return true;
  }
  return false;
}

/// A single `testWidgets` call whose callback does not install throw-time
/// error logging anywhere in its body — or a call to an unrecognised
/// test-declaring macro this lint cannot check at all (see
/// [_isUnrecognizedTesterMacro]).
class UninstrumentedTestWidgets {
  UninstrumentedTestWidgets({
    required this.path,
    required this.line,
    required this.reason,
  });

  final String path;
  final int line;
  final String reason;

  @override
  String toString() => '$path:$line  $reason';
}

/// Parses [source] and returns every `testWidgets` call (see
/// [_isTestWidgetsCall]) whose callback does not reach an [_installerNames]
/// call, plus any [_isUnrecognizedTesterMacro] match. Also returns the number
/// of `testWidgets` bodies found, so callers can enforce an anti-vacuity
/// floor.
({List<UninstrumentedTestWidgets> violations, int testWidgetsCount})
findUninstrumentedTestWidgets(String source, {String path = '<memory>'}) {
  final result = parseString(content: source, throwIfDiagnostics: false);
  final lineInfo = result.lineInfo;
  final visitor = _TestWidgetsVisitor(lineInfo, path);
  result.unit.accept(visitor);
  return (violations: visitor.violations, testWidgetsCount: visitor.count);
}

class _TestWidgetsVisitor extends RecursiveAstVisitor<void> {
  _TestWidgetsVisitor(this._lineInfo, this._path);

  final LineInfo _lineInfo;
  final String _path;

  final List<UninstrumentedTestWidgets> violations = [];
  int count = 0;

  int _lineOf(int offset) => _lineInfo.getLocation(offset).lineNumber;

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (_isTestWidgetsCall(node)) {
      count++;
      final callbacks = node.argumentList.arguments
          .whereType<FunctionExpression>()
          .toList();
      if (callbacks.isEmpty) {
        violations.add(
          UninstrumentedTestWidgets(
            path: _path,
            line: _lineOf(node.offset),
            reason: 'testWidgets callback is not an inline closure (a bare '
                'identifier forward) — reachability cannot be verified here; '
                'either give it an inline closure that installs throw-time '
                'logging, or install it inside the function it forwards to',
          ),
        );
      } else {
        for (final callback in callbacks) {
          if (!_installsThrowTimeLogging(callback)) {
            violations.add(
              UninstrumentedTestWidgets(
                path: _path,
                line: _lineOf(node.offset),
                reason: 'testWidgets body never calls '
                    '${_installerNames.join(' or ')} — a layout overflow '
                    'here will be unattributable in the drive log',
              ),
            );
          }
        }
      }
    } else if (_isUnrecognizedTesterMacro(node)) {
      violations.add(
        UninstrumentedTestWidgets(
          path: _path,
          line: _lineOf(node.offset),
          reason: 'unrecognized call to `${node.methodName.name}` whose sole '
              'callback explicitly types its parameter `WidgetTester` — this '
              'reads as a test-declaring macro this lint does not know how '
              'to check for throw-time error logging; teach '
              '_isTestWidgetsCall the new shape rather than let it pass '
              'unseen',
        ),
      );
    }
    super.visitMethodInvocation(node);
  }

  bool _installsThrowTimeLogging(FunctionExpression callback) {
    final finder = _InstallerCallFinder();
    callback.body.accept(finder);
    return finder.found;
  }
}

/// Finds a bare call to one of [_installerNames] anywhere in the subtree.
///
/// AST-based, not textual: `visitComment`/`visitCommentReference` are
/// deliberately left unvisited (the default `RecursiveAstVisitor` behaviour
/// already skips them for `visitMethodInvocation`), so a doc comment
/// promising the call happens can never satisfy this the way it promises.
/// A string literal naming the function is likewise not a `MethodInvocation`
/// and cannot match either.
class _InstallerCallFinder extends RecursiveAstVisitor<void> {
  bool found = false;

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (node.target == null && _installerNames.contains(node.methodName.name)) {
      found = true;
    }
    super.visitMethodInvocation(node);
  }
}

void main() {
  group('detector self-tests', () {
    test('accepts a body that installs as its first statement', () {
      const source = '''
void main() {
  testWidgets('x', (tester) async {
    installThrowTimeErrorLogging();
    expect(1, 1);
  });
}
''';
      final r = findUninstrumentedTestWidgets(source);
      expect(r.violations, isEmpty);
      expect(r.testWidgetsCount, 1);
    });

    test('flags a body that never installs it', () {
      const source = '''
void main() {
  testWidgets('x', (tester) async {
    expect(1, 1);
  });
}
''';
      final r = findUninstrumentedTestWidgets(source);
      expect(r.violations, hasLength(1));
    });

    test('does not count a mention in a doc comment as installed', () {
      // The trap this guard exists to avoid: the comment that promises the
      // call happens must not be what proves it does.
      const source = '''
void main() {
  testWidgets('x', (tester) async {
    // TODO: installThrowTimeErrorLogging();
    expect(1, 1);
  });
}
''';
      final r = findUninstrumentedTestWidgets(source);
      expect(r.violations, hasLength(1));
    });

    test('does not count a mention inside a string literal as installed', () {
      const source = '''
void main() {
  testWidgets('x', (tester) async {
    debugPrint('remember to call installThrowTimeErrorLogging');
    expect(1, 1);
  });
}
''';
      final r = findUninstrumentedTestWidgets(source);
      expect(r.violations, hasLength(1));
    });

    test('finds the call nested inside a forwarded inner closure', () {
      // Mirrors `boundedTestWidgets` in e2e_combined.dart: the install call
      // sits inside an inline closure passed to `testWidgets`, one level
      // removed from the literal callback body, not as the closure's own
      // first line but still inside its AST subtree.
      const source = '''
void boundedTestWidgets(String description, Function callback) {
  testWidgets(description, (tester) async {
    installThrowTimeErrorLogging();
    await callback(tester);
  });
}
''';
      final r = findUninstrumentedTestWidgets(source);
      expect(r.violations, isEmpty);
      expect(r.testWidgetsCount, 1);
    });

    test('flags a bare-identifier callback with no inline closure', () {
      const source = '''
void wrapper(String description, Function callback) {
  testWidgets(description, callback);
}
''';
      final r = findUninstrumentedTestWidgets(source);
      expect(r.violations, hasLength(1));
      expect(r.violations.single.reason, contains('bare identifier forward'));
    });

    test(
      'accepts installChainedThrowTimeHandler as an alternative install',
      () {
        const source = '''
void main() {
  testWidgets('x', (tester) async {
    final restore = installChainedThrowTimeHandler();
    addTearDown(restore);
    expect(1, 1);
  });
}
''';
        final r = findUninstrumentedTestWidgets(source);
        expect(r.violations, isEmpty);
      },
    );

    test(
      'a testWidgets call reached through an import prefix is checked, not '
      'invisible — the exact shape `ft.testWidgets(...)` would take for '
      "import 'package:flutter_test/flutter_test.dart' as ft;",
      () {
        const source = '''
void main() {
  ft.testWidgets('x', (tester) async {
    expect(1, 1);
  });
}
''';
        final r = findUninstrumentedTestWidgets(source);
        expect(
          r.testWidgetsCount,
          1,
          reason: 'a prefixed call must still count toward the anti-vacuity '
              'floor, not just toward the violations list',
        );
        expect(r.violations, hasLength(1));
      },
    );

    test(
      'a prefixed testWidgets call that does install throw-time logging is '
      'accepted, exactly like the bare form',
      () {
        const source = '''
void main() {
  ft.testWidgets('x', (tester) async {
    installThrowTimeErrorLogging();
    expect(1, 1);
  });
}
''';
        final r = findUninstrumentedTestWidgets(source);
        expect(r.testWidgetsCount, 1);
        expect(r.violations, isEmpty);
      },
    );

    test(
      'an ordinary call to an unrelated method is never flagged, prefixed '
      'or not — only the two recognised shapes are',
      () {
        const source = '''
void main() {
  someHelper.configure('x', (tester) async {
    expect(1, 1);
  });
  anotherHelper('y', (tester) async {
    expect(1, 1);
  });
}
''';
        final r = findUninstrumentedTestWidgets(source);
        expect(r.testWidgetsCount, 0);
        expect(r.violations, isEmpty);
      },
    );

    test(
      'an unrecognised macro whose callback explicitly types WidgetTester '
      'is flagged by name, naming the unrecognised construct — the shape a '
      'hypothetical Patrol patrolTest(...) would take',
      () {
        const source = '''
void main() {
  patrolTest('x', (WidgetTester tester) async {
    expect(1, 1);
  });
}
''';
        final r = findUninstrumentedTestWidgets(source);
        expect(
          r.testWidgetsCount,
          0,
          reason: 'an unrecognised macro is reported as its own violation, '
              'not folded into the testWidgets count it did not earn',
        );
        expect(r.violations, hasLength(1));
        expect(r.violations.single.reason, contains('patrolTest'));
      },
    );

    test(
      'a genuine boundedTestWidgets-style call site — a top-level call with '
      'a one-parameter closure, the obvious false positive for the '
      'unrecognised-macro trap — is not flagged because its parameter is, '
      'like every real call site in this tree, left untyped',
      () {
        const source = '''
void main() {
  boundedTestWidgets('x', (tester) async {
    installThrowTimeErrorLogging();
    expect(1, 1);
  });
}
''';
        final r = findUninstrumentedTestWidgets(source);
        expect(r.violations, isEmpty);
      },
    );

    test(
      'an explicitly WidgetTester-typed closure that is NOT its own '
      'statement (assigned to a variable rather than called bare) is not '
      'flagged — the unrecognised-macro trap is scoped to top-level calls '
      'only',
      () {
        const source = '''
void main() {
  final callback = makeCallback((WidgetTester tester) async {
    expect(1, 1);
  });
}
''';
        final r = findUninstrumentedTestWidgets(source);
        expect(r.violations, isEmpty);
      },
    );
  });

  group('the real integration_test/ tree', () {
    test('every testWidgets body installs throw-time error logging', () {
      final dir = Directory('integration_test');
      expect(
        dir.existsSync(),
        isTrue,
        reason: 'Expected to run from the haven package root '
            '(cwd=${Directory.current.path}).',
      );

      final violations = <UninstrumentedTestWidgets>[];
      var filesScanned = 0;
      var testWidgetsScanned = 0;
      for (final entity in dir.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        filesScanned++;
        final r = findUninstrumentedTestWidgets(
          entity.readAsStringSync(),
          path: entity.path,
        );
        violations.addAll(r.violations);
        testWidgetsScanned += r.testWidgetsCount;
      }

      // Anti-vacuity: if the glob or the AST match ever silently stopped
      // finding files/tests, this guard would start passing on nothing.
      expect(
        filesScanned,
        greaterThan(20),
        reason: 'Only scanned $filesScanned files — the integration_test/ '
            'glob looks broken.',
      );
      expect(
        testWidgetsScanned,
        greaterThanOrEqualTo(40),
        reason: 'Only found $testWidgetsScanned testWidgets bodies — far '
            'fewer than expected. Has the call shape changed, or has the '
            'detector gone blind?',
      );

      expect(
        violations,
        isEmpty,
        reason:
            'Integration testWidgets body(ies) with no throw-time error '
            'attribution (a future layout overflow here would be '
            'unattributable in the drive log):\n'
            '${violations.map((v) => '  • $v').join('\n')}\n\n'
            'Call installThrowTimeErrorLogging() inside the testWidgets '
            'body (or install it once in a wrapper every caller reaches — '
            'see boundedTestWidgets in integration_test/e2e/e2e_combined.dart).',
      );
    });
  });
}
