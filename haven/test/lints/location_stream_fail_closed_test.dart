// Static guards for the two properties of `location_provider.dart` that no
// runtime test in this repo can observe.
//
// ## Guard 1 — `appForegroundProvider`'s default is DERIVED, never a literal
//
// A literal `true` fails OPEN: on a background launch (an iOS SLC/region
// relaunch builds providers before the first frame) `locationStreamProvider`
// would take the foreground branch and open a background-capable location
// session — the start iOS refuses, and the shape of the 2026-08-20 field
// failure. The value must come from `WidgetsBinding.instance.lifecycleState`.
// `location_provider_test.dart` pins the paused-binding BEHAVIOUR; this pins
// that the behaviour comes from the binding rather than from a constant that
// happens to agree with it.
//
// ## Guard 2 — the not-foregrounded placeholder is a per-build controller
//
// Two ways to get this wrong, neither of which changes the provider's
// `AsyncValue` in a host test (verified: Riverpod exposes no completion
// signal, so a Dart test cannot tell these apart):
//
//   * `Stream.empty()` COMPLETES immediately. A completed position stream is
//     a stream that will never deliver again — the state every consumer of
//     this provider treats as an outage — and it is indistinguishable from a
//     real one at every listener.
//   * a controller HOISTED out of the provider body is single-subscription
//     across builds, so the second not-foregrounded build throws
//     `StateError('Stream has already been listened to.')`, which Riverpod
//     turns into the `AsyncError` the placeholder exists to avoid. That half
//     IS covered at runtime ("two consecutive not-foregrounded builds never
//     surface an error"); pinning it here as well keeps the two failure modes
//     in one place.
//
// Both detectors are self-tested against known-good and known-bad snippets so
// neither can rot into a vacuous pass.
@TestOn('vm')
library;

import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:flutter_test/flutter_test.dart';

const String _providerPath = 'lib/src/providers/location_provider.dart';

/// The initializer of the top-level variable [name], or null if absent.
Expression? _initializerOf(String source, String name) {
  final unit = parseString(content: source, throwIfDiagnostics: false).unit;
  for (final declaration in unit.declarations) {
    if (declaration is! TopLevelVariableDeclaration) continue;
    for (final variable in declaration.variables.variables) {
      if (variable.name.lexeme == name) return variable.initializer;
    }
  }
  return null;
}

/// Collects every node of interest under one subtree.
class _Collector extends RecursiveAstVisitor<void> {
  final List<String> identifiers = <String>[];

  /// Names of every type constructed under this subtree.
  ///
  /// Both node shapes are needed: an UNRESOLVED AST (which is all
  /// `parseString` gives) parses `StreamController<T>()` as a
  /// [MethodInvocation] and only `const Stream<T>.empty()` as an
  /// [InstanceCreationExpression].
  final List<String> constructed = <String>[];
  final List<IfStatement> ifs = <IfStatement>[];

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    identifiers.add(node.name);
    super.visitSimpleIdentifier(node);
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    constructed.add(node.constructorName.type.name.lexeme);
    super.visitInstanceCreationExpression(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final target = node.target;
    constructed.add(
      target is SimpleIdentifier ? target.name : node.methodName.name,
    );
    super.visitMethodInvocation(node);
  }

  @override
  void visitIfStatement(IfStatement node) {
    ifs.add(node);
    super.visitIfStatement(node);
  }
}

_Collector _collect(AstNode node) {
  final collector = _Collector();
  node.accept(collector);
  return collector;
}

/// Whether `appForegroundProvider`'s initial value is read from the binding's
/// lifecycle state rather than written as a constant.
///
/// AST-based, so `lifecycleState` named only in a comment does not count.
bool foregroundDefaultDerivesFromLifecycle(String source) {
  final initializer = _initializerOf(source, 'appForegroundProvider');
  if (initializer == null) return false;
  return _collect(initializer).identifiers.contains('lifecycleState');
}

/// One rejected placeholder shape.
class PlaceholderViolation {
  const PlaceholderViolation(this.problem);

  final String problem;

  @override
  String toString() => problem;
}

