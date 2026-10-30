/// Host-side proof of the E2E lanes' lifecycle helper, and of where the
/// device targets use it.
///
/// The lanes themselves cannot run here (no emulator), so what CAN be shown
/// host-side is: the helper does what it says against a binding in the state
/// a finished test leaves it in, and every live-sync target that pumps the
/// app calls it from the top of `main()` and asserts it at the pump.
///
/// "Every" is enforced, and the partition is TOTAL: each file under
/// `integration_test/` that pumps a widget or launches the app is in exactly
/// one of three tables — it takes the helper, its lane compiles the engine
/// out, or it pumps no shell — each with a reason this file checks. A new
/// target cannot be unclaimed without someone saying why.
///
/// Known limits — what this file does NOT catch:
///  * a shell mounted through a wrapper widget this file does not know by
///    name (`HavenApp`, `AppRouter`, `MapShell`, `runApp(`, `<lib>.main()`
///    are known), declared in `lib/` or in another target;
///  * an exempt target's lane that passes the flag some other way than a
///    `HAVEN_LIVE_SYNC:` line in its workflow;
///  * whether the device is in front: the assertion proves the helper ran.
@TestOn('vm')
library;

import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/services/mls_session_handover.dart';

import '../../integration_test/e2e/_lib/app_lifecycle.dart';

/// Every integration target that pumps the app with a live-sync session a
/// CI lane builds in, and how many times it pumps it.
const _targets = <String, int>{
  'integration_test/app_test.dart': 2,
  'integration_test/e2e/e2e_combined.dart': 2,
  'integration_test/e2e/e2e_profile_sharing.dart': 1,
  'integration_test/b1_fgs_live_foreground_test.dart': 1,
  'integration_test/b9_network_reconnect_test.dart': 1,
  'integration_test/ios_bg_publish_test.dart': 1,
};

/// The targets that mount the app and do NOT take the helper: each runs only
/// in a lane that compiles the engine out, so there is no session to claim
/// for. The workflow and the runner it calls are named so the claim is
/// checked — flip the lane to a live-sync build and its target fails here
/// until it takes the helper.
const _engineCompiledOut = <String, ({String workflow, String runner})>{
  'integration_test/b3_real_gps_test.dart': (
    workflow: 'e2e-real-gps.yml',
    runner: 'run-b3-real-gps.sh',
  ),
  'integration_test/b4_ios_real_gps_test.dart': (
    workflow: 'e2e-ios-real-gps.yml',
    runner: 'run-b4-ios-real-gps.sh',
  ),
  'integration_test/b5_permission_revocation_test.dart': (
    workflow: 'e2e-permission-revocation.yml',
    runner: 'run-b5-permission-revocation.sh',
  ),
  'integration_test/b6_location_provider_toggle_test.dart': (
    workflow: 'e2e-location-provider-toggle.yml',
    runner: 'run-b6-location-provider-toggle.sh',
  ),
  'integration_test/b7_ios_auth_tier_test.dart': (
    workflow: 'e2e-ios-auth-tier.yml',
    runner: 'run-b7-ios-auth-tier.sh',
  ),
};

/// The targets that pump a widget and mount no shell at all: no `MapShell`,
/// so no session. Checked — construct the app in one of these and it fails
/// here until it is moved to a table above.
const _pumpsNoShell = <String, String>{
  'integration_test/b8_clock_skew_test.dart':
      'pumps the clock-skew banner alone, over a detector',
  'integration_test/circle_service_remove_member_test.dart':
      'pumps the circles sheet alone, over a real circle service',
};

/// The one workflow that names every runner without running an app: it runs
/// their `--self-test` halves.
const _selfTestWorkflow = 'repo-guards.yml';

/// The widgets that are, or mount, the shell.
const _shells = {'HavenApp', 'AppRouter', 'MapShell'};

/// What [source] does that mounts the app, as written: a shell it
/// constructs, a `runApp(`, or another library's `main()`.
List<String> _mounts(String source) {
  final unit = parseString(content: source, throwIfDiagnostics: false).unit;
  final mounts = _Mounts();
  unit.accept(mounts);
  return mounts.found;
}

