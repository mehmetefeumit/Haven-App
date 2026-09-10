/// iOS-only bridge to Haven's own CoreLocation updates session.
///
/// On iOS the geolocator plugin no longer owns the position stream:
/// `HavenLocationStreamHandler` does. The plugin can only start and stop a
/// session, and this phase needs `desiredAccuracy` changed LIVE on a running
/// manager — the only lever that ends a receiver held at
/// `kCLLocationAccuracyBest` 24/7 while the device sits on a desk. It is not
/// the dominant drain, and this file used to say it was: model E ESTIMATES the
/// iOS location term at 1.2–1.8 %/h against a radio term of 0.47–3.12 %/h, and
/// its finding 2 makes the radio the wider uncertainty of the two
/// (`docs/POWER_EFFICIENCY_PLAN.md` §6.5a). Nothing here was measured; there is
/// no iPhone (§2.5).
///
/// ## What this class owns
///
/// The channel half (an [EventChannel] of fixes, a [MethodChannel] for the
/// profile write, the last-Best cache and the status read) and the PURE
/// [IosProfileController] that decides which of the two accuracy tiers the
/// session should be running at, plus the single timer that re-arms the
/// controller's confirm deadline. The controller lives here, in Dart, and not
/// in Swift, because nothing runs Swift unit tests in CI: this is the phase's
/// only non-trivial logic and it has to be testable.
///
/// ## Only-Best
///
/// `INV-L-IOS-PUBLISH-INPUT-BEST-PROFILE-ONLY`. Exactly two accuracy values
/// are ever requested (a third, coarser tier recreates the shape iOS 16.4
/// suspends), and only fixes DELIVERED UNDER THE BEST PROFILE leave this
/// class. A 100 m-tier fix — including a fix computed under the old tier that
/// arrives just after a switch, which the native side tags `hundredMeters` for
/// exactly this reason — feeds the movement detector and the freshness bound
/// and nothing else. It is never emitted, so it can never be cached as the
/// publish input and can never reach the motion trigger, whose sole input is
/// this stream.
///
/// ## Errors
///
/// Every native outcome arrives through the event SINK, never as a thrown
/// `listen`: Flutter passes an exception from the platform `listen` call to
/// `FlutterError.reportError` and never adds it to the stream, so a refusal
/// reported that way would leave subscribers waiting forever. A refused
/// background-capable start (iOS will not start one from the background —
/// the 2026-08-20 field failure) arrives as a `background_start_refused`
/// [PlatformException] followed by the end of the stream.
///
/// An error that arrives WITHOUT an end of stream is not a dead session:
/// CoreLocation reports a failure and keeps the manager running at the tier it
/// was on. The reset that follows one therefore re-asserts the tier natively
/// instead of assuming it — see `_requestedProfile`.
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/services/location_service.dart';
import 'package:haven/src/utils/geo_distance.dart';

/// The two — and only two — CoreLocation accuracy tiers Haven ever requests.
enum IosLocationProfile {
  /// `kCLLocationAccuracyBest`: foregrounded, or moving.
  best,

  /// `kCLLocationAccuracyHundredMeters`: backgrounded AND stationary.
  ///
  /// Still inside Apple's continuous-background-updates shape (numeric
  /// accuracy at or below 100 m, no distance filter), which is why the tier
  /// below it does not exist here.
  hundredMeters;

  /// The wire name shared with the native handler, for both the `setProfile`
  /// argument and the `profile` field of a fix and of `status`.
  String get wireName => name;

  /// Parses [raw] from the native side, or null when it is absent or not one
  /// of the two names.
  static IosLocationProfile? fromWire(Object? raw) => switch (raw) {
    'best' => IosLocationProfile.best,
    'hundredMeters' => IosLocationProfile.hundredMeters,
    _ => null,
  };
}

