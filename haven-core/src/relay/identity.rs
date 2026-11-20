//! Per-call identity connections: one relay, one client that answers its
//! NIP-42 challenge, shut down on every path.
//!
//! Authentication is a property of a whole client in `nostr-relay-pool`
//! 0.44.3 (the signer and the switch live in the pool's shared state), so "only
//! the relay that asked" is a client that holds only that relay. It is
//! registered with the publish pool's options (`reconnect(false)`, no ping) and
//! for one direction only: a write-only relay can carry no REQ, so no filter
//! ever rides an authenticated retry socket.
//!
//! [`with_identity_relay`] awaits the client's shutdown before it returns, so
//! the socket is closed when the call is over. A call dropped mid-await (a
//! wake's budget ending) needs nothing of its own: the pool wraps its state in
//! `atomic_destructor::AtomicDestructor`, whose last handle's drop spawns
//! `shutdown()` (`nostr-relay-pool-0.44.3 pool/inner.rs:41-46`; the relay's
//! own disconnects it, `relay/inner.rs:164-168`) — pinned by
//! `nip42_identity_e2e::a_send_dropped_mid_wait_still_closes_its_identity_socket`.
//!
//! Nothing here logs: everything it handles names a relay, a key or an event
//! (Security Rule 15).

use std::borrow::Cow;
use std::future::Future;
use std::sync::Arc;
use std::time::Duration;

use nostr::message::MachineReadablePrefix;
use nostr::{ClientMessage, Event, RelayMessage, RelayUrl};
use nostr_sdk::pool::relay::RelayNotification;
use nostr_sdk::{ClientOptions, Relay, RelayOptions, RelayStatus};
use tokio::sync::broadcast::{self, error::RecvError};
use tokio::time::Instant;

use super::manager::{publish_relay_options, CONNECTION_TIMEOUT};
use super::nip42::Nip42Signer;
use super::url_norm::may_dial;
use super::verified::identity_client;

/// How long a send waits for the relay to accept the answer to its challenge.
///
/// The pool's own wait for the same thing (`WAIT_FOR_AUTHENTICATION_TIMEOUT`,
/// `nostr-relay-pool-0.44.3 relay/constants.rs:11`, which is `pub(super)`).
pub const AUTH_WAIT: Duration = Duration::from_secs(7);

/// The direction the one relay is registered for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IdentityUse {
    /// Sending only: the relay holds no READ flag, so no REQ can be sent.
    Write,
    /// Reading only: the relay holds no WRITE flag, so no EVENT can be sent.
    Read,
}

/// The relay could not be dialled: not a URL Haven dials, not registered, or
/// not connected in time. Nothing was sent.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct NotDialled;

/// The connected relay of a [`with_identity_relay`] call.
///
/// No `Debug`: the relay handle renders its URL.
pub struct IdentityRelay {
    /// The one relay, connected.
    pub relay: Relay,
    /// The relay's own notifications, taken before it was dialled: a relay
    /// that challenges on connect is answered before any caller could
    /// subscribe, and `Authenticated` / `AuthenticationFailed` reach no other
    /// channel (`RelayPoolNotification` drops them).
    pub notifications: broadcast::Receiver<RelayNotification>,
}

/// Runs `act` on `url`, connected through a fresh [`identity_client`] that holds
/// that relay alone, for `direction` only, and shuts the client down
/// afterwards.
///
/// # Errors
///
/// [`NotDialled`] when `url` is not one Haven dials (`url_norm::may_dial`) or
/// was not connected within `CONNECTION_TIMEOUT`; `act` is not run.
pub async fn with_identity_relay<T, F, Fut>(
    signer: Arc<Nip42Signer>,
    url: &RelayUrl,
    direction: IdentityUse,
    act: F,
) -> Result<T, NotDialled>
where
    F: FnOnce(IdentityRelay) -> Fut,
    Fut: Future<Output = T>,
{
    if !may_dial(url) {
        return Err(NotDialled);
    }
    let client = identity_client(signer, ClientOptions::default(), None);
    let result = async {
        client
            .pool()
            .add_relay(url.as_str(), identity_relay_options(direction))
            .await
            .map_err(|_| NotDialled)?;
        let relay = client.relay(url.as_str()).await.map_err(|_| NotDialled)?;
        let notifications = relay.notifications();
        relay
            .try_connect(CONNECTION_TIMEOUT)
            .await
            .map_err(|_| NotDialled)?;
        Ok(act(IdentityRelay {
            relay,
            notifications,
        })
        .await)
    }
    .await;
    client.shutdown().await;
    result
}

/// The publish pool's options — no reconnect, no ping — for one direction.
fn identity_relay_options(direction: IdentityUse) -> RelayOptions {
    let options = publish_relay_options();
    match direction {
        IdentityUse::Write => options.read(false),
        IdentityUse::Read => options.write(false),
    }
}

