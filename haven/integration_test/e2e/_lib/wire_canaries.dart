/// Workstream C6 — content canaries for the relay-observer privacy oracle.
///
/// ## What a canary adds that C2–C5 do not
///
/// C2–C5 assert over *structure*: which kinds, which tags, which filters.
/// They can only reject a shape somebody thought to enumerate. A canary
/// asserts over *content*: it plants a value the test knows and requires that
/// value to be absent from every frame, in every encoding. That is the check
/// that survives a new MDK field, an unexpected serialization, or a debug path
/// that stringifies a struct into a tag — none of which any allow-list
/// anticipates.
///
/// ## The two halves, and why both are load-bearing
///
/// A forbid-check over a journal that never contained the value's *carrier*
/// passes trivially. "The circle name never appeared" is true and meaningless
/// if no circle was ever created. So every canary here carries a **positive
/// control**: a set of event ids the scenario observed carrying (or following)
/// the planted value, every one of which must be present in the journal. The
/// absence half is [WireCanaryScanner.scan]'s findings; the presence half is
/// its vacuity checks, and a run that fails the second is reported as
/// UNUSABLE — never as clean. This is the same failure the oracle being
/// supplemented had: its `isNotEmpty` stayed satisfied by commits while the
/// events it was really checking had been evicted.
///
/// ## Encodings
///
/// Matching a canary only as a literal UTF-8 substring is close to worthless —
/// the interesting leaks arrive base64'd, hex'd, escaped or percent-encoded.
/// [CanaryTermSet.expand] enumerates the encodings; [CanaryTermSet.dropped]
/// enumerates the terms that had to be discarded as too collision-prone to
/// assert on.
///
/// Those two lists describe only what the expander DID. On their own they
/// cannot report an encoding nobody thought to enumerate: such an encoding is
/// in neither list, so a ledger built from them measures its own input and
/// reports full coverage of whatever it happens to produce.
/// [CanaryEncodingLedger] is the independent half — a hand-declared claim,
/// per encoding, of `covered` / `gap` / `absent`, reconciled against the
/// expander on every scan. A covered
/// encoding the expander stopped producing, a gap it silently started keeping,
/// and an encoding it produces that nothing declares are all UNUSABLE
/// verdicts. That is what makes the coverage claim falsifiable rather than
/// self-satisfying.
///
/// ## Purity
///
/// Nothing here imports Flutter or `dart:io`. The scenario half runs on-device
/// inside `flutter drive`; the oracle half runs on the CI host over the NDJSON
/// journal that C1's recording proxy wrote; the fixtures run under plain
/// `flutter test`. One file, three hosts, no conditional imports.
///
/// ## Wiring contract — what the scenario must do
///
/// The scenario cannot half-adopt this. A plant without an announcement, or an
/// announcement without carriers, produces a run the oracle reports as
/// UNUSABLE rather than clean — deliberately, because either one leaves it
/// asserting over a window it cannot prove covered.
///
/// ```dart
/// final canaries = WireCanaryPlant.mint(role: 'alice');
///
/// // 1. Plant. The circle name goes through whatever path the scenario
/// //    already uses to create a circle; the petname through
/// //    CircleService.setContactDisplayName; the coordinate through
/// //    FakeLocationService(latitude: canaries.latitude,
/// //    longitude: canaries.longitude).
///
/// // 2. Confirm each plant took, by reading the value back OUT of the app.
/// //    Minting a canary and never applying it leaves a forbid-check that
/// //    passes for free, and carrier ids alone cannot tell that apart from a
/// //    real plant — any published event id satisfies them.
/// canaries.confirmCircleNamePlanted((await circles.load(id)).name);
/// canaries.confirmPetnamePlanted(await circles.contactDisplayName(pubkey));
/// canaries.confirmCoordinatePlanted(
///   latitude: decrypted.latitude,
///   longitude: decrypted.longitude,
/// );
///
/// // 3. Record carriers as the scenario observes them.
/// canaries.nostrGroupIdHex = _hexLower(circle.nostrGroupId);
/// for (final w in result.welcomeEvents) {
///   canaries.recordCircleNameCarrier(jsonDecode(w.eventJson)['id'] as String);
/// }
/// canaries.recordCoordinateCarrier(evt.id);      // a peer decrypted it and
///                                                // read the canary back
/// canaries.recordPetnameOpportunity(evt.id);     // any app->relay event
///                                                // published AFTER the set
///
/// // 4. Anchor. TestRelay's marker is intercepted by the proxy and never
/// //    forwarded upstream; its ack returns the wire_seq the snapshot ends
/// //    at. Emit it AFTER the traffic that should be inside the snapshot.
/// final sentinel = await ctx.relay.emitWireJournalSentinel();
/// canaries.recordSentinel(
///   token: sentinel.token,
///   wireSeq: sentinel.wireSeq,
/// );
///
/// // 5. Announce ONCE, at the very end, so every carrier is included.
/// canaries.announce(debugPrint);
/// ```
///
/// The lane then runs, on the host:
///
/// ```sh
/// dart tooling/e2e/ci/check-wire-canaries.dart \
///      --journal <C1's journal> --manifest <the drive log>
/// ```
///
/// Exit codes are the five `tooling/e2e/ci/check-wire-journal.sh` uses, so a
/// lane running both oracles reads one convention: 0 clean, 1 a canary on the
/// wire (and a signal to withhold the journal from artifact upload), 2 usage,
/// 3 UNUSABLE (the recorder broke), 4 META-FLOOR (the scenario broke).
///
/// ## Where the manifest may be written, and what may go in it
///
/// [WireCanaryPlant.announce] takes a sink, so the manifest can go to the
/// drive log (convenient — the lane already captures it) or to a dedicated
/// file. That choice is a disclosure decision, not a plumbing one: the drive
/// log is a CI artifact with weeks of retention.
///
/// Everything this library plants is a fabricated test value, so the drive log
/// is fine for C6. It would NOT be fine for every id a host-side oracle might
/// want. The `nostr_group_id` is published on the wire by design and is
/// carried here; the **real MLS group id is not**, and Security Rule 4 says it
/// must never be published. Any oracle that wants to scan the journal for it
/// needs the literal value on the host — a digest cannot be searched for — so
/// it must hand it over through a manifest file the lane does NOT upload,
/// never through logcat. `--manifest` accepts any file carrying the marker
/// line, so that path already exists; what must not happen is someone adding
/// a Rule-4 value to the announcement that goes to the drive log.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

// =============================================================================
// Planted values
// =============================================================================

/// Stem shared by every string canary.
///
/// Deliberately nonsense: it must not occur in relay furniture, in a
/// subscription id, in a `NOTICE`, or in anything the protocol legitimately
/// emits. `Qzvx` is not a word in any locale the app ships and is not a
/// prefix of any Nostr identifier.
const String kCanaryStem = 'Qzvx';

/// Canary latitude. See [kCanaryLongitude] for the selection rationale.
const double kCanaryLatitude = -47.209318;

/// Canary longitude.
///
/// `(-47.209318, -127.478205)` is open ocean in the South Pacific gyre, ~2000
/// km west of Chile — the same "unmistakable in a log, nowhere near a person"
/// property the existing role sentinels in `fake_location_service.dart` aim
/// for, but with digits chosen so that **every derived search term survives
/// [CanaryTermSet]'s hygiene gate**:
///
/// * the decimal forms all contain `.`, which cannot occur inside a base64 or
///   hex blob, so they are collision-free at any length;
/// * the geohash is `1pt77jv1y92b` — its 5-char prefix `1pt77` contains `p`
///   and `t`, neither of which is a hex digit, so it can never appear inside
///   an event id, pubkey or signature.
///
/// The second property is not decorative. A coordinate whose geohash prefix
/// happened to be all-hex (e.g. `30943`, which `(-41.783206, -133.529471)`
/// produces) would be undetectable inside the hex furniture that dominates a
/// Nostr journal, and the geohash arm of the coordinate canary would silently
/// degrade to nothing. `canaryGeohashPrefixesSurviveHygiene` pins this.
const double kCanaryLongitude = -127.478205;

/// The canary ids, used as map keys in the manifest and as report labels.
abstract final class CanaryId {
  /// The circle's user-authored display name.
  static const String circleDisplayName = 'circle_display_name';

  /// A member's local-only display-name override.
  static const String petname = 'petname';

  /// The published coordinate.
  static const String coordinate = 'coordinate';

  /// Every canary this oracle plants, in report order.
  static const List<String> all = <String>[
    circleDisplayName,
    petname,
    coordinate,
  ];
}

/// Event kinds a canary's carrier must have been PUBLISHED as.
///
/// A carrier id on its own only proves that some event crossed the wire. That
/// is satisfiable by any published id at all, so a scenario that recorded
/// three arbitrary sent ids would clear the control while having planted
/// nothing. Requiring the carrier to have been observed client->relay as an
/// event of a kind that can actually hold the value narrows "some traffic
/// happened" to "a frame able to carry THIS canary was transmitted".
///
/// The circle name lives in MLS group metadata, so its carriers are the
/// gift-wrapped Welcomes (1059) and the group's commits (445); the coordinate
/// rides an application message (445). The petname has no legitimate carrier
/// at all — that is what makes it a canary — so its control stays *opportunity*
/// coverage and it declares no kind.
const Map<String, Set<int>> kCanaryCarrierKinds = <String, Set<int>>{
  CanaryId.circleDisplayName: <int>{445, 1059},
  CanaryId.coordinate: <int>{445},
};

/// How far a coordinate plant proof may sit from the planted value.
///
/// 1e-4 degrees is ~11 m. Loose enough to survive a decrypt and a JSON round
/// trip, and tight enough that only the canary itself can satisfy it: the
/// nearest land to `(-47.209318, -127.478205)` is roughly 2000 km away.
const double kCoordinateProofTolerance = 1e-4;

/// Token alphabet for the per-run suffix.
///
/// Uppercase + digits, minus the visually ambiguous `I`/`O`/`0`/`1`, so a
/// token pasted out of a CI log round-trips. 32 symbols x 10 chars = 50 bits,
/// which is far more than enough to make an accidental match impossible and —
/// more importantly — to make a *stale* journal from a previous run fail the
/// positive control instead of quietly satisfying it.
const String _tokenAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

/// The canary values planted by one scenario process.
///
/// Minted by [WireCanaryPlant.mint], mutated by the `record*` methods as the
/// scenario learns which events carried what, then serialised by [announce].
class WireCanaryPlant {
  WireCanaryPlant._({
    required this.role,
    required this.circleDisplayName,
    required this.petname,
  });

  /// Mints a fresh set of canaries for [role].
  ///
  /// The random suffix is what forces the oracle to learn the values **from
  /// this run's manifest**. An oracle that hard-coded them would pass against
  /// a journal recorded yesterday; with a fresh token it cannot.
  ///
  /// [random] is injectable so fixtures are deterministic. Production callers
  /// omit it and get `Random.secure()`.
  factory WireCanaryPlant.mint({required String role, Random? random}) {
    final rng = random ?? Random.secure();
    String token() => List<String>.generate(
      10,
      (_) => _tokenAlphabet[rng.nextInt(_tokenAlphabet.length)],
    ).join();
    return WireCanaryPlant._(
      role: role,
      // A space is deliberate: it is the one character in these values that
      // percent- and form-encoding actually transform, which keeps those two
      // encodings from being silent aliases of the literal term.
      circleDisplayName: '$kCanaryStem CIRCLE ${token()}',
      petname: '$kCanaryStem PETNAME ${token()}',
    );
  }

  /// Which scenario role planted these (`alice` / `bob` / `carol` / `solo`).
  final String role;

  /// Circle display name to create the circle with. <= 50 chars, so it
  /// passes `name_circle_page.dart`'s validator.
  final String circleDisplayName;

  /// Petname to set via `CircleService.setContactDisplayName`.
  final String petname;

  /// Canary latitude to feed `FakeLocationService`.
  double get latitude => kCanaryLatitude;

  /// Canary longitude to feed `FakeLocationService`.
  double get longitude => kCanaryLongitude;

  final Map<String, Set<String>> _carriers = <String, Set<String>>{
    for (final id in CanaryId.all) id: <String>{},
  };

  final Map<String, String> _plantProofs = <String, String>{};

  String? _nostrGroupIdHex;
  String? _sentinelToken;
  int? _sentinelWireSeq;

  /// Records the circle's `nostr_group_id`, purely as report context.
  // ignore: avoid_setters_without_getters
  set nostrGroupIdHex(String value) => _nostrGroupIdHex = value;

  /// Records the snapshot marker returned by
  /// `TestRelay.emitWireJournalSentinel()`.
  ///
  /// Taken as two plain values rather than as that method's return type, so
  /// this library keeps its `dart:convert`-only dependency set and can run
  /// under a bare `dart` on the CI host.
  ///
  /// Supplying it buys two things. The oracle can require the marker to be
  /// PRESENT in the journal — proof the lane actually routed through the
  /// recording proxy rather than straight at the relay, which is otherwise
  /// indistinguishable from a quiet run. And it bounds the evidence checks,
  /// so a background wake still appending after the snapshot cannot turn a
  /// good run into a truncated-tail failure.
  void recordSentinel({required String token, required int wireSeq}) {
    _sentinelToken = token;
    _sentinelWireSeq = wireSeq;
  }

