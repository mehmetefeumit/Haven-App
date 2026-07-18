//! DELETED-WITH-SUBJECT (Dark Matter, DM-5a).
//!
//! This suite empirically TUNED Haven's hand-rolled `COMMIT_SETTLE_WINDOW_SECS`
//! settle window — it sampled the in-process `publish → observe` pipeline latency
//! and asserted the settle window sat safely above p99. That settle window is
//! DELETED: the Dark Matter engine owns convergence internally (deterministic
//! `CommitOrderingKey` branch selection + durable out-of-order buffering), and
//! Haven configures `settlement_quiescence_ms = 0` (immediate settlement). There
//! is no Haven-side settle window left to tune, so the measurement has no subject.
//!
//! The surviving invariant — that two engines converge over one relay — is
//! re-expressed transport-independently in
//! `live_sync_two_engine_converge_e2e::two_engines_converge_over_one_relay_via_the_engine_loop`.
