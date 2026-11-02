// The live-sync engine cannot see the screen. Whether its session is the
// foreground's — where it records commits as durable fanouts, drives the stored
// ones, redeems a parked eviction and re-anchors the whole session — is a
// CLAIM this side makes, as a `foreground:` argument on three FFI entries. The
// engine acts on that word and on nothing it could infer.
//
// So the word must have exactly one meaning, `appIsResumed()`: the lifecycle
// state is `resumed`, and an unset state, `inactive`, `hidden`, `paused`,
// `detached` and a missing binding are all "no". The neighbouring predicates
// are looser on purpose (`appIsForegrounded()` answers yes for an unset
// state so startup work is not lost; `appForegroundProvider` answers yes for
// `inactive`), and either of them handed across the FFI is how a process the
// OS launched in the background, with nobody looking, would be told it is the
// foreground.
//
// The behaviour is tested where it lives (`nostr_subscription_service_test`,
// `app_is_resumed_no_binding_test`, `maintenance_scheduler_provider_test`).
// This file holds the shape those tests cannot: that there is no OTHER place
// in `lib/` where a `foreground:` argument is spelled, and none that is fed
// by anything but the strict read — nor an `inFront:` read handed to a
// leave's carry-on, which claims from it at each call.
//
// Known limits — what this file does NOT catch:
//  * an `await` inserted between the read and the call it feeds, in a layer
//    that hands the claim on: the claim is then stale, and nothing here says
//    so;
//  * a call made through `Function.apply`, or through a tear-off of one of
//    the three entries, which spells no `foreground:` argument at all;
//  * a hand-written file under `lib/src/rust/`, which is skipped as generated
//    bridge code;
//  * a `foreground` a handing-on layer INHERITS — a field or a getter declared
//    in a superclass or a mixin in another file. In the file itself a default
//    value on the parameter, a getter of that name and an assignment through
//    `this.` are each found.
@TestOn('vm')
library;

import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every `foreground:` argument in `lib/`, by file: the call it is handed to
/// and the expression it is given, in source order.
///
/// Four spellings are allowed and each means the strict read or a "no": the
/// read itself; a parameter named `foreground` being handed on untouched by a
/// layer that does not decide anything (and never assigns it: see below); the
/// circle service's `_appInFront()`, which is the read or, in a background
/// isolate's service, a constant `false` (pinned below); and a literal
/// `false`, in the Android service's isolate, which is never in front. A
/// session start carries none: the service claims once it holds the engine.
///
/// A new site is added here in the change that adds it — which is the point:
/// someone has to say where its claim comes from.
const _claimSites = <String, List<String>>{
  'lib/src/providers/maintenance_scheduler_provider.dart': [
    'maintainSubscriptionHealth(foreground: appIsResumed())',
    'reinviteOwed(foreground: appIsResumed())',
    'resumeDrive(foreground: appIsResumed())',
  ],
  // The Android service's cycle drives its stored records claiming nothing.
  'lib/src/services/background_location_task.dart': [
    'resume(foreground: false)',
    'sealLocation(foreground: false)',
  ],
  // The leaver backstop claims what its caller's lifecycle read says at each
  // call: `appIsResumed` from a foreground plane, none from a background one.
  'lib/src/services/leaver_backstop.dart': [
    'resumeLeave(foreground: inFront?.call() ?? false)',
  ],
  'lib/src/services/maintenance_service.dart': [
    'reinvite(foreground: foreground)',
    'resume(foreground: foreground)',
    'maintainSubscriptionHealth(foreground: foreground)',
  ],
  // The circle changes the user makes, handed to the fanout driver once the
  // live session has settled its own claim (`_foreground`, pinned below).
  'lib/src/services/nostr_circle_service.dart': [
    'createCircle(foreground: await _foreground())',
    'leave(foreground: await _foreground())',
    'removeMembers(foreground: await _foreground())',
    'addMembers(foreground: await _foreground())',
    'updateCircleRelays(foreground: await _foreground())',
    'repairRotation(foreground: await _foreground())',
    // A location's seal.
    'sealLocation(foreground: _appInFront())',
    // A polled event's ingest.
    'ingest(foreground: _appInFront())',
    'circleRecovery(foreground: _appInFront())',
  ],
  'lib/src/services/nostr_relay_service.dart': [
    'maintainSubscriptionHealth(foreground: foreground)',
    'createCircleDriven(foreground: foreground)',
    'addMembersDriven(foreground: foreground)',
    'removeMembersDriven(foreground: foreground)',
    'updateCircleRelaysDriven(foreground: foreground)',
    'adminHandoffDriven(foreground: foreground)',
    'selfDemoteDriven(foreground: foreground)',
    'repairRotationDriven(foreground: foreground)',
    'circleRecovery(foreground: foreground)',
    'ingestDriven(foreground: foreground)',
    'resumeDriven(foreground: foreground)',
    'reinviteDriven(foreground: foreground)',
    'sealLocationDriven(foreground: foreground)',
    'leaveDriven(foreground: foreground)',
    'resumeLeaveDriven(foreground: foreground)',
  ],
  'lib/src/services/nostr_subscription_service.dart': [
    'resumeAfterBackground(foreground: appIsResumed())',
    'claimForeground(foreground: appIsResumed())',
  ],
};

