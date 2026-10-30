// One `ProviderContainer` lives for the process. A provider that reads the
// circle service, the identity, a relay list or a manager handle WHILE IT IS
// BUILT keeps the previous identity's after a logout and a login, unless the
// login rebuilds it: the next identity's inbox REQ was once issued on the
// last one's cached inbox relay list.
//
// `identityScopedProviders` is the set a login and a logout invalidate. What
// they do with it is tested in `identity_provider_test.dart` ("a logout, then
// a login as someone else, in one process"). This file holds the shape those
// tests cannot: that no provider OUTSIDE the set captures an identity-scoped
// value at build. It also pins the premise the mounted shell's
// re-subscriber set rests on, which no provider holds: a login happens only on
// an onboarding page, which `AppRouter` shows in place of `MapShell`, so the
// next identity's engine is never started from the last one's circle set.
//
// Known limits — what this file does NOT catch:
//  * a value captured in a field of a state notifier at some later call
//    rather than at build (the notifiers that hold per-identity state today
//    are in the set by hand);
//  * a capture made outside `lib/src/providers/` — a widget's `State`, a
//    service's constructor argument read once by its caller;
//  * a root reached through an alias or a helper rather than spelt
//    `ref.read(<provider>)`.
@TestOn('vm')
library;

import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:flutter_test/flutter_test.dart';

/// What every identity-scoped value is derived from. A provider in the set
/// is itself a root for whoever reads it.
///
/// Not `identityServiceProvider`: one process-lifetime service, never
/// invalidated, holds whichever identity is signed in, so a capture of it is
/// never the previous identity's.
const _baseRoots = {
  'circleServiceProvider',
  'identityProvider',
  'identityNotifierProvider',
};

/// Captures that are right, each for a stated reason.
const _exempt = <String, String>{
  // Retired by a login's own line, and deliberately kept — wiped and
  // latched — across a logout, so every logged-out read fails closed.
  'circleServiceProvider': 'retired at login by its own invalidation',
};

/// The `ref.read(…)` arguments [build] evaluates itself — not inside a
/// closure it merely creates, which runs at each use.
class _BuildReads extends RecursiveAstVisitor<void> {
  _BuildReads(this.build, {this.refName = 'ref'});

  final AstNode build;

  /// What the build calls its ref: its first parameter, or `ref` in a
  /// notifier.
  final String refName;
  final List<String> reads = [];

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final target = node.target;
    if (target is SimpleIdentifier &&
        target.name == refName &&
        node.methodName.name == 'read' &&
        node.argumentList.arguments.isNotEmpty) {
      var deferred = false;
      for (var n = node.parent; n != null && n != build; n = n.parent) {
        // A closure invoked where it is written runs at build.
        if (n is FunctionExpression &&
            n.parent is! FunctionExpressionInvocation &&
            n.parent?.parent is! FunctionExpressionInvocation) {
          deferred = true;
        }
      }
      if (!deferred) {
        reads.add(node.argumentList.arguments.first.toSource());
      }
    }
    super.visitMethodInvocation(node);
  }

  @override
  void visitComment(Comment node) {}
}

/// The body of each class's `build` method, by class name.
class _NotifierBuilds extends RecursiveAstVisitor<void> {
  final Map<String, FunctionBody> byClass = {};

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    final owner = node.thisOrAncestorOfType<ClassDeclaration>();
    final name = owner == null
        ? null
        : RegExp(r'class\s+(\w+)').firstMatch(owner.toSource())?.group(1);
    if (node.name.lexeme == 'build' && name != null) byClass[name] = node.body;
    super.visitMethodDeclaration(node);
  }
}

/// The sign-in methods every login goes through.
const _logins = {'createIdentity', 'importFromNsec'};

/// How many times [source] calls or tears off one of [_logins] on an
/// instance — not a declaration, a comment, or a type's member of that name
/// (`OnboardingStep.createIdentity`).
int _loginUses(String source) {
  final uses = _LoginUses();
  parseString(content: source, throwIfDiagnostics: false).unit.accept(uses);
  return uses.count;
}

