//! The frames two phones exchange on a mesh link once its Noise handshake is
//! done (plan §6.2).
//!
//! ```text
//! plaintext  max_frame − 16 B   type ‖ len ‖ body ‖ zero padding
//!   type        1 B
//!   len         2 B   length of the body, big-endian
//!   body
//!     HELLO     8 B   the sender's link-deduplication value (§6.1)
//!     HAVE   17·n B   n ≥ 1 of: packet id (16) ‖ lifetime units left (1, never 0)
//!     WANT   16·n B   n ≥ 1 packet ids
//!     PKT   1 + c B   chunk index ‖ chunk
//!     BYE       0 B
//! ```
//!
//! Every plaintext on a link has the one length its [`FrameSize`] fixes, so a
//! sealed frame's size says nothing about its type or how much it carries.
//! A packet crosses as [`FrameSize::chunk_count`] `PKT` frames in index order,
//! each chunk as long as fits and the last one whatever is left.
//!
//! [`decode`] borrows from the plaintext and allocates nothing; it accepts
//! exactly what the encoders here produce, so every frame has one encoding.
//! A `None` from it ends the link. No type here is `Debug`: a frame holds
//! packet ids and packet bytes (Security Rule 15).

use std::ops::Range;

use super::noise;
use super::packet::{Packet, PacketId, PACKET_LEN};

/// The shortest radio frame a link may have: a handshake message crosses in
/// one frame, and the reply is the longer of the two.
pub const MIN_FRAME_LEN: usize = noise::REPLY_LEN;

/// The longest radio frame a link may have: what the link cipher seals at most.
pub const MAX_FRAME_LEN: usize = noise::MAX_PLAINTEXT_LEN + noise::TAG_LEN;

/// Length of the value a `HELLO` carries.
pub const HELLO_VALUE_LEN: usize = 8;

const HEADER_LEN: usize = 3;
const ID_LEN: usize = 16;
const ENTRY_LEN: usize = ID_LEN + 1;

const HELLO: u8 = 1;
const HAVE: u8 = 2;
const WANT: u8 = 3;
const PKT: u8 = 4;
const BYE: u8 = 5;

// A chunk index is one byte: the shortest frame must not need more chunks.
const _: () = assert!(PACKET_LEN.div_ceil(MIN_FRAME_LEN - noise::TAG_LEN - HEADER_LEN - 1) <= 256);

/// The plaintext length of every frame on one link, and what fits in it.
#[derive(Clone, Copy, PartialEq, Eq)]
pub struct FrameSize(usize);

impl FrameSize {
    /// For a link whose radio frames are `max_frame` bytes. `None` below
    /// [`MIN_FRAME_LEN`] or above [`MAX_FRAME_LEN`].
    #[must_use]
    pub const fn of_link(max_frame: usize) -> Option<Self> {
        if max_frame < MIN_FRAME_LEN || max_frame > MAX_FRAME_LEN {
            return None;
        }
        Some(Self(max_frame - noise::TAG_LEN))
    }

    /// Length of every plaintext frame.
    #[must_use]
    pub const fn plaintext_len(self) -> usize {
        self.0
    }

    /// Length of every sealed frame: the link's `max_frame`.
    #[must_use]
    pub const fn sealed_len(self) -> usize {
        self.0 + noise::TAG_LEN
    }

    /// The most entries one `HAVE` carries; at least one.
    #[must_use]
    pub const fn have_capacity(self) -> usize {
        (self.0 - HEADER_LEN) / ENTRY_LEN
    }

    /// The most ids one `WANT` carries; at least one.
    #[must_use]
    pub const fn want_capacity(self) -> usize {
        (self.0 - HEADER_LEN) / ID_LEN
    }

    /// Length of every `PKT` chunk but a packet's last.
    #[must_use]
    pub const fn chunk_len(self) -> usize {
        let room = self.0 - HEADER_LEN - 1;
        if room < PACKET_LEN {
            room
        } else {
            PACKET_LEN
        }
    }

    /// How many `PKT` frames carry one packet.
    #[must_use]
    pub const fn chunk_count(self) -> usize {
        PACKET_LEN.div_ceil(self.chunk_len())
    }