/// Every `inFront:` argument in `lib/`, by file: what a caller hands a leave's
/// carry-on as its lifecycle read, which the backstop then claims from at
/// each call (`leaver_backstop.dart`). Two spellings are allowed: a tear-off
/// of the strict read, and a parameter named `inFront` handed on untouched.
const _inFrontSites = <String, List<String>>{
  'lib/src/pages/map_shell.dart': ['carryOnLeavesNow(inFront: appIsResumed)'],
  // The single-flight carry-on records each caller's read in an ask (a record
  // built from the parameter, or merged from another ask) and hands it on.
  'lib/src/providers/maintenance_scheduler_provider.dart': [
    '?(inFront: inFront)',
    '_carryOnOnce(inFront: next.inFront)',
    '?(inFront: ask.inFront)',
    'migrateToCore(inFront: inFront)',
    'carryOnLeaves(inFront: inFront)',
    'carryOnLeavesNow(inFront: appIsResumed)',
    'carryOnLeavesNow(inFront: appIsResumed)',
  ],
  'lib/src/providers/service_providers.dart': [
    'carryOnLeavesNow(inFront: appIsResumed)',
  ],
  'lib/src/services/maintenance_service.dart': ['carryOn(inFront: inFront)'],
};

class _InFrontCollector extends RecursiveAstVisitor<void> {
  final List<String> found = [];

  @override
  void visitNamedExpression(NamedExpression node) {
    if (node.name.label.name == 'inFront') {
      final call = node.thisOrAncestorOfType<MethodInvocation>();
      found.add(
        '${call?.methodName.name ?? '?'}'
        '(inFront: ${node.expression.toSource()})',
      );
    }
    super.visitNamedExpression(node);
  }
}

/// What a handing-on layer could make of an `inFront` it is given: an
/// assignment, a declaration over it, or a default of its own.
class _InFrontRewriteCollector extends RecursiveAstVisitor<void> {
  final List<String> found = [];

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    final lhs = node.leftHandSide;
    if ((lhs is SimpleIdentifier && lhs.name == 'inFront') ||
        (lhs is PropertyAccess && lhs.propertyName.name == 'inFront')) {
      found.add(node.toSource());
    }
    super.visitAssignmentExpression(node);
  }

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    if (node.name.lexeme == 'inFront') found.add(node.toSource());
    super.visitVariableDeclaration(node);
  }

  @override
  void visitDefaultFormalParameter(DefaultFormalParameter node) {
    if (node.name?.lexeme == 'inFront' && node.defaultValue != null) {
      found.add(node.toSource());
    }
    super.visitDefaultFormalParameter(node);
  }
}

List<String> _inFrontIn(String source) {
  final unit = parseString(content: source, throwIfDiagnostics: false).unit;
  final collector = _InFrontCollector();
  unit.accept(collector);
  return collector.found;
}

List<String> _inFrontRewritesIn(String source) {
  final unit = parseString(content: source, throwIfDiagnostics: false).unit;
  final collector = _InFrontRewriteCollector();
  unit.accept(collector);
  return collector.found;
}

class _ClaimCollector extends RecursiveAstVisitor<void> {
  final List<String> found = [];

