// Security Rule 13's DART half: "NEVER call `confirm_published` before at
// least one relay has returned an OK-ack ... call `publish_failed` on failure".
//
// The Rust half of the pause is defended twice — a rule gate asserts the
// publish-drain gauge runs before `disconnect()` AND that the wait mentions no
// `timeout`/`sleep`/`Duration`, and a CI guard pins the body of
// `pause_subscriptions`. The Dart half was one sentence of doc comment, and the
// obvious thing to do when a background task must finish before iOS suspends
// the process is to bound the link that is taking too long:
//
//     } finally {
//       await _subscriptions.pauseSubscriptions()
//           .timeout(const Duration(seconds: 5));   // <- passes every gate
//     }
//
// That does not cancel the Rust future. It lets the CALLER return while the
// engine is still draining, so the process can suspend with a commit sitting
// between SEND and OK. The peer never sees an ack, the sender calls
// `publish_failed` on a commit a relay already accepted, and the roster forks —
// a confidentiality-relevant divergence, not a lost location sample.
//
// So: no `.timeout(` may wrap a commit-critical link, anywhere in `lib/`.
//
// ## The link is often one name away
//
// Naming the links alone was one indirection too shallow. A teardown is
// normally extracted into a private helper — `_closeBurst()` performs settle →
// pause → pool shutdown and is called bare from a `finally` — and
//
//     await _closeBurst().timeout(const Duration(seconds: 5));
//
// cuts exactly the same future while naming none of the links. So the checker
// DERIVES the wrappers from the file it is reading: a declaration whose body
// contains a commit-critical link is itself commit-critical, transitively, to
// a fixpoint. Nothing to maintain and
// nothing to forget — a helper extracted tomorrow is covered the moment it
// exists, which a hand-kept name list and an opt-in `// commit-critical`
// marker both fail to be.
//
// ## Public wrappers, and only where the name is unambiguous
//
// The derivation used to be confined to library-private names, on the ground
// that `_x` can only denote a declaration in this same library, so resolving
// it by name inside one file is exact even without an element model. That held
// while every teardown wrapper was private — and stopped holding the moment
// one was not. `MapShell.releaseBurstPlaneOnOptOut` is PUBLIC (it is a static
// the opt-out path's tests call directly, because `MapShell` cannot be pumped)
// and it calls `pauseSubscriptions()`. A bound written on the CALL,
//
//     await MapShell.releaseBurstPlaneOnOptOut(...)
//         .timeout(const Duration(seconds: 5));
//
// cuts the same future as a bound written on the link inside it, and the
// private-only rule could not see it: the direct arm reached the declaration
// and the transitive arm structurally could not reach the caller.
//
// So a declaration of ANY visibility can be derived — but a public name is
// only ever matched against call sites in the SAME FILE as the declaration,
// which is exactly what a per-file checker gives for free: a name is a wrapper
// here only because this unit declares it, and a unit that declares no
// `onTick` derives no `onTick`. That keeps the reason the boundary was drawn
// in the first place. `sink.onTick(...)` in some other file is an interface
// call whose implementation lives elsewhere, and NOTHING in this checker will
// ever match a public name across files.
//
// Within one file the receiver is still not consulted, so a same-named method
// of a second type declared in the same unit would be flagged too. That is
// accepted deliberately: inside one file the ambiguity is visible to whoever
// wrote it, the flag says exactly which chain it believes it found, and the
// remedy — rename one of them — is the same thing a reader needs anyway.
// See the boundary self-tests below.
//
// The checker is self-tested against known-good and known-bad snippets before
// it is run over the tree, and two inventory passes prove it still SEES the
// real call sites — one globally, and one PER FILE for every file that owns a
// teardown, because a global count is supplied by whichever file still has a
// link and hides the file that lost all of its.
@TestOn('vm')
library;

import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:flutter_test/flutter_test.dart';

/// Methods whose Dart future must be allowed to run to completion.
///
/// * `settleBeforePause` / `pauseSubscriptions` — the burst's teardown pair.
///   The settle is what holds the sockets open until this burst's commit
///   traffic has quiesced; the pause is what drops the REQs and disconnects.
///   Cutting either one lands the process in exactly the suspend-mid-commit
///   state the settle exists to prevent.
/// * `confirmPublished` / `finalizeRelayUpdate` / `publishFailed` — the three
///   ways a staged MLS commit is RESOLVED. A resolution that is abandoned
///   half-way leaves the group in `PendingPublish`, where every later send
///   fails.
const _criticalMethods = {
  'settleBeforePause',
  'pauseSubscriptions',
  'confirmPublished',
  'finalizeRelayUpdate',
  'publishFailed',
};

