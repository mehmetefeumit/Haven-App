/// Tests for the background publish path's location-disclosure gate.
///
/// ## Why this exists
///
/// The foreground publisher has always refused to publish without the accepted
/// foreground disclosure (`location_publish_scheduler_provider.dart`, the
/// `kLocationDisclosureAcceptedKey` check in `_publishCircle`). The background
/// isolate enforced **nothing** — `kLocationDisclosureAcceptedKey` appeared
/// nowhere in `background_location_task.dart` — so background publishing was
/// strictly weaker than foreground publishing on the one consent gate Google
/// Play's "disclosure before collection" rule requires.
///
/// That asymmetry was invisible only because the background isolate could not
/// publish at all (`docs/CI_HARDENING_BACKLOG.md` P0-1: its
/// `CircleManagerFfi.newInstance` fails closed against the foreground's Rule-14
/// guard). It would have become live the moment P0-1 was fixed. The gate
/// therefore landed BEFORE the P0-1 architectural work, and these tests exist
/// so it cannot quietly regress while that work is in flight.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/services/background_location_task.dart';

void main() {
  group('backgroundPublishDisclosureAccepted', () {
    test('permits publishing only when BOTH disclosures are accepted', () {
      expect(
        backgroundPublishDisclosureAccepted(
          foregroundAccepted: true,
          backgroundAccepted: true,
        ),
        isTrue,
      );
    });

    test('refuses when the BACKGROUND disclosure is missing', () {
      // The stricter half: the background disclosure is the one carrying the
      // "even when the app is closed or not in use" sentence, which is exactly
      // what the foreground service does. Accepting only the foreground
      // disclosure must not authorise it.
      expect(
        backgroundPublishDisclosureAccepted(
          foregroundAccepted: true,
          backgroundAccepted: false,
        ),
        isFalse,
      );
    });

    test('refuses when the FOREGROUND disclosure is missing', () {
      expect(
        backgroundPublishDisclosureAccepted(
          foregroundAccepted: false,
          backgroundAccepted: true,
        ),
        isFalse,
      );
    });

    // THE security property. `SharedPreferences.getBool` returns null for a key
    // that was never written — a fresh install, a wiped profile, or a key
    // renamed by a future migration. Treating null as permission would let
    // exactly those cases publish location with no disclosure ever shown.
    for (final (name, fg, bg) in const <(String, bool?, bool?)>[
      ('both null', null, null),
      ('background null', true, null),
      ('foreground null', null, true),
      ('background null, foreground false', false, null),
    ]) {
      test('refuses when a flag was never written ($name)', () {
        expect(
          backgroundPublishDisclosureAccepted(
            foregroundAccepted: fg,
            backgroundAccepted: bg,
          ),
          isFalse,
          reason: 'a missing disclosure flag must be a REFUSAL, never a '
              'default-allow — otherwise a fresh or migrated profile publishes '
              'location with no disclosure shown',
        );
      });
    }
  });

  group('the gate is actually reached', () {
    // A correct predicate that nothing calls is the failure mode this repo has
    // hit repeatedly (see the "recurring failure mode" section of
    // docs/CI_HARDENING_BACKLOG.md — six cases of code that looked complete,
    // passed review, and executed nowhere). The predicate above is only worth
    // anything if the publish cycle consults it, so pin that here rather than
    // trusting review.
    late final String source;

    setUpAll(() {
      source = _readSource('lib/src/services/background_location_task.dart');
    });

    test('the background publish cycle consults the disclosure gate', () {
      // `contains` alone is VACUOUS here: the declaration is
      // `bool backgroundPublishDisclosureAccepted({`, which contains the same
      // substring. Deleting the call site would leave such a test green — the
      // precise failure this group exists to prevent. Require the declaration
      // AND at least one further occurrence.
      const gate = 'backgroundPublishDisclosureAccepted(';
      expect(
        gate.allMatches(source).length,
        greaterThanOrEqualTo(2),
        reason: 'only the declaration was found — nothing CALLS the gate',
      );
      expect(
        source.contains('if (!$gate'),
        isTrue,
        reason: 'the gate must be consulted as a refusal branch',
      );
    });

    test('the cycle reads both disclosure keys', () {
      expect(source, contains('kLocationDisclosureAcceptedKey'));
      expect(source, contains('kLocationDisclosureBackgroundAcceptedKey'));
    });

    test('the gate precedes location COLLECTION, not just publication', () {
      // Anchor on the CALL, never `indexOf` of the bare name — that returns the
      // declaration's index and would still precede everything even with the
      // call deleted.
      final gateAt = source.indexOf(
        'if (!backgroundPublishDisclosureAccepted(',
      );
      final collectAt = source.indexOf('getCurrentLocation(');
      final encryptAt = source.indexOf('encryptLocation(');

      expect(gateAt, greaterThan(0), reason: 'no call-site form found');
      expect(collectAt, greaterThan(0));
      expect(encryptAt, greaterThan(0));

      // "Disclosure before COLLECTION" is the actual Play rule, and collection
      // is the GPS read — which happens before the encrypt. Pinning only the
      // encrypt would leave a gate that reads the user's position first.
      expect(
        gateAt,
        lessThan(collectAt),
        reason: 'the gate must run BEFORE the GPS fix is acquired',
      );
      expect(gateAt, lessThan(encryptAt));
    });

    test('the foreground publisher still enforces its own gate', () {
      // Guards against "fixing" a future divergence by deleting the foreground
      // check instead of aligning the two.
      final foreground = _readSource(
        'lib/src/providers/location_publish_scheduler_provider.dart',
      );
      // The IDENTIFIER, not the constant's value — the source references the
      // symbol, and asserting on `kLocationDisclosureAcceptedKey` here would
      // compare against its expansion ('haven.location.disclosure_accepted').
      expect(foreground, contains('kLocationDisclosureAcceptedKey'));
    });
  });
}

/// Reads a repo-relative source file.
///
/// `flutter test` runs with the package root as the working directory, so a
/// package-relative path resolves without any path-provider plumbing.
String _readSource(String relativePath) {
  final file = File(relativePath);
  if (!file.existsSync()) {
    fail(
      'expected source file not found: $relativePath (has it moved? this test '
      'pins a security invariant to its call site)',
    );
  }
  return file.readAsStringSync();
}
