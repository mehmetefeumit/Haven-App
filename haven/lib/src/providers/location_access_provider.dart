/// Live location-access state for the map.
///
/// ## The defect this exists to close
///
/// Both app-side listeners of `locationStreamProvider` used to handle it with
/// `next.whenData(...)`, which runs ONLY for `AsyncData`. An `AsyncError` — the
/// plugin's `LocationServiceDisabledException` when the OS location provider is
/// switched off mid-session, or a `PermissionDeniedException` when the user
/// revokes access from system settings — was dropped on the floor, and so was a
/// stream that simply stopped delivering. Haven went on drawing the last fix as
/// if nothing had happened while sharing was dead. This notifier is the piece
/// that notices.
///
/// ## Why a probe rather than the stream error alone
///
/// Two reasons, both load-bearing:
///
/// 1. **A stream can stop without erroring.** On Android the plugin's native
///    client calls `removeUpdates` and nulls its provider when the OS provider
///    goes away; on iOS a revoked authorization can simply end delivery. An
///    error is one way access loss shows up, not the only one, so a silence
///    watchdog runs alongside the error path.
/// 2. **The stream cannot say WHY.** A remedy the user can act on needs the
///    cause: "location services are off" is fixed at the device toggle,
///    "Haven has no permission" is fixed in the app's settings. Only
///    [LocationService.isLocationServiceEnabled] and
///    [LocationService.checkPermission] can tell those apart, so every
///    detection funnels into one [LocationAccessNotifier.refresh] that asks
///    both.
///
/// ## Why it keeps polling once blocked, and why the clear never waits for a fix
///
/// Recovery cannot be detected from the position stream. Two independent layers
/// keep an Android stream dead after the OS provider is switched off and back
/// on:
///
///   1. the native client's `onProviderDisabled` calls `removeUpdates` and
///      nulls `currentLocationProvider`, while `onProviderEnabled` is an EMPTY
///      method — the platform side never re-arms itself; and
///   2. `GeolocatorAndroid` caches `_positionStream` and returns it verbatim to
///      any later `getPositionStream` call.
///
/// Layer 2 is escapable: `_wrapStream` wraps the channel stream in
/// `asBroadcastStream(onCancel:)` whose callback nulls `_positionStream` when
/// the LAST listener cancels — which is exactly what disposing
/// `locationStreamProvider` does, so an invalidate genuinely yields a fresh
/// native subscription (verified against `geolocator_android` 5.0.2). That is
/// why [LocationAccessNotifier] invalidates on the recovery edge: it is the one
/// thing that can bring the live map dot and the motion-triggered publish back
/// without an app relaunch.
///
/// But it is a property of a third-party package, not of this app, so the
/// USER-VISIBLE state is never staked on it. The blocked → available
/// transition is decided solely by the authoritative re-check
/// ([LocationAccessNotifier.refresh]), which does not consult the stream at
/// all; the stream rebuild is a best-effort side effect that happens
/// afterwards. A surface that waited for an `AsyncData` would, if the stream
/// stayed dead, be stuck on screen forever after the user had already fixed
/// the problem — worse than the silence it replaced, because it would be
/// actively lying. Pinned by
/// `location_access_provider_test.dart`'s "clears even when the position
/// stream NEVER revives".
///
/// ## Fail-quiet, never fail-loud
///
/// Every probe failure degrades to a state that shows the user LESS, never a
/// wrong accusation: an unreadable disclosure flag or an unreadable service
/// state resolves to [LocationAccessStatus.available] or
/// [LocationAccessStatus.unknown] (generic copy), never to a confident
/// "you revoked permission".
///
/// The same rule governs the "never asked" reading, which is the one the
/// platform makes easiest to get wrong — see
/// [LocationAccessNotifier.classify].
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/providers/location_provider.dart';
import 'package:haven/src/providers/map_controller_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/location_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Why (and whether) Haven is currently unable to read this device's location.
enum LocationAccessStatus {
  /// Location is readable: the device provider is on and Haven may use it.
  ///
  /// Also the state used whenever Haven has no standing to complain — before
  /// the prominent disclosure has been accepted, the disclosure flow owns the
  /// user's attention and this notifier stays quiet.
  available,

