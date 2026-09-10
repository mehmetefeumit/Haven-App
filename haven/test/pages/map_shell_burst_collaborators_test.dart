/// What `MapShell` HANDS the burst plane — not the shapes it writes around it.
///
/// ## Why this file exists
///
/// The P4 wiring was covered by structural tests that read call NAMES and
/// containment ("the install sits inside the keep rule", "the release is
/// called on the opt-out branch") and by behavioural tests of the collaborators
/// themselves. Between them sat an uncovered layer: the ARGUMENTS. A mutation
/// pass over the wiring found nine survivors, four of them constructor
/// arguments, and every one is a silent, user-visible failure:
///
///   * `burstEnabled: () => mounted && consent` → `() => mounted` — a burst
///     keeps publishing the user's location after consent is withdrawn;
///   * `onOpenOutcome` reporting a constant `0` — a run of failed opens never
///     reaches the banner, and the device publishes into a subscription it
///     does not hold;
///   * `foregrounded:` dropped, or latched — either the resume defect it
///     closes comes back, or every burst after the first resume keeps its
///     sockets for the whole background window;
///   * `runningBurst:` → `null` — the opt-out pauses underneath a running
///     burst, cutting its ingest mid-replay;
///   * `_burstCoordinator ??=` → `=` — a second coordinator built while the
///     first holds a burst: two engine opens and two socket sets, the exact
///     state this phase removes;
///   * dropping `_lastPublishTime = pausedAt` — a motion publish seconds later
///     duplicates the immediate burst's;
///   * dropping `_burstScheduler = scheduler` — `dispose()` can never clear
///     the sink, and every later tick routes into a dead coordinator;
///   * `pausedRelayOwner(...) != burst` → `== none` — the ANDROID background
///     pause stops closing this isolate's publish socket, so it stays open for
///     the whole window while the foreground service publishes over its own.
///
/// ## Why it is structural
///
/// `MapShell` reaches the Rust bridge in `initState` and cannot be pumped
/// (CLAUDE.md), and `_MapShellState` is private, so there is no way to observe
/// a constructed coordinator at runtime. What the arguments MEAN is proved
/// where it can be — `BackgroundBurstCoordinator`'s own tests for the
/// collaborators, `map_shell_burst_wiring_test.dart` for the statics — and
/// this file proves the shell passes those meanings rather than lookalikes.
/// The analysis is AST-based and scoped to one method body at a time, so a
/// comment or an unrelated call elsewhere in a 2400-line file cannot satisfy
/// it; the detector is self-tested against both below.
@TestOn('vm')
library;

import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:flutter_test/flutter_test.dart';

// ONE method-body detector for `map_shell.dart`, not two. It lives next door
// because that file's guards needed it first; a second copy here would be a
// second thing to keep correct about the same source.
import 'map_shell_location_access_lifecycle_test.dart' show methodBlock;

/// The named arguments of the one `<name>(...)` invocation or instance
/// creation inside [source]'s [className].[method], rendered as source.
///
/// Exactly one match is required: a guard with no anchor is not a guard, and
/// one with two is about whichever it found first.
Map<String, String> namedArgumentsOf(
  String source, {
  required String className,
  required String method,
  required String constructed,
}) {
  final args = _argumentListOf(
    source,
    className: className,
    method: method,
    constructed: constructed,
  );
  return {
    for (final argument in args.arguments.whereType<NamedExpression>())
      argument.name.label.name: argument.expression.toSource(),
  };
}

ArgumentList _argumentListOf(
  String source, {
  required String className,
  required String method,
  required String constructed,
}) {
  final block = methodBlock(source, className: className, method: method);
  final probe = _ConstructionVisitor(name: constructed);
  block.accept(probe);
  expect(
    probe.found,
    hasLength(1),
    reason: 'expected exactly one $constructed(...) in $className.$method',
  );
  return probe.found.single;
}

/// The condition and the then/else arms of every `if` inside
/// [className].[method] whose condition mentions [conditionContains].
///
/// `orElse` is null when the `if` has no else arm — which is the defect this
/// reads for, not an absence of the `if`.
///
/// The condition comes back as the AST node, not as source: the arms are what
/// this was written for, and an `if` whose ARMS are both right can still be
/// joined by the wrong operator, or have lost the conjunct in front of the
/// rule entirely. Neither shows up in either arm.
List<({Expression condition, String then, String? orElse})> conditionalArms(
  String source, {
  required String className,
  required String method,
  required String conditionContains,
}) {
  final block = methodBlock(source, className: className, method: method);
  final probe = _IfVisitor(conditionContains: conditionContains);
  block.accept(probe);
  return probe.found;
}

