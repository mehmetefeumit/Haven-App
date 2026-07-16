/// Public-profile (kind-0 + Blossom) end-to-end scenario — Alice through the
/// real Flutter app + production profile providers, Bob as an in-process
/// synthetic peer.
///
/// This is the driver for the `e2e-profile.yml` lane
/// (docs/PUBLIC_PROFILE_MIGRATION_PLAN.md §7.3). It exercises Haven's
/// owner-directed public-profile feature end to end against BOTH a hermetic
/// Nostr relay (strfry) AND a hermetic Blossom media server:
///
///   * **Alice** is a real `HavenApp` instance with her identity pre-seeded
///     onto `MapShell`. Her profile actions are driven through the SAME
///     production surface the Identity-page UI drives — `ProfileService`
///     (display-name, photo — publishing is unconditional, no consent step,
///     owner-directed 2026-07-16) read out of her live `ProviderScope`, plus
///     the `CircleManagerFfi.deleteMyPublicProfile` FFI for the retract step
///     (which has no provider wrapper yet, plan D10).
///   * **Bob** is an in-process [SyntheticUser] — his own `CircleManagerFfi`,
///     driven directly. He is the "other circle member" whose app resolves
///     Alice's public profile by pubkey via `fetchMemberProfiles` +
///     `downloadMemberPicture`.
///
/// Both share the local strfry and the local Blossom. This mirrors the
/// single-process pattern the consolidated `e2e_combined.dart` scenario
/// established (one runner drives one UI role; other roles participate via
/// their FFI surfaces) — see that file's header for the full rationale.
///
/// ## How the hermetic hosts are reached (traced before writing)
///
///   * **Relay.** `ScenarioHarness.bootstrap` → `TestUser.bootstrapProcess`
///     installs the loopback-`ws://` opt-in (`allowWsLoopbackForTest`) and the
///     DEFAULT-relay override (`setDefaultRelaysForTest`) pointing at strfry.
///   * **Discovery plane.** Public-profile fetch/publish never rides a
///     circle's relays — reads use `profile_read_relays()` ==
///     `discovery_relays()` and writes fall back to the discovery plane when
///     the user has no NIP-65 write relays (which Alice does not). Both are the
///     SEPARATE discovery override, so this scenario additionally calls
///     `setDiscoveryRelaysForTest` to point the discovery plane at the same
///     strfry — that is what lets B fetch A's kind-0 and A publish it.
///   * **Blossom.** A's picture upload targets the server returned by
///     `blossom_server()`; `setBlossomServerForTest` redirects it from the
///     production default to the hermetic Blossom. B's DOWNLOAD path applies a
///     connect-time anti-SSRF IP filter that rejects loopback/private
///     addresses; `allowPrivateBlossomForTest` relaxes it for the
///     loopback/emulator allowlist only (debug builds only) so B can fetch the
///     blob whose URL points at `http://10.0.2.2:3000` / `http://localhost:3000`.
///
/// ## Scenario steps (plan §7.3)
///
/// 0. Alice + Bob become co-members of a "Family" circle (reuses the
///    `createCircle` → publish-Welcome → `acceptInvitationViaRelay` flow).
/// 1. **Fresh user has published nothing yet.** Before Alice sets a name or
///    photo, the relay has observed ZERO kind-0 for her (so ZERO blob could
///    exist on Blossom) — publishing is unconditional (public-by-default,
///    owner-directed 2026-07-16), so there is no consent step; simply never
///    having called `updateOwnProfile`/`setOwnAvatar` yet is what keeps the
///    relay clean.
/// 2. **Set name + photo + publish.** A kind-0 with the display name AND a
///    `picture` URL lands on strfry, and the blob is retrievable from
///    Blossom.
/// 3. **B resolves and displays.** Bob's `fetchMemberProfiles` sees Alice's
///    name; `downloadMemberPicture` + `getProfilePicture` return her photo
///    bytes.
/// 4. **A edits ONLY the display name.** B's forced re-fetch shows the NEW name
///    AND the SAME photo — the on-relay kind-0 still carries the original
///    `picture` URL, proving the fetch-merge-publish did not clobber it.
/// 5. **A deletes the public profile.** B's forced re-fetch falls back to a
///    blank profile (no stale name), i.e. the member tile would render the
///    npub prefix + initials. No crash, no stale data.
///
/// ## Acceptance hooks
///
/// Reverting any of the following to a no-op turns this scenario red:
/// - `upload_my_profile_picture` / `blossom_server()` — step 2's Blossom GET
///   404s / connection-refuses.
/// - `publish_my_profile` / `resolve_write_relays` — step 2/4's kind-0 relay
///   waits time out.
/// - `merge_edits` picture preservation — step 4's on-relay `picture`-field
///   assertion fails.
/// - `fetch_profiles` / `download_profile_picture` — step 3's B-side name /
///   photo assertions fail.
/// - `delete_public_profile` — step 5's blank-profile assertion fails.
library;

