//! The WebSocket frames the proxy reads, forwards and forges — and the forged
//! EVENTS it injects into them.
//!
//! Frame-accurate rather than byte-accurate: every edit the fault layer makes
//! lands on a frame boundary chosen by CONTENT, so nothing here depends on how
//! the kernel happened to segment the stream. Frames are taken out of a growing
//! buffer rather than read field by field, because the reader that fills that
//! buffer sits in a `select!` beside the injection channels and a read that can
//! be cancelled halfway through a frame would desynchronise the stream.
//!
//! Client→server frames are masked and server→client frames are not
//! (RFC 6455 §5.1), so a frame carries its mask and unmasks into a scratch copy
//! to be READ — what gets forwarded is always the original bytes.
//!
//! # The forgeries, and why they are minted here
//!
//! [`Forgery`] is an OUTSIDER's vocabulary: every recipe below is mintable from
//! a circle's public `#h` routing id and a key belonging to nobody, which is
//! precisely the adversary Haven's cursor-poisoning gates are written against.
//! They are shaped after `haven-core/tests/cursor_poisoning_e2e.rs`'s own
//! minters, so a scenario grades the product against the wire shape its unit
//! gates already name rather than against a synthetic one.

use std::borrow::Cow;

use nostr::{Event, EventBuilder, EventId, Keys, Kind, Tag, TagStandard, Timestamp};

use crate::rig::{RigError, Step};

/// A text frame (RFC 6455 §5.2). Everything else — ping, pong, close, binary,
/// continuation — is forwarded without being read, because nothing the fault
/// layer does keys on it.
const OPCODE_TEXT: u8 = 0x1;

/// The terminator of an HTTP head, upgrade request and response alike.
const HEAD_END: &[u8] = b"\r\n\r\n";

/// One WebSocket frame, verbatim.
pub struct Frame {
    bytes: Vec<u8>,
    payload_at: usize,
    mask: Option<[u8; 4]>,
    opcode: u8,
}

impl Frame {
    /// The frame exactly as it arrived, header included. This — never a
    /// re-encoding — is what gets forwarded.
    pub fn bytes(&self) -> &[u8] {
        &self.bytes
    }

    /// Whether the payload is text, and therefore a NIP-01 message.
    pub const fn is_text(&self) -> bool {
        self.opcode == OPCODE_TEXT
    }

    /// The payload, unmasked if it arrived masked.
    pub fn payload(&self) -> Cow<'_, [u8]> {
        let raw = &self.bytes[self.payload_at..];
        self.mask.map_or(Cow::Borrowed(raw), |mask| {
            Cow::Owned(
                raw.iter()
                    .enumerate()
                    .map(|(i, byte)| byte ^ mask[i % 4])
                    .collect(),
            )
        })
    }
}

/// Takes the HTTP head at the front of `buf`, or `None` while it is incomplete.
///
/// The upgrade handshake is not framed, so it is forwarded verbatim; framing
/// starts immediately after the blank line that ends it, and whatever follows
/// stays in `buf` for [`take_frame`].
pub fn take_http_head(buf: &mut Vec<u8>) -> Option<Vec<u8>> {
    let end = buf
        .windows(HEAD_END.len())
        .position(|window| window == HEAD_END)?
        + HEAD_END.len();
    Some(buf.drain(..end).collect())
}

/// Takes the frame at the front of `buf`, or `None` while it is incomplete.
pub fn take_frame(buf: &mut Vec<u8>) -> Option<Frame> {
    let (payload_len, header_len) = frame_lengths(buf)?;
    let masked = buf[1] & 0x80 != 0;
    let mask_len = if masked { 4 } else { 0 };
    let total = header_len + mask_len + payload_len;
    if buf.len() < total {
        return None;
    }

    let bytes: Vec<u8> = buf.drain(..total).collect();
    let mask = masked.then(|| {
        let mut mask = [0u8; 4];
        mask.copy_from_slice(&bytes[header_len..header_len + 4]);
        mask
    });
    Some(Frame {
        opcode: bytes[0] & 0x0F,
        payload_at: header_len + mask_len,
        mask,
        bytes,
    })
}

