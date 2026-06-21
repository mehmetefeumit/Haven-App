/// Map-style selection page.
///
/// Lets the user pick the basemap style: "Auto" (follow the app's light/dark
/// theme) or an explicit style. The selection is persisted via
/// [mapStyleControllerProvider] and takes effect on the map immediately.
///
/// Copy is deliberately cartographic, never privacy vocabulary: changing the
/// map's appearance does not change who can see the user's location, so the
/// page avoids "exact/precise/hidden/visible" wording and lock/eye/shield
/// icons that would imply otherwise.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/constants/tiles.dart';
import 'package:haven/src/providers/map_style_provider.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// User-visible metadata for a single map-style choice.
@immutable
class _MapStyleOption {
  const _MapStyleOption({
    required this.selection,
    required this.title,
    required this.subtitle,
    required this.icon,
  });

  final MapStyleSelection selection;
  final String title;
  final String subtitle;
  final IconData icon;
}

/// The ordered list of selectable map styles.
///
/// The single source of truth for both this page's radio list and the
/// settings-hub subtitle ([mapStyleLabel]). "Auto" is first so it is the
/// natural default. The muted Alidade Smooth canvas is reached only through
/// "Auto" (which is theme-aware), so dark-theme users are never stranded on a
/// glaring light basemap.
const List<_MapStyleOption> _options = [
  _MapStyleOption(
    selection: MapStyleSelection.auto(),
    title: 'Auto',
    subtitle: 'Match your current theme, light or dark',
    icon: LucideIcons.sunMoon,
  ),
  _MapStyleOption(
    selection: MapStyleSelection.style(kStyleIdOsmBright),
    title: 'Detailed',
    subtitle: 'Familiar full colour streets and landmarks',
    icon: LucideIcons.map,
  ),
  _MapStyleOption(
    selection: MapStyleSelection.style(kStyleIdOutdoors),
    title: 'Outdoors',
    subtitle: 'Trails, parks, and terrain',
    icon: LucideIcons.mountain,
  ),
];

/// Returns the user-facing label for [selection].
///
/// Used by the settings hub to summarize the current choice without
/// duplicating the option strings. An unrecognised selection (e.g. one pinned
/// to a style not exposed as a row) falls back to the first option, "Auto".
String mapStyleLabel(MapStyleSelection selection) {
  for (final option in _options) {
    if (option.selection == selection) return option.title;
  }
  return _options.first.title;
}

/// Page presenting the map-style options as a radio group.
class MapStyleSettingsPage extends ConsumerWidget {
  /// Creates the map-style settings page.
  const MapStyleSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(mapStyleControllerProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Map style')),
      body: RadioGroup<MapStyleSelection>(
        groupValue: selected,
        onChanged: (selection) {
          if (selection == null) return;
          // setStyle is a no-op when the selection is unchanged, so re-tapping
          // the active row writes nothing. RadioListTile announces the
          // selection change itself, so no manual SemanticsService call is
          // needed (and a manual one would race the rebuild).
          ref.read(mapStyleControllerProvider.notifier).setStyle(selection);
        },
        child: ListView(
          children: [
            for (final option in _options)
              RadioListTile<MapStyleSelection>(
                value: option.selection,
                title: Text(option.title),
                subtitle: Text(option.subtitle),
                secondary: Icon(option.icon),
              ),
          ],
        ),
      ),
    );
  }
}
