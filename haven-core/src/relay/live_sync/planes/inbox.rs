//! The inbox plane: `kind:1059` gift-wrapped invitations addressed to us by
//! the `#p` tag.

use nostr::{Filter, Kind, PublicKey, Timestamp};

/// Builds the `kind:1059` inbox filter for our own public key.
///
/// `own_pubkey` is matched against the `#p` (recipient) tag, **not** the event
/// author — gift wraps are authored by ephemeral keys. `since_secs` already
/// incorporates the 7-day NIP-59 backdating lookback via
/// [`crate::relay::cursor::since_for_stream`].
///
/// # Examples
///
/// ```
/// use haven_core::relay::live_sync::planes::inbox::inbox_filter;
/// use nostr::Keys;
///
/// let pk = Keys::generate().public_key();
/// let f = inbox_filter(pk, 1_000);
/// assert!(f.kinds.as_ref().unwrap().contains(&nostr::Kind::GiftWrap));
/// ```
#[must_use]
pub fn inbox_filter(own_pubkey: PublicKey, since_secs: i64) -> Filter {
    let since = u64::try_from(since_secs).unwrap_or(0);
    Filter::new()
        .kind(Kind::GiftWrap)
        .pubkey(own_pubkey)
        .since(Timestamp::from(since))
}

#[cfg(test)]
mod tests {
    use super::*;
    use nostr::{Alphabet, Keys, SingleLetterTag};

    #[test]
    fn filter_targets_giftwrap_and_p_tag_is_recipient_not_author() {
        let keys = Keys::generate();
        let pk = keys.public_key();
        let f = inbox_filter(pk, 9_999);

        assert!(f.kinds.as_ref().unwrap().contains(&Kind::GiftWrap));
        assert_eq!(f.since, Some(Timestamp::from(9_999)));

        // `#p` carries the recipient pubkey; `authors` must stay unset (the
        // author is an ephemeral gift-wrap key, never our identity).
        let p = SingleLetterTag::lowercase(Alphabet::P);
        let values = f.generic_tags.get(&p).expect("#p tag present");
        assert!(values.contains(&pk.to_hex()));
        assert!(
            f.authors.is_none(),
            "must filter by #p recipient, not author"
        );
    }

    #[test]
    fn negative_since_floors_to_zero() {
        let pk = Keys::generate().public_key();
        let f = inbox_filter(pk, -10);
        assert_eq!(f.since, Some(Timestamp::from(0)));
    }
}
