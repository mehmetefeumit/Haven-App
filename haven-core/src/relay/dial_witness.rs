//! Every relay a client built by `verified_client` dials, while a test is
//! watching.
//!
//! Compiled only with `test-utils`. A recording front sees what reaches it and
//! nothing that went elsewhere: a dial to a real host is invisible from inside
//! the test's world. The pool asks the client's admission policy before every
//! connection attempt, reconnects included, so the policy notes the URL here
//! and admits it exactly as the trait's default would. The record holds relay
//! URLs, so nothing here has `Debug`, and what it reports names ordinals only
//! (Security Rule 15).

use std::sync::{Mutex, PoisonError};

static WATCH: Mutex<Option<Vec<String>>> = Mutex::new(None);

fn watch() -> std::sync::MutexGuard<'static, Option<Vec<String>>> {
    WATCH.lock().unwrap_or_else(PoisonError::into_inner)
}

/// Records every dial while it lives; one at a time per process.
pub struct DialWatch(());

/// [`DialWatch::arm`] found a watch already armed.
pub struct AlreadyArmed;

impl DialWatch {
    /// Starts recording.
    ///
    /// # Errors
    ///
    /// [`AlreadyArmed`] while another watch lives: two would each miss what
    /// the other recorded.
    pub fn arm() -> Result<Self, AlreadyArmed> {
        let mut watch = watch();
        if watch.is_some() {
            return Err(AlreadyArmed);
        }
        *watch = Some(Vec::new());
        drop(watch);
        Ok(Self(()))
    }

    /// Every URL dialled since [`Self::arm`], in order, as the pool spells it.
    #[must_use]
    pub fn dials(&self) -> Vec<String> {
        watch().clone().unwrap_or_default()
    }
}

impl Drop for DialWatch {
    fn drop(&mut self) {
        *watch() = None;
    }
}

/// Notes a dial of `url`; nothing while no watch is armed.
pub(crate) fn note(url: &str) {
    if let Some(dials) = watch().as_mut() {
        dials.push(url.to_owned());
    }
}

/// Whether `dials` went only to `world` and reached each of its relays,
/// compared as parsed relay URLs. `Err` names the offending dial or the
/// undialled relay by its ordinal alone, never by its URL.
///
/// # Errors
///
/// A dial outside `world`, or a relay of `world` never dialled.
pub fn dials_cover_exactly(dials: &[String], world: &[String]) -> Result<(), String> {
    let norm = |url: &String| {
        nostr::RelayUrl::parse(url).map_or_else(
            |_| url.clone(),
            |url| url.as_str_without_trailing_slash().to_owned(),
        )
    };
    let world: Vec<String> = world.iter().map(norm).collect();
    let dialled: Vec<String> = dials.iter().map(norm).collect();
    if let Some(ordinal) = dialled.iter().position(|dial| !world.contains(dial)) {
        return Err(format!(
            "dial #{ordinal} went to a relay outside the test's world"
        ));
    }
    if let Some(ordinal) = world.iter().position(|relay| !dialled.contains(relay)) {
        return Err(format!("relay #{ordinal} of the world was never dialled"));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const WORLD: [&str; 2] = ["ws://127.0.0.1:4101", "ws://127.0.0.1:4102"];

    fn owned(urls: &[&str]) -> Vec<String> {
        urls.iter().map(|url| (*url).to_owned()).collect()
    }

    #[test]
    fn dials_inside_the_world_reaching_every_relay_pass_in_any_spelling() {
        assert!(dials_cover_exactly(
            &owned(&[
                "ws://127.0.0.1:4102/",
                "ws://127.0.0.1:4101",
                "ws://127.0.0.1:4101"
            ]),
            &owned(&WORLD),
        )
        .is_ok());
    }

    /// A dial to a production host, and a world relay never dialled, are each
    /// reported by ordinal: neither the host nor any URL reaches the message.
    #[test]
    fn a_dial_outside_the_world_is_named_by_ordinal_and_never_by_its_url() {
        let planted = "wss://relay.damus.io";
        let outside = dials_cover_exactly(&owned(&[WORLD[0], planted, WORLD[1]]), &owned(&WORLD))
            .expect_err("a dial outside the world fails");
        let undialled = dials_cover_exactly(&owned(&[WORLD[0]]), &owned(&WORLD))
            .expect_err("an undialled relay fails");
        assert_eq!(outside, "dial #1 went to a relay outside the test's world");
        assert_eq!(undialled, "relay #1 of the world was never dialled");
        for message in [&outside, &undialled] {
            for needle in [planted, "damus", "127.0.0.1", "4101", "4102", "ws://"] {
                assert!(!message.contains(needle), "a failure message names a relay");
            }
        }
    }
}
