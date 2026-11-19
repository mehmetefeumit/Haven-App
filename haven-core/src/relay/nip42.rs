//! The identity key's one relay-facing use: answering a NIP-42 challenge.
//!
//! Owner-directed (2026-11-16): Haven authenticates where White Noise does —
//! its own inbox reads, and a Welcome or kind-445 send a relay refused with
//! `auth-required:`. The pool signs its AUTH answer with whatever signer the
//! client holds, so the signer IS the scope: this one signs a kind-22242 event
//! with empty content and exactly the `challenge` and `relay` tags
//! `EventBuilder::auth` builds, under the identity key, and refuses every other
//! event and every encryption. A client holding it cannot be made to sign a
//! profile, a relay list, a gift wrap or a commit, whatever code reaches it.
//!
//! Like `HavenIdentityProofSigner`, it keeps the 32 secret bytes in a
//! [`Zeroizing`] buffer, rebuilds the event it signs instead of trusting the one
//! it is handed, and rebuilds the [`Keys`] for each signature only.

use std::borrow::Cow;

use nostr::signer::SignerBackend;
use nostr::util::BoxedFuture;
use nostr::{
    Event, EventBuilder, Keys, Kind, NostrSigner, PublicKey, RelayUrl, SecretKey, SignerError,
    UnsignedEvent,
};
use zeroize::{ZeroizeOnDrop, Zeroizing};

/// The one refusal, fixed text: it names no challenge, relay or key, so it can
/// reach a log or an error string as it is (Security Rule 15).
const REFUSED: &str = "the NIP-42 signer signs only a NIP-42 authentication event";

/// Signs the identity key's answer to a relay's NIP-42 challenge, and nothing
/// else.
///
/// Built by `CircleManager::new` from the session's identity keys and handed
/// out as `CircleManager::nip42_signer()`; only `relay::verified::identity_client`
/// installs it on a relay client (`check_engine_client_options.sh` check 11).
#[derive(ZeroizeOnDrop)]
pub struct Nip42Signer {
    /// The identity public key: every answer is signed under it, and an event
    /// naming another author is refused.
    #[zeroize(skip)]
    public_key: PublicKey,
    secret: Zeroizing<[u8; 32]>,
}

impl Nip42Signer {
    /// Copies the key material out of `keys`; the reference is not kept.
    pub(crate) fn new(keys: &Keys) -> Self {
        Self {
            public_key: keys.public_key(),
            secret: Zeroizing::new(keys.secret_key().to_secret_bytes()),
        }
    }

    /// The identity public key every answer is signed under.
    #[must_use]
    pub const fn public_key(&self) -> PublicKey {
        self.public_key
    }

    /// `unsigned`, signed, when it is exactly an answer to a challenge.
    ///
    /// The event signed is rebuilt here by `EventBuilder::auth` from the
    /// challenge and relay read off `unsigned`, and must spell the same tags:
    /// a tag with an extra element, a third tag, the two in the other order or
    /// a relay the URL parser would respell are all refused, and any id the
    /// caller set is never what is signed.
    fn sign_auth(&self, unsigned: &UnsignedEvent) -> Result<Event, SignerError> {
        if unsigned.kind != Kind::Authentication
            || !unsigned.content.is_empty()
            || unsigned.pubkey != self.public_key
        {
            return Err(SignerError::from(REFUSED));
        }
        let [challenge, relay] = unsigned.tags.as_slice() else {
            return Err(SignerError::from(REFUSED));
        };
        let (["challenge", challenge], ["relay", relay]) =
            (tag_parts(challenge.as_slice()), tag_parts(relay.as_slice()))
        else {
            return Err(SignerError::from(REFUSED));
        };
        let relay = RelayUrl::parse(relay).map_err(|_| SignerError::from(REFUSED))?;
        let rebuilt = EventBuilder::auth(challenge, relay)
            .custom_created_at(unsigned.created_at)
            .build(self.public_key);
        if rebuilt.tags != unsigned.tags {
            return Err(SignerError::from(REFUSED));
        }
        let secret =
            SecretKey::from_slice(self.secret.as_ref()).map_err(|_| SignerError::from(REFUSED))?;
        rebuilt
            .sign_with_keys(&Keys::new(secret))
            .map_err(|_| SignerError::from(REFUSED))
    }
}

/// A tag's elements as `&str`s, for matching by shape.
const fn tag_parts(tag: &[String]) -> [&str; 2] {
    match tag {
        [name, value] => [name.as_str(), value.as_str()],
        _ => ["", ""],
    }
}

