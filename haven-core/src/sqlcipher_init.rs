//! Serialises this process's first use of `SQLite`.
//!
//! `sqlite3_initialize` marks the library initialised, releases its mutex, and
//! only then runs `SQLCipher`'s own start-up (`sqlcipher_extra_init`) on the
//! thread that got there first. Until that returns, `PRAGMA key` fails on every
//! other thread, so of two stores opened at process start on two threads — every
//! isolate shares the one loaded library — one could fail to open. Every store
//! open therefore calls [`ensure`] first
//! (`scripts/ci/check_sqlcipher_first_use_gate.sh`). The gap is upstream's:
//! `docs/MDK_UPSTREAM_TRACKER.md`, row T-SQLCIPHER-FIRST-USE.

use std::sync::{Mutex, PoisonError};

static INITIALISED: Mutex<bool> = Mutex::new(false);

/// Runs `SQLite`'s one-time initialisation to completion on the calling thread,
/// once per process; a concurrent caller waits for it, and every later call
/// returns at once.
///
/// Call it before opening a `rusqlite` or `storage-sqlite` connection directly.
///
/// # Errors
///
/// Returns the `rusqlite` error if the in-memory open fails; nothing is
/// recorded then, so the next call tries again. A failure of `SQLCipher`'s own
/// start-up is not visible here and cannot be retried in-process (`SQLite` has
/// already marked itself initialised): every keyed open then fails closed until
/// the process restarts.
pub fn ensure() -> rusqlite::Result<()> {
    run_once(&INITIALISED, || {
        rusqlite::Connection::open_in_memory().map(drop)
    })
}

/// Whether [`ensure`] has completed in this process.
///
/// Read-only, and nothing clears the flag: a test can tell an open that passed
/// the gate from one that did not only in a process that has opened nothing
/// else.
#[cfg(any(test, feature = "test-utils"))]
#[must_use]
pub fn ran() -> bool {
    *INITIALISED.lock().unwrap_or_else(PoisonError::into_inner)
}

/// Holds `done` across `init`: a second caller must wait for the first to
/// FINISH, which a flag checked before `init` would not make it do.
fn run_once<E>(done: &Mutex<bool>, init: impl FnOnce() -> Result<(), E>) -> Result<(), E> {
    // A panic inside `init` leaves the flag unset, which is still the truth.
    let mut done = done.lock().unwrap_or_else(PoisonError::into_inner);
    if !*done {
        init()?;
        *done = true;
    }
    drop(done);
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::sync::TryLockError;

    use super::*;

    #[test]
    fn the_gate_is_held_while_the_first_use_runs() {
        let gate = Mutex::new(false);
        let mut ran = false;

        run_once(&gate, || {
            ran = true;
            assert!(
                matches!(gate.try_lock(), Err(TryLockError::WouldBlock)),
                "a second caller must wait for the first use to finish"
            );
            Ok::<(), ()>(())
        })
        .expect("the first use succeeds");

        assert!(ran);
    }

    #[test]
    fn the_first_use_runs_once() {
        let gate = Mutex::new(false);
        let mut runs = 0;

        for _ in 0..3 {
            run_once(&gate, || {
                runs += 1;
                Ok::<(), ()>(())
            })
            .expect("every call succeeds");
        }

        assert_eq!(runs, 1);
    }

    #[test]
    fn a_failed_first_use_is_reported_and_tried_again() {
        let gate = Mutex::new(false);

        assert_eq!(run_once(&gate, || Err("refused")), Err("refused"));

        let mut retried = false;
        run_once(&gate, || {
            retried = true;
            Ok::<(), &str>(())
        })
        .expect("the retry succeeds");
        assert!(retried, "a failure must not be recorded as done");
    }

    #[test]
    fn a_first_use_that_panicked_is_tried_again() {
        let gate = Mutex::new(false);
        let panicked = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            run_once(&gate, || -> Result<(), ()> { panic!("first use") })
        }));
        assert!(panicked.is_err());

        let mut retried = false;
        run_once(&gate, || {
            retried = true;
            Ok::<(), ()>(())
        })
        .expect("the retry succeeds");
        assert!(retried, "a poisoned gate must not refuse every later open");
    }

    #[test]
    fn sqlite_initialises_and_every_later_call_succeeds() {
        ensure().expect("the first use");
        ensure().expect("a later call");
        assert!(ran());
    }
}
