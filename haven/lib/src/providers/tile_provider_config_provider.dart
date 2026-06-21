/// Riverpod provider exposing the active map [TileProviderConfig].
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/constants/tiles.dart';
import 'package:haven/src/providers/map_style_provider.dart';

/// The tile provider configuration used by the map, keyed by [Brightness].
///
/// A [Provider.family] over the *current* brightness: it watches
/// [mapStyleControllerProvider] and resolves the user's [MapStyleSelection]
/// against the passed-in brightness. The map reads it with
/// `Theme.of(context).brightness`, so an "Auto" selection follows the live
/// light/dark theme (including an OS sunset auto-dark under `ThemeMode.system`)
/// because the framework rebuilds the map on every brightness change — no
/// context-free brightness state is needed.
///
/// Defaults to [stadiaAlidadeSmooth] (light) / [stadiaAlidadeSmoothDark] (dark)
/// while the selection is "Auto". Tests can swap the result by overriding
/// [mapStyleControllerProvider]; mirroring the service-provider singletons.
final ProviderFamily<TileProviderConfig, Brightness>
    tileProviderConfigProvider =
    Provider.family<TileProviderConfig, Brightness>(
      (ref, brightness) {
        final selection = ref.watch(mapStyleControllerProvider);
        return selection.resolve(brightness);
      },
    );