/// Futures that ARE a commit-critical section, held in a variable rather than
/// called inline.
///
/// `background_location_task.dart` tracks its receive-side auto-commit publish
/// in `_inFlightCommitCritical` precisely so its teardown can await that one
/// slice unbounded, next to a DIFFERENT in-flight future (`_inFlightPublish`,
/// a plain application message) that it deliberately DOES bound. Only the name
/// distinguishes them at the await, so only the name can protect it.
const _criticalFutures = {'_inFlightCommitCritical', 'commitCritical'};

/// Every file that OWNS a commit-critical link, and the links it must still
/// contain.
///
/// The global inventory below cannot see a file going quiet:
/// `settleBeforePause` lives in the coordinator AND in the subscription
/// service, so deleting both of the coordinator's leaves the global count at
/// one and the guard green over a file it now inspects for nothing. Per file,
/// that is visible.
///
/// A file that legitimately stops owning a teardown is removed from this table
/// in the same change — which is the point: someone has to say so.
const _teardownOwners = <String, Set<String>>{
  'lib/src/services/background_burst_coordinator.dart': {
    'settleBeforePause',
    'pauseSubscriptions',
  },
  'lib/src/services/nostr_subscription_service.dart': {
    'settleBeforePause',
    'pauseSubscriptions',
  },
  'lib/src/services/background_location_task.dart': {
    '_inFlightCommitCritical',
    'commitCritical',
  },
  'lib/src/services/background_deferred_send.dart': {
    'confirmPublished',
    'publishFailed',
  },
  'lib/src/services/nostr_circle_service.dart': {
    'confirmPublished',
    'publishFailed',
    'finalizeRelayUpdate',
  },
  // The opt-out release: consent withdrawn while the app is paused has to
  // leave no socket behind, and `releaseBurstPlaneOnOptOut` is where the
  // engine is actually paused for it. Without a floor here the file could lose
  // its only commit-critical link — the whole release, or just its pause —
  // with nothing red: the global count would still be supplied by the
  // subscription service, and the scan would go on inspecting this file for
  // nothing.
  'lib/src/pages/map_shell.dart': {'pauseSubscriptions'},
  // The shared publish pool's other user. `resolveAutoCommits` publishes a
  // staged commit and then resolves it over the SAME pool the burst teardown
  // shuts, and `_awaitCommitCritical(commitCritical)` is what makes those
  // three windows visible to the teardown.
  //
  // This floor is the NAME's floor and nothing more: it goes red when
  // `commitCritical` leaves the file's executable code entirely, which is
  // what a rename or a deleted registration helper looks like. It does NOT
  // see one of the three windows losing its registration — the helper's own
  // body still names the parameter — and it is not asked to. That case is
  // caught below, by the group that asserts the three PUBLIC callers are
  // still derived THROUGH the registration; both mutations were run.
  'lib/src/services/location_sharing_service.dart': {'commitCritical'},
};

/// One `.timeout(` that bounds a commit-critical link.
class TimeoutViolation {
  TimeoutViolation(this.line, this.what);

  /// Line of the offending `.timeout(`.
  final int line;

  /// The commit-critical link it wraps, with the chain that reaches it.
  final String what;

  @override
  String toString() => 'line $line: `.timeout(` wraps $what';
}

/// Finds the commit-critical link inside [root]'s subtree, or `null`.
String? _criticalLinkIn(AstNode root) {
  final finder = _CriticalFinder();
  root.accept(finder);
  return finder.found;
}

class _CriticalFinder extends RecursiveAstVisitor<void> {
  String? found;

  /// Prose is not code. See [_CriticalCounter.visitComment].
  @override
  void visitComment(Comment node) {}

  @override
  void visitMethodInvocation(MethodInvocation node) {
    // `target != null` keeps this to calls ON something — a same-named bare
    // function would be a different thing entirely, and `publishFailed` is
    // also a local bool in the background task.
    final name = node.methodName.name;
    if (node.target != null && _criticalMethods.contains(name)) {
      found ??= '$name()';
    }
    super.visitMethodInvocation(node);
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (_criticalFutures.contains(node.name)) found ??= node.name;
    super.visitSimpleIdentifier(node);
  }
}

// ---------------------------------------------------------------------------
// Derived wrappers
// ---------------------------------------------------------------------------

/// Every declaration in [unit], by name, with EVERY body that name has.
///
/// Methods, top-level functions and the getters that back them all count: any
/// of them can be the one hop between a `.timeout(` and a link.
///
/// A name maps to a LIST because one unit may declare it more than once — the
/// abstract `BurstSink.onTick` and the concrete `BackgroundBurstCoordinator`
/// one live in the same file, and so would two classes that each have a
/// `_close`. Keeping only the last would make criticality depend on
/// declaration ORDER: an empty interface body declared after a real one would
/// hide the teardown behind it.
Map<String, List<FunctionBody>> _localDeclarations(CompilationUnit unit) {
  final out = <String, List<FunctionBody>>{};
  unit.accept(_DeclarationCollector(out));
  return out;
}

