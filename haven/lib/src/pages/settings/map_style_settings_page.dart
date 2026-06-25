/// Map-style selection page.
///
/// Lets the user pick the basemap style and shows two live, theme-aware
/// previews of the current choice — one zoomed into a city, one into nature —
/// so the difference between styles is visible at a glance. "Minimal" follows
/// the app's light/dark theme; the other styles render the same way in both.
///
/// Every style's previews for both scenes are kept mounted (via [IndexedStack])
/// while the page is open, so all tiles load on entry and switching styles
/// repaints an already-loaded map instead of refetching — switching is instant.
/// Leaving the page disposes the previews, freeing the tile memory immediately
/// (tighter than waiting for an app-background event, and it never touches the
/// tile cache shared with the real map).
///
/// Copy is deliberately cartographic, never privacy vocabulary: changing the
/// map's appearance does not change who can see the user's location, so the
/// page avoids "exact/precise/hidden/visible" wording and lock/eye/shield
/// icons that would imply otherwise.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/constants/tiles.dart';
import 'package:haven/src/providers/map_style_provider.dart';
import 'package:haven/src/providers/tile_http_client_provider.dart';
import 'package:haven/src/widgets/map/map_attribution.dart';
import 'package:latlong2/latlong.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Centre of the city preview: the canal ring of Amsterdam, Netherlands.
///
/// A dense, water-laced city core. Zoomed in this close, "Detailed" fills with
/// place and shop labels, tram lines, and building footprints that "Minimal"
/// deliberately leaves out — so the difference is obvious at a glance.
const LatLng _kCityPreviewCenter = LatLng(52.3676, 4.8895);

/// City preview zoom: close enough that "Detailed" renders POIs and place
/// labels which "Minimal" omits.
const double _kCityPreviewZoom = 16;

/// Centre of the nature preview: Lake Louise, Banff National Park, Canada.
///
/// A glacial lake ringed by forest, hiking trails, and named peaks (Mount
/// Victoria, Fairview). Zoomed in this close, "Detailed" and "Outdoors" show
/// the water, woodland, paths, and summits that "Minimal" renders as a calm
/// empty canvas. Deliberately a different country from the city preview.
const LatLng _kNaturePreviewCenter = LatLng(51.4163, -116.2200);

/// Nature preview zoom: close enough to reveal trails, water, and terrain
/// detail that "Minimal" leaves blank.
const double _kNaturePreviewZoom = 14;

/// Height of each preview box.
const double _kPreviewHeight = 180;

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
/// settings-hub subtitle ([mapStyleLabel]). "Minimal" is first so it is the
/// natural default; it is the only theme-aware style (its dark twin exists), so
/// its subtitle is the one that mentions following the light/dark theme.
const List<_MapStyleOption> _options = [
  _MapStyleOption(
    selection: MapStyleSelection.auto(),
    title: 'Minimal',
    subtitle: 'Calm, low-detail canvas that follows your light or dark theme',
    icon: LucideIcons.sunMoon,
  ),
  _MapStyleOption(
    selection: MapStyleSelection.style(kStyleIdOsmBright),
    title: 'Detailed',
    subtitle: 'Full-colour streets, labels, and places',
    icon: LucideIcons.map,
  ),
  _MapStyleOption(
    selection: MapStyleSelection.style(kStyleIdOutdoors),
    title: 'Outdoors',
    subtitle: 'Shaded terrain with trails and parks',
    icon: LucideIcons.mountain,
  ),
];

/// Returns the user-facing label for [selection].
///
/// Used by the settings hub to summarize the current choice without
/// duplicating the option strings. An unrecognised selection (e.g. one pinned
/// to a style not exposed as a row) falls back to the first option, "Minimal".
String mapStyleLabel(MapStyleSelection selection) {
  for (final option in _options) {
    if (option.selection == selection) return option.title;
  }
  return _options.first.title;
}

/// Page presenting the map-style options as a radio group with a live preview.
class MapStyleSettingsPage extends ConsumerWidget {
  /// Creates the map-style settings page.
  const MapStyleSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(mapStyleControllerProvider);
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;

