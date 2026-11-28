/// Location prominent-disclosure state + gate.
///
/// Persists whether the user has accepted the in-app location disclosure
/// (foreground and, separately, background) and exposes a single
/// [LocationDisclosureController.ensureDisclosed] gate that callers invoke
/// immediately BEFORE any code path that triggers the OS location permission
/// prompt — satisfying Google Play's "disclosure before collection" rule.
library;

import 'dart:io' show Platform;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/services/android_background_location.dart';
import 'package:haven/src/widgets/location/location_disclosure_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The background-disclosure version a user on this platform must have
/// accepted before sharing starts again without them opening Haven:
/// [kBackgroundDisclosureVersion] on iPhone,
/// [kAndroidBackgroundDisclosureVersion] on Android.
int resumeDisclosureVersion({required bool isIOS}) =>
    isIOS ? kBackgroundDisclosureVersion : kAndroidBackgroundDisclosureVersion;

/// Whether sharing may start again without the user opening Haven: both
/// disclosures accepted, the background one at [resumeDisclosureVersion] or
/// later. A missing key is a refusal.
///
/// The one predicate for that question on every platform: the iOS native
/// relaunch gate (`HavenBackgroundSessionHandler.resumeConsented`) and the
/// Android resume gates read the same three keys.
bool backgroundResumeDisclosureAccepted({
  required bool? foregroundAccepted,
  required bool? backgroundAccepted,
  required int? acceptedVersion,
  required bool isIOS,
}) =>
    (foregroundAccepted ?? false) &&
    (backgroundAccepted ?? false) &&
    (acceptedVersion ?? 0) >= resumeDisclosureVersion(isIOS: isIOS);

/// [backgroundResumeDisclosureAccepted] read from [prefs]. [isIOS] is a test
/// seam over `Platform.isIOS`.
bool backgroundResumeDisclosureAcceptedIn(
  SharedPreferences prefs, {
  bool? isIOS,
}) => backgroundResumeDisclosureAccepted(
  foregroundAccepted: prefs.getBool(kLocationDisclosureAcceptedKey),
  backgroundAccepted: prefs.getBool(kLocationDisclosureBackgroundAcceptedKey),
  acceptedVersion: prefs.getInt(kLocationDisclosureBackgroundVersionKey),
  isIOS: isIOS ?? Platform.isIOS,
);

/// Which consent dialog the first foreground of a mount owes, if any.
enum ForegroundConsentStep {
  /// Nothing is owed.
  none,

  /// The updated background disclosure, re-shown once to a user who accepted
  /// an older version.
  reconfirm,

  /// The same, carrying the Android "Allow all the time" step: Agree records
  /// the current version and then requests the permission.
  reconfirmWithAllTime,

  /// The Android "Allow all the time" step alone, for a user already at the
  /// current version.
  allTime,
}

/// Decides [ForegroundConsentStep] from persisted state: pure, so the "at most
/// one dialog" rule is tested without a widget tree.
///
/// The all-time step is never due for a user still at an older version: they
/// have not consented to sharing that starts again by itself, so the
/// permission that makes it possible is asked only through the re-confirm.
ForegroundConsentStep foregroundConsentStepDue({
  required bool sharingOn,
  required bool backgroundAccepted,
  required int acceptedVersion,
  required int promptedVersion,
  required BackgroundLocationStatus allTime,
  required bool allTimePrompted,
  required bool isIOS,
}) {
  if (!sharingOn || !backgroundAccepted) return ForegroundConsentStep.none;
  final owed = resumeDisclosureVersion(isIOS: isIOS);
  if (acceptedVersion < owed) {
    if (promptedVersion >= owed) {
      return ForegroundConsentStep.none;
    }
    return allTime.missing
        ? ForegroundConsentStep.reconfirmWithAllTime
        : ForegroundConsentStep.reconfirm;
  }
  return allTime.missing && !allTimePrompted
      ? ForegroundConsentStep.allTime
      : ForegroundConsentStep.none;
}

/// Immutable snapshot of which disclosure scopes the user has accepted.
@immutable
class LocationDisclosureState {
  /// Creates a disclosure-acceptance snapshot.
  const LocationDisclosureState({
    required this.foregroundAccepted,
    required this.backgroundAccepted,
  });

  /// Nothing accepted yet (first-run state).
  static const LocationDisclosureState none = LocationDisclosureState(
    foregroundAccepted: false,
    backgroundAccepted: false,
  );

  /// True once the foreground location disclosure has been accepted.
  final bool foregroundAccepted;