import 'dart:convert' show jsonDecode;
import 'dart:io' show HttpClient;
import 'dart:typed_data' show Uint8List;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/main.dart';
import 'package:haven/src/pages/map_shell.dart' show MapShell;
import 'package:haven/src/providers/maintenance_scheduler_provider.dart'
    show MaintenanceSchedulerNotifier, maintenanceSchedulerProvider;
import 'package:haven/src/providers/onboarding_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/rust/api.dart'
    show
        MemberKeyPackageFfi,
        RelayManagerFfi,
        allowPrivateBlossomForTest,
        setBlossomServerForTest,
        setDiscoveryRelaysForTest;
import 'package:haven/src/services/nostr_circle_service.dart'
    show NostrCircleService;
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '_lib/coordination.dart';
import '_lib/fake_location_service.dart';
import '_lib/pump_helpers.dart';
import '_lib/scenario_harness.dart';
import '_lib/synthetic_user.dart' show SyntheticUser;
import '_lib/test_relay.dart' show TestRelayEvent, defaultStrfryUrl;
import '_lib/test_user.dart';

// =============================================================================
// Constants
// =============================================================================

/// Blossom base URL the scenario points A's uploads at and reads the blob
/// back from. Baked into the APK / test binary via `--dart-define`; CI passes
/// `http://10.0.2.2:3000` (Android emulator host-loopback alias) or
/// `http://localhost:3000` (iOS simulator / host). The default keeps a local
/// `flutter test` run pointed at a host-native `local-blossom`.
const String _blossomUrl = String.fromEnvironment(
  'HAVEN_E2E_BLOSSOM_URL',
  defaultValue: 'http://localhost:3000',
);

/// Circle name Alice + Bob share (co-membership context; not load-bearing for
/// the profile assertions — profile resolution is by pubkey — but faithful to
/// the plan's "two members of a circle" framing).
const String _circleName = 'Family';

/// Alice's initial and edited public display names. Distinct so the step-4
/// edit is unambiguous on the wire and in B's re-fetch.
const String _aliceName = 'Alice Public';
const String _aliceEditedName = 'Alice Edited';

/// Overall test budget. The profile round-trips are lighter than
/// `e2e_combined`'s MLS choreography, but a cold AVD + two hermetic hosts want
/// headroom; 10 min still surfaces a real hang as a clean failure.
const Duration _outerTestTimeout = Duration(minutes: 10);

/// Deadline on relay-level waits for a kind-1059 gift-wrap / kind-0 to land.
const Duration _relayWaitDeadline = Duration(seconds: 90);

/// Deadline for a single Blossom HTTP round-trip.
const Duration _blossomHttpTimeout = Duration(seconds: 15);

/// Bound on every best-effort `tearDownAll` cleanup await.
const Duration _teardownTimeout = Duration(seconds: 15);

