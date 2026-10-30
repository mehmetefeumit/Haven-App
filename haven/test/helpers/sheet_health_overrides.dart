import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/providers/location_access_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/change_notices.dart';
import 'package:haven/src/services/circle_health_service.dart';

import 'fake_change_notices.dart';

/// A location-access state that never probes the platform.
class FixedLocationAccess extends LocationAccessNotifier {
  FixedLocationAccess([this._status = LocationAccessStatus.available]);

  final LocationAccessStatus _status;

  @override
  LocationAccessStatus build() => _status;

  /// The standing access state; set it as the platform probe would.
  LocationAccessStatus get status => state;
  set status(LocationAccessStatus next) => state = next;
}

/// A circle-health store that has observed nothing.
class EmptyCircleHealth implements CircleHealthService {
  const EmptyCircleHealth();

  @override
  Future<void> notePublishAcked({
    required List<int> nostrGroupId,
    required DateTime at,
  }) async {}

  @override
  Future<void> notePeerEvent({
    required List<int> nostrGroupId,
    required DateTime at,
  }) async {}

  @override
  Future<CircleHealthTimestamps> read({
    required List<int> nostrGroupId,
  }) async => CircleHealthTimestamps.none;
}

/// Location access that never probes the platform, standing [access].
List<Override> deviceBannerOverrides({
  LocationAccessStatus access = LocationAccessStatus.available,
}) => [locationAccessProvider.overrideWith(() => FixedLocationAccess(access))];

/// What a widget test of the circles sheet needs for its sharing card, cue
/// and announcer to build without the platform: location access that never
/// probes, an empty health store and the change notices [notices] holds
/// (none unless given).
List<Override> sheetHealthOverrides({
  FakeNoticeManager? notices,
  LocationAccessStatus access = LocationAccessStatus.available,
}) => [
  ...deviceBannerOverrides(access: access),
  circleHealthServiceProvider.overrideWithValue(const EmptyCircleHealth()),
  changeNoticesProvider.overrideWithValue(
    ChangeNotices(manager: () async => notices ?? FakeNoticeManager()),
  ),
];
