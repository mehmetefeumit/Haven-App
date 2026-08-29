/// Tests for [MapStatusBanners] — the map's single status slot, and the
/// precedence rule between the two surfaces that can occupy it.
///
/// Both banners were individually complete and individually tested before this
/// widget existed; what was untested (and, for the clock banner, entirely
/// unwired) is what happens when both have something to say at once.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/providers/location_access_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/providers/sharing_health_provider.dart';
import 'package:haven/src/services/clock_skew_detector.dart';
import 'package:haven/src/services/location_settings_launcher.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/widgets/map/map_status_banners.dart';

import '../../helpers/localized_app_harness.dart';

class _NoopLauncher implements LocationSettingsLauncher {
  @override
  Future<bool> openLocationSettings() async => true;

  @override
  Future<bool> openAppSettings() async => true;
}

/// A [SharingHealthNotifier] with the timer and the async derivation removed.
class _StubHealthNotifier extends SharingHealthNotifier {
  _StubHealthNotifier(this._initial);

  final SharingHealth _initial;

  @override
  SharingHealth build() => _initial;

  @override
  Future<void> refresh() async {}
}

/// A [LocationAccessNotifier] with the platform wiring removed.
class _StubAccessNotifier extends LocationAccessNotifier {
  _StubAccessNotifier(this._initial);

  final LocationAccessStatus _initial;

  @override
  LocationAccessStatus build() => _initial;

  @override
  Future<void> refresh() async {}

  void moveTo(LocationAccessStatus next) => state = next;
}