/// A NIP-42 verdict for one relay.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AuthVerdict {
    /// The relay accepted the answer to its challenge.
    Authenticated,
    /// The relay refused it, on a connection it had not authenticated.
    Failed,
}

/// Reads a relay's notifications for the verdict on its connection.
///
/// `AuthenticationFailed` on a connection that already authenticated is no
/// verdict: strfry answers a second challenge's answer with `OK false
/// "already authenticated"`, and the pool reports that as a failure while the
/// connection stays authenticated. A connection that ends forgets it was.
#[derive(Debug, Default)]
pub struct AuthTracker {
    authenticated: bool,
}

impl AuthTracker {
    /// The verdict `notification` carries, if any.
    pub fn observe(&mut self, notification: &RelayNotification) -> Option<AuthVerdict> {
        match notification {
            RelayNotification::Authenticated => {
                self.authenticated = true;
                Some(AuthVerdict::Authenticated)
            }
            RelayNotification::AuthenticationFailed if !self.authenticated => {
                Some(AuthVerdict::Failed)
            }
            RelayNotification::RelayStatus { status } if *status != RelayStatus::Connected => {
                self.authenticated = false;
                None
            }
            _ => None,
        }
    }

    /// Whether the current connection has authenticated.
    #[must_use]
    pub const fn is_authenticated(&self) -> bool {
        self.authenticated
    }
}

/// What one relay did with an event [`IdentityRelay::send_once_authenticated`]
/// sent it.
///
/// Read off the relay's own `OK` frames for that event id — the category from
/// the machine-readable prefix, never the relay's prose.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AuthSendOutcome {
    /// An `OK true`, or a `duplicate:`: the relay holds the event.
    Accepted,
    /// Every frame sent was answered `OK false`, at least one of them after
    /// the connection authenticated.
    Refused,
    /// Every frame sent was answered `OK false` and none was sent after the
    /// connection authenticated: the answer to the challenge failed, no
    /// challenge came, or the relay did not accept it within [`AUTH_WAIT`].
    NotAuthenticated,
    /// A frame got no `OK` in time, or the socket went, and none was accepted:
    /// the relay may hold the event.
    Unanswered,
    /// The relay was not dialled, or nothing could be handed to its socket:
    /// nothing left the device.
    NotSent,
}

impl AuthSendOutcome {
    /// The outcome of a [`with_identity_relay`] call that ran a send: a relay
    /// that was never dialled was sent nothing.
    #[must_use]
    pub const fn or_not_sent(result: Result<Self, NotDialled>) -> Self {
        match result {
            Ok(outcome) => outcome,
            Err(NotDialled) => Self::NotSent,
        }
    }
}

/// The longest [`send_signed_once_authenticated`] can take with `ack_window`
/// per `OK`, before its shutdown.
///
/// The connect, the first frame's `OK`, the wait for authentication and the
/// second frame's `OK`. A caller with a budget adds this.
#[must_use]
pub const fn auth_send_ceiling(ack_window: Duration) -> Duration {
    CONNECTION_TIMEOUT
        .saturating_add(ack_window)
        .saturating_add(AUTH_WAIT)
        .saturating_add(ack_window)
}

/// Sends `event`, already signed, to `url` at most once after authenticating.
///
/// On its own identity connection ([`with_identity_relay`], write-only), and
/// reads the answer off the relay's own `OK` frames.
///
/// The byte-identical event goes out at most twice: once to provoke the
/// challenge a relay issues only on a gated write (strfry, `nostr-relay-builder`),
/// and once more only after `Authenticated`. Never through `Relay::send_event`,
/// whose hidden resend after an `auth-required:` would make the frames sent
/// differ from the frames counted.
pub async fn send_signed_once_authenticated(
    signer: Arc<Nip42Signer>,
    url: &RelayUrl,
    event: &Event,
    ack_window: Duration,
) -> AuthSendOutcome {
    AuthSendOutcome::or_not_sent(
        with_identity_relay(signer, url, IdentityUse::Write, |mut relay| async move {
            relay.send_once_authenticated(event, ack_window).await
        })
        .await,
    )
}

