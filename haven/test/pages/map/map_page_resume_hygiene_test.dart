/// What `MapPage` does — and no longer does — on a resume and on every GPS fix.
///
/// Two promises live here, both about work the user cannot see:
///
/// 1. A resume no longer sweeps the tile cache unconditionally. Eviction is a
///    disk scan plus deletes; ten shade-pull glances an hour used to be ten of
///    them. It now rides the ONE resume-extras decision `MapShell` takes, so
///    the map and the shell cannot throttle each other out of their turn.
/// 2. A GPS fix that arrives while the app is not foregrounded no longer
///    crosses the FFI to be obfuscated, nor rebuilds a map nobody is looking
///    at. On iOS with background sharing on, that stream keeps delivering for
///    the whole background window.
///
/// ## Why source guards
///
/// `MapPage.initState` calls `HavenCore.newInstance()` across the Rust bridge,
/// so the widget cannot be pumped in `flutter test` (see
/// `map_page_prefetch_test.dart`). `_onPositionStreamEvent`, `_runEviction`
/// and the lifecycle callback are all private. What only the page can answer
/// is whether the wiring is there; the analysis is AST-based and scoped to one
/// method body, so a comment or an unrelated call site cannot satisfy it —
/// both dodges are self-tested below.
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
/// assertion below is about statements that run.
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

/// The parsed body of [method] on [className].
///
/// The AST, not its text: "these two names appear in this order" cannot tell a
/// listener that RUNS the eviction from one that ignores its argument while an
/// unrelated call further down the method supplies the name — and cannot tell
/// a gate that skips the work from one that merely precedes it.
AstNode methodBodyNode(
  String source, {
  required String className,
  required String method,
}) {
  final unit = parseString(content: source, throwIfDiagnostics: false).unit;
  final visitor = _MethodBodyVisitor(className: className, method: method);
  unit.accept(visitor);
  final body = visitor.body;
  expect(
    body,
    isNotNull,
    reason: '$className.$method must exist — if it was renamed, update this '
        'guard rather than deleting it',
  );
  return body!;
}

/// The single `ref.listen…(<provider>, …)` invocation inside [body].
MethodInvocation listenOn(AstNode body, String provider) {
  final probe = _ListenVisitor(provider);
  body.accept(probe);
  expect(
    probe.found,
    hasLength(1),
    reason: 'expected exactly one ref.listen on $provider — none means the '
        'wiring is gone, two means this assertion is about whichever came '
        'first',
  );
  return probe.found.single;
}

/// The single `if` inside [body] whose condition mentions [token].
IfStatement ifOn(AstNode body, String token) {
  final probe = _IfVisitor(token);
  body.accept(probe);
  expect(
    probe.found,
    hasLength(1),
    reason: 'expected exactly one `if` gating on $token',
  );
  return probe.found.single;
}

/// The source offset of the single invocation of [name] inside [body].
int _invocationOffset(AstNode body, String name) {
  final probe = _InvocationVisitor(name);
  body.accept(probe);
  expect(
    probe.found,
    hasLength(1),
    reason: 'expected exactly one $name() call — a guard with no anchor is '
        'not a guard',
  );
  return probe.found.single.offset;
}

class _InvocationVisitor extends RecursiveAstVisitor<void> {
  _InvocationVisitor(this.name);

  final String name;
  final List<MethodInvocation> found = [];

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (node.methodName.name == name) found.add(node);
    super.visitMethodInvocation(node);
  }

  @override
  void visitComment(Comment node) {}
}

class _ListenVisitor extends RecursiveAstVisitor<void> {
  _ListenVisitor(this.provider);

  final String provider;
  final List<MethodInvocation> found = [];

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final isListen = node.methodName.name.startsWith('listen');
    final args = node.argumentList.arguments;
    if (isListen &&
        args.isNotEmpty &&
        args.first.toSource().contains(provider)) {
      found.add(node);
    }
    super.visitMethodInvocation(node);
  }

  @override
  void visitComment(Comment node) {}
}

class _IfVisitor extends RecursiveAstVisitor<void> {
  _IfVisitor(this.token);

  final String token;
  final List<IfStatement> found = [];

  @override
  void visitIfStatement(IfStatement node) {
    if (node.expression.toSource().contains(token)) found.add(node);
    super.visitIfStatement(node);
  }

  @override
  void visitComment(Comment node) {}
}

