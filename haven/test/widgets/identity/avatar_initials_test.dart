/// Unit tests for [avatarInitials].
///
/// Ported from the former `ProfilePicturePage._initialsFor` tests. Covers
/// grapheme-safe handling of multi-byte Unicode, emoji, and the critical
/// regression where an npub must never be sliced for initials.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/widgets/identity/avatar_initials.dart';

void main() {
  group('avatarInitials', () {
    test('null display name returns "?"', () {
      expect(avatarInitials(null), equals('?'));
    });

    test('empty display name returns "?"', () {
      expect(avatarInitials(''), equals('?'));
    });

    test('whitespace-only display name returns "?"', () {
      expect(avatarInitials('   '), equals('?'));
    });

    test('single-word ASCII name returns first char uppercased', () {
      expect(avatarInitials('Alice'), equals('A'));
    });

    test('two-word name returns first chars uppercased', () {
      expect(avatarInitials('Alice B'), equals('AB'));
    });

    test('lowercase two-word name returns uppercased initials', () {
      expect(avatarInitials('alice b'), equals('AB'));
    });

    test('multi-word name uses first and last word', () {
      expect(avatarInitials('Alice Marie Bell'), equals('AB'));
    });

    test('non-Latin name returns grapheme-safe first char', () {
      // Arabic: first grapheme is the right character.
      expect(avatarInitials('علي'), equals('ع'));
    });

    test('emoji name returns first emoji grapheme cluster', () {
      // The first character of an emoji string is the first emoji.
      expect(avatarInitials('😀😁'), equals('😀'));
    });

    // The critical regression: npub slicing must NOT be used.
    test('never returns index-4 npub slice ("1") as initials', () {
      // npub starts with "npub1...", index 4 is '1' — a meaningless glyph.
      const npub = 'npub1alice0000000000000000000000000000000000000000000000000';
      final result = avatarInitials(npub);
      expect(result, isNot(equals('1')));
      expect(result, equals('N')); // 'N' from 'npub...'
    });
  });
}