/// How many `<name>(...)` invocations [statements] makes, by AST.
///
/// `String.contains` over rendered source cannot answer this: `toSource()`
/// preserves string-literal CONTENTS, so
/// `debugPrint('… skipping closeIdle() …')` satisfies a substring match while
/// closing nothing at all.
int invocationCount(String statements, String name) =>
    _invocationsIn(statements, name).length;

/// Whether every `<call>(...)` in [statements] runs inside a `<future>.then(…)`
/// continuation — i.e. is ORDERED behind it rather than issued beside it.
///
/// False for none at all, so it cannot pass vacuously.
bool chainedBehind(
  String statements, {
  required String call,
  required String future,
}) {
  final found = _invocationsIn(statements, call);
  if (found.isEmpty) return false;
  return found.every((args) {
    for (var n = args.parent; n != null; n = n.parent) {
      if (n is MethodInvocation &&
          n.methodName.name == 'then' &&
          n.target?.toSource() == future) {
        return true;
      }
    }
    return false;
  });
}

List<ArgumentList> _invocationsIn(String statements, String name) {
  final probe = _ConstructionVisitor(name: name);
  parseString(
    content: 'void _probe() { $statements }',
    throwIfDiagnostics: false,
  ).unit.accept(probe);
  return probe.found;
}

/// The source of every assignment to [target] inside [className].[method].
List<String> assignmentsTo(
  String source, {
  required String className,
  required String method,
  required String target,
}) {
  final block = methodBlock(source, className: className, method: method);
  final probe = _AssignmentVisitor(target: target);
  block.accept(probe);
  return probe.sources;
}

/// The rendered source of [className].[method]'s body, comments stripped
/// (`toSource()` rebuilds from the AST), so no assertion here can be satisfied
/// by prose describing the code.
String methodSource(
  String source, {
  required String className,
  required String method,
}) => methodBlock(source, className: className, method: method).toSource();

/// Whether [expression] combines [left] and [right] with [operator] as the
/// operator that actually joins them (the smallest binary expression holding
/// both).
bool joinedBy(
  String expression, {
  required String left,
  required String right,
  required String operator,
}) {
  final parsed = parseString(
    content: 'final _x = $expression;',
    throwIfDiagnostics: false,
  ).unit;
  return _smallestJoin(parsed, left: left, right: right)?.operator.lexeme ==
      operator;
}

/// The smallest binary expression inside [condition] that combines [left] and
/// [right], or `null`.
///
/// The NODE, where [joinedBy] answers about the operator alone. The operands
/// are matched by containment — neither side is written out here — and
/// containment cannot tell `x` from `!x`, so an operator-only answer accepts
/// the rule inverted. Whoever needs that ruled out asserts the operands.
BinaryExpression? joining(
  Expression condition, {
  required String left,
  required String right,
}) => _smallestJoin(condition, left: left, right: right);

