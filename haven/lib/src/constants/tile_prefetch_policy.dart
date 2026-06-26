/// Policy constants for Haven's anticipatory tile prefetch (M-D).
///
/// These constants control the scope, budget, and network behaviour of the
/// prefetch burst that fires when a circle is selected and member locations
/// arrive. They are consumed by `TilePrefetchServiceImpl` and verified by the
/// test suite.
///
/// **Frugality rationale (Stadia ToS §8 / design §4):**
/// The burst is restricted to `kPrefetchMaxTilesTotal` tiles from the
/// nearest-to-camera members only. At ~25 KB/tile this is <1 MB — well
/// inside the "standard client-side caching" envelope and below any
/// metered-gating threshold that would require `connectivity_plus`
/// (deferred to M-E if ever needed).
library;

/// Debounce window before the prefetch burst fires after member locations
/// arrive.
///
/// Rapid circle-switching or poll-driven location refreshes within this
/// window collapse into a single burst, preventing a spray of concurrent
/// requests.
const Duration kPrefetchDebounce = Duration(milliseconds: 400);

/// Tile ring radius around each member's landing-zoom tile.
///
/// A radius of 1 produces up to a 3×3 block (9 tiles) centred on the
/// member's tile. Combined with [kPrefetchMaxTilesTotal] this means ~3–4
/// members can be fully warmed before the cap is hit.
const int kPrefetchRing = 1;

/// How many zoom levels to shift up to obtain the single coarse parent tile
/// prefetched per member.
///
/// `landingZoom − 2` is the tile flutter_map up-samples during the loading
/// flash while detail tiles arrive. It is a genuinely-rendered tile (the only
/// additional zoom level fetched — never a pyramid), justified by ToS
/// "standard client-side caching" provisions.
const int kPrefetchCoarseParentDelta = 2;

/// Maximum tiles prefetched per member (3×3 ring = 9).
///
/// Kept as a named constant so tests can assert the ring-radius relationship.
/// The actual per-member limit is enforced by `tileRing`'s radius parameter;
/// this constant documents the intent.
const int kPrefetchMaxTilesPerMember = 9;

/// Hard cap on the total number of tiles across all members in one burst.
///
/// At ~25 KB/tile this is ~0.8 MB — well under Stadia's 100 MB device-total
/// ceiling and a single radio-tail wake-up. Members beyond the cap are left
/// cold deterministically (nearest-to-camera priority; see design §4 O7).
const int kPrefetchMaxTilesTotal = 32;

/// Maximum number of simultaneous HTTP GETs during a prefetch burst.
///
/// Four concurrent requests keeps throughput high while staying below the
/// number that would starve the map's foreground tile fetches (which share
/// the same pinned HTTP client pool).
const int kPrefetchConcurrency = 4;

/// Flat delay applied after an HTTP 429 response before halting the burst.
///
/// On 429 the burst is halted entirely after this delay. There is no
/// exponential backoff: `kPrefetchBackoffBase` is the only delay applied.
const Duration kPrefetchBackoffBase = Duration(seconds: 1);
