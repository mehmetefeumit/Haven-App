// Static guard for Security Rule 8: "No Raw Errors in UI — never display `$e`
// or `e.message` to users — could leak MLS group IDs or internal state. Use
// `debugPrint` for details, generic messages for UI."
//
// Coverage before this guard was five per-site redaction tests
// (`profile_service_test.dart`, `live_sync_resubscriber_test.dart`,
// `map_shell_detached_release_test.dart`, `nostr_subscription_service_test
// .dart`) and no repo-wide check. A literal `grep '$e'` is defeated the
// moment a call site renames its bound identifier — the repo convention is
// `on Object catch (e)`, but nothing stops `catch (err)` — so this parses
// each `catch`/`on ... catch` clause for the identifier it actually binds,
// then flags STRING INTERPOLATION of that identifier anywhere it is not
// provably confined to a permitted sink.
//
// Permitted:
//   * `debugPrint(...)` — a direct argument to it, anywhere in the ancestor
//     chain from the interpolation.
//   * `assert(...)` — the condition or message of an `AssertStatement` /
//     `AssertInitializer`; asserts are stripped from release builds and exist
//     to fail loudly in debug/test, not to show a user anything.
//   * `${e.runtimeType}` — explicitly allowed by the rule text. Only THIS
//     access shape is exempt; `${e.message}`, `${e.toString()}`, bare `$e`,
//     etc. are not, because `Object.toString()` / a typed exception's
//     `.message` can carry FFI detail text that embeds an MLS group id or
//     other internal state (the reason the rule exists).
//
// Everything else interpolating the caught identifier is flagged: a thrown
// exception's message, a value assigned to UI state, a widget's `Text(...)`,
// a `SnackBar` — anything that is not the two named sinks.
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

/// One caught-error identifier interpolated somewhere that is not a
/// permitted sink.
class RawErrorViolation {
  RawErrorViolation({
    required this.path,
    required this.line,
    required this.snippet,
  });

  final String path;
  final int line;
  final String snippet;

  @override
  String toString() => '$path:$line  $snippet';
}

/// Collects references to any name in [_names] within an interpolation
/// expression's subtree.
///
/// Deliberately does NOT descend into the member-name child of a
/// `PrefixedIdentifier` (`.identifier`), a `PropertyAccess`
/// (`.propertyName`), or a `MethodInvocation` (`.methodName`) — those are
/// member names, not variable references, and a member literally named the
/// same as the caught identifier (e.g. `foo.e`) must not be mistaken for a
/// reference to it.
class _IdentRefCollector extends RecursiveAstVisitor<void> {
  _IdentRefCollector(this._names);

  final Set<String> _names;
  final List<SimpleIdentifier> refs = [];

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (_names.contains(node.name)) refs.add(node);
    // No children on a SimpleIdentifier — nothing further to visit.
  }

  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    node.prefix.accept(this);
  }

  @override
  void visitPropertyAccess(PropertyAccess node) {
    node.target?.accept(this);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    node.target?.accept(this);
    node.argumentList.accept(this);
  }
}

/// Whether [ref] (a reference to a caught identifier) is used ONLY as the
/// target of a `.runtimeType` access — the one access shape Rule 8 names as
/// exempt.
bool _isRuntimeTypeAccess(SimpleIdentifier ref) {
  final parent = ref.parent;
  if (parent is PrefixedIdentifier && parent.prefix == ref) {
    return parent.identifier.name == 'runtimeType';
  }
  if (parent is PropertyAccess && parent.target == ref) {
    return parent.propertyName.name == 'runtimeType';
  }
  return false;
}

/// Whether [node] (an `InterpolationExpression`) sits inside a permitted
/// sink: a direct argument to `debugPrint(...)`, or the condition/message of
/// an `assert`.
bool _isWithinPermittedSink(AstNode node) {
  for (var cur = node.parent; cur != null; cur = cur.parent) {
    if (cur is MethodInvocation && cur.methodName.name == 'debugPrint') {
      return true;
    }
    if (cur is AssertStatement || cur is AssertInitializer) return true;
  }
  return false;
}

class _RawErrorVisitor extends RecursiveAstVisitor<void> {
  _RawErrorVisitor(this._lineInfo, this._path);

  final LineInfo _lineInfo;
  final String _path;
  final List<RawErrorViolation> violations = [];

  /// Stack of caught-identifier names currently in scope, one per enclosing
  /// `catch` clause (so a violation inside a nested catch still sees an
  /// outer catch's identifier, and shadowing by a same-named inner catch is
  /// harmless — both bindings carry the same risk).
  final List<String> _activeCatchNames = [];