BinaryExpression? _smallestJoin(
  AstNode root, {
  required String left,
  required String right,
}) {
  final probe = _BinaryVisitor();
  root.accept(probe);
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

/// The name of the single parameter of the closure [expression] is, or `null`.
String? soleParameterOf(String expression) {
  final probe = _ClosureVisitor();
  parseString(
    content: 'final _x = $expression;',
    throwIfDiagnostics: false,
  ).unit.accept(probe);
  final parameters = probe.found.isEmpty
      ? null
      : probe.found.first.parameters?.parameters;
  if (parameters == null || parameters.length != 1) return null;
  return parameters.single.name?.lexeme;
}

/// The arguments of the one `<callName>(...)` inside [expression], rendered as
/// source.
List<String> argumentsOfCall(String expression, String callName) {
  final probe = _ConstructionVisitor(name: callName);
  parseString(
    content: 'final _x = $expression;',
    throwIfDiagnostics: false,
  ).unit.accept(probe);
  expect(
    probe.found,
    hasLength(1),
    reason: 'expected exactly one $callName(...) in the expression',
  );
  return [for (final a in probe.found.single.arguments) a.toSource()];
}

class _ClosureVisitor extends RecursiveAstVisitor<void> {
  final List<FunctionExpression> found = [];

  @override
  void visitFunctionExpression(FunctionExpression node) {
    found.add(node);
    super.visitFunctionExpression(node);
  }
}

class _ConstructionVisitor extends RecursiveAstVisitor<void> {
  _ConstructionVisitor({required this.name});

  final String name;
  final List<ArgumentList> found = [];

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    if (node.constructorName.type.toSource() == name) {
      found.add(node.argumentList);
    }
    super.visitInstanceCreationExpression(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (node.methodName.name == name) found.add(node.argumentList);
    super.visitMethodInvocation(node);
  }

  // Doc-comment references parse to real identifiers; walking into them would
  // let the comment describing a call satisfy the guard.
  @override
  void visitComment(Comment node) {}
}

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

class _IfVisitor extends RecursiveAstVisitor<void> {
  _IfVisitor({required this.conditionContains});

  final String conditionContains;
  final List<({Expression condition, String then, String? orElse})> found = [];

  @override
  void visitIfStatement(IfStatement node) {
    if (node.expression.toSource().contains(conditionContains)) {
      found.add((
        condition: node.expression,
        then: node.thenStatement.toSource(),
        orElse: node.elseStatement?.toSource(),
      ));
    }
    super.visitIfStatement(node);
  }

  // Same reason its two siblings do it: a doc comment's `[Foo]` reference
  // parses to a real identifier, so walking into comments would let prose
  // describing an `if` be matched as one.
  @override
  void visitComment(Comment node) {}
}

class _BinaryVisitor extends RecursiveAstVisitor<void> {
  final List<BinaryExpression> found = [];

  @override
  void visitBinaryExpression(BinaryExpression node) {
    found.add(node);
    super.visitBinaryExpression(node);
  }
}

void main() {
  group('detector self-tests', () {
    const sample = '''
class _S {
  void install() {
    final c = _burstCoordinator ??= Coordinator(
      engine: ref.read(engineProvider),
      burstEnabled: () => mounted && ref.read(consentProvider),
    );
    _scheduler = scheduler;
  }
  void other() {
    final c = Coordinator(engine: somethingElse);
  }
}
''';

    test('reads the named arguments of the construction it is asked about',
        () {
      expect(
        namedArgumentsOf(
          sample,
          className: '_S',
          method: 'install',
          constructed: 'Coordinator',
        ),
        {
          'engine': 'ref.read(engineProvider)',
          'burstEnabled': '() => mounted && ref.read(consentProvider)',
        },
      );
    });

    test('does not read a construction from a DIFFERENT method', () {
      expect(
        namedArgumentsOf(
          sample,
          className: '_S',
          method: 'other',
          constructed: 'Coordinator',
        ),
        {'engine': 'somethingElse'},
      );
    });

    test('is not satisfied by a comment describing the construction', () {
      const prose = '''
class _S {
  /// Builds a [Coordinator] with burstEnabled: () => mounted && consent.
  void install() {
    // Coordinator(burstEnabled: () => mounted && consent);
  }
}
''';
      expect(
        () => namedArgumentsOf(
          prose,
          className: '_S',
          method: 'install',
          constructed: 'Coordinator',
        ),
        throwsA(anything),
        reason: 'a guard a comment can satisfy is not a guard',
      );
    });

    test('reads the assignments it is asked about, and only those', () {
      expect(
        assignmentsTo(
          sample,
          className: '_S',
          method: 'install',
          target: '_burstCoordinator',
        ),
        hasLength(1),
      );
      expect(
        assignmentsTo(
          sample,
          className: '_S',
          method: 'install',
          target: '_burstCoordinator',
        ).single,
        startsWith('_burstCoordinator ??= Coordinator('),
      );
      expect(
        assignmentsTo(
          sample,
          className: '_S',
          method: 'install',
          target: '_missing',
        ),
        isEmpty,
      );
    });

    const branches = '''
class _S {
  void go() {
    if (ready && shouldBurst(now)) {
      drive();
    } else {
      closeIdle();
    }
    if (unrelated) { nothing(); }
  }
}
''';

    test('reads the arms of the if it is asked about, and only those', () {
      final arms = conditionalArms(
        branches,
        className: '_S',
        method: 'go',
        conditionContains: 'shouldBurst',
      );
      expect(arms, hasLength(1));
      expect(arms.single.condition.toSource(), 'ready && shouldBurst(now)');
      expect(arms.single.then, contains('drive()'));
      expect(arms.single.orElse, contains('closeIdle()'));
    });

    test('a missing else reads as a missing arm, not as a missing if', () {
      // THE defect this helper exists for: the `if` is present, the branch it
      // guards is present, and the exit it does not take does nothing at all.
      const bare = 'class _S { void go() { if (shouldBurst(now)) drive(); } }';
      final arms = conditionalArms(
        bare,
        className: '_S',
        method: 'go',
        conditionContains: 'shouldBurst',
      );
      expect(arms, hasLength(1));
      expect(arms.single.orElse, isNull);
    });

    test('an `if` that no longer tests the rule reads as NO arms', () {
      // The other direction, and the one a `for (final arm in arms)` without a
      // length check turns into silence: a rename or a dropped call leaves the
      // branch shape intact and the guard iterating over nothing.
      expect(
        conditionalArms(
          branches,
          className: '_S',
          method: 'go',
          conditionContains: 'shouldBurstImmediatelyOnPause',
        ),
        isEmpty,
      );
    });

    test('a call inside a STRING is not a call', () {
      // `toSource()` keeps literal contents, so `contains('closeIdle()')` over
      // a rendered arm is satisfied by an arm that only mentions it in a log
      // line — the plane never closed, the guard still green.
      expect(
        invocationCount("{ debugPrint('skipping closeIdle()'); }", 'closeIdle'),
        0,
      );
      expect(invocationCount('{ coordinator.closeIdle(); }', 'closeIdle'), 1);
    });

    test('joinedBy answers about the operator that JOINS the two', () {
      expect(
        joinedBy('a && b', left: 'a', right: 'b', operator: '&&'),
        isTrue,
      );
      expect(
        joinedBy('a || b', left: 'a', right: 'b', operator: '&&'),
        isFalse,
        reason: 'an OR is not an AND, and the difference here is a consent '
            'check that no longer gates anything',
      );
      expect(
        joinedBy('a && (b || c)', left: 'a', right: 'c', operator: '&&'),
        isTrue,
      );
      expect(
        joinedBy('b', left: 'a', right: 'b', operator: '&&'),
        isFalse,
        reason: 'a missing operand must not read as a passing join',
      );
    });
  });

  group('the collaborators the burst coordinator is built with', () {
    late String source;
    late Map<String, String> args;

    setUpAll(() {
      final file = File('lib/src/pages/map_shell.dart');
      expect(
        file.existsSync(),
        isTrue,
        reason: 'map_shell.dart moved — update this guard, do not delete it',
      );
      source = file.readAsStringSync();
      args = namedArgumentsOf(
        source,
        className: '_MapShellState',
        method: '_installBurstCoordinator',
        constructed: 'BackgroundBurstCoordinator',
      );
    });

    test('the consent read gates the burst, and it is BOTH conditions', () {
      // The privacy promise of the whole branch: a burst re-reads consent
      // between its links, and a withdrawal stops the publish that follows it
      // rather than the one after that. `() => mounted` alone type-checks,
      // passes every other test in the suite, and keeps publishing the user's
      // location after they said stop. `() => consent` alone keeps an
      // unmounted shell bursting through a `ref` that throws.
      final enabled = args['burstEnabled'];
      expect(enabled, isNotNull, reason: 'the coordinator must be given one');
      expect(
        joinedBy(
          enabled!,
          left: 'mounted',
          right: 'backgroundSharingProvider',
          operator: '&&',
        ),
        isTrue,
        reason: 'burstEnabled must be `mounted && <the consent read>` — an OR '
            'between them, or either one alone, is a burst that outlives the '
            'consent that authorised it',
      );
    });

    test('the open outcome is FORWARDED, never a constant', () {
      // A failed open leaves the burst holding no subscription: it publishes
      // and ingests nothing, and a RUN of them means peers' commits pile up
      // unread until this device's kind-445s are undecryptable to all of them.
      // Reporting a constant 0 makes every open look healthy — the silent
      // failure this phase can produce, wearing the reporting that exists to
      // catch it.
      final report = args['onOpenOutcome'];
      expect(report, isNotNull);
      final parameter = soleParameterOf(report!);
      expect(
        parameter,
        isNotNull,
        reason: 'the callback takes the consecutive-failure count',
      );
      expect(
        argumentsOfCall(report, 'recordBurstOpenOutcome'),
        ['ref.read(sharingHealthProvider.notifier)', parameter],
        reason: 'the health mapping has ONE definition and this is its only '
            'production caller, and the failure COUNT must reach it — a '
            'literal there reports the same verdict for every open there has '
            'ever been',
      );
    });

    test('the Rule-13 drain is given something real to observe', () {
      // The teardown's `shutdownPublishPool` reaches `RelayManager::shutdown`
      // — `client.disconnect()` with no drain of any kind — and the pool it
      // cuts is SHARED: the motion trigger keeps running while backgrounded on
      // iOS and publishes over it, unawaited by and invisible to the
      // coordinator. That path reaches the deferred-send ladder, so a cut
      // there makes an ack unobservable and the sender rolls back a commit a
      // relay may already have stored and served: the roster fork Rule 13
      // exists to prevent, not a lost location sample.
      //
      // Unwired, the parameter defaults to "nothing in flight" — armed, and
      // observing nothing, which is the defect wearing the fix's name.
      expect(
        args['pendingCommitCritical'],
        '() => mounted ? '
            'ref.read(locationSharingServiceProvider).inFlightCommitCritical '
            ': null',
        reason: 'the registry must be READ per call and never captured: it '
            'answers the same future object while work is in flight and null '
            'once the last ladder finishes, which is what makes the '
            'coordinator’s drain-until-null loop terminate',
      );
    });

    test('the handback signal is a PULL, not a latch', () {
      // One coordinator serves every pause of a mount, so a flag that only
      // ever went true would leave every burst after the first resume holding
      // its sockets for the whole background window — worse than the defect it
      // closes. Two writes, in the two directions, are what make it a pull.
      expect(
        args['foregrounded'],
        '() => _foregroundOwnsEngine',
        reason: 'without it a burst still in flight at resume settles, pauses '
            'and shuts the pool while the app is on screen, and nothing '
            'recovers it: ensureRunning reads isRunning, which a pause leaves '
            'true, and the health model freezes its verdict while paused',
      );
      expect(
        assignmentsTo(
          source,
          className: '_MapShellState',
          method: '_installBurstCoordinator',
          target: '_foregroundOwnsEngine',
        ),
        ['_foregroundOwnsEngine = false'],
        reason: 'every install is a re-entry into the background, including '
            'the one that REUSES the coordinator — that is the reuse the '
            'latch would break',
      );
      expect(
        assignmentsTo(
          source,
          className: '_MapShellState',
          method: '_onResumed',
          target: '_foregroundOwnsEngine',
        ),
        ['_foregroundOwnsEngine = true'],
      );
      expect(
        assignmentsTo(
          source,
          className: '_MapShellState',
          method: 'dispose',
          target: '_foregroundOwnsEngine',
        ),
        isEmpty,
        reason: 'an unmounted shell is not a foreground owner; flipping it '
            "there would stop a running burst's teardown and leave the "
            'engine subscribed with the publish pool open',
      );
    });

    test('the handback is taken BEFORE the sink is cleared', () {
      // Between the two, a tick would still be routed to a coordinator that
      // is about to decline it — and, worse, a burst reaching its teardown in
      // that gap still pauses an engine the foreground already owns.
      final resume = methodSource(
        source,
        className: '_MapShellState',
        method: '_onResumed',
      );
      expect(
        resume.indexOf('_foregroundOwnsEngine = true'),
        lessThan(resume.indexOf('setTickSink(')),
      );
    });

    test('the remaining collaborators are the real ones', () {
      // Each is read ONCE here, and each has exactly one production source.
      // A double built in their place would be a burst that publishes over
      // nothing, folds no maintenance, or staggers on a fixed cadence a relay
      // can fingerprint.
      expect(args['engine'], 'ref.read(subscriptionServiceProvider)');
      expect(
        args['publisher'],
        'scheduler',
        reason: 'the scheduler already owns the access gate, the publish call '
            'and the health recording; a second implementation of any of them '
            'is a second thing to keep in sync',
      );
      expect(
        args['maintenance'],
        'ref.read(maintenanceSchedulerProvider.notifier)',
      );
      expect(args['stagger'], 'ref.read(locationPublishStaggerProvider)');
      expect(
        args['shutdownPublishPool'],
        '_shutdownPublishPool',
        reason: "the pool shutdown must be the shell's, which survives an "
            'unmount through its captured handle',
      );
    });

    test('ONE coordinator per mount, and the sink handle is kept', () {
      final assignments = assignmentsTo(
        source,
        className: '_MapShellState',
        method: '_installBurstCoordinator',
        target: '_burstCoordinator',
      );
      expect(assignments, hasLength(1));
      expect(
        assignments.single,
        startsWith('_burstCoordinator ??='),
        reason: 'a plain `=` builds a SECOND coordinator while the first still '
            'holds a burst: two engine opens and two socket sets at once, '
            'which is the state this phase exists to remove — and the R1 '
            'consent edge reaches this method a second time by design',
      );
      expect(
        assignmentsTo(
          source,
          className: '_MapShellState',
          method: '_installBurstCoordinator',
          target: '_burstScheduler',
        ),
        ['_burstScheduler = scheduler'],
        reason: 'dispose() clears the sink through this handle and may not use '
            '`ref`; without it the sink outlives the shell and every later '
            'tick routes into a coordinator that can no longer do anything',
      );
    });
  });

  group('what the pause and the opt-out hand over', () {
    late String source;
    late String paused;

    setUpAll(() {
      source = File('lib/src/pages/map_shell.dart').readAsStringSync();
      paused = methodSource(
        source,
        className: '_MapShellState',
        method: '_onPaused',
      );
    });

    test('the opt-out is given the burst actually in flight', () {
      final release = namedArgumentsOf(
        source,
        className: '_MapShellState',
        method: '_onPaused',
        constructed: 'releaseBurstPlaneOnOptOut',
      );
      expect(
        release['runningBurst'],
        '_burstCoordinator?.runningBurst',
        reason: 'passing null (or omitting it) pauses the engine UNDERNEATH a '
            'running burst: its ingest is cut mid-replay and the settle that '
            "keeps a commit's OK from being lost is truncated (Rule 13)",
      );
      expect(release['engine'], 'ref.read(subscriptionServiceProvider)');
      expect(release['shutdownPublishPool'], '_shutdownPublishPool');
    });

    test('the pause socket decision is asked about exactly two things', () {
      // It took the eligible set as a third input until the burst plane closed
      // both planes on EVERY iOS background pause. Re-adding it would put two
      // owners on one plane: the unawaited shutdown at this call site cutting
      // the publish pool while the coordinator's teardown is deliberately
      // waiting out a commit ladder (Security Rule 13).
      final owner = namedArgumentsOf(
        source,
        className: '_MapShellState',
        method: '_onPaused',
        constructed: 'pausedRelayOwner',
      );
      expect(owner.keys, ['backgroundSharingEnabled', 'isIOS']);
      expect(owner['backgroundSharingEnabled'], 'bgEnabled');
      expect(owner['isIOS'], 'Platform.isIOS');
    });

    test('only the burst owner keeps the socket past the pause', () {
      // What this still guards is the OTHER three states: `== none` would
      // leave the ANDROID background pause holding this isolate's publish
      // socket for the whole window while the foreground service publishes
      // over its own, and would leave the sharing-off pause holding one on
      // both platforms.
      expect(
        paused,
        contains('!= PausedRelayOwner.burst'),
        reason: 'the shutdown is skipped for exactly one owner, and it is the '
            'one whose coordinator closes the socket itself',
      );
    });

    test('a pause that drives no burst still closes what it holds', () {
      // The two exits that used to do nothing at all. `burstCircles` is empty
      // for an account with nothing publishable — a fresh install, one that
      // left its last circle, every circle blocked or legacy-orphaned — and
      // `shouldBurstImmediatelyOnPause` declines inside the 60 s overlap
      // guard, which is the DOMINANT interaction (open the app, glance,
      // background it). Both left the foreground's standing REQ, its socket
      // and the crate's 55 s pinger up: to the first per-circle tick in the
      // second case, and for the whole background window in the first, where
      // no tick is ever coming.
      final arms = conditionalArms(
        source,
        className: '_MapShellState',
        method: '_onPaused',
        conditionContains: 'shouldBurstImmediatelyOnPause',
      );
      expect(
        arms,
        hasLength(2),
        reason: 'the pause branch, and the R1 consent edge that arrives at the '
            'same state late',
      );
      for (final arm in arms) {
        // The CONDITION, on both arms. `_conditionContaining` in the
        // lifecycle-test file is scoped to `_onPaused`'s own `FunctionBody`,
        // so it cannot see the R1 one at all — it lives inside a
        // `listenManual` closure — and this loop used to inspect the arms and
        // never the test in front of them. Dropping the eligible-set conjunct,
        // or joining it with `||`, therefore survived both files: the R1 edge
        // would burst with nothing due, or inside the very overlap guard the
        // rule exists to hold.
        final join = joining(
          arm.condition,
          left: '.isNotEmpty',
          right: 'shouldBurstImmediatelyOnPause',
        );
        expect(
          join,
          isNotNull,
          reason: 'both exits are gated on the eligible set AND the named rule',
        );
        expect(
          join!.operator.lexeme,
          '&&',
          reason: 'an `||` reads as "a circle is due OR the guard has passed" '
              'and bursts on an empty tick list, or inside the guard',
        );
        expect(
          join.leftOperand.toSource(),
          matches(RegExp(r'^\w+\.isNotEmpty$')),
          reason: 'negated, it bursts exactly when there is nothing to burst',
        );
        expect(
          join.rightOperand.toSource(),
          startsWith('MapShell.shouldBurstImmediatelyOnPause('),
          reason: 'the rule is CONSULTED, never inverted — a `!` here bursts '
              'inside the 60 s overlap guard and re-sends every circle '
              'seconds after the resume publish',
        );

        expect(
          invocationCount(arm.then, '_driveBurstNow'),
          1,
          reason: 'the arm the rule passed must actually drive the burst',
        );
        expect(
          arm.orElse,
          isNotNull,
          reason: 'the exit that drives no burst must still close the plane — '
              'nothing else on this branch ever will',
        );
        expect(
          invocationCount(arm.orElse!, 'closeIdle'),
          1,
          reason: 'and the COORDINATOR must be the one to close it: '
              'releaseBurstPlaneOnOptOut has no handback gate (a resume 300 ms '
              'later must stop the close, not race it) and no Rule-13 '
              'commit-critical drain, so routing this through it would import '
              'a Rule-13 hole onto the most frequent pause in the app',
        );
      }
    });

    test('the publish clock is stamped only where a burst was driven', () {
      // The burst publishes EVERY eligible circle, so a motion trigger seconds
      // later is a duplicate of what just went out. Dropping the stamp is
      // invisible in every structural assertion about the branch — and so is
      // the opposite defect, which the branch had: the stamp was written
      // ahead of the empty-set check, recording a publish that never happened
      // and suppressing a motion publish that was genuinely due.
      final stamps = assignmentsTo(
        source,
        className: '_MapShellState',
        method: '_onPaused',
        target: '_lastPublishTime',
      );
      expect(stamps, [
        '_lastPublishTime = pausedAt',
        '_lastPublishTime = armedAt',
      ]);
      final arms = conditionalArms(
        source,
        className: '_MapShellState',
        method: '_onPaused',
        conditionContains: 'shouldBurstImmediatelyOnPause',
      );
      expect(
        arms,
        hasLength(2),
        reason: 'the pause branch and the R1 consent edge — without this a '
            'rename leaves the loop below iterating over nothing',
      );
      for (final arm in arms) {
        expect(
          stamps.where(arm.then.contains),
          hasLength(1),
          reason: 'without it `_guardedPublish` lets a motion publish re-send '
              "the immediate burst's locations within seconds of it",
        );
        expect(
          arm.orElse,
          isNot(contains('_lastPublishTime')),
          reason: 'an idle close publishes nothing, and a stamp there '
              'suppresses the next motion publish for a send that never went',
        );
      }
    });

    test('the R1 consent edge starts closed too', () {
      // It arrives at the burst state LATE — a pause that raced the notifier's
      // async load read a stale `false` and stopped every driver, then the
      // persisted consent resolved `true`. `startScheduling()` arms FRESH
      // jittered schedules there, so with no burst of its own the first tick
      // is a full publish interval away while the engine still holds the
      // foreground's standing REQ and its socket.
      const marker = 'if (next) ';
      final at = paused.indexOf(marker);
      expect(at, isNonNegative);
      var depth = 0;
      var end = at;
      for (var i = at + marker.length; i < paused.length; i++) {
        if (paused[i] == '{') depth++;
        if (paused[i] == '}') {
          depth--;
          if (depth == 0) {
            end = i + 1;
            break;
          }
        }
      }
      final rearm = paused.substring(at, end);
      expect(
        invocationCount(rearm.substring(marker.length), '_driveBurstNow'),
        1,
        reason: 'the edge that becomes the background receiver must close the '
            'socket it inherited, on the same rule the pause branch uses',
      );
      expect(
        rearm,
        contains('shouldBurstImmediatelyOnPause('),
        reason: 'an unconditional burst here re-sends what a publish seconds '
            'earlier already sent',
      );
      expect(
        invocationCount(rearm.substring(marker.length), 'closeIdle'),
        1,
        reason: 'and the exit that declines the burst must still close the '
            'plane: this edge has just become the background receiver, and '
            'its own fresh schedules put the first tick a full interval away',
      );
      expect(
        rearm.indexOf('startScheduling()'),
        lessThan(rearm.indexOf('_driveBurstNow(')),
        reason: "both BurstPublisher methods hard-gate on the scheduler's "
            'active flag, so a burst driven ahead of it opens a socket, waits '
            'out a backlog, publishes nothing and pauses',
      );
      expect(
        rearm.indexOf('_lastPublishTime = armedAt'),
        isNonNegative,
        reason: 'same stamp, same reason as the pause branch',
      );
      // And ordered behind the engine restart, on BOTH exits. The arm this
      // edge arrives from STOPPED the engine (sharing read `false`), and
      // `NostrSubscriptionService.stop()` nulls its handle synchronously — so
      // work issued beside the restart either opens a burst against a stopped
      // session (no receive, one failed open on the banner) or starts a fresh
      // session the original stop then cancels the event subscription of.
      expect(
        invocationCount(rearm, '_restartReceiveAfterPausedStop'),
        1,
        reason: 'anti-vacuity: the restart the two exits order behind',
      );
      for (final call in const ['_driveBurstNow', 'closeIdle']) {
        expect(
          chainedBehind(rearm, call: call, future: 'receiving'),
          isTrue,
          reason: '$call must run in a continuation of the restart, not '
              'beside it',
        );
      }
    });
  });

  group('the publish pool shutdown survives an unmount', () {
    late String source;
    late String shutdown;

    setUpAll(() {
      source = File('lib/src/pages/map_shell.dart').readAsStringSync();
      shutdown = methodSource(
        source,
        className: '_MapShellState',
        method: '_shutdownPublishPool',
      );
    });

    test('it does not return on !mounted', () {
      // It used to, which quietly made "an opt-out leaves no socket"
      // conditional on the shell still being mounted — and a burst can outlive
      // the widget (a logout taken while paused). The sockets then stayed up
      // until the pool's own idle sweep noticed, minutes later, with consent
      // already withdrawn.
      expect(
        shutdown,
        isNot(contains('if (!mounted) return;')),
        reason: 'the shutdown must be unconditional; only the provider READ '
            'needs a live element',
      );
      expect(
        shutdown,
        contains('_publishPool?.shutdown()'),
        reason: 'the captured handle is what makes it work after the unmount',
      );
      expect(
        shutdown,
        contains('if (mounted)'),
        reason: '`ref` is unusable once the element is gone, so the capture '
            'itself still has to be guarded',
      );
    });

    test('the handle is captured at startup, not only at the first shutdown',
        () {
      // The refresh above only ever runs from a MOUNTED shutdown, so a
      // teardown that is the FIRST to reach the shutdown after the unmount —
      // a burst or an idle close that outlived the widget — had nothing
      // captured and closed nothing at all. `relayServiceProvider` is a plain
      // `Provider` nothing in `lib/` invalidates, so the handle taken here is
      // the same singleton every later read would return.
      expect(
        assignmentsTo(
          source,
          className: '_MapShellState',
          method: '_runStartupTasks',
          target: '_publishPool',
        ),
        ['_publishPool = relay'],
      );
    });
  });

  group('nothing else in the app pauses the engine', () {
    test('the only pauseSubscriptions callers are the burst teardown and the '
        'opt-out', () {
      // What makes "every background pause instant ends with the engine
      // paused" a closed statement rather than an inspection of two files. The
      // burst teardown answers EVERY pause on the iOS branch — the burst this
      // pause drove, or the idle close it took instead — and the opt-out
      // answers a consent withdrawal. A third caller would be a second owner
      // of the engine plane: able to pause it underneath a burst mid-replay,
      // or to cut a settle that is holding a commit's OK (Security Rule 13).
      final callers = <String, int>{};
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        // `lib/src/rust/` is FRB-generated and declares the FFI binding these
        // two ultimately reach (CLAUDE.md: DO NOT EDIT).
        if (entity.path.startsWith('lib/src/rust/')) continue;
        final probe = _ConstructionVisitor(name: 'pauseSubscriptions');
        parseString(
          content: entity.readAsStringSync(),
          throwIfDiagnostics: false,
        ).unit.accept(probe);
        if (probe.found.isNotEmpty) callers[entity.path] = probe.found.length;
      }
      expect(callers, {
        'lib/src/services/background_burst_coordinator.dart': 1,
        'lib/src/pages/map_shell.dart': 1,
        // Not a decision to pause: this is `SubscriptionService`'s single
        // implementation forwarding to the FFI engine, i.e. the method the two
        // above call.
        'lib/src/services/nostr_subscription_service.dart': 1,
      });
    });

    test('each of the two is the method it is supposed to be', () {
      // A file-level count says nothing about WHERE: moved into a lifecycle
      // callback or a timer, either call would pause the engine outside the
      // teardown that owns it, with the same two failures.
      expect(
        methodSource(
          File('lib/src/services/background_burst_coordinator.dart')
              .readAsStringSync(),
          className: 'BackgroundBurstCoordinator',
          method: '_closeBurst',
        ),
        contains('pauseSubscriptions()'),
        reason: 'the ONE teardown, reached by a burst and by an idle close, '
            'with the per-link handback re-reads and the Rule-13 drain around '
            'it',
      );
      expect(
        methodSource(
          File('lib/src/pages/map_shell.dart').readAsStringSync(),
          className: 'MapShell',
          method: 'releaseBurstPlaneOnOptOut',
        ),
        contains('pauseSubscriptions()'),
        reason: 'withdrawn consent must leave no socket whatever the burst '
            'plane is doing, which is why this one has no handback gate',
      );
    });
  });
}