/// One CoreLocation fix as the native handler reports it.
///
/// Deliberately without a `toString` carrying coordinates: this type crosses
/// the whole controller, and an interpolation of it in a log line would be a
/// plaintext position in the device log (Security Rule 6/8).
@immutable
class IosFix {
  /// Creates an [IosFix].
  const IosFix({
    required this.latitude,
    required this.longitude,
    required this.timestamp,
    required this.accuracy,
    required this.profile,
    this.altitude,
    this.speed,
    this.course,
  });

  /// WGS-84 latitude in degrees.
  final double latitude;

  /// WGS-84 longitude in degrees.
  final double longitude;

  /// When CoreLocation computed the fix — the clock every decision here uses.
  final DateTime timestamp;

  /// Horizontal accuracy in metres.
  final double accuracy;

  /// The profile the session was running at when this fix was COMPUTED, as
  /// judged natively against the instant of the last switch to Best.
  final IosLocationProfile profile;

  /// Altitude in metres, when the platform reported one.
  final double? altitude;

  /// Ground speed in m/s, when the platform reported one.
  final double? speed;

  /// Course in degrees, when the platform reported one.
  final double? course;

  /// The app-wide position type. Only ever called for a Best-profile fix.
  Position toPosition() => Position(
    latitude: latitude,
    longitude: longitude,
    timestamp: timestamp,
    accuracy: accuracy,
    altitude: altitude,
    speed: speed,
    heading: course,
  );
}

/// What the native updates session is currently doing.
///
/// Every field is parsed FAIL-CLOSED: a missing or wrong-typed key answers in
/// the direction that cannot lose publishing or start something iOS refuses —
/// notably [backgrounded], which defaults to `true` so an unreadable lifecycle
/// can never let a background-launched process start the doomed one-shot.
///
/// Mirrors the six keys `HavenLocationStreamHandler.status()` emits, and only
/// those. The `alwaysConfirmed` predicate is deliberately NOT one of them: it
/// is owned and exported by `HavenBackgroundSessionHandler` on its own channel
/// (`IosBackgroundSessionStatus`), which is what the indicator copy selects
/// on. Declared here it could only ever read `false`, and a fallback that
/// silently disagrees with the owner would tell a user watching the blue bar
/// that they are looking at the arrow.
@immutable
class IosLocationStreamStatus {
  /// Creates an [IosLocationStreamStatus].
  const IosLocationStreamStatus({
    required this.running,
    required this.allowsBackgroundLocationUpdates,
    required this.showsBackgroundLocationIndicator,
    required this.profile,
    required this.authorization,
    required this.backgrounded,
  });

  /// The reading for a status that could not be obtained at all.
  static const IosLocationStreamStatus unknown = IosLocationStreamStatus(
    running: false,
    allowsBackgroundLocationUpdates: false,
    showsBackgroundLocationIndicator: false,
    profile: IosLocationProfile.best,
    authorization: 'unknown',
    backgrounded: true,
  );

  /// Whether `startUpdatingLocation()` is in effect.
  final bool running;

  /// Whether the running session is background-capable.
  final bool allowsBackgroundLocationUpdates;

  /// Whether the manager is asking for the blue location bar. The OS ignores
  /// the flag under When-In-Use, where the bar is mandatory anyway.
  final bool showsBackgroundLocationIndicator;

  /// The accuracy tier the session is running at.
  final IosLocationProfile profile;

  /// `CLAuthorizationStatus` as an enum NAME — never a coordinate, never a
  /// user identifier.
  final String authorization;

  /// Whether UIKit reports the app as backgrounded.
  final bool backgrounded;
}

/// Bridge to the native iOS location updates session.
abstract class IosLocationSource {
  /// The session's Best-profile fixes.
  ///
  /// One subscriber by construction (the location service's single stream
  /// owner). [allowsBackgroundLocationUpdates] is the user's background
  /// sharing intent and reaches `CLLocationManager` unchanged; the native
  /// side REFUSES a background-capable start while the app is backgrounded
  /// and reports that through the stream as an error.
  Stream<Position> positions({required bool allowsBackgroundLocationUpdates});

  /// The last fix the session delivered under the Best profile, or null.
  ///
  /// The iOS last-known source: the geolocator plugin's own manager is never
  /// started under this owner, so what its `getLastKnownPosition` would return
  /// is undefined.
  Future<Position?> lastBestFix();