impl IdentityRelay {
    /// The body of [`send_signed_once_authenticated`], on a relay already
    /// dialled.
    pub async fn send_once_authenticated(
        &mut self,
        event: &Event,
        ack_window: Duration,
    ) -> AuthSendOutcome {
        let mut auth = AuthTracker::default();
        // An answer already in hand decides whether the first frame is sent
        // after authentication.
        while let Ok(notification) = self.notifications.try_recv() {
            auth.observe(&notification);
        }
        let mut sent_after_auth = auth.is_authenticated();
        if !self.send(event) {
            return AuthSendOutcome::NotSent;
        }
        let mut unanswered = 1_usize;
        let mut auth_failed = false;
        let mut deadline = Instant::now() + ack_window;
        loop {
            let notification =
                match tokio::time::timeout_at(deadline, self.notifications.recv()).await {
                    Ok(Ok(notification)) => notification,
                    // A lost notification may have been an `OK`; an `OK` never
                    // read leaves its frame unanswered, which is the safe
                    // reading.
                    Ok(Err(RecvError::Lagged(_))) => continue,
                    Ok(Err(RecvError::Closed)) | Err(_) => {
                        return Self::ended(unanswered, sent_after_auth)
                    }
                };
            if auth.observe(&notification) == Some(AuthVerdict::Failed) {
                auth_failed = true;
            }
            match &notification {
                RelayNotification::Message {
                    message:
                        RelayMessage::Ok {
                            event_id,
                            status,
                            message,
                        },
                } if *event_id == event.id => {
                    let prefix = MachineReadablePrefix::parse(message);
                    if *status || prefix == Some(MachineReadablePrefix::Duplicate) {
                        return AuthSendOutcome::Accepted;
                    }
                    unanswered = unanswered.saturating_sub(1);
                    let wants_auth = prefix == Some(MachineReadablePrefix::AuthRequired);
                    if unanswered == 0 && !sent_after_auth && !auth.is_authenticated() {
                        // A refusal authentication would not change ends it.
                        if !wants_auth || auth_failed {
                            return AuthSendOutcome::NotAuthenticated;
                        }
                        deadline = Instant::now() + AUTH_WAIT;
                    }
                }
                RelayNotification::RelayStatus { status } if gone(*status) => {
                    return Self::ended(unanswered, sent_after_auth);
                }
                RelayNotification::Shutdown => return Self::ended(unanswered, sent_after_auth),
                _ => {}
            }
            if unanswered > 0 {
                continue;
            }
            if sent_after_auth {
                return AuthSendOutcome::Refused;
            }
            if auth_failed {
                return AuthSendOutcome::NotAuthenticated;
            }
            if auth.is_authenticated() {
                if !self.send(event) {
                    return AuthSendOutcome::NotAuthenticated;
                }
                sent_after_auth = true;
                unanswered = 1;
                deadline = Instant::now() + ack_window;
            }
        }
    }

    /// Hands `event` to the socket; `false` when the pool refused it there,
    /// before any byte left.
    fn send(&self, event: &Event) -> bool {
        self.relay
            .send_msg(ClientMessage::Event(Cow::Borrowed(event)))
            .is_ok()
    }

    /// The outcome when no further answer can come.
    const fn ended(unanswered: usize, sent_after_auth: bool) -> AuthSendOutcome {
        if unanswered > 0 {
            AuthSendOutcome::Unanswered
        } else if sent_after_auth {
            AuthSendOutcome::Refused
        } else {
            AuthSendOutcome::NotAuthenticated
        }
    }
}

/// Whether `status` means the socket is gone.
const fn gone(status: RelayStatus) -> bool {
    matches!(
        status,
        RelayStatus::Disconnected
            | RelayStatus::Terminated
            | RelayStatus::Banned
            | RelayStatus::Sleeping
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn status(status: RelayStatus) -> RelayNotification {
        RelayNotification::RelayStatus { status }
    }

    #[test]
    fn a_failure_on_a_connection_that_authenticated_is_no_verdict() {
        let mut auth = AuthTracker::default();
        assert_eq!(
            auth.observe(&RelayNotification::AuthenticationFailed),
            Some(AuthVerdict::Failed)
        );
        assert!(!auth.is_authenticated());
        assert_eq!(
            auth.observe(&RelayNotification::Authenticated),
            Some(AuthVerdict::Authenticated)
        );
        assert_eq!(auth.observe(&RelayNotification::AuthenticationFailed), None);
        assert!(
            auth.is_authenticated(),
            "strfry's 'already authenticated' undid it"
        );
    }

    #[test]
    fn a_connection_that_ends_forgets_it_authenticated() {
        let mut auth = AuthTracker::default();
        auth.observe(&RelayNotification::Authenticated);
        assert_eq!(auth.observe(&status(RelayStatus::Connected)), None);
        assert!(auth.is_authenticated());
        assert_eq!(auth.observe(&status(RelayStatus::Disconnected)), None);
        assert!(!auth.is_authenticated());
        assert_eq!(
            auth.observe(&RelayNotification::AuthenticationFailed),
            Some(AuthVerdict::Failed),
            "a failure on the next connection is that connection's verdict"
        );
    }

    #[test]
    fn the_ceiling_is_every_wait_the_send_can_make() {
        assert_eq!(
            auth_send_ceiling(Duration::from_secs(5)),
            CONNECTION_TIMEOUT + Duration::from_secs(10) + AUTH_WAIT
        );
    }
}
