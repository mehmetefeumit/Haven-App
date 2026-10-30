// V11: gift wraps (kind 1059) are read only from the user's own inbox relays
// — `inboxRelaysProvider`, the list Haven's kind 10050 advertises (NIP-17) —
// on every Dart plane: the poller, the manual refresh, and the live-sync
// engine's inbox REQ, where what a start is HANDED is that list.
//
// What each site does with the list it reads is tested where it lives
// (`invitation_provider_test.dart`,
// `invitation_poll_status_provider_test.dart`, and
// `live_sync_resubscriber_test.dart`, whose starts are handed exactly what its
// `inboxRelays` closure returns). This file pins that those are ALL the
// sites, and what each is fed.
//
// Not covered here: what Rust reads in a process Dart does not drive (the
// background catch-up and the Android service's cycle).
@TestOn('vm')
library;

import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:flutter_test/flutter_test.dart';

/// Where each call named in [_names] is made, with the source of the argument
/// named [_argument] (or `''`), comments stripped.
class _Calls extends RecursiveAstVisitor<void> {
  _Calls(this._names, this._argument);

  final Set<String> _names;
  final String _argument;
  final List<String> found = [];

  String _arg(ArgumentList list) => list.arguments
      .whereType<NamedExpression>()
      .where((a) => a.name.label.name == _argument)
      .map((a) => a.expression.toSource())
      .join();

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (_names.contains(node.methodName.name)) {
      found.add(_arg(node.argumentList));
    }
    super.visitMethodInvocation(node);
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    if (_names.contains(node.constructorName.type.name.lexeme)) {
      found.add(_arg(node.argumentList));
    }
    super.visitInstanceCreationExpression(node);
  }
}

/// Every call of [names] in `lib/` (the generated bridge and [skip] left out),
/// as `<path>: <argument source>`.
List<String> _sites(
  Set<String> names, {
  required String argument,
  Set<String> skip = const {},
}) {
  final files =
      Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where(
            (f) =>
                f.path.endsWith('.dart') &&
                !f.path.startsWith('lib/src/rust/') &&
                !skip.contains(f.path),
          )
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  return [
    for (final file in files) ...[
      for (final arg in _callsIn(file, names, argument)) '${file.path}: $arg',
    ],
  ];
}

List<String> _callsIn(File file, Set<String> names, String argument) {
  final calls = _Calls(names, argument);
  parseString(
    content: file.readAsStringSync(),
    throwIfDiagnostics: false,
  ).unit.accept(calls);
  return calls.found;
}

void main() {
  test('only the poller and the refresh fetch gift wraps, each over the list '
      'it read from inboxRelaysProvider', () {
    expect(
      _sites(
        {'fetchGiftWraps', 'fetchGiftWrapsPerRelay'},
        argument: 'relays',
        skip: {
          'lib/src/services/relay_service.dart',
          'lib/src/services/nostr_relay_service.dart',
        },
      ),
      [
        'lib/src/providers/invitation_poll_status_provider.dart: [relays[i]]',
        'lib/src/providers/invitation_provider.dart: pollRelays',
      ],
    );
    for (final (path, variable) in [
      ('lib/src/providers/invitation_poll_status_provider.dart', 'relays'),
      ('lib/src/providers/invitation_provider.dart', 'pollRelays'),
    ]) {
      final source = File(path).readAsStringSync();
      expect(
        RegExp(
          'final $variable = await ref\\.read\\(inboxRelaysProvider\\.future\\);',
        ).allMatches(source),
        hasLength(1),
        reason: '$path fetches over a list that is not the inbox list',
      );
      expect(
        RegExp('\\b$variable = ').allMatches(source),
        hasLength(1),
        reason: '$path reassigns the list it fetches over',
      );
    }
  });

  test("the engine's inbox REQ is started only from the re-subscriber, which "
      'MapShell feeds from inboxRelaysProvider', () {
    const fed = '() => ref.read(inboxRelaysProvider.future)';
    expect(
      _sites({'LiveSyncResubscriber'}, argument: 'inboxRelays'),
      ['lib/src/pages/map_shell.dart: $fed'],
      reason: 'a start handed a list other than the inbox relays',
    );
    expect(
      _sites({'start'}, argument: 'inboxRelays').where(
        (site) => !site.endsWith(': '),
      ),
      ['lib/src/services/live_sync_resubscriber.dart: inbox'],
    );
    expect(
      File('lib/src/services/live_sync_resubscriber.dart').readAsStringSync(),
      contains('final inbox = await _inboxRelays();'),
    );
    expect(
      _sites({'startSession'}, argument: 'inboxRelays'),
      ['lib/src/services/nostr_subscription_service.dart: inboxRelays'],
    );
  });
}
