//! `Noise_NN_25519_ChaChaPoly_SHA256` for one mesh link (plan §6.7), written
//! for this one pattern from the Noise specification, revision 34; a bare `§`
//! below cites that specification.
//!
//! ```text
//! -> e          32 bytes   the initiator: the BLE central
//! <- e, ee      48 bytes   the responder; 16 are the tag over an empty payload
//! ```
//!
//! The prologue is `"haven/mesh/link"` and [`LINK_VERSION`], so two phones on
//! different versions fail the handshake rather than negotiate one. After it a
//! [`Transport`] seals every link frame under its direction's key and a counter
//! nonce.
//!
//! Both sides are anonymous. The link hides its traffic from a listener that
//! does not connect and authenticates nobody: a peer that connects, or sits in
//! the middle, reads everything a neighbour reads.
//!
//! Any `None` from this module ends the link; nothing here is retried. No
//! type here is `Debug`: each holds key material (Security Rule 6).

use chacha20poly1305::aead::{Aead, Payload};
use chacha20poly1305::{ChaCha20Poly1305, KeyInit, Nonce};
use hkdf::Hkdf;
use rand::{CryptoRng, RngCore};
use sha2::{Digest, Sha256};
use x25519_dalek::{EphemeralSecret, PublicKey};
use zeroize::Zeroizing;

/// The link protocol version, the prologue's last byte.
pub const LINK_VERSION: u8 = 1;

/// Length of the initiator's handshake message.
pub const HELLO_LEN: usize = 32;

/// Length of the responder's handshake message.
pub const REPLY_LEN: usize = 48;

/// What sealing adds to a frame.
pub const TAG_LEN: usize = 16;

/// The longest plaintext one frame carries, checked before any work.
pub const MAX_PLAINTEXT_LEN: usize = 4096;

/// Exactly `HASHLEN` bytes, so it is the initial `h` as it stands (§5.2).
const PROTOCOL_NAME: [u8; 32] = *b"Noise_NN_25519_ChaChaPoly_SHA256";

const PROLOGUE: [u8; 16] = {
    let mut prologue = *b"haven/mesh/link\0";
    prologue[15] = LINK_VERSION;
    prologue
};

/// `HKDF(chaining_key, input_key_material, 2)` of §4.3: RFC 5869 with the
/// chaining key as salt and no info.
fn hkdf2(chaining_key: &[u8; 32], ikm: &[u8]) -> [Zeroizing<[u8; 32]>; 2] {
    let mut okm = Zeroizing::new([0; 64]);
    Hkdf::<Sha256>::new(Some(chaining_key), ikm)
        .expand(&[], &mut okm[..])
        .expect("64 bytes is a valid HKDF-SHA256 output length");
    let mut outputs = [Zeroizing::new([0; 32]), Zeroizing::new([0; 32])];
    outputs[0].copy_from_slice(&okm[..32]);
    outputs[1].copy_from_slice(&okm[32..]);
    outputs
}

/// §12.3: 32 zero bits, then the counter little-endian.
fn nonce(n: u64) -> Nonce {
    let mut bytes = [0; 12];
    bytes[4..].copy_from_slice(&n.to_le_bytes());
    bytes.into()
}

fn encrypt(key: &[u8; 32], n: u64, ad: &[u8], plaintext: &[u8]) -> Option<Vec<u8>> {
    let payload = Payload {
        msg: plaintext,
        aad: ad,
    };
    ChaCha20Poly1305::new(key.into())
        .encrypt(&nonce(n), payload)
        .ok()
}

fn decrypt(key: &[u8; 32], n: u64, ad: &[u8], ciphertext: &[u8]) -> Option<Vec<u8>> {
    let payload = Payload {
        msg: ciphertext,
        aad: ad,
    };
    ChaCha20Poly1305::new(key.into())
        .decrypt(&nonce(n), payload)
        .ok()
}