/// The payload length the header at the front of `buf` announces, and the
/// length of that header — or `None` while the header itself is incomplete.
fn frame_lengths(buf: &[u8]) -> Option<(usize, usize)> {
    let short = buf.get(1)? & 0x7F;
    match short {
        126 => {
            let ext: [u8; 2] = buf.get(2..4)?.try_into().ok()?;
            Some((usize::from(u16::from_be_bytes(ext)), 4))
        }
        127 => {
            let ext: [u8; 8] = buf.get(2..10)?.try_into().ok()?;
            Some((usize::try_from(u64::from_be_bytes(ext)).ok()?, 10))
        }
        len => Some((usize::from(len), 2)),
    }
}

/// One unmasked text frame carrying `payload`, for the server→client direction.
///
/// # Panics
///
/// If `payload` is longer than a 16-bit length can announce. Every frame this
/// forges carries a harness literal — a `CLOSED` prefix, a `NOTICE` text, an
/// `EOSE` — so a 64-bit length is unreachable, and silently writing a malformed
/// frame would make every assertion behind it meaningless.
pub fn text_frame(payload: &[u8]) -> Vec<u8> {
    let mut frame = vec![0x80 | OPCODE_TEXT];
    if payload.len() < 126 {
        frame.push(u8::try_from(payload.len()).expect("a length below 126 fits a byte"));
    } else {
        frame.push(126);
        let len = u16::try_from(payload.len()).expect("a forged frame fits a 16-bit length");
        frame.extend_from_slice(&len.to_be_bytes());
    }
    frame.extend_from_slice(payload);
    frame
}

// ---------------------------------------------------------------------------
// Minting
// ---------------------------------------------------------------------------

/// The kind every forgery here wears: Marmot's group message.
const GROUP_MESSAGE_KIND: u16 = 445;

/// How far in the past an expired forgery's `expiration` sits.
///
/// An hour, a literal of this crate's own: far beyond any plausible clock-skew
/// grace, so no forgery restates the product's grace constant — which is the
/// thing the arm reading it is trying to measure.
const EXPIRED_BY_SECS: u64 = 3600;

/// Content for the recipes whose content is never meant to be peeled.
///
/// Base64, so the pre-engine transport parse gets as far as the ENGINE: the
/// difference between [`Forgery::MalformedDoubleH`] and
/// [`Forgery::Unprocessable`] is which side of the authentication boundary
/// refuses them, and identical content is what keeps the tag the only variable.
const OPAQUE_CONTENT: &str = "b3BhcXVl";

/// Content no base64 decoder accepts, so the envelope parses and the engine is
/// the thing that refuses it.
const UNDECODABLE_CONTENT: &str = "!!!!not-base64!!!!";

/// A second `#h` value, so a doubled routing tag is one this crate chose.
const FOREIGN_ROUTING_ID: [u8; 32] = [0x11; 32];

/// One forged event, by recipe.
///
/// `Copy`, deliberately: a forgery travels inside [`crate::nemesis::types::Fault`],
/// which every schedule op is built from. A rewrap names the ciphertext it
/// copies by ID and the plane resolves it from its own store, because "an
/// OBSERVED ciphertext" means one the relay really carried.
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Forgery {
    /// A kind-445 at a circle's public `#h` whose NIP-40 `expiration` is
    /// already past.
    ///
    /// The relay double is NIP-40-conformant, so it refuses to store this and
    /// filters it out of every query — which is exactly why an expired-event
    /// arm has to be injected live rather than seeded.
    Expired {
        /// The circle's public routing id, as the `#h` tag carries it.
        group_id: [u8; 32],
    },
    /// An observed ciphertext re-signed under a throwaway key, dated
    /// `offset_secs` from the original.
    ///
    /// The real cursor-poisoning shape: the outer ciphertext is copied
    /// verbatim, the routing tag is the circle's public one, and the signer
    /// holds no MLS secret. The date is an OFFSET rather than an instant so an
    /// arm never has to hold a wall clock.
    Rewrap {
        /// The event the plane's own store holds.
        source: EventId,
        /// Seconds from the source's `created_at`, forwards or backwards.
        offset_secs: i64,
    },
    /// A kind-445 carrying TWO `h` tags.
    ///
    /// A conformant relay matches a `#h` filter on ANY of an event's values, so
    /// this reaches a victim subscribed on the first one — and Haven's pure
    /// pre-engine transport parse refuses it before the engine, the signature
    /// or any key material is involved.
    MalformedDoubleH {
        /// The circle's public routing id.
        group_id: [u8; 32],
    },
    /// A kind-445 whose envelope is well formed and whose content no decoder
    /// accepts, so the pre-engine parse succeeds and the ENGINE refuses it.
    Unprocessable {
        /// The circle's public routing id.
        group_id: [u8; 32],
    },
}

