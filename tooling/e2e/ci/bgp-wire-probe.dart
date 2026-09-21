#!/usr/bin/env dart
// bgp-wire-probe.dart — the HOST's wire oracle for P3's settle window.
//
// P3 of the e2e-ios-background-publish lane promises that disabling background
// sharing while the app is still OS-backgrounded stops publishing. The drive
// target proves that from INSIDE the app: it snapshots the relay's kind-445
// set, disables, waits out one full max-jitter interval and diffs. That proof
// dies with the app — and the app is entitled to die there, because the
// disable is exactly what removes its claim to execute in the background. In
// CI runs 35397118356 and 35622556197 iOS took the process 37-42 s into the
// window and the lane could say only "P3 was neither proved nor disproved".
//
// This probe is the same question asked from a process the OS cannot reclaim:
// the relay is on the host, it holds what the app published, and it answers
// whether or not the app still exists. It is also the only oracle that would
// see a BACKGROUND RELAUNCH publishing after the reclaim — the defect P3
// exists to catch, and the one an in-app oracle can never observe.
//
// # Why a count is enough here, when the drive needs an id diff
//
// The drive runs while OTHER publishers are alive, so it discriminates by
// event id against a baseline. By the time this runs, the synthetic peer has
// been disposed (`bob.dispose()` precedes P3 in the drive, deliberately) and
// the app under test is the only thing on this relay that can author a
// kind-445 for any circle. So every kind-445 created inside the window is
// Alice's, and a COUNT over that window is the whole answer. Bringing Bob
// back inside P3 would break that, which is why the drive's ordering is
// pinned by the lane's guard rather than left to convention.
//
// # Fail closed, with TWO controls
//
// "The relay answered nothing" and "the probe could not read the relay" are
// the same observation to a caller that only counts, and this repo has
// reported the second as the first before. So every run also asks two
// questions whose answers CANNOT be zero on a healthy lane. Either coming back
// empty is reported as `no verdict` (rc 4), never as silence.
//
//   1. The account's KeyPackage (kind 30443), which the invitation flow must
//      have published and which carries no NIP-40 expiration. It proves the
//      relay is answering this probe at all.
//   2. At least one kind-445 in the 230 s BEFORE the disable. This is the one
//      that certifies the class actually under test: a relay that served
//      30443 but no longer served 445 — a kind filter lost, a store that
//      dropped them — would answer "silent" for the window and read as a
//      healthy P3. P1/P2 guarantee this event exists: the publish scheduler
//      ticks every 72-168 s, and the lane has already asserted
//      BACKGROUND_PUBLISH_OK by the time the disable is signalled.
//
// Why 230 s and not the 228 s NIP-40 expiration those events carry: this
// relay (nostr-relay-builder 0.44.1 over nostr-database 0.44.0) enforces
// expiry at INGEST ONLY — `internal_index_event` rejects an already-expired
// event, queries never filter on expiry, and there is no sweeper — so an event
// it accepted is still served afterwards. The bound is therefore about which
// publishes are the app's pre-disable ones, not about what survives.
//
// The RANGE arithmetic has no run-time control — an empty window looks the
// same whether the range is right or inverted — so it is proven by
// `--self-test` instead: a planted in-window event must be SEEN (rc 1), and a
// planted event one second past the window must not be. The lane runs that
// self-test on the runner before it depends on this probe, the same preflight
// discipline `start-wire-proxy.sh` applies to the recording proxy.
//
// # Rule 15
//
// Nothing this prints can single out a user, a circle, a device or a relay:
// counts are bucketed (`0 | 1 | 2-4 | 5+`, the same buckets as
// `haven_core::log_alias::bucket` and Dart's `magnitudeBucket` — duplicated
// here because those live behind `package:flutter`, which a plain `dart`
// script cannot load), the relay URL is an argument and never an output, and
// relay-authored prose (NOTICE/CLOSED text) is never echoed.
//
// Usage:
//   dart tooling/e2e/ci/bgp-wire-probe.dart \
//     --relay ws://127.0.0.1:7777 --since <epoch> --until <epoch> \
//     --disable-at <epoch> [--deadline <secs>]
//   dart tooling/e2e/ci/bgp-wire-probe.dart --self-test
//
// Exit status:
//   0  both controls answered AND no kind-445 was created inside the window
//   1  at least one kind-445 was created inside the window — P3 broken
//   2  usage
//   3  the wire could not be read (no connection, no EOSE, refused REQ)
//   4  a control came back empty — the probe proved nothing either way

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// The account KeyPackage kind. Addressable, never expiring, and structurally
/// guaranteed on this lane: the synthetic peer cannot be invited without one.
const int kControlKind = 30443;

