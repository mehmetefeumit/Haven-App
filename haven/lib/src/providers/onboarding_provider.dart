/// Onboarding state providers.
///
/// Models first-run onboarding as two independent persisted flags plus a
/// derived [OnboardingStep] for the UI. The flow is two screens: a merged
/// intro screen and an identity-creation screen. The identity-creation
/// screen's single action creates the identity, publishes the public profile,
/// runs the location disclosure, and marks onboarding complete — so routing
/// only ever needs `introSeen` and `completed`.
///
/// # Persistence contract
///
/// Each flag is stored independently in [SharedPreferences]. Every mutation
/// awaits the underlying [SharedPreferences.setBool] **before** updating the
/// in-memory [OnboardingFlags] state, so a process-kill between storage
/// write and state update never leaves a user "stuck at a step that says
/// it's done."
///
/// # Flicker-free startup
///
/// The [onboardingControllerProvider] is overridden at the root of the
/// provider tree in `main.dart` with flags pre-loaded from
/// [SharedPreferences] before `runApp`. The first frame therefore routes
/// correctly without a loading state.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// [SharedPreferences] key for the "user finished the intro screen" flag.
const String kOnboardingIntroSeenKey = 'haven.onboarding.intro_seen';

/// Legacy [SharedPreferences] key for the old, separate display-name step.
///
/// The display-name step was merged into the identity-creation screen, so this
/// flag is no longer read or written by [OnboardingFlags]. The constant is
/// retained so (a) any value left on disk by a pre-consolidation install is
/// harmlessly ignored, and (b) existing test / e2e fixtures that seed or clear
/// it keep compiling. Do not repurpose it.
const String kOnboardingDisplayNameSetKey = 'haven.onboarding.display_name_set';

/// [SharedPreferences] key for the terminal "onboarding complete" flag.
///
/// When `true`, the app router unconditionally enters the main shell.
const String kOnboardingCompletedKey = 'haven.onboarding.completed';

/// Total onboarding step-indicator slots.
const int kOnboardingTotalSteps = 2;

/// 1-based step-indicator number for the intro screen.
const int kOnboardingStepIntro = 1;

/// 1-based step-indicator number for the create-identity screen.
const int kOnboardingStepCreateIdentity = 2;

/// Immutable snapshot of the persisted onboarding flags.
@immutable
class OnboardingFlags {
  /// Creates a snapshot with the given flags.
  const OnboardingFlags({
    required this.introSeen,
    required this.completed,
  });

  /// Convenience: all flags false (first-ever launch state).
  static const OnboardingFlags none = OnboardingFlags(
    introSeen: false,
    completed: false,
  );

  /// True once the user has advanced past the intro screen.
  final bool introSeen;

  /// True once the user has finished the identity-creation screen — the
  /// terminal step that also creates the identity and publishes the profile.
  final bool completed;

  /// Returns a new snapshot with selected fields replaced.
  OnboardingFlags copyWith({
    bool? introSeen,
    bool? completed,
  }) {
    return OnboardingFlags(
      introSeen: introSeen ?? this.introSeen,
      completed: completed ?? this.completed,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is OnboardingFlags &&
        other.introSeen == introSeen &&
        other.completed == completed;
  }

  @override
  int get hashCode => Object.hash(introSeen, completed);

  @override
  String toString() =>
      'OnboardingFlags(introSeen: $introSeen, completed: $completed)';
}

/// Discrete UI states dispatched by the onboarding shell.
///
/// [done] means the app router should render the main shell instead of the
/// onboarding shell.
enum OnboardingStep {
  /// Merged intro screen: hero (logo + tagline) plus the value-prop cards.
  intro,

  /// Identity-creation screen. Its single action creates the identity,
  /// publishes the public profile, runs the location disclosure, and completes
  /// onboarding. A user who created an identity but was killed before
  /// `completed` persisted resumes here; the screen detects the existing
  /// identity and does not re-create it.
  createIdentity,

  /// Onboarding is complete; the app router should render `MapShell`.
  done,
}

/// Pure function mapping the persisted flags to the current step.
///
/// This is the single source of truth for routing decisions. It is a pure
/// function so it can be unit-tested exhaustively without any Riverpod or
/// Flutter machinery.
///
/// The step ordering is:
///
/// 1. `completed = true` → [OnboardingStep.done]
/// 2. `introSeen = false` → [OnboardingStep.intro]
/// 3. otherwise → [OnboardingStep.createIdentity]
///
/// Identity presence is deliberately **not** an input: an identity created
/// on a prior (interrupted) attempt is handled inside the create-identity
/// screen, which is idempotent, rather than by the router.
OnboardingStep resolveStep({
  required bool introSeen,
  required bool completed,
}) {
  if (completed) return OnboardingStep.done;
  if (!introSeen) return OnboardingStep.intro;
  return OnboardingStep.createIdentity;
}

/// Synchronous [StateNotifier] holding the current [OnboardingFlags].
///
/// Every mutator awaits the [SharedPreferences.setBool] write before
/// updating [state], so a process-kill mid-write cannot desync persisted
/// state from in-memory state.
class OnboardingController extends StateNotifier<OnboardingFlags> {
  /// Creates a controller seeded with [initial] flags.
  ///
  /// In production the root [ProviderScope] overrides the provider with
  /// flags pre-loaded from [SharedPreferences]. Tests may pass any value.
  OnboardingController(super.initial);

  /// Marks the intro screen as complete and persists the flag.
  Future<void> markIntroSeen() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kOnboardingIntroSeenKey, true);
    if (!mounted) return;
    state = state.copyWith(introSeen: true);
  }

  /// Marks onboarding as fully complete and persists the flag.
  ///
  /// Flipping this flag causes `AppRouter` to render the main shell.
  Future<void> markCompleted() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kOnboardingCompletedKey, true);
    if (!mounted) return;
    state = state.copyWith(completed: true);
  }

  /// Resets all onboarding flags to false and persists the change.
  ///
  /// Invoked from the Manage Identity recovery path when the user deletes
  /// their identity — the next launch should drop them back into onboarding.
  Future<void> reset() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kOnboardingIntroSeenKey, false);
    // Legacy flag: cleared defensively so a downgrade to a pre-consolidation
    // build doesn't see a stale `true` and skip the (now-merged) name step.
    await prefs.setBool(kOnboardingDisplayNameSetKey, false);
    await prefs.setBool(kOnboardingCompletedKey, false);
    if (!mounted) return;
    state = OnboardingFlags.none;
  }
}

/// Provides the [OnboardingController] and its current [OnboardingFlags].
///
/// The default factory yields [OnboardingFlags.none]; the production root
/// overrides this with flags pre-loaded from [SharedPreferences] before
/// `runApp` to guarantee zero routing flicker on cold start.
final onboardingControllerProvider =
    StateNotifierProvider<OnboardingController, OnboardingFlags>(
      (ref) => OnboardingController(OnboardingFlags.none),
    );

/// Derived boolean: the terminal "completed" flag.
///
/// `AppRouter` watches this to decide between `OnboardingShell` and the
/// main shell.
final onboardingCompletedProvider = Provider<bool>(
  (ref) => ref.watch(onboardingControllerProvider).completed,
);

/// Derived [OnboardingStep] from the persisted flags.
///
/// Routing no longer depends on live identity presence: resumption of an
/// interrupted create-identity attempt is handled inside the create-identity
/// screen (which is idempotent), not here.
final onboardingStepProvider = Provider<OnboardingStep>((ref) {
  final flags = ref.watch(onboardingControllerProvider);
  return resolveStep(
    introSeen: flags.introSeen,
    completed: flags.completed,
  );
});
