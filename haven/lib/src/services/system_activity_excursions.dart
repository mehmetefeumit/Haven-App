/// Haven's own trips through a system activity — the photo picker and the crop
/// editor. Android stops Haven's activity for them exactly as it does when the
/// user leaves, so the pause they cause must not hand the MLS session away
/// from the save waiting on their result.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

/// How long a pause during one of those trips keeps the MLS session in this
/// isolate before handing it to the foreground service, counted from the
/// trip's FIRST pause: a second pause before the user is back keeps what is
/// left rather than starting over.
///
/// Owner-chosen (2026-11-16), not derived. It spends the 30 s propagation and
/// clock-skew margin the 228 s retention keeps above the scheduled worst case,
/// so it is no proof that the service's first publish still lands inside the
/// retention: that publish also pays the service's own fix head and the relay
/// round trip. It is the fourth realized-gap term on
/// `constants/location.dart` and in `haven-core/SECURITY.md`.
///
/// Under one heartbeat, so the foreground stamp the pause leaves (at most one
/// heartbeat old) stays fresh for the whole grace and the service defers on
/// its own gate instead of probing a live owner.
const Duration kSystemActivityHandoffGrace = Duration(seconds: 20);

/// Why a pending grace ended, as its debug line names it.
enum HandoffGraceEnd {
  /// The user is back: the pause is superseded and hands nothing over.
  resumed,

  /// The bound ran out: the pause hands the session over now.
  expired,

  /// A pause with no trip in flight: the user left, so the session goes now.
  superseded,

  /// The activity is being destroyed. The pause still has the session to hand
  /// over, but on a host whose engine dies with its activity (Haven's) the
  /// platform writes it awaits first may never answer.
  detached,

  /// The shell or the provider went away.
  disposed,
}

/// Tracks Haven's own system-activity trips, and holds the handoff of a pause
/// one of them caused for at most [kSystemActivityHandoffGrace].
class SystemActivityExcursions {
  /// Creates the tracker.
  SystemActivityExcursions({
    @visibleForTesting Duration grace = kSystemActivityHandoffGrace,
  }) : _grace = grace;

  final Duration _grace;
  int _open = 0;
  int _saving = 0;
  Completer<void>? _saved;
  Completer<void>? _pending;
  Timer? _timer;

  /// Whether this stretch away has already spent its grace: a later pause in
  /// it hands over at once. Cleared by every [endGrace].
  bool _spent = false;

  /// Whether one of Haven's own system activities is open, or its result is
  /// still being saved.
  bool get inFlight => _open > 0;

  /// Completes once no result is being saved — at once when none is.
  Future<void> get saved =>
      _saving == 0 ? Future.value() : (_saved ??= Completer<void>()).future;

  /// Runs [body] as one trip: from before the activity is launched until its
  /// result is saved.
  Future<T> run<T>(Future<T> Function() body) async {
    _open++;
    try {
      return await body();
    } finally {
      _open--;
    }
  }

  /// Runs [body], the local write of a trip's result, as the phase a handoff
  /// waits for: releasing the session under it would dispose the manager the
  /// save is still reading through.
  Future<T> save<T>(Future<T> Function() body) async {
    _saving++;
    try {
      return await body();
    } finally {
      if (--_saving == 0) {
        _saved?.complete();
        _saved = null;
      }
    }
  }

  /// The wait a pause owes before handing the session over — `null` when it
  /// owes none: no trip is in flight (the user left), or this stretch away
  /// already spent its grace.
  Future<void>? graceForPause() {
    if (!inFlight) {
      endGrace(HandoffGraceEnd.superseded);
      return null;
    }
    if (_spent) return null;
    final pending = _pending ??= Completer<void>();
    _timer ??= Timer(_grace, () {
      _spent = true;
      _finish(HandoffGraceEnd.expired);
    });
    return pending.future;
  }

  /// Ends a pending grace now, as [outcome], and starts the next stretch away
  /// with a fresh one.
  void endGrace(HandoffGraceEnd outcome) {
    _spent = false;
    _finish(outcome);
  }

  void _finish(HandoffGraceEnd outcome) {
    _timer?.cancel();
    _timer = null;
    final pending = _pending;
    _pending = null;
    if (pending == null) return;
    // Fixed vocabulary only (Rule 15); the e2e lanes read it to tell the
    // grace's outcomes apart.
    debugPrint('[MapShell] handoff grace: ended by ${outcome.name}');
    pending.complete();
  }
}