    /// The packet bytes chunk `index` carries; `None` past the last chunk.
    fn chunk_range(self, index: u8) -> Option<Range<usize>> {
        let start = usize::from(index) * self.chunk_len();
        (start < PACKET_LEN).then(|| start..(start + self.chunk_len()).min(PACKET_LEN))
    }
}

/// One decoded frame, borrowing its body from the plaintext.
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Frame<'a> {
    /// The sender's link-deduplication value.
    Hello([u8; HELLO_VALUE_LEN]),
    /// Packets the sender holds, each with its lifetime units left.
    Have(Entries<'a>),
    /// Packets the sender asks for.
    Want(Ids<'a>),
    /// Chunk `index` of the packet the sender is transferring.
    Pkt {
        /// Position of the chunk in its packet, from zero.
        index: u8,
        /// The chunk: exactly the length its index has on this link.
        chunk: &'a [u8],
    },
    /// The sender is closing the link.
    Bye,
}

/// The entries of a `HAVE`: at least one, each with a non-zero lifetime.
#[derive(Clone, Copy, PartialEq, Eq)]
pub struct Entries<'a>(&'a [u8]);

impl<'a> Entries<'a> {
    /// Each packet id with its lifetime units left, in frame order.
    pub fn iter(self) -> impl Iterator<Item = (PacketId, u8)> + 'a {
        self.0.chunks_exact(ENTRY_LEN).filter_map(|entry| {
            let (id, rest) = entry.split_first_chunk()?;
            Some((PacketId(*id), *rest.first()?))
        })
    }
}

/// The ids of a `WANT`: at least one.
#[derive(Clone, Copy, PartialEq, Eq)]
pub struct Ids<'a>(&'a [u8]);

impl<'a> Ids<'a> {
    /// Each packet id, in frame order.
    pub fn iter(self) -> impl Iterator<Item = PacketId> + 'a {
        self.0
            .chunks_exact(ID_LEN)
            .filter_map(|id| Some(PacketId(id.try_into().ok()?)))
    }
}

/// Parses one opened frame, strictly.
///
/// `None` for a plaintext of a length no link has, an unknown type, a body
/// length past the plaintext, a non-zero padding byte, or a body outside its
/// type's bounds.
#[must_use]
pub fn decode(plaintext: &[u8]) -> Option<Frame<'_>> {
    let size = FrameSize::of_link(plaintext.len().checked_add(noise::TAG_LEN)?)?;
    let (&kind, rest) = plaintext.split_first()?;
    let (len, rest) = rest.split_first_chunk()?;
    let (body, padding) = rest.split_at_checked(u16::from_be_bytes(*len).into())?;
    if padding.iter().any(|&byte| byte != 0) {
        return None;
    }
    match kind {
        HELLO => Some(Frame::Hello(body.try_into().ok()?)),
        HAVE => {
            let whole = !body.is_empty() && body.len() % ENTRY_LEN == 0;
            let entries = Entries(body);
            (whole && entries.iter().all(|(_, remaining)| remaining != 0))
                .then_some(Frame::Have(entries))
        }
        WANT => (!body.is_empty() && body.len() % ID_LEN == 0).then_some(Frame::Want(Ids(body))),
        PKT => {
            let (&index, chunk) = body.split_first()?;
            (chunk.len() == size.chunk_range(index)?.len()).then_some(Frame::Pkt { index, chunk })
        }
        BYE => body.is_empty().then_some(Frame::Bye),
        _ => None,
    }
}

/// A padded plaintext of `size` with `kind`, the body length and room for
/// `body_len` bytes of body, which `fill` writes.
fn build(
    kind: u8,
    size: FrameSize,
    body_len: usize,
    fill: impl FnOnce(&mut [u8]),
) -> Option<Vec<u8>> {
    let mut plaintext = vec![0; size.plaintext_len()];
    let (header, rest) = plaintext.split_first_chunk_mut::<HEADER_LEN>()?;
    let [len_high, len_low] = u16::try_from(body_len).ok()?.to_be_bytes();
    *header = [kind, len_high, len_low];
    fill(rest.get_mut(..body_len)?);
    Some(plaintext)
}

/// A `HELLO` carrying `value`.
#[must_use]
pub fn hello(value: &[u8; HELLO_VALUE_LEN], size: FrameSize) -> Option<Vec<u8>> {
    build(HELLO, size, HELLO_VALUE_LEN, |body| {
        body.copy_from_slice(value);
    })
}