class _DeclarationCollector extends RecursiveAstVisitor<void> {
  _DeclarationCollector(this.out);
  final Map<String, List<FunctionBody>> out;

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    (out[node.name.lexeme] ??= []).add(node.body);
    super.visitMethodDeclaration(node);
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    (out[node.name.lexeme] ??= []).add(node.functionExpression.body);
    super.visitFunctionDeclaration(node);
  }
}

/// First invocation of any name in [names] inside [root]'s subtree, or `null`.
///
/// The receiver is not consulted, and [names] only ever holds names THIS unit
/// declares — which is what confines a public wrapper to its own file. A
/// private name could not denote anything outside the library anyway; a public
/// one is matched here because the declaration it would resolve to is in front
/// of us.
String? _localCallIn(AstNode root, Set<String> names) {
  final finder = _LocalCallFinder(names);
  root.accept(finder);
  return finder.found;
}

class _LocalCallFinder extends RecursiveAstVisitor<void> {
  _LocalCallFinder(this.names);
  final Set<String> names;
  String? found;

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (names.contains(node.methodName.name)) found ??= node.methodName.name;
    super.visitMethodInvocation(node);
  }
}

/// Declarations in [unit] that are commit-critical, mapped to the chain that
/// makes them so (`_runBurst() → _closeBurst() → settleBeforePause()`).
///
/// Seeded from the declarations that name a link directly, then closed under
/// "calls a declaration already known to be critical". A name is critical when
/// ANY of its declarations in this unit is.
Map<String, String> criticalWrappersIn(CompilationUnit unit) {
  final declarations = _localDeclarations(unit);

  final directs = <String, String>{}; // name -> the link it names
  final vias = <String, String>{}; // name -> the local name it calls
  declarations.forEach((name, bodies) {
    for (final body in bodies) {
      final link = _criticalLinkIn(body);
      if (link != null) {
        directs[name] = link;
        break;
      }
    }
  });

  var changed = true;
  while (changed) {
    changed = false;
    for (final entry in declarations.entries) {
      final name = entry.key;
      if (directs.containsKey(name) || vias.containsKey(name)) continue;
      final known = {...directs.keys, ...vias.keys}
        ..remove(name); // direct recursion proves nothing
      String? via;
      for (final body in entry.value) {
        via ??= _localCallIn(body, known);
      }
      if (via == null) continue;
      vias[name] = via;
      changed = true;
    }
  }

  return {
    for (final name in {...directs.keys, ...vias.keys})
      name: _chain(name, directs, vias),
  };
}

/// Renders `_runBurst() → _closeBurst() → settleBeforePause()`.
String _chain(
  String name,
  Map<String, String> directs,
  Map<String, String> vias,
) {
  final parts = <String>[];
  final seen = <String>{};
  var current = name;
  while (seen.add(current)) {
    parts.add('$current()');
    final next = vias[current];
    if (next != null) {
      current = next;
      continue;
    }
    final link = directs[current];
    if (link != null) parts.add(link);
    break;
  }
  return parts.join(' → ');
}

// ---------------------------------------------------------------------------
// The check
// ---------------------------------------------------------------------------

/// Every `.timeout(` in [unit] that bounds a commit-critical link, directly or
/// through a wrapper this unit declares.
List<TimeoutViolation> checkNoTimeoutOnCriticalLinks(
  CompilationUnit unit,
  LineInfo lines,
) {
  final wrappers = criticalWrappersIn(unit);
  final byOffset = <int, TimeoutViolation>{};
  for (final call in _allTimeoutCalls(unit)) {
    final target = call.target;
    if (target == null) continue; // a bare `timeout(...)` is something else
    final line = lines.getLocation(call.offset).lineNumber;
    final direct = _criticalLinkIn(target);
    if (direct != null) {
      byOffset[call.offset] = TimeoutViolation(line, direct);
      continue;
    }
    final via = _localCallIn(target, wrappers.keys.toSet());
    if (via == null) continue;
    byOffset[call.offset] = TimeoutViolation(line, wrappers[via]!);
  }
  return byOffset.values.toList()..sort((a, b) => a.line.compareTo(b.line));
}

class _TimeoutCollector extends RecursiveAstVisitor<void> {
  _TimeoutCollector(this.out);
  final List<MethodInvocation> out;

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (node.methodName.name == 'timeout') out.add(node);
    super.visitMethodInvocation(node);
  }
}

List<MethodInvocation> _allTimeoutCalls(AstNode root) {
  final out = <MethodInvocation>[];
  root.accept(_TimeoutCollector(out));
  return out;
}

/// Counts commit-critical links, so the scan can prove it still sees them.
class _CriticalCounter extends RecursiveAstVisitor<void> {
  final Map<String, int> counts = {};