/// The `SymmetricState` of §5.2 without its cipher: NN encrypts one handshake
/// payload, so [`Self::mix_dh`] hands that key straight to its one use.
struct Symmetric {
    ck: Zeroizing<[u8; 32]>,
    h: [u8; 32],
}

impl Symmetric {
    fn new(prologue: &[u8]) -> Self {
        let mut symmetric = Self {
            ck: Zeroizing::new(PROTOCOL_NAME),
            h: PROTOCOL_NAME,
        };
        symmetric.mix_hash(prologue);
        symmetric
    }

    fn mix_hash(&mut self, data: &[u8]) {
        self.h = Sha256::new()
            .chain_update(self.h)
            .chain_update(data)
            .finalize()
            .into();
    }

    /// The `ee` token: `MixKey(DH(e, re))`, returning the handshake cipher key.
    fn mix_dh(&mut self, e: EphemeralSecret, re: [u8; 32]) -> Option<Zeroizing<[u8; 32]>> {
        let shared = e.diffie_hellman(&PublicKey::from(re));
        // An all-zero output is a low-order point: a secret the peer dictated,
        // which anyone can compute. §12.1 allows signalling it as an error.
        if !shared.was_contributory() {
            return None;
        }
        let [ck, k] = hkdf2(&self.ck, shared.as_bytes());
        self.ck = ck;
        Some(k)
    }

    /// `Split` (§5.2): the first key seals what the initiator sends. Also
    /// returns the handshake hash.
    fn split(self, initiator: bool) -> (Transport, [u8; 32]) {
        let [first, second] = hkdf2(&self.ck, &[]);
        let (send, recv) = if initiator {
            (first, second)
        } else {
            (second, first)
        };
        let transport = Transport {
            send: CipherState { key: send, n: 0 },
            recv: CipherState { key: recv, n: 0 },
        };
        (transport, self.h)
    }
}

/// One direction's `CipherState` (§5.1).
struct CipherState {
    key: Zeroizing<[u8; 32]>,
    n: u64,
}

impl CipherState {
    /// The nonce for the next frame. 2^64 − 1 is reserved (§5.1): a state that
    /// reaches it seals and opens nothing more.
    fn next_nonce(&self) -> Option<u64> {
        (self.n != u64::MAX).then_some(self.n)
    }
}

/// An initiator that has sent its handshake message and awaits the reply.
pub struct Initiator {
    e: EphemeralSecret,
    symmetric: Symmetric,
}

impl Initiator {
    /// Starts a link from the connecting side. Returns the state to keep and
    /// the [`HELLO_LEN`] bytes to send.
    #[must_use]
    pub fn start<R: RngCore + CryptoRng>(rng: &mut R) -> (Self, [u8; HELLO_LEN]) {
        Self::write_hello(&PROLOGUE, &[], rng)
    }

    /// Finishes the handshake with the responder's [`REPLY_LEN`] bytes.
    ///
    /// `None` for any other length, a low-order key, or a tag that does not
    /// verify — which is also what another [`LINK_VERSION`] looks like.
    #[must_use]
    pub fn finish(self, reply: &[u8]) -> Option<Transport> {
        if reply.len() != REPLY_LEN {
            return None;
        }
        let (_empty, transport, _hash) = self.read_reply(reply)?;
        Some(transport)
    }

    /// `-> e`. The message on the wire is the returned key followed by
    /// `payload`, which no key protects yet and is only hashed.
    fn write_hello<R: RngCore + CryptoRng>(
        prologue: &[u8],
        payload: &[u8],
        rng: &mut R,
    ) -> (Self, [u8; 32]) {
        let mut symmetric = Symmetric::new(prologue);
        let e = EphemeralSecret::random_from_rng(&mut *rng);
        let public = PublicKey::from(&e).to_bytes();
        symmetric.mix_hash(&public);
        symmetric.mix_hash(payload);
        (Self { e, symmetric }, public)
    }

