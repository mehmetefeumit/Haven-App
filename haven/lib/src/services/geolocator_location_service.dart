/// Production implementation of [LocationService] using the geolocator package.
///
/// This implementation provides high-accuracy location tracking with:
/// - Best accuracy possible for precise location data
/// - Forces Android LocationManager (bypasses Google Play Services for F-Droid)
/// - Frequent updates for real-time tracking
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/services/ios_location_source.dart';
import 'package:haven/src/services/location_service.dart';

/// Which Android platform registration a [GeolocatorLocationService
/// .getLocationStream] subscription asks the plugin for.
///
/// Two USE CASES over the one plugin boundary, never two streams (see the
/// class doc): the map isolate's live registration, and the Android
/// foreground service's single long-interval one. Ignored on iOS, where the
/// session's shape follows the background-sharing intent instead.
sealed class AndroidStreamProfile {
  /// Const base constructor for the two profiles below.
  const AndroidStreamProfile();

  /// The map's live registration — see [ForegroundStreamProfile].
  const factory AndroidStreamProfile.foreground() = ForegroundStreamProfile;

  /// The foreground service's registration — see
  /// [BackgroundServiceStreamProfile].
  const factory AndroidStreamProfile.backgroundService({
    required Duration interval,
  }) = BackgroundServiceStreamProfile;
}

/// A responsive registration for a map somebody is looking at: a fix every
/// metre, up to once a second.
///
/// Deliberately unchanged by the background work — this is what a live map
/// needs, and `b5_permission_revocation_test.dart` tells a revoked
/// permission from a granted one by the SILENCE of this stream, which only
/// discriminates while deliveries are otherwise a second apart.
final class ForegroundStreamProfile extends AndroidStreamProfile {
  /// Creates the foreground profile.
  const ForegroundStreamProfile();
}

/// The Android foreground service's registration: one fix per [interval],
/// no distance filter, no `timeLimit`.
///
/// [interval] reaches `LocationRequest.intervalMillis` — and geolocator
/// builds the request with `minUpdateInterval` equal to it
/// (`LocationManagerClient.startPositionUpdates`), so no fix arrives early.
/// That is what lets the platform duty-cycle GNSS between fixes instead of
/// navigating continuously, which is the whole point of the profile. The
/// publish is due on TIME, so a distance filter would only suppress the fix
/// the cycle is waiting for while the device sits still.
///
/// No `timeLimit`, ever: on a STREAM geolocator's `timeLimit` is an
/// inter-event timeout that CLOSES the stream, which this service reads as
/// an access loss and answers by dropping the cached fix. A silent provider
/// is the foreground service's watchdog to handle, not a reason to
/// self-inflict a revocation.
final class BackgroundServiceStreamProfile extends AndroidStreamProfile {
  /// Creates a background-service profile requesting a fix per [interval].
  const BackgroundServiceStreamProfile({required this.interval});

  /// How often the platform is asked for a fix.
  final Duration interval;
}

/// Abstraction for geolocator static methods.
///
/// This allows for dependency injection in tests.
abstract class GeolocatorWrapper {
  /// Checks if location services are enabled.
  Future<bool> isLocationServiceEnabled();

  /// Checks current location permission.
  Future<geo.LocationPermission> checkPermission();

  /// Requests location permission.
  Future<geo.LocationPermission> requestPermission();

  /// Reads the granted location ACCURACY, which is orthogonal to the
  /// permission above: a user can hold `whileInUse` and still have
  /// downgraded the app to approximate coordinates (iOS: Settings →
  /// Privacy → Location Services → Precise Location off; Android:
  /// COARSE granted while FINE is revoked). Both platforms report that
  /// downgrade only here — `checkPermission()` keeps reading
  /// `whileInUse` — so without this the access gate structurally cannot
  /// see it.
  Future<geo.LocationAccuracyStatus> getLocationAccuracy();

  /// Gets the current position.
  Future<geo.Position> getCurrentPosition({
    required geo.LocationSettings locationSettings,
  });

  /// Gets the last known position.
  Future<geo.Position?> getLastKnownPosition();

  /// Gets a stream of position updates.
  Stream<geo.Position> getPositionStream({
    required geo.LocationSettings locationSettings,
  });
}

/// Production implementation that delegates to Geolocator static methods.
class DefaultGeolocatorWrapper implements GeolocatorWrapper {
  /// Creates a new [DefaultGeolocatorWrapper].
  const DefaultGeolocatorWrapper();

  @override
  Future<bool> isLocationServiceEnabled() {
    return geo.Geolocator.isLocationServiceEnabled();
  }

  @override
  Future<geo.LocationPermission> checkPermission() {
    return geo.Geolocator.checkPermission();
  }

  @override
  Future<geo.LocationPermission> requestPermission() {
    return geo.Geolocator.requestPermission();
  }

  @override
  Future<geo.LocationAccuracyStatus> getLocationAccuracy() {
    return geo.Geolocator.getLocationAccuracy();
  }

  @override
  Future<geo.Position> getCurrentPosition({
    required geo.LocationSettings locationSettings,
  }) {
    return geo.Geolocator.getCurrentPosition(
      locationSettings: locationSettings,
    );
  }

  @override
  Future<geo.Position?> getLastKnownPosition() {
    return geo.Geolocator.getLastKnownPosition();
  }

  @override
  Stream<geo.Position> getPositionStream({
    required geo.LocationSettings locationSettings,
  }) {
    return geo.Geolocator.getPositionStream(locationSettings: locationSettings);
  }
}

