//! The mesh packet: one signed kind-445 location event inside a fixed-size
//! envelope with no cleartext field (plan §4).
//!
//! ```text
//! packet     1024 B   nonce ‖ ct ‖ tag
//!   nonce      12 B   fresh from the CSPRNG per packet
//!   ct        996 B   ChaCha20-Poly1305(K_mesh, nonce, AAD = "haven/mesh/v1")
//!   tag        16 B
//!
//! plaintext   996 B   integers big-endian
//!   format      1 B   [`Format`]
//!   pubkey     32 B   the event's ephemeral key
//!   sig        64 B
//!   created_at  8 B
//!   expiration  8 B
//!   content_len 2 B
//!   content   ≤881 B  the kind-445 content, base64-decoded
//!   padding           zero
//! ```
//!
//! To anyone without the circle's [`MeshKey`] a packet is 1024 random-looking
//! bytes, the same as a [`cover_packet`]. Rebuilding the event and
//! `Event::verify()` are the opener's next step and live with the MLS session,
//! not here: a packet that opens is not yet an authentic event.
//!
//! No type here is `Debug` except [`Format`]: a packet, its id and an event's
//! key are identifiers, and a mesh key is a secret (Security Rules 6 and 15).

use std::sync::Arc;

use chacha20poly1305::{AeadInPlace, ChaCha20Poly1305, KeyInit};
use hkdf::Hkdf;
use rand::{CryptoRng, RngCore};
use sha2::{Digest, Sha256};
use zeroize::ZeroizeOnDrop;

/// The one size every mesh packet has.
pub const PACKET_LEN: usize = 1024;

/// The longest kind-445 content a packet holds; a longer event is not sent
/// over mesh.
pub const MAX_CONTENT_LEN: usize = PLAINTEXT_LEN - HEADER_LEN;

const NONCE_LEN: usize = 12;
const TAG_LEN: usize = 16;
const PLAINTEXT_LEN: usize = PACKET_LEN - NONCE_LEN - TAG_LEN;
const HEADER_LEN: usize = 1 + 32 + 64 + 8 + 8 + 2;

// The plan's two numbers; every peer must agree on them.
const _: () = assert!(PLAINTEXT_LEN == 996 && MAX_CONTENT_LEN == 881);

/// HKDF salt and AEAD associated data: a mesh key and a mesh ciphertext are
/// good for this envelope version and nothing else.
const DOMAIN: &[u8] = b"haven/mesh/v1";

/// What the envelope says about the event's tags and whether a fellow member
/// may pass it on to the circle's relays (plan §5.5).
///
/// Both values mean the kind-445 tag layout `[h, expiration]`. The byte sits
/// under the mesh key, so it binds honest phones only.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum Format {
    /// Never bridged. Every mesh-only seal carries this: bridging one would
    /// hand the relays an event its sender's phone refused to send them.
    NeverBridged = 0x01,
    /// The event passed its sender's send-time check and is not a mesh-only
    /// seal.
    Bridgeable = 0x02,
}

impl Format {
    const fn from_byte(byte: u8) -> Option<Self> {
        match byte {
            0x01 => Some(Self::NeverBridged),
            0x02 => Some(Self::Bridgeable),
            _ => None,
        }
    }
}

/// The fields of a kind-445 event the envelope carries. With the `h` tag of
/// the circle whose key opened the packet they rebuild the signed event.
#[derive(Clone, PartialEq, Eq)]
pub struct EventParts {
    /// Tag layout and bridging mark.
    pub format: Format,
    /// The event's ephemeral public key.
    pub pubkey: [u8; 32],
    /// The event's signature.
    pub sig: [u8; 64],
    /// The event's `created_at`.
    pub created_at: u64,
    /// The value of the event's NIP-40 `expiration` tag.
    pub expiration: u64,
    /// The event's `content`, base64-decoded; at most [`MAX_CONTENT_LEN`].
    pub content: Vec<u8>,
}

/// A circle's packet key for one MLS epoch (plan §4.2).
#[derive(ZeroizeOnDrop)]
pub struct MeshKey {
    bytes: [u8; 32],
}

