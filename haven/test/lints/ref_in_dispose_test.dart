// Static guard against using `ref` (a Riverpod `WidgetRef`) inside a
// `dispose()` method — a bug class that crashed MapShell teardown and broke
// every CI e2e job.
//
// What happened: `_MapPageState.dispose()` called
// `ref.read(tilePrefetchServiceProvider).cancel()`. Riverpod's
// `ConsumerStatefulElement` throws
// "Bad state: Cannot use "ref" after the widget was disposed"
// because the element is already unregistered by the time `dispose()` runs.
// The crash only surfaces during MapPage teardown, which only happens in the
// slow emulator e2e lane — `flutter test` never exercises it — so the
// regression sailed through CI and landed on `main`.
//
// The fix is to capture the provider value in a field during
// `initState`/`build` and use the field in `dispose()` (which is what
// `map_page.dart` now does).
//
// This test closes the gap with a fast, deterministic, emulator-free analysis
// that runs inside the existing `flutter test` gate. It parses every file
// under `lib/` and, for each class that declares `dispose()`, walks the call
// graph that runs synchronously during `dispose` — into same-class helpers,
// but never past the first `await` on each path, and never into deferred
// closures (`addPostFrameCallback`, `Future.microtask`, `.then(...)`, etc.).
// Any access to a Riverpod `WidgetRef` API (`ref.read`, `ref.watch`,
// `ref.listen`, `ref.listenManual`, `ref.invalidate`, `ref.refresh`,
// `ref.exists`) reachable in that region is flagged.
//
// The detector itself is unit-tested below against known-buggy and known-safe
// snippets so it cannot silently rot into a vacuous pass.
@TestOn('vm')
library;