  /// True once the stricter background disclosure has been accepted.
  ///
  /// Background acceptance implies foreground acceptance.
  final bool backgroundAccepted;

  /// Returns a copy with selected fields replaced.
  LocationDisclosureState copyWith({
    bool? foregroundAccepted,
    bool? backgroundAccepted,
  }) {
    return LocationDisclosureState(
      foregroundAccepted: foregroundAccepted ?? this.foregroundAccepted,
      backgroundAccepted: backgroundAccepted ?? this.backgroundAccepted,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is LocationDisclosureState &&
        other.foregroundAccepted == foregroundAccepted &&
        other.backgroundAccepted == backgroundAccepted;
  }

  @override
  int get hashCode => Object.hash(foregroundAccepted, backgroundAccepted);
}

/// Persists disclosure acceptance and gates the first permission request.
class LocationDisclosureController
    extends StateNotifier<LocationDisclosureState> {
  /// Creates a controller with nothing accepted yet. [isIOS] is a test seam
  /// over `Platform.isIOS`: it picks the dialog's background sentence and the
  /// version this platform's resume needs, so the two never disagree.
  LocationDisclosureController({bool? isIOS})
    : _isIOS = isIOS ?? Platform.isIOS,
      super(LocationDisclosureState.none);

  final bool _isIOS;

  /// Ensures the user has seen and accepted the location disclosure for the
  /// requested scope, showing the dialog if not already accepted.
  ///
  /// Returns `true` if the user has consented (now or previously) and the
  /// caller may proceed to request the OS permission; `false` if the user
  /// declined. When [includeBackground] is `true`, the stricter
  /// background-specific disclosure must have been accepted at this
  /// platform's [resumeDisclosureVersion] — neither a prior foreground-only
  /// acceptance nor one of an older background text satisfies it.
  ///
  /// Decisions are read from [SharedPreferences] so the gate is correct even
  /// on the very first frame before in-memory state is hydrated.
  ///
  /// [allTimeStep], on Android, adds the "Allow all the time" step to the
  /// dialog when the caller requests that permission right after it, so a
  /// first enable shows one dialog rather than two in a row.
  Future<bool> ensureDisclosed(
    BuildContext context, {
    required bool includeBackground,
    BackgroundLocationStatus? allTimeStep,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final alreadyAccepted = includeBackground
        ? _backgroundCurrent(prefs)
        : prefs.getBool(kLocationDisclosureAcceptedKey) ?? false;

    if (alreadyAccepted) {
      _syncFromPrefs(prefs);
      return true;
    }

    if (!context.mounted) return false;
    final accepted = await LocationDisclosureDialog.show(
      context,
      includeBackground: includeBackground,
      allTimeStep: allTimeStep,
      isIOS: _isIOS,
    );
    if (!accepted) return false;
    await _recordAccepted(prefs, includeBackground: includeBackground);
    return true;
  }

  /// Whether the background disclosure has been accepted at this platform's
  /// [resumeDisclosureVersion]. A user who accepted an older version is shown
  /// the current text again when they turn background sharing on.
  Future<bool> backgroundDisclosureCurrent() async =>
      _backgroundCurrent(await SharedPreferences.getInstance());

  bool _backgroundCurrent(SharedPreferences prefs) =>
      (prefs.getBool(kLocationDisclosureBackgroundAcceptedKey) ?? false) &&
      (prefs.getInt(kLocationDisclosureBackgroundVersionKey) ?? 1) >=
          resumeDisclosureVersion(isIOS: _isIOS);

  Future<void> _recordAccepted(
    SharedPreferences prefs, {
    required bool includeBackground,
  }) async {
    // Background acceptance implies foreground acceptance. The version goes
    // last, so a write torn part-way reads as the older version.
    await prefs.setBool(kLocationDisclosureAcceptedKey, true);
    if (includeBackground) {
      await prefs.setBool(kLocationDisclosureBackgroundAcceptedKey, true);
      await prefs.setInt(
        kLocationDisclosureBackgroundPromptedVersionKey,
        kBackgroundDisclosureVersion,
      );
      await prefs.setInt(
        kLocationDisclosureBackgroundVersionKey,
        kBackgroundDisclosureVersion,
      );
    }
    if (mounted) {
      state = state.copyWith(
        foregroundAccepted: true,
        backgroundAccepted: includeBackground ? true : null,
      );
    }
  }

  /// Shows the updated background disclosure, in re-confirm mode, to a user
  /// with background sharing on who accepted an older version and has not yet
  /// been shown this one. Returns the answer, or null when nothing was owed.
  ///
  /// Asked once: any answer records the version as shown. "Not now" leaves the
  /// older acceptance and background sharing exactly as they were — it only
  /// means sharing does not start again by itself after Haven is closed.
  /// [force] re-asks a user who already answered (the settings advisory).
  Future<bool?> reconfirmBackgroundIfOwed(
    BuildContext context, {
    BackgroundLocationStatus? allTimeStep,
    bool force = false,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final owed =
        (prefs.getBool(kBackgroundSharingKey) ?? false) &&
        (prefs.getBool(kLocationDisclosureBackgroundAcceptedKey) ?? false) &&
        !_backgroundCurrent(prefs) &&
        (force ||
            (prefs.getInt(kLocationDisclosureBackgroundPromptedVersionKey) ??
                    0) <
                resumeDisclosureVersion(isIOS: _isIOS));
    if (!owed || !context.mounted) return null;
    final accepted = await LocationDisclosureDialog.show(
      context,
      includeBackground: true,
      reconfirm: true,
      allTimeStep: allTimeStep,
      isIOS: _isIOS,
    );
    await prefs.setInt(
      kLocationDisclosureBackgroundPromptedVersionKey,
      kBackgroundDisclosureVersion,
    );
    if (accepted) await _recordAccepted(prefs, includeBackground: true);
    return accepted;
  }

  /// The first foreground's consent step: at most ONE dialog — the re-confirm
  /// when it is owed (on Android 11+ without "Allow all the time", carrying
  /// that step), else the Android all-time step when it is owed.
  ///
  /// [isResumed] is re-read before anything is shown. Returns false when the
  /// app had left the front by then, so the caller owes the step to the next
  /// resume; true otherwise, whether or not a dialog was due.
  Future<bool> runForegroundConsentStep(
    BuildContext context, {
    required AndroidBackgroundLocation allTime,
    required bool Function() isResumed,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final sharingOn = prefs.getBool(kBackgroundSharingKey) ?? false;
    if (!sharingOn) return true;
    final status = await allTime.status();
    final step = foregroundConsentStepDue(
      sharingOn: sharingOn,
      backgroundAccepted:
          prefs.getBool(kLocationDisclosureBackgroundAcceptedKey) ?? false,
      acceptedVersion:
          prefs.getInt(kLocationDisclosureBackgroundVersionKey) ?? 1,
      promptedVersion:
          prefs.getInt(kLocationDisclosureBackgroundPromptedVersionKey) ?? 0,
      allTime: status,
      allTimePrompted:
          prefs.getBool(kAndroidBackgroundLocationPromptedKey) ?? false,
      isIOS: _isIOS,
    );
    if (step == ForegroundConsentStep.none) return true;
    if (!context.mounted || !isResumed()) return false;
    switch (step) {
      case ForegroundConsentStep.reconfirm:
        await reconfirmBackgroundIfOwed(context);
      case ForegroundConsentStep.reconfirmWithAllTime:
        final agreed = await reconfirmBackgroundIfOwed(
          context,
          allTimeStep: status,
        );
        if (agreed ?? false) {
          await requestBackgroundLocation(allTime);
          await prefs.setBool(kAndroidBackgroundLocationPromptedKey, true);
        }
      case ForegroundConsentStep.allTime:
        await prefs.setBool(kAndroidBackgroundLocationPromptedKey, true);
        if (!context.mounted) return true;
        final agreed = await LocationDisclosureDialog.show(
          context,
          includeBackground: true,
          allTimeStep: status,
          isIOS: _isIOS,
        );
        if (agreed) await requestBackgroundLocation(allTime);
      case ForegroundConsentStep.none:
    }
    return true;
  }

  void _syncFromPrefs(SharedPreferences prefs) {
    final next = LocationDisclosureState(
      foregroundAccepted:
          prefs.getBool(kLocationDisclosureAcceptedKey) ?? false,
      backgroundAccepted:
          prefs.getBool(kLocationDisclosureBackgroundAcceptedKey) ?? false,
    );
    if (mounted && next != state) state = next;
  }
}

/// Provides the [LocationDisclosureController] and its current state.
final locationDisclosureControllerProvider =
    StateNotifierProvider<
      LocationDisclosureController,
      LocationDisclosureState
    >((ref) => LocationDisclosureController());

/// Whether the current background disclosure has been accepted. Read by the
/// settings page's re-confirm advisory; invalidated by whoever records an
/// answer.
final backgroundDisclosureCurrentProvider = FutureProvider<bool>(
  (ref) => ref
      .read(locationDisclosureControllerProvider.notifier)
      .backgroundDisclosureCurrent(),
);
