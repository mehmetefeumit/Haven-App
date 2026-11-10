/// Late but authentic fixes after the receive-side NIP-40 screen goes.
///
/// Receivers never judge a kind-445 by its outer `expiration` (Marmot
/// `transports/nostr.md`): the tag is unauthenticated, and dropping on it
/// stalls a device on a commit every other member applies. So a fix whose
/// outer `expiration` (created_at + the 228 s 0x8005 retention) has passed can
/// now reach this service, MLS-authenticated, long after it was sent. Staleness
/// is judged here instead, on the sender's authenticated inner timestamp: such
/// a fix never displaces a fresher one, in the map cache or in the persisted
/// last-known store, and when it is all there is its marker carries its age.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/location_sharing_service.dart';
import 'package:haven/src/widgets/map/member_marker.dart';

import '../mocks/mock_circle_service.dart';
import '../mocks/mock_relay_service.dart';

final String _peer = 'c' * 64;

/// The inner `expires_at` offset every sender stamps
/// (`LOCATION_FRESHNESS_TTL_SECS`, `haven-core/src/location/types.rs:19,164`),
/// which reaches Dart as [DecryptedLocation.expiresAt]. Not the 228 s outer
/// retention: that is the relay-facing tag, and nothing here reads it.
const _freshnessTtl = Duration(minutes: 15);

/// A peer fix sealed at [sentAt], shaped as the FFI delivers it.
DecryptedLocation _fix({required DateTime sentAt, required double latitude}) =>
    DecryptedLocation(
      senderPubkey: _peer,
      latitude: latitude,
      longitude: 2.3522,
      geohash: 'u09tvw',
      timestamp: sentAt,
      expiresAt: sentAt.add(_freshnessTtl),
    );

/// Renders [shown] as `member_markers_layer.dart` does — `lastSeen` is the
/// member's timestamp — and returns the age pill it carries, if any.
Future<String?> _renderedAgePill(
  WidgetTester tester,
  MemberLocation shown,
) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Center(
          child: MemberMarker(
            initials: 'CC',
            publicKey: shown.pubkey,
            diameter: 48,
            nubLength: 0,
            angle: 0,
            bearing: 0,
            offScreen: false,
            lastSeen: shown.timestamp,
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 200));
  final pill = find.textContaining(RegExp(r'^\d+m$'));
  if (pill.evaluate().isEmpty) return null;
  return tester.widget<Text>(pill).data;
}

void main() {
  // The real clock, to the second: the marker computes its age from
  // `DateTime.now()` and `MemberLocation.isExpired` reads it too, so the
  // injected one must agree with it. Every instant below sits whole minutes
  // from `now` and from the 15-minute expiry, so neither the second the suite
  // starts in nor a slow run (under a minute) can move an age pill or an
  // expiry verdict.
  final now = DateTime.fromMillisecondsSinceEpoch(
    DateTime.now().millisecondsSinceEpoch ~/ 1000 * 1000,
    isUtc: true,
  );
  // Sent ten minutes ago: its outer expiration (228 s) passed long ago, its
  // inner freshness window (15 min) has five minutes left.
  final lateSentAt = now.subtract(const Duration(minutes: 10));
  // Sent twenty minutes ago: inner-expired five minutes ago, still well inside
  // the cache's 30-minute eviction grace, so it is kept as last-known.
  final expiredSentAt = now.subtract(const Duration(minutes: 20));

  late DateTime clock;
  late MockCircleService circleService;
  late LocationSharingService service;
  late Circle circle;

  setUp(() {
    clock = now;
    circleService = MockCircleService();
    service = LocationSharingService(
      circleService: circleService,
      relayService: MockRelayService(),
      now: () => clock,
    );
    circle = TestCircleFactory.createCircle(
      nostrGroupId: const [1, 2, 3],
      mlsGroupId: const [9, 9, 9],
    );
  });

  test('a late fix never replaces a fresher one, in the map cache or '
      'in the persisted store', () async {
    await service.ingestStreamedLocation(
      circle: circle,
      decrypted: _fix(
        sentAt: now.subtract(const Duration(minutes: 1)),
        latitude: 48.8566,
      ),
    );
    // It ARRIVES later, as a late fix does: the receipt instant is the one
    // value in the rank the late fix wins.
    clock = now.add(const Duration(seconds: 30));
    await service.ingestStreamedLocation(
      circle: circle,
      decrypted: _fix(sentAt: lateSentAt, latitude: 10),
    );

    expect(
      circleService.methodCalls.where((c) => c == 'upsertLastKnownLocation'),
      hasLength(2),
      reason: 'the late fix reached the store: the verdict below is a rank, '
          'not a fix that never arrived',
    );
    final cached = await service.cachedLocations(circle);
    expect(cached.map((l) => l.latitude), [48.8566]);
    expect(circleService.lastKnownRows.map((r) => r['latitude']), [48.8566]);
  });

  testWidgets("a late fix that is all there is is kept at its sender's "
      'instant, not inner-expired, and its marker shows its age', (
    tester,
  ) async {
    await service.ingestStreamedLocation(
      circle: circle,
      decrypted: _fix(sentAt: lateSentAt, latitude: 10),
    );

    final cached = await service.cachedLocations(circle);
    expect(cached, hasLength(1), reason: 'an authentic fix is kept');
    final shown = cached.single;
    expect(shown.timestamp, lateSentAt);
    expect(shown.freshness, lateSentAt);
    expect(
      shown.isExpired,
      isFalse,
      reason: 'late past its outer expiration is not past its inner one',
    );
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    expect(
      await _renderedAgePill(tester, shown),
      l10n.memberMarkerMinutesShort(10),
      reason: "the marker ages the fix from the sender's reading, not from "
          "this device's receipt",
    );
  });

  testWidgets('an inner-expired fix that is all there is is kept as '
      'last-known and its marker shows its age', (tester) async {
    await service.ingestStreamedLocation(
      circle: circle,
      decrypted: _fix(sentAt: expiredSentAt, latitude: 10),
    );

    final cached = await service.cachedLocations(circle);
    expect(cached, hasLength(1), reason: 'inside the eviction grace');
    final shown = cached.single;
    expect(shown.timestamp, expiredSentAt);
    expect(shown.isExpired, isTrue);
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    expect(
      await _renderedAgePill(tester, shown),
      l10n.memberMarkerMinutesShort(20),
    );
  });
}
