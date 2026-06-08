/// Riverpod provider exposing the active map [TileProviderConfig].
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/constants/tiles.dart';

/// The tile provider configuration used by the map.
///
/// A plain synchronous [Provider] so the map can read it directly in `build`
/// and tests can swap providers via `ProviderScope(overrides: [...])` —
/// mirroring the service-provider singletons. Defaults to
/// [defaultTileProvider] (Stadia Maps).
final tileProviderConfigProvider = Provider<TileProviderConfig>(
  (ref) => defaultTileProvider,
);
