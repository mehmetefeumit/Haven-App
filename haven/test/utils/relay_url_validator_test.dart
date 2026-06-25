/// Unit tests for [validateRelayUrl].
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/utils/relay_url_validator.dart';

void main() {
  group('validateRelayUrl', () {
    test('rejects empty input as in-progress', () {
      final r = validateRelayUrl('');
      expect(r.isValid, isFalse);
      expect(r.errorCode, RelayUrlError.empty);
    });

    test('rejects whitespace-only input', () {
      final r = validateRelayUrl('   ');
      expect(r.isValid, isFalse);
      expect(r.errorCode, RelayUrlError.empty);
    });

    test('rejects bare scheme prefix as in-progress', () {
      expect(validateRelayUrl('wss://').isValid, isFalse);
      expect(validateRelayUrl('wss://').errorCode, RelayUrlError.empty);
      expect(validateRelayUrl('ws://').isValid, isFalse);
      expect(validateRelayUrl('ws://').errorCode, RelayUrlError.empty);
    });

    test('auto-prefixes wss:// when scheme missing', () {
      final r = validateRelayUrl('relay.damus.io');
      expect(r.isValid, isTrue);
      expect(r.canonicalUrl, 'wss://relay.damus.io');
    });

    test('rejects ws:// (insecure) with specific code', () {
      final r = validateRelayUrl('ws://insecure.example.com');
      expect(r.isValid, isFalse);
      expect(r.errorCode, RelayUrlError.insecureScheme);
    });

    test('rejects ws:// (case insensitive) with specific code', () {
      final r = validateRelayUrl('WS://Insecure.Example.Com');
      expect(r.isValid, isFalse);
      expect(r.errorCode, RelayUrlError.insecureScheme);
    });

    test('rejects URLs with credentials', () {
      final r = validateRelayUrl('wss://user:pass@relay.example.com');
      expect(r.isValid, isFalse);
      expect(r.errorCode, RelayUrlError.hasCredentials);
    });

    test('rejects bare hostname with no dot (typo guard)', () {
      final r = validateRelayUrl('wss://relay');
      expect(r.isValid, isFalse);
      expect(r.errorCode, RelayUrlError.invalidFormat);
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