impl std::fmt::Debug for Nip42Signer {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // Not even the public key: it would tie a log line to an identity.
        f.debug_struct("Nip42Signer").finish_non_exhaustive()
    }
}

impl NostrSigner for Nip42Signer {
    fn backend(&self) -> SignerBackend<'_> {
        SignerBackend::Custom(Cow::Borrowed("nip42"))
    }

    fn get_public_key(&self) -> BoxedFuture<'_, Result<PublicKey, SignerError>> {
        let public_key = self.public_key;
        Box::pin(async move { Ok(public_key) })
    }

    fn sign_event(&self, unsigned: UnsignedEvent) -> BoxedFuture<'_, Result<Event, SignerError>> {
        let signed = self.sign_auth(&unsigned);
        Box::pin(async move { signed })
    }

    fn nip04_encrypt<'a>(
        &'a self,
        _public_key: &'a PublicKey,
        _content: &'a str,
    ) -> BoxedFuture<'a, Result<String, SignerError>> {
        Box::pin(async { Err(SignerError::from(REFUSED)) })
    }

    fn nip04_decrypt<'a>(
        &'a self,
        _public_key: &'a PublicKey,
        _encrypted_content: &'a str,
    ) -> BoxedFuture<'a, Result<String, SignerError>> {
        Box::pin(async { Err(SignerError::from(REFUSED)) })
    }

    fn nip44_encrypt<'a>(
        &'a self,
        _public_key: &'a PublicKey,
        _content: &'a str,
    ) -> BoxedFuture<'a, Result<String, SignerError>> {
        Box::pin(async { Err(SignerError::from(REFUSED)) })
    }

    fn nip44_decrypt<'a>(
        &'a self,
        _public_key: &'a PublicKey,
        _payload: &'a str,
    ) -> BoxedFuture<'a, Result<String, SignerError>> {
        Box::pin(async { Err(SignerError::from(REFUSED)) })
    }
}

#[cfg(test)]
mod tests {
    use nostr::Tag;

    use super::*;

    const CHALLENGE: &str = "challenge-7f3a91c2e4b8";
    const RELAY: &str = "wss://inbox.relay.example.com";

    fn relay() -> RelayUrl {
        RelayUrl::parse(RELAY).expect("a relay url")
    }

    /// The answer exactly as the pool builds it (`InnerRelay::auth`).
    fn answer(author: PublicKey) -> UnsignedEvent {
        EventBuilder::auth(CHALLENGE, relay()).build(author)
    }

    fn tag(parts: &[&str]) -> Tag {
        Tag::parse(parts.iter().copied()).expect("a tag")
    }

    async fn refused(signer: &Nip42Signer, unsigned: UnsignedEvent, shape: &str) {
        let result = signer.sign_event(unsigned).await;
        assert!(
            result == Err(SignerError::from(REFUSED)),
            "{shape} was event, or refused in words other than the fixed text",
        );
    }

    #[tokio::test]
    async fn it_signs_the_answer_the_pool_builds_under_the_identity_key() {
        let keys = Keys::generate();
        let signer = Nip42Signer::new(&keys);
        let unsigned = answer(keys.public_key());
        let event = signer
            .sign_event(unsigned.clone())
            .await
            .expect("the answer is event");
        assert!(event.verify().is_ok(), "the id or signature is wrong");
        assert_eq!(event.pubkey, keys.public_key());
        assert_eq!(event.kind, Kind::Authentication);
        assert_eq!(event.content, "");
        assert_eq!(event.created_at, unsigned.created_at);
        assert_eq!(
            event.tags.iter().map(Tag::as_slice).collect::<Vec<_>>(),
            [["challenge", CHALLENGE], ["relay", RELAY]],
        );
        assert_eq!(
            signer.get_public_key().await.expect("the identity"),
            keys.public_key()
        );
    }

    /// The pool reaches the signer only through `EventBuilder::sign`, so the
    /// whole path, as the pool takes it, signs the same answer.
    #[tokio::test]
    async fn the_pools_own_signing_call_yields_the_answer() {
        let keys = Keys::generate();
        let signer = Nip42Signer::new(&keys);
        let event = EventBuilder::auth(CHALLENGE, relay())
            .sign(&signer)
            .await
            .expect("the pool's call signs");
        assert!(event.verify().is_ok());
        assert_eq!(event.pubkey, keys.public_key());
    }