import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ref-in-dispose detector', () {
    test('flags ref.read written directly in dispose()', () {
      const source = '''
class _S extends ConsumerStatefulWidget {
  @override
  void dispose() {
    ref.read(somePod).cancel();
    super.dispose();
  }
}
''';
      final violations = findRefInDispose(source);
      expect(violations, hasLength(1));
      expect(violations.single.accessor, contains('ref.read'));
    });

    test('flags ref.watch in dispose()', () {
      const source = '''
class _S extends ConsumerState<W> {
  @override
  void dispose() {
    final v = ref.watch(provider);
    super.dispose();
  }
}
''';
      final violations = findRefInDispose(source);
      expect(violations, hasLength(1));
      expect(violations.single.accessor, contains('ref.watch'));
    });

    test('flags ref.invalidate in dispose()', () {
      const source = '''
class _S extends ConsumerState<W> {
  @override
  void dispose() {
    ref.invalidate(provider);
    super.dispose();
  }
}
''';
      final violations = findRefInDispose(source);
      expect(violations, hasLength(1));
      expect(violations.single.accessor, contains('ref.invalidate'));
    });

    test('flags ref.listen in dispose()', () {
      const source = '''
class _S extends ConsumerState<W> {
  @override
  void dispose() {
    ref.listen(provider, (a, b) {});
    super.dispose();
  }
}
''';
      final violations = findRefInDispose(source);
      expect(violations, hasLength(1));
      expect(violations.single.accessor, contains('ref.listen'));
    });

    test('flags ref.refresh in dispose()', () {
      const source = '''
class _S extends ConsumerState<W> {
  @override
  void dispose() {
    ref.refresh(provider);
    super.dispose();
  }
}
''';
      final violations = findRefInDispose(source);
      expect(violations, hasLength(1));
      expect(violations.single.accessor, contains('ref.refresh'));
    });

    test('flags ref.listenManual in dispose()', () {
      const source = '''
class _S extends ConsumerState<W> {
  @override
  void dispose() {
    ref.listenManual(provider, (a, b) {});
    super.dispose();
  }
}
''';
      final violations = findRefInDispose(source);
      expect(violations, hasLength(1));
      expect(violations.single.accessor, contains('ref.listenManual'));
    });

    test('flags ref.exists in dispose()', () {
      const source = '''
class _S extends ConsumerState<W> {
  @override
  void dispose() {
    if (ref.exists(provider)) ref.invalidate(provider);
    super.dispose();
  }
}
''';
      // Two violations: ref.exists and ref.invalidate.
      final violations = findRefInDispose(source);
      expect(violations, hasLength(2));
    });

    // -------------------------------------------------------------------------
    // The regression shape: ref.read inside a private helper called
    // synchronously from dispose().
    // -------------------------------------------------------------------------
    test('flags ref.read inside a private helper called synchronously from '
        'dispose() — the regression shape', () {
      const source = '''
class _S extends ConsumerState<W> {
  @override
  void dispose() {
    _teardown();
    super.dispose();
  }

  void _teardown() {
    ref.read(someServiceProvider).cancel();
  }
}
''';
      final violations = findRefInDispose(source);
      expect(violations, hasLength(1));
      expect(violations.single.chain, 'dispose → _teardown');
      expect(violations.single.accessor, contains('ref.read'));
    });

    // -------------------------------------------------------------------------
    // Boundary: ref.read AFTER the first await in dispose() — the element IS
    // gone by then but this is already a separate Dart bug (the suspend point
    // means the call races with the GC/Riverpod scope teardown). We conservatively
    // stop scanning at the first await, matching the template's pattern.
    // Documented: the detector may miss ref usage after an await — the pattern
    // is already unsafe for other reasons and caught by runtime exceptions.
    // -------------------------------------------------------------------------
    test('does NOT flag ref.read that is only reachable after the first await '
        'in dispose() (scan stops at await — matching template boundary)', () {
      const source = '''
class _S extends ConsumerState<W> {
  @override
  Future<void> dispose() async {
    await Future<void>.value();
    ref.read(provider);
    super.dispose();
  }
}
''';
      // Detector stops at the first await, so the ref.read is not seen.
      expect(findRefInDispose(source), isEmpty);
    });

    // -------------------------------------------------------------------------
    // Boundary: ref inside a deferred closure scheduled in dispose() —
    // the closure runs on the next microtask/frame, not during dispose() itself.
    // This mirrors the template's "deferred closures excluded" rule and avoids
    // false positives for patterns like:
    //   WidgetsBinding.instance.addPostFrameCallback((_) => ref.read(...))
    // -------------------------------------------------------------------------
    test(
        'does NOT flag ref.read inside a deferred closure '
        '(addPostFrameCallback) scheduled in dispose()', () {
      const source = '''
class _S extends ConsumerState<W> {
  @override
  void dispose() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(provider).cancel();
    });
    super.dispose();
  }
}
''';
      expect(findRefInDispose(source), isEmpty);
    });

    test(
        'does NOT flag ref.read inside a Future.microtask closure '
        'in dispose()', () {
      const source = '''
class _S extends ConsumerState<W> {
  @override
  void dispose() {
    Future.microtask(() => ref.read(provider));
    super.dispose();
  }
}
''';
      expect(findRefInDispose(source), isEmpty);
    });

    test('does NOT flag ref.read inside a .then() handler in dispose()', () {
      const source = '''
class _S extends ConsumerState<W> {
  @override
  void dispose() {
    someFuture.then((_) => ref.read(provider));
    super.dispose();
  }
}
''';
      expect(findRefInDispose(source), isEmpty);
    });

    // -------------------------------------------------------------------------
    // Boundary: ref.read is legal in build(), initState(), and other methods.
    // -------------------------------------------------------------------------
    test('does NOT flag ref.read in build()', () {
      const source = '''
class _S extends ConsumerState<W> {
  @override
  Widget build(BuildContext context) {
    final v = ref.watch(provider);
    return SizedBox();
  }
}
''';
      expect(findRefInDispose(source), isEmpty);
    });

    test('does NOT flag ref.read in initState()', () {
      const source = '''
class _S extends ConsumerState<W> {
  @override
  void initState() {
    super.initState();
    _service = ref.read(someServiceProvider);
  }
}
''';
      expect(findRefInDispose(source), isEmpty);
    });

    test('does NOT flag ref.read in an ordinary event handler', () {
      const source = '''
class _S extends ConsumerState<W> {
  void _onTap() {
    ref.read(provider).doSomething();
  }
}
''';
      expect(findRefInDispose(source), isEmpty);
    });

    // -------------------------------------------------------------------------
    // Heuristic boundary: local variable also named `ref`.
    //
    // The detector checks only the method-invocation TARGET being the *bare*
    // identifier `ref` (no qualifier), so a local variable named `ref` would
    // be flagged if it has a Riverpod-named method called on it. This is
    // documented as an accepted heuristic, matching the template's pragmatic
    // approach. In practice, naming a local variable `ref` inside dispose()
    // without it being a WidgetRef is extraordinarily unlikely — and if someone
    // does it, the resulting flag is a reviewer prompt to rename the variable.
    // -------------------------------------------------------------------------
    test('does NOT flag a field-cached service accessed WITHOUT ref — the '
        'correct fix pattern (field cached in initState)', () {
      const source = '''
class _S extends ConsumerState<W> {
  late final SomeService _service;

  @override
  void initState() {
    super.initState();
    _service = ref.read(someServiceProvider);
  }

  @override
  void dispose() {
    _service.cancel();
    super.dispose();
  }
}
''';
      // No ref usage in dispose() — clean.
      expect(findRefInDispose(source), isEmpty);
    });

    test('does NOT flag a class that has no dispose() method at all', () {
      const source = '''
class _S extends ConsumerState<W> {
  @override
  Widget build(BuildContext context) {
    return ref.watch(provider);
  }
}
''';
      expect(findRefInDispose(source), isEmpty);
    });
  });

  group('repository scan', () {
    test('no ref.read/watch/etc. runs synchronously during dispose() '
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
          findRefInDispose(
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
        reason:
            'Riverpod ref.read/watch/etc. called inside dispose() — Riverpod '
            'throws "Cannot use \\"ref\\" after the widget was disposed".\n'
            'Violations:\n'
            '${violations.map((v) => '  • $v').join('\n')}\n\n'
            'Fix: capture the provider value in a field during initState() and '
            'use the field in dispose() — see map_page.dart for the pattern.',
      );
    });
  });
}

