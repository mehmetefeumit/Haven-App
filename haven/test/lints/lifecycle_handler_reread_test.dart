// `MapShell`'s pause and resume handlers are async, and the framework does
// not wait for them. Every `await` in one is a point where the OTHER can run
// to completion: the user comes back while the pause is still stopping the
// engine, or leaves again while the resume is still waiting for the
// foreground service to go idle. Whatever the first handler does after that
// await then lands on top of the second — a released MLS session, a "sharing
// in the background" notification and a cancelled timer set under an app that
// is on screen; or an ended handoff, a foreground-owner heartbeat and every
// timer armed in a process the user has left.
//
// So each handler captures `_lifecycleTurn` — how many pauses and resumes
// have been dispatched — and stops, after every await, once it has moved. A
// count and not a read of the lifecycle: "is the app resumed NOW" answers no
// for a window that lost focus after its resume ran, and a pause that
// finished late would then hand the session over under a visible app. The
// behaviour of the steps that are statics is tested where it lives
// (`map_shell_pause_start_test.dart`, `map_shell_receive_recovery_test.dart`,
// `background_burst_coordinator_test.dart`); `MapShell` itself cannot be pumped
// (CLAUDE.md), so this file holds the shape those tests cannot: that no await
// in either handler, or in the hand-off static the pause delegates its awaits
// to, is followed by anything else first.
//
// Also here, for the same reason: where the turn is moved, the places the
// shell hands the lifecycle to whatever could bring a session up or arm a
// timer behind a pause, and that the pause uses `ref` after its await only
// while mounted.
//
// Known limits — what this file does NOT catch:
//  * an `await` moved out of a handler into a helper this file does not name
//    (`handOffMlsSession` is named, and checked), or into a closure the
//    handler calls — a closure's awaits are not the handler's own;
//  * an effect deferred into a `Timer`, a microtask, or a continuation spelt
//    otherwise than `.then(` / `.whenComplete(` (`.timeout(…, onTimeout:)`);
//  * a `ref` reached through a getter or a closure rather than spelt `ref`
//    in the handler's own body;
//  * a re-read that is present, adjacent and WRONG in a way its exact text
//    does not show — the condition is matched as written, not understood.
// Caught, each with a fixture: an `await for`; a `.then(` / `.whenComplete(`
// chain; an `await` that is not the whole of its statement (`if (await a())`,
// `f(await a(), g())`), which runs something behind the suspension and ahead
// of the re-read; every way of writing `_lifecycleTurn`; a second caller of
// `_startTimers`, and a second arming of the heal backstop.
@TestOn('vm')
library;

import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:flutter_test/flutter_test.dart';

/// The body of the one method named [method] in [source].
FunctionBody _bodyOf(String source, String method) {
  final unit = parseString(content: source, throwIfDiagnostics: false).unit;
  final collector = _MethodCollector(method);
  unit.accept(collector);
  expect(
    collector.found,
    hasLength(1),
    reason: 'exactly one $method must exist — if it was renamed, update this '
        'guard rather than deleting it',
  );
  return collector.found.single.body;
}

class _MethodCollector extends RecursiveAstVisitor<void> {
  _MethodCollector(this.method);

  final String method;
  final List<MethodDeclaration> found = [];

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    if (node.name.lexeme == method) found.add(node);
    super.visitMethodDeclaration(node);
  }
}

/// What [body] does ITSELF after a suspension: its awaits, and the two
/// shapes that run code after one without an `await` expression. Anything
/// inside a closure runs later, under whatever lifecycle that closure is
/// called in.
class _SuspensionCollector extends RecursiveAstVisitor<void> {
  _SuspensionCollector(this.body);

  final FunctionBody body;
  final List<AwaitExpression> awaits = [];

  /// `await for` loops and `.then(` / `.whenComplete(` chains, as source.
  final List<String> unreadable = [];

  /// Every use of the identifier `ref`.
  final List<SimpleIdentifier> refs = [];

  bool _own(AstNode node) =>
      identical(node.thisOrAncestorOfType<FunctionBody>(), body);