class _Mounts extends RecursiveAstVisitor<void> {
  final List<String> found = [];

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    final type = node.constructorName.type.name.lexeme;
    if (_shells.contains(type)) found.add('$type(');
    super.visitInstanceCreationExpression(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final name = node.methodName.name;
    // Without `const` or `new` an unresolved constructor call parses as a
    // plain invocation — on its import prefix, when it has one.
    if ((node.target == null || node.target is SimpleIdentifier) &&
        _shells.contains(name)) {
      found.add('$name(');
    }
    if (node.target == null && name == 'runApp') found.add('runApp(');
    if (node.target != null && name == 'main') found.add('.main()');
    super.visitMethodInvocation(node);
  }

  @override
  void visitComment(Comment node) {}
}

/// The `HAVEN_LIVE_SYNC:` values [workflow] assigns, comments excluded.
List<String> _liveSyncValues(String workflow) => [
  for (final line in workflow.split('\n'))
    if (RegExp(r'^\s*HAVEN_LIVE_SYNC:\s*(.+?)\s*$').firstMatch(line)
        case final match?)
      match.group(1)!,
];

class _Calls extends RecursiveAstVisitor<void> {
  final List<MethodInvocation> pumps = [];
  final List<MethodInvocation> asserts = [];
  final List<AwaitExpression> awaits = [];

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final name = node.methodName.name;
    final teardown = node.argumentList.arguments.any(
      (a) => a.toSource().startsWith('const SizedBox.shrink('),
    );
    if ((name == 'pumpWidget' || name == 'pumpFrames') && !teardown) {
      pumps.add(node);
    }
    if (name == 'expectAppResumed' && node.target == null) asserts.add(node);
    super.visitMethodInvocation(node);
  }

  @override
  void visitAwaitExpression(AwaitExpression node) {
    awaits.add(node);
    super.visitAwaitExpression(node);
  }

  @override
  void visitComment(Comment node) {}
}

/// The app pumps in [source] that are NOT preceded, in the same function and
/// with no `await` in between, by `expectAppResumed()` — as 1-based ordinals.
List<int> _unassertedPumps(String source) {
  final unit = parseString(content: source, throwIfDiagnostics: false).unit;
  final calls = _Calls();
  unit.accept(calls);
  final missing = <int>[];
  for (var i = 0; i < calls.pumps.length; i++) {
    final pump = calls.pumps[i];
    final body = pump.thisOrAncestorOfType<FunctionBody>();
    final statement = pump.thisOrAncestorOfType<Statement>()!;
    final asserted = calls.asserts.any(
      (a) =>
          identical(a.thisOrAncestorOfType<FunctionBody>(), body) &&
          a.end <= statement.offset &&
          !calls.awaits.any(
            (w) => w.offset > a.end && w.offset < statement.offset,
          ),
    );
    if (!asserted) missing.add(i + 1);
  }
  return missing;
}