// =============================================================================
// Data types
// =============================================================================

/// A single Riverpod `ref` access found inside a `dispose()` synchronous
/// region, with the synchronous call chain that reaches it.
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

// =============================================================================
// Public entry point
// =============================================================================

/// Parses [source] and returns every Riverpod `ref` API call
/// (`ref.read`, `ref.watch`, `ref.listen`, `ref.listenManual`,
/// `ref.invalidate`, `ref.refresh`, `ref.exists`) that can execute
/// synchronously while `dispose()` is still on the stack.
///
/// Purely syntactic (no name resolution), so it is fast and requires no
/// analysis context. Conservative toward *no false positives*:
/// * Stops at the first `await` on each path (the operand of the await itself
///   is still scanned, since it evaluates synchronously before suspension).
/// * Never descends into closure bodies (they run later).
/// * Only flags `ref.<api>(` where `ref` is the *bare, unqualified identifier*
///   on the call target — this is a pragmatic heuristic (matching the template)
///   that will false-positively flag a local variable named `ref` with a
///   coincidental Riverpod-named method, but that naming is vanishingly rare
///   and the false positive is a reviewer prompt to rename.
List<Violation> findRefInDispose(
  String source, {
  String path = '<memory>',
}) {
  final result = parseString(content: source, throwIfDiagnostics: false);
  final unit = result.unit;
  final lineInfo = result.lineInfo;
  final violations = <Violation>[];

  // Collect every `dispose` method declaration in the unit (in classes and
  // mixins alike). Using `childEntities` rather than `ClassDeclaration.members`
  // keeps this stable across the analyzer 9→10 `ClassBody` API change
  // (same pattern as the initState guard).
  final collector = _DisposeCollector();
  unit.accept(collector);

  for (final disposeMethod in collector.disposeMethods) {
    final container = disposeMethod.parent;
    if (container == null) continue;

    final siblings = container.childEntities.whereType<MethodDeclaration>();
    final methods = <String, MethodDeclaration>{};
    for (final member in siblings) {
      if (!member.isStatic && !member.isGetter && !member.isSetter) {
        methods[member.name.lexeme] = member;
      }
    }

    _scanMethod(
      method: disposeMethod,
      chain: const ['dispose'],
      methods: methods,
      visited: {},
      lineInfo: lineInfo,
      path: path,
      out: violations,
    );
  }

  return violations;
}

