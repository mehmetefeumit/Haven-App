/// The providers that belong to one identity.
///
/// One `ProviderContainer` lives for the process, across a logout and the
/// login that follows it. A provider that read the circle service, the
/// identity, a relay list or a manager handle when it was built goes on
/// holding the PREVIOUS identity's: the next identity's inbox REQ was issued
/// on the last one's cached inbox relay list — which, with a customised list,
/// links the two at that relay and listens where nobody sends its Welcomes.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/evolution_poller_provider.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/invitation_poll_status_provider.dart';
import 'package:haven/src/providers/invitation_provider.dart';
import 'package:haven/src/providers/join_watcher_provider.dart';
import 'package:haven/src/providers/key_package_provider.dart';
import 'package:haven/src/providers/live_sync_provider.dart';
import 'package:haven/src/providers/location_publish_scheduler_provider.dart';
import 'package:haven/src/providers/location_sharing_provider.dart';
import 'package:haven/src/providers/maintenance_scheduler_provider.dart';
import 'package:haven/src/providers/member_profile_refresh_provider.dart';
import 'package:haven/src/providers/member_removal_provider.dart';
import 'package:haven/src/providers/mesh_provider.dart';
import 'package:haven/src/providers/own_reachability_provider.dart';
import 'package:haven/src/providers/profile_sync_provider.dart';
import 'package:haven/src/providers/relay_preferences_provider.dart';
import 'package:haven/src/providers/relay_status_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/providers/sharing_health_provider.dart';

/// Every provider whose value is the current identity's and is not rebuilt by
/// watching one that is.
///
/// Invalidated as a set at a login and at the end of a logout
/// ([invalidateIdentityScope]). `circleServiceProvider` is deliberately not
/// here: a logout leaves it as the wiped, latched instance so that every
/// logged-out read fails closed, and only a login retires it.
///
/// A provider that `ref.read`s one of these, the circle service or the
/// identity while it is BUILT must be added here, or read it at each use
/// instead — `test/providers/identity_scope_test.dart` fails otherwise.
final List<ProviderOrFamily> identityScopedProviders = [
  // A manager handle, and a service with per-identity memory.
  relayPreferencesServiceProvider,
  locationSharingServiceProvider,
  // The relay lists, and what is derived from them.
  inboxRelaysProvider,
  keyPackageRelaysProvider,
  profileRelaysProvider,
  profilePoolStatusProvider,
  relayStatusProvider,
  // Circles.
  circlesProvider,
  circleEpochProvider,
  circleLocationExpiryProvider,
  selectedCircleIdProvider,
  // Invitations and the KeyPackage.
  pendingInvitationsProvider,
  invitationPollerProvider,
  invitationPollStatusProvider,
  keyPackagePublisherProvider,
  ownReachabilityProvider,
  // Locations.
  memberLocationsProvider,
  locationPublisherProvider,
  evolutionPollerProvider,
  // Schedulers and state held per identity.
  maintenanceSchedulerProvider,
  locationPublishSchedulerProvider,
  memberProfileRefreshProvider,
  sharingHealthProvider,
  meshProvider,
  meshOnUntilProvider,
  meshStoppedNoticeProvider,
  syncStatusProvider,
  ownProfileSyncProvider,
  memberRemovalProvider,
  joinWatcherProvider,
  displayNameProvider,
];

/// Drops everything [identityScopedProviders] holds, so that each is rebuilt
/// from the identity that is current when it is next read.
void invalidateIdentityScope(Ref ref) {
  identityScopedProviders.forEach(ref.invalidate);
}
