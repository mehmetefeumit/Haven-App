/// Shared helper for triggering the own-profile local-outbox sync from the
/// widget layer (mirrors `profile_refresh_trigger.dart`).
///
/// Every in-process sync entry — the display-name/avatar editors and
/// onboarding — goes through [triggerProfileSync], and the resume/cold-start
/// triggers (`map_shell.dart`) go through [triggerProfileSyncRetry], so Dart
/// coalescing in `OwnProfileSyncController` (not the Rust
/// `profile_sync_lock`, which is only the backstop) is the normal serializer
/// for overlapping in-process calls.
///
/// NEVER wire either of these into a background isolate
/// (`background_location_task.dart` / `background_catchup_worker.dart`) — a
/// publish there would need its own identity/manager wiring outside the
/// foreground Riverpod container this trigger reads from, and would defeat
/// the single coalescing point above.
/// `test/lints/background_isolate_no_profile_sync_test.dart` guards this.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/providers/profile_sync_provider.dart';

/// Runs one own-profile sync pass immediately, unconditionally.
///
/// Use right after a local save (`ProfileService.updateOwnProfile` /
/// `ProfileService.setOwnAvatar` returning), where a fresh edit is known to
/// be pending — the point of a save is for it to reach the network as soon
/// as possible.
///
/// Fire-and-forget: never throws to the caller and does not await network
/// completion, so it is safe to call from a widget that may unmount before
/// the publish finishes (`OwnProfileSyncController` is non-autoDispose and
/// keeps running independently of any widget's lifecycle). Coalescing lives
/// in [OwnProfileSyncController.sync].
void triggerProfileSync(WidgetRef ref) {
  unawaited(ref.read(ownProfileSyncProvider.notifier).sync());
}

/// Syncs only if the local outbox is pending AND the persisted backoff
/// permits another attempt now — never unconditionally (relay metadata
/// minimization). The resume/cold-start entry point.
///
/// Fire-and-forget, same contract as [triggerProfileSync].
void triggerProfileSyncRetry(WidgetRef ref) {
  unawaited(ref.read(ownProfileSyncProvider.notifier).retryIfPending());
}
