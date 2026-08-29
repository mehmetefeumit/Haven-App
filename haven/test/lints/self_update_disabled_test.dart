/// Regression guard for the M5 self-update disable.
///
/// Leaderless periodic + post-join self-update is the DOMINANT generator of
/// MLS epoch forks (two members rotating from the same epoch and each eagerly
/// merging their own commit diverge permanently). M5 disables it via the
/// `enablePeriodicSelfUpdate` kill switch. These tests fail loudly if a future
/// change re-introduces an ungated self-update driver — re-opening the fork.
library;

import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('M5 — self-update stays disabled', () {
    test('no production self-update timer is re-introduced', () {
      // The hourly `_selfUpdateTimer` was removed in M5. A re-added timer
      // field / Timer.periodic driving self-update would re-enable the fork.
      final offenders = <String>[];
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        if (entity.path.contains(
          '${Platform.pathSeparator}rust${Platform.pathSeparator}',
        )) {
          continue; // generated bindings
        }
        final src = entity.readAsStringSync();
        if (src.contains('_selfUpdateTimer')) {
          offenders.add(entity.path);
        }
      }
      expect(
        offenders,
        isEmpty,
        reason: 'a self-update timer was re-introduced in: $offenders',
      );
    });

    test('no scheduled driver re-keys a circle anywhere in lib/', () {
      // The invariant this file is cited for
      // (`docs/privacy/privacy_invariants.json` INV-E-NO-PERIODIC-REKEY) has an
      // absolute half and a relative half. The absolute half — NOTHING re-keys
      // on a timer — is what the user-facing copy promises, and it is what this
      // scan protects. The companion check,
      // `scripts/ci/check_epoch_repair_isolation.sh`, owns the other question:
      // which files may reach the repair at all.
      //
      // This is an AST walk, not a line scan, and that is the whole point. A
      // line-scoped grep sees `Timer.periodic(d, (_) => repair())` and misses
      // the far likelier multi-line form, because the scheduler and the call
      // land on different lines. The previous version of this test had exactly
      // that hole — proven by `detects a multi-line scheduled repair` below.
      // Walking the tree asks the question that actually matters: is the
      // ENCLOSING function of this invocation a scheduler callback?
      final offenders = <String>[];
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        offenders.addAll(
          scheduledRepairInvocations(entity.readAsStringSync(), entity.path),
        );
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'a scheduled epoch repair would make the privacy copy false — '
            'Haven changes keys on a membership change or an explicit user '
            'repair, never on a timer: $offenders',
      );
    });

    test('detects a multi-line scheduled repair', () {
      // The shape that defeated the line-scoped version. Without this fixture
      // the walk above could regress to a substring match and stay green.
      const source = '''
void drive() {
  Timer.periodic(d, (_) {
    svc.repairCircleEpoch(c);
  });
}
''';
      expect(scheduledRepairInvocations(source, 'fixture.dart'), hasLength(1));
    });

    test('detects a repair nested deeper inside a scheduler callback', () {
      const source = '''
void drive() {
  Future.delayed(d, () async {
    if (ready) {
      await svc.repairCircleEpoch(c);
    }
  });
}
''';
      expect(scheduledRepairInvocations(source, 'fixture.dart'), hasLength(1));
    });

    test('follows one method extraction out of the callback', () {
      // The escape that made the lexical walk cosmetic. Extracting the call
      // into a method — the way `sharing_health_provider.dart` writes its own
      // health tick — moved the repair out of the callback's subtree, and a
      // walk that only looks lexically outward called it clean.
      const source = '''
void drive() {
  Timer.periodic(d, (_) => _tick());
}

void _tick() {
  svc.repairCircleEpoch(c);
}
''';
      expect(scheduledRepairInvocations(source, 'fixture.dart'), hasLength(1));
    });

    test('follows a tear-off handed straight to the scheduler', () {
      // No function literal exists at all here, so there is nothing for a
      // callback-shaped detector to look inside.
      const source = '''
void drive() {
  Timer.periodic(d, _tick);
}

void _tick() {
  svc.repairEpochRotation(g);
}
''';
      expect(scheduledRepairInvocations(source, 'fixture.dart'), hasLength(1));
    });

    test('detects a repair driven by a cron-shaped scheduler', () {
      // `Timer` is not the only way to make something periodic. The receiver's
      // variable name is unknowable, so the method name has to carry the
      // match — otherwise every package binding walks through.
      const source = '''
void drive() {
  cron.schedule('*/5 * * * *', () {
    svc.repairCircleEpoch(c);
  });
  workManager.registerPeriodicTask('id', 'name', callback: () {
    svc.repairCircleEpoch(c);
  });
}
''';
      expect(scheduledRepairInvocations(source, 'fixture.dart'), hasLength(2));
    });

    test('detects a scheduled repair through the Dart WRAPPERS', () {
      // Neither name is an FFI method, and both re-key. `sharingRepairProvider`
      // is read, never invoked as a method, so a `visitMethodInvocation`-only
      // detector never saw it.
      const source = '''
void drive(WidgetRef ref) {
  Timer.periodic(d, (_) {
    unawaited(ref.read(sharingRepairProvider)());
  });
  Future.delayed(d, () => repairSelectedCircleEpoch(ref));
}
''';
      expect(scheduledRepairInvocations(source, 'fixture.dart'), hasLength(2));
    });

    test('does not follow an extraction that never reaches a repair', () {
      // Anti-vacuity for the indirection: chasing every call out of every
      // scheduler callback would flag the whole app.
      const source = '''
void drive() {
  Timer.periodic(d, (_) => _tick());
}

void _tick() {
  setState(() {});
}

Future<void> onTap() async {
  await svc.repairCircleEpoch(c);
}
''';
      expect(scheduledRepairInvocations(source, 'fixture.dart'), isEmpty);
    });

    test('does not fire on an unrelated timer in the same file', () {
      // Both allowlisted UI files legitimately hold a `Timer.periodic` (the
      // health model's re-derivation tick, the banner's age re-render). A
      // detector that fired on those would be uninstallable — which is exactly
      // why the shell guard leaves this question to the AST.
      const source = '''
void build() {
  Timer.periodic(tick, (_) => setState(() {}));
}

Future<void> onTap() async {
  await svc.repairCircleEpoch(c);
}
''';
      expect(scheduledRepairInvocations(source, 'fixture.dart'), isEmpty);
    });

    test('does not fire on the identifier in a comment or a string', () {
      // The two ways a naive detector goes vacuous.
      const source = '''
void drive() {
  // Timer.periodic must never call repairCircleEpoch.
  Timer.periodic(d, (_) {
    log('repairCircleEpoch is not called here');
  });
}
''';
      expect(scheduledRepairInvocations(source, 'fixture.dart'), isEmpty);
    });

    test('the deleted self-update provider stays deleted', () {
      // Deleting it was the point: a "documented no-op" that still existed was
      // a place a future change could quietly re-enable a rotation timer.
      expect(
        File('lib/src/providers/self_update_provider.dart').existsSync(),
        isFalse,
        reason:
            'self_update_provider.dart was deleted with Unit E; re-adding it '
            're-opens the periodic-rekey path',
      );
      final offenders = <String>[];
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final src = entity.readAsStringSync();
        if (src.contains('selfUpdateProvider') ||
            src.contains('enablePeriodicSelfUpdate')) {
          offenders.add(entity.path);
        }
      }
      expect(offenders, isEmpty, reason: 'stale self-update references');
    });
  });
}

