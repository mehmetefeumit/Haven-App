/// A Welcome whose invitee's inbox relay is down when it is made is not lost:
/// the next foreground drive sends it from its record — the SAME event, by
/// id — for a founding Welcome and for an invite's alike.
///
/// The invitee's inbox relay is a loopback gate in this process in front of
/// the hermetic relay. While it is down it refuses every connection, so the
/// create (or the invite) reaches no inbox and reports the Welcome owed. Once
/// it is up it forwards both ways and records the id of every gift wrap the
/// device sends, and it swallows the first acknowledgement, so the driver
/// cannot take the first delivery as its last: the Welcome is sent again, and
/// the gate sees the same id twice. A re-wrap would have a new id; a lost
/// record would send nothing.
///
/// The invitee then takes the Welcome off the hermetic relay and joins, which
/// proves the delivered event is a Welcome that works.
///
/// ## Running
///
/// ```sh
/// cd haven && flutter test integration_test/welcome_redelivery_test.dart
/// ```
///
/// Requires a device or emulator and the hermetic strfry relay.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/rust/api.dart';
import 'package:integration_test/integration_test.dart';

import 'e2e/_lib/circle_creation.dart'
    show createCircleOwingWelcomes, joinDeliveredWelcome;
import 'e2e/_lib/coordination.dart' show waitForKeyPackage;
import 'e2e/_lib/scenario_harness.dart';
import 'e2e/_lib/synthetic_user.dart';
import 'e2e/_lib/test_user.dart';
import 'e2e/_lib/throw_time_error_capture.dart';

/// How long the redelivery may take: drives honour the waits the core names
/// between attempts, so a few of them can pass before the record is due.
const Duration _redeliveryDeadline = Duration(seconds: 150);

