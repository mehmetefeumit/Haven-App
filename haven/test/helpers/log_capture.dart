/// Shared [debugPrint] capture + log-anonymity assertions for tests.
///
/// Replaces the `_captureDebugPrint()` helper hand-copied into roughly a
/// dozen test files: same install/restore mechanism, plus one assertion
/// surface (`assertNoNeedles`) so every caller checks the same truncation/
/// re-casing shapes a half-fixed log line could still leak an identifier
/// through, instead of whatever subset the copy-paste happened to keep.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// Captures everything written through [debugPrint] for the life of this
/// object, and restores the prior callback on [restore].
class LogCapture {
  /// Installs the capture immediately. The caller controls when [restore]
  /// runs — use this shape when a test must restore before its body ends
  /// (e.g. a `testWidgets` invariant check that runs before `addTearDown`
  /// callbacks do; see `throw_time_error_capture_behavior_test.dart`).
  LogCapture() : _previous = debugPrint {
    debugPrint = (String? message, {int? wrapWidth}) => _lines.add(message);
  }

  /// Installs a capture and schedules [restore] via [addTearDown] — the
  /// right choice whenever the test itself does not need to control the
  /// restore instant.
  factory LogCapture.install() {
    final capture = LogCapture();
    addTearDown(capture.restore);
    return capture;
  }

  final DebugPrintCallback _previous;
  final List<String?> _lines = [];

  /// Every line captured so far, in call order.
  List<String?> get lines => List.unmodifiable(_lines);

  /// All non-null captured lines, joined with `\n`, for substring
  /// assertions.
  String get joined => _lines.whereType<String>().join('\n');

  /// Puts the real [debugPrint] back. Idempotent; safe to call more than
  /// once (e.g. once manually, once via a stale `addTearDown`).
  void restore() => debugPrint = _previous;

  /// Asserts that none of [needles] appear anywhere in [joined], in any of
  /// the shapes a "redaction" that only prettifies truncation would still
  /// leak: the literal value, upper/lower case, an 8- or 16-char prefix, the
  /// needle's own bytes hex-encoded, and — for a needle that parses as a
  /// URL — its bare host. Needles shorter than 4 chars are skipped: below
  /// that length a "match" proves nothing (it matches arbitrary prose), the
  /// same floor the Rust side's `assert_no_needles`/`assert_rendering_redacted`
  /// enforce.
  ///
  /// Requires [joined] to be non-empty — the other half of the anti-vacuity
  /// contract [assertContains] provides explicitly: a capture that recorded
  /// NOTHING would otherwise satisfy every needle check by having nothing to
  /// contain it, which proves a redaction happened as convincingly as it
  /// proves logging was silently disabled. Call [assertContains] first (or
  /// otherwise establish something was captured) so a genuinely empty
  /// capture fails loudly here instead.
  void assertNoNeedles(Iterable<String> needles) {
    final text = joined;
    expect(
      text,
      isNotEmpty,
      reason: 'nothing was captured, so the absence of every needle below '
          'proves nothing — call assertContains (or otherwise confirm '
          'something was logged) before assertNoNeedles',
    );
    for (final needle in needles) {
      if (needle.length < 4) continue;
      for (final variant in _variantsOf(needle)) {
        expect(
          text,
          isNot(contains(variant)),
          reason: 'log output must never contain "$variant" (from "$needle")',
        );
      }
    }
  }

  /// Anti-vacuity: asserts [marker] IS present in [joined]. Without this,
  /// [assertNoNeedles] would pass identically whether the code redacted the
  /// needle or simply logged nothing.
  void assertContains(String marker) {
    expect(
      joined,
      contains(marker),
      reason:
          'expected marker "$marker" to be present — otherwise the '
          'negative assertions above prove nothing',
    );
  }

  static Set<String> _variantsOf(String needle) {
    final variants = <String>{
      needle,
      needle.toUpperCase(),
      needle.toLowerCase(),
      // Mirrors `haven_core::util::forbidden_forms`'s `encoded` form: a
      // "redaction" that hex-encodes the raw value before printing it has
      // not redacted anything.
      _hexEncode(needle),
    };
    if (needle.length > 8) variants.add(needle.substring(0, 8));
    if (needle.length > 16) variants.add(needle.substring(0, 16));
    // A needle that is itself a URL can still leak via its bare host once
    // the scheme/path are stripped off by an otherwise-fixed log line.
    final uri = Uri.tryParse(needle);
    if (uri != null && uri.host.isNotEmpty) variants.add(uri.host);
    return variants;
  }

  /// Lowercase hex of [value]'s UTF-8 bytes — no external dependency needed
  /// for a two-nibble-per-byte encoding.
  static String _hexEncode(String value) => utf8
      .encode(value)
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
}
