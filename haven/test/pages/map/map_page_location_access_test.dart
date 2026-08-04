/// Tests for the map page's response to a lost location access — in
/// particular the stale-position decision.
///
/// ## Why pure statics plus a wiring guard, rather than a widget test
///
/// `MapPage` calls `HavenCore.newInstance()` across the Rust FFI in
/// `State.initState`, so pumping it in `flutter test` crashes the runner (the
/// same limitation `map_page_prefetch_test.dart` documents). The overlay and
/// marker decisions are therefore expressed as pure statics on [MapPage] — the
/// pattern `MapShell.shouldKeepRelayConnectedWhilePaused` already established
/// here — which are exhaustively tested below, plus an AST guard proving the
/// page actually calls them. Runtime proof of the composed page is in
/// `integration_test/b6_location_provider_toggle_test.dart`.
@TestOn('vm')
library;

import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/pages/map/map_page.dart';

/// Counts `MapPage.<name>(...)` calls inside class [className].
int countStaticCalls(
  String source, {
  required String className,
  required String method,
}) {
  final unit = parseString(content: source, throwIfDiagnostics: false).unit;
  final visitor = _StaticCallVisitor(className: className, method: method);
  unit.accept(visitor);
  return visitor.count;
}

/// Whether class [className] reads [provider] through `ref.watch`.
bool watchesProvider(
  String source, {
  required String className,
  required String provider,
}) {
  final unit = parseString(content: source, throwIfDiagnostics: false).unit;
  final visitor = _WatchVisitor(className: className, provider: provider);
  unit.accept(visitor);
  return visitor.found;
}

class _StaticCallVisitor extends RecursiveAstVisitor<void> {
  _StaticCallVisitor({required this.className, required this.method});

  final String className;
  final String method;
  int count = 0;

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final target = node.target;
    if (target is SimpleIdentifier &&
        target.name == className &&
        node.methodName.name == method) {
      count++;
    }
    super.visitMethodInvocation(node);
  }
}

class _WatchVisitor extends RecursiveAstVisitor<void> {
  _WatchVisitor({required this.className, required this.provider});

  final String className;
  final String provider;
  bool found = false;

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (node.methodName.name == 'watch') {
      final args = node.argumentList.arguments;
      if (args.isNotEmpty) {
        final first = args.first;
        if (first is SimpleIdentifier && first.name == provider) found = true;
        // `ref.watch(someProvider).isBlocked` parses the same way; the
        // property access is on the invocation, not inside it.
      }
    }
    super.visitMethodInvocation(node);
  }
}