  /// Doc comments are NOT code, and the analyzer does not agree by default: a
  /// `[commitCritical]` reference in a sentence is a `CommentReference`
  /// wrapping a real `SimpleIdentifier`, which an unguarded visitor counts
  /// exactly like the registration itself.
  ///
  /// That made the per-file floor below satisfiable by prose — proven by
  /// mutation: renaming every executable `commitCritical` in
  /// `location_sharing_service.dart` left the floor GREEN on the strength of
  /// two doc comments that still described a registration the file no longer
  /// had. A guard that a comment can satisfy is the same defect as a guard a
  /// comment can violate.
  @override
  void visitComment(Comment node) {}

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final name = node.methodName.name;
    if (node.target != null && _criticalMethods.contains(name)) {
      counts[name] = (counts[name] ?? 0) + 1;
    }
    super.visitMethodInvocation(node);
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (_criticalFutures.contains(node.name)) {
      counts[node.name] = (counts[node.name] ?? 0) + 1;
    }
    super.visitSimpleIdentifier(node);
  }
}

Map<String, int> _criticalCounts(String source) {
  final counter = _CriticalCounter();
  parseString(content: source, throwIfDiagnostics: false).unit.accept(counter);
  return counter.counts;
}

/// Every hand-written Dart file under `lib/`, generated bindings excluded.
Iterable<File> _libSources() sync* {
  final sep = Platform.pathSeparator;
  for (final entity in Directory('lib').listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    if (entity.path.contains('${sep}rust$sep')) continue;
    yield entity;
  }
}

String _read(String relativePath) {
  final file = File(relativePath);
  if (!file.existsSync()) {
    fail(
      'expected source file not found: $relativePath (has it moved? this test '
      'pins Security Rule 13 to its call sites)',
    );
  }
  return file.readAsStringSync();
}

/// Splices [statement] in as the first statement of [method]'s body in
/// [source], located through the AST rather than by string search.
///
/// Used to mutate the REAL sources: a self-test on a hand-written snippet
/// proves the checker can fire, but only a mutation of the file it actually
/// guards proves it fires THERE.
String _injectIntoMethod(String source, String method, String statement) {
  final unit = parseString(content: source, throwIfDiagnostics: false).unit;
  final collector = _MethodBodyFinder(method);
  unit.accept(collector);
  final body = collector.found;
  if (body == null) {
    fail(
      'cannot mutate: no method `$method` with a block body was found. It was '
      'renamed or inlined — re-point this mutation at whatever replaced it, '
      'or the guard below is no longer proven to fire on the real file.',
    );
  }
  return source.replaceRange(
    body.block.leftBracket.end,
    body.block.leftBracket.end,
    '\n$statement\n',
  );
}

class _MethodBodyFinder extends RecursiveAstVisitor<void> {
  _MethodBodyFinder(this.name);
  final String name;
  BlockFunctionBody? found;

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    final body = node.body;
    if (node.name.lexeme == name && body is BlockFunctionBody) found ??= body;
    super.visitMethodDeclaration(node);
  }
}

List<TimeoutViolation> _violationsIn(String source) {
  final parsed = parseString(content: source, throwIfDiagnostics: false);
  return checkNoTimeoutOnCriticalLinks(parsed.unit, parsed.lineInfo);
}

const _coordinator = 'lib/src/services/background_burst_coordinator.dart';
const _mapShell = 'lib/src/pages/map_shell.dart';
const _locationSharing = 'lib/src/services/location_sharing_service.dart';

