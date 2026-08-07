#!/usr/bin/env dart
// check-wire-canaries.dart — Workstream C6 content-canary oracle.
//
// Reads the NDJSON wire journal produced by C1's recording WebSocket proxy and
// asserts that three values the scenario planted never crossed the wire in any
// encoding: the circle display name, a member petname, and the published
// coordinate.
//
// # Why this is not another structural check
//
// C2-C5 assert over structure — which kinds, which tags, which filters. They
// reject only shapes somebody thought to enumerate. This asserts over CONTENT:
// a value known to the test that must be absent from every frame. It is the
// check that survives a new MDK field, an unexpected serialization, or a debug
// path that stringifies a struct into a tag.
//
// # Fail-closed, both directions
//
// C1's proxy fails OPEN so a recording fault can never break the product. This
// oracle fails CLOSED: an absent, empty, truncated or partly-unreadable
// journal is a FAILURE, and so is a run whose positive controls show the
// journal never covered the window in which a canary could have leaked. "There
// was nothing to scan" has been reported as "nothing leaked" in this repo
// before (backlog A4); it is not reported that way here.
//
// # Output never re-leaks
//
// On a hit this names WHICH canary leaked, in WHICH encoding, and WHERE
// (wire_seq / conn_id / direction / frame verb / kind). It never prints the
// matched text, the frame body, or the canary value. See
// `WireCanaryReport.renderLines` for the full rationale. `--disclose-values`
// relaxes that for local triage; no CI caller should pass it.
//
// A leak verdict means the JOURNAL now contains plaintext of a planted secret.
// Callers must treat exit 1 as a containment signal and withhold the journal
// from any artifact upload, exactly as `scan-logs-for-secrets.sh` requires of
// the logs it flags.
//
// Usage:
//   dart tooling/e2e/ci/check-wire-canaries.dart \
//        --journal <file-or-dir> [--journal ...] \
//        --manifest <drive-log-or-manifest-file> [--manifest ...] \
//        [--sentinel <token>] [--max-wire-seq N] [--disclose-values]
//   dart tooling/e2e/ci/check-wire-canaries.dart --self-test
//
// Exit codes — the SAME five as tooling/e2e/ci/check-wire-journal.sh (the
// C2-C4 structural oracle), so a lane running both reads one convention:
//   0 = every journal was present, readable, anchored and clean, and every
//       positive control was satisfied
//   1 = VIOLATION — a canary reached the wire
//   2 = usage error
//   3 = UNUSABLE — the RECORDER broke: a journal was absent, empty,
//       unreadable, unparseable, blind (a frame whose preview was truncated),
//       or unanchored (the sentinel the proxy acked was never written). The
//       scan could not be performed.
//   4 = META-FLOOR — the SCENARIO broke: the journal is fine but proves too
//       little. No manifest was announced; a canary was never confirmed
//       PLANTED (carrier ids cannot tell a genuine carrier from any published
//       event id, so a run that minted three values, applied none and
//       recorded three sent ids would otherwise read as clean); a canary has
//       no carrier events; the frames that carried one are absent from the
//       journal; or no carrier was published as an event of a kind able to
//       hold it. A forbid-check over a value that was never applied, or over
//       a window that never contained it, passes for free, so this is not a
//       pass. Distinct from 3 because the operator response differs: 3 means
//       fix the recorder, 4 means fix the scenario.

import 'dart:io';

import '../../../haven/integration_test/e2e/_lib/wire_canaries.dart';

/// Clean: journal scannable and anchored, controls satisfied, nothing found.
const int rcClean = 0;

/// A canary reached the wire.
const int rcLeak = 1;

/// Usage error.
const int rcUsage = 2;

/// The recorder broke; the scan could not be performed.
const int rcUnusable = 3;

/// The scenario broke; the scan proves too little to be a pass.
const int rcMetaFloor = 4;

/// Journal file extensions recognised when a directory is given.
const List<String> kJournalExtensions = <String>[
  '.ndjson',
  '.jsonl',
  '.journal',
];

void main(List<String> args) {
  exitCode = run(args, stdout.writeln, stderr.writeln);
}

