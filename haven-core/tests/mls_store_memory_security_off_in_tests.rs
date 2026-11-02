//! No test fixture's MLS store turns `SQLCipher`'s `cipher_memory_security` on.
//!
//! The setting is process-wide and can only be turned on, and while it is on
//! every `SQLite` allocation is `mlock`ed and scrubbed under one process-global
//! mutex: one fixture open that turns it on serialises every test thread of its
//! binary behind that mutex, which made the library tests four times slower. The app's
//! own store keeps it on (`mls_store_memory_security_on`). The one test in its
//! binary that opens a store (the `helpers` log-capture self-tests compiled
//! beside it open none), so no other open can set it first.

mod helpers;

use haven_core::circle::CircleManager;
use haven_core::nostr::mls::{SessionManager, StorageConfig};
use nostr::Keys;

#[tokio::test]
async fn no_test_fixture_turns_cipher_memory_security_on() {
    haven_core::sqlcipher_init::ensure().expect("SQLite initialises");
    let probe = rusqlite::Connection::open_in_memory().expect("a fresh connection");
    let memory_security = || -> String {
        probe
            .query_row("PRAGMA cipher_memory_security", [], |row| row.get(0))
            .expect("the pragma reads back")
    };
    let dirs: Vec<_> = (0..3)
        .map(|_| tempfile::TempDir::new().expect("temp dir"))
        .collect();

    let session = SessionManager::new_unencrypted(dirs[0].path(), &Keys::generate())
        .expect("the test session opens");
    let manager = CircleManager::new_unencrypted(dirs[1].path(), &Keys::generate())
        .expect("the test circle manager opens");
    let in_memory = StorageConfig::in_memory_storage().expect("the in-memory store opens");
    keyring_core::set_default_store(
        keyring_core::mock::Store::new().expect("mock store creation never fails"),
    );
    let keyring_keyed = StorageConfig::new(dirs[2].path())
        .open_encrypted_storage()
        .expect("the keyring-keyed test store opens");
    let mut fixture = helpers::setup_circle(2, &["wss://memory-security.example.com"]).await;
    let halted = fixture
        .members
        .pop()
        .expect("a member")
        .halted(&fixture.group);
    let reopened = helpers::CircleMember::new().reopen();

    assert_eq!(
        memory_security(),
        "0",
        "a test fixture's MLS store turned cipher_memory_security on for its \
         whole test binary"
    );
    drop((
        session,
        manager,
        in_memory,
        keyring_keyed,
        fixture,
        halted,
        reopened,
        dirs,
    ));
}