/// The group-message kind P3 must see none of inside its window.
const int kSettleKind = 445;

/// How far back of the disable the second control looks for a kind-445.
///
/// Wider than one full publish interval (`kLocationPublishMaxInterval`, 168 s)
/// plus the scheduler's jitter, so a healthy lane always has one to find.
const int kPreDisableControlSecs = 230;

/// The `limit` this probe states on every REQ it sends.
///
/// Stated rather than left out: nostr-relay-builder injects its own
/// `default_filter_limit` (500) into any filter that omits one, so a probe
/// with no limit has a ceiling set by a relay configuration nothing here
/// reads. The verdicts are "is this count zero" and a bucketed magnitude, so
/// the exact ceiling never changes an answer — only which file owns it.
const int kFilterLimit = 500;

/// How long the probe waits for both subscriptions to reach EOSE.
///
/// The relay is on loopback and the store is in memory, so a healthy answer
/// takes milliseconds; this is a wedge bound, not a budget. It runs after the
/// window has already elapsed, so nothing downstream is waiting on it.
const int kDefaultDeadlineSecs = 15;

Future<void> main(List<String> args) async {
  exitCode = await run(args, stdout.writeln, stderr.writeln);
}

/// Buckets an exact count into a magnitude that cannot single out a specific
/// circle, member or event by its precise size (Rule 15).
String magnitudeBucket(int count) {
  if (count <= 0) return '0';
  if (count == 1) return '1';
  if (count <= 4) return '2-4';
  return '5+';
}

/// What one pass over the relay observed.
class ProbeReading {
  ProbeReading.read({
    required this.controlCount,
    required this.preDisableCount,
    required this.windowCount,
  }) : unreadable = null;

  ProbeReading.unreadable(String why)
    : controlCount = 0,
      preDisableCount = 0,
      windowCount = 0,
      unreadable = why;

  /// Events answering the control question. Zero means the probe proved
  /// nothing, never that the window was silent.
  final int controlCount;

  /// kind-445 events in the [kPreDisableControlSecs] before the disable. Zero
  /// means this relay was not serving the very kind the window is read for, so
  /// the window's own emptiness proves nothing.
  final int preDisableCount;

  /// kind-445 events whose `created_at` falls inside the settle window.
  final int windowCount;

  /// Why the relay could not be read, or null when it was.
  ///
  /// A fixed phrase chosen by this file — never relay-authored text, which
  /// Rule 15 keeps out of every log.
  final String? unreadable;
}

