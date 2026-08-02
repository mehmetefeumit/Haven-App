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
/// Both share the local Blossom, but NOT a relay: the circle plane and the
/// profile plane run on physically separate strfry instances (see below). This
/// mirrors the single-process pattern the consolidated `e2e_combined.dart`
/// scenario established (one runner drives one UI role; other roles participate
/// via their FFI surfaces) — see that file's header for the full rationale.
///
/// ## How the hermetic hosts are reached (traced before writing)
///
///   * **Circle relay.** `ScenarioHarness.bootstrap` →
///     `TestUser.bootstrapProcess` installs the loopback-`ws://` opt-in
///     (`allowWsLoopbackForTest`) and the DEFAULT-relay override
///     (`setDefaultRelaysForTest`) pointing at strfry.
///     That relay carries the CIRCLE plane only — KeyPackages, the gift-wrapped
///     Welcome, kind-445 — and never a byte of kind-0 (asserted at the end of
///     the scenario).
///   * **Profile plane (DISJOINT, three relays).** kind-0 does not ride the
///     circle's relays, and — unlike when this scenario was first written — it
///     does not ride the discovery plane either: `haven-core/src/profile/` is
///     structurally forbidden from naming it (CI check 3 in
///     `check_profile_privacy_boundaries.sh`), because the discovery set is a
///     superset of the relays already carrying this account's kind-445/1059.
///     Every profile read AND write resolves through
///     `CircleManager::usable_profile_relays()` = the curated pool minus the
///     append-only contamination ledger, so this scenario installs the hermetic
///     pool from `HAVEN_E2E_PROFILE_RELAYS` by passing it as
///     `ScenarioHarness.bootstrap(profileRelays: ...)` — the harness owns the
///     single `setProfileRelaysForTest` call site, because the Rust override is
///     install-once and a second site throws (CI run 30753193231).
///     THREE relays, not one: `PROFILE_POOL_MIN` is
///     3 and `resolve_profile_pool` dedupes after normalization, so a shorter
///     *distinct* pool is a terminal `PoolUnderflow` and the plane stops
///     resolving entirely (fail-closed by design — there is no fallback).
///   * **Discovery plane.** Still installed, but now serving only the CIRCLE
///     plane: `fetchMemberKeypackage` resolves Bob's kind-10002 / 10050 / 10051
///     relay lists off `discovery_relays()` (haven-core `relay/manager.rs`), so
///     without the override step 0 cannot find his KeyPackage.
///     `setDiscoveryRelaysForTest` is INERT for kind-0.
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
/// - `set_profile_relays_for_test` / `profile_relay_pool_default` — `setUpAll`
///   throws, or every kind-0 wait times out because the plane resolved onto the
///   curated PUBLIC pool instead of the hermetic one.
library;

import 'dart:async' show StreamSubscription;
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
        ProfilePoolStatusFfi,
        RelayManagerFfi,
        allowPrivateBlossomForTest,
        setBlossomServerForTest,
        setDiscoveryRelaysForTest;
import 'package:haven/src/services/nostr_circle_service.dart'
    show NostrCircleService;
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '_lib/circle_creation.dart' show createCircleConfirmed;
import '_lib/coordination.dart';
import '_lib/fake_location_service.dart';
import '_lib/pump_helpers.dart';
import '_lib/scenario_harness.dart';
import '_lib/synthetic_user.dart' show SyntheticUser;
import '_lib/test_relay.dart' show TestRelay, TestRelayEvent, defaultStrfryUrl;
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

/// The hermetic profile-plane relay pool, comma-separated. Baked into the APK /
/// test binary via `--dart-define` by `e2e-profile.yml`; CI passes
/// `ws://10.0.2.2:{7778,7779,7780}` (Android emulator) or
/// `ws://localhost:{7778,7779,7780}` (iOS simulator / host). The default keeps a
/// local run pointed at the three host-native `local-relay` processes
/// `tooling/e2e/ci/start-profile-relays.sh native 7778 7779 7780` starts.
///
/// DISJOINT from [defaultStrfryUrl] by construction — see [_profileRelayUrls].
const String _profileRelaysRaw = String.fromEnvironment(
  'HAVEN_E2E_PROFILE_RELAYS',
  defaultValue: 'ws://localhost:7778,ws://localhost:7779,ws://localhost:7780',
);