/// Production location service implementation using geolocator.
///
/// Configuration:
/// - **Android**: Forces LocationManager API (NOT Google Play Services)
/// - **Accuracy**: Best - uses GPS for maximum precision
/// - **Update frequency**: Continuous updates via stream
/// - **User Experience**: Optimized for responsive, accurate location tracking
///
/// ## One stream owner per platform, per isolate
///
/// On **iOS** the position stream is not geolocator's at all: it is Haven's
/// own `CLLocationManager`, reached through [IosLocationSource]. The plugin
/// can only start and stop a session, and the accuracy profiles this app runs
/// need `desiredAccuracy` written LIVE on a running manager. Only fixes the
/// native owner delivered under the Best profile ever arrive here.
///
/// On **Android** it stays geolocator's, and geolocator supports exactly ONE
/// active position stream per plugin instance: the Dart side caches it
/// (`GeolocatorAndroid._positionStream`) and silently returns the cached
/// stream — old settings and all — to any later `getPositionStream` call,
/// while the native side rejects a second concurrent listen outright. Only
/// cancelling the subscription clears that cache, so SETTINGS CAN ONLY
/// CHANGE BY A NEW SUBSCRIPTION.
///
/// Therefore this service exposes a single [getLocationStream] with exactly
/// one call site per platform, whose shape is chosen per subscription: on iOS
/// by the caller-supplied `backgroundSharingEnabled` intent (which reaches
/// `allowsBackgroundLocationUpdates` unchanged), on Android by the
/// caller-supplied [AndroidStreamProfile]. There must never be a second
/// stream-returning API: a "background variant" stream would silently inherit
/// the first session's settings (the exact defect that broke iOS background
/// publishing). CI pins this invariant
/// (`scripts/ci/check_ios_background_publish.sh`).
///
/// A profile is not a second stream. Each Dart isolate has its own plugin
/// instance and its own instance of this service, so the UI isolate and the
/// Android foreground service can each own ONE registration — and they never
/// hold one at the same time: the UI releases its subscription
/// ([suspendStream]) before it hands ownership over at pause, and the
/// foreground service releases its own before the UI takes it back. The two
/// profiles are exclusive by LIFECYCLE, not by settings.
///
/// ## Access gate (no coordinate outlives consent)
///
/// The stream's latest fix is cached ([_lastStreamPosition]) so publish
/// cycles work while backgrounded on iOS. That cache is served only behind
/// [_ensureAccessOrThrow] and is dropped by [_noteAccessLost] the moment
/// any code path observes that the provider was switched off, the
/// permission withdrawn, or the granted accuracy downgraded from precise
/// to approximate. Android can withdraw access without touching any of
/// those — an app-op denial leaves every permission read saying "granted"
/// — so the cache read is additionally corroborated by
/// [_platformStillPermitsLocation]. See all three members for the rules.
///
/// ## The gate never prompts from the background
///
/// [_ensureAccessOrThrow] asks for the permission only while
/// [_foregroundActive]. A prompt is a foreground-UI interaction by
/// definition, and raising one from a background publish tick cannot
/// succeed on either platform: iOS DEFERS the alert while suspended and
/// geolocator's `PermissionHandler` never resolves its `FlutterResult`
/// (its delegate early-returns on `notDetermined`), so the Dart future
/// hangs forever; Android needs an `Activity` the background isolate does
/// not have. The un-prompted read is treated as a denial — cache cleared,
/// [LocationServiceException] thrown — so skipping the prompt fails
/// CLOSED.
class GeolocatorLocationService implements LocationService {
  /// Creates a new [GeolocatorLocationService].
  ///
  /// Optionally accepts a [GeolocatorWrapper] and an [IosLocationSource] for
  /// testing. The optional [isIOS] flag is a test seam overriding the
  /// [Platform.isIOS] check that routes the stream and the last-known read;
  /// production callers omit all three.
  GeolocatorLocationService({
    GeolocatorWrapper? geolocator,
    bool? isIOS,
    IosLocationSource? iosSource,
  }) : _geolocator = geolocator ?? const DefaultGeolocatorWrapper(),
       _isIOS = isIOS ?? Platform.isIOS,
       _iosSource = iosSource ?? createIosLocationSource();

  final GeolocatorWrapper _geolocator;

  /// Haven's own iOS CoreLocation session — the stream owner and the
  /// last-known source on that platform, and a no-op everywhere else.
  final IosLocationSource _iosSource;

  /// Whether this device is running iOS.
  ///
  /// Routes the position stream and the last-known read to [_iosSource], and
  /// selects [geo.AppleSettings] over [geo.AndroidSettings] for the one-shot.
  /// Passing [geo.AndroidSettings] on iOS is a latent bug: the
  /// `forceLocationManager` flag is meaningless to CLLocationManager and the
  /// wrong settings class can degrade the cold-start fix the location
  /// publisher depends on.
  final bool _isIOS;

  /// Latest position delivered by the unified stream ([getLocationStream]).
  ///
  /// Served by [getCurrentLocation] while fresher than
  /// [kStreamPositionMaxAge] so publish cycles never depend on the one-shot
  /// `getCurrentPosition` path while the app is backgrounded on iOS — the
  /// plugin's one-time CLLocationManager hard-codes
  /// `allowsBackgroundLocationUpdates = NO`, so a backgrounded one-shot can
  /// only stall for [kOneShotLocationTimeout] and fall back anyway.
  ///
  /// ## The cache must never outlive the user's access
  ///
  /// [kStreamPositionMaxAge] is a FRESHNESS bound, never a consent bound: a
  /// fix that is 10 s old is still the user's live position, and publishing
  /// it after access was withdrawn is a privacy defect, not a staleness
  /// one. Two independent rules keep the two aligned:
  ///
  /// 1. **Gated read.** [getCurrentLocation] serves this field only after
  ///    [_ensureAccessOrThrow] has confirmed, on that same call, that the
  ///    location provider is on and the permission is an affirmative grant,
  ///    and — on Android, where a grant is not the whole answer — after
  ///    [_platformStillPermitsLocation] has confirmed the platform still
  ///    serves this app a position at all. The gate runs BEFORE the cache
  ///    read, before the iOS-backgrounded `getLastKnownPosition` branch,
  ///    and before the one-shot.
  /// 2. **Eager invalidation.** Every observation of lost access clears
  ///    this field immediately via [_noteAccessLost] instead of letting it
  ///    age out: the [getCurrentLocation]/[getCurrentLocationFresh] gate,
  ///    the public [checkPermission]/[isLocationServiceEnabled]/
  ///    [requestPermission] reads, and a [getLocationStream] error or
  ///    close. Clearing (not merely bypassing) is what stops a later
  ///    re-grant from resurrecting a coordinate captured before the denial.
  /// 3. **Precision is part of access.** A user who switches the app to
  ///    approximate location has withdrawn consent to precise
  ///    coordinates, and this field may be holding one. The gate treats
  ///    that transition as an access loss too — see
  ///    [_lastAccuracyStatus].
  ///
  /// Also cleared via [clearCachedPosition] on logout and on
  /// background-sharing opt-out.
  Position? _lastStreamPosition;