  /// Records an event id that CARRIES the circle display name.
  ///
  /// The name lives in MLS group metadata, so its carriers are the
  /// gift-wrapped Welcomes (kind 1059) and the group's create/evolution
  /// commits (kind 445). Requiring these in the journal is what proves the
  /// journal's window covers the frames in which the name could have leaked.
  void recordCircleNameCarrier(String eventId) =>
      _record(CanaryId.circleDisplayName, eventId);

  /// Records an event id the scenario confirmed carries the canary coordinate.
  ///
  /// "Confirmed" means a peer decrypted it and read the coordinate back — not
  /// merely that it appeared while the fake location service was installed.
  void recordCoordinateCarrier(String eventId) =>
      _record(CanaryId.coordinate, eventId);

  /// Records an event the app sent to a relay AFTER the petname was set.
  ///
  /// The petname has no legitimate carrier — that is the whole point of it as
  /// a canary. Its positive control is therefore *opportunity* coverage
  /// rather than carrier coverage: proof that the journal recorded real
  /// client->relay traffic during the window in which a leak was possible. An
  /// oracle that asserted "the petname never appeared" over a journal that
  /// ended before the petname was set would be asserting nothing.
  void recordPetnameOpportunity(String eventId) =>
      _record(CanaryId.petname, eventId);

  void _record(String canaryId, String eventId) {
    final normalised = eventId.trim().toLowerCase();
    if (normalised.isEmpty) return;
    _carriers[canaryId]!.add(normalised);
  }

  /// Records the circle display name **as the app returned it** after the
  /// plant.
  ///
  /// See [confirmCoordinatePlanted] for why this exists and what it can and
  /// cannot prove.
  void confirmCircleNamePlanted(String observed) =>
      _plantProofs[CanaryId.circleDisplayName] = observed.trim();

  /// Records the petname **as the app returned it** after the plant.
  void confirmPetnamePlanted(String observed) =>
      _plantProofs[CanaryId.petname] = observed.trim();

  /// Records the coordinate **as a peer decrypted it** after the plant.
  ///
  /// ## Why carrier ids are not enough
  ///
  /// A carrier id proves the journal's window covers frames the canary COULD
  /// have leaked in. It says nothing about whether the canary was ever
  /// applied: a scenario that mints three values, plants none of them, and
  /// records three ordinary published event ids satisfies every carrier check
  /// and reports clean. The forbid half is then asserting the absence of a
  /// value that was never anywhere near the wire — the exact vacuity this
  /// oracle exists to refuse.
  ///
  /// A plant proof is the value read back OUT of the app through its own read
  /// path (the circle store, the contact store, a peer's decrypted location),
  /// so recording one requires the plant to have taken.
  ///
  /// ## What it cannot do, stated plainly
  ///
  /// A scenario that passes the minted value straight back here instead of
  /// reading it from the app satisfies this too, and no host-side check can
  /// tell the difference — the manifest is the only channel and every field
  /// on it is equally forgeable. What this closes is the SILENT failure: a
  /// plant that a UI change, a validator or a renamed field quietly dropped.
  /// It does not close deliberate misuse.
  void confirmCoordinatePlanted({
    required double latitude,
    required double longitude,
  }) => _plantProofs[CanaryId.coordinate] = formatCoordinateProof(
    latitude,
    longitude,
  );

  /// Builds the manifest describing everything planted so far.
  WireCanaryManifest manifest() => WireCanaryManifest(
    role: role,
    circleDisplayName: circleDisplayName,
    petname: petname,
    latitude: latitude,
    longitude: longitude,
    nostrGroupIdHex: _nostrGroupIdHex,
    sentinelToken: _sentinelToken,
    sentinelWireSeq: _sentinelWireSeq,
    carrierEventIds: <String, List<String>>{
      for (final entry in _carriers.entries)
        entry.key: entry.value.toList()..sort(),
    },
    plantProofs: Map<String, String>.unmodifiable(_plantProofs),
  );

  /// Emits the manifest through [log] as a single greppable line.
  ///
  /// Call this ONCE, at the very end of the scenario, so every carrier id is
  /// already recorded. [log] is normally `debugPrint`; taking it as a
  /// parameter is what keeps this library free of a Flutter import.
  ///
  /// The manifest goes to the DRIVE log, never to a relay, so publishing the
  /// canary values here cannot contaminate the journal the oracle scans.
  void announce(void Function(String) log) =>
      log(manifest().toAnnouncementLine());
}

// =============================================================================
// Manifest
// =============================================================================

/// Marker prefix the oracle greps for.
const String kCanaryManifestMarker = '[wire-canary] MANIFEST ';

/// Record type of a traffic line in C1's journal (`docs/WIRE_JOURNAL.md`).
///
/// `conn_open` / `conn_error` lifecycle records carry NO `dir` and NO `frame`
/// key at all. Treating every line as traffic is not a cosmetic error: it
/// makes every real journal read as one blind spot per connection, and the
/// whole run reports UNUSABLE. This constant exists so that discrimination is
/// explicit rather than inferred from a missing key.
const String kJournalTypeFrame = 'frame';

/// Cap on `raw_preview`, in CHARACTERS, per `docs/WIRE_JOURNAL.md`.
///
/// The truncation test has to be `preview.length >= this`, not
/// `raw_len > preview.length`: `raw_len` is a BYTE count while the preview is
/// capped in characters, so any non-ASCII payload has `raw_len` greater than
/// the preview length without a single character having been dropped.
/// Comparing those two directly would report a blind spot on every multi-byte
/// frame the proxy could not parse.
const int kRawPreviewMaxChars = 200;

/// The character `String::from_utf8_lossy` substitutes for a byte sequence it
/// could not decode.
///
/// Its presence in a `raw_preview` means the producer rendered a payload it
/// could not read as UTF-8 — every binary WebSocket message is recorded that
/// way by design — so the ORIGINAL bytes are not recoverable from the line and
/// a content scan over it proves nothing.
const String kLossyReplacementChar = '\u{FFFD}';

/// Whether a `frame: null` line's `raw_preview` failed to record the whole
/// message.
///
/// Three ways it can, and all three have to be tested, because the producer
/// renders BEFORE it truncates:
///
/// * the preview reached the [kRawPreviewMaxChars] cap, so bytes past it were
///   never written;
/// * the preview carries [kLossyReplacementChar], so the producer's
///   `from_utf8_lossy` destroyed the bytes it could not decode. A short binary
///   message arrives under the cap and looks complete, which is precisely how
///   "every binary message is counted as blind" stopped being true;
/// * the preview's UTF-8 length disagrees with the `raw_len` the producer
///   recorded, which is the general form of both of the above and catches a
///   lossy render whose replacement characters happen to balance out in
///   character count.
///
/// A missing or non-integer `raw_len` is itself blind: without it there is
/// nothing to check completeness against, and this oracle fails closed.
bool previewIsIncomplete({
  required Object? preview,
  required Object? rawLen,
}) {
  if (preview is! String) return true;
  if (preview.length >= kRawPreviewMaxChars) return true;
  if (preview.contains(kLossyReplacementChar)) return true;
  if (rawLen is! int) return true;
  return utf8.encode(preview).length != rawLen;
}

/// The serialised description of one process's planted canaries.
class WireCanaryManifest {
  /// Creates a manifest.
  const WireCanaryManifest({
    required this.role,
    required this.circleDisplayName,
    required this.petname,
    required this.latitude,
    required this.longitude,
    required this.carrierEventIds,
    this.plantProofs = const <String, String>{},
    this.nostrGroupIdHex,
    this.sentinelToken,
    this.sentinelWireSeq,
  });

  /// Parses one manifest from its JSON object form.
  ///
  /// Throws [FormatException] on anything missing or mistyped — a manifest
  /// that cannot be read is an evidence failure, not a value to guess at.
  factory WireCanaryManifest.fromJson(Map<String, dynamic> json) {
    T require<T>(String key) {
      final value = json[key];
      if (value is! T) {
        throw FormatException(
          'wire-canary manifest field "$key" is ${value.runtimeType}, '
          'expected $T',
        );
      }
      return value;
    }

    final rawCarriers = require<Map<String, dynamic>>('carrier_event_ids');
    final carriers = <String, List<String>>{};
    for (final id in CanaryId.all) {
      final list = rawCarriers[id];
      if (list is! List) {
        throw FormatException(
          'wire-canary manifest carrier_event_ids."$id" is missing or is '
          'not a list',
        );
      }
      // Checked, never cast. `(e as String)` throws a TypeError, which is an
      // Error rather than an Exception — it escapes every `on FormatException`
      // this file's callers wrap the parse in, and the CLI that promises five
      // exit codes exits 255 with a stack trace instead of reporting an
      // unreadable manifest.
      carriers[id] = <String>[
        for (final e in list)
          if (e is String)
            e.trim().toLowerCase()
          else
            throw FormatException(
              'wire-canary manifest carrier_event_ids."$id" holds a '
              '${e.runtimeType} where an event id string was expected',
            ),
      ];
    }
    final rawProofs = json['plant_proofs'];
    final proofs = <String, String>{};
    if (rawProofs != null) {
      if (rawProofs is! Map<String, dynamic>) {
        throw const FormatException(
          'wire-canary manifest "plant_proofs" is not a JSON object',
        );
      }
      for (final entry in rawProofs.entries) {
        final value = entry.value;
        if (value is! String) {
          throw FormatException(
            'wire-canary manifest plant_proofs."${entry.key}" is a '
            '${value.runtimeType}, expected String',
          );
        }
        proofs[entry.key] = value;
      }
    }
    return WireCanaryManifest(
      role: require<String>('role'),
      circleDisplayName: require<String>('circle_display_name'),
      petname: require<String>('petname'),
      latitude: require<num>('latitude').toDouble(),
      longitude: require<num>('longitude').toDouble(),
      nostrGroupIdHex: json['nostr_group_id'] as String?,
      sentinelToken: json['sentinel_token'] as String?,
      sentinelWireSeq: json['sentinel_wire_seq'] as int?,
      carrierEventIds: carriers,
      plantProofs: proofs,
    );
  }

  /// Which role planted this set.
  final String role;

  /// The planted circle display name.
  final String circleDisplayName;

  /// The planted petname.
  final String petname;

  /// The planted latitude.
  final double latitude;

  /// The planted longitude.
  final double longitude;

  /// The circle's `nostr_group_id`, if the scenario recorded one.
  final String? nostrGroupIdHex;

  /// The snapshot marker token, if the scenario emitted one.
  final String? sentinelToken;

  /// `wire_seq` the proxy assigned to the marker line.
  final int? sentinelWireSeq;

  /// Canary id -> event ids proving the journal covers that canary's window.
  final Map<String, List<String>> carrierEventIds;

  /// Canary id -> the value the scenario read back OUT of the app.
  ///
  /// See [WireCanaryPlant.confirmCoordinatePlanted] for what this proves and
  /// what it cannot. Absent for a canary means the scenario never confirmed
  /// the plant, which [WireCanaryScanner.scan] reports as a meta-floor
  /// failure rather than as a pass.
  final Map<String, String> plantProofs;

  /// The value [plantProofs] must carry for [canaryId] if the plant took.
  ///
  /// For the coordinate this is a canonical `lat,lon` rendering; the scanner
  /// compares it numerically with a tolerance rather than as a string, so a
  /// value that survived a float round trip still matches.
  String expectedPlantProof(String canaryId) => switch (canaryId) {
    CanaryId.circleDisplayName => circleDisplayName,
    CanaryId.petname => petname,
    CanaryId.coordinate => formatCoordinateProof(latitude, longitude),
    _ => throw ArgumentError.value(canaryId, 'canaryId', 'unknown canary'),
  };

  /// JSON form.
  Map<String, dynamic> toJson() => <String, dynamic>{
    'role': role,
    'circle_display_name': circleDisplayName,
    'petname': petname,
    'latitude': latitude,
    'longitude': longitude,
    if (nostrGroupIdHex != null) 'nostr_group_id': nostrGroupIdHex,
    if (sentinelToken != null) 'sentinel_token': sentinelToken,
    if (sentinelWireSeq != null) 'sentinel_wire_seq': sentinelWireSeq,
    'carrier_event_ids': carrierEventIds,
    'plant_proofs': plantProofs,
  };

  /// The single log line the scenario emits.
  String toAnnouncementLine() =>
      '$kCanaryManifestMarker${jsonEncode(toJson())}';

  /// Extracts every manifest from [text] (a drive log, or a file holding
  /// nothing but manifest lines).
  ///
  /// Multi-process scenarios announce once per role; all of them are returned.
  /// A line carrying the marker but unparseable JSON throws, because silently
  /// skipping it would turn a corrupted plant into "nothing was planted",
  /// which this oracle reports as a pass-shaped verdict only when it is
  /// certain nothing was planted.
  static List<WireCanaryManifest> parseAll(String text) {
    final out = <WireCanaryManifest>[];
    for (final line in const LineSplitter().convert(text)) {
      final at = line.indexOf(kCanaryManifestMarker);
      if (at < 0) continue;
      final payload = line.substring(at + kCanaryManifestMarker.length).trim();
      final Object? decoded;
      try {
        decoded = jsonDecode(payload);
      } on FormatException catch (e) {
        throw FormatException(
          'a line carries $kCanaryManifestMarker but its payload is not '
          'JSON: ${e.message}',
        );
      }
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException(
          'wire-canary manifest payload is not a JSON object',
        );
      }
      out.add(WireCanaryManifest.fromJson(decoded));
    }
    return out;
  }
}