/// The FIRST pool member alone, as the workflow also exports it.
///
/// Nothing in this scenario needs a single profile relay — the plane is only
/// ever addressed as a whole — so this exists purely as a drift check against
/// [_profileRelaysRaw]: `e2e-profile.yml` sets `HAVEN_E2E_PROFILE_RELAY` and
/// `HAVEN_E2E_PROFILE_RELAYS` as two independent `env:` entries, and a
/// hand-edit that renumbers one port but not the other would go unnoticed until
/// some future single-URL hook silently dialled a relay nobody started.
const String _profileRelayFirst = String.fromEnvironment(
  'HAVEN_E2E_PROFILE_RELAY',
);

/// Minimum DISTINCT relays the profile plane needs to operate.
///
/// Mirrors `haven_core::profile::PROFILE_POOL_MIN`. Duplicated as a literal
/// because the constant is deliberately not exported over the FFI; if it ever
/// changes upstream this scenario fails loudly in `setUpAll` (pool too small)
/// rather than mysteriously, at the first kind-0 wait.
const int _profilePoolMin = 3;

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
// Profile-plane pool
// =============================================================================

/// The parsed, validated hermetic profile-plane pool.
///
/// Lazily initialised on first read, which is `setUpAll` — so a bad
/// `--dart-define` surfaces there, before anything can publish.
final List<String> _profileRelayUrls =
    _parseProfileRelayPool(_profileRelaysRaw);

/// Splits, trims and validates [_profileRelaysRaw] into the pool this scenario
/// hands to `ScenarioHarness.bootstrap(profileRelays: ...)`, which owns the one
/// `setProfileRelaysForTest` call site in the tree.
///
/// Four checks, each guarding a distinct failure mode that would otherwise
/// surface far from its cause (or, in the first case, not surface at all):
///
///  1. **Loopback only.** Mirrors `TestUser.bootstrapProcess`'s guard on the
///     circle relay. Without it a mistyped `--dart-define` would make the lane
///     publish a real kind-0 — display name and Blossom picture URL — for the
///     sentinel `aliceSeed` pubkey to a PUBLIC Nostr relay, where kind-0 is
///     replaceable but not retractable. That is a permanent public artifact of
///     a CI run, so it is checked before the pool is installed rather than
///     after something fails.
///  2. **At least [_profilePoolMin] DISTINCT entries.** `resolve_profile_pool`
///     dedupes after normalization, so three spellings of one host collapse to
///     one and the plane fails closed with `PoolUnderflow`: no fetch, no
///     publish, and every later kind-0 wait timing out for a reason that looks
///     nothing like its cause.
///  3. **Disjoint from [defaultStrfryUrl].** The circle relay is contaminated
///     by construction (it routes the Family circle's Welcome and kind-445),
///     so the append-only ledger subtracts it. Including it would both shrink
///     the usable pool and quietly defeat the plane-separation proof.
///  4. **`HAVEN_E2E_PROFILE_RELAY` agrees with the head of the list**, when the
///     workflow set it — see [_profileRelayFirst].
List<String> _parseProfileRelayPool(String raw) {
  final urls = raw
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList(growable: false);

  for (final url in urls) {
    if (!_isLoopbackUrl(url)) {
      throw StateError(
        '[e2e_profile] HAVEN_E2E_PROFILE_RELAYS entry "$url" is not a '
        'loopback / emulator-host URL. The profile plane PUBLISHES a kind-0 '
        'for Alice to every pool member, so a non-loopback entry would put a '
        'sentinel-seed public profile on a real relay. Refusing to install.',
      );
    }
  }

  final distinct = urls.map(_normalizeForCompare).toSet();
  if (distinct.length < _profilePoolMin) {
    throw StateError(
      '[e2e_profile] HAVEN_E2E_PROFILE_RELAYS resolved to '
      '${distinct.length} distinct relay(s) ($urls) but the profile plane '
      'needs at least $_profilePoolMin. Fewer is a terminal PoolUnderflow: '
      'resolve_profile_pool fails closed instead of degrading, so kind-0 '
      'would neither publish nor resolve. Start (and pass) three relays.',
    );
  }

  final circleRelay = _normalizeForCompare(defaultStrfryUrl);
  if (distinct.contains(circleRelay)) {
    throw StateError(
      '[e2e_profile] HAVEN_E2E_PROFILE_RELAYS contains the CIRCLE relay '
      '($defaultStrfryUrl). That relay carries the account Welcome and '
      'kind-445 traffic, so the contamination ledger excludes it from the '
      'profile pool — including it shrinks the usable pool and defeats the '
      'plane-separation proof this lane exists to make.',
    );
  }

  if (_profileRelayFirst.isNotEmpty &&
      _normalizeForCompare(_profileRelayFirst) !=
          _normalizeForCompare(urls.first)) {
    throw StateError(
      '[e2e_profile] HAVEN_E2E_PROFILE_RELAY ("$_profileRelayFirst") is not '
      'the first member of HAVEN_E2E_PROFILE_RELAYS ("${urls.first}"). The '
      'two dart-defines are set independently in e2e-profile.yml; they have '
      'drifted apart.',
    );
  }

  return urls;
}

