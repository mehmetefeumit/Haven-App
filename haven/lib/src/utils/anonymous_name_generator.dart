/// Generates a random anonymous "Adjective Archetype" display name.
library;

import 'dart:math';

import 'package:haven/src/utils/anonymous_name_words.dart';

/// Returns a random anonymous display name of the form "Adjective Archetype"
/// (e.g. "Quiet Wanderer").
///
/// Picks one word uniformly at random from [kAnonymousNameAdjectives] and one
/// from [kAnonymousNameArchetypes], capitalizes the first letter of each, and
/// joins them with a single space. There are
/// `kAnonymousNameAdjectives.length * kAnonymousNameArchetypes.length` possible
/// names (~181K); uniqueness is not guaranteed and no numeric suffix is
/// appended — this is a pre-filled, user-editable default, not an identifier.
///
/// Pass a seeded [random] for deterministic output in tests; production callers
/// omit it and get a platform-seeded [Random]. The randomness is cosmetic (a
/// default display name), never used for keys, nonces, or any entropy purpose,
/// so a non-cryptographic [Random] is appropriate.
String generateAnonymousName([Random? random]) {
  final rng = random ?? Random();
  final adjective =
      kAnonymousNameAdjectives[rng.nextInt(kAnonymousNameAdjectives.length)];
  final archetype =
      kAnonymousNameArchetypes[rng.nextInt(kAnonymousNameArchetypes.length)];
  return '${_capitalize(adjective)} ${_capitalize(archetype)}';
}

/// Returns [word] with its first character upper-cased.
///
/// The word lists store lowercase ASCII, so this is a plain first-letter
/// capitalization (no locale or grapheme-cluster handling required).
String _capitalize(String word) {
  if (word.isEmpty) return word;
  return word[0].toUpperCase() + word.substring(1);
}
