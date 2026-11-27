/// The one secure-storage configuration the identity secret key is read and
/// written under, in every isolate and the E2E harness.
///
/// The options are part of where the key lives: a read under different ones
/// can miss it or, on Android, take a path that deletes it. So every site
/// uses [identitySecureStorage], and `identity_secure_storage_pinned_test.dart`
/// holds both that and each option's value.
library;

// Every option that decides where the key lives or what happens to it is
// spelled out, defaults included, so none moves with the plugin's defaults.
// ignore_for_file: avoid_redundant_argument_values

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Secure-storage key of the identity secret bytes (base64).
const String identityStorageKey = 'haven.nostr.identity';

/// Secure storage for the identity secret key.
///
/// Android: `resetOnError: false`, because the plugin's default answers any
/// failed read or decrypt by deleting the stored data (one entry, or all of
/// it) and reporting success, which Haven would read as "no identity" and
/// replace with a new key. The ciphers are pinned at the plugin's current
/// defaults, which the stored key is encrypted under: a changed default would
/// run the plugin's algorithm migration, which deletes the old wrapping key
/// before re-encrypting.
///
/// iOS: readable from first unlock until reboot, never synchronised, never
/// restored onto another device.
const FlutterSecureStorage identitySecureStorage = FlutterSecureStorage(
  iOptions: IOSOptions(
    accessibility: KeychainAccessibility.first_unlock_this_device,
    synchronizable: false,
  ),
  aOptions: AndroidOptions(
    resetOnError: false,
    migrateOnAlgorithmChange: true,
    enforceBiometrics: false,
    keyCipherAlgorithm:
        KeyCipherAlgorithm.RSA_ECB_OAEPwithSHA_256andMGF1Padding,
    storageCipherAlgorithm: StorageCipherAlgorithm.AES_GCM_NoPadding,
  ),
);
