//! Picture downloads that a Blossom server redirects, proven through the public
//! `download_profile_picture` — scheme gate, SSRF pre-flight, the production
//! client, its redirect policy and its resolver.
//!
//! Primal answers every `GET /<sha256>` with a `302` to its media host, so a
//! download that refused redirects never showed a Primal-hosted photo on any
//! other device. These tests need the debug loopback exemption to reach the
//! mock servers at all, which a lib test must not install, hence a binary of
//! their own; with it installed, `127.0.0.1` and `localhost` are dialable and
//! every other non-public address is still refused.

// A mockito server must outlive every request a test sends it, so the "drop it
// earlier" suggestion is a false positive throughout.
#![allow(clippy::significant_drop_tightening)]

use haven_core::profile::{
    allow_private_blossom_for_test, download_profile_picture, ProfileError, BLOSSOM_MAX_REDIRECTS,
};
use image::{codecs::jpeg::JpegEncoder, RgbImage};
use mockito::Matcher;
use sha2::{Digest, Sha256};

mod helpers;
use helpers::{assert_no_needles, assert_some_line_from, capture_haven_log_here, haven_core_lines};

/// A distinct JPEG per `seed`, and its content address.
fn jpeg(seed: u8) -> (Vec<u8>, String) {
    let mut img = RgbImage::new(64, 64);
    for (x, y, px) in img.enumerate_pixels_mut() {
        let r = u8::try_from(x % 256).unwrap_or(0);
        let g = u8::try_from(y % 256).unwrap_or(0);
        *px = image::Rgb([r, g, seed]);
    }
    let mut out = Vec::new();
    JpegEncoder::new_with_quality(std::io::Cursor::new(&mut out), 90)
        .encode_image(&img)
        .expect("encode jpeg");
    let sha_hex = hex::encode(Sha256::digest(&out));
    (out, sha_hex)
}

/// A mock server, with the loopback exemption armed so it can be reached.
async fn server() -> mockito::ServerGuard {
    let _ = allow_private_blossom_for_test();
    mockito::Server::new_async().await
}

/// `server`'s address under the `localhost` name, so a hop to it is vetted by
/// the resolver rather than as a literal.
fn by_name(server: &mockito::ServerGuard) -> String {
    format!("http://localhost:{}", server.socket_address().port())
}

/// Answers `GET path` with a `302` to `location`.
async fn redirect(server: &mut mockito::ServerGuard, path: &str, location: &str) -> mockito::Mock {
    server
        .mock("GET", path)
        .with_status(302)
        .with_header("location", location)
        .create_async()
        .await
}

#[tokio::test]
async fn a_blossom_redirect_to_another_host_is_followed_without_a_referer() {
    let (bytes, sha) = jpeg(1);
    let mut media = server().await;
    let served = media
        .mock("GET", format!("/media/ab/{sha}.jpg").as_str())
        .match_header("referer", Matcher::Missing)
        .with_status(200)
        .with_body(&bytes)
        .expect(1)
        .create_async()
        .await;
    let mut origin = server().await;
    let _r = redirect(
        &mut origin,
        &format!("/{sha}"),
        &format!("{}/media/ab/{sha}.jpg", by_name(&media)),
    )
    .await;

    let url = format!("{}/{sha}", origin.url());
    let picture = download_profile_picture(&url)
        .await
        .expect("a same-blob redirect is followed");
    assert_eq!(picture.sha256_hex, sha);
    assert_eq!(picture.url, url, "the kind-0's URL is what gets cached");
    served.assert_async().await;
}

#[tokio::test]
async fn a_redirect_target_serving_other_bytes_fails_the_requested_address() {
    // A hop need not carry the hash (Primal may redirect to a key-addressed
    // copy), so what binds the bytes is the REQUESTED URL's address.
    let (_, sha) = jpeg(2);
    let (other, _) = jpeg(3);
    let mut media = server().await;
    let served = media
        .mock("GET", "/cache/key-addressed.jpg")
        .with_status(200)
        .with_body(other)
        .expect(1)
        .create_async()
        .await;
    let mut origin = server().await;
    let _r = redirect(
        &mut origin,
        &format!("/{sha}"),
        &format!("{}/cache/key-addressed.jpg", by_name(&media)),
    )
    .await;

    let err = download_profile_picture(&format!("{}/{sha}", origin.url()))
        .await
        .expect_err("bytes that do not hash to the requested address");
    assert!(matches!(err, ProfileError::HashMismatch), "got {err:?}");
    served.assert_async().await;
}