  @override
  void visitAwaitExpression(AwaitExpression node) {
    if (_own(node)) awaits.add(node);
    super.visitAwaitExpression(node);
  }

  @override
  void visitForStatement(ForStatement node) {
    if (node.awaitKeyword != null && _own(node)) {
      unreadable.add('await for');
    }
    super.visitForStatement(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final name = node.methodName.name;
    if ((name == 'then' || name == 'whenComplete') && _own(node)) {
      unreadable.add('.$name(');
    }
    super.visitMethodInvocation(node);
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (node.name == 'ref' && _own(node)) refs.add(node);
    super.visitSimpleIdentifier(node);
  }

  @override
  void visitComment(Comment node) {}
}

_SuspensionCollector _suspensionsIn(String source, String method) {
  final body = _bodyOf(source, method);
  final collector = _SuspensionCollector(body);
  body.accept(collector);
  return collector;
}

/// The awaits in [method] that are NOT immediately followed, in their own
/// block, by `if (<condition>) return;` — as source, in order — and every
/// suspension that has no place to put one.
///
/// "Immediately" is the whole rule: a statement between the await and the
/// re-read is one that runs whatever the lifecycle has become.
List<String> _unguardedAwaits(
  String source, {
  required String method,
  required bool Function(String condition) isReread,
}) {
  final collector = _suspensionsIn(source, method);
  final unguarded = <String>[...collector.unreadable];
  for (final awaited in collector.awaits) {
    final statement = awaited.thisOrAncestorOfType<Statement>()!;
    final block = statement.parent;
    Statement? next;
    if (block is Block) {
      final at = block.statements.indexOf(statement);
      if (at + 1 < block.statements.length) next = block.statements[at + 1];
    }
    final guarded =
        _isWholeStatement(awaited, statement) &&
        !_insideCatchingTry(awaited, collector.body) &&
        next is IfStatement &&
        next.elseStatement == null &&
        next.thenStatement is ReturnStatement &&
        (next.thenStatement as ReturnStatement).expression == null &&
        isReread(next.expression.toSource());
    if (!guarded) unguarded.add(statement.toSource());
  }
  return unguarded;
}

/// Whether [awaited] sits in the body of a `try` with a `catch` or a
/// `finally`: either runs behind the suspension without the re-read — a
/// `finally` even after it returns, a `catch` whenever the await throws.
bool _insideCatchingTry(AwaitExpression awaited, FunctionBody body) {
  AstNode child = awaited;
  for (var n = awaited.parent;
      n != null && n != body;
      child = n, n = n.parent) {
    if (n is TryStatement &&
        identical(n.body, child) &&
        (n.catchClauses.isNotEmpty || n.finallyBlock != null)) {
      return true;
    }
  }
  return false;
}

/// Whether [awaited] is everything [statement] does: `await x;`, or the
/// whole initializer of the one variable it declares.
///
/// Inside anything larger — a condition, an argument list, a loop header —
/// what the statement goes on to do runs behind the suspension and AHEAD of
/// the re-read that follows the statement.
bool _isWholeStatement(AwaitExpression awaited, Statement statement) {
  if (statement is ExpressionStatement) {
    return identical(statement.expression, awaited);
  }
  if (statement is VariableDeclarationStatement) {
    final declared = statement.variables.variables;
    return declared.length == 1 &&
        identical(declared.single.initializer, awaited);
  }
  return false;
}

/// Whether [a] and [b] sit in different arms of one `if`: only one of them
/// runs.
bool _exclusive(AstNode a, AstNode b) {
  Map<IfStatement, bool> arms(AstNode node) {
    final found = <IfStatement, bool>{};
    var child = node;
    for (var n = node.parent; n != null; child = n, n = n.parent) {
      if (n is! IfStatement) continue;
      if (identical(n.thenStatement, child)) found[n] = true;
      if (identical(n.elseStatement, child)) found[n] = false;
    }
    return found;
  }

  final ofA = arms(a);
  for (final MapEntry(key: branch, value: inThen) in arms(b).entries) {
    final other = ofA[branch];
    if (other != null && other != inThen) return true;
  }
  return false;
}

/// The uses of `ref` in [method]'s own body that can run after one of its
/// awaits on a State that await outlived — as the source of the statement
/// each is in.
///
/// A use is safe inside an `if (mounted)`, or where the last await that can
/// run before it is followed at once by a return on `!mounted`. A use in the
/// other arm of an `if` from the await does not run after it.
///
/// A State the await outlived has no `ref`: the read throws, unhandled, and
/// everything after it in the handler is skipped.
List<String> _unmountedRefUses(String source, String method) {
  final collector = _suspensionsIn(source, method);
  final exposed = <String>[];
  for (final use in collector.refs) {
    final before = collector.awaits
        .where((a) => a.end <= use.offset && !_exclusive(a, use))
        .toList();
    if (before.isEmpty) continue;
    var guarded = false;
    for (var n = use.parent; n != null && n != collector.body; n = n.parent) {
      // An `if (mounted)` read after every await that can run before the use.
      final start = n.offset;
      if (n is IfStatement &&
          n.expression.toSource() == 'mounted' &&
          before.every((a) => a.end <= start)) {
        guarded = true;
      }
    }
    // Or every such await is followed at once by a return on `!mounted`: a
    // path passes each of them, not only the last.
    if (before.every(_returnsOnUnmounted)) guarded = true;
    if (!guarded) {
      exposed.add(use.thisOrAncestorOfType<Statement>()!.toSource());
    }
  }
  return exposed;
}

/// Whether the statement [awaited] is in is followed at once by
/// `if (!mounted) return;` or `if (!mounted || …) return;` — a return that
/// runs whenever the State is gone.
bool _returnsOnUnmounted(AwaitExpression awaited) {
  final statement = awaited.thisOrAncestorOfType<Statement>()!;
  final block = statement.parent;
  if (block is! Block) return false;
  final at = block.statements.indexOf(statement);
  if (at + 1 >= block.statements.length) return false;
  final next = block.statements[at + 1];
  if (next is! IfStatement ||
      next.elseStatement != null ||
      next.thenStatement is! ReturnStatement) {
    return false;
  }
  bool unmounted(Expression e) =>
      e.toSource() == '!mounted' ||
      (e is BinaryExpression &&
          e.operator.lexeme == '||' &&
          unmounted(e.leftOperand));
  return unmounted(next.expression);
}

/// Every write of [field] in [source], whatever its spelling — as
/// `<enclosing method>: <the write>`.
List<String> _writesOf(String source, String field) {
  final unit = parseString(content: source, throwIfDiagnostics: false).unit;
  final collector = _WriteCollector(field);
  unit.accept(collector);
  return collector.found;
}

class _WriteCollector extends RecursiveAstVisitor<void> {
  _WriteCollector(this.field);