  /// The device-wide location provider is switched off. Remedy: the system
  /// location toggle.
  serviceDisabled,

  /// Haven's location permission was granted and is not any more, but the OS
  /// will still let it be requested. Remedy: grant access (app settings).
  ///
  /// Only ever reported once Haven has actually HELD access in this session —
  /// see [LocationAccessNotifier.classify] for why a never-granted reading of
  /// the same platform value is not a revocation.
  permissionDenied,

  /// Haven's location permission is denied in a way the app can no longer
  /// prompt for ("Don't ask again" / iOS "Never"). Remedy: system settings.
  permissionPermanentlyDenied,

  /// Both blockers at once. Deliberately its own state rather than a guess at
  /// which one to name: fixing only one of them would leave the user still
  /// broken and no wiser.
  serviceDisabledAndPermissionDenied,

  /// Location is not being delivered and the cause could not be determined
  /// (the platform checks themselves failed). Honest generic copy, no claim
  /// about which remedy applies.
  unknown,
}

/// Convenience predicates over [LocationAccessStatus].
extension LocationAccessStatusX on LocationAccessStatus {
  /// Whether Haven currently cannot read this device's location, for any
  /// reason — i.e. whether the user must be told.
  bool get isBlocked => this != LocationAccessStatus.available;
}

/// How long the position stream may stay silent before Haven asks the platform
/// whether location access is still granted, and how often it re-asks while
/// blocked (which is the only way recovery is ever noticed — see the library
/// doc).
///
/// Deliberately short relative to [kLocationPublishMaxInterval] (168 s): a user
/// must learn that sharing stopped well before the circle-visible gap opens.
/// Each probe is two local platform calls — no GPS fix is requested and no
/// network traffic is generated — so the cost of the cadence is negligible.
const Duration kLocationAccessProbeInterval = Duration(seconds: 30);

/// How soon to re-probe when a probe answered `available` while the position
/// stream had just faulted.
///
/// Short because the only thing being waited on is the OS finishing a settings
/// write it has already begun; long enough that the recheck is a fresh read
/// rather than the same racing one.
const Duration kLocationAccessContradictedRetryDelay = Duration(seconds: 1);

/// How many fast rechecks a contradicted probe is worth before falling back to
/// [kLocationAccessProbeInterval].
///
/// Five at one second each bounds the surface's worst-case silence at ~5 s
/// instead of 30 s, while a device that really is fine (one dropped stream
/// event, no settings change) pays five cheap local reads and stops.
const int _kContradictedProbeAttempts = 5;

/// The probe cadence actually used, so tests can compress it.
///
/// A seam, not a setting: production reads
/// [kLocationAccessProbeInterval] and nothing in the app overrides it. Without
/// it, the two behaviours that only the watchdog can produce — a stream that
/// stops without erroring, and recovery on a stream that never comes back —
/// would be untestable except through wall-clock waits.
final locationAccessProbeIntervalProvider = Provider<Duration>((ref) {
  return kLocationAccessProbeInterval;
});

/// How soon to re-probe after a probe contradicted a stream fault.
///
/// The same kind of seam as [locationAccessProbeIntervalProvider], and for the
/// same reason: the contradiction path is only observable as a DELAY, so
/// without an override the tests that pin it would be wall-clock waits.
final locationAccessContradictedRetryProvider = Provider<Duration>((ref) {
  return kLocationAccessContradictedRetryDelay;
});

/// Live location-access state, driven by the position stream plus a platform
/// probe. `LocationAccessStatus.available` until something says otherwise.
final locationAccessProvider =
    NotifierProvider<LocationAccessNotifier, LocationAccessStatus>(
      LocationAccessNotifier.new,
    );

/// Notifier backing [locationAccessProvider]. See the library doc for the
/// design and why it polls.
class LocationAccessNotifier extends Notifier<LocationAccessStatus> {
  Timer? _watchdog;

  /// Fences a probe whose `await`s were overtaken by a newer one, so a slow
  /// platform answer can never overwrite a fresher verdict.
  int _generation = 0;