void main() {
  // -------------------------------------------------------------------------
  // The stale-position decision
  // -------------------------------------------------------------------------

  group('MapPage.showOwnLocationMarker (the stale-position decision)', () {
    test('a live fix with access intact is drawn', () {
      expect(
        MapPage.showOwnLocationMarker(hasFix: true, accessBlocked: false),
        isTrue,
      );
    });

    test('a fix held from BEFORE the outage is NOT drawn', () {
      // The decision under review: the marker goes rather than being restyled.
      // Haven never persists an own-location, so a dot under a "location is
      // off" banner asserts the one thing that is no longer true — that this
      // is where the user is now.
      expect(
        MapPage.showOwnLocationMarker(hasFix: true, accessBlocked: true),
        isFalse,
      );
    });

    test('no fix draws nothing, blocked or not', () {
      expect(
        MapPage.showOwnLocationMarker(hasFix: false, accessBlocked: false),
        isFalse,
      );
      expect(
        MapPage.showOwnLocationMarker(hasFix: false, accessBlocked: true),
        isFalse,
      );
    });
  });

  // -------------------------------------------------------------------------
  // The overlays that would otherwise fight the banner
  // -------------------------------------------------------------------------

  group('MapPage.showLoadingScrim', () {
    test('covers the map while the first fix is genuinely in flight', () {
      expect(
        MapPage.showLoadingScrim(
          hasFix: false,
          hasError: false,
          locationDeclined: false,
          accessBlocked: false,
        ),
        isTrue,
      );
    });

    test('blocked access is NOT a loading state', () {
      // Without this, clearing the marker on an access loss would drop the map
      // behind an indefinite "Loading map…" scrim that no fix will ever lift.
      expect(
        MapPage.showLoadingScrim(
          hasFix: false,
          hasError: false,
          locationDeclined: false,
          accessBlocked: true,
        ),
        isFalse,
      );
    });

    test('a resolved fix, an error or a decline all lift it', () {
      expect(
        MapPage.showLoadingScrim(
          hasFix: true,
          hasError: false,
          locationDeclined: false,
          accessBlocked: false,
        ),
        isFalse,
      );
      expect(
        MapPage.showLoadingScrim(
          hasFix: false,
          hasError: true,
          locationDeclined: false,
          accessBlocked: false,
        ),
        isFalse,
      );
      expect(
        MapPage.showLoadingScrim(
          hasFix: false,
          hasError: false,
          locationDeclined: true,
          accessBlocked: false,
        ),
        isFalse,
      );
    });
  });

  group('MapPage.showFullScreenError', () {
    test('still covers the map for a plain error with no fix', () {
      // The pre-existing behaviour, unchanged: the declined-disclosure empty
      // state and a transient GPS failure both still render full-screen.
      expect(
        MapPage.showFullScreenError(
          hasFix: false,
          hasError: true,
          accessBlocked: false,
        ),
        isTrue,
      );
    });

    test('is suppressed while access is blocked', () {
      // The banner names the cause AND the remedy, and leaves the circle
      // members visible while it does. Two overlays saying the same thing,
      // one of which hides information the outage did not take away, is worse
      // than one.
      expect(
        MapPage.showFullScreenError(
          hasFix: false,
          hasError: true,
          accessBlocked: true,
        ),
        isFalse,
      );
    });

    test('never covers a map that still has a fix', () {
      expect(
        MapPage.showFullScreenError(
          hasFix: true,
          hasError: true,
          accessBlocked: false,
        ),
        isFalse,
      );
    });
  });

  // -------------------------------------------------------------------------
  // Wiring: the decisions must be the ones the page actually makes
  // -------------------------------------------------------------------------

  group('detector self-tests', () {
    test('counts a static call on the named class', () {
      const source = '''
class _S {
  Widget build() {
    if (MapPage.showOwnLocationMarker(hasFix: true, accessBlocked: false)) {
      return const Marker();
    }
    return const SizedBox();
  }
}
''';
      expect(
        countStaticCalls(
          source,
          className: 'MapPage',
          method: 'showOwnLocationMarker',
        ),
        1,
      );
      expect(
        countStaticCalls(source, className: 'MapPage', method: 'somethingElse'),
        0,
      );
    });

    test('does not mistake a hand-rolled condition for the helper', () {
      const source = '''
class _S {
  Widget build() {
    if (_obfuscatedLocation != null) return const Marker();
    return const SizedBox();
  }
}
''';
      expect(
        countStaticCalls(
          source,
          className: 'MapPage',
          method: 'showOwnLocationMarker',
        ),
        0,
        reason: 'reverting to the old raw guard must be visible here',
      );
    });

    test('detects a watched provider', () {
      const good = '''
class _S {
  Widget build() {
    final blocked = ref.watch(locationAccessProvider).isBlocked;
    return Text('\$blocked');
  }
}
''';
      expect(
        watchesProvider(
          good,
          className: '_MapPageState',
          provider: 'locationAccessProvider',
        ),
        isTrue,
      );

      const bad = '''
class _S {
  Widget build() => const SizedBox();
}
''';
      expect(
        watchesProvider(
          bad,
          className: '_MapPageState',
          provider: 'locationAccessProvider',
        ),
        isFalse,
      );
    });
  });

  group('the real source', () {
    late String source;

    setUpAll(() {
      final file = File('lib/src/pages/map/map_page.dart');
      expect(
        file.existsSync(),
        isTrue,
        reason: 'map_page.dart moved — update this guard, do not delete it',
      );
      source = file.readAsStringSync();
    });

    test('the user marker is gated on showOwnLocationMarker', () {
      // Otherwise the pure decision above is tested and used nowhere.
      expect(
        countStaticCalls(
          source,
          className: 'MapPage',
          method: 'showOwnLocationMarker',
        ),
        greaterThanOrEqualTo(1),
      );
    });

    test('both overlays are gated on their helpers', () {
      expect(
        countStaticCalls(
          source,
          className: 'MapPage',
          method: 'showLoadingScrim',
        ),
        greaterThanOrEqualTo(1),
      );
      expect(
        countStaticCalls(
          source,
          className: 'MapPage',
          method: 'showFullScreenError',
        ),
        greaterThanOrEqualTo(1),
      );
    });

    test('the page watches the access state itself', () {
      // Keeps `locationAccessProvider` alive from the page as well as the
      // shell's banner, so detection does not depend on one widget staying
      // where it is.
      expect(
        watchesProvider(
          source,
          className: '_MapPageState',
          provider: 'locationAccessProvider',
        ),
        isTrue,
      );
    });
  });
}