  /// Drops the native copy of the last Best fix AND the profile controller's
  /// anchor, which is the same coordinate held a third time.
  ///
  /// Called wherever the Dart cache is dropped, so a plaintext coordinate can
  /// never survive in one copy after another was cleared.
  Future<void> clearLastBestFix();

  /// Reports the app's foreground state. A foregrounded session is always at
  /// Best; backgrounding starts the stationary dwell.
  void onForeground({required bool foregrounded});

  /// When the last Best fix was last confirmed to still describe where the
  /// device is, or null when nothing has confirmed it since it was taken.
  DateTime? get lastConfirmedAt;

  /// Reads the native session's state.
  Future<IosLocationStreamStatus> status();
}

/// Returns the platform-appropriate [IosLocationSource]: the channel-backed
/// owner on iOS, a source that never delivers anywhere else (Android's
/// position stream stays on geolocator).
IosLocationSource createIosLocationSource() => Platform.isIOS
    ? MethodChannelIosLocationSource()
    : const NoopIosLocationSource();

/// The stationary/moving decision behind the two accuracy profiles.
///
/// PURE: no clock, no timer, no channel. Every transition is driven by the
/// timestamp of the fix that caused it, and the confirm deadline is a function
/// of a caller-supplied `now` — so the whole state machine is exercised on
/// fixed [DateTime]s.
///
/// The rules, and what each one is protecting:
/// * Foreground is always Best. Somebody is looking at the map.
/// * Backgrounded, the profile drops only after [kStationaryDwell] without a
///   [kMotionTriggerDistanceMeters] displacement — one full publish cadence of
///   evidence before coarsening the input to a publish.
/// * Under the coarse profile a fix no coarser than
///   [kStationaryConfirmMaxAccuracyMeters] either CONFIRMS the anchor (inside
///   the trigger distance) or returns the session to Best (at or beyond it).
///   Anything coarser does neither: it cannot resolve the distance it is being
///   asked about.
/// * Nothing confirming within [kStationaryConfirmMaxAge] returns the session
///   to Best and restarts the dwell — the honest fallback when the OS delivers
///   nothing usable, and what stops a Best/100 m flap in good signal (a
///   confirming fix re-arms the deadline instead).
/// * A confirmation may extend the anchor's life but may not make it
///   immortal. Once the anchor's OWN timestamp is [kStationaryAnchorMaxAge]
///   behind, the session returns to Best to take a real fix however many
///   confirmations have arrived — the only thing that bounds how old a
///   published coordinate can be, because the wire carries the publish
///   instant and not the fix's (OD-P3-e).
class IosProfileController {
  IosLocationProfile _profile = IosLocationProfile.best;
  bool _foreground = true;
  IosFix? _anchor;
  DateTime? _movedAt;
  DateTime? _confirmedAt;

  /// The tier the session should be running at.
  IosLocationProfile get profile => _profile;

  /// The last Best-profile fix — the reference every displacement is measured
  /// from, and the coordinate a confirmation vouches for.
  IosFix? get anchor => _anchor;

  /// When the anchor was last confirmed, or null while at Best.
  DateTime? get confirmedAt => _confirmedAt;

  /// Records a lifecycle transition at [now].
  void onForeground({required bool foregrounded, required DateTime now}) {
    _foreground = foregrounded;
    if (foregrounded) {
      _profile = IosLocationProfile.best;
      _confirmedAt = null;
      return;
    }
    // The dwell starts at the backgrounding instant: an app that has been open
    // has been moving as far as this controller knows.
    _movedAt = now;
  }

