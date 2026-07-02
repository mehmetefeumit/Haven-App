//! The group plane: `kind:445` messages multiplexed by the `#h` tag.
//!
//! A single REQ carries every circle's `hex(nostr_group_id)` in one `#h` filter,
//! so all circles sharing a relay set are served by one subscription on one
//! socket.

use nostr::{Alphabet, Filter, Kind, SingleLetterTag, Timestamp};

/// Builds the `kind:445` group filter for a set of circles.
///
/// `group_ids_hex` are the circles' `hex(nostr_group_id)` values (NOT the real
/// MLS group ids — Security Rule 4); they populate the `#h` tag. `since_secs` is
/// the REQ lower bound already derived by
/// [`crate::relay::cursor::since_for_stream`] (non-negative).
///
/// # Examples
///
/// ```
/// use haven_core::relay::live_sync::planes::group::group_filter;
///
/// let f = group_filter(&["aa00".to_string(), "bb11".to_string()], 1_000);
/// // One filter multiplexes both circles' `#h` values.
/// assert!(f.kinds.as_ref().unwrap().contains(&nostr::Kind::Custom(445)));
/// ```
#[must_use]
pub fn group_filter(group_ids_hex: &[String], since_secs: i64) -> Filter {
    let since = u64::try_from(since_secs).unwrap_or(0);
    Filter::new()
        .kind(Kind::Custom(445))
        .custom_tags(
            SingleLetterTag::lowercase(Alphabet::H),
            group_ids_hex.iter().cloned(),
        )
        .since(Timestamp::from(since))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn filter_targets_kind_445_and_carries_h_tag() {
        let ids = vec!["aa00".to_string(), "bb11".to_string()];
        let f = group_filter(&ids, 1_234);

        assert!(f.kinds.as_ref().unwrap().contains(&Kind::Custom(445)));
        assert_eq!(f.since, Some(Timestamp::from(1_234)));

        // The `#h` generic tag must contain exactly the supplied hex ids.
        let h = SingleLetterTag::lowercase(Alphabet::H);
        let values = f.generic_tags.get(&h).expect("#h tag present");
        assert!(values.contains("aa00"));
        assert!(values.contains("bb11"));
    }

    #[test]
    fn negative_since_floors_to_zero() {
        let f = group_filter(&["aa00".to_string()], -5);
        assert_eq!(f.since, Some(Timestamp::from(0)));
    }
}
