//! What a store written in one run needs to be reopened in the next: its own
//! directory, the app's keying, and its relays at the same addresses.
//!
//! Its own binary, because a production-keyed open turns `SQLCipher`'s
//! process-wide memory security on and installs a process-wide mock keyring,
//! and the port test binds a fixed port no other test may race for.

use std::path::Path;
use std::time::Duration;

use haven_core::nostr::mls::storage::{
    is_session_live, session_sqlcipher_key_for_test, StorageConfig,
};
use haven_soak::nemesis::types::Fault;
use haven_soak::relay::{SimRelay, FIXED_PORTS};
use haven_soak::rig::{
    kill_and_reopen, poll_until, DeviceTag, Keying, KillKind, RelayPlane, RelayTag, RigError,
    SimDevice, StoreDir,
};
use nostr::key::Keys;
use tokio::io::AsyncReadExt;
use tokio::net::TcpStream;

/// Far past a task abort on an idle runtime: a miss is a listener that never
/// closed.
const RELEASE_BOUND: Duration = Duration::from_secs(5);

fn open_in(dir: StoreDir, keys: Keys, keying: Keying) -> Result<SimDevice, RigError> {
    let relays = vec!["ws://127.0.0.1:1".to_string()];
    SimDevice::open_in(
        DeviceTag::new(0),
        relays
            .iter()
            .map(|url| (url.clone(), url.clone()))
            .collect(),
        relays.clone(),
        (relays.clone(), relays),
        dir,
        keys,
        keying,
    )
}

/// The circle store's first page: `SQLite`'s plain header, or ciphertext.
fn circle_store_is_plain(dir: &Path) -> bool {
    let bytes = std::fs::read(dir.join(haven_core::circle::CIRCLES_DB_FILENAME))
        .expect("the circle store exists");
    bytes.starts_with(b"SQLite format 3\0")
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_production_keyed_device_opens_reopens_and_keeps_its_directory() {
    let outer = tempfile::TempDir::new().expect("a temp dir");
    let dir = outer.path().join("device");
    let keys = Keys::generate();
    let keying = Keying::fresh_production();
    let Keying::Production { session_secret, .. } = &keying else {
        panic!("fresh production keying is production keying");
    };
    let session_key = session_sqlcipher_key_for_test(session_secret).expect("the session key");

    let mut device = open_in(StoreDir::Kept(dir.clone()), keys.clone(), keying)
        .expect("the app's opener opens a new store");
    let minted = device.mint_key_package().await;
    assert!(minted.is_ok(), "a production-keyed session works");
    assert!(
        !circle_store_is_plain(&dir),
        "production keying encrypts the circle store"
    );
    // The session store answers to the key the app derives from the secret,
    // and to no other.
    let db = StorageConfig::new(&dir).database_path();
    let read = |key| haven_core::nostr::mls::storage::ungrouped_openmls_labels_for_test(&db, key);
    assert!(read(&session_key).is_ok_and(|labels| !labels.is_empty()));
    let test_key = StorageConfig::test_sqlcipher_key().expect("the test key");
    assert!(read(&test_key).is_err(), "the test key does not open it");

    kill_and_reopen(&mut device, KillKind::Hard)
        .await
        .expect("a restart reopens the store keyed as it was opened");
    assert!(device.session_is_live().expect("liveness"));
    drop(device);
    assert!(
        !is_session_live(&db).expect("liveness"),
        "the session went with its device, so the refusal below is the key's"
    );

    assert!(dir.exists(), "a kept directory outlives its device");
    let reopened = open_in(StoreDir::Kept(dir.clone()), keys, Keying::Test);
    assert!(
        reopened.is_err(),
        "a production-keyed store does not open under the test key"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_test_keyed_device_in_a_kept_directory_leaves_plain_stores_behind() {
    let outer = tempfile::TempDir::new().expect("a temp dir");
    let dir = outer.path().join("device");
    let keys = Keys::generate();
    let device = open_in(StoreDir::Kept(dir.clone()), keys.clone(), Keying::Test)
        .expect("a test-keyed device opens");
    let db = device.session_db_path();
    drop(device);
    assert!(!is_session_live(&db).expect("liveness"));
    assert!(circle_store_is_plain(&dir));
    let again = open_in(StoreDir::Kept(dir), keys, Keying::Test);
    assert!(
        again.is_ok(),
        "the same directory reopens as the same device"
    );
}

/// One test, because the port is fixed: two would race for it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_plane_pinned_to_a_port_serves_there_and_frees_it_when_it_goes() {
    let port = *FIXED_PORTS.end();
    assert!(
        matches!(
            SimRelay::start_on(RelayTag::new(0), 0).await,
            Err(RigError::ShapeMismatch)
        ),
        "only a fixed port may be asked for"
    );
    assert!(matches!(
        SimRelay::start_on(RelayTag::new(0), *FIXED_PORTS.start() - 1).await,
        Err(RigError::ShapeMismatch)
    ));

    let mut plane = SimRelay::start_on(RelayTag::new(0), port)
        .await
        .expect("a free fixed port binds");
    // Compared, never rendered: a relay address is an identifier.
    assert!(
        plane.url() == format!("ws://127.0.0.1:{port}"),
        "the canonical endpoint is the pinned port"
    );
    assert!(
        SimRelay::start_on(RelayTag::new(1), port).await.is_err(),
        "a bound port is not bound twice"
    );

    // The endpoint closes a connection first, so the port is held in the
    // closing states a server's side of a connection goes through.
    plane
        .apply(Fault::ColdFirstConnect)
        .await
        .expect("the fault arms");
    let mut client = TcpStream::connect(("127.0.0.1", port))
        .await
        .expect("the endpoint accepts");
    let mut byte = [0u8; 1];
    assert_eq!(
        client.read(&mut byte).await.expect("the close is read"),
        0,
        "the endpoint closed the connection itself"
    );
    drop(client);
    // A plane's listener goes with the task that owns it, an abort that lands
    // on a worker's next poll; across runs, with the process that held it.
    drop(plane);
    let released = poll_until(RELEASE_BOUND, Duration::from_millis(5), || async {
        Ok(TcpStream::connect(("127.0.0.1", port)).await.is_err())
    })
    .await
    .expect("a connect attempt reads");
    assert!(released.is_some(), "the endpoint stops accepting");

    let again = SimRelay::start_on(RelayTag::new(0), port).await;
    assert!(
        again.is_ok(),
        "the next run binds the port its stores name, whatever its closed connections hold"
    );
}
