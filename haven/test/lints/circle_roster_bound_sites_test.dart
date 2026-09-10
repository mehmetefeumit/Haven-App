// Static guard for the account roster bound: nothing grows the roster except
// the two gated calls.
//
// `kMaxCirclesPerAccount` is only a bound if every path that can add a circle
// passes through the check. Two operations can: creating a circle and accepting
// an invitation — the same two the Rust core INSERTS a `circles` row from
// (`CircleStorage::save_circle`, reached from `create_circle_with_config`, and
// `record_processed_invitation`'s own transaction). `save_circle`'s three other
// callers — `add_members`, `remove_members`, `update_circle_relays` — each open
// with `if let Some(circle) = get_circle(..)`, so they re-save a row they just
// read and can never mint one. Both growth paths are gated once, inside
// `NostrCircleService`, and the refusal itself is driven as behaviour by
// `test/services/nostr_circle_service_roster_bound_test.dart`.
//
// What a behavioural test cannot see is a THIRD caller appearing: a page or
// isolate that reaches `CircleManagerFfi` directly — which the integration
// tests already do, so the path exists — would grow the roster with the gate
// untouched and every existing test still green. So this file pins the
// inventory of call sites by exact equality; a floor would let a new one land
// silently, which is the whole failure mode.
//
// A new site is not necessarily wrong. It has to be a visible edit here, with
// the question "does this one go through the gate?" answered in review.
@TestOn('vm')
library;

import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:flutter_test/flutter_test.dart';

/// One roster-growing call, named by the file and the member that makes it.
///
/// The enclosing member is part of the identity so that moving a call from the
/// gated method into an ungated one in the SAME file changes the inventory.
typedef GrowthSite = ({String file, String member, String method});

class _GrowthSiteFinder extends RecursiveAstVisitor<void> {
  _GrowthSiteFinder(this.file);
  final String file;
  final List<GrowthSite> sites = [];

  bool _isGrowth(String name) =>
      name == 'createCircle' || name == 'acceptInvitation';

  void _record(String name, AstNode node) =>
      sites.add((file: file, member: _enclosingMember(node), method: name));

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final name = node.methodName.name;
    // A receiver is required: these only grow a roster when invoked on the
    // service or on the FFI manager. A cascade section has no `target` of its
    // own — the receiver is the cascade's — so `isCascaded` is the second half
    // of "has a receiver", not a refinement of it.
    if (_isGrowth(name) && (node.target != null || node.isCascaded)) {
      _record(name, node);
    }
    super.visitMethodInvocation(node);
  }

  // A tear-off never appears as a MethodInvocation, so `Future.wait(ids.map(
  // svc.acceptInvitation))` — the natural shape of a future "accept all" —
  // would otherwise reach the roster with the inventory untouched. Neither
  // visitor can double-count a plain call: `a.acceptInvitation(x)` is one
  // MethodInvocation node holding `a` and the name directly, with no
  // PrefixedIdentifier or PropertyAccess child for the name.
  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    if (_isGrowth(node.identifier.name)) _record(node.identifier.name, node);
    super.visitPrefixedIdentifier(node);
  }

  @override
  void visitPropertyAccess(PropertyAccess node) {
    final name = node.propertyName.name;
    if (_isGrowth(name)) _record(name, node);
    super.visitPropertyAccess(node);
  }
}

/// The nearest enclosing method/function declaration's name, or `<top-level>`.
String _enclosingMember(AstNode node) {
  for (var n = node.parent; n != null; n = n.parent) {
    if (n is MethodDeclaration) return n.name.lexeme;
    if (n is FunctionDeclaration) return n.name.lexeme;
  }
  return '<top-level>';
}

List<GrowthSite> sitesIn(String source, String file) {
  final unit = parseString(content: source, throwIfDiagnostics: false).unit;
  final finder = _GrowthSiteFinder(file);
  unit.accept(finder);
  return finder.sites;
}

/// Which methods consult the roster gate, and which of those give the slot
/// back from a `finally`.
typedef GateUse = ({Set<String> consults, Set<String> releasesInFinally});

