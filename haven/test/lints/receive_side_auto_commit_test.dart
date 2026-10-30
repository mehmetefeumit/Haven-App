/// Regression guard for the receive-side auto-commit contract (Rule 13).
///
/// A peer's `SelfRemove` (RFC 9420 §12.1.2) is a bare PROPOSAL. It only
/// becomes a removal once a remaining member publishes the commit their
/// engine stages for it. Every receive path — the app's polls and the E2E
/// synthetic peer alike — ingests through the fanout driver
/// (`ingest_driven`), which records and drives that auto-commit in Rust.
///
/// The older ingest calls are retired: one rolled the auto-commit back, and
/// picking it on a real receive path failed **silently and totally** — no
/// error, no removal, the departing member in everyone's roster forever.
/// That is exactly what happened when the E2E synthetic peer's drain used
/// it; every leave scenario deadlocked and the only symptom was a 60s
/// convergence timeout, 20 minutes into an emulator lane.
///
/// These scans are the cheap tripwire for that. The behavioural proof lives
/// in `haven-core/tests/circle_integration_test.rs`, in the test whose name
/// begins `peer_self_remove_is_made_by_a_driving_plane`: it pins a plane that
/// makes the commit and one that makes none side by side on the same proposal.
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
    test('the E2E synthetic peer ingests through the fanout driver', () {
      // `synthetic_user.dart` is the stand-in for a real remaining member in
      // every multi-party E2E scenario, including all three leave paths
      // (non-admin leave, admin handoff, abandon). Its drain MUST ingest
      // through the driver, or a peer's SelfRemove is never committed.
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

      for (final retired in [
        RegExp(r'\bdecryptLocation\s*\('),
        RegExp(r'\bdecryptLocationCollectingCommits\s*\('),
        RegExp(r'\bconfirmPublished\s*\('),
      ]) {
        expect(
          retired.hasMatch(src),
          isFalse,
          reason: 'the synthetic peer calls a retired ingest or confirm '
              '(${retired.pattern}): a receive-side auto-commit must be '
              'recorded and driven in Rust, never handled in Dart.',
        );
      }
      expect(src, contains('ingestForTest('));
      expect(
        File('integration_test/e2e/_lib/driven_location.dart')
            .readAsStringSync(),
        contains('.ingestDriven('),
        reason: "the synthetic peer's ingest goes through the driver",
      );
    });

    test('production receive paths ingest through the fanout driver', () {
      // Both polls hand a received kind-445 to the driver's ingest, which
      // records and drives a receive-side auto-commit in Rust
      // (`haven-core/tests/poll_send_drive_e2e.rs`, the test whose name
      // begins `a_removal_owed_after_a_departure_is_published_promptly`).
      // A Dart receive path that collected the commit itself would run it
      // outside any record again.
      final collecting = <String>[];
      for (final file in _dartSources('lib')) {
        if (file.src.contains('decryptLocationCollectingCommits(')) {
          collecting.add(file.path);
        }
      }
      expect(collecting, isEmpty);
      final sharing = File(
        'lib/src/services/location_sharing_service.dart',
      ).readAsStringSync();
      expect(
        RegExp(r'\.ingestEvent\(').allMatches(sharing),
        hasLength(2),
        reason: 'the location poll and the evolution poll each ingest '
            'through the driver',
      );
    });

    test('production receive paths never use the roll-back shim', () {
      // Every plane makes a receive-side auto-commit in Rust: the polls
      // through the driver's ingest, live-sync and background catch-up in
      // their own planes. No production path has a legitimate reason to call
      // the rolling-back shim.
      final offenders = <String>[];
      final callPattern = RegExp(r'\bdecryptLocation\s*\(');
      for (final file in _dartSources('lib')) {
        if (callPattern.hasMatch(file.src)) {
          offenders.add(file.path);
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'these production files call the rolling-back `decryptLocation` '
            'shim on what looks like a receive path: $offenders. Ingest '
            'through the fanout driver (`CircleService.ingestEvent`).',
      );
    });
  });
}
