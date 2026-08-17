// Static guard for Security Rule 9: "Dart has no `zeroize`; minimize
// exposure by re-fetching secret bytes per use rather than holding long-lived
// references."
//
// Two shapes are policed, both rooted in the same fact: a 32-byte secp256k1
// secret that no name refers to cannot be overwritten, so it survives in the
// isolate's heap until the GC happens to relocate rather than erase it —
// reachable from a heap dump, tombstone, or core file on a rooted or
// debuggable device.
//
//  1. A fetch bound to a NAMED LOCAL (`final secretBytes = await
//     x.getSecretBytes();`) must be `fillRange`'d somewhere in the SAME
//     enclosing function. Once bound to a name, the plaintext sits in the heap
//     until something explicitly overwrites it; this guard requires that
//     overwrite.
//
//  2. `Uint8List.fromList(<secret bytes>)` is flagged UNCONDITIONALLY,
//     scrubbed wrapper or not. `fromList` copies, so the buffer it copied FROM
//     stays live — and at a fetch site that source is an unnamed temporary no
//     `fillRange` anywhere in the program can reach. Scrubbing the copy wipes
//     one of the two live secrets and reports success. There is no correct
//     variant of this shape, which is why it has no "…WITH a scrub" escape.
//
// The sanctioned way to move a fetched buffer is `takeSecretOwnership`
// (`lib/src/services/fresh_secret.dart`): it returns the SAME buffer when it
// already is a `Uint8List` (minting no copy at all) and otherwise wipes the
// source before returning. This guard climbs through it and moves the scrub
// requirement onto whatever its result binds to. Its own internal
// `Uint8List.fromList(raw)` is the one correct copy in the repo and is not
// matched, because the value it copies is not itself named as secret bytes.
//
// `withFreshSecret` covers the three `CircleManagerFfi.newInstance` call sites
// — pinned per-site by `test/services/identity_secret_scrub_test.dart`, which
// also pins the helper's scrub BEHAVIOURALLY. That pattern is a TEAR-OFF: the
// caller never calls `getSecretBytes()` itself, it hands the unevaluated
// method reference to `withFreshSecret`, which fetches, uses, and scrubs on
// the caller's behalf. A tear-off (`x.getSecretBytes` with no `()`) never
// produces a `MethodInvocation` node, so this guard — which only inspects
// actual invocations — never needs to special-case it.
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

/// One place secret bytes are left recoverable in the Dart heap.
class SecretScrubViolation {
  SecretScrubViolation({
    required this.path,
    required this.line,
    required this.detail,
  });

  final String path;
  final int line;

  /// Why this site is a violation, in the terms the fixer needs.
  final String detail;

  @override
  String toString() => '$path:$line ($detail)';
}

/// A secret-bytes value bound to a named local, and the AST node (the
/// `VariableDeclaration` or `AssignmentExpression`) that bound it — used to
/// locate the enclosing function to search for a scrub.
class _Capture {
  _Capture(this.varName, this.bindingNode);
  final String varName;
  final AstNode bindingNode;
}

/// Whether [name] names a secret-BYTES accessor — a buffer of raw key
/// material, not merely something with "secret" in its name.
///
/// Requiring BOTH halves is what makes this sound: it catches every fetch
/// shape the repo actually uses (`getSecretBytes`, the `secretBytes` callback
/// field, `_identitySecretBytes`) while excluding `_buildSecretKeyCard` — a
/// widget builder that returns no bytes and is the known near-miss.
bool _namesSecretBytes(String name) {
  final lower = name.toLowerCase();
  return lower.contains('secret') && lower.contains('bytes');
}

/// Strips `await` and redundant parentheses, which move a value without
/// changing which buffer it is.
Expression _unwrap(Expression expression) {
  var current = expression;
  while (true) {
    if (current is AwaitExpression) {
      current = current.expression;
    } else if (current is ParenthesizedExpression) {
      current = current.expression;
    } else {
      return current;
    }
  }
}

/// Whether [expression] evaluates to secret bytes: a call to a secret-bytes
/// accessor, or a name already holding them (a `identitySecretBytes`
/// parameter forwarded to the FFI).
bool _isSecretBytes(Expression expression) {
  final expr = _unwrap(expression);
  if (expr is MethodInvocation) return _namesSecretBytes(expr.methodName.name);
  if (expr is SimpleIdentifier) return _namesSecretBytes(expr.name);
  return false;
}

/// Whether [node] is the `Uint8List.fromList(...)` copy constructor.
bool _isBytesCopy(MethodInvocation node) {
  final target = node.target;
  return node.methodName.name == 'fromList' &&
      target is SimpleIdentifier &&
      target.name == 'Uint8List';
}