#[tokio::test]
async fn three_redirects_are_followed_and_a_fourth_is_not() {
    assert_eq!(BLOSSOM_MAX_REDIRECTS, 3);
    let (bytes, sha) = jpeg(4);
    let mut chain = server().await;
    let base = chain.url();
    let mut mocks = Vec::new();
    // /a0 → /a1 → /a2 → /a3 (served): three redirects.
    for hop in 0..3 {
        mocks.push(
            redirect(
                &mut chain,
                &format!("/a{hop}/{sha}"),
                &format!("{base}/a{}/{sha}", hop + 1),
            )
            .await,
        );
    }
    let served = chain
        .mock("GET", format!("/a3/{sha}").as_str())
        .with_status(200)
        .with_body(&bytes)
        .expect(1)
        .create_async()
        .await;
    let picture = download_profile_picture(&format!("{base}/a0/{sha}"))
        .await
        .expect("three redirects are followed");
    assert_eq!(picture.sha256_hex, sha);
    served.assert_async().await;

    // /b0 → … → /b4: the fourth redirect is refused before /b4 is asked.
    for hop in 0..4 {
        mocks.push(
            redirect(
                &mut chain,
                &format!("/b{hop}/{sha}"),
                &format!("{base}/b{}/{sha}", hop + 1),
            )
            .await,
        );
    }
    let never = chain
        .mock("GET", format!("/b4/{sha}").as_str())
        .with_status(200)
        .with_body(&bytes)
        .expect(0)
        .create_async()
        .await;
    let err = download_profile_picture(&format!("{base}/b0/{sha}"))
        .await
        .expect_err("a fourth redirect is refused");
    assert!(matches!(err, ProfileError::Http(_)), "got {err:?}");
    never.assert_async().await;
    for hop in mocks {
        hop.assert_async().await;
    }
}

#[tokio::test]
async fn a_redirect_to_a_non_public_literal_is_refused_even_with_the_test_exemption() {
    // The connector dials a literal without asking the resolver; https, so the
    // scheme gate passes and only the address can refuse it. A dial would end
    // in a transport error or a timeout, never in InsecureUrl.
    let (_, sha) = jpeg(5);
    let mut origin = server().await;
    let _r = redirect(
        &mut origin,
        &format!("/{sha}"),
        &format!("https://192.168.77.1/{sha}"),
    )
    .await;
    let err = download_profile_picture(&format!("{}/{sha}", origin.url()))
        .await
        .expect_err("a private literal is never dialled");
    assert!(matches!(err, ProfileError::InsecureUrl), "got {err:?}");
}

#[tokio::test]
async fn a_redirect_down_to_plain_http_is_refused() {
    let (_, sha) = jpeg(6);
    let mut origin = server().await;
    let _r = redirect(
        &mut origin,
        &format!("/{sha}"),
        &format!("http://cdn.example.invalid/{sha}"),
    )
    .await;
    let err = download_profile_picture(&format!("{}/{sha}", origin.url()))
        .await
        .expect_err("a plaintext hop is refused");
    assert!(matches!(err, ProfileError::InsecureUrl), "got {err:?}");
}

#[tokio::test]
async fn a_failed_download_logs_its_kind_and_status_class_only() {
    let (_, sha) = jpeg(7);
    let mut origin = server().await;
    let _m = origin
        .mock("GET", format!("/{sha}").as_str())
        .with_status(404)
        .with_body(format!("no blob {sha}"))
        .create_async()
        .await;
    let url = format!("{}/{sha}", origin.url());
    let port = origin.socket_address().port().to_string();

    let lines = capture_haven_log_here(async {
        let err = download_profile_picture(&url).await.expect_err("404");
        assert!(matches!(err, ProfileError::Http(_)), "got {err:?}");
    })
    .await;

    let ours = haven_core_lines(&lines);
    assert_some_line_from(&ours, "haven_core::profile::blossom");
    let messages: Vec<&str> = ours.iter().map(|l| l.message.as_str()).collect();
    assert_eq!(
        messages,
        [
            "[profile] picture download: status 4xx",
            "[profile] picture download failed (http)",
        ],
    );
    assert_no_needles(&ours, &[&sha, &url, &origin.host_with_port(), &port]);
}

#[tokio::test]
async fn a_refused_redirect_logs_no_target() {
    let (_, sha) = jpeg(8);
    let (_, other) = jpeg(9);
    let location = format!("https://192.168.77.1/redirect-target/{other}");
    let mut origin = server().await;
    let _r = redirect(&mut origin, &format!("/{sha}"), &location).await;
    let url = format!("{}/{sha}", origin.url());
    let port = origin.socket_address().port().to_string();

    let lines = capture_haven_log_here(async {
        let err = download_profile_picture(&url).await.expect_err("refused");
        assert!(matches!(err, ProfileError::InsecureUrl), "got {err:?}");
    })
    .await;

    let ours = haven_core_lines(&lines);
    let messages: Vec<&str> = ours.iter().map(|l| l.message.as_str()).collect();
    assert_eq!(
        messages,
        ["[profile] picture download failed (insecure-url)"]
    );
    assert_no_needles(
        &ours,
        &[
            &location,
            "192.168.77.1",
            "redirect-target",
            &other,
            &sha,
            &url,
            &port,
        ],
    );
}