  /// Folds one delivered fix into the decision.
  void onFix(IosFix fix) {
    if (_profile == IosLocationProfile.hundredMeters) {
      _onCoarseProfileFix(fix);
      return;
    }
    // At Best, a fix TAGGED `hundredMeters` was computed under the previous
    // tier (the native `bestSince` rule). It may not become the anchor: the
    // reference for the next displacement has to be a Best coordinate.
    if (fix.profile != IosLocationProfile.best) return;

    final previous = _anchor;
    _anchor = fix;
    if (previous != null &&
        _distance(previous, fix) >= kMotionTriggerDistanceMeters) {
      _movedAt = fix.timestamp;
    }
    final movedAt = _movedAt;
    if (!_foreground &&
        movedAt != null &&
        fix.timestamp.difference(movedAt) >= kStationaryDwell) {
      _profile = IosLocationProfile.hundredMeters;
      // The fix that drops the profile is itself the first confirmation, or
      // the deadline below would fire against nothing.
      _confirmedAt = fix.timestamp;
    }
  }

  void _onCoarseProfileFix(IosFix fix) {
    if (fix.accuracy > kStationaryConfirmMaxAccuracyMeters) return;
    final anchor = _anchor;
    if (anchor == null) return;
    if (_distance(anchor, fix) >= kMotionTriggerDistanceMeters) {
      // Moved. The anchor stays put until the first Best fix replaces it.
      _profile = IosLocationProfile.best;
      _movedAt = fix.timestamp;
      _confirmedAt = null;
      return;
    }
    if (fix.timestamp.difference(anchor.timestamp) > kStationaryAnchorMaxAge) {
      // Still here — but the coordinate itself is now too old to serve, so
      // this fix breaks the confirmation chain instead of extending it. The
      // break happens on the DELIVERY and not only on the deadline timer: a
      // suspended app services the fix that woke it, and an overdue timer must
      // never be what stands between a peer and a coordinate this class
      // already knows is stale. The dwell is deliberately left running — see
      // [onDeadline].
      _profile = IosLocationProfile.best;
      _confirmedAt = null;
      return;
    }
    _confirmedAt = fix.timestamp;
  }

  /// How long until the next escalation deadline, or null while neither
  /// applies. Never negative: an overdue deadline is due now.
  ///
  /// The EARLIER of the two: [kStationaryConfirmMaxAge] since the last
  /// confirmation, and [kStationaryAnchorMaxAge] since the anchor was taken.
  /// The first bounds a session nothing is vouching for, the second one that is
  /// being vouched for indefinitely. (The coarse tier is only ever entered by a
  /// fix that becomes the anchor, so the null check on it is what the type
  /// system needs rather than a state to defend against.)
  Duration? nextDeadline(DateTime now) {
    final confirmedAt = _confirmedAt;
    final anchor = _anchor;
    if (_profile != IosLocationProfile.hundredMeters ||
        confirmedAt == null ||
        anchor == null) {
      return null;
    }
    final unconfirmed = kStationaryConfirmMaxAge - now.difference(confirmedAt);
    final anchorLeft =
        kStationaryAnchorMaxAge - now.difference(anchor.timestamp);
    final remaining = unconfirmed < anchorLeft ? unconfirmed : anchorLeft;
    return remaining.isNegative ? Duration.zero : remaining;
  }

  /// A deadline from [nextDeadline] came due: return to Best.
  ///
  /// WHICH of the two came due decides whether the dwell restarts, and they are
  /// told apart from state rather than from a flag, so a timer that fires late
  /// cannot pick the wrong branch:
  ///
  /// * **Nothing confirmed** ([kStationaryConfirmMaxAge]). An absence of
  ///   evidence: the next drop must re-earn a fresh [kStationaryDwell] of
  ///   stillness, which is also what stops a Best/100 m flap in poor signal.
  /// * **The anchor aged out** ([kStationaryAnchorMaxAge]) while confirmations
  ///   kept arriving. The evidence of stillness is intact and only the
  ///   COORDINATE is old, so the dwell is left running: the next Best fix
  ///   re-anchors and either shows a displacement — which [onFix] answers with
  ///   a dwell restart, on GPS truth rather than on the coarse fixes that
  ///   missed it — or returns the session to the coarse tier at once.
  ///   Restarting the dwell here would spend a [kStationaryDwell] at Best on
  ///   every expiry to re-learn what the confirmations already established —
  ///   ≈ 29 % of the time at Best, against the ≈ 1 % a delivery-only excursion
  ///   costs. Both duties are ESTIMATED from the cycle arithmetic (see
  ///   [kStationaryAnchorMaxAge]); no device has measured a profile duty, and
  ///   none can while there is no iPhone
  ///   (`docs/POWER_EFFICIENCY_PLAN.md` §2.5, §6.5a).
  void onDeadline(DateTime now) {
    final confirmedAt = _confirmedAt;
    _profile = IosLocationProfile.best;
    _confirmedAt = null;
    if (confirmedAt == null ||
        now.difference(confirmedAt) >= kStationaryConfirmMaxAge) {
      _movedAt = now;
    }
  }

