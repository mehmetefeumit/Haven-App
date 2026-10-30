/// The one-time storage-reset notice (MDK v0.10.4, owner decision D1).
///
/// Whether it is owed is decided BEFORE `runApp`: `main.dart` runs the Rust
/// reset, which deletes every pre-migration store and answers `true` while its
/// marker file is on disk — whichever isolate's reset wrote it, since a
/// background isolate may open a store first. `MapShell` reads this once on
/// its first frame, shows the notice if `true`, then flips it back to `false`
/// so a rebuild never re-shows it within the same app session. The marker
/// itself is only removed when the user answers the notice, so a notice that
/// was never answered is owed again next launch.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/constants/feature_flags.dart';
import 'package:haven/src/providers/key_package_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/rust/api.dart' as frb_api;
import 'package:haven/src/services/background_location_manager.dart';
import 'package:haven/src/services/nostr_identity_service.dart'
    show kDisplayNamePrefPrefix, kOwnNameReseedOwedKey;
import 'package:haven/src/services/pending_leave_service.dart';
import 'package:haven/src/services/profile_service.dart';
import 'package:haven/src/widgets/common/storage_reset_notice_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Whether the storage-reset notice is still owed this app session.
///
/// Seeded from `main.dart` via `overrideWith`; defaults to `false` (a test
/// `ProviderScope` that does not override it, or a fresh install).
final storageResetNoticeProvider = StateProvider<bool>((ref) => false);

/// MapShell's startup half of the notice: shows it when it is owed, at most
/// once per app session, and re-runs the KeyPackage publisher only once the
/// reset is acknowledged — until then the core holds every relay-list and
/// KeyPackage publish, so a run before would publish nothing.
Future<void> showStorageResetNoticeIfOwed(
  BuildContext context,
  WidgetRef ref, {
  required Future<void> Function() openRelaySettings,
}) async {
  if (!ref.read(storageResetNoticeProvider)) return;
  ref.read(storageResetNoticeProvider.notifier).state = false;
  // The container, not `ref`: an answer saved by a later Try Again may land
  // after the shell that asked has gone.
  final container = ProviderScope.containerOf(context, listen: false);
  await StorageResetNoticeDialog.answer(
    context,
    openRelaySettings: openRelaySettings,
    acknowledge: container.read(circleServiceProvider).acknowledgeStorageReset,
    onAcknowledged: () => container
      ..invalidate(keyPackagePublisherProvider)
      ..read(keyPackagePublisherProvider),
  );
}

/// Opens Relay settings for the notice, completing only once the user leaves
/// them: coming back is the answer, so nothing may be acknowledged — and no
/// relay list or KeyPackage published — while they are still adding their own
/// relays.
Future<void> openRelaySettingsForNotice(
  NavigatorState navigator,
  WidgetBuilder relaySettings,
) => navigator.push(MaterialPageRoute<void>(builder: relaySettings));

/// Runs the one-time storage reset for [dataDir] and returns whether its
/// notice is owed.
///
/// [reset] is the Rust `reset_pre_v2_storage` in production. When it throws,
/// the answer falls back to [owed] — whether a marker some other opener's
/// reset wrote still stands — because the core holds relay-list publishing
/// for as long as the marker does, and a notice that is never shown would
/// hold it with nothing on screen to release it.
bool decideStorageResetNotice(
  String dataDir, {
  bool Function(String dataDir) reset = _ffiReset,
  bool Function(String dataDir) owed = _ffiOwed,
}) {
  try {
    return reset(dataDir);
  } on Object catch (e) {
    debugPrint('[Haven] storage reset failed: ${e.runtimeType}');
  }
  try {
    return owed(dataDir);
  } on Object catch (e) {
    debugPrint('[Haven] storage reset marker unreadable: ${e.runtimeType}');
    return false;
  }
}

