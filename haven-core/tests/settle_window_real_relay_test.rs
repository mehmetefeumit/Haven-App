//! DELETED-WITH-SUBJECT + FOLDED (Dark Matter, DM-5a).
//!
//! This was the authoritative real-`strfry` MEASUREMENT behind
//! `COMMIT_SETTLE_WINDOW_SECS`: it drove the `publish → observe` latency probe
//! through a real strfry daemon (env-gated on `HAVEN_E2E_RELAY`) to justify
//! Haven's settle-window lower bound. Both the settle window and its latency
//! sensitivity are DELETED under Dark Matter.
//!
//! # Why the real-relay proof folds onto the in-process relay
//!
//! The pre-migration settle window's CORRECTNESS depended on the window exceeding
//! the relay's real p99 latency (a window MISS forked permanently), so the
//! authoritative number had to come from a real strfry. The Dark Matter engine
//! owns convergence internally — deterministic `CommitOrderingKey` branch
//! selection + durable out-of-order buffering — which is TRANSPORT-INDEPENDENT:
//! convergence correctness no longer depends on any relay-latency-vs-window
//! relationship (with `settlement_quiescence_ms = 0` there is no window at all; a
//! late sibling triggers a deterministic reorg, never a permanent fork). So the
//! real-relay CONVERGENCE proof no longer needs a real strfry to be meaningful,
//! and is re-anchored on the in-process `MockRelay` socket in
//! `live_sync_two_engine_converge_e2e::two_engines_converge_over_one_relay_via_the_engine_loop`
//! (a member's commit, published to a real relay socket, is received + converged
//! by the peer engine end-to-end), which preserves equivalent proof value.