    /// Reads `<- e, ee`: the payload, the transport and the handshake hash.
    fn read_reply(self, reply: &[u8]) -> Option<(Vec<u8>, Transport, [u8; 32])> {
        let Self { e, mut symmetric } = self;
        let (re, ciphertext) = reply.split_first_chunk()?;
        symmetric.mix_hash(re);
        let k = symmetric.mix_dh(e, *re)?;
        let payload = decrypt(&k, 0, &symmetric.h, ciphertext)?;
        symmetric.mix_hash(ciphertext);
        let (transport, hash) = symmetric.split(true);
        Some((payload, transport, hash))
    }
}

/// Answers an initiator's [`HELLO_LEN`] bytes. Returns the transport and the
/// [`REPLY_LEN`] bytes to send.
///
/// `None` for any other length or a low-order key. A responder cannot tell an
/// initiator on another [`LINK_VERSION`]: that initiator fails on the reply.
#[must_use]
pub fn respond<R: RngCore + CryptoRng>(
    hello: &[u8],
    rng: &mut R,
) -> Option<(Transport, [u8; REPLY_LEN])> {
    if hello.len() != HELLO_LEN {
        return None;
    }
    let (reply, transport, _hash) = write_reply(&PROLOGUE, hello, &[], rng)?;
    Some((transport, reply.try_into().ok()?))
}

/// Reads `-> e` and writes `<- e, ee` carrying `payload`: the message, the
/// transport and the handshake hash.
fn write_reply<R: RngCore + CryptoRng>(
    prologue: &[u8],
    hello: &[u8],
    payload: &[u8],
    rng: &mut R,
) -> Option<(Vec<u8>, Transport, [u8; 32])> {
    let (re, hello_payload) = hello.split_first_chunk()?;
    let mut symmetric = Symmetric::new(prologue);
    symmetric.mix_hash(re);
    symmetric.mix_hash(hello_payload);

    let e = EphemeralSecret::random_from_rng(&mut *rng);
    let mut reply = PublicKey::from(&e).as_bytes().to_vec();
    symmetric.mix_hash(&reply);
    let k = symmetric.mix_dh(e, *re)?;
    let ciphertext = encrypt(&k, 0, &symmetric.h, payload)?;
    symmetric.mix_hash(&ciphertext);
    reply.extend_from_slice(&ciphertext);

    let (transport, hash) = symmetric.split(false);
    Some((reply, transport, hash))
}

/// An established link: seals what this side sends and opens what the peer
/// sent, each direction under its own key and counter.
///
/// Frames must arrive in the order they were sealed. There is no replay
/// window: a replayed, reordered, dropped or altered frame fails to open, and
/// the caller closes the link.
pub struct Transport {
    send: CipherState,
    recv: CipherState,
}

impl Transport {
    /// Seals one frame: `plaintext.len()` + [`TAG_LEN`] bytes.
    ///
    /// `None` when the plaintext is longer than [`MAX_PLAINTEXT_LEN`] or the
    /// counter is exhausted.
    #[must_use]
    pub fn seal(&mut self, plaintext: &[u8]) -> Option<Vec<u8>> {
        if plaintext.len() > MAX_PLAINTEXT_LEN {
            return None;
        }
        let n = self.send.next_nonce()?;
        let ciphertext = encrypt(&self.send.key, n, &[], plaintext)?;
        self.send.n = n + 1;
        Some(ciphertext)
    }

    /// Opens the peer's next frame.
    ///
    /// `None` when the frame is longer than a sealed [`MAX_PLAINTEXT_LEN`],
    /// does not verify as the next frame in order, or the counter is
    /// exhausted.
    #[must_use]
    pub fn open(&mut self, ciphertext: &[u8]) -> Option<Vec<u8>> {
        if ciphertext.len() > MAX_PLAINTEXT_LEN + TAG_LEN {
            return None;
        }
        let n = self.recv.next_nonce()?;
        let plaintext = decrypt(&self.recv.key, n, &[], ciphertext)?;
        // Only a frame that verified moves the counter: a forged one must not
        // desynchronise the link or burn a nonce (§5.1, RUSTSEC-2024-0011).
        self.recv.n = n + 1;
        Some(plaintext)
    }
}

