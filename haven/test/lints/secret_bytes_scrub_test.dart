// Static guard for Security Rule 9: "Dart has no `zeroize`; minimize
// exposure by re-fetching secret bytes per use rather than holding long-lived
// references."
//
// `withFreshSecret` (`lib/src/services/fresh_secret.dart`) already covers the
// three `CircleManagerFfi.newInstance` call sites — pinned per-site by
// `test/services/identity_secret_scrub_test.dart`, which also checks the
// helper still `fillRange`s. That pattern is a TEAR-OFF: the caller never
// calls `getSecretBytes()` itself, it hands the unevaluated method reference
// to `withFreshSecret`, which fetches, uses, and scrubs on the caller's
// behalf. A tear-off (`x.getSecretBytes` with no `()`) never produces a
// `MethodInvocation` node, so this guard — which only inspects actual
// invocations — never needs to special-case it.
//
// The remaining gap (`docs/CI_HARDENING_BACKLOG.md` Workstream D) is call
// sites that invoke `getSecretBytes()` directly and bind the result to a
// named local (`final secretBytes = await x.getSecretBytes();`, or the same
// wrapped in `Uint8List.fromList(...)`). Once bound to a name, the plaintext
// sits in the isolate's heap for the GC to relocate rather than erase —
// reachable from a heap dump, tombstone, or core file on a rooted or
// debuggable device — until something explicitly overwrites it. This guard
// requires that overwrite: every such local must be `fillRange`'d somewhere
// in the SAME enclosing function.
//
// A call whose result is never bound to a local at all — returned directly,
// the implicit body of an arrow-function "provider" closure
// (`() => ref.read(...).getSecretBytes()`, the shape `service_providers.dart`
// uses to hand a re-fetch-per-call closure to a constructor param), or passed
// straight into another call's arguments — needs no scrub here: there is no
// name in this scope to overwrite, so nothing is retained.
//
// The detector is unit-tested below against known-buggy and known-safe
// snippets, including a same-file/different-method boundary case, so it
// cannot silently rot into a vacuous pass or a same-file substring match that
// launders an unrelated `fillRange` into covering the wrong function.
@TestOn('vm')
library;

import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:flutter_test/flutter_test.dart';

/// One `getSecretBytes()` call whose result is bound to a local that is
/// never scrubbed in its enclosing function.
class SecretScrubViolation {
  SecretScrubViolation({
    required this.path,
    required this.line,
    required this.varName,
  });

  final String path;
  final int line;
  final String varName;

  @override
  String toString() => "$path:$line (local `$varName` never fillRange'd)";
}

/// A `getSecretBytes()` result bound to a named local, and the AST node
/// (the `VariableDeclaration` or `AssignmentExpression`) that bound it —
/// used to locate the enclosing function to search for a scrub.
class _Capture {
  _Capture(this.varName, this.bindingNode);
  final String varName;
  final AstNode bindingNode;
}

/// Climbs from a `getSecretBytes()` invocation through the shapes this
/// codebase actually uses to move the value around — `await`, redundant
/// parentheses, and the `Uint8List.fromList(...)` repackaging idiom every
/// scrubbed call site already uses — to find whether the result ends up
/// bound to a name in the current scope.
///
/// Returns `null` when the value flows straight through: a `return`, the
/// implicit body of an arrow function, or an argument handed to some other
/// call without ever being captured. Both are legitimate "provider" shapes
/// this repo uses instead of holding a reference (see file header).
_Capture? _findCapture(MethodInvocation call) {
  AstNode node = call;
  while (true) {
    final parent = node.parent;
    if (parent == null) return null;

    if (parent is AwaitExpression || parent is ParenthesizedExpression) {
      node = parent;
      continue;
    }

    if (parent is ArgumentList) {
      final invocation = parent.parent;
      final target = invocation is MethodInvocation ? invocation.target : null;
      final isBytesRepackaging = invocation is MethodInvocation &&
          invocation.methodName.name == 'fromList' &&
          target is SimpleIdentifier &&
          target.name == 'Uint8List';
      if (isBytesRepackaging) {
        node = invocation;
        continue;
      }
      // Handed straight to a real sink (a different function's argument) —
      // never bound to a name in this scope, so nothing to scrub here.
      return null;
    }

    if (parent is VariableDeclaration) {
      return _Capture(parent.name.lexeme, parent);
    }

    if (parent is AssignmentExpression) {
      final lhs = parent.leftHandSide;
      if (lhs is SimpleIdentifier) return _Capture(lhs.name, parent);
      return null;
    }

    // ReturnStatement, ExpressionFunctionBody (arrow-closure provider), or
    // anything else — the value flows out without being retained here.
    return null;
  }
}