/// A `HAVE` of `entries`. `None` for no entry, more than
/// [`FrameSize::have_capacity`], or a zero lifetime.
#[must_use]
pub fn have(entries: &[(PacketId, u8)], size: FrameSize) -> Option<Vec<u8>> {
    if entries.is_empty() || entries.iter().any(|&(_, remaining)| remaining == 0) {
        return None;
    }
    build(HAVE, size, entries.len() * ENTRY_LEN, |body| {
        for (slot, (id, remaining)) in body.chunks_exact_mut(ENTRY_LEN).zip(entries) {
            let (id_bytes, remaining_byte) = slot.split_at_mut(ID_LEN);
            id_bytes.copy_from_slice(&id.0);
            remaining_byte.copy_from_slice(&[*remaining]);
        }
    })
}

/// A `WANT` of `ids`. `None` for no id or more than
/// [`FrameSize::want_capacity`].
#[must_use]
pub fn want(ids: &[PacketId], size: FrameSize) -> Option<Vec<u8>> {
    if ids.is_empty() {
        return None;
    }
    build(WANT, size, ids.len() * ID_LEN, |body| {
        for (slot, id) in body.chunks_exact_mut(ID_LEN).zip(ids) {
            slot.copy_from_slice(&id.0);
        }
    })
}

/// The `PKT` carrying chunk `index` of `packet`. `None` past the last chunk.
#[must_use]
pub fn pkt(packet: &Packet, index: u8, size: FrameSize) -> Option<Vec<u8>> {
    let chunk = packet.as_bytes().get(size.chunk_range(index)?)?;
    build(PKT, size, 1 + chunk.len(), |body| {
        if let Some((index_byte, rest)) = body.split_first_mut() {
            *index_byte = index;
            rest.copy_from_slice(chunk);
        }
    })
}

/// A `BYE`.
#[must_use]
pub fn bye(size: FrameSize) -> Option<Vec<u8>> {
    build(BYE, size, 0, |_| {})
}

#[cfg(test)]
mod tests {
    use proptest::prelude::*;
    use rand::rngs::StdRng;
    use rand::SeedableRng;

    use super::*;
    use crate::mesh::packet::cover_packet;

    /// A link of a common Bluetooth frame size.
    fn size() -> FrameSize {
        FrameSize::of_link(512).expect("within bounds")
    }

    fn id(n: usize) -> PacketId {
        PacketId(std::array::from_fn(|i| (n + i).to_le_bytes()[0]))
    }

    fn packet(seed: u64) -> Packet {
        cover_packet(&mut StdRng::seed_from_u64(seed))
    }

    /// A plaintext of `size()` laid out by hand from the module's table.
    fn raw(kind: u8, len: u16, body: &[u8]) -> Vec<u8> {
        let mut plaintext = vec![0; size().plaintext_len()];
        plaintext[0] = kind;
        plaintext[1..3].copy_from_slice(&len.to_be_bytes());
        plaintext[3..3 + body.len()].copy_from_slice(body);
        plaintext
    }

    fn entries_of(frame: Option<Frame<'_>>) -> Option<Vec<(PacketId, u8)>> {
        match frame? {
            Frame::Have(entries) => Some(entries.iter().collect()),
            _ => None,
        }
    }

    fn ids_of(frame: Option<Frame<'_>>) -> Option<Vec<PacketId>> {
        match frame? {
            Frame::Want(ids) => Some(ids.iter().collect()),
            _ => None,
        }
    }

    #[test]
    fn a_link_frame_is_between_48_and_4112_bytes() {
        assert!(FrameSize::of_link(MIN_FRAME_LEN - 1).is_none());
        assert!(FrameSize::of_link(MAX_FRAME_LEN + 1).is_none());
        assert_eq!((MIN_FRAME_LEN, MAX_FRAME_LEN), (48, 4112));

        let smallest = FrameSize::of_link(48).expect("the minimum");
        assert_eq!(smallest.plaintext_len(), 32);
        assert_eq!(smallest.sealed_len(), 48);
        assert_eq!(smallest.have_capacity(), 1);
        assert_eq!(smallest.want_capacity(), 1);
        assert_eq!((smallest.chunk_len(), smallest.chunk_count()), (28, 37));

        assert_eq!(size().plaintext_len(), 496);
        assert_eq!(size().have_capacity(), 29);
        assert_eq!(size().want_capacity(), 30);
        assert_eq!((size().chunk_len(), size().chunk_count()), (492, 3));

        let largest = FrameSize::of_link(4112).expect("the maximum");
        assert_eq!((largest.chunk_len(), largest.chunk_count()), (1024, 1));
    }

