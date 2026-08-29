// Static guards for the sharing-health recording sites.
//
// ## What is and is not pinned here
//
// The BEHAVIOUR — that an unacked publish is never stamped as delivered, and
// that a decrypted peer location is stamped on the receipt clock — is proved by
// execution in `test/services/location_sharing_health_recording_test.dart`,
// against the real service and a recording fake.
//
// What CANNOT be executed is the Android foreground service's publish cycle.
// `BackgroundLocationTaskHandler._publishCycle` drives `CircleManagerFfi`
// directly, so reaching it needs the Rust bridge and a live foreground service
// — the same reason the disclosure gate and the decorrelation wiring in that
// file are guarded this way
// (`test/lints/publish_decorrelation_wiring_test.dart`). And what a unit test
// cannot notice at all is a FOURTH publish site being added later without a
// recording, which is precisely how the pipeline became silent in the first
// place: three call sites each dropped their outcome into a `debugPrint`.
//
// So this file pins WIRING only, and it matches IDENTIFIERS on whitespace-
// normalized code with comments stripped — never prose — so neither a comment
// rewrite nor a reformat can satisfy it or break it.
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String relativePath) {
  final file = File(relativePath);
  if (!file.existsSync()) {
    fail(
      'expected source file not found: $relativePath (has it moved? this test '
      'pins a delivery-liveness invariant to its call site)',
    );
  }
  return file.readAsStringSync();
}

