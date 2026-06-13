/// Provider-level regression test for the relay-customization publish trigger.
///
/// This test exercises the production trigger: adding a KeyPackage relay must
/// cause the app to republish the KeyPackage to the new relay.  It is
/// EXPECTED TO FAIL until the add path drives [keyPackagePublisherProvider]
/// (see `relay_preferences_provider.dart` `_invalidateDownstream`, which
/// currently only invalidates a marker with no live listener in this
/// `ProviderContainer` -- no side-effecting re-evaluation is scheduled).
///
/// Do NOT force-read the publisher here -- that would mask the gap.
///
/// ## What the test proves
///
/// The `addRelay` production path in [KeyPackageRelaysNotifier]:
///
/// ```dart
/// await service.addRelay(RelayCategory.keyPackage, url);
/// state = AsyncValue.data(...);
/// _invalidateDownstream();
/// ```
///
/// The `_invalidateDownstream` marker exists so [keyPackagePublisherProvider]
/// -- which `ref.watch(keyPackagePublisherInvalidatorProvider)` -- re-runs
/// whenever a KP relay is added or removed.  But a non-autoDispose
/// `FutureProvider` that is merely marked dirty does NOT re-execute unless
/// something `read`s or `watch`es it.  Every OTHER republish call site pairs
/// `invalidate(keyPackagePublisherProvider)` with a follow-up
/// `read(keyPackagePublisherProvider)` -- the `read` is what forces the
/// rebuild.  The relay-settings add/remove
/// path invalidates only the MARKER and never reads the publisher, so on the
/// settings route (where nothing listens to the publisher) the republish
/// never fires.
///
/// This test replicates that production state FAITHFULLY: it establishes NO
/// listener and NO read on [keyPackagePublisherProvider].  It drives the real
/// `addRelay` path and asserts ONLY that R2 receives the republished kind
/// 30443.
///
///   * Against the BUG: `addRelay` invalidates the marker, nothing drives the
///     publisher, R2 receives nothing -> the firstWhere times out -> RED.
///   * Against the FIX (the add path also `read`s keyPackagePublisherProvider,
///     matching every other call site): the publisher rebuilds, signs a new
///     30443 over the updated KP relay list [R1, R2], and publishes it to R2
///     -> GREEN.
///
/// ## CRITICAL: do NOT `read`, `watch`, or `listen` keyPackagePublisherProvider
/// anywhere in this test.  ANY of those would supply the very subscription
/// whose absence is the bug, masking the gap.  The ONLY thing allowed to
/// trigger the republish is the production `addRelay` path.
library;

import 'dart:io';

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
import 'package:integration_test/integration_test.dart';

import 'e2e/_lib/test_relay.dart';
import 'e2e/_lib/test_user.dart';

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
  Future<List<int>> getSecretBytes() async =>
      List<int>.unmodifiable(_secretBytes);

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
        final r2 = await TestRelay.connect(url: secondStrfryUrl);
        try {
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
          );
          await circleManager.seedRelayDefaultsIfUnseeded();
          await circleManager.setPublishRelayList(
            relayType: RelayTypeFfi.keyPackage,
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
              'id=${ev.id.substring(0, 8)}',
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