impl MeshKey {
    /// `HKDF-SHA256(salt = "haven/mesh/v1", IKM = exporter_secret, info =
    /// "packet-aead")`, `exporter_secret` being the epoch's
    /// `marmot/group-event` exporter secret.
    ///
    /// # Panics
    ///
    /// Never: 32 bytes is within HKDF-SHA256's output limit.
    #[must_use]
    pub fn derive(exporter_secret: &[u8; 32]) -> Self {
        let mut key = Self { bytes: [0; 32] };
        Hkdf::<Sha256>::new(Some(DOMAIN), exporter_secret)
            .expand(b"packet-aead", &mut key.bytes)
            .expect("32 bytes is a valid HKDF-SHA256 output length");
        key
    }

    fn cipher(&self) -> ChaCha20Poly1305 {
        ChaCha20Poly1305::new((&self.bytes).into())
    }
}

/// `SHA-256(packet)[..16]`: how phones name a packet to each other. Computed
/// locally, never carried in the packet.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct PacketId(pub [u8; 16]);

/// One mesh packet: exactly [`PACKET_LEN`] bytes, immutable.
///
/// Cloning shares the one allocation, so a store, an unread queue and a send
/// queue hold the same packet without copying it.
#[derive(Clone, PartialEq, Eq)]
pub struct Packet(Arc<[u8; PACKET_LEN]>);

impl Packet {
    /// A packet received from a peer. Any 1024 bytes are a packet.
    #[must_use]
    pub fn from_bytes(bytes: [u8; PACKET_LEN]) -> Self {
        Self(Arc::new(bytes))
    }

    /// The bytes that cross a link.
    #[must_use]
    pub fn as_bytes(&self) -> &[u8; PACKET_LEN] {
        &self.0
    }

    /// The packet's id.
    #[must_use]
    pub fn id(&self) -> PacketId {
        let mut id = [0; 16];
        id.copy_from_slice(&Sha256::digest(self.as_bytes())[..16]);
        PacketId(id)
    }
}

/// Wraps an event under `key`, drawing the 12-byte nonce from `rng`.
///
/// `None` when the content is longer than [`MAX_CONTENT_LEN`]. Wrapping the
/// same event twice gives two unrelated packets; a re-broadcast must reuse the
/// first.
#[must_use]
pub fn wrap<R: RngCore + CryptoRng>(
    key: &MeshKey,
    parts: &EventParts,
    rng: &mut R,
) -> Option<Packet> {
    let mut bytes = [0; PACKET_LEN];
    let (nonce, rest) = bytes.split_first_chunk_mut::<NONCE_LEN>()?;
    let (plaintext, rest) = rest.split_first_chunk_mut::<PLAINTEXT_LEN>()?;
    let (tag, _) = rest.split_first_chunk_mut::<TAG_LEN>()?;

    let (format, rest) = plaintext.split_first_mut()?;
    let (pubkey, rest) = rest.split_first_chunk_mut()?;
    let (sig, rest) = rest.split_first_chunk_mut()?;
    let (created_at, rest) = rest.split_first_chunk_mut()?;
    let (expiration, rest) = rest.split_first_chunk_mut()?;
    let (content_len, rest) = rest.split_first_chunk_mut()?;
    // `rest` is the `MAX_CONTENT_LEN` bytes left: longer content has no split.
    let (content, _zero_padding) = rest.split_at_mut_checked(parts.content.len())?;

    *format = parts.format as u8;
    *pubkey = parts.pubkey;
    *sig = parts.sig;
    *created_at = parts.created_at.to_be_bytes();
    *expiration = parts.expiration.to_be_bytes();
    *content_len = u16::try_from(parts.content.len()).ok()?.to_be_bytes();
    content.copy_from_slice(&parts.content);

    rng.fill_bytes(nonce);
    *tag = key
        .cipher()
        .encrypt_in_place_detached((&*nonce).into(), DOMAIN, plaintext)
        .ok()?
        .into();
    Some(Packet::from_bytes(bytes))
}