  @override
  void visitCatchClause(CatchClause node) {
    final name = node.exceptionParameter?.name.lexeme;
    if (name != null) _activeCatchNames.add(name);
    super.visitCatchClause(node);
    if (name != null) _activeCatchNames.removeLast();
  }

  @override
  void visitInterpolationExpression(InterpolationExpression node) {
    if (_activeCatchNames.isNotEmpty) {
      final collector = _IdentRefCollector(_activeCatchNames.toSet());
      node.expression.accept(collector);
      final touchesCaughtError = collector.refs.isNotEmpty;
      final allExempt = touchesCaughtError &&
          collector.refs.every(_isRuntimeTypeAccess);
      if (touchesCaughtError &&
          !allExempt &&
          !_isWithinPermittedSink(node)) {
        violations.add(
          RawErrorViolation(
            path: _path,
            line: _lineInfo.getLocation(node.offset).lineNumber,
            snippet: node.toSource(),
          ),
        );
      }
    }
    super.visitInterpolationExpression(node);
  }
}

/// Returns every caught-error interpolation in [source] that is not confined
/// to a permitted sink.
List<RawErrorViolation> findRawErrorInterpolations(
  String source, {
  String path = '<memory>',
}) {
  final parsed = parseString(content: source, throwIfDiagnostics: false);
  final visitor = _RawErrorVisitor(parsed.lineInfo, path);
  parsed.unit.accept(visitor);
  return visitor.violations;
}

