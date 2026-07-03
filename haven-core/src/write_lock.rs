//! Process-global advisory writer lock excluding concurrent MLS/MDK writers.
//!
//! # Why this exists (the 2026-07-02 revert)
//!
//! Both `circles.db` and MDK's `haven_mdk.db` run rollback-journal with
//! `busy_timeout = 0`. The foreground FGS publish path is an **authoring** MDK
//! writer (`encrypt_location` → `create_message`, plus the receiver auto-commit
//! finalize) and today takes no lock. If a background receive-only catch-up
//! sweep holds `haven_mdk.db` while the foreground authors, the foreground write
//! gets `SQLITE_BUSY` → MDK records the message `Failed` → it is never
//! reprocessed → the dropped membership commit is a **fork on the writer side**.
//! The receive-only sweep's four fork-safety barriers protect only the *sweep*,
//! not the *other* writer. This lock is that missing exclusion. See
//! `docs/M7_BACKGROUND_SHARING_PLAN.md` §B, §E, §F.
//!
//! # Why a Rust `static` is the right primitive (cross-isolate / cross-engine)
//!
//! A Rust `static` lives **once per OS process** and is shared by every Flutter
//! isolate/engine that loads the same dylib:
//!
//! - **Android:** the FGS isolate and the `WorkManager` engine are separate Dart
//!   isolates in the *same* process; both load the one Rust dylib, so both see
//!   this one `WRITER_LOCK`.
//! - **iOS:** the foreground engine and the SLC / `BGTask` headless engine are
//!   separate `FlutterEngine`s in the *same* process; again one dylib, one lock.
//!
//! This is the enabling fact: the lock works **even when the in-memory live-sync
//! `SESSION` is empty** (a cold background wake), which is exactly the situation
//! where the reverted draft's "shared in-memory gate" could not exist.
//!
//! # Lock type
//!
//! `std::sync::Mutex<()>` — **not** `tokio::sync::Mutex`. The authoring FFI
//! methods are synchronous / `spawn_blocking`; acquiring an async mutex from a
//! sync context would deadlock. The protected data is `()`, so a panic while the
//! guard is held cannot corrupt any invariant — poisoning is therefore recovered
//! and ignored (see [`recover`]).
//!
//! # Granularity (load-bearing — this is the whole point)
//!
//! The lock is wrapped around the **narrowest scope**: each individual low-level
//! `self.mdk.<write>()` call site, **never** a whole authoring method. Authoring
//! methods call each other (`add_members_with_welcomes` → `add_members`;
//! `converge_commit` → `finalize_pending_commit` / `clear_pending_commit`), and
//! this `Mutex` is **not reentrant** — wrapping whole methods would deadlock.
//! Wrapping the individual MDK write avoids re-entrancy because MDK calls do not
//! nest back into other lock-taking Haven methods. The guard is **never** held
//! across an `.await` (relay I/O stays outside the critical section).

use std::sync::{Mutex, MutexGuard};

/// The one process-global writer lock. See the module docs.
static WRITER_LOCK: Mutex<()> = Mutex::new(());

/// Recovers a possibly-poisoned guard.
///
/// The protected data is `()`, so a panic while the lock was held left no
/// invariant broken; recovering the guard is always safe here.
fn recover<'a, T>(
    result: Result<MutexGuard<'a, T>, std::sync::PoisonError<MutexGuard<'a, T>>>,
) -> MutexGuard<'a, T> {
    result.unwrap_or_else(std::sync::PoisonError::into_inner)
}

/// Acquires the writer lock for a **priority authoring** MDK write, blocking
/// until it is available.
///
/// Every foreground/authoring MDK write path holds one of these for the brief
/// duration of the underlying `self.mdk.<write>()` call (plus the co-located
/// `circles.db` marker write it guards). The returned guard MUST NOT be held
/// across an `.await`.
///
/// The returned value is an opaque guard; drop it to release the lock.
#[must_use = "the lock is released when the returned guard is dropped"]
pub fn acquire_authoring() -> MutexGuard<'static, ()> {
    recover(WRITER_LOCK.lock())
}

/// Attempts to acquire the writer lock for a **background receive-only** sweep
/// without blocking.
///
/// Returns `None` on contention (an authoring writer holds the lock). The sweep
/// then yields losslessly — it treats `None` exactly like the existing
/// `Skipped` outcome: it does not decrypt, does not advance the cursor, and the
/// event is re-fetched on the next sweep via the contiguous-prefix cursor.
///
/// The returned value is an opaque guard; drop it to release the lock.
#[must_use = "None means contention; a Some guard releases the lock when dropped"]
pub fn try_acquire_background() -> Option<MutexGuard<'static, ()>> {
    match WRITER_LOCK.try_lock() {
        Ok(guard) => Some(guard),
        Err(std::sync::TryLockError::WouldBlock) => None,
        // Poisoned-but-uncontended: recover the guard (protected data is `()`).
        Err(std::sync::TryLockError::Poisoned(e)) => Some(e.into_inner()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `WRITER_LOCK` is process-global and shared by every parallel test that
    /// authors; serialize these lock-observation tests against each other so
    /// one's held guard cannot perturb the other's post-release assertion.
    /// (Cross-test contention from OTHER modules' authoring tests is absorbed by
    /// the bounded retry below — a transient miss there is the correct behavior.)
    static SERIALIZE: Mutex<()> = Mutex::new(());

    /// Bounded-retry acquire of the background guard: absorbs transient
    /// contention from unrelated parallel authoring tests (each holds the global
    /// lock only briefly), which is itself the correct lossless-yield behavior.
    fn eventually_acquire_background() -> bool {
        for _ in 0..2000 {
            if try_acquire_background().is_some() {
                return true;
            }
            // A short sleep (not a bare `yield_now`) lets the scheduler drain
            // concurrent lock holders under the full parallel test suite.
            std::thread::sleep(std::time::Duration::from_millis(1));
        }
        false
    }

    /// The background acquirer must yield (return `None`) while an authoring
    /// guard is held on this thread — the contention path that makes the sweep
    /// no-op. (Deterministic: same-thread `try_lock` cannot re-enter.)
    #[test]
    fn background_yields_while_authoring_held() {
        let _serialize = SERIALIZE
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let authoring = acquire_authoring();
        assert!(
            try_acquire_background().is_none(),
            "background must yield while an authoring guard is held"
        );
        drop(authoring);
        assert!(
            eventually_acquire_background(),
            "background acquires once the authoring guard is released"
        );
    }

    /// After a poisoning panic while the lock was held, both acquirers must
    /// still succeed (the protected `()` cannot be corrupted). This
    /// permanently poisons the process-global lock, exercising the recovery
    /// leg every other authoring acquirer relies on.
    #[test]
    fn poison_is_recovered() {
        let _serialize = SERIALIZE
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let _ = std::panic::catch_unwind(|| {
            let _guard = acquire_authoring();
            panic!("poison the lock");
        });
        // Blocking acquire recovers the poisoned guard.
        drop(acquire_authoring());
        // try-acquire also recovers it (poisoned leg).
        assert!(eventually_acquire_background());
    }
}
