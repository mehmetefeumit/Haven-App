/// Unit tests for [NpubValidator.shortenForDisplay] — the ONE npub display
/// format (plan §7.1).
///
/// The format is an anti-impersonation control, not styling: a 12-character
/// prefix exposes only 7 bech32 data characters (~2^35, seconds of grinding),
/// while pinning the trailing 6 checksum characters as well reaches ~2^65.
/// These tests fail if the suffix is dropped or either end is shortened.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/utils/npub_validator.dart';

/// Real bech32 encodings of `bb * 32` and of `bb bb bb bb bb cc * 27`
/// (computed offline), so the trailing characters under test are authentic
/// checksums rather than filler.
///
/// The two keys are DIFFERENT and their npubs agree on the first 13
/// characters — the collision an attacker grinds for. Only the checksum
/// tells them apart.
const _npub = 'npub1hwamhwamhwamhwamhwamhwamhwamhwamhwamhwamhwamhwamhwasxw04hu';
const _prefixTwin =
    'npub1hwamhwamenxvenxvenxvenxvenxvenxvenxvenxvenxvenxvenxquwpfwt';

void main() {
  group('NpubValidator.shortenForDisplay', () {
    test('renders exactly the 12/6 form for a known npub', () {
      expect(NpubValidator.shortenForDisplay(_npub), 'npub1hwamhwa...xw04hu');
    });

    test('is 21 characters: 12 + the 3-character ellipsis + 6', () {
      expect(NpubValidator.shortenForDisplay(_npub).length, 21);
    });

    test('keeps the last 6 characters of the source npub', () {
      expect(
        NpubValidator.shortenForDisplay(_npub),
        endsWith(_npub.substring(_npub.length - 6)),
      );
    });

    test('keeps the first 12 characters of the source npub', () {
      expect(
        NpubValidator.shortenForDisplay(_npub),
        startsWith(_npub.substring(0, 12)),
      );
    });

    test('separates two npubs that share the whole displayed prefix', () {
      // The premise of the format: the prefix is grindable, the checksum is
      // not. A prefix-only "cleanup" would render these two distinct keys
      // identically — asserted here so the regression is visible.
      expect(_prefixTwin.substring(0, 12), _npub.substring(0, 12));
      expect(
        NpubValidator.shortenForDisplay(_npub),
        isNot(NpubValidator.shortenForDisplay(_prefixTwin)),
      );
    });

    test('returns input untouched when it is too short to shorten', () {
      expect(NpubValidator.shortenForDisplay('npub1abc'), 'npub1abc');
    });
  });
}