    #[test]
    fn a_frame_laid_out_by_hand_decodes_to_its_fields() {
        let hello = raw(1, 8, &[9; 8]);
        assert!(decode(&hello) == Some(Frame::Hello([9; 8])));

        let mut body = id(1).0.to_vec();
        body.push(200);
        body.extend_from_slice(&id(2).0);
        body.push(1);
        assert!(entries_of(decode(&raw(2, 34, &body))) == Some(vec![(id(1), 200), (id(2), 1)]));

        let body = [id(3).0, id(4).0].concat();
        assert!(ids_of(decode(&raw(3, 32, &body))) == Some(vec![id(3), id(4)]));

        let mut body = vec![1];
        body.extend_from_slice(&[0xab; 492]);
        assert!(
            decode(&raw(4, 493, &body))
                == Some(Frame::Pkt {
                    index: 1,
                    chunk: &[0xab; 492]
                })
        );

        assert!(decode(&raw(5, 0, &[])) == Some(Frame::Bye));
    }

    #[test]
    fn an_encoded_frame_is_the_hand_laid_one() {
        assert_eq!(hello(&[9; 8], size()), Some(raw(1, 8, &[9; 8])));
        let mut body = id(1).0.to_vec();
        body.push(200);
        assert_eq!(have(&[(id(1), 200)], size()), Some(raw(2, 17, &body)));
        assert_eq!(want(&[id(3)], size()), Some(raw(3, 16, &id(3).0)));
        assert_eq!(bye(size()), Some(raw(5, 0, &[])));

        let packet = packet(1);
        let mut body = vec![2];
        body.extend_from_slice(&packet.as_bytes()[984..]);
        assert_eq!(pkt(&packet, 2, size()), Some(raw(4, 41, &body)));
    }

    #[test]
    fn an_unknown_type_is_rejected() {
        for kind in (0..=u8::MAX).filter(|kind| !(1..=5).contains(kind)) {
            assert!(decode(&raw(kind, 0, &[])).is_none());
            assert!(decode(&raw(kind, 8, &[1; 8])).is_none());
        }
    }

    #[test]
    fn a_body_length_past_the_plaintext_is_rejected() {
        let space = u16::try_from(size().plaintext_len() - 3).expect("fits");
        assert!(decode(&raw(3, space + 1, &[])).is_none());
        assert!(decode(&raw(3, u16::MAX, &[])).is_none());
        // The whole space is a body of 30 ids and 13 stray bytes, not a WANT.
        assert!(decode(&raw(3, space, &[])).is_none());
        assert!(ids_of(decode(&raw(3, 480, &[]))).is_some_and(|ids| ids.len() == 30));
    }

    #[test]
    fn any_non_zero_padding_byte_is_rejected() {
        for dirty in [3, 4, 200, size().plaintext_len() - 1] {
            let mut plaintext = raw(5, 0, &[]);
            plaintext[dirty] = 1;
            assert!(decode(&plaintext).is_none());
        }
        let mut plaintext = raw(1, 8, &[9; 8]);
        plaintext[11] = 0x80;
        assert!(decode(&plaintext).is_none());
    }

    #[test]
    fn a_plaintext_of_a_length_no_link_has_is_rejected() {
        assert!(decode(&[]).is_none());
        assert!(decode(&[5, 0, 0]).is_none());
        assert!(decode(&[5; 31][..]).is_none());
        assert!(decode(&vec![0; noise::MAX_PLAINTEXT_LEN + 1]).is_none());
        let mut shortest = vec![0; 32];
        shortest[0] = 5;
        assert!(decode(&shortest) == Some(Frame::Bye));
    }

    #[test]
    fn a_hello_is_exactly_eight_bytes() {
        assert!(decode(&raw(1, 7, &[9; 7])).is_none());
        assert!(decode(&raw(1, 9, &[9; 9])).is_none());
        assert!(decode(&raw(1, 0, &[])).is_none());
    }

