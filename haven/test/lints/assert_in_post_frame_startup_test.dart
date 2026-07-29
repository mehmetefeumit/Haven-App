// Static guard against an `assert` that can ABORT a deferred startup
// sequence — the bug class that reddened the iOS live-sync e2e lane.
//
// What happened: `_MapShellState.initState` registered an
// `addPostFrameCallback` whose body asserted the AppRouter identity
// invariant and then, below that assert, did all of the app's startup work
// — relay init, KeyPackage publish, the location publisher, the maintenance
// scheduler and `_startLiveSync()`.
//
// Asserts are live in debug and profile builds, and in every integration
// test. So when one transient secure-storage read returned null (an iOS
// Keychain entry written with `first_unlock_this_device` can read back null
// while protected data is briefly unavailable), the assert threw and every
// statement after it was skipped. The app kept running with NO receive plane
// for the rest of the session, and the e2e scenario failed 20 s later on an
// unrelated "peer location never surfaced" timeout that pointed nowhere near
// the real cause.
//
// The fix is to treat the violated invariant as a diagnostic + recovery path
// (log it, re-arm, then run startup once) rather than a throw sitting in the
// middle of essential work — which is what `map_shell.dart` now does.
//
// This test closes the gap with a fast, emulator-free analysis inside the
// existing `flutter test` gate: it parses every file under `lib/` and flags
// any `assert` inside an `addPostFrameCallback` closure that still has work
// after it. An assert in tail position is harmless (nothing left to skip) and
// is deliberately allowed.
//
// The detector is unit-tested below against known-buggy and known-safe
// snippets so it cannot silently rot into a vacuous pass.
@TestOn('vm')
library;

import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:flutter_test/flutter_test.dart';

/// One flagged `assert` that can abort work queued after it.
class _Violation {
  const _Violation(this.line, this.snippet);

  final int line;
  final String snippet;

  @override
  String toString() => 'line $line: $snippet';
}

/// Finds `assert`s inside `addPostFrameCallback` closures that are followed by
/// further statements in the same closure.
class _AbortingAssertVisitor extends RecursiveAstVisitor<void> {
  _AbortingAssertVisitor(this._lineInfo);

  final LineInfo _lineInfo;
  final List<_Violation> violations = <_Violation>[];

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (node.methodName.name == 'addPostFrameCallback') {
      for (final arg in node.argumentList.arguments) {
        if (arg is FunctionExpression) {
          final body = arg.body;
          if (body is BlockFunctionBody) {
            _scanBlock(body.block);
          }
        }
      }
    }
    super.visitMethodInvocation(node);
  }

  /// Flags every `assert` in [block] that is not the final statement, then
  /// recurses into nested blocks (an assert inside an `if` still aborts the
  /// statements that follow the `if`).
  void _scanBlock(Block block) {
    final statements = block.statements;
    for (var i = 0; i < statements.length; i++) {
      final statement = statements[i];
      final isLast = i == statements.length - 1;
      if (statement is AssertStatement && !isLast) {
        violations.add(
          _Violation(
            _lineInfo.getLocation(statement.offset).lineNumber,
            statement.toSource(),
          ),
        );
      }
      // An assert nested inside control flow aborts the tail just the same,
      // unless the whole construct is itself in tail position.
      if (statement is! AssertStatement && !(isLast && statements.length == 1)) {
        statement.accept(_NestedBlockScanner(this));
      }
    }
  }
}

/// Walks into nested blocks of a statement so a guarded `assert` (inside an
/// `if`/`try`/loop) is still seen — but never crosses into another
/// `addPostFrameCallback`, which the outer visitor handles on its own.
class _NestedBlockScanner extends RecursiveAstVisitor<void> {
  _NestedBlockScanner(this._owner);

  final _AbortingAssertVisitor _owner;

  @override
  void visitBlock(Block node) {
    _owner._scanBlock(node);
    super.visitBlock(node);
  }
}

/// Returns every aborting-assert violation in [source].
List<_Violation> findAbortingAsserts(String source) {
  final parsed = parseString(content: source, throwIfDiagnostics: false);
  final visitor = _AbortingAssertVisitor(parsed.lineInfo);
  parsed.unit.accept(visitor);
  return visitor.violations;
}

void main() {
  group('aborting-assert detector', () {
    test('flags an assert with startup work after it', () {
      const source = '''
class _S {
  void initState() {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await ref.read(identityProvider.future);
      assert(ref.read(identityProvider).valueOrNull != null, 'gate failed');
      await relay.initialize();
      unawaited(_startLiveSync());
    });
  }
}
''';
      final found = findAbortingAsserts(source);
      expect(found, hasLength(1));
      expect(found.single.snippet, contains('gate failed'));
    });

    test('allows an assert in tail position (nothing left to skip)', () {
      const source = '''
class _S {
  void initState() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _doAllTheWork();
      assert(_invariantHolds(), 'checked last');
    });
  }
}
''';
      expect(findAbortingAsserts(source), isEmpty);
    });

    test('flags an assert nested in an if when work follows', () {
      const source = '''
class _S {
  void initState() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        assert(identity != null, 'gate failed');
        _startEngine();
      }
      _more();
    });
  }
}
''';
      expect(findAbortingAsserts(source), hasLength(1));
    });

    test('ignores asserts outside a post-frame callback', () {
      const source = '''
class _S {
  void build() {
    assert(debugCheckHasMaterial(context), 'needs Material');
    return const SizedBox();
  }
}
''';
      expect(findAbortingAsserts(source), isEmpty);
    });
  });

  group('repository scan', () {
    test(
      'no assert can abort a post-frame startup sequence anywhere in lib/',
      () {
        final libDir = Directory('lib');
        expect(
          libDir.existsSync(),
          isTrue,
          reason: 'run this test from the `haven/` package root',
        );

        final offenders = <String>[];
        final dartFiles = libDir
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))
            // FRB-generated bindings are not hand-written startup code.
            .where((f) => !f.path.contains('/rust/'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));

        for (final file in dartFiles) {
          final violations = findAbortingAsserts(file.readAsStringSync());
          for (final v in violations) {
            offenders.add('${file.path}:$v');
          }
        }

        expect(
          offenders,
          isEmpty,
          reason:
              'An `assert` inside an addPostFrameCallback aborts every '
              'statement after it in debug/profile builds and in all '
              'integration tests. If the assertion guards an invariant, log '
              'the violation and recover instead — do not let it silently '
              'skip the work queued below it.\n'
              'Offenders:\n  ${offenders.join('\n  ')}',
        );
      },
    );
  });
}
