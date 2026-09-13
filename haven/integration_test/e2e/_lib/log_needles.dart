/// Log-needle declaration + positive-control plants for the runtime
/// log-privacy scanner (`tooling/logscan`, Phase 0b of the soak plan).
///
/// The scanner (Security Rule 15 / the Log anonymity pillar) asserts that a
/// value the scenario minted or observed is ABSENT from every captured sink.
/// An absence assertion needs the value, and the value cannot be recovered
/// from the sinks themselves — their not containing it is the assertion. So
/// the device hands every value it wants scanned-for to the host, over the
/// proxy's control channel, exactly as [TestRelay.announceMlsGroupId] already
/// does for the one value with its own dedicated channel (the real MLS group
/// id, Security Rule 4). [LogNeedles.declare] is the general form of that same
/// idea for every OTHER identifier class the scanner covers.
///
/// [LogNeedles.plant] additionally proves the Dart sinks (`logcat`'s `flutter`
/// tag and the `drive` capture) are reached at all: a forbid-check over a sink
/// the scanner never actually read passes for free, so a positive control —
/// a value planted on purpose and required to be FOUND — is what makes the
/// negative half falsifiable.
library;

import 'dart:math';

import 'package:flutter/foundation.dart';

import 'test_relay.dart';

/// Alphabet a plant-token suffix is drawn from — Crockford's base32 (excludes
/// `I`, `O`, `0`, `1`, which read as ambiguous next to `1`/`l`/`0`/`O`).
const String _kPlantAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

/// The subset of [_kPlantAlphabet] that is NOT a valid hex digit in either
/// case — i.e. everything except `A`-`F` and `2`-`9`.
///
/// A plant must never itself trip the structural hex-run rule either scanner
/// applies, so [_mintPlantSuffix] forces a character from this set into every
/// 4-character window of the random suffix — see that function's doc for how.
const String _kPlantNonHexAlphabet = 'GHJKLMNPQRSTUVWXYZ';

/// Positions in the 10-character suffix forced to [_kPlantNonHexAlphabet].
///
/// Spaced 3 apart, so every possible 4-character window of a 10-character
/// string contains at least one of them — the property that keeps a
/// contiguous hex-valid run from ever reaching 4 characters, let alone the
/// ≥16 a structural rule fires on. This is a construction guarantee, not a
/// probabilistic one: it holds for every token this function can produce, not
/// merely for most of them.
const List<int> _kForcedNonHexPositions = <int>[0, 3, 6, 9];

/// How many characters make up a plant token's random suffix.
const int _kPlantSuffixLength = 10;

/// Mints a plant-token suffix immune to a hex-run structural rule BY
/// CONSTRUCTION.
///
/// [_kPlantAlphabet]'s hex-valid subset (`A`-`F`, `2`-`9` — 14 of its 32
/// symbols) can still spell out ordinary-looking hex if drawn without
/// constraint, so [_kForcedNonHexPositions] are always drawn from
/// [_kPlantNonHexAlphabet] instead.
String _mintPlantSuffix(Random rng) {
  final buffer = StringBuffer();
  for (var i = 0; i < _kPlantSuffixLength; i++) {
    final alphabet = _kForcedNonHexPositions.contains(i)
        ? _kPlantNonHexAlphabet
        : _kPlantAlphabet;
    buffer.write(alphabet[rng.nextInt(alphabet.length)]);
  }
  return buffer.toString();
}

/// One log-privacy plant token: `logscan-plant-dart-<phase>-<10 chars>`.
String _mintPlantToken(String phase, Random rng) =>
    'logscan-plant-dart-$phase-${_mintPlantSuffix(rng)}';

/// The declaration payload [LogNeedles.declare] sends — the frame's second
/// element, before the proxy adds `role`/`seq` (`needles.rs`'s reserved keys,
/// which this payload must never carry).
///
/// A pure function so the exact shape the proxy's `validate_payload` and the
/// sidecar line see can be pinned by a host test with no socket in the loop.
Map<String, String> needleDeclPayload({
  required String needleClass,
  required String value,
}) => <String, String>{'class': needleClass, 'value': value};

/// The declaration payload [LogNeedles.plant] sends for one plant token.
///
/// Carries `sink`/`phase` alongside `class`/`value` so the scanner's plant
/// reconciliation (recon §9.3) can tell a `dart` plant from the undeclared
/// Rust/Kotlin/Swift ones, and `open` from `close`.
Map<String, String> plantDeclPayload({
  required String phase,
  required String token,
}) => <String, String>{
  'class': 'plant',
  'sink': 'dart',
  'phase': phase,
  'value': token,
};

/// Declares log needles and positive-control plants for one scenario run,
/// over a [TestRelay] connection to the recording proxy.
///
/// One instance per drive target, bound to whichever [TestRelay] connection
/// is conveniently alive for the run's duration — the proxy's needle sidecar
/// is keyed by its own process role, not by which app-side WebSocket carried
/// a given declaration, so any live connection through the same proxy
/// instance reaches the same sidecar.
class LogNeedles {
  /// Creates a declarer bound to [relay].
  LogNeedles(TestRelay relay) : _relay = relay;

  final TestRelay _relay;
  final Random _rng = Random.secure();

  /// Declares one value the runtime log scanner must assert is ABSENT from
  /// every captured sink.
  ///
  /// A no-op — never a throw — on a lane that declares no recording proxy
  /// (`wireRecorderDeclared` false): see [TestRelay.declareNeedle]'s doc for
  /// why that gate lives there rather than here.
  Future<void> declare(String needleClass, String value) => _relay
      .declareNeedle(needleDeclPayload(needleClass: needleClass, value: value));

  /// Mints, declares and prints one positive-control plant for [phase]
  /// (`'open'` or `'close'`).
  ///
  /// The token is declared over the SAME channel as [declare] (so an
  /// undeclared-recorder lane also skips the declare half, silently) but is
  /// ALWAYS printed via [debugPrint] — plants prove sink reach, and a lane
  /// with no proxy still has a `logcat`/`drive` sink for the scanner to check
  /// once a recorder eventually runs against its capture.
  Future<void> plant(String phase) async {
    final token = _mintPlantToken(phase, _rng);
    await _relay.declareNeedle(plantDeclPayload(phase: phase, token: token));
    debugPrint(token);
  }

  /// Announces the run's wire-canary manifest (`WireCanaryManifest.toJson()`)
  /// to the recording proxy, replacing the old drive-log announcement line.
  ///
  /// See [TestRelay.announceCanaryManifest] for the full contract — in
  /// particular, unlike [declare]/[plant], this throws on an undeclared
  /// recorder rather than silently dropping the manifest.
  Future<void> announceCanaryManifest(Map<String, Object?> manifest) =>
      _relay.announceCanaryManifest(manifest);
}
