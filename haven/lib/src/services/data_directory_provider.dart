/// The SINGLE source of truth for the app's data directory (M7-6).
///
/// Every entrypoint/isolate that opens `circles.db` (or the tile/avatar stores)
/// MUST resolve its path through [DataDirectoryProvider] so they all agree on
/// ONE location. There are four such sites — the app `main()`, the relay
/// service, the circle service, and the Android FGS background isolate. If any
/// of them resolved a divergent path, two `CircleManagerFfi` instances would
/// open two different SQLCipher DBs and the MLS state would SPLIT-BRAIN — a
/// worse failure than the fork the staged-commit marker guards against.
///
/// ## iOS App-Group extension (device/CI)
///
/// M9's Notification Service Extension and M7's `BGTask`/SLC relaunch run in a
/// separate iOS process that CANNOT see the app's private Documents directory —
/// they can only share an **App-Group container**. When that lands,
/// [PathProviderDataDirectory.getDataDirectory] gains an iOS branch that returns
/// the App-Group container path (resolved via a platform channel, since
/// `path_provider` does not expose it) and performs a one-time
/// copy-then-delete-with-sentinel migration of the already-encrypted DB (a RAW
/// ciphertext file move — never `sqlcipher_export`, which would transiently
/// materialize plaintext). Because this resolver is the single call every
/// isolate makes, that migration runs idempotently from whichever entrypoint
/// fires first — no split-brain window. Keeping the logic HERE (not inlined at
/// any call site) is what makes that guarantee hold.
library;

import 'package:path_provider/path_provider.dart';

/// Abstraction for resolving the app data directory. Injected in tests.
abstract class DataDirectoryProvider {
  /// Resolves the absolute path of the app's data directory.
  Future<String> getDataDirectory();
}

/// Production resolver over `path_provider`.
///
/// Today this is the app's private Documents directory (`…/haven`). The iOS
/// App-Group branch (see the library docs) is added with the M7-6 native work.
class PathProviderDataDirectory implements DataDirectoryProvider {
  /// Creates a new [PathProviderDataDirectory].
  const PathProviderDataDirectory();

  @override
  Future<String> getDataDirectory() async {
    final appDir = await getApplicationDocumentsDirectory();
    return '${appDir.path}/haven';
  }
}