/// The names that REACH the epoch repair, not only the two at the FFI boundary.
///
/// The wrappers belong here because they are the reachable surface: a caller
/// writing `ref.read(sharingRepairProvider)()` names neither FFI method and
/// re-keys all the same, which is exactly how the first version of this lint —
/// and its shell companion — were escaped.
const _repairIdentifiers = {
  'repairCircleEpoch',
  'repairEpochRotation',
  'repairSelectedCircleEpoch',
  'sharingRepairProvider',
};

/// Schedulers named by their exact call form.
const _schedulerCalls = {
  'Timer',
  'Timer.periodic',
  'Future.delayed',
  'Stream.periodic',
};

/// Schedulers named by METHOD alone, whatever the receiver is called.
///
/// A cron package, a WorkManager binding and a hand-rolled ticker are all
/// reached through an instance whose variable name this lint cannot know, so
/// matching `<receiver>.<method>` exactly would let every one of them through.
///
/// `every` and `interval` also match `Iterable.every` and anything else that
/// happens to use those names, and that collision is deliberate. It can only
/// produce a LOUD false positive — a named file and line to look at, on a
/// callback that would have to contain a repair call to fire at all — whereas
/// dropping them produces a silent false negative, which is the failure this
/// lint exists to prevent. Narrow the set only if a real call site trips it.
const _schedulerMethods = {
  'schedule',
  'periodic',
  'delayed',
  'every',
  'interval',
  'addPeriodicTask',
  'registerPeriodicTask',
  'enqueueUniquePeriodicWork',
};

/// How many call hops away from a scheduler callback a repair is still counted.
///
/// Two, not unbounded: this is a syntactic parse of ONE file with no element
/// model, so a name resolves to a same-file declaration or not at all, and a
/// deeper chase would mostly follow name collisions. Two covers the shape that
/// actually occurs — a callback delegating to one private method, which in turn
/// delegates once more — and the shape this lint previously missed entirely.
const _maxIndirectionHops = 2;

