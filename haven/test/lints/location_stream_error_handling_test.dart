// Static guards for the two invariants that the mid-session location-access
// defect was made of.
//
// ## Guard 1 — no listener of `locationStreamProvider` may use bare `whenData`
//
// The defect: `map_shell.dart` and `map_page.dart` both handled the position
// stream with `next.whenData(...)`, which runs ONLY for `AsyncData`. An
// `AsyncError` — Android's mid-stream `LocationServiceDisabledException` when
// the OS provider is switched off, or a revoked permission — was silently
// dropped, and so was a stream that stopped delivering. Location sharing died
// and the map went on drawing the last fix as though nothing had happened.
//
// `whenData` is not wrong in general (it is used correctly elsewhere in the
// codebase for providers whose failure is not user-visible), so this guard is
// scoped precisely to listeners of `locationStreamProvider` — the one stream
// whose silence means the app's core function has stopped. It requires each
// such listener to visibly handle the error case, and follows tear-offs into
// the named handler method so the check cannot be evaded by extracting the
// closure.
//
// ## Guard 2 — the surfacing must actually be reachable from the widget tree
//
// A banner that exists, is unit-tested, and is rendered by nothing is the same
// defect in a new costume. `MapShell` cannot be pumped in `flutter test` (its
// `MapPage` child calls `HavenCore.newInstance()` across the Rust FFI in
// `initState`), so runtime proof of the composed tree lives in the integration
// lane (`integration_test/b6_location_provider_toggle_test.dart`). This guard
// is the fast half: it fails if `_MapShellState.build` stops constructing the
// banner at all.
//
// Both detectors are self-tested below against known-bad and known-good
// snippets, so neither can rot into a vacuous pass.
@TestOn('vm')
library;

import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:flutter_test/flutter_test.dart';

/// The provider whose listeners are guarded.
const String _guardedProvider = 'locationStreamProvider';

/// One rejected listener.
class StreamListenerViolation {
  StreamListenerViolation({required this.line, required this.problem});

  final int line;
  final String problem;

  @override
  String toString() => 'line $line: $problem';
}

/// Finds `ref.listen`/`ref.listenManual` calls on [_guardedProvider] whose
/// handler ignores the non-data states.
///
/// Structural, not textual: the walk looks for a `whenData` invocation and for
/// evidence of error handling (`is AsyncError`, `.hasError`, or a
/// `when`/`whenOrNull`-style call that takes an `error:` argument) in the
/// handler's AST, and resolves tear-off handlers to the sibling method they
/// name.
List<StreamListenerViolation> findUnhandledLocationStreamListeners(
  String source,
) {
  final result = parseString(content: source, throwIfDiagnostics: false);
  final unit = result.unit;
  final lineInfo = result.lineInfo;

  final methods = <String, MethodDeclaration>{};
  unit.accept(_MethodIndexVisitor(methods));

  final listeners = <MethodInvocation>[];
  unit.accept(_ListenerVisitor(listeners));

  final violations = <StreamListenerViolation>[];
  for (final listener in listeners) {
    final line = lineInfo.getLocation(listener.offset).lineNumber;
    final args = listener.argumentList.arguments;
    if (args.length < 2) {
      violations.add(
        StreamListenerViolation(
          line: line,
          problem: 'listener call has no handler argument to inspect',
        ),
      );
      continue;
    }

    final handler = args[1];
    AstNode? body;
    if (handler is FunctionExpression) {
      body = handler.body;
    } else if (handler is SimpleIdentifier) {
      // A tear-off: follow it to the method it names, so extracting the
      // closure cannot be used to slip past this guard.
      final target = methods[handler.name];
      if (target == null) {
        violations.add(
          StreamListenerViolation(
            line: line,
            problem:
                'handler `${handler.name}` could not be resolved in this file',
          ),
        );
        continue;
      }
      body = target.body;
    } else {
      violations.add(
        StreamListenerViolation(
          line: line,
          problem: 'handler is a ${handler.runtimeType}, which this guard '
              'cannot inspect — extract it to a named method',
        ),
      );
      continue;
    }

    final probe = _HandlerVisitor();
    body.accept(probe);

    if (probe.usesWhenData) {
      violations.add(
        StreamListenerViolation(
          line: line,
          problem: 'handles $_guardedProvider with `whenData`, which drops '
              'AsyncError — the mid-session location-loss defect',
        ),
      );
      continue;
    }
    if (!probe.handlesError) {
      violations.add(
        StreamListenerViolation(
          line: line,
          problem: 'handler for $_guardedProvider never inspects the error '
              'state (`is AsyncError` / `.hasError` / `error:`)',
        ),
      );
    }
  }
  return violations;
}

/// Whether [className]'s `build` method constructs [widgetName].
bool buildConstructs(
  String source, {
  required String className,
  required String widgetName,
}) {
  final unit = parseString(content: source, throwIfDiagnostics: false).unit;
  final visitor = _BuildConstructionVisitor(
    className: className,
    widgetName: widgetName,
  );
  unit.accept(visitor);
  return visitor.found;
}