/// Clears the preferences that name what the reset deleted — the pending
/// leaves (each a deleted circle's routing id), the background publish
/// history and the user's own display name ([clearCircleScopedPrefsAfterReset])
/// — once: only while the pass that removed the user's data, in any
/// isolate, still owes it ([owed]), and never again after [cleared] records
/// it. A launch while the notice merely waits keeps them, because the app has
/// been making new ones since.
///
/// Cleared before recorded, so a kill between the two clears again rather
/// than leaving the deleted circles named; a clear that fails is logged by
/// its type, never recorded, and never stops the launch ([clear] is the real
/// clear in production).
Future<void> clearCircleScopedPrefsIfResetOwes(
  SharedPreferences prefs,
  String dataDir, {
  bool Function(String dataDir) owed = _ffiPrefsOwed,
  void Function(String dataDir) cleared = _ffiPrefsCleared,
  Future<void> Function(SharedPreferences prefs) clear =
      clearCircleScopedPrefsAfterReset,
}) async {
  try {
    if (!owed(dataDir)) return;
  } on Object catch (e) {
    debugPrint(
      '[Haven] storage reset prefs marker unreadable: ${e.runtimeType}',
    );
    return;
  }
  try {
    await clear(prefs);
  } on Object catch (e) {
    debugPrint('[Haven] storage reset prefs not cleared: ${e.runtimeType}');
    return;
  }
  try {
    cleared(dataDir);
  } on Object catch (e) {
    debugPrint('[Haven] storage reset prefs not recorded: ${e.runtimeType}');
  }
}

/// Clears the preferences the reset left naming what it deleted: the pending
/// leaves, the background publish history — and the user's own display name.
///
/// The name is written here before it is published, and the reset deleted
/// the record of whether it ever was, so it may be an edit the network never
/// saw. It is dropped, and [reseedOwnNameIfOwed] takes the name the user's
/// published profile carries instead.
Future<void> clearCircleScopedPrefsAfterReset(SharedPreferences prefs) async {
  await PendingLeaveService(prefs: prefs).clearAll();
  await BackgroundLocationManager.clearPublishHistoryOnIdentityDelete();
  for (final key in prefs.getKeys()) {
    if (key.startsWith(kDisplayNamePrefPrefix)) await prefs.remove(key);
  }
  await prefs.setBool(kOwnNameReseedOwedKey, true);
}

/// Takes the user's own name from their published profile, once, after the
/// reset dropped the local one ([clearCircleScopedPrefsAfterReset]).
///
/// [fetchPublished] says what the profile relays hold
/// ([ProfileService.fetchOwnPublishedProfile]). Until they settle it — a
/// relay serves the profile, or every relay answers that none is published
/// — the reseed stays owed, and the fetch's own miss backoff spaces the asks.
/// A name the user has set since the update ([currentName]) wins over the
/// published one. Nothing is asked while the build fetches no public
/// profiles ([profilesEnabled]). Returns whether the name changed.
Future<bool> reseedOwnNameIfOwed({
  required SharedPreferences prefs,
  required Future<PublishedOwnProfile> Function() fetchPublished,
  required Future<String?> Function() currentName,
  required Future<void> Function(String name) setName,
  bool profilesEnabled = publicProfilesEnabled,
}) async {
  if (!profilesEnabled) return false;
  if (prefs.getBool(kOwnNameReseedOwedKey) != true) return false;
  final PublishedOwnProfile published;
  try {
    published = await fetchPublished();
  } on Object catch (e) {
    debugPrint('[Haven] own profile not fetched: ${e.runtimeType}');
    return false;
  }
  if (!published.answered) return false;
  var changed = false;
  // The first two tiers of Rust's `resolve_display_name`: a blank display
  // name falls through to the name. Its two deprecated fallback keys do not
  // cross the FFI, so a profile naming the user only there reseeds nothing.
  final displayName = published.profile?.displayName?.trim() ?? '';
  final name = displayName.isNotEmpty
      ? displayName
      : published.profile?.name?.trim() ?? '';
  if (await currentName() == null && name.isNotEmpty) {
    await setName(name);
    changed = true;
  }
  await prefs.remove(kOwnNameReseedOwedKey);
  return changed;
}

bool _ffiReset(String dataDir) => frb_api.resetPreV2Storage(dataDir: dataDir);

bool _ffiOwed(String dataDir) =>
    frb_api.storageResetNoticeOwed(dataDir: dataDir);

bool _ffiPrefsOwed(String dataDir) =>
    frb_api.storageResetPrefsOwed(dataDir: dataDir);

void _ffiPrefsCleared(String dataDir) =>
    frb_api.storageResetPrefsCleared(dataDir: dataDir);
