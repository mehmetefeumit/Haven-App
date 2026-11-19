/// Locations through the driver entries production uses, for integration
/// tests that hand an event to another member or look for it on a relay.
///
/// A sealed event carries the circle's `#h`, its event id and its ephemeral
/// pubkey: never print [SealedForTest.eventJson].
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/rust/api.dart';

/// A sealed location: what the driver sends, and the signed event it holds.
class SealedForTest {
  /// Pairs [sealed] with the event it carries.
  const SealedForTest(this.sealed, this.eventJson);

  /// The handle `publishLocationDriven` sends.
  final SealedLocationFfi sealed;

  /// The signed kind-445, as JSON.
  final String eventJson;

  /// The event's id.
  String get eventId =>
      (jsonDecode(eventJson) as Map<String, dynamic>)['id'] as String;
}

/// The holds the core clears by itself on a later drive: a commit awaiting
/// its relay is sent again once the relay is due, an acknowledged one is
/// applied, stored input is carried on, and a refused eviction's wait ends.
/// Every other hold, and every refusal, needs an action no drive takes.
const _clearedByALaterDrive = <SendHeldFfi>{
  SendHeldFfi.awaitingRelays,
  SendHeldFfi.acknowledged,
  SendHeldFfi.storedInput,
  SendHeldFfi.departureDue,
  SendHeldFfi.nothing,
};

/// How long [sealLocationForTest] follows the core's "drive again" answers:
/// one re-send of a commit no relay answered (due 30 s after its call began,
/// itself up to 25 s), with margin. A relay silent past that fails the test.
const _heldSealDeadline = Duration(minutes: 2);

/// Seals a fix for [mlsGroupId] through [relay], claiming the foreground, and
/// fails the test when the core seals nothing.
///
/// A seal held by a commit still in flight is a state, not a failure: as
/// production's scheduler does, the seal is driven again after the wait the
/// core names, until [_heldSealDeadline]. The failure names the hold or the
/// refusal by its variant.
Future<SealedForTest> sealLocationForTest({
  required RelayManagerFfi relay,
  required CircleManagerFfi circle,
  required List<int> mlsGroupId,
  required double latitude,
  required double longitude,
}) async {
  // Monotonic: the clock-skew lane moves the device's wall clock.
  final elapsed = Stopwatch()..start();
  SendHeldFfi? lastHeld;
  while (true) {
    final fix = (await HavenCore.newInstance()).updateLocation(
      latitude: latitude,
      longitude: longitude,
    );
    final SealOutcomeFfi seal;
    try {
      seal = await relay.sealLocationDriven(
        circle: circle,
        mlsGroupId: mlsGroupId,
        location: fix,
        foreground: true,
      );
    } finally {
      fix.dispose();
    }
    final sealed = seal.sealed;
    if (sealed != null) return _sealedForTest(sealed);
    final held = seal.heldBy;
    // `nothing`: what deferred the send was resolved in the call, and the
    // next one is sealed.
    final waitMs =
        seal.retryAfterMs?.toInt() ?? (held == SendHeldFfi.nothing ? 0 : null);
    if (held == null ||
        waitMs == null ||
        !_clearedByALaterDrive.contains(held)) {
      fail(
        // harness-log-ok: a closed SendHeldFfi variant name
        'the core sealed nothing: heldBy=${held?.name} '
        // harness-log-ok: closed RefusalFfi variant name and a boolean
        'refusal=${seal.refusal?.name} retryNamed=${waitMs != null}',
      );
    }
    final wait = Duration(milliseconds: waitMs);
    if (elapsed.elapsed + wait > _heldSealDeadline) {
      fail(
        'the core still held the seal at the deadline: '
        // harness-log-ok: a closed SendHeldFfi variant name
        'heldBy=${held.name}',
      );
    }
    if (held != lastHeld) {
      debugPrint(
        // harness-log-ok: a closed SendHeldFfi variant name
        '[driven_location] seal held (${held.name}); driving again after '
        'the wait the core named',
      );
      lastHeld = held;
    }
    await Future<void>.delayed(wait);
  }
}

SealedForTest _sealedForTest(SealedLocationFfi sealed) {
  final eventJson = sealedLocationEventJsonForTest(sealed: sealed);
  expect(
    eventJson,
    isNotNull,
    reason: 'the sealed-event accessor answers only in a build with debug '
        'assertions',
  );
  return SealedForTest(sealed, eventJson!);
}

/// Seals a fix and sends it once to the relays its record names; fails the
/// test unless a relay accepted it.
Future<SealedForTest> publishLocationForTest({
  required RelayManagerFfi relay,
  required CircleManagerFfi circle,
  required List<int> mlsGroupId,
  required double latitude,
  required double longitude,
}) async {
  final sealed = await sealLocationForTest(
    relay: relay,
    circle: circle,
    mlsGroupId: mlsGroupId,
    latitude: latitude,
    longitude: longitude,
  );
  final answer = await relay.publishLocationDriven(
    circle: circle,
    sealed: sealed.sealed,
    // No relay receive precedes this send: nothing is passed on.
    received: false,
  );
  expect(answer, LocationPublishFfi.accepted);
  return sealed;
}

/// Takes [eventJson] in through [relay]'s driver, claiming the foreground,
/// and answers what it handed back.
Future<List<LocationMessageResultFfi>> ingestForTest({
  required RelayManagerFfi relay,
  required CircleManagerFfi circle,
  required String eventJson,
}) async => (await relay.ingestDriven(
  circle: circle,
  eventJson: eventJson,
  foreground: true,
)).replayed;
