/// Tests for the relay constants — in particular the read-only discovery
/// relay set introduced by the two-plane relay model.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/relays.dart';

void main() {
  group('discovery relays', () {
    test('fallbackDiscoveryRelays includes the purpose-built indexers', () {
      expect(fallbackDiscoveryRelays, contains('wss://index.hzrd149.com'));
      expect(
        fallbackDiscoveryRelays,
        contains('wss://indexer.coracle.social'),
      );
    });

    test('account-seed defaults exclude the discovery-only indexers', () {
      // A user seeded with the account defaults is never exposed to the
      // indexer-only relays as a publish target.
      expect(
        fallbackDefaultRelays,
        isNot(contains('wss://index.hzrd149.com')),
      );
      expect(
        fallbackDefaultRelays,
        isNot(contains('wss://indexer.coracle.social')),
      );
    });

    test('discoveryRelays getter falls back without an initialized FFI', () {
      // No RustLib.init() in unit tests — the getter must not throw and must
      // return the compile-time fallback (mirrors the defaultRelays getter).
      expect(discoveryRelays, equals(fallbackDiscoveryRelays));
    });

    test('discovery set is a superset of the account-seed defaults', () {
      // Discoverability coupling (mirrors the Rust unit test
      // discovery_relays_is_superset_of_account_seed): every seeded public
      // default is also a discovery relay, so a user who keeps the seed
      // stays discoverable by bare pubkey.
      for (final seed in defaultRelays) {
        expect(discoveryRelays, contains(seed));
      }
    });
  });
}
