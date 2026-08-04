/// Reactive device-clock skew state for the UI.
///
/// [ClockSkewDetector] is the accumulator; this is the thin Riverpod surface
/// over it. Kept separate so the detector stays a plain, framework-free class
/// that pure-Dart unit tests can drive without a `ProviderContainer`.
///
/// The stream is the source of truth rather than a poll: both evidence sources
/// are event-driven (a publish completes, a peer location decrypts), so a
/// polled provider would either lag the signal or burn a timer for nothing.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/clock_skew_detector.dart';

/// The current device-clock verdict.
///
/// Starts at the detector's present value (so a rebuild after the signal fired
/// does not briefly render the all-clear) and then follows every change.
final clockSkewStatusProvider = StreamProvider<ClockSkewStatus>((ref) {
  final detector = ref.watch(clockSkewDetectorProvider);
  return detector.changes;
});

/// Convenience read: the verdict, resolved, with the detector's current value
/// as the fallback while the stream has not yet emitted.
///
/// UI should watch this rather than unwrapping the [AsyncValue] at each call
/// site — an `AsyncLoading` here is not a meaningful state (the detector always
/// has a value), and treating it as one would flash the banner off on rebuild.
final clockSkewProvider = Provider<ClockSkewStatus>((ref) {
  final detector = ref.watch(clockSkewDetectorProvider);
  return ref
      .watch(clockSkewStatusProvider)
      .maybeWhen(data: (s) => s, orElse: () => detector.status);
});