/// Climbs from a secret-bytes invocation through the shapes this codebase
/// uses to move the value around — `await`, redundant parentheses, and
/// `takeSecretOwnership`, the one sanctioned ownership transfer — to find
/// whether the result ends up bound to a name in the current scope.
///
/// Returns `null` when the value flows straight through: a `return`, the
/// implicit body of an arrow function, or an argument handed to some other
/// call without ever being captured. All are legitimate "provider" shapes
/// this repo uses instead of holding a reference (see file header).
///
/// `Uint8List.fromList(...)` is deliberately NOT climbed through: it is
/// handled as a violation in its own right by [_SecretScrubVisitor], because
/// continuing the climb from the copy would ask only whether the COPY is
/// scrubbed and say nothing about the source it was copied from.
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
      final isOwnershipTransfer = invocation is MethodInvocation &&
          invocation.target == null &&
          invocation.methodName.name == 'takeSecretOwnership';
      if (isOwnershipTransfer) {
        // Ownership moved, no copy left behind — the scrub requirement moves
        // with it, onto whatever this result binds to.
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

  void _report(AstNode at, String detail) {
    violations.add(
      SecretScrubViolation(
        path: _path,
        line: _lineInfo.getLocation(at.offset).lineNumber,
        detail: detail,
      ),
    );
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final args = node.argumentList.arguments;
    if (_isBytesCopy(node) && args.length == 1 && _isSecretBytes(args.single)) {
      _report(
        node,
        'Uint8List.fromList copies the secret and leaves the source live — '
        'use takeSecretOwnership',
      );
    } else if (_namesSecretBytes(node.methodName.name)) {
      final capture = _findCapture(node);
      if (capture != null) {
        final body = _enclosingFunctionBody(capture.bindingNode);
        if (body == null || !_scrubsVariable(body, capture.varName)) {
          _report(node, "local `${capture.varName}` never fillRange'd");
        }
      }
    }
    super.visitMethodInvocation(node);
  }
}

/// Returns every place in [source] where secret bytes are left recoverable:
/// a fetch bound to a local that is never `fillRange`'d in the same function,
/// or a `Uint8List.fromList` copy of secret bytes.
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
      expect(v.single.detail, contains('secretBytes'));
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

    test('flags the Uint8List.fromList shape without a scrub', () {
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
      expect(v.single.detail, contains('Uint8List.fromList'));
    });

    test(
      'flags the Uint8List.fromList shape EVEN WHEN the wrapper is scrubbed '
      '— the copy is not the problem, the un-scrubbable source is',
      () {
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
        final v = findUnscrubbedSecretCaptures(source);
        expect(
          v,
          hasLength(1),
          reason: 'the fetched buffer is an unnamed temporary — scrubbing the '
              'COPY leaves the original live, and reports success',
        );
        expect(v.single.detail, contains('takeSecretOwnership'));
      },
    );

    test(
      'flags a Uint8List.fromList copy of a secret-bytes PARAMETER — the '
      'caller owns that buffer, so the copy is one nothing will ever scrub',
      () {
        const source = '''
class _S {
  Future<void> go(List<int> identitySecretBytes) async {
    await ffi.createCircle(
      identitySecretBytes: Uint8List.fromList(identitySecretBytes),
    );
  }
}
''';
        expect(findUnscrubbedSecretCaptures(source), hasLength(1));
      },
    );

    test('permits takeSecretOwnership when the result is scrubbed', () {
      const source = '''
class _S {
  Future<void> go() async {
    final secret = takeSecretOwnership(await x.getSecretBytes());
    try {
      use(secret);
    } finally {
      secret.fillRange(0, secret.length, 0);
    }
  }
}
''';
      expect(findUnscrubbedSecretCaptures(source), isEmpty);
    });

    test(
      'flags takeSecretOwnership when the result is NOT scrubbed — the '
      'transfer moves the obligation, it does not discharge it',
      () {
        const source = '''
class _S {
  Future<void> go() async {
    final secret = takeSecretOwnership(await x.getSecretBytes());
    use(secret);
  }
}
''';
        final v = findUnscrubbedSecretCaptures(source);
        expect(v, hasLength(1));
        expect(v.single.detail, contains('secret'));
      },
    );

    test(
      'flags a fetch named something other than getSecretBytes — the guard '
      'keys on "secret" + "bytes", not on one hard-coded method name',
      () {
        const source = '''
class _S {
  Future<void> go() async {
    final a = await secretBytes();
    final b = await _identitySecretBytes();
    use(a, b);
  }
}
''';
        final v = findUnscrubbedSecretCaptures(source);
        expect(
          v,
          hasLength(2),
          reason: 'both the callback-field fetch and the private-method fetch '
              'hold raw key material, whatever they are called',
        );
      },
    );

    test(
      'does NOT flag a secret-named call that returns no bytes — '
      '`_buildSecretKeyCard` is a widget builder, not key material',
      () {
        const source = '''
class _S {
  Widget build() {
    final card = _buildSecretKeyCard();
    return card;
  }
}
''';
        expect(
          findUnscrubbedSecretCaptures(source),
          isEmpty,
          reason: 'requiring BOTH "secret" and "bytes" is what keeps this '
              'guard free of false positives',
        );
      },
    );

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
    // fix. Empty is the steady state (see
    // `announcement_keys_reachable_test.dart` for the same pattern): every
    // site the rule can name has been fixed, not merely allowlisted. The
    // last to close were the seven `Uint8List.fromList(<fetch>)` call sites
    // and the three `Uint8List.fromList(identitySecretBytes)` FFI forwards,
    // each of which minted a second live 32-byte secret that no `fillRange`
    // anywhere could reach; they now take ownership of the fetched buffer
    // instead of copying it. Each entry, if one is ever added back, must be a
    // SPECIFIC, individually-named site — never a pattern — so a new
    // violation anywhere else still fails this test, and fixing one without
    // deleting its line here fails it too.
    const knownOpenViolations = <String>{};

    test(
      'every secret-bytes capture is scrubbed and no copy is minted, except '
      'the individually-named known-open set',
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
              'Security Rule 9: a raw nsec that no name refers to cannot be '
              'overwritten, so it stays in the heap for the GC to relocate '
              'rather than erase. Wrap the fetch in `withFreshSecret` '
              '(tear-off, no local ever bound), or take ownership of the '
              'fetched buffer with `takeSecretOwnership` and scrub that local '
              'with fillRange in the same function. Never `Uint8List.fromList` '
              'a secret: the buffer it copies FROM stays live.\n'
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