  final String field;
  final List<String> found = [];

  bool _isField(Expression e) =>
      (e is SimpleIdentifier && e.name == field) ||
      (e is PropertyAccess && e.propertyName.name == field) ||
      (e is PrefixedIdentifier && e.identifier.name == field);

  void _add(AstNode node) => found.add(
    '${node.thisOrAncestorOfType<MethodDeclaration>()?.name.lexeme}: '
    '${node.toSource()}',
  );

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    if (_isField(node.leftHandSide)) _add(node);
    super.visitAssignmentExpression(node);
  }

  @override
  void visitPostfixExpression(PostfixExpression node) {
    if (_isField(node.operand)) _add(node);
    super.visitPostfixExpression(node);
  }

  @override
  void visitPrefixExpression(PrefixExpression node) {
    final op = node.operator.lexeme;
    if ((op == '++' || op == '--') && _isField(node.operand)) _add(node);
    super.visitPrefixExpression(node);
  }

  @override
  void visitForEachPartsWithIdentifier(ForEachPartsWithIdentifier node) {
    if (_isField(node.identifier)) _add(node);
    super.visitForEachPartsWithIdentifier(node);
  }

  @override
  void visitComment(Comment node) {}
}

/// Every call of a method named [method] in [source], on [target] if given
/// (a cascade's target counts) — as `<enclosing method>: <the call>`.
List<String> _callsOf(String source, String method, {String? target}) {
  final unit = parseString(content: source, throwIfDiagnostics: false).unit;
  final collector = _CallCollector(method, target);
  unit.accept(collector);
  return collector.found;
}