impl Forgery {
    /// The label the timeline and the schedule digest carry. A literal from
    /// this file.
    #[must_use]
    pub const fn label(self) -> &'static str {
        match self {
            Self::Expired { .. } => "expired",
            Self::Rewrap { .. } => "rewrap",
            Self::MalformedDoubleH { .. } => "malformed-double-h",
            Self::Unprocessable { .. } => "unprocessable",
        }
    }

    /// The digest discriminant.
    pub(crate) const fn code(self) -> u8 {
        match self {
            Self::Expired { .. } => 0,
            Self::Rewrap { .. } => 1,
            Self::MalformedDoubleH { .. } => 2,
            Self::Unprocessable { .. } => 3,
        }
    }

    /// Whether this recipe needs the plane to resolve an observed event first.
    pub(crate) const fn source(self) -> Option<EventId> {
        match self {
            Self::Rewrap { source, .. } => Some(source),
            Self::Expired { .. } | Self::MalformedDoubleH { .. } | Self::Unprocessable { .. } => {
                None
            }
        }
    }
}

// The recipe's NAME and nothing else. A routing id is an identifier and an
// event id is 64 hex — the shape a structural rule matches — so neither may
// reach a rendering, and a derived `Debug` would print both (Rule 15).
impl std::fmt::Debug for Forgery {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_tuple("Forgery").field(&self.label()).finish()
    }
}

// Serialised as the label alone, for the same reason: a fault reaches the
// timeline, and a record says WHAT was forged, never against which circle.
impl serde::Serialize for Forgery {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(self.label())
    }
}

/// Mints the event `forgery` describes.
///
/// `source` is the observed ciphertext a [`Forgery::Rewrap`] copies; every
/// other recipe ignores it. The signing key is freshly generated and belongs to
/// nobody — it is deliberately NOT declared to the needle manifest, because an
/// outsider's key is not one the world minted for itself and declaring it would
/// claim the rig owns an identity it is impersonating an attacker with.
///
/// # Errors
///
/// [`RigError::Core`] with [`Step::ApplyFault`] if a rewrap was asked for
/// without the event it copies, or if the event could not be signed: a fault
/// that could not be minted did not fire.
pub fn mint(forgery: Forgery, source: Option<&Event>) -> Result<Event, RigError> {
    let keys = Keys::generate();
    let builder = match forgery {
        Forgery::Expired { group_id } => EventBuilder::new(kind(), OPAQUE_CONTENT).tags(vec![
            routing_tag(&group_id)?,
            Tag::expiration(Timestamp::from(
                Timestamp::now().as_secs().saturating_sub(EXPIRED_BY_SECS),
            )),
        ]),
        Forgery::Rewrap { offset_secs, .. } => {
            let observed = source.ok_or(RigError::Core(Step::ApplyFault))?;
            // The expiration is dropped rather than copied: a rewrap's whole
            // subject is the SIGNATURE and the date, and carrying the
            // original's expiry would let Haven's own expiry screen answer
            // before the authentication boundary the arm is aiming at.
            let tags: Vec<Tag> = observed
                .tags
                .iter()
                .filter(|tag| !matches!(tag.as_standardized(), Some(TagStandard::Expiration(_))))
                .cloned()
                .collect();
            EventBuilder::new(observed.kind, observed.content.clone())
                .tags(tags)
                .custom_created_at(shifted(observed.created_at, offset_secs))
        }
        Forgery::MalformedDoubleH { group_id } => {
            EventBuilder::new(kind(), OPAQUE_CONTENT).tags(vec![
                routing_tag(&group_id)?,
                routing_tag(&FOREIGN_ROUTING_ID)?,
            ])
        }
        Forgery::Unprocessable { group_id } => {
            EventBuilder::new(kind(), UNDECODABLE_CONTENT).tags(vec![routing_tag(&group_id)?])
        }
    };
    builder
        .sign_with_keys(&keys)
        .map_err(|_| RigError::Core(Step::ApplyFault))
}

