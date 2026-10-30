// Static guard for Security Rule 13's newest edge: which publish LADDER each
// call site takes.
//
// `RelayService.publishEvent` (three attempts, ~49 s worst case) is the one
// signed-event publish left in Dart; the one-shot `publishLocationEvent` is
// retired — every location is sealed and sent through the fanout driver —
// and must not come back: a commit on a one-shot ladder would be neither
// confirmed nor rolled back after a single missed ack.
//
// So this file pins the inventory of `publishEvent` callers, and the absence
// of any `publishLocationEvent` caller, by exact equality — a floor would let
// a new caller appear silently, which is the whole failure mode. The
// behavioural halves live where they can be executed:
// `test/services/location_sharing_service_test.dart` (the foreground publish
// and its clock-rejection contract) and
// `test/services/background_location_task_publish_cycle_test.dart` (the
// foreground service's two planes, driven through `onRepeatEvent`). Welcomes,
// KeyPackages, relay lists and profiles have no Dart behavioural equivalent —
// they reach the relay through their own `RelayService` methods or their own
// FFI — so for those the inventory below IS the guarantee.
//
// The Rust side owns the complementary check (no Dart file both publishes a
// location and resolves a staged commit) in
// `haven-core/tests/security_rule_gates.rs`.
@TestOn('vm')
library;

import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:flutter_test/flutter_test.dart';

/// One publish call, named by the file and the member that makes it.
///
/// The enclosing member is part of the identity on purpose: moving a call from
/// the deferral branch into the send branch of the SAME file would otherwise
/// leave the inventory unchanged.
typedef PublishSite = ({String file, String member, String method});

