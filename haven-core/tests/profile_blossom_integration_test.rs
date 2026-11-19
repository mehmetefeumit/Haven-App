//! Container-gated Blossom interop tests (real `blossom-server`).
//!
//! These are `#[ignore]`d and additionally guarded on the `HAVEN_E2E_BLOSSOM`
//! env flag + a `HAVEN_E2E_BLOSSOM_URL` (e.g. `http://127.0.0.1:3000`), so they
//! never run in the normal `cargo test` pass — they require a live Blossom
//! server (the plan's e2e lane spins up `ghcr.io/hzrd149/blossom-server`). They
//! are the empirical proof of the standard-base64 auth-encoding interop and of
//! the upload→download byte round trip. Run with:
//!
//! ```bash
//! HAVEN_E2E_BLOSSOM=1 HAVEN_E2E_BLOSSOM_URL=http://127.0.0.1:3000 \
//!   cargo test --test profile_blossom_integration_test -- --ignored
//! ```

use std::io::Cursor;

use haven_core::avatar::{process_own_avatar, StagedPicture};
use haven_core::profile::{
    blossom_servers, download_profile_picture, upload_profile_picture, BlossomAuthEncoding,
    UploadServer,
};
use image::{codecs::jpeg::JpegEncoder, RgbImage};
use nostr::Keys;

/// Resolves the live Blossom base URL from the env gate, or `None` (skip).
fn blossom_url() -> Option<url::Url> {
    if std::env::var("HAVEN_E2E_BLOSSOM").is_err() {
        return None;
    }
    let raw = std::env::var("HAVEN_E2E_BLOSSOM_URL").ok()?;
    url::Url::parse(&raw).ok()
}

/// The live server as the one upload server, sent the token as Primal
/// decodes it.
fn only(server: &url::Url) -> [UploadServer; 1] {
    [UploadServer {
        base: server.clone(),
        site: server.host_str().expect("a host").to_string(),
        auth: BlossomAuthEncoding::PaddedStandard,
    }]
}

fn sample_jpeg(seed: u8) -> Vec<u8> {
    let mut img = RgbImage::new(96, 96);
    for (x, y, px) in img.enumerate_pixels_mut() {
        let r = u8::try_from(x % 256).unwrap_or(0);
        let g = u8::try_from(y % 256).unwrap_or(0);
        *px = image::Rgb([r, g, seed]);
    }
    let mut out = Vec::new();
    JpegEncoder::new_with_quality(Cursor::new(&mut out), 88)
        .encode_image(&img)
        .expect("encode jpeg");
    out
}

/// Seals raw bytes for upload the only way the type permits: through the
/// sanitizer. Called per upload because a `StagedPicture` is consumed by one.
fn staged(raw: &[u8]) -> StagedPicture {
    StagedPicture::from_processed(&process_own_avatar(raw).expect("sanitize"))
}

#[tokio::test]
#[ignore = "requires a live Blossom server (HAVEN_E2E_BLOSSOM)"]
async fn upload_then_download_byte_identical_after_revalidation() {
    let Some(server) = blossom_url() else {
        eprintln!("skipping: HAVEN_E2E_BLOSSOM(_URL) not set");
        return;
    };
    // Allow the download anti-SSRF filter to reach the loopback container.
    let _ = haven_core::profile::allow_private_blossom_for_test();

    let keys = Keys::generate();
    let raw = sample_jpeg(11);

    let uploaded = upload_profile_picture(&keys, &only(&server), staged(&raw))
        .await
        .expect("upload to live Blossom");
    let downloaded = download_profile_picture(&uploaded.url)
        .await
        .expect("download from live Blossom");

    // The content-address commitment must match end to end: the raw bytes the
    // server returned are byte-identical to what we uploaded (the sanitized
    // canonical), which is also the empirical proof the standard-base64 auth
    // header was accepted by a real server.
    assert_eq!(
        downloaded.sha256_hex, uploaded.sha256_hex,
        "round-tripped bytes are byte-identical (content hash matches)"
    );
    assert!(!downloaded.canonical.is_empty());
    assert!(!downloaded.thumbnail.is_empty());
}

