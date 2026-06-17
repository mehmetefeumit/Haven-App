/// Integration tests proving Haven's TWO-PLANE relay privacy invariant at the
/// SERVICE-FFI level: a relay-list event (kind 10050 / 10051) is published
/// ONLY to the user's own configured relays — NEVER force-unioned with the
/// public default relays. A user who configures a private relay (and removes
/// the public defaults) must not leak that private relay onto any public relay.
///
/// These tests call [CircleManagerFfi] / [RelayManagerFfi] directly (no
/// Riverpod), mirroring `relay_customization_publish_test.dart`.
///
/// ## Relay layout
///
/// ```text
/// R1 = defaultStrfryUrl  (7777)  — a PUBLIC relay; the process-global default
///                                  seed. Removed from the user's list below.
/// R2 = secondStrfryUrl   (7778)  — the user's PRIVATE relay (the only one kept).
/// ```
///
/// The proof: seed `[R1]`, add `R2`, then REMOVE `R1` so the user's list is
/// `[R2]` only. Under the OLD model `built.targets` would re-add R1 (the
/// default) via the publish union; under the two-plane model `built.targets`
/// is exactly `[R2]`, and the kind 10050/10051 event lands ONLY on R2 — never
/// on the public R1.
///
/// ## Platform requirements
///
/// `CircleManagerFfi.newInstance` requires a live platform keyring; tests skip
/// honestly via [markTestSkipped] when it is unavailable.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/rust/api.dart';
import 'package:integration_test/integration_test.dart';

import 'e2e/_lib/test_relay.dart';
import 'e2e/_lib/test_user.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late TestRelay r1; // public relay (former default) — must stay leak-free
  late TestRelay r2; // private relay (the only one the user keeps)
  late TestUser alice;

  setUpAll(() async {
    // Process-global default seed = [R1] only.
    await TestUser.bootstrapProcess(relays: [defaultStrfryUrl]);

    // R1 is a current default; R2 is provably NOT — so observing the list
    // event only on R2 (and never on R1) is a definitive no-union proof.
    expect(
      defaultRelays(),
      contains(defaultStrfryUrl),
      reason: 'R1 must be a process-global default for the no-union proof.',
    );
    expect(
      defaultRelays(),
      isNot(contains(secondStrfryUrl)),
      reason: 'R2 must NOT be a default, or the private-relay proof is vacuous.',
    );

    r1 = await TestRelay.connect(url: defaultStrfryUrl);
    r2 = await TestRelay.connect(url: secondStrfryUrl);
    alice = await TestUser.alice();
  });

  tearDownAll(() async {
    await r1.dispose();
    await r2.dispose();
    await alice.dispose();
  });

  /// Runs the private-only leak-proof for one relay category / list kind.
  Future<void> runLeakProof({
    required RelayTypeFfi category,
    required int listKind,
    required String label,
  }) async {
    try {
      await initKeyringStore();
    } on Object catch (e) {
      markTestSkipped(
        'Keyring unavailable on this runner (${e.runtimeType}); '
        'skipping $label.',
      );
      return;
    }

    final dataDir = await Directory.systemTemp.createTemp('haven_2plane_');
    try {
      final manager = await CircleManagerFfi.newInstance(dataDir: dataDir.path);
      await manager.seedRelayDefaultsIfUnseeded();
      final secretBytes = await alice.getSecretBytes();

      await manager.setPublishRelayList(relayType: category, value: true);

      // Add the private relay, then REMOVE the public default so the user's
      // list is the private relay ONLY.
      await manager.addUserRelay(url: secondStrfryUrl, relayType: category);
      final removed = await manager.removeUserRelay(
        url: defaultStrfryUrl,
        relayType: category,
      );
      expect(
        removed,
        isTrue,
        reason: 'Removing the public default R1 must succeed (R2 remains).',
      );

      final userList = await manager.listUserRelays(relayType: category);
      expect(
        userList,
        equals(<String>[secondStrfryUrl]),
        reason: 'After removing R1, the user list must be exactly [R2].',
      );

      final built = await manager.buildRelayListPublish(
        identitySecretBytes: secretBytes,
        relayType: category,
      );
      expect(built.suppressed, isFalse);
      expect(built.eventJson, isNotNull);

      // CORE ORACLE (two-plane leak invariant I1/I2): the publish targets are
      // EXACTLY the user's configured list — the public default R1 is NOT
      // re-added by a union, even though it is still a process-global default.
      expect(
        built.targets,
        equals(<String>[secondStrfryUrl]),
        reason:
            '$label: built.targets must equal [R2] exactly. Containing R1 (a '
            'current default) would mean the old publish union is back — '
            'leaking the private relay onto a public relay.',
      );

      // Observe R2 BEFORE publishing so we never race the EVENT frame.
      final onR2 = r2.firstWhere(
        filter: <String, dynamic>{
          'kinds': <int>[listKind],
          'authors': <String>[alice.pubkeyHex],
        },
        timeout: const Duration(seconds: 40),
      );

      final sinceTs = DateTime.now().millisecondsSinceEpoch ~/ 1000 - 2;

      final relayMgr = await RelayManagerFfi.newInstance();
      await relayMgr.publishEvent(
        eventJson: built.eventJson!,
        relays: built.targets,
      );

      // POSITIVE: the private relay received the list event, and its relay
      // tags name the private relay. This must resolve FIRST so the negative
      // assertion below is anchored to a completed publish (no false pass on
      // slow propagation).
      final r2Event = await onR2;
      final relayTags = r2Event.tags
          .where((t) => t.isNotEmpty && t.first == 'relay')
          .toList();
      expect(
        relayTags.any((t) => t.length >= 2 && t[1] == secondStrfryUrl),
        isTrue,
        reason: '$label: the kind $listKind event on R2 must name R2.',
      );

      // NEGATIVE (anchored): the PUBLIC relay R1 must NEVER receive a kind
      // $listKind event from alice — the private relay is not leaked.
      final r1Events = await r1.collectN(
        count: 1,
        filter: <String, dynamic>{
          'kinds': <int>[listKind],
          'authors': <String>[alice.pubkeyHex],
          'since': sinceTs,
        },
        timeout: const Duration(seconds: 15),
      );
      expect(
        r1Events,
        isEmpty,
        reason:
            '$label: two-plane leak invariant violated — a kind $listKind '
            'relay-list event (which names the private relay R2) reached the '
            'public relay R1. It must publish to the user list ONLY.',
      );

      debugPrint('[$label] PASS: kind $listKind on R2 only; R1 leak-free.');
    } finally {
      await dataDir.delete(recursive: true);
    }
  }

  testWidgets(
    'TP-INBOX: private-only inbox (10050) never leaks to the public relay',
    (tester) async {
      await runLeakProof(
        category: RelayTypeFfi.inbox,
        listKind: 10050,
        label: 'TP-INBOX',
      );
    },
  );

  testWidgets(
    'TP-KP: private-only KeyPackage list (10051) never leaks to the public relay',
    (tester) async {
      await runLeakProof(
        category: RelayTypeFfi.keyPackage,
        listKind: 10051,
        label: 'TP-KP',
      );
    },
  );
}