  /// Returns to the start state. The next session begins at Best by
  /// construction, and a dead session vouches for nothing.
  void reset() {
    _profile = IosLocationProfile.best;
    _anchor = null;
    _movedAt = null;
    _confirmedAt = null;
  }

  /// Drops the anchor — the third and last full-precision coordinate a live
  /// session holds — and returns to Best with the dwell restarted at [now].
  ///
  /// Called wherever the other two copies go (logout, a toggle-off pause, an
  /// observed access loss), so no full-precision coordinate outlives the
  /// consent that produced it on ANY of the three sides. Unlike [reset] the
  /// session is still running, so the dwell restarts from [now] rather than
  /// being cleared: a null `_movedAt` can only be re-armed by backgrounding,
  /// which would strand a backgrounded session at Best for the rest of its
  /// life.
  ///
  /// Returning to Best is not optional. Without an anchor the coarse tier can
  /// neither confirm stillness nor measure a displacement, so leaving the
  /// session there would leave it at a tier that decides nothing.
  void forgetAnchor(DateTime now) {
    _anchor = null;
    _profile = IosLocationProfile.best;
    _movedAt = now;
    _confirmedAt = null;
  }

  static double _distance(IosFix a, IosFix b) =>
      haversineMeters(a.latitude, a.longitude, b.latitude, b.longitude);
}

/// Channel-backed [IosLocationSource] talking to `HavenLocationStreamHandler`.
class MethodChannelIosLocationSource implements IosLocationSource {
  /// Creates a [MethodChannelIosLocationSource].
  MethodChannelIosLocationSource();

  /// The method channel shared with the native handler.
  @visibleForTesting
  static const MethodChannel methodChannel = MethodChannel(
    'haven.app/ios_location_stream',
  );

  /// The event channel carrying fixes and every native refusal.
  @visibleForTesting
  static const EventChannel eventChannel = EventChannel(
    'haven.app/ios_location_stream/events',
  );

  final IosProfileController _controller = IosProfileController();

  /// The single confirm timer, armed from [IosProfileController.nextDeadline].
  Timer? _confirmTimer;

  /// The profile the native session was last ASKED for, so a transition costs
  /// exactly one channel write and a steady state costs none.
  ///
  /// Null means the native tier is UNKNOWN, which is what a failure this class
  /// did not choose leaves behind: CoreLocation reports an error WITHOUT
  /// stopping the manager, so the session keeps running at whatever tier it
  /// was on while the controller resets to Best. The next [_applyProfile] then
  /// re-issues the write unconditionally instead of suppressing it as a
  /// no-op — without that, a session that failed while coarse stayed coarse
  /// for ever: every later fix arrived tagged `hundredMeters`, the only-Best
  /// rule dropped it, and no transition was left to repair the desync.
  IosLocationProfile? _requestedProfile = IosLocationProfile.best;

  @override
  DateTime? get lastConfirmedAt => _controller.confirmedAt;