/// Opens a packet under `key` and parses it strictly.
///
/// `None` for a packet that is not for this key — a cover packet, another
/// circle's, another epoch's, a damaged one — and for one whose plaintext has
/// an unknown format byte, an impossible content length or a non-zero padding
/// byte.
#[must_use]
pub fn open(key: &MeshKey, packet: &Packet) -> Option<EventParts> {
    let (nonce, rest) = packet.as_bytes().split_first_chunk::<NONCE_LEN>()?;
    let (ciphertext, rest) = rest.split_first_chunk::<PLAINTEXT_LEN>()?;
    let (tag, _) = rest.split_first_chunk::<TAG_LEN>()?;
    let mut plaintext = *ciphertext;
    key.cipher()
        .decrypt_in_place_detached(nonce.into(), DOMAIN, &mut plaintext, tag.into())
        .ok()?;

    let (format, rest) = plaintext.split_first()?;
    let (pubkey, rest) = rest.split_first_chunk()?;
    let (sig, rest) = rest.split_first_chunk()?;
    let (created_at, rest) = rest.split_first_chunk()?;
    let (expiration, rest) = rest.split_first_chunk()?;
    let (content_len, rest) = rest.split_first_chunk()?;
    // `rest` is the `MAX_CONTENT_LEN` bytes left: a larger length has no split.
    let (content, padding) = rest.split_at_checked(u16::from_be_bytes(*content_len).into())?;
    if padding.iter().any(|&byte| byte != 0) {
        return None;
    }
    Some(EventParts {
        format: Format::from_byte(*format)?,
        pubkey: *pubkey,
        sig: *sig,
        created_at: u64::from_be_bytes(*created_at),
        expiration: u64::from_be_bytes(*expiration),
        content: content.to_vec(),
    })
}

/// A packet of [`PACKET_LEN`] CSPRNG bytes, which no key opens: what an
/// emission slot carries when no circle has an update for it.
#[must_use]
pub fn cover_packet<R: RngCore + CryptoRng>(rng: &mut R) -> Packet {
    let mut bytes = [0; PACKET_LEN];
    rng.fill_bytes(&mut bytes);
    Packet::from_bytes(bytes)
}

#[cfg(test)]
mod tests {
    use chacha20poly1305::aead::{Aead, Payload};
    use proptest::prelude::*;
    use rand::rngs::StdRng;
    use rand::{RngCore, SeedableRng};

    use super::*;
    use crate::mesh::test_rng::Scripted;

    const EXPORTER_SECRET: [u8; 32] = [0x5a; 32];

    fn low_byte(n: usize) -> u8 {
        n.to_le_bytes()[0]
    }

    fn key() -> MeshKey {
        MeshKey::derive(&EXPORTER_SECRET)
    }

    fn parts(content_len: usize) -> EventParts {
        EventParts {
            format: Format::Bridgeable,
            pubkey: [0x11; 32],
            sig: [0x22; 64],
            created_at: 1_800_000_000,
            expiration: 1_800_000_228,
            content: (0..content_len).map(|i| low_byte(i % 251)).collect(),
        }
    }

    /// A packet whose plaintext is whatever the test says, sealed under the
    /// real key with the real nonce size and AAD: what a member who ignores
    /// the layout rules could put on air.
    fn forge(key: &MeshKey, plaintext: &[u8; PLAINTEXT_LEN], aad: &[u8]) -> Packet {
        let nonce = [0x77; NONCE_LEN];
        let sealed = key
            .cipher()
            .encrypt(
                (&nonce).into(),
                Payload {
                    msg: plaintext,
                    aad,
                },
            )
            .expect("the AEAD accepts 996 bytes");
        let mut bytes = [0; PACKET_LEN];
        bytes[..NONCE_LEN].copy_from_slice(&nonce);
        bytes[NONCE_LEN..].copy_from_slice(&sealed);
        Packet::from_bytes(bytes)
    }

    /// The plaintext `wrap` would seal for `parts(600)`, built by hand.
    fn plaintext_of_600() -> [u8; PLAINTEXT_LEN] {
        let parts = parts(600);
        let mut plaintext = [0; PLAINTEXT_LEN];
        plaintext[0] = 0x02;
        plaintext[1..33].copy_from_slice(&parts.pubkey);
        plaintext[33..97].copy_from_slice(&parts.sig);
        plaintext[97..105].copy_from_slice(&parts.created_at.to_be_bytes());
        plaintext[105..113].copy_from_slice(&parts.expiration.to_be_bytes());
        plaintext[113..115].copy_from_slice(&600u16.to_be_bytes());
        plaintext[115..715].copy_from_slice(&parts.content);
        plaintext
    }