#[cfg(test)]
mod tests {
    use rand::rngs::StdRng;
    use rand::SeedableRng;
    use x25519_dalek::SharedSecret;
    use zeroize::Zeroize;

    use super::*;
    use crate::mesh::test_rng::Scripted;

    fn unhex(hex: &str) -> Vec<u8> {
        hex::decode(hex).expect("hex")
    }

    fn rng(seed: u64) -> StdRng {
        StdRng::seed_from_u64(seed)
    }

    /// A finished handshake over the public API: (initiator, responder).
    fn link() -> (Transport, Transport) {
        let (initiator, hello) = Initiator::start(&mut rng(1));
        let (responder, reply) = respond(&hello, &mut rng(2)).expect("a valid hello");
        (initiator.finish(&reply).expect("a valid reply"), responder)
    }

    /// One public test vector: the ephemeral private keys, the prologue, and
    /// each message's payload and expected bytes — two handshake messages,
    /// then transport messages alternating from the initiator.
    struct Vector {
        prologue: &'static str,
        init_ephemeral: &'static str,
        resp_ephemeral: &'static str,
        handshake_hash: Option<&'static str>,
        messages: &'static [(&'static str, &'static str)],
    }

    /// Runs the handshake and transport on the vector's own prologue, keys and
    /// payloads, and holds every byte either side emits to the vector's.
    fn assert_matches(vector: &Vector) {
        let prologue = unhex(vector.prologue);
        let mut init_rng = Scripted::new(&unhex(vector.init_ephemeral));
        let mut resp_rng = Scripted::new(&unhex(vector.resp_ephemeral));
        let payload = |i: usize| unhex(vector.messages[i].0);
        let expected = |i: usize| unhex(vector.messages[i].1);

        let (initiator, e) = Initiator::write_hello(&prologue, &payload(0), &mut init_rng);
        let hello = [&e[..], &payload(0)[..]].concat();
        assert_eq!(hello, expected(0));

        let (reply, mut responder, responder_hash) =
            write_reply(&prologue, &hello, &payload(1), &mut resp_rng).expect("a valid hello");
        assert_eq!(reply, expected(1));

        let (reply_payload, mut initiator, initiator_hash) =
            initiator.read_reply(&reply).expect("a valid reply");
        assert_eq!(reply_payload, payload(1));
        assert_eq!(initiator_hash, responder_hash);
        if let Some(hash) = vector.handshake_hash {
            assert_eq!(initiator_hash[..], unhex(hash)[..]);
        }
        assert!(init_rng.is_spent() && resp_rng.is_spent());

        for i in 2..vector.messages.len() {
            let (sender, receiver) = if i % 2 == 0 {
                (&mut initiator, &mut responder)
            } else {
                (&mut responder, &mut initiator)
            };
            let sealed = sender.seal(&payload(i)).expect("within bounds");
            assert_eq!(sealed, expected(i));
            assert_eq!(receiver.open(&sealed), Some(payload(i)));
        }
    }