  /// Set from [Ref.onDispose]. Writing `state` after disposal throws, and a
  /// probe can still be in flight at that point.
  bool _disposed = false;

  /// Whether Haven has held location access at any point in this session —
  /// either a probe read a granted permission, or a fix was delivered.
  ///
  /// The discriminator between "you revoked it" and "you have not granted it
  /// yet", which the platform itself does not provide. See [classify].
  ///
  /// Session-scoped on purpose. This surface's claim is that sharing STOPPED;
  /// a cold start that has never had access has nothing to have stopped, and
  /// the map's own empty state owns that moment.
  bool _everGranted = false;

  /// How many fast rechecks are still owed because a probe answered
  /// `available` while the position stream had just reported a fault.
  ///
  /// The two readings CONTRADICT each other, and the probe is the one that can
  /// be wrong for a knowable reason: on Android `isLocationServiceEnabled()`
  /// races the OS write behind `cmd location set-location-enabled` /
  /// Quick Settings, so a probe fired by the stream error can still read the
  /// PRE-toggle value. Accepting that answer used to cost a full
  /// [kLocationAccessProbeInterval] of silence — the user switches location
  /// off, sharing dies immediately, and nothing says so for up to 30 s.
  /// Observed in CI run 30977235075, where the whole 28 s disabled window
  /// closed before the next probe was due and the banner never appeared at all.
  ///
  /// Bounded, so a genuinely-available device that merely dropped one stream
  /// event settles back onto the normal cadence instead of probing forever.
  int _contradictedProbesLeft = 0;

  @override
  LocationAccessStatus build() {
    ref
      ..onDispose(() {
        _disposed = true;
        _watchdog?.cancel();
        _watchdog = null;
      })
      // NOT `whenData`. Handling only `AsyncData` is precisely the defect: an
      // `AsyncError` and a stream that stops both mean location access may be
      // gone, and both used to be silently discarded.
      ..listen<AsyncValue<Position>>(
        locationStreamProvider,
        _onPositionEvent,
        fireImmediately: true,
      );
    return LocationAccessStatus.available;
  }

  void _onPositionEvent(
    AsyncValue<Position>? previous,
    AsyncValue<Position> next,
  ) {
    if (next is AsyncError<Position>) {
      // Type only — a raw stream error must never reach the UI (Security
      // Rule 8) and must not be trusted to name the cause either; the probe
      // does that.
      debugPrint(
        '[LocationAccess] position stream error: ${next.error.runtimeType}',
      );
      // The stream faulting is a FACT. If the probe about to run disagrees and
      // says everything is fine, that disagreement is worth rechecking
      // promptly rather than sleeping the full probe interval on it.
      _contradictedProbesLeft = _kContradictedProbeAttempts;
      unawaited(refresh());
      return;
    }
    if (next is AsyncData<Position>) {
      // A fix is proof access works. Clear any blocked state, and restart the
      // silence watchdog from now.
      _everGranted = true;
      // A delivered fix settles the contradiction in the probe's favour: the
      // stream is demonstrably alive, so stop paying for fast rechecks.
      _contradictedProbesLeft = 0;
      _armWatchdog();
      _apply(LocationAccessStatus.available, restartStream: false);
      return;
    }
    // AsyncLoading: a (re)subscribe is in flight. Arm the watchdog so a stream
    // that never delivers a first fix is still noticed, but do not disturb the
    // current verdict.
    _armWatchdog();
  }

  /// Stops the silence watchdog until something re-arms it.
  ///
  /// Called when the app is paused. The watchdog exists to keep a USER-VISIBLE
  /// surface honest, and there is no user looking while the app is backgrounded
  /// — but its side effects are not free:
  ///
  ///   * a blocked → available flip invalidates `locationStreamProvider`,
  ///     which tears down and re-creates the one geolocator stream the process
  ///     has. With background sharing OFF that rebuild also runs the provider's
  ///     `clearCachedPosition()`, throwing away the cached fix the publish path
  ///     uses; and
  ///   * on Android the probe would otherwise keep firing platform calls every
  ///     [kLocationAccessProbeInterval] for as long as the app is backgrounded.
  ///
  /// `_onResumed` calls [refresh] before anything else, which re-arms — so the
  /// banner is re-decided from a fresh platform read on the way back in, which
  /// is more accurate than whatever a background tick would have left behind.
  void suspend() {
    _watchdog?.cancel();
    _watchdog = null;
  }

