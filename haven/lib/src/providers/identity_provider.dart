/// Identity state providers.
///
/// Provides reactive access to the user's Nostr identity across the app.
/// The identity is loaded once and shared between all widgets that need it.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/providers/location_precision_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/identity_service.dart';

/// Read-only provider for the current identity.
///
/// Returns the identity if it exists, null otherwise.
/// Automatically updates when [identityNotifierProvider] changes.
///
/// Usage:
/// ```dart
/// final identityAsync = ref.watch(identityProvider);
/// return identityAsync.when(
///   data: (identity) => identity != null
///       ? Text('Logged in as ${identity.npub}')
///       : const Text('No identity'),
///   loading: () => const CircularProgressIndicator(),
///   error: (_, __) => Text('Something went wrong'),
/// );
/// ```
final identityProvider = FutureProvider<Identity?>((ref) async {
  final service = ref.watch(identityServiceProvider);
  return service.getIdentity();
});

/// Provider for the user's display name.
///
/// Returns the stored display name, or null if not set.
/// Invalidate after calling [IdentityService.setDisplayName].
final displayNameProvider = FutureProvider<String?>((ref) async {
  final service = ref.watch(identityServiceProvider);
  return service.getDisplayName();
});

/// Notifier for identity mutations (create, delete, import).
///
/// Use this for actions that modify the identity state.
///
/// Usage:
/// ```dart
/// // Create new identity
/// await ref.read(identityNotifierProvider.notifier).createIdentity();
///
/// // Import from nsec
/// await ref.read(identityNotifierProvider.notifier).importFromNsec(nsec);
///
/// // Delete identity
/// await ref.read(identityNotifierProvider.notifier).deleteIdentity();
/// ```
final identityNotifierProvider =
    AsyncNotifierProvider<IdentityNotifier, Identity?>(IdentityNotifier.new);

/// AsyncNotifier for identity state management.
///
/// Handles identity creation, import, and deletion with proper
/// loading and error states.
class IdentityNotifier extends AsyncNotifier<Identity?> {
  @override
  Future<Identity?> build() async {
    final service = ref.read(identityServiceProvider);
    return service.getIdentity();
  }

  /// Creates a new random identity.
  ///
  /// The identity is automatically persisted to secure storage.
  /// Throws [IdentityServiceException] if an identity already exists.
  Future<void> createIdentity() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final service = ref.read(identityServiceProvider);
      return service.createIdentity();
    });
    // Invalidate the read-only provider so all watchers see the new identity
    ref.invalidate(identityProvider);
  }

  /// Imports an identity from an nsec string.
  ///
  /// The nsec must be a valid NIP-19 bech32-encoded secret key.
  /// Throws [IdentityServiceException] if invalid or identity exists.
  Future<void> importFromNsec(String nsec) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final service = ref.read(identityServiceProvider);
      return service.importFromNsec(nsec);
    });
    // Invalidate the read-only provider so all watchers see the new identity
    ref.invalidate(identityProvider);
  }

  /// Deletes the identity from secure storage.
  ///
  /// This permanently removes the secret key.
  Future<void> deleteIdentity() async {
    final service = ref.read(identityServiceProvider);
    // Wipe all persisted last-known locations BEFORE deleting the
    // identity, so any failure leaves no orphaned location rows behind.
    // Best-effort: swallow errors so a storage hiccup cannot block the
    // primary objective of removing the secret key. These failures are
    // privacy-relevant (stale location rows could survive an account
    // delete), so log them loudly with a leading SECURITY marker that is
    // trivial to grep for in a bug report.
    try {
      await ref.read(locationSharingServiceProvider).wipeAll();
    } on Object catch (e, stack) {
      debugPrint(
        '[SECURITY][IdentityNotifier] CRITICAL: wipeAll failed during '
        'identity deletion — persisted last-known rows may survive the '
        'delete: ${e.runtimeType}\n$stack',
      );
    }
    // Wipe the location precision preference for the same reason.
    try {
      await ref.read(locationPrecisionProvider.notifier).resetToDefault();
    } on Object catch (e, stack) {
      debugPrint(
        '[SECURITY][IdentityNotifier] CRITICAL: precision resetToDefault '
        'failed during identity deletion — precision preference may '
        'persist into the next account: ${e.runtimeType}\n$stack',
      );
    }
    await service.deleteIdentity();
    state = const AsyncData(null);
    // Invalidate the read-only provider too
    ref.invalidate(identityProvider);
  }

  /// Exports the identity as nsec for backup.
  ///
  /// Returns the nsec string or throws if no identity exists.
  Future<String> exportNsec() async {
    final service = ref.read(identityServiceProvider);
    return service.exportNsec();
  }

  /// Gets the secret bytes for FFI operations.
  ///
  /// Returns 32 bytes of the secret key.
  Future<List<int>> getSecretBytes() async {
    final service = ref.read(identityServiceProvider);
    return service.getSecretBytes();
  }
}