void main() {
  group('detector self-tests', () {
    test(r'flags a bare $e outside any sink', () {
      const source = r'''
class _S {
  void go() {
    try {
      risky();
    } on Object catch (e) {
      _errorMessage = 'Failed: $e';
    }
  }
}
''';
      final v = findRawErrorInterpolations(source);
      expect(v, hasLength(1));
      expect(v.single.snippet, r'$e');
    });

    test(r'flags ${e.message} outside any sink', () {
      const source = r'''
class _S {
  void go() {
    try {
      risky();
    } on Object catch (e) {
      throw StateError('Failed: ${e.message}');
    }
  }
}
''';
      final v = findRawErrorInterpolations(source);
      expect(v, hasLength(1));
      expect(v.single.snippet, contains('e.message'));
    });

    test('flags interpolation reaching a widget (Text)', () {
      const source = r'''
class _S {
  Widget build() {
    try {
      risky();
    } on Object catch (e) {
      return Text('Error: $e');
    }
  }
}
''';
      expect(findRawErrorInterpolations(source), hasLength(1));
    });

    test(r'flags a renamed identifier — defeats a literal `$e` grep', () {
      const source = r'''
class _S {
  void go() {
    try {
      risky();
    } on Object catch (err) {
      _errorMessage = 'Failed: $err';
    }
  }
}
''';
      final v = findRawErrorInterpolations(source);
      expect(v, hasLength(1));
      expect(v.single.snippet, r'$err');
    });

    test(r'permits $e inside debugPrint', () {
      const source = r'''
class _S {
  void go() {
    try {
      risky();
    } on Object catch (e) {
      debugPrint('[X] failed: $e');
    }
  }
}
''';
      expect(findRawErrorInterpolations(source), isEmpty);
    });

    test(r'permits ${e.message} inside an assert message', () {
      const source = r'''
class _S {
  void go() {
    try {
      risky();
    } on Object catch (e) {
      assert(false, 'unexpected: ${e.message}');
    }
  }
}
''';
      expect(findRawErrorInterpolations(source), isEmpty);
    });

    test('permits a bare assert condition referencing e', () {
      const source = r'''
class _S {
  void go() {
    try {
      risky();
    } on Object catch (e) {
      assert(e is! StateError, 'should not be $e');
    }
  }
}
''';
      expect(findRawErrorInterpolations(source), isEmpty);
    });

    test(r'permits ${e.runtimeType} anywhere, not just inside a sink', () {
      const source = r'''
class _S {
  void go() {
    try {
      risky();
    } on Object catch (e) {
      throw ProfileServiceException('Failed: ${e.runtimeType}');
    }
  }
}
''';
      expect(findRawErrorInterpolations(source), isEmpty);
    });

    test(
      r'flags ${e.toString()} — a call is not the allowed runtimeType shape',
      () {
        const source = r'''
class _S {
  void go() {
    try {
      risky();
    } on Object catch (e) {
      throw StateError('Failed: ${e.toString()}');
    }
  }
}
''';
        final v = findRawErrorInterpolations(source);
        expect(v, hasLength(1));
      },
    );

    test(
      'permits a member access on an unrelated object named the same as '
      'the caught identifier (foo.e is not a reference to e)',
      () {
        const source = r'''
class _S {
  void go() {
    try {
      risky();
    } on Object catch (e) {
      debugPrint('unrelated: irrelevant');
      _label = 'value: ${foo.e}';
    }
  }
}
''';
        expect(findRawErrorInterpolations(source), isEmpty);
      },
    );

    test('permits interpolation that never references the caught name', () {
      const source = r'''
class _S {
  void go() {
    try {
      risky();
    } on Object catch (e) {
      final label = attempt;
      _status = 'attempt: $label';
    }
  }
}
''';
      expect(findRawErrorInterpolations(source), isEmpty);
    });

    test('flags one interpolation but not a sibling exempt one', () {
      const source = r'''
class _S {
  void go() {
    try {
      risky();
    } on Object catch (e) {
      debugPrint('type: ${e.runtimeType}');
      _errorMessage = 'detail: ${e.message}';
    }
  }
}
''';
      final v = findRawErrorInterpolations(source);
      expect(v, hasLength(1));
      expect(v.single.snippet, contains('e.message'));
    });

    test('flags a nested catch with a shadowed identical name', () {
      const source = r'''
class _S {
  void go() {
    try {
      risky();
    } on Object catch (e) {
      try {
        riskier();
      } on Object catch (e) {
        _errorMessage = 'inner: $e';
      }
    }
  }
}
''';
      final v = findRawErrorInterpolations(source);
      expect(v, hasLength(1));
    });

    test('flags an outer-catch reference used inside a nested catch body', () {
      const source = r'''
class _S {
  void go() {
    try {
      risky();
    } on Object catch (e) {
      try {
        riskier();
      } on Object catch (e2) {
        _errorMessage = 'outer was: $e, inner: ${e2.runtimeType}';
      }
    }
  }
}
''';
      final v = findRawErrorInterpolations(source);
      expect(v, hasLength(1));
      // Equality, not `contains` — `${e2.runtimeType}` also contains the
      // substring `$e`, so a loose match would not catch the wrong
      // (exempt) interpolation being flagged instead of this one.
      expect(v.single.snippet, r'$e');
    });

    test(r'ignores $e mentioned only in a comment', () {
      const source = r'''
class _S {
  void go() {
    try {
      risky();
    } on Object catch (e) {
      // Logging `$e` would expose that even in debug builds.
      debugPrint('[X] failed: ${e.runtimeType}');
    }
  }
}
''';
      expect(findRawErrorInterpolations(source), isEmpty);
    });
  });

  group('repository scan', () {
    test('no lib/ source interpolates a caught error outside a permitted '
        'sink', () {
      final libDir = Directory('lib');
      expect(
        libDir.existsSync(),
        isTrue,
        reason: 'Expected to run from the haven package root '
            '(cwd=${Directory.current.path}).',
      );

      final sep = Platform.pathSeparator;
      final offenders = <String>[];
      var scanned = 0;

      for (final entity in libDir.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        if (entity.path.contains('${sep}rust$sep')) continue; // generated
        scanned++;
        final violations = findRawErrorInterpolations(
          entity.readAsStringSync(),
          path: entity.path,
        );
        offenders.addAll(violations.map((v) => v.toString()));
      }

      expect(
        scanned,
        greaterThan(50),
        reason: 'Only scanned $scanned files — the lib/ glob looks broken.',
      );

      expect(
        offenders,
        isEmpty,
        reason:
            'Security Rule 8: a caught error was interpolated outside '
            'debugPrint/assert without being confined to `.runtimeType`. FFI '
            'error strings can carry MLS group ids or other internal state — '
            'use debugPrint for details and a generic message for the UI.\n'
            'Offenders:\n  ${offenders.join('\n  ')}',
      );
    });

    test('the scan actually walks catch clauses in lib/ (anti-vacuity)', () {
      // If nothing in lib/ ever binds a catch identifier, the scan above
      // passes by construction rather than by absence of violations.
      var totalCatchesWithBinding = 0;
      final libDir = Directory('lib');
      final sep = Platform.pathSeparator;
      for (final entity in libDir.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        if (entity.path.contains('${sep}rust$sep')) continue;
        final unit = parseString(
          content: entity.readAsStringSync(),
          throwIfDiagnostics: false,
        ).unit;
        final counter = _CatchBindingCounter();
        unit.accept(counter);
        totalCatchesWithBinding += counter.count;
      }
      expect(
        totalCatchesWithBinding,
        greaterThan(50),
        reason: 'Only found $totalCatchesWithBinding bound catch clauses in '
            'lib/ — the repo convention `on Object catch (e)` should account '
            'for far more than this; the guard may have gone blind.',
      );
    });
  });
}

class _CatchBindingCounter extends RecursiveAstVisitor<void> {
  int count = 0;

  @override
  void visitCatchClause(CatchClause node) {
    if (node.exceptionParameter != null) count++;
    super.visitCatchClause(node);
  }
}
