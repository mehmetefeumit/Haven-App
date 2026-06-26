// Static guard against integration tests whose failures never fail the build.
//
// Flutter's `flutter drive` + `integrationDriver()` model reports a target as
// PASS based solely on `IntegrationTestWidgetsFlutterBinding.results`. That map
// is written in exactly two places (see
// flutter/packages/integration_test/lib/integration_test.dart):
//   * line 238 — `results[description] ??= _success`, inside the binding's
//     `runTest()` override, which ONLY `testWidgets()` invokes; and
//   * line 90  — `reportTestException`, the flutter_test hook that ONLY a
//     `testWidgets()` body routes through.
// A plain `test()` from package:test_api touches neither, so its failure never
// enters `results`; `tearDownAll` then computes
// `allTestsPassed = failureMethodsDetails.isEmpty == true`, `integrationDriver`
// prints "All tests passed." and `exit(0)`, and the CI runner marks the target
// PASS. The device reporter shows "+N -M Some tests failed" but that signal
// never reaches the host. (Worse: `Response.toJson` only serializes failures,
// never the success count — so a driver-side "non-empty results" backstop is
// impossible; the fix MUST be that every test is a `testWidgets`.)
//
// The same gap swallows `expect()` inside `setUpAll`/`tearDownAll`: those
// callbacks run outside `runTest`, so a failed precondition assertion there is
// invisible to `results`. Load-bearing non-vacuity guards therefore belong in
// test bodies, not in group setup/teardown.
//
// This guard, run inside the ordinary `flutter test` gate, fails fast and
// emulator-free if any file under `integration_test/`:
//   1. declares a test with bare `test(...)` instead of `testWidgets(...)`;
//   2. asserts with `expect`/`expectLater` inside `setUpAll`/`tearDownAll`; or
//   3. declares tests but never calls
//      `IntegrationTestWidgetsFlutterBinding.ensureInitialized()`.
//
// Per-test `setUp`/`tearDown` are intentionally NOT flagged: they run inside the
// surrounding test's `runTest` invocation, so an assertion failure there DOES
// propagate. Only the group-level `setUpAll`/`tearDownAll` run outside `runTest`
// and are swallowed.
//
// The detector is unit-tested below so it cannot rot into a vacuous pass.
@TestOn('vm')
library;

import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('integration-test propagation detector', () {
    test('flags a bare test() declaration', () {
      const source = '''
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  test('does a thing', () async {
    expect(1, 1);
  });
}
''';
      final v = findPropagationViolations(source);
      expect(v.where((x) => x.kind == 'bare-test'), hasLength(1));
    });

    test('accepts testWidgets() declarations', () {
      const source = '''
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('does a thing', (tester) async {
    expect(1, 1);
  });
}
''';
      expect(findPropagationViolations(source), isEmpty);
    });

    test('does not confuse markTestSkipped/groupX/identifiers with test()', () {
      const source = '''
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('x', (tester) async {
    markTestSkipped('nope');
    final forTest = 1;
    obj.test();
    expect(forTest, 1);
  });
}
''';
      expect(findPropagationViolations(source), isEmpty);
    });

    test('flags expect() inside setUpAll', () {
      const source = '''
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await boot();
    expect(isDefault('r1'), isTrue);
  });
  testWidgets('x', (tester) async {
    expect(1, 1);
  });
}
''';
      final v = findPropagationViolations(source);
      expect(v.where((x) => x.kind == 'assert-in-setup'), hasLength(1));
    });

    test('flags expectLater() inside tearDownAll', () {
      const source = '''
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('x', (tester) async {
    expect(1, 1);
  });
  tearDownAll(() async {
    await expectLater(cleanup(), completes);
  });
}
''';
      final v = findPropagationViolations(source);
      expect(v.where((x) => x.kind == 'assert-in-setup'), hasLength(1));
    });

    test('allows non-assert work in setUpAll/tearDownAll', () {
      const source = '''
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await RustLib.init();
    await useInMemoryKeyringForTest();
  });
  testWidgets('x', (tester) async {
    expect(1, 1);
  });
  tearDownAll(() async {
    await disposeEverything();
  });
}
''';
      expect(findPropagationViolations(source), isEmpty);
    });

    test('flags a file that declares tests but never inits the binding', () {
      const source = '''
void main() {
  testWidgets('x', (tester) async {
    expect(1, 1);
  });
}
''';
      final v = findPropagationViolations(source);
      expect(v.where((x) => x.kind == 'missing-binding-init'), hasLength(1));
    });

    test('does not require binding init in a file with no tests', () {
      const source = '''
class Helper {
  void run() {}
}
''';
      expect(findPropagationViolations(source), isEmpty);
    });
  });

  group('repository scan', () {
    test('every integration_test/ file propagates failures to the driver', () {
      final dir = Directory('integration_test');
      expect(
        dir.existsSync(),
        isTrue,
        reason: 'Expected to run from the haven package root '
            '(cwd=${Directory.current.path}).',
      );

      final violations = <PropagationViolation>[];
      var scanned = 0;
      for (final entity in dir.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        scanned++;
        violations.addAll(
          findPropagationViolations(
            entity.readAsStringSync(),
            path: entity.path,
          ),
        );
      }

      expect(
        scanned,
        greaterThan(5),
        reason: 'Only scanned $scanned files — the integration_test/ glob '
            'looks broken.',
      );

      expect(
        violations,
        isEmpty,
        reason: 'Integration test(s) whose failures would NOT fail the build '
            '(see this file for the mechanism):\n'
            '${violations.map((v) => '  • $v').join('\n')}\n\n'
            'Use testWidgets() (never bare test()); move precondition '
            'expect()/expectLater() out of setUpAll/tearDownAll into a test '
            'body; and call '
            'IntegrationTestWidgetsFlutterBinding.ensureInitialized().',
      );
    });
  });
}