/// Runs the probe. Returns the process exit status.
Future<int> run(
  List<String> args,
  void Function(String) out,
  void Function(String) err,
) async {
  if (args.length == 1 && args.first == '--self-test') {
    return _selfTest(out, err);
  }

  String? relay;
  int? since;
  int? until;
  int? disableAt;
  var deadline = kDefaultDeadlineSecs;
  for (var i = 0; i < args.length; i++) {
    final String arg = args[i];
    final String? value = i + 1 < args.length ? args[i + 1] : null;
    switch (arg) {
      case '--relay':
        relay = value;
        i++;
      case '--since':
        since = value == null ? null : int.tryParse(value);
        i++;
      case '--until':
        until = value == null ? null : int.tryParse(value);
        i++;
      case '--disable-at':
        disableAt = value == null ? null : int.tryParse(value);
        i++;
      case '--deadline':
        final int? parsed = value == null ? null : int.tryParse(value);
        if (parsed == null || parsed <= 0) {
          err('bgp-wire-probe: --deadline must be a positive integer.');
          return 2;
        }
        deadline = parsed;
        i++;
      default:
        err('bgp-wire-probe: unknown argument.');
        _usage(err);
        return 2;
    }
  }
  if (relay == null ||
      relay.isEmpty ||
      since == null ||
      until == null ||
      disableAt == null) {
    err(
      'bgp-wire-probe: --relay, --since, --until and --disable-at are all '
      'required.',
    );
    _usage(err);
    return 2;
  }
  if (until < since) {
    // An inverted range answers "silent" for every relay there is, so it is
    // refused rather than reported.
    err(
      'bgp-wire-probe: the window ends before it begins, so it could only '
      'ever report silence. Refusing to answer.',
    );
    return 2;
  }

  final ProbeReading reading = await readRelay(
    url: relay,
    since: since,
    until: until,
    disableAt: disableAt,
    deadline: Duration(seconds: deadline),
  );
  return verdict(reading, out, err);
}

/// Turns one [ProbeReading] into this probe's exit status, saying in one line
/// what was proven. Pure, so `--self-test` can drive it over planted readings.
int verdict(
  ProbeReading reading,
  void Function(String) out,
  void Function(String) err,
) {
  final String? why = reading.unreadable;
  if (why != null) {
    err(
      'bgp-wire-probe: the settle window has no verdict — $why. An unread '
      'relay is not a silent one.',
    );
    return 3;
  }
  if (reading.windowCount > 0) {
    err(
      'bgp-wire-probe: ${magnitudeBucket(reading.windowCount)} kind-445 '
      "event(s) were created INSIDE P3's settle window. Publishing did not "
      'stop when background sharing was disabled.',
    );
    return 1;
  }
  if (reading.controlCount <= 0) {
    err(
      'bgp-wire-probe: the control question came back empty, so this read '
      'proves nothing about the window. Treating it as no verdict rather '
      'than as silence.',
    );
    return 4;
  }
  if (reading.preDisableCount <= 0) {
    err(
      'bgp-wire-probe: the relay answered, but served no kind-445 from the '
      '${kPreDisableControlSecs}s BEFORE the disable — publishes the lane has '
      'already asserted were happening. An empty settle window proves nothing '
      'against a relay that is not serving that kind. Treating it as no '
      'verdict rather than as silence.',
    );
    return 4;
  }
  out(
    'bgp-wire-probe: the relay answered (control '
    '${magnitudeBucket(reading.controlCount)}, pre-disable kind-445 '
    '${magnitudeBucket(reading.preDisableCount)}) and held '
    '${magnitudeBucket(reading.windowCount)} kind-445 event(s) inside the '
    'settle window.',
  );
  return 0;
}

