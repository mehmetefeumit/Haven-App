/// Map-style selection page.
///
/// Lets the user pick the basemap style and shows two previews of the current
/// choice — one zoomed into a city, one into nature — so the difference between
/// styles is visible at a glance. "Minimal" follows the app's light/dark theme;
/// the other styles look the same in both.
///
/// The previews are images bundled with the app, one per style and scene
/// (rendered by `scripts/generate_map_style_previews.sh`), so opening the page
/// makes no network request and costs no tile credits. Every image the radio
/// list can switch to is decoded when the page opens, so a tap repaints from
/// the image cache in the same frame.
///
/// Copy is deliberately cartographic, never privacy vocabulary: changing the
/// map's appearance does not change who can see the user's location, so the
/// page avoids "exact/precise/hidden/visible" wording and lock/eye/shield
/// icons that would imply otherwise.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/constants/tiles.dart';
import 'package:haven/src/providers/map_style_provider.dart';
import 'package:haven/src/widgets/map/map_attribution.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// A fixed scene every style is previewed over.
///
/// Each scene's centre and zoom, and why they were chosen, are defined once, in
/// `scripts/generate_map_style_previews.sh`, which renders the bundled images.
enum MapStylePreviewScene {
  /// A dense city core: street, place and shop labels set the styles apart.
  city,

  /// Lake, forest, trails and peaks: terrain and paths set the styles apart.
  nature,
}

/// Bundled preview image of [config] over [scene].
///
/// Named by [TileProviderConfig.id], so every config
/// [MapStyleSelection.resolve] can return has exactly one image per scene and
/// there is no second style-to-image mapping to drift.
String mapStylePreviewAsset(
  TileProviderConfig config,
  MapStylePreviewScene scene,
) => 'assets/map_style_previews/${config.id}_${scene.name}.webp';

/// Height of each preview box. The generator renders the images at this
/// logical height so the map's labels appear at their native size.
@visibleForTesting
const double kMapStylePreviewHeight = 180;

/// User-visible metadata for a single map-style choice.
///
/// The localized [title]/[subtitle] are resolved from [AppLocalizations] at use
/// time (not stored as raw strings) so the option list can stay `const` while
/// its labels follow the active locale.
@immutable
class _MapStyleOption {
  const _MapStyleOption({
    required this.selection,
    required this.title,
    required this.subtitle,
    required this.icon,
  });

  final MapStyleSelection selection;
  final String Function(AppLocalizations l10n) title;
  final String Function(AppLocalizations l10n) subtitle;
  final IconData icon;
}

/// The ordered list of selectable map styles.
///
/// The single source of truth for both this page's radio list and the preview's
/// spoken label ([mapStyleLabel]). "Minimal" is first so it is the
/// natural default; it is the only theme-aware style (its dark twin exists), so
/// its subtitle is the one that mentions following the light/dark theme.
const List<_MapStyleOption> _options = [
  _MapStyleOption(
    selection: MapStyleSelection.auto(),
    title: _minimalTitle,
    subtitle: _minimalSubtitle,
    icon: LucideIcons.sunMoon,
  ),
  _MapStyleOption(
    selection: MapStyleSelection.style(kStyleIdOsmBright),
    title: _detailedTitle,
    subtitle: _detailedSubtitle,
    icon: LucideIcons.map,
  ),
  _MapStyleOption(
    selection: MapStyleSelection.style(kStyleIdOutdoors),
    title: _outdoorsTitle,
    subtitle: _outdoorsSubtitle,
    icon: LucideIcons.mountain,
  ),
];

// Top-level resolvers so [_options] can be a `const` list of tear-offs.
String _minimalTitle(AppLocalizations l10n) => l10n.mapStyleMinimalTitle;
String _minimalSubtitle(AppLocalizations l10n) => l10n.mapStyleMinimalSubtitle;
String _detailedTitle(AppLocalizations l10n) => l10n.mapStyleDetailedTitle;
String _detailedSubtitle(AppLocalizations l10n) =>
    l10n.mapStyleDetailedSubtitle;
String _outdoorsTitle(AppLocalizations l10n) => l10n.mapStyleOutdoorsTitle;
String _outdoorsSubtitle(AppLocalizations l10n) =>
    l10n.mapStyleOutdoorsSubtitle;