  /// Last location-accuracy authorization this service observed, or null
  /// before the first gated call.
  ///
  /// `whileInUse` + approximate is a first-class user choice on both
  /// platforms (iOS: "Precise Location" off; Android: COARSE granted
  /// while FINE is revoked — geolocator's `checkPermissionStatus` breaks
  /// out of its loop on EITHER, so it still reports `whileInUse`). The
  /// permission read therefore cannot see it, but the cache can be
  /// holding a fix captured while the grant was still precise, and
  /// publishing that after the downgrade re-opens exactly the defect the
  /// gate exists to close — one coordinate class narrower.
  ///
  /// The rule the gate applies is asymmetric on purpose:
  /// **serve the cache only when the current authorization is not
  /// `reduced`, or when the previous observation was already `reduced`.**
  /// - `precise → reduced` is the downgrade — the cache is dropped.
  /// - `null → reduced` is dropped too. [getLocationStream] fills the
  ///   cache without running the gate, so on the first gated call a warm
  ///   cache has UNKNOWN provenance; assuming it was captured under the
  ///   current reduced grant would be the optimistic assumption, and this
  ///   is not a place for one. The cost is one extra one-shot per
  ///   process for approximate-mode users.
  /// - `reduced → reduced` is steady state and serves normally, so an
  ///   approximate-mode user does not pay a one-shot every tick.
  /// - `reduced → precise` is an UPGRADE, never a loss.
  ///
  /// [geo.LocationAccuracyStatus.unknown] is ignored entirely (neither
  /// compared nor recorded): it means "no information", and the baseline
  /// must survive it. Recording it could not create a false negative — the
  /// comparison is against `reduced`, so an `unknown` baseline still trips
  /// the next genuine downgrade — but it WOULD create a false positive: it
  /// would destroy a settled `reduced` baseline, so the very next reduced
  /// read would look like a fresh downgrade and drop a cache captured
  /// under the same authorization. That is a spurious one-shot per
  /// `unknown`, not a leak; ignoring the value is simply the reading that
  /// costs nothing in either direction.
  ///
  /// Neither mobile plugin emits it — iOS reads `CLLocationManager
  /// .accuracyAuthorization` (precise/reduced only) and Android maps a
  /// two-value enum — so this is defence against a platform we do not
  /// ship, not a live path.
  geo.LocationAccuracyStatus? _lastAccuracyStatus;

  /// Whether the app UI is currently foregrounded.
  ///
  /// A plain synchronous in-memory seam set by `map_shell.dart`'s
  /// `didChangeAppLifecycleState` (paused → false, resumed → true; the
  /// transient `inactive`/`hidden` states are deliberately not distinct for
  /// this purpose). Defaults to `true` so a freshly constructed instance
  /// (cold start, tests, the Android FGS isolate) behaves as foreground.
  ///
  /// Two consumers:
  /// - [getCurrentLocation]'s iOS branch, to avoid a doomed backgrounded
  ///   one-shot;
  /// - [_ensureAccessOrThrow], which must never raise a permission PROMPT
  ///   from a non-interactive context (see the class doc).
  ///
  /// The default matters differently for each. For the prompt gate,
  /// defaulting to `true` is the fail-open direction, and it is load-
  /// bearing only in the Android foreground-service isolate, which never
  /// receives the lifecycle callback. That isolate is safe by platform
  /// accident rather than by this flag: Android's
  /// `PermissionManager.requestPermission` reports `activityMissing`
  /// straight away, so the future completes with an error instead of
  /// hanging. iOS — the platform whose prompt can hang forever — has no
  /// second isolate: its background publishing runs in this one, where
  /// `map_shell.dart` sets the flag `false` on pause.
  bool _foregroundActive = true;

  /// Sets the foreground-active hint consulted by [_ensureAccessOrThrow], and
  /// tells the iOS session which accuracy profile it may run at.
  ///
  /// Backgrounding starts the stationary dwell; foregrounding returns the
  /// session to Best at once. Both are property writes on a running manager —
  /// nothing is restarted, nothing is published, no socket is opened.
  // ignore: avoid_setters_without_getters
  set foregroundActive(bool value) {
    _foregroundActive = value;
    _iosSource.onForeground(foregrounded: value);
  }

  /// The outer stream handed to the newest [getLocationStream] caller.
  ///
  /// One controller PER CALL, never one per service: Riverpod cancels the
  /// outer on every toggle rebuild and the deferred rebuild asks for a new
  /// one, so a shared single-subscription controller would throw
  /// `StateError: Stream has already been listened to` on the second listen.
  StreamController<Position>? _outer;

  /// The plugin subscription feeding [_outer], or null while suspended.
  ///
  /// Released by [suspendStream], by [_outer]'s `onCancel`, and by the next
  /// [getLocationStream] call — none of which the `cancel_subscriptions` lint
  /// recognises, since it only looks for a `dispose()`.
  // ignore: cancel_subscriptions
  StreamSubscription<Position>? _inner;

  /// Whether [_inner] has reported an error since it was created.
  ///
  /// An errored plugin subscription delivers nothing further, and while the
  /// app is paused the access watchdog's recovery `invalidate` is suppressed
  /// — so [resumeStream] is the only thing that can replace it.
  bool _innerFailed = false;

  /// The background-sharing intent [_outer] was created with, so a
  /// [resumeStream] restart asks the iOS session for the same background
  /// capability rather than the parameter default.
  bool _streamBackgroundSharing = false;

  /// The Android profile [_outer] was created with, for the same reason: a
  /// restart that reverted to the default would put the map's 1 Hz
  /// registration behind a backgrounded foreground service.
  AndroidStreamProfile _streamProfile = const AndroidStreamProfile.foreground();

  /// Releases the platform position subscription without ending the stream
  /// its subscribers hold.
  ///
  /// Called directly (never through a provider rebuild) from the pause
  /// handler: a watched-provider write cancels the old subscription at once
  /// but defers the REBUILD to a frame, and frames are off while paused, so
  /// a release that rides a rebuild happens at RESUME. Synchronous by
  /// construction — the pause handler must not depend on anything running
  /// after it returns.
  ///
  /// Cancel, not close: neither [_noteAccessLost] handler fires, so the
  /// consent-bounded cache survives the pause (the caller clears it
  /// separately when the user has not consented to background sharing).
  ///
  /// A no-op when the current outer has no listener — nothing is being
  /// delivered to anybody, so there is nothing to release.
  void suspendStream() {
    final outer = _outer;
    final inner = _inner;
    if (outer == null || inner == null || !outer.hasListener) return;
    _inner = null;
    unawaited(inner.cancel());
  }

  /// Re-establishes the platform position subscription for the current
  /// outer stream, with the settings that outer was created with.
  ///
  /// The ONLY restart site, and foregrounded by construction (it is called
  /// from the resume handler): iOS refuses to start a background-capable
  /// location session from the background, which is what the 2026-08-20
  /// field failure was.
  ///
  /// A no-op when the current outer has no listener, and when its
  /// subscription is still alive — the iOS background-sharing branch never
  /// suspends, and restarting that session on every resume would tear down
  /// the keep-alive holding the process executable. An inner that ERRORED is
  /// not alive: it delivers nothing further, so it is replaced.
  void resumeStream() {
    final outer = _outer;
    if (outer == null || outer.isClosed || !outer.hasListener) return;
    final inner = _inner;
    if (inner != null && !_innerFailed) return;
    _inner = null;
    if (inner != null) unawaited(inner.cancel());
    _listenInner(outer);
  }

