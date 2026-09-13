//! A Rule-14 refusal leaves exactly one greppable trace, carrying no identifier.
//!
//! # Why this needs its own binary
//!
//! [`SESSION_BUSY_MARKER`] is the one Haven-authored token in the tree whose
//! whole purpose is to be searched for in a captured log after a support report.
//! Phase L0 removed every path it used to travel: no log site interpolates an
//! error's `Display` any more (they quote `code()`), and the production caller —
//! `CircleManager::new` — converts the error to `CircleError::Mls`, whose payload
//! no rendering shows. So the marker now reaches a log from exactly one place,
//! the `warn!` inside `LiveSessionGuard::acquire`, and that line is the promise
//! this file pins.
//!
//! The second half of the promise is that the line is a LITERAL: a database path
//! would name the install and the platform, and Rule 15 does not exempt a line
//! because it is rare or because it reports a fault. The captured line is
//! therefore searched for the path, the file stem and the directory it was
//! refused for, in every encoding `assert_no_needles` knows.
//!
//! `capture_haven_log` installs the process-wide logger, which is why this is its
//! own test binary rather than a case inside another one.

use haven_core::nostr::mls::storage::{LiveSessionGuard, SESSION_BUSY_MARKER};

mod helpers;
use helpers::{assert_no_needles, capture_haven_log};

/// A path component that appears nowhere else, so a match is a leak and not a
/// coincidence with the temp directory's own random name.
const NEEDLE_STEM: &str = "needle-zephyr-session";

#[tokio::test]
async fn session_busy_refusal_is_logged_once_with_no_identifier() {
    let dir = tempfile::tempdir().expect("tempdir");
    let db = dir.path().join(format!("{NEEDLE_STEM}.sqlite"));
    let db_display = db.display().to_string();

    let lines = capture_haven_log(async {
        let _held = LiveSessionGuard::acquire(&db).expect("first acquire");
        // The refusal under test: a second live session on one database file is a
        // confidentiality risk (Rule 14), not merely DB contention.
        LiveSessionGuard::acquire(&db).expect_err("a second acquire must be refused");
    })
    .await;

    let marked: Vec<&helpers::LogLine> = lines
        .iter()
        .filter(|l| l.message.contains(SESSION_BUSY_MARKER))
        .collect();
    assert_eq!(
        marked.len(),
        1,
        "the refusal must leave exactly one greppable line — none means a support \
         report has nothing to search for, more than one means the marker is being \
         re-emitted per layer: {lines:?}"
    );

    let line = marked[0];
    // Warn, not debug: the release log silencer caps at Warn, and a line that
    // only exists in debug builds cannot serve a field report.
    assert_eq!(
        line.level,
        log::Level::Warn,
        "the refusal must survive the release log silencer"
    );
    assert!(
        line.target.starts_with("haven_core"),
        "the refusal must be attributed to this crate, not a dependency: {}",
        line.target
    );

    // No identifier, in any encoding: not the database path, not its stem, not
    // the directory the refusal was about.
    assert_no_needles(
        std::slice::from_ref(line),
        &[
            db_display.as_str(),
            NEEDLE_STEM,
            "session.sqlite",
            dir.path()
                .file_name()
                .and_then(std::ffi::OsStr::to_str)
                .expect("the temp directory has a name"),
        ],
    );
}