class _MethodIndexVisitor extends RecursiveAstVisitor<void> {
  _MethodIndexVisitor(this.methods);

  final Map<String, MethodDeclaration> methods;

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    methods[node.name.lexeme] = node;
    super.visitMethodDeclaration(node);
  }
}

class _ListenerVisitor extends RecursiveAstVisitor<void> {
  _ListenerVisitor(this.listeners);

  final List<MethodInvocation> listeners;

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final name = node.methodName.name;
    if (name == 'listen' || name == 'listenManual') {
      final args = node.argumentList.arguments;
      if (args.isNotEmpty) {
        final first = args.first;
        if (first is SimpleIdentifier && first.name == _guardedProvider) {
          listeners.add(node);
        }
      }
    }
    super.visitMethodInvocation(node);
  }
}

class _HandlerVisitor extends RecursiveAstVisitor<void> {
  bool usesWhenData = false;
  bool handlesError = false;

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final name = node.methodName.name;
    if (name == 'whenData') usesWhenData = true;
    // `when(data: ..., error: ..., loading: ...)` and friends handle the error
    // state explicitly.
    if (node.argumentList.arguments.any(
      (a) => a is NamedExpression && a.name.label.name == 'error',
    )) {
      handlesError = true;
    }
    super.visitMethodInvocation(node);
  }

  @override
  void visitIsExpression(IsExpression node) {
    final type = node.type;
    if (type is NamedType && type.name.lexeme == 'AsyncError') {
      handlesError = true;
    }
    super.visitIsExpression(node);
  }

  @override
  void visitPropertyAccess(PropertyAccess node) {
    if (node.propertyName.name == 'hasError') handlesError = true;
    super.visitPropertyAccess(node);
  }

  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    if (node.identifier.name == 'hasError') handlesError = true;
    super.visitPrefixedIdentifier(node);
  }
}

class _BuildConstructionVisitor extends RecursiveAstVisitor<void> {
  _BuildConstructionVisitor({
    required this.className,
    required this.widgetName,
  });

  final String className;
  final String widgetName;
  bool found = false;

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    if (node.name.lexeme != className) return;
    for (final member in node.members) {
      if (member is MethodDeclaration && member.name.lexeme == 'build') {
        final probe = _InstantiationVisitor(widgetName);
        member.body.accept(probe);
        if (probe.found) found = true;
      }
    }
  }
}

class _InstantiationVisitor extends RecursiveAstVisitor<void> {
  _InstantiationVisitor(this.widgetName);

  final String widgetName;
  bool found = false;

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    if (node.constructorName.type.name.lexeme == widgetName) found = true;
    super.visitInstanceCreationExpression(node);
  }
}

// ---------------------------------------------------------------------------