  /// The platform permission request currently in flight, if any.
  ///
  /// Exactly one may exist at a time, because a SECOND simultaneous request
  /// strands a caller forever. Android's `Activity.requestPermissions`
  /// refuses one while another is pending — it logs "Can request only one
  /// set of permissions at a time" and dispatches an EMPTY grant result,
  /// which geolocator's `PermissionManager.onRequestPermissionsResult`
  /// drops without invoking either callback. The second call has meanwhile
  /// overwritten the single `resultCallback` slot the plugin keeps, so when
  /// the real answer arrives it goes to the LAST caller and the first
  /// caller's `FlutterResult` is never invoked: its Dart future never
  /// completes. Observed in CI — a publish tick and a one-shot read raced
  /// with the permission revoked, and the loser hung for the rest of the
  /// process while the winner got its answer.
  ///
  /// Coalescing is also the only bound that stays honest with a REAL
  /// prompt on screen: a user who has not answered yet must keep every
  /// waiting caller waiting, which is why this is a shared future and not
  /// a `.timeout()` (see the prompt discussion in [_ensureAccessOrThrow]).
  Future<geo.LocationPermission>? _permissionRequestInFlight;

  /// Asks the platform for the location permission, at most one request at
  /// a time; concurrent callers await the same answer.
  ///
  /// The single entry point for both prompting paths — the gate's `denied`
  /// branch and the public [requestPermission] onboarding calls — so a
  /// prompt raised by one can never be cancelled by the other.
  Future<geo.LocationPermission> _requestPermission() {
    final inFlight = _permissionRequestInFlight;
    if (inFlight != null) return inFlight;

    final request = _geolocator.requestPermission();
    _permissionRequestInFlight = request;
    return request.whenComplete(() => _permissionRequestInFlight = null);
  }

  /// Clears the cached stream position.
  ///
  /// Called on logout (`deleteIdentity`) and when background sharing is
  /// disabled, so plaintext coordinates never outlive the session intent
  /// that produced them (mirrors `LocationSharingService.wipeAll`'s
  /// cache-wiping posture). Access-loss invalidation goes through
  /// [_noteAccessLost], which adds the presence-only log line.
  ///
  /// Clears the NATIVE copy too: on iOS the last Best fix also lives in the
  /// stream handler's memory, and a coordinate that merely moved across the
  /// channel boundary has not been dropped.
  void clearCachedPosition() {
    _lastStreamPosition = null;
    unawaited(_iosSource.clearLastBestFix());
  }

  /// Whether a fix younger than [kStreamPositionMaxAge] is already in hand.
  ///
  /// The Android foreground service asks this before deciding whether its
  /// cycle needs an acquisition at all; [now] is injectable so the boundary
  /// is testable exactly.
  ///
  /// FRESHNESS, never consent. A `true` authorises nothing: whether the fix
  /// may be produced is still decided per call by [_ensureAccessOrThrow] (and
  /// on Android by [_platformStillPermitsLocation]) inside
  /// [getCurrentLocation]. It reads the same field those paths clear, so it
  /// can never report a fix that outlived its consent — but a caller must
  /// never treat it as permission to skip them.
  ///
  /// It answers from memory: no platform read, and no coordinate leaves.
  bool hasFreshStreamFix({DateTime Function()? now}) {
    final fix = _lastStreamPosition;
    return fix != null && _streamFixIsFresh(fix, (now ?? DateTime.now)());
  }

  /// The one freshness rule, shared by [hasFreshStreamFix] and the cache read
  /// in [getCurrentLocation] so the predicate cannot disagree with what the
  /// read will actually serve.
  ///
  /// Measured on the GPS fix time ([Position.timestamp]) rather than a
  /// Dart-side arrival stamp: a chipset can hand over a fix it took minutes
  /// ago, and it is the fix — not the delivery — that gets published — or,
  /// where one exists, on the later instant at which that fix was CONFIRMED to
  /// still describe where the device is ([_lastFixConfirmedAt]).
  ///
  /// Two clauses, because a confirmation may EXTEND the window but may not
  /// remove it: the confirmed age is bounded by [kStreamPositionMaxAge] as
  /// before, and the fix's own age by [kStationaryAnchorMaxAge] however many
  /// confirmations have arrived (OD-P3-e). The second clause is slack whenever
  /// nothing confirms — 168 s is then the tighter bound — so Android, where
  /// nothing ever confirms, decides exactly as it always did.
  ///
  /// This is the SERVING half of that cap. `IosProfileController` escalates at
  /// the same bound to go and take a real fix, but that escalation is carried
  /// by a delivery or a timer, and neither is guaranteed to have run before the
  /// next publish reads this. Both halves read the one constant, so the bound
  /// cannot be enforced in two places at two values.
  bool _streamFixIsFresh(Position fix, DateTime now) =>
      now.difference(_lastFixConfirmedAt ?? fix.timestamp) <=
          kStreamPositionMaxAge &&
      now.difference(fix.timestamp) <= kStationaryAnchorMaxAge;

  /// When the cached fix was last confirmed still to be where the device is,
  /// or null when nothing has confirmed it since it was taken.
  ///
  /// iOS only, and only while a cached fix exists. While the session is
  /// stationary at the 100 m tier it delivers no publishable fix at all, so
  /// without this the cached Best coordinate would age out every
  /// [kStreamPositionMaxAge] and a motionless user would pay a fresh GPS
  /// acquisition to learn they had not moved. A confirming fix is one no
  /// coarser than [kStationaryConfirmMaxAccuracyMeters] taken within
  /// [kMotionTriggerDistanceMeters] of the anchor — see
  /// [IosProfileController] for the rule and the 200 m bound it buys.
  ///
  /// It extends the window; it does not remove it. [_streamFixIsFresh] caps the
  /// fix's own age at [kStationaryAnchorMaxAge] whatever this reads, so a
  /// confirmation chain — including one a systematically biased coarse fix is
  /// keeping alive — can never make a coordinate publishable indefinitely.
  ///
  /// It cannot outlive the coordinate it vouches for: it is read only from
  /// [_streamFixIsFresh], which is only ever reached with one of the two
  /// copies of that coordinate in hand, and every observation of lost access
  /// drops both (along with the anchor the confirmation is measured against,
  /// which is what nulls this). The native session resets its own confirmation
  /// whenever the stream ends. On Android nothing confirms and this is always
  /// null, which is the behaviour that shipped before the iOS session existed.
  DateTime? get _lastFixConfirmedAt =>
      _isIOS ? _iosSource.lastConfirmedAt : null;

