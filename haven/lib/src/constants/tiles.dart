/// Map tile provider configuration for Haven.
///
/// Centralizes the tile source, its mandatory attribution, and the related
/// external links so the provider can be swapped without a binary update —
/// mirroring the [`defaultRelays`](relays.dart) constant + getter pattern.
///
/// The production default is **Stadia Maps**. The raw OpenStreetMap endpoint
/// is retained only as a clearly-marked development fallback and MUST never
/// be the release default (enforced by `scripts/ci/check_tile_provider.sh`).
library;

import 'package:flutter/foundation.dart';

// ---------------------------------------------------------------------------
// PLACEHOLDERS — replace before any public release.
//
// Haven does not yet own a public domain or contact mailbox. These values are
// embedded in the OpenStreetMap-fallback User-Agent and surfaced in the
// privacy policy / About page. Tracked in docs/MAP_AND_PRIVACY_BACKLOG.md
// (register domain + mailbox, then replace these two constants).
// ---------------------------------------------------------------------------

/// PLACEHOLDER public website URL. See file header.
const String kHavenWebsiteUrl = 'https://haven.example';

/// PLACEHOLDER contact mailbox. See file header.
const String kHavenContactEmail = 'maps@haven.example';

// ---------------------------------------------------------------------------
// Canonical external links (attribution, reporting, donations, provider legal)
// ---------------------------------------------------------------------------

/// OpenStreetMap copyright & licence page (ODbL). The clickable target for the
/// mandatory "© OpenStreetMap" attribution and the ODbL disclosure.
const String kOsmCopyrightUrl = 'https://www.openstreetmap.org/copyright';

/// "Report a map issue" target (OSMF recommended).
const String kOsmFixTheMapUrl = 'https://www.openstreetmap.org/fixthemap';

/// "Support OpenStreetMap" / donate target.
const String kSupportOsmUrl = 'https://supporting.openstreetmap.org/';

/// Stadia Maps home page (attribution link target).
const String kStadiaHomeUrl = 'https://stadiamaps.com/';

/// OpenMapTiles home page (attribution link target).
const String kOpenMapTilesUrl = 'https://openmaptiles.org/';

/// Stadia Maps privacy policy (named in Haven's privacy policy).
const String kStadiaPrivacyUrl = 'https://stadiamaps.com/privacy/privacy-policy/';

/// Stadia Maps terms of service.
const String kStadiaTermsUrl = 'https://stadiamaps.com/terms-of-service/';

/// Stadia Maps Data Processing Addendum (GDPR/UK-GDPR).
const String kStadiaDpaUrl = 'https://stadiamaps.com/legal/data-processing-addendum/';

// ---------------------------------------------------------------------------
// Stadia API key (build-time injected, never committed)
// ---------------------------------------------------------------------------

/// Sentinel used when no real Stadia API key is supplied at build time.
const String stadiaApiKeyPlaceholder = 'STADIA_API_KEY_PLACEHOLDER';

/// Stadia Maps API key, injected at build time via
/// `--dart-define=STADIA_API_KEY=<key>` (CI secret).
///
/// Never commit a real key. When unset it falls back to
/// [stadiaApiKeyPlaceholder] and [TileProviderConfig.apiKeyConfigured]
/// reports `false`, so dev builds degrade to error tiles rather than crashing.
const String stadiaApiKey = String.fromEnvironment(
  'STADIA_API_KEY',
  defaultValue: stadiaApiKeyPlaceholder,
);

// ---------------------------------------------------------------------------
// Config types
// ---------------------------------------------------------------------------

/// A single attribution credit shown on the map and in the licences list.
@immutable
class TileAttributionSource {
  /// Creates an attribution credit linking [text] to [url].
  const TileAttributionSource(this.text, this.url);

  /// The credited entity (e.g. `OpenStreetMap`). Rendered after a `©`.
  final String text;

  /// The page the credit links to.
  final String url;
}

/// Immutable description of a map tile source and its display obligations.
@immutable
class TileProviderConfig {
  /// Creates a tile provider configuration.
  const TileProviderConfig({
    required this.id,
    required this.urlTemplate,
    required this.attribution,
    required this.maxNativeZoom,
    required this.userAgentPackageName,
    this.additionalOptions = const {},
    this.userAgentHeader,
    this.requiresApiKey = false,
  });

  /// Stable identifier (used in tests and the CI guard).
  final String id;

  /// flutter_map URL template; may contain `{api_key}` and `{r}` tokens.
  final String urlTemplate;

  /// Token substitutions for [urlTemplate] (e.g. the Stadia `api_key`).
  final Map<String, String> additionalOptions;

  /// Credits that MUST be shown on the map surface (ODbL §4.3).
  final List<TileAttributionSource> attribution;