/// A single propagation hazard in an integration-test file.
class PropagationViolation {
  PropagationViolation({
    required this.path,
    required this.line,
    required this.kind,
    required this.detail,
  });

  final String path;
  final int line;

  /// One of: `bare-test`, `assert-in-setup`, `missing-binding-init`.
  final String kind;
  final String detail;

  @override
  String toString() => '$path:$line  [$kind] $detail';
}

/// Parses [source] and returns every way a genuine failure in this
/// integration-test file could fail to fail the build.
List<PropagationViolation> findPropagationViolations(
  String source, {
  String path = '<memory>',
}) {
  final result = parseString(content: source, throwIfDiagnostics: false);
  final lineInfo = result.lineInfo;
  final visitor = _PropagationVisitor(lineInfo, path);
  result.unit.accept(visitor);

  final out = <PropagationViolation>[...visitor.violations];

  // A file that declares tests but never initializes the integration binding
  // reports nothing to the driver at all.
  if (visitor.declaresTests && !visitor.initsBinding) {
    out.add(
      PropagationViolation(
        path: path,
        line: visitor.firstTestLine,
        kind: 'missing-binding-init',
        detail: 'declares tests but never calls '
            'IntegrationTestWidgetsFlutterBinding.ensureInitialized()',
      ),
    );
  }
  return out;
}

class _PropagationVisitor extends RecursiveAstVisitor<void> {
  _PropagationVisitor(this._lineInfo, this._path);

  final LineInfo _lineInfo;
  final String _path;

  final List<PropagationViolation> violations = [];
  bool declaresTests = false;
  bool initsBinding = false;
  int firstTestLine = 1;

  int _lineOf(int offset) => _lineInfo.getLocation(offset).lineNumber;

  bool _isBareCall(MethodInvocation node, Set<String> names) =>
      node.target == null && names.contains(node.methodName.name);

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final name = node.methodName.name;

    if (name == 'ensureInitialized' &&
        node.target is SimpleIdentifier &&
        (node.target! as SimpleIdentifier).name ==
            'IntegrationTestWidgetsFlutterBinding') {
      initsBinding = true;
    }

    if (_isBareCall(node, const {'test', 'testWidgets'})) {
      declaresTests = true;
      final line = _lineOf(node.offset);
      if (violations.isEmpty || line < firstTestLine) firstTestLine = line;
    }

    if (_isBareCall(node, const {'test'})) {
      violations.add(
        PropagationViolation(
          path: _path,
          line: _lineOf(node.offset),
          kind: 'bare-test',
          detail: 'bare test() — its failure is never recorded in the '
              'integration binding; use testWidgets()',
        ),
      );
    }

    if (_isBareCall(node, const {'setUpAll', 'tearDownAll'})) {
      _flagAssertsIn(node, name);
    }

    super.visitMethodInvocation(node);
  }

  /// Records every `expect`/`expectLater` lexically inside a
  /// `setUpAll`/`tearDownAll` callback — those run outside `runTest`, so the
  /// assertion failure is swallowed by the driver.
  void _flagAssertsIn(MethodInvocation setupCall, String setupName) {
    final finder = _AssertFinder();
    setupCall.argumentList.accept(finder);
    for (final assertCall in finder.asserts) {
      violations.add(
        PropagationViolation(
          path: _path,
          line: _lineOf(assertCall.offset),
          kind: 'assert-in-setup',
          detail: '${assertCall.methodName.name}() inside $setupName — a '
              'failed precondition here is swallowed; move it into a test body',
        ),
      );
    }
  }
}

class _AssertFinder extends RecursiveAstVisitor<void> {
  final List<MethodInvocation> asserts = [];

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (node.target == null &&
        const {'expect', 'expectLater'}.contains(node.methodName.name)) {
      asserts.add(node);
    }
    super.visitMethodInvocation(node);
  }
}