// =============================================================================
// Search terms
// =============================================================================

/// How a term must appear before it counts as a hit.
enum TermMatch {
  /// Anywhere in the line, or in any decoded string value.
  substring,

  /// As a COMPLETE JSON string token (`"term"`), or as a decoded string value
  /// exactly equal to the term.
  ///
  /// This is what makes short, low-entropy terms assertable: a `"` cannot
  /// occur inside a base64 or hex blob, so a token match cannot be produced by
  /// ciphertext coincidence. It is also the exact shape the live-but-
  /// unreachable geohash builder in `haven-core/src/nostr/event.rs` would
  /// produce — `["g","1pt77"]`.
  jsonToken,

  /// Anywhere, provided the characters immediately either side are not
  /// `[A-Za-z0-9]`.
  ///
  /// For decimal integer encodings (E6/E7 fixed point): inside a hex id or a
  /// longer epoch the neighbours are alphanumeric, so only a standalone
  /// numeric token matches.
  delimited,
}

/// One thing to look for in the journal.
class CanaryTerm {
  /// Creates a term.
  const CanaryTerm({
    required this.canaryId,
    required this.encoding,
    required this.value,
    required this.match,
    this.caseFold = false,
  });

  /// Which canary this term derives from.
  final String canaryId;

  /// Human label for the encoding, e.g. `base64/align1`.
  final String encoding;

  /// The literal string to search for. Already lowercased when [caseFold].
  final String value;

  /// How it must appear.
  final TermMatch match;

  /// Whether the haystack is lowercased before matching.
  final bool caseFold;

  /// Stable identity for reporting and de-duplication.
  String get label => '$canaryId/$encoding';

  @override
  String toString() => '$label (${match.name}${caseFold ? ', folded' : ''})';
}

/// A term that was generated and then discarded.
class DroppedTerm {
  /// Creates a dropped-term record.
  const DroppedTerm(this.term, this.reason, {required this.isCoverageGap});

  /// The term that will NOT be searched for.
  final CanaryTerm term;

  /// Why it was dropped.
  final String reason;

  /// Whether dropping it actually loses coverage.
  ///
  /// Two encodings frequently collapse to the same string — base64url equals
  /// base64 whenever no group happens to encode to `+` or `/`, and truncation
  /// equals rounding whenever the next digit is below 5. Discarding the
  /// duplicate loses nothing, and reporting it as a gap would bury the drops
  /// that ARE gaps under dozens that are not.
  ///
  /// Gaps are the hygiene rejections AND the terms that could not be built at
  /// all — a base64 alignment with no whole group inside the value. Both mean
  /// the encoding is not being searched for, which is the only thing a reader
  /// of this flag is asking.
  final bool isCoverageGap;
}

/// What the ledger CLAIMS about one encoding.
///
/// The three values exist because "not searched for" collapses two different
/// facts that need different reviews: a term that was BUILT and then rejected
/// as too collision-prone (a cost paid knowingly, printed on every run), and
/// an encoding that is not derived at all (a scope boundary). Conflating them
/// is how a gap comes to look like coverage.
enum CanaryCoverage {
  /// [CanaryTermSet.expand] must enumerate it and the hygiene gate must KEEP
  /// it — either as a live term or as an exact alias of one.
  covered,

  /// [CanaryTermSet.expand] must enumerate it and the hygiene gate must
  /// REJECT it. A gap that is still generated is a gap the CLI prints on
  /// every run, which is the difference between a documented limitation and a
  /// forgotten one.
  gap,

  /// [CanaryTermSet.expand] must NOT enumerate it at all. A scope boundary,
  /// carrying the reason it is outside scope.
  absent,
}

/// One hand-declared claim about one encoding.
class CanaryEncodingClaim {
  /// Creates a claim.
  const CanaryEncodingClaim(this.encoding, this.coverage, this.reason);

  /// The encoding label, exactly as [CanaryTerm.encoding] spells it.
  final String encoding;

  /// What is claimed about it.
  final CanaryCoverage coverage;

  /// Why — in the operator's terms, and required to be TRUE.
  ///
  /// A stated gap whose reason is false is worse than an unstated one: it
  /// answers the question a reviewer would otherwise ask. The reasons on
  /// [CanaryCoverage.gap] entries name the concrete hygiene floor that
  /// rejects the term, and every one of them is executable — the floors are
  /// public constants on [CanaryTermSet] and the fixtures compute against
  /// them rather than restating them.
  final String reason;
}

/// The hand-declared coverage ledger, reconciled against the expander.
///
/// ## Why this exists at all
///
/// [CanaryTermSet.dropped] records a term that was built and then rejected.
/// An encoding nobody thought to enumerate is in neither [CanaryTermSet.terms]
/// nor [CanaryTermSet.dropped], so any test written over those two lists is a
/// measurement of the expander's own output: delete an encoding and the test
/// passes with less work. That is the exact shape of a check that certifies
/// its own input.
///
/// This list is the independent term. It is written by hand, it names the
/// encoding space this oracle CLAIMS to reason about, and [reconcile] fails
/// on any disagreement in either direction:
///
/// * a `covered` encoding the expander no longer produces (the F14 mutation —
///   narrowing the decimal ladder from `dp <= 8` to `dp <= 5` deletes four
///   encodings and, without this, deletes four tests' worth of work with
///   them);
/// * a `covered` encoding the hygiene gate silently started rejecting (a
///   raised floor turning coverage into a gap without anyone saying so);
/// * a `gap` the gate silently started keeping (a lowered floor, which is a
///   false-positive risk rather than a coverage one, and still must not
///   happen unannounced);
/// * an `absent` encoding the expander started producing (a scope boundary
///   moved without the ledger following);
/// * an encoding the expander produces that nothing here declares.
///
/// A disagreement is reported as UNUSABLE, not as a leak and not as a pass:
/// the instrument's own coverage claim is unverified, so its verdict carries
/// no information.
///
/// ## What it still cannot do
///
/// It cannot invent an encoding neither half thought of. Nothing can. What it
/// does is make every boundary of the claimed space explicit and executable,
/// so the next gap has to be argued for in this list rather than discovered
/// by an adversarial reader three months later.
abstract final class CanaryEncodingLedger {
  static CanaryEncodingClaim _covered(String encoding) =>
      CanaryEncodingClaim(encoding, CanaryCoverage.covered, 'searched for');

  static CanaryEncodingClaim _gap(String encoding, String reason) =>
      CanaryEncodingClaim(encoding, CanaryCoverage.gap, reason);

  static CanaryEncodingClaim _absent(String encoding, String reason) =>
      CanaryEncodingClaim(encoding, CanaryCoverage.absent, reason);

  /// Reason shared by every term the pure-hex floor rejects.
  static const String hexFloorReason =
      'a pure-hex term shorter than CanaryTermSet.minPureHexLength would '
      'collide with the event ids, pubkeys and signatures that dominate a '
      'Nostr journal';

  /// Reason shared by every term the alphanumeric floor rejects.
  static const String alnumFloorReason =
      'a pure-alphanumeric term shorter than CanaryTermSet.minAlnumLength '
      'would collide with base64 ciphertext';

  /// Reason shared by every term the mixed floor rejects.
  static const String mixedFloorReason =
      'shorter than CanaryTermSet.minMixedLength, which is the floor below '
      'which even a term containing a `.` is a degenerate needle';

  /// The eleven encodings every byte source expands to.
  static const List<String> byteEncodings = <String>[
    'hex-lower',
    'hex-upper',
    'debug-dec',
    'debug-hex02',
    'debug-hex',
    'base64-align0',
    'base64-align1',
    'base64-align2',
    'base64url-align0',
    'base64url-align1',
    'base64url-align2',
  ];

  /// The eight encodings a byte source expands to when its debug renderings
  /// are already covered by a narrower source (see the f32 pair sources).
  static const List<String> byteEncodingsWithoutDebug = <String>[
    'hex-lower',
    'hex-upper',
    'base64-align0',
    'base64-align1',
    'base64-align2',
    'base64url-align0',
    'base64url-align1',
    'base64url-align2',
  ];

  /// The six encodings one base64 layer over a string form expands to.
  static const List<String> base64Encodings = <String>[
    'base64-align0',
    'base64-align1',
    'base64-align2',
    'base64url-align0',
    'base64url-align1',
    'base64url-align2',
  ];

  /// The string forms each of which additionally carries one base64 layer.
  ///
  /// The composition space is unbounded — `base64(hex(percent(x)))` is as
  /// real as any other — so the budget is stated rather than left implicit:
  /// exactly ONE base64 layer over each covered string form. base64 is the
  /// layer that actually appears on this wire (every Nostr `content` is one),
  /// which is why it is the layer that gets the budget.
  static const List<String> composedStringForms = <String>[
    'utf8-casefold',
    'json-unicode-escape',
    'percent-component',
    'percent-form',
    'utf8/hex-lower',
    'utf8/hex-upper',
  ];

  /// How many trailing characters a covered truncation may drop.
  ///
  /// The per-run token is the last 10 characters of every string canary, so
  /// dropping 6 still leaves 4 of them — 32^4 ≈ 10^6, which keeps a truncated
  /// prefix specific to THIS run's plant. Dropping more starts matching the
  /// constant stem, where a previous run's canary would satisfy it.
  static const int maxCoveredTruncation = 6;

  /// The claims for one string canary (circle display name, petname).
  static final List<CanaryEncodingClaim> stringValue = <CanaryEncodingClaim>[
    _covered('utf8-literal'),
    _covered('utf8-casefold'),
    _covered('json-unicode-escape'),
    _covered('percent-component'),
    _covered('percent-form'),
    for (var n = 1; n <= maxCoveredTruncation; n++) _covered('utf8-drop$n'),
    for (final e in byteEncodings) _covered('utf8/$e'),
    for (final form in composedStringForms)
      for (final e in base64Encodings) _covered('$form/$e'),
    _absent(
      'utf8-drop${maxCoveredTruncation + 1}',
      'a truncation dropping more than $maxCoveredTruncation characters '
          'leaves fewer than 4 of the 10 random-token characters, so it would '
          'also match a canary minted by an earlier run',
    ),
    _absent(
      'utf8/hex-lower/hex-lower',
      'compositions deeper than one base64 layer over a covered string form '
          'are not derived; the space is unbounded and the budget is stated '
          'on CanaryEncodingLedger.composedStringForms',
    ),
    _absent(
      'percent-component/hex-lower',
      'hex OVER a re-encoded form is not derived, for the same bounded-budget '
          'reason: only base64 gets the composition layer, because only '
          'base64 is what a Nostr content field actually carries',
    ),
    _absent(
      'utf8/base32',
      'base32, base58, bech32, quoted-printable and UTF-16 byte dumps are not '
          'derived. None is produced by any code path in this repo, and each '
          'would add an encoder whose drift from a real implementation nothing '
          'here could detect',
    ),
    _absent(
      'utf8/sha256-hex',
      'a hashed canary is not searched for. It is a linkable identifier and a '
          'real (weaker) disclosure, but it is left to the structural oracles, '
          'which reject unknown tags outright',
    ),
  ];