  /// Drops the cached fix the instant location access is observed to be
  /// gone, rather than letting it age out of [kStreamPositionMaxAge].
  ///
  /// The age window is 168 s; without this, every path that learns access
  /// ended would still hand out the user's last position for the rest of
  /// that window. [reason] is presence-only diagnostic text — never a
  /// coordinate, and never surfaced to the user (Security Rule 8).
  ///
  /// The native iOS copy goes first, and unconditionally: it is a separate
  /// full-precision coordinate that this method has already emptied the Dart
  /// side of on an earlier call, so gating it on the Dart cache would leave it
  /// behind exactly when the loss repeats.
  void _noteAccessLost(String reason) {
    unawaited(_iosSource.clearLastBestFix());
    if (_lastStreamPosition == null) return;
    _lastStreamPosition = null;
    debugPrint('[Location] access lost ($reason) — cached fix dropped');
  }

  /// Confirms the user still has location access, and reports whether the
  /// permission is an affirmative grant.
  ///
  /// Callers MUST await this before producing any position — cached,
  /// last-known or fresh. Returns `true` only for `whileInUse`/`always`
  /// (and only after [_noteAccuracyDowngrade] has had its say), the sole
  /// state in which a stored coordinate may be served. Throws
  /// [LocationServiceException] when access is definitely gone, having
  /// first cleared the cache.
  ///
  /// Returns `false` for `unableToDetermine` — not evidence of loss (so
  /// the cache is left alone) but not consent either (so no stored
  /// coordinate may be served). The caller then falls through to the
  /// one-shot chain, and the line that actually needs justifying is that
  /// chain's FALLBACK: `getLastKnownPosition()`, which is a STORED
  /// coordinate, not the live read this comment used to appeal to. It is
  /// safe because it is natively permission-gated on both platforms —
  /// geolocator's iOS `onGetLastKnownPosition` returns
  /// `permissionDenied` unless `[PermissionHandler hasPermission]`, and
  /// its Android twin refuses on `!permissionManager.hasPermission` — so
  /// neither can hand back a coordinate the OS has not authorised.
  ///
  /// That arm is unreachable on mobile by construction: the platform
  /// interface's own enum documents `unableToDetermine` as web-only, and
  /// both mobile mappers can emit nothing else — iOS folds `notDetermined`
  /// and `restricted` into `denied` (Dart index 0), and Android's
  /// `checkPermissionStatus` returns only denied/whileInUse/always. It is
  /// kept because the enum is exhaustive and the safe answer here is not
  /// the one a `default:` would give.
  ///
  /// A platform-channel failure propagates as-is. That still fails closed
  /// for the call in progress (it aborts before any position is produced),
  /// but it is deliberately not treated as a consent loss: an errored
  /// channel is not an observation that the user revoked anything.
  ///
  /// ## No prompting from the background
  ///
  /// The `denied` branch prompts only while [_foregroundActive]. On iOS
  /// `denied` also covers `notDetermined` (the mapper folds both to Dart
  /// index 0), and in that state geolocator calls
  /// `requestWhenInUseAuthorization` and waits on
  /// `didChangeAuthorizationStatus` — which early-returns on
  /// `notDetermined`. iOS defers the alert while the app is backgrounded,
  /// so the delegate never reports anything else, the `FlutterResult` is
  /// never invoked and the Dart future NEVER COMPLETES. That hang used to
  /// be unreachable from the publish path (a warm cache short-circuited
  /// ahead of the permission read); putting the gate first made it
  /// reachable, and one hung await wedges the per-circle publish chain for
  /// the rest of the process. Skipping the prompt leaves `permission ==
  /// denied`, which falls into the throwing branch below — the same
  /// outcome as a refused prompt, i.e. fail closed, not fail open.
  ///
  /// A `.timeout()` on the prompt was the alternative and is worse: a
  /// prompt the user simply has not answered yet is indistinguishable
  /// from a hang, so any bound short enough to rescue the chain is also
  /// short enough to turn a deliberating user into a spurious denial.
  ///
  /// ## Cost
  ///
  /// Three platform-channel round trips per granted call (two on a
  /// denial), added to a path that previously short-circuited on a warm
  /// cache. Accepted rather than memoised behind a TTL, because:
  /// - the call rate is low — [getCurrentLocation] runs once per publish
  ///   tick per circle (each circle on its own 72–168 s jittered
  ///   schedule), plus a map recenter tap;
  /// - the permission pair already ran on every cache MISS, on every
  ///   [getCurrentLocationFresh], and `map_page` already calls
  ///   [isLocationServiceEnabled] before each `_getLocation`, so this is
  ///   at worst a small multiple of a cost the app already pays several
  ///   times a minute;
  /// - all three platform sides are cheap in-memory reads
  ///   (`CLLocationManager`'s `authorizationStatus` and
  ///   `accuracyAuthorization` are properties; Android's are
  ///   `checkSelfPermission` calls), not GPS acquisition;
  /// - a TTL memo would re-create the very hole being closed — a window,
  ///   however short, in which a revoked permission still yields a
  ///   position. A privacy gate that is sometimes skipped is a gate with a
  ///   documented bypass.
  ///
  /// ## What this canNOT see
  ///
  /// The Android app-op, and only that. Every read this method makes goes
  /// to the permission GRANT via `ContextCompat.checkSelfPermission` —
  /// `checkPermission()` and `getLocationAccuracy()` alike — and none of
  /// them consults the app-op, so a denial applied with
  /// `cmd appops set --uid PKG android:fine_location deny` still reads as
  /// "granted, precise" here. It is caught one level up instead, at the
  /// only place a stored coordinate can be produced without a live
  /// platform read: [_platformStillPermitsLocation], which guards the
  /// cache read in [getCurrentLocation].
  ///
  /// Precision downgrade — the other hole this doc once omitted, and the
  /// one that is a first-class Settings toggle rather than an adb trick —
  /// IS now seen, via [_noteAccuracyDowngrade].
  Future<bool> _ensureAccessOrThrow() async {
    final serviceEnabled = await _geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      _noteAccessLost('location services disabled');
      throw LocationServiceException(
        'Location services are disabled. Please enable location services.',
      );
    }

    var permission = await _geolocator.checkPermission();
    if (permission == geo.LocationPermission.denied) {
      // Access is gone as of this read; whether the user re-grants it in
      // the prompt below does not retroactively re-authorise the fix that
      // is sitting in the cache, so drop it before asking.
      _noteAccessLost('permission read denied');
      if (_foregroundActive) {
        permission = await _requestPermission();
      } else {
        // Backgrounded: never raise a prompt (see the doc above). Leave
        // `permission` denied so the switch throws — fail closed.
        debugPrint(
          '[Location] permission read denied while backgrounded — '
          'not prompting; treating as denied',
        );
      }
    }