    /// T-PRIV-2. The expected packet comes from an independent implementation:
    /// Python `cryptography` 50.0.1 — `HKDF(SHA256, salt = b"haven/mesh/v1",
    /// info = b"packet-aead")` over the exporter secret `40..5f`, then
    /// `ChaCha20Poly1305(key).encrypt(nonce, plaintext, b"haven/mesh/v1")`
    /// with the plaintext laid out by hand from §4.1 — for format `0x02`,
    /// pubkey `10 + i`, sig `80 + 3i`, `created_at` `0x0102030405060708`,
    /// expiration `0x1112131415161718` and 600 content bytes `7i + 3`.
    #[test]
    fn a_wrapped_packet_matches_the_independent_vector() {
        const EXPECTED: &str = "\
            a0a1a2a3a4a5a6a7a8a9aaabd5a844f63f1c6d4b0a4ce71e01a82db99ce3ea56\
            f0f7dec342571d2214661975872c030ee80f388c1b11c6b9931c5426759e34a8\
            39ce1131876f50b498a8ad2b431bf7e72d5123b91235f5cee88d2755483c1dde\
            2b6f35a7cdb6fa98d4740db658d10415016eeab9ebc9cc0ddab6f31a63806d6d\
            82e52a941edcf456600d0ccde9cb013fb180348a4da3865e226a6a9d94dd4bbf\
            a2b1f020cb182f2398ebdeca465bc8cfc26061d11032d2d7ce43bbda4ed4f20f\
            a6bbe22d2322974110df4be80ae5913c324721d004720e3678c7bc8f497f2519\
            a26fe0f9e171aaf594ef8c618d7e54edb7561f3144c72abd55a73fbf8002bdbd\
            1da29b131e44f3376a859bcec129f578474024c6b98e7108bf081a415da3c193\
            224786782885ccd4d1c9ef86d25311d0d2bcf6f3701d9d0d92c9f9acd0cd4e44\
            a44c7b9a2f1e8a097294e2d1c57e7a6109c6ea75f9f3a0a69358c3faf6fc7332\
            9171306585e067724aff47c7e64d78e2d7529d79dc8d1f7aca87ac60f41de9f4\
            ee88bf2c83fe650ad63eb5b980f33ade67ced6c087bc1dca61932dd25b42e47a\
            b73e278fe60626e8699d339d7b54c73d891212be442a592873acddaab61f6967\
            373e4c485189778f8ab2803805af19ebc691d78ce065faa18395629d11e41275\
            a43b6e919d7e8f28d4814c3f6b7d15e4650f875b561ae30988802e90c385eb0c\
            8a26a664f1dfe826da17d63cbd889a1b554e1a89d74b5cec62df2f256f93ff35\
            7f70af3c3f84644860162b97a18c21082acf36ee2bbe918eee0cbf277fdfdf18\
            ae7b5bcbc2702250c2eb44ed09993f851c18b1390e3932ccb7143baf35819202\
            f859016fc9f79a8c4cafcc875990900a82c33cc5e62c16c373b38c2113a026f7\
            b5f367de528e1619aefd93566d9878b3276f025a124b9867fc261ac303e5ebfb\
            e400b995655ce2d4bb0e4015776b8ce4f4cee60057844844784659e4d9c43f95\
            039f2cf8797ea19c383b7fe9f32bfbafe1c7f9dcd5bd167f3fd99e4991570df1\
            126b5aafcfd27191f5d5ca48f9346b82e867cf1903c9d608bcd7a7a07642b1b6\
            f9299d039f8a1b8fdec7bd9087f34abdab4d67dc8e35076f456c24d6f5bd5a4d\
            8c8e8d9638640d5e62b0c23d99ce1366daec71f45f2b142a0dcde3861c32a990\
            c37898d9ee19c795cd86a96b37044f8be1a3d01cf34ede19614b1e2b0fe25d28\
            d6083e6a2b4996411b7060e9c1fe6a6d09d874dc58880cc6fc2d5e80079b807c\
            0aa81c33d27349e2a1a145eee51d7f6889b851cf3b024209a3380b1ea8b70120\
            d334c3d6b494682922aa8bcb6cb4b9e11339c0fc78fc08450ae0f6cad58a892c\
            980d27b164212c0d2f1d705e04cf0f042d000aaef7c644355085156c937309e2\
            2b94e6ea3df40820e9b7eaeb612b579e8b61b2f9266a09fdc7e4f78bd1aff041";
        let exporter_secret: [u8; 32] = std::array::from_fn(|i| low_byte(0x40 + i));
        let nonce: [u8; NONCE_LEN] = std::array::from_fn(|i| low_byte(0xa0 + i));
        let parts = EventParts {
            format: Format::Bridgeable,
            pubkey: std::array::from_fn(|i| low_byte(0x10 + i)),
            sig: std::array::from_fn(|i| low_byte(0x80 + 3 * i)),
            created_at: 0x0102_0304_0506_0708,
            expiration: 0x1112_1314_1516_1718,
            content: (0..600).map(|i| low_byte(7 * i + 3)).collect(),
        };
        // The script holds the nonce and nothing else: `wrap` draws exactly
        // those twelve bytes, and they are the packet's first twelve.
        let mut rng = Scripted::new(&nonce);

        let packet = wrap(&MeshKey::derive(&exporter_secret), &parts, &mut rng).expect("fits");

        assert!(rng.is_spent());
        assert_eq!(
            packet.as_bytes()[..],
            hex::decode(EXPECTED).expect("hex")[..]
        );
        assert_eq!(
            packet.id().0[..],
            hex::decode("33883692e9dd01605072abc40b38e021").expect("hex")[..]
        );
    }

