// Static guards for the DEFERRED-send wiring (Unit B).
//
// ## Why a source scan, and what it is NOT for
//
// The behaviour — that a staged commit goes through the Rule-13 ladder, that a
// deferral records no delivery, that it reaches `recordDeferredSend` — is
// proved by execution in
// `test/services/location_sharing_deferred_send_test.dart` and
// `test/providers/location_publish_scheduler_provider_test.dart`.
//
// Two things cannot be executed here. The Android foreground service's publish
// cycle drives `CircleManagerFfi` directly, so reaching it needs the Rust
// bridge and a live service (the same reason
// `test/lints/sharing_health_recording_sites_test.dart` exists). And no Dart
// test can observe HOW the Rust side decided a send was deferred — whether it
// matched the error VARIANT or sniffed the error prose. That distinction is a
// security property, not a style preference: Haven's error strings interpolate
// remote-authored text (a relay URL, a peer-supplied component), so a
// `contains` over them hands a remote party a channel into a local control
// decision. It is pinned here.
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

    test('encrypt_location matches CircleError::SendDeferred structurally', () {
      expect(
        api,
        contains('Err(haven_core::circle::CircleError::SendDeferred {'),
        reason:
            'the deferral must be recognised by destructuring the Rust '
            'enum variant. If this match is gone, either the outcome is being '
            'flattened to a string again (the original defect) or it is being '
            'sniffed out of one (worse).',
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

    test('the deferred outcome carries the staged work across the boundary', () {
      // A `DeferredSendFfi` with no `commits` would silently drop every staged
      // eviction commit — the group would sit in `PendingPublish` and stop
      // sending altogether.
      expect(api, contains('pub commits: Vec<CommitToPublishFfi>'));
      expect(api, contains('pub proposals: Vec<String>'));
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

    test(
      'the foreground service resolves staged commits and stamps no ack',
      () {
        final code = _code(
          _read('lib/src/services/background_location_task.dart'),
        );
        // The FGS has no Riverpod container, so its only obligations are the
        // Rule-13 ladder and NOT stamping a delivery that never happened.
        expect(
          code,
          contains('final deferred = outcome.deferredSend;'),
          reason: 'the FGS must narrow the deferral before touching the event',
        );
        expect(
          code,
          contains('await _resolveDeferredCommits(circle, deferred);'),
          reason:
              'a staged eviction commit the FGS drops pins the group in '
              'PendingPublish, which stops sending entirely',
        );
        // The ack stamp must remain reachable ONLY from the sent path. The
        // deferral branch `continue`s before it.
        final deferralAt = code.indexOf(
          'final deferred = outcome.deferredSend;',
        );
        final ackAt = code.indexOf('await _circleManager!.notePublishAcked(');
        expect(deferralAt, greaterThan(-1));
        expect(
          ackAt,
          greaterThan(deferralAt),
          reason:
              'the deferral branch must be evaluated BEFORE the ack '
              'stamp, and exit before reaching it',
        );
        expect(
          code.substring(deferralAt, ackAt),
          contains('continue;'),
          reason:
              'a deferred cycle must leave the loop iteration before the '
              'ack stamp — nothing was delivered (Security Rule 13)',
        );
      },
    );

    test('the FGS ladder is registered as commit-critical work', () {
      // MAJOR-2. Publishing a staged commit and confirming it are two FFI
      // round trips; a teardown that lands between them leaves a commit that
      // is neither confirmed nor rolled back while possibly already on a
      // relay. `_inFlightCommitCritical` is what makes `onDestroy` WAIT for
      // this, and deleting the assignment is invisible to every behavioural
      // test — the FGS cycle cannot be executed without the Rust bridge and a
      // live service — so the registration is pinned here.
      final code = _code(
        _read('lib/src/services/background_location_task.dart'),
      );
      final ladderAt = code.indexOf(
        'Future<void> _resolveDeferredCommits( Circle circle, DeferredSendFfi '
        'deferred, ) async {',
      );
      expect(
        ladderAt,
        greaterThan(-1),
        reason:
            'the deferred-commit ladder was renamed or removed; update '
            'this guard rather than deleting it',
      );
      final innerAt = code.indexOf(
        'Future<void> _resolveDeferredCommitsInner(',
        ladderAt,
      );
      expect(innerAt, greaterThan(ladderAt));
      expect(
        code.substring(ladderAt, innerAt),
        contains('_inFlightCommitCritical = work;'),
        reason:
            'the ladder must register itself as commit-critical BEFORE it '
            'is awaited, or teardown can abandon it mid-Rule-13',
      );
      expect(
        code.substring(ladderAt, innerAt),
        contains('_inFlightCommitCritical = null;'),
        reason:
            'and must clear the registration, or a completed ladder would '
            'hold teardown open forever',
      );
    });

    test('the FGS publishes the proposals a deferral handed back', () {
      // MINOR-3. A bare proposal has no pending token, so nothing else in the
      // system notices it being dropped.
      final code = _code(
        _read('lib/src/services/background_location_task.dart'),
      );
      expect(
        code,
        contains('await _publishDeferredProposals(circle, deferred);'),
        reason:
            'the FGS must publish a deferral\'s proposals, as the '
            'foreground does',
      );
      final proposalsAt = code.indexOf(
        'Future<void> _publishDeferredProposals(',
      );
      expect(proposalsAt, greaterThan(-1));
      final body = code.substring(proposalsAt, proposalsAt + 900);
      expect(
        body,
        isNot(contains('confirmPublished')),
        reason:
            'a proposal carries no staged state — there is nothing to '
            'confirm',
      );
      expect(body, isNot(contains('publishFailed')));
    });

    test('the Rule-13 ladder in the FGS confirms only on an ack', () {
      final code = _code(
        _read('lib/src/services/background_location_task.dart'),
      );
      expect(code, contains('published = result.acceptedBy.isNotEmpty;'));
      expect(
        code,
        contains(
          'if (published) { await _circleManager!.confirmPublished(pending: '
          'commit.pending); } else { await _circleManager!.publishFailed('
          'pending: commit.pending); }',
        ),
        reason:
            'confirm on a >=1-relay ACK, roll back otherwise — never the '
            'other way round, and never neither',
      );
    });
  });
}
