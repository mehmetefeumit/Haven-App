/// Phase 0 smoke test for the Haven E2E infrastructure.
///
/// This test does *not* drive the Haven UI — that lands in Phase 1 with
/// the first scenario file. Instead, it proves that the infrastructure
/// added in Phase 0 actually works end-to-end:
///
/// 1. The Rust bridge initialises on the target platform.
/// 2. The in-memory keyring backend installs cleanly, so the keyring-
///    dependent FFI paths (`CircleManagerFfi.newInstance`) do not require
///    a platform Secret Service / Keychain / Keystore.
/// 3. The relay override propagates through to every call site (we read
///    `defaultRelays()` after installing the override and assert it
///    matches).
/// 4. Two distinct `TestUser` instances (Alice + Bob) can be constructed
///    from deterministic ephemeral seeds and produce stable pubkey hex.
/// 5. The strfry probe (if a relay is reachable on the configured URL)
///    can open a WebSocket and stay connected.
///
/// Run with:
///
/// ```sh
/// scripts/run_e2e_local.sh smoke
/// ```
///
/// which boots a local strfry container and a device/emulator, then
/// invokes:
///
/// ```sh
/// flutter test integration_test/e2e/smoke_test.dart \
///   --dart-define=HAVEN_E2E_RELAY=ws://10.0.2.2:7777
/// ```
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/rust/api.dart';
import 'package:integration_test/integration_test.dart';

import '_lib/scenario_harness.dart';
import '_lib/test_user.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late ScenarioContext context;

  setUpAll(() async {
    context = await ScenarioHarness.bootstrap();
  });

  tearDownAll(() async {
    await context.relay.dispose();
  });

  group('Phase 0 E2E infrastructure', () {
    testWidgets(
      'in-memory keyring + relay override + deterministic identities work',
      (tester) async {
        // ---- Assertion 1: relay override propagates through to Rust ----
        // `setDefaultRelaysForTest` was called by ScenarioHarness.bootstrap;
        // reading `defaultRelays()` now must return the override list, not
        // the production fallback.
        final relays = defaultRelays();
        expect(
          relays,
          isNotEmpty,
          reason: 'relay override must produce a non-empty list',
        );
        expect(
          relays.first,
          startsWith('ws://'),
          reason:
              'Phase 0 relay override should point at the hermetic strfry; '
              'production relays use wss://, so a ws:// scheme is a strong '
              'signal that the override is active',
        );
        expect(
          relays.any((r) => r.contains('damus.io')),
          isFalse,
          reason: 'production relay damus.io must not leak through the '
              'override',
        );

        // ---- Assertion 2: deterministic identities ----
        // Alice's seed is 32 bytes of 0x01 — pubkey is therefore fixed.
        // We don't hard-code the expected pubkey here because it depends on
        // the secp256k1 derivation; we only assert *stability* across calls.
        final aliceA = await TestUser.alice();
        addTearDown(aliceA.dispose);
        final aliceB = await TestUser.alice();
        addTearDown(aliceB.dispose);
        expect(
          aliceA.pubkeyHex,
          equals(aliceB.pubkeyHex),
          reason: 'two TestUser.alice() calls with the same seed must yield '
              'the same pubkey',
        );
        expect(
          aliceA.pubkeyHex.length,
          equals(64),
          reason: 'pubkey hex must be exactly 64 lowercase hex chars',
        );
        expect(
          aliceA.pubkeyHex,
          matches(RegExp(r'^[0-9a-f]{64}$')),
          reason: 'pubkey hex must be lowercase 0-9a-f only',
        );

        // ---- Assertion 3: Alice and Bob have distinct identities ----
        final bob = await TestUser.bob();
        addTearDown(bob.dispose);
        expect(
          bob.pubkeyHex,
          isNot(equals(aliceA.pubkeyHex)),
          reason: 'Alice and Bob seeds must produce different pubkeys',
        );

        // ---- Assertion 4: keyring backend works ----
        // `CircleManagerFfi.newInstance` (inside TestUser.bootstrap) calls
        // `init_keyring_store` internally. If we reached this point without
        // an exception, the in-memory backend is installed correctly.
        expect(
          aliceA.circleManager,
          isNotNull,
          reason:
              'CircleManagerFfi must construct successfully under the '
              'in-memory keyring',
        );

        // ---- Assertion 5: strfry probe survives the smoke ----
        // If the relay URL is unreachable we expect the WebSocket to have
        // raised already during ScenarioHarness.bootstrap. Send a probe REQ
        // with a wide filter and a short timeout; we don't care about
        // results, only that the connection accepts traffic.
        try {
          await context.relay.firstWhere(
            filter: const <String, dynamic>{
              'kinds': <int>[1],
              'limit': 1,
            },
            timeout: const Duration(seconds: 2),
          );
          // We don't actually expect events here; reaching the success branch
          // means an event matched, which is fine (older test data perhaps).
        } on TimeoutException {
          // Expected on a fresh hermetic relay — no events to match.
        }

        debugPrint(
          '[smoke_test] OK: relays=$relays alice=${aliceA.pubkeyHex} '
          'bob=${bob.pubkeyHex}',
        );
      },
      timeout: ScenarioHarness.defaultTimeout,
    );
  });
}
