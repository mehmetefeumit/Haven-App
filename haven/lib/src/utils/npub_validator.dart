/// Utilities for validating Nostr public keys (npub).
///
/// Provides validation for bech32-encoded Nostr public keys.
library;

/// Exception thrown when npub validation fails.
class NpubValidationException implements Exception {
  /// Creates a [NpubValidationException] with the given message.
  const NpubValidationException(this.message);

  /// The error message.
  final String message;

  @override
  String toString() => message;
}

/// Validates and converts Nostr public keys.
///
/// Supports npub (bech32) format validation and basic format checks.
abstract final class NpubValidator {
  /// The required prefix for npub strings.
  static const String npubPrefix = 'npub1';

  /// The expected length of a valid npub string.
  static const int npubLength = 63;

  /// Valid bech32 characters (lowercase only for npub).
  static const String _bech32Chars = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';

  /// Validates an npub string.
  ///
  /// Returns the validated npub (trimmed and normalized).
  ///
  /// Throws [NpubValidationException] if validation fails.
  static String validate(String input) {
    final trimmed = input.trim();

    // Handle nostr: URI prefix
    final npub = trimmed.startsWith('nostr:') ? trimmed.substring(6) : trimmed;

    if (npub.isEmpty) {
      throw const NpubValidationException('Please enter an npub');
    }

    if (!npub.startsWith(npubPrefix)) {
      throw const NpubValidationException(
        'Invalid format. Npub should start with "npub1"',
      );
    }

    if (npub.length != npubLength) {
      throw const NpubValidationException('Invalid length');
    }

    // Validate bech32 characters (after prefix)
    final data = npub.substring(npubPrefix.length);
    for (var i = 0; i < data.length; i++) {
      if (!_bech32Chars.contains(data[i])) {
        // log-scan-ok: npubPrefix.length is the fixed constant 5; loop counter.
        throw NpubValidationException(
          'Invalid character at position ${npubPrefix.length + i}',
        );
      }
    }

    return npub;
  }

  /// Checks if a string is a valid npub without throwing.
  ///
  /// Returns true if the string is a valid npub format.
  static bool isValid(String input) {
    try {
      validate(input);
      return true;
    } on NpubValidationException {
      return false;
    }
  }

  /// Leading characters kept by [shortenForDisplay], counted from the very
  /// start — so 12 spends 5 on the constant `npub1` HRP and exposes 7 bech32
  /// data characters.
  static const int _displayPrefixLength = 12;

  /// Trailing characters kept by [shortenForDisplay], taken from the END of
  /// the string, where the 6-character bech32 checksum lives.
  static const int _displaySuffixLength = 6;

  /// Shortens an npub to the one format Haven displays it in:
  /// `npub1abcdefg...uvwxyz`.
  ///
  /// Deliberately takes no lengths. The format is an anti-impersonation
  /// control, and every weaker variant this replaced (10/4, 8/4, 6/3) was
  /// reached by passing a smaller literal at one call site.
  ///
  /// An npub is `npub1` + 52 data characters + a 6-character bech32 checksum
  /// over the whole payload. A 12-character prefix therefore pins only 7 data
  /// characters — about 2^35, ~34 seconds of grinding at 10^9 keys/s to mint
  /// a key a user reads as identical to someone else's. Pinning the trailing
  /// checksum as well raises that to about 2^65 (~1200 years), because an
  /// attacker can only SAMPLE keys, never solve for a target checksum.
  ///
  /// So the suffix must come from the end, and a "cleaner" prefix-only or
  /// shorter form is a real regression — on the very screens where a user
  /// confirms who they are about to share live location with.
  static String shortenForDisplay(String npub) {
    if (npub.length <= _displayPrefixLength + _displaySuffixLength + 3) {
      return npub;
    }
    return '${npub.substring(0, _displayPrefixLength)}...${npub.substring(npub.length - _displaySuffixLength)}';
  }

  /// Extracts an npub from various input formats.
  ///
  /// Handles:
  /// - Plain npub (npub1...)
  /// - Nostr URI (nostr:npub1...)
  /// - QR code content with npub
  ///
  /// Returns the extracted npub or null if not found.
  static String? extract(String input) {
    final trimmed = input.trim();

    // Handle nostr: URI
    if (trimmed.startsWith('nostr:npub1')) {
      final npub = trimmed.substring(6);
      return isValid(npub) ? npub : null;
    }

    // Handle plain npub
    if (trimmed.startsWith('npub1')) {
      return isValid(trimmed) ? trimmed : null;
    }

    // Try to find npub in the string
    final regex = RegExp(r'npub1[' + _bech32Chars + r']{58}');
    final match = regex.firstMatch(trimmed);
    if (match != null) {
      return match.group(0);
    }

    return null;
  }
}