  /// Re-reads the platform's location-access state and republishes the verdict.
  ///
  /// Safe to call at any time and from anywhere: it is what the silence
  /// watchdog fires, what app resume calls (the user may have changed a system
  /// toggle while away), what a failed one-shot location read calls, and what
  /// the map's retry button calls.
  ///
  /// **Never throws, and never returns without re-arming.** Both halves matter
  /// and neither is free: every caller uses `unawaited`, so a throw would
  /// surface as an unhandled async error far from here — and, worse, it would
  /// skip the re-arm at the end and leave the watchdog dead for the rest of the
  /// session. Recovery is watchdog-only (see the library doc), and some OEM
  /// location toggles never pause the app, so "dead watchdog" means a banner
  /// stuck on screen after the user has already fixed the problem. The re-arm
  /// therefore lives in a `finally`, and the platform reads it depends on are
  /// wrapped rather than assumed infallible.
  Future<void> refresh() async {
    // A watchdog tick, an app resume and a button tap can all land after
    // teardown (rapid logout unmounts the map mid-probe). Reading any provider
    // from a disposed container throws, and this runs unawaited, so the throw
    // would surface as an unhandled async error rather than anywhere useful.
    if (_disposed) return;
    final generation = ++_generation;
    try {
      final status = await _diagnose();
      if (_disposed || generation != _generation) return;
      _apply(status, restartStream: true);
    } on Object catch (e) {
      // Type only (Security Rule 8). `_diagnose` already handles the platform
      // calls it makes; this catches everything else a probe touches — every
      // `ref.read`/`ref.invalidate` on a container being torn down underneath
      // it, which is exactly when an unhandled async error is least useful.
      debugPrint('[LocationAccess] refresh failed: ${e.runtimeType}');
    } finally {
      // Not re-armed when superseded: a newer probe is in flight and owns the
      // next arm, and arming here would leave two timers racing.
      if (!_disposed && generation == _generation) _armWatchdog();
    }
  }