void main() {
  group('detector self-tests', () {
    test('reads the named method, not the file', () {
      const source = '''
class _MapPageState {
  void a() { first(); }
  void b() { second(); }
}
''';
      expect(
        methodBodySource(source, className: '_MapPageState', method: 'a'),
        contains('first()'),
      );
      expect(
        methodBodySource(source, className: '_MapPageState', method: 'a'),
        isNot(contains('second()')),
        reason: 'a guard satisfied by a sibling method proves nothing',
      );
    });

    test('is not satisfied by a comment describing the call', () {
      const source = '''
class _MapPageState {
  /// Calls _runEviction() on resume.
  void a() {
    // _runEviction();
  }
}
''';
      expect(
        methodBodySource(source, className: '_MapPageState', method: 'a'),
        isNot(contains('_runEviction')),
      );
    });

    test('returns null for a method that does not exist', () {
      expect(
        methodBodySource(
          'class _MapPageState { void a() {} }',
          className: '_MapPageState',
          method: 'missing',
        ),
        isNull,
        reason: 'a renamed method must fail the guard, not silently pass it',
      );
    });
  });

  group('the real source', () {
    late String source;

    setUpAll(() {
      final file = File('lib/src/pages/map/map_page.dart');
      expect(
        file.existsSync(),
        isTrue,
        reason: 'map_page.dart moved — update this guard, do not delete it',
      );
      source = file.readAsStringSync();
    });

    test('the resume callback no longer evicts on its own', () {
      final body = methodBodySource(
        source,
        className: '_MapPageState',
        method: 'didChangeAppLifecycleState',
      );
      expect(body, isNotNull);
      expect(
        body,
        isNot(contains('_runEviction')),
        reason: 'evicting straight off the lifecycle edge is exactly the '
            'unthrottled sweep the resume-extras window exists to remove',
      );
    });

    test('eviction is what the resume-extras listener DOES', () {
      // Containment, not appearance. "`lastResumeExtrasAtProvider` occurs, and
      // `_runEviction` occurs after it" is satisfied by a listener that
      // ignores its edge entirely while some unrelated call further down
      // `build` supplies the second name — leaving the tile cache growing
      // until the app restarts, with both names still in the file.
      final listen = listenOn(
        methodBodyNode(
          source,
          className: '_MapPageState',
          method: 'build',
        ),
        'lastResumeExtrasAtProvider',
      );
      expect(
        listen.argumentList.arguments.last.toSource(),
        contains('_runEviction'),
        reason: 'the page must observe the ONE decision the shell takes and '
            'act on it; a second throttle of its own would drift out of step',
      );
    });

    test('a fix arriving while backgrounded RETURNS before the FFI', () {
      // Containment again: `gateAt < applyAt` is equally true of
      //
      //   if (!ref.read(appForegroundProvider)) debugPrint('…');
      //   _updateLocationFromPosition(next.value);
      //
      // which obfuscates and rebuilds for every background fix — the whole
      // cost this gate exists to avoid, on the platform (iOS with background
      // sharing on) where the stream keeps delivering for hours.
      final body = methodBodyNode(
        source,
        className: '_MapPageState',
        method: '_onPositionStreamEvent',
      );
      final gate = ifOn(body, 'appForegroundProvider');
      expect(
        gate.expression.toSource(),
        '!ref.read(appForegroundProvider)',
        reason: 'the gate must skip on NOT-foregrounded',
      );
      expect(
        gate.thenStatement.toSource(),
        contains('return'),
        reason: 'a gate whose branch does not leave the method is not a gate',
      );
      expect(
        gate.thenStatement.toSource(),
        isNot(contains('_updateLocationFromPosition')),
        reason: 'the skipped branch must not do the work it skips',
      );
      final apply = _invocationOffset(body, '_updateLocationFromPosition');
      expect(
        apply,
        greaterThan(gate.end),
        reason: 'the FFI obfuscation and the setState must sit AFTER the '
            'gate, where the early return can actually prevent them',
      );
    });

    test('the user-initiated one-shot fix is never gated', () {
      // The disclosure/permission flow leaves the app `inactive`, and the
      // scrim clears only when a fix is applied. Gating this path would strand
      // a consenting user on "Getting location…" until the next stream fix.
      final body = methodBodySource(
        source,
        className: '_MapPageState',
        method: '_getLocation',
      );
      expect(body, isNotNull);
      expect(body, contains('_updateLocationFromPosition'));
      expect(
        body,
        isNot(contains('appForegroundProvider')),
        reason: 'the one-shot is asked for by the user, not by the OS',
      );
    });
  });
}
