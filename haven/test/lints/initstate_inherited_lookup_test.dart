// Static guard against the bug class that took down every e2e job:
// an inherited-widget lookup (`SomeWidget.of(context)`) that runs
// SYNCHRONOUSLY during `initState()`.
//
// What happened: `map_page.dart` read `AppLocalizations.of(context)` at the top
// of an async helper that `initState()` calls before its first `await`. Because
// an async function runs synchronously up to its first `await`, that lookup
// executed while `initState()` was still on the stack, so Flutter threw
// "dependOnInheritedWidgetOfExactType() ... was called before initState()
// completed" and MapPage crashed on its first frame. Only the (slow, expensive)
// emulator/simulator e2e jobs exercise MapPage, so the regression sailed through
// `flutter test` and landed on `main`.
//
// This test closes that gap with a fast, deterministic, emulator-free analysis
// that runs inside the existing `flutter test` gate. It parses every file under
// `lib/` and, for each class that declares `initState()`, walks the call graph
// that can run synchronously during `initState` — into helper methods, but only
// up to the first `await` on each path, and never into deferred closures
// (`addPostFrameCallback`, `Future.microtask`, `.then(...)`, etc.). Any
// inherited-widget lookup reachable in that region is a violation.
//
// The detector itself is unit-tested below against known buggy/safe snippets so
// it cannot silently rot into a vacuous pass.
@TestOn('vm')
library;

import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('initState inherited-widget lookup detector', () {
    test('flags a lookup written directly in initState', () {
      const source = '''
class _S extends State<W> {
  @override
  void initState() {
    super.initState();
    final l = Theme.of(context);
  }
}
''';
      final violations = findInitStateInheritedLookups(source);
      expect(violations, hasLength(1));
      expect(violations.single.accessor, contains('Theme.of(context)'));
    });

    test('flags a lookup in a helper called before its first await '
        '(the regression shape)', () {
      const source = '''
class _S extends State<W> {
  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final l = AppLocalizations.of(context);
    await something();
  }
}
''';
      final violations = findInitStateInheritedLookups(source);
      expect(violations, hasLength(1));
      expect(violations.single.chain, 'initState → _init');
      expect(violations.single.accessor, contains('AppLocalizations.of'));
    });

    test('clears a lookup that runs only AFTER the first await', () {
      const source = '''
class _S extends State<W> {
  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await something();
    final l = AppLocalizations.of(context);
  }
}
''';
      expect(findInitStateInheritedLookups(source), isEmpty);
    });

    test('clears a lookup in a post-frame callback', () {
      const source = '''
class _S extends State<W> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final l = AppLocalizations.of(context);
    });
  }
}
''';
      expect(findInitStateInheritedLookups(source), isEmpty);
    });

    test('clears a lookup behind the mounted guard in a catch block '
        '(the fixed shape)', () {
      const source = '''
class _S extends State<W> {
  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      core = await build();
      await getLocation();
    } on Exception {
      if (!mounted) return;
      final m = AppLocalizations.of(context).mapInitFailedRetry;
    }
  }
}
''';
      expect(findInitStateInheritedLookups(source), isEmpty);
    });

    test('follows an awaited same-class call into the callee sync prefix', () {
      // `await _b()` evaluates `_b()` synchronously to produce the future, so
      // _b's pre-await region still runs during initState.
      const source = '''
class _S extends State<W> {
  @override
  void initState() {
    super.initState();
    _a();
  }

  Future<void> _a() async {
    await _b();
  }

  Future<void> _b() async {
    final m = MediaQuery.of(context);
    await something();
  }
}
''';
      final violations = findInitStateInheritedLookups(source);
      expect(violations, hasLength(1));
      expect(violations.single.chain, 'initState → _a → _b');
    });

    test('flags the *Of(context) family (e.g. MediaQuery.sizeOf)', () {
      const source = '''
class _S extends State<W> {
  @override
  void initState() {
    super.initState();
    _i();
  }

  Future<void> _i() async {
    final s = MediaQuery.sizeOf(context);
    await x();
  }
}
''';
      expect(findInitStateInheritedLookups(source), hasLength(1));
    });

    test('flags an import-prefixed type lookup (material.Theme.of)', () {
      const source = '''
class _S extends State<W> {
  @override
  void initState() {
    super.initState();
    _i();
  }

  Future<void> _i() async {
    final t = material.Theme.of(context);
    await x();
  }
}
''';
      expect(findInitStateInheritedLookups(source), hasLength(1));
    });

    test('flags context.dependOnInheritedWidgetOfExactType in initState', () {
      const source = '''
class _S extends State<W> {
  @override
  void initState() {
    super.initState();
    context.dependOnInheritedWidgetOfExactType<Theme>();
  }
}
''';
      expect(findInitStateInheritedLookups(source), hasLength(1));
    });

    test('ignores lookups in build() and event handlers (no initState)', () {
      const source = '''
class _S extends State<W> {
  void _onTap() {
    final l = AppLocalizations.of(context);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return const SizedBox();
  }
}
''';
      expect(findInitStateInheritedLookups(source), isEmpty);
    });

    test('does not recurse into a tear-off passed to a deferred callback', () {
      const source = '''
class _S extends State<W> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(_later);
  }

  void _later(Duration _) {
    final l = AppLocalizations.of(context);
  }
}
''';
      expect(findInitStateInheritedLookups(source), isEmpty);
    });
  });

  group('repository scan', () {
    test('no inherited-widget lookup runs synchronously during initState() '
        'anywhere in lib/', () {
      final libDir = Directory('lib');
      expect(
        libDir.existsSync(),
        isTrue,
        reason: 'Expected to run from the haven package root '
            '(cwd=${Directory.current.path}).',
      );

      final sep = Platform.pathSeparator;
      final violations = <Violation>[];
      var scanned = 0;
      for (final entity in libDir.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        // Generated FFI bindings — never hand-written, excluded from analysis.
        if (entity.path.contains('${sep}rust$sep')) continue;
        scanned++;
        violations.addAll(
          findInitStateInheritedLookups(
            entity.readAsStringSync(),
            path: entity.path,
          ),
        );
      }

      // Guard against a silently-empty glob masquerading as a pass.
      expect(
        scanned,
        greaterThan(50),
        reason: 'Only scanned $scanned files — the lib/ glob looks broken.',
      );

      expect(
        violations,
        isEmpty,
        reason: 'Inherited-widget lookup(s) reachable synchronously from '
            'initState() — Flutter throws before initState() completes:\n'
            '${violations.map((v) => '  • $v').join('\n')}\n\n'
            'Move the lookup into build()/didChangeDependencies(), a post-frame '
            'callback, or past the first await (behind a mounted guard).',
      );
    });
  });
}