/// The innermost enclosing function/method body of [node], or `null` if
/// [node] is not inside one (should not happen for real Dart source).
FunctionBody? _enclosingFunctionBody(AstNode node) {
  for (var cur = node.parent; cur != null; cur = cur.parent) {
    if (cur is MethodDeclaration) return cur.body;
    if (cur is FunctionDeclaration) return cur.functionExpression.body;
    if (cur is FunctionExpression) return cur.body;
  }
  return null;
}

/// Whether [body] contains a `<varName>.fillRange(...)` call anywhere in its
/// subtree. Scoped to a single function body (never a whole-file search) so
/// a scrub in one method cannot launder an unscrubbed capture in a sibling
/// method that happens to reuse the same local name.
bool _scrubsVariable(FunctionBody body, String varName) {
  final finder = _FillRangeFinder(varName);
  body.accept(finder);
  return finder.found;
}

class _FillRangeFinder extends RecursiveAstVisitor<void> {
  _FillRangeFinder(this._varName);

  final String _varName;
  bool found = false;

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (!found &&
        node.methodName.name == 'fillRange' &&
        node.target is SimpleIdentifier &&
        (node.target! as SimpleIdentifier).name == _varName) {
      found = true;
    }
    super.visitMethodInvocation(node);
  }
}

class _SecretScrubVisitor extends RecursiveAstVisitor<void> {
  _SecretScrubVisitor(this._lineInfo, this._path);

  final LineInfo _lineInfo;
  final String _path;
  final List<SecretScrubViolation> violations = [];

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (node.methodName.name == 'getSecretBytes') {
      final capture = _findCapture(node);
      if (capture != null) {
        final body = _enclosingFunctionBody(capture.bindingNode);
        final scrubbed = body != null && _scrubsVariable(body, capture.varName);
        if (!scrubbed) {
          violations.add(
            SecretScrubViolation(
              path: _path,
              line: _lineInfo.getLocation(node.offset).lineNumber,
              varName: capture.varName,
            ),
          );
        }
      }
    }
    super.visitMethodInvocation(node);
  }
}

/// Returns every `getSecretBytes()` call in [source] whose result is bound to
/// a local never scrubbed with `fillRange` in the same function.
List<SecretScrubViolation> findUnscrubbedSecretCaptures(
  String source, {
  String path = '<memory>',
}) {
  final parsed = parseString(content: source, throwIfDiagnostics: false);
  final visitor = _SecretScrubVisitor(parsed.lineInfo, path);
  parsed.unit.accept(visitor);
  return visitor.violations;
}

