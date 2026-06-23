//! At-rest verification (plan Layer-6, host-side portable form).
//!
//! Proves that avatar BLOBs stored in `circles.db` are SQLCipher-encrypted at
//! rest: after storing an avatar with a distinctive plaintext marker, a raw
//! byte scan of the database file **and** every sidecar it may spill to
//! (`-wal`, `-shm`, `-journal`) finds no avatar plaintext. This runs entirely
//! on the host (no device/`adb` needed) and also exercises the encrypted-path
//! hardening PRAGMAs (`cipher_memory_security`, `temp_store`).

use std::io::Read;
use std::path::PathBuf;

use haven_core::circle::{AvatarBlobs, CircleStorage};
use sha2::{Digest, Sha256};
use zeroize::Zeroizing;

fn sha256(bytes: &[u8]) -> [u8; 32] {
    Sha256::digest(bytes).into()
}

fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    needle.len() <= haystack.len() && haystack.windows(needle.len()).any(|w| w == needle)
}

#[test]
fn avatar_blobs_are_encrypted_at_rest() {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("circles.db");
    // 64 hex chars (a raw 256-bit key), as the FFI layer supplies in production.
    let hex_key = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

    // Long, unique markers that will not appear in encrypted (high-entropy)
    // output by chance — unlike a bare 3-byte image magic. The canonical blob
    // is prefixed with the JPEG magic for realism and padded to a realistic
    // size so it is large enough to span multiple cipher pages.
    const CANON_MARKER: &[u8] = b"HAVEN_AT_REST_AVATAR_PLAINTEXT_MARKER_DO_NOT_LEAK";
    const THUMB_MARKER: &[u8] = b"HAVEN_AT_REST_THUMB_PLAINTEXT_MARKER_DO_NOT_LEAK";
    let mut canonical = vec![0xFF, 0xD8, 0xFF];
    canonical.extend_from_slice(CANON_MARKER);
    canonical.resize(8192, 0xAB);
    let thumbnail = THUMB_MARKER.to_vec();

    let blobs = AvatarBlobs {
        content_hash: sha256(&canonical),
        thumb_hash: sha256(&thumbnail),
        canonical: Zeroizing::new(canonical.clone()),
        thumbnail: Zeroizing::new(thumbnail.clone()),
        mime: "image/jpeg".to_string(),
        width: 512,
        thumb_edge: 96,
    };

    {
        let storage = CircleStorage::new(&path, Some(hex_key)).expect("open encrypted db");
        storage
            .set_own_avatar("ownpub", &blobs, 1000)
            .expect("store own avatar");
        // Sanity: the plaintext IS retrievable through the cipher.
        let got = storage
            .get_avatar_canonical(&[], "ownpub")
            .expect("get")
            .expect("present");
        assert_eq!(
            &*got,
            &canonical[..],
            "round-trip must return the plaintext"
        );
        // Drop closes the connection and flushes any journal/WAL to disk.
    }

    // The main DB file must exist and be non-trivial.
    let main = std::fs::read(&path).expect("read db");
    assert!(main.len() > 1024, "db file unexpectedly small");

    // Scan the DB and every sidecar for any avatar plaintext.
    let mut scanned_any = false;
    for ext in ["", "-wal", "-shm", "-journal"] {
        let p = if ext.is_empty() {
            path.clone()
        } else {
            PathBuf::from(format!("{}{ext}", path.display()))
        };
        if !p.exists() {
            continue;
        }
        scanned_any = true;
        let mut bytes = Vec::new();
        std::fs::File::open(&p)
            .expect("open sidecar")
            .read_to_end(&mut bytes)
            .expect("read sidecar");
        assert!(
            !contains(&bytes, CANON_MARKER),
            "canonical avatar plaintext leaked at rest in '{ext}'"
        );
        assert!(
            !contains(&bytes, THUMB_MARKER),
            "thumbnail avatar plaintext leaked at rest in '{ext}'"
        );
        assert!(
            !contains(&bytes, &canonical),
            "verbatim canonical blob leaked at rest in '{ext}'"
        );
    }
    assert!(scanned_any, "no db files were scanned");
}
