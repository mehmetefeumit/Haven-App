/// Locations through the driver entries production uses, for integration
/// tests that hand an event to another member or look for it on a relay.
///
/// A sealed event carries the circle's `#h`, its event id and its ephemeral
/// pubkey: never print [SealedForTest.eventJson].
library;

import 'dart:convert';

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

/// Seals a fix for [mlsGroupId] through [relay], claiming the foreground, and
/// fails the test when the core seals nothing.
Future<SealedForTest> sealLocationForTest({
  required RelayManagerFfi relay,
  required CircleManagerFfi circle,
  required List<int> mlsGroupId,
  required double latitude,
  required double longitude,
}) async {
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
  expect(
    sealed,
    isNotNull,
    reason: 'the core held or refused the seal',
  );
  final eventJson = sealedLocationEventJsonForTest(sealed: sealed!);
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