    /// T-PRIV-8. `Noise_NN_25519_ChaChaPoly_SHA256` from cacophony's vectors:
    /// `vectors/cacophony.txt` of haskell-cryptography/cacophony, byte-identical
    /// to `tests/vectors/cacophony.txt` of mcginty/snow.
    #[test]
    fn the_handshake_and_transport_match_the_cacophony_vector() {
        assert_matches(&Vector {
            prologue: "4a6f686e2047616c74",
            init_ephemeral: "893e28b9dc6ca8d611ab664754b8ceb7bac5117349a4439a6b0569da977c464a",
            resp_ephemeral: "bbdb4cdbd309f1a1f2e1456967fe288cadd6f712d65dc7b7793d5e63da6b375b",
            handshake_hash: Some(
                "9223fec1b892ec9d0dc2fb3bbeb261f170d1ea679f9c44ccf34aa131b4f5d97e",
            ),
            messages: &[
                (
                    "4c756477696720766f6e204d69736573",
                    "ca35def5ae56cec33dc2036731ab14896bc4c75dbb07a61f879f8e3afa4c7944\
                     4c756477696720766f6e204d69736573",
                ),
                (
                    "4d757272617920526f746862617264",
                    "95ebc60d2b1fa672c1f46a8aa265ef51bfe38e7ccb39ec5be34069f144808843\
                     a0ff96bdf86b579ef7dbf94e812a7470b903c20a85a87e3a1fe863264ae547",
                ),
                (
                    "462e20412e20486179656b",
                    "eb1a3e3d80c1792b1bb9cb0e1382f8d8322bfb1ca7c4c8517bb686",
                ),
                (
                    "4361726c204d656e676572",
                    "c781b198d2a974eb1da2c7d518c000cf6396de87ca540963c03713",
                ),
                (
                    "4a65616e2d426170746973746520536179",
                    "c77048eb6919fdfe8fe45842bfc5b8d1ff50d1e20c717453ccdfe6176d805b996d",
                ),
                (
                    "457567656e2042f6686d20766f6e2042617765726b",
                    "61834d7069dcfb7a1adf8d5ac910f83fa04c73a67789895c6f5f995c5db2ce88e49b124178",
                ),
            ],
        });
    }

    /// T-PRIV-8. `Noise_NN_25519_ChaChaPoly_SHA256` from snow's own vectors,
    /// `tests/vectors/snow.txt` of mcginty/snow. It carries no handshake hash.
    #[test]
    fn the_handshake_and_transport_match_the_snow_vector() {
        assert_matches(&Vector {
            prologue: "5468657265206973206e6f20726967687420616e642077726f6e672e20546865\
                       72652773206f6e6c792066756e20616e6420626f72696e672e",
            init_ephemeral: "ba743ce40b65ad7ec0700dc2e57de4791022a8f42cd46517c6689c5c812b3b36",
            resp_ephemeral: "d5cb9c3d9df2b6263f292f59099680ab2b523cf02b43a4c534b1fa94f9a80ed8",
            handshake_hash: None,
            messages: &[
                (
                    "d369dc8436b80ad2936b4179ef262a0d174c06e3d452de5f22a7ca0326baaac7",
                    "479a148ee78e18278f7716338574086a12bf8d90cc54c6c88ae6a4275dbd1478\
                     d369dc8436b80ad2936b4179ef262a0d174c06e3d452de5f22a7ca0326baaac7",
                ),
                (
                    "87f4ce9acdcfe73e88f0d2b7e8b6009f07c5a42b3412909c1b7ce407a763ebd1",
                    "5f1bc611a449717c2fc7c33a0f3976beae914c336d2a761c2f6e1ee2ab721f7c\
                     166608582f25b34bf5ebe478049971b64e5982d8b546b1cfa58fae828b7c8137\
                     562fdec5808f41fadeeee43013019277",
                ),
                (
                    "bdc326451b8af9b6b82a2054643878d9eeaea4845c6b1e9ba616b2723c2ef272",
                    "15f337bd32ddb96a17765a9499a4eb24b757d59c78d5366fdd56a2eab7eed11a\
                     0b6d4ed2947c0bf83d9d625ab90ee60b",
                ),
                (
                    "a783aa12cefa403d1dff9d6ac924f860a15d1ba21c2c4976f8fa88d76e590fef",
                    "6b676682c308c230a602d1997ff9e94b815dbc497346a4144fc4290021a2dbfc\
                     bee618798a8eb5042562a637927d4e98",
                ),
            ],
        });
    }