  /// The claims for the coordinate canary.
  static final List<CanaryEncodingClaim> coordinate = <CanaryEncodingClaim>[
    // ---- decimals -------------------------------------------------------
    // The ladder runs 0..8 and every rung is named, so narrowing the loop
    // that generates it fails here by encoding name. Rungs 0 and 1 are the
    // only ones the hygiene floors reject, and which of them do is
    // axis-dependent: `47` and `127` are bare digit runs that would match
    // inside any hex id (and `127` matches the loopback address stamped on
    // every journal line), while `127.5` carries a `.` and five characters
    // and is therefore assertable where `47.2` is not.
    for (final axis in coordinateAxes) ...<CanaryEncodingClaim>[
      _covered('$axis/decimal-full'),
      for (final style in <String>['round', 'trunc']) ...<CanaryEncodingClaim>[
        _gap(
          '$axis/decimal-${style}0',
          '0 decimal places renders a bare digit run — $alnumFloorReason, and '
              'for lon it is additionally a substring of the 127.0.0.1 '
              'loopback address every journal line carries',
        ),
        if (axis == 'lat')
          _gap('$axis/decimal-${style}1', '`47.2` is 4 characters: '
              '$mixedFloorReason')
        else
          _covered('$axis/decimal-${style}1'),
        for (var dp = 2; dp <= maxCoveredDecimalPlaces; dp++)
          _covered('$axis/decimal-$style$dp'),
      ],
      _absent(
        '$axis/decimal-round${maxCoveredDecimalPlaces + 1}',
        'a fixed rendering with more decimals than the value itself has '
            'significant digits contains `$axis/decimal-full` as a prefix, so '
            'it is already matched by that term',
      ),
      // ---- fixed point ---------------------------------------------------
      _covered('$axis/fixed-e6'),
      _covered('$axis/fixed-e7'),
      // ---- IEEE-754 ------------------------------------------------------
      for (final endian in <String>['be', 'le'])
        for (final e in byteEncodings) _covered('$axis/f64-$endian/$e'),
      // A single-precision axis is 4 bytes: 8 hex characters and a 4-character
      // base64 core, both under the floors that the hex and base64 furniture
      // force. The floor is a hard CEILING here, which is why the pair sources
      // below exist — 8 bytes clears both floors and is the shape a struct of
      // two f32s actually serialises to. The debug renderings survive because
      // `, ` cannot occur inside hex or base64 at all.
      for (final endian in <String>['be', 'le']) ...<CanaryEncodingClaim>[
        _gap('$axis/f32-$endian/hex-lower', '8 hex characters: $hexFloorReason'),
        _gap('$axis/f32-$endian/hex-upper', '8 hex characters: $hexFloorReason'),
        _covered('$axis/f32-$endian/debug-dec'),
        _covered('$axis/f32-$endian/debug-hex02'),
        _covered('$axis/f32-$endian/debug-hex'),
        for (final variant in <String>['base64', 'base64url']) ...[
          _gap(
            '$axis/f32-$endian/$variant-align0',
            'a 4-byte value has a 4-character stable core: $alnumFloorReason',
          ),
          _gap(
            '$axis/f32-$endian/$variant-align1',
            'a 4-byte value straddles every 3-byte group at this alignment, so '
                'no whole base64 group survives trimming and there is no '
                'alignment-independent core to search for',
          ),
          _gap(
            '$axis/f32-$endian/$variant-align2',
            'a 4-byte value has a 4-character stable core: $alnumFloorReason',
          ),
        ],
      ],
    ],
    // ---- f32 pairs -------------------------------------------------------
    for (final order in coordinatePairOrders)
      for (final endian in <String>['be', 'le'])
        for (final e in byteEncodingsWithoutDebug)
          _covered('f32pair-$order-$endian/$e'),
    _absent(
      'f64pair-latlon-le/hex-lower',
      'a double-precision PAIR needs no source of its own: each axis is 8 '
          'bytes on its own, which already clears every floor, and a pair '
          'contains each axis verbatim',
    ),
    // ---- geohash ---------------------------------------------------------
    // Precision 1 is a ~5000 km cell and precision 3 a ~156 km one; a coarse
    // `g` tag is the idiomatic way location leaks in Nostr, so the ladder
    // starts at 1 rather than at a precision somebody found convenient.
    for (var n = 1; n <= geohashPrecision; n++) ...<CanaryEncodingClaim>[
      if (n < minTokenGeohashPrecision)
        _gap(
          'geohash$n/token',
          'a $n-character JSON token would match any field whose whole value '
              'is those $n characters — a subscription id, a relay label, a '
              'single-digit number rendered as a string',
        )
      else
        _covered('geohash$n/token'),
      if (n < minSubstringGeohashPrecision)
        _gap(
          'geohash$n/substring',
          'every geohash character is also a base64 character, so a '
              '$n-character bare substring lands inside ciphertext by chance: '
              '$alnumFloorReason. The standalone-field form IS covered from '
              'precision $minTokenGeohashPrecision up, via '
              'TermMatch.jsonToken',
        )
      else
        _covered('geohash$n/substring'),
    ],
    _absent(
      'geohash${geohashPrecision + 1}/token',
      'precision $geohashPrecision is ~37 mm; a longer geohash adds no '
          'distinguishing power and every longer prefix contains the covered '
          'ones',
    ),
    _absent(
      'coord/plus-code',
      'Open Location Code, MGRS, UTM, H3 and S2 are alternative geocoding '
          'SYSTEMS rather than encodings of these numbers. No code path in '
          'this repo produces one, and re-implementing four of them on the '
          'host would add four encoders whose drift nothing could detect — '
          'the geohash implementation is pinned against the Rust crate the '
          'app uses, and no equivalent anchor exists for these',
    ),
    _absent(
      'coord/dms',
      'a degrees/minutes/seconds rendering is not derived: the symbol set, '
          'spacing and hemisphere suffix vary so widely between formatters '
          'that a single derived string would assert almost nothing',
    ),
  ];

  /// The axis labels the coordinate expansion is written over.
  static const List<String> coordinateAxes = <String>['lat', 'lon'];

  /// The two component orders an f32 pair may serialise in.
  ///
  /// Declaration order (`lat`, `lon`) and GeoJSON order (`lon`, `lat`) are
  /// both real; neither can be assumed.
  static const List<String> coordinatePairOrders = <String>['latlon', 'lonlat'];

  /// Highest decimal place the ladder covers.
  static const int maxCoveredDecimalPlaces = 8;

  /// Geohash precision the ladder runs to.
  static const int geohashPrecision = 12;

  /// Lowest geohash precision assertable as a complete JSON token.
  ///
  /// Stated HERE, as a number, rather than read off
  /// [CanaryTermSet.minJsonTokenLength]. A ledger that computes its own
  /// boundaries from the expander's constants moves whenever the expander
  /// does, which is the one thing it must not do: raising a hygiene floor
  /// would silently convert covered encodings into gaps and the ledger would
  /// agree with the change instead of reporting it. Two numbers that must
  /// stay equal, maintained apart, is the point.
  static const int minTokenGeohashPrecision = 3;

  /// Lowest geohash precision assertable as a bare substring. Stated here for
  /// the same reason as [minTokenGeohashPrecision].
  static const int minSubstringGeohashPrecision = 6;

  /// The claims that apply to [canaryId].
  static List<CanaryEncodingClaim> forCanary(String canaryId) =>
      switch (canaryId) {
        CanaryId.circleDisplayName || CanaryId.petname => stringValue,
        CanaryId.coordinate => coordinate,
        _ => throw ArgumentError.value(canaryId, 'canaryId', 'unknown canary'),
      };

  /// Reconciles [set] against this ledger, canary by canary.
  ///
  /// Returns one human-readable line per disagreement, empty when the
  /// expander and the ledger agree exactly.
  static List<String> reconcile(CanaryTermSet set) {
    final out = <String>[];
    for (final canaryId in CanaryId.all) {
      final live = <String>{
        for (final t in set.terms)
          if (t.canaryId == canaryId) t.encoding,
      };
      final gaps = <String>{
        for (final d in set.dropped)
          if (d.term.canaryId == canaryId && d.isCoverageGap) d.term.encoding,
      };
      final aliases = <String>{
        for (final d in set.dropped)
          if (d.term.canaryId == canaryId && !d.isCoverageGap) d.term.encoding,
      };
      final considered = <String>{...live, ...gaps, ...aliases};
      final declared = <String>{};

      for (final claim in forCanary(canaryId)) {
        declared.add(claim.encoding);
        final wasBuilt = considered.contains(claim.encoding);
        switch (claim.coverage) {
          case CanaryCoverage.covered:
            if (!wasBuilt) {
              out.add(
                '[$canaryId] "${claim.encoding}" is declared COVERED but the '
                'expander never enumerated it. Either restore the encoding or '
                'move its claim to gap/absent with a true reason — an '
                'encoding in neither terms nor dropped is invisible to every '
                'check written over those two lists.',
              );
            } else if (gaps.contains(claim.encoding)) {
              out.add(
                '[$canaryId] "${claim.encoding}" is declared COVERED but the '
                'hygiene gate rejected it. A floor moved; say so in the '
                'ledger rather than losing the encoding quietly.',
              );
            }
          case CanaryCoverage.gap:
            if (!wasBuilt) {
              out.add(
                '[$canaryId] "${claim.encoding}" is declared a hygiene GAP '
                'but the expander never built it. A gap that is not generated '
                'is never printed, so the limitation stops being reported.',
              );
            } else if (!gaps.contains(claim.encoding)) {
              out.add(
                '[$canaryId] "${claim.encoding}" is declared a hygiene GAP '
                'but the gate KEPT it. A floor was lowered; that is a '
                'false-positive risk and must be declared, not discovered.',
              );
            }
          case CanaryCoverage.absent:
            if (wasBuilt) {
              out.add(
                '[$canaryId] "${claim.encoding}" is declared ABSENT (out of '
                'scope) but the expander now produces it. Move the claim to '
                'covered or gap so the scope boundary matches the code.',
              );
            }
        }
      }

      for (final encoding in considered) {
        if (!declared.contains(encoding)) {
          out.add(
            '[$canaryId] the expander produces "$encoding", which the ledger '
            'does not declare at all. Every encoding must be claimed, or the '
            'coverage statement is whatever the expander happens to do.',
          );
        }
      }
    }
    return out;
  }
}

/// The expanded, hygiene-filtered search set for one manifest.
///
/// The authoritative statement of WHAT is covered is
/// [CanaryEncodingLedger] — a hand-declared claim per encoding, reconciled
/// against this expander on every scan. This doc comment summarises it; the
/// ledger is what a change has to argue with.
///
/// ## Encodings COVERED
///
/// For the two string canaries (circle display name, petname):
///
/// * literal UTF-8;
/// * ASCII case-folded (catches an upper/lower normaliser);
/// * JSON `\uXXXX` escaping of every code unit;
/// * percent-encoding (`Uri.encodeComponent`) and form encoding
///   (space -> `+`);
/// * lowercase and uppercase hex of the UTF-8 bytes;
/// * Rust's `{:?}`, `{:02x?}` and `{:x?}` renderings of the UTF-8 bytes —
///   "a debug path that stringifies a struct into a tag" is the threat this
///   library opens by naming, and a `Vec<u8>` is what such a path most often
///   holds;
/// * base64 and base64url, at **all three byte alignments** — a value
///   embedded at an arbitrary offset inside a larger blob encodes differently
///   depending on `offset % 3`, so a single alignment would miss two thirds
///   of embedded cases;
/// * one base64 layer over each of the forms above (the shape a URL-encoded
///   or hex-dumped name takes once it lands inside a base64 `content`);
/// * the prefixes left by dropping 1 to 6 trailing characters — a
///   UI-truncated name is the likeliest partial leak in an app that renders
///   names in fixed-width rows.
///
/// For the coordinate canary:
///
/// * the decimal form of |lat| and |lon| at full `toString()` precision and
///   at every precision from 0 to 8 decimal places, **both truncated and
///   rounded** (a leak formatted with `{:.5}` rounds; a leak truncated for
///   privacy does not, and at 5 dp those differ). The coarse rungs are
///   generated even where a floor rejects them, so the ledger reports them;
/// * E6 and E7 fixed-point integers (the `latE7` shape);
/// * the IEEE-754 `f64` bit pattern, big- and little-endian, in hex, in
///   Rust debug form and in base64 at all three alignments — the shape a
///   `bincode`/`postcard` struct dump hexed into a tag would produce;
/// * the `f32` bit pattern of the lat/lon PAIR, in both component orders and
///   both endiannesses. A single f32 axis is 8 hex characters and a
///   4-character base64 core, i.e. under both floors the journal's own
///   furniture forces; the pair is 8 bytes and clears them, and a pair is
///   what a struct of two f32s actually serialises to;
/// * geohash prefixes from length 1 to 12: as JSON tokens from length 3, and
///   as bare substrings from length 6 up.
///
/// Sign is deliberately dropped from the decimal terms so that `-47.2093`,
/// `47.2093` and a Unicode-minus `−47.2093` all match the same term.
///
/// ## Encodings NOT covered — stated, not implied
///
/// Every scope boundary that has a NAME is a [CanaryCoverage.absent] claim on
/// [CanaryEncodingLedger], carrying its own reason, and a fixture proves each
/// one is really uncovered rather than stale. The boundaries that are
/// properties of the pipeline rather than of one encoding are here:
///
/// * **Compression.** If a WebSocket negotiates `permessage-deflate` and C1's
///   proxy records the compressed octets, nothing here matches. The producer
///   records the *parsed* frame, which implies it inflates first;
///   [WireCanaryScanner] independently fails closed on any frame it could not
///   parse and could not fully preview, which is how that assumption is
///   enforced rather than trusted.
/// * **Anything past the 200-character `raw_preview` cap** on a frame the
///   proxy could not parse at all. Not a silent gap: each such line is
///   counted and the run is reported UNUSABLE rather than clean. The same
///   applies to a preview the producer rendered LOSSILY — every binary
///   message is, by design — which is why a preview is treated as complete
///   only when it is under the cap, free of U+FFFD, and its UTF-8 length
///   equals the `raw_len` the producer recorded.
/// * **Encryption.** A canary inside correctly-encrypted content is not a
///   leak and is not searched for. This oracle can only see plaintext.
/// * **Fragmentation.** A value split across two frames, or across a tag
///   boundary, matches nothing.
/// * **Unicode normalisation forms.** Moot by construction: every canary
///   string is pure ASCII, where NFC, NFD, NFKC and NFKD coincide.
///
/// One thing that is NOT a gap, and would be under a weaker producer: a frame
/// whose VERB nobody has seen before. `docs/WIRE_JOURNAL.md` records `frame`
/// verbatim for any JSON array with a string first element, so a novel verb
/// arrives with its payload intact and is scanned like any other. That is
/// exactly where an unanticipated leak would land, and a structural
/// allow-list can only report that the verb was unknown, never what it
/// carried. It is also why the verb reaches the REPORT only through
/// [sanitiseFrameVerb]: scanning `frame[0]` fully and printing it verbatim
/// are not the same decision, and the second one re-leaks.
class CanaryTermSet {
  const CanaryTermSet._(this.terms, this.dropped);