    #[test]
    fn the_nonce_is_the_generators_output() {
        let mut expected = [0; NONCE_LEN];
        StdRng::seed_from_u64(7).fill_bytes(&mut expected);

        let packet = wrap(&key(), &parts(600), &mut StdRng::seed_from_u64(7)).expect("fits");

        assert_eq!(packet.as_bytes()[..NONCE_LEN], expected);
    }

    #[test]
    fn a_plaintext_laid_out_by_hand_opens_to_its_parts() {
        let forged = forge(&key(), &plaintext_of_600(), DOMAIN);
        assert!(open(&key(), &forged) == Some(parts(600)));
    }

    #[test]
    fn a_packet_sealed_with_another_aad_does_not_open() {
        let plaintext = plaintext_of_600();
        assert!(open(&key(), &forge(&key(), &plaintext, DOMAIN)).is_some());
        assert!(open(&key(), &forge(&key(), &plaintext, b"haven/mesh/v2")).is_none());
        assert!(open(&key(), &forge(&key(), &plaintext, b"")).is_none());
    }

    /// T-PRIV-6.
    #[test]
    fn every_single_bit_flip_makes_a_packet_unopenable() {
        let key = key();
        let packet = wrap(&key, &parts(600), &mut StdRng::seed_from_u64(1)).expect("fits");
        assert!(open(&key, &packet).is_some());
        for bit in 0..PACKET_LEN * 8 {
            let mut bytes = *packet.as_bytes();
            bytes[bit / 8] ^= 1 << (bit % 8);
            assert!(
                open(&key, &Packet::from_bytes(bytes)).is_none(),
                "a flipped bit left the packet openable"
            );
        }
    }

    #[test]
    fn content_of_881_bytes_fits_and_882_does_not() {
        let key = key();
        let mut rng = StdRng::seed_from_u64(2);
        let largest = wrap(&key, &parts(881), &mut rng).expect("881 bytes fit");
        assert!(open(&key, &largest) == Some(parts(881)));
        assert!(wrap(&key, &parts(882), &mut rng).is_none());
        assert!(open(&key, &wrap(&key, &parts(0), &mut rng).expect("fits")) == Some(parts(0)));
    }

    #[test]
    fn a_content_length_past_the_plaintext_is_rejected() {
        let mut plaintext = plaintext_of_600();
        plaintext[113..115].copy_from_slice(&882u16.to_be_bytes());
        assert!(open(&key(), &forge(&key(), &plaintext, DOMAIN)).is_none());
        plaintext[113..115].copy_from_slice(&u16::MAX.to_be_bytes());
        assert!(open(&key(), &forge(&key(), &plaintext, DOMAIN)).is_none());
    }

    #[test]
    fn any_non_zero_padding_byte_is_rejected() {
        for dirty in [715, 800, PLAINTEXT_LEN - 1] {
            let mut plaintext = plaintext_of_600();
            plaintext[dirty] = 0x01;
            assert!(open(&key(), &forge(&key(), &plaintext, DOMAIN)).is_none());
        }
    }