    #[test]
    fn two_phones_shake_hands_and_exchange_frames_both_ways() {
        let (mut initiator, mut responder) = link();
        for round in 0..3u8 {
            let out = initiator.seal(&[round; 40]).expect("within bounds");
            assert_eq!(responder.open(&out), Some(vec![round; 40]));
            let back = responder.seal(&[round, 0xee]).expect("within bounds");
            assert_eq!(initiator.open(&back), Some(vec![round, 0xee]));
        }
    }

    #[test]
    fn the_public_handshake_is_the_haven_prologue_with_empty_payloads() {
        let prologue = b"haven/mesh/link\x01";

        let (initiator, e) = Initiator::write_hello(prologue, &[], &mut rng(1));
        let (mut responder, reply) = respond(&e, &mut rng(2)).expect("a valid hello");
        let (payload, mut initiator, _) = initiator.read_reply(&reply).expect("a valid reply");
        assert!(payload.is_empty());
        let sealed = initiator.seal(b"ping").expect("within bounds");
        assert_eq!(responder.open(&sealed), Some(b"ping".to_vec()));

        let (initiator, hello) = Initiator::start(&mut rng(1));
        let (reply, _, _) = write_reply(prologue, &hello, &[], &mut rng(2)).expect("a valid hello");
        assert!(initiator.finish(&reply).is_some());
    }

    #[test]
    fn another_version_byte_fails_the_handshake_at_the_reply() {
        let other = b"haven/mesh/link\x02";

        let (initiator, e) = Initiator::write_hello(other, &[], &mut rng(1));
        let (_, reply) = respond(&e, &mut rng(2)).expect("a responder cannot tell");
        assert!(initiator.read_reply(&reply).is_none());

        let (initiator, hello) = Initiator::start(&mut rng(1));
        let (reply, _, _) = write_reply(other, &hello, &[], &mut rng(2)).expect("a valid hello");
        assert_eq!(reply.len(), REPLY_LEN);
        assert!(initiator.finish(&reply).is_none());
    }

    #[test]
    fn a_handshake_message_of_any_other_length_is_refused() {
        let (_, hello) = Initiator::start(&mut rng(1));
        let (_, reply) = respond(&hello, &mut rng(2)).expect("a valid hello");

        assert!(respond(&hello[..HELLO_LEN - 1], &mut rng(2)).is_none());
        assert!(respond(&[&hello[..], &[0][..]].concat(), &mut rng(2)).is_none());
        assert!(respond(&[], &mut rng(2)).is_none());

        for wrong in [
            reply[..REPLY_LEN - 1].to_vec(),
            [&reply[..], &[0][..]].concat(),
            reply[..HELLO_LEN].to_vec(),
            Vec::new(),
        ] {
            let (initiator, _) = Initiator::start(&mut rng(1));
            assert!(initiator.finish(&wrong).is_none());
        }
        // A longer reply whose tag verifies — the same handshake carrying a
        // payload — so only the length refuses it.
        let (initiator, _) = Initiator::start(&mut rng(1));
        let (carrying, _, _) =
            write_reply(&PROLOGUE, &hello, b"x", &mut rng(2)).expect("a valid hello");
        assert_eq!(carrying.len(), REPLY_LEN + 1);
        assert!(initiator.finish(&carrying).is_none());

        let (initiator, _) = Initiator::start(&mut rng(1));
        assert!(initiator.finish(&reply).is_some());
    }

    #[test]
    fn every_single_bit_flip_of_the_reply_fails_the_handshake() {
        let (_, hello) = Initiator::start(&mut rng(1));
        let (_, reply) = respond(&hello, &mut rng(2)).expect("a valid hello");
        for bit in 0..REPLY_LEN * 8 {
            let mut altered = reply;
            altered[bit / 8] ^= 1 << (bit % 8);
            let (initiator, _) = Initiator::start(&mut rng(1));
            assert!(
                initiator.finish(&altered).is_none(),
                "an altered reply finished the handshake"
            );
        }
    }

