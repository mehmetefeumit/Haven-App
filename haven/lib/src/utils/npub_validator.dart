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
    final npub =
        trimmed.startsWith('nostr:') ? trimmed.substring(6) : trimmed;

    if (npub.isEmpty) {
      throw const NpubValidationException('Please enter an npub');
    }

    if (!npub.startsWith(npubPrefix)) {
      throw const NpubValidationException(
        'Invalid format. Npub should start with "npub1"',
      );
    }

    if (npub.length != npubLength) {
      throw NpubValidationException(
        'Invalid length. Expected $npubLength characters, got ${npub.length}',
      );
    }

    // Validate bech32 characters (after prefix)
    final data = npub.substring(npubPrefix.length);
    for (var i = 0; i < data.length; i++) {
      if (!_bech32Chars.contains(data[i])) {
        throw NpubValidationException(
          'Invalid character "${data[i]}" at position ${npubPrefix.length + i}',
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

  /// Truncates an npub for display.
  ///
  /// Returns a shortened version like "npub1abc...xyz".
  ///
  /// The [prefixLength] and [suffixLength] control how many characters
  /// to show at each end.
  static String truncate(
    String npub, {
    int prefixLength = 10,
    int suffixLength = 4,
  }) {
    if (npub.length <= prefixLength + suffixLength + 3) {
      return npub;
    }
    return '${npub.substring(0, prefixLength)}...${npub.substring(npub.length - suffixLength)}';
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