  /// Builds the search set for [manifest].
  factory CanaryTermSet.expand(WireCanaryManifest manifest) {
    final raw = <_Candidate>[
      ..._stringTerms(CanaryId.circleDisplayName, manifest.circleDisplayName),
      ..._stringTerms(CanaryId.petname, manifest.petname),
      ..._coordinateTerms(manifest.latitude, manifest.longitude),
    ];

    final kept = <CanaryTerm>[];
    final dropped = <DroppedTerm>[];
    final seen = <String>{};
    for (final candidate in raw) {
      final term = candidate.term;
      // An encoding that could not be BUILT at all is a coverage gap exactly
      // like one the hygiene gate rejected, and it has to be recorded as one.
      // The alternative — returning null and adding nothing — deletes the
      // encoding from `terms` AND from `dropped`, which is the one state no
      // check over those two lists can see.
      final unbuildable = candidate.unbuildable;
      if (unbuildable != null) {
        dropped.add(DroppedTerm(term, unbuildable, isCoverageGap: true));
        continue;
      }
      final reason = _hygieneReject(term);
      if (reason != null) {
        dropped.add(DroppedTerm(term, reason, isCoverageGap: true));
        continue;
      }
      // De-duplicate on (value, match, caseFold) so an encoding that happens
      // to be the identity of another does not double-report one leak. The
      // FIRST label wins, and the alias is recorded as dropped so the ledger
      // still shows the encoding was considered.
      final key = '${term.match.name}|${term.caseFold}|${term.value}';
      if (!seen.add(key)) {
        dropped.add(
          DroppedTerm(
            term,
            'identical to an earlier term in this set',
            isCoverageGap: false,
          ),
        );
        continue;
      }
      kept.add(term);
    }
    return CanaryTermSet._(
      List<CanaryTerm>.unmodifiable(kept),
      List<DroppedTerm>.unmodifiable(dropped),
    );
  }

  /// The terms that will be searched for.
  final List<CanaryTerm> terms;

  /// The terms that were generated and discarded, with reasons.
  final List<DroppedTerm> dropped;

  // ---------------------------------------------------------------------------
  // Hygiene
  // ---------------------------------------------------------------------------

  /// Minimum length for a term whose alphabet is entirely `[0-9a-f]`.
  ///
  /// A Nostr journal is dominated by lowercase hex — event ids, pubkeys,
  /// signatures, group ids. With a 16-symbol alphabet a 6-character term has
  /// roughly a 1-in-150 chance of occurring by accident somewhere in a
  /// megabyte of it; at 12 characters that falls below 1 in 10^8. A guard
  /// that cries wolf is a guard that gets deleted.
  static const int minPureHexLength = 12;

  /// Minimum length for a term whose alphabet is entirely `[A-Za-z0-9]`.
  ///
  /// The relevant haystack is base64 ciphertext (64 symbols): 6 characters is
  /// ~1-in-45000 per megabyte, 5 characters is ~1-in-1000 — the latter is
  /// flaky enough to matter over a year of nightlies, which is exactly why
  /// short geohash prefixes are asserted as JSON tokens instead.
  static const int minAlnumLength = 6;

  /// Minimum length for a term containing a non-alphanumeric character.
  ///
  /// `.`, `-`, `%`, `\`, `+`, `,` and space cannot occur inside base64 or
  /// hex, so these terms are collision-free against the journal's bulk; the
  /// floor only guards against a degenerate one-character term.
  static const int minMixedLength = 5;

  /// Minimum length for [TermMatch.delimited].
  static const int minDelimitedLength = 6;

  /// Minimum length for [TermMatch.jsonToken].
  ///
  /// A full-token match requires a literal `"` either side, which no base64
  /// or hex run can supply, so short terms are safe here — but not
  /// arbitrarily short: at one or two characters the term starts matching
  /// whole field values that legitimately are one or two characters, such as
  /// a subscription id or a single-digit number rendered as a string.
  static const int minJsonTokenLength = 3;

  static final RegExp _pureHex = RegExp(r'^[0-9a-f]+$');
  static final RegExp _pureAlnum = RegExp(r'^[A-Za-z0-9]+$');