/// Whether `main()` in [source] calls `resumeAppBeforeEachTest()` as one of
/// its own statements — not inside a group, where it would cover only that
/// group's tests.
bool _resumesBeforeEachTest(String source) {
  final unit = parseString(content: source, throwIfDiagnostics: false).unit;
  for (final declaration in unit.declarations) {
    if (declaration is! FunctionDeclaration) continue;
    if (declaration.name.lexeme != 'main') continue;
    final body = declaration.functionExpression.body;
    if (body is! BlockFunctionBody) return false;
    return body.block.statements.any(
      (s) => s.toSource() == 'resumeAppBeforeEachTest();',
    );
  }
  return false;
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(
    () => binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed),
  );

  group('after a test, a binding has forgotten the lifecycle', () {
    // What `postTest` does to the binding between two tests of one process.
    setUp(binding.resetInternalState);

    test('and an app pumped then is refused by name', () {
      expect(appIsResumed(), isFalse, reason: 'premise');
      expect(expectAppResumed, throwsA(isA<TestFailure>()));
    });

    group('unless the target resumes the app before each test', () {
      resumeAppBeforeEachTest();

      test('first test', () {
        expect(binding.lifecycleState, AppLifecycleState.resumed);
        expectAppResumed();
      });

      test('and every test after it', () {
        expect(binding.lifecycleState, AppLifecycleState.resumed);
        expectAppResumed();
      });
    });
  });

  test('a test that drives paused itself is not overridden', () {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    expect(expectAppResumed, throwsA(isA<TestFailure>()));
  });

  group('the checker sees what it must', () {
    test('a pump with the assertion just before it passes', () {
      expect(
        _unassertedPumps(
          'f(t) async { await g(); expectAppResumed(); if (x) throw 1; '
          'await t.pumpWidget(App()); }',
        ),
        isEmpty,
      );
    });

    test('a pump with none, or with an await in between, is found', () {
      expect(
        _unassertedPumps('f(t) async { await t.pumpWidget(App()); }'),
        [1],
      );
      expect(
        _unassertedPumps(
          'f(t) async { expectAppResumed(); await g(); '
          'await t.pumpWidget(App()); }',
        ),
        [1],
      );
    });

    test('an assertion in another function does not count', () {
      expect(
        _unassertedPumps(
          'a() { expectAppResumed(); } '
          'f(t) async { await t.pumpWidget(App()); }',
        ),
        [1],
      );
    });

    test('the teardown pump is not an app pump', () {
      expect(
        _unassertedPumps(
          'f(t) async { await t.pumpWidget(const SizedBox.shrink()); }',
        ),
        isEmpty,
      );
    });

    test('a file that mounts the app is told from one that does not', () {
      expect(_mounts('f(t) => t.pumpWidget(const HavenApp());'), ['HavenApp(']);
      expect(_mounts('f(t) => t.pumpWidget(HavenApp());'), ['HavenApp(']);
      expect(
        _mounts('f(t) => t.pumpWidget(app.HavenApp());'),
        ['HavenApp('],
        reason: 'an import prefix without `const` parses as a call on it',
      );
      expect(_mounts('f(t) => t.pumpWidget(const MapShell());'), ['MapShell(']);
      expect(
        _mounts(
          '// pumps HavenApp elsewhere\n'
          'f(t) { find.byType(HavenApp); '
          'return t.pumpWidget(const MaterialApp(home: Banner())); }',
        ),
        isEmpty,
        reason: 'named, in a comment and in a finder, and never constructed',
      );
    });

    test('the shell under another name, and an app that is never pumped, '
        'are seen', () {
      expect(
        _mounts(
          'f(t) => t.pumpWidget(const ProviderScope(child: '
          'MaterialApp(home: AppRouter())));',
        ),
        ['AppRouter('],
      );
      expect(_mounts('f() { runApp(const Placeholder()); }'), ['runApp(']);
      expect(_mounts('f() async { app.main(); }'), ['.main()']);
      expect(
        _mounts('Widget app() => const ProviderScope(child: HavenApp());'),
        ['HavenApp('],
        reason: 'a helper that returns the app constructs it',
      );
    });

    test('a pumpFrames is a pump', () {
      final unit = parseString(
        content: 'f(t) => t.pumpFrames(const HavenApp(), d);',
        throwIfDiagnostics: false,
      ).unit;
      final calls = _Calls();
      unit.accept(calls);
      expect(calls.pumps, hasLength(1));
    });

    test("a workflow's live-sync values are read, comments aside", () {
      expect(
        _liveSyncValues(
          '    env:\n'
          '      # HAVEN_LIVE_SYNC: "true" was the old value\n'
          '      HAVEN_LIVE_SYNC: "false"\n'
          r'      HAVEN_LIVE_SYNC: ${{ inputs.live_sync }}'
          '\n',
        ),
        ['"false"', r'${{ inputs.live_sync }}'],
      );
    });

    test('the helper must be called by main itself', () {
      expect(
        _resumesBeforeEachTest('void main() { resumeAppBeforeEachTest(); }'),
        isTrue,
      );
      expect(
        _resumesBeforeEachTest(
          "void main() { group('g', () { resumeAppBeforeEachTest(); }); }",
        ),
        isFalse,
      );
      expect(_resumesBeforeEachTest('void main() {}'), isFalse);
    });
  });

  test('every integration target that pumps or launches anything is in '
      'exactly one table, for a reason that still holds', () {
    final subjects = <String, List<String>>{};
    for (final file
        in Directory('integration_test')
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))) {
      final path = file.path.replaceAll(r'\', '/');
      final source = file.readAsStringSync();
      final unit = parseString(content: source, throwIfDiagnostics: false).unit;
      final calls = _Calls();
      unit.accept(calls);
      final mounts = _mounts(source);
      if (path.contains('/_lib/')) {
        expect(
          [...calls.pumps.map((p) => p.toSource()), ...mounts],
          isEmpty,
          reason: '$path: a pump inside a helper, or a helper that returns '
              'the app, is one no target shows',
        );
        continue;
      }
      if (calls.pumps.isNotEmpty || mounts.isNotEmpty) subjects[path] = mounts;
    }
    final tables = [
      _targets.keys.toSet(),
      _engineCompiledOut.keys.toSet(),
      _pumpsNoShell.keys.toSet(),
    ];
    expect(
      subjects.keys.toSet(),
      tables.expand((t) => t).toSet(),
      reason: 'a target that pumps or launches something appeared or went. '
          'In a lane that compiles the engine in it takes the helper '
          '(`_targets`); one whose lane compiles it out, or that mounts no '
          'shell, says so in its own table',
    );
    expect(
      tables.expand((t) => t),
      hasLength(subjects.length),
      reason: 'a target is in two tables',
    );
    for (final path in [..._targets.keys, ..._engineCompiledOut.keys]) {
      expect(
        subjects[path],
        isNotEmpty,
        reason: '$path mounts no shell any more: it belongs in '
            '`_pumpsNoShell`',
      );
    }
    for (final path in _pumpsNoShell.keys) {
      expect(
        subjects[path],
        isEmpty,
        reason: '$path now mounts the app: it takes the helper, or its lane '
            'compiles the engine out',
      );
    }
  });

  test('a scenario that was overtaken ends as superseded, not as a '
      'lifecycle failure', () {
    final source = File(
      'integration_test/e2e/e2e_combined.dart',
    ).readAsStringSync().replaceAll(RegExp(r'\s+'), ' ');
    expect(
      source,
      contains(
        'if (_m11Superseded(generation)) throw const _M11ScenarioSuperseded(); '
        'expectAppResumed(); await tester.pumpWidget(',
      ),
      reason: 'the scenario that overtook it may be the one that moved the '
          'lifecycle: asserted first, the overtaken one reports a failure '
          'that is not its own',
    );
  });

  for (final MapEntry(key: path, value: lane) in _engineCompiledOut.entries) {
    test('$path is exempt only while its one lane compiles the engine out',
        () {
      final workflows = Directory('../.github/workflows')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.yml'));
      final naming = [
        for (final workflow in workflows)
          if (workflow.readAsStringSync().contains(lane.runner))
            workflow.uri.pathSegments.last,
      ]..remove(_selfTestWorkflow);
      expect(
        naming,
        [lane.workflow],
        reason: 'a second lane runs this target: say here what it compiles',
      );
      expect(
        _liveSyncValues(
          File('../.github/workflows/${lane.workflow}').readAsStringSync(),
        ),
        ['"false"'],
        reason: 'the lane now builds a live-sync session nothing claims for: '
            'move the target to `_targets` and give it the helper',
      );
      expect(
        _resumesBeforeEachTest(File(path).readAsStringSync()),
        isFalse,
        reason: 'it takes the helper after all: move it to `_targets`',
      );
    });
  }

  for (final MapEntry(key: path, value: pumps) in _targets.entries) {
    test('$path resumes the app before each test and asserts it at every '
        'pump', () {
      final source = File(path).readAsStringSync();
      expect(
        _resumesBeforeEachTest(source),
        isTrue,
        reason: 'only the first test of a process can read `resumed` '
            'without it, and only by luck',
      );
      final unit = parseString(content: source, throwIfDiagnostics: false).unit;
      final calls = _Calls();
      unit.accept(calls);
      expect(
        calls.pumps,
        hasLength(pumps),
        reason: 'anti-vacuity: an app pump appeared or went — count it here',
      );
      expect(
        _unassertedPumps(source),
        isEmpty,
        reason: 'a lane whose session is never claimed for passes on the '
            'legacy receive path and says nothing',
      );
    });
  }
}
