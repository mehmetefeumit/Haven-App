//! At-rest verification for the encrypted map-tile cache (`tiles.db`).
//!
//! Proves that tile BLOBs stored in `tiles.db` are SQLCipher-encrypted at rest:
//! after storing a tile with a distinctive plaintext marker (and the real PNG
//! magic), a raw byte scan of the database file **and** every sidecar it may
//! spill to (`-wal`, `-shm`, `-journal`) finds no tile plaintext.
//!
//! This is the Security-HIGH gate the design (`docs/TILE_CACHING_DESIGN.md`
//! §5/§8) mandates. It matters more here than for `circles.db` because the tile
//! cache deliberately enables **WAL** — so tile bytes land in the `-wal` sidecar
//! before checkpoint. The encryption of that sidecar is asserted in comments; this
//! test enforces it. The scan runs BOTH while the connection is live (so the
//! pre-checkpoint `-wal` is on disk) and after drop (post-checkpoint main file).

use std::io::Read;
use std::path::{Path, PathBuf};

use haven_core::tiles::TileCacheStorage;

fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    needle.len() <= haystack.len() && haystack.windows(needle.len()).any(|w| w == needle)
}

/// Scans `tiles.db` and every sidecar for any of `needles`; asserts absence.
/// Returns the number of files actually scanned so the caller can assert it
/// scanned something.
fn assert_no_plaintext(base: &Path, needles: &[&[u8]], phase: &str) -> usize {
    let mut scanned = 0;
    for ext in ["", "-wal", "-shm", "-journal"] {
        let p = if ext.is_empty() {
            base.to_path_buf()
        } else {
            PathBuf::from(format!("{}{ext}", base.display()))
        };
        if !p.exists() {
            continue;
        }
        let mut bytes = Vec::new();
        let Ok(mut f) = std::fs::File::open(&p) else {
            continue;
        };
        f.read_to_end(&mut bytes).expect("read sidecar");
        if bytes.is_empty() {
            continue;
        }
        scanned += 1;
        for needle in needles {
            assert!(
                !contains(&bytes, needle),
                "tile plaintext leaked at rest in '{ext}' (phase: {phase})"
            );
        }
    }
    scanned
}

#[test]
fn tile_blobs_are_encrypted_at_rest() {
    // A long, unique marker that will not appear in encrypted (high-entropy)
    // output by chance, plus the literal PNG magic a real tile carries. Declared
    // first to satisfy `clippy::items_after_statements`.
    const PNG_MAGIC: &[u8] = b"\x89PNG\r\n\x1a\n";
    const MARKER: &[u8] = b"HAVEN_AT_REST_TILE_PLAINTEXT_MARKER_DO_NOT_LEAK";

    let dir = tempfile::tempdir().expect("tempdir");
    let base = dir.path().join("tiles.db");
    // 64 hex chars (a raw 256-bit key), as the FFI layer supplies in production.
    let hex_key = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

    // The payload is padded so it spans multiple cipher pages.
    let mut tile = Vec::new();
    tile.extend_from_slice(PNG_MAGIC);
    tile.extend_from_slice(MARKER);
    tile.resize(8192, 0xAB);

    let now_ms = 1_700_000_000_000;
    let stale_at_ms = now_ms + 7 * 24 * 60 * 60 * 1000;

    let needles: [&[u8]; 3] = [MARKER, &tile, PNG_MAGIC];

    {
        let storage = TileCacheStorage::open(&base, hex_key).expect("open encrypted tiles.db");
        storage
            .put(
                "alidade_smooth",
                14,
                8187,
                5451,
                false,
                &tile,
                stale_at_ms,
                Some(now_ms),
                Some("\"etag-marker\""),
                now_ms,
            )
            .expect("put tile");

        // Sanity: the plaintext IS retrievable through the cipher.
        let got = storage
            .get("alidade_smooth", 14, 8187, 5451, false, now_ms)
            .expect("get")
            .expect("present");
        assert_eq!(&got.bytes, &tile, "round-trip must return the plaintext");

        // Phase 1: scan while the connection is live — the pre-checkpoint `-wal`
        // sidecar holds the just-written page and MUST be encrypted.
        let scanned = assert_no_plaintext(&base, &needles, "live");
        assert!(scanned > 0, "no db files scanned while live");

        // Drop closes the connections and checkpoints the WAL into the main file.
    }

    // The main DB file must exist and be non-trivial.
    let main = std::fs::read(&base).expect("read db");
    assert!(main.len() > 1024, "db file unexpectedly small");

    // Phase 2: scan after drop — the post-checkpoint main file (and any remaining
    // sidecar) must also be free of tile plaintext.
    let scanned = assert_no_plaintext(&base, &needles, "after-drop");
    assert!(scanned > 0, "no db files scanned after drop");
}
