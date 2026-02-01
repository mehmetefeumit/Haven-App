/// Abstract interface for identity services.
///
/// Provides a platform-agnostic API for managing Nostr identity.
/// This abstraction allows for:
/// - Easy testing with mock implementations
/// - Clean separation between storage and identity management
///
/// Implementations:
/// - NostrIdentityService - Production implementation using Rust core
library;

import 'package:flutter/foundation.dart';

/// Exception thrown when identity operations fail.
class IdentityServiceException implements Exception {
  /// Creates an [IdentityServiceException] with the given message.
  const IdentityServiceException(this.message);

  /// The error message.
  final String message;

  @override
  String toString() => 'IdentityServiceException: $message';
}

/// Public identity information.
///
/// Contains only public data that can be safely stored and shared.
/// This is a Dart-native representation of the Rust PublicIdentity.
@immutable
class Identity {
  /// Creates a new [Identity].
  const Identity({
    required this.pubkeyHex,
    required this.npub,
    required this.createdAt,
  });

  /// Public key as 64-character hex string.
  ///
  /// This format is used for MDK operations and internal references.
  final String pubkeyHex;

  /// Public key in NIP-19 bech32 format (npub1...).
  ///
  /// This is the human-readable format for sharing with others.
  final String npub;

  /// When this identity was created.
  final DateTime createdAt;

  @override
  String toString() => 'Identity(npub: $npub)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Identity &&
          runtimeType == other.runtimeType &&
          pubkeyHex == other.pubkeyHex;

  @override
  int get hashCode => pubkeyHex.hashCode;
}

/// Abstract interface for identity services.
///
/// Manages the user's Nostr identity (nsec/npub keypair).
/// The identity is used for:
/// - Signing Nostr events (kind 443 KeyPackage, etc.)
/// - Providing public key to MDK for MLS credential binding
abstract class IdentityService {
  /// Checks if an identity exists.
  ///
  /// Returns `true` if an identity has been created or imported.
  Future<bool> hasIdentity();

  /// Gets the current identity.
  ///
  /// Returns `null` if no identity exists.
  /// Throws [IdentityServiceException] if loading fails.
  Future<Identity?> getIdentity();

  /// Creates a new random identity.
  ///
  /// The identity is automatically persisted to secure storage.
  ///
  /// Throws [IdentityServiceException] if:
  /// - An identity already exists (call [deleteIdentity] first)
  /// - Storage operation fails
  Future<Identity> createIdentity();

  /// Imports an identity from an nsec string.
  ///
  /// The nsec must be a valid NIP-19 bech32-encoded secret key
  /// starting with "nsec1".
  ///
  /// Throws [IdentityServiceException] if:
  /// - An identity already exists
  /// - The nsec is invalid
  /// - Storage operation fails
  Future<Identity> importFromNsec(String nsec);

  /// Exports the identity as nsec for backup.
  ///
  /// **Security Warning**: This exposes the secret key.
  /// Only use for user-initiated backup with appropriate warnings.
  ///
  /// Throws [IdentityServiceException] if no identity exists.
  Future<String> exportNsec();

  /// Signs a 32-byte message hash using the identity.
  ///
  /// Returns the 64-byte Schnorr signature as a 128-character hex string.
  ///
  /// Throws [IdentityServiceException] if:
  /// - No identity exists
  /// - The message hash is not exactly 32 bytes
  /// - Signing fails
  Future<String> sign(Uint8List messageHash);

  /// Gets the public key as a hex string.
  ///
  /// This format is needed for MDK operations.
  ///
  /// Throws [IdentityServiceException] if no identity exists.
  Future<String> getPubkeyHex();

  /// Deletes the identity from secure storage.
  ///
  /// This permanently removes the secret key. Make sure the user
  /// has exported a backup before calling this.
  ///
  /// Throws [IdentityServiceException] if deletion fails.
  Future<void> deleteIdentity();

  /// Clears in-memory caches.
  ///
  /// Call this when the app goes to background to reduce
  /// the window of exposure for secret material in memory.
  Future<void> clearCache();
}