/// A single offending lookup, with the synchronous call chain that reaches it.
class Violation {
  Violation({
    required this.path,
    required this.line,
    required this.accessor,
    required this.chain,
  });

  final String path;
  final int line;
  final String accessor;
  final String chain;

  @override
  String toString() => '$path:$line  $accessor  (via $chain)';
}

/// Parses [source] and returns every inherited-widget lookup
/// (`X.of(context)`, `X.*Of(context)`, `context.dependOn…`) that can execute
/// synchronously while `initState()` is still on the stack.
///
/// Purely syntactic (no name resolution), so it is fast and needs no analysis
/// context. The analysis is intentionally conservative toward *not* producing
/// false positives: it treats everything textually after the first `await` on a
/// path as already-asynchronous (initState has returned by then) and never
/// descends into closures, since those run later.
List<Violation> findInitStateInheritedLookups(
  String source, {
  String path = '<memory>',
}) {
  final result = parseString(content: source, throwIfDiagnostics: false);
  final unit = result.unit;
  final lineInfo = result.lineInfo;
  final violations = <Violation>[];

  // Collect every `initState` declaration anywhere in the unit (classes and
  // mixins alike), then resolve its sibling methods via the enclosing node's
  // child entities. Using `childEntities` rather than the now-deprecated
  // `ClassDeclaration.members` keeps this stable across the analyzer 9→10
  // `ClassBody` API change.
  final collector = _InitStateCollector();
  unit.accept(collector);

  for (final initState in collector.initStates) {
    final container = initState.parent;
    if (container == null) continue;

    final siblings = container.childEntities.whereType<MethodDeclaration>();
    final methods = <String, MethodDeclaration>{};
    for (final member in siblings) {
      if (!member.isStatic && !member.isGetter && !member.isSetter) {
        methods[member.name.lexeme] = member;
      }
    }

    _scanMethod(
      method: initState,
      chain: const ['initState'],
      methods: methods,
      visited: <String>{},
      lineInfo: lineInfo,
      path: path,
      out: violations,
    );
  }

  return violations;
}

void _scanMethod({
  required MethodDeclaration method,
  required List<String> chain,
  required Map<String, MethodDeclaration> methods,
  required Set<String> visited,
  required LineInfo lineInfo,
  required String path,
  required List<Violation> out,
}) {
  if (!visited.add(method.name.lexeme)) return;

  final visitor = _SyncRegionVisitor(methods.keys.toSet());
  method.body.accept(visitor);

  for (final lookup in visitor.inheritedLookups) {
    out.add(
      Violation(
        path: path,
        line: lineInfo.getLocation(lookup.offset).lineNumber,
        accessor: lookup.toSource(),
        chain: chain.join(' → '),
      ),
    );
  }

  for (final call in visitor.sameClassCalls) {
    final callee = methods[call.methodName.name];
    if (callee != null) {
      _scanMethod(
        method: callee,
        chain: [...chain, call.methodName.name],
        methods: methods,
        visited: visited,
        lineInfo: lineInfo,
        path: path,
        out: out,
      );
    }
  }
}

