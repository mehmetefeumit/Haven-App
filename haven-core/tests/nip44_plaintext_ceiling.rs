//! The NIP-44 v2 plaintext ceiling, gated as the dependency invariant it is.
//!
//! `nostr`'s v2 codec refuses a plaintext longer than its
//! `MAX_SUPPORTED_PLAINTEXT_SIZE` (`nostr-0.44.7/src/nips/nip44/v2.rs:35`,
//! refused in `pad` at `:334-336`) on the client, before any socket opens. Every
//! Welcome crosses it twice (the NIP-59 seal and wrap are each a NIP-44 layer),
//! so an oversized Welcome never reaches the relay size cap the soak's S22
//! grades. It is a function of one length, which is why it is proved here rather
//! than in a soak world (soak plan decision 0.12).
//!
//! The constant is private, so the ceiling is pinned by BEHAVIOUR at its edge —
//! the longest plaintext that encrypts and the first that is refused — on the
//! path the NIP-59 layers call (`nip44::encrypt`) and on Haven's own
//! `encrypt_nip44`. A dependency bump that moves the edge fails here.
//!
//! Rule 15: no plaintext, key or length is rendered by any assertion.

use haven_core::nostr::encryption::encrypt_nip44;
use haven_core::nostr::NostrError;
use nostr::nips::nip44::{self, v2::ErrorV2, Version};
use nostr::Keys;
use zeroize::Zeroizing;

/// The ceiling as the dependency spells its private constant.
const CEILING: usize = 65_536 - 128;

#[test]
fn a_plaintext_one_byte_past_the_ceiling_is_refused_and_one_at_it_is_not() {
    let sender = Keys::generate();
    let receiver = Keys::generate().public_key();
    let at = "x".repeat(CEILING);
    let past = "x".repeat(CEILING + 1);

    assert!(
        nip44::encrypt(sender.secret_key(), &receiver, &at, Version::V2).is_ok(),
        "a plaintext exactly at the NIP-44 ceiling must encrypt on the NIP-59 layer's path"
    );
    assert!(
        matches!(
            nip44::encrypt(sender.secret_key(), &receiver, &past, Version::V2),
            Err(nip44::Error::V2(ErrorV2::MessageTooLong))
        ),
        "one byte past the ceiling must be refused as too long, before any relay sees it"
    );

    let key = Zeroizing::new([0x42_u8; 32]);
    assert!(
        encrypt_nip44(&at, &key).is_ok(),
        "Haven's own NIP-44 wrapper must accept a plaintext exactly at the ceiling"
    );
    assert!(
        matches!(encrypt_nip44(&past, &key), Err(NostrError::Encryption(_))),
        "and refuse one byte past it as an encryption failure"
    );
}