/// Strips `//` comments — whole-line AND trailing — then collapses every
/// whitespace run to one space, so an assertion sees syntax rather than layout.
///
/// Trailing comments matter: `foo(); // notePublishAcked here` would otherwise
/// satisfy a `contains` and let the real call be deleted. String literals are
/// left alone deliberately — none of the anchors below are string-shaped, and
/// a naive `//`-stripper that ignored quoting would mangle every URL in the
/// file and silently change what the assertions see.
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
  group('every publish site reports its outcome', () {
    test('the foreground per-circle scheduler records both verdicts', () {
      final code = _code(
        _read('lib/src/providers/location_publish_scheduler_provider.dart'),
      );

      expect(
        code,
        contains('acked: result.acceptedBy.isNotEmpty'),
        reason: 'the scheduler must classify the publish by what a relay kept, '
            'not by whether the call returned',
      );
      expect(
        code,
        contains('_recordPublishOutcome(circle, acked: false)'),
        reason: 'the catch used to end in a debugPrint and nowhere else',
      );
    });

    test('the one-shot publish burst records both verdicts', () {
      final code = _code(
        _read('lib/src/providers/location_sharing_provider.dart'),
      );

      expect(code, contains('acked: result.acceptedBy.isNotEmpty'));
      expect(code, contains('_recordPublishOutcome(ref, circle, acked: false)'));
    });

    test('the background service stamps delivery only on a relay ACK', () {
      // The foreground service has no Riverpod container, so the persisted
      // stamp is the ONLY channel by which the health model learns that
      // background publishing still works — and an unguarded stamp there would
      // make a dead background plane read as healthy for as long as the service
      // kept trying.
      final code = _code(
        _read('lib/src/services/background_location_task.dart'),
      );

      expect(
        code,
        contains(
          'if (publishResult.acceptedBy.isNotEmpty) { '
          'await _circleManager!.notePublishAcked(',
        ),
        reason: 'the ACK guard must sit immediately around the stamp',
      );
      expect(
        'notePublishAcked'.allMatches(code).length,
        1,
        reason: 'a second, unguarded stamp anywhere in this file would defeat '
            'the guard above',
      );
    });

    test('the shared publish path stamps delivery only on a relay ACK', () {
      final code = _code(
        _read('lib/src/services/location_sharing_service.dart'),
      );

      expect(
        code,
        contains(
          'if (publishResult.acceptedBy.isNotEmpty) { '
          'await _healthService?.notePublishAcked(',
        ),
      );
      expect('notePublishAcked'.allMatches(code).length, 1);
    });
  });

  group('thresholds are DERIVED, not typed in', () {
    // A relation test (`kPublishSilenceThreshold == kLocationPublishMaxInterval
    // * 2`) cannot catch this on its own: it passes just as happily against a
    // literal `Duration(seconds: 336)`, because both sides are read from the
    // same compiled constants. The only thing that fails when someone inlines
    // a number is a scan of the DEFINITION.
    late String code;

    setUp(() {
      code = _code(_read('lib/src/providers/sharing_health_provider.dart'));
    });

    test('the retention mirror is computed from the cadence constants', () {
      expect(
        code,
        contains(
          'final Duration kLocationMessageRetention = Duration( seconds: '
          'kLocationPublishMaxInterval.inSeconds + 2 * '
          'kTtlNetworkBufferSeconds, );',
        ),
      );
    });

    test('the publish and receive thresholds are multiples of the cadence', () {
      expect(
        code,
        contains(
          'const Duration kSharingFaultConfirmationWindow = '
          'kLocationPublishMaxInterval;',
        ),
      );
      expect(
        code,
        contains(
          'final Duration kPublishSilenceThreshold = '
          'kLocationPublishMaxInterval * 2;',
        ),
      );
      expect(
        code,
        contains(
          'final Duration kReceiveSilenceThreshold = '
          'kLocationPublishMaxInterval * 2 + kLocationMessageRetention;',
        ),
      );
    });

    test('the tick cadence is the minimum publish interval', () {
      expect(
        code,
        contains(
          'const Duration kSharingHealthTick = kLocationPublishMinInterval;',
        ),
      );
    });

    test('no threshold is a bare Duration literal', () {
      // The regression this whole group exists for.
      final definitions = RegExp(
        '(?:const|final) Duration k(?:SharingFaultConfirmationWindow|'
        'PublishSilenceThreshold|ReceiveSilenceThreshold|SharingHealthTick|'
        'LocationMessageRetention) = ([^;]+);',
      ).allMatches(code).map((m) => m.group(1)!).toList();

      expect(definitions, hasLength(5), reason: 'all five must be found');
      for (final rhs in definitions) {
        expect(
          rhs,
          anyOf(
            contains('kLocationPublish'),
            contains('kTtlNetworkBufferSeconds'),
            contains('kLocationMessageRetention'),
          ),
          reason: 'a threshold defined without naming a cadence constant is a '
              'magic number: "$rhs"',
        );
      }
    });
  });

  group('the background service records BOTH planes', () {
    test('its LocationSharingService is built with a health recorder', () {
      // Without this the foreground service's peer receipts never reach
      // `circle_health`, and the foreground — whose cache pause() clears —
      // comes back to a stale persisted stamp and shows a "not receiving"
      // banner over a background session that was receiving perfectly.
      final code = _code(
        _read('lib/src/services/background_location_task.dart'),
      );

      expect(code, contains('healthService: NostrCircleHealthService('));
      // The factory must re-read the FIELD on every call. The reclaim path
      // closes and re-opens the manager, so anything that captures today's
      // handle — whether spelled as a one-line closure over it or hoisted into
      // a local before the constructor — is a disposed handle from the first
      // reclaim onwards, and every later health write silently fails.
      expect(
        code,
        isNot(contains('circleManagerFactory: () async => _circleManager!')),
        reason: 'a one-line closure over the current handle captures it',
      );
      expect(
        code,
        contains('final manager = _circleManager;'),
        reason: 'the read must happen INSIDE the closure body; a handle '
            'hoisted above the constructor is captured just as fatally',
      );
    });
  });

  group('the receive site reports arrivals', () {
    test('the single decrypt funnel stamps a peer event', () {
      // `_persistDecryptedLocation` is the one funnel every receive plane
      // reaches (poll fetch, evolution poll, live-sync stream) in BOTH
      // isolates. Stamping anywhere else would cover one plane and miss two.
      final code = _code(
        _read('lib/src/services/location_sharing_service.dart'),
      );

      expect(code, contains('await _healthService?.notePeerEvent('));
      expect(
        'notePeerEvent'.allMatches(code).length,
        1,
        reason: 'more than one stamp means the funnel was bypassed somewhere',
      );
    });
  });
}