  static String? _hygieneReject(CanaryTerm term) {
    final v = term.value;
    if (v.isEmpty) return 'empty';
    switch (term.match) {
      case TermMatch.jsonToken:
        if (v.length < minJsonTokenLength) {
          return 'json-token term shorter than $minJsonTokenLength chars';
        }
        return null;
      case TermMatch.delimited:
        if (v.length < minDelimitedLength) {
          return 'delimited term shorter than $minDelimitedLength chars';
        }
        return null;
      case TermMatch.substring:
        if (_pureHex.hasMatch(v.toLowerCase()) && v.length < minPureHexLength) {
          return 'pure-hex substring term shorter than $minPureHexLength '
              'chars would collide with event ids / pubkeys / signatures';
        }
        if (_pureAlnum.hasMatch(v) && v.length < minAlnumLength) {
          return 'alphanumeric substring term shorter than $minAlnumLength '
              'chars would collide with base64 ciphertext';
        }
        if (v.length < minMixedLength) {
          return 'substring term shorter than $minMixedLength chars';
        }
        return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Expansion
  // ---------------------------------------------------------------------------

  static List<_Candidate> _stringTerms(String canaryId, String value) {
    _Candidate t(String encoding, String v, {bool fold = false}) =>
        _Candidate(
          CanaryTerm(
            canaryId: canaryId,
            encoding: encoding,
            value: v,
            match: TermMatch.substring,
            caseFold: fold,
          ),
        );

    final casefold = value.toLowerCase();
    final jsonEscaped = jsonUnicodeEscape(value);
    final percentComponent = Uri.encodeComponent(value);
    final percentForm = Uri.encodeQueryComponent(value);
    final hexLower = bytesToHex(utf8.encode(value));

    return <_Candidate>[
      t('utf8-literal', value),
      t('utf8-casefold', casefold, fold: true),
      t('json-unicode-escape', jsonEscaped),
      t('percent-component', percentComponent),
      t('percent-form', percentForm),
      // A UI that renders names in a fixed-width row truncates them, and a
      // truncated name reaching the wire is a partial leak of exactly the
      // value this canary stands for. The bound is stated on
      // CanaryEncodingLedger.maxCoveredTruncation, not chosen here.
      for (var n = 1; n <= CanaryEncodingLedger.maxCoveredTruncation; n++)
        t(
          'utf8-drop$n',
          value.length > n ? value.substring(0, value.length - n) : '',
        ),
      ..._byteTerms(canaryId, 'utf8', utf8.encode(value)),
      // One base64 layer over each covered form. Named by the form's own
      // encoding label, so `percent-component/base64-align1` reads as exactly
      // what it is.
      for (final (form, formValue) in <(String, String)>[
        ('utf8-casefold', casefold),
        ('json-unicode-escape', jsonEscaped),
        ('percent-component', percentComponent),
        ('percent-form', percentForm),
        ('utf8/hex-lower', hexLower),
        ('utf8/hex-upper', hexLower.toUpperCase()),
      ])
        ..._base64Terms(canaryId, form, utf8.encode(formValue)),
    ];
  }

  /// Hex, Rust-debug and base64 renderings of one byte source.
  static List<_Candidate> _byteTerms(
    String canaryId,
    String source,
    List<int> bytes,
  ) {
    final hex = bytesToHex(bytes);
    _Candidate t(String encoding, String v) => _Candidate(
      CanaryTerm(
        canaryId: canaryId,
        encoding: '$source/$encoding',
        value: v,
        match: TermMatch.substring,
      ),
    );
    return <_Candidate>[
      t('hex-lower', hex),
      t('hex-upper', hex.toUpperCase()),
      // `{:?}` / `{:02x?}` / `{:x?}` over a byte slice. The `, ` separator is
      // what makes these assertable at all — it cannot occur inside hex or
      // base64, so even a short slice clears the mixed floor.
      t('debug-dec', rustDebugBytes(bytes)),
      t('debug-hex02', rustDebugBytes(bytes, radix: 16, pad: true)),
      t('debug-hex', rustDebugBytes(bytes, radix: 16)),
      ..._base64Terms(canaryId, source, bytes),
    ];
  }

  /// base64 and base64url stable cores of one byte source, at all three
  /// alignments.
  static List<_Candidate> _base64Terms(
    String canaryId,
    String source,
    List<int> bytes,
  ) {
    final out = <_Candidate>[];
    for (final (variant, urlSafe) in <(String, bool)>[
      ('base64', false),
      ('base64url', true),
    ]) {
      for (var shift = 0; shift < 3; shift++) {
        final core = base64AlignedCore(bytes, shift: shift, urlSafe: urlSafe);
        final term = CanaryTerm(
          canaryId: canaryId,
          encoding: '$source/$variant-align$shift',
          value: core ?? '',
          match: TermMatch.substring,
        );
        out.add(
          core == null
              ? _Candidate.unbuildable(
                  term,
                  '${bytes.length} bytes leave no whole base64 group inside '
                      'the value at alignment $shift, so there is no '
                      'alignment-independent core to search for',
                )
              : _Candidate(term),
        );
      }
    }
    return out;
  }

  static List<_Candidate> _coordinateTerms(double lat, double lon) {
    const id = CanaryId.coordinate;
    final out = <_Candidate>[];

    _Candidate t(String encoding, String v, {TermMatch? match}) => _Candidate(
      CanaryTerm(
        canaryId: id,
        encoding: encoding,
        value: v,
        match: match ?? TermMatch.substring,
      ),
    );

    for (final (name, value) in <(String, double)>[
      ('lat', lat),
      ('lon', lon),
    ]) {
      // Sign-free, so `-47.2093`, `47.2093` and a Unicode-minus form all hit
      // the same term. The `.` is what makes these collision-free.
      final magnitude = value.abs();
      out.add(t('$name/decimal-full', magnitude.toString()));
      // The ladder starts at 0, not at a precision somebody found convenient:
      // 3 dp is house-level (~110 m) and 2 dp is ~1.1 km, both of which are
      // disclosures. The coarsest rungs are generated even where a floor
      // rejects them, so the ledger REPORTS the limitation instead of hiding
      // it behind a loop bound.
      //
      // The rungs ABOVE the value's own significance — 7 and 8 dp for the
      // current canary, whose `toString()` stops at 6 — cannot be shown to
      // fire on a leak that `decimal-full` would miss, because a longer fixed
      // rendering necessarily CONTAINS the shorter one. They are generated
      // anyway, and pinned by name in the ledger, because the canary
      // coordinate is a constant somebody may move: at a coordinate with 8
      // significant decimals the same rungs stop being subsumed, and a ladder
      // that had quietly been shortened would then be a real gap.
      for (var dp = 0; dp <= CanaryEncodingLedger.maxCoveredDecimalPlaces;
          dp++) {
        out
          ..add(t('$name/decimal-round$dp', magnitude.toStringAsFixed(dp)))
          ..add(t('$name/decimal-trunc$dp', truncateDecimal(magnitude, dp)));
      }
      // Fixed point. Delimited, because a bare digit run is otherwise free to
      // land inside an event id or an epoch.
      for (final exp in <int>[6, 7]) {
        out.add(
          t(
            '$name/fixed-e$exp',
            (magnitude * pow(10, exp)).round().toString(),
            match: TermMatch.delimited,
          ),
        );
      }
      // IEEE-754, both widths and both endiannesses, through the full byte
      // pipeline.
      for (final (label, endian) in <(String, Endian)>[
        ('be', Endian.big),
        ('le', Endian.little),
      ]) {
        out
          ..addAll(_byteTerms(id, '$name/f64-$label', float64Bytes(value, endian)))
          ..addAll(
            _byteTerms(id, '$name/f32-$label', float32Bytes(value, endian)),
          );
      }
    }

    // A single f32 axis is under both floors (see the ledger); the PAIR is
    // 8 bytes and clears them, and a pair is what a struct of two f32s
    // serialises to. Both component orders, because declaration order and
    // GeoJSON order are both real.
    for (final (order, first, second) in <(String, double, double)>[
      ('latlon', lat, lon),
      ('lonlat', lon, lat),
    ]) {
      for (final (label, endian) in <(String, Endian)>[
        ('be', Endian.big),
        ('le', Endian.little),
      ]) {
        final bytes = <int>[
          ...float32Bytes(first, endian),
          ...float32Bytes(second, endian),
        ];
        final source = 'f32pair-$order-$label';
        final hex = bytesToHex(bytes);
        out
          ..add(t('$source/hex-lower', hex))
          ..add(t('$source/hex-upper', hex.toUpperCase()))
          ..addAll(_base64Terms(id, source, bytes));
      }
    }

    final gh = geohashEncode(lat, lon, CanaryEncodingLedger.geohashPrecision);
    for (var len = 1; len <= gh.length; len++) {
      final prefix = gh.substring(0, len);
      out
        ..add(t('geohash$len/token', prefix, match: TermMatch.jsonToken))
        ..add(t('geohash$len/substring', prefix));
    }
    return out;
  }
}

/// A term on its way through the expander, plus the reason it could not be
/// built at all (if it could not).
///
/// The reason is carried rather than swallowed because "returned null" and
/// "was rejected" have to reach the same ledger: an encoding that vanishes
/// before the hygiene gate is invisible to every check written over
/// [CanaryTermSet.terms] and [CanaryTermSet.dropped].
class _Candidate {
  const _Candidate(this.term) : unbuildable = null;

  const _Candidate.unbuildable(this.term, this.unbuildable);

  final CanaryTerm term;
  final String? unbuildable;
}

// =============================================================================
// Encoding primitives (public so the fixtures can pin them directly)
// =============================================================================

/// Lowercase hex of [bytes].
String bytesToHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Every code unit of [value] as a JSON `\uXXXX` escape.
String jsonUnicodeEscape(String value) => value.codeUnits
    .map((c) => '\\u${c.toRadixString(16).padLeft(4, '0')}')
    .join();

/// [value] truncated (never rounded) to [dp] decimal places.
String truncateDecimal(double value, int dp) {
  final s = value.toStringAsFixed(dp + 4);
  final dot = s.indexOf('.');
  if (dot < 0) return s;
  return dp == 0 ? s.substring(0, dot) : s.substring(0, dot + 1 + dp);
}

/// IEEE-754 double bytes of [value] in [endian] order.
Uint8List float64Bytes(double value, Endian endian) {
  final data = ByteData(8)..setFloat64(0, value, endian);
  return data.buffer.asUint8List();
}

/// IEEE-754 **single**-precision bytes of [value] in [endian] order.
///
/// A coordinate that has been through an `f32` has lost about 4 decimal
/// digits, which is a different bit pattern from [float64Bytes] and matches
/// none of its terms. Location pipelines narrow to `f32` routinely — a
/// graphics/geometry crate, a protobuf `float`, a compact wire struct — so the
/// narrowed form is its own leak shape rather than a variant of the wide one.
Uint8List float32Bytes(double value, Endian endian) {
  final data = ByteData(4)..setFloat32(0, value, endian);
  return data.buffer.asUint8List();
}

/// Rust's `{:?}` (or `{:x?}` / `{:02x?}`) rendering of a byte slice, without
/// the enclosing brackets.
///
/// The brackets are dropped on purpose: a leak rarely arrives as a bare
/// `Vec<u8>` debug print, it arrives INSIDE one — `Foo { bytes: [81, 122, …] }`
/// — so the bracketless body is what matches both. The `, ` separator is what
/// makes these terms assertable at all: neither a comma nor a space can occur
/// inside hex or base64, so the run is collision-free against the journal's
/// bulk even when it is short.
String rustDebugBytes(List<int> bytes, {int radix = 10, bool pad = false}) =>
    bytes
        .map((b) {
          final s = b.toRadixString(radix);
          return pad ? s.padLeft(2, '0') : s;
        })
        .join(', ');

/// The canonical `lat,lon` rendering used for a coordinate plant proof.
///
/// Six decimal places is ~11 cm, far finer than any tolerance the scanner
/// applies, so this is a lossless-enough record of what the scenario read
/// back rather than a rounding decision.
String formatCoordinateProof(double latitude, double longitude) =>
    '${latitude.toStringAsFixed(6)},${longitude.toStringAsFixed(6)}';

/// The base64 of [bytes] as it appears when [bytes] sit at a byte offset
/// congruent to [shift] (mod 3) inside a larger buffer.
///
/// Base64 consumes three input bytes per four output characters, so a value
/// embedded at an arbitrary offset produces three different character
/// sequences depending on `offset % 3`. Searching only the aligned form would
/// miss two thirds of embedded occurrences.
///
/// Returns the **stable core** only: the leading group that mixes filler with
/// the value, and the trailing group that would mix the value with whatever
/// follows it, are both dropped. What remains is the character run that is
/// identical no matter what surrounds the value. Returns `null` when [bytes]
/// is too short for any whole group to survive that trimming.
String? base64AlignedCore(
  List<int> bytes, {
  required int shift,
  bool urlSafe = false,
}) {
  assert(shift >= 0 && shift < 3, 'shift must be 0, 1 or 2');
  // 0x41 ('A') is arbitrary; the trimming below removes every character that
  // could depend on it.
  final buffer = <int>[...List<int>.filled(shift, 0x41), ...bytes];
  final codec = urlSafe ? base64Url : base64;
  final encoded = codec.encode(buffer).replaceAll('=', '');

  // Index of the first 3-byte group lying wholly inside `bytes`.
  final firstWholeGroup = (shift + 2) ~/ 3;
  // Index one past the last 3-byte group lying wholly inside `bytes`.
  final endWholeGroup = (shift + bytes.length) ~/ 3;
  if (endWholeGroup <= firstWholeGroup) return null;

  final start = firstWholeGroup * 4;
  final end = endWholeGroup * 4;
  if (end > encoded.length) return null;
  return encoded.substring(start, end);
}

/// Standard geohash base-32 alphabet (no `a`, `i`, `l`, `o`).
const String kGeohashAlphabet = '0123456789bcdefghjkmnpqrstuvwxyz';

/// Encodes [lat]/[lon] to a geohash of [precision] characters.
///
/// Re-implemented here rather than bound over FFI because the oracle runs on
/// the CI host with no Rust bridge. `geohashMatchesRustCrate` pins it against
/// values produced by the exact `geohash` 0.13 crate `haven-core` depends on.
String geohashEncode(double lat, double lon, int precision) {
  var latMin = -90.0;
  var latMax = 90.0;
  var lonMin = -180.0;
  var lonMax = 180.0;
  final out = StringBuffer();
  var evenBit = true;
  var bit = 0;
  var index = 0;
  while (out.length < precision) {
    if (evenBit) {
      final mid = (lonMin + lonMax) / 2;
      if (lon >= mid) {
        index = index * 2 + 1;
        lonMin = mid;
      } else {
        index *= 2;
        lonMax = mid;
      }
    } else {
      final mid = (latMin + latMax) / 2;
      if (lat >= mid) {
        index = index * 2 + 1;
        latMin = mid;
      } else {
        index *= 2;
        latMax = mid;
      }
    }
    evenBit = !evenBit;
    if (++bit == 5) {
      out.write(kGeohashAlphabet[index]);
      bit = 0;
      index = 0;
    }
  }
  return out.toString();
}

// =============================================================================
// Journal scanning
// =============================================================================

/// The shape every Nostr frame verb has: `EVENT`, `REQ`, `CLOSE`, `OK`,
/// `EOSE`, `NOTICE`, `CLOSED`, `AUTH`, `COUNT`, `NEG-OPEN`, `NEG-MSG`,
/// `NEG-ERR`, `NEG-CLOSE`, `HAVEN_WIRE_SENTINEL`.
///
/// Deliberately a SHAPE and not an allow-list. A novel verb is exactly what
/// this oracle most needs to surface — `docs/WIRE_JOURNAL.md` records
/// `frame` verbatim for any JSON array with a string first element precisely
/// so an unanticipated frame type keeps its payload — and an allow-list would
/// blank the one field that tells a triager what they are looking at.
final RegExp kFrameVerbShape = RegExp(r'^[A-Z][A-Z0-9_-]{0,31}$');

/// [verb] if it is shaped like a Nostr frame verb, a redacted placeholder if
/// it is not.
///
/// `frame[0]` is frame content like any other element. A debug path that
/// stringifies a struct into the verb position — the same class of bug this
/// library opens by naming — would otherwise reach the LEAK line verbatim,
/// with disclosure off, in the report whose stated contract is "say WHICH
/// canary leaked and WHERE, never WHAT".
///
/// The placeholder keeps the length, because "the verb was 23 characters of
/// something else" is the actionable part and a length is not a disclosure.
String sanitiseFrameVerb(String verb) => kFrameVerbShape.hasMatch(verb)
    ? verb
    : '<non-verb:${verb.length} chars>';

/// Where in the journal a term was found. Never carries frame content.
class FrameRef {
  /// Creates a reference.
  const FrameRef({
    required this.lineNumber,
    this.wireSeq,
    this.connId,
    this.dir,
    this.verb,
    this.kind,
  });

  /// 1-based line number in the journal.
  final int lineNumber;

  /// `wire_seq`, when the line parsed.
  final int? wireSeq;

  /// `conn_id`, when the line parsed.
  final String? connId;

  /// `c2r` / `r2c`, when the line parsed.
  final String? dir;

  /// Frame verb (`EVENT`, `REQ`, ...), when the line parsed.
  ///
  /// SANITISED, never `frame[0]` verbatim — see [sanitiseFrameVerb]. This
  /// class is printed into the failure report, and `frame[0]` is frame
  /// CONTENT: a leak landing in the verb position would otherwise be echoed
  /// in full into a CI artifact with weeks of retention, by the one tool
  /// whose entire job is not to do that.
  final String? verb;

  /// Event kind, for `EVENT` frames.
  final int? kind;

  @override
  String toString() {
    final parts = <String>[
      if (wireSeq != null) 'wire_seq=$wireSeq' else 'line=$lineNumber',
      if (connId != null) 'conn=$connId',
      if (dir != null) dir!,
      if (verb != null) verb!,
      if (kind != null) 'kind=$kind',
    ];
    return parts.join(' ');
  }
}

/// One canary observed on the wire, in one encoding.
class CanaryFinding {
  /// Creates a finding.
  const CanaryFinding({
    required this.term,
    required this.refs,
    required this.totalHits,
  });

  /// The term that matched.
  final CanaryTerm term;

  /// Where it matched, capped at [WireCanaryScanner.maxRefsPerFinding].
  final List<FrameRef> refs;

  /// How many lines matched in total, including any beyond [refs].
  final int totalHits;
}

/// A parsed journal, ready to scan.
class WireJournal {
  const WireJournal._({
    required this.path,
    required List<_JournalLine> lines,
    required this.parsedCount,
    required this.blindLines,
    required this.truncatedTail,
  }) : _lines = lines;

  /// Parses NDJSON [text] from [path].
  ///
  /// A trailing line without its newline is tolerated — C1's proxy may be
  /// mid-write while the oracle reads — but it is still scanned as raw text,
  /// so a leak in it is still caught, and it is reported via [truncatedTail].
  factory WireJournal.parse(String text, {String path = '<memory>'}) {
    final rawLines = text.split('\n');
    final endsWithNewline = text.endsWith('\n');
    final entries = <_JournalLine>[];
    var parsed = 0;
    var blind = 0;
    var truncatedTail = false;

    for (var i = 0; i < rawLines.length; i++) {
      final raw = rawLines[i];
      final isLast = i == rawLines.length - 1;
      if (raw.isEmpty && isLast) continue;
      final lineNumber = i + 1;
      Map<String, dynamic>? obj;
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) obj = decoded;
      } on FormatException {
        obj = null;
      }
      if (obj == null) {
        final isTail = isLast && !endsWithNewline;
        if (isTail) {
          truncatedTail = true;
        } else {
          blind++;
        }
        entries.add(
          _JournalLine(
            lineNumber,
            raw,
            null,
            const <String>[],
            isBlind: !isTail,
          ),
        );
        continue;
      }
      parsed++;
      // Only TRAFFIC lines can hide a leak. `conn_open` / `conn_error`
      // records carry no `dir` and no `frame` key at all, so a check that
      // reads a missing `frame` as "unparseable" would score one blind spot
      // per connection and report every healthy journal as UNUSABLE.
      final isFrameLine =
          obj['type'] == kJournalTypeFrame || obj.containsKey('frame');
      var lineIsBlind = false;
      if (isFrameLine && obj['frame'] == null) {
        lineIsBlind = previewIsIncomplete(
          preview: obj['raw_preview'],
          rawLen: obj['raw_len'],
        );
        if (lineIsBlind) blind++;
      }
      // `raw_preview` is scanned in DECODED form alongside the frame: an
      // unparseable frame is exactly where an unanticipated serialization
      // shows up, and reading only `frame` would leave the one field that
      // records it visible in raw text but not in decoded text.
      entries.add(
        _JournalLine(
          lineNumber,
          raw,
          obj,
          <String>[
            ..._collectStrings(obj['frame']),
            ..._collectStrings(obj['raw_preview']),
          ],
          isBlind: lineIsBlind,
        ),
      );
    }
    return WireJournal._(
      path: path,
      lines: entries,
      parsedCount: parsed,
      blindLines: blind,
      truncatedTail: truncatedTail,
    );
  }

  final List<_JournalLine> _lines;

  /// How many lines decoded as JSON objects.
  final int parsedCount;

  /// Lines this oracle could NOT fully see into.
  ///
  /// Either the line was not JSON at all, or it recorded an unparseable frame
  /// whose preview was truncated. Both mean bytes crossed the wire that were
  /// never scanned, so a clean verdict over them would be an assertion about
  /// evidence that does not exist.
  final int blindLines;

  /// Whether the final line was incomplete (a concurrent writer).
  final bool truncatedTail;

  /// Where this journal came from.
  final String path;

  /// Total lines held.
  int get lineCount => _lines.length;

