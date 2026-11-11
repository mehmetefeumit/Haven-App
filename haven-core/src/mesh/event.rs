//! A kind-445 location event as the envelope's [`EventParts`], and back
//! (plan §4.1).
//!
//! Both envelope formats mean one event shape, the one MDK's peeler gives an
//! application message: kind 445, tags exactly `["h", <64 lower-case hex>]`
//! then `["expiration", <decimal seconds>]`, content padded standard base64.
//! [`parts_of`] takes that shape and no other, so every string the signature
//! covers is one [`rebuild`] writes back byte for byte. The `h` value is not
//! carried: the recipient supplies the routing id of the circle whose key
//! opened the packet, and a wrong one fails the signature.

use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine as _;
use nostr::secp256k1::schnorr::Signature;
use nostr::{Event, EventId, Kind, PublicKey, Tag, TagKind, Tags, Timestamp};

use super::packet::{EventParts, Format, MAX_CONTENT_LEN};
use crate::nostr::KIND_GROUP_MESSAGE;

const GROUP_TAG: &str = "h";
const EXPIRATION_TAG: &str = "expiration";

/// The envelope fields of `event`, marked `format`.
///
/// `None` unless `event` has the shape in the module docs and its content
/// decodes to at most [`MAX_CONTENT_LEN`] bytes. The event is not verified
/// here; [`rebuild`] verifies.
#[must_use]
pub fn parts_of(event: &Event, format: Format) -> Option<EventParts> {
    if event.kind != Kind::Custom(KIND_GROUP_MESSAGE) {
        return None;
    }
    let [group, expiration] = event.tags.as_slice() else {
        return None;
    };
    let [group_tag, routing] = group.as_slice() else {
        return None;
    };
    let [expiration_tag, expiration] = expiration.as_slice() else {
        return None;
    };
    let lower_hex = |byte: u8| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte);
    if group_tag != GROUP_TAG
        || expiration_tag != EXPIRATION_TAG
        || routing.len() != 64
        || !routing.bytes().all(lower_hex)
    {
        return None;
    }
    // `parse` also reads `+7` and `007`, which `rebuild` would write as `7`.
    let expiration = expiration
        .parse::<u64>()
        .ok()
        .filter(|secs| secs.to_string() == *expiration)?;
    // This engine decodes only what it would itself encode: padding required,
    // no stray trailing bits, no whitespace.
    let content = BASE64
        .decode(&event.content)
        .ok()
        .filter(|content| content.len() <= MAX_CONTENT_LEN)?;
    Some(EventParts {
        format,
        pubkey: event.pubkey.to_bytes(),
        sig: event.sig.serialize(),
        created_at: event.created_at.as_secs(),
        expiration,
        content,
    })
}

/// The event `parts` describe in the circle routed by `nostr_group_id`,
/// verified.
///
/// The id is computed here from the rebuilt fields, so `Event::verify()`
/// (Security Rule 16) passes only for the signer's own event: `None` for a
/// changed field and for another circle's routing id, which the id binds.
/// [`Format`] is outside the signature.
#[must_use]
pub fn rebuild(parts: &EventParts, nostr_group_id: &[u8; 32]) -> Option<Event> {
    let pubkey = PublicKey::from_byte_array(parts.pubkey);
    let created_at = Timestamp::from_secs(parts.created_at);
    let kind = Kind::Custom(KIND_GROUP_MESSAGE);
    let tags = Tags::from_list(vec![
        Tag::custom(TagKind::custom(GROUP_TAG), [hex::encode(nostr_group_id)]),
        Tag::custom(
            TagKind::custom(EXPIRATION_TAG),
            [parts.expiration.to_string()],
        ),
    ]);
    let content = BASE64.encode(&parts.content);
    let id = EventId::new(&pubkey, &created_at, &kind, &tags, &content);
    let sig = Signature::from_slice(&parts.sig).ok()?;
    let event = Event::new(id, pubkey, created_at, kind, tags, content, sig);
    event.verify().is_ok().then_some(event)
}

#[cfg(test)]
mod tests {
    use nostr::{EventBuilder, JsonUtil as _, Keys, SecretKey};
    use proptest::prelude::*;
    use rand::rngs::StdRng;
    use rand::{RngCore, SeedableRng};

    use super::*;
    use crate::mesh::packet::{open, wrap, MeshKey};

    const ROUTING: [u8; 32] = [0xa7; 32];
    const CREATED_AT: u64 = 1_800_000_000;
    const EXPIRATION: u64 = 1_800_000_228;
    const EXPIRATION_TEXT: &str = "1800000228";