void main() {
  late AppLocalizations l10n;

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('en'));
  });

  late _StubAccessNotifier access;
  late ClockSkewDetector detector;

  Future<void> pumpSlot(
    WidgetTester tester, {
    required LocationAccessStatus status,
    bool clockSkewed = false,
    SharingHealth sharingHealth = SharingHealth.healthy,
  }) async {
    access = _StubAccessNotifier(status);
    detector = ClockSkewDetector();
    addTearDown(detector.dispose);
    if (clockSkewed) detector.recordPublishClockRejection('ahead');

    await pumpLocalized(
      tester,
      const Scaffold(body: MapStatusBanners()),
      overrides: [
        locationAccessProvider.overrideWith(() => access),
        locationSettingsLauncherProvider.overrideWithValue(_NoopLauncher()),
        clockSkewDetectorProvider.overrideWithValue(detector),
        sharingHealthProvider.overrideWith(
          () => _StubHealthNotifier(sharingHealth),
        ),
        sharingHealthClockProvider.overrideWithValue(
          () => DateTime.utc(2026, 8, 28, 12, 30),
        ),
        sharingRepairProvider.overrideWithValue(() async => null),
      ],
    );
  }

  /// A fault old enough for the banner to have something to date.
  final stoppedAt = DateTime.utc(2026, 8, 28, 12);

  group('precedence', () {
    testWidgets('shows nothing at all while both conditions are fine', (
      tester,
    ) async {
      // Anti-vacuity for every "is shown" assertion below.
      await pumpSlot(tester, status: LocationAccessStatus.available);

      expect(find.byType(Card), findsNothing);
      expect(find.text(l10n.mapLocationOffTitle), findsNothing);
      expect(find.text(l10n.clockSkewTitle), findsNothing);
    });

    testWidgets('shows the clock banner when only the clock is wrong', (
      tester,
    ) async {
      await pumpSlot(
        tester,
        status: LocationAccessStatus.available,
        clockSkewed: true,
      );

      expect(find.text(l10n.clockSkewTitle), findsOneWidget);
      expect(find.text(l10n.clockSkewBodyRejected), findsOneWidget);
    });

    testWidgets('shows the access banner when only access is blocked', (
      tester,
    ) async {
      await pumpSlot(tester, status: LocationAccessStatus.serviceDisabled);

      expect(find.text(l10n.mapLocationOffTitle), findsOneWidget);
      expect(find.text(l10n.clockSkewTitle), findsNothing);
    });

    testWidgets('location access WINS when both would show', (tester) async {
      // Its causes are strictly upstream: with the device provider off there
      // is no fix to timestamp, so telling the user to fix their clock first
      // sends them to a settings screen that changes nothing — and the skew
      // verdict itself is stale, since its evidence (publishes completing,
      // peer locations decrypting) stops arriving while access is blocked.
      await pumpSlot(
        tester,
        status: LocationAccessStatus.serviceDisabled,
        clockSkewed: true,
      );

      expect(find.text(l10n.mapLocationOffTitle), findsOneWidget);
      expect(
        find.text(l10n.clockSkewTitle),
        findsNothing,
        reason: 'two full-width error cards over the map would eat the '
            'viewport and leave the user to work out which to act on first',
      );
    });

    testWidgets('exactly one card is ever rendered', (tester) async {
      // Stacking is the tempting failure: each banner renders nothing on its
      // own when healthy, so a naive Column would silently show both.
      await pumpSlot(
        tester,
        status: LocationAccessStatus.serviceDisabled,
        clockSkewed: true,
      );
      expect(find.byType(Card), findsOneWidget);

      access.moveTo(LocationAccessStatus.available);
      await tester.pumpAndSettle();
      expect(find.byType(Card), findsOneWidget);
      expect(find.text(l10n.clockSkewTitle), findsOneWidget);
    });

    testWidgets('shows the sharing-health banner when only delivery is dead', (
      tester,
    ) async {
      // The case the field incident produced: access is fine, the clock is
      // fine, and nothing is being delivered. Before this banner the map said
      // nothing at all.
      await pumpSlot(
        tester,
        status: LocationAccessStatus.available,
        sharingHealth: SharingHealth.receiveSilent(stoppedAt),
      );

      expect(find.byKey(WidgetKeys.sharingHealthBanner), findsOneWidget);
      expect(find.text(l10n.sharingHealthTitleNotReceiving), findsOneWidget);
    });

    testWidgets('location access WINS over sharing health', (tester) async {
      // Strictly upstream: with no fix to send, "nothing is being delivered"
      // is the symptom, and its Repair button would retry a publish that
      // cannot produce a location in the first place.
      await pumpSlot(
        tester,
        status: LocationAccessStatus.serviceDisabled,
        sharingHealth: SharingHealth.publishFailing(stoppedAt),
      );

      expect(find.text(l10n.mapLocationOffTitle), findsOneWidget);
      expect(find.byKey(WidgetKeys.sharingHealthBanner), findsNothing);
      expect(find.byType(Card), findsOneWidget);
    });

    testWidgets('the clock banner WINS over sharing health', (tester) async {
      // A wrong clock is a CAUSE of the delivery silence: a publisher lagging
      // past the retention window has every event discarded by correctly-
      // clocked peers while relays still ACK it. Showing the symptom over the
      // cause would also offer a Repair that republishes into the same failure.
      await pumpSlot(
        tester,
        status: LocationAccessStatus.available,
        clockSkewed: true,
        sharingHealth: SharingHealth.publishFailing(stoppedAt),
      );

      expect(find.text(l10n.clockSkewTitle), findsOneWidget);
      expect(find.byKey(WidgetKeys.sharingHealthBanner), findsNothing);
      expect(find.byType(Card), findsOneWidget);
    });

    testWidgets('sharing health takes over when the clock is corrected', (
      tester,
    ) async {
      // The still-true condition must not be swallowed by the one that
      // cleared.
      await pumpSlot(
        tester,
        status: LocationAccessStatus.available,
        clockSkewed: true,
        sharingHealth: SharingHealth.publishFailing(stoppedAt),
      );
      expect(find.byKey(WidgetKeys.sharingHealthBanner), findsNothing);

      detector.reset();
      await tester.pumpAndSettle();

      expect(find.byKey(WidgetKeys.sharingHealthBanner), findsOneWidget);
      expect(find.byType(Card), findsOneWidget);
    });

    testWidgets('all three at once still renders exactly one card', (
      tester,
    ) async {
      await pumpSlot(
        tester,
        status: LocationAccessStatus.serviceDisabled,
        clockSkewed: true,
        sharingHealth: SharingHealth.publishFailing(stoppedAt),
      );

      expect(find.byType(Card), findsOneWidget);
      expect(find.text(l10n.mapLocationOffTitle), findsOneWidget);
    });

    testWidgets('the clock banner takes over when access is restored', (
      tester,
    ) async {
      // The still-true condition must not be swallowed by the one that
      // cleared.
      await pumpSlot(
        tester,
        status: LocationAccessStatus.serviceDisabled,
        clockSkewed: true,
      );
      expect(find.text(l10n.clockSkewTitle), findsNothing);

      access.moveTo(LocationAccessStatus.available);
      await tester.pumpAndSettle();

      expect(find.text(l10n.clockSkewTitle), findsOneWidget);
    });
  });

  group('accessibility', () {
    testWidgets('the access banner still announces its own recovery, even '
        'though the slot swaps at that exact moment', (tester) async {
      // The recovery announcement fires from a `ref.listen` inside
      // `LocationAccessBanner.build`, on the one edge that also causes this
      // slot to swap its contents. A live region announces its appearance and
      // never its removal, so if that announcement is lost a screen-reader
      // user is told sharing stopped and never told it resumed.
      //
      // Measured, not assumed: swapping the banner out conditionally on the
      // same edge does NOT currently lose it, because Riverpod fires `listen`
      // callbacks before the rebuild that unmounts them. So this test pins the
      // OUTCOME rather than the structure — it fails if the announcement is
      // removed, mis-gated, or fired on the wrong edge, which is what actually
      // matters to the user.
      final announcements = <String>[];
      tester.binding.defaultBinaryMessenger
          .setMockDecodedMessageHandler<dynamic>(SystemChannels.accessibility, (
        dynamic message,
      ) async {
        final map = message! as Map<Object?, Object?>;
        if (map['type'] == 'announce') {
          final data = map['data']! as Map<Object?, Object?>;
          announcements.add(data['message']! as String);
        }
        return null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger
            .setMockDecodedMessageHandler<dynamic>(
              SystemChannels.accessibility,
              null,
            ),
      );

      await pumpSlot(tester, status: LocationAccessStatus.serviceDisabled);
      expect(announcements, isEmpty, reason: 'nothing to announce yet');

      access.moveTo(LocationAccessStatus.available);
      await tester.pumpAndSettle();

      expect(announcements, [l10n.mapLocationAccessRestoredAnnouncement]);
    });

    testWidgets('the clock banner announces its own recovery too', (
      tester,
    ) async {
      // `clockSkewResolvedAnnouncement` exists for the same reason and must
      // likewise be reachable in the composed slot, not just in the banner's
      // own isolated test.
      final announcements = <String>[];
      tester.binding.defaultBinaryMessenger
          .setMockDecodedMessageHandler<dynamic>(SystemChannels.accessibility, (
        dynamic message,
      ) async {
        final map = message! as Map<Object?, Object?>;
        if (map['type'] == 'announce') {
          final data = map['data']! as Map<Object?, Object?>;
          announcements.add(data['message']! as String);
        }
        return null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger
            .setMockDecodedMessageHandler<dynamic>(
              SystemChannels.accessibility,
              null,
            ),
      );

      await pumpSlot(
        tester,
        status: LocationAccessStatus.available,
        clockSkewed: true,
      );
      expect(find.text(l10n.clockSkewTitle), findsOneWidget);
      expect(announcements, isEmpty);

      detector.reset();
      await tester.pumpAndSettle();

      expect(announcements, [l10n.clockSkewResolvedAnnouncement]);
      expect(find.byType(Card), findsNothing);
    });
  });
}
