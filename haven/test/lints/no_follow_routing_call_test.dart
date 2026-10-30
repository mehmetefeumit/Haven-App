// `LiveSyncFfi.followRouting()` is not called from the app: a subscribe that
// fails inside it loses the circle's REQ, and Rust follows a changed row by
// itself at the health tick (and, with W10-rest, after a resync).
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:flutter_test/flutter_test.dart';

/// Whether [source] names `followRouting` in code: a call, a tear-off or any
/// other reference. Read from the syntax tree, so neither a comment of either
/// kind nor a string can hide or fake one.
bool namesFollowRouting(String source) {
  final finder = _FollowRoutingFinder();
  parseString(content: source, throwIfDiagnostics: false).unit.accept(finder);
  return finder.found;
}

class _FollowRoutingFinder extends RecursiveAstVisitor<void> {
  bool found = false;

  // A doc comment's `[followRouting]` is a reference node too.
  @override
  void visitComment(Comment node) {}

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (node.name == 'followRouting') found = true;
    super.visitSimpleIdentifier(node);
  }
}

void main() {
  test('nothing in the app calls followRouting', () {
    final callers = [
      for (final file in Directory('lib').listSync(recursive: true))
        if (file is File &&
            file.path.endsWith('.dart') &&
            !file.path.startsWith('lib/src/rust/') &&
            namesFollowRouting(file.readAsStringSync()))
          file.path,
    ];
    expect(callers, isEmpty);
  });

  test('a call, a tear-off and a reference are each seen; a comment is not',
      () {
    expect(namesFollowRouting('f() async { await live.followRouting(); }'),
        isTrue);
    expect(namesFollowRouting('f() { final g = live.followRouting; }'), isTrue);
    expect(namesFollowRouting('f() { run(live.followRouting); }'), isTrue);
    expect(
      namesFollowRouting('f() {} // live.followRouting() is not called'),
      isFalse,
    );
    expect(namesFollowRouting('f() { followRoutingCount++; }'), isFalse);
  });

  test('a string or a block comment hides nothing and names nothing', () {
    expect(
      namesFollowRouting("f() { g('wss://x'); live.followRouting(); }"),
      isTrue,
    );
    expect(namesFollowRouting('f() { /* live.followRouting() */ }'), isFalse);
    expect(namesFollowRouting('/// See [followRouting].\nf() {}'), isFalse);
    expect(namesFollowRouting("f() { log('followRouting'); }"), isFalse);
  });
}