  @override
  void visitNamedExpression(NamedExpression node) {
    if (node.name.label.name == 'foreground') {
      final call = node.thisOrAncestorOfType<MethodInvocation>();
      found.add(
        '${call?.methodName.name ?? '?'}'
        '(foreground: ${node.expression.toSource()})',
      );
    }
    super.visitNamedExpression(node);
  }
}

/// What the circle service gives `_appInFront`: each constructor's
/// initializer, every assignment, the field and the constant `no`.
class _AppInFrontCollector extends RecursiveAstVisitor<void> {
  _AppInFrontCollector({
    required this.onInitializer,
    required this.onAssignment,
    required this.onField,
    required this.onNever,
  });

  final void Function(String) onInitializer;
  final void Function(String) onAssignment;
  final void Function(String) onField;
  final void Function(String) onNever;

  @override
  void visitConstructorFieldInitializer(ConstructorFieldInitializer node) {
    if (node.fieldName.name == '_appInFront') {
      onInitializer(node.expression.toSource());
    }
    super.visitConstructorFieldInitializer(node);
  }

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    if (node.leftHandSide.toSource().endsWith('_appInFront')) {
      onAssignment(node.toSource());
    }
    super.visitAssignmentExpression(node);
  }

  @override
  void visitFieldDeclaration(FieldDeclaration node) {
    if (node.fields.variables.any((v) => v.name.lexeme == '_appInFront')) {
      onField(node.toSource());
    }
    super.visitFieldDeclaration(node);
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    if (node.name.lexeme == '_neverInFront') onNever(node.toSource());
    super.visitMethodDeclaration(node);
  }
}

/// Everything that gives something named `foreground` a value other than the
/// caller's: an assignment (bare or through a receiver), a pattern
/// assignment, a declaration that shadows the parameter (a local, a pattern
/// variable, a loop variable), a getter of that name, and a default value on
/// the parameter itself — as written. A parameter declared without a default
/// is none of these.
class _AssignmentCollector extends RecursiveAstVisitor<void> {
  final List<String> found = [];

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    final target = node.leftHandSide;
    final assigned = switch (target) {
      SimpleIdentifier() => target.name,
      PropertyAccess() => target.propertyName.name,
      PrefixedIdentifier() => target.identifier.name,
      _ => null,
    };
    if (assigned == 'foreground') found.add(node.toSource());
    super.visitAssignmentExpression(node);
  }

  @override
  void visitDefaultFormalParameter(DefaultFormalParameter node) {
    if (node.name?.lexeme == 'foreground' && node.defaultValue != null) {
      found.add(node.toSource());
    }
    super.visitDefaultFormalParameter(node);
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    if (node.isGetter && node.name.lexeme == 'foreground') {
      found.add(node.toSource());
    }
    super.visitMethodDeclaration(node);
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    if (node.isGetter && node.name.lexeme == 'foreground') {
      found.add(node.toSource());
    }
    super.visitFunctionDeclaration(node);
  }

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    if (node.name.lexeme == 'foreground') found.add(node.toSource());
    super.visitVariableDeclaration(node);
  }

  @override
  void visitAssignedVariablePattern(AssignedVariablePattern node) {
    if (node.name.lexeme == 'foreground') {
      found.add(_patternStatement(node));
    }
    super.visitAssignedVariablePattern(node);
  }

  @override
  void visitDeclaredVariablePattern(DeclaredVariablePattern node) {
    if (node.name.lexeme == 'foreground') {
      found.add(_patternStatement(node));
    }
    super.visitDeclaredVariablePattern(node);
  }

  @override
  void visitDeclaredIdentifier(DeclaredIdentifier node) {
    if (node.name.lexeme == 'foreground') found.add(node.toSource());
    super.visitDeclaredIdentifier(node);
  }

  /// The pattern assignment or declaration [node] belongs to, as written.
  static String _patternStatement(AstNode node) =>
      (node.thisOrAncestorOfType<PatternAssignment>() ??
              node.thisOrAncestorOfType<PatternVariableDeclaration>() ??
              node.thisOrAncestorOfType<GuardedPattern>() ??
              node)
          .toSource();
}

/// Every call of something named `claimForeground`, with or without a
/// receiver, as written.
class _ClaimCallCollector extends RecursiveAstVisitor<void> {
  final List<String> found = [];

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (node.methodName.name == 'claimForeground') found.add(node.toSource());
    super.visitMethodInvocation(node);
  }

  @override
  void visitComment(Comment node) {}
}