    // Index of the selected style within [_options]; drives which mounted
    // preview each IndexedStack paints. Falls back to the first option for a
    // pinned selection not exposed as a row (mirrors [mapStyleLabel]).
    final selectedIndex = _options.indexWhere((o) => o.selection == selected);
    final previewIndex = selectedIndex < 0 ? 0 : selectedIndex;

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
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(
                    header: true,
                    child: Text(
                      'Preview',
                      style: textTheme.labelLarge?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'City',
                    style: textTheme.labelMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 6),
                  _PreviewStack(
                    index: previewIndex,
                    center: _kCityPreviewCenter,
                    zoom: _kCityPreviewZoom,
                    label: 'City',
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'Nature',
                    style: textTheme.labelMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 6),
                  _PreviewStack(
                    index: previewIndex,
                    center: _kNaturePreviewCenter,
                    zoom: _kNaturePreviewZoom,
                    label: 'Nature',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A vertical [IndexedStack] of one [_MapStylePreview] per style for a single
/// scene ([center]/[zoom]/[label]).
///
/// All styles are built and laid out (so flutter_map loads and caches each
/// style's tiles as soon as the page opens), but only [index] is painted.
/// Switching the selected style just changes which already-loaded child paints,
/// so there is no refetch and no flicker. The maps dispose when the page is
/// left, freeing the tile memory.
class _PreviewStack extends StatelessWidget {
  const _PreviewStack({
    required this.index,
    required this.center,
    required this.zoom,
    required this.label,
  });

  final int index;
  final LatLng center;
  final double zoom;
  final String label;

  @override
  Widget build(BuildContext context) {
    return IndexedStack(
      index: index,
      children: [
        for (final option in _options)
          _MapStylePreview(
            selection: option.selection,
            center: center,
            zoom: zoom,
            label: label,
          ),
      ],
    );
  }
}

/// A live, non-interactive preview of how the map looks for [selection] over a
/// fixed scene ([center]/[zoom], named by [label] e.g. "City"/"Nature").
///
/// Renders a small fixed-camera [FlutterMap] using the same certificate-pinned
/// HTTP client, cache, and attribution as the real map, resolved against the
/// current theme brightness so "Minimal" previews light or dark accordingly.
/// When no Stadia API key is configured (debug/test builds) it shows a neutral
/// placeholder instead of broken tiles — and never touches the network.
class _MapStylePreview extends ConsumerWidget {
  const _MapStylePreview({
    required this.selection,
    required this.center,
    required this.zoom,
    required this.label,
  });

  final MapStyleSelection selection;

  /// Camera centre of this preview scene.
  final LatLng center;

  /// Camera zoom of this preview scene.
  final double zoom;

  /// Short scene name ("City"/"Nature") used in the accessibility label and to
  /// key the two scenes' previews apart.
  final String label;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    final config = selection.resolve(Theme.of(context).brightness);

    // One Container so the border decoration paints BEFORE the clip — a
    // ClipRRect wrapping a bordered child would shave off the stroke's outer
    // half at the corners. Per-branch Semantics live in the two builders below
    // (the live map is an image; the placeholder is not).
    return Container(
      height: _kPreviewHeight,
      width: double.infinity,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: config.apiKeyConfigured
          ? _buildLiveMap(context, ref, config)
          : _buildPlaceholder(context),
    );
  }

  Widget _buildLiveMap(
    BuildContext context,
    WidgetRef ref,
    TileProviderConfig config,
  ) {
    // Long-lived, certificate-pinned client shared with the real map. Read only
    // on this (key-configured) path so debug/test builds never construct or hit
    // the network through the preview.
    final tileHttpClient = ref.watch(tileHttpClientProvider);

    return Semantics(
      image: true,
      label: 'Map preview ($label): ${mapStyleLabel(selection)}',
      child: FlutterMap(
        // Key by scene + style so a theme flip (Minimal light↔dark changes
        // config.id) rebuilds with the right tiles, and the two scenes keep
        // distinct keys via [label].
        key: ValueKey('map_preview_${label}_${config.id}'),
        options: MapOptions(
          initialCenter: center,
          initialZoom: zoom,
          // A static showcase: no panning, zooming, or rotation.
          interactionOptions: const InteractionOptions(
            flags: InteractiveFlag.none,
          ),
        ),
        children: [
          TileLayer(
            urlTemplate: config.urlTemplate,
            additionalOptions: config.additionalOptions,
            userAgentPackageName: config.userAgentPackageName,
            maxNativeZoom: config.maxNativeZoom,
            retinaMode: RetinaMode.isHighDensity(context),
            tileProvider: NetworkTileProvider(
              httpClient: tileHttpClient,
              headers: <String, String>{
                if (config.userAgentHeader != null)
                  'User-Agent': config.userAgentHeader!,
              },
              // !kDebugMode is `false` in debug/test (matches the default) but
              // genuinely suppresses transient 403/404/429 tile errors in
              // release, so the redundancy check is a false positive here.
              // ignore: avoid_redundant_argument_values
              silenceExceptions: !kDebugMode,
              // Reuses the startup cache singleton (configured in main.dart
              // with tileKeyGenerator: tileCacheKey, which strips the api_key);
              // this no-arg call returns that same instance unchanged.
              cachingProvider: BuiltInMapCachingProvider.getOrCreateInstance(),
            ),
            // Never log the tile URL (it carries the api_key) — only the type.
            errorTileCallback: (tile, error, stackTrace) =>
                debugPrint('Preview tile load error: ${error.runtimeType}'),
            evictErrorTileStrategy: EvictErrorTileStrategy.notVisible,
          ),
          // Same mandatory Stadia/OSM attribution + ODbL link as the real map.
          MapAttribution(config: config),
        ],
      ),
    );
  }

  Widget _buildPlaceholder(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    // Not an image and not a real preview, so it must NOT inherit the live
    // branch's image/"Map preview: <style>" semantics. Collapse the inner icon
    // + caption into one neutral announcement.
    return Semantics(
      container: true,
      excludeSemantics: true,
      label: 'Map preview unavailable in this build',
      child: ColoredBox(
        color: colorScheme.surfaceContainerHighest,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(LucideIcons.map, color: colorScheme.onSurfaceVariant),
              const SizedBox(height: 8),
              Text(
                'Live preview appears in release builds',
                style: textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