class _LoginUses extends RecursiveAstVisitor<void> {
  int count = 0;

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (!_logins.contains(node.name)) return;
    final parent = node.parent;
    // A bare identifier is an implicit-`this` tear-off (or call target).
    final bare =
        parent is! PrefixedIdentifier &&
        parent is! PropertyAccess &&
        parent is! MethodInvocation &&
        parent is! Label;
    if (bare ||
        (parent is MethodInvocation && parent.methodName == node) ||
        (parent is PropertyAccess && parent.propertyName == node) ||
        (parent is PrefixedIdentifier &&
            parent.identifier == node &&
            !parent.prefix.name.startsWith(RegExp('[A-Z]')))) {
      count++;
    }
  }

  @override
  void visitComment(Comment node) {}
}

/// Counts the instance creations and constructor tear-offs of [screens].
class _ScreenBuilds extends RecursiveAstVisitor<void> {
  _ScreenBuilds(this.screens);

  final Set<String> screens;
  int count = 0;

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    if (screens.contains(node.constructorName.type.name.lexeme)) count++;
    super.visitInstanceCreationExpression(node);
  }

  @override
  void visitConstructorReference(ConstructorReference node) {
    if (screens.contains(node.constructorName.type.name.lexeme)) count++;
    super.visitConstructorReference(node);
  }

  @override
  void visitComment(Comment node) {}
}

/// Every provider declared in [source], with what it `ref.read`s at build.
Map<String, List<String>> _providersIn(String source) {
  final unit = parseString(content: source, throwIfDiagnostics: false).unit;
  final builds = _NotifierBuilds();
  unit.accept(builds);
  // `Provider(_helper)`: a build that is a top-level function of the file.
  final functions = {
    for (final f in unit.declarations.whereType<FunctionDeclaration>())
      f.name.lexeme: f.functionExpression,
  };
  final found = <String, List<String>>{};
  for (final declaration
      in unit.declarations.whereType<TopLevelVariableDeclaration>()) {
    for (final variable in declaration.variables.variables) {
      final init = variable.initializer;
      if (init == null || !init.toSource().contains('Provider')) continue;
      final arguments = switch (init) {
        MethodInvocation() => init.argumentList.arguments,
        InstanceCreationExpression() => init.argumentList.arguments,
        _ => const <Expression>[],
      };
      AstNode? build;
      var refName = 'ref';
      for (final argument in arguments) {
        final function = argument is FunctionExpression
            ? argument
            : argument is SimpleIdentifier
            ? functions[argument.name]
            : null;
        if (function != null) {
          build = function.body;
          final parameters =
              function.parameters?.parameters ?? const <FormalParameter>[];
          if (parameters.isNotEmpty) {
            final named = parameters.first.name;
            if (named != null) refName = named.lexeme;
          }
        }
        // `NotifierProvider(Controller.new)`: the notifier's own `build`.
        final notifier = RegExp(r'^(\w+)\.new$').firstMatch(
          argument.toSource(),
        );
        if (notifier != null) build = builds.byClass[notifier.group(1)];
      }
      // A provider this cannot find a build for still exists; it has no
      // build-time read this file could see.
      final reads = _BuildReads(build ?? init, refName: refName);
      build?.accept(reads);
      found[variable.name.lexeme] = reads.reads;
    }
  }
  return found;
}

/// The providers of [providers] that capture one of [roots] at build and are
/// not in [scoped] — as `<provider> reads <root>`.
List<String> _capturing(
  Map<String, List<String>> providers, {
  required Set<String> scoped,
  required Set<String> roots,
}) => [
  for (final MapEntry(key: provider, value: reads) in providers.entries)
    if (!scoped.contains(provider) && !_exempt.containsKey(provider))
      for (final read in reads)
        // `identityProvider.future`, `identityNotifierProvider.notifier`, a
        // family's `fooProvider(arg)`.
        if (roots.contains(RegExp(r'^\w+').firstMatch(read)?.group(0)))
          '$provider reads $read',
];