/// The real entry point, factored out so `--self-test` exercises it rather
/// than reaching past it into internals.
///
/// The A4 false-green did not live in the scanner: it lived in an argument
/// loop that printed "skipping non-existent path" and then returned success.
/// A self-test that only drove the scanner would have stayed green while that
/// hole stayed open.
///
/// ## Why the blanket catch
///
/// The header above promises exactly five exit codes, and a lane's shell
/// reads that promise as a contract. An uncaught throw exits 255 with a stack
/// trace, which is none of the five and which `set -e` reports as an
/// unclassified failure — so the operator cannot tell "the recorder broke"
/// from "the oracle crashed", and the containment rule keyed on rc=1 never
/// gets evaluated. `on Object` rather than `on Exception` because the escapes
/// that matter here are Errors: a `TypeError` out of a mistyped manifest
/// field, a `RangeError` out of a hand-edited journal. UNUSABLE is the honest
/// bucket — the scan did not happen, and that is not a pass.
int run(
  List<String> args,
  void Function(String) out,
  void Function(String) err,
) {
  try {
    return _run(args, out, err);
  } on Object catch (e) {
    // The message, never the object's toString of any parsed value: a throw
    // out of the manifest parser can carry manifest content.
    err(
      'UNUSABLE: the oracle threw while reading its inputs '
      '(${e.runtimeType}). The scan did not run, so this run carries no '
      'evidence about content leakage either way.',
    );
    return rcUnusable;
  }
}