  /// Highest zoom the server renders; higher zooms scale client-side.
  final int maxNativeZoom;

  /// Package name folded into flutter_map's default `User-Agent`.
  final String userAgentPackageName;

  /// Explicit, contactable `User-Agent` for endpoints that require one (the
  /// OSM raw fallback). `null` for authenticated providers (Stadia), which
  /// must not receive a Haven contact string. flutter_map respects a
  /// caller-supplied `User-Agent` header via `putIfAbsent`.
  final String? userAgentHeader;

  /// Whether [urlTemplate] needs a real API key to return tiles.
  final bool requiresApiKey;

  /// Whether a usable API key is configured (always `true` when none is
  /// required). `false` while only the [stadiaApiKeyPlaceholder] is present.
  bool get apiKeyConfigured {
    if (!requiresApiKey) return true;
    final key = additionalOptions['api_key'];
    return key != null && key.isNotEmpty && key != stadiaApiKeyPlaceholder;
  }
}

// ---------------------------------------------------------------------------
// Concrete providers
// ---------------------------------------------------------------------------

/// Stable identifier for the [stadiaAlidadeSmooth] config.
///
/// These ids are persisted (see `providers/map_style_provider.dart`) and
/// asserted by tests, so the settings selection model and the configs below
/// share one source of truth instead of repeating magic strings.
const String kStyleIdAlidadeSmooth = 'stadia_alidade_smooth';

/// Stable identifier for the [stadiaAlidadeSmoothDark] config.
const String kStyleIdAlidadeSmoothDark = 'stadia_alidade_smooth_dark';

/// Stable identifier for the [stadiaOsmBright] config.
const String kStyleIdOsmBright = 'stadia_osm_bright';

/// Stable identifier for the [stadiaOutdoors] config.
const String kStyleIdOutdoors = 'stadia_outdoors';

/// Attribution shared by every Stadia OpenMapTiles-schema basemap Haven ships
/// (Alidade Smooth + Dark, OSM Bright, Outdoors).
///
/// Renders as "© Stadia Maps © OpenMapTiles © OpenStreetMap". Valid ONLY for
/// the OpenMapTiles-based styles: a Stamen, Watercolor, or satellite style
/// would each require a tailored credit list (e.g. "© Stamen Design" or the
/// CNES/Airbus/PlanetObserver imagery credit) and MUST NOT reuse this.
const List<TileAttributionSource> _stadiaBaseAttribution = [
  TileAttributionSource('Stadia Maps', kStadiaHomeUrl),
  TileAttributionSource('OpenMapTiles', kOpenMapTilesUrl),
  TileAttributionSource('OpenStreetMap', kOsmCopyrightUrl),
];

/// Production default: Stadia Maps "alidade_smooth" raster tiles.
///
/// Chosen for Haven's privacy posture (anonymized IPs, no data sale, DPA
/// available). Requires a paid subscription + API key in release builds.
/// Attribution renders as "© Stadia Maps © OpenMapTiles © OpenStreetMap".
const TileProviderConfig stadiaAlidadeSmooth = TileProviderConfig(
  id: kStyleIdAlidadeSmooth,
  urlTemplate:
      'https://tiles.stadiamaps.com/tiles/alidade_smooth/{z}/{x}/{y}{r}.png'
      '?api_key={api_key}',
  additionalOptions: {'api_key': stadiaApiKey},
  attribution: _stadiaBaseAttribution,
  maxNativeZoom: 20,
  userAgentPackageName: 'com.oblivioustech.haven',
  requiresApiKey: true,
);

/// Dark twin of [stadiaAlidadeSmooth] ("alidade_smooth_dark").
///
/// A desaturated dark canvas built so coloured overlays stay legible. Shares
/// the base attribution and the Starter tier (1 credit/tile), so the on-map
/// credit is identical to the light default. Paired with [stadiaAlidadeSmooth]
/// by the "Auto" map-style selection to follow the app's light/dark theme.
const TileProviderConfig stadiaAlidadeSmoothDark = TileProviderConfig(
  id: kStyleIdAlidadeSmoothDark,
  urlTemplate:
      'https://tiles.stadiamaps.com/tiles/alidade_smooth_dark'
      '/{z}/{x}/{y}{r}.png?api_key={api_key}',
  additionalOptions: {'api_key': stadiaApiKey},
  attribution: _stadiaBaseAttribution,
  maxNativeZoom: 20,
  userAgentPackageName: 'com.oblivioustech.haven',
  requiresApiKey: true,
);