class _CallCollector extends RecursiveAstVisitor<void> {
  _CallCollector(this.method, this.target);

  final String method;
  final String? target;
  final List<String> found = [];

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (node.methodName.name == method &&
        (target == null || node.realTarget?.toSource() == target)) {
      found.add(
        '${node.thisOrAncestorOfType<MethodDeclaration>()?.name.lexeme}: '
        '${node.methodName.name}${node.argumentList.toSource()}',
      );
    }
    super.visitMethodInvocation(node);
  }

  @override
  void visitComment(Comment node) {}
}

/// Every use of the heal backstop in [source] that can arm it — anything but
/// a stop or a heal — as `<enclosing method>: <the use>`. Read from every
/// reference to the field, so a `this.` spelling, an alias, a tear-off or a
/// private member it reaches is a use too.
List<String> _armingUses(String source) {
  final unit = parseString(content: source, throwIfDiagnostics: false).unit;
  final collector = _UseCollector('_healBackstop');
  unit.accept(collector);
  return [
    for (final use in collector.found)
      if (!const {'stop()', 'heal()', 'heal (tear-off)'}.contains(use.$2))
        '${use.$1}: ${use.$2}',
  ];
}

class _UseCollector extends RecursiveAstVisitor<void> {
  _UseCollector(this.field);

  final String field;
  final List<(String?, String)> found = [];

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (node.name == field) {
      AstNode use = node;
      final up = node.parent;
      if (up is PropertyAccess && up.target is ThisExpression) use = up;
      final p = use.parent;
      final String what;
      if (p is MethodInvocation && identical(p.target, use)) {
        what = '${p.methodName.name}()';
      } else if (p is PrefixedIdentifier && identical(p.prefix, use)) {
        what = '${p.identifier.name} (tear-off)';
      } else if (p is PropertyAccess && identical(p.target, use)) {
        what = '${p.propertyName.name} (tear-off)';
      } else {
        what = p!.toSource();
      }
      found.add((node.thisOrAncestorOfType<MethodDeclaration>()?.name.lexeme,
          what));
    }
    super.visitSimpleIdentifier(node);
  }

  @override
  void visitComment(Comment node) {}
}

bool _turnRead(String condition) => condition == 'turn != _lifecycleTurn';

bool _turnOrUnmounted(String condition) =>
    _turnRead(condition) || condition == '!mounted || turn != _lifecycleTurn';

bool _supersededRead(String condition) => condition == 'superseded()';

String _handler(String body) => 'class S { Future<void> h() async { $body } }';

List<String> _unguardedIn(String body) =>
    _unguardedAwaits(_handler(body), method: 'h', isReread: _turnRead);

const _reread = 'if (turn != _lifecycleTurn) return;';