void main() {
  group('the checker sees what it must', () {
    const roots = {'circleServiceProvider', 'scopedProvider'};

    test('a read at build is found, with or without a selector', () {
      expect(
        _capturing(
          _providersIn(
            'final a = Provider((ref) => A(ref.read(circleServiceProvider))); '
            'final b = FutureProvider((ref) async { '
            'final s = await ref.read(scopedProvider.future); return s; });',
          ),
          scoped: const {},
          roots: roots,
        ),
        ['a reads circleServiceProvider', 'b reads scopedProvider.future'],
      );
    });

    test('a family read, a closure called at once, a helper build and a ref '
        'by another name are all captures', () {
      expect(
        _capturing(
          _providersIn(
            'final a = Provider((ref) => A(ref.read(scopedProvider(7)))); '
            'final b = Provider((ref) => (() => ref.read(scopedProvider))()); '
            'final c = Provider(_c); '
            'A _c(Ref ref) => A(ref.read(circleServiceProvider)); '
            'final d = Provider((r) => A(r.read(circleServiceProvider)));',
          ),
          scoped: const {},
          roots: roots,
        ),
        [
          'a reads scopedProvider(7)',
          'b reads scopedProvider',
          'c reads circleServiceProvider',
          'd reads circleServiceProvider',
        ],
      );
    });

    test('a read inside a closure the build only creates is not a capture',
        () {
      expect(
        _capturing(
          _providersIn(
            'final a = Provider((ref) => '
            'A(circle: () => ref.read(circleServiceProvider)));',
          ),
          scoped: const {},
          roots: roots,
        ),
        isEmpty,
      );
    });

    test('a watch follows, and a provider in the set may capture', () {
      expect(
        _capturing(
          _providersIn(
            'final a = Provider((ref) => A(ref.watch(circleServiceProvider))); '
            'final b = Provider((ref) => A(ref.read(circleServiceProvider)));',
          ),
          scoped: const {'b'},
          roots: roots,
        ),
        isEmpty,
      );
    });

    test('a login is seen called or torn off, and not declared, in a '
        'comment or as an enum value', () {
      expect(
        _loginUses('''
/// Calls [createIdentity].
class A {
  Future<void> createIdentity() async {}
  void g() {
    final own = createIdentity;
    own();
  }
}
enum Step { createIdentity }
void f(A a, String n) {
  a.createIdentity();
  final login = a.importFromNsec;
  login(n);
  g().createIdentity;
  Step.createIdentity;
  h(createIdentity: true);
}
'''),
        4,
      );
    });

    test("a notifier's build is read through its class", () {
      expect(
        _capturing(
          _providersIn(
            'class C extends Notifier<int> { @override int build() { '
            'ref.read(circleServiceProvider); return 0; } } '
            'final c = NotifierProvider<C, int>(C.new);',
          ),
          scoped: const {},
          roots: roots,
        ),
        ['c reads circleServiceProvider'],
      );
    });
  });

  group('lib/src/providers', () {
    late Map<String, List<String>> providers;
    late Set<String> scoped;

    setUpAll(() {
      providers = {
        for (final file
            in Directory('lib/src/providers')
                .listSync()
                .whereType<File>()
                .where((f) => f.path.endsWith('.dart')))
          ..._providersIn(file.readAsStringSync()),
      };
      final scope = File(
        'lib/src/providers/identity_scope.dart',
      ).readAsStringSync();
      final from = scope.indexOf('identityScopedProviders = [');
      scoped = RegExp(r'^\s+(\w+Provider),$', multiLine: true)
          .allMatches(scope.substring(from, scope.indexOf('];', from)))
          .map((m) => m.group(1)!)
          .toSet();
    });

    test('the set names providers that exist, once each', () {
      expect(scoped, hasLength(greaterThan(20)), reason: 'anti-vacuity');
      expect(
        scoped.difference(providers.keys.toSet()),
        isEmpty,
        reason: 'a name in the set is not a provider this file can see',
      );
      expect(scoped, isNot(contains('circleServiceProvider')));
    });

    test('no provider outside the set captures an identity-scoped value at '
        'build', () {
      expect(
        _capturing(
          providers,
          scoped: scoped,
          roots: {..._baseRoots, ...scoped},
        ),
        isEmpty,
        reason: "each of these goes on holding the previous identity's value "
            'after a logout and a login: add it to `identityScopedProviders`, '
            'or read the value at each use',
      );
    });

    test('the router and the engine factory read at each use', () {
      expect(providers['liveEventRouterProvider'], isEmpty);
      expect(
        providers['subscriptionServiceProvider'],
        ['liveEventRouterProvider'],
      );
    });

    test('the onboarding screens are built only on the onboarding pages', () {
      // A login reached from a screen pushed over a mounted MapShell would
      // leave the call sites above where they are and the premise broken.
      const screens = {'CreateIdentityScreen', 'ImportNsecScreen'};
      final built = <String>[];
      for (final file
          in Directory('lib')
              .listSync(recursive: true)
              .whereType<File>()
              .where(
                (f) =>
                    f.path.endsWith('.dart') &&
                    !f.path.startsWith('lib/src/rust/'),
              )) {
        final finder = _ScreenBuilds(screens);
        parseString(
          content: file.readAsStringSync(),
          throwIfDiagnostics: false,
        ).unit.accept(finder);
        for (var i = 0; i < finder.count; i++) {
          built.add(file.path);
        }
      }
      expect(built, isNotEmpty, reason: 'anti-vacuity');
      expect(
        built.where((p) => !p.startsWith('lib/src/pages/onboarding/')),
        isEmpty,
        reason: 'an onboarding screen is built outside onboarding',
      );
    });

    test('only an onboarding page signs in', () {
      final uses = {
        for (final file
            in Directory('lib')
                .listSync(recursive: true)
                .whereType<File>()
                .where(
                  (f) =>
                      f.path.endsWith('.dart') &&
                      !f.path.startsWith('lib/src/rust/'),
                ))
          file.path: _loginUses(file.readAsStringSync()),
      }..removeWhere((_, count) => count == 0);
      expect(
        uses.keys.where((path) => path.startsWith('lib/src/pages/onboarding/')),
        hasLength(2),
        reason: 'anti-vacuity: both screens',
      );
      expect(
        {
          for (final MapEntry(key: path, value: count) in uses.entries)
            if (!path.startsWith('lib/src/pages/onboarding/')) path: count,
        },
        {
          // The notifier hands each to the service, and the service to Rust.
          'lib/src/providers/identity_provider.dart': 2,
          'lib/src/services/nostr_identity_service.dart': 2,
        },
        reason: 'a login reached from outside onboarding can run under a '
            'mounted MapShell, whose engine restarts would carry the last '
            "identity's circle set into the next one's session",
      );
    });

    test('a login invalidates the set beside the circle service, and a '
        'logout invalidates it and keeps the circle service', () {
      final source = File(
        'lib/src/providers/identity_provider.dart',
      ).readAsStringSync().replaceAll(RegExp(r'\s+'), ' ');
      expect(
        'ref.invalidate(circleServiceProvider); invalidateIdentityScope(ref);'
            .allMatches(source),
        hasLength(2),
        reason: 'createIdentity and importFromNsec',
      );
      expect(
        'invalidateIdentityScope(ref);'.allMatches(source),
        hasLength(3),
        reason: 'and the end of deleteIdentity',
      );
      expect(
        'ref.invalidate(circleServiceProvider)'.allMatches(source),
        hasLength(2),
        reason: 'a logout must leave the wiped, latched circle service in '
            'place',
      );
    });
  });
}