/// Checks the branch `locationStreamProvider` takes when the app is not
/// foregrounded: it must construct its own `StreamController` and must not
/// hand back any other kind of `Stream`.
List<PlaceholderViolation> findPlaceholderViolations(String source) {
  final initializer = _initializerOf(source, 'locationStreamProvider');
  if (initializer == null) {
    return const [
      PlaceholderViolation('locationStreamProvider not found — this guard '
          'moved with it or has gone blind'),
    ];
  }

  final guards = _collect(initializer).ifs.where(
    (node) =>
        _collect(node.expression).identifiers.contains('appForegroundProvider'),
  );
  if (guards.isEmpty) {
    return const [
      PlaceholderViolation('no branch on appForegroundProvider — the provider '
          'would start a location session on a background launch'),
    ];
  }

  final violations = <PlaceholderViolation>[];
  for (final guard in guards) {
    // One check covers both failure modes: `Stream.empty()` constructs no
    // controller, and a HOISTED controller is constructed outside this
    // branch, so neither leaves a construction here.
    final constructed = _collect(guard.thenStatement).constructed;
    if (!constructed.contains('StreamController')) {
      violations.add(
        const PlaceholderViolation(
          'the not-foregrounded branch does not construct its own '
          'StreamController: a hoisted one throws on the second build, and '
          'Stream.empty() completes — both surface as an outage',
        ),
      );
    }
  }
  return violations;
}

void main() {
  group('foregroundDefaultDerivesFromLifecycle (detector)', () {
    test('accepts the derived switch', () {
      const source = '''
final appForegroundProvider = StateProvider<bool>((_) {
  return switch (WidgetsBinding.instance.lifecycleState) {
    AppLifecycleState.resumed || AppLifecycleState.inactive || null => true,
    _ => false,
  };
});
''';
      expect(foregroundDefaultDerivesFromLifecycle(source), isTrue);
    });

    test('rejects a literal default', () {
      const source = '''
final appForegroundProvider = StateProvider<bool>((_) => true);
''';
      expect(foregroundDefaultDerivesFromLifecycle(source), isFalse);
    });

    test('rejects a literal default that only mentions the binding in prose',
        () {
      const source = '''
// Derived from WidgetsBinding.instance.lifecycleState.
final appForegroundProvider = StateProvider<bool>((_) => true);
''';
      expect(foregroundDefaultDerivesFromLifecycle(source), isFalse);
    });

    test('rejects the provider being removed altogether', () {
      expect(foregroundDefaultDerivesFromLifecycle('void main() {}'), isFalse);
    });
  });

  group('findPlaceholderViolations (detector)', () {
    const good = '''
final locationStreamProvider = StreamProvider<Position>((ref) {
  if (!ref.read(appForegroundProvider)) {
    ref.watch(appForegroundProvider);
    final paused = StreamController<Position>();
    ref.onDispose(paused.close);
    return paused.stream;
  }
  return service.getLocationStream(backgroundSharingEnabled: bg);
});
''';

    test('accepts the per-build controller', () {
      expect(findPlaceholderViolations(good), isEmpty);
    });

    test('rejects Stream.empty()', () {
      const source = '''
final locationStreamProvider = StreamProvider<Position>((ref) {
  if (!ref.read(appForegroundProvider)) {
    ref.watch(appForegroundProvider);
    return const Stream<Position>.empty();
  }
  return service.getLocationStream(backgroundSharingEnabled: bg);
});
''';
      expect(findPlaceholderViolations(source), isNotEmpty);
    });

    test('rejects a controller hoisted out of the provider body', () {
      const source = '''
final _never = StreamController<Position>();

final locationStreamProvider = StreamProvider<Position>((ref) {
  if (!ref.read(appForegroundProvider)) {
    ref.watch(appForegroundProvider);
    return _never.stream;
  }
  return service.getLocationStream(backgroundSharingEnabled: bg);
});
''';
      expect(findPlaceholderViolations(source), isNotEmpty);
    });

    test('rejects dropping the fail-closed branch entirely', () {
      const source = '''
final locationStreamProvider = StreamProvider<Position>((ref) {
  return service.getLocationStream(backgroundSharingEnabled: bg);
});
''';
      expect(findPlaceholderViolations(source), isNotEmpty);
    });

    test('rejects the provider being renamed away', () {
      expect(findPlaceholderViolations('void main() {}'), isNotEmpty);
    });
  });

  group('the real source', () {
    late String source;

    setUp(() {
      final file = File(_providerPath);
      expect(
        file.existsSync(),
        isTrue,
        reason: '$_providerPath moved — update this guard rather than '
            'deleting it',
      );
      source = file.readAsStringSync();
    });

    test('appForegroundProvider derives its default from the binding', () {
      expect(
        foregroundDefaultDerivesFromLifecycle(source),
        isTrue,
        reason: 'a constant default fails OPEN on a background launch',
      );
    });

    test('the not-foregrounded branch returns a per-build controller', () {
      expect(findPlaceholderViolations(source), isEmpty);
    });
  });
}