/// Every expression a named argument [label] is given, as written.
List<String> _namedArgumentsIn(String source, String label) {
  final unit = parseString(content: source, throwIfDiagnostics: false).unit;
  final found = <String>[];
  unit.accept(_NamedArgumentCollector(label, found.add));
  return found;
}

class _NamedArgumentCollector extends RecursiveAstVisitor<void> {
  _NamedArgumentCollector(this.label, this.onFound);

  final String label;
  final void Function(String) onFound;

  @override
  void visitNamedExpression(NamedExpression node) {
    if (node.name.label.name == label) onFound(node.expression.toSource());
    super.visitNamedExpression(node);
  }
}

/// What the method [name] returns, each `return` as written, in source order.
class _ReturnCollector extends RecursiveAstVisitor<void> {
  _ReturnCollector(this.name, this.onReturn);

  final String name;
  final void Function(String) onReturn;

  @override
  void visitReturnStatement(ReturnStatement node) {
    final method = node.thisOrAncestorOfType<MethodDeclaration>();
    if (method?.name.lexeme == name) {
      onReturn(node.expression?.toSource() ?? '');
    }
    super.visitReturnStatement(node);
  }
}

List<String> _claimCallsIn(String source) {
  final unit = parseString(content: source, throwIfDiagnostics: false).unit;
  final collector = _ClaimCallCollector();
  unit.accept(collector);
  return collector.found;
}

List<String> _assignmentsIn(String source) {
  final unit = parseString(content: source, throwIfDiagnostics: false).unit;
  final collector = _AssignmentCollector();
  unit.accept(collector);
  return collector.found;
}

List<String> _claimsIn(String source) {
  final unit = parseString(content: source, throwIfDiagnostics: false).unit;
  final collector = _ClaimCollector();
  unit.accept(collector);
  return collector.found;
}

