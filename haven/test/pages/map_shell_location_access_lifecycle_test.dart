/// Pins what `MapShell` does at pause and at resume: it suspends the
/// location-access watchdog, releases the platform position subscription
/// itself, stops the live-sync engine when nothing needs it, and brings every
/// one of those back on the way in — ahead of the 30 s resume debounce.
///
/// ## Why this matters beyond battery
///
/// The watchdog exists to keep a USER-VISIBLE banner honest, and nobody is
/// looking while the app is backgrounded — but leaving it running is not
/// merely wasteful. Its recovery edge calls
/// `ref.invalidate(locationStreamProvider)`, and with background sharing OFF
/// that provider's rebuild runs `GeolocatorLocationService.clearCachedPosition()`.
/// So a blocked → available flip that happens while backgrounded tears down the
/// one geolocator stream the process has AND discards the cached fix the
/// publish path serves from, for a banner nobody can see. On Android it would
/// also keep firing platform calls for as long as the app is away.
///
/// `_onPaused` already cancels six timers; this one was simply never added to
/// the list.
///
/// ## Why a source guard
///
/// `_MapShellState`, `_onPaused` and the watchdog handle are all private, and
/// per CLAUDE.md `MapShell` cannot be pumped in `flutter test` — `MapPage`
/// reaches the Rust bridge in `initState`. The behaviour of `suspend()` itself
/// is covered at the unit level in `location_access_provider_test.dart`
/// ("suspend() stops probing until something re-arms it"); what only the shell
/// can answer is whether the pause path calls it, and whether the resume path
/// undoes it. The analysis is AST-based and scoped to the two method bodies, so
/// it cannot be satisfied by a comment or by an unrelated call elsewhere in a
/// 1500-line file — the detector is self-tested against both of those below.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:haven/src/providers/background_location_provider.dart';
import 'package:haven/src/providers/location_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/background_location_manager.dart';
import 'package:haven/src/services/geolocator_location_service.dart';

/// Whether [method] on [className] invokes `<provider>.notifier`'s [call].
///
/// Structural: it looks for a `<call>()` invocation whose receiver chain
/// mentions [provider], so neither a same-named call on something else nor a
/// mention in prose satisfies it.
bool methodCallsNotifierMember(
  String source, {
  required String className,
  required String method,
  required String provider,
  required String call,
}) {
  final unit = parseString(content: source, throwIfDiagnostics: false).unit;
  final visitor = _MethodBodyVisitor(className: className, method: method);
  unit.accept(visitor);
  final body = visitor.body;
  if (body == null) return false;
  final probe = _NotifierCallVisitor(provider: provider, call: call);
  body.accept(probe);
  return probe.found;
}

/// The executable source of [method] on [className], or null if absent.
///
/// `toSource()` reconstructs the body from the AST, so comments are GONE:
/// every ordering assertion below is about statements that run, and cannot be
/// satisfied by prose describing them.
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

/// The brace-balanced block starting at [open], which must index a `{`.
///
/// Slicing a branch by its opening brace rather than "everything after the
/// last `} else {`" is what keeps an assertion about ONE branch from being
/// satisfied — or dodged — by a sibling further down the method.
String _blockAt(String source, int open) {
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

/// The parsed body block of [method] on [className].
///
/// The AST itself, not its text: containment ("this call runs inside that
/// branch") and nesting depth ("this statement is not inside any conditional")
/// are structure, and every attempt to read them off offsets in a string has
/// the same hole — a call that merely FOLLOWS a branch reads exactly like one
/// inside it.
Block methodBlock(
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
    isA<BlockFunctionBody>(),
    reason: '$className.$method must exist with a block body — if it was '
        'renamed, update this guard rather than deleting it',
  );
  return (body! as BlockFunctionBody).block;
}

/// Every `if`/`for`/`while`/`do`/`switch`/`try` between [node] and [stop],
/// innermost first, rendered as source.
///
/// `if (…)` conditions come back as the bare condition so an assertion can
/// name the rule it expects; every other construct is labelled by kind, which
/// is enough to fail a call that was quietly wrapped in a loop or a `try`.
List<String> _enclosingControlFlow(AstNode node, AstNode stop) {
  final out = <String>[];
  for (var n = node.parent; n != null && n != stop; n = n.parent) {
    switch (n) {
      case IfStatement():
        out.add(n.expression.toSource());
      case ForStatement():
        out.add('for');
      case WhileStatement():
        out.add('while');
      case DoStatement():
        out.add('do');
      case SwitchStatement():
        out.add('switch');
      case TryStatement():
        out.add('try');
      case FunctionBody():
        // A closure body: everything above it belongs to another function.
        return out;
      case _:
        break;
    }
  }
  return out;
}

/// The one invocation of [name] that [block] runs ITSELF.
///
/// Calls nested inside a closure are excluded: `_onPaused` installs a
/// `listenManual` watcher whose callback releases the same things on the
/// consent-withdrawn edge, and those run later, from a different branch, under
/// a different condition. Requiring exactly one match is the anti-vacuity
/// half — a second direct call site would make "the enclosing condition" an
/// ambiguous question, and the test would silently answer it about whichever
/// came first.
MethodInvocation _invocationOf(Block block, String name) {
  final found = _invocationsOf(block, name);
  expect(
    found,
    hasLength(1),
    reason: 'expected exactly one direct $name() call in the method body — a '
        'guard with no anchor is not a guard, and one with two anchors is '
        'about whichever it happened to find first',
  );
  return found.single;
}

/// Every invocation of [name] that [block] runs ITSELF, for the calls a method
/// legitimately makes from more than one branch. The caller states how many it
/// expects — an unbounded loop over a possibly-empty list asserts nothing.
List<MethodInvocation> _invocationsOf(Block block, String name) {
  final probe = _InvocationVisitor(name: name, body: block.parent!);
  block.accept(probe);
  return probe.found;
}

/// The innermost `if` [node] sits inside.
IfStatement _enclosingIf(AstNode node) {
  for (var n = node.parent; n != null; n = n.parent) {
    if (n is IfStatement) return n;
  }
  fail('${node.toSource()} is not inside an if');
}

/// The condition of the one `if` in [block] whose test mentions [marker].
///
/// The `if` itself, never a text slice of the method: "the substring from the
/// last `if (` before X to the first `)) {` after Y" is a guess about
/// formatting, and it silently answers about a different expression the moment
/// a parenthesis moves.
Expression _conditionContaining(Block block, String marker) {
  final probe = _IfConditionVisitor(marker: marker, body: block.parent!);
  block.accept(probe);
  expect(
    probe.found,
    hasLength(1),
    reason: 'expected exactly one `if` testing $marker in the method body',
  );
  return probe.found.single;
}

/// The SMALLEST binary expression inside [condition] that has [left] on one
/// side and [right] on the other, or `null` if none does.
///
/// Smallest, because that is the one that decides how the two combine.
/// `false || (a && b)` answers `&&` — which is the whole point: an assertion
/// that merely looked for `||` anywhere in the condition would pass on it.
///
/// The node, not just its operator: the operands are matched by CONTAINMENT
/// (they have to be, since neither side is written out here), and containment
/// cannot tell `x` from `!x`. A caller that only reads the operator therefore
/// accepts a negated operand — the rule inverted, joined by the right
/// operator — so the operands are the caller's to assert exactly.
BinaryExpression? _joining(
  Expression condition, {
  required String left,
  required String right,
}) {
  final probe = _BinaryVisitor();
  condition.accept(probe);
  BinaryExpression? smallest;
  for (final node in probe.found) {
    final l = node.leftOperand.toSource();
    final r = node.rightOperand.toSource();
    final joins =
        (l.contains(left) && r.contains(right)) ||
        (l.contains(right) && r.contains(left));
    if (!joins) continue;
    if (smallest == null || node.length < smallest.length) smallest = node;
  }
  return smallest;
}

