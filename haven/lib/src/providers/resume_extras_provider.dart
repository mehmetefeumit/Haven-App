/// The throttle shared by everything a resume re-runs "just in case".
///
/// `MapShell._onResumed` and `MapPage` both do one-shot work on foreground
/// return that is a repeat of something already on a periodic timer. Two
/// independent throttles would drift apart and would each need their own
/// timestamp; one decision point, taken by the shell and observed by the page,
/// keeps a glance costing the same everywhere.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/constants/location.dart';

/// When the resume extras last ran, or `null` before the first resume.
///
/// Written ONLY by `MapShell._onResumed`, and only when
/// [shouldRunResumeExtras] said yes. The write is therefore also the signal
/// that the extras are due: `MapPage` evicts its tile cache off a listener on
/// this provider rather than off its own lifecycle callback, because both
/// widgets observe the same resume and whichever ran first would otherwise
/// stamp the other out of its turn.
final lastResumeExtrasAtProvider = StateProvider<DateTime?>((ref) => null);

/// Whether the one-shot resume extras may run at [now].
///
/// The first resume of a session always runs them ([lastAt] is `null`): the
/// throttle exists to absorb repeats, not to delay the first answer.
bool shouldRunResumeExtras({
  required DateTime? lastAt,
  required DateTime now,
}) =>
    lastAt == null || now.difference(lastAt) >= kResumeExtrasMinInterval;
