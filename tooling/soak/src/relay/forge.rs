//! The WebSocket frames the proxy reads, forwards and forges.
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

use std::borrow::Cow;

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
}