/// The operator of [_joining], or `null` when nothing joins the two.
String? _joiningOperator(
  Expression condition, {
  required String left,
  required String right,
}) => _joining(condition, left: left, right: right)?.operator.lexeme;

class _BinaryVisitor extends RecursiveAstVisitor<void> {
  final List<BinaryExpression> found = [];

  @override
  void visitBinaryExpression(BinaryExpression node) {
    found.add(node);
    super.visitBinaryExpression(node);
  }
}

class _IfConditionVisitor extends RecursiveAstVisitor<void> {
  _IfConditionVisitor({required this.marker, required this.body});

  final String marker;

  /// The [FunctionBody] a match must belong to directly.
  final AstNode body;

  final List<Expression> found = [];

  @override
  void visitIfStatement(IfStatement node) {
    if (node.expression.toSource().contains(marker)) {
      for (var n = node.parent; n != null; n = n.parent) {
        if (n is FunctionBody) {
          if (identical(n, body)) found.add(node.expression);
          break;
        }
      }
    }
    super.visitIfStatement(node);
  }

  @override
  void visitComment(Comment node) {}
}

/// Collects the `return`s a method body executes ITSELF (never a closure's)
/// that appear before [beforeOffset].
class _ReturnVisitor extends RecursiveAstVisitor<void> {
  _ReturnVisitor({required this.body, required this.beforeOffset});

  final AstNode body;
  final int beforeOffset;
  final List<ReturnStatement> found = [];

  @override
  void visitReturnStatement(ReturnStatement node) {
    if (node.offset < beforeOffset) {
      for (var n = node.parent; n != null; n = n.parent) {
        if (n is FunctionBody) {
          if (identical(n, body)) found.add(node);
          break;
        }
      }
    }
    super.visitReturnStatement(node);
  }
}

/// Collects every assignment whose left-hand side is exactly [target].
class _AssignmentVisitor extends RecursiveAstVisitor<void> {
  _AssignmentVisitor({required this.target});

  final String target;
  final List<String> sources = [];

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    if (node.leftHandSide.toSource() == target) sources.add(node.toSource());
    super.visitAssignmentExpression(node);
  }

  @override
  void visitComment(Comment node) {}
}

class _InvocationVisitor extends RecursiveAstVisitor<void> {
  _InvocationVisitor({required this.name, required this.body});

  final String name;

  /// The [FunctionBody] a match must belong to directly.
  final AstNode body;

  final List<MethodInvocation> found = [];

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (node.methodName.name == name) {
      for (var n = node.parent; n != null; n = n.parent) {
        if (n is FunctionBody) {
          if (identical(n, body)) found.add(node);
          break;
        }
      }
    }
    super.visitMethodInvocation(node);
  }

  @override
  void visitComment(Comment node) {}
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

class _NotifierCallVisitor extends RecursiveAstVisitor<void> {
  _NotifierCallVisitor({required this.provider, required this.call});

  final String provider;
  final String call;
  bool found = false;

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (node.methodName.name == call) {
      final target = node.target;
      if (target != null && target.toSource().contains(provider)) found = true;
    }
    super.visitMethodInvocation(node);
  }

  // Doc-comment references parse to real identifiers; a guard that walked into
  // them could be satisfied by the comment describing the call.
  @override
  void visitComment(Comment node) {}
}