    #[test]
    fn a_hello_altered_in_transit_fails_the_handshake_at_the_reply() {
        let (initiator, mut hello) = Initiator::start(&mut rng(1));
        hello[0] ^= 1;
        let (_, reply) = respond(&hello, &mut rng(2)).expect("still a key");
        assert!(initiator.finish(&reply).is_none());
    }

    /// The points whose X25519 output is all zeros whatever the scalar.
    const LOW_ORDER: [&str; 3] = [
        "0000000000000000000000000000000000000000000000000000000000000000",
        "0100000000000000000000000000000000000000000000000000000000000000",
        "e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800",
    ];

    #[test]
    fn a_responder_refuses_a_low_order_key() {
        for point in LOW_ORDER {
            assert!(respond(&unhex(point), &mut rng(2)).is_none());
        }
    }

    /// The reply here is one the initiator would accept without the check: its
    /// tag is computed, as anyone can, from the all-zero DH output.
    #[test]
    fn an_initiator_refuses_a_low_order_key_even_under_a_valid_tag() {
        for point in LOW_ORDER {
            let (initiator, hello) = Initiator::start(&mut rng(1));
            let point = unhex(point);

            let mut symmetric = Symmetric::new(&PROLOGUE);
            symmetric.mix_hash(&hello);
            symmetric.mix_hash(&[]);
            symmetric.mix_hash(&point);
            let [_, k] = hkdf2(&symmetric.ck, &[0; 32]);
            let tag = encrypt(&k, 0, &symmetric.h, &[]).expect("an empty payload");
            let reply = [point, tag].concat();

            assert_eq!(reply.len(), REPLY_LEN);
            assert!(initiator.finish(&reply).is_none());
        }
    }

    #[test]
    fn every_single_bit_flip_of_a_frame_fails_to_open_and_the_frame_still_opens() {
        let (mut initiator, mut responder) = link();
        let sealed = initiator.seal(b"location frame").expect("within bounds");
        for bit in 0..sealed.len() * 8 {
            let mut altered = sealed.clone();
            altered[bit / 8] ^= 1 << (bit % 8);
            assert!(
                responder.open(&altered).is_none(),
                "an altered frame opened"
            );
        }
        assert!(responder.open(&sealed[..sealed.len() - 1]).is_none());
        assert!(responder.open(&sealed[..TAG_LEN - 1]).is_none());
        assert!(responder.open(&[]).is_none());
        assert_eq!(responder.open(&sealed), Some(b"location frame".to_vec()));
    }

    #[test]
    fn a_replayed_frame_fails_to_open() {
        let (mut initiator, mut responder) = link();
        let first = initiator.seal(b"one").expect("within bounds");
        assert!(responder.open(&first).is_some());
        assert!(responder.open(&first).is_none());

        let second = initiator.seal(b"two").expect("within bounds");
        assert_eq!(responder.open(&second), Some(b"two".to_vec()));
    }

    /// A frame out of order is what the receiver sees after a drop as well: the
    /// frame that follows the missing one.
    #[test]
    fn a_reordered_or_dropped_frame_fails_to_open_and_does_not_move_the_counter() {
        let (mut initiator, mut responder) = link();
        let first = initiator.seal(b"one").expect("within bounds");
        let second = initiator.seal(b"two").expect("within bounds");
        let third = initiator.seal(b"three").expect("within bounds");

        assert!(responder.open(&second).is_none());
        assert!(responder.open(&third).is_none());
        assert_eq!(responder.open(&first), Some(b"one".to_vec()));
        assert!(responder.open(&third).is_none());
        assert_eq!(responder.open(&second), Some(b"two".to_vec()));
        assert_eq!(responder.open(&third), Some(b"three".to_vec()));
    }

