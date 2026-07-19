/// Integration tests for Haven's custom-relay-addition feature — wire proofs
/// at the SERVICE-FFI level.
///
/// These tests call [CircleManagerFfi] and [RelayManagerFfi] directly without
/// going through Riverpod, which mirrors the pattern established in
/// `circle_service_remove_member_test.dart`.  Every assertion is a
/// **protocol oracle**: it encodes a specific behaviour guaranteed by MIP-00
/// through MIP-04 plus Haven's privacy model.  Comments on each assertion
/// state what goes wrong in production when that assertion is red.
///
/// ## Relay layout
///
/// ```text
/// R1 = defaultStrfryUrl  (7777)  — the default hermetic relay.
/// R2 = secondStrfryUrl   (7778)  — the custom relay under test.
/// ```
///
/// [TestUser.bootstrapProcess] sets the process-global default list to
/// `[R1]` only.  All tests in this file confirm that R2 is provably
/// non-default at the start of each scenario; adding R2 through the FFI and
/// observing events on `r2` is therefore a definitive proof that the
/// production add-relay path works end-to-end.
///
/// ## Platform requirements
///
/// `CircleManagerFfi.newInstance` calls `init_keyring_store()` internally;
/// a live platform keyring is required.  Each test skips honestly with
/// [markTestSkipped] when the keyring is unavailable.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/rust/api.dart';
import 'package:integration_test/integration_test.dart';

import 'e2e/_lib/synthetic_user.dart';
import 'e2e/_lib/test_relay.dart';
import 'e2e/_lib/test_user.dart';

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Convenience hex encoder — mirrors the one in test_user.dart.
String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Returns `true` iff [hex] is exactly 64 lowercase hex characters.
bool _is64LowerHex(String hex) =>
    hex.length == 64 && RegExp(r'^[0-9a-f]{64}$').hasMatch(hex);