/// Case- and trailing-slash-insensitive form used for the set comparisons
/// above. Deliberately coarse: Rust's `normalize_relay_url` is the real
/// canonicalizer, and these checks only need to catch two spellings of the
/// same hermetic URL.
String _normalizeForCompare(String url) {
  final lower = url.trim().toLowerCase();
  return lower.endsWith('/') ? lower.substring(0, lower.length - 1) : lower;
}

/// `true` when [url] resolves to a loopback / emulator-host alias. Mirrors the
/// private guard in `TestUser.bootstrapProcess`.
bool _isLoopbackUrl(String url) {
  final Uri uri;
  try {
    uri = Uri.parse(url);
  } on FormatException {
    return false;
  }
  return uri.host == 'localhost' ||
      uri.host == '127.0.0.1' ||
      uri.host == '10.0.2.2' || // Android emulator host-loopback alias
      uri.host == '::1';
}

/// Waits until [relay] serves a kind-0 authored by [authorHex] that satisfies
/// [matcher], attributing a timeout to the specific pool member that never
/// produced it.
Future<TestRelayEvent> _awaitKind0(
  TestRelay relay,
  String authorHex,
  bool Function(TestRelayEvent event) matcher,
  String step,
) async {
  try {
    return await relay.firstWhere(
      filter: <String, dynamic>{
        'kinds': const <int>[0],
        'authors': <String>[authorHex],
      },
      matcher: matcher,
      timeout: _relayWaitDeadline,
    );
  } on Object catch (e) {
    throw StateError(
      '[e2e_profile] $step: profile relay ${relay.url} never served a '
      'matching kind-0 for Alice within ${_relayWaitDeadline.inSeconds}s. '
      'Every publish path targets the WHOLE usable pool, so a single lagging '
      'member means either that relay is not running (check '
      'start-profile-relays.sh) or the publish fan-out regressed to a '
      'subset — never a benign timing artifact: $e',
    );
  }
}

/// Waits for a matching kind-0 on EVERY pool member and returns them in pool
/// order.
///
/// This is how the scenario defuses the salt lottery. Each peer resolves an
/// author from that author's top-ranked pool relay under a rendezvous hash over
/// a RANDOM per-install salt, and the three hermetic relays have INDEPENDENT
/// stores — so an assertion made after only one member has the event is a ~1/3
/// coin flip on whichever relay Bob's salt happens to pick. Waiting for the
/// whole pool makes Bob's choice irrelevant, and doubles as the empirical proof
/// that the production publish path really does fan out to every pool member
/// (`publish_metadata` returns as soon as ONE relay acks, so "published" alone
/// would not establish it).
Future<List<TestRelayEvent>> _awaitKind0AcrossPool(
  List<TestRelay> pool,
  String authorHex,
  bool Function(TestRelayEvent event) matcher,
  String step,
) =>
    Future.wait(
      pool.map((r) => _awaitKind0(r, authorHex, matcher, step)),
    );

