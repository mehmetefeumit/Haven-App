/// On-map attribution overlay for the active tile provider.
library;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:haven/src/constants/tiles.dart';
import 'package:url_launcher/url_launcher.dart';

/// Persistent, expandable attribution shown in the map's bottom-right corner.
///
/// Renders one credit per [TileProviderConfig.attribution] entry plus an
/// explicit Open Database License link — satisfying the OSMF Attribution
/// Guidelines, which require BOTH a credit ("© OpenStreetMap") AND the licence
/// disclosure, not a credit alone. Works for whichever provider is active
/// (three credits for Stadia, one for the OSM dev fallback).
///
/// Must be used as a child of [FlutterMap].
class MapAttribution extends StatelessWidget {
  /// Creates an attribution overlay for [config].
  const MapAttribution({required this.config, super.key});

  /// The active tile provider whose credits are displayed.
  final TileProviderConfig config;

  Future<void> _open(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } on Object catch (e) {
      // Never surface raw errors; only the type goes to the debug log.
      debugPrint('Attribution link launch failed: ${e.runtimeType}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return RichAttributionWidget(
      // alignment defaults to AttributionAlignment.bottomRight.
      showFlutterMapAttribution: false,
      // Theme-aware backplate so the expanded credits keep >=4.5:1 contrast in
      // both light and dark app themes (WCAG 1.4.3).
      popupBackgroundColor: colorScheme.surface,
      // The package default open button is a fixed-black 24px icon with a
      // sub-48dp hit area. Replace it with a themed, backplated, >=48dp target
      // so the affordance meets WCAG 2.5.5 tap size and 1.4.11 contrast in both
      // themes and over any tile.
      openButton: (context, open) => Semantics(
        button: true,
        label: 'Map credits and licence',
        child: Material(
          color: colorScheme.surface.withValues(alpha: 0.9),
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: open,
            child: SizedBox(
              width: 48,
              height: 48,
              child: Icon(
                Icons.info_outline,
                size: 20,
                color: colorScheme.onSurface,
              ),
            ),
          ),
        ),
      ),
      attributions: [
        for (final source in config.attribution)
          TextSourceAttribution(
            source.text,
            onTap: () => _open(source.url),
          ),
        // Explicit ODbL disclosure — a credit line alone is not sufficient
        // under the OSMF Attribution Guidelines.
        TextSourceAttribution(
          'Open Database License',
          prependCopyright: false,
          onTap: () => _open(kOsmCopyrightUrl),
        ),
      ],
    );
  }
}
