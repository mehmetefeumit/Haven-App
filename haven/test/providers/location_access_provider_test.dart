/// Tests for [locationAccessProvider] — the state machine that notices when
/// Haven can no longer read this device's location, and says why.
///
/// ## What these pin, and why each one exists
///
/// The defect being closed is that BOTH app-side listeners of
/// `locationStreamProvider` handled it with `next.whenData(...)`, which runs
/// only for `AsyncData`. Two distinct failure shapes were therefore invisible:
///
///   * an `AsyncError` (Android raises `LocationServiceDisabledException`
///     mid-stream when the OS provider is switched off), and
///   * a stream that simply STOPS delivering, with no error at all (iOS can
///     end delivery on a revoked authorization; a completed stream leaves
///     Riverpod's `AsyncValue` sitting on its last `AsyncData` forever).
///
/// Both are covered here, deliberately and separately: a fix that only handles
/// the error path would pass the first and fail the second.
///
/// ## Why the fake service, and what it is faithful to
///
/// [_FakeLocationService] is NOT a stand-in for
/// `GeolocatorLocationService` behaviour — it is a controllable platform. It
/// lets a test drive the two things only the platform can say
/// (`isLocationServiceEnabled`, `checkPermission`) independently of the
/// stream, which is exactly the axis the production code has to reason about:
/// the stream says *that* something broke, the probe says *what*.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/providers/background_location_provider.dart';
import 'package:haven/src/providers/location_access_provider.dart';
import 'package:haven/src/providers/map_controller_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/background_location_manager.dart';
import 'package:haven/src/services/location_service.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

/// A controllable platform: the position stream and the two access checks are
/// driven independently, because in reality they fail independently.
///
/// Each `getLocationStream()` call hands out a NEW controller, mirroring
/// geolocator: a subscription is a platform subscription, and the Android
/// client's provider-disabled path (`removeUpdates` + a nulled provider) leaves
/// the OLD one open, silent and unrecoverable — a zombie. Modelling that
/// faithfully is the point: a recovery design that waits for the existing
/// stream to resume would pass a fake that replays on the same controller and
/// hang forever in production.
class _FakeLocationService implements LocationService {
  final List<StreamController<Position>> _controllers = [];

  /// The most recently handed-out stream — the only one a live subscriber is
  /// listening to.
  StreamController<Position> get controller => _controllers.last;

  /// What `isLocationServiceEnabled()` answers.
  bool serviceEnabled = true;

  /// Models the OS settings write LANDING BETWEEN PROBES.
  ///
  /// On Android `isLocationServiceEnabled()` races the write behind
  /// `cmd location set-location-enabled` / Quick Settings, so the probe fired
  /// by the stream error can still read the pre-toggle value while a later one
  /// reads the truth. Expressed as a check COUNT rather than a wall-clock
  /// delay so the test that pins this cannot become a timing race itself.
  int? flipServiceEnabledAfterChecks;

  /// What `checkPermission()` answers.
  LocationPermissionStatus permission = LocationPermissionStatus.whileInUse;

  /// When set, the matching check throws instead of answering.
  Object? serviceCheckError;
  Object? permissionCheckError;

  /// Number of times `getLocationStream()` was called — i.e. how many times
  /// the provider (re)subscribed. Recovery must re-subscribe, or an Android
  /// stream torn down with the OS provider never comes back.
  int streamSubscriptions = 0;

  int serviceChecks = 0;
  int permissionChecks = 0;

  /// When true, every `getLocationStream()` call hands back the SAME dead
  /// stream, which never emits and never closes.
  ///
  /// This is the worst case the platform can produce: `GeolocatorAndroid`
  /// caches `_positionStream` and returns it verbatim, and its native
  /// `onProviderEnabled` is an empty method, so if the cache is ever handed
  /// out again the app is left holding a corpse for the rest of the session.
  /// The surfacing must not depend on that stream to clear — a banner still up
  /// after the user fixed the problem is worse than the silence it replaced,
  /// because it is actively wrong.
  bool handBackTheCorpse = false;

  StreamController<Position>? _corpse;

  @override
  Stream<Position> getLocationStream() {
    streamSubscriptions++;
    if (handBackTheCorpse) {
      final corpse = _corpse ??= StreamController<Position>.broadcast();
      return corpse.stream;
    }
    final fresh = StreamController<Position>();
    _controllers.add(fresh);
    addTearDown(fresh.close);
    return fresh.stream;
  }

  @override
  Future<bool> isLocationServiceEnabled() async {
    serviceChecks++;
    if (serviceCheckError != null) throw serviceCheckError!;
    final flipAfter = flipServiceEnabledAfterChecks;
    if (flipAfter != null && serviceChecks > flipAfter) return false;
    return serviceEnabled;
  }

  @override
  Future<LocationPermissionStatus> checkPermission() async {
    permissionChecks++;
    if (permissionCheckError != null) throw permissionCheckError!;
    return permission;
  }

  @override
  Future<Position> getCurrentLocation() => throw UnimplementedError();

  @override
  Future<Position> getCurrentLocationFresh() => throw UnimplementedError();

  @override
  Future<bool> requestPermission() async => true;
}