class _PublishSiteFinder extends RecursiveAstVisitor<void> {
  _PublishSiteFinder(this.file);
  final String file;
  final List<PublishSite> sites = [];

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final name = node.methodName.name;
    // A receiver is required: a bare same-named top-level function would not
    // be a relay publish at all.
    if ((name == 'publishEvent' || name == 'publishLocationEvent') &&
        node.target != null) {
      sites.add((file: file, member: _enclosingMember(node), method: name));
    }
    super.visitMethodInvocation(node);
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

List<PublishSite> sitesIn(String source, String file) {
  final unit = parseString(content: source, throwIfDiagnostics: false).unit;
  final finder = _PublishSiteFinder(file);
  unit.accept(finder);
  return finder.sites;
}

/// Every Dart source under `lib/src`, minus the generated FRB bindings, which
/// DECLARE both methods and hold no call sites.
List<File> _productionSources() {
  final root = Directory('lib/src');
  if (!root.existsSync()) {
    fail(
      'expected lib/src (cwd=${Directory.current.path}); run this from the '
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
          'await _relay.publishLocationEvent(eventJson: e, relays: r); } }',
          'f.dart',
        ),
        [(file: 'f.dart', member: 'go', method: 'publishLocationEvent')],
      );
    });

    test('a top-level function body is attributed, not dropped', () {
      expect(
        sitesIn(
          'Future<void> go() async { await relay.publishEvent(eventJson: e); }',
          'f.dart',
        ),
        [(file: 'f.dart', member: 'go', method: 'publishEvent')],
      );
    });

    test('an abstract declaration is not a call site', () {
      expect(
        sitesIn(
          'abstract class S { Future<PublishResult> publishLocationEvent({'
          ' required String eventJson, required List<String> relays}); }',
          'f.dart',
        ),
        isEmpty,
      );
    });

    test('a same-named bare function call is not a relay publish', () {
      expect(
        sitesIn('void go() { publishLocationEvent(e, r); }', 'f.dart'),
        isEmpty,
      );
    });

    test('a mention inside a comment or a string is not a call site', () {
      expect(
        sitesIn(
          '''
void go() {
  // relay.publishLocationEvent(x)
  debugPrint('relay.publishLocationEvent(x)');
}
''',
          'f.dart',
        ),
        isEmpty,
      );
    });
  });

  group('repository inventory', () {
    late List<PublishSite> sites;
    late int scannedFiles;

    setUpAll(() {
      final files = _productionSources();
      scannedFiles = files.length;
      sites = [
        for (final f in files)
          ...sitesIn(f.readAsStringSync(), f.path.replaceAll(r'\', '/')),
      ];
    });

    test('the scan is not vacuous', () {
      expect(
        scannedFiles,
        greaterThan(50),
        reason: 'a scan that found almost no sources proves nothing',
      );
      expect(sites, isNotEmpty);
    });

    test('nothing takes the one-shot ladder', () {
      // Every plane seals through the fanout driver and sends the sealed
      // record once (`publishLocation`); the forwarder went with the method.
      expect(
        sites.where((s) => s.method == 'publishLocationEvent').toSet(),
        isEmpty,
        reason:
            'the one-shot ladder gives up after a single 5 s per-relay ack '
            'window. That is only safe for an event a later send supersedes — '
            'a kind-445 LOCATION. Anything whose outcome resolves a staged '
            'PendingStateRef, and anything nothing re-sends (a welcome, a '
            'KeyPackage, a relay list, a profile), must keep publishEvent '
            '(Security Rule 13).',
      );
    });

    test('the plain publishers keep the ladder', () {
      expect(sites.where((s) => s.method == 'publishEvent').toSet(), {
        (
          file: 'lib/src/services/nostr_relay_service.dart',
          member: 'publishEvent',
          method: 'publishEvent',
        ),
        (
          file: 'lib/src/providers/relay_preferences_provider.dart',
          member: '_scrubDroppedRelay',
          method: 'publishEvent',
        ),
      }, reason: 'a ladder site that disappeared either lost its retries or '
          'moved to the one-shot path; both are Rule-13 regressions. (The '
          'legacy leave, the deferred-send ladders, their proposals and the '
          'founding Welcome send are gone: the fanout driver records and '
          'drives each in Rust.)');
    });
  });

  group("the retry ladder's error contract", () {
    // What each failure becomes is driven on the host
    // (`test/services/nostr_relay_service_publish_event_test.dart`); this pins
    // the shape that keeps it typed and surfaces no raw error.
    late Map<String, String> bodies;

    setUpAll(() {
      final unit = parseString(
        content: File(
          'lib/src/services/nostr_relay_service.dart',
        ).readAsStringSync(),
        throwIfDiagnostics: false,
      ).unit;
      final finder = _MethodSourceFinder({'publishEvent'});
      unit.accept(finder);
      bodies = finder.sources;
    });

    test('the publish was found (anti-vacuity)', () {
      expect(bodies.keys, contains('publishEvent'));
    });

    test('a device-clock rejection stays typed', () {
      for (final method in ['publishEvent']) {
        expect(
          bodies[method],
          contains('on PublishFailureFfi catch (failure)'),
          reason:
              '$method must classify the FFI error by its typed fields, '
              'never by its text',
        );
        expect(
          bodies[method],
          contains('throw RelayClockRejectionException(verdict)'),
          reason:
              '$method must rethrow the one publish failure a user can act '
              'on as its own type; flattening it is what made a fast clock a '
              'silent outage',
        );
      }
    });

    test('the raw error is not surfaced (Security Rule 8)', () {
      for (final method in ['publishEvent']) {
        for (final leak in [r'$e', 'e.toString()', 'e.message']) {
          expect(
            bodies[method],
            isNot(contains(leak)),
            reason:
                '$method must log the runtime TYPE only — an FFI error can '
                'carry an MLS group id or remote-authored relay prose',
          );
        }
      }
    });
  });
}

/// Collects the source of each named method declaration in one unit.
class _MethodSourceFinder extends RecursiveAstVisitor<void> {
  _MethodSourceFinder(this._names);
  final Set<String> _names;
  final Map<String, String> sources = {};

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    if (_names.contains(node.name.lexeme)) {
      sources[node.name.lexeme] = node.toSource();
    }
    super.visitMethodDeclaration(node);
  }
}