/// A genuine, decodable 16×16 RGB PNG (463 bytes) used as Alice's photo.
///
/// The avatar/profile pipeline DECODES the input with the `image` crate (magic
/// bytes → JPEG/PNG/WebP allowlist) before stripping metadata and re-encoding,
/// so the fake `[0xFF,0xD8,…]` JPEG headers the mocked widget tests use would
/// be rejected here — this is a real PNG. Generated deterministically (zlib +
/// correct CRCs), so no runtime rasterization (`dart:ui`) is needed on a
/// headless emulator.
final Uint8List _testPng = Uint8List.fromList(const <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x10,
  0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x91, 0x68, 0x36, 0x00, 0x00, 0x01,
  0x96, 0x49, 0x44, 0x41, 0x54, 0x78, 0xDA, 0x0D, 0xCB, 0x41, 0x01, 0x00,
  0x21, 0x08, 0x00, 0x41, 0x1B, 0xD0, 0xC0, 0x06, 0x34, 0xB0, 0x81, 0x0D,
  0x68, 0x40, 0x03, 0x9E, 0xFB, 0xB3, 0x01, 0x0D, 0x6C, 0x60, 0x03, 0x1B,
  0xD0, 0xC0, 0x26, 0x77, 0xF3, 0x9F, 0xD6, 0x1A, 0xD2, 0xE8, 0x0D, 0x6D,
  0x8C, 0xC6, 0x6C, 0x58, 0xC3, 0x1B, 0xD1, 0x58, 0x8D, 0x6C, 0xEC, 0xC6,
  0x69, 0xDC, 0x46, 0x35, 0x5E, 0xA3, 0x35, 0x41, 0x84, 0x2E, 0xA8, 0x30,
  0x84, 0x29, 0x98, 0xE0, 0x42, 0x08, 0x4B, 0x48, 0x61, 0x0B, 0x47, 0xB8,
  0x42, 0x09, 0x4F, 0xFE, 0xD0, 0x91, 0x4E, 0xEF, 0x68, 0x67, 0x74, 0x66,
  0xC7, 0x3A, 0xDE, 0x89, 0xCE, 0xEA, 0x64, 0x67, 0x77, 0x4E, 0xE7, 0x76,
  0xAA, 0xF3, 0xFA, 0x1F, 0x14, 0x51, 0xBA, 0xA2, 0xCA, 0x50, 0xA6, 0x62,
  0x8A, 0x2B, 0xA1, 0x2C, 0x25, 0x95, 0xAD, 0x1C, 0xE5, 0x2A, 0xA5, 0x3C,
  0xFD, 0xC3, 0x40, 0x06, 0x7D, 0xA0, 0x83, 0x31, 0x98, 0x03, 0x1B, 0xF8,
  0x20, 0x06, 0x6B, 0x90, 0x83, 0x3D, 0x38, 0x83, 0x3B, 0xA8, 0xC1, 0x1B,
  0x7F, 0x98, 0xC8, 0xA4, 0x4F, 0x74, 0x32, 0x26, 0x73, 0x62, 0x13, 0x9F,
  0xC4, 0x64, 0x4D, 0x72, 0xB2, 0x27, 0x67, 0x72, 0x27, 0x35, 0x79, 0xF3,
  0x0F, 0x86, 0x18, 0xDD, 0x50, 0x63, 0x18, 0xD3, 0x30, 0xC3, 0x8D, 0x30,
  0x96, 0x91, 0xC6, 0x36, 0x8E, 0x71, 0x8D, 0x32, 0x9E, 0xFD, 0xC1, 0x11,
  0xA7, 0x3B, 0xEA, 0x0C, 0x67, 0x3A, 0xE6, 0xB8, 0x13, 0xCE, 0x72, 0xD2,
  0xD9, 0xCE, 0x71, 0xAE, 0x53, 0xCE, 0xF3, 0x3F, 0x04, 0x12, 0xF4, 0x40,
  0x83, 0x11, 0xCC, 0xC0, 0x02, 0x0F, 0x22, 0x58, 0x41, 0x06, 0x3B, 0x38,
  0xC1, 0x0D, 0x2A, 0x78, 0xF1, 0x87, 0x85, 0x2C, 0xFA, 0x42, 0x17, 0x63,
  0x31, 0x17, 0xB6, 0xF0, 0x45, 0x2C, 0xD6, 0x22, 0x17, 0x7B, 0x71, 0x16,
  0x77, 0x51, 0x8B, 0xB7, 0xFE, 0x90, 0x48, 0xD2, 0x13, 0x4D, 0x46, 0x32,
  0x13, 0x4B, 0x3C, 0x89, 0x64, 0x25, 0x99, 0xEC, 0xE4, 0x24, 0x37, 0xA9,
  0xE4, 0xE5, 0x1F, 0x36, 0xB2, 0xE9, 0x1B, 0xDD, 0x8C, 0xCD, 0xDC, 0xD8,
  0xC6, 0x37, 0xB1, 0x59, 0x9B, 0xDC, 0xEC, 0xCD, 0xD9, 0xDC, 0x4D, 0x6D,
  0xDE, 0xFE, 0xC3, 0x41, 0x0E, 0xFD, 0xA0, 0x87, 0x71, 0x98, 0x07, 0x3B,
  0xF8, 0x21, 0x0E, 0xEB, 0x90, 0x87, 0x7D, 0x38, 0x87, 0x7B, 0xA8, 0xC3,
  0x3B, 0x7F, 0xB8, 0xC8, 0xA5, 0x5F, 0xF4, 0x32, 0x2E, 0xF3, 0x62, 0x17,
  0xBF, 0xC4, 0x65, 0x5D, 0xF2, 0xB2, 0x2F, 0xE7, 0x72, 0x2F, 0x75, 0x79,
  0xF7, 0x0F, 0x85, 0x14, 0xBD, 0xD0, 0x62, 0x14, 0xB3, 0xB0, 0xC2, 0x8B,
  0x28, 0x56, 0x91, 0xC5, 0x2E, 0x4E, 0x71, 0x8B, 0x2A, 0x5E, 0xFD, 0xE1,
  0x21, 0x8F, 0xFE, 0xD0, 0xC7, 0x78, 0xCC, 0x87, 0x3D, 0xFC, 0x11, 0x8F,
  0xF5, 0xC8, 0xC7, 0x7E, 0x9C, 0xC7, 0x7D, 0xD4, 0xE3, 0x3D, 0x3E, 0xD8,
  0x65, 0x61, 0x10, 0xB7, 0x98, 0x5E, 0x07, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

// =============================================================================
// Shared ProviderScope overrides
// =============================================================================

/// Inert stand-in for [MaintenanceSchedulerNotifier] that arms no timers.
///
/// `MapShell.initState` reads `maintenanceSchedulerProvider.notifier`, which in
/// production arms three self-rescheduling KeyPackage / relay-list /
/// subscription-health timers doing real FFI + relay round-trips. Nothing in
/// this scenario reads the scheduler's output, so disabling it removes a source
/// of unattributed relay/FFI contention and a timer that would otherwise leak
/// into `tearDownAll` (identical rationale to `e2e_combined.dart`).
class _InertMaintenanceScheduler extends MaintenanceSchedulerNotifier {
  @override
  void build() {}
}

/// Runs [cleanup] but never lets it hang past [_teardownTimeout] or throw out
/// of a `tearDownAll` block.
Future<void> _boundedTeardown(
  String label,
  Future<void> Function() cleanup,
) async {
  try {
    await cleanup().timeout(_teardownTimeout);
  } on Object catch (e) {
    debugPrint(
      '[e2e_profile:tearDownAll] $label did not complete within '
      '${_teardownTimeout.inSeconds}s (or threw): ${e.runtimeType}. '
      'Best-effort cleanup only — never rethrown.',
    );
  }
}

/// Short prefix-and-ellipsis pubkey form for log lines.
String _redactPk(String hex) =>
    hex.length <= 8 ? hex : '${hex.substring(0, 8)}…';

// =============================================================================
// Entry point
// =============================================================================

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late ScenarioContext ctx;
  late SyntheticUser bob;
  late String aliceHex;
  var didInitCtx = false;
  var didInitPreSeed = false;
  var didInitBob = false;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});

    // Rust bridge + in-memory keyring + loopback ws:// opt-in + DEFAULT-relay
    // override (→ strfry) + a TestRelay probe socket.
    ctx = await ScenarioHarness.bootstrap();
    didInitCtx = true;

    // Point the SEPARATE discovery plane at the same strfry so profile
    // reads/writes (kind-0) are hermetic, and relax the two Blossom debug
    // opt-ins so A's upload targets — and B's download reaches — the local
    // Blossom. All three are install-once, called exactly once here.
    setDiscoveryRelaysForTest(relays: <String>[defaultStrfryUrl]);
    allowPrivateBlossomForTest();
    setBlossomServerForTest(url: _blossomUrl);

    // Pre-seed Alice's identity and skip onboarding — the production identity
    // load + KeyPackagePublisher providers run exactly as in a real install.
    await TestUser.preSeedIdentityAndSkipOnboarding(seed: aliceSeed);
    didInitPreSeed = true;

    // Cache Alice's pubkey without opening a second CircleManager.
    final alice = await TestUser.derivePubkeyAndNpub(aliceSeed);
    aliceHex = alice.pubkeyHex;

    // Bob as an in-process synthetic peer; his bootstrap publishes a KeyPackage
    // to strfry so Alice's circle creation can resolve him.
    bob = await SyntheticUser.bob(ctx.relay);
    didInitBob = true;

    debugPrint(
      '[e2e_profile:setUpAll] alice=${_redactPk(aliceHex)} '
      'bob=${_redactPk(bob.pubkeyHex)} blossom=$_blossomUrl',
    );
  });

  tearDownAll(() async {
    if (didInitBob) {
      await _boundedTeardown('bob.dispose', bob.dispose);
    }
    if (didInitPreSeed) {
      await _boundedTeardown(
        'TestUser.clearPreSeededIdentity',
        TestUser.clearPreSeededIdentity,
      );
    }
    if (didInitCtx) {
      await _boundedTeardown('ctx.relay.dispose', ctx.relay.dispose);
    }
  });

  testWidgets(
    'Alice UI/providers + Bob FFI: public profile publish → resolve → '
    'name-only edit (photo preserved) → delete → npub fallback',
    (tester) async {
      // Relay-layer privacy/consent watch: buffer EVERY kind-0 the relay sees
      // authored by Alice, from before anything is pumped. Consent defaults
      // OFF, so this MUST stay empty until step 2 grants it.
      final aliceKind0 = <TestRelayEvent>[];
      final kind0Watch = ctx.relay
          .events(<String, dynamic>{
            'kinds': const <int>[0],
            'authors': <String>[aliceHex],
          })
          .listen(aliceKind0.add);

      try {
        // -------------------------------------------------------------------
        // Pump HavenApp (Alice) → MapShell, with the maintenance scheduler
        // no-op'd and the geolocator replaced by a deterministic fake.
        // -------------------------------------------------------------------
        final prefs = await SharedPreferences.getInstance();
        final flags = OnboardingFlags(
          introSeen: prefs.getBool(kOnboardingIntroSeenKey) ?? false,
          displayNameSet:
              prefs.getBool(kOnboardingDisplayNameSetKey) ?? false,
          completed: prefs.getBool(kOnboardingCompletedKey) ?? false,
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              maintenanceSchedulerProvider
                  .overrideWith(_InertMaintenanceScheduler.new),
              onboardingControllerProvider.overrideWith(
                (ref) => OnboardingController(flags),
              ),
              locationServiceProvider.overrideWithValue(
                FakeLocationService(
                  latitude: aliceFakeLatitude,
                  longitude: aliceFakeLongitude,
                ),
              ),
            ],
            child: const HavenApp(),
          ),
        );
        await pumpUntilFound(
          tester,
          find.byType(MapShell),
          timeout: const Duration(seconds: 60),
          description: 'MapShell after pumpWidget',
        );

        final container = ProviderScope.containerOf(
          tester.element(find.byType(MapShell)),
          listen: false,
        );
        final circleService =
            container.read(circleServiceProvider) as NostrCircleService;
        final aliceManager = await circleService.getCircleManagerFfi();
        final profileService = container.read(profileServiceProvider);

        // -------------------------------------------------------------------
        // STEP 0 — Alice + Bob become co-members of the "Family" circle.
        // Reuses the createCircle → publish-Welcome → accept flow.
        // -------------------------------------------------------------------
        await waitForKeyPackage(
          relay: ctx.relay,
          authorPubkeyHex: bob.pubkeyHex,
          timeout: _relayWaitDeadline,
        );
        final relayManager = await RelayManagerFfi.newInstance();
        final bobKp = await relayManager.fetchMemberKeypackage(
          pubkey: bob.pubkeyHex,
        );
        if (bobKp == null) {
          throw StateError(
            '[e2e_profile] fetchMemberKeypackage returned null for Bob — his '
            'KeyPackage never reached the relay.',
          );
        }

        final creation = await aliceManager.createCircle(
          identitySecretBytes: Uint8List.fromList(aliceSeed),
          members: <MemberKeyPackageFfi>[bobKp],
          name: _circleName,
          circleType: 'location_sharing',
          relays: <String>[ctx.relay.url],
          creatorFallbackRelays: <String>[ctx.relay.url],
        );
        final bobWelcome = creation.welcomeEvents.firstWhere(
          (e) => e.recipientPubkey.toLowerCase() == bob.pubkeyHex.toLowerCase(),
          orElse: () => throw StateError(
            '[e2e_profile] createCircle produced no Welcome for Bob.',
          ),
        );
        final (welcomeOk, welcomeMsg) =
            await ctx.relay.publishAndAwaitOk(bobWelcome.eventJson);
        if (!welcomeOk) {
          throw StateError(
            '[e2e_profile] relay rejected Bob Welcome: $welcomeMsg',
          );
        }
        // Default accept timeout is already 90 s (== _relayWaitDeadline).
        final bobCircle = await bob.acceptInvitationViaRelay(relay: ctx.relay);
        expect(
          bobCircle.members.length,
          2,
          reason: 'Bob should see exactly [Alice, Bob] after accepting.',
        );
        debugPrint('[e2e_profile] STEP 0 — Alice + Bob co-members OK');

        // -------------------------------------------------------------------
        // STEP 1 — fresh user has published nothing yet: no kind-0, no blob.
        // Publishing is unconditional (public-by-default, owner-directed
        // 2026-07-16) — there is no consent flag to check; the relay is
        // clean simply because Alice has not yet called
        // updateOwnProfile/setOwnAvatar.
        // -------------------------------------------------------------------
        expect(
          aliceKind0,
          isEmpty,
          reason: 'Relay must observe ZERO kind-0 for a fresh Alice who has '
              'not yet set a name or photo (so ZERO blob can exist on '
              'Blossom).',
        );
        debugPrint(
          '[e2e_profile] STEP 1 — fresh user verified (no kind-0 yet)',
        );

        // -------------------------------------------------------------------
        // STEP 2 — set name + photo, publish. No consent step: publishing is
        // unconditional.
        // -------------------------------------------------------------------
        await profileService.updateOwnProfile(displayName: _aliceName);
        final published = await profileService.setOwnAvatar(_testPng);
        final pictureHash = published.pictureHash;
        expect(
          pictureHash,
          isNotNull,
          reason: 'setOwnAvatar must return the uploaded blob sha256.',
        );

        // (a) A kind-0 with the name AND a picture URL landed on strfry.
        final publishedKind0 = await ctx.relay.firstWhere(
          filter: <String, dynamic>{
            'kinds': const <int>[0],
            'authors': <String>[aliceHex],
          },
          matcher: (e) {
            final c = _contentJson(e);
            return c['display_name'] == _aliceName &&
                ((c['picture'] as String?)?.isNotEmpty ?? false);
          },
          timeout: _relayWaitDeadline,
        );
        final originalPictureUrl =
            _contentJson(publishedKind0)['picture'] as String;
        expect(originalPictureUrl, isNotEmpty);

        // (b) The blob is retrievable from Blossom (BUD-02 GET /<sha256>).
        await _assertBlobRetrievable(_blossomUrl, pictureHash!);
        debugPrint(
          '[e2e_profile] STEP 2 — kind-0 on relay + blob on Blossom OK',
        );

        // -------------------------------------------------------------------
        // STEP 3 — Bob resolves Alice's profile and photo by pubkey.
        // -------------------------------------------------------------------
        final resolved = await bob.user.circleManager.fetchMemberProfiles(
          pubkeysHex: <String>[aliceHex],
          force: true,
        );
        final aliceProfile = resolved.firstWhere(
          (p) => p.pubkeyHex.toLowerCase() == aliceHex.toLowerCase(),
          orElse: () => throw StateError(
            '[e2e_profile] Bob did not resolve Alice kind-0.',
          ),
        );
        expect(
          aliceProfile.displayName,
          _aliceName,
          reason: "Bob must see Alice's published display name.",
        );
        await bob.user.circleManager.downloadMemberPicture(pubkeyHex: aliceHex);
        final bobPhotoBefore = await bob.user.circleManager.getProfilePicture(
          pubkeyHex: aliceHex,
        );
        expect(
          bobPhotoBefore,
          isNotNull,
          reason: "Bob must download Alice's photo bytes from Blossom.",
        );
        expect(bobPhotoBefore!.isNotEmpty, isTrue);
        debugPrint('[e2e_profile] STEP 3 — Bob resolved name + photo OK');

        // -------------------------------------------------------------------
        // STEP 4 — Alice edits ONLY the display name; photo must survive.
        // -------------------------------------------------------------------
        await profileService.updateOwnProfile(displayName: _aliceEditedName);

        // On-relay proof the fetch-merge-publish preserved `picture`: the
        // newest kind-0 carries the NEW name AND the ORIGINAL picture URL.
        final editedKind0 = await ctx.relay.firstWhere(
          filter: <String, dynamic>{
            'kinds': const <int>[0],
            'authors': <String>[aliceHex],
          },
          matcher: (e) =>
              _contentJson(e)['display_name'] == _aliceEditedName,
          timeout: _relayWaitDeadline,
        );
        expect(
          _contentJson(editedKind0)['picture'],
          originalPictureUrl,
          reason: 'Name-only edit must not clobber the picture URL (merge).',
        );

        // B side: forced re-fetch shows the new name AND still has the photo.
        final reResolved = await bob.user.circleManager.fetchMemberProfiles(
          pubkeysHex: <String>[aliceHex],
          force: true,
        );
        final aliceAfterEdit = reResolved.firstWhere(
          (p) => p.pubkeyHex.toLowerCase() == aliceHex.toLowerCase(),
          orElse: () => throw StateError(
            '[e2e_profile] Bob did not re-resolve Alice after edit.',
          ),
        );
        expect(aliceAfterEdit.displayName, _aliceEditedName);
        expect(
          aliceAfterEdit.hasPicture,
          isTrue,
          reason: "Bob must still hold Alice's cached photo after the edit.",
        );
        // The picture URL is unchanged, so a re-download yields byte-identical
        // canonical bytes — the SAME photo.
        await bob.user.circleManager.downloadMemberPicture(pubkeyHex: aliceHex);
        final bobPhotoAfter = await bob.user.circleManager.getProfilePicture(
          pubkeyHex: aliceHex,
        );
        expect(bobPhotoAfter, isNotNull);
        expect(
          bobPhotoAfter,
          bobPhotoBefore,
          reason: 'Same picture bytes before/after the name-only edit.',
        );
        debugPrint('[e2e_profile] STEP 4 — new name + preserved photo OK');

        // -------------------------------------------------------------------
        // STEP 5 — Alice deletes the public profile; B falls back to npub.
        // -------------------------------------------------------------------
        await aliceManager.deleteMyPublicProfile(
          identitySecretBytes: Uint8List.fromList(aliceSeed),
        );

        final afterDelete = await bob.user.circleManager.fetchMemberProfiles(
          pubkeysHex: <String>[aliceHex],
          force: true,
        );
        // A blank kind-0 is state=Known but carries no display fields, so the
        // member tile would render the npub prefix + initials. The entry may be
        // present (blank) or, if the relay dropped it, absent — either way
        // there must be NO stale 'Alice Edited' name.
        for (final p in afterDelete) {
          if (p.pubkeyHex.toLowerCase() == aliceHex.toLowerCase()) {
            expect(
              p.displayName,
              isNull,
              reason: 'Deleted profile must carry no stale display name.',
            );
            expect(p.name, isNull, reason: 'No stale name after delete.');
          }
        }
        debugPrint('[e2e_profile] STEP 5 — delete → npub fallback OK');
      } finally {
        await kind0Watch.cancel();
      }
    },
    timeout: const Timeout(_outerTestTimeout),
  );
}