// ---------------------------------------------------------------------------
// Test entry-point
// ---------------------------------------------------------------------------

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // The two hermetic relay observers that all tests share.  Opened once in
  // setUpAll and closed in tearDownAll so the WebSocket handshake overhead is
  // paid only once per process.
  late TestRelay r1;
  late TestRelay r2;

  // Alice's single test identity.  Bootstrapped once; each scenario operates
  // on an isolated [CircleManagerFfi] in its own temp directory so MLS state
  // doesn't leak between tests.
  late TestUser alice;

  setUpAll(() async {
    // [bootstrapProcess] installs the in-memory keyring, arms
    // ws-loopback acceptance, and sets the process-global default relay
    // list to [R1] only.  Called before any FFI operation.
    await TestUser.bootstrapProcess(relays: [defaultStrfryUrl]);

    // Open probe connections.  These are read-only observers; they never
    // publish events themselves (except for [SyntheticUser.bootstrap] which
    // uses [TestRelay.publishAndAwaitOk] to seed KeyPackages).
    r1 = await TestRelay.connect(url: defaultStrfryUrl);
    r2 = await TestRelay.connect(url: secondStrfryUrl);

    // Bootstrap Alice's identity (no CircleManagerFfi yet — each test
    // creates its own).
    alice = await TestUser.alice();
  });

  tearDownAll(() async {
    await r1.dispose();
    await r2.dispose();
    await alice.dispose();
  });

  // Precondition asserted in a testWidgets body (NOT setUpAll): a failed
  // expect() inside setUpAll is swallowed by integrationDriver and would let
  // the "custom relay received events" proofs run vacuously. See
  // test/lints/integration_test_propagation_test.dart.
  testWidgets('precondition: R2 is not a process-global default relay', (
    tester,
  ) async {
    expect(
      defaultRelays(),
      isNot(contains(secondStrfryUrl)),
      reason:
          'R2 ($secondStrfryUrl) must NOT be in the process-global default '
          'relay list before any test.  If it is, the proofs below cannot '
          'distinguish "events landed because R2 was added" from "events '
          'landed because R2 was already a default".',
    );
  });

  // =========================================================================
  // FFI-KP-1  — custom KeyPackage relay R2 receives kind 30443 + kind 10002
  //
  // Dark Matter DM-4b note: `CircleManagerFfi.signKeyPackageEvent` (a bare
  // "sign, don't publish" call giving the test direct control over which
  // relays the KeyPackage's `relays` tag embeds) no longer exists.
  // `RelayManagerFfi.maintainKeyPackage` is now the ONE publish path
  // (decide → reuse-or-mint → publish → record, all Rust-internal): it
  // reads the user's OWN NIP-65 relay list and probes/publishes to it,
  // with no Dart-controllable relay parameter. This test is re-expressed
  // to verify the SAME two-plane privacy oracles — the published
  // KeyPackage's `relays` tag matches the user's configured list exactly,
  // and it lands on the newly-added custom relay (R2), never a
  // public-default union — by OBSERVING the wire-published event on R2
  // rather than introspecting a `signed.relays` return value. The kind
  // 10002 relay-list build+publish path is unaffected (still a directly
  // Dart-controlled `buildRelayListPublish` + `publishEvent` call; W2
  // renamed the wire kind 10051→10002, replacing kind 10051 entirely).
  // =========================================================================
  testWidgets(
    'FFI-KP-1: custom KeyPackage relay R2 receives kind 30443 and kind 10002',
    (tester) async {
      // Skip honestly when the platform keyring is unavailable.
      try {
        await initKeyringStore();
      } on Object catch (e) {
        markTestSkipped(
          'Keyring unavailable on this runner (${e.runtimeType}); '
          'skipping FFI-KP-1.',
        );
        return;
      }

      final dataDir = await Directory.systemTemp.createTemp(
        'haven_relay_kp1_',
      );
      try {
        final secretBytes = await alice.getSecretBytes();
        final manager = await CircleManagerFfi.newInstance(
          dataDir: dataDir.path,
          identitySecretBytes: secretBytes,
        );

        // Seed the default relay list so the manager has a non-empty
        // starting point.  This is idempotent.
        await manager.seedRelayDefaultsIfUnseeded();

        try {
          // Enable publishing of the relay list so buildRelayListPublish
          // does not return suppressed.
          await manager.setPublishRelayList(
            relayType: RelayTypeFfi.nip65,
            value: true,
          );

          // Add R2 to the KeyPackage-discovery (NIP-65) category.
          await manager.addUserRelay(
            url: secondStrfryUrl,
            relayType: RelayTypeFfi.nip65,
          );

          // Read back the list — must contain both R1 and R2.
          final kpRelays = await manager.listUserRelays(
            relayType: RelayTypeFfi.nip65,
          );
          expect(
            kpRelays,
            contains(defaultStrfryUrl),
            reason:
                'listUserRelays(nip65) must still contain R1 after '
                'adding R2 — addUserRelay must be additive, not replacing.',
          );
          expect(
            kpRelays,
            contains(secondStrfryUrl),
            reason:
                'listUserRelays(nip65) must contain R2 '
                'after addUserRelay.',
          );

          // Build the kind 10002 relay-list event. Still a directly
          // Dart-controlled publish (unaffected by the KP-publish change).
          final built = await manager.buildRelayListPublish(
            identitySecretBytes: secretBytes,
            relayType: RelayTypeFfi.nip65,
          );

          // ORACLE: suppressed must be false — we just enabled publishing.
          // If true, buildRelayListPublish short-circuited without signing
          // anything; subsequent publish calls would be no-ops.
          expect(
            built.suppressed,
            isFalse,
            reason:
                'buildRelayListPublish must not be suppressed: the toggle was '
                'explicitly enabled above.  A suppressed result means the '
                'toggle write silently failed or buildRelayListPublish reads '
                'a stale cache.',
          );
          expect(
            built.eventJson,
            isNotNull,
            reason:
                'buildRelayListPublish must return eventJson when not '
                'suppressed.',
          );
          // ORACLE (two-plane): targets are EXACTLY the user's configured
          // KeyPackage-discovery list — no public-default union. R1 is
          // present only because it was seeded into the user's list; R2
          // because the user added it. Neither comes from a forced default
          // union (that would leak a private relay onto public relays).
          expect(
            built.targets,
            contains(defaultStrfryUrl),
            reason:
                'buildRelayListPublish.targets must contain R1 — it is in the '
                "user's configured list (seeded), not force-unioned.",
          );
          expect(
            built.targets,
            contains(secondStrfryUrl),
            reason:
                'buildRelayListPublish.targets must contain R2 (user-added '
                'relay).',
          );
          // ORACLE (two-plane): built.targets == the user's configured list,
          // verbatim. No public-default union is added.
          expect(
            built.targets.toSet(),
            equals(kpRelays.toSet()),
            reason:
                'built.targets must equal the user KeyPackage-discovery list '
                'exactly — no public-default union (two-plane leak '
                'invariant).',
          );

          // Register observers BEFORE publishing/triggering maintenance so
          // we do not race the relay's ingestion of the EVENT frame.
          final r2Kp30443Future = r2.firstWhere(
            filter: <String, dynamic>{
              'kinds': <int>[30443],
              'authors': <String>[alice.pubkeyHex],
            },
            timeout: const Duration(seconds: 40),
          );
          final r2KpListFuture = r2.firstWhere(
            filter: <String, dynamic>{
              'kinds': <int>[10002],
              'authors': <String>[alice.pubkeyHex],
            },
            timeout: const Duration(seconds: 40),
          );

          // Publish the kind 30443 KeyPackage via the ONE publish path —
          // `maintainKeyPackage` reads the user's OWN NIP-65 relay list
          // (just seeded with R1+R2 above) and probes/publishes to it
          // internally; there is no Dart-controllable relay parameter.
          final relayMgr = await RelayManagerFfi.newInstance();
          final kpOutcome = await relayMgr.maintainKeyPackage(
            circle: manager,
            identitySecretBytes: secretBytes,
          );
          expect(
            kpOutcome.relayErrors,
            0,
            reason:
                'maintainKeyPackage must reach both R1 and R2 without a '
                'relay error for this assertion to be meaningful.',
          );
          // Publish kind 10002 to built.targets (the user's own list).
          await relayMgr.publishEvent(
            eventJson: built.eventJson!,
            relays: built.targets,
          );

          // Wait for both events to land on R2.
          final kp30443OnR2 = await r2Kp30443Future;
          final kpListOnR2 = await r2KpListFuture;

          // ORACLE: the Dark Matter kind 30443 carries the Marmot v2 tag
          // set EXACTLY — `d` (stable addressable slot),
          // `mls_protocol_version`, `i`, `mls_ciphersuite`,
          // `mls_extensions`, `mls_proposals`, `app_components` — and
          // deliberately NO `relays` tag and NO `encoding` tag (the retired
          // kind-443 MIP-00 §3.2 shape). Relay location is conveyed by the
          // kind-10002 NIP-65 list instead, asserted below. Mirrors the
          // Rust unit oracle in `relay/maintenance/key_package.rs` (the
          // has-marmot-tag-set / no-encoding-or-relays test) at the wire
          // level.
          final kpTags = kp30443OnR2.tags;
          String? kpTagValue(String name) => kpTags
              .where((t) => t.length >= 2 && t.first == name)
              .map((t) => t[1])
              .firstOrNull;
          expect(
            kpTagValue('d'),
            isNotNull,
            reason:
                "kind 30443 must carry a non-empty 'd' tag — it is a NIP-33 "
                'addressable event; without the stable slot, republishes '
                'would accumulate instead of replacing.',
          );
          expect(
            kpTagValue('d'),
            isNotEmpty,
            reason: "the 30443 'd' slot must not be the empty string.",
          );
          for (final required in <String>[
            'mls_protocol_version',
            'mls_ciphersuite',
            'mls_extensions',
            'mls_proposals',
          ]) {
            expect(
              kpTagValue(required),
              isNotNull,
              reason:
                  "kind 30443 must carry an '$required' tag "
                  '(Marmot v2 KeyPackage tag set).',
            );
          }
          for (final retired in <String>['relays', 'encoding']) {
            expect(
              kpTagValue(retired),
              isNull,
              reason:
                  "kind 30443 must NOT carry a '$retired' tag — that is the "
                  'retired kind-443 wire shape. Peers locate KeyPackages via '
                  "the kind-10002 NIP-65 'r' tags, never via an embedded "
                  'relay list.',
            );
          }

          // ORACLE: the kind 10002 event must carry singular `r` tags (one
          // per URL) per NIP-65 semantics, and the full `r`-tag URL set must
          // equal the user's configured KeyPackage-discovery list EXACTLY
          // (kpRelays) — the two-plane leak invariant restated at the wire
          // level, which the retired 30443 `relays` tag used to carry: no
          // public-default union may widen what the user advertised.
          final listTags = kpListOnR2.tags;
          final relayTagsOnList = listTags
              .where((t) => t.isNotEmpty && t.first == 'r')
              .toList();
          expect(
            relayTagsOnList,
            isNotEmpty,
            reason: "kind 10002 must carry at least one 'r' tag per NIP-65.",
          );
          expect(
            relayTagsOnList
                .where((t) => t.length >= 2)
                .map((t) => t[1])
                .toSet(),
            equals(kpRelays.toSet()),
            reason:
                "the kind 10002 'r'-tag URL set must equal the user's "
                'configured KeyPackage-discovery list exactly — peers fetch '
                'the 30443 from these relays, and a wider set would leak '
                'relays the user never advertised (two-plane invariant).',
          );
          // Negative-control comment: if addUserRelay silently failed,
          // kpRelays would be [R1] only.  The 30443 publish would go to R1
          // only and r2Kp30443Future would time out here → test red.
          debugPrint(
            '[FFI-KP-1] PASS: '
            '30443 on R2 id=${kp30443OnR2.id.substring(0, 8)}, '
            '10002 on R2 id=${kpListOnR2.id.substring(0, 8)}',
          );
        } finally {
          // Best-effort wipe of secret bytes in Dart's managed heap.
          for (var i = 0; i < secretBytes.length; i++) {
            secretBytes[i] = 0;
          }
        }
      } finally {
        try {
          await dataDir.delete(recursive: true);
        } on Object catch (_) {}
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  // =========================================================================
  // FFI-INBOX-1 — custom Inbox relay R2 receives kind 10050
  // =========================================================================
  testWidgets(
    'FFI-INBOX-1: custom Inbox relay R2 receives kind 10050',
    (tester) async {
      try {
        await initKeyringStore();
      } on Object catch (e) {
        markTestSkipped(
          'Keyring unavailable on this runner (${e.runtimeType}); '
          'skipping FFI-INBOX-1.',
        );
        return;
      }

      final dataDir = await Directory.systemTemp.createTemp(
        'haven_relay_inbox1_',
      );
      try {
        final secretBytes = await alice.getSecretBytes();
        final manager = await CircleManagerFfi.newInstance(
          dataDir: dataDir.path,
          identitySecretBytes: secretBytes,
        );
        await manager.seedRelayDefaultsIfUnseeded();

        try {
          await manager.setPublishRelayList(
            relayType: RelayTypeFfi.inbox,
            value: true,
          );

          await manager.addUserRelay(
            url: secondStrfryUrl,
            relayType: RelayTypeFfi.inbox,
          );

          final built = await manager.buildRelayListPublish(
            identitySecretBytes: secretBytes,
            relayType: RelayTypeFfi.inbox,
          );

          // ORACLE: kind must be 10050 for inbox category.
          // If 10051 is returned, the category→kind mapping is wrong in
          // Rust; clients querying kind 10050 for inbox relay discovery
          // would not find this user's event.
          expect(
            built.kind,
            equals(10050),
            reason:
                'buildRelayListPublish for RelayTypeFfi.inbox must produce '
                'kind 10050 (NIP-17 inbox relay list).  Got ${built.kind}.',
          );
          expect(
            built.suppressed,
            isFalse,
            reason:
                'Inbox relay list publish must not be suppressed — toggle '
                'was explicitly enabled.',
          );
          expect(
            built.targets,
            contains(secondStrfryUrl),
            reason: 'built.targets must contain R2 after addUserRelay(inbox).',
          );

          final r2Inbox10050Future = r2.firstWhere(
            filter: <String, dynamic>{
              'kinds': <int>[10050],
              'authors': <String>[alice.pubkeyHex],
            },
            timeout: const Duration(seconds: 40),
          );

          final relayMgr = await RelayManagerFfi.newInstance();
          await relayMgr.publishEvent(
            eventJson: built.eventJson!,
            relays: built.targets,
          );

          final inbox10050OnR2 = await r2Inbox10050Future;

          // ORACLE: singular `relay` tags (not `r`).
          final listTags = inbox10050OnR2.tags;
          final relayTagsOnList = listTags
              .where((t) => t.isNotEmpty && t.first == 'relay')
              .toList();
          expect(
            relayTagsOnList,
            isNotEmpty,
            reason:
                "kind 10050 must carry 'relay' tags per NIP-17.",
          );
          final r2InboxTag = relayTagsOnList
              .where((t) => t.length >= 2 && t[1] == secondStrfryUrl)
              .firstOrNull;
          expect(
            r2InboxTag,
            isNotNull,
            reason:
                "kind 10050 must carry ['relay', '$secondStrfryUrl'].",
          );
          final rTags = listTags
              .where((t) => t.isNotEmpty && t.first == 'r')
              .toList();
          expect(
            rTags,
            isEmpty,
            reason:
                "kind 10050 must NOT carry 'r' tags (NIP-65 confusion guard).",
          );
          debugPrint(
            '[FFI-INBOX-1] PASS: 10050 on R2 id='
            '${inbox10050OnR2.id.substring(0, 8)}',
          );
        } finally {
          for (var i = 0; i < secretBytes.length; i++) {
            secretBytes[i] = 0;
          }
        }
      } finally {
        try {
          await dataDir.delete(recursive: true);
        } on Object catch (_) {}
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  // =========================================================================
  // FFI-445-POS — per-circle 445 lands on BOTH relays when the circle was
  // created with explicit relays [R1, R2]
  // =========================================================================
  testWidgets(
    'FFI-445-POS: kind 445 lands on both R1 and R2 when circle created '
    'with explicit relays [R1, R2]',
    (tester) async {
      try {
        await initKeyringStore();
      } on Object catch (e) {
        markTestSkipped(
          'Keyring unavailable on this runner (${e.runtimeType}); '
          'skipping FFI-445-POS.',
        );
        return;
      }

      final aliceDir = await Directory.systemTemp.createTemp(
        'haven_relay_445pos_alice_',
      );
      try {
        final secretBytes = await alice.getSecretBytes();
        final aliceManager = await CircleManagerFfi.newInstance(
          dataDir: aliceDir.path,
          identitySecretBytes: secretBytes,
        );

        try {
          // Bob is a SyntheticUser bootstrapped on R1 — this already
          // publishes his KeyPackage via `maintainKeyPackage` during
          // bootstrap (Dark Matter's ONE publish path), so Alice can
          // fetch it from R1 below without needing to sign it herself.
          final bob = await SyntheticUser.bob(r1);
          try {
            final relayMgrForKp = await RelayManagerFfi.newInstance();
            final bobKpJson = await relayMgrForKp.fetchKeypackage(
              pubkey: bob.pubkeyHex,
            );
            expect(
              bobKpJson,
              isNotNull,
              reason: 'Bob must have a discoverable KeyPackage on R1',
            );

            try {
              // Alice creates the circle with BOTH relays explicitly.
              // This snapshot is stored in the circle row and later
              // returned as circle.relays.
              final circleRelays = <String>[
                defaultStrfryUrl,
                secondStrfryUrl,
              ];
              final creation = await aliceManager.createCircle(
                identitySecretBytes: secretBytes,
                members: [
                  MemberKeyPackageFfi(
                    keyPackageJson: bobKpJson!,
                    inboxRelays: <String>[defaultStrfryUrl],
                    nip65Relays: <String>[defaultStrfryUrl],
                  ),
                ],
                name: 'Dual-Relay Circle',
                circleType: 'location_sharing',
                relays: circleRelays,
                creatorFallbackRelays: <String>[defaultStrfryUrl],
              );

              // Confirm the pending group-creation state Alice staged when
              // creating the circle (publish-before-apply, Rule 13).
              await aliceManager.confirmPublished(pending: creation.pending);

              // ORACLE: the stored circle.relays must exactly match the
              // explicit list.  If createCircle ignores the caller's relay
              // argument and falls back to defaults, R2 would be absent and
              // every 445 would miss R2 — breaking location sharing for any
              // member who is exclusively on R2.
              final storedRelays = creation.circle.relays;
              expect(
                storedRelays,
                contains(defaultStrfryUrl),
                reason:
                    'circle.relays must contain R1 as requested at creation.',
              );
              expect(
                storedRelays,
                contains(secondStrfryUrl),
                reason:
                    'circle.relays must contain R2 as requested at creation — '
                    'the relay snapshot was not honored.',
              );

              // Compute the nostrGroupId hex used in h-tags.
              final nostrGroupIdHex = _hex(creation.circle.nostrGroupId);
              // ORACLE: nostrGroupIdHex must be exactly 64 lowercase hex
              // chars (32 bytes * 2).  An incorrect length would produce
              // malformed h-tags, breaking relay routing for all members.
              expect(
                _is64LowerHex(nostrGroupIdHex),
                isTrue,
                reason:
                    'nostrGroupId hex must be 64 lowercase hex chars '
                    '(32 bytes). Got "${nostrGroupIdHex.length}" chars: '
                    '$nostrGroupIdHex',
              );

              // Confirm the real MLS group ID differs from nostrGroupId.
              // The mlsGroupId is the internal MDK identifier and must
              // NEVER appear in Nostr events (MIP-00 Rule 4).
              final mlsGroupIdHex = _hex(creation.circle.mlsGroupId);
              expect(
                mlsGroupIdHex,
                isNot(equals(nostrGroupIdHex)),
                reason:
                    'mlsGroupId and nostrGroupId must differ: nostrGroupId '
                    'is the public Nostr routing id (h-tag value), while '
                    'mlsGroupId is the private internal identifier that must '
                    'never appear on the wire (MIP-00 Rule 4).',
              );

              // Register observers on BOTH relays BEFORE publishing the 445.
              final r1445Future = r1.firstWhere(
                filter: <String, dynamic>{
                  'kinds': <int>[445],
                  '#h': <String>[nostrGroupIdHex],
                },
                timeout: const Duration(seconds: 40),
              );
              final r2445Future = r2.firstWhere(
                filter: <String, dynamic>{
                  'kinds': <int>[445],
                  '#h': <String>[nostrGroupIdHex],
                },
                timeout: const Duration(seconds: 40),
              );

              // Encrypt and publish a location to the circle's relays.
              final enc = await aliceManager.encryptLocation(
                mlsGroupId: creation.circle.mlsGroupId,
                senderPubkeyHex: alice.pubkeyHex,
                latitude: 51.5,
                longitude: -0.1,
                updateIntervalSecs: BigInt.from(
                  kLocationPublishMaxInterval.inSeconds +
                      kTtlNetworkBufferSeconds,
                ),
              );

              final relayMgr = await RelayManagerFfi.newInstance();
              await relayMgr.publishEvent(
                eventJson: enc.eventJson,
                relays: creation.circle.relays,
              );

              // Await both relay observations.
              final ev445OnR1 = await r1445Future;
              final ev445OnR2 = await r2445Future;

              // ORACLE: ephemeral-key invariant — the kind 445 event's
              // author pubkey must differ from Alice's identity pubkey.
              // Per MIP-02, each group message uses a fresh ephemeral keypair
              // so the sender cannot be identified by pubkey on the relay.
              expect(
                ev445OnR1.pubkey.toLowerCase(),
                isNot(equals(alice.pubkeyHex.toLowerCase())),
                reason:
                    'Ephemeral-key invariant violated: kind 445 pubkey must '
                    "differ from the sender's identity pubkey. If they match "
                    'the sender is linkable by pubkey on the relay, breaking '
                    'MIP-02 sender privacy.',
              );
              expect(
                ev445OnR2.pubkey.toLowerCase(),
                isNot(equals(alice.pubkeyHex.toLowerCase())),
                reason:
                    'Same ephemeral-key invariant on R2.',
              );

              // ORACLE: h-tag value must be nostrGroupIdHex, not the real
              // mlsGroupId.  If the Rust layer accidentally uses the internal
              // MDK group id as the h-tag value, the real group identifier is
              // published to the relay, violating MIP-00 Rule 4 (group id
              // privacy).
              bool hasCorrectHTag(List<List<String>> tags) {
                final hTag = tags
                    .where((t) => t.isNotEmpty && t.first == 'h')
                    .firstOrNull;
                return hTag != null &&
                    hTag.length >= 2 &&
                    hTag[1] == nostrGroupIdHex;
              }

              expect(
                hasCorrectHTag(ev445OnR1.tags),
                isTrue,
                reason:
                    'kind 445 on R1 must carry an h-tag with nostrGroupIdHex '
                    '($nostrGroupIdHex). Missing or wrong h-tag breaks relay '
                    'routing and (if the MLS group id is used instead) leaks '
                    'the internal group identifier.',
              );
              expect(
                hasCorrectHTag(ev445OnR2.tags),
                isTrue,
                reason: 'kind 445 on R2 must carry the same correct h-tag.',
              );

              // Guard: h-tag must NOT equal mlsGroupIdHex (MIP-00 Rule 4).
              bool hTagIsNotMlsId(List<List<String>> tags) {
                final hTag = tags
                    .where((t) => t.isNotEmpty && t.first == 'h')
                    .firstOrNull;
                return hTag == null ||
                    hTag.length < 2 ||
                    hTag[1] != mlsGroupIdHex;
              }

              expect(
                hTagIsNotMlsId(ev445OnR1.tags),
                isTrue,
                reason:
                    'MIP-00 Rule 4: the real MLS group id must NEVER appear '
                    'in h-tags on the relay. Got mlsGroupIdHex=$mlsGroupIdHex '
                    'which must differ from the h-tag value.',
              );
              expect(
                hTagIsNotMlsId(ev445OnR2.tags),
                isTrue,
                reason: 'Same MLS group id guard on R2.',
              );

              debugPrint(
                '[FFI-445-POS] PASS: '
                '445 on R1 id=${ev445OnR1.id.substring(0, 8)}, '
                '445 on R2 id=${ev445OnR2.id.substring(0, 8)}, '
                'nostrGroupIdHex=${nostrGroupIdHex.substring(0, 8)}...',
              );
            } finally {
              // Nothing peer-specific to scrub at this level any more —
              // Bob's KeyPackage came from `maintainKeyPackage` during
              // `SyntheticUser` bootstrap, not a secret fetched here.
            }
          } finally {
            await bob.dispose();
          }
        } finally {
          for (var i = 0; i < secretBytes.length; i++) {
            secretBytes[i] = 0;
          }
        }
      } finally {
        try {
          await aliceDir.delete(recursive: true);
        } on Object catch (_) {}
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );

  // =========================================================================
  // FFI-445-NEG — circle created with relays [R1] only → 445 NEVER reaches R2
  // =========================================================================
  testWidgets(
    'FFI-445-NEG: kind 445 published to circle with relays [R1] only '
    'does NOT reach R2',
    (tester) async {
      try {
        await initKeyringStore();
      } on Object catch (e) {
        markTestSkipped(
          'Keyring unavailable on this runner (${e.runtimeType}); '
          'skipping FFI-445-NEG.',
        );
        return;
      }

      final aliceDir = await Directory.systemTemp.createTemp(
        'haven_relay_445neg_alice_',
      );
      try {
        final secretBytes = await alice.getSecretBytes();
        final aliceManager = await CircleManagerFfi.newInstance(
          dataDir: aliceDir.path,
          identitySecretBytes: secretBytes,
        );

        try {
          // Distinct Bob identity (seedOffset) so this circle's
          // nostrGroupId differs from the one in FFI-445-POS, making the R2
          // negative-control filter unambiguous — AND so the maintenance
          // tick actually publishes: FFI-445-POS already put the base-seed
          // Bob's 30443 on R1, and reusing that pubkey would make this
          // bootstrap ADOPT the stale slot (action=seededD, nothing
          // published) instead of publishing bob_neg's own KeyPackage.
          // Bootstrapping publishes it via `maintainKeyPackage` (Dark
          // Matter's ONE publish path), so Alice can fetch it from R1 below.
          final bob = await SyntheticUser.bootstrap(
            label: 'bob_neg',
            seed: bobSeed,
            relay: r1,
            seedOffset: 1,
          );
          try {
            final relayMgrForKp = await RelayManagerFfi.newInstance();
            final bobKpJson = await relayMgrForKp.fetchKeypackage(
              pubkey: bob.pubkeyHex,
            );
            expect(
              bobKpJson,
              isNotNull,
              reason: 'Bob must have a discoverable KeyPackage on R1',
            );
            try {
              // Create the circle with R1 ONLY.
              final creation = await aliceManager.createCircle(
                identitySecretBytes: secretBytes,
                members: [
                  MemberKeyPackageFfi(
                    keyPackageJson: bobKpJson!,
                    inboxRelays: <String>[defaultStrfryUrl],
                    nip65Relays: <String>[defaultStrfryUrl],
                  ),
                ],
                name: 'Single-Relay Circle (NEG)',
                circleType: 'location_sharing',
                relays: <String>[defaultStrfryUrl],
                creatorFallbackRelays: <String>[defaultStrfryUrl],
              );

              await aliceManager.confirmPublished(pending: creation.pending);

              // ORACLE: circle.relays must be [R1] only.
              expect(
                creation.circle.relays,
                equals(<String>[defaultStrfryUrl]),
                reason:
                    'circle.relays must be [R1] — the caller passed only R1 '
                    'at creation time.',
              );

              final nostrGroupIdHex = _hex(creation.circle.nostrGroupId);

              final enc = await aliceManager.encryptLocation(
                mlsGroupId: creation.circle.mlsGroupId,
                senderPubkeyHex: alice.pubkeyHex,
                latitude: 48.85,
                longitude: 2.35,
                updateIntervalSecs: BigInt.from(
                  kLocationPublishMaxInterval.inSeconds +
                      kTtlNetworkBufferSeconds,
                ),
              );

              // Capture a `since` timestamp immediately before publishing
              // so the R2 negative-control query uses a tightly bounded
              // window.  This prevents stale events from other tests from
              // contaminating the result.
              final sinceTs =
                  DateTime.now().millisecondsSinceEpoch ~/ 1000 - 2;

              final relayMgr = await RelayManagerFfi.newInstance();

              // Register R1 observer BEFORE publishing to prove the observer
              // path is live on this run.  If R1 doesn't receive it either,
              // the test setup is broken rather than the production code.
              final r1445Future = r1.firstWhere(
                filter: <String, dynamic>{
                  'kinds': <int>[445],
                  '#h': <String>[nostrGroupIdHex],
                  'since': sinceTs,
                },
                timeout: const Duration(seconds: 40),
              );

              await relayMgr.publishEvent(
                eventJson: enc.eventJson,
                relays: creation.circle.relays,
              );

              // R1 MUST receive the 445 — this is the positive baseline.
              // If this times out, the relay or publish path is broken,
              // not the relay-isolation logic.
              await r1445Future;

              // Negative control: R2 must NOT receive the 445 within the
              // observation window.  collectN returns whatever was seen before
              // the timeout fires (empty list if nothing matched).
              // ORACLE: relay-metadata privacy invariant — kind 445 events
              // go to circle.relays ONLY.  There is no default-relay fallback
              // for group messages.  If this invariant were violated, R2
              // would see the nostrGroupIdHex h-tag and gain knowledge that
              // this group exists — a group-membership disclosure to an
              // untrusted relay.
              final r2Events = await r2.collectN(
                count: 1,
                filter: <String, dynamic>{
                  'kinds': <int>[445],
                  '#h': <String>[nostrGroupIdHex],
                  'since': sinceTs,
                },
                timeout: const Duration(seconds: 15),
              );
              expect(
                r2Events,
                isEmpty,
                reason:
                    'Relay-metadata privacy invariant violated: kind 445 for '
                    'this circle (h-tag $nostrGroupIdHex) must NEVER reach R2 '
                    'because R2 is not in circle.relays.  If R2 receives it, '
                    'the publish path fell back to default relays for group '
                    'messages — a group-membership disclosure.',
              );
              debugPrint(
                '[FFI-445-NEG] PASS: 445 reached R1 but not R2 '
                '(nostrGroupIdHex=${nostrGroupIdHex.substring(0, 8)}...)',
              );
            } finally {
              // Nothing peer-specific to scrub at this level any more —
              // Bob's KeyPackage came from `maintainKeyPackage` during
              // `SyntheticUser` bootstrap, not a secret fetched here.
            }
          } finally {
            await bob.dispose();
          }
        } finally {
          for (var i = 0; i < secretBytes.length; i++) {
            secretBytes[i] = 0;
          }
        }
      } finally {
        try {
          await aliceDir.delete(recursive: true);
        } on Object catch (_) {}
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  // =========================================================================
  // FFI-445-SNAPSHOT — adding R2 to personal relay lists does NOT reroute
  // an existing circle's kind 445 traffic
  // =========================================================================
  testWidgets(
    'FFI-445-SNAPSHOT: adding R2 to personal Inbox/KP lists does not '
    'reroute kind 445 for an existing circle whose relays are [R1]',
    (tester) async {
      // NOTE: This test is RE-SCOPED per protocol-oracle audit.  It does NOT
      // assert "circle.relays is immutable by design".  Instead it asserts a
      // narrower, observable invariant: adding R2 to the user's personal
      // Inbox and KeyPackage relay lists does NOT touch the group-relay list
      // stored in an unrelated circle row.  The two relay sets are
      // INTENTIONALLY DECOUPLED — personal relay lists govern where the user
      // publishes their own discoverable events (KP, inbox), while a circle's
      // relay list governs where group messages are routed.
      //
      // The spec-sanctioned way to change a circle's relay list is a MIP-01
      // admin GroupContextExtensions Commit (not yet implemented in Haven).
      // This test asserts ONLY that a personal Inbox/KeyPackage add does not
      // reroute group 445 traffic.

      try {
        await initKeyringStore();
      } on Object catch (e) {
        markTestSkipped(
          'Keyring unavailable on this runner (${e.runtimeType}); '
          'skipping FFI-445-SNAPSHOT.',
        );
        return;
      }

      final aliceDir = await Directory.systemTemp.createTemp(
        'haven_relay_445snap_alice_',
      );
      try {
        final secretBytes = await alice.getSecretBytes();
        final aliceManager = await CircleManagerFfi.newInstance(
          dataDir: aliceDir.path,
          identitySecretBytes: secretBytes,
        );
        await aliceManager.seedRelayDefaultsIfUnseeded();

        try {
          // Distinct Bob identity (seedOffset 2 — base is FFI-445-POS,
          // offset 1 is bob_neg) so the maintenance tick publishes this
          // instance's KeyPackage instead of adopting a stale on-relay slot
          // for a reused pubkey (action=seededD, nothing published).
          // Bootstrapping publishes it via `maintainKeyPackage` (Dark
          // Matter's ONE publish path), so Alice can fetch it from R1 below.
          final bob = await SyntheticUser.bootstrap(
            label: 'bob_snap',
            seed: bobSeed,
            relay: r1,
            seedOffset: 2,
          );
          try {
            final relayMgrForKp = await RelayManagerFfi.newInstance();
            final bobKpJson = await relayMgrForKp.fetchKeypackage(
              pubkey: bob.pubkeyHex,
            );
            expect(
              bobKpJson,
              isNotNull,
              reason: 'Bob must have a discoverable KeyPackage on R1',
            );
            try {
              // Step 1: Create a circle with R1 only.
              final creation = await aliceManager.createCircle(
                identitySecretBytes: secretBytes,
                members: [
                  MemberKeyPackageFfi(
                    keyPackageJson: bobKpJson!,
                    inboxRelays: <String>[defaultStrfryUrl],
                    nip65Relays: <String>[defaultStrfryUrl],
                  ),
                ],
                name: 'Snapshot Circle',
                circleType: 'location_sharing',
                relays: <String>[defaultStrfryUrl],
                creatorFallbackRelays: <String>[defaultStrfryUrl],
              );
              await aliceManager.confirmPublished(pending: creation.pending);

              // Step 2: Add R2 to BOTH personal relay lists.
              await aliceManager.addUserRelay(
                url: secondStrfryUrl,
                relayType: RelayTypeFfi.inbox,
              );
              await aliceManager.addUserRelay(
                url: secondStrfryUrl,
                relayType: RelayTypeFfi.nip65,
              );

              // Step 3: Re-read the circle and assert its relay list is
              // still [R1] — the personal-list add must not have touched it.
              final refreshed = await aliceManager.getCircle(
                mlsGroupId: creation.circle.mlsGroupId,
              );
              expect(
                refreshed,
                isNotNull,
                reason: 'getCircle must return the circle after re-read.',
              );
              final circleRelaysAfter = refreshed!.circle.relays;
              expect(
                circleRelaysAfter,
                isNot(contains(secondStrfryUrl)),
                reason:
                    'Adding R2 to the personal Inbox/KeyPackage lists must '
                    'NOT change the relay list of an unrelated circle.  The '
                    'two relay sets are intentionally decoupled in the data '
                    'model.  If this fails, a personal relay add is writing '
                    'to the circles table — a model-layer bug.',
              );
              expect(
                circleRelaysAfter,
                contains(defaultStrfryUrl),
                reason:
                    'The circle’s relay snapshot must still contain R1.',
              );

              final nostrGroupIdHex = _hex(refreshed.circle.nostrGroupId);

              // Step 4: Publish a fresh 445 to circle.relays.
              final enc = await aliceManager.encryptLocation(
                mlsGroupId: refreshed.circle.mlsGroupId,
                senderPubkeyHex: alice.pubkeyHex,
                latitude: 35.68,
                longitude: 139.69,
                updateIntervalSecs: BigInt.from(
                  kLocationPublishMaxInterval.inSeconds +
                      kTtlNetworkBufferSeconds,
                ),
              );

              final sinceTs =
                  DateTime.now().millisecondsSinceEpoch ~/ 1000 - 2;

              final relayMgr = await RelayManagerFfi.newInstance();
              await relayMgr.publishEvent(
                eventJson: enc.eventJson,
                relays: refreshed.circle.relays,
              );

              // Step 5: R2 must NOT receive the 445.
              // This assertion is the relay-metadata privacy invariant for
              // the snapshot scenario: a personal relay add (inbox/KP) must
              // not accidentally expand the routing scope of group messages
              // for circles that did not opt in to R2.
              final r2Events = await r2.collectN(
                count: 1,
                filter: <String, dynamic>{
                  'kinds': <int>[445],
                  '#h': <String>[nostrGroupIdHex],
                  'since': sinceTs,
                },
                timeout: const Duration(seconds: 15),
              );
              expect(
                r2Events,
                isEmpty,
                reason:
                    'Relay-metadata privacy invariant (snapshot): kind 445 '
                    'for this circle must NOT reach R2 after a personal '
                    'relay add.  The spec-sanctioned way to change a '
                    'circle’s relays is a MIP-01 admin '
                    'GroupContextExtensions Commit (not yet implemented in '
                    'Haven); this test asserts ONLY that a personal '
                    'Inbox/KeyPackage add does not reroute group 445 traffic.',
              );
              debugPrint(
                '[FFI-445-SNAPSHOT] PASS: 445 not on R2 after personal '
                'relay add '
                '(nostrGroupIdHex=${nostrGroupIdHex.substring(0, 8)}...)',
              );
            } finally {
              // Nothing peer-specific to scrub at this level any more —
              // Bob's KeyPackage came from `maintainKeyPackage` during
              // `SyntheticUser` bootstrap, not a secret fetched here.
            }
          } finally {
            await bob.dispose();
          }
        } finally {
          for (var i = 0; i < secretBytes.length; i++) {
            secretBytes[i] = 0;
          }
        }
      } finally {
        try {
          await aliceDir.delete(recursive: true);
        } on Object catch (_) {}
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
