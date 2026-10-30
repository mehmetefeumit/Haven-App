// Static guards for the HELD-send wiring.
//
// ## Why a source scan, and what it is NOT for
//
// The behaviour — that a held seal sends nothing, records no delivery and
// reaches `recordDeferredSend` — is proved by execution in
// `test/services/location_sharing_service_test.dart`,
// `test/providers/location_publish_scheduler_provider_test.dart` and
// `test/services/background_location_task_publish_cycle_test.dart`; what a
// seal stages is driven in Rust (`haven-core/tests/fanout_end_e2e.rs`
// `a_send_never_leaves_an_eviction_staged_beside_a_commit_a_relay_may_hold`).
//
// What no Dart test can observe is HOW the Rust side decided a send was
// deferred — whether it matched the error VARIANT or sniffed the error prose.
// That distinction is a security property, not a style preference: Haven's
// error strings interpolate remote-authored text (a relay URL, a
// peer-supplied component), so a `contains` over them hands a remote party a
// channel into a local control decision. It is pinned here, on the seal every
// location send takes (`seal_location_driven`, answered through
// `SealOutcomeFfi::answer`).
//
// Matches IDENTIFIERS on whitespace-normalized code with comments stripped, so
// neither a comment rewrite nor a reformat can satisfy or break an assertion.
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String relativePath) {
  final file = File(relativePath);
  if (!file.existsSync()) {
    fail(
      'expected source file not found: $relativePath (has it moved? this test '
      'pins the deferred-send routing to its call sites)',
    );
  }
  return file.readAsStringSync();
}

/// Strips `//` comments — whole-line AND trailing — then collapses every
/// whitespace run to one space, so an assertion sees syntax rather than layout.
String _code(String source) => source
    .split('\n')
    .map((line) {
      if (line.trimLeft().startsWith('//')) return '';
      final marker = line.indexOf('//');
      return marker == -1 ? line : line.substring(0, marker);
    })
    .join('\n')
    .replaceAll(RegExp(r'\s+'), ' ');

void main() {
  group('the FFI classifies a deferral by VARIANT, never by prose', () {
    final api = _code(_read('rust_builder/src/api.rs'));

    test('the seal matches a deferral and each refusal structurally', () {
      expect(
        api,
        contains('S::Deferred(held_by) => (None, Some(held_by.into())),'),
        reason:
            'the deferral must be recognised by destructuring the Rust '
            'enum variant. If this match is gone, either the outcome is being '
            'flattened to a string again (the original defect) or it is being '
            'sniffed out of one (worse).',
      );
      expect(
        api,
        contains(
          'fn refusal_of(error: &haven_core::circle::CircleError) '
          '-> Option<RefusalFfi>',
        ),
      );
      for (final arm in const [
        'E::EngineHeld => Some(RefusalFfi::EngineHeld),',
        'E::ForegroundOnly => Some(RefusalFfi::ForegroundOnly),',
        'E::LeaveInProgress => Some(RefusalFfi::LeaveInProgress),',
        'E::RoutingCollision => Some(RefusalFfi::RoutingCollision),',
      ]) {
        expect(api, contains(arm), reason: 'a refusal is matched by variant');
      }
      expect(
        api,
        contains('Err(error) => refusal_of(&error).map_or_else('),
        reason: "the seal's error is classified through refusal_of",
      );
    });

    test('no publish-path code classifies an error by its text', () {
      // Scoped to the FFI file because that is where the flattening happens.
      // `to_string()` itself is fine and unavoidable at the boundary; what is
      // forbidden is TESTING the resulting text.
      for (final forbidden in const [
        'to_string().contains',
        'e.to_string().starts_with',
        '.to_string().find(',
      ]) {
        expect(
          api,
          isNot(contains(forbidden)),
          reason:
              'classifying an error by its rendered text is a control '
              'channel for whoever supplied the interpolated part of it '
              '(see nostr::mls::storage::is_session_live)',
        );
      }
    });

    test('the deferred outcome says what holds it, and no staged commit '
        'crosses the boundary', () {
      // A staged commit is recorded and driven inside Rust in the call that
      // staged it (Security Rule 13); one handed to Dart instead could be
      // dropped there, leaving the group in `PendingPublish`.
      final sealAt = api.indexOf('pub struct SealOutcomeFfi {');
      expect(sealAt, greaterThan(-1), reason: 'the seal outcome moved');
      expect(
        api.substring(sealAt, api.indexOf(' }', sealAt)),
        contains('pub held_by: Option<SendHeldFfi>,'),
      );
      expect(api, contains('pub enum SendHeldFfi {'));
      expect(api, isNot(contains('CommitToPublishFfi')));
    });
  });

  group('every publish site routes a deferral', () {
    test('the per-circle scheduler records it as a deferral', () {
      final code = _code(
        _read('lib/src/providers/location_publish_scheduler_provider.dart'),
      );
      expect(code, contains('case LocationPublishDeferred('));
      expect(code, contains('_recordDeferredSend(circle)'));
      expect(code, contains('recordDeferredSend('));
    });

    test('the burst publisher records it as a deferral', () {
      final code = _code(
        _read('lib/src/providers/location_sharing_provider.dart'),
      );
      expect(code, contains('LocationPublishDeferred'));
      expect(code, contains('_recordDeferredSend(ref, circle)'));
    });

    test('the foreground service sends nothing and stamps no ack for a held '
        'seal', () {
      final code = _code(
        _read('lib/src/services/background_location_task.dart'),
      );
      final heldAt = code.indexOf(
        'final sealed = seal.sealed; if (sealed == null) {',
      );
      final sendAt = code.indexOf('await _relayService!.publishLocation(');
      final ackAt = code.indexOf('await _circleManager!.notePublishAcked(');
      expect(heldAt, greaterThan(-1), reason: 'the hold must be narrowed');
      expect(sendAt, greaterThan(heldAt));
      expect(ackAt, greaterThan(sendAt));
      expect(
        code.substring(heldAt, sendAt),
        contains('continue;'),
        reason: 'a held cycle must leave the loop iteration before the send '
            'and the ack stamp — nothing was delivered (Security Rule 13)',
      );
    });
  });
}
