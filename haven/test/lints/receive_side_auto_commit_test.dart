/// Regression guard for the receive-side auto-commit contract (Rule 13).
///
/// A peer's `SelfRemove` (RFC 9420 §12.1.2) is a bare PROPOSAL. It only
/// becomes a removal once a remaining member publishes the commit their
/// engine stages for it. The Dark Matter engine owns publish-before-apply
/// for every SEND-side commit internally, but it cannot publish this one:
/// the Rust `CircleManagerFfi` holds no relay handle, so it hands the
/// commit back to the caller as `DecryptLocationOutcomeFfi.autoCommits`.
///
/// There are two Dart-visible ingest APIs and only one of them is safe on a
/// receive path:
///
///   * `decryptLocationCollectingCommits` — SURFACES the auto-commit for the
///     caller to publish, then confirm on a ≥1-relay ack.
///   * `decryptLocation` — a shim that ROLLS THE AUTO-COMMIT BACK. Safe only
///     where a `SelfRemove` can never arrive (e.g. a fixture that only ever
///     feeds admin-authored removal commits or location messages).
///
/// Picking the shim on a real receive path fails **silently and totally**:
/// no error, no result, no removal — the departing member simply stays in
/// everyone's roster forever. That is exactly what happened when the E2E
/// synthetic peer's drain used it; every leave scenario deadlocked and the
/// only symptom was a 60s convergence timeout, 20 minutes into an emulator
/// lane.
///
/// These scans are the cheap tripwire for that. The behavioural proof lives
/// in `haven-core/tests/circle_integration_test.rs`
/// (`peer_self_remove_surfaces_a_receive_side_auto_commit`), which pins both
/// APIs side by side on the same proposal.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Reads every `.dart` file under [root], skipping generated bindings.
Iterable<({String path, String src})> _dartSources(String root) sync* {
  final dir = Directory(root);
  if (!dir.existsSync()) return;
  for (final entity in dir.listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    if (entity.path.contains(
      '${Platform.pathSeparator}rust${Platform.pathSeparator}',
    )) {
      continue; // generated FFI bindings
    }
    yield (path: entity.path, src: entity.readAsStringSync());
  }
}

void main() {
  group('receive-side auto-commit (Rule 13)', () {
    test('the E2E synthetic peer drains via the commit-collecting API', () {
      // `synthetic_user.dart` is the stand-in for a real remaining member in
      // every multi-party E2E scenario, including all three leave paths
      // (non-admin leave, admin handoff, abandon). Its drain MUST use the
      // collecting API, or a peer's SelfRemove is discarded on arrival.
      final harness = File(
        'integration_test/e2e/_lib/synthetic_user.dart',
      );
      expect(
        harness.existsSync(),
        isTrue,
        reason:
            'the E2E synthetic-peer harness moved; update this guard to '
            'follow it rather than deleting it.',
      );
      final src = harness.readAsStringSync();

      // Scan for the CALL, not merely a mention: the file also documents the
      // contract in prose and defines the publish helper, so a substring
      // search for the safe name passes even after the drain is switched back
      // to the shim. `\bdecryptLocation\s*\(` matches the shim call and NOT
      // `decryptLocationCollectingCommits(` (the next char there is `C`).
      final shimCall = RegExp(r'\bdecryptLocation\s*\(');
      expect(
        shimCall.hasMatch(src),
        isFalse,
        reason:
            'the synthetic peer calls the rolling-back `decryptLocation` '
            'shim. It must ingest via `decryptLocationCollectingCommits`: '
            'the shim rolls back the eviction commit the engine stages for a '
            "peer's SelfRemove, so the leaver never leaves any roster and "
            'every leave scenario deadlocks with no error surfaced.',
      );
      expect(
        src.contains('decryptLocationCollectingCommits('),
        isTrue,
        reason:
            'the synthetic peer no longer calls '
            '`decryptLocationCollectingCommits` — a receive path that never '
            'collects auto-commits cannot converge a peer SelfRemove.',
      );

      // The publish-then-confirm half of the contract: surfacing the commit
      // and then not publishing it is just as broken as never surfacing it.
      for (final required in const [
        'publishAndAwaitOk',
        'confirmPublished',
        'publishFailed',
      ]) {
        expect(
          src.contains(required),
          isTrue,
          reason:
              'the synthetic peer surfaces receive-side auto-commits but no '
              'longer calls `$required`. Rule 13 needs the full dance: '
              'publish once, confirm on a ≥1-relay ack, roll back otherwise '
              '— never confirm before an ack, never drop the pending ref.',
        );
      }
    });

    test('production receive paths never use the roll-back shim', () {
      // The foreground poll owns a relay handle and must publish the
      // auto-commit itself; live-sync and background catch-up publish it
      // in-Rust and therefore never surface one. No production path has a
      // legitimate reason to call the rolling-back shim.
      final offenders = <String>[];
      final callPattern = RegExp(r'\bdecryptLocation\s*\(');
      for (final file in _dartSources('lib')) {
        // The service interface declares both APIs, and the Nostr
        // implementation forwards both to the FFI; those declarations are
        // the definitions, not receive-path call sites.
        if (file.path.endsWith('circle_service.dart') ||
            file.path.endsWith('nostr_circle_service.dart')) {
          continue;
        }
        if (callPattern.hasMatch(file.src)) {
          offenders.add(file.path);
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'these production files call the rolling-back `decryptLocation` '
            'shim on what looks like a receive path: $offenders. Use '
            '`decryptLocationCollectingCommits` and publish + confirm each '
            'surfaced auto-commit (see '
            'LocationSharingService._publishAutoCommits).',
      );
    });
  });
}
