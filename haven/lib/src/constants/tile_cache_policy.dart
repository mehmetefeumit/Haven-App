/// Policy constants for Haven's encrypted tile cache.
///
/// These constants control the eviction and retention budget for the
/// SQLCipher-backed `EncryptedTileCachingProvider`. They are consumed by the
/// startup eviction call in `main.dart` and documented here as a single source
/// of truth.
///
/// **Freshness** (how long until a tile must be revalidated with the server)
/// is deliberately absent: it is HTTP-driven. flutter_map computes `staleAt`
/// from Stadia's Cache-Control / Expires headers and passes it to
/// `EncryptedTileCachingProvider.putTile`, which persists it verbatim.
/// The cache makes no freshness policy of its own.
library;

/// Maximum total size of the encrypted tile cache in bytes (48 MB).
///
/// Tiles totalling more than this are evicted oldest-accessed-first by
/// `tileCacheEvict` on each cold start (M-D adds a warm-resume path).
const int kTileCacheMaxBytes = 48 * 1024 * 1024;

/// Absolute retention window (7 days).
///
/// Tiles whose `fetched_at` column is older than this age are deleted
/// unconditionally during eviction, regardless of the budget.
const Duration kTileMaxRetention = Duration(days: 7);

/// Idle-access age after which a tile becomes eligible for eviction (2 days).
///
/// Tiles that have not been accessed (`accessed_at` column) within this
/// window are candidates for LRU removal when the cache exceeds
/// [kTileCacheMaxBytes].
const Duration kTileIdlePurgeAge = Duration(days: 2);
