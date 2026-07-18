/// Nostr `kind` classification for MLS KeyPackage events.
///
/// Dark Matter migration (DM-4c): the current addressable KeyPackage is kind
/// `30443`; the deprecated pre-migration KeyPackage was kind `443`. A peer
/// whose only discoverable KeyPackage carries the legacy kind is still
/// running a pre-Dark-Matter Haven build — its wire format (exporter label,
/// leaf identity proof, group metadata encoding) is mutually unintelligible
/// with the new engine, so it cannot be invited into a circle created on the
/// new stack (see `docs/MDK_DARKMATTER_MIGRATION_PLAN.md` §6, F11).
library;

import 'dart:convert';

/// Deprecated pre-Dark-Matter KeyPackage kind (MIP era).
const int legacyKeyPackageKind = 443;

/// Current addressable KeyPackage kind (Dark Matter, MIP-04).
const int currentKeyPackageKind = 30443;

/// Extracts the Nostr `kind` field from a KeyPackage's raw event JSON.
///
/// Returns `null` if the JSON is malformed, is not an object, or the `kind`
/// field is missing/not an integer. Callers should treat `null` as "unknown"
/// rather than assuming either kind.
int? keyPackageEventKind(String eventJson) {
  try {
    final decoded = jsonDecode(eventJson);
    if (decoded is! Map<String, dynamic>) return null;
    final kind = decoded['kind'];
    return kind is int ? kind : null;
  } on Object catch (_) {
    return null;
  }
}

/// Whether [eventJson] is a legacy (pre-migration, kind 443) KeyPackage.
///
/// Fails open (`false`) on a malformed/unknown `kind` — a genuinely
/// malformed KeyPackage is already rejected elsewhere in validation; this
/// helper only classifies protocol generation.
bool isLegacyKeyPackageJson(String eventJson) =>
    keyPackageEventKind(eventJson) == legacyKeyPackageKind;
