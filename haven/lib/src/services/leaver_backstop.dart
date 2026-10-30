/// Carries every leave this device asked for on, at each wake.
///
/// The leave itself lives in Rust: its intent is written before anything
/// else, holds every send to the circle from that instant, and ends on this
/// device once a peer commits the leave, the copy is marked removed, or the
/// day's bound from the intent passes (`haven-core`
/// `Publishing::resume_leave`). Nothing calls `resume_leave` on a timer, so
/// each plane calls [LeaverBackstop.carryOn] at each of its wakes — the
/// foreground's health tick, start-up and resume, a group update an ingest
/// reports, the one follow-up a standing leave arms in front of the user,
/// the Android service's cycle, an iOS burst, a WorkManager wake — and the
/// core answers
/// which circles have a leave at all: a circle with none answers
/// [LeaveStatusFfi.notLeaving] from a store read, contacting nothing.
library;

import 'package:flutter/foundation.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/circle_change_driver.dart';

/// A circle a carry-on found its leave ended for, by both of its ids.
typedef LeftCircle = ({List<int> mlsGroupId, List<int> nostrGroupId});

/// What one carry-on found.
class LeaveCarryOn {
  /// Creates a [LeaveCarryOn].
  const LeaveCarryOn({
    this.left = const [],
    this.namedWait,
    this.unnamedStanding = false,
  });

  /// Nothing carried on.
  static const LeaveCarryOn none = LeaveCarryOn();

  /// Each circle the leave ended for, so the caller forgets it.
  final List<LeftCircle> left;

  /// The soonest wait the core named for a leave still standing.
  final Duration? namedWait;

  /// Whether a leave still stands whose answer named no wait.
  final bool unnamedStanding;

  /// Whether any leave still stands.
  bool get standing => namedWait != null || unnamedStanding;

  /// What a standing leave whose answer named no wait is first asked again
  /// after, in front of the user.
  static const Duration unnamedWait = Duration(seconds: 15);
}

/// Carries leaves on for one plane, never asking a circle again before the
/// wait its last answer named.
class LeaverBackstop {
  /// Creates a backstop reading [clock] (the wall clock unless injected).
  LeaverBackstop({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  /// When each circle (by its MLS group id's bytes) may be asked again.
  final Map<String, DateTime> _notBefore = {};

  /// Bumped by [forget]: a carry-on begun before it writes no wait after it.
  int _forgets = 0;

  /// Forgets every wait: an identity's circles are not the next one's.
  void forget() {
    _forgets++;
    _notBefore.clear();
  }

  /// Carries on every circle's leave, once per circle. A background plane
  /// passes no [inFront] and claims no foreground; a foreground plane passes
  /// its lifecycle read, which is read again before each circle — a pause
  /// stops the carry-on at the next circle, so a paused process begins no
  /// leave step — and read again as each call's claim (a leaving admin's
  /// steps are made only in front of the user). [stopped], read before each
  /// circle as well, ends the carry-on there for a plane whose teardown has
  /// begun. [pastWaits] asks every circle whatever wait its last answer
  /// named: a group update may be the commit that ends a leave. Never
  /// throws.
  Future<LeaveCarryOn> carryOn({
    required CircleManagerFfi manager,
    required CircleChangeDriver driver,
    bool Function()? inFront,
    bool Function()? stopped,
    bool pastWaits = false,
  }) async {
    final forgets = _forgets;
    final List<CircleWithMembersFfi> circles;
    try {
      circles = await manager.getVisibleCircles();
    } on Object catch (e) {
      debugPrint('[Leave] carry-on: circles unreadable: ${e.runtimeType}');
      return LeaveCarryOn.none;
    }
    final left = <LeftCircle>[];
    Duration? named;
    var unnamed = false;
    void standing(Duration wait) {
      if (named == null || wait < named!) named = wait;
    }

    for (final circle in circles) {
      if (inFront != null && !inFront()) break;
      if (stopped != null && stopped()) break;
      final groupId = circle.circle.mlsGroupId;
      final key = groupId.join(',');
      final notBefore = _notBefore[key];
      if (!pastWaits && notBefore != null && _clock().isBefore(notBefore)) {
        standing(notBefore.difference(_clock()));
        continue;
      }
      final LeaveOutcomeFfi outcome;
      try {
        outcome = await driver.resumeLeave(
          circle: manager,
          mlsGroupId: groupId,
          foreground: inFront?.call() ?? false,
        );
      } on Object catch (e) {
        debugPrint('[Leave] carry-on failed: ${e.runtimeType}');
        continue;
      }
      // Forgotten meanwhile (a logout): the answer is the previous identity's.
      if (forgets != _forgets) break;
      switch (outcome.status) {
        case LeaveStatusFfi.completed:
        case LeaveStatusFfi.circleNotFound:
          _notBefore.remove(key);
          left.add((
            mlsGroupId: groupId.toList(),
            nostrGroupId: circle.circle.nostrGroupId.toList(),
          ));
        case LeaveStatusFfi.notLeaving:
          _notBefore.remove(key);
        case LeaveStatusFfi.adminMustStepDown:
          // Answered only off the driver now (the core keeps the intent and
          // re-plans there); mapped, never re-issued here.
          _notBefore.remove(key);
          debugPrint(
            '[Leave] carry-on ended unmade: an admin step comes first',
          );
        case LeaveStatusFfi.proposed:
        case LeaveStatusFfi.pending:
        case LeaveStatusFfi.foregroundOnly:
        case LeaveStatusFfi.engineHeld:
          // `Some(0)` means "at the next call", which is the next wake: one
          // call per circle per wake is what keeps it from spinning.
          final wait = outcome.retryAfterMs;
          if (wait == null || wait == BigInt.zero) {
            _notBefore.remove(key);
            unnamed = true;
          } else {
            final asked = Duration(milliseconds: wait.toInt());
            _notBefore[key] = _clock().add(asked);
            standing(asked);
          }
      }
    }
    return LeaveCarryOn(
      left: left,
      namedWait: named,
      unnamedStanding: unnamed,
    );
  }
}
