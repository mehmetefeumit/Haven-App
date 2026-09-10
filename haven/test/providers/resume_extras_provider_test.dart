/// The resume-extras throttle: what a glance costs, and what it must never
/// suppress.
///
/// The promise this pins: repeating a shade-pull glance ten times an hour must
/// not repeat ten KeyPackage probes, ten profile fetches, ten prunes and ten
/// tile-cache sweeps — while the work a user can actually SEE (the immediate
/// publish, the member-location refresh) stays outside the window entirely.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/providers/maintenance_scheduler_provider.dart';
import 'package:haven/src/providers/resume_extras_provider.dart';

final _t0 = DateTime.utc(2026, 8, 30, 9);

void main() {
  group('shouldRunResumeExtras', () {
    test('runs on the first resume of a session', () {
      // The throttle absorbs REPEATS; it must never delay the first answer,
      // which is also the one a cold start most needs.
      expect(shouldRunResumeExtras(lastAt: null, now: _t0), isTrue);
    });

    test('suppresses a repeat inside the window', () {
      expect(
        shouldRunResumeExtras(
          lastAt: _t0,
          now: _t0.add(kResumeExtrasMinInterval - const Duration(seconds: 1)),
        ),
        isFalse,
        reason: 'a glance one second short of the window buys no freshness — '
            'every one of these tasks re-runs on its own timer anyway',
      );
    });

    test('runs again exactly at the window', () {
      // Boundary pinned so the rule cannot drift into "strictly greater",
      // which would make the effective cadence depend on resume timing.
      expect(
        shouldRunResumeExtras(
          lastAt: _t0,
          now: _t0.add(kResumeExtrasMinInterval),
        ),
        isTrue,
      );
    });

    test('runs after the window', () {
      expect(
        shouldRunResumeExtras(
          lastAt: _t0,
          now: _t0.add(kResumeExtrasMinInterval + const Duration(seconds: 1)),
        ),
        isTrue,
      );
    });

    test('a clock that moved backwards suppresses rather than repeats', () {
      // NTP correction / manual clock change. Neither answer is "right", but
      // suppressing is the safe one: the extras are sweeps, and the next
      // resume past the window runs them.
      expect(
        shouldRunResumeExtras(
          lastAt: _t0,
          now: _t0.subtract(const Duration(hours: 1)),
        ),
        isFalse,
      );
    });
  });

  group('the window', () {
    test('equals the shortest of the extras own timers', () {
      // Derived, not chosen. A window LONGER than the shortest maintenance
      // cadence would make this throttle — not the timer — decide how often
      // the KeyPackage is checked, which is a resilience promise, not a
      // presentation detail.
      expect(kResumeExtrasMinInterval, keyPackageMaintenanceInterval);
    });
  });

  group('lastResumeExtrasAtProvider', () {
    test('starts unset so the first resume is never throttled', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(lastResumeExtrasAtProvider), isNull);
    });
  });
}