// =============================================================================
// Helpers
// =============================================================================

/// Decodes a kind-0 event's stringified-JSON `content` into a map.
Map<String, dynamic> _contentJson(TestRelayEvent event) {
  final content = event.raw['content'];
  if (content is! String || content.isEmpty) return const <String, dynamic>{};
  final decoded = jsonDecode(content);
  return decoded is Map<String, dynamic> ? decoded : const <String, dynamic>{};
}

/// Asserts the blob at `<blossomBase>/<sha256Hex>` is retrievable (HTTP 200,
/// non-empty body) — the plan-§7.3 "blob retrievable from Blossom" check.
///
/// Uses a raw `dart:io` client so this proof is independent of the app's own
/// download path (which step 3 exercises separately). The hermetic Blossom is
/// on a loopback / emulator-host alias, reached over cleartext http exactly as
/// the strfry ws:// probe is.
Future<void> _assertBlobRetrievable(
  String blossomBase,
  String sha256Hex,
) async {
  final base = blossomBase.endsWith('/')
      ? blossomBase.substring(0, blossomBase.length - 1)
      : blossomBase;
  final uri = Uri.parse('$base/$sha256Hex');
  final client = HttpClient()..connectionTimeout = _blossomHttpTimeout;
  try {
    final request = await client.getUrl(uri).timeout(_blossomHttpTimeout);
    final response = await request.close().timeout(_blossomHttpTimeout);
    expect(
      response.statusCode,
      200,
      reason: 'Blossom GET $uri must return 200 (blob present).',
    );
    var bytes = 0;
    await for (final chunk in response) {
      bytes += chunk.length;
    }
    expect(
      bytes,
      greaterThan(0),
      reason: 'Blossom blob body must be non-empty.',
    );
  } finally {
    client.close(force: true);
  }
}