int _run(
  List<String> args,
  void Function(String) out,
  void Function(String) err,
) {
  final journalArgs = <String>[];
  final manifestArgs = <String>[];
  var discloseValues = false;
  int? maxWireSeq;
  String? sentinel;

  // An explicit cursor rather than a `for` loop: the flag handlers below need
  // to consume the following argument, and Dart gives each iteration of a
  // C-style `for` its own binding of the loop variable, which makes "advance
  // the index from inside the body" subtle enough to be worth not relying on.
  var i = 0;
  while (i < args.length) {
    final arg = args[i];
    i++;
    String? next() {
      if (i >= args.length) return null;
      final value = args[i];
      i++;
      return value;
    }

    switch (arg) {
      case '--self-test':
        return selfTest(out, err);
      case '--help' || '-h':
        _usage(out);
        return rcUsage;
      case '--disclose-values':
        discloseValues = true;
      case '--journal':
        final v = next();
        if (v == null) {
          err('ERROR: --journal needs a path');
          return rcUsage;
        }
        journalArgs.add(v);
      case '--manifest':
        final v = next();
        if (v == null) {
          err('ERROR: --manifest needs a path');
          return rcUsage;
        }
        manifestArgs.add(v);
      case '--sentinel':
        final v = next();
        if (v == null || v.length < 8) {
          err('ERROR: --sentinel needs a token of at least 8 characters');
          return rcUsage;
        }
        sentinel = v;
      case '--max-wire-seq':
        final v = next();
        final parsed = v == null ? null : int.tryParse(v);
        if (parsed == null) {
          err('ERROR: --max-wire-seq needs an integer');
          return rcUsage;
        }
        maxWireSeq = parsed;
      default:
        err('ERROR: unknown argument "$arg"');
        _usage(err);
        return rcUsage;
    }
  }

  if (journalArgs.isEmpty || manifestArgs.isEmpty) {
    err('ERROR: at least one --journal and one --manifest are required');
    _usage(err);
    return rcUsage;
  }

  // ---- gather journals ------------------------------------------------------
  final journals = <WireJournal>[];
  final unusable = <String>[];
  for (final path in journalArgs) {
    final dir = Directory(path);
    final file = File(path);
    if (dir.existsSync()) {
      final found = dir
          .listSync(recursive: true)
          .whereType<File>()
          .where(
            (f) => kJournalExtensions.any((e) => f.path.endsWith(e)),
          )
          .toList();
      if (found.isEmpty) {
        unusable.add(
          '$path [no journals] — directory holds no '
          '${kJournalExtensions.join('/')} file; nothing was scanned.',
        );
        continue;
      }
      for (final f in found) {
        final j = _readJournal(f.path, unusable);
        if (j != null) journals.add(j);
      }
    } else if (file.existsSync()) {
      final j = _readJournal(path, unusable);
      if (j != null) journals.add(j);
    } else {
      unusable.add(
        '$path [absent] — the wire journal does not exist; C1\'s proxy never '
        'wrote it, so nothing was scanned.',
      );
    }
  }

  // ---- gather manifests -----------------------------------------------------
  final manifests = <WireCanaryManifest>[];
  for (final path in manifestArgs) {
    final file = File(path);
    if (!file.existsSync()) {
      unusable.add(
        '$path [absent] — expected the scenario\'s manifest (or the drive '
        'log carrying it); nothing was read.',
      );
      continue;
    }
    final String text;
    try {
      text = file.readAsStringSync();
    } on FileSystemException catch (e) {
      unusable.add('$path [unreadable] — ${e.osError?.message ?? 'IO error'}');
      continue;
    }
    if (text.isEmpty) {
      unusable.add('$path [empty] — 0 bytes; the capture never wrote it.');
      continue;
    }
    try {
      manifests.addAll(WireCanaryManifest.parseAll(text));
    } on FormatException catch (e) {
      unusable.add('$path [malformed manifest] — ${e.message}');
    }
    // No `on Object` here: `run`'s outer guard owns that, and swallowing an
    // unexpected throw per-file would let a second manifest's parse hide the
    // first one's crash behind a clean verdict.
  }

  // The lane passes the SAME token to the drive (as a --dart-define) and to
  // both host oracles, so the two halves cannot drift. Requiring it to match
  // what the drive announced catches the case where they did.
  if (sentinel != null) {
    for (final m in manifests) {
      if (m.sentinelToken != null && m.sentinelToken != sentinel) {
        unusable.add(
          '[${m.role}] --sentinel does not match the token the drive '
          'announced. The lane handed the two halves different strings, so '
          'the snapshot boundary this oracle would anchor on is not the one '
          'the run actually emitted.',
        );
      }
      if (m.sentinelToken == null) {
        unusable.add(
          '[${m.role}] --sentinel was supplied but the drive announced no '
          'sentinel, so nothing anchors this read.',
        );
      }
    }
  }

  // ---- scan -----------------------------------------------------------------
  final report = WireCanaryScanner.scan(
    journals: journals,
    manifests: manifests,
    maxWireSeq: maxWireSeq,
  );

  for (final line in report.renderLines(discloseValues: discloseValues)) {
    err(line);
  }
  for (final u in unusable) {
    err('UNUSABLE: $u');
  }
  // Only real coverage gaps are announced. Aliases (base64url that equals
  // base64, truncation that equals rounding) are recorded on the report but
  // not printed: dozens of them would bury the ones that matter.
  //
  // De-duplicated by label, because a multi-role run expands the same canary
  // ids once per role and the gaps are a property of the ENCODING, not of who
  // planted it. Printing every gap on every run is deliberate: a limitation
  // that is only in a doc comment is one nobody reads at the moment it
  // matters.
  final announced = <String>{};
  for (final d in report.dropped.where((d) => d.isCoverageGap)) {
    if (!announced.add(d.term.label)) continue;
    out('note: term ${d.term.label} NOT searched for — ${d.reason}');
  }

  final leaked = report.findings.isNotEmpty;
  if (leaked) {
    err('');
    err('ERROR: a planted canary reached the wire (see LEAK line(s) above).');
    err('       The journal now holds plaintext of a value that must never');
    err('       leave the device. Do NOT upload it as a build artifact.');
    return rcLeak;
  }
  if (unusable.isNotEmpty || report.unusable.isNotEmpty) {
    err('');
    err('ERROR: UNUSABLE — the recorder broke, so the canary scan could not');
    err('       be performed. An absent, blind or unanchored journal is NOT');
    err('       a clean journal. This run carries no evidence about content');
    err('       leakage either way. Fix the recorder, not the scenario.');
    return rcUnusable;
  }
  if (report.vacuities.isNotEmpty) {
    err('');
    err('ERROR: META-FLOOR — the journal is fine but proves too little. A');
    err('       canary the scenario never confirmed it PLANTED, or whose');
    err('       carrier never appeared, makes "it never showed up"');
    err('       unfalsifiable: a forbid-check over a value that was never');
    err('       applied, or over a window that never contained it, passes');
    err('       for free. Fix the scenario, not the recorder.');
    return rcMetaFloor;
  }
  out(report.summary);
  return rcClean;
}

