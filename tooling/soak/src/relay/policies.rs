//! The `CLOSED` frames: the two the relay produces on its own, and the text the
//! proxy forges for every prefix.
//!
//! `nostr-relay-builder` has exactly two hook layers — build-time fields and
//! per-`EVENT`/per-`REQ` policy plugins — and neither can spell an arbitrary
//! machine-readable prefix: `WritePolicy::Reject` always renders
//! `OK false "blocked: …"` and `QueryPolicy::Reject` always renders
//! `CLOSED "error: …"`. So every prefix the scenarios need is forged by the
//! proxy, and these two build-time knobs exist for one purpose: to be the
//! CONTROL that proves the forged bytes are the bytes a relay really sends.

use nostr_relay_builder::builder::{
    RateLimit, RelayBuilder, RelayBuilderNip42, RelayBuilderNip42Mode,
};

use crate::nemesis::types::ClosedPrefix;

/// A `CLOSED` the relay itself produces, from a build-time knob.
///
/// A plane built with one of these is a fixed, permanently-refusing relay: the
/// knobs are consumed when the relay is built, so they are the byte-fidelity
/// control rather than a fault the schedule can apply mid-run.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NativeClosed {
    /// Every `REQ` is refused as one too many.
    RateLimited,
    /// Every `REQ` is refused until the session authenticates.
    AuthRequired,
}

impl NativeClosed {
    /// The prefix this knob makes the relay send.
    #[must_use]
    pub const fn prefix(self) -> ClosedPrefix {
        match self {
            Self::RateLimited => ClosedPrefix::RateLimited,
            Self::AuthRequired => ClosedPrefix::AuthRequired,
        }
    }

    /// Configures `builder` to refuse every subscription this way.
    pub(crate) fn configure(self, builder: RelayBuilder) -> RelayBuilder {
        match self {
            // The relay refuses a REQ when the session already holds max_reqs
            // subscriptions, so a maximum of zero refuses the first one. The
            // per-minute event allowance is left at its default: this control
            // is about the REQ side, and a relay that also refused writes could
            // not be asked to store anything.
            Self::RateLimited => builder.rate_limit(RateLimit {
                max_reqs: 0,
                ..RateLimit::default()
            }),
            // Read mode only: the same relay must still accept an EVENT, so the
            // control can publish and then be refused its subscription.
            Self::AuthRequired => builder.nip42(RelayBuilderNip42 {
                mode: RelayBuilderNip42Mode::Read,
            }),
        }
    }
}

/// The `CLOSED` message the proxy forges for `prefix`.
///
/// Composed from [`ClosedPrefix::as_str`] rather than written out per prefix,
/// so a message can never carry a prefix other than the one it was asked for.
/// The two suffixes a real relay also spells are copied from it verbatim
/// (`rate-limited: too many REQs`, `auth-required: you must auth`); the
/// byte-fidelity control is what keeps them true.
pub fn closed_message(prefix: ClosedPrefix) -> String {
    let reason = match prefix {
        ClosedPrefix::Duplicate => "that subscription is already open",
        ClosedPrefix::Pow => "required a difficulty this subscription does not carry",
        ClosedPrefix::Blocked => "this subscription is not permitted",
        ClosedPrefix::RateLimited => "too many REQs",
        ClosedPrefix::Invalid => "malformed filter",
        ClosedPrefix::Error => "the relay could not serve this subscription",
        ClosedPrefix::Unsupported => "this filter is not supported",
        ClosedPrefix::AuthRequired => "you must auth",
        ClosedPrefix::Restricted => "not permitted for this key",
    };
    format!("{} {reason}", prefix.as_str())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_prefix_has_a_message_that_begins_with_it() {
        for prefix in ClosedPrefix::ALL {
            let message = closed_message(prefix);
            assert!(
                message.starts_with(prefix.as_str()),
                "a forged CLOSED must carry the prefix it was asked for"
            );
            assert!(
                message.len() > prefix.as_str().len() + 1,
                "a bare prefix is not a message a relay would send"
            );
        }
    }

    #[test]
    fn a_native_knob_names_the_prefix_it_will_produce() {
        assert_eq!(
            NativeClosed::RateLimited.prefix(),
            ClosedPrefix::RateLimited
        );
        assert_eq!(
            NativeClosed::AuthRequired.prefix(),
            ClosedPrefix::AuthRequired
        );
    }
}