    /// An event signed by `keys` with exactly these tags and this content,
    /// built the way the peeler builds its own.
    fn signed(keys: &Keys, kind: u16, tags: &[&[&str]], content: &str, created_at: u64) -> Event {
        let tags = tags
            .iter()
            .map(|tag| Tag::parse(tag.iter().copied()).expect("a tag has a name"));
        EventBuilder::new(Kind::Custom(kind), content)
            .tags(tags)
            .custom_created_at(Timestamp::from_secs(created_at))
            .sign_with_keys(keys)
            .expect("sign")
    }

    /// A kind 445 in the peeler's application-message shape.
    fn sealed(
        keys: &Keys,
        routing: &[u8; 32],
        created_at: u64,
        expiration: u64,
        content: &[u8],
    ) -> Event {
        signed(
            keys,
            KIND_GROUP_MESSAGE,
            &[
                &[GROUP_TAG, &hex::encode(routing)],
                &[EXPIRATION_TAG, &expiration.to_string()],
            ],
            &BASE64.encode(content),
            created_at,
        )
    }

    fn random_bytes(len: usize) -> Vec<u8> {
        let mut bytes = vec![0; len];
        StdRng::seed_from_u64(0x6d65_7368).fill_bytes(&mut bytes);
        bytes
    }

    fn with_tags(tags: &[&[&str]]) -> Event {
        signed(
            &Keys::generate(),
            KIND_GROUP_MESSAGE,
            tags,
            "+/8=",
            CREATED_AT,
        )
    }

    fn with_content(content: &str) -> Event {
        signed(
            &Keys::generate(),
            KIND_GROUP_MESSAGE,
            &[
                &[GROUP_TAG, &hex::encode(ROUTING)],
                &[EXPIRATION_TAG, EXPIRATION_TEXT],
            ],
            content,
            CREATED_AT,
        )
    }

    fn has_parts(event: &Event) -> bool {
        parts_of(event, Format::Bridgeable).is_some()
    }

    #[test]
    fn a_sealed_event_is_rebuilt_byte_for_byte() {
        let keys = Keys::generate();
        // 0 to 3 cover every base64 padding; 575 is a location's size.
        for len in [0, 1, 2, 3, 575, MAX_CONTENT_LEN] {
            let content = random_bytes(len);
            let event = sealed(&keys, &ROUTING, CREATED_AT, EXPIRATION, &content);

            let parts = parts_of(&event, Format::Bridgeable).expect("the peeler's shape");
            assert!(
                parts
                    == EventParts {
                        format: Format::Bridgeable,
                        pubkey: keys.public_key().to_bytes(),
                        sig: event.sig.serialize(),
                        created_at: CREATED_AT,
                        expiration: EXPIRATION,
                        content,
                    }
            );

            let rebuilt = rebuild(&parts, &ROUTING).expect("the signer's own event");
            assert_eq!(rebuilt.id, event.id);
            assert_eq!(rebuilt.sig, event.sig);
            assert_eq!(rebuilt.as_json(), event.as_json());
        }
    }

    #[test]
    fn the_format_is_carried_and_is_not_signed() {
        let event = sealed(
            &Keys::generate(),
            &ROUTING,
            CREATED_AT,
            EXPIRATION,
            &random_bytes(575),
        );
        for format in [Format::NeverBridged, Format::Bridgeable] {
            let parts = parts_of(&event, format).expect("the peeler's shape");
            assert_eq!(parts.format, format);
            assert_eq!(rebuild(&parts, &ROUTING), Some(event.clone()));
        }
    }

    #[test]
    fn another_circles_routing_id_rebuilds_nothing() {
        let event = sealed(
            &Keys::generate(),
            &ROUTING,
            CREATED_AT,
            EXPIRATION,
            &random_bytes(575),
        );
        let parts = parts_of(&event, Format::Bridgeable).expect("the peeler's shape");
        assert!(rebuild(&parts, &ROUTING).is_some());
        for bit in 0..ROUTING.len() * 8 {
            let mut other = ROUTING;
            other[bit / 8] ^= 1 << (bit % 8);
            assert!(rebuild(&parts, &other).is_none());
        }
    }