void main() {
  group('the checker sees what it must', () {
    test('an await followed at once by the re-read passes', () {
      expect(_unguardedIn('await a(); $_reread b();'), isEmpty);
      expect(
        _unguardedIn('if (x) { await a(); $_reread } b();'),
        isEmpty,
        reason: 'the re-read is in the block the await is in',
      );
    });

    test('an await with nothing after it is found', () {
      expect(_unguardedIn('b(); await a();'), ['await a();']);
    });

    test('an await with a statement before its re-read is found', () {
      expect(_unguardedIn('await a(); b(); $_reread'), ['await a();']);
    });

    test('an await whose re-read is outside its block is found', () {
      expect(_unguardedIn('if (x) { await a(); } $_reread'), ['await a();']);
    });

    test('an await bound to a local is still an await', () {
      expect(_unguardedIn('final v = await a(); use(v);'), [
        'final v = await a();',
      ]);
    });

    test('an instantaneous read, a negated one, or one that does not return '
        'fails', () {
      for (final after in const [
        'if (appIsResumed()) return;',
        'if (_away) return;',
        'if (turn == _lifecycleTurn) return;',
        'if (turn != _lifecycleTurn) b();',
        'if (turn != _lifecycleTurn) return; else b();',
        'if (turn != _lifecycleTurn && x) return;',
      ]) {
        expect(
          _unguardedIn('await a(); $after'),
          ['await a();'],
          reason: after,
        );
      }
    });

    test("an await inside a closure is not the handler's own", () {
      expect(_unguardedIn('f(() async { await a(); });'), isEmpty);
    });

    test('an await-for loop is found: it has no place for a re-read', () {
      expect(
        _unguardedIn('await for (final e in s) { b(e); }'),
        ['await for'],
      );
    });

    test('a continuation chained in the handler is found', () {
      expect(_unguardedIn('a().then((_) => b());'), ['.then(']);
      expect(_unguardedIn('a().whenComplete(b);'), ['.whenComplete(']);
      expect(
        _unguardedIn('f(() { a().then((_) => b()); });'),
        isEmpty,
        reason: 'inside a closure it is not this handler running',
      );
    });

    test('a ref used after the await, outside if (mounted), is found', () {
      const pause =
          'class S { Future<void> h() async { ref.read(a); '
          'if (x) { await a(); } ref.read(b); '
          'if (mounted) { ref.read(c); } f(() => ref.read(d)); } }';
      expect(_unmountedRefUses(pause, 'h'), ['ref.read(b);']);
    });

    test("a ref in the await's own branch is found, one in the other arm "
        'is not', () {
      expect(
        _unmountedRefUses(
          _handler('if (x) { await a(); $_reread ref.read(b); } '
              'else { ref.read(c); }'),
          'h',
        ),
        ['ref.read(b);'],
        reason: 'the statement that holds the await is not skipped',
      );
    });

    test('a ref behind a return on !mounted is not found; behind any other '
        'return it is', () {
      expect(
        _unmountedRefUses(
          _handler('await a(); if (!mounted || turn != _lifecycleTurn) '
              'return; ref.read(b);'),
          'h',
        ),
        isEmpty,
      );
      expect(
        _unmountedRefUses(_handler('await a(); $_reread ref.read(b);'), 'h'),
        ['ref.read(b);'],
      );
    });

    test('an await that is not the whole of its statement is found', () {
      for (final compound in const [
        'if (await a()) { release(); }',
        'switch (await a()) { case 1: release(); }',
        'for (final x in await a()) { release(x); }',
        'f(await a(), effect());',
        'final v = g(await a());',
        'final v = await a(), w = effect();',
      ]) {
        expect(
          _unguardedIn('$compound $_reread'),
          hasLength(1),
          reason: 'what `$compound` goes on to do runs behind the suspension '
              'and ahead of the re-read',
        );
      }
      expect(_unguardedIn('final v = await a(); $_reread use(v);'), isEmpty);
    });

    test('every way of writing a field is found', () {
      expect(
        _writesOf(
          'class S { int _t = 0; '
          'a() { _t++; ++_t; _t += 1; _t = 0; this._t--; '
          'for (_t in xs) {} } '
          'b() { if (_t != 1) return; f(-_t); for (final t in xs) {} } }',
          '_t',
        ),
        [
          'a: _t++',
          'a: ++_t',
          'a: _t += 1',
          'a: _t = 0',
          'a: this._t--',
          'a: _t in xs',
        ],
      );
    });

    test('a call is found with its caller, a cascade included', () {
      expect(
        _callsOf(
          'class S { a() { _b.start(); _b..start(); other.start(); '
          'f(() => _b.start()); } c() { go(x: true); } }',
          'start',
          target: '_b',
        ),
        ['a: start()', 'a: start()', 'a: start()'],
      );
      expect(
        _callsOf(
          'class S { c() { go(x: true); } d() { go(x: false); } }',
          'go',
        ),
        ['c: go(x: true)', 'd: go(x: false)'],
      );
    });
  });

  group('the checker closes the holes it had', () {
    test('every spelling of arming the heal backstop is found', () {
      expect(
        _armingUses(
          'class S { a() { this._healBackstop.start(); '
          'final b = _healBackstop; f(_healBackstop.start); '
          '_healBackstop._arm(); _healBackstop.stop(); '
          '_healBackstop.heal(); g(heal: _healBackstop.heal); } }',
        ),
        [
          'a: start()',
          'a: b = _healBackstop',
          'a: start (tear-off)',
          'a: _arm()',
        ],
      );
    });

    test('an await inside a try with a catch or a finally is found', () {
      expect(
        _unguardedIn('try { await a(); $_reread } finally { effect(); }'),
        hasLength(1),
        reason: 'the finally runs behind the suspension, after the return',
      );
      expect(
        _unguardedIn('try { await a(); $_reread } catch (_) { effect(); }'),
        hasLength(1),
        reason: 'a throwing await runs the catch, and no re-read, behind it',
      );
    });

    test('an if (mounted) that holds the await guards nothing behind it', () {
      expect(
        _unmountedRefUses(
          _handler('if (mounted) { await b(); ref.read(c); }'),
          'h',
        ),
        ['ref.read(c);'],
      );
    });

    test('every await before a use needs its own return on !mounted', () {
      expect(
        _unmountedRefUses(
          _handler('await a(); $_reread if (x) { await b(); '
              'if (!mounted) return; } ref.read(c);'),
          'h',
        ),
        ['ref.read(c);'],
        reason: 'with x false the path reaches the read past an await whose '
            're-read does not look at mounted',
      );
    });

    test('a return on !mounted that may not return is not one', () {
      expect(
        _unmountedRefUses(
          _handler('await a(); if (!mounted && neverTrue) return; '
              'ref.read(c);'),
          'h',
        ),
        ['ref.read(c);'],
      );
    });
  });

  group('MapShell', () {
    late String source;

    setUpAll(() {
      source = File('lib/src/pages/map_shell.dart').readAsStringSync();
    });

    test('the pause stops after every await once the lifecycle has turned',
        () {
      expect(
        _suspensionsIn(source, '_onPaused').awaits,
        isNotEmpty,
        reason: 'anti-vacuity: the Android handoff awaits',
      );
      expect(
        _unguardedAwaits(source, method: '_onPaused', isReread: _turnRead),
        isEmpty,
        reason: 'what follows one of these runs even when a resume, or a '
            'second pause, has already run: each must be followed at once by '
            '`$_reread`',
      );
    });

    test('the hand-off the pause awaits stops after each of its own awaits',
        () {
      expect(
        _suspensionsIn(source, 'handOffMlsSession').awaits,
        hasLength(2),
        reason: 'anti-vacuity: each ownership write, and the engine stop',
      );
      expect(
        _unguardedAwaits(
          source,
          method: 'handOffMlsSession',
          isReread: _supersededRead,
        ),
        isEmpty,
        reason: "the pause's awaits live here; a write or a release after "
            'one of them lands on whatever superseded the pause',
      );
    });

    test('the resume re-reads the lifecycle after every await', () {
      expect(
        _suspensionsIn(source, '_onResumed').awaits,
        isNotEmpty,
        reason: 'anti-vacuity: the Android reclaim awaits',
      );
      expect(
        _unguardedAwaits(
          source,
          method: '_onResumed',
          isReread: _turnOrUnmounted,
        ),
        isEmpty,
        reason: 'what follows one of these runs even when the user has left '
            'again and the pause has already run: each must be followed at '
            'once by a return on a moved `_lifecycleTurn`',
      );
    });

    test('the turn is captured at entry and moved by a pause and a resume '
        'only', () {
      for (final handler in const ['_onPaused', '_onResumed']) {
        final body = _bodyOf(source, handler).toSource();
        final captured = body.indexOf('final turn = _lifecycleTurn;');
        expect(captured, isNonNegative, reason: handler);
        expect(
          captured,
          lessThan(body.indexOf('await ')),
          reason: '$handler must capture the turn before it first suspends',
        );
      }
      final dispatch = _bodyOf(
        source,
        'didChangeAppLifecycleState',
      ).toSource().replaceAll(RegExp(r'\s+'), ' ');
      expect(
        dispatch,
        allOf(
          contains(
            'if (state == AppLifecycleState.paused) {_lifecycleTurn++;',
          ),
          contains(
            'else if (state == AppLifecycleState.resumed) {_lifecycleTurn++;',
          ),
        ),
      );
      expect(
        _writesOf(source, '_lifecycleTurn'),
        [
          'didChangeAppLifecycleState: _lifecycleTurn++',
          'didChangeAppLifecycleState: _lifecycleTurn++',
        ],
        reason: 'every write, however spelt. A detach must not move it: the '
            'pause in flight still has the session to hand over, and nothing '
            'else would',
      );
    });

    test('what the pause hands its statics is the turn it captured', () {
      final pause = _bodyOf(
        source,
        '_onPaused',
      ).toSource().replaceAll(RegExp(r'\s+'), ' ');
      expect(
        'superseded: () => turn != _lifecycleTurn'.allMatches(pause),
        hasLength(1),
        reason: 'handed an instantaneous read, the hand-off lands on a user '
            'whose window has lost focus',
      );
      expect(
        pause,
        contains(
          'ownershipWrites: [if (lastPublish != null) () => '
          'BackgroundLocationManager.writeLastPublishTime(lastPublish), () => '
          'BackgroundLocationManager.markForegroundActive(active: false)], ',
        ),
        reason: 'the seed first, then the ownership: a service told the '
            'foreground has stood down before the seed is written draws its '
            'first cycle from a stale one',
      );
    });

    test('the pause uses ref after its await only while mounted', () {
      expect(
        _unmountedRefUses(source, '_onPaused'),
        isEmpty,
        reason: 'on a State the hand-off outlived it throws, unhandled, and '
            'skips the pool shutdown and the cache drop',
      );
    });

    test('the resume uses ref after an await only behind a return on '
        '!mounted', () {
      final resume = _suspensionsIn(source, '_onResumed');
      expect(
        resume.refs.where((r) => r.offset > resume.awaits.first.end),
        isNotEmpty,
        reason: 'anti-vacuity',
      );
      expect(_unmountedRefUses(source, '_onResumed'), isEmpty);
    });

    test('the hand-off reads no ref: what it needs was captured while '
        'mounted', () {
      for (final method in const [
        '_handOffMlsSession',
        '_releaseMlsSessionForHandoff',
      ]) {
        // Anywhere in it, a closure it builds included: that closure is
        // what runs behind the stop.
        expect(
          RegExp(r'\bref\b').allMatches(_bodyOf(source, method).toSource()),
          isEmpty,
          reason: '$method runs behind the stop, on a State that may be gone',
        );
      }
      final pause = _bodyOf(source, '_onPaused').toSource();
      expect(
        pause.indexOf('final circleService = ref.read(circleServiceProvider);'),
        allOf(isNonNegative, lessThan(pause.indexOf('await '))),
      );
    });

    test('the pause closes the location cache in its first synchronous run, '
        'and only a resume opens it', () {
      final pause = _bodyOf(
        source,
        '_onPaused',
      ).toSource().replaceAll(RegExp(r'\s+'), ' ');
      expect(_callsOf(source, 'onAppPaused'), ['_onPaused: onAppPaused()']);
      expect(
        pause.indexOf(
          'if (!(bgEnabled && Platform.isIOS)) '
          '{ref.read(locationSharingServiceProvider).onAppPaused();}',
        ),
        allOf(isNonNegative, lessThan(pause.indexOf('await '))),
        reason: 'behind the hand-off it leaves plaintext coordinates in a '
            'paused process for as long as the stop takes; and the one '
            'branch that keeps receiving keeps its cache',
      );
      expect(_callsOf(source, 'onAppResumed'), ['_onResumed: onAppResumed()']);
      final resume = _bodyOf(source, '_onResumed').toSource();
      expect(
        resume.indexOf('onAppResumed()'),
        allOf(isNonNegative, lessThan(resume.indexOf('await '))),
        reason: 'opened in the dispatch itself: behind an await the map '
            'reads an empty cache in an app that is in front',
      );
    });

    test("the resume's ownership write is guarded, as the pause's are", () {
      final resume = _bodyOf(
        source,
        '_onResumed',
      ).toSource().replaceAll(RegExp(r'\s+'), ' ');
      expect(
        resume,
        contains(
          'await MapShell._handoffWrite(() => '
          'BackgroundLocationManager.markForegroundActive(active: true));',
        ),
        reason: 'a throw here aborted the resume before the hand-off was '
            'ended, the heal and every timer',
      );
      expect(
        resume,
        isNot(contains('await BackgroundLocationManager.markForegroundActive')),
      );
    });

    test("the read the re-subscriber acts on is the binding's, at the call",
        () {
      final code = source.replaceAll(RegExp(r'\s+'), ' ');
      expect(
        code,
        contains(
          'bool _liveSyncWanted() => mounted && MapShell.liveSyncWanted( '
          'lifecycle: WidgetsBinding.instance.lifecycleState, '
          'isIOS: Platform.isIOS, '
          'backgroundSharingEnabled: ref.read(backgroundSharingProvider), );',
        ),
        reason: 'a remembered lifecycle, or the consent as the pause read '
            'it, is a latch the other handler can leave wrong',
      );
    });

    test('every re-subscriber is built with that read', () {
      final built = RegExp(r'\bLiveSyncResubscriber\(').allMatches(source);
      expect(built, hasLength(1));
      final from = built.single.start;
      expect(
        source.substring(from, source.indexOf(');', from)),
        contains('sessionWanted: _liveSyncWanted,'),
        reason: 'without it every queued leg starts a session behind the '
            "pause's stop",
      );
    });

    test('the heal timer is never armed while the app is away', () {
      // What the backstop does with each call is proved on a fake clock
      // (`LiveSyncHealBackstop`, `map_shell_receive_recovery_test.dart`):
      // a completion behind a stop arms nothing, and a mount arms only under
      // the strict read. What is pinned here is who calls which — every one.
      for (final handler in const ['_onPaused', '_onDetached', 'dispose']) {
        expect(
          _bodyOf(source, handler).toSource(),
          contains('_healBackstop.stop();'),
          reason: '$handler must stop the backstop',
        );
      }
      expect(
        _callsOf(source, '_startTimers'),
        [
          'initState: _startTimers(atMount: true)',
          '_onResumed: _startTimers(atMount: false)',
        ],
        reason: 'a third caller arms the backstop wherever it is called from',
      );
      expect(
        _armingUses(source),
        ['_startTimers: startAtMount()', '_startTimers: start()'],
        reason: 'armed from a completion, or from the consent edge, it ticks '
            'for the whole background window',
      );
      expect(
        _bodyOf(source, '_startTimers').toSource(),
        contains(
          'if (atMount) {_healBackstop.startAtMount();} '
          'else {_healBackstop.start();}',
        ),
      );
      expect(
        _bodyOf(source, 'startAtMount').toSource(),
        '{if (appIsResumed()) start();}',
        reason: 'a mount in a process the OS relaunched in the background '
            'reads `detached`, `inactive` or `paused`: a looser read arms a '
            'timer that re-establishes a dead session with nobody looking',
      );
    });
  });

  test('the re-subscriber holds the only start there is', () {
    // The gate lives where the start is. A second caller of
    // `SubscriptionService.start` would be a way to a session that never
    // reads whether one is wanted.
    final starts = <String>[];
    for (final file
        in Directory('lib')
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))) {
      final path = file.path.replaceAll(r'\', '/');
      if (path.startsWith('lib/src/rust/')) continue;
      final unit = parseString(
        content: file.readAsStringSync(),
        throwIfDiagnostics: false,
      ).unit;
      final collector = _StartCollector();
      unit.accept(collector);
      for (var i = 0; i < collector.found; i++) {
        starts.add(path);
      }
    }
    expect(starts, ['lib/src/services/live_sync_resubscriber.dart']);
  });
}

/// Counts calls of a method named `start` that carry a `groups:` argument —
/// the shape of `SubscriptionService.start` and of nothing else in `lib/`.
class _StartCollector extends RecursiveAstVisitor<void> {
  int found = 0;

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final isStart =
        node.methodName.name == 'start' &&
        node.argumentList.arguments.whereType<NamedExpression>().any(
          (a) => a.name.label.name == 'groups',
        );
    if (isStart) found++;
    super.visitMethodInvocation(node);
  }

  @override
  void visitComment(Comment node) {}
}
