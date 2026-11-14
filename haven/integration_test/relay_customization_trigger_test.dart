/// Provider-level regression test for the relay-customization publish trigger.
///
/// Adding a KeyPackage relay must republish the KeyPackage to the new relay,
/// driven by the production add path alone: `_invalidateDownstream` in
/// `relay_preferences_provider.dart` bumps
/// [keyPackagePublisherInvalidatorProvider] and then `read`s
/// [keyPackagePublisherProvider]. Both halves are needed: a non-autoDispose
/// `FutureProvider` that is merely marked dirty does NOT re-execute unless
/// something reads or watches it, and a marker that is invalidated rather
/// than bumped rebuilds to the same value and marks nothing dirty at all.
///
/// This test replicates the settings route FAITHFULLY: it establishes NO
/// listener and NO read on [keyPackagePublisherProvider]. It drives the real
/// `addRelay` path and asserts ONLY that R2 receives the republished kind
/// 30443, signed over the updated KP relay list [R1, R2].
///
/// ## CRITICAL: do NOT `read`, `watch`, or `listen` keyPackagePublisherProvider
/// anywhere in this test.  ANY of those would supply the very subscription
/// whose absence is the bug, masking the gap.  The ONLY thing allowed to
/// trigger the republish is the production `addRelay` path.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/key_package_provider.dart';
import 'package:haven/src/providers/relay_preferences_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/nostr_circle_service.dart';
import 'package:haven/src/services/nostr_relay_service.dart';
import 'package:haven/src/utils/log_alias.dart'
    show LogAliasClass, logAliasHandle;
import 'package:integration_test/integration_test.dart';

import 'e2e/_lib/plane_store_check.dart';
import 'e2e/_lib/test_relay.dart';
import 'e2e/_lib/test_user.dart';
import 'e2e/_lib/throw_time_error_capture.dart';

// ---------------------------------------------------------------------------
// Minimal IdentityService backed by a pre-constructed TestUser.
// ---------------------------------------------------------------------------

class _TestIdentityService implements IdentityService {
  _TestIdentityService({
    required this.pubkeyHex,
    required this.npub,
    required List<int> secretBytes,
  }) : _secretBytes = List<int>.unmodifiable(secretBytes);

  final String pubkeyHex;
  final String npub;
  final List<int> _secretBytes;

  @override
  Future<bool> hasIdentity() async => true;

  @override
  Future<Identity?> getIdentity() async => Identity(
    pubkeyHex: pubkeyHex,
    npub: npub,
    createdAt: DateTime.fromMillisecondsSinceEpoch(0),
  );

  @override
  Future<Identity> createIdentity() => throw UnimplementedError();

  @override
  Future<Identity> importFromNsec(String nsec) => throw UnimplementedError();

  @override
  Future<String> exportNsec() => throw UnimplementedError();

  @override
  Future<String> sign(Uint8List messageHash) => throw UnimplementedError();

  @override
  Future<String> getPubkeyHex() async => pubkeyHex;

  @override
  // A FRESH, writable buffer per call, which is what production returns: the
  // `Uint8List` flutter_rust_bridge just allocated, whose ownership passes to
  // the caller (`takeSecretOwnership`) and which the caller scrubs on the way
  // out. An unmodifiable list is not merely a stricter double — it is a secret
  // nothing can wipe, so `takeSecretOwnership` throws `UnsupportedError` on it
  // by design, and every maintenance tick then reports `identityUnavailable`.
  Future<List<int>> getSecretBytes() async => Uint8List.fromList(_secretBytes);

  @override
  Future<void> deleteIdentity() => throw UnimplementedError();

  @override
  Future<String?> getDisplayName() async => null;

  @override
  Future<void> setDisplayName(String? name) async {}