/// The group-message kind, built once so the literal lives in one place.
const fn kind() -> Kind {
    Kind::Custom(GROUP_MESSAGE_KIND)
}

/// The `#h` tag for a routing id.
fn routing_tag(group_id: &[u8; 32]) -> Result<Tag, RigError> {
    Tag::parse(["h", &hex::encode(group_id)]).map_err(|_| RigError::Core(Step::ApplyFault))
}

/// `created_at` moved by `offset_secs`, saturating at the epoch.
fn shifted(created_at: Timestamp, offset_secs: i64) -> Timestamp {
    let base = created_at.as_secs();
    let moved = if offset_secs.is_negative() {
        base.saturating_sub(offset_secs.unsigned_abs())
    } else {
        base.saturating_add(offset_secs.unsigned_abs())
    };
    Timestamp::from(moved)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn masked(payload: &[u8], mask: [u8; 4]) -> Vec<u8> {
        let mut frame = vec![
            0x80 | OPCODE_TEXT,
            0x80 | u8::try_from(payload.len()).expect("test payload is short"),
        ];
        frame.extend_from_slice(&mask);
        frame.extend(
            payload
                .iter()
                .enumerate()
                .map(|(i, byte)| byte ^ mask[i % 4]),
        );
        frame
    }

    #[test]
    fn an_unmasked_frame_reads_back_verbatim() {
        let forged = text_frame(br#"["EOSE","probe"]"#);
        let mut buf = forged.clone();
        let frame = take_frame(&mut buf).expect("a whole frame");
        assert!(frame.is_text());
        assert_eq!(frame.payload().as_ref(), br#"["EOSE","probe"]"#);
        assert_eq!(frame.bytes(), forged.as_slice());
        assert!(buf.is_empty());
    }

    #[test]
    fn a_masked_frame_is_unmasked_to_read_and_forwarded_as_it_arrived() {
        let wire = masked(br#"["CLOSE","probe"]"#, [0x37, 0xfa, 0x21, 0x3d]);
        let mut buf = wire.clone();
        let frame = take_frame(&mut buf).expect("a whole frame");
        assert_eq!(frame.payload().as_ref(), br#"["CLOSE","probe"]"#);
        assert_eq!(
            frame.bytes(),
            wire.as_slice(),
            "the forwarded bytes must be the arriving bytes, mask included"
        );
    }

    #[test]
    fn a_partial_frame_is_left_in_the_buffer_until_the_rest_arrives() {
        let whole = text_frame(b"[\"NOTICE\",\"held\"]");
        let mut buf = whole[..whole.len() - 3].to_vec();
        assert!(take_frame(&mut buf).is_none());
        assert_eq!(buf.len(), whole.len() - 3, "nothing may be consumed");
        buf.extend_from_slice(&whole[whole.len() - 3..]);
        assert!(take_frame(&mut buf).is_some());
    }

    #[test]
    fn a_header_that_has_not_arrived_yet_consumes_nothing() {
        let mut buf = vec![0x81];
        assert!(take_frame(&mut buf).is_none());
        assert_eq!(buf.len(), 1);

        let mut extended = vec![0x81, 126, 0x01];
        assert!(take_frame(&mut extended).is_none());
        assert_eq!(extended.len(), 3);
    }

    #[test]
    fn two_frames_in_one_read_are_taken_one_at_a_time() {
        let mut buf = text_frame(b"first");
        buf.extend_from_slice(&text_frame(b"second"));
        assert_eq!(
            take_frame(&mut buf).expect("first").payload().as_ref(),
            b"first"
        );
        assert_eq!(
            take_frame(&mut buf).expect("second").payload().as_ref(),
            b"second"
        );
        assert!(take_frame(&mut buf).is_none());
    }

    #[test]
    fn a_payload_of_126_bytes_and_up_carries_an_extended_length() {
        let payload = vec![b'x'; 300];
        let mut buf = text_frame(&payload);
        assert_eq!(buf[1] & 0x7F, 126);
        let frame = take_frame(&mut buf).expect("a whole frame");
        assert_eq!(frame.payload().len(), 300);
    }

    #[test]
    fn a_64_bit_length_header_is_read_back() {
        let payload = vec![b'y'; 8];
        let mut buf = vec![0x81, 127];
        buf.extend_from_slice(&(payload.len() as u64).to_be_bytes());
        buf.extend_from_slice(&payload);
        let frame = take_frame(&mut buf).expect("a whole frame");
        assert_eq!(frame.payload().as_ref(), payload.as_slice());
    }

    #[test]
    fn a_non_text_frame_is_carried_but_never_read_as_a_message() {
        let mut buf = vec![0x8A, 0x00]; // an unmasked, empty pong
        let frame = take_frame(&mut buf).expect("a whole frame");
        assert!(!frame.is_text());
        assert!(frame.payload().is_empty());
    }

    #[test]
    fn the_http_head_is_taken_whole_and_the_first_frame_survives_it() {
        let mut buf = b"GET / HTTP/1.1\r\nHost: x\r\n\r\n".to_vec();
        buf.extend_from_slice(&text_frame(b"after"));
        let head = take_http_head(&mut buf).expect("a whole head");
        assert!(head.ends_with(b"\r\n\r\n"));
        assert_eq!(
            take_frame(&mut buf)
                .expect("the first frame")
                .payload()
                .as_ref(),
            b"after"
        );
    }

    #[test]
    fn a_head_that_has_not_finished_arriving_consumes_nothing() {
        let mut buf = b"GET / HTTP/1.1\r\nHost: x\r\n".to_vec();
        assert!(take_http_head(&mut buf).is_none());
        assert_eq!(buf.len(), 25);
    }

    // -- minting ------------------------------------------------------------

    /// A routing id no circle in any world holds.
    const A_ROUTING_ID: [u8; 32] = [0x7c; 32];

    /// A ciphertext a plane observed, standing in for one a member published.
    fn observed() -> Event {
        EventBuilder::new(kind(), "Y2lwaGVydGV4dA")
            .tags(vec![
                routing_tag(&A_ROUTING_ID).expect("a routing tag"),
                Tag::expiration(Timestamp::from(Timestamp::now().as_secs() + 228)),
            ])
            .custom_created_at(Timestamp::from(1_700_000_000))
            .sign_with_keys(&Keys::generate())
            .expect("a member's own event signs")
    }

    fn routing_values(event: &Event) -> Vec<String> {
        event
            .tags
            .iter()
            .filter(|tag| tag.kind().as_str() == "h")
            .filter_map(|tag| tag.content().map(str::to_owned))
            .collect()
    }

    #[test]
    fn an_expired_forgery_is_routed_at_the_circle_and_dated_in_the_past() {
        let event = mint(
            Forgery::Expired {
                group_id: A_ROUTING_ID,
            },
            None,
        )
        .expect("mints");
        assert_eq!(routing_values(&event), vec![hex::encode(A_ROUTING_ID)]);
        let expiry = event
            .tags
            .find(nostr::TagKind::Expiration)
            .and_then(|tag| tag.content().map(str::to_owned))
            .expect("an expiration");
        let expiry: u64 = expiry.parse().expect("an expiration is seconds");
        assert!(
            expiry < Timestamp::now().as_secs(),
            "an expired forgery whose expiry is in the future is not expired"
        );
        assert!(event.verify().is_ok(), "it must be a real, signed event");
    }

    #[test]
    fn a_rewrap_copies_the_ciphertext_verbatim_under_another_key_and_drops_the_expiry() {
        let source = observed();
        let forged = mint(
            Forgery::Rewrap {
                source: source.id,
                offset_secs: 600,
            },
            Some(&source),
        )
        .expect("mints");
        assert_eq!(forged.content, source.content, "the ciphertext is copied");
        assert_eq!(routing_values(&forged), routing_values(&source));
        assert_ne!(
            forged.pubkey, source.pubkey,
            "a rewrap is signed by somebody who holds no MLS secret"
        );
        assert_eq!(
            forged.created_at.as_secs(),
            source.created_at.as_secs() + 600
        );
        assert!(
            forged.tags.find(nostr::TagKind::Expiration).is_none(),
            "the expiry is dropped so Haven's own expiry screen does not answer first"
        );
        assert!(forged.verify().is_ok());

        let backwards = mint(
            Forgery::Rewrap {
                source: source.id,
                offset_secs: -600,
            },
            Some(&source),
        )
        .expect("mints");
        assert_eq!(
            backwards.created_at.as_secs(),
            source.created_at.as_secs() - 600
        );
    }

    #[test]
    fn a_rewrap_without_the_event_it_copies_is_refused_rather_than_invented() {
        let refused = mint(
            Forgery::Rewrap {
                source: EventId::from_slice(&[9; 32]).expect("32 bytes is an event id"),
                offset_secs: 1,
            },
            None,
        );
        assert!(
            matches!(refused, Err(RigError::Core(Step::ApplyFault))),
            "a rewrap of nothing is a fault that did not fire"
        );
    }

    #[test]
    fn the_two_unpeelable_forgeries_differ_only_where_they_are_refused() {
        let malformed = mint(
            Forgery::MalformedDoubleH {
                group_id: A_ROUTING_ID,
            },
            None,
        )
        .expect("mints");
        assert_eq!(
            routing_values(&malformed),
            vec![hex::encode(A_ROUTING_ID), hex::encode(FOREIGN_ROUTING_ID)],
            "a doubled routing tag is what the pre-engine parse refuses"
        );
        assert_eq!(malformed.content, OPAQUE_CONTENT);

        let unprocessable = mint(
            Forgery::Unprocessable {
                group_id: A_ROUTING_ID,
            },
            None,
        )
        .expect("mints");
        assert_eq!(
            routing_values(&unprocessable),
            vec![hex::encode(A_ROUTING_ID)]
        );
        assert_ne!(
            unprocessable.content, malformed.content,
            "the engine-side refusal turns on the content, and the parse-side one on the tag"
        );
        for event in [&malformed, &unprocessable] {
            assert!(event.verify().is_ok());
            assert_eq!(event.kind, kind());
        }
    }

    #[test]
    fn a_forgery_renders_its_recipe_and_neither_the_circle_nor_the_event_it_names() {
        let recipes = [
            Forgery::Expired {
                group_id: A_ROUTING_ID,
            },
            Forgery::Rewrap {
                source: EventId::from_slice(&[0xAB; 32]).expect("32 bytes is an event id"),
                offset_secs: 86_400,
            },
            Forgery::MalformedDoubleH {
                group_id: A_ROUTING_ID,
            },
            Forgery::Unprocessable {
                group_id: A_ROUTING_ID,
            },
        ];
        let mut codes = Vec::new();
        for recipe in recipes {
            let rendered = format!("{recipe:?}");
            let json = serde_json::to_string(&recipe).expect("a recipe serialises");
            for surface in [rendered.as_str(), json.as_str()] {
                assert!(surface.contains(recipe.label()), "{surface}");
                assert!(!surface.contains("7c7c"), "{surface}");
                assert!(!surface.contains("abab"), "{surface}");
                assert!(!surface.contains("86400"), "{surface}");
            }
            codes.push(recipe.code());
        }
        codes.sort_unstable();
        codes.dedup();
        assert_eq!(
            codes.len(),
            recipes.len(),
            "two recipes that share a digest code would digest as one schedule"
        );
    }
}