  /// Maps a platform reading to a [LocationAccessStatus].
  ///
  /// Pure and total, so every combination is unit-testable without a platform.
  /// Order matters: the device-wide provider is the outer blocker, so it is
  /// named first, and the both-broken case gets its own state rather than a
  /// guess (fixing one of two blockers leaves the user still broken).
  ///
  /// ## Why [everGranted] exists: "never asked" is not "revoked"
  ///
  /// [LocationPermissionStatus.denied] does NOT mean the user took access
  /// away. It means "Haven does not hold permission and the OS will still let
  /// it ask", and on iOS it does not even mean that much:
  /// `AuthorizationStatusMapper.m` maps BOTH
  /// `kCLAuthorizationStatusNotDetermined` and `kCLAuthorizationStatusRestricted`
  /// to index 0, which is
  /// `LocationPermission.denied` — while a real iOS denial ("Don't Allow")
  /// arrives as `kCLAuthorizationStatusDenied` → index 1 →
  /// `LocationPermission.deniedForever`. So on iOS this value means
  /// *not-determined or restricted*, i.e. never-granted, and never a
  /// revocation. [LocationPermissionStatus.notDetermined] is reachable only
  /// from geolocator's web `unableToDetermine`, so it is the same class of
  /// answer and is treated identically.
  ///
  /// Without this parameter the first run reads as an accusation. The user
  /// accepts the in-app disclosure (which persists the flag immediately), the
  /// OS prompt goes up, a watchdog tick lands while it is on screen and reads
  /// service-enabled + denied — and Haven renders "Haven no longer has
  /// permission, so sharing has stopped" over the top of the prompt it is
  /// waiting on. Both clauses are false.
  ///
  /// So an askable denial is only ever reported once Haven has actually HELD
  /// access this session; before that it resolves to
  /// [LocationAccessStatus.available] (stay quiet — the map's own empty state
  /// and the full-screen error own the acquisition flow) and, when the device
  /// provider is also off, to the unambiguous
  /// [LocationAccessStatus.serviceDisabled] alone rather than the combined
  /// state. Fail-quiet, per the library doc.
  ///
  /// [LocationPermissionStatus.deniedForever] is exempt: on every platform it
  /// is an explicit, unambiguous "no" that the app can no longer prompt for,
  /// so it is surfaced whether or not access was ever held.
  ///
  /// ## `restricted`, honestly
  ///
  /// An MDM- or Screen-Time-restricted device cannot grant location at all, so
  /// "grant access" copy would be advice the user cannot follow. Haven CANNOT
  /// distinguish it: geolocator collapses `restricted` and `notDetermined` into
  /// the same Dart value (above) and exposes no other channel for it. The
  /// never-granted rule is what keeps that honest — a restricted device never
  /// held access, so it is never told that it lost it. It is left in the
  /// acquisition flow instead, where the map's own error surface says location
  /// is unavailable without naming a remedy that does not exist.
  static LocationAccessStatus classify({
    required bool serviceEnabled,
    required LocationPermissionStatus permission,
    required bool everGranted,
  }) {
    final granted =
        permission == LocationPermissionStatus.whileInUse ||
        permission == LocationPermissionStatus.always;
    // An askable "no" that Haven has never had a "yes" for: not a revocation,
    // so never reported as one. See the doc above.
    final unaskedFor =
        !granted &&
        !everGranted &&
        permission != LocationPermissionStatus.deniedForever;
    if (serviceEnabled) {
      if (granted) return LocationAccessStatus.available;
      if (unaskedFor) return LocationAccessStatus.available;
      return permission == LocationPermissionStatus.deniedForever
          ? LocationAccessStatus.permissionPermanentlyDenied
          : LocationAccessStatus.permissionDenied;
    }
    // The device-wide provider being off is unambiguous and actionable, so it
    // is still named — but only it. Adding a permission claim Haven cannot
    // stand behind would make the honest half less believable.
    return granted || unaskedFor
        ? LocationAccessStatus.serviceDisabled
        : LocationAccessStatus.serviceDisabledAndPermissionDenied;
  }

  Future<LocationAccessStatus> _diagnose() async {
    // Before the prominent disclosure is accepted, "no location" is the user's
    // own choice and the map already says so in its own empty state. Claiming
    // a fault here would be both wrong and a second, contradictory surface.
    if (!await _disclosureAccepted()) return LocationAccessStatus.available;
    if (_disposed) return state;

    final service = ref.read(locationServiceProvider);

    bool serviceEnabled;
    try {
      serviceEnabled = await service.isLocationServiceEnabled();
    } on Object catch (e) {
      debugPrint('[LocationAccess] service check failed: ${e.runtimeType}');
      return LocationAccessStatus.unknown;
    }

    LocationPermissionStatus permission;
    try {
      permission = await service.checkPermission();
    } on Object catch (e) {
      debugPrint('[LocationAccess] permission check failed: ${e.runtimeType}');
      // The half we did read is still worth reporting; the half we did not is
      // never guessed at.
      return serviceEnabled
          ? LocationAccessStatus.unknown
          : LocationAccessStatus.serviceDisabled;
    }

    // A granted read is the other way (besides a delivered fix) that Haven
    // learns it has actually held access, which is what lets a LATER denial be
    // called a revocation. Recorded before classifying so the very same probe
    // that first sees the grant already counts.
    if (permission == LocationPermissionStatus.whileInUse ||
        permission == LocationPermissionStatus.always) {
      _everGranted = true;
    }

    return classify(
      serviceEnabled: serviceEnabled,
      permission: permission,
      everGranted: _everGranted,
    );
  }