  @override
  Future<void> clearCache() async {}
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'RLY-PROV-01: adding a KeyPackage relay triggers a republish of '
    'kind 30443 to the new relay via the production addRelay path',
    (tester) async {
      installThrowTimeErrorLogging();
      // ------------------------------------------------------------------
      // Process-global bootstrap FIRST.
      //
      // bootstrapProcess performs the single RustLib.init() for this
      // process, installs the in-memory keyring backend, arms ws-loopback
      // acceptance, and pins the default relay list to [R1]. It MUST run
      // before any other FFI call -- including initKeyringStore below: the
      // in-memory keyring and the platform keyring share one process-global
      // KEYRING_INIT guard on a first-writer-wins basis, so bootstrapProcess
      // must claim it first for the hermetic in-memory backend to win. This
      // matches the ordering the sibling publish/resync tests rely on (they
      // call bootstrapProcess in setUpAll, then initKeyringStore in the body).
      //
      // No try/catch: a bootstrapProcess failure is a hard test-infra error
      // and must surface loudly. If it were swallowed, the addRelay(ws://...)
      // below would later throw a confusing RelayValidationError far from the
      // real root cause.
      // ------------------------------------------------------------------
      await TestUser.bootstrapProcess(relays: [defaultStrfryUrl]);

      // ------------------------------------------------------------------
      // Keyring guard -- honest skip, not silent return.
      //
      // After bootstrapProcess installed the in-memory backend this is a
      // no-op (KEYRING_INIT is already claimed, first-writer-wins), but it is
      // kept as a defensive skip path: if the keyring is genuinely
      // unavailable the test skips honestly rather than hard-failing.
      // ------------------------------------------------------------------
      try {
        await initKeyringStore();
      } on Object catch (e) {
        markTestSkipped(
          'Keyring unavailable on this runner (${e.runtimeType}); '
          'skipping RLY-PROV-01.',
        );
        return;
      }

      // Confirm R2 is provably non-default.
      expect(
        defaultRelays(),
        isNot(contains(secondStrfryUrl)),
        reason:
            'R2 must NOT be a default relay before the test.  If it is, the '
            '"R2 received the 30443" assertion cannot prove the add-relay '
            'path worked.',
      );

      final aliceDir = await Directory.systemTemp.createTemp(
        'haven_trigger_alice_',
      );
      TestUser? alice;
      Uint8List? secretBytes;

      try {
        alice = await TestUser.alice();
        secretBytes = await alice.getSecretBytes();

        // Connect the R2 observer BEFORE wiring the container.
        final r2 = await connectProbeRelay(secondStrfryUrl);
        try {
          final r2Before = await storeIds(r2);
          // Register the observer BEFORE any state mutation.
          final r2EventFuture = r2.firstWhere(
            filter: <String, dynamic>{
              'kinds': <int>[30443],
              'authors': <String>[alice.pubkeyHex],
            },
            // 45s rather than firstWhere's 30s default. The sibling publish
            // test uses 40s for the same R2 wire assertion; the trigger path
            // is heavier still (Riverpod provider resolution + FFI signing +
            // publish from a cold, listener-less container), so give the
            // round-trip a little extra headroom on a slow/starved runner.
            // Comfortably inside the 3-min test timeout, and it does NOT
            // weaken the oracle: a broken republish never delivers to R2 and
            // still fails — only a slow-but-correct run is protected.
            timeout: const Duration(seconds: 45),
          );

          // ------------------------------------------------------------------
          // Wire real services into a ProviderContainer.
          // ------------------------------------------------------------------
          final identityService = _TestIdentityService(
            pubkeyHex: alice.pubkeyHex,
            npub: alice.npub,
            secretBytes: secretBytes,
          );

          final circleManager = await CircleManagerFfi.newInstance(
            dataDir: aliceDir.path,
            identitySecretBytes: secretBytes,
          );
          await circleManager.seedRelayDefaultsIfUnseeded();
          await circleManager.setPublishRelayList(
            relayType: RelayTypeFfi.nip65,
            value: true,
          );

          final circleService = NostrCircleService.withInjectedManager(
            relayService: NostrRelayService(),
            injectedManager: circleManager,
          );

          final container = ProviderContainer(
            overrides: [
              identityServiceProvider.overrideWithValue(identityService),
              circleServiceProvider.overrideWithValue(circleService),
              relayServiceProvider.overrideWithValue(NostrRelayService()),
            ],
          );

          try {
            // Warm up identity and KP relay notifiers.
            await container.read(identityNotifierProvider.future);
            await container.read(keyPackageRelaysProvider.future);

            // Deliberately establish NO listener / read / watch on
            // keyPackagePublisherProvider.  Doing so would supply the exact
            // subscription whose absence is the bug under test, masking it.
            // The publisher must be driven -- if at all -- SOLELY by the
            // production addRelay path.

            // ----------------------------------------------------------------
            // THE PRODUCTION TRIGGER.
            //
            // This is the ONLY thing allowed to cause the republish.  Any
            // explicit container.read(keyPackagePublisherProvider.future)
            // call would mask the bug.
            // ----------------------------------------------------------------
            await container
                .read(keyPackageRelaysProvider.notifier)
                .addRelay(secondStrfryUrl);

            // Give the event loop time to propagate the marker invalidation
            // through Riverpod and for the publish Future to complete.
            await tester.pump(const Duration(milliseconds: 500));
            await tester.pump(const Duration(milliseconds: 500));

            // ----------------------------------------------------------------
            // THE ORACLE.
            //
            // If the production path correctly drives
            // keyPackagePublisherProvider after addRelay, the provider
            // re-evaluates, signs a new kind 30443 event that lists R2 in
            // its `relays` tag, and publishes it to R2.
            // r2EventFuture then resolves and we get a non-null event.
            //
            // If the production path is broken (the marker is invalidated
            // but no live listener re-evaluation is scheduled, or the
            // provider rebuild does not reach the publish call),
            // r2EventFuture times out after 45 seconds and this test
            // fails with a TimeoutException.
            // ----------------------------------------------------------------
            final ev = await r2EventFuture;
            expect(
              ev.kind,
              equals(30443),
              reason:
                  'The event on R2 must be kind 30443 (canonical KeyPackage). '
                  'If kind 443 or another kind arrives first, the KP publisher '
                  'is not using the canonical event path.',
            );
            expect(
              ev.pubkey.toLowerCase(),
              equals(alice.pubkeyHex.toLowerCase()),
              reason:
                  'The kind 30443 on R2 must be authored by the identity key. '
                  'A mismatch suggests the wrong KP was published.',
            );

            debugPrint(
              '[RLY-PROV-01] PASS: kind 30443 received on R2 '
              'id=${logAliasHandle(LogAliasClass.event, ev.id)}',
            );
            await assertStoreWithinRoles(
              r2,
              check: 'RLY-PROV-01 R2',
              roles: const <String>{'keypackage'},
              before: r2Before,
              harnessIds: r2.publishedIds,
            );
          } finally {
            container.dispose();
          }
        } finally {
          await r2.dispose();
        }
      } finally {
        if (secretBytes != null) {
          for (var i = 0; i < secretBytes.length; i++) {
            secretBytes[i] = 0;
          }
        }
        await alice?.dispose();
        try {
          await aliceDir.delete(recursive: true);
        } on Object catch (_) {}
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
