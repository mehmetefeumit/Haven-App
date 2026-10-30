/// MapShell runs the storage-reset notice at startup.
///
/// `MapShell` cannot be pumped in `flutter test` (`MapPage` reaches the Rust
/// bridge in `initState`), so what the notice does is tested on
/// `showStorageResetNoticeIfOwed` (`storage_reset_notice_provider_test.dart`)
/// and this pins only that the shell's startup calls it, and that the shell
/// re-takes the user's own name after the reset — by reading, never
/// publishing. Comments are stripped by parsing, so prose cannot satisfy it.
@TestOn('vm')
library;

import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test("the shell's startup tasks run the storage-reset notice", () {
    final file = File('lib/src/pages/map_shell.dart');
    expect(file.existsSync(), isTrue, reason: 'map_shell.dart moved');
    final unit = parseString(
      content: file.readAsStringSync(),
      throwIfDiagnostics: false,
    ).unit;
    final shell = unit.declarations.whereType<ClassDeclaration>().singleWhere(
      (c) => c.name.lexeme == '_MapShellState',
    );
    final startup = shell.members.whereType<MethodDeclaration>().singleWhere(
      (m) => m.name.lexeme == '_runStartupTasks',
    );
    final body = startup.body.toSource();
    expect(
      body,
      contains('showStorageResetNoticeIfOwed('),
      reason: 'without it an owed notice is never shown, and relay-list '
          'publishing stays held for good',
    );
    expect(
      body,
      contains('openRelaySettingsForNotice('),
      reason: 'Relay settings must be opened by the helper whose future '
          'completes only when the user leaves them, or the reset is '
          'acknowledged while they are still adding their own relays',
    );
  });

  test("the shell's startup takes the user's own name from their published "
      'profile after the reset', () {
    final unit = parseString(
      content: File('lib/src/pages/map_shell.dart').readAsStringSync(),
      throwIfDiagnostics: false,
    ).unit;
    final shell = unit.declarations.whereType<ClassDeclaration>().singleWhere(
      (c) => c.name.lexeme == '_MapShellState',
    );
    String body(String name) => shell.members
        .whereType<MethodDeclaration>()
        .singleWhere((m) => m.name.lexeme == name)
        .body
        .toSource();
    // The startup's relay contact is made by `startUpRelayContact`, which
    // the startup runs through `gateStartUp` when the app is in front and the
    // next resume pays otherwise (`foreground_start_up_gate_test`).
    expect(body('_runStartupTasks'), contains('gateStartUp()'));
    expect(body('_onResumed'), contains('payOwedStartUp()'));
    for (final caller in ['startUpRelayContact', '_onResumed']) {
      expect(
        body(caller),
        contains('_reseedOwnNameAfterReset()'),
        reason: '$caller: without it a user whose name the reset dropped '
            'shows only their key until the next launch finds a relay',
      );
    }
    expect(
      body('_reseedOwnNameAfterReset'),
      allOf(
        contains('reseedOwnNameIfOwed('),
        contains('fetchOwnPublishedProfile'),
        contains('invalidate(displayNameProvider)'),
      ),
      reason: 'the name must come from what a relay answers, and show at once',
    );
  });

  test('the reset reseed only reads: it never publishes', () {
    final provider = parseString(
      content: File(
        'lib/src/providers/storage_reset_notice_provider.dart',
      ).readAsStringSync(),
      throwIfDiagnostics: false,
    ).unit;
    final reseed = provider.declarations
        .whereType<FunctionDeclaration>()
        .singleWhere((f) => f.name.lexeme == 'reseedOwnNameIfOwed')
        .toSource();
    final shell = parseString(
      content: File('lib/src/pages/map_shell.dart').readAsStringSync(),
      throwIfDiagnostics: false,
    ).unit.declarations.whereType<ClassDeclaration>().singleWhere(
      (c) => c.name.lexeme == '_MapShellState',
    );
    final caller = shell.members
        .whereType<MethodDeclaration>()
        .singleWhere((m) => m.name.lexeme == '_reseedOwnNameAfterReset')
        .toSource();
    final service = parseString(
      content: File(
        'lib/src/services/nostr_profile_service.dart',
      ).readAsStringSync(),
      throwIfDiagnostics: false,
    ).unit.declarations.whereType<ClassDeclaration>().singleWhere(
      (c) => c.name.lexeme == 'NostrProfileService',
    );
    final fetch = service.members
        .whereType<MethodDeclaration>()
        .singleWhere((m) => m.name.lexeme == 'fetchOwnPublishedProfile')
        .toSource();
    expect(
      fetch,
      contains('fetchMyProfile('),
      reason: 'anti-vacuity: this is the body that reaches the relays',
    );
    // Everything that publishes, retracts or queues a profile, and the two
    // ways to the signing secret no read needs.
    for (final publish in [
      'triggerProfileSync',
      'syncOwnProfile',
      'updateOwnProfile',
      'setOwnAvatar',
      'removeOwnAvatar',
      'ownProfileSyncProvider',
      'retryIfPending',
      'syncMyProfile',
      'removeMyProfilePicture',
      'deleteMyPublicProfile',
      'saveMyProfile',
      'getSecretBytes',
      'withFreshSecret',
    ]) {
      expect(reseed, isNot(contains(publish)), reason: publish);
      expect(caller, isNot(contains(publish)), reason: publish);
      expect(fetch, isNot(contains(publish)), reason: publish);
    }
  });
}