/// Opens ONE connection, asks both questions on it, and returns what came
/// back. Both subscriptions must reach EOSE; anything else is unreadable.
Future<ProbeReading> readRelay({
  required String url,
  required int since,
  required int until,
  required int disableAt,
  required Duration deadline,
}) async {
  final Random random = Random.secure();
  String subId(String tag) {
    final int salt = random.nextInt(0x7fffffff);
    return 'bgp-$tag-${salt.toRadixString(16)}';
  }

  final String controlSub = subId('c');
  final String settleSub = subId('s');
  final String priorSub = subId('p');
  final int priorSince = disableAt - kPreDisableControlSecs;

  WebSocket socket;
  try {
    socket = await WebSocket.connect(url).timeout(deadline);
  } on Object {
    // Never the exception's text: a connection error renders the endpoint.
    return ProbeReading.unreadable('the relay accepted no connection');
  }

  var controlCount = 0;
  var preDisableCount = 0;
  var windowCount = 0;
  var controlDone = false;
  var settleDone = false;
  var priorDone = false;
  String? refused;
  final Completer<void> finished = Completer<void>();

  void settle() {
    if (controlDone && settleDone && priorDone && !finished.isCompleted) {
      finished.complete();
    }
  }

  final StreamSubscription<dynamic> frames = socket.listen(
    (dynamic raw) {
      if (raw is! String) return;
      final Object? decoded = _decode(raw);
      if (decoded is! List || decoded.isEmpty) return;
      final Object? verb = decoded.first;
      if (verb == 'EVENT' && decoded.length >= 3) {
        final Object? sub = decoded[1];
        final Object? event = decoded[2];
        if (event is! Map) return;
        final Object? kind = event['kind'];
        final Object? createdAt = event['created_at'];
        if (kind is! int || createdAt is! int) return;
        // The kind and the range are re-checked HERE rather than trusted to
        // the REQ filter: a relay that widened a filter would otherwise be
        // read as a leak, and one that narrowed it as silence.
        if (sub == controlSub && kind == kControlKind) {
          controlCount++;
        } else if (sub == settleSub &&
            kind == kSettleKind &&
            createdAt >= since &&
            createdAt <= until) {
          windowCount++;
        } else if (sub == priorSub &&
            kind == kSettleKind &&
            createdAt >= priorSince &&
            createdAt <= disableAt) {
          preDisableCount++;
        }
      } else if (verb == 'EOSE' && decoded.length >= 2) {
        if (decoded[1] == controlSub) controlDone = true;
        if (decoded[1] == settleSub) settleDone = true;
        if (decoded[1] == priorSub) priorDone = true;
        settle();
      } else if (verb == 'CLOSED' && decoded.length >= 2) {
        // The relay refused a subscription. Its reason is remote-authored
        // prose (Rule 15) and is deliberately not carried out of here.
        if (decoded[1] == controlSub ||
            decoded[1] == settleSub ||
            decoded[1] == priorSub) {
          refused ??= 'the relay refused the subscription';
          if (!finished.isCompleted) finished.complete();
        }
      }
    },
    onError: (Object _) {
      refused ??= 'the connection failed mid-read';
      if (!finished.isCompleted) finished.complete();
    },
    onDone: () {
      if (!controlDone || !settleDone || !priorDone) {
        refused ??= 'the relay closed before it finished answering';
      }
      if (!finished.isCompleted) finished.complete();
    },
    cancelOnError: false,
  );

  // Every filter states its own `since`/`until` where it has one AND its own
  // `limit`; the ranges are re-checked above regardless, so a relay that
  // widens a filter cannot be read as a leak nor one that narrows it as
  // silence.
  socket.add(
    jsonEncode(<Object>[
      'REQ',
      controlSub,
      <String, Object>{
        'kinds': <int>[kControlKind],
        'limit': kFilterLimit,
      },
    ]),
  );
  socket.add(
    jsonEncode(<Object>[
      'REQ',
      settleSub,
      <String, Object>{
        'kinds': <int>[kSettleKind],
        'since': since,
        'until': until,
        'limit': kFilterLimit,
      },
    ]),
  );
  socket.add(
    jsonEncode(<Object>[
      'REQ',
      priorSub,
      <String, Object>{
        'kinds': <int>[kSettleKind],
        'since': priorSince,
        'until': disableAt,
        'limit': kFilterLimit,
      },
    ]),
  );

  var timedOut = false;
  try {
    await finished.future.timeout(deadline);
  } on TimeoutException {
    timedOut = true;
  }

  socket.add(jsonEncode(<Object>['CLOSE', controlSub]));
  socket.add(jsonEncode(<Object>['CLOSE', settleSub]));
  socket.add(jsonEncode(<Object>['CLOSE', priorSub]));
  await frames.cancel();
  await socket.close().catchError((Object _) => null);

  if (refused != null) return ProbeReading.unreadable(refused!);
  if (timedOut || !controlDone || !settleDone || !priorDone) {
    return ProbeReading.unreadable('the relay never finished answering');
  }
  return ProbeReading.read(
    controlCount: controlCount,
    preDisableCount: preDisableCount,
    windowCount: windowCount,
  );
}