/// Visits the region of a method body that runs synchronously when the method
/// is entered: everything before the first `await` (plus that await's operand,
/// which is evaluated before suspension), excluding closure bodies.
///
/// Modeled assumptions (deliberately conservative toward *no false positives*,
/// since this gates CI):
/// * Everything textually after the first `await` is treated as asynchronous —
///   including a `catch` block, which in practice runs on a microtask
///   continuation once the awaited future completes. This is correct as long as
///   the first await's operand yields a future rather than throwing
///   synchronously before suspending (true for the FFI future-returning calls
///   in this codebase).
/// * A lookup behind a conditional first await (`if (c) await x();` then
///   `Foo.of(...)`) is not flagged; modeling that needs control-flow analysis.
/// * Same-class recursion is keyed by method name and cycle-guarded, so it
///   cannot distinguish overloads/shadowing — fine for Dart method bodies.
class _SyncRegionVisitor extends RecursiveAstVisitor<void> {
  _SyncRegionVisitor(this._classMethodNames);

  final Set<String> _classMethodNames;

  /// Inherited-widget lookups found in the synchronous region.
  final List<MethodInvocation> inheritedLookups = [];

  /// Same-class instance calls found in the synchronous region (to recurse).
  final List<MethodInvocation> sameClassCalls = [];

  bool _passedAwait = false;

  @override
  void visitFunctionExpression(FunctionExpression node) {
    // Closures (post-frame callbacks, microtasks, .then handlers, …) run later,
    // not during the current synchronous entry. Do not descend.
  }

  @override
  void visitAwaitExpression(AwaitExpression node) {
    if (_passedAwait) return;
    // The operand is evaluated synchronously before the future is awaited, so
    // scan it; everything sequentially after this await is asynchronous.
    node.expression.accept(this);
    _passedAwait = true;
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (_passedAwait) return;

    if (_isInheritedLookup(node)) {
      inheritedLookups.add(node);
    } else if (_isSameClassCall(node)) {
      sameClassCalls.add(node);
    }

    super.visitMethodInvocation(node);
  }

  bool _isSameClassCall(MethodInvocation node) {
    final target = node.target;
    final isImplicitThis = target == null || target is ThisExpression;
    return isImplicitThis && _classMethodNames.contains(node.methodName.name);
  }

  bool _isInheritedLookup(MethodInvocation node) {
    final name = node.methodName.name;
    final target = node.target;

    // `context.dependOnInheritedWidgetOfExactType<T>()` and friends.
    if (target is SimpleIdentifier && target.name == 'context') {
      const contextLookups = {
        'dependOnInheritedWidgetOfExactType',
        'dependOnInheritedElement',
        'getInheritedWidgetOfExactType',
        'getElementForInheritedWidgetOfExactType',
      };
      if (contextLookups.contains(name)) return true;
    }

    // `SomeWidget.of(context)` / `SomeWidget.sizeOf(context)` / `.maybeOf(...)`,
    // whether the type is bare (`Theme.of`) or import-prefixed
    // (`material.Theme.of`).
    final looksLikeAccessor = name == 'of' || name.endsWith('Of');
    if (looksLikeAccessor &&
        _targetIsTypeName(target) &&
        _passesContext(node)) {
      return true;
    }

    return false;
  }

  /// Whether [target] names a type — `Theme` (bare) or `material.Theme`
  /// (import-prefixed) — by the Dart convention that type names are
  /// upper-camel-case.
  bool _targetIsTypeName(Expression? target) {
    if (target is SimpleIdentifier) {
      return target.name.isNotEmpty && _isUpperCase(target.name[0]);
    }
    if (target is PrefixedIdentifier) {
      final typeName = target.identifier.name;
      return typeName.isNotEmpty && _isUpperCase(typeName[0]);
    }
    return false;
  }

  bool _passesContext(MethodInvocation node) {
    return node.argumentList.arguments
        .whereType<SimpleIdentifier>()
        .any((arg) => arg.name == 'context');
  }

  bool _isUpperCase(String ch) =>
      ch == ch.toUpperCase() && ch != ch.toLowerCase();
}

/// Collects every `initState` method declaration in a compilation unit.
class _InitStateCollector extends RecursiveAstVisitor<void> {
  final List<MethodDeclaration> initStates = [];

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    if (!node.isStatic &&
        !node.isGetter &&
        !node.isSetter &&
        node.name.lexeme == 'initState') {
      initStates.add(node);
    }
    super.visitMethodDeclaration(node);
  }
}
