/// Host-side proof that the C6 content canaries actually catch a leak.
///
/// The oracle itself only runs on a CI host over a journal that C1's recording
/// proxy wrote during a 12-minute E2E lane, so without these its matchers
/// would execute nowhere else — the classic place a rotted oracle hides. Every
/// group below therefore has BOTH directions:
///
///   * GREEN — a realistic clean journal. If this side ever fails, the oracle
///     is red on a clean tree, and a privacy guard that cries wolf is a guard
///     that gets deleted.
///   * RED — the same journal with the canary planted in one specific
///     encoding. If this side ever passes, that encoding has stopped being
///     covered and the oracle would stay green through the leak.
///
/// `everyCoveredEncodingIsLive` is the load-bearing one: it drives the RED
/// direction for **every term the expander produces**, so an encoding cannot
/// be added to the ledger without a proof that it fires, and cannot silently
/// stop matching. The hand-written groups after it pin the specific leak
/// SHAPES the repo already knows about — the truncated `g` geohash tag, a
/// struct hexed into a tag, a value smuggled through a REQ filter.
///
/// These run under plain `flutter test`: no Rust bridge, no relay, no device.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import '../../integration_test/e2e/_lib/wire_canaries.dart';

void main() {
  group('geohash encoder', () {
    // The oracle re-implements geohash in Dart because it runs on a host with
    // no Rust bridge. If that re-implementation drifts from the `geohash`
    // 0.13 crate `haven-core` depends on, the coordinate canary searches the
    // journal for a string the app would never emit — it would pass forever
    // while catching nothing. These vectors were produced by running the
    // crate itself through `haven_core::location::location_to_geohash`.
    test('geohashMatchesRustCrate', () {
      expect(geohashEncode(37.8324, 112.5584, 9), 'ww8p1r4t8');
      expect(geohashEncode(57.64911, 10.40744, 11), 'u4pruydqqvj');
      expect(geohashEncode(42.6, -5.6, 5), 'ezs42');
      expect(geohashEncode(0, 0, 5), 's0000');
      expect(geohashEncode(12.345678, 87.654321, 8), 'tfnq4x7y');
      expect(
        geohashEncode(kCanaryLatitude, kCanaryLongitude, 12),
        '1pt77jv1y92b',
      );
    });

    test('geohash prefixes are prefixes at every precision', () {
      final full = geohashEncode(kCanaryLatitude, kCanaryLongitude, 12);
      for (var n = 1; n <= 12; n++) {
        expect(
          geohashEncode(kCanaryLatitude, kCanaryLongitude, n),
          full.substring(0, n),
        );
      }
    });
  });

  group('base64 alignment', () {
    // A value embedded at an arbitrary byte offset inside a larger blob
    // encodes to three different character sequences depending on offset % 3.
    // Searching only the aligned form would miss two thirds of embedded
    // occurrences — which is most of them, because a leak inside a
    // serialized struct is never conveniently 3-byte aligned.
    test('alignedCoreSurvivesArbitraryEmbedding', () {
      final needle = utf8.encode('Qzvx CIRCLE ABCDEFGHJK');
      final cores = <String>[
        for (var shift = 0; shift < 3; shift++)
          base64AlignedCore(needle, shift: shift)!,
      ];
      for (var prefixLen = 0; prefixLen < 12; prefixLen++) {
        for (var suffixLen = 0; suffixLen < 5; suffixLen++) {
          final blob = <int>[
            ...List<int>.filled(prefixLen, 0x5a),
            ...needle,
            ...List<int>.filled(suffixLen, 0x39),
          ];
          final encoded = base64.encode(blob);
          expect(
            cores.any(encoded.contains),
            isTrue,
            reason:
                'no alignment matched for prefix=$prefixLen suffix=$suffixLen',
          );
        }
      }
    });

    test('alignment 0 alone would MISS two thirds of embeddings', () {
      // The negative half of the claim above: proof the extra two alignments
      // are load-bearing rather than decorative.
      final needle = utf8.encode('Qzvx CIRCLE ABCDEFGHJK');
      final aligned = base64AlignedCore(needle, shift: 0)!;
      var missed = 0;
      for (var prefixLen = 0; prefixLen < 12; prefixLen++) {
        final blob = <int>[
          ...List<int>.filled(prefixLen, 0x5a),
          ...needle,
        ];
        if (!base64.encode(blob).contains(aligned)) missed++;
      }
      expect(missed, greaterThanOrEqualTo(8));
    });

    test('too-short input yields no stable core rather than a bogus one', () {
      expect(base64AlignedCore(<int>[1, 2], shift: 2), isNull);
    });
  });

  group('term expansion ledger', () {
    test('every canary contributes at least one live term', () {
      final set = CanaryTermSet.expand(_manifest());
      for (final id in CanaryId.all) {
        expect(
          set.terms.where((t) => t.canaryId == id),
          isNotEmpty,
          reason: 'canary "$id" expanded to nothing — it is not being '
              'searched for at all',
        );
      }
    });

    // Pins the coordinate choice documented on [kCanaryLongitude]. A
    // coordinate whose geohash prefix were all-hex (e.g. `30943`, which
    // (-41.783206, -133.529471) produces) would be undetectable inside the
    // hex furniture that dominates a Nostr journal, and the geohash arm of
    // the coordinate canary would silently degrade to nothing. Anyone moving
    // the canary coordinate has to keep this true.
    test('canaryGeohashPrefixesSurviveHygiene', () {
      final set = CanaryTermSet.expand(_manifest());
      final live = set.terms
          .where((t) => t.encoding.startsWith('geohash'))
          .map((t) => t.encoding)
          .toSet();
      // Precision 5 is the one the live-but-unreachable builder in
      // haven-core/src/nostr/event.rs emits; it must be assertable at least
      // as a standalone field value. Precision 3 is a ~156 km cell and is
      // still a disclosure, so the token ladder has to reach it.
      expect(live, contains('geohash5/token'));
      expect(live, contains('geohash3/token'));
      // And precision 6 and up must survive as bare substrings, or a geohash
      // buried inside a longer token would be invisible.
      for (var n = 6; n <= 12; n++) {
        expect(
          live,
          contains('geohash$n/substring'),
          reason: 'geohash precision $n lost its substring coverage',
        );
      }
      // The gaps this canary's coordinate is allowed to have, named. Read
      // from the LEDGER rather than from the drop list: reading the drop list
      // would be reading the expander's own output back to itself, and the
      // whole point of the ledger is that the claim is written down
      // independently of what the expander happens to do.
      final declaredGaps = <String>{
        for (final claim in CanaryEncodingLedger.coordinate)
          if (claim.coverage == CanaryCoverage.gap) claim.encoding,
      };
      final geohashGaps = declaredGaps
          .where((e) => e.startsWith('geohash'))
          .toSet();
      expect(geohashGaps, <String>{
        'geohash1/token',
        'geohash2/token',
        'geohash1/substring',
        'geohash2/substring',
        'geohash3/substring',
        'geohash4/substring',
        'geohash5/substring',
      });
      // ...and the expander must actually agree with that claim.
      expect(CanaryEncodingLedger.reconcile(set), isEmpty);
    });

    test('aliases are recorded but not reported as coverage gaps', () {
      final set = CanaryTermSet.expand(_manifest());
      final aliases = set.dropped.where((d) => !d.isCoverageGap);
      expect(aliases, isNotEmpty);
      for (final a in aliases) {
        expect(a.reason, contains('identical'));
      }
    });

    test('hygiene rejects a term that would collide with hex furniture', () {
      // Not a canary term — a direct probe of the gate, so the floor values
      // themselves are pinned rather than inferred.
      expect(CanaryTermSet.minPureHexLength, 12);
      expect(CanaryTermSet.minAlnumLength, 6);
      expect(CanaryTermSet.minMixedLength, 5);
      expect(CanaryTermSet.minJsonTokenLength, 3);
    });

    // ---- the ledger is the independent half ------------------------------
    //
    // `everyCoveredEncodingIsLive` drives every term the expander produces,
    // so DELETING an encoding makes it pass with less work — the classic
    // shape of a check that measures its own input. `dropped` does not fix
    // that: it only records terms that were BUILT and then rejected, so an
    // encoding nobody enumerated is in neither list and is invisible to both.
    //
    // These four tests are the other term. The ledger is written by hand, it
    // is reconciled against the expander on every scan, and each direction of
    // the disagreement fails by name.

    test('theExpanderAndTheLedgerAgreeExactly', () {
      expect(
        CanaryEncodingLedger.reconcile(CanaryTermSet.expand(_manifest())),
        isEmpty,
        reason: 'the hand-declared coverage ledger and the term expander have '
            'diverged. Whichever is wrong, the oracle no longer covers what '
            'it claims to cover.',
      );
    });

    test('aLedgerDisagreementIsUNUSABLE', () {
      // Not a leak (nothing was found) and not a pass: an oracle whose
      // coverage claim is unverified has produced a verdict that carries no
      // information. Driven through a manifest whose canary is too short for
      // the expander to build the declared encodings from — the same shape a
      // deleted encoding produces, reached without editing the library.
      final degenerate = WireCanaryManifest(
        role: 'solo',
        circleDisplayName: 'ab',
        petname: 'cd',
        latitude: kCanaryLatitude,
        longitude: kCanaryLongitude,
        carrierEventIds: <String, List<String>>{
          for (final id in CanaryId.all) id: <String>[_circleCarrier],
        },
      );
      expect(
        CanaryEncodingLedger.reconcile(CanaryTermSet.expand(degenerate)),
        isNotEmpty,
      );
      final report = WireCanaryScanner.scan(
        journals: <WireJournal>[
          WireJournal.parse(_cleanJournalText(), path: 'clean'),
        ],
        manifests: <WireCanaryManifest>[degenerate],
      );
      expect(report.verdict, CanaryVerdict.unusable);
      expect(report.unusable.join('\n'), contains('ledger'));
    });

    test('theLedgerDeclaresEveryEncodingWithARealReason', () {
      // A stated gap with an empty or copy-pasted reason is the failure mode
      // this whole mechanism exists to prevent: it answers the question a
      // reviewer would otherwise ask, wrongly. Every non-covered claim has to
      // carry its own words.
      final all = <CanaryEncodingClaim>[
        ...CanaryEncodingLedger.stringValue,
        ...CanaryEncodingLedger.coordinate,
      ];
      expect(all, isNotEmpty);
      final reasons = <String>{};
      for (final claim in all) {
        expect(claim.encoding, isNotEmpty);
        expect(claim.reason.trim(), isNotEmpty, reason: claim.encoding);
        if (claim.coverage == CanaryCoverage.covered) continue;
        expect(
          claim.reason.length,
          greaterThan(40),
          reason: '${claim.encoding} is declared ${claim.coverage.name} with a '
              'reason too short to be one',
        );
        reasons.add(claim.reason);
      }
      // At least as many distinct reasons as there are reason FAMILIES; a
      // single reason pasted across every gap would collapse this.
      expect(reasons.length, greaterThanOrEqualTo(8));

      // No encoding may be declared twice, in either list — a duplicate is
      // how a claim gets "changed" while the old one keeps being satisfied.
      for (final list in <List<CanaryEncodingClaim>>[
        CanaryEncodingLedger.stringValue,
        CanaryEncodingLedger.coordinate,
      ]) {
        final names = list.map((c) => c.encoding).toList();
        expect(names.toSet(), hasLength(names.length));
      }
    });

    // ---- the declared gaps are REAL gaps ---------------------------------
    //
    // A stated boundary rots in one direction that nothing else catches:
    // somebody covers the encoding, and the ledger keeps saying it is out of
    // scope. Each probe below plants a canary in a declared-ABSENT encoding
    // and requires the oracle to report NO finding. If one of these ever goes
    // red, the boundary moved and the claim has to move with it.
    //
    // They are also the honest half of the F4/F5/F6/F7 answer: an unstated
    // gap and a falsely-stated one are both worse than an admitted one, so
    // every boundary is executable rather than prose.

    test('declaredAbsentEncodingsReallyAreAbsent', () {
      final manifest = _manifest();
      final name = manifest.circleDisplayName;
      final probes = <String, String>{
        // Truncation past the covered depth: fewer than 4 of the 10
        // random-token characters survive, so it would also match an earlier
        // run's plant.
        'utf8-drop7': name.substring(0, name.length - 7),
        // Composition depth 3 (hex of a hex dump).
        'utf8/hex-lower/hex-lower': bytesToHex(
          utf8.encode(bytesToHex(utf8.encode(name))),
        ),
        // hex OVER a re-encoded form.
        'percent-component/hex-lower': bytesToHex(
          utf8.encode(Uri.encodeComponent(name)),
        ),
        // An alternative base encoding.
        'utf8/base32': _base32(utf8.encode(name)),
        // Degrees / minutes / seconds.
        'coord/dms': _dms(kCanaryLatitude),
      };

      final failures = <String>[];
      var seq = 960;
      for (final entry in probes.entries) {
        final report = _scanWithExtra(
          _tagLine('x', entry.value, seq: seq++),
          manifest: manifest,
        );
        if (report.findings.isNotEmpty) failures.add(entry.key);
      }
      expect(
        failures,
        isEmpty,
        reason: 'these encodings are declared out of scope but the oracle now '
            'finds them. That is coverage the ledger is not claiming: move '
            'the claim to covered. ${failures.join(', ')}',
      );

      // Every probe above must name a claim that actually exists and is
      // actually declared absent, or the test is asserting about nothing.
      final absent = <String>{
        for (final c in <CanaryEncodingClaim>[
          ...CanaryEncodingLedger.stringValue,
          ...CanaryEncodingLedger.coordinate,
        ])
          if (c.coverage == CanaryCoverage.absent) c.encoding,
      };
      expect(absent, containsAll(probes.keys));
    });

    test('theGeohash13ClaimStatesTheRightReason', () {
      // `geohash13/token` is declared ABSENT, and its stated reason is not
      // "it would be invisible" but "every longer prefix contains the covered
      // ones". That reason is checkable, and checking it is the difference
      // between a boundary and an excuse: a 13-character geohash on the wire
      // must still be a LEAK, caught by the 12-character substring term.
      final gh13 = geohashEncode(kCanaryLatitude, kCanaryLongitude, 13);
      expect(gh13, hasLength(13));
      final report = _scanWithExtra(_tagLine('g', gh13, seq: 970));
      expect(report.verdict, CanaryVerdict.leak);
      expect(
        report.findings.map((f) => f.term.encoding),
        contains('geohash12/substring'),
      );
    });

    test('noLiveTermIsShapedLikeADigest', () {
      // The ledger declares `utf8/sha256-hex` out of scope. A digest is 64
      // hex characters, so the executable form of that claim is that nothing
      // this oracle searches for has that shape — which also catches the
      // accident of an encoding growing into one.
      final digestShaped = RegExp(r'^[0-9a-fA-F]{64}$');
      for (final term in CanaryTermSet.expand(_manifest()).terms) {
        expect(
          digestShaped.hasMatch(term.value),
          isFalse,
          reason: '${term.label} is digest-shaped',
        );
      }
    });

    test('anUnbuildableAlignmentIsRecordedAsAGapNotDropped', () {
      // The latent half of the same defect. `base64AlignedCore` returns null
      // when no whole group survives trimming, and the expander used to add
      // nothing at all — so the alignment vanished from `terms` AND from
      // `dropped`, which is the one state no check over those two lists can
      // see. A 4-byte f32 at alignment 1 is exactly that case.
      expect(
        base64AlignedCore(
          float32Bytes(kCanaryLatitude, Endian.little),
          shift: 1,
        ),
        isNull,
      );
      final set = CanaryTermSet.expand(_manifest());
      final gap = set.dropped.firstWhere(
        (d) => d.term.encoding == 'lat/f32-le/base64-align1',
        orElse: () => throw StateError(
          'lat/f32-le/base64-align1 is in neither terms nor dropped',
        ),
      );
      expect(gap.isCoverageGap, isTrue);
      expect(gap.reason, contains('no whole base64 group'));
    });

    test('theLedgerPinsEveryRungOfEveryLadder', () {
      // The F14 mutation, pinned by name rather than by count: narrowing the
      // decimal loop from `dp <= 8` to `dp <= 5` deletes four encodings, and
      // 7 dp is exactly what a `latE7 / 1e7` render produces. Same for the
      // geohash ladder, the three base64 alignments, and both endiannesses.
      final declared = <String>{
        for (final c in CanaryEncodingLedger.coordinate) c.encoding,
      };
      for (final axis in <String>['lat', 'lon']) {
        expect(declared, contains('$axis/decimal-full'));
        for (var dp = 0; dp <= 8; dp++) {
          expect(declared, contains('$axis/decimal-round$dp'));
          expect(declared, contains('$axis/decimal-trunc$dp'));
        }
        for (final endian in <String>['be', 'le']) {
          for (final width in <String>['f64', 'f32']) {
            for (final e in CanaryEncodingLedger.byteEncodings) {
              expect(declared, contains('$axis/$width-$endian/$e'));
            }
          }
        }
        expect(declared, contains('$axis/fixed-e6'));
        expect(declared, contains('$axis/fixed-e7'));
      }
      for (var n = 1; n <= 12; n++) {
        expect(declared, contains('geohash$n/token'));
        expect(declared, contains('geohash$n/substring'));
      }
      for (final order in <String>['latlon', 'lonlat']) {
        for (final endian in <String>['be', 'le']) {
          for (final e in CanaryEncodingLedger.byteEncodingsWithoutDebug) {
            expect(declared, contains('f32pair-$order-$endian/$e'));
          }
        }
      }

      final strings = <String>{
        for (final c in CanaryEncodingLedger.stringValue) c.encoding,
      };
      for (final e in CanaryEncodingLedger.byteEncodings) {
        expect(strings, contains('utf8/$e'));
      }
      for (var n = 1; n <= 6; n++) {
        expect(strings, contains('utf8-drop$n'));
      }
      for (final form in CanaryEncodingLedger.composedStringForms) {
        for (final e in CanaryEncodingLedger.base64Encodings) {
          expect(strings, contains('$form/$e'));
        }
      }
    });
  });

  group('per-encoding red/green matrix', () {
    // The load-bearing test. Every term the expander produces is planted, on
    // its own, into an otherwise-clean journal; the oracle must find exactly
    // that canary. An encoding that stopped matching — a hygiene floor raised
    // too far, an expander that returns the wrong string, a matcher that
    // handles the wrong TermMatch mode — fails here by name.
    test('everyCoveredEncodingIsLive', () {
      final manifest = _manifest();
      final set = CanaryTermSet.expand(manifest);
      expect(set.terms.length, greaterThan(50));

      // The clean half is parsed ONCE and handed to every scan as its own
      // journal; `scan` takes a list, and the carriers live in the clean half.
      // It is also the SHORT clean fixture: this test is a red/green matrix
      // over ~180 encodings, and re-scanning a full-size journal per encoding
      // costs minutes without testing anything the matrix is about. Scale is
      // proven once, by `largeRealisticJournalProducesNoFalsePositives`.
      final clean = WireJournal.parse(
        _cleanJournalText(lines: 6, contentChars: 120),
        path: 'clean',
      );
      final failures = <String>[];
      for (final term in set.terms) {
        final report = WireCanaryScanner.scan(
          journals: <WireJournal>[
            clean,
            WireJournal.parse(
              '${_plantLine(term)}\n',
              path: 'planted-${term.label}',
            ),
          ],
          manifests: <WireCanaryManifest>[manifest],
        );
        final hit = report.findings.any(
          (f) => f.term.encoding == term.encoding &&
              f.term.canaryId == term.canaryId,
        );
        if (!hit) failures.add(term.label);
      }
      expect(
        failures,
        isEmpty,
        reason: 'these encodings are advertised as covered but did NOT fire '
            'on a planted leak: ${failures.join(', ')}',
      );
    });

    // The two deterministic false-positive fixtures. The probabilistic one
    // above (a megabyte of random ciphertext) usually clears a matcher that
    // has quietly become too permissive; these two never do, because the
    // colliding text is planted rather than hoped for. They are what make
    // TermMatch.jsonToken and TermMatch.delimited load-bearing rather than
    // decorative: relax either to a plain substring and one of them goes red.

    test('shortGeohashInsideCiphertextIsNotAFalsePositive', () {
      // The 5-character geohash prefix, embedded inside a longer base64 run.
      // Every character of a geohash is also a base64 character, so this WILL
      // happen by chance in a long enough journal; asserting on it as a bare
      // substring is how a privacy guard turns into a flaky one. As a
      // complete JSON token it cannot happen at all — base64 has no quote.
      final gh5 = geohashEncode(kCanaryLatitude, kCanaryLongitude, 5);
      final gh4 = gh5.substring(0, 4);
      final report = _scanWithExtra(
        '{"wire_seq":920,"type":"frame","conn_id":"c1","ts_ms":1785886170000,'
        '"dir":"c2r",'
        '$_endpoint,"frame":["EVENT",{"id":"${'a' * 64}","kind":445,'
        '"pubkey":"${'8' * 64}","created_at":1785886170,'
        '"tags":[["h","${'e' * 64}"]],'
        '"content":"QUJDRUZH${gh5}KLMNOP${gh4}QRSTUV","sig":"${'f' * 128}"}],'
        '"raw_len":420}',
      );
      expect(
        report.findings.map((f) => f.term.label),
        isEmpty,
        reason: 'a geohash prefix matched inside ciphertext — the lane will '
            'flake red on runs that leaked nothing',
      );
      expect(report.verdict, CanaryVerdict.clean);
    });

    test('fixedPointDigitsInsideAHexIdAreNotAFalsePositive', () {
      // The E7 digit run buried inside a 64-character event id. Hex ids are
      // the single most common thing in a Nostr journal, so a bare digit-run
      // search would fire on them constantly.
      final e7 = (kCanaryLatitude.abs() * 10000000).round().toString();
      final id = 'a' * 20 + e7 + 'b' * (64 - 20 - e7.length);
      expect(id.length, 64);
      final report = _scanWithExtra(
        '{"wire_seq":921,"type":"frame","conn_id":"c1","ts_ms":1785886171000,'
        '"dir":"c2r",'
        '$_endpoint,"frame":["EVENT",{"id":"$id","kind":445,'
        '"pubkey":"${'8' * 64}","created_at":1785886171,'
        '"tags":[["h","${'e' * 64}"]],"content":"","sig":"${'f' * 128}"}],'
        '"raw_len":420}',
      );
      expect(
        report.findings.map((f) => f.term.label),
        isEmpty,
        reason: 'a fixed-point coordinate term matched inside an event id',
      );
      expect(report.verdict, CanaryVerdict.clean);
    });

    test('the same clean journal alone stays green', () {
      final manifest = _manifest();
      final report = WireCanaryScanner.scan(
        journals: <WireJournal>[
          WireJournal.parse(_cleanJournalText(), path: 'clean'),
        ],
        manifests: <WireCanaryManifest>[manifest],
      );
      expect(report.findings, isEmpty);
      expect(report.vacuities, isEmpty);
      expect(report.unusable, isEmpty);
      expect(report.verdict, CanaryVerdict.clean);
      expect(report.exitCode, 0);
    });

    // The false-positive control at scale. A megabyte of realistic Nostr
    // furniture — 64-char hex ids, pubkeys, 128-char signatures, long base64
    // ciphertexts, REQ filters, OK/EOSE frames — must produce zero findings.
    // Short low-entropy terms (the geohash prefixes) are exactly what would
    // fire here if the hygiene floors were wrong.
    test('largeRealisticJournalProducesNoFalsePositives', () {
      final manifest = _manifest();
      final report = WireCanaryScanner.scan(
        journals: <WireJournal>[
          WireJournal.parse(
            _cleanJournalText(lines: 1200, contentChars: 900),
            path: 'big-clean',
          ),
        ],
        manifests: <WireCanaryManifest>[manifest],
      );
      expect(
        report.findings.map((f) => f.term.label),
        isEmpty,
        reason: 'a term matched random ciphertext — its hygiene floor is too '
            'low and the lane will flake red on a clean run',
      );
    });
  });

  group('realistic leak shapes', () {
    // Each of these is a leak the repo could actually produce, planted in the
    // exact frame shape it would take.

    test('truncatedGeohashTagIsCaught', () {
      // haven-core/src/nostr/event.rs:220-227 is a live-but-unreachable
      // builder that pushes ["g", <geohash truncated to 5>] onto a kind-445.
      // C5.4 forbids the TAG NAME; this catches the VALUE, which is what
      // survives someone renaming the tag.
      final gh5 = geohashEncode(kCanaryLatitude, kCanaryLongitude, 5);
      final report = _scanWithExtra(
        '{"wire_seq":900,"type":"frame","conn_id":"c1","ts_ms":1785886150000,'
        '"dir":"c2r",'
        '$_endpoint,"frame":["EVENT",{"id":"${'7' * 64}","kind":445,'
        '"pubkey":"${'8' * 64}","created_at":1785886150,'
        '"tags":[["h","${'e' * 64}"],["g","$gh5"]],"content":"",'
        '"sig":"${'f' * 128}"}],"raw_len":420}',
      );
      expect(report.verdict, CanaryVerdict.leak);
      expect(
        report.findings.map((f) => f.term.encoding),
        contains('geohash5/token'),
      );
      expect(report.findings.first.term.canaryId, CanaryId.coordinate);
    });

    test('coordinateAsJsonFloatsInPlaintextContentIsCaught', () {
      final report = _scanWithExtra(
        '{"wire_seq":901,"type":"frame","conn_id":"c1","ts_ms":1785886151000,'
        '"dir":"c2r",'
        '$_endpoint,"frame":["EVENT",{"id":"${'6' * 64}","kind":445,'
        '"pubkey":"${'8' * 64}","created_at":1785886151,'
        '"tags":[["h","${'e' * 64}"]],'
        r'"content":"{\"lat\":-47.209318,\"lon\":-127.478205}",'
        '"sig":"${'f' * 128}"}],"raw_len":420}',
      );
      expect(report.verdict, CanaryVerdict.leak);
      expect(
        report.findings.map((f) => f.term.encoding),
        contains('lat/decimal-full'),
      );
    });

    test('coordinateAtReducedPrecisionIsCaught', () {
      // The shape a "privacy-preserving" rounding would produce. A naive
      // search for the exact decimal string would miss this entirely.
      final report = _scanWithExtra(
        '{"wire_seq":902,"type":"frame","conn_id":"c1","ts_ms":1785886152000,'
        '"dir":"c2r",'
        '$_endpoint,"frame":["EVENT",{"id":"${'5' * 64}","kind":445,'
        '"pubkey":"${'8' * 64}","created_at":1785886152,'
        '"tags":[["h","${'e' * 64}"],["approx","-47.2093,-127.4782"]],'
        '"content":"","sig":"${'f' * 128}"}],"raw_len":420}',
      );
      expect(report.verdict, CanaryVerdict.leak);
      expect(
        report.findings.map((f) => f.term.encoding),
        containsAll(<String>['lat/decimal-round4', 'lon/decimal-round4']),
      );
    });

    test('coordinateRoundedToFiveDecimalsIsCaught', () {
      // Rounding and truncation diverge at the fifth decimal place for this
      // coordinate (…20932 vs …20931). A term set that generated only one of
      // the two would miss whichever the leak used, so both are generated and
      // this fixture pins the rounded half specifically.
      expect(
        kCanaryLatitude.abs().toStringAsFixed(5),
        isNot(truncateDecimal(kCanaryLatitude.abs(), 5)),
      );
      final report = _scanWithExtra(
        '{"wire_seq":911,"type":"frame","conn_id":"c1","ts_ms":1785886164000,'
        '"dir":"c2r",'
        '$_endpoint,"frame":["EVENT",{"id":"${'a' * 62}77","kind":445,'
        '"pubkey":"${'8' * 64}","created_at":1785886164,'
        '"tags":[["h","${'e' * 64}"],'
        '["fuzz","${kCanaryLatitude.toStringAsFixed(5)}"]],'
        '"content":"","sig":"${'f' * 128}"}],"raw_len":420}',
      );
      expect(report.verdict, CanaryVerdict.leak);
      expect(
        report.findings.map((f) => f.term.encoding),
        contains('lat/decimal-round5'),
      );
    });

    test('coordinateAsFixedPointIntegerIsCaught', () {
      final report = _scanWithExtra(
        '{"wire_seq":903,"type":"frame","conn_id":"c1","ts_ms":1785886153000,'
        '"dir":"c2r",'
        '$_endpoint,"frame":["EVENT",{"id":"${'4' * 64}","kind":445,'
        '"pubkey":"${'8' * 64}","created_at":1785886153,'
        '"tags":[["h","${'e' * 64}"],["latE7","-472093180"]],'
        '"content":"","sig":"${'f' * 128}"}],"raw_len":420}',
      );
      expect(report.verdict, CanaryVerdict.leak);
      expect(
        report.findings.map((f) => f.term.encoding),
        contains('lat/fixed-e7'),
      );
    });

    test('structHexedIntoATagIsCaught', () {
      // A `bincode`/`postcard` dump of a struct holding an f64 pair, hexed
      // into a tag. No structural oracle would object: the tag name is new,
      // the value is opaque hex, and the shape is indistinguishable from an
      // id.
      final lat = bytesToHex(float64Bytes(kCanaryLatitude, Endian.little));
      final lon = bytesToHex(float64Bytes(kCanaryLongitude, Endian.little));
      final report = _scanWithExtra(
        '{"wire_seq":904,"type":"frame","conn_id":"c1","ts_ms":1785886154000,'
        '"dir":"c2r",'
        '$_endpoint,"frame":["EVENT",{"id":"${'3' * 64}","kind":445,'
        '"pubkey":"${'8' * 64}","created_at":1785886154,'
        '"tags":[["h","${'e' * 64}"],["fix","0a$lat$lon"]],'
        '"content":"","sig":"${'f' * 128}"}],"raw_len":460}',
      );
      expect(report.verdict, CanaryVerdict.leak);
      expect(
        report.findings.map((f) => f.term.encoding),
        containsAll(<String>['lat/f64-le/hex-lower', 'lon/f64-le/hex-lower']),
      );
    });

    test('circleNameBase64dIntoAnUnalignedBlobIsCaught', () {
      // The canary sits at byte offset 7 of a longer buffer, so it is NOT
      // 3-byte aligned. Only the alignment-1 term can see it.
      final manifest = _manifest();
      final blob = <int>[
        ...utf8.encode('HDR:v1|'),
        ...utf8.encode(manifest.circleDisplayName),
        ...utf8.encode('|end'),
      ];
      final report = _scanWithExtra(
        '{"wire_seq":905,"type":"frame","conn_id":"c1","ts_ms":1785886155000,'
        '"dir":"c2r",'
        '$_endpoint,"frame":["EVENT",{"id":"${'2' * 64}","kind":445,'
        '"pubkey":"${'8' * 64}","created_at":1785886155,'
        '"tags":[["h","${'e' * 64}"]],"content":"${base64.encode(blob)}",'
        '"sig":"${'f' * 128}"}],"raw_len":500}',
        manifest: manifest,
      );
      expect(report.verdict, CanaryVerdict.leak);
      expect(report.findings.first.term.canaryId, CanaryId.circleDisplayName);
      expect(
        report.findings.map((f) => f.term.encoding),
        contains('utf8/base64-align1'),
      );
    });

    test('petnameInsideAReqFilterIsCaught', () {
      // The petname is local-only by design, so ANY occurrence is a defect
      // and there is no legitimate case to carve out. A REQ is the shape C5.2
      // warns about — the same information as a banned event, in a frame type
      // an event-kind allow-list never looks at.
      final manifest = _manifest();
      final report = _scanWithExtra(
        '{"wire_seq":906,"type":"frame","conn_id":"c2","ts_ms":1785886156000,'
        '"dir":"c2r",'
        '$_endpoint,"frame":["REQ","sub7",{"kinds":[0],'
        '"search":"${manifest.petname}"}],"raw_len":180}',
        manifest: manifest,
      );
      expect(report.verdict, CanaryVerdict.leak);
      expect(report.findings.first.term.canaryId, CanaryId.petname);
      expect(report.findings.first.refs.first.verb, 'REQ');
    });

    test('percentEncodedCanaryInAUrlIsCaught', () {
      final manifest = _manifest();
      final report = _scanWithExtra(
        '{"wire_seq":907,"type":"frame","conn_id":"c1","ts_ms":1785886157000,'
        '"dir":"c2r",'
        '$_endpoint,"frame":["EVENT",{"id":"${'1' * 64}","kind":0,'
        '"pubkey":"${'8' * 64}","created_at":1785886157,"tags":[],'
        r'"content":"{\"about\":\"https://x.example/?c='
        '${Uri.encodeComponent(manifest.circleDisplayName)}'
        r'\"}",'
        '"sig":"${'f' * 128}"}],"raw_len":320}',
        manifest: manifest,
      );
      expect(report.verdict, CanaryVerdict.leak);
      expect(
        report.findings.map((f) => f.term.encoding),
        contains('percent-component'),
      );
    });

    test('unicodeEscapedCanaryInALineThatIsNotJsonIsCaught', () {
      // The one case the decoded-string pass cannot reach at all: a journal
      // line that is not JSON, so there is nothing to decode. Here it is the
      // half-flushed final record of a proxy that was still writing — the
      // shape the contract explicitly says never to drop. Only the
      // json-unicode-escape TERM can see into it, which is why that term
      // survives even though `jsonDecode` makes it redundant everywhere else.
      final manifest = _manifest();
      final partial =
          '{"wire_seq":908,"type":"frame","conn_id":"c1",'
          '"dir":"c2r",$_endpoint,"frame":["EVENT",'
          '{"note":"${jsonUnicodeEscape(manifest.petname)}';
      final report = WireCanaryScanner.scan(
        journals: <WireJournal>[
          WireJournal.parse('${_cleanJournalText()}$partial', path: 'j'),
        ],
        manifests: <WireCanaryManifest>[manifest],
      );
      expect(report.verdict, CanaryVerdict.leak);
      expect(
        report.findings.map((f) => f.term.encoding),
        contains('json-unicode-escape'),
      );
      // The literal term cannot see it — that is the whole point of keeping
      // the escaped variant.
      expect(
        report.findings.map((f) => f.term.encoding),
        isNot(contains('utf8-literal')),
      );
    });

    test('escapedCanaryInAnUnparseableFramePreviewIsCaughtDecoded', () {
      // A frame the proxy could not parse but recorded WHOLE in
      // `raw_preview`. `raw_len` equals the preview length, so the line is
      // fully visible and is not a blind spot; the preview is decoded like
      // any other string, so the plain literal term sees the canary however
      // the proxy's serialiser chose to escape it.
      final manifest = _manifest();
      final escaped = jsonUnicodeEscape(manifest.petname);
      final decodedLength = '["EVENT",{"note":"${manifest.petname}"'.length;
      final line =
          '{"wire_seq":909,"type":"frame","conn_id":"c1","ts_ms":1785886158000,'
          '"dir":"c2r",'
          '$_endpoint,"frame":null,'
          r'"raw_preview":"[\"EVENT\",{\"note\":\"' '$escaped' r'\"",'
          '"raw_len":$decodedLength}';
      final report = _scanWithExtra(line, manifest: manifest);
      expect(report.verdict, CanaryVerdict.leak);
      expect(report.findings.first.term.canaryId, CanaryId.petname);
      expect(
        report.findings.map((f) => f.term.encoding),
        contains('utf8-literal'),
      );
    });

    test('caseFoldedCanaryIsCaught', () {
      final manifest = _manifest();
      final report = _scanWithExtra(
        '{"wire_seq":910,"type":"frame","conn_id":"c1","ts_ms":1785886159000,'
        '"dir":"c2r",'
        '$_endpoint,"frame":["EVENT",{"id":"${'0' * 64}","kind":445,'
        '"pubkey":"${'8' * 64}","created_at":1785886159,'
        '"tags":[["h","${'e' * 64}"],'
        '["slug","${manifest.circleDisplayName.toLowerCase()}"]],'
        '"content":"","sig":"${'f' * 128}"}],"raw_len":420}',
        manifest: manifest,
      );
      expect(report.verdict, CanaryVerdict.leak);
      expect(
        report.findings.map((f) => f.term.encoding),
        contains('utf8-casefold'),
      );
    });

    // ---- coverage the ledger used to claim, or hide, without holding ------
    //
    // Each of these was a journal that verdicted CLEAN before the encoding
    // behind it was covered. They are the probes that found the gaps, kept as
    // the tests for them: a leak in this shape has to be a leak.

    test('coarseGeohashTagIsCaught', () {
      // The prefix loop used to start at length 4. `["g","1pt"]` is a ~156 km
      // cell — the idiomatic shape of a location leak in Nostr, and one that
      // three characters of JSON token can assert on safely because a `"`
      // cannot occur inside base64 or hex.
      final gh3 = geohashEncode(kCanaryLatitude, kCanaryLongitude, 3);
      expect(gh3, hasLength(3));
      final report = _scanWithExtra(_tagLine('g', gh3));
      expect(report.verdict, CanaryVerdict.leak);
      expect(
        report.findings.map((f) => f.term.encoding),
        contains('geohash3/token'),
      );
    });

    test('coarseDecimalCoordinateIsCaught', () {
      // The ladder used to start at 4 dp, and the ledger's stated reason for
      // the omission was false: `47.209` is 6 mixed characters against a
      // 5-character floor and was never rejected by anything — it was simply
      // never generated. 3 dp is ~110 m, i.e. which house.
      final lat = kCanaryLatitude.abs().toStringAsFixed(3);
      final lon = kCanaryLongitude.abs().toStringAsFixed(3);
      expect(lat.length, greaterThanOrEqualTo(CanaryTermSet.minMixedLength));
      final report = _scanWithExtra(
        _tagLine('approx', '-$lat,-$lon', seq: 931),
      );
      expect(report.verdict, CanaryVerdict.leak);
      expect(
        report.findings.map((f) => f.term.encoding),
        containsAll(<String>['lat/decimal-round3', 'lon/decimal-round3']),
      );
    });

    test('kilometreScaleDecimalCoordinateIsCaught', () {
      // 2 dp is ~1.1 km: still a neighbourhood, still a disclosure.
      final report = _scanWithExtra(
        _tagLine(
          'approx',
          '${kCanaryLatitude.toStringAsFixed(2)},'
              '${kCanaryLongitude.toStringAsFixed(2)}',
          seq: 932,
        ),
      );
      expect(report.verdict, CanaryVerdict.leak);
      expect(
        report.findings.map((f) => f.term.encoding),
        containsAll(<String>['lat/decimal-round2', 'lon/decimal-round2']),
      );
    });

    test('singlePrecisionCoordinatePairIsCaught', () {
      // A struct of two f32s, hexed into a tag. Each axis alone is 8 hex
      // characters, under the 12-character floor the journal's own hex
      // furniture forces — so the single-axis terms are declared gaps and the
      // PAIR is what carries the coverage.
      final bytes = <int>[
        ...float32Bytes(kCanaryLatitude, Endian.little),
        ...float32Bytes(kCanaryLongitude, Endian.little),
      ];
      expect(bytesToHex(bytes), hasLength(16));
      final report = _scanWithExtra(
        _tagLine('fix32', '0a${bytesToHex(bytes)}', seq: 933),
      );
      expect(report.verdict, CanaryVerdict.leak);
      expect(
        report.findings.map((f) => f.term.encoding),
        contains('f32pair-latlon-le/hex-lower'),
      );
    });

    test('geoJsonOrderedSinglePrecisionPairIsCaught', () {
      // The same struct in GeoJSON order. Assuming declaration order would
      // miss half of the real serialisations.
      final bytes = <int>[
        ...float32Bytes(kCanaryLongitude, Endian.big),
        ...float32Bytes(kCanaryLatitude, Endian.big),
      ];
      final report = _scanWithExtra(
        _tagLine('geo', bytesToHex(bytes), seq: 934),
      );
      expect(report.verdict, CanaryVerdict.leak);
      expect(
        report.findings.map((f) => f.term.encoding),
        contains('f32pair-lonlat-be/hex-lower'),
      );
    });

    test('base64OfAPercentEncodedNameIsCaught', () {
      // A composed transform: the name is URL-escaped into a query string and
      // the whole document is then base64'd into a `content`. Applying the
      // byte encodings only to the RAW utf8 form left this clean.
      final manifest = _manifest();
      final composed = base64.encode(
        utf8.encode(Uri.encodeComponent(manifest.circleDisplayName)),
      );
      final report = _scanWithExtra(
        _tagLine('x', composed, seq: 935),
        manifest: manifest,
      );
      expect(report.verdict, CanaryVerdict.leak);
      expect(
        report.findings.map((f) => f.term.encoding),
        contains('percent-component/base64-align0'),
      );
    });

    test('base64OfAHexDumpedPetnameIsCaught', () {
      final manifest = _manifest();
      final composed = base64.encode(
        utf8.encode(bytesToHex(utf8.encode(manifest.petname))),
      );
      final report = _scanWithExtra(
        _tagLine('x', composed, seq: 936),
        manifest: manifest,
      );
      expect(report.verdict, CanaryVerdict.leak);
      expect(report.findings.first.term.canaryId, CanaryId.petname);
      expect(
        report.findings.map((f) => f.term.encoding),
        contains('utf8/hex-lower/base64-align0'),
      );
    });

    test('uiTruncatedDisplayNameIsCaught', () {
      // The likeliest partial leak in an app that renders names in
      // fixed-width rows: the name, cut short, with an ellipsis. Only the
      // truncation terms can see it — the literal term cannot.
      final manifest = _manifest();
      final name = manifest.circleDisplayName;
      final shown = '${name.substring(0, name.length - 6)}…';
      final report = _scanWithExtra(
        _tagLine('name', shown, seq: 937),
        manifest: manifest,
      );
      expect(report.verdict, CanaryVerdict.leak);
      expect(
        report.findings.map((f) => f.term.encoding),
        contains('utf8-drop6'),
      );
      expect(
        report.findings.map((f) => f.term.encoding),
        isNot(contains('utf8-literal')),
      );
    });

    test('rustDebugByteDumpIsCaught', () {
      // `{:?}` over a `Vec<u8>` — the exact shape of "a debug path that
      // stringifies a struct into a tag", which is the threat this library's
      // own opening paragraph names.
      final manifest = _manifest();
      final report = _scanWithExtra(
        _tagLine(
          'dbg',
          'Payload { name: '
              '[${rustDebugBytes(utf8.encode(manifest.petname))}] }',
          seq: 938,
        ),
        manifest: manifest,
      );
      expect(report.verdict, CanaryVerdict.leak);
      expect(report.findings.first.term.canaryId, CanaryId.petname);
      expect(
        report.findings.map((f) => f.term.encoding),
        contains('utf8/debug-dec'),
      );
    });

    test('rustHexDebugByteDumpOfACoordinateIsCaught', () {
      // `{:02x?}` over the f64 bytes. The `, ` separator is what makes this
      // assertable where the same bytes as a bare 16-character hex run would
      // still be — but the debug form is not that run, and a term set built
      // only from `hex-lower` would not see it.
      final dump = rustDebugBytes(
        float64Bytes(kCanaryLatitude, Endian.little),
        radix: 16,
        pad: true,
      );
      final report = _scanWithExtra(_tagLine('dbg', '[$dump]', seq: 939));
      expect(report.verdict, CanaryVerdict.leak);
      expect(
        report.findings.map((f) => f.term.encoding),
        contains('lat/f64-le/debug-hex02'),
      );
    });
  });

  group('positive controls (anti-vacuity)', () {
    test('emptyCarrierSetIsVacuousNotClean', () {
      // The plant DID take — proofs and all — and the scenario still recorded
      // no carriers, so the journal is not shown to cover any window in which
      // a canary could have leaked. Confirming the plant here is what keeps
      // this fixture pointed at the carrier control rather than sliding onto
      // the proof one that now precedes it.
      final plant = _confirmPlanted(
        WireCanaryPlant.mint(role: 'solo', random: Random(3)),
      );
      final report = WireCanaryScanner.scan(
        journals: <WireJournal>[
          WireJournal.parse(_cleanJournalText(), path: 'clean'),
        ],
        manifests: <WireCanaryManifest>[plant.manifest()],
      );
      expect(report.findings, isEmpty);
      // META-FLOOR (4), not UNUSABLE (3): the recorder did its job, the
      // SCENARIO failed to plant anything the journal could have covered.
      // The two demand opposite fixes, so they are separate exit codes —
      // the same split `check-wire-journal.sh` makes.
      expect(report.verdict, CanaryVerdict.metaFloor);
      expect(report.exitCode, 4);
      expect(report.vacuities.length, CanaryId.all.length);
      for (final id in CanaryId.all) {
        expect(report.vacuities.join('\n'), contains(id));
      }
      // Named specifically, not just "some vacuity fired": an empty carrier
      // set and a carrier seen only inbound are different operator failures
      // (nothing was recorded vs nothing was sent) and a report that
      // collapses them sends triage to the wrong place.
      for (final v in report.vacuities) {
        expect(v, contains('EMPTY carrier set'));
      }
    });

    test('missingCarrierEventIsVacuousNotClean', () {
      // The exact failure this supplements: the journal is fine, nothing
      // matched, and the run still proves nothing because the frames that
      // carried the canary were never recorded (NIP-40 eviction, a late
      // snapshot, a proxy that started after the circle was created).
      final manifest = _manifestWithCarriers(<String>['d' * 64]);
      final report = WireCanaryScanner.scan(
        journals: <WireJournal>[
          WireJournal.parse(_cleanJournalText(), path: 'clean'),
        ],
        manifests: <WireCanaryManifest>[manifest],
      );
      expect(report.findings, isEmpty);
      expect(report.verdict, CanaryVerdict.metaFloor);
      expect(report.vacuities.join('\n'), contains('ABSENT from the journal'));
    });

    test('carrierSeenOnlyInboundIsVacuousNotClean', () {
      // A send-side instrument that only ever saw the relay's echo never
      // observed a transmission, so it cannot speak to what the client sent.
      final carrier = 'ab${'c' * 62}';
      final manifest = _manifestWithCarriers(<String>[carrier]);
      final inboundOnly =
          '{"wire_seq":500,"type":"frame","conn_id":"c1","ts_ms":1785886160000,'
          '"dir":"r2c",'
          '$_endpoint,"frame":["EVENT","sub1",{"id":"$carrier","kind":445,'
          '"pubkey":"${'8' * 64}","created_at":1785886160,'
          '"tags":[["h","${'e' * 64}"]],"content":"",'
          '"sig":"${'f' * 128}"}],"raw_len":400}';
      final report = WireCanaryScanner.scan(
        journals: <WireJournal>[
          WireJournal.parse('${_cleanJournalText()}$inboundOnly\n', path: 'j'),
        ],
        manifests: <WireCanaryManifest>[manifest],
      );
      expect(report.findings, isEmpty);
      expect(report.verdict, CanaryVerdict.metaFloor);
      expect(report.vacuities.join('\n'), contains('SEND-side'));
    });

    test('satisfiedCarriersClearAllThreeControls', () {
      final manifest = _manifest();
      final report = WireCanaryScanner.scan(
        journals: <WireJournal>[
          WireJournal.parse(_cleanJournalText(), path: 'clean'),
        ],
        manifests: <WireCanaryManifest>[manifest],
      );
      expect(report.vacuities, isEmpty);
      expect(report.verdict, CanaryVerdict.clean);
    });

    test('aStaleJournalFromAnotherRunFailsTheControl', () {
      // Freshness. The canary token is minted per run, so a journal recorded
      // by an earlier run cannot satisfy this run's carriers — which is what
      // stops "we scanned yesterday's file" from reading as a pass.
      final today = _manifest();
      final yesterday = _manifestWithCarriers(<String>['9a${'b' * 62}']);
      expect(today.circleDisplayName, isNot(yesterday.circleDisplayName));
      final report = WireCanaryScanner.scan(
        journals: <WireJournal>[
          WireJournal.parse(_cleanJournalText(), path: 'yesterday'),
        ],
        manifests: <WireCanaryManifest>[yesterday],
      );
      expect(report.verdict, CanaryVerdict.metaFloor);
    });

    // ---- the controls have to prove a canary was ever PLANTABLE ----------

    test('carriersWithoutAPlantProofAreVacuousNotClean', () {
      // The run this whole group existed to refuse, and did not: three values
      // minted, none applied to anything, three ordinary published event ids
      // recorded as their carriers. Every carrier is present, every carrier
      // was sent, the journal is spotless — and the forbid half was asserting
      // the absence of a value that never went near the app.
      final unplanted = WireCanaryPlant.mint(role: 'solo', random: Random(7))
        ..recordCircleNameCarrier(_circleCarrier)
        ..recordCoordinateCarrier(_coordCarrier)
        ..recordPetnameOpportunity(_petnameCarrier);
      final report = WireCanaryScanner.scan(
        journals: <WireJournal>[
          WireJournal.parse(_cleanJournalText(), path: 'clean'),
        ],
        manifests: <WireCanaryManifest>[unplanted.manifest()],
      );
      expect(report.findings, isEmpty);
      expect(report.verdict, CanaryVerdict.metaFloor);
      expect(report.exitCode, 4);
      expect(report.vacuities, hasLength(CanaryId.all.length));
      for (final v in report.vacuities) {
        expect(v, contains('NO plant proof'));
      }
    });

    test('aPlantProofThatDoesNotMatchIsVacuousNotClean', () {
      // The plant ran and produced something else — a validator trimmed it, a
      // rename dropped it, a UI path substituted a default. The journal is
      // then being searched for a string the app never held.
      final plant = WireCanaryPlant.mint(role: 'solo', random: Random(8))
        ..recordCircleNameCarrier(_circleCarrier)
        ..recordCoordinateCarrier(_coordCarrier)
        ..recordPetnameOpportunity(_petnameCarrier)
        ..confirmCircleNamePlanted('Some Other Circle')
        ..confirmPetnamePlanted(WireCanaryPlant.mint(role: 'x').petname)
        ..confirmCoordinatePlanted(latitude: 51.5, longitude: -0.12);
      final report = WireCanaryScanner.scan(
        journals: <WireJournal>[
          WireJournal.parse(_cleanJournalText(), path: 'clean'),
        ],
        manifests: <WireCanaryManifest>[plant.manifest()],
      );
      expect(report.verdict, CanaryVerdict.metaFloor);
      expect(report.vacuities, hasLength(CanaryId.all.length));
      for (final v in report.vacuities) {
        expect(v, contains('does NOT match'));
      }
      // The mismatch report must not print either value: it is read off a CI
      // artifact, and "expected X, got Y" would put the canary in it twice.
      final rendered = report.renderLines().join('\n');
      expect(rendered, isNot(contains(plant.circleDisplayName)));
      expect(rendered, isNot(contains('Some Other Circle')));
    });

    test('aCoordinateProofSurvivesAFloatRoundTripButNotAWrongPlace', () {
      // The proof is compared numerically, not as a string: a coordinate that
      // came back through a decrypt and a JSON round trip may differ in the
      // last bits. A DIFFERENT place must still fail, and 11 m is a tolerance
      // only the canary can satisfy — the nearest land is ~2000 km away.
      WireCanaryReport scanWith(double lat, double lon) {
        final plant = WireCanaryPlant.mint(role: 'solo', random: Random(9))
          ..recordCircleNameCarrier(_circleCarrier)
          ..recordCoordinateCarrier(_coordCarrier)
          ..recordPetnameOpportunity(_petnameCarrier)
          ..confirmCircleNamePlanted(
            WireCanaryPlant.mint(role: 'solo', random: Random(9))
                .circleDisplayName,
          )
          ..confirmPetnamePlanted(
            WireCanaryPlant.mint(role: 'solo', random: Random(9)).petname,
          )
          ..confirmCoordinatePlanted(latitude: lat, longitude: lon);
        return WireCanaryScanner.scan(
          journals: <WireJournal>[
            WireJournal.parse(_cleanJournalText(), path: 'clean'),
          ],
          manifests: <WireCanaryManifest>[plant.manifest()],
        );
      }

      expect(
        scanWith(kCanaryLatitude + 1e-9, kCanaryLongitude - 1e-9).verdict,
        CanaryVerdict.clean,
      );
      final elsewhere = scanWith(kCanaryLatitude + 0.01, kCanaryLongitude);
      expect(elsewhere.verdict, CanaryVerdict.metaFloor);
      expect(elsewhere.vacuities.join('\n'), contains('does NOT match'));
    });

    test('carriersOfTheWrongKindAreVacuousNotClean', () {
      // "Some id the app published" is satisfiable by any event at all. A
      // carrier for the circle name has to be a frame that can CARRY group
      // metadata (a Welcome or a commit); one for the coordinate has to be a
      // group message. Here both were recorded off a KeyPackage publish.
      const kpId =
          'aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111';
      final plant = WireCanaryPlant.mint(role: 'solo', random: Random(10))
        ..recordCircleNameCarrier(kpId)
        ..recordCoordinateCarrier(kpId)
        ..recordPetnameOpportunity(kpId);
      _confirmPlanted(plant);
      final keyPackage =
          '{"wire_seq":940,"type":"frame","conn_id":"c2",'
          '"ts_ms":1785886199000,"dir":"c2r",$_endpoint,'
          '"frame":["EVENT",{"id":"$kpId","kind":30443,'
          '"pubkey":"${'8' * 64}","created_at":1785886199,'
          '"tags":[["d","slot-0"]],"content":"AAAA","sig":"${'f' * 128}"}],'
          '"raw_len":420}';
      final report = WireCanaryScanner.scan(
        journals: <WireJournal>[
          WireJournal.parse('${_cleanJournalText()}$keyPackage\n', path: 'j'),
        ],
        manifests: <WireCanaryManifest>[plant.manifest()],
      );
      expect(report.verdict, CanaryVerdict.metaFloor);
      final joined = report.vacuities.join('\n');
      expect(joined, contains('no carrier event was observed'));
      expect(joined, contains('kind 445 or 1059'));
      expect(joined, contains('kind 445'));
      // The petname declares no kind — its control is opportunity coverage,
      // and any client->relay event is a real opportunity — so it must NOT
      // fire here, or the distinction has been lost.
      expect(joined, isNot(contains('"${CanaryId.petname}": no carrier')));
    });

    test('carriersPastTheEvidenceBoundAreVacuousNotClean', () {
      // The A4 failure, reintroduced through the back door: `--max-wire-seq`
      // skipped lines past the bound in the forbid half and iterated the
      // WHOLE journal in the control half, so carriers recorded far past the
      // snapshot satisfied a window the scan never examined. Verdict was
      // clean, with zero vacuities, over evidence that was entirely outside
      // the sample.
      const lateCircle =
          'ccc11111111111111111111111111111111111111111111111111111111111c1';
      const lateCoord =
          'ccc22222222222222222222222222222222222222222222222222222222222c2';
      const latePetname =
          'ccc33333333333333333333333333333333333333333333333333333333333c3';
      final plant = WireCanaryPlant.mint(role: 'solo', random: Random(11))
        ..recordCircleNameCarrier(lateCircle)
        ..recordCoordinateCarrier(lateCoord)
        ..recordPetnameOpportunity(latePetname);
      _confirmPlanted(plant);
      String late(int seq, String id) =>
          '{"wire_seq":$seq,"type":"frame","conn_id":"c1",'
          '"ts_ms":1785886199000,"dir":"c2r",$_endpoint,'
          '"frame":["EVENT",{"id":"$id","kind":445,"pubkey":"${'8' * 64}",'
          '"created_at":1785886199,"tags":[["h","${'e' * 64}"]],'
          '"content":"","sig":"${'f' * 128}"}],"raw_len":420}';
      final journal = WireJournal.parse(
        '${_cleanJournalText()}'
        '${late(9000, lateCircle)}\n'
        '${late(9001, lateCoord)}\n'
        '${late(9002, latePetname)}\n',
        path: 'j',
      );

      // Unbounded, the carriers are inside the sample and the run is clean.
      expect(
        WireCanaryScanner.scan(
          journals: <WireJournal>[journal],
          manifests: <WireCanaryManifest>[plant.manifest()],
        ).verdict,
        CanaryVerdict.clean,
      );

      // Bounded at 100, every one of them is outside it.
      final bounded = WireCanaryScanner.scan(
        journals: <WireJournal>[journal],
        manifests: <WireCanaryManifest>[plant.manifest()],
        maxWireSeq: 100,
      );
      expect(bounded.findings, isEmpty);
      expect(bounded.verdict, CanaryVerdict.metaFloor);
      expect(bounded.vacuities, hasLength(CanaryId.all.length));
      expect(bounded.vacuities.join('\n'), contains('ABSENT from the journal'));
    });

    test('aSentinelBoundsTheControlsToo', () {
      // The same asymmetry, reached through the sentinel rather than the
      // flag. A carrier a background wake published AFTER the snapshot is not
      // evidence about the snapshot.
      const token = 'HAVEN_WIRE_SENTINEL:abc123def456';
      const lateCoord =
          'ddd22222222222222222222222222222222222222222222222222222222222d2';
      final plant = WireCanaryPlant.mint(role: 'solo', random: Random(12))
        ..recordCircleNameCarrier(_circleCarrier)
        ..recordCoordinateCarrier(lateCoord)
        ..recordPetnameOpportunity(_petnameCarrier)
        ..recordSentinel(token: token, wireSeq: 5000);
      _confirmPlanted(plant);
      const sentinelLine =
          '{"wire_seq":5000,"type":"frame","conn_id":"c1",'
          '"ts_ms":1785886165000,"dir":"c2r",'
          '$_endpoint,"frame":["HAVEN_WIRE_SENTINEL","$token"],'
          '"raw_len":60}';
      final afterSnapshot =
          '{"wire_seq":5001,"type":"frame","conn_id":"c1",'
          '"ts_ms":1785886199000,"dir":"c2r",$_endpoint,'
          '"frame":["EVENT",{"id":"$lateCoord","kind":445,'
          '"pubkey":"${'8' * 64}","created_at":1785886199,'
          '"tags":[["h","${'e' * 64}"]],"content":"",'
          '"sig":"${'f' * 128}"}],"raw_len":420}';
      final report = WireCanaryScanner.scan(
        journals: <WireJournal>[
          WireJournal.parse(
            '${_cleanJournalText()}$sentinelLine\n$afterSnapshot\n',
            path: 'j',
          ),
        ],
        manifests: <WireCanaryManifest>[plant.manifest()],
      );
      expect(report.verdict, CanaryVerdict.metaFloor);
      expect(
        report.vacuities.join('\n'),
        contains('"${CanaryId.coordinate}"'),
      );
    });
  });

  group('evidence failures', () {
    test('emptyJournalIsUnusableNotClean', () {
      final report = WireCanaryScanner.scan(
        journals: <WireJournal>[WireJournal.parse('', path: 'empty')],
        manifests: <WireCanaryManifest>[_manifest()],
      );
      expect(report.verdict, CanaryVerdict.unusable);
      expect(report.unusable.join('\n'), contains('empty'));
    });

    test('noManifestIsMetaFloorNotClean', () {
      final report = WireCanaryScanner.scan(
        journals: <WireJournal>[
          WireJournal.parse(_cleanJournalText(), path: 'clean'),
        ],
        manifests: const <WireCanaryManifest>[],
      );
      // A readable log with no announcement is the SCENARIO failing, not the
      // recorder. An ABSENT or empty manifest file is the other case and is
      // reported as UNUSABLE by the CLI, where the file access happens.
      expect(report.verdict, CanaryVerdict.metaFloor);
      expect(report.vacuities.join('\n'), contains('never announced a plant'));
    });

    test('lifecycleRecordsAreNotBlindSpots', () {
      // The deviation that bit the C2-C4 oracle. `conn_open` / `conn_error`
      // records carry NO `dir` and NO `frame` key, so an implementation that
      // reads a missing `frame` as "unparseable" scores one blind spot per
      // connection and reports EVERY healthy journal as UNUSABLE. The shared
      // clean fixture already contains both record types, so this asserts the
      // property directly rather than by side effect.
      final journal = WireJournal.parse(_cleanJournalText(), path: 'j');
      expect(journal.blindLines, 0);
      expect(
        WireCanaryScanner.scan(
          journals: <WireJournal>[journal],
          manifests: <WireCanaryManifest>[_manifest()],
        ).verdict,
        CanaryVerdict.clean,
      );
    });

    test('anUnparseableFrameWithMultibytePreviewIsNotABlindSpot', () {
      // `raw_len` is a BYTE count; the preview is capped in CHARACTERS. A
      // naive `raw_len > preview.length` test therefore reports a blind spot
      // on every non-ASCII frame the proxy could not parse, without a single
      // character having been dropped. The cap itself is the truncation test.
      const preview = 'héllo wörld — not a nostr frame';
      final rawLen = utf8.encode(preview).length;
      expect(rawLen, greaterThan(preview.length));
      final line =
          '{"wire_seq":702,"type":"frame","conn_id":"c1",'
          '"ts_ms":1785886163000,"dir":"c2r",'
          '$_endpoint,"frame":null,"raw_preview":"$preview",'
          '"raw_len":$rawLen}';
      final report = WireCanaryScanner.scan(
        journals: <WireJournal>[
          WireJournal.parse('${_cleanJournalText()}$line\n', path: 'j'),
        ],
        manifests: <WireCanaryManifest>[_manifest()],
      );
      expect(report.verdict, CanaryVerdict.clean);
    });

    test('novelFrameVerbIsStillFullyScanned', () {
      // C1 records `frame` verbatim for ANY JSON array with a string first
      // element, so a verb nobody has seen keeps its payload rather than
      // arriving as `frame: null`. That is the case a canary most needs to
      // see into: an unanticipated frame type is exactly where an
      // unanticipated leak lands, and a structural allow-list can only tell
      // you the verb was unknown, never what it carried.
      final manifest = _manifest();
      final report = _scanWithExtra(
        '{"wire_seq":703,"type":"frame","conn_id":"c1",'
        '"ts_ms":1785886164000,"dir":"c2r",'
        '$_endpoint,"frame":["NEG-OPEN","sub1","${manifest.petname}"],'
        '"raw_len":90}',
        manifest: manifest,
      );
      expect(report.verdict, CanaryVerdict.leak);
      expect(report.findings.first.term.canaryId, CanaryId.petname);
      expect(report.findings.first.refs.first.verb, 'NEG-OPEN');
    });

    test('sentinelAnnouncedButNeverRecordedIsUnusable', () {
      // The only direct proof that the traffic scanned went THROUGH the
      // recording proxy. A lane that pointed the app straight at the relay
      // produces a journal holding only the harness's frames — quiet,
      // well-formed, and worthless. Without this it reads as clean.
      final plant = _confirmPlanted(
        WireCanaryPlant.mint(role: 'solo', random: Random(5))
          ..recordCircleNameCarrier(_circleCarrier)
          ..recordCoordinateCarrier(_coordCarrier)
          ..recordPetnameOpportunity(_petnameCarrier)
          ..recordSentinel(
            token: 'HAVEN_WIRE_SENTINEL:abc123def456',
            wireSeq: 9,
          ),
      );
      final report = WireCanaryScanner.scan(
        journals: <WireJournal>[
          WireJournal.parse(_cleanJournalText(), path: 'j'),
        ],
        manifests: <WireCanaryManifest>[plant.manifest()],
      );
      expect(report.verdict, CanaryVerdict.unusable);
      expect(report.unusable.join('\n'), contains('ABSENT from every'));
    });

    test('sentinelRecordedAtTheAckedSeqAnchorsTheRead', () {
      const token = 'HAVEN_WIRE_SENTINEL:abc123def456';
      const seq = 9000;
      final plant = _confirmPlanted(
        WireCanaryPlant.mint(role: 'solo', random: Random(5))
          ..recordCircleNameCarrier(_circleCarrier)
          ..recordCoordinateCarrier(_coordCarrier)
          ..recordPetnameOpportunity(_petnameCarrier)
          ..recordSentinel(token: token, wireSeq: seq),
      );
      const sentinelLine =
          '{"wire_seq":$seq,"type":"frame","conn_id":"c1",'
          '"ts_ms":1785886165000,"dir":"c2r",'
          '$_endpoint,"frame":["HAVEN_WIRE_SENTINEL","$token"],'
          '"raw_len":60}';
      final report = WireCanaryScanner.scan(
        journals: <WireJournal>[
          WireJournal.parse(
            '${_cleanJournalText()}$sentinelLine\n',
            path: 'j',
          ),
        ],
        manifests: <WireCanaryManifest>[plant.manifest()],
      );
      expect(report.verdict, CanaryVerdict.clean);
    });

    test('truncatedTailPastTheSentinelIsNotAnEvidenceFailure', () {
      // A background wake still appending after the snapshot boundary must
      // not fail a lane for traffic the scenario never claimed to cover. The
      // partial line is still SCANNED — a leak in it is still a leak, proven
      // by `truncatedTailIsReportedButStillScannedForLeaks` — it just stops
      // being an evidence failure once something anchors the read.
      const token = 'HAVEN_WIRE_SENTINEL:abc123def456';
      const seq = 9000;
      final plant = _confirmPlanted(
        WireCanaryPlant.mint(role: 'solo', random: Random(5))
          ..recordCircleNameCarrier(_circleCarrier)
          ..recordCoordinateCarrier(_coordCarrier)
          ..recordPetnameOpportunity(_petnameCarrier)
          ..recordSentinel(token: token, wireSeq: seq),
      );
      const sentinelLine =
          '{"wire_seq":$seq,"type":"frame","conn_id":"c1",'
          '"ts_ms":1785886165000,"dir":"c2r",'
          '$_endpoint,"frame":["HAVEN_WIRE_SENTINEL","$token"],'
          '"raw_len":60}';
      const partial = '{"wire_seq":9002,"type":"frame","conn_id":"c1"';
      // A background wake's BLIND frame, also past the boundary: a binary or
      // unparseable message whose preview hit the cap. Bounded away for the
      // same reason as the tail — the run never claimed to cover it.
      final lateBlind =
          '{"wire_seq":9001,"type":"frame","conn_id":"c3",'
          '"ts_ms":1785886166000,"dir":"c2r",'
          '$_endpoint,"frame":null,"raw_preview":"${'z' * 200}",'
          '"raw_len":8192}';
      final anchored = WireCanaryScanner.scan(
        journals: <WireJournal>[
          WireJournal.parse(
            '${_cleanJournalText()}$sentinelLine\n$lateBlind\n$partial',
            path: 'j',
          ),
        ],
        manifests: <WireCanaryManifest>[plant.manifest()],
      );
      expect(anchored.verdict, CanaryVerdict.clean);

      // The same blind frame BELOW the boundary is still an evidence failure
      // — the anchor bounds what the run covers, it does not excuse gaps
      // inside that window.
      final inWindowBlind =
          lateBlind.replaceFirst('"wire_seq":9001', '"wire_seq":10');
      final gapped = WireCanaryScanner.scan(
        journals: <WireJournal>[
          WireJournal.parse(
            '${_cleanJournalText()}$inWindowBlind\n$sentinelLine\n',
            path: 'j',
          ),
        ],
        manifests: <WireCanaryManifest>[plant.manifest()],
      );
      expect(gapped.verdict, CanaryVerdict.unusable);
      expect(gapped.unusable.join('\n'), contains('blind spots'));

      // ...and WITHOUT an anchor the same tail is still reported, because
      // then nothing bounds what the run claims to have covered.
      final unanchored = WireCanaryScanner.scan(
        journals: <WireJournal>[
          WireJournal.parse('${_cleanJournalText()}$partial', path: 'j'),
        ],
        manifests: <WireCanaryManifest>[_manifest()],
      );
      expect(unanchored.verdict, CanaryVerdict.unusable);
      expect(unanchored.unusable.join('\n'), contains('truncated tail'));
    });

    test('truncatedUnparseableFrameIsABlindSpotNotAPass', () {
      // A frame the proxy could not parse, whose preview stops at 200 chars.
      // The bytes past that were never recorded, so a clean verdict over them
      // would be an assertion about evidence that does not exist.
      final preview = 'x' * 200;
      final line =
          '{"wire_seq":700,"type":"frame","conn_id":"c1","ts_ms":1785886161000,'
          '"dir":"c2r",'
          '$_endpoint,"frame":null,"raw_preview":"$preview","raw_len":4096}';
      final report = WireCanaryScanner.scan(
        journals: <WireJournal>[
          WireJournal.parse('${_cleanJournalText()}$line\n', path: 'j'),
        ],
        manifests: <WireCanaryManifest>[_manifest()],
      );
      expect(report.verdict, CanaryVerdict.unusable);
      expect(report.unusable.join('\n'), contains('blind spots'));
    });

    test('fullyPreviewedUnparseableFrameIsNotABlindSpot', () {
      const preview = 'not-a-nostr-frame';
      const line =
          '{"wire_seq":701,"type":"frame","conn_id":"c1","ts_ms":1785886162000,'
          '"dir":"c2r",'
          '$_endpoint,"frame":null,"raw_preview":"$preview",'
          '"raw_len":${preview.length}}';
      final report = WireCanaryScanner.scan(
        journals: <WireJournal>[
          WireJournal.parse('${_cleanJournalText()}$line\n', path: 'j'),
        ],
        manifests: <WireCanaryManifest>[_manifest()],
      );
      expect(report.verdict, CanaryVerdict.clean);
    });

    test('aShortLossyBinaryFrameIsABlindSpotNotAPass', () {
      // The producer renders a Binary message with `from_utf8_lossy` and THEN
      // truncates, so a binary message under 200 rendered characters arrives
      // with a preview under the cap and used to score zero blind lines — in
      // direct contradiction of a ledger that claims every binary message is
      // counted and reported UNUSABLE. `raw_len` was on the line the whole
      // time and never read, and U+FFFD was never tested for.
      const lossy = 'ab��cd';
      expect(lossy.length, lessThan(kRawPreviewMaxChars));
      final line =
          '{"wire_seq":703,"type":"frame","conn_id":"c1",'
          '"ts_ms":1785886163000,"dir":"c2r",'
          '$_endpoint,"frame":null,"raw_preview":${jsonEncode(lossy)},'
          '"raw_len":64}';
      final journal = WireJournal.parse(
        '${_cleanJournalText()}$line\n',
        path: 'j',
      );
      expect(journal.blindLines, 1);
      final report = WireCanaryScanner.scan(
        journals: <WireJournal>[journal],
        manifests: <WireCanaryManifest>[_manifest()],
      );
      expect(report.verdict, CanaryVerdict.unusable);
      expect(report.unusable.join('\n'), contains('blind spots'));
    });

    test('aPreviewWhoseByteLengthDisagreesWithRawLenIsABlindSpot', () {
      // The general form of the same check, and the one that catches a lossy
      // render whose replacement characters happen to balance out in
      // character count. `raw_len` is the producer's own statement of how big
      // the message was; a preview that does not weigh that much is not the
      // whole message.
      const preview = 'short-but-not-all-of-it';
      const line =
          '{"wire_seq":704,"type":"frame","conn_id":"c1",'
          '"ts_ms":1785886163000,"dir":"c2r",'
          '$_endpoint,"frame":null,"raw_preview":"$preview","raw_len":9001}';
      final journal = WireJournal.parse(
        '${_cleanJournalText()}$line\n',
        path: 'j',
      );
      expect(journal.blindLines, 1);
    });

    test('aFrameNullLineWithNoRawLenIsABlindSpot', () {
      // Fail closed: without `raw_len` there is nothing to check completeness
      // against, so "it looked short enough" is not a finding of completeness.
      const line =
          '{"wire_seq":705,"type":"frame","conn_id":"c1",'
          '"ts_ms":1785886163000,"dir":"c2r",'
          '$_endpoint,"frame":null,"raw_preview":"tiny"}';
      expect(
        WireJournal.parse('${_cleanJournalText()}$line\n', path: 'j')
            .blindLines,
        1,
      );
    });

    test('previewIsIncompleteIsDirectlyPinned', () {
      // The predicate itself, so each arm is proven rather than inferred from
      // one journal that happens to exercise it.
      expect(
        previewIsIncomplete(preview: 'abc', rawLen: 3),
        isFalse,
        reason: 'a complete ASCII preview is not blind',
      );
      expect(
        previewIsIncomplete(preview: 'héllo', rawLen: 6),
        isFalse,
        reason: 'raw_len is BYTES and the preview is CHARACTERS; a multi-byte '
            'payload is complete when those agree after encoding',
      );
      expect(previewIsIncomplete(preview: 'x' * 200, rawLen: 200), isTrue);
      expect(previewIsIncomplete(preview: 'a�b', rawLen: 5), isTrue);
      expect(previewIsIncomplete(preview: 'abc', rawLen: 4), isTrue);
      expect(previewIsIncomplete(preview: 'abc', rawLen: null), isTrue);
      expect(previewIsIncomplete(preview: null, rawLen: 3), isTrue);
    });

    test('truncatedTailIsReportedButStillScannedForLeaks', () {
      // A background wake can be mid-write while the oracle reads. The
      // partial line still gets scanned as raw text — a leak in it is still a
      // leak — but the journal is reported as an incomplete record.
      final manifest = _manifest();
      final partial =
          '{"wire_seq":800,"type":"frame","conn_id":"c1",'
          '"dir":"c2r",$_endpoint,"frame":["EVENT",'
          '{"tags":[["x","${manifest.petname}"';
      final report = WireCanaryScanner.scan(
        journals: <WireJournal>[
          WireJournal.parse('${_cleanJournalText()}$partial', path: 'j'),
        ],
        manifests: <WireCanaryManifest>[manifest],
      );
      expect(report.verdict, CanaryVerdict.leak);
      expect(report.findings.first.term.canaryId, CanaryId.petname);
    });

    test('leakOutranksMissingEvidence', () {
      // Callers key containment (journal withholding) off the leak verdict,
      // so a run that both leaked and lost evidence must report the leak.
      final manifest = _manifestWithCarriers(<String>['d' * 64]);
      final leaking = _plantLine(
        CanaryTermSet.expand(manifest).terms.first,
      );
      final report = WireCanaryScanner.scan(
        journals: <WireJournal>[
          WireJournal.parse('${_cleanJournalText()}$leaking\n', path: 'j'),
        ],
        manifests: <WireCanaryManifest>[manifest],
      );
      expect(report.vacuities, isNotEmpty);
      expect(report.verdict, CanaryVerdict.leak);
      expect(report.exitCode, 1);
    });
  });

  group('manifest', () {
    test('round-trips through its announcement line', () {
      final plant = WireCanaryPlant.mint(role: 'alice', random: Random(11))
        ..recordCircleNameCarrier('AB${'C' * 62}')
        ..recordCoordinateCarrier('de${'f' * 62}')
        ..recordPetnameOpportunity('12${'3' * 62}')
        ..nostrGroupIdHex = 'ee${'e' * 62}';
      final logged = <String>[];
      plant.announce(logged.add);
      expect(logged, hasLength(1));

      final parsed = WireCanaryManifest.parseAll(
        'I/flutter: noise\n${logged.single}\nI/flutter: more noise\n',
      );
      expect(parsed, hasLength(1));
      final m = parsed.single;
      expect(m.role, 'alice');
      expect(m.circleDisplayName, plant.circleDisplayName);
      expect(m.petname, plant.petname);
      expect(m.latitude, kCanaryLatitude);
      expect(m.longitude, kCanaryLongitude);
      // Carrier ids are normalised to lowercase so an uppercase hex id from
      // one source and a lowercase one from another are the same carrier.
      expect(
        m.carrierEventIds[CanaryId.circleDisplayName],
        <String>['ab${'c' * 62}'],
      );
    });

    test('a marker line with a broken payload throws rather than reads as '
        'nothing-planted', () {
      expect(
        () => WireCanaryManifest.parseAll('$kCanaryManifestMarker{oops\n'),
        throwsA(isA<FormatException>()),
      );
    });

    test('aMistypedCarrierIdThrowsFormatExceptionNotTypeError', () {
      // `(e as String)` threw a TypeError, which is an Error rather than an
      // Exception: it walked past every `on FormatException` in the CLI and
      // exited 255 with a stack trace, against a header promising exactly
      // five codes. The parse still has to REFUSE the manifest — a carrier
      // list this oracle cannot read is an evidence failure — it just has to
      // refuse it in the currency its callers catch.
      expect(
        () => WireCanaryManifest.parseAll(
          '$kCanaryManifestMarker'
          '{"role":"solo","circle_display_name":"x","petname":"y",'
          '"latitude":1.0,"longitude":2.0,'
          '"carrier_event_ids":{"circle_display_name":[123],'
          '"petname":[],"coordinate":[]}}\n',
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('aMistypedPlantProofThrowsFormatException', () {
      expect(
        () => WireCanaryManifest.parseAll(
          '$kCanaryManifestMarker'
          '{"role":"solo","circle_display_name":"x","petname":"y",'
          '"latitude":1.0,"longitude":2.0,'
          '"carrier_event_ids":{"circle_display_name":[],'
          '"petname":[],"coordinate":[]},'
          '"plant_proofs":{"petname":7}}\n',
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('plant proofs round-trip through the announcement line', () {
      final plant = WireCanaryPlant.mint(role: 'alice', random: Random(13));
      _confirmPlanted(plant);
      final logged = <String>[];
      plant.announce(logged.add);
      final parsed = WireCanaryManifest.parseAll(logged.single).single;
      expect(
        parsed.plantProofs[CanaryId.circleDisplayName],
        plant.circleDisplayName,
      );
      expect(parsed.plantProofs[CanaryId.petname], plant.petname);
      expect(
        parsed.plantProofs[CanaryId.coordinate],
        parsed.expectedPlantProof(CanaryId.coordinate),
      );
    });

    test('a manifest announced by an older scenario carries no proofs', () {
      // Forward compatibility, fail-CLOSED: a manifest without the field
      // parses (so the run is not an unreadable-evidence failure) and then
      // fails the control (so it is not a pass either).
      final legacy = _manifest().toJson()..remove('plant_proofs');
      final parsed = WireCanaryManifest.parseAll(
        '$kCanaryManifestMarker${jsonEncode(legacy)}\n',
      ).single;
      expect(parsed.plantProofs, isEmpty);
      final report = WireCanaryScanner.scan(
        journals: <WireJournal>[
          WireJournal.parse(_cleanJournalText(), path: 'clean'),
        ],
        manifests: <WireCanaryManifest>[parsed],
      );
      expect(report.verdict, CanaryVerdict.metaFloor);
    });

    test('two mints produce different canaries', () {
      final a = WireCanaryPlant.mint(role: 'solo');
      final b = WireCanaryPlant.mint(role: 'solo');
      expect(a.circleDisplayName, isNot(b.circleDisplayName));
      expect(a.petname, isNot(b.petname));
      expect(a.circleDisplayName, isNot(a.petname));
    });

    test('minted names fit the circle-name validator', () {
      for (var i = 0; i < 50; i++) {
        final p = WireCanaryPlant.mint(role: 'solo');
        expect(p.circleDisplayName.length, lessThanOrEqualTo(50));
        expect(p.circleDisplayName.trim(), isNotEmpty);
      }
    });

    test('multi-role scenarios fold every announced plant into one scan', () {
      final alice = _confirmPlanted(
        WireCanaryPlant.mint(role: 'alice', random: Random(1))
          ..recordCircleNameCarrier('a' * 64)
          ..recordCoordinateCarrier('a' * 64)
          ..recordPetnameOpportunity('a' * 64),
      );
      final bob = _confirmPlanted(
        WireCanaryPlant.mint(role: 'bob', random: Random(2))
          ..recordCircleNameCarrier('a' * 64)
          ..recordCoordinateCarrier('a' * 64)
          ..recordPetnameOpportunity('a' * 64),
      );
      final log = <String>[];
      alice.announce(log.add);
      bob.announce(log.add);
      final manifests = WireCanaryManifest.parseAll(log.join('\n'));
      expect(manifests, hasLength(2));

      // Bob's petname leaking must be caught even though Alice announced too.
      final leaking =
          '{"wire_seq":950,"type":"frame","conn_id":"c1","ts_ms":1785886163000,'
          '"dir":"c2r",'
          '$_endpoint,"frame":["EVENT",{"id":"${'a' * 64}","kind":445,'
          '"pubkey":"${'8' * 64}","created_at":1785886163,'
          '"tags":[["h","${'e' * 64}"],["n","${bob.petname}"]],'
          '"content":"","sig":"${'f' * 128}"}],"raw_len":420}';
      final report = WireCanaryScanner.scan(
        journals: <WireJournal>[
          WireJournal.parse('$leaking\n', path: 'j'),
        ],
        manifests: manifests,
      );
      expect(report.verdict, CanaryVerdict.leak);
      expect(report.findings.first.term.canaryId, CanaryId.petname);
    });
  });

  group('failure output discloses location, never content', () {
    test('renderLinesNamesTheCanaryAndWithholdsItsValue', () {
      final manifest = _manifest();
      final term = CanaryTermSet.expand(manifest).terms.firstWhere(
            (t) => t.encoding == 'utf8-literal' &&
                t.canaryId == CanaryId.circleDisplayName,
          );
      final report = WireCanaryScanner.scan(
        journals: <WireJournal>[
          WireJournal.parse(
            '${_cleanJournalText()}${_plantLine(term)}\n',
            path: 'j',
          ),
        ],
        manifests: <WireCanaryManifest>[manifest],
      );
      final rendered = report.renderLines().join('\n');

      // Actionable: which canary, which encoding, where.
      expect(rendered, contains(CanaryId.circleDisplayName));
      expect(rendered, contains('utf8-literal'));
      expect(rendered, contains('wire_seq='));
      expect(rendered, contains('c2r'));
      expect(rendered, contains('EVENT'));

      // Withheld: the value itself and any frame content. A CI artifact with
      // weeks of retention must not become a second copy of the leak.
      expect(rendered, isNot(contains(manifest.circleDisplayName)));
      expect(rendered, isNot(contains(manifest.petname)));
      expect(rendered, isNot(contains('sig')));
      expect(rendered, isNot(contains('content')));

      // ...unless a human explicitly asks, at their own terminal.
      final disclosed =
          report.renderLines(discloseValues: true).join('\n');
      expect(disclosed, contains(manifest.circleDisplayName));
    });

    test('findings cap how many locations they name', () {
      final manifest = _manifest();
      final term = CanaryTermSet.expand(manifest).terms.first;
      final many = List<String>.generate(
        WireCanaryScanner.maxRefsPerFinding + 7,
        (i) => _plantLine(term, seq: 2000 + i),
      ).map((l) => '$l\n').join();
      final report = WireCanaryScanner.scan(
        journals: <WireJournal>[
          WireJournal.parse('${_cleanJournalText()}$many', path: 'j'),
        ],
        manifests: <WireCanaryManifest>[manifest],
      );
      // Pinned, not read: a test that only compares the report against the
      // constant it was generated from stays green at any value, including
      // 1 — which would strip the locations that make a finding actionable.
      expect(WireCanaryScanner.maxRefsPerFinding, 20);
      final finding = report.findings.first;
      expect(finding.totalHits, WireCanaryScanner.maxRefsPerFinding + 7);
      expect(finding.refs, hasLength(WireCanaryScanner.maxRefsPerFinding));
      expect(report.renderLines().join('\n'), contains('[+7 more]'));
    });

    test('aCanaryInTheFrameVERBIsNotReLeakedByTheReport', () {
      // The instrument leaking. `FrameRef.verb` was `frame.first` verbatim and
      // is printed unconditionally into the LEAK line, so a leak landing in
      // the verb position travelled back out in full, with disclosure OFF, in
      // a CI artifact retained for weeks — by the one tool whose entire
      // contract is "say WHICH canary leaked and WHERE, never WHAT".
      //
      // Two tests jointly documented the hole without noticing: the guard test
      // planted only into a tag, and `novelFrameVerbIsStillFullyScanned`
      // asserts arbitrary verbs are surfaced.
      final manifest = _manifest();
      final report = _scanWithExtra(
        '{"wire_seq":941,"type":"frame","conn_id":"c1","ts_ms":1785886199000,'
        '"dir":"c2r",$_endpoint,"frame":["${manifest.petname}","sub1"],'
        '"raw_len":90}',
        manifest: manifest,
      );
      expect(report.verdict, CanaryVerdict.leak);
      final rendered = report.renderLines().join('\n');
      expect(rendered, isNot(contains(manifest.petname)));
      // ...and it still says enough to find the frame.
      expect(rendered, contains('wire_seq=941'));
      expect(rendered, contains(CanaryId.petname));
      // The placeholder keeps the length, which is the actionable part.
      expect(rendered, contains('non-verb:${manifest.petname.length} chars'));
    });

    test('aVerbShapedCanaryInTheVerbIsScrubbedByValueToo', () {
      // The structural stop is a SHAPE, so a leak that happens to look like a
      // verb passes it — and one of the covered encodings genuinely does. The
      // uppercase hex of an f64 coordinate is 16 characters of `[A-Z0-9]`,
      // which is a well-formed Nostr verb as far as any shape test can tell.
      // The value-aware stop is what catches that, which is why neither of
      // the two is redundant.
      expect(sanitiseFrameVerb('NEG-OPEN'), 'NEG-OPEN');
      final hexUpper = bytesToHex(
        float64Bytes(kCanaryLatitude, Endian.big),
      ).toUpperCase();
      expect(kFrameVerbShape.hasMatch(hexUpper), isTrue);
      expect(sanitiseFrameVerb(hexUpper), hexUpper);

      final report = _scanWithExtra(
        '{"wire_seq":942,"type":"frame","conn_id":"c1","ts_ms":1785886199000,'
        '"dir":"c2r",$_endpoint,"frame":["$hexUpper","sub1"],"raw_len":90}',
      );
      expect(report.verdict, CanaryVerdict.leak);
      expect(
        report.findings.map((f) => f.term.encoding),
        contains('lat/f64-be/hex-upper'),
      );
      final rendered = report.renderLines().join('\n');
      expect(rendered, contains('<redacted>'));
      expect(rendered, isNot(contains(hexUpper)));
    });
  });

  group('sentinel bound', () {
    test('maxWireSeq excludes lines a background wake appended later', () {
      final manifest = _manifest();
      final term = CanaryTermSet.expand(manifest).terms.first;
      final text =
          '${_cleanJournalText()}${_plantLine(term, seq: 5000)}\n';
      final journal = WireJournal.parse(text, path: 'j');

      expect(
        WireCanaryScanner.scan(
          journals: <WireJournal>[journal],
          manifests: <WireCanaryManifest>[manifest],
        ).verdict,
        CanaryVerdict.leak,
      );
      expect(
        WireCanaryScanner.scan(
          journals: <WireJournal>[journal],
          manifests: <WireCanaryManifest>[manifest],
          maxWireSeq: 4999,
        ).findings,
        isEmpty,
      );
    });
  });
}

// =============================================================================
// Fixtures
// =============================================================================

/// The `relay_url` / `listen` pair C1's proxy stamps on every traffic line
/// (`docs/WIRE_JOURNAL.md`). Present on every fixture so the tests run against
/// the schema the real recorder emits rather than the working draft.
const String _endpoint =
    '"relay_url":"ws://127.0.0.1:7777","listen":"127.0.0.1:7788"';

/// Event ids used as the canaries' carriers; they appear in the clean journal.
const String _circleCarrier =
    '11111111111111111111111111111111111111111111111111111111111111a1';
const String _coordCarrier =
    '22222222222222222222222222222222222222222222222222222222222222b2';
const String _petnameCarrier =
    '33333333333333333333333333333333333333333333333333333333333333c3';

/// A manifest whose carriers are all present, client-to-relay, in
/// [_cleanJournalText] — i.e. every positive control is satisfied, so a test
/// that fails does so for the reason it names.
WireCanaryManifest _manifest() {
  final plant = WireCanaryPlant.mint(role: 'solo', random: Random(42))
    ..recordCircleNameCarrier(_circleCarrier)
    ..recordCoordinateCarrier(_coordCarrier)
    ..recordPetnameOpportunity(_petnameCarrier)
    ..nostrGroupIdHex = 'e' * 64;
  return _confirmPlanted(plant).manifest();
}

/// Records the plant proofs a scenario would take from the app after
/// planting.
///
/// Every fixture that expects a non-vacuous run needs these: carrier ids
/// alone cannot distinguish a genuine carrier from any published event id, so
/// a manifest without proofs is a META-FLOOR by design.
WireCanaryPlant _confirmPlanted(WireCanaryPlant plant) => plant
  ..confirmCircleNamePlanted(plant.circleDisplayName)
  ..confirmPetnamePlanted(plant.petname)
  ..confirmCoordinatePlanted(
    latitude: plant.latitude,
    longitude: plant.longitude,
  );

/// A manifest with a different mint and a caller-chosen carrier set.
WireCanaryManifest _manifestWithCarriers(List<String> carriers) {
  final plant = WireCanaryPlant.mint(role: 'solo', random: Random(99));
  for (final id in carriers) {
    plant
      ..recordCircleNameCarrier(id)
      ..recordCoordinateCarrier(id)
      ..recordPetnameOpportunity(id);
  }
  return _confirmPlanted(plant).manifest();
}

/// RFC 4648 base32 of [bytes], uppercase, unpadded.
///
/// Only a probe: base32 is a declared-ABSENT encoding, and the claim that it
/// is absent needs something to be absent OF.
String _base32(List<int> bytes) {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  final out = StringBuffer();
  var buffer = 0;
  var bits = 0;
  for (final b in bytes) {
    buffer = (buffer << 8) | b;
    bits += 8;
    while (bits >= 5) {
      out.write(alphabet[(buffer >> (bits - 5)) & 31]);
      bits -= 5;
    }
  }
  if (bits > 0) out.write(alphabet[(buffer << (5 - bits)) & 31]);
  return out.toString();
}

/// A degrees/minutes/seconds rendering of [degrees]. Probe only, as above.
String _dms(double degrees) {
  final magnitude = degrees.abs();
  final d = magnitude.floor();
  final minutesFull = (magnitude - d) * 60;
  final m = minutesFull.floor();
  final sec = (minutesFull - m) * 60;
  return "$d\u00b0$m'${sec.toStringAsFixed(2)}\"";
}

/// One `c2r` kind-445 event carrying `[tagName, value]` as an extra tag.
///
/// The leak shapes below differ only in what goes in that tag, so the frame
/// around it is written once — a per-test copy of 6 lines of JSON is where a
/// fixture quietly stops being the shape it claims to be.
String _tagLine(String tagName, String value, {int seq = 930}) =>
    '{"wire_seq":$seq,"type":"frame","conn_id":"c1","ts_ms":1785886199000,'
    '"dir":"c2r",$_endpoint,"frame":["EVENT",{"id":"${'a' * 63}9","kind":445,'
    '"pubkey":"${'b' * 64}","created_at":1785886199,'
    '"tags":[["h","${'e' * 64}"],["$tagName","$value"]],"content":"",'
    '"sig":"${'c' * 128}"}],"raw_len":480}';

/// Scans [_cleanJournalText] plus one extra hand-written line.
WireCanaryReport _scanWithExtra(
  String extraLine, {
  WireCanaryManifest? manifest,
}) {
  final m = manifest ?? _manifest();
  return WireCanaryScanner.scan(
    journals: <WireJournal>[
      WireJournal.parse('${_cleanJournalText()}$extraLine\n', path: 'j'),
    ],
    manifests: <WireCanaryManifest>[m],
  );
}

/// A journal line carrying [term]'s value verbatim, in the shape its
/// [TermMatch] mode expects.
///
/// Written as raw text rather than through `jsonEncode` on purpose: the
/// `json-unicode-escape` term must appear as literal `\uXXXX` in the line, and
/// an encoder would have escaped the backslash.
String _plantLine(CanaryTerm term, {int seq = 1000}) {
  final value = term.value;
  final tag = switch (term.match) {
    // A prefix and suffix, so substring semantics are what is being proven —
    // a matcher that only handled whole field values would fail here.
    TermMatch.substring => '["dbg","pfx_${value}_sfx"]',
    // A complete field value, which is what the mode requires.
    TermMatch.jsonToken => '["g","$value"]',
    // Delimited by `-` and `,`, neither alphanumeric.
    TermMatch.delimited => '["fix","-$value,0"]',
  };
  return '{"wire_seq":$seq,"type":"frame","conn_id":"cX","ts_ms":1785886199000,'
  '"dir":"c2r",'
      '$_endpoint,"frame":["EVENT",{"id":"${'a' * 63}9","kind":445,'
      '"pubkey":"${'b' * 64}","created_at":1785886199,'
      '"tags":[["h","${'e' * 64}"],$tag],"content":"",'
      '"sig":"${'c' * 128}"}],"raw_len":480}';
}

String? _cleanJournalCache;

/// A realistic clean journal: hex ids, pubkeys, signatures, base64
/// ciphertexts, REQ/OK/EOSE frames, and every carrier event present in the
/// client-to-relay direction.
///
/// Deterministic (seeded) so a false positive here is reproducible rather
/// than a once-a-year mystery.
String _cleanJournalText({int lines = 60, int contentChars = 240}) {
  if (lines == 60 && contentChars == 240 && _cleanJournalCache != null) {
    return _cleanJournalCache!;
  }
  final rng = Random(20260805);
  const hexChars = '0123456789abcdef';
  const b64Chars =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  String hex(int n) =>
      List<String>.generate(n, (_) => hexChars[rng.nextInt(16)]).join();
  String b64(int n) =>
      List<String>.generate(n, (_) => b64Chars[rng.nextInt(64)]).join();

  final buf = StringBuffer();
  var seq = 0;
  final carriers = <String>[_circleCarrier, _coordCarrier, _petnameCarrier];
  final groupId = 'e' * 64;

  // Lifecycle records carry NO `dir` and NO `frame` key. They lead the
  // fixture deliberately: an oracle that reads a missing `frame` as
  // "unparseable" scores one blind spot per connection and reports every
  // healthy journal as UNUSABLE, and putting them in the SHARED fixture means
  // every test in this file would go red on that mistake, not just one.
  buf
    ..writeln(
      '{"wire_seq":${seq++},"type":"conn_open","conn_id":"c1",'
      '"ts_ms":1785886099000,$_endpoint}',
    )
    ..writeln(
      '{"wire_seq":${seq++},"type":"conn_error","conn_id":"c9",'
      '"ts_ms":1785886099500,"relay_url":"ws://127.0.0.1:9999",'
      '"listen":"127.0.0.1:7788","reason":"upstream connect failed"}',
    )
    ..writeln(
      '{"wire_seq":${seq++},"type":"frame","conn_id":"c1",'
      '"ts_ms":1785886100000,"dir":"c2r",'
      '$_endpoint,"frame":["REQ","sub0",{"kinds":[445],'
      '"#h":["$groupId"],"since":1785886000}],"raw_len":120}',
    )
    ..writeln(
      '{"wire_seq":${seq++},"type":"frame","conn_id":"c1",'
      '"ts_ms":1785886100100,"dir":"r2c",'
      '$_endpoint,"frame":["EOSE","sub0"],"raw_len":24}',
    );

  for (var i = 0; i < lines; i++) {
    final id = i < carriers.length ? carriers[i] : hex(64);
    buf
      ..writeln(
        '{"wire_seq":${seq++},"type":"frame","conn_id":"c1",'
        '"ts_ms":${1785886100200 + i},'
        '"dir":"c2r",$_endpoint,"frame":["EVENT",{"id":"$id","kind":445,'
        '"pubkey":"${hex(64)}","created_at":${1785886100 + i},'
        '"tags":[["h","$groupId"],["expiration","${1785886328 + i}"]],'
        '"content":"${b64(contentChars)}","sig":"${hex(128)}"}],'
        '"raw_len":${contentChars + 400}}',
      )
      ..writeln(
        '{"wire_seq":${seq++},"type":"frame","conn_id":"c1",'
        '"ts_ms":${1785886100300 + i},'
        '"dir":"r2c",$_endpoint,"frame":["OK","$id",true,""],"raw_len":80}',
      );
  }
  // A gift-wrapped welcome and a KeyPackage, so the fixture is not all 445s.
  buf
    ..writeln(
      '{"wire_seq":${seq++},"type":"frame","conn_id":"c2",'
      '"ts_ms":1785886140000,"dir":"c2r",'
      '$_endpoint,"frame":["EVENT",{"id":"${hex(64)}","kind":1059,'
      '"pubkey":"${hex(64)}","created_at":1785886140,'
      '"tags":[["p","${hex(64)}"]],"content":"${b64(600)}",'
      '"sig":"${hex(128)}"}],"raw_len":1200}',
    )
    ..writeln(
      '{"wire_seq":${seq++},"type":"frame","conn_id":"c2",'
      '"ts_ms":1785886141000,"dir":"c2r",'
      '$_endpoint,"frame":["EVENT",{"id":"${hex(64)}","kind":30443,'
      '"pubkey":"${hex(64)}","created_at":1785886141,'
      '"tags":[["d","slot-0"],["relays","wss://relay.example"]],'
      '"content":"${b64(400)}","sig":"${hex(128)}"}],"raw_len":900}',
    );

  final text = buf.toString();
  if (lines == 60 && contentChars == 240) _cleanJournalCache = text;
  return text;
}