    #[test]
    fn one_flipped_bit_in_any_signed_field_rebuilds_nothing() {
        let event = sealed(
            &Keys::generate(),
            &ROUTING,
            CREATED_AT,
            EXPIRATION,
            &random_bytes(64),
        );
        let parts = parts_of(&event, Format::Bridgeable).expect("the peeler's shape");
        assert!(rebuild(&parts, &ROUTING).is_some());
        let rebuilds_nothing = |changed: &EventParts| assert!(rebuild(changed, &ROUTING).is_none());

        for bit in 0..parts.pubkey.len() * 8 {
            let mut changed = parts.clone();
            changed.pubkey[bit / 8] ^= 1 << (bit % 8);
            rebuilds_nothing(&changed);
        }
        for bit in 0..parts.sig.len() * 8 {
            let mut changed = parts.clone();
            changed.sig[bit / 8] ^= 1 << (bit % 8);
            rebuilds_nothing(&changed);
        }
        for bit in 0..u64::BITS {
            let mut changed = parts.clone();
            changed.created_at ^= 1 << bit;
            rebuilds_nothing(&changed);

            let mut changed = parts.clone();
            changed.expiration ^= 1 << bit;
            rebuilds_nothing(&changed);
        }
        for bit in 0..parts.content.len() * 8 {
            let mut changed = parts.clone();
            changed.content[bit / 8] ^= 1 << (bit % 8);
            rebuilds_nothing(&changed);
        }
    }

    #[test]
    fn only_a_kind_445_has_parts() {
        let keys = Keys::generate();
        let routing = hex::encode(ROUTING);
        let tags: &[&[&str]] = &[&[GROUP_TAG, &routing], &[EXPIRATION_TAG, EXPIRATION_TEXT]];
        assert!(has_parts(&signed(&keys, 445, tags, "+/8=", CREATED_AT)));
        for kind in [9, 444, 446, 1059, 25442] {
            assert!(!has_parts(&signed(&keys, kind, tags, "+/8=", CREATED_AT)));
        }
    }

    #[test]
    fn only_the_tags_h_then_expiration_have_parts() {
        let routing = hex::encode(ROUTING);
        let group: &[&str] = &[GROUP_TAG, &routing];
        let expiration: &[&str] = &[EXPIRATION_TAG, EXPIRATION_TEXT];
        assert!(has_parts(&with_tags(&[group, expiration])));

        let refused: &[&[&[&str]]] = &[
            &[],
            // A commit's or a proposal's layout.
            &[group],
            &[expiration],
            &[expiration, group],
            &[group, group],
            &[expiration, expiration],
            &[group, expiration, expiration],
            &[group, expiration, group],
            &[group, expiration, &["e", &routing]],
            &[&["e", &routing], group, expiration],
            &[&[GROUP_TAG, &routing, ""], expiration],
            &[group, &[EXPIRATION_TAG, EXPIRATION_TEXT, ""]],
            &[&[GROUP_TAG], expiration],
            &[group, &[EXPIRATION_TAG]],
            &[&["H", &routing], expiration],
            &[&["e", &routing], expiration],
            &[group, &["Expiration", EXPIRATION_TEXT]],
            &[group, &["created_at", EXPIRATION_TEXT]],
        ];
        for tags in refused {
            assert!(!has_parts(&with_tags(tags)));
        }
    }

    #[test]
    fn only_64_lower_case_hex_characters_are_a_routing_id() {
        let lower = "0123456789abcdef".repeat(4);
        let tagged =
            |routing: &str| with_tags(&[&[GROUP_TAG, routing], &[EXPIRATION_TAG, EXPIRATION_TEXT]]);
        assert!(has_parts(&tagged(&lower)));

        let one_upper = lower.replacen('a', "A", 1);
        let one_not_hex = lower.replacen('a', "g", 1);
        for routing in [
            lower.to_uppercase().as_str(),
            one_upper.as_str(),
            one_not_hex.as_str(),
            &lower[..62],
            &lower[..63],
            &format!("{lower}00"),
            &format!("0x{}", &lower[..62]),
            &format!(" {}", &lower[..63]),
            "",
        ] {
            assert!(!has_parts(&tagged(routing)));
        }
    }

    #[test]
    fn only_the_decimal_the_peeler_writes_is_an_expiration() {
        let routing = hex::encode(ROUTING);
        let tagged =
            |expiration: &str| with_tags(&[&[GROUP_TAG, &routing], &[EXPIRATION_TAG, expiration]]);

        for (text, value) in [
            ("0", 0),
            (EXPIRATION_TEXT, EXPIRATION),
            ("18446744073709551615", u64::MAX),
        ] {
            let parts = parts_of(&tagged(text), Format::Bridgeable).expect("a u64 as it prints");
            assert_eq!(parts.expiration, value);
        }

        for text in [
            "+1800000228",
            "-1800000228",
            "-0",
            "01800000228",
            "00",
            "",
            " 1800000228",
            "1800000228 ",
            "1800000228.0",
            "18e8",
            "0x6b49d2e4",
            "6b49d2e4",
            "1_800_000_228",
            "18446744073709551616",
            "１８",
        ] {
            assert!(!has_parts(&tagged(text)));
        }
    }

