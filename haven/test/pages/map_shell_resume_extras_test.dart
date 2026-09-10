/// What a resume costs, and what it must always do anyway.
///
/// `MapShell._onResumed` does two different kinds of work. One kind is a
/// PROMISE: publish now, refresh the peers on the map, repair a subscription a
/// relay ended. The other is EXTRAS — probes and sweeps that each already run
/// on a periodic timer, and that a shade-pull glance repeated ten times an hour
/// for nothing. Only the second kind may be throttled, and this file pins the
/// line between them: the throttle is one `if`, and it is far too easy to widen
/// it by one statement and quietly stop publishing on resume.
///
/// ## Why a source guard
///
/// `_MapShellState` and `_onResumed` are private, and per CLAUDE.md `MapShell`
/// cannot be pumped in `flutter test` — `MapPage` reaches the Rust bridge in
/// `initState`. The throttle's own arithmetic is unit-tested in
/// `test/providers/resume_extras_provider_test.dart`; what only the shell can
/// answer is WHICH work sits behind it. The analysis is AST-based and scoped to
/// the brace-balanced gated block, so neither prose nor a call elsewhere in a
/// 2000-line method can satisfy it — both dodges are self-tested below.
@TestOn('vm')
library;

import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:flutter_test/flutter_test.dart';

/// The executable source of [method] on [className], or `null` if absent.
///
/// `toSource()` rebuilds the body from the AST, so comments are GONE: every
/// assertion here is about statements that run.
String? methodBodySource(
  String source, {
  required String className,
  required String method,
}) {
  final unit = parseString(content: source, throwIfDiagnostics: false).unit;
  final visitor = _MethodBodyVisitor(className: className, method: method);
  unit.accept(visitor);
  return visitor.body?.toSource();
}

/// The brace-balanced block that starts at [open], which must index a `{`.
///
/// Slicing by braces rather than "everything after the `if`" is what keeps an
/// assertion about the GATED statements from being satisfied — or dodged — by
/// a statement that merely follows the block.
String blockAt(String source, int open) {
  expect(source[open], '{');
  var depth = 0;
  for (var i = open; i < source.length; i++) {
    if (source[i] == '{') depth++;
    if (source[i] == '}') {
      depth--;
      if (depth == 0) return source.substring(open, i + 1);
    }
  }
  fail('unbalanced braces from offset $open');
}

class _MethodBodyVisitor extends RecursiveAstVisitor<void> {
  _MethodBodyVisitor({required this.className, required this.method});

  final String className;
  final String method;
  AstNode? body;

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    if (node.name.lexeme != className) return;
    for (final member in node.members) {
      if (member is MethodDeclaration && member.name.lexeme == method) {
        body = member.body;
      }
    }
  }
}

void main() {
  group('detector self-tests', () {
    test('the block slice stops at its own closing brace', () {
      const source = 'if (x) {inside(); if (y) {nested();}} after();';
      final slice = blockAt(source, source.indexOf('{'));
      expect(slice, contains('inside()'));
      expect(slice, contains('nested()'));
      expect(
        slice,
        isNot(contains('after()')),
        reason: 'a slice that ran past the block would call every following '
            'statement "gated"',
      );
    });

    test('comments cannot satisfy a body assertion', () {
      const source = '''
class _MapShellState {
  Future<void> _onResumed() async {
    // if (runExtras) { _runPrune(); }
  }
}
''';
      expect(
        methodBodySource(
          source,
          className: '_MapShellState',
          method: '_onResumed',
        ),
        isNot(contains('runExtras')),
      );
    });

    test('a renamed method fails the guard rather than passing it', () {
      expect(
        methodBodySource(
          'class _MapShellState { void a() {} }',
          className: '_MapShellState',
          method: '_onResumed',
        ),
        isNull,
      );
    });
  });

  group('the real source', () {
    late String body;
    late String gated;

    setUpAll(() {
      final file = File('lib/src/pages/map_shell.dart');
      expect(
        file.existsSync(),
        isTrue,
        reason: 'map_shell.dart moved — update this guard, do not delete it',
      );
      final resumed = methodBodySource(
        file.readAsStringSync(),
        className: '_MapShellState',
        method: '_onResumed',
      );
      expect(resumed, isNotNull);
      body = resumed!;
      final gateAt = body.indexOf('if (runExtras) {');
      expect(
        gateAt,
        isNonNegative,
        reason: 'the resume extras must sit behind ONE named decision, so that '
            'what is and is not throttled is readable at a glance',
      );
      gated = blockAt(body, body.indexOf('{', gateAt));
    });

    test('the decision is taken once, from the shared stamp', () {
      expect(body, contains('shouldRunResumeExtras('));
      expect(
        body,
        contains('lastResumeExtrasAtProvider'),
        reason: 'a private field would throttle only this widget; the map page '
            'evicts its tile cache off the same stamp',
      );
      expect(
        gated,
        contains('lastResumeExtrasAtProvider.notifier'),
        reason: 'stamping outside the gate would push the window forward on '
            'every glance and starve the extras forever',
      );
    });

    for (final extra in const [
      'keyPackagePublisherProvider',
      'triggerProfileRefresh',
      '_runPrune',
    ]) {
      test('$extra is behind the window', () {
        expect(
          gated,
          contains(extra),
          reason: 'it re-runs on its own timer; repeating it per glance buys '
              'no freshness and costs relay round-trips',
        );
      });
    }

    for (final promise in const [
      'locationPublisherProvider',
      'memberLocationsProvider',
    ]) {
      test('$promise stays unconditional', () {
        expect(
          body,
          contains(promise),
          reason: 'anti-vacuity: the resume must still do it at all',
        );
        expect(
          gated,
          isNot(contains(promise)),
          reason: 'this is what the user came back to see; throttling it '
              'breaks a promise rather than saving power',
        );
      });
    }

    test('the engine re-anchor keeps its own 60 s guard, ahead of the '
        'window', () {
      final reanchorAt = body.indexOf('shouldReanchorOnResume(');
      expect(reanchorAt, isNonNegative);
      expect(
        gated,
        isNot(contains('shouldReanchorOnResume(')),
        reason: 'the re-anchor is the only repair for a relay-CLOSED REQ; a '
            '10 min window would leave a user who opened the app BECAUSE '
            'peers stopped appearing without one',
      );
      expect(
        reanchorAt,
        lessThan(body.indexOf('if (runExtras) {')),
        reason: 'it also runs ahead of the 30 s resume debounce',
      );
    });
  });
}
