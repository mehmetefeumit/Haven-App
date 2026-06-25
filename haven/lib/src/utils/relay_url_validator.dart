/// Pure-Dart pre-flight validator for user-supplied relay URLs.
///
/// Mirrors the security and normalization rules enforced by the Rust
/// storage layer (`haven-core/src/circle/storage_relay_prefs.rs`):
///
/// * Trims whitespace.
/// * Auto-prefixes `wss://` when no scheme is present (paste UX).
/// * Rejects `ws://` (insecure) with a specific error message.
/// * Rejects URLs with embedded credentials.
/// * Validates that the host is present and looks like a domain.
/// * Lowercases scheme + host.
/// * Strips a single trailing slash on the root path.
///
/// The Rust side re-validates on insert (defense in depth). The pure-Dart
/// validator exists so the UI can give immediate, debounced feedback as
/// the user types without crossing the FFI boundary.
library;

import 'package:flutter/foundation.dart';

/// Machine-readable reason a relay URL failed validation.
///
/// This util stays free of UI strings so it can be unit-tested and reused
/// without a localization context. The mapping from a code to a localized,
/// user-facing message lives in the UI layer (see `add_relay_sheet.dart`).
enum RelayUrlError {
  /// Input was empty, whitespace-only, or a bare scheme prefix
  /// (`wss://` / `ws://`) — treated as "in progress".
  empty,

  /// Input used the insecure `ws://` scheme instead of `wss://`.
  insecureScheme,

  /// Input embedded credentials (a `user:pass@host` form).
  hasCredentials,

  /// Input could not be parsed as, or did not look like, a relay address.
  invalidFormat,
}

/// Result of [`validateRelayUrl`].
@immutable
class RelayValidationResult {
  /// Creates a [RelayValidationResult].
  const RelayValidationResult({this.canonicalUrl, this.errorCode});

  /// Canonicalized URL when validation succeeded; `null` when [`errorCode`]
  /// is set.
  final String? canonicalUrl;

  /// Machine-readable failure reason when validation failed; `null` when
  /// [`canonicalUrl`] is set. The UI maps this code to a localized message.
  final RelayUrlError? errorCode;

  /// Whether validation succeeded.
  bool get isValid => canonicalUrl != null;
}

/// Validates and canonicalizes a user-supplied relay URL.
///
/// Empty / whitespace-only input is treated as "in progress" and reported
/// as an error so the UI can keep the Add button disabled without
/// flashing a misleading "invalid" message.
RelayValidationResult validateRelayUrl(String input) {
  final trimmed = input.trim();
  if (trimmed.isEmpty || trimmed == 'wss://' || trimmed == 'ws://') {
    return const RelayValidationResult(errorCode: RelayUrlError.empty);
  }

  // Auto-prefix wss:// for paste UX. We do this BEFORE the ws:// check
  // so a user typing "relay.example.com" goes the happy path.
  final withScheme = _hasWsScheme(trimmed) ? trimmed : 'wss://$trimmed';

  if (_isWsScheme(withScheme)) {
    return const RelayValidationResult(
      errorCode: RelayUrlError.insecureScheme,
    );
  }

  if (withScheme.contains('@')) {
    return const RelayValidationResult(
      errorCode: RelayUrlError.hasCredentials,
    );
  }

  // Parse and inspect host; tolerate trailing slash on root.
  final Uri parsed;
  try {
    parsed = Uri.parse(withScheme);
  } on FormatException {
    return const RelayValidationResult(
      errorCode: RelayUrlError.invalidFormat,
    );
  }
  if (parsed.host.isEmpty) {
    return const RelayValidationResult(
      errorCode: RelayUrlError.invalidFormat,
    );
  }
  // A bare hostname with no dot ("relay") is almost certainly user
  // typo. Require at least one dot in the host.
  if (!parsed.host.contains('.')) {
    return const RelayValidationResult(
      errorCode: RelayUrlError.invalidFormat,
    );
  }

  // Canonicalize: lowercase scheme + host; strip trailing slash on root.
  final scheme = parsed.scheme.toLowerCase();
  final host = parsed.host.toLowerCase();
  final port = parsed.hasPort ? ':${parsed.port}' : '';
  final path = parsed.path == '/' ? '' : parsed.path;
  final query = parsed.hasQuery ? '?${parsed.query}' : '';
  final fragment = parsed.hasFragment ? '#${parsed.fragment}' : '';
  final canonical = '$scheme://$host$port$path$query$fragment';

  return RelayValidationResult(canonicalUrl: canonical);
}

bool _hasWsScheme(String s) {
  final lower = s.toLowerCase();
  return lower.startsWith('wss://') || lower.startsWith('ws://');
}

bool _isWsScheme(String s) => s.toLowerCase().startsWith('ws://');