Object? _decode(String raw) {
  try {
    return jsonDecode(raw);
  } on FormatException {
    return null;
  }
}

void _usage(void Function(String) err) {
  err('''
Usage:
  dart tooling/e2e/ci/bgp-wire-probe.dart \\
    --relay <ws-url> --since <epoch> --until <epoch> --disable-at <epoch> \\
    [--deadline <secs>]
  dart tooling/e2e/ci/bgp-wire-probe.dart --self-test''');
}

// ---------------------------------------------------------------------------
// --self-test — hermetic. The fixtures are the ways this probe could report a
// window it never read, or miss one it did.
// ---------------------------------------------------------------------------

/// How many fixtures the suite must RUN, pinned by equality: a count printed
/// from whatever ran would report "all passed" over a deleted fixture.
const int kSelfTestFixtures = 13;

Future<int> _selfTest(
  void Function(String) out,
  void Function(String) err,
) async {
  var failures = 0;
  var checked = 0;
  void check(String label, int want, int got) {
    checked++;
    if (want == got) {
      out('  PASS $label');
    } else {
      err('  FAIL $label (want rc=$want, got rc=$got)');
      failures++;
    }
  }

  // The lane's own arithmetic: `since` is the disable plus the in-flight
  // grace, `until` the disable plus the settle window.
  const int base = 1700000000;
  const int disableAt = base;
  const int since = base + 10;
  const int until = base + 200;
  Map<String, Object?> event(int kind, int createdAt) => <String, Object?>{
    'kind': kind,
    'created_at': createdAt,
  };
  final Map<String, Object?> keyPackage = event(kControlKind, base - 600);
  // One publish inside the 230 s before the disable — what P1/P2 guarantee,
  // and what proves this relay still serves the kind the window is read for.
  final Map<String, Object?> preDisable445 = event(kSettleKind, disableAt - 60);

  Future<int> against(
    List<Map<String, Object?>> events, {
    bool eose = true,
    int deadlineSecs = kDefaultDeadlineSecs,
  }) async {
    final _FakeRelay relay = await _FakeRelay.start(events: events, eose: eose);
    try {
      return await run(
        <String>[
          '--relay',
          'ws://127.0.0.1:${relay.port}',
          '--since',
          '$since',
          '--until',
          '$until',
          '--disable-at',
          '$disableAt',
          '--deadline',
          '$deadlineSecs',
        ],
        (String _) {},
        (String _) {},
      );
    } finally {
      await relay.close();
    }
  }

  // S1 — the shape a healthy P3 produces: both controls answer, and the only
  // kind-445 on the relay predates the disable.
  check(
    'S1 both controls answered and the window is empty',
    0,
    await against(<Map<String, Object?>>[keyPackage, preDisable445]),
  );

  // S2 — NON-VACUITY, the fixture the whole instrument rests on: a kind-445
  // planted INSIDE the window must be seen and reported as a leak. Without
  // this, rc 0 could mean "reads nothing" just as well as "silent".
  check(
    'S2 a planted in-window kind-445 is SEEN',
    1,
    await against(<Map<String, Object?>>[
      keyPackage,
      preDisable445,
      event(kSettleKind, since + 5),
    ]),
  );

  // S3 — the upper boundary. The host re-foregrounds the app when the window
  // ends and a foregrounded Haven publishes BY DESIGN, so an event one second
  // past the window must not count. (The fake ignores `since`, so this also
  // proves the probe's own range filter does the work rather than the relay.)
  check(
    'S3 an event one second past the window is not a leak',
    0,
    await against(<Map<String, Object?>>[
      keyPackage,
      preDisable445,
      event(kSettleKind, until + 1),
    ]),
  );

  // S4 — the kind discriminator. Other kinds keep flowing inside the window
  // (relay lists, KeyPackages, profiles); only 445 is publishing.
  check(
    'S4 a non-445 inside the window is not a leak',
    0,
    await against(<Map<String, Object?>>[
      keyPackage,
      preDisable445,
      event(kControlKind, since + 5),
    ]),
  );

  // C1 — a relay that answers no KeyPackage must be `no verdict`, never
  // silence. It still serves 445, so this isolates the first control.
  check(
    'C1 an empty KeyPackage control reports no verdict',
    4,
    await against(<Map<String, Object?>>[preDisable445]),
  );

  // C2 — the second control, and the class it certifies: a relay answering
  // 30443 perfectly while serving no kind-445 from before the disable. Each
  // case differs from S1 by exactly where its single 445 sits.
  //
  // C2a puts it AFTER the window, which is the vacuity that would really
  // happen: the wrapper re-foregrounds the app before running this probe and a
  // foregrounded Haven publishes by design, so a control without an upper
  // bound would be satisfied on every run by that publish alone — even on a
  // relay that had dropped every pre-disable 445. C2b puts it one second
  // before the control window opens, which is not a publish P1/P2 guarantee.
  check(
    'C2a a post-window 445 does not stand in for a pre-disable one',
    4,
    await against(<Map<String, Object?>>[
      keyPackage,
      event(kSettleKind, until + 5),
    ]),
  );
  check(
    'C2b a 445 older than the control window does not stand in either',
    4,
    await against(<Map<String, Object?>>[
      keyPackage,
      event(kSettleKind, disableAt - kPreDisableControlSecs - 1),
    ]),
  );

  // E1 — a relay that never says EOSE has not finished answering, so what was
  // collected so far is not an absence proof.
  check(
    'E1 a relay that never EOSEs is unreadable',
    3,
    await against(
      <Map<String, Object?>>[keyPackage],
      eose: false,
      deadlineSecs: 2,
    ),
  );

  // E2 — nothing listening. Port 1 is privileged and never bound by a test.
  check(
    'E2 a refused connection is unreadable',
    3,
    await run(
      <String>[
        '--relay',
        'ws://127.0.0.1:1',
        '--since',
        '$since',
        '--until',
        '$until',
        '--disable-at',
        '$disableAt',
        '--deadline',
        '2',
      ],
      (String _) {},
      (String _) {},
    ),
  );

  // L1/L2 — what the probe SENDS, which no verdict fixture can see because the
  // fake answers a superset and the probe re-checks every range itself.
  //
  // `limit`: the lane's relay (nostr-relay-builder 0.44.1) injects
  // `default_filter_limit` (500) into any filter that omits one, so a probe
  // without limits has a ceiling set by a config file nothing here reads.
  // `until` on the two windowed REQs: the relay applies that ceiling to the
  // most RECENT matches, and the wrapper re-foregrounds the app before this
  // runs — a foregrounded Haven publishes by design — so an unbounded settle
  // REQ would make in-window events compete for slots with publishes that are
  // not the question. Counting the REQs that state each, against three and
  // two, catches a dropped key and a dropped REQ alike.
  final _FakeRelay limitRelay = await _FakeRelay.start(
    events: <Map<String, Object?>>[keyPackage, preDisable445],
    eose: true,
  );
  int reqsStatingALimit;
  int reqsStatingAnUntil;
  try {
    await run(
      <String>[
        '--relay',
        'ws://127.0.0.1:${limitRelay.port}',
        '--since',
        '$since',
        '--until',
        '$until',
        '--disable-at',
        '$disableAt',
        '--deadline',
        '$kDefaultDeadlineSecs',
      ],
      (String _) {},
      (String _) {},
    );
    reqsStatingALimit = limitRelay.reqFilters
        .where((Map<Object?, Object?> filter) => filter['limit'] is int)
        .length;
    reqsStatingAnUntil = limitRelay.reqFilters
        .where((Map<Object?, Object?> filter) => filter['until'] is int)
        .length;
  } finally {
    await limitRelay.close();
  }
  check('L1 all three REQs state their own limit', 3, reqsStatingALimit);
  check('L2 both windowed REQs state their own until', 2, reqsStatingAnUntil);

  // U1/U2 — a missing bound and an inverted window are both usage errors.
  // Neither may fall through to "the window was silent".
  check(
    'U1 a missing --until is usage',
    2,
    await run(
      <String>[
        '--relay',
        'ws://127.0.0.1:1',
        '--since',
        '$since',
        '--disable-at',
        '$disableAt',
      ],
      (String _) {},
      (String _) {},
    ),
  );
  check(
    'U2 an inverted window is refused',
    2,
    await run(
      <String>[
        '--relay',
        'ws://127.0.0.1:1',
        '--since',
        '$until',
        '--until',
        '$since',
        '--disable-at',
        '$disableAt',
      ],
      (String _) {},
      (String _) {},
    ),
  );

  if (checked != kSelfTestFixtures) {
    err(
      'bgp-wire-probe: SELF-TEST FAIL — ran $checked fixture(s), expected '
      '$kSelfTestFixtures. Move the pin in the same commit that adds or '
      'removes one.',
    );
    return 1;
  }
  if (failures > 0) {
    err('bgp-wire-probe: SELF-TEST FAILED ($failures case(s))');
    return 1;
  }
  out(
    'bgp-wire-probe: self-test passed ($checked fixtures) — a planted '
    'in-window event reds, one past the window does not, an unread relay is '
    'never reported as a silent one, a relay serving KeyPackages but no '
    'kind-445 is no verdict rather than silence, and every REQ states its own '
    'limit and window rather than inheriting the relay defaults.',
  );
  return 0;
}