/// Every scheduled invocation of a repair entry point in [source].
///
/// Reports `path:line` for each. Parses rather than scans, so an identifier
/// that appears only in a comment or a string literal is not reported and a
/// call several lines below its scheduler is.
///
/// Follows ONE level of indirection the obvious way and one more beyond it:
/// `Timer.periodic(d, (_) => _tick())` with the repair inside `_tick` is a
/// scheduled re-key, and a purely lexical walk calls it clean. Tear-offs
/// (`Timer.periodic(d, _tick)`) are treated as callbacks for the same reason.
List<String> scheduledRepairInvocations(String source, String path) {
  final parsed = parseString(content: source, throwIfDiagnostics: false);
  final unit = parsed.unit;

  final declarations = <String, AstNode>{};
  unit.accept(_DeclarationCollector(declarations));

  final callbacks = _CallbackCollector(declarations);
  unit.accept(callbacks);

  final offenders = <String>[];
  final reported = <int>{};
  void flag(AstNode body, String? via) {
    for (final id in _NameCollector.repairNamesIn(body)) {
      if (!reported.add(id.offset)) continue;
      final line = parsed.lineInfo.getLocation(id.offset).lineNumber;
      final trail = via == null ? '' : ' (via $via)';
      offenders.add('$path:$line: ${id.name}$trail');
    }
  }

  for (final callback in callbacks.bodies) {
    flag(callback, null);
    var frontier = _NameCollector.calledNamesIn(callback)
        .where(declarations.containsKey)
        .toSet();
    final visited = <String>{};
    for (var hop = 0; hop < _maxIndirectionHops && frontier.isNotEmpty; hop++) {
      final next = <String>{};
      for (final name in frontier) {
        if (!visited.add(name)) continue;
        final body = declarations[name]!;
        flag(body, name);
        next.addAll(
          _NameCollector.calledNamesIn(body).where(declarations.containsKey),
        );
      }
      frontier = next;
    }
  }
  return offenders;
}

/// Indexes every named function and method body in the unit.
class _DeclarationCollector extends RecursiveAstVisitor<void> {
  _DeclarationCollector(this._bodies);

  final Map<String, AstNode> _bodies;

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    _bodies[node.name.lexeme] = node.functionExpression;
    super.visitFunctionDeclaration(node);
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    _bodies[node.name.lexeme] = node.body;
    super.visitMethodDeclaration(node);
  }
}

/// Collects the bodies a scheduler will run later.
class _CallbackCollector extends RecursiveAstVisitor<void> {
  _CallbackCollector(this._declarations);

  final Map<String, AstNode> _declarations;
  final List<AstNode> bodies = [];

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final qualified = node.target == null
        ? node.methodName.name
        : '${node.target}.${node.methodName.name}';
    if (_schedulerCalls.contains(qualified) ||
        _schedulerMethods.contains(node.methodName.name)) {
      _collectArguments(node.argumentList);
    }
    super.visitMethodInvocation(node);
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    if (_schedulerCalls.contains(node.constructorName.toSource())) {
      _collectArguments(node.argumentList);
    }
    super.visitInstanceCreationExpression(node);
  }

  void _collectArguments(ArgumentList arguments) {
    for (final argument in arguments.arguments) {
      final value = argument is NamedExpression
          ? argument.expression
          : argument;
      if (value is FunctionExpression) {
        bodies.add(value);
      } else if (value is SimpleIdentifier) {
        // A tear-off: the scheduler runs a body declared elsewhere, and no
        // function literal exists to walk into.
        final declared = _declarations[value.name];
        if (declared != null) bodies.add(declared);
      }
    }
  }
}

/// Pulls the two kinds of name this lint reasons about out of a subtree.
class _NameCollector extends RecursiveAstVisitor<void> {
  _NameCollector({required this.wantRepairNames});

  /// Whether to collect repair references (the alternative is called names).
  final bool wantRepairNames;
  final List<SimpleIdentifier> repairNames = [];
  final Set<String> calledNames = {};

  /// Every reference to a repair entry point inside [node], declarations aside.
  ///
  /// Matches bare identifiers as well as call targets, because
  /// `ref.read(sharingRepairProvider)` never becomes a `MethodInvocation` on
  /// the provider — the earlier `visitMethodInvocation`-only detector was blind
  /// to it.
  static List<SimpleIdentifier> repairNamesIn(AstNode node) {
    final collector = _NameCollector(wantRepairNames: true);
    node.accept(collector);
    return collector.repairNames;
  }

  /// Every name invoked inside [node], for chasing one hop further.
  static Set<String> calledNamesIn(AstNode node) {
    final collector = _NameCollector(wantRepairNames: false);
    node.accept(collector);
    return collector.calledNames;
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    calledNames.add(node.methodName.name);
    super.visitMethodInvocation(node);
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (wantRepairNames &&
        _repairIdentifiers.contains(node.name) &&
        !node.inDeclarationContext()) {
      repairNames.add(node);
    }
    super.visitSimpleIdentifier(node);
  }
}