/// Returns the user-facing label for [selection].
///
/// Names the current choice in the preview's semantics label without
/// duplicating the option strings. An unrecognised selection (e.g. one pinned
/// to a style not exposed as a row) falls back to the first option, "Minimal".
String mapStyleLabel(AppLocalizations l10n, MapStyleSelection selection) {
  for (final option in _options) {
    if (option.selection == selection) return option.title(l10n);
  }
  return _options.first.title(l10n);
}

/// The selections the page's radio list offers, in display order.
@visibleForTesting
List<MapStyleSelection> get selectableMapStyles => [
  for (final option in _options) option.selection,
];

String _sceneLabel(AppLocalizations l10n, MapStylePreviewScene scene) =>
    switch (scene) {
      MapStylePreviewScene.city => l10n.mapStylePreviewCity,
      MapStylePreviewScene.nature => l10n.mapStylePreviewNature,
    };

/// The decode-sized provider for one preview. The page and its precache build
/// it the same way, so both resolve to the same image-cache key.
ImageProvider _previewImage(
  BuildContext context,
  TileProviderConfig config,
  MapStylePreviewScene scene,
) => ResizeImage.resizeIfNeeded(
  null,
  (kMapStylePreviewHeight * MediaQuery.devicePixelRatioOf(context)).round(),
  AssetImage(mapStylePreviewAsset(config, scene)),
);

/// Page presenting the map-style options as a radio group with a preview.
class MapStyleSettingsPage extends ConsumerStatefulWidget {
  /// Creates the map-style settings page.
  const MapStyleSettingsPage({super.key});

  @override
  ConsumerState<MapStyleSettingsPage> createState() =>
      _MapStyleSettingsPageState();
}

class _MapStyleSettingsPageState extends ConsumerState<MapStyleSettingsPage> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Without this, the first tap on each style paints an empty box for the
    // frames its asset takes to decode.
    final brightness = Theme.of(context).brightness;
    for (final option in _options) {
      for (final scene in MapStylePreviewScene.values) {
        final config = option.selection.resolve(brightness);
        unawaited(
          precacheImage(_previewImage(context, config, scene), context),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final selected = ref.watch(mapStyleControllerProvider);
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;
    final colorScheme = theme.colorScheme;
    // Resolved exactly as the real map resolves it, so a pinned selection the
    // list does not offer still previews what the map shows.
    final config = selected.resolve(theme.brightness);
    final styleLabel = mapStyleLabel(l10n, selected);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.mapStyleTitle)),
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
                title: Text(option.title(l10n)),
                subtitle: Text(option.subtitle(l10n)),
                secondary: Icon(option.icon),
              ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(
                    header: true,
                    child: Text(
                      l10n.mapStylePreviewHeader,
                      style: textTheme.labelLarge?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  for (final scene in MapStylePreviewScene.values) ...[
                    SizedBox(
                      height: scene == MapStylePreviewScene.values.first
                          ? 12
                          : 20,
                    ),
                    Text(
                      _sceneLabel(l10n, scene),
                      style: textTheme.labelMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 6),
                    _MapStylePreview(
                      image: _previewImage(context, config, scene),
                      semanticLabel: l10n.mapStylePreviewSemantics(
                        _sceneLabel(l10n, scene),
                        styleLabel,
                      ),
                    ),
                  ],
                  const SizedBox(height: 4),
                  // The images are produced from OpenStreetMap data in
                  // Stadia's styles, so they carry the real map's credits.
                  StaticMapAttribution(config: config),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One bordered, rounded preview box showing [image].
class _MapStylePreview extends StatelessWidget {
  const _MapStylePreview({required this.image, required this.semanticLabel});

  final ImageProvider image;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    // One Container so the border decoration paints BEFORE the clip — a
    // ClipRRect wrapping a bordered child would shave off the stroke's outer
    // half at the corners.
    return Container(
      height: kMapStylePreviewHeight,
      width: double.infinity,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Image(
        image: image,
        fit: BoxFit.cover,
        semanticLabel: semanticLabel,
      ),
    );
  }
}