void main() {
  group('detector self-tests', () {
    const good = '''
class _MapShellState {
  Future<void> _onPaused() async {
    ref.read(locationAccessProvider.notifier).suspend();
  }
}
''';

    test('finds the call in the named method', () {
      expect(
        methodCallsNotifierMember(
          good,
          className: '_MapShellState',
          method: '_onPaused',
          provider: 'locationAccessProvider',
          call: 'suspend',
        ),
        isTrue,
      );
    });

    test('does not accept the call from a DIFFERENT method', () {
      const elsewhere = '''
class _MapShellState {
  Future<void> _onPaused() async {}
  void dispose() {
    ref.read(locationAccessProvider.notifier).suspend();
  }
}
''';
      expect(
        methodCallsNotifierMember(
          elsewhere,
          className: '_MapShellState',
          method: '_onPaused',
          provider: 'locationAccessProvider',
          call: 'suspend',
        ),
        isFalse,
        reason: 'suspending on dispose instead of on pause would leave the '
            'whole backgrounded window uncovered',
      );
    });

    test('does not accept a same-named call on a different provider', () {
      const wrongProvider = '''
class _MapShellState {
  Future<void> _onPaused() async {
    ref.read(someOtherProvider.notifier).suspend();
  }
}
''';
      expect(
        methodCallsNotifierMember(
          wrongProvider,
          className: '_MapShellState',
          method: '_onPaused',
          provider: 'locationAccessProvider',
          call: 'suspend',
        ),
        isFalse,
      );
    });

    group('_joiningOperator', () {
      Expression conditionOf(String test) => _conditionContaining(
        methodBlock(
          'class _S { void go() { if ($test) { doIt(); } } }',
          className: '_S',
          method: 'go',
        ),
        'shouldReanchorOnResume',
      );

      String? join(String test) => _joiningOperator(
        conditionOf(test),
        left: 'isPaused',
        right: 'shouldReanchorOnResume',
      );

      test('reads the operator that actually joins the two', () {
        expect(join('e.isPaused || shouldReanchorOnResume(a)'), '||');
        expect(
          join('flag && (e.isPaused || shouldReanchorOnResume(a))'),
          '||',
          reason: 'an outer AND on an unrelated guard is not the join',
        );
        expect(
          join('e.isPaused || burst != null || shouldReanchorOnResume(a)'),
          '||',
          reason: 'a third disjunct between them does not change how the two '
              'combine',
        );
      });

      test('rejects the decoy the old `contains("||")` accepted', () {
        // THE mutation this helper exists for. It contains `||`, and it is
        // exactly the defect: a paused engine made stricter, not exempt.
        expect(
          join('false || (e.isPaused && shouldReanchorOnResume(a))'),
          '&&',
          reason: 'the join is the AND, whatever else the condition contains',
        );
        expect(join('e.isPaused && shouldReanchorOnResume(a)'), '&&');
      });

      test('answers null when they are not joined at all', () {
        expect(
          _joiningOperator(
            conditionOf('shouldReanchorOnResume(a)'),
            left: 'isPaused',
            right: 'shouldReanchorOnResume',
          ),
          isNull,
          reason: 'a missing operand must not read as a passing join',
        );
      });

      test('matches a NEGATED operand, which is why the node is returned', () {
        // Containment cannot tell `x` from `!x`, so the OPERATOR alone accepts
        // the rule inverted — same operator, opposite meaning. Returning the
        // node is what lets a caller assert the operand it actually wants.
        final join = _joining(
          conditionOf('e.isPaused && !shouldReanchorOnResume(a)'),
          left: 'isPaused',
          right: 'shouldReanchorOnResume',
        );
        expect(join, isNotNull);
        expect(join!.operator.lexeme, '&&');
        expect(join.rightOperand.toSource(), '!shouldReanchorOnResume(a)');
      });
    });

    test('is not satisfied by a comment describing the call', () {
      const prose = '''
class _MapShellState {
  /// Calls [locationAccessProvider].notifier.suspend() on pause.
  Future<void> _onPaused() async {
    // ref.read(locationAccessProvider.notifier).suspend();
  }
}
''';
      expect(
        methodCallsNotifierMember(
          prose,
          className: '_MapShellState',
          method: '_onPaused',
          provider: 'locationAccessProvider',
          call: 'suspend',
        ),
        isFalse,
        reason: 'a guard that a comment can satisfy is not a guard',
      );
    });
  });

  group('the real source', () {
    late String source;

    setUpAll(() {
      final file = File('lib/src/pages/map_shell.dart');
      expect(
        file.existsSync(),
        isTrue,
        reason: 'map_shell.dart moved — update this guard, do not delete it',
      );
      source = file.readAsStringSync();
    });

    test('_onPaused suspends the location-access watchdog', () {
      expect(
        methodCallsNotifierMember(
          source,
          className: '_MapShellState',
          method: '_onPaused',
          provider: 'locationAccessProvider',
          call: 'suspend',
        ),
        isTrue,
        reason: 'the watchdog would keep probing for the whole backgrounded '
            'window, and a recovery edge there invalidates the position '
            'stream — which also wipes the publish path\'s cached fix when '
            'background sharing is off',
      );
    });

    test('_onResumed re-decides it from a fresh platform read', () {
      // The other half: suspend() must not be a one-way door. `refresh()` is
      // what re-arms, and it deliberately runs BEFORE the resume debounce,
      // since leaving to change a system toggle and coming straight back lands
      // well inside that window.
      expect(
        methodCallsNotifierMember(
          source,
          className: '_MapShellState',
          method: '_onResumed',
          provider: 'locationAccessProvider',
          call: 'refresh',
        ),
        isTrue,
        reason: 'without this the banner stays frozen at whatever it said when '
            'the app was backgrounded, for the rest of the session',
      );
      final resumeAt = source.indexOf('Future<void> _onResumed() async {');
      expect(resumeAt, isNonNegative);
      final debounceAt = source.indexOf('_resumeStopwatch.isRunning', resumeAt);
      final refreshAt = source.indexOf(
        'locationAccessProvider.notifier',
        resumeAt,
      );
      expect(refreshAt, isNonNegative);
      expect(
        refreshAt,
        lessThan(debounceAt),
        reason: 'gating the re-check behind the 30 s resume debounce would '
            'leave the banner stale in exactly the case it exists for — the '
            'user who just left to flip a system toggle and came straight '
            'back',
      );
    });

    test('_onResumed lifts the suspension explicitly, before refreshing', () {
      // `refresh()` deliberately does NOT clear the suspension: it is also
      // reached from the stream-error branch, from the map's retry button and
      // from a failed one-shot read. A permission revoked in Settings while
      // the app is away would otherwise re-open the 30 s probe loop for the
      // whole backgrounded window — the exact cost `suspend()` exists to
      // remove.
      expect(
        methodCallsNotifierMember(
          source,
          className: '_MapShellState',
          method: '_onResumed',
          provider: 'locationAccessProvider',
          call: 'resume',
        ),
        isTrue,
        reason: 'without an explicit resume() the watchdog stays suspended for '
            'the rest of the session and the banner never updates again',
      );
      final body = methodBodySource(
        source,
        className: '_MapShellState',
        method: '_onResumed',
      );
      expect(body, isNotNull);
      expect(
        body!.indexOf('.resume()'),
        lessThan(body.indexOf('.refresh()')),
        reason: 'refreshing while still suspended publishes a verdict but arms '
            'nothing, so the watchdog would be dead until the next pause',
      );
    });
  });

  group('the foreground state reaches the provider', () {
    late String source;

    setUpAll(() {
      source = File('lib/src/pages/map_shell.dart').readAsStringSync();
    });

    test('_setForegroundActive writes appForegroundProvider', () {
      // `locationStreamProvider` refuses to START a session while this reads
      // false, which is what makes an iOS SLC/region background LAUNCH safe.
      // Its initial value is derived from the binding, so without this write
      // that launch would hold the never-emitting placeholder past its first
      // resume — a map with no position stream for the rest of the process.
      final body = methodBodySource(
        source,
        className: '_MapShellState',
        method: '_setForegroundActive',
      );
      expect(body, isNotNull);
      expect(
        body,
        contains('ref.read(appForegroundProvider.notifier).state = active'),
        reason: 'the lifecycle mirror is the only writer of this provider',
      );
      // `ref` on a `ConsumerState` is usable only while mounted, and
      // `detached` dispatches this from a tear-down that may already have
      // unmounted the element — where the write throws.
      expect(
        body!.indexOf('if (!mounted) return;'),
        allOf(
          isNonNegative,
          lessThan(body.indexOf('appForegroundProvider')),
        ),
        reason: 'the liveness guard must precede the write it protects',
      );
    });

    test('every lifecycle edge sets it before running its handler', () {
      final body = methodBodySource(
        source,
        className: '_MapShellState',
        method: 'didChangeAppLifecycleState',
      );
      expect(body, isNotNull);
      for (final pair in const [
        ['_setForegroundActive(false)', '_onPaused()'],
        ['_setForegroundActive(true)', '_onResumed()'],
        ['_setForegroundActive(false)', '_onDetached()'],
      ]) {
        final flag = body!.indexOf(pair[0]);
        final handler = body.indexOf(pair[1]);
        expect(flag, isNonNegative, reason: '${pair[0]} must be dispatched');
        expect(handler, isNonNegative, reason: '${pair[1]} must be dispatched');
        expect(
          flag,
          lessThan(handler),
          reason: '${pair[1]} reads the state ${pair[0]} establishes',
        );
      }
    });
  });

  group('_onPaused releases the platform position subscription', () {
    late String pausedBody;
    late Block pausedBlock;

    setUpAll(() {
      final source = File('lib/src/pages/map_shell.dart').readAsStringSync();
      final body = methodBodySource(
        source,
        className: '_MapShellState',
        method: '_onPaused',
      );
      expect(body, isNotNull, reason: '_onPaused must exist');
      pausedBody = body!;
      pausedBlock = methodBlock(
        source,
        className: '_MapShellState',
        method: '_onPaused',
      );
    });

    test('suspendStream precedes markForegroundActive(active: false)', () {
      // The Android pause tells the foreground service to take publishing
      // over. Releasing GPS after that write leaves two isolates holding a
      // location client at the same time — the drain this whole packet exists
      // to remove, doubled.
      final suspend = pausedBody.indexOf('suspendStream()');
      final ownership = pausedBody.indexOf(
        'markForegroundActive(active: false)',
      );
      expect(
        suspend,
        isNonNegative,
        reason: 'the UI isolate must release its own 1 Hz / 1 m registration; '
            'nothing else cancels it for the whole backgrounded window',
      );
      expect(
        ownership,
        isNonNegative,
        reason: 'anti-vacuity: without the ownership write there is no '
            'ordering to assert',
      );
      expect(suspend, lessThan(ownership));
    });

    test('suspendStream is CONTAINED by the keep rule, not merely preceded '
        'by it', () {
      // The iOS background-sharing stream IS the process keep-alive, so the
      // one place that decides whether to release it must be the one place
      // that owns that rule. A hand-rolled `Platform.isIOS` test beside it is
      // how the two silently diverge — and the symptom is background
      // publishing simply ending.
      //
      // Containment, not order. "The nearest `if (` before the call names the
      // keep rule" is satisfied by
      //
      //   if (!shouldKeepLocationStreamWhilePaused(...)) { _log(); }
      //   locationService?.suspendStream();
      //
      // which releases on EVERY pause — the exact regression the rule exists
      // to prevent, wearing the rule's own name.
      final enclosing = _enclosingControlFlow(
        _invocationOf(pausedBlock, 'suspendStream'),
        pausedBlock,
      );
      expect(
        enclosing,
        isNotEmpty,
        reason: 'an unconditional release kills the iOS keep-alive too',
      );
      expect(
        enclosing.first,
        startsWith('!shouldKeepLocationStreamWhilePaused('),
        reason: 'the release must run INSIDE the keep rule, and the keep rule '
            'has exactly one definition',
      );
    });

    test('the cached fix is cleared inside the consent condition, not the '
        'keep rule', () {
      // Rule 10: with background sharing off no coordinate may survive the
      // pause on either platform. With it on, the warm Android fix still
      // serves the resume publish inside its freshness window — clearing on
      // `!keep` would conflate "not iOS" with "no consent" and throw it away.
      //
      // Containment again: a clear that merely FOLLOWS `if (!bgEnabled) …`
      // discards the fix the Android resume publish serves from, on every
      // pause, for consenting users.
      final enclosing = _enclosingControlFlow(
        _invocationOf(pausedBlock, 'clearCachedPosition'),
        pausedBlock,
      );
      expect(
        enclosing,
        isNotEmpty,
        reason: 'an unconditional clear throws away the fix the Android '
            'resume publish serves from',
      );
      expect(
        enclosing.first,
        '!bgEnabled',
        reason: 'the clear is gated on consent, never on the keep rule',
      );
    });

    test('the maintenance timers are cancelled on the way out, and the R1 '
        'edge re-arms the receive path', () {
      // Out: unconditional, on every platform. The scheduler's arming gate
      // only refuses to RE-arm after a tick settles, so without this call a
      // pause landing between two ticks still bought one KeyPackage and one
      // relay-list relay round-trip from the timers already armed — sockets
      // opened for a backgrounded device, unrelated to any send.
      // `suspendForBackground` itself decides what survives, so the call site
      // must not second-guess it with a platform test of its own.
      final suspend = _invocationOf(pausedBlock, 'suspendForBackground');
      expect(
        _enclosingControlFlow(suspend, pausedBlock),
        isEmpty,
        reason: 'the cancel belongs on every pause path; a branch here would '
            'leave the other paths paying for the timers that were armed',
      );

      // In: the R1 edge. A pause that raced the background-sharing notifier's
      // async load read a stale `false` and stopped every driver with it; when
      // the persisted consent resolves `true` the paused process becomes the
      // background receiver, and this is the only thing that re-arms it.
      //
      // THIS ROW USED TO REQUIRE `rearmHealthForBackgroundReceive()`, and it
      // is replaced rather than deleted: the promise it was written for — "the
      // receive repair is re-armed on exactly the branch that is receiving" —
      // is still owed, but a 15-minute health timer is no longer what pays it
      // and is now actively harmful. Since P4 the background receive path is
      // one bounded burst per publish tick; a health tick landing between
      // bursts inspects a paused engine and learns nothing, and one landing
      // DURING a burst repairs the mid-`connect()` pool through the FOREGROUND
      // re-anchor — standing REQs and a 49-hour inbox replay, at an instant
      // that is not a publish. `_armHealth` refuses while backgrounded for
      // that reason, so the old call is inert; requiring an inert call is
      // exactly the coverage-without-a-guarantee this suite must not report.
      final rearmAt = pausedBody.indexOf('if (next) ');
      expect(
        rearmAt,
        isNonNegative,
        reason: 'the mid-pause consent watcher must still have a re-arm branch',
      );
      final rearm = _blockAt(pausedBody, rearmAt + 'if (next) '.length);
      expect(
        rearm,
        contains('_installBurstCoordinator()'),
        reason: 'without this the R1 edge publishes over a standing '
            'subscription and an open socket for the whole background window '
            '— the pre-P4 shape, on the one branch that reached the burst '
            'state late',
      );
      final install = rearm.indexOf('_installBurstCoordinator()');
      final start = rearm.indexOf('startScheduling()');
      expect(start, isNonNegative);
      expect(
        start,
        lessThan(install),
        reason: 'the burst publisher hard-gates on the active flag the '
            'scheduler keeps, and only startScheduling() raises it — a sink '
            'installed '
            'ahead of it produces bursts that open a socket, wait out a '
            'backlog, publish nothing and pause',
      );
      expect(
        rearm,
        isNot(contains('rearmHealthForBackgroundReceive')),
        reason: 'R14: no branch reached while the app is paused may arm a '
            'background Dart timer, and this one is inert as well as unwanted',
      );
    });

    test('the iOS background branch hands the publish ticks to a burst', () {
      // The install is the whole of P4's Dart half: without it `setTickSink`
      // has no production caller and the coordinator is inert — every tick
      // publishes directly, over a socket and a standing subscription held for
      // the entire background window.
      //
      // Containment, not order: the install must sit INSIDE the branch that
      // keeps publishing. The other three pause branches call
      // `stopScheduling()`, and both `BurstPublisher` methods refuse while the
      // scheduler is inactive, so a sink installed there would open a socket,
      // wait, publish nothing and pause.
      final install = _invocationOf(pausedBlock, '_installBurstCoordinator');
      final enclosing = _enclosingControlFlow(install, pausedBlock);
      expect(
        enclosing,
        isNotEmpty,
        reason: 'an unconditional install routes Android and the sharing-off '
            'pause through bursts that can publish nothing',
      );
      expect(
        enclosing.first,
        startsWith('MapShell.shouldKeepPublishingWhilePaused('),
        reason: 'the install belongs to the ONE rule that names the branch '
            'whose publish drivers keep running',
      );
    });

    test('the burst branch starts closed, on the named rule', () {
      // Without an immediate first burst the branch pauses with the
      // foreground's standing REQ and socket still up until whichever circle
      // ticks first — up to a full jittered publish interval of exactly the
      // continuous connection this phase removes.
      final drive = _invocationOf(pausedBlock, '_driveBurstNow');
      final enclosing = _enclosingControlFlow(drive, pausedBlock);
      // This used to read `startsWith('MapShell.shouldBurstImmediatelyOnPause(')`
      // on the whole condition and was relaxed to `contains` when the
      // eligible-set check was put in front of it — which accepts
      // `burstCircles.isNotEmpty && !MapShell.shouldBurstImmediatelyOnPause(…)`
      // — same operator, rule inverted — and that bursts EXACTLY inside the
      // 60 s overlap guard: open the app (the resume publishes), glance,
      // background 5 s later, and every circle is re-published, one extra
      // presence instant per circle relay.
      //
      // So the condition is identified rather than pattern-matched, and its
      // operands are asserted below.
      final condition = _conditionContaining(
        pausedBlock,
        'shouldBurstImmediatelyOnPause',
      );
      expect(
        enclosing.first,
        condition.toSource(),
        reason: 'the `if` guarding the burst must BE the one testing the named '
            'rule (which the overlap guard derives), not a branch shape that '
            'merely mentions it — an unconditional burst re-sends what a '
            'resume published seconds ago',
      );
      final join = _joining(
        condition,
        left: 'burstCircles.isNotEmpty',
        right: 'shouldBurstImmediatelyOnPause',
      );
      expect(
        join,
        isNotNull,
        reason: 'anti-vacuity: the two must be joined at all',
      );
      expect(
        join!.operator.lexeme,
        '&&',
        reason: 'the eligible-set check only ADDS to the named rule — an `||` '
            'reads as "a circle is due OR the guard has passed" and drives a '
            'burst on an empty tick list, or inside the guard the rule exists '
            'to hold',
      );
      expect(
        join.leftOperand.toSource(),
        'burstCircles.isNotEmpty',
        reason: 'negated, it bursts only when there is nothing to burst',
      );
      expect(
        join.rightOperand.toSource(),
        'MapShell.shouldBurstImmediatelyOnPause('
            'lastPublishAt: _lastPublishTime, now: pausedAt)',
        reason: 'the rule is CONSULTED, never inverted, and it is asked about '
            "this shell's own last publish and this pause's instant",
      );
      expect(
        enclosing[1],
        startsWith('MapShell.shouldKeepPublishingWhilePaused('),
        reason: 'and it runs only on the branch that installed the sink',
      );
    });

    test('the C4 opt-out branch releases the burst plane', () {
      // Consent withdrawn mid-pause must leave NO socket, whatever the burst
      // plane is doing. The branch is only reachable while the process is
      // PAUSED and `MapShell` cannot be pumped, so what the release DOES is
      // proved in `map_shell_burst_wiring_test.dart`; this is the half that
      // says the branch still calls it.
      //
      // Sliced by branch rather than searched for in the method: the call
      // lives inside the `listenManual` callback, and "somewhere in
      // `_onPaused`" would be satisfied by a release on the branch that runs
      // for users who withdrew nothing.
      const marker = 'if (next) ';
      final rearmAt = pausedBody.indexOf(marker);
      expect(rearmAt, isNonNegative);
      final rearm = _blockAt(pausedBody, rearmAt + marker.length);
      final optOut = pausedBody.substring(
        rearmAt + marker.length + rearm.length,
      );
      expect(
        optOut,
        contains('releaseBurstPlaneOnOptOut('),
        reason: 'without it, withdrawn consent leaves the engine subscribed '
            'and the publish socket open until iOS happens to suspend the '
            'process — a non-deterministic window of continued presence after '
            'the user said stop',
      );
      expect(
        rearm,
        isNot(contains('releaseBurstPlaneOnOptOut(')),
        reason: 'on the re-arm branch it would pause the engine of a user who '
            'just consented',
      );
    });

    test('every engine stop on a pause path is behind the named rule', () {
      // Two call sites, and the second is the fix: the rule's iOS arm used to
      // be unreachable, because its only caller sat inside the branch that
      // `else if (Platform.isIOS)` had already claimed — so `isIOS:` there was
      // constant-false, and a user who had turned background sharing OFF still
      // held every per-circle REQ, the inbox REQ, the engine socket and the
      // crate's 55 s pinger for the whole background window. Nothing failed,
      // because `pausedRelayOwner` returning `none` only closes the PUBLISH
      // pool.
      final stops = _invocationsOf(pausedBlock, '_stopLiveSyncBounded');
      expect(
        stops,
        hasLength(2),
        reason: 'the Android branch and the iOS branch — a third direct stop '
            'would be one this rule does not own',
      );
      for (final stop in stops) {
        expect(
          _enclosingControlFlow(stop, pausedBlock).first,
          'MapShell.shouldStopLiveSyncOnPause(isIOS: Platform.isIOS, '
              'backgroundSharingEnabled: bgEnabled)',
          reason: 'the decision belongs to the named rule, asked about the '
              'real platform AND the toggle this pause read — a hand-rolled '
              'test beside it is how the two silently diverge, and dropping '
              'the toggle stops the one branch that must keep receiving',
        );
      }
    });

    test('the iOS arm that keeps publishing never stops the engine', () {
      // The one exemption the rule carries, proved where it is USED: with
      // sharing on, this paused process IS the receiver — the burst plane owns
      // the engine and a stop here ends background delivery outright. The rule
      // is consulted OUTSIDE this arm, so only the arm itself can say the stop
      // does not also live inside it.
      final keep =
          _conditionContaining(pausedBlock, 'shouldKeepPublishingWhilePaused')
                  .parent!
              as IfStatement;
      final burstArm = keep.thenStatement.toSource();
      expect(
        burstArm,
        contains('_installBurstCoordinator()'),
        reason: 'anti-vacuity: this is the arm that hands the plane over',
      );
      for (final stop in const [
        '_stopLiveSyncBounded',
        'shouldStopLiveSyncOnPause',
        'releaseForHandoff',
        '_handOffMlsSession',
      ]) {
        expect(
          burstArm,
          isNot(contains(stop)),
          reason: 'the iOS sharing-on arm must not reach $stop — this process '
              'is the one that keeps receiving while the app is away',
        );
      }
    });

    test('both platform branches stop the engine and neither latches a '
        'handoff', () {
      // With sharing off nothing reclaims this session, on either platform, so
      // `releaseForHandoff()` must NOT come with the stop: the latch fails
      // every `getCircleManagerFfi()` closed until the next resume — which the
      // R1 watcher would then publish against.
      final platformIf = _enclosingIf(
        _conditionContaining(pausedBlock, 'shouldKeepPublishingWhilePaused')
            .parent!,
      );
      expect(
        platformIf.expression.toSource(),
        'Platform.isIOS',
        reason: 'anti-vacuity: the arms below must be the iOS branch and the '
            'Android-with-sharing-off one it falls through to',
      );
      for (final branch in [
        platformIf.thenStatement.toSource(),
        platformIf.elseStatement!.toSource(),
      ]) {
        expect(
          branch,
          contains('_stopLiveSyncBounded()'),
          reason: 'the engine must be stopped, through the ONE bounded stop '
              'path',
        );
        expect(
          branch,
          isNot(contains('releaseForHandoff')),
          reason: 'a latch nobody ends until resume, for a handoff nobody '
              'takes',
        );
        expect(
          branch,
          isNot(contains('_handOffMlsSession')),
          reason: 'same, one level up',
        );
      }
    });
  });

  group('_onResumed order', () {
    late String resumeBody;
    late Block resumeBlock;

    setUpAll(() {
      final source = File('lib/src/pages/map_shell.dart').readAsStringSync();
      final body = methodBodySource(
        source,
        className: '_MapShellState',
        method: '_onResumed',
      );
      expect(body, isNotNull, reason: '_onResumed must exist');
      resumeBody = body!;
      resumeBlock = methodBlock(
        source,
        className: '_MapShellState',
        method: '_onResumed',
      );
    });

    test('the stream restart is the first thing the resume does', () {
      // The ONLY restart site, and foregrounded by construction: iOS refuses
      // to start a background-capable session from the background, so a
      // restart anywhere else is a silent end to background publishing.
      final restart = resumeBody.indexOf('resumeStream()');
      expect(restart, isNonNegative);
      expect(
        restart,
        lessThan(resumeBody.indexOf('_resumeStopwatch.isRunning')),
        reason: 'behind the debounce, a glance-and-return would come back to a '
            'map with no position stream at all',
      );
    });

    test('the reclaim block and _startTimers() precede the debounce', () {
      // THE DEFECT THIS CLOSES. `_onPaused` stops the publish scheduler, the
      // motion trigger and the foreground-active heartbeat on every pause, and
      // `_startTimers()` is the only thing that starts them again — but it sat
      // BELOW the 30 s debounce, and so did the ownership stamp. So a
      // pause/resume pair inside 30 s (a shade pull, a lock-screen check, an
      // app-switcher peek — exactly what the debounce exists to absorb)
      // returned early with every publish driver dead and the stamp still
      // reading "backgrounded": the foreground published nothing, the service
      // correctly declined to publish against a live foreground app, and the
      // notification kept saying Haven was sending and receiving.
      final debounce = resumeBody.indexOf('_resumeStopwatch.isRunning');
      expect(debounce, isNonNegative, reason: 'the debounce must still exist');
      for (final anchor in const [
        'markForegroundActive(active: true)',
        'waitUntilIdle()',
        'readLastPublishTime()',
        '_startTimers()',
      ]) {
        final at = resumeBody.indexOf(anchor);
        expect(at, isNonNegative, reason: '$anchor must still run on resume');
        expect(
          at,
          lessThan(debounce),
          reason: '$anchor behind the debounce means a glance-and-return comes '
              'back with publishing dead until some later resume happens to '
              'land more than 30 s after the previous one',
        );
      }
    });

    test('the debounced early return carries no repair of its own', () {
      // The heal backstop used to be re-armed inside the early return, because
      // `_startTimers()` (which re-arms it) was unreachable from there. With
      // the timers moved above the debounce that duplicate is not merely
      // redundant — it is the tell that something load-bearing is still
      // trapped below.
      final debounce = resumeBody.indexOf('_resumeStopwatch.isRunning');
      final returnAt = resumeBody.indexOf('return;', debounce);
      expect(returnAt, isNonNegative);
      expect(
        resumeBody.substring(debounce, returnAt),
        isNot(contains('_rearmLiveSyncHealTimer')),
        reason: 'the debounced path must not need to repair anything; if it '
            'does, that repair belongs above the debounce',
      );
    });

    test('the resume takes the publish ticks back from the burst plane', () {
      // ONE line restores the foreground direct publish: with no sink a tick
      // publishes here and now, over the engine's own standing subscription —
      // which is what a foregrounded app is allowed to hold. Left installed,
      // every foreground publish would pay an open/settle/pause cycle AND
      // pause the engine after itself, so a foregrounded map would go blind
      // between its own publishes.
      final clear = _invocationOf(resumeBlock, 'setTickSink');
      expect(
        clear.argumentList.arguments.single.toSource(),
        'null',
        reason: 'the resume CLEARS the sink; installing one here would route '
            'the foreground through bursts',
      );
      final statement = clear.parent?.parent;
      expect(
        identical(statement, resumeBlock),
        isTrue,
        reason: 'a conditional here leaves the foreground bursting on '
            'whichever path skips it',
      );
      expect(
        resumeBody.indexOf('setTickSink('),
        lessThan(resumeBody.indexOf('_resumeStopwatch.isRunning')),
        reason: 'behind the 30 s debounce, a glance-and-return would come back '
            'to a foreground that still publishes in bursts and pauses the '
            'engine after each one',
      );
    });

    test('the paused engine BYPASSES the re-anchor throttle', () {
      // The 60 s throttle exists because a second re-anchor inside it
      // "re-queries a window the first already covered". That premise holds
      // for a LIVE engine, which kept its REQs and advanced its cursors. It is
      // false for a PAUSED one: it holds no REQ at all, so it covered nothing.
      //
      // Without the bypass, a glance landing inside 60 s of the last
      // background burst returns to the foreground with the engine still
      // paused — no standing subscription until the next publish tick, on the
      // one plane a foregrounded app must have live. Nothing behavioural can
      // see it (`MapShell` cannot be pumped), and both readings pass every
      // other test in this file.
      final guardAt = resumeBody.indexOf('shouldReanchorOnResume(');
      expect(guardAt, isNonNegative, reason: 'the throttle must still exist');
      final pausedAt = resumeBody.indexOf('isPaused');
      expect(
        pausedAt,
        isNonNegative,
        reason: 'the resume must consult the paused state of the engine at '
            'all',
      );
      final reanchorAt = resumeBody.indexOf('reanchorOnResume(');
      expect(
        pausedAt,
        lessThan(reanchorAt),
        reason: 'it gates the re-anchor, it does not follow it',
      );
      // The two must be ONE condition, joined by `||`.
      //
      // THIS ASSERTION USED TO BE `condition.contains('||')` over a slice of
      // the whole `if`, and it is REPLACED rather than deleted because that
      // shape is satisfied by a decoy: `false || (isPaused &&
      // shouldReanchorOnResume(...))` contains `||`, and is literally the
      // defect the test is named after — a paused engine made STRICTER rather
      // than exempt, left un-anchored for another 60 s. What has to be true is
      // about the operator JOINING the two operands, not about a character
      // appearing somewhere in the condition, so that is what is asserted:
      // the smallest expression containing both must be a `||` with one of
      // them on each side.
      final join = _joiningOperator(
        _conditionContaining(resumeBlock, 'shouldReanchorOnResume'),
        left: 'isPaused',
        right: 'shouldReanchorOnResume',
      );
      expect(
        join,
        '||',
        reason: 'the paused engine BYPASSES the throttle; ANDing them would '
            'leave a paused engine un-anchored for another 60 s, which is the '
            'defect wearing the name of the fix',
      );
    });

    test('a burst still in flight also bypasses the throttle', () {
      // The third way in, and the one with the shortest fuse: a burst that
      // started at the pause instant is still running when the glance comes
      // back 1-3 s later, and the `pauseSubscriptions()` it ends in has not
      // happened YET — so `isPaused` reads FALSE here and the throttle would
      // swallow the resume. The burst then pauses an engine the foreground
      // owns, and nothing recovers it: `ensureRunning` reads `isRunning`
      // (true across a pause), the periodic heal short-circuits on it, and
      // `SharingHealthNotifier.refresh()` early-returns while paused, so the
      // banner holds at "healthy" while the device receives nothing.
      final join = _joiningOperator(
        _conditionContaining(resumeBlock, 'shouldReanchorOnResume'),
        left: 'burstInFlight',
        right: 'shouldReanchorOnResume',
      );
      expect(
        join,
        '||',
        reason: 'a burst in flight must reach the repair whatever the '
            'throttle says — the pause it is about to take is not one the '
            'throttle can have covered',
      );
    });

    test('the re-anchor is ORDERED behind the burst in flight', () {
      // Not merely "a re-anchor happens": the repair for a burst that pauses
      // AFTER the resume is a re-anchor that runs after that pause, and
      // `reanchorOnResume` is what owns that ordering (behaviourally proved in
      // `map_shell_burst_wiring_test.dart`). A bare `engine.resumeAfter
      // Background()` here — the pre-fix shape — re-anchors into the race
      // instead of behind it.
      final call = _invocationOf(resumeBlock, 'reanchorOnResume');
      final args = {
        for (final a in call.argumentList.arguments.whereType<NamedExpression>())
          a.name.label.name: a.expression.toSource(),
      };
      expect(
        args['burstInFlight'],
        'burstInFlight',
        reason: 'passing null (or omitting it) restores the defect: the '
            'repair has nothing to order itself behind',
      );
      expect(
        resumeBody,
        isNot(contains('engine.resumeAfterBackground()')),
        reason: 'the direct call is the racing shape this replaced',
      );
    });

    test('the maintenance timers are re-armed on the way in', () {
      // Nothing else re-arms them: they are not armed while backgrounded (each
      // one opens relay sockets unrelated to any send), and a tick that
      // settles while away deliberately leaves its timer unarmed.
      expect(
        resumeBody,
        contains('rearmForForeground()'),
        reason: 'without this the KeyPackage, relay-list and health tasks stop '
            'for the rest of the process after the first pause',
      );
    });

    // THE ORDER ASSERTIONS ABOVE ARE NOT ENOUGH, and this group is why.
    //
    // "`_startTimers()` appears before the debounce" is true of
    //
    //   if (_liveSync == null) return;
    //   _startTimers();
    //
    // and of `if (Platform.isAndroid) { _startTimers(); }` — both of which
    // re-open the exact wedge the move above closed: after a glance the
    // publish scheduler, the heartbeat and the motion trigger stay stopped
    // while the foreground-service notification still says Haven is sending.
    // Position cannot see the difference; only reachability can.
    //
    // `_MapShellState` is private and `MapShell` cannot be pumped (`MapPage`
    // reaches the Rust bridge in `initState`, CLAUDE.md), so reachability is
    // asserted structurally: the restarts are statements of the method body
    // itself, and the only `return` that may precede them is the liveness
    // check every Flutter `State` needs.
    test('the restarts are unconditional statements of the method body', () {
      for (final call in const ['_startTimers', 'rearmForForeground']) {
        final invocation = _invocationOf(resumeBlock, call);
        final statement = invocation.parent;
        expect(
          statement,
          isA<ExpressionStatement>(),
          reason: '$call() must be a plain statement',
        );
        expect(
          identical(statement!.parent, resumeBlock),
          isTrue,
          reason: '$call() sits inside a conditional, a loop or a try — every '
              'publish driver `_onPaused` stopped stays stopped on the paths '
              'that skip it, while the notification keeps claiming Haven is '
              'sending',
        );
      }
    });

    test('the only early return before the restarts is the liveness check',
        () {
      final startTimers = _invocationOf(resumeBlock, '_startTimers');
      final probe = _ReturnVisitor(
        body: resumeBlock.parent!,
        beforeOffset: startTimers.offset,
      );
      resumeBlock.accept(probe);
      expect(
        probe.found,
        isNotEmpty,
        reason: 'anti-vacuity: the Android reclaim block awaits, so it must '
            'still re-check `mounted` before touching `ref`',
      );
      for (final returnStatement in probe.found) {
        final enclosing = _enclosingControlFlow(returnStatement, resumeBlock);
        expect(
          enclosing,
          isNotEmpty,
          reason: 'an unconditional return above the restarts ends the resume '
              'for everyone',
        );
        // The INNERMOST condition, so the outer `if (Platform.isAndroid)` the
        // reclaim block already needs stays legal while any new predicate —
        // `_liveSync == null`, a flag, a platform test — does not. Anything
        // reachable with a live tree that returns here leaves the publish
        // scheduler, the heartbeat and the motion trigger stopped for the
        // rest of the session while the notification claims Haven is sending.
        expect(
          enclosing.first,
          '!mounted',
          reason: 'the only reason to abandon a resume is a torn-down tree',
        );
      }
    });

    test('the Android reclaim is gated by the platform and nothing else', () {
      // These three are the ownership handshake with the foreground service.
      // Each is Android-only, and each must be reached on EVERY Android
      // resume: the stamp is what stops the service publishing on behalf of a
      // foregrounded app, and the drain is what keeps the two off the same
      // in-flight encrypt.
      for (final call in const [
        'markForegroundActive',
        'waitUntilIdle',
        'readLastPublishTime',
      ]) {
        expect(
          _enclosingControlFlow(_invocationOf(resumeBlock, call), resumeBlock),
          ['Platform.isAndroid'],
          reason: '$call() is either unreachable on some Android resumes or '
              'reached on iOS, where no foreground service exists',
        );
      }
    });

    test('the background publish stamp is adopted, not merely read', () {
      // Seeding the overlap guard is the whole point of reading it: without
      // the assignment the foreground would republish seconds after the
      // service already did.
      final read = _invocationOf(resumeBlock, 'readLastPublishTime');
      final declaration = read.thisOrAncestorOfType<VariableDeclaration>();
      expect(
        declaration,
        isNotNull,
        reason: 'the read must be bound to a local so it can be adopted',
      );
      final probe = _AssignmentVisitor(target: '_lastPublishTime');
      resumeBlock.accept(probe);
      expect(
        probe.sources,
        contains('_lastPublishTime = ${declaration!.name.lexeme}'),
        reason: 'a read whose value is discarded leaves the overlap guard '
            'seeded from the foreground stamp only',
      );
    });
  });

  group('the foreground-service signals', () {
    late String resumeBody;
    late Block pausedBlock;
    late Block resumeBlock;

    setUpAll(() {
      final source = File('lib/src/pages/map_shell.dart').readAsStringSync();
      pausedBlock = methodBlock(
        source,
        className: '_MapShellState',
        method: '_onPaused',
      );
      resumeBlock = methodBlock(
        source,
        className: '_MapShellState',
        method: '_onResumed',
      );
      final body = methodBodySource(
        source,
        className: '_MapShellState',
        method: '_onResumed',
      );
      expect(body, isNotNull, reason: '_onResumed must exist');
      resumeBody = body!;
    });

    test('a declined handoff sends no paused signal', () {
      // S-13. The signal makes the service run its publish cycle AT ONCE, and
      // that cycle probes for the Rule-14 guard. `_handOffMlsSession()`
      // returns false when the bounded stop TIMED OUT, i.e. exactly when the
      // engine's supervisor tasks may still be unwinding while holding it —
      // so an unconditional signal moves that probe from "≤ 72 s later, once
      // the teardown has settled" to "now, mid-teardown". The declined path
      // has already told the user the truth (`fgsNotificationPaused`); it must
      // not also poke the service.
      final signal = _invocationOf(pausedBlock, 'signalTask');
      expect(
        signal.argumentList.arguments.single.toSource(),
        'kForegroundPausedSignal',
        reason: 'the pause direction sends the paused signal — the resumed one '
            'would cancel the registration the service is about to need',
      );
      expect(
        _enclosingControlFlow(signal, pausedBlock),
        ['handedOff', 'bgEnabled && Platform.isAndroid'],
        reason: 'the signal must be CONTAINED by the handoff result, not '
            'merely follow it: a signal sent after a declined handoff races '
            'the reclaim probe against a session that is still tearing down, '
            'and it must never leave the Android + sharing-on branch, where '
            'there is a foreground service to receive it',
      );
    });

    test('the resumed signal is sent on every Android resume, after the '
        'ownership write', () {
      // The signal only ever REMOVES capability — the service cancels its
      // platform location request the moment it arrives — so it belongs on
      // every Android resume, not on a branch: without it the service keeps a
      // second registration alive beside the UI's own until its next watchdog
      // tick. After the stamp, because the stamp is what keeps that tick from
      // simply re-registering; a cancel taken while the service still reads
      // "no foreground owner" is undone by the very next one.
      final signal = _invocationOf(resumeBlock, 'signalTask');
      expect(
        signal.argumentList.arguments.single.toSource(),
        'kForegroundResumedSignal',
      );
      expect(
        _enclosingControlFlow(signal, resumeBlock),
        ['Platform.isAndroid'],
        reason: 'either unreachable on some Android resumes — leaving both '
            'isolates holding a platform location request for the whole '
            'foreground session — or reached on iOS, where no foreground '
            'service exists',
      );
      final stamp = resumeBody.indexOf('markForegroundActive(active: true)');
      expect(
        stamp,
        isNonNegative,
        reason: 'anti-vacuity: the ownership write is what this is ordered '
            'against',
      );
      expect(
        resumeBody.indexOf('signalTask('),
        greaterThan(stamp),
        reason: 'a cancel that lands before the ownership stamp is undone by '
            'the very next watchdog tick, which still sees no foreground owner',
      );
    });
  });

  group('_onDetached and the handoff share one bounded stop', () {
    late String source;

    setUpAll(() {
      source = File('lib/src/pages/map_shell.dart').readAsStringSync();
    });

    String bodyOf(String method) {
      final body = methodBodySource(
        source,
        className: '_MapShellState',
        method: method,
      );
      expect(body, isNotNull, reason: '$method must exist');
      return body!;
    }

    test('every engine stop goes through _stopLiveSyncBounded', () {
      // C1: a second `stop()` path that swallows its outcome reads a
      // timed-out teardown as a release and orphans the Rule-14 guard — a
      // database no isolate can open until a Force Stop. One implementation
      // means one classification.
      for (final method in const [
        '_onDetached',
        '_handOffMlsSession',
        '_onPaused',
      ]) {
        expect(
          bodyOf(method),
          contains('_stopLiveSyncBounded()'),
          reason: '$method must use the shared bounded stop',
        );
      }
      for (final method in const [
        '_onDetached',
        '_handOffMlsSession',
        '_onPaused',
      ]) {
        expect(
          bodyOf(method),
          isNot(contains('liveSync.stop()')),
          reason: '$method must not keep a stop path of its own',
        );
      }
    });

    test('the shared stop never throws and never logs the raw error', () {
      // It runs on lifecycle paths the framework dispatches without awaiting,
      // and an FFI error string can carry MLS group ids (Security Rule 8).
      final body = bodyOf('_stopLiveSyncBounded');
      expect(body, contains('on Object catch'));
      expect(
        RegExp(r'\brethrow\s*;').hasMatch(body),
        isFalse,
        reason: 'nothing upstream can act on a failure here',
      );
      expect(
        RegExp(r'\$e[^a-zA-Z]').hasMatch(body),
        isFalse,
        reason: 'log the type, never the message',
      );
      expect(body, contains(r'${e.runtimeType}'));
    });

    test('a stop that failed is reported as still holding', () {
      // The wrong guess in the other direction is the one that wedges the app:
      // the caller would release its handle believing the engine let go, while
      // the engine's supervisor tasks still hold the guard.
      final body = bodyOf('_stopLiveSyncBounded');
      final declaration = body.indexOf(
        'var outcome = LiveSyncStopOutcome.stillHolding',
      );
      expect(
        declaration,
        isNonNegative,
        reason: 'the pessimistic value must be the one a throw leaves behind',
      );
      expect(
        declaration,
        lessThan(body.indexOf('await liveSync.stop()')),
      );
    });
  });

  group('the paused release needs no frame', () {
    // The whole reason `_onPaused` calls the service DIRECTLY. Flutter
    // disables frames before the lifecycle observers run and Riverpod defers a
    // rebuild into a frame, so a release expressed as a watch or an invalidate
    // lands at RESUME — i.e. never, for the window that matters.
    //
    // `MapShell` cannot be pumped (`MapPage` reaches the Rust bridge in
    // `initState`, CLAUDE.md), so this drives the same production pieces the
    // pause path drives — the keep rule and the service gate — against a real
    // provider graph. That `_onPaused` calls them in that order is the source
    // family above.
    TestWidgetsFlutterBinding.ensureInitialized();

    test('an Android pause releases the plugin subscription with no frame '
        'pumped and no provider read', () {
      final plugin = _CountingGeolocator();
      final service = GeolocatorLocationService(
        geolocator: plugin,
        isIOS: false,
      );
      final container = ProviderContainer(
        overrides: [
          locationServiceProvider.overrideWithValue(service),
          backgroundSharingProvider.overrideWith(
            (ref) => _AlwaysOnBackgroundSharingNotifier(),
          ),
        ],
      );
      addTearDown(container.dispose);
      final sub = container.listen(locationStreamProvider, (_, _) {});
      addTearDown(sub.close);

      expect(
        plugin.listens,
        1,
        reason: 'anti-vacuity: the foreground app must really hold a platform '
            'subscription, or the release below proves nothing',
      );
      expect(plugin.cancels, 0);

      // --- the pause, exactly as `_onPaused` performs it ---
      container.read(appForegroundProvider.notifier).state = false;
      if (!shouldKeepLocationStreamWhilePaused(
        backgroundSharingEnabled: true,
        isIOS: false,
      )) {
        service.suspendStream();
      }
      // NOTHING between here and the assertions: no `pump`, no
      // `container.read(locationStreamProvider)`, no microtask flush. A
      // release that needed any of those would not have happened yet.
      expect(
        plugin.cancels,
        1,
        reason: 'the platform registration must be gone the moment the app '
            'pauses, not at the next frame — which arrives at RESUME',
      );
      expect(
        plugin.listens,
        1,
        reason: 'and nothing may re-subscribe from the background',
      );

      // The outer stream SURVIVED, which is what lets the resume path restart
      // it directly. An invalidate-based release would have disposed the
      // provider, dropped the service's outer controller, and left
      // `resumeStream()` a no-op until a frame rebuilt it.
      service.resumeStream();
      expect(
        plugin.listens,
        2,
        reason: 'the resume path must be able to re-subscribe the SAME outer '
            'stream, with no rebuild involved',
      );
      expect(plugin.cancels, 1);
    });
  });
}