WireJournal? _readJournal(String path, List<String> unusable) {
  final file = File(path);
  final String text;
  try {
    text = file.readAsStringSync();
  } on FileSystemException catch (e) {
    unusable.add('$path [unreadable] — ${e.osError?.message ?? 'IO error'}');
    return null;
  }
  if (text.isEmpty) {
    unusable.add(
      '$path [empty] — 0 bytes; the recording proxy never wrote a frame.',
    );
    return null;
  }
  return WireJournal.parse(text, path: path);
}

void _usage(void Function(String) sink) {
  sink('''
Usage:
  dart tooling/e2e/ci/check-wire-canaries.dart \\
       --journal <file-or-dir> [--journal ...] \\
       --manifest <drive-log-or-manifest> [--manifest ...] \\
       [--sentinel <token>] [--max-wire-seq N] [--disclose-values]
  dart tooling/e2e/ci/check-wire-canaries.dart --self-test

Exit: 0 clean, 1 canary on the wire, 2 usage,
      3 UNUSABLE (recorder broke), 4 META-FLOOR (scenario broke).''');
}

// =============================================================================
// Self-test
// =============================================================================

/// End-to-end assertions over [run] itself.
///
/// Toolchain-only (no relay, no device, no network), so an E2E lane can prove
/// the oracle still separates a leaking journal from a clean one BEFORE it
/// trusts the oracle's verdict on the real run. The per-encoding red/green
/// matrix lives in `haven/test/e2e/wire_canaries_test.dart`; this half exists
/// because that half never executes `run`.
int selfTest(void Function(String) out, void Function(String) err) {
  final tmp = Directory.systemTemp.createTempSync('wire-canary-selftest');
  var failed = 0;

  void expectRc(int want, String desc, List<String> args) {
    final got = run(args, (_) {}, (_) {});
    if (got != want) {
      err('SELF-TEST FAIL: $desc — expected rc=$want, got rc=$got');
      failed++;
    }
  }

  try {
    final plant = WireCanaryPlant.mint(role: 'solo')
      ..recordCircleNameCarrier('a' * 64)
      ..recordCoordinateCarrier('b' * 64)
      ..recordPetnameOpportunity('c' * 64);
    // A plant the scenario confirmed took. Without these the run is a
    // META-FLOOR, which is the whole point of them: carrier ids alone cannot
    // tell a genuine carrier from any published event id.
    plant
      ..confirmCircleNamePlanted(plant.circleDisplayName)
      ..confirmPetnamePlanted(plant.petname)
      ..confirmCoordinatePlanted(
        latitude: plant.latitude,
        longitude: plant.longitude,
      );
    final manifest = File('${tmp.path}/drive.log')
      ..writeAsStringSync(
        'I/flutter: starting\n${plant.manifest().toAnnouncementLine()}\n',
      );

    // Shaped exactly like docs/WIRE_JOURNAL.md: a `type` on every line,
    // `relay_url`/`listen` on traffic, and lifecycle records that carry
    // NEITHER `dir` NOR `frame`. Reading a missing `frame` as "unparseable"
    // scores one blind spot per connection and reports every healthy journal
    // as UNUSABLE — the failure this fixture exists to make impossible.
    const endpoint =
        '"relay_url":"ws://127.0.0.1:7777","listen":"127.0.0.1:7788"';
    String eventLine(int seq, String id, String content) =>
        '{"wire_seq":$seq,"type":"frame","conn_id":"c1",'
        '"ts_ms":1785886144123,"dir":"c2r",$endpoint,'
        '"frame":["EVENT",{"id":"$id","kind":445,"pubkey":"${'d' * 64}",'
        '"created_at":1785886144,"tags":[["h","${'e' * 64}"]],'
        '"content":"$content","sig":"${'f' * 128}"}],"raw_len":400}';
    const connOpen =
        '{"wire_seq":900,"type":"conn_open","conn_id":"c1",'
        '"ts_ms":1785886144000,$endpoint}';
    const connError =
        '{"wire_seq":901,"type":"conn_error","conn_id":"c9",'
        '"ts_ms":1785886144010,"relay_url":"ws://127.0.0.1:9999",'
        '"listen":"127.0.0.1:7788","reason":"upstream connect failed"}';

    // A clean journal that still CARRIES every canary's carrier events. The
    // trailing newline matters: a final line without one is reported as a
    // truncated tail, which is its own failure class.
    final cleanText = <String>[
      connOpen,
      eventLine(0, 'a' * 64, 'AgID' * 20),
      eventLine(1, 'b' * 64, 'BAUG' * 20),
      eventLine(2, 'c' * 64, 'BwgJ' * 20),
      connError,
    ].map((line) => '$line\n').join();
    final clean = File('${tmp.path}/clean.ndjson')
      ..writeAsStringSync(cleanText);

    expectRc(rcClean, 'clean journal with all carriers present', <String>[
      '--journal', clean.path, '--manifest', manifest.path,
    ]);

    // The same journal with the circle name in the clear on one frame.
    final leaking = File('${tmp.path}/leaking.ndjson')
      ..writeAsStringSync(
        '${clean.readAsStringSync().trimRight()}\n'
        '{"wire_seq":3,"type":"frame","conn_id":"c1","ts_ms":1785886144999,'
        '"dir":"c2r",$endpoint,'
        '"frame":["EVENT",{"id":"${'9' * 64}","kind":445,'
        '"pubkey":"${'d' * 64}","created_at":1785886145,'
        '"tags":[["h","${'e' * 64}"],'
        '["name","${plant.circleDisplayName}"]],"content":"",'
        '"sig":"${'f' * 128}"}],"raw_len":400}\n',
      );
    expectRc(rcLeak, 'journal with a plaintext circle-name canary', <String>[
      '--journal', leaking.path, '--manifest', manifest.path,
    ]);

    // META-FLOOR, not UNUSABLE: the journal is well-formed, the SCENARIO
    // failed to put the canaries' carriers anywhere the recorder could see.
    final uncovered = File('${tmp.path}/uncovered.ndjson')
      ..writeAsStringSync('${eventLine(0, '1' * 64, 'AgID' * 20)}\n');
    expectRc(rcMetaFloor, 'journal missing every carrier event', <String>[
      '--journal', uncovered.path, '--manifest', manifest.path,
    ]);

    // Evidence failures.
    final empty = File('${tmp.path}/empty.ndjson')..writeAsStringSync('');
    expectRc(rcUnusable, 'empty journal', <String>[
      '--journal', empty.path, '--manifest', manifest.path,
    ]);
    expectRc(rcUnusable, 'absent journal', <String>[
      '--journal', '${tmp.path}/never-written.ndjson',
      '--manifest', manifest.path,
    ]);
    final noManifest = File('${tmp.path}/plain.log')
      ..writeAsStringSync('I/flutter: nothing was planted here\n');
    expectRc(rcMetaFloor, 'drive log carrying no manifest', <String>[
      '--journal', clean.path, '--manifest', noManifest.path,
    ]);
    final emptyDir = Directory('${tmp.path}/nojournals')..createSync();
    File('${emptyDir.path}/README.txt').writeAsStringSync('not a journal');
    expectRc(rcUnusable, 'directory with no journal files', <String>[
      '--journal', emptyDir.path, '--manifest', manifest.path,
    ]);

    // A leak outranks missing evidence when both are present, so callers can
    // key containment off rc=1 alone.
    expectRc(rcLeak, 'leaking journal + absent journal', <String>[
      '--journal', leaking.path,
      '--journal', '${tmp.path}/never-written.ndjson',
      '--manifest', manifest.path,
    ]);

    // Anchoring. A sentinel the drive announced but the journal never
    // recorded means the traffic did not go through the proxy — which is
    // indistinguishable from a quiet run without this check.
    final anchoredPlant = WireCanaryPlant.mint(role: 'solo')
      ..recordCircleNameCarrier('a' * 64)
      ..recordCoordinateCarrier('b' * 64)
      ..recordPetnameOpportunity('c' * 64)
      ..recordSentinel(token: 'HAVEN_WIRE_SENTINEL:selftest01', wireSeq: 77);
    anchoredPlant
      ..confirmCircleNamePlanted(anchoredPlant.circleDisplayName)
      ..confirmPetnamePlanted(anchoredPlant.petname)
      ..confirmCoordinatePlanted(
        latitude: anchoredPlant.latitude,
        longitude: anchoredPlant.longitude,
      );
    final anchoredManifest = File('${tmp.path}/anchored.log')
      ..writeAsStringSync(
        '${anchoredPlant.manifest().toAnnouncementLine()}\n',
      );
    expectRc(rcUnusable, 'sentinel announced but never recorded', <String>[
      '--journal', clean.path, '--manifest', anchoredManifest.path,
    ]);

    final anchored = File('${tmp.path}/anchored.ndjson')
      ..writeAsStringSync(
        '${clean.readAsStringSync()}'
        '{"wire_seq":77,"type":"frame","conn_id":"c1",'
        '"ts_ms":1785886145000,"dir":"c2r",$endpoint,'
        '"frame":["HAVEN_WIRE_SENTINEL",'
        '"HAVEN_WIRE_SENTINEL:selftest01"],"raw_len":60}\n',
      );
    expectRc(rcClean, 'sentinel recorded at the acked wire_seq', <String>[
      '--journal', anchored.path, '--manifest', anchoredManifest.path,
    ]);
    expectRc(rcUnusable, 'sentinel token mismatch between the halves',
        <String>[
      '--journal', anchored.path, '--manifest', anchoredManifest.path,
      '--sentinel', 'HAVEN_WIRE_SENTINEL:somethingelse',
    ]);

    // A minted-but-never-applied plant. Every carrier is present and sent,
    // and the journal is spotless — this is the run that used to report rc=0
    // while proving nothing, because "the value never appeared" is free when
    // the value was never applied to anything.
    final unplanted = WireCanaryPlant.mint(role: 'solo')
      ..recordCircleNameCarrier('a' * 64)
      ..recordCoordinateCarrier('b' * 64)
      ..recordPetnameOpportunity('c' * 64);
    final unplantedManifest = File('${tmp.path}/unplanted.log')
      ..writeAsStringSync('${unplanted.manifest().toAnnouncementLine()}\n');
    expectRc(rcMetaFloor, 'carriers recorded but no plant confirmed', <String>[
      '--journal', clean.path, '--manifest', unplantedManifest.path,
    ]);

    // A manifest whose carrier list holds a non-string. `(e as String)` threw
    // a TypeError here, which is an Error rather than an Exception: it walked
    // past every `on FormatException` and exited 255 with a stack trace,
    // against a header that promises exactly five codes.
    final mistyped = File('${tmp.path}/mistyped.log')
      ..writeAsStringSync(
        '$kCanaryManifestMarker'
        '{"role":"solo","circle_display_name":"x","petname":"y",'
        '"latitude":1.0,"longitude":2.0,'
        '"carrier_event_ids":{"circle_display_name":[123],'
        '"petname":[],"coordinate":[]}}\n',
      );
    expectRc(rcUnusable, 'manifest carrier id is not a string', <String>[
      '--journal', clean.path, '--manifest', mistyped.path,
    ]);

    // A binary frame the proxy rendered with from_utf8_lossy and that fits
    // under the 200-character preview cap. It LOOKS complete; the U+FFFD and
    // the raw_len disagreement are the only evidence that bytes were lost.
    final lossy = File('${tmp.path}/lossy.ndjson')
      ..writeAsStringSync(
        '${clean.readAsStringSync()}'
        '{"wire_seq":4,"type":"frame","conn_id":"c1","ts_ms":1785886146000,'
        '"dir":"c2r",$endpoint,"frame":null,'
        '"raw_preview":"ab\\uFFFD\\uFFFDcd","raw_len":64}\n',
      );
    expectRc(rcUnusable, 'short lossy binary preview is a blind spot',
        <String>[
      '--journal', lossy.path, '--manifest', manifest.path,
    ]);

    // Usage errors stay distinct from all four verdicts.
    expectRc(rcUsage, 'no arguments', const <String>[]);
    expectRc(rcUsage, 'journal without manifest', <String>[
      '--journal', clean.path,
    ]);
    expectRc(rcUsage, 'unknown flag', <String>[
      '--journal', clean.path, '--manifest', manifest.path, '--nope',
    ]);
  } finally {
    tmp.deleteSync(recursive: true);
  }

  if (failed > 0) {
    err('check-wire-canaries: SELF-TEST FAILED ($failed case(s))');
    return rcLeak;
  }
  out(
    'check-wire-canaries: self-test passed (clean clears; a planted canary '
    'is caught; absent/empty/uncovered/lossy journals and a mistyped '
    'manifest fail loudly; and a run that recorded carriers without ever '
    'confirming a plant is a META-FLOOR, not a pass).',
  );
  return rcClean;
}
