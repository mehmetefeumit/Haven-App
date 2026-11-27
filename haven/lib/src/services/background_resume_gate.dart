/// The gate on every start of the Android foreground service that Haven's UI
/// did not make: a boot or update start from `BootResumeReceiver`, and a
/// restart the system makes after killing the process (`START_STICKY`).
///
/// Owner-directed 2026-11-26 (OD-R2/OD-R3): sharing resumes without the user
/// opening Haven only with consent to the CURRENT background disclosure, a
/// foreground location grant and, on Android 11+, "Allow all the time". The
/// Kotlin twin is `decideResume` in `ResumeRule.kt`; a UI start keeps the
/// v1 disclosure gate (`backgroundPublishDisclosureAccepted`).
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/providers/location_disclosure_provider.dart'
    show backgroundResumeDisclosureAccepted;
import 'package:shared_preferences/shared_preferences.dart';

/// What a system start does.
enum SystemResumeDecision {
  /// Run the task.
  start,

  /// Post the resume notice, then stop.
  notify,

  /// Stop without a notice.
  stop,
}

/// The resume rule for a system start: sharing on, then the consent and
/// grants its Kotlin twin, `decideResume`, requires.
@visibleForTesting
SystemResumeDecision decideSystemResume({
  required bool sharingOn,
  required bool? foregroundAccepted,
  required bool? backgroundAccepted,
  required int? acceptedVersion,
  required bool locationGranted,
  required bool backgroundRequired,
  required bool backgroundGranted,
}) {
  if (!sharingOn) return SystemResumeDecision.stop;
  final consented = backgroundResumeDisclosureAccepted(
    foregroundAccepted: foregroundAccepted,
    backgroundAccepted: backgroundAccepted,
    acceptedVersion: acceptedVersion,
  );
  if (!consented ||
      !locationGranted ||
      (backgroundRequired && !backgroundGranted)) {
    return SystemResumeDecision.notify;
  }
  return SystemResumeDecision.start;
}

/// The location grants, as the foreground-service engine's
/// `haven.app/background_location` channel reports them.
@immutable
class ResumeGrants {
  /// Creates a snapshot of the grants.
  const ResumeGrants({
    required this.foregroundGranted,
    required this.backgroundRequired,
    required this.backgroundGranted,
  });

  /// What a failed read reports: every grant missing, so a broken channel
  /// costs a notice, never a start the user did not allow.
  static const ResumeGrants none = ResumeGrants(
    foregroundGranted: false,
    backgroundRequired: true,
    backgroundGranted: false,
  );

  /// Fine or coarse location is granted.
  final bool foregroundGranted;

  /// The OS restricts a background-started location service (Android 11+).
  final bool backgroundRequired;

  /// "Allow all the time" is granted (true when not required).
  final bool backgroundGranted;
}

/// The foreground-service engine's half of `haven.app/background_location`
/// (`BackgroundLocation.ServiceEngine`).
class BackgroundResumeChannel {
  /// Creates the client over the given channel.
  const BackgroundResumeChannel([
    this._channel = const MethodChannel('haven.app/background_location'),
  ]);

  final MethodChannel _channel;

  /// The live grants; [ResumeGrants.none] when the channel fails.
  Future<ResumeGrants> grants() async {
    try {
      final map = await _channel.invokeMapMethod<String, Object?>('status');
      if (map == null) return ResumeGrants.none;
      return ResumeGrants(
        foregroundGranted: map['foregroundGranted'] == true,
        backgroundRequired: map['required'] != false,
        backgroundGranted: map['granted'] == true,
      );
    } on Object catch (e) {
      debugPrint('[BackgroundResume] status failed: ${e.runtimeType}');
      return ResumeGrants.none;
    }
  }

  /// Posts the one "Tap to resume sharing" notification.
  Future<void> postResumeNotice() async {
    try {
      await _channel.invokeMethod<void>('postResumeNotice');
    } on Object catch (e) {
      debugPrint('[BackgroundResume] notice failed: ${e.runtimeType}');
    }
  }
}

/// Why a system start was refused; each logs one fixed line.
enum SystemStartRefusal {
  /// Background sharing is off.
  sharingOff,

  /// No identity is stored (logged out while the service was already dead).
  noIdentity,

  /// Consent or a grant the resume rule needs is missing.
  notPermitted,
}

/// Applies the resume rule at the top of the task's `onStart`, before any
/// work: no Rust, no keyring, no session.
class SystemStartGate {
  /// Creates the gate over its inputs and effects.
  const SystemStartGate({
    required this.identityStored,
    this.channel = const BackgroundResumeChannel(),
    this.stopService = _stopService,
  });

  /// Whether an identity is stored (presence only; nothing is decoded).
  final Future<bool> Function() identityStored;

  /// The grants and the notice.
  final BackgroundResumeChannel channel;

  /// Stops the service this task runs in.
  final Future<void> Function() stopService;

  static Future<void> _stopService() async {
    await FlutterForegroundTask.stopService();
  }

  /// Returns the refusal for a start by [starter], having already posted the
  /// notice (when owed) and asked the service to stop; `null` lets it run.
  Future<SystemStartRefusal?> check(TaskStarter starter) async {
    if (starter != TaskStarter.system) return null;
    final refusal = await _refusal();
    if (refusal == null) return null;
    debugPrint(switch (refusal) {
      SystemStartRefusal.sharingOff =>
        '[BackgroundTask] system start refused: sharing off',
      SystemStartRefusal.noIdentity =>
        '[BackgroundTask] system start refused: no identity',
      SystemStartRefusal.notPermitted =>
        '[BackgroundTask] system start refused: not permitted',
    });
    if (refusal == SystemStartRefusal.notPermitted) {
      await channel.postResumeNotice();
    }
    await stopService();
    return refusal;
  }

  Future<SystemStartRefusal?> _refusal() async {
    final bool sharingOn;
    final bool? foregroundAccepted;
    final bool? backgroundAccepted;
    final int? acceptedVersion;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      sharingOn = prefs.getBool(kBackgroundSharingKey) ?? false;
      foregroundAccepted = prefs.getBool(kLocationDisclosureAcceptedKey);
      backgroundAccepted = prefs.getBool(
        kLocationDisclosureBackgroundAcceptedKey,
      );
      acceptedVersion = prefs.getInt(kLocationDisclosureBackgroundVersionKey);
    } on Object catch (e) {
      debugPrint('[BackgroundResume] prefs read failed: ${e.runtimeType}');
      return SystemStartRefusal.notPermitted;
    }
    final grants = await channel.grants();
    final decision = decideSystemResume(
      sharingOn: sharingOn,
      foregroundAccepted: foregroundAccepted,
      backgroundAccepted: backgroundAccepted,
      acceptedVersion: acceptedVersion,
      locationGranted: grants.foregroundGranted,
      backgroundRequired: grants.backgroundRequired,
      backgroundGranted: grants.backgroundGranted,
    );
    if (decision == SystemResumeDecision.stop) {
      return SystemStartRefusal.sharingOff;
    }
    try {
      if (!await identityStored()) return SystemStartRefusal.noIdentity;
    } on Object catch (e) {
      debugPrint('[BackgroundResume] identity read failed: ${e.runtimeType}');
      return SystemStartRefusal.notPermitted;
    }
    return decision == SystemResumeDecision.notify
        ? SystemStartRefusal.notPermitted
        : null;
  }
}