void main() {
  group('detector self-tests (whenData)', () {
    test('flags the exact shape the defect had — an inline whenData', () {
      const source = '''
class _S {
  void go() {
    ref.listen<AsyncValue<Position>>(locationStreamProvider, (_, next) {
      next.whenData(_update);
    });
  }
}
''';
      final violations = findUnhandledLocationStreamListeners(source);
      expect(violations, hasLength(1));
      expect(violations.single.problem, contains('whenData'));
    });

    test('flags listenManual too — the map shell used that variant', () {
      const source = '''
class _S {
  void go() {
    _sub = ref.listenManual<AsyncValue<Position>>(
      locationStreamProvider,
      (_, next) {
        next.whenData(_onMotionPosition);
      },
    );
  }
}
''';
      expect(findUnhandledLocationStreamListeners(source), hasLength(1));
    });

    test('flags a handler that silently ignores everything but data', () {
      const source = '''
class _S {
  void go() {
    ref.listen<AsyncValue<Position>>(locationStreamProvider, (_, next) {
      if (next is AsyncData<Position>) _update(next.value);
    });
  }
}
''';
      final violations = findUnhandledLocationStreamListeners(source);
      expect(violations, hasLength(1));
      expect(violations.single.problem, contains('never inspects the error'));
    });

    test('accepts an explicit AsyncError branch', () {
      const source = '''
class _S {
  void go() {
    ref.listen<AsyncValue<Position>>(locationStreamProvider, (_, next) {
      if (next is AsyncError<Position>) {
        _report();
        return;
      }
      if (next is AsyncData<Position>) _update(next.value);
    });
  }
}
''';
      expect(findUnhandledLocationStreamListeners(source), isEmpty);
    });

    test('follows a tear-off into the handler method', () {
      const bad = '''
class _S {
  void go() {
    ref.listen<AsyncValue<Position>>(locationStreamProvider, _onEvent);
  }

  void _onEvent(AsyncValue<Position>? p, AsyncValue<Position> next) {
    next.whenData(_update);
  }
}
''';
      expect(
        findUnhandledLocationStreamListeners(bad),
        hasLength(1),
        reason: 'extracting the closure must not launder a whenData',
      );

      const good = '''
class _S {
  void go() {
    ref.listen<AsyncValue<Position>>(locationStreamProvider, _onEvent);
  }

  void _onEvent(AsyncValue<Position>? p, AsyncValue<Position> next) {
    if (next is AsyncError<Position>) return;
    if (next is AsyncData<Position>) _update(next.value);
  }
}
''';
      expect(findUnhandledLocationStreamListeners(good), isEmpty);
    });

    test('ignores whenData on OTHER providers', () {
      // Scoped on purpose: whenData is fine where a failure is not a
      // user-visible loss of function.
      const source = '''
class _S {
  void go() {
    ref.listen<AsyncValue<List<Circle>>>(circlesProvider, (_, next) {
      next.whenData(_onCircles);
    });
  }
}
''';
      expect(findUnhandledLocationStreamListeners(source), isEmpty);
    });
  });

  group('detector self-tests (build reachability)', () {
    const shellLike = '''
class _MapShellState extends ConsumerState<MapShell> {
  @override
  Widget build(BuildContext context) {
    return Stack(children: [const MapPage(), const LocationAccessBanner()]);
  }
}
''';

    test('finds a widget constructed in build', () {
      expect(
        buildConstructs(
          shellLike,
          className: '_MapShellState',
          widgetName: 'LocationAccessBanner',
        ),
        isTrue,
      );
    });

    test('does not find a widget that is merely imported', () {
      const source = '''
import 'location_access_banner.dart';

class _MapShellState extends ConsumerState<MapShell> {
  @override
  Widget build(BuildContext context) {
    return Stack(children: [const MapPage()]);
  }
}
''';
      expect(
        buildConstructs(
          source,
          className: '_MapShellState',
          widgetName: 'LocationAccessBanner',
        ),
        isFalse,
        reason: 'an import is not a render — that is the whole failure mode',
      );
    });

    test('does not count construction outside build', () {
      const source = '''
class _MapShellState extends ConsumerState<MapShell> {
  final Widget _unused = const LocationAccessBanner();

  @override
  Widget build(BuildContext context) => const Stack(children: []);
}
''';
      expect(
        buildConstructs(
          source,
          className: '_MapShellState',
          widgetName: 'LocationAccessBanner',
        ),
        isFalse,
      );
    });
  });

  group('the real sources', () {
    test('no locationStreamProvider listener drops the non-data states', () {
      final offenders = <String>[];
      for (final path in const [
        'lib/src/pages/map_shell.dart',
        'lib/src/pages/map/map_page.dart',
      ]) {
        final file = File(path);
        expect(
          file.existsSync(),
          isTrue,
          reason: '$path moved — update this guard rather than deleting it',
        );
        final violations = findUnhandledLocationStreamListeners(
          file.readAsStringSync(),
        );
        offenders.addAll(violations.map((v) => '$path ${v}'));
      }
      expect(
        offenders,
        isEmpty,
        reason: 'A listener of the position stream that ignores AsyncError is '
            'the mid-session location-loss defect returning:\n'
            '${offenders.join('\n')}',
      );
    });

    test('every listener the guard checks is actually found', () {
      // Anti-vacuity: if the listeners were renamed or moved out of these two
      // files, the guard above would pass by checking nothing.
      var total = 0;
      for (final path in const [
        'lib/src/pages/map_shell.dart',
        'lib/src/pages/map/map_page.dart',
      ]) {
        final source = File(path).readAsStringSync();
        final unit = parseString(
          content: source,
          throwIfDiagnostics: false,
        ).unit;
        final listeners = <MethodInvocation>[];
        unit.accept(_ListenerVisitor(listeners));
        total += listeners.length;
      }
      expect(
        total,
        greaterThanOrEqualTo(2),
        reason: 'Both the map shell and the map page must still listen to the '
            'position stream; finding fewer means the guard has gone blind.',
      );
    });

    test('MapShell.build reaches both status banners, link by link', () {
      // The surfacing must be reachable from the real tree, not merely exist.
      //
      // The chain gained a link when the banners were consolidated into one
      // slot with an explicit precedence rule (`MapStatusBanners`), so BOTH
      // hops are asserted: a guard that only checked the first would go green
      // on a slot widget that rendered neither banner, which is the same
      // "exists, tested, reached by nothing" defect one level down.
      final shell = File('lib/src/pages/map_shell.dart').readAsStringSync();
      expect(
        buildConstructs(
          shell,
          className: '_MapShellState',
          widgetName: 'MapStatusBanners',
        ),
        isTrue,
        reason: 'MapShell stopped rendering the status-banner slot — every '
            'banner below it would be computed and shown to nobody.',
      );

      final slot = File(
        'lib/src/widgets/map/map_status_banners.dart',
      ).readAsStringSync();
      for (final banner in ['LocationAccessBanner', 'ClockSkewBanner']) {
        expect(
          buildConstructs(
            slot,
            className: 'MapStatusBanners',
            widgetName: banner,
          ),
          isTrue,
          reason: 'MapStatusBanners stopped rendering $banner — its state '
              'would be computed and shown to nobody.',
        );
      }
    });
  });
}