/// A NIP-01 relay just real enough to answer this probe.
///
/// It deliberately does NOT honour `since`: a real relay does, so serving a
/// superset is always safe, and it forces the probe's own range filter to be
/// the thing S3 measures rather than the fake's.
class _FakeRelay {
  _FakeRelay._(this._server, this.port);

  final HttpServer _server;
  final int port;

  /// Every filter it was asked for, in order, so a fixture can assert what the
  /// probe SENT rather than only what it did with the answer.
  final List<Map<Object?, Object?>> reqFilters = <Map<Object?, Object?>>[];

  static Future<_FakeRelay> start({
    required List<Map<String, Object?>> events,
    required bool eose,
  }) async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final _FakeRelay relay = _FakeRelay._(server, server.port);
    relay._serve(events, eose);
    return relay;
  }

  void _serve(List<Map<String, Object?>> events, bool eose) {
    _server.listen((HttpRequest request) async {
      final WebSocket socket = await WebSocketTransformer.upgrade(request);
      socket.listen((dynamic raw) {
        if (raw is! String) return;
        final Object? frame = jsonDecode(raw);
        if (frame is! List || frame.length < 3 || frame.first != 'REQ') return;
        final Object? sub = frame[1];
        final Object? filter = frame[2];
        if (sub is! String || filter is! Map) return;
        reqFilters.add(filter);
        final Object? kinds = filter['kinds'];
        for (final Map<String, Object?> event in events) {
          if (kinds is List && !kinds.contains(event['kind'])) continue;
          socket.add(jsonEncode(<Object?>['EVENT', sub, event]));
        }
        if (eose) socket.add(jsonEncode(<Object?>['EOSE', sub]));
      });
    });
  }

  Future<void> close() => _server.close(force: true);
}
