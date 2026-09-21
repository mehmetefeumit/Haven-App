/// Reading the one Nostr tag Haven routes on.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

/// The `h` tag value of a signed Nostr event JSON — the circle's PUBLIC nostr
/// group id, lowercase hex — or `null` when the event carries none.
///
/// This is the only thing on a group event that says which circle it belongs
/// to: the real MLS group id never goes on the wire (Security Rule 4). A
/// replayed proposal has to be published to THAT circle's relays, not to
/// whichever circle's resolution happened to surface it — otherwise those
/// relay operators learn the device participates in a second group, and the
/// event may never reach the members it was minted for.
///
/// Full JSON parse rather than the linear scans this file's neighbours use for
/// `id` / `created_at`: those run per event on the fetch hot path, this runs
/// once per replayed proposal (rare), and a tag array cannot be read correctly
/// with `indexOf`. Returns `null` on malformed input rather than throwing —
/// every caller's fail-closed branch is the same one it needs for an unknown
/// circle.
String? hTagOf(String eventJson) {
  try {
    final decoded = jsonDecode(eventJson);
    if (decoded is! Map<String, dynamic>) return null;
    final tags = decoded['tags'];
    if (tags is! List) return null;
    for (final tag in tags) {
      if (tag is List && tag.length >= 2 && tag[0] == 'h') {
        final value = tag[1];
        return value is String ? value : null;
      }
    }
  } on FormatException catch (e) {
    // The event is remote-authored, so neither it nor the parser's message
    // may reach a log line (Rules 8/15) — the type alone says what happened.
    debugPrint('[EventTags] unparseable event JSON: ${e.runtimeType}');
  }
  return null;
}
