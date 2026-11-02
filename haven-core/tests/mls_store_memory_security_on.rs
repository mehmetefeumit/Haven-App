//! The app's MLS store runs with `SQLCipher`'s `cipher_memory_security` on.
//!
//! Opened through `SessionManager::new`, the session opener the app's
//! `CircleManager::new` calls, with the keyring key it provisions, and
//! nothing else: a release build's `circles.db` turns the setting on itself,
//! so a test that opened it too would pass whatever the MLS store did. The
//! setting is process-wide and can only be turned on, so this is the one test
//! in its binary: no other open can set it first.

use haven_core::nostr::mls::SessionManager;
use nostr::Keys;

#[test]
fn the_production_mls_store_turns_cipher_memory_security_on() {
    haven_core::sqlcipher_init::ensure().expect("SQLite initialises");
    keyring_core::set_default_store(
        keyring_core::mock::Store::new().expect("mock store creation never fails"),
    );
    let dir = tempfile::TempDir::new().expect("temp dir");

    let probe = rusqlite::Connection::open_in_memory().expect("a fresh connection");
    let memory_security = || -> String {
        probe
            .query_row("PRAGMA cipher_memory_security", [], |row| row.get(0))
            .expect("the pragma reads back")
    };
    assert_eq!(memory_security(), "0", "premise: nothing has turned it on");

    let session =
        SessionManager::new(dir.path(), &Keys::generate()).expect("the production session opens");
    drop(session);

    assert_eq!(
        memory_security(),
        "1",
        "the production MLS store no longer turns cipher_memory_security on"
    );
}