    #[test]
    fn an_unknown_format_byte_is_rejected() {
        for format in [0x00, 0x03, 0xff] {
            let mut plaintext = plaintext_of_600();
            plaintext[0] = format;
            assert!(open(&key(), &forge(&key(), &plaintext, DOMAIN)).is_none());
        }
    }

    #[test]
    fn both_formats_survive_the_round_trip() {
        for format in [Format::NeverBridged, Format::Bridgeable] {
            let parts = EventParts {
                format,
                ..parts(600)
            };
            let packet = wrap(&key(), &parts, &mut StdRng::seed_from_u64(3)).expect("fits");
            assert!(open(&key(), &packet) == Some(parts));
        }
    }

    #[test]
    fn another_circles_or_epochs_key_does_not_open() {
        let packet = wrap(&key(), &parts(600), &mut StdRng::seed_from_u64(4)).expect("fits");
        assert!(open(&MeshKey::derive(&[0x5b; 32]), &packet).is_none());
    }

    #[test]
    fn the_id_is_the_truncated_sha256_of_the_packet() {
        let packet = cover_packet(&mut StdRng::seed_from_u64(5));
        let digest = Sha256::digest(packet.as_bytes());
        assert_eq!(packet.id().0, digest[..16]);
        assert!(Packet::from_bytes(*packet.as_bytes()).id() == packet.id());
    }

    #[test]
    fn two_wraps_of_one_event_share_neither_nonce_nor_id() {
        let mut rng = StdRng::seed_from_u64(6);
        let first = wrap(&key(), &parts(600), &mut rng).expect("fits");
        let second = wrap(&key(), &parts(600), &mut rng).expect("fits");
        assert_ne!(
            first.as_bytes()[..NONCE_LEN],
            second.as_bytes()[..NONCE_LEN]
        );
        assert!(first.id() != second.id());
        assert!(open(&key(), &first) == open(&key(), &second));
    }

    #[test]
    fn a_cover_packet_is_the_generators_bytes_and_opens_under_no_key() {
        let mut expected = [0; PACKET_LEN];
        StdRng::seed_from_u64(8).fill_bytes(&mut expected);
        let cover = cover_packet(&mut StdRng::seed_from_u64(8));
        assert_eq!(*cover.as_bytes(), expected);

        let mut rng = StdRng::seed_from_u64(9);
        for seed in 0..=u8::MAX {
            let key = MeshKey::derive(&[seed; 32]);
            assert!(open(&key, &cover_packet(&mut rng)).is_none());
        }
    }

    #[test]
    fn the_key_is_zeroized_on_drop() {
        const fn assert_zeroize_on_drop<T: ZeroizeOnDrop>() {}
        assert_zeroize_on_drop::<MeshKey>();
    }

    proptest! {
        /// Whatever fits comes back unchanged, and only under its own key.
        #[test]
        fn prop_wrap_then_open_returns_the_parts(
            bridgeable in any::<bool>(),
            pubkey in any::<[u8; 32]>(),
            sig in any::<([u8; 32], [u8; 32])>(),
            created_at in any::<u64>(),
            expiration in any::<u64>(),
            content in proptest::collection::vec(any::<u8>(), 0..=MAX_CONTENT_LEN),
            exporter_secret in any::<[u8; 32]>(),
            seed in any::<u64>(),
        ) {
            let parts = EventParts {
                format: if bridgeable { Format::Bridgeable } else { Format::NeverBridged },
                pubkey,
                sig: std::array::from_fn(|i| if i < 32 { sig.0[i] } else { sig.1[i - 32] }),
                created_at,
                expiration,
                content,
            };
            let key = MeshKey::derive(&exporter_secret);
            let packet = wrap(&key, &parts, &mut StdRng::seed_from_u64(seed));
            prop_assert!(packet.is_some());
            let packet = packet.expect("checked");
            prop_assert!(open(&key, &packet) == Some(parts));

            let mut other = exporter_secret;
            other[0] ^= 1;
            prop_assert!(open(&MeshKey::derive(&other), &packet).is_none());
        }

        /// Content that does not fit is refused, never truncated.
        #[test]
        fn prop_oversized_content_is_never_wrapped(extra in 1usize..2000) {
            let wrapped = wrap(
                &key(),
                &parts(MAX_CONTENT_LEN + extra),
                &mut StdRng::seed_from_u64(10),
            );
            prop_assert!(wrapped.is_none());
        }
    }
}