/// A [BackgroundSharingNotifier] pinned on, with no platform side effects.
class _AlwaysOnBackgroundSharingNotifier extends BackgroundSharingNotifier {
  _AlwaysOnBackgroundSharingNotifier()
    : super(
        ensurePermissions: () async => const EnsurePermissionsGranted(),
        isAndroid: false,
        isIOS: false,
      ) {
    state = true;
  }
}

/// A [GeolocatorWrapper] that counts platform subscriptions and cancellations.
///
/// A fresh controller per call, because the service is expected to hold ONE
/// live inner subscription at a time and a shared single-subscription
/// controller would throw on the second listen rather than report it.
class _CountingGeolocator implements GeolocatorWrapper {
  int listens = 0;
  int cancels = 0;

  @override
  Stream<geo.Position> getPositionStream({
    required geo.LocationSettings locationSettings,
  }) {
    final controller = StreamController<geo.Position>()
      ..onListen = (() => listens++)
      ..onCancel = (() => cancels++);
    return controller.stream;
  }

  @override
  Future<bool> isLocationServiceEnabled() async => true;

  @override
  Future<geo.LocationPermission> checkPermission() async =>
      geo.LocationPermission.whileInUse;

  @override
  Future<geo.LocationPermission> requestPermission() async =>
      geo.LocationPermission.whileInUse;

  @override
  Future<geo.LocationAccuracyStatus> getLocationAccuracy() async =>
      geo.LocationAccuracyStatus.precise;

  @override
  Future<geo.Position> getCurrentPosition({
    required geo.LocationSettings locationSettings,
  }) => throw UnimplementedError();

  @override
  Future<geo.Position?> getLastKnownPosition() async => null;
}
