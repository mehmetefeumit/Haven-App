/// The device-side stimulus for the runtime log scanner's `S-SQLC` rule: a
/// SQLCipher database opened with the wrong key INSIDE Haven's process.
///
/// SQLCipher's own logger writes page numbers, pointers, KDF parameters and
/// database filenames to logcat / os_log from inside the app, beneath every
/// Haven log filter (Security Rule 15). Every build compiles it out
/// (`-DSQLCIPHER_OMIT_LOG`, `.cargo/config.toml` + `rust_builder/cargokit.yaml`),
/// and a wrong-key open is the first failure it would report
/// (`hmac check failed for pgno=1`). A lane that makes one here and then
/// passes its log-privacy gate has shown the logger is absent from the library
/// that device actually loaded; `scripts/ci/check_sqlcipher_logger_omitted.sh`
/// pins the call's presence and the lanes that scan it.
///
/// It discriminates from SQLCipher 4.17 (MDK v0.10.4), whose default is WARN to
/// the device log. At 4.5.7 the default level is NONE, so until that bump the
/// stimulus is logged by nothing even with the flag missing.
library;

import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:haven/src/rust/api.dart';

/// Printed once the wrong-key open has failed as it must.
const String kSqlcipherWrongKeyMarker =
    '[sqlcipher-wrong-key] a circle store the device key cannot decrypt was '
    'refused';

/// The live circle store's file name, `CIRCLES_DB_FILENAME` in
/// `haven-core/src/circle/manager.rs` (held equal by
/// `check_sqlcipher_logger_omitted.sh`). Never a pre-migration name such as
/// `circles.db`: the storage reset deletes those before the store opens, so
/// the open would create a fresh store and never decrypt a page.
const String _circleStoreFilename = 'circles-v2.db';

/// Opens the circle store under a key that cannot decrypt it, and throws
/// unless that open is refused.
///
/// Two managers over two fresh directories with one throwaway identity: the
/// control opens cleanly, so the keyring and the MLS session work in this
/// process; the stimulus differs only by a circle store of random pages, which
/// to the codec is indistinguishable from one written under another key.
/// Separate directories, never a reopen, so no MLS database file ever has two
/// sessions (Security Rule 14).
Future<void> provokeSqlcipherWrongKeyOpen() async {
  final rng = Random.secure();
  final secret = Uint8List.fromList(
    List<int>.generate(32, (_) => rng.nextInt(256)),
  );
  final control = await Directory.systemTemp.createTemp('haven_sqlc_ok_');
  final stimulus = await Directory.systemTemp.createTemp('haven_sqlc_bad_');
  try {
    final controlManager = await CircleManagerFfi.newInstance(
      dataDir: control.path,
      identitySecretBytes: Uint8List.fromList(secret),
    );
    controlManager.dispose();

    File('${stimulus.path}/$_circleStoreFilename').writeAsBytesSync(
      List<int>.generate(2 * 4096, (_) => rng.nextInt(256)),
    );
    var refused = false;
    try {
      final opened = await CircleManagerFfi.newInstance(
        dataDir: stimulus.path,
        identitySecretBytes: Uint8List.fromList(secret),
      );
      opened.dispose();
    } on Object catch (_) {
      // The error text is never read: the control above is what attributes
      // this failure to the key.
      refused = true;
    }
    if (!refused) {
      throw StateError(
        '[sqlcipher-wrong-key] a circle store of random pages OPENED under the '
        'device key, so SQLCipher never ran its wrong-key path and the '
        "lane's S-SQLC scan has nothing to catch. Harness failure.",
      );
    }
    debugPrint(kSqlcipherWrongKeyMarker);
  } finally {
    // Security Rule 9: minimise the Dart-side secret's lifetime.
    for (var i = 0; i < secret.length; i++) {
      secret[i] = 0;
    }
    for (final dir in <Directory>[control, stimulus]) {
      try {
        await dir.delete(recursive: true);
      } on Object catch (e) {
        debugPrint(
          '[sqlcipher-wrong-key] temp-dir cleanup failed: ${e.runtimeType}',
        );
      }
    }
  }
}