/// The longest single wait a drive's own hint is honoured for.
const Duration _maxDriveWait = Duration(seconds: 60);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'a founding Welcome made while its inbox relay is down is sent again, '
    'the same event, by the next foreground drive',
    (tester) async {
      installThrowTimeErrorLogging();
      final ctx = await ScenarioHarness.bootstrap();
      final gate = await _RelayGate.start(upstream: ctx.relay.url);
      final alice = await TestUser.alice();
      // A seed of its own, so no earlier scenario's wrap waits for it.
      final bob = await SyntheticUser.bob(ctx.relay, seedOffset: 31);
      final relayManager = await RelayManagerFfi.newInstance();
      try {
        await waitForKeyPackage(
          relay: ctx.relay,
          authorPubkeyHex: bob.pubkeyHex,
        );
        final bobKp = await _inboxBehind(
          relayManager,
          bob,
          alice.circleManager,
          gate,
        );

        final secret = await alice.getSecretBytes();
        final CircleCreationOutcomeFfi created;
        try {
          created = await createCircleOwingWelcomes(
            manager: alice.circleManager,
            relayManager: relayManager,
            identitySecretBytes: secret,
            members: [bobKp],
            name: 'Redelivery Circle',
            circleType: 'location_sharing',
            relays: <String>[ctx.relay.url],
            scenario: 'redelivery',
          );
        } finally {
          secret.fillRange(0, secret.length, 0);
        }
        expect(created.welcomesTotal, 1);
        expect(
          created.welcomesSent,
          0,
          reason: 'premise: the inbox was down, so no relay took the Welcome',
        );
        expect(
          created.unsentRecipients.map((hex) => hex.toLowerCase()),
          [bob.pubkeyHex.toLowerCase()],
        );
        expect(gate.sentWrapIds, isEmpty, reason: 'premise: nothing got in');

        gate.up(swallowFirstOk: true);
        await _driveUntilSentTwice(relayManager, alice.circleManager, gate);

        expect(
          gate.sentWrapIds.toSet(),
          hasLength(1),
          reason: 'every send was the stored Welcome, never a new wrap',
        );
        expect(gate.sentWrapIds.length, greaterThanOrEqualTo(2));

        final joined = await joinDeliveredWelcome(
          relayManager: relayManager,
          invitee: bob.user.circleManager,
          inviteeSecretBytes: await bob.user.getSecretBytes(),
          inviteePubkeyHex: bob.pubkeyHex,
          relays: <String>[ctx.relay.url],
          scenario: 'redelivery',
        );
        expect(joined.circle.mlsGroupId, created.circle!.mlsGroupId);
      } finally {
        await relayManager.shutdown();
        await gate.close();
        await bob.dispose();
        await alice.dispose();
        await ctx.relay.dispose();
      }
    },
    // Two of these stay inside the lane's 10 min drive bound.
    timeout: const Timeout(Duration(minutes: 4)),
  );

  testWidgets(
    "an invite's Welcome made while its inbox relay is down is sent again, "
    'the same event, by the next foreground drive',
    (tester) async {
      installThrowTimeErrorLogging();
      final ctx = await ScenarioHarness.bootstrap();
      final gate = await _RelayGate.start(upstream: ctx.relay.url);
      final alice = await TestUser.alice();
      final bob = await SyntheticUser.bob(ctx.relay, seedOffset: 32);
      final carol = await SyntheticUser.carol(ctx.relay, seedOffset: 32);
      final relayManager = await RelayManagerFfi.newInstance();
      try {
        await waitForKeyPackage(
          relay: ctx.relay,
          authorPubkeyHex: bob.pubkeyHex,
        );
        await waitForKeyPackage(
          relay: ctx.relay,
          authorPubkeyHex: carol.pubkeyHex,
        );
        // Bob's inbox is the hermetic relay itself: the founding is ordinary.
        final bobKp = await relayManager.fetchMemberKeypackage(
          pubkey: bob.pubkeyHex,
          circle: alice.circleManager,
        );
        if (bobKp == null) {
          throw StateError('[redelivery] no KeyPackage for Bob');
        }
        final secret = await alice.getSecretBytes();
        final CircleCreationOutcomeFfi created;
        try {
          created = await createCircleOwingWelcomes(
            manager: alice.circleManager,
            relayManager: relayManager,
            identitySecretBytes: secret,
            members: [bobKp],
            name: 'Redelivery Invite Circle',
            circleType: 'location_sharing',
            relays: <String>[ctx.relay.url],
            scenario: 'redelivery',
          );
        } finally {
          secret.fillRange(0, secret.length, 0);
        }
        final groupId = created.circle!.mlsGroupId;

        final carolKp = await _inboxBehind(
          relayManager,
          carol,
          alice.circleManager,
          gate,
          mlsGroupId: groupId,
        );
        final invited = await relayManager.addMembersDriven(
          circle: alice.circleManager,
          mlsGroupId: groupId,
          members: [carolKp],
          foreground: true,
        );
        expect(
          invited.status,
          PublishStatusFfi.confirmed,
          reason: "premise: the commit reached the circle's own relay",
        );
        expect(invited.welcomesTotal, 1);
        expect(
          invited.welcomesDelivered,
          0,
          reason: "premise: Carol's inbox was down",
        );
        expect(gate.sentWrapIds, isEmpty, reason: 'premise: nothing got in');

        gate.up(swallowFirstOk: true);
        await _driveUntilSentTwice(relayManager, alice.circleManager, gate);

        expect(gate.sentWrapIds.toSet(), hasLength(1));
        expect(gate.sentWrapIds.length, greaterThanOrEqualTo(2));

        final joined = await joinDeliveredWelcome(
          relayManager: relayManager,
          invitee: carol.user.circleManager,
          inviteeSecretBytes: await carol.user.getSecretBytes(),
          inviteePubkeyHex: carol.pubkeyHex,
          relays: <String>[ctx.relay.url],
          scenario: 'redelivery',
        );
        expect(joined.circle.mlsGroupId, groupId);
      } finally {
        await relayManager.shutdown();
        await gate.close();
        await carol.dispose();
        await bob.dispose();
        await alice.dispose();
        await ctx.relay.dispose();
      }
    },
    // Two of these stay inside the lane's 10 min drive bound.
    timeout: const Timeout(Duration(minutes: 4)),
  );
}

