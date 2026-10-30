//! Captures the log lines `haven-core` itself emits on the current thread, for
//! the lib tests that prove a log line carries no identifier (Rule 15).
//!
//! One logger per process: every lib test that captures goes through here.

/// Captures `log` records emitted on the CURRENT thread while armed.
///
/// Thread-local, so a test that arms it sees only its own records however
/// many other tests run beside it; the code under test must run on the test's
/// own current-thread runtime for its lines to land here.
struct ThreadLocalCapture;

thread_local! {
    static CAPTURED: std::cell::RefCell<Option<Vec<String>>> =
        const { std::cell::RefCell::new(None) };
}

impl log::Log for ThreadLocalCapture {
    fn enabled(&self, _metadata: &log::Metadata<'_>) -> bool {
        true
    }

    fn log(&self, record: &log::Record<'_>) {
        // Haven's own lines only. Everything else on this thread belongs to
        // the in-process relay and the WebSocket stack, which log whole
        // frames at trace — including the relay's own refusal prose. What
        // this app promises about its diagnostics is what THIS crate
        // writes.
        if !record.target().starts_with("haven_core") {
            return;
        }
        CAPTURED.with_borrow_mut(|captured| {
            if let Some(lines) = captured.as_mut() {
                lines.push(record.args().to_string());
            }
        });
    }

    fn flush(&self) {}
}

/// Runs `body` with capture armed on this thread and returns what it
/// logged.
pub async fn capture_log_lines(body: impl std::future::Future<Output = ()>) -> Vec<String> {
    static INSTALL: std::sync::Once = std::sync::Once::new();
    /// Whether OUR logger won the process-wide slot. `log` allows exactly
    /// one logger per process and reports the loser only as an `Err` from
    /// `set_boxed_logger` — a value a `let _ =` throws away. Any future
    /// helper that installs its own logger would therefore make this one
    /// capture NOTHING, and the anti-vacuity assertions below would be the
    /// only thing standing between that and a silently green test. Record
    /// the verdict and fail on it directly instead.
    static OWNS_LOGGER: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
    INSTALL.call_once(|| {
        OWNS_LOGGER.store(
            log::set_boxed_logger(Box::new(ThreadLocalCapture)).is_ok(),
            std::sync::atomic::Ordering::SeqCst,
        );
        log::set_max_level(log::LevelFilter::Trace);
    });
    assert!(
        OWNS_LOGGER.load(std::sync::atomic::Ordering::SeqCst),
        "another logger already owns this process, so this capture sees \
         nothing at all. `log` permits exactly one; whoever installed the \
         other one has to route through ThreadLocalCapture instead.",
    );

    CAPTURED.with_borrow_mut(|captured| *captured = Some(Vec::new()));
    body.await;
    CAPTURED
        .with_borrow_mut(Option::take)
        .expect("capture was armed above")
}