class _GateUseFinder extends RecursiveAstVisitor<void> {
  final Set<String> consults = {};
  final Set<String> releasesInFinally = {};
  String? _method;

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    _method = node.name.lexeme;
    super.visitMethodDeclaration(node);
    _method = null;
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final method = _method;
    if (method != null) {
      switch (node.methodName.name) {
        case '_refuseIfRosterFull':
          consults.add(method);
        case '_releaseRosterSlot' when _insideFinally(node):
          releasesInFinally.add(method);
      }
    }
    super.visitMethodInvocation(node);
  }
}

/// Whether [node] sits in the `finally` block of a `try` in the same member.
bool _insideFinally(AstNode node) {
  for (var n = node.parent; n != null; n = n.parent) {
    if (n is MethodDeclaration) return false;
    final parent = n.parent;
    if (parent is TryStatement && parent.finallyBlock == n) return true;
  }
  return false;
}

GateUse gateUseIn(String source) {
  final unit = parseString(content: source, throwIfDiagnostics: false).unit;
  final finder = _GateUseFinder();
  unit.accept(finder);
  return (
    consults: finder.consults,
    releasesInFinally: finder.releasesInFinally,
  );
}

/// Every Dart source under `lib`, minus the generated FRB bindings, which
/// DECLARE both methods and hold no call sites.
///
/// `lib`, not `lib/src`: `lib/main.dart` sits outside `lib/src` and is compiled
/// into the app like anything else, so a scan rooted at `lib/src` would let the
/// one file every build starts from grow the roster unseen.
List<File> _productionSources() {
  final root = Directory('lib');
  if (!root.existsSync()) {
    fail(
      'expected lib/ (cwd=${Directory.current.path}); run this from the '
      'haven package root',
    );
  }
  return root
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .where((f) => !f.path.replaceAll(r'\', '/').contains('lib/src/rust/'))
      .toList();
}

void main() {
  group('finder self-tests', () {
    test('a call through a receiver is recorded with its enclosing member', () {
      expect(
        sitesIn(
          'class S { Future<void> go() async { '
          'await svc.acceptInvitation(id); } }',
          'f.dart',
        ),
        [(file: 'f.dart', member: 'go', method: 'acceptInvitation')],
      );
    });

    test('a cascade section is recorded even though it carries no target', () {
      expect(
        sitesIn(
          'class S { void go() { svc..acceptInvitation(id); } }',
          'f.dart',
        ),
        [(file: 'f.dart', member: 'go', method: 'acceptInvitation')],
      );
    });

    test('a tear-off handed to another call is recorded', () {
      // The shape a bulk "accept all" would take. It never becomes a
      // MethodInvocation, so the invocation visitor alone cannot see it.
      expect(
        sitesIn(
          'class S { void go() { '
          'Future.wait(ids.map(svc.acceptInvitation)); } }',
          'f.dart',
        ),
        [(file: 'f.dart', member: 'go', method: 'acceptInvitation')],
      );
      expect(
        sitesIn(
          'class S { void go() { '
          'ids.map(ref.read(p).createCircle); } }',
          'f.dart',
        ),
        [(file: 'f.dart', member: 'go', method: 'createCircle')],
      );
    });

    test('a plain call is recorded once, not once per visitor', () {
      expect(
        sitesIn(
          'class S { void go() { ref.read(p).createCircle(name: n); } }',
          'f.dart',
        ),
        [(file: 'f.dart', member: 'go', method: 'createCircle')],
      );
    });

    test('an abstract declaration is not a call site', () {
      expect(
        sitesIn(
          'abstract class S { Future<Circle> acceptInvitation(List<int> id); }',
          'f.dart',
        ),
        isEmpty,
      );
    });

    test('a same-named bare function call is not a roster growth', () {
      // `TestCircleFactory.createCircle` builds a fixture; a bare call builds
      // nothing at all. Neither reaches a roster.
      expect(sitesIn('void go() { createCircle(name); }', 'f.dart'), isEmpty);
    });

    test('a mention inside a comment or a string is not a call site', () {
      expect(
        sitesIn(
          '''
void go() {
  // svc.acceptInvitation(id)
  debugPrint('svc.createCircle(x)');
}
''',
          'f.dart',
        ),
        isEmpty,
      );
    });
  });

  group('gate-use self-tests', () {
    test('a release outside the finally does not count as one', () {
      final use = gateUseIn('''
class S {
  Future<void> grow() async {
    await _refuseIfRosterFull();
    try {
      await manager.acceptInvitation(id: x);
      _releaseRosterSlot();
    } on Object catch (_) {}
  }
}
''');
      expect(use.consults, {'grow'});
      expect(
        use.releasesInFinally,
        isEmpty,
        reason: 'a release on the success path alone leaks the slot whenever '
            'the growth throws',
      );
    });

    test('a release in the finally counts', () {
      final use = gateUseIn('''
class S {
  Future<void> grow() async {
    await _refuseIfRosterFull();
    try {
      await manager.acceptInvitation(id: x);
    } finally {
      _releaseRosterSlot();
    }
  }
}
''');
      expect(use.consults, {'grow'});
      expect(use.releasesInFinally, {'grow'});
    });
  });

  group('repository inventory', () {
    late List<GrowthSite> sites;
    late List<String> scannedPaths;

    setUpAll(() {
      final files = _productionSources();
      scannedPaths = [
        for (final f in files) f.path.replaceAll(r'\', '/'),
      ];
      sites = [
        for (final f in files)
          ...sitesIn(f.readAsStringSync(), f.path.replaceAll(r'\', '/')),
      ];
    });

    test('the scan is not vacuous', () {
      expect(
        scannedPaths.length,
        greaterThan(50),
        reason: 'a scan that found almost no sources proves nothing',
      );
      expect(
        scannedPaths,
        contains('lib/main.dart'),
        reason: 'the app entry point is production Dart like any other file; a '
            'scan that skips it leaves the roster reachable from the one place '
            'every build starts',
      );
      expect(sites, isNotEmpty);
    });

    test('every method that consults the gate gives its slot back', () {
      // The reservation in `_refuseIfRosterFull` is what makes the bound hold
      // across two concurrent growths. A method that takes a slot and does not
      // release it in a `finally` leaks it on the throwing path, and the bound
      // then tightens for the rest of the process — a user with eight circles
      // told they hold ten.
      final use = gateUseIn(
        File('lib/src/services/nostr_circle_service.dart').readAsStringSync(),
      );

      expect(
        use.consults,
        {'createCircle', 'acceptInvitation'},
        reason: 'a new consumer of the gate is a new place the slot can leak; '
            'add it here once it releases in a finally',
      );
      expect(
        use.consults.difference(use.releasesInFinally),
        isEmpty,
        reason: 'these methods reserve a roster slot and never give it back',
      );
    });

    test('only the gated service grows the account roster', () {
      expect(sites.toSet(), {
        // The two gated implementations. `_refuseIfRosterFull` runs before
        // each, outside its try, so a refusal stages nothing.
        (
          file: 'lib/src/services/nostr_circle_service.dart',
          member: 'createCircle',
          method: 'createCircle',
        ),
        (
          file: 'lib/src/services/nostr_circle_service.dart',
          member: 'acceptInvitation',
          method: 'acceptInvitation',
        ),
        // The two UI entry points, which reach the roster only THROUGH the
        // gated service above and localize its refusal.
        (
          file: 'lib/src/pages/circles/name_circle_page.dart',
          member: '_createCircle',
          method: 'createCircle',
        ),
        (
          file: 'lib/src/widgets/circles/invitation_card.dart',
          member: '_handleAccept',
          method: 'acceptInvitation',
        ),
      }, reason:
          'a roster-growing call outside this inventory is a path around '
          'kMaxCirclesPerAccount: it would let an account past ten circles, '
          'and from twelve the publish burst defers its tail and a marker '
          'expires at the relay before its replacement is created. If the new '
          'site goes through CircleService it is already gated — add it here. '
          'If it reaches CircleManagerFfi directly, gate it first.');
    });
  });
}