/// A [BackgroundSharingNotifier] with no platform side effects.
class _FakeBackgroundSharingNotifier extends BackgroundSharingNotifier {
  _FakeBackgroundSharingNotifier()
    : super(
        ensurePermissions: () async => const EnsurePermissionsGranted(),
        isAndroid: false,
        isIOS: false,
      );
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

Position _position() => Position(
  latitude: 51.5,
  longitude: -0.12,
  timestamp: DateTime.now(),
);

/// Compressed so the watchdog-driven behaviours are testable without
/// wall-clock waits. See [locationAccessProbeIntervalProvider].
const _probeInterval = Duration(milliseconds: 10);

/// A probe interval so long the watchdog cannot fire during a test.
///
/// Used to isolate the stream-error path: with the watchdog effectively off,
/// a detection can only have come from the `AsyncError` branch. Without this,
/// the error test passes even when that branch is deleted — the compressed
/// watchdog quietly does the work and the assertion proves nothing about the
/// bug it was written for. (This is exactly what mutation M1 exposed.)
const _watchdogDisabled = Duration(minutes: 5);

/// Long enough for several probe cycles (each probe awaits SharedPreferences
/// plus two service calls), short enough to keep the suite fast.
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 120));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeLocationService service;

  /// Builds a container with the fake platform installed and the position
  /// stream live. [disclosureAccepted] seeds the prominent-disclosure flag,
  /// which gates the whole surface.
  ///
  /// [probeInterval] is compressed by default so the watchdog-driven
  /// behaviours are testable. Pass [_watchdogDisabled] to take the watchdog
  /// OUT of the picture entirely, which is the only way to attribute a
  /// detection to the stream-error path rather than to a timer that would have
  /// found it anyway.
  ///
  /// [extraOverrides] is for the one thing the fake platform cannot express:
  /// a provider read that THROWS. Every platform call the notifier makes is
  /// inside a `try`, so the fake can never reach the code paths that break
  /// when an unguarded `ref.read` fails.
  ProviderContainer harness({
    bool disclosureAccepted = true,
    Duration probeInterval = _probeInterval,
    Duration contradictedRetry = _probeInterval,
    List<Override> extraOverrides = const [],
  }) {
    SharedPreferences.setMockInitialValues(<String, Object>{
      if (disclosureAccepted) kLocationDisclosureAcceptedKey: true,
    });
    service = _FakeLocationService();
    final container = ProviderContainer(
      overrides: [
        locationServiceProvider.overrideWithValue(service),
        backgroundSharingProvider.overrideWith(
          (ref) => _FakeBackgroundSharingNotifier(),
        ),
        locationAccessProbeIntervalProvider.overrideWithValue(probeInterval),
        locationAccessContradictedRetryProvider
            .overrideWithValue(contradictedRetry),
        ...extraOverrides,
      ],
    );
    addTearDown(container.dispose);
    // A permanent listener mirrors the map UI's watch: without one the
    // provider would be disposed between reads and the watchdog would never
    // survive to fire.
    final sub = container.listen(locationAccessProvider, (_, _) {});
    addTearDown(sub.close);
    return container;
  }

  /// Drives the notifier to the "Haven has held access" state the way
  /// production does — a delivered fix — and leaves it `available`.
  ///
  /// Needed by every test whose subject is a REVOCATION, because a revocation
  /// is by definition a loss of something held: `classify` deliberately
  /// refuses to call an askable denial a revocation until access has actually
  /// been granted once (see F5 / the `never asked` group). Without this the
  /// permission tests would silently be testing the first-run path instead.
  Future<void> establishAccess(ProviderContainer container) async {
    service.controller.add(_position());
    await _settle();
    expect(
      container.read(locationAccessProvider),
      LocationAccessStatus.available,
      reason: 'precondition: a fix must have landed, or nothing below is '
          'testing a revocation',
    );
  }

  // -------------------------------------------------------------------------
  // Baseline — anti-vacuity for every "surfaced" assertion below
  // -------------------------------------------------------------------------

  group('baseline', () {
    test('starts available and stays available while fixes arrive', () async {
      final container = harness();
      expect(container.read(locationAccessProvider),
          LocationAccessStatus.available);

      service.controller.add(_position());
      await _settle();

      expect(
        container.read(locationAccessProvider),
        LocationAccessStatus.available,
        reason: 'A healthy stream must never raise the surface — every '
            '"blocked" assertion in this file is vacuous otherwise.',
      );
    });
  });

  // -------------------------------------------------------------------------
  // The two failure shapes `whenData` dropped
  // -------------------------------------------------------------------------

  group('detection', () {
    test('an AsyncError on the position stream surfaces the state', () async {
      // THE `whenData` GAP. Before the fix this error reached two listeners
      // and both discarded it.
      //
      // The watchdog is disabled for this test on purpose. With it running,
      // this assertion passes even if the AsyncError branch is deleted — the
      // timer finds the same thing a moment later — so the test would claim to
      // cover the defect while covering nothing. Attribution matters here
      // beyond tidiness: the platform tells us immediately, and a user whose
      // sharing just died should not wait a probe interval to be told.
      final container = harness(probeInterval: _watchdogDisabled);
      service.controller.add(_position());
      await _settle();
      expect(container.read(locationAccessProvider),
          LocationAccessStatus.available);

      service.serviceEnabled = false;
      service.controller.addError(
        StateError('location service disabled'),
        StackTrace.empty,
      );
      await _settle();

      expect(
        container.read(locationAccessProvider),
        LocationAccessStatus.serviceDisabled,
        reason: 'The watchdog cannot have fired, so only the AsyncError branch '
            'can be responsible for this.',
      );
    });

    test('a stream that completes WITHOUT error also surfaces the state',
        () async {
      // The other half of the gap, and the one an error-only fix would miss:
      // Riverpod leaves a completed stream sitting on its last AsyncData, so
      // no listener of any kind ever fires again. Only the silence watchdog
      // can notice this.
      final container = harness();
      service.controller.add(_position());
      await _settle();
      expect(container.read(locationAccessProvider),
          LocationAccessStatus.available);

      service.serviceEnabled = false;
      await service.controller.close();
      await _settle();

      expect(
        container.read(locationAccessProvider),
        LocationAccessStatus.serviceDisabled,
        reason: 'A silently-stopped stream must be noticed. Handling only '
            'AsyncError would leave this available forever.',
      );
    });

    test('a stream that never delivers a first fix is noticed', () async {
      // Cold start into a disabled provider: nothing is ever emitted, so
      // there is no AsyncData to arm anything from except the initial
      // AsyncLoading.
      final container = harness();
      service.serviceEnabled = false;
      await _settle();

      expect(
        container.read(locationAccessProvider),
        LocationAccessStatus.serviceDisabled,
      );
    });

    test('a stream that goes silent while the PLATFORM still reports access '
        'is not surfaced — the Android app-ops residual', () async {
      // THE ANDROID `appops set <pkg> android:fine_location deny` CASE, modelled
      // as it actually behaves.
      //
      // This test used to set `permission = denied`, which app-ops provably
      // does NOT do — that is the entire point of the residual documented in
      // `GeolocatorLocationService._ensureAccessOrThrow`: app-ops does not
      // touch the permission GRANT, so `ContextCompat.checkSelfPermission` (and
      // therefore `checkPermission()`) keeps answering "granted", and unlike
      // `pm revoke` it does not kill the process. Delivery just stops. Setting
      // `denied` here made the probe do the work and hid the fact that the real
      // scenario reaches NONE of it.
      //
      // So: probe reads granted, stream falls silent, no error, no close.
      final container = harness();
      service
        ..serviceEnabled = true
        ..permission = LocationPermissionStatus.whileInUse;
      service.controller.add(_position());
      await _settle();
      expect(container.read(locationAccessProvider),
          LocationAccessStatus.available);

      // Deliberately no addError, no close, no permission change: the platform
      // goes on claiming everything is fine while nothing is delivered.
      await _settle();
      await _settle();

      expect(
        container.read(locationAccessProvider),
        LocationAccessStatus.available,
        reason: 'THE HONEST CURRENT BEHAVIOUR, AND A DELIBERATE LIMIT — not an '
            'oversight to be "fixed" by surfacing on silence alone.\n'
            '\n'
            'Everything Haven can ask says access is fine: '
            '`isLocationServiceEnabled()` is true, `checkPermission()` is '
            'granted, the stream is open and un-errored. The only remaining '
            'signal is the silence itself, and silence is NOT evidence — the '
            'stream carries `distanceFilter: 1`, so a stationary device (a '
            'phone on a desk, a user asleep, anyone indoors without a fix) '
            'legitimately emits nothing for hours. Surfacing on that would '
            'raise "your location sharing has stopped" over a perfectly '
            'healthy session, which is the false alarm '
            '"a silent stream with healthy access does NOT raise a false '
            'alarm" exists to forbid, and it would train users to ignore the '
            'banner — costing them the real outages it does catch.\n'
            '\n'
            'Closing this properly needs a signal Haven does not have: '
            '`AppOpsManager.unsafeCheckOpNoThrow`, which geolocator exposes no '
            'channel for. Until then the exposure is bounded elsewhere (the '
            'cached fix ages out of `kStreamPositionMaxAge`, and any stream '
            'error or close clears it), not here.',
      );
      expect(
        service.permissionChecks,
        greaterThan(0),
        reason: 'the watchdog must actually have probed — otherwise this is '
            'asserting that nothing happened because nothing ran',
      );
    });

    test('the cause comes from the platform probe, never from the error object',
        () async {
      // Platform-asymmetric by nature: Android raises a clean
      // `LocationServiceDisabledException`, but an iOS denial arrives as a
      // generic update failure indistinguishable from a transient GPS
      // problem. Naming the cause from the error would therefore be wrong on
      // iOS, so the error is only ever a TRIGGER — the verdict comes from
      // reading the service and permission state.
      // Watchdog off: this must prove that the ERROR triggers a probe and the
      // probe's verdict wins, not that a timer eventually stumbled on it.
      final container = harness(probeInterval: _watchdogDisabled);
      // A REVOCATION, so the permission verdict is one the notifier is willing
      // to reach at all (see the `never asked` group). Without this the test
      // would be asserting the first-run path and quietly stop covering the
      // error-vs-probe attribution it is named for.
      await establishAccess(container);
      service
        ..serviceEnabled = true
        ..permission = LocationPermissionStatus.denied;
      service.controller.addError(
        // An error that "looks like" a disabled service, while the platform
        // says the real cause is the permission.
        StateError('LocationServiceDisabledException'),
        StackTrace.empty,
      );
      await _settle();

      expect(
        container.read(locationAccessProvider),
        LocationAccessStatus.permissionDenied,
        reason: 'A cause inferred from the exception type would be wrong on '
            'iOS, where a denial and a transient GPS failure share one type.',
      );
    });

    test('a silent stream with healthy access does NOT raise a false alarm',
        () async {
      // A stationary device indoors legitimately stops producing fixes while
      // location is perfectly enabled. Surfacing there would train users to
      // ignore the banner.
      final container = harness();
      service.controller.add(_position());
      await service.controller.close();
      await _settle();

      expect(
        container.read(locationAccessProvider),
        LocationAccessStatus.available,
      );
    });
  });

  // -------------------------------------------------------------------------
  // Recovery, in the same session
  // -------------------------------------------------------------------------

  group('recovery', () {
    test('clears when access returns, without a restart', () async {
      final container = harness();
      service.serviceEnabled = false;
      await _settle();
      expect(container.read(locationAccessProvider),
          LocationAccessStatus.serviceDisabled);

      service.serviceEnabled = true;
      await _settle();

      expect(
        container.read(locationAccessProvider),
        LocationAccessStatus.available,
        reason: 'Recovery cannot come from the position stream (an Android '
            'subscription torn down with the OS provider never revives), so '
            'the watchdog must keep probing while blocked.',
      );
    });

    test('re-subscribes the position stream on recovery', () async {
      final container = harness();
      final before = service.streamSubscriptions;
      service.serviceEnabled = false;
      await _settle();
      expect(container.read(locationAccessProvider).isBlocked, isTrue);

      service.serviceEnabled = true;
      await _settle();

      expect(
        service.streamSubscriptions,
        greaterThan(before),
        reason: 'Without a re-subscribe the map stays frozen for the rest of '
            'the session even though access is fine.',
      );
    });

    test('recovers from the Android ZOMBIE stream: off/on, not just error',
        () async {
      // The full Android sequence, which no error-driven design survives:
      //
      //   provider off → onProviderDisabled errors into the stream AND calls
      //   removeUpdates + nulls currentLocationProvider → the stream stays
      //   OPEN and never delivers again, even after the user re-enables
      //   location (onProviderEnabled is an empty method).
      //
      // So recovery cannot be observed on the existing subscription at all.
      // It must be actively re-established, and a fix must then flow on the
      // NEW stream — which is what this asserts end to end.
      final container = harness();
      service.controller.add(_position());
      await _settle();

      // --- provider off
      service.serviceEnabled = false;
      final zombie = service.controller;
      zombie.addError(StateError('provider disabled'), StackTrace.empty);
      await _settle();
      expect(container.read(locationAccessProvider),
          LocationAccessStatus.serviceDisabled);

      // --- provider on. The zombie stays open and silent forever; nothing
      // will ever arrive on it.
      service.serviceEnabled = true;
      await _settle();

      expect(
        container.read(locationAccessProvider),
        LocationAccessStatus.available,
        reason: 'Waiting for the zombie to resume would hang forever.',
      );
      expect(
        identical(service.controller, zombie),
        isFalse,
        reason: 'Recovery must hand out a NEW platform subscription.',
      );

      // And the rebuilt stream is genuinely live: a fix on it flows through.
      service.controller.add(_position());
      await _settle();
      expect(container.read(locationAccessProvider),
          LocationAccessStatus.available);
      expect(zombie.hasListener, isFalse);
    });

    test('clears even when the position stream NEVER revives', () async {
      // The load-bearing one. Two independent layers can keep the Android
      // stream dead for the rest of the session:
      //
      //   1. the native client's `onProviderDisabled` calls `removeUpdates`
      //      and nulls its provider, while `onProviderEnabled` is empty; and
      //   2. `GeolocatorAndroid` caches `_positionStream` and hands the same
      //      object back to any later `getPositionStream` call.
      //
      // (2) is escapable — `_wrapStream`'s `asBroadcastStream(onCancel:)` nulls
      // the cache when the LAST listener cancels, which a provider invalidate
      // does — but that is a property of a third-party package, not something
      // this app controls or should stake a user-facing surface on. So the
      // clear is driven by an authoritative re-check that never consults the
      // stream, and this test removes the stream from the equation entirely.
      final container = harness();
      service
        ..handBackTheCorpse = true
        ..serviceEnabled = false;
      await _settle();
      expect(container.read(locationAccessProvider),
          LocationAccessStatus.serviceDisabled);

      // The user fixes it. No fix will EVER arrive: the corpse neither emits
      // nor closes, exactly like the real thing.
      service.serviceEnabled = true;
      await _settle();

      expect(
        container.read(locationAccessProvider),
        LocationAccessStatus.available,
        reason: 'A banner that waits for AsyncData would be stuck on screen '
            'permanently after the user already fixed the problem.',
      );
    });

    test('recovers repeatedly across several off/on cycles', () async {
      final container = harness();
      for (var cycle = 0; cycle < 3; cycle++) {
        service.serviceEnabled = false;
        await _settle();
        expect(
          container.read(locationAccessProvider),
          LocationAccessStatus.serviceDisabled,
          reason: 'cycle $cycle: must re-detect after a previous recovery',
        );

        service.serviceEnabled = true;
        await _settle();
        expect(
          container.read(locationAccessProvider),
          LocationAccessStatus.available,
          reason: 'cycle $cycle: must re-clear',
        );
      }
    });

    test('a delivered fix clears the state without churning the stream',
        () async {
      // ATTRIBUTION, not tidiness. With the compressed watchdog running this
      // test's HEADLINE assertion — that the state clears — passed even with
      // the entire delivered-fix fast path deleted: the 10 ms timer probed a
      // moment later and cleared it, and only the stream-churn count noticed
      // anything had changed. Half the test was vacuous, in exactly the shape
      // the file's own `_watchdogDisabled` comment warns about.
      //
      // So the watchdog is OFF here, which means the blocked state has to be
      // reached some other way: the stream ERROR path, whose verdict is
      // already pinned by the `detection` group. What remains is attributable
      // to nothing but the AsyncData branch.
      final container = harness(probeInterval: _watchdogDisabled);
      service.controller.add(_position());
      await _settle();
      expect(container.read(locationAccessProvider),
          LocationAccessStatus.available);

      service.serviceEnabled = false;
      service.controller.addError(
        StateError('provider disabled'),
        StackTrace.empty,
      );
      await _settle();
      expect(container.read(locationAccessProvider),
          LocationAccessStatus.serviceDisabled);

      // Access comes back AND the stream is alive: a fix is proof, and
      // re-creating a working stream would be pointless GPS churn.
      service.serviceEnabled = true;
      final subscriptionsBefore = service.streamSubscriptions;
      service.controller.add(_position());
      await _settle();

      expect(
        container.read(locationAccessProvider),
        LocationAccessStatus.available,
        reason: 'The watchdog cannot have fired, so only the AsyncData branch '
            'can have cleared this. A user whose location just came back '
            'should not wait a probe interval to be believed.',
      );
      expect(
        service.streamSubscriptions,
        subscriptionsBefore,
        reason: 'The stream is demonstrably alive — it just delivered. '
            'Re-creating it would be a pointless GPS session churn.',
      );
    });
  });

  // -------------------------------------------------------------------------
  // Cause discrimination
  // -------------------------------------------------------------------------

  group('cause discrimination (through the notifier)', () {
    test('service disabled and permission denied are distinguished', () async {
      final container = harness();
      // Explicit, because an askable denial is only a REVOCATION once access
      // has been held (see the `never asked` group). Without this the second
      // half of this test would quietly be exercising the first-run path and
      // asserting the wrong thing.
      await establishAccess(container);

      service
        ..serviceEnabled = false
        ..permission = LocationPermissionStatus.whileInUse;
      await _settle();
      expect(container.read(locationAccessProvider),
          LocationAccessStatus.serviceDisabled);

      service
        ..serviceEnabled = true
        ..permission = LocationPermissionStatus.denied;
      await _settle();
      expect(
        container.read(locationAccessProvider),
        LocationAccessStatus.permissionDenied,
        reason: 'The two have different remedies — the device toggle vs the '
            'app permission — so they must not collapse into one state.',
      );
    });

    test('permanently denied is distinguished from denied', () async {
      final container = harness();
      service
        ..serviceEnabled = true
        ..permission = LocationPermissionStatus.deniedForever;
      await _settle();

      expect(
        container.read(locationAccessProvider),
        LocationAccessStatus.permissionPermanentlyDenied,
      );
    });

    test('both blockers at once get their own state', () async {
      final container = harness();
      service
        ..serviceEnabled = false
        ..permission = LocationPermissionStatus.deniedForever;
      await _settle();

      expect(
        container.read(locationAccessProvider),
        LocationAccessStatus.serviceDisabledAndPermissionDenied,
        reason: 'Naming only one of two blockers leaves the user still broken '
            'after following the advice.',
      );
    });

    test('an unreadable platform yields unknown, never an accusation',
        () async {
      final container = harness();
      service.serviceCheckError = StateError('channel down');
      await _settle();

      expect(
        container.read(locationAccessProvider),
        LocationAccessStatus.unknown,
      );
    });

    test('a readable service check survives an unreadable permission check',
        () async {
      final container = harness();
      service
        ..serviceEnabled = false
        ..permissionCheckError = StateError('channel down');
      await _settle();

      expect(
        container.read(locationAccessProvider),
        LocationAccessStatus.serviceDisabled,
        reason: 'The half that WAS readable is still worth reporting; the '
            'half that was not is never guessed at.',
      );
    });
  });

  // -------------------------------------------------------------------------
  // "Never asked" is not "revoked"
  // -------------------------------------------------------------------------

  group('never asked (through the notifier)', () {
    test('an askable denial before access was ever held stays quiet',
        () async {
      // THE FIRST-RUN FALSE ACCUSATION. The user accepts the in-app prominent
      // disclosure — which persists the flag IMMEDIATELY, opening this gate —
      // and `getCurrentLocation()` then calls `requestPermission()`. While the
      // OS prompt is on screen `checkPermission()` reports not-granted, and a
      // watchdog tick landing in that window used to render "Haven no longer
      // has permission, so sharing has stopped" over the top of the prompt
      // Haven is waiting on. Both clauses false, and shown at the single worst
      // moment.
      //
      // On iOS it is not even a window: `AuthorizationStatusMapper.m` maps
      // `kCLAuthorizationStatusNotDetermined` to the same Dart value as a
      // denial, so a never-asked iOS device reads exactly like this forever.
      final container = harness();
      service
        ..serviceEnabled = true
        ..permission = LocationPermissionStatus.denied;
      await _settle();

      expect(
        container.read(locationAccessProvider),
        LocationAccessStatus.available,
        reason: 'Nothing has stopped, because nothing had started. The map '
            "owns this moment with its own empty state; a second surface "
            'claiming a revocation would be both wrong and contradictory.',
      );
      expect(
        service.permissionChecks,
        greaterThan(0),
        reason: 'anti-vacuity: the probe must have RUN and decided to stay '
            'quiet, not simply never fired',
      );
    });

    test('the same reading IS a revocation once access has been held',
        () async {
      // The other side of the rule, and the anti-vacuity for the test above:
      // identical platform values, opposite verdict, the only difference being
      // that Haven has actually had access this session.
      final container = harness();
      await establishAccess(container);

      service
        ..serviceEnabled = true
        ..permission = LocationPermissionStatus.denied;
      await _settle();

      expect(
        container.read(locationAccessProvider),
        LocationAccessStatus.permissionDenied,
        reason: 'A permission that WAS held and is not any more is exactly the '
            'mid-session loss this surface exists for.',
      );
    });

    test('a granted probe alone (no fix) is enough to arm the revocation claim',
        () async {
      // The other way Haven learns it holds access. It matters on its own:
      // a stream that never delivers (stationary indoors) would otherwise
      // leave a genuine later revocation permanently unreportable.
      final container = harness();
      service
        ..serviceEnabled = true
        ..permission = LocationPermissionStatus.whileInUse;
      await _settle();
      expect(container.read(locationAccessProvider),
          LocationAccessStatus.available);
      expect(service.permissionChecks, greaterThan(0));

      service.permission = LocationPermissionStatus.denied;
      await _settle();

      expect(
        container.read(locationAccessProvider),
        LocationAccessStatus.permissionDenied,
      );
    });

    test('a hard denial is surfaced even when access was never held', () async {
      // `deniedForever` is exempt: on every platform it is an explicit,
      // unambiguous "no" that the app can no longer prompt for, so there is
      // nothing ambiguous to protect the user from. iOS in particular only
      // ever produces it from a real "Don't Allow".
      final container = harness();
      service
        ..serviceEnabled = true
        ..permission = LocationPermissionStatus.deniedForever;
      await _settle();

      expect(
        container.read(locationAccessProvider),
        LocationAccessStatus.permissionPermanentlyDenied,
      );
    });

    test('a disabled provider is still named while the permission is not',
        () async {
      // Half the reading is unambiguous and actionable; half is not. Naming
      // only the half Haven can stand behind beats both alternatives —
      // silence (the user is not told about a real blocker) and the combined
      // state (a permission accusation Haven cannot support).
      final container = harness();
      service
        ..serviceEnabled = false
        ..permission = LocationPermissionStatus.denied;
      await _settle();

      expect(
        container.read(locationAccessProvider),
        LocationAccessStatus.serviceDisabled,
      );
    });
  });

  // -------------------------------------------------------------------------
  // The watchdog's own lifecycle
  // -------------------------------------------------------------------------

  group('probe racing the OS settings write', () {
    test(
        'a probe that answers available while the stream faulted rechecks '
        'FAST, not on the slow cadence', () async {
      // THE CI RUN 30977235075 DEFECT. On Android
      // `isLocationServiceEnabled()` races the OS write behind
      // `cmd location set-location-enabled false` / Quick Settings, so the
      // probe fired by the stream error can still read the PRE-toggle value.
      // The verdict was then `available`, the banner never rendered, and the
      // next probe was a full interval away — so the user's sharing was dead
      // and silent for up to 30 s. In that run the whole 28 s disabled window
      // closed before the recheck was due and the banner never appeared at all.
      //
      // The watchdog is set to a cadence that CANNOT fire inside this test, so
      // only the contradicted-probe fast path can produce the recovery below.
      // Without that, a compressed interval would do the work and this test
      // would prove nothing about the bug it was written for.
      final container = harness(probeInterval: _watchdogDisabled);
      service.controller.add(_position());
      await _settle();
      expect(container.read(locationAccessProvider),
          LocationAccessStatus.available);

      // The stream faults, and the FIRST probe after it still reads the
      // pre-toggle value — exactly the race. Every later probe reads the truth.
      // Sequenced on the check COUNT, not on wall-clock timing, so this test
      // cannot itself become the flaky thing it is pinning.
      service.flipServiceEnabledAfterChecks = service.serviceChecks + 1;
      service.controller.addError(
        StateError('location service disabled'),
        StackTrace.empty,
      );
      await _settle();

      expect(
        container.read(locationAccessProvider),
        LocationAccessStatus.serviceDisabled,
        reason: 'the slow cadence is 5 minutes here, so the surface can only '
            'have come from the contradicted-probe recheck',
      );
    });

    test('the fast recheck is BOUNDED — a healthy device settles back down',
        () async {
      // A single dropped stream event on a device whose location is genuinely
      // fine must not buy an unbounded fast-probe loop.
      final container = harness(probeInterval: _watchdogDisabled);
      service.controller.add(_position());
      await _settle();

      service.controller.addError(
        StateError('transient stream blip'),
        StackTrace.empty,
      );
      await _settle();
      final afterBudget = service.serviceChecks;

      // Well past the budget's worth of fast rechecks.
      await _settle();
      await _settle();

      expect(
        container.read(locationAccessProvider),
        LocationAccessStatus.available,
        reason: 'the platform never said anything was wrong',
      );
      expect(
        service.serviceChecks,
        afterBudget,
        reason: 'the budget is spent; with a 5-minute cadence nothing further '
            'may probe, or the fast path never stops',
      );
    });

    test('a delivered fix cancels the fast rechecks', () async {
      // The stream proving itself alive settles the contradiction in the
      // probe's favour — there is nothing left to recheck.
      final container = harness(probeInterval: _watchdogDisabled);
      service.controller.add(_position());
      await _settle();

      service.controller.addError(
        StateError('transient stream blip'),
        StackTrace.empty,
      );
      await _settle();

      service.controller.add(_position());
      await _settle();
      final afterFix = service.serviceChecks;

      await _settle();
      await _settle();

      expect(container.read(locationAccessProvider),
          LocationAccessStatus.available);
      expect(
        service.serviceChecks,
        afterFix,
        reason: 'a delivered fix must clear the remaining budget',
      );
    });
  });

  group('watchdog liveness', () {
    test('a probe that THROWS does not disarm the watchdog for the session',
        () async {
      // `refresh()` is documented "never throws", but its `_armWatchdog()` used
      // to be the last statement with no `try`/`finally` — so a throw from any
      // of the `ref` calls outside its try blocks skipped the re-arm, and every
      // caller uses `unawaited`, so nothing noticed. Recovery is watchdog-only
      // (an Android stream torn down with the OS provider never revives), so
      // that is a banner stuck on screen for the rest of the session after the
      // user has already fixed the problem.
      //
      // The throw is injected at `_apply`'s own-location clear, which runs only
      // on the entering-blocked edge — precisely the moment the watchdog is
      // most needed next.
      final failOwnLocation = StateProvider<bool>((ref) => true);
      final container = harness(
        extraOverrides: [
          obfuscatedLocationProvider.overrideWith((ref) {
            if (ref.watch(failOwnLocation)) {
              throw StateError('own-location write failed');
            }
            return null;
          }),
        ],
      );

      service.serviceEnabled = false;
      await _settle();
      expect(
        container.read(locationAccessProvider),
        LocationAccessStatus.serviceDisabled,
        reason: 'the verdict is published before the side effect that throws',
      );
      expect(
        () => container.read(obfuscatedLocationProvider),
        throwsStateError,
        reason: 'anti-vacuity: the injected failure must actually be armed, or '
            'this test is just watching an ordinary recovery',
      );

      // The user fixes it. Only a still-armed watchdog can ever notice.
      container.read(failOwnLocation.notifier).state = false;
      service.serviceEnabled = true;
      await _settle();

      expect(
        container.read(locationAccessProvider),
        LocationAccessStatus.available,
        reason: 'A throw inside one probe must cost that probe, not every '
            'probe after it.',
      );
    });

    test('suspend() stops probing until something re-arms it', () async {
      // The app is paused: nobody can see the banner, and a recovery edge
      // fired while backgrounded would invalidate `locationStreamProvider` —
      // which with background sharing OFF also runs that provider's
      // `clearCachedPosition()`, throwing away the fix the publish path
      // serves from.
      final container = harness();
      service.serviceEnabled = false;
      await _settle();
      expect(container.read(locationAccessProvider),
          LocationAccessStatus.serviceDisabled);

      container.read(locationAccessProvider.notifier).suspend();
      final checksAtSuspend = service.serviceChecks;
      service.serviceEnabled = true;
      await _settle();
      await _settle();

      expect(
        service.serviceChecks,
        checksAtSuspend,
        reason: 'A suspended watchdog must make NO platform calls — many probe '
            'intervals have elapsed here.',
      );
      expect(
        container.read(locationAccessProvider),
        LocationAccessStatus.serviceDisabled,
        reason: 'and therefore must not have noticed the recovery either',
      );

      // The resume path: `_onResumed` calls refresh() before anything else.
      await container.read(locationAccessProvider.notifier).refresh();
      expect(
        container.read(locationAccessProvider),
        LocationAccessStatus.available,
        reason: 'refresh() must re-arm and re-decide, or suspend() would be a '
            'one-way door',
      );

      // ...and the watchdog is genuinely live again, not merely correct once.
      service.serviceEnabled = false;
      await _settle();
      expect(container.read(locationAccessProvider),
          LocationAccessStatus.serviceDisabled);
    });
  });

  group('LocationAccessNotifier.classify (pure, exhaustive)', () {
    test('granted + service on → available', () {
      for (final granted in [
        LocationPermissionStatus.whileInUse,
        LocationPermissionStatus.always,
      ]) {
        for (final everGranted in [true, false]) {
          expect(
            LocationAccessNotifier.classify(
              serviceEnabled: true,
              permission: granted,
              everGranted: everGranted,
            ),
            LocationAccessStatus.available,
            reason: '$granted, everGranted=$everGranted',
          );
        }
      }
    });

    test('granted + service off → serviceDisabled', () {
      for (final everGranted in [true, false]) {
        expect(
          LocationAccessNotifier.classify(
            serviceEnabled: false,
            permission: LocationPermissionStatus.always,
            everGranted: everGranted,
          ),
          LocationAccessStatus.serviceDisabled,
          reason: 'everGranted=$everGranted',
        );
      }
    });

    test('service on + an askable denial → permissionDenied ONLY once access '
        'was held', () {
      // `denied` and `notDetermined` are the same class of answer: "not
      // granted, and the OS will still let you ask". On iOS `denied` is
      // literally what a NEVER-ASKED device reports
      // (`AuthorizationStatusMapper.m` folds `kCLAuthorizationStatusNotDetermined`
      // and `kCLAuthorizationStatusRestricted` into it), so calling it a
      // revocation is wrong by construction until Haven has held access.
      for (final p in [
        LocationPermissionStatus.denied,
        LocationPermissionStatus.notDetermined,
      ]) {
        expect(
          LocationAccessNotifier.classify(
            serviceEnabled: true,
            permission: p,
            everGranted: true,
          ),
          LocationAccessStatus.permissionDenied,
          reason: '$p after access was held is a revocation',
        );
        expect(
          LocationAccessNotifier.classify(
            serviceEnabled: true,
            permission: p,
            everGranted: false,
          ),
          LocationAccessStatus.available,
          reason: '$p with access never held is "not yet granted", and a '
              'restricted (MDM / Screen Time) device — which Haven cannot '
              'tell apart from never-asked — must never be told to grant '
              'something it is forbidden to grant',
        );
      }
    });

    test('service on + deniedForever → permissionPermanentlyDenied, always',
        () {
      // Exempt from the never-granted rule: an unambiguous "no" the app can no
      // longer prompt for is worth saying whether or not access was ever held.
      for (final everGranted in [true, false]) {
        expect(
          LocationAccessNotifier.classify(
            serviceEnabled: true,
            permission: LocationPermissionStatus.deniedForever,
            everGranted: everGranted,
          ),
          LocationAccessStatus.permissionPermanentlyDenied,
          reason: 'everGranted=$everGranted',
        );
      }
    });

    test('service off + a held-then-lost permission → the combined state', () {
      for (final p in [
        LocationPermissionStatus.denied,
        LocationPermissionStatus.notDetermined,
      ]) {
        expect(
          LocationAccessNotifier.classify(
            serviceEnabled: false,
            permission: p,
            everGranted: true,
          ),
          LocationAccessStatus.serviceDisabledAndPermissionDenied,
          reason: '$p',
        );
      }
      // deniedForever needs no history to be believed.
      expect(
        LocationAccessNotifier.classify(
          serviceEnabled: false,
          permission: LocationPermissionStatus.deniedForever,
          everGranted: false,
        ),
        LocationAccessStatus.serviceDisabledAndPermissionDenied,
      );
    });

    test('service off + never-granted askable denial names only the service',
        () {
      // The device toggle is unambiguous; the permission half is not. Naming
      // both would attach an accusation Haven cannot support to the one claim
      // it can, and the user acting on the wrong half is left still broken.
      for (final p in [
        LocationPermissionStatus.denied,
        LocationPermissionStatus.notDetermined,
      ]) {
        expect(
          LocationAccessNotifier.classify(
            serviceEnabled: false,
            permission: p,
            everGranted: false,
          ),
          LocationAccessStatus.serviceDisabled,
          reason: '$p',
        );
      }
    });

    test('isBlocked is true for every status except available', () {
      for (final status in LocationAccessStatus.values) {
        expect(
          status.isBlocked,
          status != LocationAccessStatus.available,
          reason: '$status',
        );
      }
    });
  });

  // -------------------------------------------------------------------------
  // Stale position — the provider half of the decision
  // -------------------------------------------------------------------------

  group('stale position', () {
    test('entering blocked clears the shared own-location', () async {
      // `obfuscatedLocationProvider` is what the circles sheet uses to centre
      // on "me". Leaving it populated would let another surface keep treating
      // a pre-outage fix as the user's current position.
      final container = harness();
      container.read(obfuscatedLocationProvider.notifier).state =
          const LatLng(51.5, -0.12);

      service.serviceEnabled = false;
      await _settle();

      expect(container.read(locationAccessProvider).isBlocked, isTrue);
      expect(container.read(obfuscatedLocationProvider), isNull);
    });

    test('a healthy session never clears the own-location', () async {
      final container = harness();
      container.read(obfuscatedLocationProvider.notifier).state =
          const LatLng(51.5, -0.12);

      service.controller.add(_position());
      await _settle();

      expect(container.read(obfuscatedLocationProvider), isNotNull);
    });
  });

  // -------------------------------------------------------------------------
  // Standing: the surface must not pre-empt the disclosure flow
  // -------------------------------------------------------------------------

  group('disclosure gate', () {
    test('stays quiet before the prominent disclosure is accepted, and '
        'surfaces the moment it is granted', () async {
      // Pre-consent, "no location" is the user's own choice and the map
      // already says so in its own empty state. A fault claim here would be
      // both wrong and a second, contradictory surface.
      //
      // Both halves are ONE test on purpose. A standalone "stays available"
      // assertion is satisfied by a watchdog that never fired at all — the
      // provider starts `available` — so it would keep passing if the whole
      // probe were deleted. Flipping the flag under the SAME still-ticking
      // watchdog is what proves it was running and chose to stay quiet.
      final container = harness(disclosureAccepted: false);
      service
        ..serviceEnabled = false
        ..permission = LocationPermissionStatus.denied;
      await _settle();

      expect(
        container.read(locationAccessProvider),
        LocationAccessStatus.available,
        reason: 'the disclosure flow owns the user\'s attention until it is '
            'answered',
      );

      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(kLocationDisclosureAcceptedKey, true);
      await _settle();

      expect(
        container.read(locationAccessProvider).isBlocked,
        isTrue,
        reason: 'Same platform state, same watchdog, same container — the ONLY '
            'thing that changed is the disclosure flag. So the quiet above was '
            'the gate, not a probe that never ran.',
      );
    });

    test('reads the PERSISTED flag, not in-memory disclosure state', () async {
      // The gate deliberately consults SharedPreferences and nothing else.
      // `LocationDisclosureController.ensureDisclosed` persists before it
      // publishes anything in memory, and `_syncFromPrefs` derives memory FROM
      // prefs, so prefs is never behind — which is what makes the in-memory
      // read that used to sit in front of this both redundant and unreachable
      // as load-bearing. The ordering that guarantee rests on is pinned in
      // `location_disclosure_provider_test.dart`; this pins that the gate
      // still works with no disclosure controller in the picture at all.
      final container = harness();
      service.serviceEnabled = false;
      await _settle();

      expect(container.read(locationAccessProvider).isBlocked, isTrue);
    });
  });

  // -------------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------------

  group('lifecycle', () {
    test('refresh() is safe after disposal', () async {
      final container = harness();
      final notifier = container.read(locationAccessProvider.notifier);
      service.serviceEnabled = false;
      container.dispose();

      // Must not throw "Cannot use a Notifier after it was disposed".
      await expectLater(notifier.refresh(), completes);
    });
  });
}
