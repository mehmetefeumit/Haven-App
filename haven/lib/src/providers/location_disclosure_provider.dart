/// Location prominent-disclosure state + gate.
///
/// Persists whether the user has accepted the in-app location disclosure
/// (foreground and, separately, background) and exposes a single
/// [LocationDisclosureController.ensureDisclosed] gate that callers invoke
/// immediately BEFORE any code path that triggers the OS location permission
/// prompt — satisfying Google Play's "disclosure before collection" rule.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/widgets/location/location_disclosure_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  /// Creates a controller seeded with the given initial state.
  LocationDisclosureController([
    super.initial = LocationDisclosureState.none,
  ]);

  /// Ensures the user has seen and accepted the location disclosure for the
  /// requested scope, showing the dialog if not already accepted.
  ///
  /// Returns `true` if the user has consented (now or previously) and the
  /// caller may proceed to request the OS permission; `false` if the user
  /// declined. When [includeBackground] is `true`, the stricter
  /// background-specific disclosure must have been accepted — a prior
  /// foreground-only acceptance does NOT satisfy it.
  ///
  /// Decisions are read from [SharedPreferences] so the gate is correct even
  /// on the very first frame before in-memory state is hydrated.
  Future<bool> ensureDisclosed(
    BuildContext context, {
    required bool includeBackground,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final key = includeBackground
        ? kLocationDisclosureBackgroundAcceptedKey
        : kLocationDisclosureAcceptedKey;

    if (prefs.getBool(key) ?? false) {
      _syncFromPrefs(prefs);
      return true;
    }

    if (!context.mounted) return false;
    final accepted = await LocationDisclosureDialog.show(
      context,
      includeBackground: includeBackground,
    );
    if (!accepted) return false;

    // Background acceptance implies foreground acceptance.
    await prefs.setBool(kLocationDisclosureAcceptedKey, true);
    if (includeBackground) {
      await prefs.setBool(kLocationDisclosureBackgroundAcceptedKey, true);
    }
    if (mounted) {
      state = state.copyWith(
        foregroundAccepted: true,
        backgroundAccepted: includeBackground ? true : null,
      );
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