    #[tokio::test]
    async fn it_refuses_every_other_kind() {
        let keys = Keys::generate();
        let signer = Nip42Signer::new(&keys);
        // Kind 0 is refused too: `tests/nip42_identity_e2e.rs`, since
        // `check_profile_privacy_boundaries.sh` holds kind-0 construction to
        // the profile module everywhere under `src/`.
        for kind in [
            Kind::TextNote,
            Kind::Custom(444),
            Kind::Custom(445),
            Kind::Custom(450),
            Kind::Seal,
            Kind::GiftWrap,
            Kind::RelayList,
            Kind::Custom(10050),
            Kind::Custom(24242),
            Kind::Custom(25442),
            Kind::Custom(30443),
            Kind::Custom(22241),
            Kind::Custom(22243),
        ] {
            let mut unsigned = answer(keys.public_key());
            unsigned.kind = kind;
            unsigned.id = None;
            refused(&signer, unsigned, &format!("kind {}", kind.as_u16())).await;
        }
    }

    #[tokio::test]
    async fn it_refuses_content() {
        let keys = Keys::generate();
        let signer = Nip42Signer::new(&keys);
        let mut unsigned = answer(keys.public_key());
        unsigned.content = "sign me".to_owned();
        unsigned.id = None;
        refused(&signer, unsigned, "an answer with content").await;
    }

    #[tokio::test]
    async fn it_refuses_any_other_tag_set() {
        let keys = Keys::generate();
        let signer = Nip42Signer::new(&keys);
        let challenge = || tag(&["challenge", CHALLENGE]);
        let relay_tag = || tag(&["relay", RELAY]);
        let shapes: Vec<(&str, Vec<Tag>)> = vec![
            ("no tags", vec![]),
            ("the challenge alone", vec![challenge()]),
            ("the relay alone", vec![relay_tag()]),
            ("the two reordered", vec![relay_tag(), challenge()]),
            (
                "a third tag",
                vec![challenge(), relay_tag(), tag(&["h", "00ff"])],
            ),
            ("two challenges", vec![challenge(), challenge()]),
            (
                "an extra element",
                vec![tag(&["challenge", CHALLENGE, "x"]), relay_tag()],
            ),
            (
                "a relay that is no URL",
                vec![challenge(), tag(&["relay", "not a url"])],
            ),
            (
                "a relay the parser respells",
                vec![
                    challenge(),
                    tag(&["relay", "wss://INBOX.relay.example.com"]),
                ],
            ),
            (
                "another tag in the relay's place",
                vec![challenge(), tag(&["p", &keys.public_key().to_hex()])],
            ),
        ];
        for (shape, tags) in shapes {
            let mut unsigned = answer(keys.public_key());
            unsigned.tags = tags.into_iter().collect();
            unsigned.id = None;
            refused(&signer, unsigned, shape).await;
        }
    }

    #[tokio::test]
    async fn it_refuses_another_author() {
        let signer = Nip42Signer::new(&Keys::generate());
        refused(
            &signer,
            answer(Keys::generate().public_key()),
            "another author's answer",
        )
        .await;
    }

    /// The id a caller set is never what is event: the event is rebuilt.
    #[tokio::test]
    async fn it_signs_the_rebuilt_answer_never_a_caller_supplied_id() {
        let keys = Keys::generate();
        let signer = Nip42Signer::new(&keys);
        let mut unsigned = answer(keys.public_key());
        let wanted = EventBuilder::text_note("not an answer")
            .build(keys.public_key())
            .id();
        unsigned.id = Some(wanted);
        let event = signer.sign_event(unsigned).await.expect("the answer signs");
        assert!(event.id != wanted && event.verify().is_ok());
    }

    #[tokio::test]
    async fn it_neither_encrypts_nor_decrypts() {
        let signer = Nip42Signer::new(&Keys::generate());
        let peer = Keys::generate().public_key();
        let refusal = Err(SignerError::from(REFUSED));
        assert_eq!(signer.nip04_encrypt(&peer, "x").await, refusal);
        assert_eq!(signer.nip04_decrypt(&peer, "x").await, refusal);
        assert_eq!(signer.nip44_encrypt(&peer, "x").await, refusal);
        assert_eq!(signer.nip44_decrypt(&peer, "x").await, refusal);
    }

    #[test]
    fn nip42_signer_debug_redacts_both_keys() {
        let keys = Keys::generate();
        let signer = Nip42Signer::new(&keys);
        crate::assert_debug_redacted!(
            &signer,
            "Nip42Signer",
            &[
                keys.public_key().to_hex().as_str(),
                keys.secret_key().to_secret_hex().as_str(),
            ]
        );
    }

    #[test]
    fn it_zeroizes_on_drop() {
        const fn assert_zeroize_on_drop<T: ZeroizeOnDrop>() {}
        assert_zeroize_on_drop::<Nip42Signer>();
    }
}