    #[test]
    fn a_bye_has_no_body() {
        assert!(decode(&raw(5, 1, &[1])).is_none());
    }

    #[test]
    fn a_have_holds_whole_entries_with_a_lifetime_and_at_least_one() {
        let mut entry = id(1).0.to_vec();
        entry.push(7);
        assert!(decode(&raw(2, 0, &[])).is_none());
        assert!(decode(&raw(2, 16, &entry[..16])).is_none());
        assert!(decode(&raw(2, 18, &[&entry[..], &[1]].concat())).is_none());
        entry[16] = 0;
        assert!(decode(&raw(2, 17, &entry)).is_none());

        assert!(have(&[], size()).is_none());
        assert!(have(&[(id(1), 0)], size()).is_none());
        let full: Vec<_> = (0..29).map(|n| (id(n), 1)).collect();
        assert!(entries_of(decode(&have(&full, size()).expect("fits"))) == Some(full.clone()));
        let over: Vec<_> = (0..30).map(|n| (id(n), 1)).collect();
        assert!(have(&over, size()).is_none());
    }

    #[test]
    fn a_want_holds_whole_ids_and_at_least_one() {
        assert!(decode(&raw(3, 0, &[])).is_none());
        assert!(decode(&raw(3, 15, &[1; 15])).is_none());
        assert!(decode(&raw(3, 17, &[1; 17])).is_none());

        assert!(want(&[], size()).is_none());
        let full: Vec<_> = (0..30).map(id).collect();
        assert!(ids_of(decode(&want(&full, size()).expect("fits"))) == Some(full.clone()));
        let over: Vec<_> = (0..31).map(id).collect();
        assert!(want(&over, size()).is_none());
    }

    #[test]
    fn a_chunk_has_the_length_its_index_has_and_no_other() {
        let chunk = |index: u8, len: usize| {
            let mut body = vec![index];
            body.extend_from_slice(&vec![1; len]);
            raw(4, u16::try_from(body.len()).expect("fits"), &body)
        };
        assert!(decode(&chunk(0, 492)).is_some());
        assert!(decode(&chunk(1, 492)).is_some());
        assert!(decode(&chunk(2, 40)).is_some());
        assert!(decode(&chunk(0, 491)).is_none());
        assert!(decode(&chunk(0, 40)).is_none());
        assert!(decode(&chunk(2, 41)).is_none());
        assert!(decode(&chunk(2, 492)).is_none());
        assert!(decode(&chunk(3, 40)).is_none());
        assert!(decode(&chunk(u8::MAX, 40)).is_none());
        assert!(decode(&raw(4, 0, &[])).is_none());
        assert!(decode(&raw(4, 1, &[0])).is_none());

        assert!(pkt(&packet(1), 3, size()).is_none());
    }

    /// Whatever the frame size, the chunks in index order are the packet.
    #[test]
    fn the_chunks_of_every_frame_size_rebuild_the_packet() {
        let packet = packet(2);
        for max_frame in MIN_FRAME_LEN..=MAX_FRAME_LEN {
            let size = FrameSize::of_link(max_frame).expect("within bounds");
            let mut rebuilt = Vec::with_capacity(PACKET_LEN);
            for index in 0..size.chunk_count() {
                let index = u8::try_from(index).expect("at most 256 chunks");
                let plaintext = pkt(&packet, index, size).expect("a chunk of the packet");
                assert_eq!(plaintext.len(), size.plaintext_len());
                let Some(Frame::Pkt { index: read, chunk }) = decode(&plaintext) else {
                    panic!("an encoded chunk did not decode");
                };
                assert_eq!(read, index);
                rebuilt.extend_from_slice(chunk);
            }
            assert_eq!(rebuilt[..], packet.as_bytes()[..]);
            let past = u8::try_from(size.chunk_count());
            assert!(past.is_ok_and(|past| pkt(&packet, past, size).is_none()));
        }
    }

    fn size_of(max_frame: usize) -> FrameSize {
        FrameSize::of_link(max_frame).expect("within bounds")
    }