/// Stadia Maps "osm_bright": the familiar full-colour OpenStreetMap look.
///
/// Surfaced to users as "Detailed". Same PNG/retina/zoom-20 economics and the
/// same base attribution as the Alidade styles (no extra credit).
const TileProviderConfig stadiaOsmBright = TileProviderConfig(
  id: kStyleIdOsmBright,
  urlTemplate:
      'https://tiles.stadiamaps.com/tiles/osm_bright/{z}/{x}/{y}{r}.png'
      '?api_key={api_key}',
  additionalOptions: {'api_key': stadiaApiKey},
  attribution: _stadiaBaseAttribution,
  maxNativeZoom: 20,
  userAgentPackageName: 'com.oblivioustech.haven',
  requiresApiKey: true,
);

/// Stadia Maps "outdoors": trails, parks, and terrain shading.
///
/// Surfaced to users as "Outdoors". Stays on the base attribution and the
/// Starter tier, unlike the Stamen terrain styles which require an extra
/// "© Stamen Design" credit.
const TileProviderConfig stadiaOutdoors = TileProviderConfig(
  id: kStyleIdOutdoors,
  urlTemplate:
      'https://tiles.stadiamaps.com/tiles/outdoors/{z}/{x}/{y}{r}.png'
      '?api_key={api_key}',
  additionalOptions: {'api_key': stadiaApiKey},
  attribution: _stadiaBaseAttribution,
  maxNativeZoom: 20,
  userAgentPackageName: 'com.oblivioustech.haven',
  requiresApiKey: true,
);

/// All user-selectable Stadia basemaps, in catalog order.
///
/// Single source of truth for resolving a persisted style id back to a config
/// and for validating stored selections (`providers/map_style_provider.dart`).
/// Every entry targets `tiles.stadiamaps.com`, is PNG with the `{r}` retina
/// token, and shares the base attribution — so switching among them never
/// changes the host (TLS pinning holds) or the on-map credit.
///
/// Privacy note: each style fetches a distinct path slug
/// (`alidade_smooth`/`alidade_smooth_dark`/`osm_bright`/`outdoors`), a
/// low-entropy signal visible to Stadia and any on-path observer. It carries no
/// Nostr/relay correlation and the choice is stored only on-device, so the
/// exposure is negligible — but keep new styles on the same host so this stays
/// the only added signal.
const List<TileProviderConfig> kTileStyleCatalog = [
  stadiaAlidadeSmooth,
  stadiaAlidadeSmoothDark,
  stadiaOsmBright,
  stadiaOutdoors,
];

/// Development-only fallback: the raw OpenStreetMap tile endpoint.
///
/// NEVER the release default — the OSMF tile usage policy forbids it at scale
/// and `scripts/ci/check_tile_provider.sh` fails the build if this endpoint
/// becomes the default. Sends a contactable User-Agent (see
/// [TileProviderConfig.userAgentHeader]) so the OSMF can reach us before
/// blocking (per their policy).
const TileProviderConfig osmRawDevFallback = TileProviderConfig(
  id: 'osm_raw_dev',
  // The only sanctioned use of the raw OSM endpoint lives in this constants
  // file: scripts/ci/check_tile_provider.sh permits it here only and verifies
  // the release default stays on Stadia.
  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
  attribution: [
    TileAttributionSource('OpenStreetMap', kOsmCopyrightUrl),
  ],
  maxNativeZoom: 19,
  userAgentPackageName: 'com.oblivioustech.haven',
  userAgentHeader:
      'Haven/0.1.0 (+$kHavenWebsiteUrl; contact: $kHavenContactEmail) '
      'flutter_map',
);

/// The active tile provider for the running build.
///
/// Mirrors the [`defaultRelays`] getter shape. Returns Stadia in all builds;
/// swap to [osmRawDevFallback] only via a Riverpod override in dev/tests,
/// never as the shipped default.
TileProviderConfig get defaultTileProvider => stadiaAlidadeSmooth;

// ---------------------------------------------------------------------------
// Cache key sanitisation
// ---------------------------------------------------------------------------

/// Strips the `api_key` query parameter from a tile [url] before it is used as
/// a cache key.
///
/// Keeps the Stadia secret out of the on-disk tile cache (no secret-at-rest in
/// cache filenames/index) and lets the cache survive an API-key rotation.
/// Passed to `BuiltInMapCachingProvider.getOrCreateInstance`.
String tileCacheKey(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.queryParameters.containsKey('api_key')) return url;
  final params = Map<String, String>.of(uri.queryParameters)..remove('api_key');
  if (params.isEmpty) {
    // `replace(queryParameters: null)` KEEPS the original query (and thus the
    // secret), so drop the query explicitly and trim the dangling separator.
    final stripped = uri.replace(query: '').toString();
    return stripped.endsWith('?')
        ? stripped.substring(0, stripped.length - 1)
        : stripped;
  }
  return uri.replace(queryParameters: params).toString();
}