    #[test]
    fn a_frame_does_not_open_on_the_side_that_sealed_it() {
        let (mut initiator, mut responder) = link();
        let sealed = initiator.seal(b"mine").expect("within bounds");
        assert!(initiator.open(&sealed).is_none());
        assert!(responder.open(&sealed).is_some());
    }

    #[test]
    fn a_sealed_frame_shows_no_plaintext() {
        let (mut initiator, mut responder) = link();
        let plaintext = [0xa5; 64];
        let first = initiator.seal(&plaintext).expect("within bounds");
        let again = initiator.seal(&plaintext).expect("within bounds");
        let back = responder.seal(&plaintext).expect("within bounds");

        for sealed in [&first, &again, &back] {
            assert_eq!(sealed.len(), plaintext.len() + TAG_LEN);
            assert!(!sealed.windows(4).any(|window| window == [0xa5; 4]));
        }
        assert!(first != again && first != back);
    }

    #[test]
    fn a_frame_past_the_size_bound_is_refused_without_using_a_nonce() {
        let (mut initiator, mut responder) = link();
        assert!(initiator.seal(&[0; MAX_PLAINTEXT_LEN + 1]).is_none());
        // Sealed exactly as the sender's next frame would be, so only the
        // bound refuses it.
        let oversized = encrypt(&initiator.send.key, 0, &[], &[0; MAX_PLAINTEXT_LEN + 1])
            .expect("an AEAD call");
        assert!(responder.open(&oversized).is_none());

        let largest = initiator
            .seal(&[7; MAX_PLAINTEXT_LEN])
            .expect("at the bound");
        assert_eq!(largest.len(), MAX_PLAINTEXT_LEN + TAG_LEN);
        assert_eq!(responder.open(&largest), Some(vec![7; MAX_PLAINTEXT_LEN]));
        let empty = initiator.seal(&[]).expect("within bounds");
        assert_eq!(responder.open(&empty), Some(Vec::new()));
    }

    #[test]
    fn the_reserved_last_nonce_is_never_used() {
        let (mut initiator, mut responder) = link();
        initiator.send.n = u64::MAX - 1;
        responder.recv.n = u64::MAX - 1;

        let last = initiator.seal(b"last").expect("the last usable nonce");
        assert!(initiator.seal(b"past").is_none());
        assert_eq!(responder.open(&last), Some(b"last".to_vec()));

        // What the sender would have sealed next, had it not refused.
        let past = encrypt(&initiator.send.key, u64::MAX, &[], b"past").expect("an AEAD call");
        assert!(responder.open(&past).is_none());
        assert_eq!(responder.recv.n, u64::MAX);
    }

    #[test]
    fn two_links_share_no_keys() {
        let (mut initiator, _) = link();
        let (other_initiator, hello) = Initiator::start(&mut rng(3));
        let (mut other_responder, reply) = respond(&hello, &mut rng(4)).expect("a valid hello");
        assert!(other_initiator.finish(&reply).is_some());

        let sealed = initiator.seal(b"for my link").expect("within bounds");
        assert!(other_responder.open(&sealed).is_none());
    }

    #[test]
    fn every_secret_the_link_holds_wipes_itself_on_drop() {
        const fn assert_zeroize<T: Zeroize>() {}
        // x25519-dalek derives `Zeroize`, and the drop that calls it, only
        // under its `zeroize` feature: losing the feature fails this build.
        assert_zeroize::<EphemeralSecret>();
        assert_zeroize::<SharedSecret>();

        let (initiator, hello) = Initiator::start(&mut rng(1));
        let _: &EphemeralSecret = &initiator.e;
        let _: &Zeroizing<[u8; 32]> = &initiator.symmetric.ck;
        let (transport, _) = respond(&hello, &mut rng(2)).expect("a valid hello");
        let _: &Zeroizing<[u8; 32]> = &transport.send.key;
        let _: &Zeroizing<[u8; 32]> = &transport.recv.key;
    }
}
