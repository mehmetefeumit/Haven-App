// Static guard for Security Rule 13's newest edge: which publish LADDER each
// call site takes.
//
// `RelayService` now offers two publishes with the same signature —
// `publishEvent` (three attempts, ~49 s worst case) and `publishLocationEvent`
// (one connect, one 5 s per-relay ack window, no retry). Nothing in the type
// system tells them apart: both take an event JSON and a relay list and both
// return a `PublishResult`. The difference is what a miss costs. A location
// nobody acked is superseded by the next tick within
// `kLocationPublishMaxInterval`; a COMMIT is not superseded by anything, and
// one that is neither confirmed nor rolled back leaves the group at an epoch
// its peers never received.
//
// So "only a location may take the one-shot ladder" is a property of the CALL
// SITES, and this file pins the inventory of both ladders by exact equality —
// a floor would let a new caller appear silently, which is the whole failure
// mode. The behavioural halves live where they can be executed:
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

    test('only the two location publishes take the one-shot ladder', () {
      expect(
        sites.where((s) => s.method == 'publishLocationEvent').toSet(),
        {
          // The forwarder: the interface implementation that hands the call to
          // the FFI. Not a decision, but it must exist for the two below.
          (
            file: 'lib/src/services/nostr_relay_service.dart',
            member: 'publishLocationEvent',
            method: 'publishLocationEvent',
          ),
          (
            file: 'lib/src/services/location_sharing_service.dart',
            member: 'publishLocation',
            method: 'publishLocationEvent',
          ),
          (
            file: 'lib/src/services/background_location_task.dart',
            member: '_publishCycle',
            method: 'publishLocationEvent',
          ),
        },
        reason:
            'the one-shot ladder gives up after a single 5 s per-relay ack '
            'window. That is only safe for an event a later send supersedes — '
            'a kind-445 LOCATION. Anything whose outcome resolves a staged '
            'PendingStateRef, and anything nothing re-sends (a welcome, a '
            'KeyPackage, a relay list, a profile), must keep publishEvent '
            '(Security Rule 13).',
      );
    });

    test('the commit, welcome and proposal publishers keep the ladder', () {
      expect(sites.where((s) => s.method == 'publishEvent').toSet(), {
        (
          file: 'lib/src/services/nostr_relay_service.dart',
          member: 'publishWelcome',
          method: 'publishEvent',
        ),
        (
          file: 'lib/src/services/nostr_relay_service.dart',
          member: 'publishEvent',
          method: 'publishEvent',
        ),
        (
          file: 'lib/src/services/nostr_circle_service.dart',
          member: '_publishEvolutionEvent',
          method: 'publishEvent',
        ),
        (
          file: 'lib/src/services/location_sharing_service.dart',
          member: '_publishDeferredProposals',
          method: 'publishEvent',
        ),
        (
          file: 'lib/src/services/location_auto_commit.dart',
          member: '_publishAndConfirmAutoCommit',
          method: 'publishEvent',
        ),
        (
          file: 'lib/src/services/background_deferred_send.dart',
          member: 'publishStagedCommits',
          method: 'publishEvent',
        ),
        (
          file: 'lib/src/services/background_deferred_send.dart',
          member: 'publishDeferredProposals',
          method: 'publishEvent',
        ),
        (
          file: 'lib/src/providers/relay_preferences_provider.dart',
          member: '_scrubDroppedRelay',
          method: 'publishEvent',
        ),
      }, reason: 'a ladder site that disappeared either lost its retries or '
          'moved to the one-shot path; both are Rule-13 regressions');
    });
  });

  group('the one-shot ladder keeps the retry ladder’s error contract', () {
    // `NostrRelayService` reaches the core through `RelayManagerFfi`, which
    // cannot be constructed without the native library, so neither publish can
    // be driven on the host — `publishEvent`'s own mapping has always been
    // pinned by the Rust side plus `clock_skew_detector_test.dart`. What is
    // NEW here is a second method that could quietly differ: written with a
    // plain catch, a fast device clock would become the generic failure on the
    // location plane alone — the one plane the user watches — and the
    // actionable "your clock is wrong" would never be shown.
    //
    // `location_sharing_service_test.dart` proves the far end (a typed
    // rejection reaches the detector); this proves the near end raises the
    // typed rejection at all.
    late Map<String, String> bodies;

    setUpAll(() {
      final unit = parseString(
        content: File(
          'lib/src/services/nostr_relay_service.dart',
        ).readAsStringSync(),
        throwIfDiagnostics: false,
      ).unit;
      final finder = _MethodSourceFinder({
        'publishEvent',
        'publishLocationEvent',
      });
      unit.accept(finder);
      bodies = finder.sources;
    });

    test('both publishes were found (anti-vacuity)', () {
      expect(
        bodies.keys,
        containsAll(['publishEvent', 'publishLocationEvent']),
      );
    });

    test('a device-clock rejection stays typed on both ladders', () {
      for (final method in ['publishEvent', 'publishLocationEvent']) {
        expect(
          bodies[method],
          contains('_deviceClockComplaintToken(e)'),
          reason:
              '$method must classify the FFI error by the Haven-authored '
              'token, not by relay prose',
        );
        expect(
          bodies[method],
          contains('throw RelayClockRejectionException(complaintToken)'),
          reason:
              '$method must rethrow the one publish failure a user can act '
              'on as its own type; flattening it is what made a fast clock a '
              'silent outage',
        );
      }
    });

    test('neither ladder surfaces the raw error (Security Rule 8)', () {
      for (final method in ['publishEvent', 'publishLocationEvent']) {
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