  @override
  Stream<Position> positions({required bool allowsBackgroundLocationUpdates}) {
    // `sync: true`, like the location service's own outer controller: an async
    // controller inserts a microtask between the platform fix and every
    // subscriber, which is one turn for a rebuild to cancel the subscription
    // in and lose the fix.
    final out = StreamController<Position>(sync: true);
    // Released by `out`'s onCancel and by the native stream's own onDone,
    // neither of which the `cancel_subscriptions` lint recognises.
    // ignore: cancel_subscriptions
    StreamSubscription<Object?>? native;
    out
      ..onListen = () {
        _resetSession();
        native = eventChannel
            .receiveBroadcastStream(<String, Object?>{
              'allowsBackgroundLocationUpdates':
                  allowsBackgroundLocationUpdates,
            })
            .listen(
              (event) => _onNativeEvent(event, out),
              onError: (Object error, StackTrace stackTrace) {
                // The one reset that does NOT end the session: a CoreLocation
                // failure leaves the manager running at whatever tier it was
                // on, so the controller's return to Best has to be written
                // through rather than assumed.
                _resetSession(nativeTierUnknown: true);
                _applyProfile();
                out.addError(error, stackTrace);
              },
              onDone: () {
                // Dropped BEFORE the close: `onCancel` below runs as part of
                // delivering the done event, and a `cancel()` issued there
                // against a subscription that is itself mid-`onDone` never
                // completes — which would strand the done event the location
                // service reads as "no further fix will arrive", leaving a
                // coordinate servable for the rest of kStreamPositionMaxAge
                // after the session died.
                native = null;
                _resetSession();
                unawaited(out.close());
              },
            );
      }
      // Not `async`: a returned future makes the framework defer the done
      // event until it completes, for no gain — the reset is synchronous.
      ..onCancel = () {
        _resetSession();
        final pending = native;
        native = null;
        return pending?.cancel();
      };
    return out.stream;
  }

  void _onNativeEvent(Object? event, StreamController<Position> out) {
    final fix = _fixFromWire(event);
    if (fix == null) {
      // A wire-shape mismatch carries no usable coordinate, and killing the
      // session over one would end background publishing outright.
      debugPrint('[IosLocationSource] unparseable fix event dropped');
      return;
    }
    _controller.onFix(fix);
    _applyProfile();
    if (fix.profile == IosLocationProfile.best) out.add(fix.toPosition());
  }

  @override
  void onForeground({required bool foregrounded}) {
    _controller.onForeground(foregrounded: foregrounded, now: clock.now());
    _applyProfile();
  }

  @override
  Future<Position?> lastBestFix() async {
    try {
      final raw = await methodChannel.invokeMapMethod<String, Object?>(
        'lastBestFix',
      );
      return _fixFromWire(raw)?.toPosition();
    } on PlatformException catch (e) {
      debugPrint('[IosLocationSource] lastBestFix failed: ${e.code}');
    } on MissingPluginException {
      debugPrint('[IosLocationSource] lastBestFix: no native handler');
    }
    return null;
  }

  @override
  Future<void> clearLastBestFix() {
    // THREE copies of the last Best fix exist while a session runs: the native
    // one, the location service's `_lastStreamPosition`, and the controller's
    // anchor. They clear together or the guarantee is not a guarantee.
    _controller.forgetAnchor(clock.now());
    _applyProfile();
    return _invoke('clearLastBestFix');
  }

  @override
  Future<IosLocationStreamStatus> status() async {
    try {
      final raw = await methodChannel.invokeMapMethod<String, Object?>(
        'status',
      );
      if (raw == null) return IosLocationStreamStatus.unknown;
      return IosLocationStreamStatus(
        running: _boolOr(raw['running'], fallback: false),
        allowsBackgroundLocationUpdates: _boolOr(
          raw['allowsBackgroundLocationUpdates'],
          fallback: false,
        ),
        showsBackgroundLocationIndicator: _boolOr(
          raw['showsBackgroundLocationIndicator'],
          fallback: false,
        ),
        profile:
            IosLocationProfile.fromWire(raw['profile']) ??
            IosLocationProfile.best,
        authorization: raw['authorization'] is String
            ? raw['authorization']! as String
            : 'unknown',
        // The one key whose fallback is load-bearing: an unreadable lifecycle
        // must read as backgrounded.
        backgrounded: _boolOr(raw['backgrounded'], fallback: true),
      );
    } on PlatformException catch (e) {
      debugPrint('[IosLocationSource] status failed: ${e.code}');
    } on MissingPluginException {
      debugPrint('[IosLocationSource] status: no native handler');
    }
    return IosLocationStreamStatus.unknown;
  }