  /// Blind lines at or below [bound] (all of them when [bound] is null).
  ///
  /// Anchoring matters: a background wake appending after the snapshot can
  /// leave a half-written record, and counting that against the run would
  /// fail a lane for traffic the scenario never claimed to cover.
  int blindLinesUpTo(int? bound) {
    if (bound == null) return blindLines;
    var n = 0;
    for (final line in _lines) {
      final seq = line.obj?['wire_seq'];
      if (line.isBlind && (seq is! int || seq <= bound)) n++;
    }
    return n;
  }

  /// Whether a line at `wire_seq == seq` carries [token] verbatim.
  bool recordsSentinel(String token, int seq) {
    for (final line in _lines) {
      if (line.obj?['wire_seq'] == seq && line.raw.contains(token)) return true;
    }
    return false;
  }

  /// Highest `wire_seq` seen. `null` when no line carried one.
  int? get maxWireSeq {
    int? best;
    for (final line in _lines) {
      final seq = line.obj?['wire_seq'];
      if (seq is int && (best == null || seq > best)) best = seq;
    }
    return best;
  }

  static List<String> _collectStrings(Object? node) {
    final out = <String>[];
    void walk(Object? n) {
      if (n is String) {
        out.add(n);
      } else if (n is List) {
        for (final e in n) {
          walk(e);
        }
      } else if (n is Map) {
        for (final entry in n.entries) {
          if (entry.key is String) out.add(entry.key as String);
          walk(entry.value);
        }
      }
    }

    walk(node);
    return out;
  }
}

class _JournalLine {
  _JournalLine(
    this.lineNumber,
    this.raw,
    this.obj,
    this.strings, {
    this.isBlind = false,
  });

  /// Whether a content scan could NOT see all of this line's payload.
  final bool isBlind;

  final int lineNumber;
  final String raw;
  final Map<String, dynamic>? obj;
  final List<String> strings;

  // Lazily derived views. A journal can run to hundreds of thousands of
  // lines; materialising a lowercase copy and a joined decoded form for every
  // one of them up front is the difference between a scan that fits in the
  // lane's memory budget and one that does not.
  String? _lowerRaw;
  String? _joined;
  String? _lowerJoined;

  String get lowerRaw => _lowerRaw ??= raw.toLowerCase();

  /// Decoded string values joined by NUL, which no term can contain, so the
  /// join cannot manufacture a cross-boundary match for the pre-filter.
  String get joinedStrings => _joined ??= strings.join('\u0000');

  String get lowerJoinedStrings =>
      _lowerJoined ??= joinedStrings.toLowerCase();

  FrameRef get ref {
    final o = obj;
    if (o == null) return FrameRef(lineNumber: lineNumber);
    final frame = o['frame'];
    String? verb;
    int? kind;
    if (frame is List && frame.isNotEmpty && frame.first is String) {
      verb = sanitiseFrameVerb(frame.first as String);
      for (final element in frame.skip(1)) {
        if (element is Map<String, dynamic> && element['kind'] is int) {
          kind = element['kind'] as int;
          break;
        }
      }
    }
    return FrameRef(
      lineNumber: lineNumber,
      wireSeq: o['wire_seq'] is int ? o['wire_seq'] as int : null,
      connId: o['conn_id'] is String ? o['conn_id'] as String : null,
      dir: o['dir'] is String ? o['dir'] as String : null,
      verb: verb,
      kind: kind,
    );
  }

  /// The event ids this line mentions, lowercased.
  Set<String> eventIds() {
    final out = <String>{};
    final frame = obj?['frame'];
    if (frame is! List) return out;
    for (final element in frame.skip(1)) {
      if (element is Map<String, dynamic> && element['id'] is String) {
        out.add((element['id'] as String).toLowerCase());
      }
    }
    // `["OK", <id>, true, ""]` carries the id as a bare string.
    if (frame.isNotEmpty && frame.first == 'OK' && frame.length >= 2) {
      final id = frame[1];
      if (id is String) out.add(id.toLowerCase());
    }
    return out;
  }
}

/// The verdict for one run.
///
/// The three failure modes demand three different operator responses, which is
/// why they are three values and three exit codes rather than "non-zero". This
/// mirrors `tooling/e2e/ci/check-wire-journal.sh` exactly, so a lane running
/// both oracles reads one convention.
enum CanaryVerdict {
  /// Journal usable and anchored, every positive control satisfied, nothing
  /// found.
  clean,

  /// A canary appeared on the wire. Also a containment signal: the journal
  /// now holds plaintext of a value that must never leave the device.
  leak,

  /// The RECORDER broke — absent, empty, unreadable, blind or unanchored
  /// journal. The scan could not be performed.
  unusable,

  /// The SCENARIO broke — the journal is fine, but it proves too little: a
  /// canary with no carrier, or carriers the journal never recorded. A
  /// forbid-check over a window that never contained the value passes for
  /// free, so this is emphatically not a pass.
  metaFloor,
}

/// The complete result of scanning a journal set against a manifest set.
class WireCanaryReport {
  /// Creates a report.
  const WireCanaryReport({
    required this.findings,
    required this.vacuities,
    required this.unusable,
    required this.dropped,
    required this.linesScanned,
    required this.termCount,
    required this.canaryCount,
  });

  /// Canaries observed on the wire. Non-empty means [CanaryVerdict.leak].
  final List<CanaryFinding> findings;

  /// Positive controls that were not satisfied.
  final List<String> vacuities;

  /// Reasons the evidence itself is unusable.
  final List<String> unusable;

  /// Terms that were generated and discarded, with reasons.
  final List<DroppedTerm> dropped;

  /// Journal lines scanned across all journals.
  final int linesScanned;

  /// Distinct terms searched for.
  final int termCount;

  /// Manifests folded into this report.
  final int canaryCount;

  /// The overall verdict.
  ///
  /// A confirmed leak outranks missing evidence, matching
  /// `tooling/e2e/ci/scan-logs-for-secrets.sh`: callers key log containment
  /// off the leak verdict, and it is the actionable finding.
  /// The overall verdict.
  ///
  /// Precedence is leak > unusable > meta-floor. A confirmed leak outranks
  /// everything because callers key log containment off it. A broken recorder
  /// outranks a failed meta-floor because it EXPLAINS one: a carrier missing
  /// from a journal the proxy never finished writing is a recorder symptom,
  /// and reporting it as a scenario fault would send triage to the wrong
  /// half of the lane.
  CanaryVerdict get verdict {
    if (findings.isNotEmpty) return CanaryVerdict.leak;
    if (unusable.isNotEmpty) return CanaryVerdict.unusable;
    if (vacuities.isNotEmpty) return CanaryVerdict.metaFloor;
    return CanaryVerdict.clean;
  }

  /// Process exit code, matching `tooling/e2e/ci/check-wire-journal.sh`:
  /// 0 clean, 1 violation, 3 UNUSABLE (recorder broke), 4 META-FLOOR
  /// (scenario broke). 2 is reserved for usage errors, raised by the CLI.
  int get exitCode => switch (verdict) {
    CanaryVerdict.clean => 0,
    CanaryVerdict.leak => 1,
    CanaryVerdict.unusable => 3,
    CanaryVerdict.metaFloor => 4,
  };

  /// The failure report, deliberately WITHOUT any matched content.
  ///
  /// ## What this discloses, and why
  ///
  /// A canary oracle's output is, by construction, a report about a secret.
  /// The CI artifact it lands in is retained for weeks and is readable by
  /// anyone with repository access, so the rule applied here is the one
  /// `scan-logs-for-secrets.sh` established: say WHICH canary leaked and
  /// WHERE, never WHAT.
  ///
  /// Emitted: the canary id, the encoding, the number of matching lines, and
  /// for each one its `wire_seq` / `conn_id` / direction / frame verb / event
  /// kind. That is everything needed to open the journal and find the frame.
  ///
  /// Withheld: the matched substring, the frame body, and the canary's own
  /// value. The value is withheld even though it is a test fixture rather
  /// than a real user secret, for two reasons. It is already recoverable from
  /// the manifest line in the drive log by anyone triaging, so repeating it
  /// buys nothing; and the habit of printing "the thing we were looking for"
  /// is precisely the habit that turns a privacy guard into a second copy of
  /// the leak the day someone points it at a real value.
  ///
  /// [discloseValues] switches that off for local triage. It exists so the
  /// CI default can stay strict without making the tool unusable at a
  /// developer's terminal; no CI caller should pass it.
  ///
  /// ## Two independent stops on the location string
  ///
  /// A location is not automatically content-free. `frame[0]` reaches the
  /// report as [FrameRef.verb], so a leak landing in the verb position would
  /// travel out inside the very field that is supposed to be metadata.
  /// [sanitiseFrameVerb] is the structural stop — a verb that is not shaped
  /// like a Nostr verb never leaves [FrameRef] at all — and [_scrub] is the
  /// value-aware one: any term this report already knows leaked is removed
  /// from the rendered location, case-insensitively, whatever field carried
  /// it. The structural stop alone would let an all-caps leak through; the
  /// value-aware stop alone would let a leak through that no term matched
  /// exactly. Neither is redundant.
  List<String> renderLines({bool discloseValues = false}) {
    final out = <String>[];
    for (final f in findings) {
      final where = f.refs.map((r) => '(${_scrub(r.toString())})').join(', ');
      final more = f.totalHits > f.refs.length
          ? ' [+${f.totalHits - f.refs.length} more]'
          : '';
      out.add(
        'LEAK: canary "${f.term.canaryId}" reached the wire '
        '[encoding: ${f.term.encoding}] [match: ${f.term.match.name}] '
        'on ${f.totalHits} line(s): $where$more',
      );
      if (discloseValues) {
        out.add('      term (--disclose-values): ${f.term.value}');
      }
    }
    for (final v in vacuities) {
      out.add('META-FLOOR: $v');
    }
    for (final u in unusable) {
      out.add('UNUSABLE: $u');
    }
    return out;
  }

  /// Removes every leaked term value from [text].
  ///
  /// Case-insensitive because the case-folded terms are stored lowercased
  /// while the frame that carried them need not be, so an exact-case pass
  /// would step over precisely the leak the folded term found.
  String _scrub(String text) {
    if (findings.isEmpty) return text;
    final values = <String>{
      for (final f in findings)
        if (f.term.value.isNotEmpty) f.term.value,
    };
    if (values.isEmpty) return text;
    final pattern = RegExp(
      values.map(RegExp.escape).join('|'),
      caseSensitive: false,
    );
    return text.replaceAll(pattern, '<redacted>');
  }

  /// One-line summary for the success path.
  ///
  /// Gaps and aliases are counted SEPARATELY. A single "N dropped" number
  /// reads as N holes when most of them are an encoding that collapsed into
  /// its neighbour and cost nothing — and a reader who learns to ignore the
  /// number stops noticing when the half that is real grows.
  String get summary {
    final gaps = dropped.where((d) => d.isCoverageGap).length;
    return 'wire-canary: ${verdict.name} — $canaryCount manifest(s), '
        '$termCount term(s), $linesScanned journal line(s) scanned, '
        '$gaps term(s) unassertable (declared gaps), '
        '${dropped.length - gaps} alias(es) folded.';
  }
}

/// Scans wire journals for planted canaries.
abstract final class WireCanaryScanner {
  /// How many locations to name per finding before summarising the rest.
  static const int maxRefsPerFinding = 20;