void main() {
  group('checker self-tests', () {
    List<TimeoutViolation> run(String body) =>
        _violationsIn('class _S { Future<void> go() async { $body } }');

    test('an unbounded pause link is clean', () {
      expect(run('await subscriptions.pauseSubscriptions();'), isEmpty);
    });

    test('flags a bounded pause link', () {
      final v = run(
        'await subscriptions.pauseSubscriptions().timeout(oneBurst);',
      );
      expect(v, hasLength(1));
      expect(v.single.what, 'pauseSubscriptions()');
    });

    test('flags a bounded settle link', () {
      // The likelier of the two to be bounded: it is the one that can WAIT,
      // so it is the one that looks like it is holding the burst up.
      final v = run(
        'await subscriptions.settleBeforePause().timeout(budget);',
      );
      expect(v, hasLength(1));
      expect(v.single.what, 'settleBeforePause()');
    });

    test('flags a bounded commit resolution', () {
      expect(
        run('await manager.confirmPublished(pending: p).timeout(budget);')
            .single
            .what,
        'confirmPublished()',
      );
      expect(
        run('await manager.publishFailed(pending: p).timeout(budget);')
            .single
            .what,
        'publishFailed()',
      );
      expect(
        run('await manager.finalizeRelayUpdate(pending: p).timeout(budget);')
            .single
            .what,
        'finalizeRelayUpdate()',
      );
    });

    test('flags a bounded commit-critical future held in a variable', () {
      // The shape the background task's teardown already has, one line away
      // from a bound that would be correct for its neighbour.
      expect(
        run('await commitCritical.timeout(budget);').single.what,
        'commitCritical',
      );
      expect(
        run('await _inFlightCommitCritical?.timeout(budget);').single.what,
        '_inFlightCommitCritical',
      );
    });

    test('flags a critical link bounded through a wrapper', () {
      // A bound one level up cuts the same future.
      final v = run(
        'await Future.wait([a.pauseSubscriptions()]).timeout(budget);',
      );
      expect(v, hasLength(1));
    });

    test('does not flag a bounded ORDINARY future', () {
      // `_inFlightPublish` is a plain application message: the sender ratchet
      // advanced and persisted before the relay was contacted, there is no
      // staged commit to resolve, and its teardown drain is deliberately
      // bounded. Flagging it would make this guard cry wolf on the one file
      // that documents the distinction.
      expect(run('await _inFlightPublish?.timeout(budget);'), isEmpty);
      expect(run('await relay.publishEvent(e).timeout(budget);'), isEmpty);
    });

    test('does not flag a local named publishFailed', () {
      // The background task tracks its per-cycle outcome in a bool of that
      // name. Requiring a receiver is what keeps the two apart.
      expect(
        run('''
          var publishFailed = false;
          await something.timeout(budget);
          if (publishFailed) return;
        '''),
        isEmpty,
      );
    });

    test('does not flag an unbounded critical link next to a bounded one', () {
      expect(
        run('''
          await ordinary.timeout(budget);
          await subscriptions.pauseSubscriptions();
        '''),
        isEmpty,
      );
    });
  });

  group('wrapper derivation', () {
    test('flags a bound on the private helper that holds the teardown', () {
      // The whole teardown behind one name, called bare from a `finally` —
      // the shape the coordinator actually has.
      final v = _violationsIn('''
class _C {
  Future<void> _closeBurst(DateTime startedAt) async {
    await _engine.settleBeforePause();
    await _engine.pauseSubscriptions();
  }

  Future<void> _run() async {
    try {
      await _work();
    } finally {
      await _closeBurst(startedAt).timeout(const Duration(seconds: 5));
    }
  }
}
''');
      expect(v, hasLength(1));
      expect(v.single.what, '_closeBurst() → settleBeforePause()');
    });

    test('flags a bound two hops above the link', () {
      // `onTick` → `_runBurst` → `_closeBurst` → settle. Every hop is one
      // refactor, and each one used to make the guard blind.
      final v = _violationsIn('''
class _C {
  Future<void> _closeBurst() async => _engine.pauseSubscriptions();
  Future<void> _runBurst() async {
    try {
      await _publishPass();
    } finally {
      await _closeBurst();
    }
  }

  Future<void> _tick() => _runBurst().timeout(budget);
}
''');
      expect(v, hasLength(1));
      expect(
        v.single.what,
        '_runBurst() → _closeBurst() → pauseSubscriptions()',
      );
    });

    test('flags a bound on a private wrapper reached through a receiver', () {
      // `_x` is library-private: it can only denote the declaration in this
      // file, whatever object it is called on.
      expect(
        _violationsIn('''
class _C {
  Future<void> _closeBurst() async => _engine.pauseSubscriptions();
}

class _D {
  Future<void> go(_C c) => c._closeBurst().timeout(budget);
}
'''),
        hasLength(1),
      );
    });

    test('does not flag a bound on a private helper with no link', () {
      // The false-positive that would make this rule useless: a private
      // teardown helper that shuts a pool and touches no commit.
      expect(
        _violationsIn('''
class _C {
  Future<void> _closeBurst() async {
    await _pool.shutdown();
    _cache.clear();
  }

  Future<void> _run() => _closeBurst().timeout(budget);
}
'''),
        isEmpty,
      );
    });

    test('flags a bound on a PUBLIC wrapper declared in the same file', () {
      // The shape the private-only rule could not see: the wrapper is a
      // public static, and the bound is written on the CALL rather than on the
      // link inside it. `MapShell.releaseBurstPlaneOnOptOut` is exactly this.
      final v = _violationsIn('''
class MapShell {
  static Future<void> releaseBurstPlaneOnOptOut({
    required SubscriptionService engine,
  }) async {
    await engine.pauseSubscriptions();
  }
}

class _MapShellState {
  Future<void> _onPaused() async {
    await MapShell.releaseBurstPlaneOnOptOut(engine: e)
        .timeout(const Duration(seconds: 5));
  }
}
''');
      expect(v, hasLength(1));
      expect(
        v.single.what,
        'releaseBurstPlaneOnOptOut() → pauseSubscriptions()',
      );
    });

    test('flags a bound two hops above a public wrapper', () {
      // Public and private hops mix freely: what matters is that every name in
      // the chain is declared in this unit.
      final v = _violationsIn('''
class MapShell {
  static Future<void> releaseBurstPlaneOnOptOut(SubscriptionService e) =>
      e.pauseSubscriptions();
}

class _S {
  Future<void> _onPaused() =>
      MapShell.releaseBurstPlaneOnOptOut(_engine);

  Future<void> didChangeAppLifecycleState(AppLifecycleState s) =>
      _onPaused().timeout(budget);
}
''');
      expect(v, hasLength(1));
      expect(
        v.single.what,
        '_onPaused() → releaseBurstPlaneOnOptOut() → pauseSubscriptions()',
      );
    });

    test('does not flag a bound on a PUBLIC method of another file', () {
      // `sink.onTick(...)` is an interface call, and THIS unit declares no
      // `onTick`. Nothing here resolves a public name across files: a public
      // wrapper is derived from the declaration in front of us and matched
      // only against call sites in the same unit. The boundary is deliberate —
      // see the header.
      expect(
        _violationsIn('''
class _C {
  Future<void> dispatch(BurstSink sink) =>
      sink.onTick(circleKey: k, circle: c).timeout(budget);
}
'''),
        isEmpty,
      );
    });

    test('does not derive a wrapper from a link named in PROSE', () {
      // The mirror of the counter rule: a helper whose only mention of a link
      // is in its own doc comment resolves nothing and must not be derived.
      expect(
        _violationsIn('''
class _C {
  /// Called instead of [pauseSubscriptions], which it deliberately does not.
  Future<void> _closeBurst() async {
    await _pool.shutdown();
  }

  Future<void> _run() => _closeBurst().timeout(budget);
}
'''),
        isEmpty,
      );
    });

    test('does not flag a bound on a public helper with no link', () {
      // Widening to public names must not widen what COUNTS as critical: the
      // false positive that would make the rule useless is a public teardown
      // helper that touches no commit.
      expect(
        _violationsIn('''
class MapShell {
  static Future<void> releaseOverlay(Overlay o) async {
    await o.dismiss();
  }
}

class _S {
  Future<void> _run() => MapShell.releaseOverlay(o).timeout(budget);
}
'''),
        isEmpty,
      );
    });

    test('a name is critical if ANY of its declarations is', () {
      // One unit, two declarations of `onTick`: the abstract interface member
      // and the implementation that holds the teardown. Keeping only the last
      // seen would make criticality depend on declaration ORDER, so the empty
      // body is written AFTER the real one here.
      final v = _violationsIn('''
class _Coordinator {
  Future<void> onTick() async {
    await _engine.pauseSubscriptions();
  }
}

abstract class BurstSink {
  Future<void> onTick() async {}
}

class _S {
  Future<void> _run(_Coordinator c) => c.onTick().timeout(budget);
}
''');
      expect(v, hasLength(1));
      expect(v.single.what, 'onTick() → pauseSubscriptions()');
    });

    test('a self-recursive private helper is not critical by itself', () {
      // `_retry` calling `_retry` proves nothing; without the guard the
      // fixpoint would happily call it critical on its own name.
      expect(
        _violationsIn('''
class _C {
  Future<void> _retry(int n) async {
    if (n > 0) await _retry(n - 1);
  }

  Future<void> _run() => _retry(3).timeout(budget);
}
'''),
        isEmpty,
      );
    });

    test('derives no wrapper from a file with no links', () {
      expect(
        criticalWrappersIn(
          parseString(
            content: 'class _C { Future<void> _a() => _b(); '
                'Future<void> _b() async {} }',
            throwIfDiagnostics: false,
          ).unit,
        ),
        isEmpty,
      );
    });
  });

  group('inventory self-tests', () {
    // The inventory passes below are only worth their assertions if the thing
    // doing the counting reports ZERO for an absent link. A counter that
    // matched declarations, or that never reset, would make every
    // `greaterThan(0)` below true of any file at all.
    test('counts a call ON something, not a bare one or a declaration', () {
      expect(
        _criticalCounts('class _S { void go() { a.pauseSubscriptions(); } }'),
        {'pauseSubscriptions': 1},
      );
      expect(
        _criticalCounts('class _S { Future<void> pauseSubscriptions(); }'),
        isEmpty,
      );
      expect(_criticalCounts('void go() { pauseSubscriptions(); }'), isEmpty);
    });

    test('prose does not count as a link', () {
      // The counter is what every per-file floor answers from, so a doc
      // reference that counted would let a file keep its floor by describing a
      // registration it had deleted.
      expect(
        _criticalCounts('''
/// Registers [commitCritical] and mentions [pauseSubscriptions].
class _S {
  /// See [settleBeforePause].
  void go() {}
}
'''),
        isEmpty,
      );
      // …and the executable form of the same names still counts, so the rule
      // above is about COMMENTS and not about having stopped counting.
      expect(
        _criticalCounts('''
/// Registers [commitCritical].
class _S {
  void go() {
    a.settleBeforePause();
  }
}
'''),
        {'settleBeforePause': 1},
      );
    });

    test('reports zero for a link a real file does not have', () {
      // The coordinator resolves no commit itself — it settles and pauses.
      // If this came back non-zero the per-file floors below would be
      // satisfied by a counter that cannot tell links apart.
      final counts = _criticalCounts(_read(_coordinator));
      expect(counts['confirmPublished'] ?? 0, 0);
      expect(counts['finalizeRelayUpdate'] ?? 0, 0);
      expect(counts['settleBeforePause'] ?? 0, greaterThan(0));
    });
  });

  group('lib/ carries no bounded commit-critical link', () {
    test('no `.timeout(` wraps one', () {
      final offenders = <String>[];
      for (final file in _libSources()) {
        for (final v in _violationsIn(file.readAsStringSync())) {
          offenders.add('${file.path}:$v');
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'Security Rule 13: a commit-critical link is bounded by a clock. '
            'A `.timeout(` does not cancel the Rust future — it lets the '
            'caller return and the process suspend with a commit between SEND '
            'and OK, which forks the roster.\n'
            'Offenders:\n  ${offenders.join('\n  ')}',
      );
    });

    test('the scan still sees every commit-critical link (anti-vacuity)', () {
      // Renaming a link, or moving one out of `lib/`, would otherwise make the
      // scan above pass by inspecting nothing.
      final counts = <String, int>{};
      for (final file in _libSources()) {
        _criticalCounts(
          file.readAsStringSync(),
        ).forEach((k, v) => counts[k] = (counts[k] ?? 0) + v);
      }
      for (final name in {..._criticalMethods, '_inFlightCommitCritical'}) {
        expect(
          counts[name] ?? 0,
          greaterThan(0),
          reason:
              'no call to `$name` was found anywhere in lib/. Either it was '
              'renamed (update _criticalMethods / _criticalFutures in the '
              'same change) or this guard has gone blind.',
        );
      }
    });

    test('every file that owns a teardown still has its links '
        '(anti-vacuity)', () {
      // The global count above is satisfied by whichever file still has a
      // link. Deleting BOTH of the coordinator's leaves it green, over a file
      // it now inspects for nothing.
      for (final entry in _teardownOwners.entries) {
        final counts = _criticalCounts(_read(entry.key));
        for (final name in entry.value) {
          expect(
            counts[name] ?? 0,
            greaterThan(0),
            reason:
                '${entry.key} no longer calls `$name`, so the Rule 13 scan '
                'now inspects that file for nothing. Either the teardown '
                'moved (point _teardownOwners at its new home) or the file '
                'genuinely stopped owning one (remove its entry, and say so).',
          );
        }
      }
    });

    test('_teardownOwners covers every critical name (anti-vacuity)', () {
      // A name present in _criticalMethods but in no owner's set would have a
      // global count and no per-file floor — exactly the hole above.
      final owned = _teardownOwners.values.expand((s) => s).toSet();
      expect(
        {..._criticalMethods, ..._criticalFutures}.difference(owned),
        isEmpty,
        reason:
            'these critical names have no owning file, so only the global '
            'count protects them — add the file that owns each',
      );
    });

    test('the corpus is the whole of lib/ (anti-vacuity)', () {
      // A walker that silently yielded nothing would make both tests above
      // vacuous, and it is one wrong path separator away from doing so.
      final files = _libSources().toList();
      expect(files.length, greaterThan(100));
      expect(
        files.map((f) => f.path),
        contains(
          'lib${Platform.pathSeparator}src${Platform.pathSeparator}services'
          '${Platform.pathSeparator}nostr_subscription_service.dart',
        ),
      );
    });
  });

  group('the derivation fires on the real coordinator (anti-vacuity)', () {
    test('_closeBurst is derived critical, and _runBurst through it', () {
      final wrappers = criticalWrappersIn(
        parseString(
          content: _read(_coordinator),
          throwIfDiagnostics: false,
        ).unit,
      );
      expect(
        wrappers['_closeBurst'],
        contains('settleBeforePause()'),
        reason:
            "the coordinator's teardown helper is what the derivation exists "
            'for. If it is gone, the guard is protecting a shape that no '
            'longer exists.',
      );
      expect(
        wrappers['_runBurst'],
        contains('_closeBurst()'),
        reason: 'the transitive hop must still close over the real file',
      );
    });

    test('a bound on the real _closeBurst call is flagged', () {
      // The mutation that used to survive: a five-second cap on the whole
      // teardown, written into the `finally` of the real burst.
      final mutated = _injectIntoMethod(
        _read(_coordinator),
        '_runBurst',
        'await _closeBurst().timeout(const Duration(seconds: 5));',
      );
      final found = _violationsIn(mutated);
      expect(found, hasLength(1));
      expect(found.single.what, contains('_closeBurst()'));
    });

    test('a bound on the real settle link is flagged', () {
      final mutated = _injectIntoMethod(
        _read(_coordinator),
        '_closeBurst',
        'await _engine.settleBeforePause().timeout(oneBurst);',
      );
      expect(_violationsIn(mutated), hasLength(1));
    });

    test('the unmutated coordinator is clean (the mutation is what fires)', () {
      expect(_violationsIn(_read(_coordinator)), isEmpty);
    });
  });

  group('the derivation fires on the real map_shell (anti-vacuity)', () {
    // The coordinator's chain is all private; map_shell's is not, and it is
    // the file that proved the private-only rule too narrow. Both halves are
    // pinned against the REAL source, because a hand-written snippet can only
    // show that the checker CAN fire, never that it fires here.
    test('releaseBurstPlaneOnOptOut is derived critical', () {
      final wrappers = criticalWrappersIn(
        parseString(
          content: _read(_mapShell),
          throwIfDiagnostics: false,
        ).unit,
      );
      expect(
        wrappers['releaseBurstPlaneOnOptOut'],
        contains('pauseSubscriptions()'),
        reason:
            'the opt-out release is the first PUBLIC commit-critical wrapper '
            'in lib/. If it stops being derived, a `.timeout(` on its call '
            'site goes back to being invisible.',
      );
    });

    test('a bound on the real releaseBurstPlaneOnOptOut call is flagged', () {
      // The mutation that survived the private-only rule: a five-second cap
      // written on the CALL, in the pause path that runs while frames are off.
      // It cancels nothing — the engine drains on — so the process can suspend
      // with a commit between SEND and OK while the caller has already
      // returned.
      final mutated = _injectIntoMethod(
        _read(_mapShell),
        '_onPaused',
        'await MapShell.releaseBurstPlaneOnOptOut(engine: e, '
            'shutdownPublishPool: s).timeout(const Duration(seconds: 5));',
      );
      final found = _violationsIn(mutated);
      expect(found, hasLength(1));
      expect(found.single.what, contains('releaseBurstPlaneOnOptOut()'));
    });

    test('the unmutated map_shell is clean (the mutation is what fires)', () {
      expect(_violationsIn(_read(_mapShell)), isEmpty);
    });
  });

  group('the derivation fires on the real location-sharing service '
      '(anti-vacuity)', () {
    // `_awaitCommitCritical(commitCritical)` registers each of the three
    // `resolveAutoCommits` windows as in-flight, so the burst teardown can see
    // them before it shuts the SHARED publish pool. The registration is
    // reached by the parameter's NAME, and the callers that go through it are
    // PUBLIC — this is the first production use of the same-unit public rule,
    // so it is pinned against the real file rather than assumed.
    Map<String, String> wrappers() => criticalWrappersIn(
      parseString(
        content: _read(_locationSharing),
        throwIfDiagnostics: false,
      ).unit,
    );

    test('the registration is derived critical', () {
      expect(
        wrappers()['_awaitCommitCritical'],
        contains('commitCritical'),
        reason:
            'the registration is what the three resolveAutoCommits windows '
            'are reached through. If it stops being derived, a bound anywhere '
            'above it goes back to being invisible.',
      );
    });

    test('its PUBLIC callers are derived through it', () {
      // Under the old private-only rule these three would have derived
      // nothing: every one of them is public, and every one of them owns a
      // publish-then-confirm window.
      final derived = wrappers();
      for (final name in [
        'fetchMemberLocations',
        'publishLocation',
        'pollEvolutionEvents',
      ]) {
        expect(
          derived[name],
          contains('commitCritical'),
          reason:
              '`$name` reaches a staged commit through _awaitCommitCritical, '
              'so a `.timeout(` on a call to it in this file cuts the same '
              'future. It is public, which is exactly the case the derivation '
              'was widened for.',
        );
      }
    });

    test('a bound on the real registration call is flagged', () {
      final mutated = _injectIntoMethod(
        _read(_locationSharing),
        '_handleDeferredSend',
        'await _awaitCommitCritical(p).timeout(const Duration(seconds: 5));',
      );
      final found = _violationsIn(mutated);
      expect(found, hasLength(1));
      expect(found.single.what, contains('_awaitCommitCritical()'));
    });

    test('a bound on a real PUBLIC caller is flagged', () {
      // The rule the widening bought, on production code:
      // `fetchMemberLocations` is public, is declared in THIS unit, and is
      // derived critical — so a bound on a call to it here is caught, while
      // the same name called in another file is not (see the boundary
      // self-tests). The argument list is irrelevant: nothing resolves it.
      final mutated = _injectIntoMethod(
        _read(_locationSharing),
        '_handleDeferredSend',
        'await fetchMemberLocations(c).timeout(const Duration(seconds: 5));',
      );
      final found = _violationsIn(mutated);
      expect(found, hasLength(1));
      expect(found.single.what, contains('fetchMemberLocations()'));
    });

    test('the unmutated service is clean (the mutation is what fires)', () {
      expect(_violationsIn(_read(_locationSharing)), isEmpty);
    });
  });
}