#[tokio::test]
#[ignore = "requires a live Blossom server (HAVEN_E2E_BLOSSOM)"]
async fn duplicate_upload_succeeds() {
    let Some(server) = blossom_url() else {
        eprintln!("skipping: HAVEN_E2E_BLOSSOM(_URL) not set");
        return;
    };
    let _ = haven_core::profile::allow_private_blossom_for_test();

    let keys = Keys::generate();
    let raw = sample_jpeg(22);

    let first = upload_profile_picture(&keys, &only(&server), staged(&raw))
        .await
        .expect("first upload");
    // A second upload of the same bytes (server returns the existing blob) must
    // also succeed and resolve to the same content address.
    let second = upload_profile_picture(&keys, &only(&server), staged(&raw))
        .await
        .expect("duplicate upload");
    assert_eq!(first.sha256_hex, second.sha256_hex);
}

#[tokio::test]
#[ignore = "requires a live Blossom server (HAVEN_E2E_BLOSSOM)"]
async fn download_of_absent_hash_errors_not_panics() {
    let Some(server) = blossom_url() else {
        eprintln!("skipping: HAVEN_E2E_BLOSSOM(_URL) not set");
        return;
    };
    let _ = haven_core::profile::allow_private_blossom_for_test();

    // A URL pointing at a content address the server does not hold must surface
    // an error (not panic, not silently succeed).
    let absent = "0".repeat(64);
    let url = server.join(&absent).expect("join absent hash").to_string();
    let result = download_profile_picture(&url).await;
    assert!(result.is_err(), "absent blob must error");
}

/// The live probe of the built-in upload servers that
/// `docs/BLOSSOM_SERVER_VETTING.md` records: per server, a throwaway key
/// uploads a fresh JPEG through the production checks and downloads it back
/// through the production redirect path. It writes that JPEG to each
/// third-party server for good and shows them the caller's IP, so it runs only
/// when a maintainer asks:
///
/// ```bash
/// HAVEN_PROBE_BLOSSOM_SERVERS=1 \
///   cargo test --test profile_blossom_integration_test \
///   blossom_servers_accept_an_anonymous_avatar_and_serve_it_back -- --ignored --nocapture
/// ```
#[tokio::test]
#[ignore = "uploads to the production Blossom servers (HAVEN_PROBE_BLOSSOM_SERVERS=1)"]
async fn blossom_servers_accept_an_anonymous_avatar_and_serve_it_back() {
    if std::env::var("HAVEN_PROBE_BLOSSOM_SERVERS").as_deref() != Ok("1") {
        eprintln!("skipping: HAVEN_PROBE_BLOSSOM_SERVERS=1 not set");
        return;
    }
    let mut failed = Vec::new();
    println!("| server | upload (B1-B3) | download (B4) |");
    println!("|---|---|---|");
    for server in blossom_servers() {
        let keys = Keys::generate();
        // A picture no server has seen: its colour comes from the throwaway key.
        let raw = sample_jpeg(keys.public_key().to_bytes()[0]);
        let base = server.base.to_string();
        let (upload, download) = match upload_profile_picture(
            &keys,
            std::slice::from_ref(&server),
            staged(&raw),
        )
        .await
        {
            Ok(picture) => match download_profile_picture(&picture.url).await {
                Ok(round) if round.sha256_hex == picture.sha256_hex => {
                    ("pass".to_string(), "pass".to_string())
                }
                Ok(_) => ("pass".to_string(), "fail (hash-mismatch)".to_string()),
                Err(e) => ("pass".to_string(), format!("fail ({})", e.code())),
            },
            Err(e) => (format!("fail ({})", e.code()), "not run".to_string()),
        };
        println!("| `{base}` | {upload} | {download} |");
        if upload != "pass" || download != "pass" {
            failed.push(base);
        }
    }
    assert!(failed.is_empty(), "servers that did not pass: {failed:?}");
}