  /// Runs both halves of the oracle: the forbid-scan and the positive
  /// controls.
  ///
  /// [journals] must be non-empty and every journal must hold at least one
  /// line; [manifests] must be non-empty. Each of those is an UNUSABLE
  /// verdict rather than a pass, because a run with no evidence has not shown
  /// that nothing leaked — it has shown nothing.
  static WireCanaryReport scan({
    required List<WireJournal> journals,
    required List<WireCanaryManifest> manifests,
    int? maxWireSeq,
  }) {
    final unusable = <String>[];
    final vacuities = <String>[];

    // The forbid scan and the evidence checks are bounded ASYMMETRICALLY, on
    // purpose. Lines past the snapshot can only ADD true positives to a
    // forbid check — a canary on the wire is a canary on the wire whenever it
    // was sent — so the scan runs unbounded unless a caller asks otherwise.
    // The same lines can only add FALSE alarms to an evidence check, since a
    // writer still appending has not finished its record, so the evidence
    // half is anchored to the sentinel whenever the scenario emitted one.
    //
    // "The evidence half" means ALL of it: the blind-spot count, the
    // truncated tail AND the positive controls. A control that reads past its
    // own bound reintroduces the A4 failure in the one place it is hardest to
    // see — carriers recorded far past an explicit `--max-wire-seq` would
    // satisfy a window the forbid scan never examined, and the run reports
    // clean with zero vacuities over a snapshot it never covered.
    final sentinelSeqs = manifests
        .map((m) => m.sentinelWireSeq)
        .whereType<int>()
        .toList();
    final evidenceBound = maxWireSeq ??
        (sentinelSeqs.isEmpty
            ? null
            : sentinelSeqs.reduce((a, b) => a > b ? a : b));

    if (manifests.isEmpty) {
      // META-FLOOR, not UNUSABLE: the log was readable, it simply carries no
      // announcement. That is the SCENARIO failing to plant (or failing to
      // announce), which needs a different fix from a recorder that died. A
      // manifest file that is absent or empty is reported by the CLI as
      // UNUSABLE instead, because there the evidence capture is what broke.
      vacuities.add(
        'no wire-canary manifest was found. The scenario never announced a '
        'plant, so there is no canary to look for and this run proves '
        'nothing about content leakage.',
      );
    }
    if (journals.isEmpty) {
      unusable.add(
        'no wire journal was supplied; nothing was scanned.',
      );
    }
    for (final j in journals) {
      if (j.lineCount == 0) {
        unusable.add(
          "${j.path} [empty] — 0 lines; C1's recording proxy never wrote "
          'anything, so no frame was examined.',
        );
      }
      if (j.parsedCount == 0 && j.lineCount > 0) {
        unusable.add(
          '${j.path} [unparseable] — ${j.lineCount} line(s), none of which '
          'decoded as an NDJSON object.',
        );
      }
      final blind = j.blindLinesUpTo(evidenceBound);
      if (blind > 0) {
        unusable.add(
          '${j.path} [blind spots] — $blind line(s) were not fully visible '
          'to a content scan (a frame the proxy could not parse and whose '
          'raw_preview hit the $kRawPreviewMaxChars-character cap, or a line '
          'that is not JSON). Bytes crossed the wire that this scan never '
          'read.',
        );
      }
      // A tail still being written is only a finding when nothing anchors the
      // read. With a sentinel the snapshot ends at a known `wire_seq`, and a
      // background wake appending past it is expected rather than damaging.
      if (j.truncatedTail && evidenceBound == null) {
        unusable.add(
          '${j.path} [truncated tail] — the final line has no newline, so a '
          'writer was still appending while the oracle read, and no sentinel '
          'anchors the read. It was scanned as raw text, but the journal is '
          'not a complete record.',
        );
      }
    }

    // ---- anchoring ---------------------------------------------------------
    // A recorded sentinel is the only direct proof that the traffic this
    // oracle scanned went THROUGH the recording proxy. Without it, a lane
    // that pointed the app straight at the relay produces a journal holding
    // only the harness's own frames — quiet, well-formed, and worthless.
    for (final m in manifests) {
      final token = m.sentinelToken;
      final seq = m.sentinelWireSeq;
      if (token == null || seq == null) continue;
      final recorded = journals.any((j) => j.recordsSentinel(token, seq));
      if (!recorded) {
        unusable.add(
          '[${m.role}] the wire-journal sentinel the drive emitted (and the '
          'proxy acked at wire_seq=$seq) is ABSENT from every journal. The '
          'recorder did not write what it acknowledged, or the journal '
          'handed to this oracle is not the one the run produced.',
        );
      }
    }

    // ---- forbid half -------------------------------------------------------
    final allTerms = <CanaryTerm>[];
    final allDropped = <DroppedTerm>[];
    for (final m in manifests) {
      final set = CanaryTermSet.expand(m);
      allTerms.addAll(set.terms);
      allDropped.addAll(set.dropped);
      // The coverage claim is checked, not assumed. A ledger disagreement
      // means this oracle no longer covers what it says it covers, so its
      // verdict on this run carries no information — UNUSABLE, exactly like a
      // journal the recorder never finished.
      for (final discrepancy in CanaryEncodingLedger.reconcile(set)) {
        unusable.add(
          '[${m.role}] the covered-encoding ledger and the term expander '
          'disagree. $discrepancy',
        );
      }
    }

    final findings = <CanaryFinding>[];
    if (allTerms.isNotEmpty) {
      // Two combined regexes over EVERY term, evaluated ONCE PER LINE rather
      // than once per (line, term). Almost every line matches nothing, and
      // the per-term matcher below has to walk that line's decoded string
      // list, so hoisting the gate out of the term loop is the difference
      // between a scan measured in seconds and one measured in minutes on a
      // journal of any realistic size.
      final exact = _combine(allTerms.where((t) => !t.caseFold));
      final folded = _combine(allTerms.where((t) => t.caseFold));
      final refs = <CanaryTerm, List<FrameRef>>{};
      final totals = <CanaryTerm, int>{};

      for (final journal in journals) {
        for (final line in journal._lines) {
          if (maxWireSeq != null) {
            final seq = line.obj?['wire_seq'];
            if (seq is int && seq > maxWireSeq) continue;
          }
          final exactHit = exact != null &&
              (exact.hasMatch(line.raw) || exact.hasMatch(line.joinedStrings));
          final foldedHit = folded != null &&
              (folded.hasMatch(line.lowerRaw) ||
                  folded.hasMatch(line.lowerJoinedStrings));
          if (!exactHit && !foldedHit) continue;

          for (final term in allTerms) {
            if (!(term.caseFold ? foldedHit : exactHit)) continue;
            if (!_matches(term, line)) continue;
            totals[term] = (totals[term] ?? 0) + 1;
            final seen = refs.putIfAbsent(term, () => <FrameRef>[]);
            if (seen.length < maxRefsPerFinding) seen.add(line.ref);
          }
        }
      }

      // Emitted in term order so a report is stable across runs.
      for (final term in allTerms) {
        final total = totals[term];
        if (total == null) continue;
        findings.add(
          CanaryFinding(
            term: term,
            refs: List<FrameRef>.unmodifiable(refs[term]!),
            totalHits: total,
          ),
        );
      }
    }

    // ---- positive-control half --------------------------------------------
    // Bounded by `evidenceBound`, exactly like the blind-spot and tail checks
    // above. Evidence for a snapshot has to come from INSIDE the snapshot.
    if (journals.isNotEmpty) {
      final sent = <String>{};
      final anywhere = <String>{};
      final sentKinds = <String, Set<int>>{};
      for (final journal in journals) {
        for (final line in journal._lines) {
          if (evidenceBound != null) {
            final seq = line.obj?['wire_seq'];
            if (seq is int && seq > evidenceBound) continue;
          }
          final ids = line.eventIds();
          if (ids.isEmpty) continue;
          anywhere.addAll(ids);
          if (line.obj?['dir'] != 'c2r') continue;
          sent.addAll(ids);
          final kind = line.ref.kind;
          if (kind == null) continue;
          for (final id in ids) {
            (sentKinds[id] ??= <int>{}).add(kind);
          }
        }
      }
      for (final m in manifests) {
        for (final canaryId in CanaryId.all) {
          // The plant proof comes FIRST, because it is the only check that
          // speaks to whether the canary was ever applied. Carrier ids prove
          // the journal's window; they cannot tell a genuine carrier from any
          // published event id, so a scenario that mints three values, plants
          // none, and records three ordinary sent ids clears every check
          // below this one.
          final proof = m.plantProofs[canaryId];
          if (proof == null) {
            vacuities.add(
              '[${m.role}] canary "$canaryId" has NO plant proof. The '
              'scenario never read the value back out of the app, so a run in '
              'which the plant silently failed — a renamed field, a validator '
              'that rejected it, a UI path that changed — is indistinguishable '
              'from one in which it took, and the forbid half is asserting the '
              'absence of a value that may never have existed.',
            );
            continue;
          }
          if (!_plantProofMatches(m, canaryId, proof)) {
            // Deliberately without either value: this report is read off a CI
            // artifact, and printing "expected X, got Y" would put the canary
            // in it twice.
            vacuities.add(
              '[${m.role}] canary "$canaryId": the plant proof does NOT match '
              'the planted value. The app returned something other than what '
              'the scenario planted, so whatever this run put on the wire is '
              'not what the forbid half was searching for.',
            );
            continue;
          }
          final carriers = m.carrierEventIds[canaryId] ?? const <String>[];
          if (carriers.isEmpty) {
            vacuities.add(
              '[${m.role}] canary "$canaryId" has an EMPTY carrier set. The '
              'scenario never recorded an event proving the journal covers '
              'the window in which this canary could have leaked, so '
              '"it never appeared" is unfalsifiable.',
            );
            continue;
          }
          final missing =
              carriers.where((id) => !anywhere.contains(id)).toList();
          if (missing.isNotEmpty) {
            vacuities.add(
              '[${m.role}] canary "$canaryId": ${missing.length} of '
              '${carriers.length} carrier event(s) are ABSENT from the '
              'journal (e.g. ${_redactId(missing.first)}). The frames that '
              'carried this canary were not recorded, so scanning the '
              'journal for it proves nothing.',
            );
            continue;
          }
          if (!carriers.any(sent.contains)) {
            vacuities.add(
              '[${m.role}] canary "$canaryId": every carrier event appears '
              'only as relay->client traffic. This is a SEND-side oracle; '
              'without one client->relay observation it never saw a '
              'transmission that could have leaked.',
            );
            continue;
          }
          // Typed carriers. "Some id the app published" is satisfiable by any
          // event; a carrier for the circle name has to be a frame that can
          // CARRY group metadata, and one for the coordinate a group message.
          // This also catches the mundane version of the same mistake —
          // recording the id off the wrong event.
          final requiredKinds = kCanaryCarrierKinds[canaryId];
          if (requiredKinds == null) continue;
          final observed = <int>{
            for (final id in carriers) ...?sentKinds[id],
          };
          if (observed.intersection(requiredKinds).isEmpty) {
            final wanted = (requiredKinds.toList()..sort()).join(' or ');
            final saw = observed.isEmpty
                ? 'no kind at all'
                : (observed.toList()..sort()).join('/');
            vacuities.add(
              '[${m.role}] canary "$canaryId": no carrier event was observed '
              'client->relay as an event of kind $wanted (saw $saw). '
              'The recorded ids prove traffic happened, not that anything '
              'able to carry this canary was transmitted.',
            );
          }
        }
      }
    }

    return WireCanaryReport(
      findings: findings,
      vacuities: vacuities,
      unusable: unusable,
      dropped: allDropped,
      linesScanned: journals.fold(0, (a, j) => a + j.lineCount),
      termCount: allTerms.length,
      canaryCount: manifests.length,
    );
  }

  /// Whether [proof] is the value the plant should have produced.
  ///
  /// The coordinate is compared NUMERICALLY, within
  /// [kCoordinateProofTolerance]: a coordinate read back through a decrypt
  /// and a JSON round trip can differ in the last bits without the plant
  /// having failed, while nothing but the canary is within 11 m of a point in
  /// the middle of the South Pacific gyre.
  static bool _plantProofMatches(
    WireCanaryManifest manifest,
    String canaryId,
    String proof,
  ) {
    if (canaryId != CanaryId.coordinate) {
      return proof.trim() == manifest.expectedPlantProof(canaryId).trim();
    }
    final parts = proof.split(',');
    if (parts.length != 2) return false;
    final lat = double.tryParse(parts[0].trim());
    final lon = double.tryParse(parts[1].trim());
    if (lat == null || lon == null) return false;
    return (lat - manifest.latitude).abs() <= kCoordinateProofTolerance &&
        (lon - manifest.longitude).abs() <= kCoordinateProofTolerance;
  }

  static RegExp? _combine(Iterable<CanaryTerm> terms) {
    final values = terms.map((t) => RegExp.escape(t.value)).toSet().toList();
    if (values.isEmpty) return null;
    return RegExp(values.join('|'));
  }

  static bool _matches(CanaryTerm term, _JournalLine line) {
    final haystack = term.caseFold ? line.lowerRaw : line.raw;
    switch (term.match) {
      case TermMatch.substring:
        if (haystack.contains(term.value)) return true;
        return _matchesDecoded(term, line);
      case TermMatch.jsonToken:
        if (haystack.contains('"${term.value}"')) return true;
        return _matchesDecoded(term, line);
      case TermMatch.delimited:
        var from = 0;
        while (true) {
          final at = haystack.indexOf(term.value, from);
          if (at < 0) break;
          final before = at == 0 ? null : haystack.codeUnitAt(at - 1);
          final afterIndex = at + term.value.length;
          final after = afterIndex >= haystack.length
              ? null
              : haystack.codeUnitAt(afterIndex);
          if (!_isAlnum(before) && !_isAlnum(after)) return true;
          from = at + 1;
        }
        return _matchesDecoded(term, line);
    }
  }

  /// Second pass over the frame's decoded string values.
  ///
  /// `jsonDecode` has already undone whatever escaping the proxy's serialiser
  /// applied, so this catches a canary that arrived `\uXXXX`-escaped, or
  /// half-escaped, without needing a term per escaping style. The explicit
  /// `json-unicode-escape` term still earns its place: it is the only thing
  /// that sees into a line whose frame did not parse.
  static bool _matchesDecoded(CanaryTerm term, _JournalLine line) {
    for (final s in line.strings) {
      final value = term.caseFold ? s.toLowerCase() : s;
      switch (term.match) {
        case TermMatch.substring:
          if (value.contains(term.value)) return true;
        case TermMatch.jsonToken:
          if (value == term.value) return true;
        case TermMatch.delimited:
          if (value == term.value) return true;
      }
    }
    return false;
  }

  static bool _isAlnum(int? c) {
    if (c == null) return false;
    return (c >= 0x30 && c <= 0x39) ||
        (c >= 0x41 && c <= 0x5a) ||
        (c >= 0x61 && c <= 0x7a);
  }

  static String _redactId(String id) =>
      id.length <= 12 ? id : '${id.substring(0, 12)}...';
}
