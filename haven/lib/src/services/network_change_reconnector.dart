import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:haven/src/services/mls_session_handover.dart';
import 'package:haven/src/services/network_change_source.dart';

/// How long the default network must stay unchanged before the engine
/// re-dials.
///
/// Leaving airplane mode, or walking out of Wi-Fi range, often lands as two
/// changes a second or two apart (cellular comes up, then Wi-Fi takes the
/// default), and each re-dial costs a TLS dial per relay. Three seconds
/// coalesces that pair into one re-dial while a foregrounded app is still left
/// on dead sockets for seconds, not the 55-110 s the pool's ping would take.
const Duration kNetworkChangeSettle = Duration(seconds: 3);

/// The least time between two re-dials on iOS (owner decision N3,
/// 2026-11-20).
///
/// `NWPathMonitor` reports path updates the normalised key cannot all tell
/// apart from a new network, and nothing on device has measured how often.
/// Android's callback names the network itself and needs no floor.
const Duration kIosNetworkReconnectFloor = Duration(seconds: 30);

/// Re-dials the live-sync engine once the device's default network has
/// changed and stayed put for [kNetworkChangeSettle].
///
/// One re-dial at a time: a change that lands while one runs is handled by
/// exactly one more once it ends. A change is never handed to the engine
/// unless the app is resumed at that moment (`appIsResumed`) — the engine
/// would refuse it — and is kept owed until [onResumed]: pulling down the
/// notification shade leaves the app `inactive` without pausing it, and the
/// network can change under it. A pause ([stop]) forgets an owed change: the
/// next resume opens the session anew.
///
/// A failed re-dial is not retried here: the engine leaves the session paused
/// and the heal re-anchors it.
class NetworkChangeReconnector {
  /// Creates a reconnector over [source] that calls [reconnect].
  ///
  /// [floor] is the least time between two re-dials; the latest change is
  /// still handled once it has elapsed.
  NetworkChangeReconnector({
    required NetworkChangeSource source,
    required Future<void> Function() reconnect,
    Duration floor = Duration.zero,
    Duration settle = kNetworkChangeSettle,
    bool Function() isResumed = appIsResumed,
  }) : _source = source,
       _reconnect = reconnect,
       _floor = floor,
       _settle = settle,
       _isResumed = isResumed;

  final NetworkChangeSource _source;
  final Future<void> Function() _reconnect;
  final Duration _floor;
  final Duration _settle;
  final bool Function() _isResumed;

  StreamSubscription<void>? _changes;
  Timer? _timer;
  bool _owed = false;
  bool _inFlight = false;
  DateTime? _lastRunAt;

  /// Listens for changes, unless already listening: listening again would
  /// re-take the native baseline and lose a change that is owed.
  void start() {
    _changes ??= _source.changes().listen((_) => _onChange());
  }

  /// [start] at a mount, only in an app that reads `resumed`: a process the
  /// OS relaunched in the background has no foreground session to re-dial.
  void startAtMount() {
    if (_isResumed()) start();
  }

  /// At every `resumed` dispatch: listens again after a pause, and runs a
  /// change that arrived while the app was not resumed.
  void onResumed() {
    start();
    _runIfDue();
  }

  /// At a pause, a detach and dispose: stops listening and forgets a change
  /// that is owed or settling. A re-dial already running finishes, and none
  /// follows it.
  void stop() {
    unawaited(_changes?.cancel());
    _changes = null;
    _timer?.cancel();
    _timer = null;
    _owed = false;
  }

  void _onChange() {
    _owed = true;
    _arm();
  }

  /// The one timer: this change's settle, or what is left of the floor since
  /// the last re-dial began, the later of the two. No re-dial can begin while
  /// it is pending, so the floor has always passed when it fires.
  void _arm() {
    _timer?.cancel();
    final floorLeft = _floorLeft();
    _timer = Timer(floorLeft > _settle ? floorLeft : _settle, () {
      _timer = null;
      _runIfDue();
    });
  }

  Duration _floorLeft() {
    final last = _lastRunAt;
    if (last == null) return Duration.zero;
    final left = _floor - clock.now().difference(last);
    return left.isNegative ? Duration.zero : left;
  }

  void _runIfDue() {
    if (!_owed || _inFlight || _timer != null || _changes == null) return;
    if (!_isResumed()) return;
    unawaited(_run());
  }

  Future<void> _run() async {
    _owed = false;
    _inFlight = true;
    _lastRunAt = clock.now();
    debugPrint('[NetworkChange] the default network changed: re-dialling');
    try {
      await _reconnect();
    } on Object catch (e) {
      // The type only (Rule 8): an FFI error string can carry a relay url.
      debugPrint('[NetworkChange] re-dial failed: ${e.runtimeType}');
    } finally {
      _inFlight = false;
    }
    _runIfDue();
  }
}
