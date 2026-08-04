/// Pins that `MapShell` suspends the location-access watchdog when the app is
/// paused, and lets it back on resume.
///
/// ## Why this matters beyond battery
///
/// The watchdog exists to keep a USER-VISIBLE banner honest, and nobody is
/// looking while the app is backgrounded — but leaving it running is not
/// merely wasteful. Its recovery edge calls
/// `ref.invalidate(locationStreamProvider)`, and with background sharing OFF
/// that provider's rebuild runs `GeolocatorLocationService.clearCachedPosition()`.
/// So a blocked → available flip that happens while backgrounded tears down the
/// one geolocator stream the process has AND discards the cached fix the
/// publish path serves from, for a banner nobody can see. On Android it would
/// also keep firing platform calls for as long as the app is away.
///
/// `_onPaused` already cancels six timers; this one was simply never added to
/// the list.
///
/// ## Why a source guard
///
/// `_MapShellState`, `_onPaused` and the watchdog handle are all private, and
/// per CLAUDE.md `MapShell` cannot be pumped in `flutter test` — `MapPage`
/// reaches the Rust bridge in `initState`. The behaviour of `suspend()` itself
/// is covered at the unit level in `location_access_provider_test.dart`
/// ("suspend() stops probing until something re-arms it"); what only the shell
/// can answer is whether the pause path calls it, and whether the resume path
/// undoes it. The analysis is AST-based and scoped to the two method bodies, so
/// it cannot be satisfied by a comment or by an unrelated call elsewhere in a
/// 1500-line file — the detector is self-tested against both of those below.
@TestOn('vm')
library;

import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:flutter_test/flutter_test.dart';

/// Whether [method] on [className] invokes `<provider>.notifier`'s [call].
///
/// Structural: it looks for a `<call>()` invocation whose receiver chain
/// mentions [provider], so neither a same-named call on something else nor a
/// mention in prose satisfies it.
bool methodCallsNotifierMember(
  String source, {
  required String className,
  required String method,
  required String provider,
  required String call,
}) {
  final unit = parseString(content: source, throwIfDiagnostics: false).unit;
  final visitor = _MethodBodyVisitor(className: className, method: method);
  unit.accept(visitor);
  final body = visitor.body;
  if (body == null) return false;
  final probe = _NotifierCallVisitor(provider: provider, call: call);
  body.accept(probe);
  return probe.found;
}

class _MethodBodyVisitor extends RecursiveAstVisitor<void> {
  _MethodBodyVisitor({required this.className, required this.method});

  final String className;
  final String method;
  AstNode? body;

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    if (node.name.lexeme != className) return;
    for (final member in node.members) {
      if (member is MethodDeclaration && member.name.lexeme == method) {
        body = member.body;
      }
    }
  }
}

class _NotifierCallVisitor extends RecursiveAstVisitor<void> {
  _NotifierCallVisitor({required this.provider, required this.call});

  final String provider;
  final String call;
  bool found = false;

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (node.methodName.name == call) {
      final target = node.target;
      if (target != null && target.toSource().contains(provider)) found = true;
    }
    super.visitMethodInvocation(node);
  }

  // Doc-comment references parse to real identifiers; a guard that walked into
  // them could be satisfied by the comment describing the call.
  @override
  void visitComment(Comment node) {}
}

void main() {
  group('detector self-tests', () {
    const good = '''
class _MapShellState {
  Future<void> _onPaused() async {
    ref.read(locationAccessProvider.notifier).suspend();
  }
}
''';

    test('finds the call in the named method', () {
      expect(
        methodCallsNotifierMember(
          good,
          className: '_MapShellState',
          method: '_onPaused',
          provider: 'locationAccessProvider',
          call: 'suspend',
        ),
        isTrue,
      );
    });

    test('does not accept the call from a DIFFERENT method', () {
      const elsewhere = '''
class _MapShellState {
  Future<void> _onPaused() async {}
  void dispose() {
    ref.read(locationAccessProvider.notifier).suspend();
  }
}
''';
      expect(
        methodCallsNotifierMember(
          elsewhere,
          className: '_MapShellState',
          method: '_onPaused',
          provider: 'locationAccessProvider',
          call: 'suspend',
        ),
        isFalse,
        reason: 'suspending on dispose instead of on pause would leave the '
            'whole backgrounded window uncovered',
      );
    });

    test('does not accept a same-named call on a different provider', () {
      const wrongProvider = '''
class _MapShellState {
  Future<void> _onPaused() async {
    ref.read(someOtherProvider.notifier).suspend();
  }
}
''';
      expect(
        methodCallsNotifierMember(
          wrongProvider,
          className: '_MapShellState',
          method: '_onPaused',
          provider: 'locationAccessProvider',
          call: 'suspend',
        ),
        isFalse,
      );
    });

    test('is not satisfied by a comment describing the call', () {
      const prose = '''
class _MapShellState {
  /// Calls [locationAccessProvider].notifier.suspend() on pause.
  Future<void> _onPaused() async {
    // ref.read(locationAccessProvider.notifier).suspend();
  }
}
''';
      expect(
        methodCallsNotifierMember(
          prose,
          className: '_MapShellState',
          method: '_onPaused',
          provider: 'locationAccessProvider',
          call: 'suspend',
        ),
        isFalse,
        reason: 'a guard that a comment can satisfy is not a guard',
      );
    });
  });

  group('the real source', () {
    late String source;

    setUpAll(() {
      final file = File('lib/src/pages/map_shell.dart');
      expect(
        file.existsSync(),
        isTrue,
        reason: 'map_shell.dart moved — update this guard, do not delete it',
      );
      source = file.readAsStringSync();
    });

    test('_onPaused suspends the location-access watchdog', () {
      expect(
        methodCallsNotifierMember(
          source,
          className: '_MapShellState',
          method: '_onPaused',
          provider: 'locationAccessProvider',
          call: 'suspend',
        ),
        isTrue,
        reason: 'the watchdog would keep probing for the whole backgrounded '
            'window, and a recovery edge there invalidates the position '
            'stream — which also wipes the publish path\'s cached fix when '
            'background sharing is off',
      );
    });

    test('_onResumed re-decides it from a fresh platform read', () {
      // The other half: suspend() must not be a one-way door. `refresh()` is
      // what re-arms, and it deliberately runs BEFORE the resume debounce,
      // since leaving to change a system toggle and coming straight back lands
      // well inside that window.
      expect(
        methodCallsNotifierMember(
          source,
          className: '_MapShellState',
          method: '_onResumed',
          provider: 'locationAccessProvider',
          call: 'refresh',
        ),
        isTrue,
        reason: 'without this the banner stays frozen at whatever it said when '
            'the app was backgrounded, for the rest of the session',
      );
      final resumeAt = source.indexOf('Future<void> _onResumed() async {');
      expect(resumeAt, isNonNegative);
      final debounceAt = source.indexOf('_resumeStopwatch.isRunning', resumeAt);
      final refreshAt = source.indexOf(
        'locationAccessProvider.notifier',
        resumeAt,
      );
      expect(refreshAt, isNonNegative);
      expect(
        refreshAt,
        lessThan(debounceAt),
        reason: 'gating the re-check behind the 30 s resume debounce would '
            'leave the banner stale in exactly the case it exists for — the '
            'user who just left to flip a system toggle and came straight '
            'back',
      );
    });
  });
}