    /// Anything else would be re-encoded to a string the signature does not
    /// cover.
    #[test]
    fn only_canonical_padded_standard_base64_is_content() {
        // `+/8=` is the bytes `fb ff`, `QQ==` the byte `41`.
        for (content, bytes) in [
            ("+/8=", &[0xfb, 0xff][..]),
            ("QQ==", &[0x41][..]),
            ("", &[][..]),
        ] {
            let parts = parts_of(&with_content(content), Format::Bridgeable).expect("canonical");
            assert_eq!(parts.content, bytes);
        }

        for content in [
            // Unpadded.
            "+/8", "QQ", "QQ=",  // The URL-safe alphabet.
            "-_8=", // Trailing bits set: both decode leniently to the bytes above.
            "+/9=", "QR==", // Whitespace.
            "+/8=\n", " +/8=", "+/ 8=", "+/8=\r\n", // Padding where none belongs.
            "+/8==", "QQ==+/8=", "====", "+/8=!",
        ] {
            assert!(!has_parts(&with_content(content)));
        }
    }

    #[test]
    fn content_of_881_bytes_has_parts_and_882_has_none() {
        let keys = Keys::generate();
        let sized =
            |len: usize| sealed(&keys, &ROUTING, CREATED_AT, EXPIRATION, &random_bytes(len));

        let largest = parts_of(&sized(881), Format::Bridgeable).expect("881 bytes fit");
        assert_eq!(largest.content.len(), MAX_CONTENT_LEN);
        assert!(!has_parts(&sized(882)));
    }

    #[test]
    fn an_event_survives_the_envelope() {
        let keys = Keys::generate();
        let key = MeshKey::derive(&[0x5a; 32]);
        let mut rng = StdRng::seed_from_u64(1);
        for (format, len) in [
            (Format::NeverBridged, 575),
            (Format::Bridgeable, MAX_CONTENT_LEN),
        ] {
            let event = sealed(&keys, &ROUTING, CREATED_AT, EXPIRATION, &random_bytes(len));
            let parts = parts_of(&event, format).expect("the peeler's shape");

            let packet = wrap(&key, &parts, &mut rng).expect("what has parts fits a packet");
            let opened = open(&key, &packet).expect("its own key opens it");

            assert_eq!(opened.format, format);
            let rebuilt = rebuild(&opened, &ROUTING).expect("the signer's own event");
            assert_eq!(rebuilt.as_json(), event.as_json());
        }
    }

    fn any_keys() -> impl Strategy<Value = Keys> {
        any::<[u8; 32]>().prop_filter_map("a scalar on the curve", |bytes| {
            SecretKey::from_slice(&bytes).ok().map(Keys::new)
        })
    }

    proptest! {
        #[test]
        fn prop_an_event_of_the_shape_is_rebuilt_unchanged(
            keys in any_keys(),
            routing in any::<[u8; 32]>(),
            created_at in any::<u64>(),
            expiration in any::<u64>(),
            content in proptest::collection::vec(any::<u8>(), 0..=MAX_CONTENT_LEN),
            bridgeable in any::<bool>(),
        ) {
            let format = if bridgeable { Format::Bridgeable } else { Format::NeverBridged };
            let event = sealed(&keys, &routing, created_at, expiration, &content);

            let parts = parts_of(&event, format);
            prop_assert!(parts.is_some());
            let rebuilt = rebuild(&parts.expect("checked"), &routing);
            prop_assert!(rebuilt.as_ref() == Some(&event));
            prop_assert!(rebuilt.is_some_and(|rebuilt| rebuilt.as_json() == event.as_json()));
        }

        /// What `open` can hand over from a member who signs nothing, and
        /// more: no bytes panic, and none are an event.
        #[test]
        fn prop_arbitrary_parts_rebuild_nothing(
            bridgeable in any::<bool>(),
            pubkey in any::<[u8; 32]>(),
            sig in any::<([u8; 32], [u8; 32])>(),
            created_at in any::<u64>(),
            expiration in any::<u64>(),
            content in proptest::collection::vec(any::<u8>(), 0..2000),
            routing in any::<[u8; 32]>(),
        ) {
            let parts = EventParts {
                format: if bridgeable { Format::Bridgeable } else { Format::NeverBridged },
                pubkey,
                sig: std::array::from_fn(|i| if i < 32 { sig.0[i] } else { sig.1[i - 32] }),
                created_at,
                expiration,
                content,
            };
            prop_assert!(rebuild(&parts, &routing).is_none());
        }
    }
}