/// Every Dart file under `lib/` that is not generated bridge code.
Iterable<File> _libFiles() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'))
    .where((f) => !f.path.replaceAll(r'\', '/').startsWith('lib/src/rust/'));

/// [source] with every `//` comment removed, so a sentence ABOUT a call is
/// never read as the call.
String _code(String source) => source
    .split('\n')
    .map((line) {
      final at = line.indexOf('//');
      return at < 0 ? line : line.substring(0, at);
    })
    .join('\n');

void main() {
  group('the checker sees what it must', () {
    test('a literal claim is found, and spelled as written', () {
      expect(
        _claimsIn('f() => engine.startSession(groups: g, foreground: true);'),
        ['startSession(foreground: true)'],
      );
    });

    test('a claim fed by the looser predicate is found', () {
      expect(
        _claimsIn(
          'f() => api.tick(foreground: appIsForegrounded());',
        ),
        ['tick(foreground: appIsForegrounded())'],
      );
    });

    test('a declaration is not a claim', () {
      expect(
        _claimsIn('Future<void> tick({required bool foreground}) async {}'),
        isEmpty,
      );
    });

    test('a reassigned claim is found, however it is assigned', () {
      expect(
        _assignmentsIn(
          'f({required bool foreground}) { foreground = true; '
          'foreground |= other; return api.tick(foreground: foreground); }',
        ),
        ['foreground = true', 'foreground |= other'],
      );
      expect(
        _assignmentsIn('f({required bool foreground}) => g(foreground);'),
        isEmpty,
      );
    });

    test('a declaration that shadows the claim is found', () {
      expect(
        _assignmentsIn(
          'f({required bool foreground}) { g() { final foreground = true; '
          'return api.tick(foreground: foreground); } return g(); }',
        ),
        ['foreground = true'],
      );
      expect(
        _assignmentsIn(
          'f(List<bool> all) { for (final foreground in all) { '
          'api.tick(foreground: foreground); } }',
        ),
        ['final foreground'],
      );
    });

    test('a pattern that assigns or declares the claim is found', () {
      expect(
        _assignmentsIn(
          'f({required bool foreground}) { (foreground, _) = (true, 0); '
          'return api.tick(foreground: foreground); }',
        ),
        ['(foreground, _) = (true, 0)'],
      );
      expect(
        _assignmentsIn(
          'f(Object o) { final (foreground, _) = (true, 0); '
          'return api.tick(foreground: foreground); }',
        ),
        ['final (foreground, _) = (true, 0)'],
      );
      expect(
        _assignmentsIn(
          'f(Object o) { if (o case final bool foreground) { '
          'return api.tick(foreground: foreground); } }',
        ),
        ['final bool foreground'],
      );
    });

    test('a claim the layer supplies itself is found: a default, a getter, '
        'an assignment through a receiver', () {
      expect(
        _assignmentsIn(
          'f({bool foreground = true}) => api.tick(foreground: foreground);',
        ),
        ['bool foreground = true'],
      );
      expect(
        _assignmentsIn(
          'class S { bool get foreground => true; '
          'f() => api.tick(foreground: foreground); }',
        ),
        ['bool get foreground => true;'],
      );
      expect(
        _assignmentsIn('bool get foreground => true;'),
        ['bool get foreground => true;'],
      );
      expect(
        _assignmentsIn(
          'class S extends B { f() { this.foreground = true; '
          'other.foreground = true; '
          'return api.tick(foreground: foreground); } }',
        ),
        ['this.foreground = true', 'other.foreground = true'],
      );
      expect(
        _assignmentsIn(
          'f({required bool foreground, bool? other}) => g(foreground);',
        ),
        isEmpty,
        reason: 'a parameter the caller must give is not a value of its own',
      );
    });

    test('a claim call is found with or without a receiver', () {
      expect(
        _claimCallsIn(
          'class S { f() async { await claimForeground(); '
          'await engine.claimForeground(foreground: true); '
          '// engine.claimForeground() in a comment\n'
          '} }',
        ),
        ['claimForeground()', 'engine.claimForeground(foreground: true)'],
      );
    });
  });

  test('every foreground claim in lib/ is one this file names', () {
    final found = <String, List<String>>{};
    for (final file in _libFiles()) {
      final claims = _claimsIn(file.readAsStringSync());
      if (claims.isNotEmpty) {
        found[file.path.replaceAll(r'\', '/')] = claims;
      }
    }
    expect(
      found,
      _claimSites,
      reason: 'a `foreground:` argument appeared, went, or changed what it is '
          'given. Each one is the app telling the engine its lifecycle reads '
          '`resumed`: it is handed `appIsResumed()` — directly, or as a '
          '`foreground` parameter passed on untouched — and nothing looser',
    );
  });

  test('the lifecycle read handed to a carry-on is spelled as written, and '
      'a rewrite of a handed-on one is found', () {
    expect(
      _inFrontIn('f(s) => s.carryOnLeavesNow(inFront: appIsForegrounded);'),
      ['carryOnLeavesNow(inFront: appIsForegrounded)'],
    );
    expect(
      _inFrontRewritesIn(
        'f({bool Function()? inFront}) { inFront = () => true; } '
        'g({bool Function()? inFront = _yes}) {} '
        'h() { final inFront = appIsForegrounded; }',
      ),
      [
        'inFront = () => true',
        'bool Function()? inFront = _yes',
        'inFront = appIsForegrounded',
      ],
    );
  });

  test('every lifecycle read handed to a carry-on in lib/ is the strict one',
      () {
    final found = <String, List<String>>{};
    for (final file in _libFiles()) {
      final given = _inFrontIn(file.readAsStringSync());
      if (given.isNotEmpty) found[file.path.replaceAll(r'\', '/')] = given;
    }
    expect(
      found,
      _inFrontSites,
      reason: 'an `inFront:` argument appeared, went, or changed what it is '
          'given. The backstop claims the foreground from it at each call: '
          'it is `appIsResumed` or an `inFront` handed on, never a looser '
          'read such as `appIsForegrounded`',
    );
    for (final entry in _inFrontSites.entries) {
      if (!entry.value.any((site) => site.contains('(inFront: '))) {
        continue;
      }
      expect(
        _inFrontRewritesIn(File(entry.key).readAsStringSync()),
        isEmpty,
        reason: '${entry.key} hands an `inFront` on: nothing may be put in '
            'its place on the way',
      );
    }
  });

  test('a layer that hands the claim on never assigns it', () {
    for (final entry in _claimSites.entries) {
      final handsOn = entry.value.any(
        (site) => site.endsWith('(foreground: foreground)'),
      );
      if (!handsOn) continue;
      expect(
        _assignmentsIn(File(entry.key).readAsStringSync()),
        isEmpty,
        reason: '${entry.key} hands a `foreground` parameter on: the table '
            'above reads the same whatever was assigned to it, or declared '
            'over it, on the way',
      );
    }
  });

  test('the strict read is strict', () {
    final handover = _code(
      File('lib/src/services/mls_session_handover.dart').readAsStringSync(),
    );
    final at = handover.indexOf('bool appIsResumed() {');
    expect(at, isNonNegative);
    final body = handover.substring(at, handover.indexOf('\n}\n', at));
    expect(
      body.replaceAll(RegExp(r'\s+'), ' '),
      'bool appIsResumed() { try { return '
      'WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed; '
      '} on Object { return false; }',
      reason: 'the foreground claim is `lifecycleState == resumed` and a '
          '`false` when there is no binding: a null check, a second state or '
          'a `true` in the catch makes it the fail-open read it exists to '
          'replace',
    );
  });

  test("the circle service's claim is the strict read, or a constant no", () {
    final unit = parseString(
      content: File(
        'lib/src/services/nostr_circle_service.dart',
      ).readAsStringSync(),
      throwIfDiagnostics: false,
    ).unit;
    final given = <String>[];
    final assigned = <String>[];
    String? field;
    String? never;
    unit.accept(
      _AppInFrontCollector(
        onInitializer: given.add,
        onAssignment: assigned.add,
        onField: (f) => field = f,
        onNever: (n) => never = n,
      ),
    );
    expect(
      given,
      ['appIsResumed', 'appInFront ?? _neverInFront'],
      reason: 'the main constructor hands the driver the strict read and the '
          "background isolate's constructor a constant no: anything else is a "
          'claim this file has not seen the source of',
    );
    expect(assigned, isEmpty);
    expect(field, 'final bool Function() _appInFront;');
    expect(never, 'static bool _neverInFront() => false;');
    final givenInLib = <String, List<String>>{};
    for (final file in _libFiles()) {
      final args = _namedArgumentsIn(file.readAsStringSync(), 'appInFront');
      if (args.isNotEmpty) givenInLib[file.path] = args;
    }
    expect(
      givenInLib,
      isEmpty,
      reason: "the background isolate's `appInFront` is a test seam: given "
          'anything in lib/, that isolate would claim the foreground',
    );
    final returns = <String>[];
    unit.accept(_ReturnCollector('_foreground', returns.add));
    expect(
      returns,
      ['false', '_appInFront()'],
      reason: 'a change is driven in the foreground only on the strict read, '
          'taken again after the settle it waits on',
    );
  });

  test('a started session is claimed for by its own start and by the heal, '
      'and by nothing else', () {
    final callers = <String, List<String>>{};
    for (final file in _libFiles()) {
      final calls = _claimCallsIn(file.readAsStringSync());
      if (calls.isNotEmpty) {
        callers[file.path.replaceAll(r'\', '/')] = calls;
      }
    }
    expect(
      callers,
      {
        'lib/src/services/live_sync_resubscriber.dart': [
          '_engine.claimForeground()',
        ],
        'lib/src/services/nostr_subscription_service.dart': [
          // The start's own claim, made once it holds the engine.
          'claimForeground()',
          // The one call that reaches the engine, fed by the strict read.
          'engine.claimForeground(foreground: appIsResumed())',
          // The settle a user's change waits on (`settleForegroundClaim`).
          'claimForeground()',
        ],
      },
      reason: 'the foreground claim for a session that is only started is '
          'made by the service itself once its start holds the engine, by '
          'the settle a change the user asked for waits on, and by '
          '`LiveSyncResubscriber.ensureRunning` — the heal every app resume '
          'runs — through the service, and by nothing else',
    );
    final resubscriber = _code(
      File('lib/src/services/live_sync_resubscriber.dart').readAsStringSync(),
    ).replaceAll(RegExp(r'\s+'), ' ');
    expect(
      resubscriber,
      contains(
        'final outcome = await _ensureRunningLocked(); '
        'completer.complete(outcome); '
        'if (outcome == LiveSyncHealOutcome.running) { '
        'unawaited(_claimForeground()); }',
      ),
      reason: 'the claim is made after the caller has its answer, only for '
          'an engine that is running, and without holding the chain on the '
          "engine's lifecycle lock",
    );
  });
}