  /// Whether the user has accepted the foreground location disclosure.
  ///
  /// Reads the PERSISTED flag, which is the source of truth:
  /// `LocationDisclosureController.ensureDisclosed` awaits
  /// `prefs.setBool(kLocationDisclosureAcceptedKey, true)` BEFORE it publishes
  /// anything in memory, and its only other write path (`_syncFromPrefs`)
  /// derives memory FROM prefs. So the flag is never behind the in-memory
  /// state, and a probe that fires before the map has run its disclosure gate
  /// still reads a returning user correctly. Pinned by
  /// `location_disclosure_provider_test.dart`'s "persists before it publishes".
  ///
  /// Fails closed: an unreadable flag means "stay quiet".
  Future<bool> _disclosureAccepted() async {
    if (_disposed) return false;
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(kLocationDisclosureAcceptedKey) ?? false;
    } on Object catch (e) {
      debugPrint('[LocationAccess] disclosure read failed: ${e.runtimeType}');
      return false;
    }
  }

  /// Publishes [next], handling the two edges that have side effects.
  ///
  /// [restartStream] is `false` when the verdict came from a delivered fix
  /// (the stream is demonstrably alive, so re-creating it would be a pointless
  /// GPS session churn) and `true` when it came from a probe (the stream may be
  /// the thing that died).
  void _apply(LocationAccessStatus next, {required bool restartStream}) {
    final previous = state;
    if (previous == next) return;
    // The verdict IS the surface: `available` renders nothing, everything else
    // renders the banner. Leaving it unlogged made two CI runs with
    // byte-identical app logs produce opposite surfacing outcomes with nothing
    // to explain why (runs 30977235075 and 30980908814). Enum names only — no
    // platform error text ever reaches a log line from here (Security Rule 8).
    debugPrint('[LocationAccess] ${previous.name} -> ${next.name}');
    state = next;

    if (next.isBlocked) {
      if (!previous.isBlocked) {
        // Entering blocked: drop the coordinate every other surface would keep
        // drawing as though it were current (the circles sheet's "centre on
        // me" reads this). Haven never persists an own-location, so there is
        // nothing to restore — the next real fix repopulates it.
        ref.read(obfuscatedLocationProvider.notifier).state = null;
      }
      return;
    }

    // Recovering. An Android position subscription torn down with the OS
    // provider does not come back on its own, so without this the map would
    // stay frozen for the rest of the session even though access is fine.
    if (restartStream) ref.invalidate(locationStreamProvider);
  }

  /// (Re-)arms the silence watchdog. Never throws — see [refresh].
  ///
  /// The `ref.read` here is the last thing standing between a torn-down
  /// container and an exception thrown out of a `finally`, which would defeat
  /// the whole point of putting the re-arm there.
  void _armWatchdog() {
    _watchdog?.cancel();
    _watchdog = null;
    if (_disposed) return;
    Duration interval;
    try {
      interval = ref.read(locationAccessProbeIntervalProvider);
    } on Object catch (e) {
      debugPrint('[LocationAccess] watchdog arm failed: ${e.runtimeType}');
      return;
    }
    // A probe that answered `available` while the stream had just faulted has
    // not settled anything — recheck soon instead of on the slow cadence. The
    // counter is spent here (not in `refresh`) so every arming path is covered
    // by one rule, and it is only consumed while the verdict is still the
    // unblocked one: the moment a probe agrees with the stream, the state is
    // blocked, the banner is up, and the fast cadence has done its job.
    if (_contradictedProbesLeft > 0 && !state.isBlocked) {
      _contradictedProbesLeft--;
      // The FASTER of the two, never a fixed value: a "fast" recheck that ran
      // slower than the ordinary cadence would be a contradiction in terms.
      Duration retry;
      try {
        retry = ref.read(locationAccessContradictedRetryProvider);
      } on Object catch (e) {
        debugPrint('[LocationAccess] retry read failed: ${e.runtimeType}');
        retry = kLocationAccessContradictedRetryDelay;
      }
      if (retry < interval) interval = retry;
      debugPrint(
        '[LocationAccess] probe disagreed with a stream fault — rechecking in '
        '${interval.inMilliseconds}ms ($_contradictedProbesLeft left)',
      );
    }
    _watchdog = Timer(interval, () {
      unawaited(refresh());
    });
  }
}
