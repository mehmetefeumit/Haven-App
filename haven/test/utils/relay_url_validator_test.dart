/// Unit tests for [validateRelayUrl].
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/utils/relay_url_validator.dart';

void main() {
  group('validateRelayUrl', () {
    test('rejects empty input as in-progress', () {
      final r = validateRelayUrl('');
      expect(r.isValid, isFalse);
      expect(r.error, contains('Enter a relay address'));
    });

    test('rejects whitespace-only input', () {
      final r = validateRelayUrl('   ');
      expect(r.isValid, isFalse);
    });

    test('rejects bare scheme prefix as in-progress', () {
      expect(validateRelayUrl('wss://').isValid, isFalse);
      expect(validateRelayUrl('ws://').isValid, isFalse);
    });

    test('auto-prefixes wss:// when scheme missing', () {
      final r = validateRelayUrl('relay.damus.io');
      expect(r.isValid, isTrue);
      expect(r.canonicalUrl, 'wss://relay.damus.io');
    });

    test('rejects ws:// (insecure) with specific message', () {
      final r = validateRelayUrl('ws://insecure.example.com');
      expect(r.isValid, isFalse);
      expect(r.error, contains('wss://'));
    });

    test('rejects ws:// (case insensitive) with specific message', () {
      final r = validateRelayUrl('WS://Insecure.Example.Com');
      expect(r.isValid, isFalse);
      expect(r.error, contains('wss://'));
    });

    test('rejects URLs with credentials', () {
      final r = validateRelayUrl('wss://user:pass@relay.example.com');
      expect(r.isValid, isFalse);
      expect(r.error?.toLowerCase(), contains('credential'));
    });

    test('rejects bare hostname with no dot (typo guard)', () {
      final r = validateRelayUrl('wss://relay');
      expect(r.isValid, isFalse);
    });

    test('lowercases scheme and host', () {
      final r = validateRelayUrl('WSS://Relay.Damus.IO');
      expect(r.isValid, isTrue);
      expect(r.canonicalUrl, 'wss://relay.damus.io');
    });

    test('strips trailing slash on root', () {
      final r = validateRelayUrl('wss://relay.damus.io/');
      expect(r.isValid, isTrue);
      expect(r.canonicalUrl, 'wss://relay.damus.io');
    });

    test('preserves explicit path', () {
      final r = validateRelayUrl('wss://relay.example.com/v1');
      expect(r.isValid, isTrue);
      expect(r.canonicalUrl, 'wss://relay.example.com/v1');
    });

    test('preserves explicit port', () {
      final r = validateRelayUrl('wss://relay.example.com:7777');
      expect(r.isValid, isTrue);
      expect(r.canonicalUrl, 'wss://relay.example.com:7777');
    });

    test('handles paste with leading whitespace', () {
      final r = validateRelayUrl('   wss://relay.example.com   ');
      expect(r.isValid, isTrue);
      expect(r.canonicalUrl, 'wss://relay.example.com');
    });
  });
}