void main() {
  group('detector self-tests', () {
    test('flags a bare local capture that is never scrubbed', () {
      const source = '''
class _S {
  Future<void> go() async {
    final secretBytes = await x.getSecretBytes();
    use(secretBytes);
  }
}
''';
      final v = findUnscrubbedSecretCaptures(source);
      expect(v, hasLength(1));
      expect(v.single.varName, 'secretBytes');
    });

    test('permits a local capture scrubbed in a finally block', () {
      const source = '''
class _S {
  Future<void> go() async {
    final secretBytes = await x.getSecretBytes();
    try {
      use(secretBytes);
    } finally {
      secretBytes.fillRange(0, secretBytes.length, 0);
    }
  }
}
''';
      expect(findUnscrubbedSecretCaptures(source), isEmpty);
    });

    test('flags the Uint8List.fromList wrapper shape without a scrub', () {
      const source = '''
class _S {
  Future<void> go() async {
    Uint8List? secretBuffer;
    secretBuffer = Uint8List.fromList(await x.getSecretBytes());
    use(secretBuffer);
  }
}
''';
      final v = findUnscrubbedSecretCaptures(source);
      expect(v, hasLength(1));
      expect(v.single.varName, 'secretBuffer');
    });

    test('permits the Uint8List.fromList wrapper shape WITH a scrub', () {
      const source = '''
class _S {
  Future<void> go() async {
    Uint8List? secretBuffer;
    try {
      secretBuffer = Uint8List.fromList(await x.getSecretBytes());
      use(secretBuffer);
    } finally {
      secretBuffer?.fillRange(0, secretBuffer.length, 0);
    }
  }
}
''';
      expect(findUnscrubbedSecretCaptures(source), isEmpty);
    });

    test(
      'permits a tear-off handed to withFreshSecret (no local ever bound)',
      () {
        const source = '''
class _S {
  Future<void> go() async {
    await withFreshSecret(x.getSecretBytes, (bytes) async {
      use(bytes);
    });
  }
}
''';
        expect(findUnscrubbedSecretCaptures(source), isEmpty);
      },
    );

    test(
      'permits the arrow-closure provider shape (service_providers.dart)',
      () {
        const source = '''
final p = Provider((ref) {
  return Thing(
    identitySecretBytesProvider: () =>
        ref.read(identityNotifierProvider.notifier).getSecretBytes(),
  );
});
''';
        expect(findUnscrubbedSecretCaptures(source), isEmpty);
      },
    );

    test('permits a direct pass-through return', () {
      const source = '''
class _S {
  Future<List<int>> getSecretBytes() async {
    final manager = await ensure();
    return manager.getSecretBytes();
  }
}
''';
      expect(findUnscrubbedSecretCaptures(source), isEmpty);
    });

    test('permits a value passed straight to another call, never bound', () {
      const source = '''
class _S {
  Future<void> go() async {
    await doSomething(await x.getSecretBytes());
  }
}
''';
      expect(findUnscrubbedSecretCaptures(source), isEmpty);
    });

    test(
      'flags an unscrubbed capture even when a SIBLING method scrubs a '
      'local of the same name — proves the check is per-function, not a '
      'whole-file substring search',
      () {
        const source = '''
class _S {
  Future<void> safe() async {
    final secretBytes = await x.getSecretBytes();
    try {
      use(secretBytes);
    } finally {
      secretBytes.fillRange(0, secretBytes.length, 0);
    }
  }

  Future<void> unsafe() async {
    final secretBytes = await x.getSecretBytes();
    use(secretBytes);
  }
}
''';
        final v = findUnscrubbedSecretCaptures(source);
        expect(
          v,
          hasLength(1),
          reason:
              'a whole-file search for `secretBytes.fillRange(` would find '
              'the one in safe() and wrongly clear unsafe() too',
        );
        // The flagged capture must be unsafe()'s, not safe()'s.
        final unsafeLine =
            source.substring(0, source.indexOf('unsafe()')).split('\n').length;
        expect(v.single.line, greaterThanOrEqualTo(unsafeLine));
      },
    );
  });

  group('repository scan', () {
    // Known-open Security Rule 9 violations, tracked individually pending
    // fix. `docs/CI_HARDENING_BACKLOG.md` Workstream D named 4 of the sites
    // below (nostr_profile_service.dart's 3 and
    // invitation_poll_status_provider.dart's 1 have SINCE been scrubbed and
    // no longer appear here); this scan additionally found the
    // nostr_identity_service.dart pair, which the backlog's list did not
    // enumerate. Each entry is a SPECIFIC, individually-named site — never a
    // pattern — so a new violation anywhere else still fails this test, and
    // fixing one of these without deleting its line here fails it too.
    const knownOpenViolations = <String>{
      // `_createCircle`: fetched once for `createCircle(identitySecretBytes:
      // ...)`, never scrubbed after the call returns.
      'lib/src/pages/circles/name_circle_page.dart:290',
      // `invitationPollerProvider`: fetched once for the whole gift-wrap
      // batch, never scrubbed after `Future.wait` completes.
      'lib/src/providers/invitation_provider.dart:114',
      // `createIdentity`: written to secure storage via `base64Encode`, then
      // left resident in the local for the rest of the function.
      'lib/src/services/nostr_identity_service.dart:184',
      // `importFromNsec`: same shape as `createIdentity` above.
      'lib/src/services/nostr_identity_service.dart:211',
    };

    test(
      'every getSecretBytes() capture is scrubbed, except the '
      'individually-named known-open set',
      () {
        final libDir = Directory('lib');
        expect(
          libDir.existsSync(),
          isTrue,
          reason: 'Expected to run from the haven package root '
              '(cwd=${Directory.current.path}).',
        );

        final sep = Platform.pathSeparator;
        final offenders = <String>[];
        final seenKnown = <String>{};
        var scanned = 0;

        for (final entity in libDir.listSync(recursive: true)) {
          if (entity is! File || !entity.path.endsWith('.dart')) continue;
          // Generated FFI bindings — never hand-written.
          if (entity.path.contains('${sep}rust$sep')) continue;
          scanned++;

          final violations = findUnscrubbedSecretCaptures(
            entity.readAsStringSync(),
            path: entity.path,
          );
          for (final v in violations) {
            final key = '${v.path}:${v.line}';
            if (knownOpenViolations.contains(key)) {
              seenKnown.add(key);
            } else {
              offenders.add(v.toString());
            }
          }
        }

        expect(
          scanned,
          greaterThan(50),
          reason: 'Only scanned $scanned files — the lib/ glob looks broken.',
        );

        expect(
          offenders,
          isEmpty,
          reason:
              'Security Rule 9: getSecretBytes() fetched into a local that is '
              "never fillRange'd leaves the raw nsec in the heap for the GC "
              'to relocate rather than erase. Wrap the fetch in '
              '`withFreshSecret` (tear-off, no local ever bound) or scrub the '
              'local explicitly with fillRange in the same function.\n'
              'Offenders:\n  ${offenders.join('\n  ')}',
        );

        expect(
          seenKnown,
          knownOpenViolations,
          reason:
              'The known-open allowlist no longer matches what the scan '
              'found. If a site was fixed, delete its line from '
              'knownOpenViolations (do not leave a stale entry masking a '
              'regression); if the scan found something new at one of these '
              'exact sites, the shape changed — re-verify and update the '
              'comment.',
        );
      },
    );
  });
}