// =============================================================================
// Recursive scanner
// =============================================================================

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

  for (final refCall in visitor.refCalls) {
    out.add(
      Violation(
        path: path,
        line: lineInfo.getLocation(refCall.offset).lineNumber,
        accessor: refCall.toSource(),
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

// =============================================================================
// AST visitors
// =============================================================================

/// The set of `WidgetRef` method names whose use in `dispose()` always throws.
///
/// `ref.watch` — subscribes a listener (requires the element to be alive).
/// `ref.read`  — looks up the provider scope (element must be alive).
/// `ref.listen` / `ref.listenManual` — register listeners (same).
/// `ref.invalidate` / `ref.refresh` — mutate provider state (same).
/// `ref.exists` — queries the provider scope (same).
const _kRefApis = {
  'read',
  'watch',
  'listen',
  'listenManual',
  'invalidate',
  'refresh',
  'exists',
};

/// Visits the region of a method body that runs synchronously when the method
/// is entered: everything before the first `await` (plus that await's operand,
/// which evaluates before suspension), excluding closure bodies.
///
/// Design mirrors `_SyncRegionVisitor` in the initState guard test:
/// * Everything textually after the first `await` is treated as asynchronous.
/// * Closure bodies (`FunctionExpression`) are never descended into.
/// * Same-class instance calls (no target / `this.`) are collected for the
///   outer scanner to recurse into.
class _SyncRegionVisitor extends RecursiveAstVisitor<void> {
  _SyncRegionVisitor(this._classMethodNames);

  final Set<String> _classMethodNames;

  /// `ref.<api>(...)` calls found in the synchronous region.
  final List<MethodInvocation> refCalls = [];

  /// Same-class instance calls in the synchronous region (to recurse into).
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
    // The operand is evaluated synchronously (to produce the future) before the
    // suspension point — scan it, then mark as past-await.
    node.expression.accept(this);
    _passedAwait = true;
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (_passedAwait) return;

    if (_isRefApiCall(node)) {
      refCalls.add(node);
    } else if (_isSameClassCall(node)) {
      sameClassCalls.add(node);
    }

    super.visitMethodInvocation(node);
  }

  /// Returns true if [node] is `ref.<riverpodApi>(...)` where:
  ///   * the target is the bare identifier `ref` (no qualifier), AND
  ///   * the method name is one of the known `WidgetRef` APIs.
  ///
  /// Heuristic: if a local variable also happens to be named `ref` and has a
  /// method from [_kRefApis] called on it, it is flagged. This is accepted
  /// (see top-of-file comment) because such naming is vanishingly rare inside
  /// a `dispose()` body.
  bool _isRefApiCall(MethodInvocation node) {
    final target = node.target;
    if (target is! SimpleIdentifier) return false;
    if (target.name != 'ref') return false;
    return _kRefApis.contains(node.methodName.name);
  }

  bool _isSameClassCall(MethodInvocation node) {
    final target = node.target;
    final isImplicitThis = target == null || target is ThisExpression;
    return isImplicitThis && _classMethodNames.contains(node.methodName.name);
  }
}

/// Collects every `dispose` method declaration in a compilation unit.
class _DisposeCollector extends RecursiveAstVisitor<void> {
  final List<MethodDeclaration> disposeMethods = [];

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    if (!node.isStatic &&
        !node.isGetter &&
        !node.isSetter &&
        node.name.lexeme == 'dispose') {
      disposeMethods.add(node);
    }
    super.visitMethodDeclaration(node);
  }
}