    proptest! {
        /// T-SEC-3. No bytes make `decode` panic, and whatever it accepts is
        /// the one encoding of what it returns: nothing rides in a frame
        /// beside its fields.
        #[test]
        fn prop_whatever_decodes_reencodes_to_the_same_bytes(
            max_frame in MIN_FRAME_LEN..=MAX_FRAME_LEN,
            kind in 0u8..8,
            // Lengths a body can have, and ones none has.
            len in prop_oneof![
                Just(0usize),
                Just(8),
                (1usize..250).prop_map(|n| n * 17),
                (1usize..260).prop_map(|n| n * 16),
                (1usize..=1025),
                (0usize..5000),
            ],
            first in any::<u8>(),
            fill in 1u8..=255,
            dirty in proptest::option::of(any::<proptest::sample::Index>()),
        ) {
            let size = size_of(max_frame);
            let mut plaintext = vec![0; size.plaintext_len()];
            plaintext[0] = kind;
            plaintext[1..3].copy_from_slice(&u16::try_from(len).expect("fits").to_be_bytes());
            let body_end = (3 + len).min(plaintext.len());
            plaintext[3..body_end].fill(fill);
            if len > 0 && body_end > 3 {
                plaintext[3] = first;
            }
            if let Some(dirty) = dirty {
                let at = dirty.index(plaintext.len());
                plaintext[at] = plaintext[at].wrapping_add(1);
            }
            let Some(frame) = decode(&plaintext) else { return Ok(()) };
            let again = match frame {
                Frame::Hello(value) => hello(&value, size),
                Frame::Have(entries) => have(&entries.iter().collect::<Vec<_>>(), size),
                Frame::Want(ids) => want(&ids.iter().collect::<Vec<_>>(), size),
                Frame::Pkt { index, chunk } => {
                    let range = size.chunk_range(index).expect("a decoded index is in range");
                    let mut bytes = [0; PACKET_LEN];
                    bytes[range].copy_from_slice(chunk);
                    pkt(&Packet::from_bytes(bytes), index, size)
                }
                Frame::Bye => bye(size),
            };
            prop_assert_eq!(again, Some(plaintext));
        }

        #[test]
        fn prop_arbitrary_bytes_never_panic(
            bytes in proptest::collection::vec(any::<u8>(), 0..5000),
        ) {
            let _ = decode(&bytes);
        }

        #[test]
        fn prop_a_have_round_trips(
            max_frame in MIN_FRAME_LEN..=MAX_FRAME_LEN,
            entries in proptest::collection::vec((any::<[u8; 16]>(), 1u8..=255), 1..300),
        ) {
            let size = size_of(max_frame);
            let entries: Vec<_> = entries.into_iter().map(|(id, r)| (PacketId(id), r)).collect();
            let encoded = have(&entries, size);
            prop_assert_eq!(encoded.is_some(), entries.len() <= size.have_capacity());
            if let Some(plaintext) = encoded {
                prop_assert_eq!(plaintext.len(), size.plaintext_len());
                prop_assert!(entries_of(decode(&plaintext)) == Some(entries));
            }
        }

        #[test]
        fn prop_a_want_round_trips(
            max_frame in MIN_FRAME_LEN..=MAX_FRAME_LEN,
            ids in proptest::collection::vec(any::<[u8; 16]>(), 1..300),
        ) {
            let size = size_of(max_frame);
            let ids: Vec<_> = ids.into_iter().map(PacketId).collect();
            let encoded = want(&ids, size);
            prop_assert_eq!(encoded.is_some(), ids.len() <= size.want_capacity());
            if let Some(plaintext) = encoded {
                prop_assert_eq!(plaintext.len(), size.plaintext_len());
                prop_assert!(ids_of(decode(&plaintext)) == Some(ids));
            }
        }

        #[test]
        fn prop_a_hello_and_a_bye_round_trip(
            max_frame in MIN_FRAME_LEN..=MAX_FRAME_LEN,
            value in any::<[u8; 8]>(),
        ) {
            let size = size_of(max_frame);
            let plaintext = hello(&value, size).expect("a hello fits every link");
            prop_assert_eq!(plaintext.len(), size.plaintext_len());
            prop_assert!(decode(&plaintext) == Some(Frame::Hello(value)));
            let plaintext = bye(size).expect("a bye fits every link");
            prop_assert_eq!(plaintext.len(), size.plaintext_len());
            prop_assert!(decode(&plaintext) == Some(Frame::Bye));
        }
    }
}
