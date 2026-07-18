/// Tests for the anonymous display-name generator and its curated word lists.
library;

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/utils/anonymous_name_generator.dart';
import 'package:haven/src/utils/anonymous_name_words.dart';

void main() {
  group('generateAnonymousName', () {
    test('matches the "Capitalized Capitalized" shape', () {
      final shape = RegExp(r'^[A-Z][a-z]+ [A-Z][a-z]+$');
      for (var seed = 0; seed < 300; seed++) {
        final name = generateAnonymousName(Random(seed));
        expect(shape.hasMatch(name), isTrue, reason: 'bad shape: "$name"');
      }
    });

    test('is deterministic for a given seed', () {
      expect(
        generateAnonymousName(Random(42)),
        generateAnonymousName(Random(42)),
      );
      expect(
        generateAnonymousName(Random(7)),
        generateAnonymousName(Random(7)),
      );
    });

    test('produces variety across calls (guards a broken index)', () {
      final names = <String>{};
      final rng = Random(1);
      for (var i = 0; i < 100; i++) {
        names.add(generateAnonymousName(rng));
      }
      // A broken modulo that always returned index 0 would yield one name.
      expect(names.length, greaterThan(50));
    });

    test('capitalizes the first letter of each word only', () {
      final name = generateAnonymousName(Random(3));
      final parts = name.split(' ');
      expect(parts, hasLength(2));
      for (final part in parts) {
        expect(part[0], part[0].toUpperCase());
        expect(part.substring(1), part.substring(1).toLowerCase());
      }
    });
  });

  group('word lists', () {
    final wordRe = RegExp(r'^[a-z]{2,12}$');

    test('adjectives are lowercase ASCII, 2-12 chars, and unique', () {
      for (final w in kAnonymousNameAdjectives) {
        expect(wordRe.hasMatch(w), isTrue, reason: 'bad adjective: "$w"');
      }
      expect(
        kAnonymousNameAdjectives.toSet().length,
        kAnonymousNameAdjectives.length,
        reason: 'duplicate adjective present',
      );
    });

    test('archetypes are lowercase ASCII, 2-12 chars, and unique', () {
      for (final w in kAnonymousNameArchetypes) {
        expect(wordRe.hasMatch(w), isTrue, reason: 'bad archetype: "$w"');
      }
      expect(
        kAnonymousNameArchetypes.toSet().length,
        kAnonymousNameArchetypes.length,
        reason: 'duplicate archetype present',
      );
    });

    test('the two lists are disjoint (no "Sage Sage" style collisions)', () {
      final overlap = kAnonymousNameAdjectives
          .toSet()
          .intersection(kAnonymousNameArchetypes.toSet());
      expect(overlap, isEmpty, reason: 'words in both lists: $overlap');
    });

    test('the cross product provides ample entropy (>= 150k)', () {
      expect(kAnonymousNameAdjectives.length, greaterThanOrEqualTo(400));
      expect(kAnonymousNameArchetypes.length, greaterThanOrEqualTo(300));
      expect(
        kAnonymousNameAdjectives.length * kAnonymousNameArchetypes.length,
        greaterThanOrEqualTo(150000),
      );
    });
  });
}
