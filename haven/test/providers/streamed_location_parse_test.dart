/// Pins what the live-sync receive path does with a location payload Haven
/// cannot parse.
///
/// Empty content is a ROUTINE inbound shape here, not a corruption. The Rust
/// receive-side kind gate folds an inner event of a kind Haven does not own —
/// a co-member's chat message from another Marmot client, say — into a
/// location result whose content is the empty string, and that lands on the
/// live-sync stream like any other event. It must be dropped in silence:
/// nothing ingested, nothing invalidated, no status pushed at the user, and no
/// exception out of the stream loop.
///
/// The cases below drive the PRODUCTION [parseStreamedLocation] — the very
/// tear-off `subscriptionServiceProvider` hands [LiveEventRouter] — rather than
/// a stand-in asked to return null. `subscription_service_dependency_failure_
/// test.dart` already covers the router's null branch through an injected
/// double; what is proved here is that the real function is what produces that
/// null, and that the pairing drops the event.
///
/// ## What this file deliberately does not claim
///
/// `flutter test` runs with no Rust bridge, so `parseEngineLocation` fails at
/// the FFI entrypoint instead of inside the Rust parser. Both are failures at
/// the same boundary, both must be contained here, and every assertion below
/// therefore holds equally with the bridge up. But the verdict that Rust
/// REJECTS an unparseable payload — rather than yielding a zeroed (0, 0)
/// location that would plant a member marker off West Africa — is Rust
/// behaviour, and is pinned where it can actually be executed: the
/// "Engine-delivered location content (FFI parse)" group in
/// `integration_test/encryption_pipeline_test.dart`. The two halves of the
/// fold are pinned at unit level either side of the boundary — a kind Haven
/// does not own yields empty content
/// (`inner_location_content_is_empty_for_garbage`, `haven-core`), and content
/// that does not parse yields no location rather than a fabricated one
/// (`convert_location_with_unparseable_content_is_seen_not_dropped`,
/// `rust_builder`).
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/subscription_service.dart';

/// The circle the streamed event resolves to.
final Circle _circle = Circle(
  mlsGroupId: const [7, 7, 7],
  nostrGroupId: const [1, 2, 3, 4],
  displayName: 'Test',
  circleType: CircleType.locationSharing,
  relays: const ['wss://relay.test'],
  membershipStatus: MembershipStatus.accepted,
  members: const [],
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

const String _senderPubkey =
    'aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899';

/// No scenario here fires a Welcome, so an unexpected [CircleService] call is a
/// loud failure rather than a silently-defaulted mock (the convention in
/// `subscription_service_dependency_failure_test.dart`).
class _UnusedCircleService implements CircleService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected call: ${invocation.memberName}');
}

/// Records every side effect the router can reach on a Location event.
class _Recorder {
  final List<DecryptedLocation> ingested = <DecryptedLocation>[];
  int locationsChanged = 0;
  int groupUpdated = 0;
  int invitationsReceived = 0;
  final List<FfiSyncStatusReason> statuses = <FfiSyncStatusReason>[];

  LiveEventRouter routerWith(
    Future<DecryptedLocation?> Function(String, String) parseLocation,
  ) => LiveEventRouter(
    circleService: _UnusedCircleService(),
    circlesSnapshot: () async => <Circle>[_circle],
    secretBytes: () async => const <int>[],
    parseLocation: parseLocation,
    ingestLocation: (circle, decrypted) async => ingested.add(decrypted),
    reconcileRoster: (circle) async {},
    onLocationsChanged: () => locationsChanged++,
    onGroupUpdated: (_) => groupUpdated++,
    onInvitationReceived: () => invitationsReceived++,
    onStatus: statuses.add,
  );
}

FfiRelayEvent _locationEvent(String content) => FfiRelayEvent(
  kind: FfiRelayEventKind.location,
  nostrGroupId: Uint8List.fromList(_circle.nostrGroupId),
  senderPubkey: _senderPubkey,
  content: content,
);

void main() {
  group('parseStreamedLocation (the production parse)', () {
    test('returns null for the empty content a foreign kind folds to', () {
      expect(parseStreamedLocation('', _senderPubkey), completion(isNull));
    });

    test('returns null for a malformed payload', () async {
      // The shape called out in the function's own contract: a legacy
      // `haven-avatar-*` chunk from a pre-migration client.
      expect(
        await parseStreamedLocation('haven-avatar-1/3:AAAA', _senderPubkey),
        isNull,
      );
    });

    test('contains the FFI failure instead of propagating it', () async {
      // Security Rule 8: a raw FFI error must never travel toward the UI. The
      // guarantee is that the future COMPLETES with null — removing the
      // `on Object catch` turns this into an escaping error, which is exactly
      // the regression the rule forbids.
      await expectLater(parseStreamedLocation('', _senderPubkey), completes);
    });
  });

  group('a streamed location Haven cannot parse is dropped in silence', () {
    test('empty content ingests nothing and surfaces nothing', () async {
      final recorder = _Recorder();
      final router = recorder.routerWith(parseStreamedLocation);

      await expectLater(router.handleEvent(_locationEvent('')), completes);

      expect(
        recorder.ingested,
        isEmpty,
        reason: 'an unparseable payload must never reach the location cache',
      );
      expect(
        recorder.locationsChanged,
        0,
        reason: 'no location changed, so the map must not be invalidated',
      );
      expect(
        recorder.statuses,
        isEmpty,
        reason:
            'a peer sending a kind Haven does not own is not a sync problem — '
            'a status reason would raise the sync banner at the user',
      );
      expect(recorder.groupUpdated, 0);
      expect(recorder.invitationsReceived, 0);
    });

    test('a malformed payload ingests nothing and surfaces nothing', () async {
      final recorder = _Recorder();
      final router = recorder.routerWith(parseStreamedLocation);

      await expectLater(
        router.handleEvent(_locationEvent('haven-avatar-1/3:AAAA')),
        completes,
      );

      expect(recorder.ingested, isEmpty);
      expect(recorder.locationsChanged, 0);
      expect(recorder.statuses, isEmpty);
    });

    test('the same wiring DOES deliver a location that parses', () async {
      // Non-vacuity: without this, every assertion above would still pass if
      // the router had stopped delivering locations altogether.
      final recorder = _Recorder();
      final parsed = DecryptedLocation(
        senderPubkey: _senderPubkey,
        latitude: 12.345678,
        longitude: 87.654321,
        geohash: 's0000000',
        timestamp: DateTime.utc(2026, 8, 24, 12),
        expiresAt: DateTime.utc(2026, 8, 24, 12, 15),
      );
      final router = recorder.routerWith((content, sender) async => parsed);

      await router.handleEvent(_locationEvent('{"latitude":12.345678}'));

      expect(recorder.ingested, <DecryptedLocation>[parsed]);
      expect(recorder.locationsChanged, 1);
      expect(recorder.statuses, isEmpty);
    });
  });
}
