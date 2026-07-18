/// Tests for the DM-4c KeyPackage kind classification helper.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/utils/key_package_kind.dart';

void main() {
  group('keyPackageEventKind', () {
    test('extracts an integer kind field', () {
      expect(keyPackageEventKind('{"kind":30443}'), 30443);
      expect(keyPackageEventKind('{"kind":443}'), 443);
    });

    test('extracts kind alongside other fields', () {
      final json = jsonEncode({
        'kind': 30443,
        'pubkey': 'abc123',
        'content': 'base64...',
      });
      expect(keyPackageEventKind(json), 30443);
    });

    test('returns null for malformed JSON', () {
      expect(keyPackageEventKind('not json'), isNull);
      expect(keyPackageEventKind(''), isNull);
    });

    test('returns null when kind is missing', () {
      expect(keyPackageEventKind('{"pubkey":"abc"}'), isNull);
    });

    test('returns null when kind is not an integer', () {
      expect(keyPackageEventKind('{"kind":"30443"}'), isNull);
      expect(keyPackageEventKind('{"kind":null}'), isNull);
    });

    test('returns null when the JSON is not an object', () {
      expect(keyPackageEventKind('[1,2,3]'), isNull);
      expect(keyPackageEventKind('"a string"'), isNull);
      expect(keyPackageEventKind('42'), isNull);
    });
  });

  group('isLegacyKeyPackageJson', () {
    test('true for kind 443', () {
      expect(isLegacyKeyPackageJson('{"kind":443}'), isTrue);
    });

    test('false for kind 30443 (current)', () {
      expect(isLegacyKeyPackageJson('{"kind":30443}'), isFalse);
    });

    test('fails open (false) for malformed or unknown JSON', () {
      expect(isLegacyKeyPackageJson('not json'), isFalse);
      expect(isLegacyKeyPackageJson('{"pubkey":"abc"}'), isFalse);
    });
  });

  test('legacyKeyPackageKind and currentKeyPackageKind are the documented '
      'protocol values', () {
    expect(legacyKeyPackageKind, 443);
    expect(currentKeyPackageKind, 30443);
  });
}