/// [user]'s KeyPackage as [inviter] fetched it, with its inbox relays pointed
/// at [gate]: where the Welcome made for it is sent.
Future<MemberKeyPackageFfi> _inboxBehind(
  RelayManagerFfi relayManager,
  SyntheticUser user,
  CircleManagerFfi inviter,
  _RelayGate gate, {
  Uint8List? mlsGroupId,
}) async {
  final fetched = await relayManager.fetchMemberKeypackage(
    pubkey: user.pubkeyHex,
    circle: inviter,
    mlsGroupId: mlsGroupId,
  );
  if (fetched == null) {
    throw StateError('[redelivery] no KeyPackage for ${user.role}');
  }
  return MemberKeyPackageFfi(
    keyPackageJson: fetched.keyPackageJson,
    authorNpub: fetched.authorNpub,
    inboxRelays: <String>[gate.url],
    nip65Relays: fetched.nip65Relays,
  );
}

/// Asks foreground drives, honouring each one's named wait, until [gate] has
/// seen a gift wrap sent at least twice.
Future<void> _driveUntilSentTwice(
  RelayManagerFfi relayManager,
  CircleManagerFfi manager,
  _RelayGate gate,
) async {
  final deadline = DateTime.now().add(_redeliveryDeadline);
  while (gate.sentWrapIds.length < 2) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('[redelivery] the owed Welcome was not sent twice');
    }
    final drive = await relayManager.resumeDriven(
      circle: manager,
      foreground: true,
    );
    if (gate.sentWrapIds.length >= 2) break;
    final named = drive.retryAfterMs;
    final wait = named == null
        ? const Duration(seconds: 5)
        : Duration(milliseconds: named.toInt());
    await Future<void>.delayed(wait < _maxDriveWait ? wait : _maxDriveWait);
  }
}

/// A loopback relay in front of the hermetic one: down, it refuses every
/// connection; up, it forwards both ways, records the id of every gift wrap
/// sent through it, and can swallow the first acknowledgement of one.
class _RelayGate {
  _RelayGate._(this._server, this._upstream) {
    _server.listen(_accept);
  }

  /// Binds a gate on an ephemeral loopback port, down.
  static Future<_RelayGate> start({required String upstream}) async =>
      _RelayGate._(
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
        upstream,
      );

  final HttpServer _server;
  final String _upstream;
  final List<WebSocket> _sockets = [];
  bool _up = false;
  bool _swallowOk = false;

  /// The ids of the gift wraps sent through the gate, in order.
  final List<String> sentWrapIds = [];

  /// The gate's relay URL.
  String get url => 'ws://127.0.0.1:${_server.port}';

  /// Starts forwarding; with [swallowFirstOk], the first acknowledgement of
  /// a gift wrap never reaches the device.
  void up({required bool swallowFirstOk}) {
    _swallowOk = swallowFirstOk;
    _up = true;
  }

  Future<void> _accept(HttpRequest request) async {
    if (!_up || !WebSocketTransformer.isUpgradeRequest(request)) {
      request.response.statusCode = HttpStatus.serviceUnavailable;
      await request.response.close();
      return;
    }
    final client = await WebSocketTransformer.upgrade(request);
    final relay = await WebSocket.connect(_upstream);
    _sockets.addAll([client, relay]);
    client.listen(
      (frame) {
        if (frame is String) _noteSent(frame);
        relay.add(frame);
      },
      onDone: relay.close,
      onError: (_) => relay.close(),
    );
    relay.listen(
      (frame) {
        if (frame is String && _swallowsAck(frame)) return;
        client.add(frame);
      },
      onDone: client.close,
      onError: (_) => client.close(),
    );
  }

  void _noteSent(String frame) {
    final message = jsonDecode(frame);
    if (message is List &&
        message.length >= 2 &&
        message[0] == 'EVENT' &&
        message[1] is Map &&
        (message[1] as Map)['kind'] == 1059) {
      sentWrapIds.add((message[1] as Map)['id'] as String);
    }
  }

  bool _swallowsAck(String frame) {
    if (!_swallowOk) return false;
    final message = jsonDecode(frame);
    if (message is List &&
        message.length >= 2 &&
        message[0] == 'OK' &&
        sentWrapIds.contains(message[1])) {
      _swallowOk = false;
      return true;
    }
    return false;
  }

  /// Closes every connection and the listener.
  Future<void> close() async {
    for (final socket in _sockets) {
      await socket.close();
    }
    await _server.close(force: true);
  }
}
