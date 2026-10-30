//! The engine's lock, and the one way through it to a session that can be
//! changed.
//!
//! MDK's rollback rewinds a commit and leaves that commit's own stored row as
//! sent, where any later convergence pass of its circle can select it and
//! merge a commit every relay refused (`docs/MDK_UPSTREAM_TRACKER.md`
//! T-ROLLBACK-RESURRECT). Haven retires the row right after the rewind. While
//! one may still be unretired no engine call that can run a pass may be made,
//! and every such call takes the session by `&mut`. So the lock lives here,
//! where nothing outside this module can take it: a mutable borrow is handed
//! out by [`Gated::engine`] alone, after the retirement its caller supplies
//! has run, and [`Gated::reading`] hands out a guard that cannot be borrowed
//! mutably. Neither guard can be taken apart: tokio's own guard would give
//! the lock back to whoever held it (`MutexGuard::mutex`).
//!
//! Generic over the session so that the session's type is named in one file
//! only, the one that opens it: a second name here would be a second name a
//! session could be opened under (Security Rule 14,
//! `single_account_device_session_construction_site`).

use std::sync::atomic::{AtomicBool, Ordering};

use tokio::sync::{Mutex, MutexGuard};

/// A session behind its lock — see the module.
pub(super) struct Gated<S> {
    session: Mutex<S>,
    /// Whether a rolled-back commit may still be unretired.
    unfinished: AtomicBool,
}

/// A lock guard that can only be read through ([`Gated::reading`]).
///
/// That is not "can only read": the session's `&self` calls include durable
/// writes — a fanout row put or deleted, a Welcome marked delivered — and
/// they go through here too. What none of them can do is run a convergence
/// pass, which is the one thing the gate exists to hold back.
pub(super) struct Reading<'a, S>(MutexGuard<'a, S>);

impl<S> std::ops::Deref for Reading<'_, S> {
    type Target = S;

    fn deref(&self) -> &S {
        &self.0
    }
}

#[cfg(any(test, feature = "test-utils"))]
impl<'a, S> Reading<'a, S> {
    /// The lock itself, held and nothing more: how a test queues two calls
    /// behind it in a known order. Opaque, so it cannot be borrowed through.
    pub(super) fn held(self) -> impl Drop + 'a {
        self.0
    }
}

/// The lock guard [`Gated::engine`] hands out: the session, mutably, and
/// nothing of the lock.
pub(super) struct Engine<'a, S>(MutexGuard<'a, S>);

impl<S> std::ops::Deref for Engine<'_, S> {
    type Target = S;

    fn deref(&self) -> &S {
        &self.0
    }
}

impl<S> std::ops::DerefMut for Engine<'_, S> {
    fn deref_mut(&mut self) -> &mut S {
        &mut self.0
    }
}

/// [`Gated::engine`]'s refusal: a rolled-back commit could not be retired.
pub(super) struct Held;

impl<S> Gated<S> {
    /// `session` behind its lock; `unfinished` when what ran before it was
    /// opened may have left a rolled-back commit unretired.
    pub(super) fn new(session: S, unfinished: bool) -> Self {
        Self {
            session: Mutex::new(session),
            unfinished: AtomicBool::new(unfinished),
        }
    }

    /// The session, for a call that cannot run a convergence pass.
    pub(super) async fn reading(&self) -> Reading<'_, S> {
        Reading(self.session.lock().await)
    }

    /// The session, for a call that may change a circle: the ONE way to a
    /// `&mut S`.
    ///
    /// When a rolled-back commit may be unretired, `finish` is run first
    /// under the lock, and the session is handed over only if it succeeds.
    pub(super) async fn engine<E>(
        &self,
        finish: impl FnOnce(&S) -> Result<(), E> + Send,
    ) -> Result<Engine<'_, S>, Held> {
        let session = self.session.lock().await;
        if self.unfinished.load(Ordering::Acquire) {
            if finish(&session).is_err() {
                return Err(Held);
            }
            self.unfinished.store(false, Ordering::Release);
        }
        Ok(Engine(session))
    }

    /// Whether some call holds the lock now: how a test's mode source knows
    /// it is being read with the engine held.
    #[cfg(any(test, feature = "test-utils"))]
    pub(super) fn is_held(&self) -> bool {
        self.session.try_lock().is_err()
    }

    /// Says a rolled-back commit may be unretired: the next
    /// [`Self::engine`] retires it before it hands the session over.
    ///
    /// `_held` is the session, which only a guard of this lock can lend:
    /// raised without the lock, this could fall between a finisher's success
    /// and the lowering above, and be erased by it.
    pub(super) fn owe_finish(&self, _held: &S) {
        self.unfinished.store(true, Ordering::Release);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn the_session_is_handed_over_only_once_what_was_owed_is_finished() {
        let gate = Gated::new(7_u32, false);
        // Nothing owed: the finisher is not asked.
        assert!(gate.engine(|_| Err::<(), ()>(())).await.is_ok());

        gate.owe_finish(&*gate.reading().await);
        assert!(
            gate.engine(|_| Err::<(), ()>(())).await.is_err(),
            "the session was handed over with a rollback unfinished",
        );
        assert!(
            gate.engine(|_| Err::<(), ()>(())).await.is_err(),
            "a refusal lowered what was owed",
        );
        assert_eq!(*gate.reading().await, 7, "a refusal holds reads too");

        let mut session = gate
            .engine(|_| Ok::<(), ()>(()))
            .await
            .unwrap_or_else(|Held| panic!("refused after the finish succeeded"));
        *session = 8;
        drop(session);
        assert!(
            gate.engine(|_| Err::<(), ()>(())).await.is_ok(),
            "what was finished is still owed",
        );
        assert_eq!(*gate.reading().await, 8);
    }

    #[tokio::test]
    async fn a_session_opened_after_a_failed_pass_is_owed_its_finish() {
        let gate = Gated::new((), true);
        assert!(gate.engine(|()| Err::<(), ()>(())).await.is_err());
        assert!(gate.engine(|()| Ok::<(), ()>(())).await.is_ok());
    }
}