// =============================================================================
// Entry point
// =============================================================================

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late ScenarioContext ctx;
  late SyntheticUser bob;
  late String aliceHex;
  /// Profile-pool counts sampled in `setUpAll` immediately after the FIRST
  /// `CircleManagerFfi` is constructed, and asserted in the first test below.
  /// See the sampling site for why the verdict cannot live in `setUpAll`.
  late ProfilePoolStatusFfi poolStatusAtFirstManager;
  final profilePool = <TestRelay>[];
  var didInitCtx = false;
  var didInitPreSeed = false;
  var didInitBob = false;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});

    // Rust bridge + in-memory keyring + loopback ws:// opt-in + DEFAULT-relay
    // override (→ strfry) + a TestRelay probe socket — AND the PROFILE plane
    // pointed at its own three hermetic relays.
    //
    // `profileRelays:` is the only hook that retargets kind-0: `profile/` may
    // not name the discovery plane at all, so `setDiscoveryRelaysForTest`
    // (below) has no effect on it.
    //
    // It is passed INTO the harness rather than installed after it, because the
    // Rust override is an install-once `OnceLock` and the harness installs the
    // fail-closed default (the circle relay) for every other lane. Two install
    // sites therefore race, and the loser throws
    // "set_profile_relays_for_test already installed" — which is precisely how
    // this scenario broke on both platforms in CI run 30753193231. One call
    // site makes that structurally impossible.
    //
    // Installing here also keeps the ordering guarantee this scenario needs:
    // the pool must be live BEFORE the first `CircleManagerFfi` is constructed
    // — Alice's via `HavenApp`, Bob's via `SyntheticUser.bob` — because a fresh
    // DB seeds its `RelayType::Profile` rows from
    // `profile_relay_pool_default()`
    // and `usable_profile_relays()` UNIONS those rows back in. Seeding first
    // would leave the eight curated PUBLIC relays permanently in both users'
    // pools, where the assignment hash would send real kind-0 REQs to them.
    //
    // `_profileRelayUrls` validates loopback-only, >= PROFILE_POOL_MIN distinct
    // entries, and disjointness from the circle relay before we get here. The
    // call itself is the propagation check: returning without throwing means
    // this list — and nothing else — is now the pool. (There is deliberately no
    // read-back accessor: no profile-plane relay URL crosses the FFI.)
    //
    // The pool sits exactly ON the PROFILE_POOL_MIN floor, so it has zero
    // contamination headroom: if any of these three ever also carried circle
    // traffic the ledger would subtract it and the plane would fail closed. The
    // disjointness check above is what keeps that from happening silently.
    ctx = await ScenarioHarness.bootstrap(profileRelays: _profileRelayUrls);
    didInitCtx = true;

    // The discovery plane still serves the CIRCLE plane:
    // `fetchMemberKeypackage` resolves Bob's kind-10002 / 10050 / 10051 relay
    // lists through `discovery_relays()`, so step 0 cannot find his KeyPackage
    // without this. It is INERT for kind-0 — kept for what it still does.
    setDiscoveryRelaysForTest(relays: <String>[defaultStrfryUrl]);

    // Relax the two Blossom debug opt-ins so A's upload targets — and B's
    // download reaches — the local Blossom. Both install-once, called once.
    allowPrivateBlossomForTest();
    setBlossomServerForTest(url: _blossomUrl);

    // Probe sockets on every pool member. Step 1 asserts all three are clean
    // for a fresh Alice; steps 2/4/5 wait for her kind-0 on ALL of them, which
    // is what makes Bob's salted relay choice irrelevant.
    for (final url in _profileRelayUrls) {
      profilePool.add(await TestRelay.connect(url: url));
    }

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

    // Positive proof that the hermetic pool was live BEFORE the first
    // `CircleManagerFfi` existed — Bob's, one line above, is that first one.
    //
    // Until now this scenario relied on an ORDERING ARGUMENT (install the
    // override before any DB is created, or the fresh DB seeds its
    // `RelayType::Profile` rows from `profile_relay_pool_default()` and
    // `usable_profile_relays()` unions the eight curated PUBLIC relays back in
    // permanently). Nothing tested it: a broken ordering surfaced only
    // indirectly, as three 90-second kind-0 timeouts pointing nowhere near the
    // cause — and in the worst case as REAL kind-0 REQs for test pubkeys sent
    // to public relays.
    //
    // `profilePoolStatus` returns COUNTS ONLY (no profile relay URL crosses the
    // FFI — that is a deliberate boundary), which is exactly enough: a
    // `configured` of 8 or 11 instead of 3 is the unmistakable signature of the
    // curated production pool having been seeded into the DB.
    //
    // MEASURED here, ASSERTED in the first test below. A bare read is
    // non-assert work and is legal in `setUpAll`; an `expect()` here is not,
    // because a `setUpAll` failure never reaches the results map
    // `integrationDriver()` inspects and would be swallowed —
    // `test/lints/integration_test_propagation_test.dart` enforces exactly
    // that, and it is the same blind spot the drive-log guard in
    // `tooling/e2e/ci/drive-log-lib.sh` exists to cover from the shell side.
    // Capturing the value at THIS point keeps the measurement where it proves
    // ordering (immediately after the first `CircleManagerFfi`) while moving
    // the verdict somewhere it can actually fail the build.
    poolStatusAtFirstManager = await bob.user.circleManager.profilePoolStatus();

    debugPrint(
      '[e2e_profile:setUpAll] alice=${_redactPk(aliceHex)} '
      'bob=${_redactPk(bob.pubkeyHex)} blossom=$_blossomUrl '
      'circleRelay=$defaultStrfryUrl '
      'profilePool=${_profileRelayUrls.length} relays',
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
    for (final relay in profilePool) {
      await _boundedTeardown(
        'profileRelay(${relay.url}).dispose',
        relay.dispose,
      );
    }
    if (didInitCtx) {
      await _boundedTeardown('ctx.relay.dispose', ctx.relay.dispose);
    }
  });

  // Runs FIRST: if the profile plane resolved onto the curated PUBLIC pool,
  // every later step is meaningless (and leaking), so say so before spending
  // twelve minutes discovering it as a kind-0 timeout.
  //
  // The counts were sampled in `setUpAll` right after the first
  // `CircleManagerFfi` was built — a fresh DB seeds its `RelayType::Profile`
  // rows from `profile_relay_pool_default()` and `usable_profile_relays()`
  // unions them back in permanently, so `configured` is a durable record of
  // which pool was live at DB-creation time. Asserting it here rather than at
  // the sampling site is what makes a failure actually fail the build.
  testWidgets('the kind-0 plane resolved onto the hermetic pool, not the '
      'curated public one', (tester) async {
    expect(
      poolStatusAtFirstManager.configured,
      _profileRelayUrls.length,
      reason: 'the profile pool should hold exactly the '
          '${_profileRelayUrls.length} hermetic relays this scenario '
          'installed. A larger count means the curated PUBLIC pool was seeded '
          'into the fresh DB before the override took effect — kind-0 REQs '
          'for test pubkeys would reach real relays.',
    );
    expect(
      poolStatusAtFirstManager.excluded,
      0,
      reason: 'the hermetic profile pool is disjoint from the circle relay, so '
          'the contamination ledger must exclude none of it. A non-zero count '
          'means a profile relay also carried location traffic.',
    );
    expect(
      poolStatusAtFirstManager.isUnderflow,
      isFalse,
      reason: 'an underflowing pool is TERMINAL by design (no fallback), so '
          'every kind-0 read and write in this scenario would fail closed.',
    );
  });

  testWidgets(
    'Alice UI/providers + Bob FFI: public profile publish → resolve → '
    'name-only edit (photo preserved) → delete → npub fallback',
    (tester) async {
      // Plane-separation watch: buffer EVERY kind-0 the CIRCLE relay sees
      // authored by Alice, from before anything is pumped. That relay carries
      // her Welcome and kind-445, so a kind-0 landing there is exactly the
      // cross-plane join the pool exists to break — this buffer must be empty
      // at step 1 AND still empty after the publish/edit/delete cycle.
      final aliceKind0OnCircleRelay = <TestRelayEvent>[];
      final circleRelayKind0Watch = ctx.relay
          .events(<String, dynamic>{
            'kinds': const <int>[0],
            'authors': <String>[aliceHex],
          })
          .listen(aliceKind0OnCircleRelay.add);

      // Freshness watch on the PROFILE plane, one buffer per pool member.
      // Publishing is unconditional, so what keeps these empty through step 1
      // is simply that Alice has not saved a name or photo yet.
      final aliceKind0OnPool = <int, List<TestRelayEvent>>{
        for (var i = 0; i < profilePool.length; i++) i: <TestRelayEvent>[],
      };
      final poolKind0Watches = <StreamSubscription<TestRelayEvent>>[
        for (var i = 0; i < profilePool.length; i++)
          profilePool[i]
              .events(<String, dynamic>{
                'kinds': const <int>[0],
                'authors': <String>[aliceHex],
              })
              .listen(aliceKind0OnPool[i]!.add),
      ];

      try {
        // -------------------------------------------------------------------
        // Pump HavenApp (Alice) → MapShell, with the maintenance scheduler
        // no-op'd and the geolocator replaced by a deterministic fake.
        // -------------------------------------------------------------------
        final prefs = await SharedPreferences.getInstance();
        final flags = OnboardingFlags(
          introSeen: prefs.getBool(kOnboardingIntroSeenKey) ?? false,
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

        // Publishes Bob's Welcome and CONFIRMS the staged create (Security
        // Rule 13) — an unconfirmed create pins the group in MDK's
        // `PendingPublish`, where every inbound kind-445 buffers forever. See
        // `createCircleConfirmed`'s doc.
        final creation = await createCircleConfirmed(
          manager: aliceManager,
          relay: ctx.relay,
          identitySecretBytes: Uint8List.fromList(aliceSeed),
          members: <MemberKeyPackageFfi>[bobKp],
          name: _circleName,
          circleType: 'location_sharing',
          relays: <String>[ctx.relay.url],
          creatorFallbackRelays: <String>[ctx.relay.url],
          label: 'e2e_profile',
        );
        if (!creation.welcomeEvents.any(
          (e) => e.recipientPubkey.toLowerCase() == bob.pubkeyHex.toLowerCase(),
        )) {
          throw StateError(
            '[e2e_profile] createCircle produced no Welcome for Bob.',
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
        for (var i = 0; i < profilePool.length; i++) {
          expect(
            aliceKind0OnPool[i],
            isEmpty,
            reason: 'Profile relay ${profilePool[i].url} must observe ZERO '
                'kind-0 for a fresh Alice who has not yet set a name or photo '
                '(so ZERO blob can exist on Blossom).',
          );
        }
        expect(
          aliceKind0OnCircleRelay,
          isEmpty,
          reason: 'The circle relay must observe ZERO kind-0 for Alice — '
              'ever, but especially before she has published anything.',
        );
        debugPrint(
          '[e2e_profile] STEP 1 — fresh user verified (no kind-0 yet, on any '
          'of the ${profilePool.length} pool relays or the circle relay)',
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

        // (a) A kind-0 with the name AND a picture URL landed on EVERY relay in
        // the profile pool — not just the first one to ack. `publish_metadata`
        // returns as soon as one relay accepts, so waiting on the whole pool is
        // the fan-out proof AND what makes the two downstream steps
        // deterministic: step 3 reads from whichever member Bob's private salt
        // assigns him, and step 4's fetch-merge-publish rebuilds the kind-0
        // from the freshest copy it finds across the pool — a member still
        // holding the pre-picture event could be merged onto, dropping
        // `picture`.
        final publishedKind0s = await _awaitKind0AcrossPool(
          profilePool,
          aliceHex,
          (e) {
            final c = _contentJson(e);
            return c['display_name'] == _aliceName &&
                ((c['picture'] as String?)?.isNotEmpty ?? false);
          },
          'STEP 2 (name + picture publish)',
        );
        // One signed event, broadcast — so every member must be serving the
        // SAME event, not merely something that matches.
        expect(
          publishedKind0s.map((e) => e.id).toSet(),
          hasLength(1),
          reason: 'All pool relays must hold the same published kind-0.',
        );
        final publishedKind0 = publishedKind0s.first;
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
          maxAgeSecs: 0,
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
        // The avatar decode-cache key must reach Flutter on a plain read path,
        // not only on the uploader's own upload response. Without it, Bob's map
        // marker for Alice can never render her photo — it skips the decode
        // entirely when the hash is null — no matter how fresh the profile is.
        final aliceAfterDownload = await bob.user.circleManager
            .fetchMemberProfiles(pubkeysHex: <String>[aliceHex], maxAgeSecs: 0);
        final aliceWithPicture = aliceAfterDownload.firstWhere(
          (p) => p.pubkeyHex.toLowerCase() == aliceHex.toLowerCase(),
        );
        expect(
          aliceWithPicture.hasPicture,
          isTrue,
          reason: 'cached bytes match the current kind-0 picture URL',
        );
        expect(
          aliceWithPicture.pictureSha256Hex,
          isNotNull,
          reason:
              'a member with current cached bytes must expose the decode key',
        );
        expect(aliceWithPicture.pictureSha256Hex, hasLength(64));
        debugPrint('[e2e_profile] STEP 3 — Bob resolved name + photo OK');

        // -------------------------------------------------------------------
        // STEP 4 — Alice edits ONLY the display name; photo must survive.
        // -------------------------------------------------------------------
        await profileService.updateOwnProfile(displayName: _aliceEditedName);

        // On-relay proof the fetch-merge-publish preserved `picture`: the
        // newest kind-0 carries the NEW name AND the ORIGINAL picture URL — on
        // every pool member, so Bob's re-fetch below cannot read a member that
        // still holds the pre-edit event.
        final editedKind0s = await _awaitKind0AcrossPool(
          profilePool,
          aliceHex,
          (e) => _contentJson(e)['display_name'] == _aliceEditedName,
          'STEP 4 (name-only edit)',
        );
        for (var i = 0; i < editedKind0s.length; i++) {
          expect(
            _contentJson(editedKind0s[i])['picture'],
            originalPictureUrl,
            reason: 'Name-only edit must not clobber the picture URL (merge) '
                '— violated on ${profilePool[i].url}.',
          );
        }

        // B side: forced re-fetch shows the new name AND still has the photo.
        final reResolved = await bob.user.circleManager.fetchMemberProfiles(
          pubkeysHex: <String>[aliceHex],
          maxAgeSecs: 0,
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

        // The retraction is a blank (`{}`) kind-0 that supersedes the profile
        // under NIP-01 replaceable-event semantics. Wait for it on EVERY pool
        // member before asking Bob: a retraction that reached only a subset
        // would leave the deleted profile live on precisely the relays some
        // peers are assigned to read from — and here it would make the
        // assertion below a coin flip on Bob's salt.
        await _awaitKind0AcrossPool(
          profilePool,
          aliceHex,
          (e) {
            final c = _contentJson(e);
            return c['display_name'] == null &&
                c['name'] == null &&
                c['picture'] == null;
          },
          'STEP 5 (blank retraction republish)',
        );

        final afterDelete = await bob.user.circleManager.fetchMemberProfiles(
          pubkeysHex: <String>[aliceHex],
          maxAgeSecs: 0,
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

        // -------------------------------------------------------------------
        // PLANE SEPARATION — after a full publish → edit → delete cycle, the
        // circle relay must STILL have seen no kind-0 from Alice. It routed
        // her Welcome and her circle's kind-445, so a kind-0 there would let
        // one operator join "who this IP shares location with" against "who
        // this IP is" — the join the disjoint pool exists to prevent. Asserted
        // last, when the app has had every opportunity to get it wrong.
        // -------------------------------------------------------------------
        expect(
          aliceKind0OnCircleRelay,
          isEmpty,
          reason: 'The circle relay must NEVER observe a kind-0 from Alice: '
              'the profile plane is disjoint from every relay carrying her '
              'kind-445 / kind-1059 traffic, and the contamination ledger '
              'subtracts it from the pool.',
        );
        debugPrint(
          '[e2e_profile] PLANE SEPARATION — circle relay saw 0 kind-0 for '
          'Alice across the whole cycle',
        );
      } finally {
        await circleRelayKind0Watch.cancel();
        for (final w in poolKind0Watches) {
          await w.cancel();
        }
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