  /// Writes the controller's decision to the running manager, and re-arms the
  /// confirm deadline. A property write: it publishes nothing and opens no
  /// socket.
  void _applyProfile() {
    final wanted = _controller.profile;
    if (wanted != _requestedProfile) {
      _requestedProfile = wanted;
      unawaited(_invoke('setProfile', wanted.wireName));
    }
    _armConfirmTimer();
  }

  void _armConfirmTimer() {
    _confirmTimer?.cancel();
    final due = _controller.nextDeadline(clock.now());
    if (due == null) {
      _confirmTimer = null;
      return;
    }
    _confirmTimer = Timer(due, () {
      _controller.onDeadline(clock.now());
      _applyProfile();
    });
  }

  /// Drops every trace of a session: the timer, the state machine, and the
  /// belief about which profile the native side is running at.
  ///
  /// [nativeTierUnknown] separates the two kinds of reset. A session that
  /// STARTS, ends or is cancelled leaves the native side at Best by
  /// construction (`onListen` writes it, `onCancel` stops the manager), so the
  /// belief is exact. A session that merely FAILED is still running at
  /// whatever tier it reached, and recording Best there is a lie that
  /// suppresses the very write that would repair it.
  void _resetSession({bool nativeTierUnknown = false}) {
    _confirmTimer?.cancel();
    _confirmTimer = null;
    _controller.reset();
    _requestedProfile = nativeTierUnknown ? null : IosLocationProfile.best;
  }

  Future<void> _invoke(String method, [Object? argument]) async {
    try {
      await methodChannel.invokeMethod<void>(method, argument);
    } on PlatformException catch (e) {
      debugPrint('[IosLocationSource] $method failed: ${e.code}');
    } on MissingPluginException {
      debugPrint('[IosLocationSource] $method: no native handler');
    }
  }
}

/// [IosLocationSource] for every platform that is not iOS.
///
/// Android's position stream stays on geolocator, so nothing here is ever
/// consulted; the stream still never COMPLETES, because a completed position
/// stream reads as an outage to every listener including the access watchdog.
class NoopIosLocationSource implements IosLocationSource {
  /// Creates a [NoopIosLocationSource].
  const NoopIosLocationSource();

  @override
  Stream<Position> positions({required bool allowsBackgroundLocationUpdates}) {
    final idle = StreamController<Position>();
    idle.onCancel = idle.close;
    return idle.stream;
  }

  @override
  Future<Position?> lastBestFix() async => null;

  @override
  Future<void> clearLastBestFix() async {}

  @override
  void onForeground({required bool foregrounded}) {}

  @override
  DateTime? get lastConfirmedAt => null;

  @override
  Future<IosLocationStreamStatus> status() async =>
      IosLocationStreamStatus.unknown;
}

bool _boolOr(Object? raw, {required bool fallback}) =>
    raw is bool ? raw : fallback;

/// Parses the native fix map, or null when any field it needs is absent or
/// wrong-typed.
IosFix? _fixFromWire(Object? raw) {
  if (raw is! Map) return null;
  final latitude = raw['lat'];
  final longitude = raw['lon'];
  final timestampMs = raw['tsMs'];
  final accuracy = raw['acc'];
  final profile = IosLocationProfile.fromWire(raw['profile']);
  if (latitude is! double ||
      longitude is! double ||
      timestampMs is! int ||
      accuracy is! double ||
      profile == null) {
    return null;
  }
  return IosFix(
    latitude: latitude,
    longitude: longitude,
    timestamp: DateTime.fromMillisecondsSinceEpoch(timestampMs),
    accuracy: accuracy,
    profile: profile,
    altitude: raw['alt'] is double ? raw['alt']! as double : null,
    speed: raw['speed'] is double ? raw['speed']! as double : null,
    course: raw['course'] is double ? raw['course']! as double : null,
  );
}