    switch (permission) {
      case geo.LocationPermission.whileInUse:
      case geo.LocationPermission.always:
        await _noteAccuracyDowngrade();
        return true;
      case geo.LocationPermission.denied:
        _noteAccessLost('permission denied');
        throw LocationServiceException('Location permission denied');
      case geo.LocationPermission.deniedForever:
        // Reached both from a direct `deniedForever` read and from the
        // prompt above. The direct read previously fell through to the
        // one-shot, which then failed into `getLastKnownPosition` — i.e.
        // the hardest denial the OS offers produced a coordinate anyway.
        _noteAccessLost('permission denied forever');
        throw LocationServiceException(
          'Location permission denied forever. Please enable in settings.',
        );
      case geo.LocationPermission.unableToDetermine:
        // Web-only in practice (see the doc above): no consent, but no
        // evidence of loss either, so the cache is left intact and merely
        // withheld. Never `true` — that would serve a stored coordinate on
        // an unknown authorization.
        return false;
    }
  }

  /// Clears the cached fix when the user has narrowed the grant from
  /// precise to approximate coordinates.
  ///
  /// Called only from the granted arm of [_ensureAccessOrThrow]: the read
  /// is meaningless without a permission (and Android's implementation
  /// answers with a `permissionDenied` platform error when neither FINE
  /// nor COARSE is held, which would turn a clean denial into a channel
  /// exception). See [_lastAccuracyStatus] for why the comparison is
  /// asymmetric and why `null` counts as "not reduced".
  ///
  /// A failure of the accuracy read propagates, matching the gate's
  /// existing posture for a broken platform channel: the call aborts
  /// before any coordinate is produced. The error is deliberately NOT
  /// classified — on Android the only thing that raises it is a
  /// permission that vanished between the two reads, and inspecting the
  /// message to decide would be reading platform-authored prose to make a
  /// privacy decision.
  Future<void> _noteAccuracyDowngrade() async {
    final accuracy = await _geolocator.getLocationAccuracy();
    if (accuracy == geo.LocationAccuracyStatus.unknown) return;
    if (accuracy == geo.LocationAccuracyStatus.reduced &&
        _lastAccuracyStatus != geo.LocationAccuracyStatus.reduced) {
      _noteAccessLost('precise location downgraded to approximate');
    }
    _lastAccuracyStatus = accuracy;
  }

  /// Whether the platform will still hand this app a position — the only
  /// check that can see an Android app-op denial.
  ///
  /// Always `true` on iOS, which has no app-op: every withdrawal it offers
  /// (an authorization change, Precise Location off) is already visible to
  /// [_ensureAccessOrThrow], so the extra round trip would be pure cost on
  /// the backgrounded publish path — the one path with no alternative
  /// position source.
  ///
  /// On Android `cmd appops set --uid PKG android:fine_location deny` leaves
  /// the GRANT intact, so the gate above reads "granted, precise", and —
  /// unlike `pm revoke` — it does not kill the process. AOSP then drops
  /// deliveries: `LocationProviderManager.Registration.acceptLocationChange`
  /// bails when `AppOpsHelper.noteOpNoThrow` returns false, with no
  /// guaranteed stream error or close, so the handlers on
  /// [getLocationStream] that would call [_noteAccessLost] cannot be relied
  /// on to fire. Without this check the cached fix would go on being
  /// published for the rest of [kStreamPositionMaxAge] after the user
  /// withdrew access.
  ///
  /// The scope matters: `AppOpsService` returns a non-default UID mode
  /// without ever consulting the package mode, and a `whileInUse` grant
  /// leaves the UID mode at `foreground`, so a package-scoped `deny` is a
  /// no-op for a foregrounded app. That is a property of the tooling that
  /// reproduces the state, not of this check — the check reads the platform,
  /// not the app-op.
  ///
  /// `getLastKnownPosition()` is the one Dart-reachable read the app-op
  /// DOES gate: `LocationProviderManager.getLastLocation` returns null on
  /// the same `noteOpNoThrow` denial, and geolocator maps a null `Location`
  /// to a null `Position` (`LocationMapper.toHashMap`). A null answer is
  /// the platform saying this app may not hold a position right now, which
  /// is exactly what the cache read needs to know. It cannot misfire on a
  /// device that merely has no fix yet: reaching here means the stream
  /// delivered one within [kStreamPositionMaxAge], so the provider's own
  /// last-known is set.
  ///
  /// A failing platform channel returns `false` WITHOUT clearing the cache,
  /// mirroring the gate's `unableToDetermine` rule: not evidence that
  /// access ended, so the fix is kept, but not consent either, so it may
  /// not be served.
  ///
  /// A provider toggle (off then back on) DOES clear that provider's
  /// framework-level last-known cache, which could otherwise look like this
  /// exact false positive. It cannot reach here stale, though: toggling the
  /// provider [getLocationStream] is actively subscribed to fires
  /// `onProviderDisabled` on the SAME event, which geolocator turns into a
  /// stream error — clearing [_lastStreamPosition] via [_noteAccessLost]
  /// before this method would ever be called with a now-stale cache to
  /// corroborate. `getLastKnownPosition()` also polls every ENABLED
  /// provider, not only the streamed one, for the same reason.
  ///
  /// ## Cost
  ///
  /// One extra platform-channel round trip on Android, on every call that
  /// would otherwise be a pure in-memory cache hit — i.e. most publish
  /// ticks, the case this cache exists to make cheap. Accepted for the same
  /// reasons as [_ensureAccessOrThrow]'s cost analysis: the call rate is one
  /// per circle's 72–168 s tick (plus a map recenter), and the platform side
  /// is an in-memory `LocationManager.getLastKnownLocation` read per
  /// provider, not a GPS acquisition.
  Future<bool> _platformStillPermitsLocation() async {
    if (_isIOS) return true;
    geo.Position? lastKnown;
    try {
      lastKnown = await _geolocator.getLastKnownPosition();
    } on Exception catch (e) {
      debugPrint('[Location] last-known probe failed: ${e.runtimeType}');
      return false;
    }
    if (lastKnown != null) return true;
    _noteAccessLost('platform withheld the last known fix (Android app-op)');
    return false;
  }

  /// Builds the [geo.LocationSettings] for a one-shot position read,
  /// platform-correct: [geo.AppleSettings] on iOS, [geo.AndroidSettings]
  /// (forcing the platform LocationManager to bypass Google Play Services)
  /// elsewhere. Both use best accuracy and the cold-fix
  /// [kOneShotLocationTimeout].
  geo.LocationSettings _currentPositionSettings() {
    if (_isIOS) {
      // Accuracy defaults to LocationAccuracy.best.
      return geo.AppleSettings(timeLimit: kOneShotLocationTimeout);
    }
    return geo.AndroidSettings(
      forceLocationManager: true, // Bypass Google Play Services
      timeLimit: kOneShotLocationTimeout,
    );
  }

  /// Builds the [geo.AndroidSettings] for the single continuous stream.
  ///
  /// **Android only.** iOS never reaches here: its session belongs to
  /// `HavenLocationStreamHandler`, which applies its own shape — no distance
  /// filter, auto-pause off, and one of exactly two accuracy tiers — natively,
  /// where those properties are actually set. (The `distanceFilter: -1`
  /// workaround geolocator's pointer-comparing distance mapper used to need
  /// went with it; do not reintroduce the constant.)
  ///
  /// [profile] selects the arm (see [AndroidStreamProfile]); no arm names an
  /// accuracy, so both inherit the plugin default `best`, which geolocator
  /// maps to `LocationRequest.QUALITY_HIGH_ACCURACY`.
  geo.LocationSettings _streamSettings({
    required AndroidStreamProfile profile,
  }) {
    return switch (profile) {
      ForegroundStreamProfile() => geo.AndroidSettings(
        distanceFilter: 1, // Update when device moves 1+ meter for precision
        forceLocationManager: true, // Bypass Google Play Services
        // Maximum update frequency.
        intervalDuration: const Duration(seconds: 1),
      ),
      BackgroundServiceStreamProfile(:final interval) => geo.AndroidSettings(
        // Explicit despite matching the plugin default: the publish is due
        // on TIME, so any filter here suppresses the very fix the cycle is
        // waiting for while the device sits still.
        // ignore: avoid_redundant_argument_values
        distanceFilter: 0,
        forceLocationManager: true, // Bypass Google Play Services
        intervalDuration: interval, // The provider duty-cycles GNSS on this
      ),
    };
  }

  @override
  Future<Position> getCurrentLocation() async {
    // ACCESS GATE FIRST — nothing below may produce a coordinate (cached,
    // last-known or fresh) until the platform has confirmed on THIS call
    // that the user still has location access. These checks used to sit
    // below the two shortcuts, so a warm cache or a backgrounded
    // last-known read kept publishing for up to [kStreamPositionMaxAge]
    // after the permission or the provider was gone. See
    // [_ensureAccessOrThrow] for the cost analysis and for the Android
    // app-op residual this gate cannot see.
    final granted = await _ensureAccessOrThrow();

    if (granted) {
      // Serve the unified stream's latest fix while fresh — measured
      // against the GPS fix time (`Position.timestamp`), not a Dart-side
      // clock. This is the ONLY publish-path GPS source that works while
      // backgrounded on iOS (see [_lastStreamPosition]).
      //
      // Freshness is not consent, and on Android the gate above cannot
      // see an app-op denial, so serving is conditional on the platform
      // still answering a live position read as well —
      // [_platformStillPermitsLocation].
      final cached = _lastStreamPosition;
      if (cached != null &&
          _streamFixIsFresh(cached, DateTime.now()) &&
          await _platformStillPermitsLocation()) {
        return cached;
      }

      // Backgrounded on iOS: the one-shot below cannot deliver (its
      // CLLocationManager never enables background updates) — serve the
      // native owner's last Best fix, or REFUSE.
      //
      // The refusal is the point, and it is structural: this branch never
      // falls through. `INV-L-IOS-WAKES-RECEIVE-ONLY` says a process
      // relaunched into the background cannot publish, and a fall-through
      // made that a coincidence rather than a rule — on a post-termination
      // SLC/region/BGTask relaunch both caches are empty BY DESIGN, so
      // "no cached fix" was exactly the state that reached the one-shot.
      //
      // The lifecycle is read from the NATIVE session, not from
      // [_foregroundActive]: a background-launched process (an SLC/region
      // relaunch, which builds this service before any lifecycle callback)
      // would otherwise look foregrounded and start a one-shot that cannot
      // complete. An unreadable status counts as backgrounded — fail closed.
      if (_isIOS && (await _iosSource.status()).backgrounded) {
        Position? lastPosition;
        try {
          lastPosition = await _getLastKnownPosition();
        } on Exception catch (e) {
          // Presence-only logging; never log coordinates.
          debugPrint(
            '[Location] backgrounded last-known lookup failed: '
            '${e.runtimeType}',
          );
        }
        if (lastPosition != null) return lastPosition;
        throw LocationServiceException(
          'Location unavailable while Haven is in the background.',
        );
      }
    }

    // Get location with best accuracy (default)
    try {
      final geoPosition = await _geolocator.getCurrentPosition(
        locationSettings: _currentPositionSettings(),
      );
      return _convertPosition(geoPosition);
    } on Exception catch (e) {
      // Fallback to last known position if fresh position unavailable
      try {
        final lastPosition = await _getLastKnownPosition();
        if (lastPosition != null) {
          return lastPosition;
        }
      } on Exception {
        // Ignore error from the last-known read
      }

      debugPrint('Failed to get location: ${e.runtimeType}');
      throw LocationServiceException(
        'Failed to get location. '
        'Please ensure location services are enabled.',
      );
    }
  }

  @override
  Future<Position> getCurrentLocationFresh() async {
    // Same access gate as [getCurrentLocation] (it also clears the cached
    // fix on a denial, so a fresh read that discovers the loss invalidates
    // the coordinate the cached path would otherwise still serve).
    await _ensureAccessOrThrow();

    // Force a fresh GPS read with best accuracy (default)
    // NO fallback to cached data
    try {
      final geoPosition = await _geolocator.getCurrentPosition(
        locationSettings: _currentPositionSettings(),
      );
      return _convertPosition(geoPosition);
    } on Object catch (e) {
      debugPrint('Failed to get fresh location: ${e.runtimeType}');
      throw LocationServiceException(
        'Failed to get fresh location. '
        'Please ensure location services are enabled.',
      );
    }
  }

  /// Returns the single continuous position stream.
  ///
  /// [backgroundSharingEnabled] reaches the iOS session's
  /// `allowsBackgroundLocationUpdates` unchanged; it is ignored on Android,
  /// where background publishing is the foreground service's job.
  /// [profile] selects the Android registration and is ignored on iOS; it
  /// defaults to the map's foreground one, so only the foreground service
  /// ever names it. Adding optional named parameters to the parameterless
  /// [LocationService.getLocationStream] contract is a legal override —
  /// interface-typed callers are unaffected; `locationStreamProvider`
  /// passes the toggle state through the concrete type.
  ///
  /// Every emission is teed into [_lastStreamPosition] so
  /// [getCurrentLocation] can serve a warm fix without a one-shot request.
  ///
  /// The end of the stream is the other half of that deal: an error (the
  /// platform's way of reporting a disabled provider or a revoked
  /// permission mid-stream) or a close means no further fix will arrive,
  /// so the teed coordinate is dropped immediately rather than being
  /// served for the rest of [kStreamPositionMaxAge]. Errors are still
  /// forwarded to subscribers unchanged. Cancelling a subscription — what
  /// a `locationStreamProvider` rebuild does — fires neither handler, so a
  /// settings flip keeps the warm fix (and the provider clears it
  /// explicitly on the background-sharing opt-out branch).
  ///
  /// The returned stream is an outer controller owned by this service, so
  /// [suspendStream] and [resumeStream] can swap the platform subscription
  /// underneath it without ending it. One controller per call (see [_outer]);
  /// a new call releases the previous call's platform subscription.
  @override
  Stream<Position> getLocationStream({
    bool backgroundSharingEnabled = false,
    AndroidStreamProfile profile = const AndroidStreamProfile.foreground(),
  }) {
    // The previous outer is expected to be GONE by now: Riverpod cancels it
    // before it rebuilds, and that cancel nulls `_outer`. A live one here
    // would be a subscriber holding a stream this call is about to orphan —
    // it would never receive another fix and never end, because only the
    // current outer's `onCancel` releases anything.
    assert(
      _outer == null || !_outer!.hasListener,
      'getLocationStream replaced an outer stream that still has a listener',
    );
    final previous = _inner;
    _inner = null;
    if (previous != null) unawaited(previous.cancel());

    // `sync: true` is the documented-safe case (events are only ever added
    // from another stream's callbacks) and it keeps the forwarding
    // synchronous, exactly as the `.map()`/`.transform()` chain this replaced
    // was: an async controller inserts a microtask between the platform fix
    // and every subscriber, which is one turn for a rebuild to cancel the
    // subscription in and lose the fix.
    final outer = StreamController<Position>(sync: true);
    _outer = outer;
    _streamBackgroundSharing = backgroundSharingEnabled;
    _streamProfile = profile;
    outer.onCancel = () {
      // Only the CURRENT outer owns the fields; a late cancellation of a
      // superseded one must not release the live subscription.
      if (!identical(_outer, outer)) return null;
      final inner = _inner;
      _inner = null;
      _outer = null;
      return inner?.cancel();
    };
    _listenInner(outer);
    return outer.stream;
  }

  /// Subscribes the single platform position stream — Haven's own session on
  /// iOS, geolocator's on Android — and pipes it into [outer].
  ///
  /// The one routing site, because [resumeStream] has to re-subscribe with the
  /// same intent the outer was created with.
  void _listenInner(StreamController<Position> outer) {
    _innerFailed = false;
    final backgroundSharingEnabled = _streamBackgroundSharing;
    final source = _isIOS
        ? _iosSource.positions(
            allowsBackgroundLocationUpdates: backgroundSharingEnabled,
          )
        : _geolocator
              .getPositionStream(
                locationSettings: _streamSettings(profile: _streamProfile),
              )
              .map(_convertPosition);
    _inner = source
        .listen(
          (position) {
            _lastStreamPosition = position;
            outer.add(position);
          },
          onError: (Object error, StackTrace stackTrace) {
            _innerFailed = true;
            _noteAccessLost('position stream error: ${error.runtimeType}');
            outer.addError(error, stackTrace);
          },
          onDone: () {
            _inner = null;
            _noteAccessLost('position stream closed');
            unawaited(outer.close());
          },
        );
  }

  @override
  Future<bool> isLocationServiceEnabled() async {
    final enabled = await _geolocator.isLocationServiceEnabled();
    if (!enabled) {
      // Observing the provider switched off is an access loss wherever it
      // is observed, not only inside [_ensureAccessOrThrow] — `map_page`
      // calls this directly before each `_getLocation`.
      _noteAccessLost('location services disabled');
    }
    return enabled;
  }

  @override
  Future<bool> requestPermission() async {
    final permission = await _requestPermission();
    final granted =
        permission == geo.LocationPermission.whileInUse ||
        permission == geo.LocationPermission.always;
    if (!granted) {
      // An explicit request that did not come back granted is a definite
      // "no" for the coordinate already in hand.
      _noteAccessLost('permission request not granted');
    }
    return granted;
  }

  @override
  Future<LocationPermissionStatus> checkPermission() async {
    final permission = await _geolocator.checkPermission();
    if (permission == geo.LocationPermission.denied ||
        permission == geo.LocationPermission.deniedForever) {
      _noteAccessLost('permission read denied');
    }
    return _convertPermissionStatus(permission);
  }

  /// The platform's last known position — the native owner's last BEST fix on
  /// iOS, the plugin's on Android.
  ///
  /// iOS cannot use the plugin's: under Haven's own updates owner the plugin's
  /// `CLLocationManager` is never started, so what its `location` property
  /// holds is undefined. The native answer is deterministic and carries the
  /// only-Best guarantee — a coordinate taken at the 100 m tier is never
  /// stored there, so it can never be served here.
  ///
  /// The iOS answer is AGE-BOUNDED by the same [_streamFixIsFresh] rule the
  /// cache read uses, because it is the same coordinate: every Best fix is
  /// teed into [_lastStreamPosition] and cached natively on the same
  /// delivery. Without the bound a fix rejected as stale by the read above
  /// was served verbatim by the read below. The plugin's Android answer keeps
  /// its unbounded behaviour: it is the SYSTEM-wide last known position, which
  /// any app on the device keeps current, and it is the only last-known source
  /// Android has.
  Future<Position?> _getLastKnownPosition() async {
    if (_isIOS) {
      final fix = await _iosSource.lastBestFix();
      if (fix == null || !_streamFixIsFresh(fix, DateTime.now())) return null;
      return fix;
    }
    final position = await _geolocator.getLastKnownPosition();
    return position == null ? null : _convertPosition(position);
  }

  /// Converts geolocator Position to our Position type.
  Position _convertPosition(geo.Position geoPosition) {
    return Position(
      latitude: geoPosition.latitude,
      longitude: geoPosition.longitude,
      timestamp: geoPosition.timestamp,
      accuracy: geoPosition.accuracy,
      altitude: geoPosition.altitude,
      speed: geoPosition.speed,
      heading: geoPosition.heading,
    );
  }

  /// Converts geolocator permission status to our enum.
  LocationPermissionStatus _convertPermissionStatus(
    geo.LocationPermission permission,
  ) {
    switch (permission) {
      case geo.LocationPermission.denied:
        return LocationPermissionStatus.denied;
      case geo.LocationPermission.deniedForever:
        return LocationPermissionStatus.deniedForever;
      case geo.LocationPermission.whileInUse:
        return LocationPermissionStatus.whileInUse;
      case geo.LocationPermission.always:
        return LocationPermissionStatus.always;
      case geo.LocationPermission.unableToDetermine:
        return LocationPermissionStatus.notDetermined;
    }
  }
}
