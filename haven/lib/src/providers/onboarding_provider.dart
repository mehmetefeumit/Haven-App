/// Onboarding state providers.
///
/// Models first-run onboarding as three independent persisted flags plus
/// a derived [OnboardingStep] for the UI. Deriving `identityReady` live
/// from [identityProvider] eliminates a class of reconciliation bugs where
/// a persisted "identity was created" step could disagree with the actual
/// state of secure storage.
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
import 'package:haven/src/providers/identity_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// [SharedPreferences] key for the "user finished the intro screens" flag.
const String kOnboardingIntroSeenKey = 'haven.onboarding.intro_seen';

/// [SharedPreferences] key for the "user set or explicitly skipped the
/// display-name step" flag.
const String kOnboardingDisplayNameSetKey = 'haven.onboarding.display_name_set';

/// [SharedPreferences] key for the terminal "onboarding complete" flag.
///
/// When `true`, the app router unconditionally enters the main shell.
const String kOnboardingCompletedKey = 'haven.onboarding.completed';

/// Immutable snapshot of the three persisted onboarding flags.
@immutable
class OnboardingFlags {
  /// Creates a snapshot with the given flags.
  const OnboardingFlags({
    required this.introSeen,
    required this.displayNameSet,
    required this.completed,
  });

  /// Convenience: all flags false (first-ever launch state).
  static const OnboardingFlags none = OnboardingFlags(
    introSeen: false,
    displayNameSet: false,
    completed: false,
  );

  /// True once the user has advanced past the value-prop intro screens.
  final bool introSeen;

  /// True once the user has set a display name or explicitly skipped it.
  final bool displayNameSet;

  /// True once the user has reached and dismissed the final "ready" screen.
  final bool completed;

  /// Returns a new snapshot with selected fields replaced.
  OnboardingFlags copyWith({
    bool? introSeen,
    bool? displayNameSet,
    bool? completed,
  }) {
    return OnboardingFlags(
      introSeen: introSeen ?? this.introSeen,
      displayNameSet: displayNameSet ?? this.displayNameSet,
      completed: completed ?? this.completed,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is OnboardingFlags &&
        other.introSeen == introSeen &&
        other.displayNameSet == displayNameSet &&
        other.completed == completed;
  }

  @override
  int get hashCode => Object.hash(introSeen, displayNameSet, completed);

  @override
  String toString() =>
      'OnboardingFlags(introSeen: $introSeen, '
      'displayNameSet: $displayNameSet, completed: $completed)';
}

/// Discrete UI states dispatched by the onboarding shell.
///
/// The shell always enters the intro flow at [welcome]; the value-props
/// screen is pushed onto that screen's local `Navigator` and is therefore
/// not a distinct top-level routing state. [done] means the app router
/// should render the main shell instead of the onboarding shell.
enum OnboardingStep {
  /// Hero screen with the primary value prop.
  ///
  /// Owns a local nested navigator that may push a value-props screen.
  welcome,

  /// Identity generation / import screen.
  createIdentity,

  /// Local display-name capture.
  displayName,

  /// Confirmation screen gating entry into the main app.
  ready,

  /// Onboarding is complete; the app router should render `MapShell`.
  done,
}

/// Pure function mapping flags + identity presence to the current step.
///
/// This is the single source of truth for routing decisions. It is a pure
/// function so it can be unit-tested exhaustively without any Riverpod or
/// Flutter machinery.
///
/// The step ordering is:
///
/// 1. `completed = true` → [OnboardingStep.done]
/// 2. `introSeen = false` → [OnboardingStep.welcome] (the shell itself
///    navigates locally to a value-props route owned by the welcome screen;
///    only that route's Continue action flips `introSeen`).
/// 3. `identityReady = false` → [OnboardingStep.createIdentity]
/// 4. `displayNameSet = false` → [OnboardingStep.displayName]
/// 5. otherwise → [OnboardingStep.ready]
OnboardingStep resolveStep({
  required bool introSeen,
  required bool identityReady,
  required bool displayNameSet,
  required bool completed,
}) {
  if (completed) return OnboardingStep.done;
  if (!introSeen) return OnboardingStep.welcome;
  if (!identityReady) return OnboardingStep.createIdentity;
  if (!displayNameSet) return OnboardingStep.displayName;
  return OnboardingStep.ready;
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

  /// Marks the intro screens as complete and persists the flag.
  Future<void> markIntroSeen() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kOnboardingIntroSeenKey, true);
    if (!mounted) return;
    state = state.copyWith(introSeen: true);
  }

  /// Marks the display-name step as complete and persists the flag.
  ///
  /// Called whether the user entered a name or explicitly tapped "Skip".
  Future<void> markDisplayNameSet() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kOnboardingDisplayNameSetKey, true);
    if (!mounted) return;
    state = state.copyWith(displayNameSet: true);
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

/// Derived [OnboardingStep] combining flags with live identity presence.
///
/// Reads [identityProvider]. When identity loading is still pending this
/// treats `identityReady` as false, so the shell shows the create-identity
/// screen rather than a blank frame — the user sees a meaningful screen
/// instantly and the step auto-advances once the identity future resolves.
final onboardingStepProvider = Provider<OnboardingStep>((ref) {
  final flags = ref.watch(onboardingControllerProvider);
  final identityAsync = ref.watch(identityProvider);
  final identityReady = identityAsync.valueOrNull != null;
  return resolveStep(
    introSeen: flags.introSeen,
    identityReady: identityReady,
    displayNameSet: flags.displayNameSet,
    completed: flags.completed,
  );
});
