//! A removal's members as the circle store keeps them, and the commits the
//! removal tests make: shared by the re-queue and the re-issue tests.

use haven_core::nostr::mls::types::{GroupId, SessionEffects};

use super::stranded::staged;
use super::CircleMember;

/// `member`'s circle store, opened beside its own handle.
pub fn store(member: &CircleMember) -> rusqlite::Connection {
    haven_core::sqlcipher_init::ensure().expect("SQLite initialises");
    rusqlite::Connection::open(
        member
            .dir
            .path()
            .join(haven_core::circle::CIRCLES_DB_FILENAME),
    )
    .expect("the circle store opens")
}

/// The members a removal set aside unmade holds the circle for — kept, and
/// taken out by no commit `member` applied — as hex, sorted.
pub fn held(member: &CircleMember) -> Vec<String> {
    let store = store(member);
    let mut statement = store
        .prepare("SELECT member FROM removal_targets WHERE gone_epoch IS NULL")
        .expect("the table exists");
    let mut held = statement
        .query_map([], |row| row.get::<_, Vec<u8>>(0).map(hex::encode))
        .expect("the targets are read")
        .collect::<Result<Vec<_>, _>>()
        .expect("each target is read");
    held.sort();
    held
}

/// `admins` become the circle's admins, by `by`'s commit, which each of
/// `others` applies.
pub async fn make_admins(
    by: &CircleMember,
    others: &[&CircleMember],
    group: &GroupId,
    admins: &[&CircleMember],
) {
    let keys: Vec<[u8; 32]> = admins
        .iter()
        .map(|admin| admin.keys.public_key().to_bytes())
        .collect();
    let (event, pending) = staged(
        &by.session()
            .update_admin_policy(group, &keys)
            .await
            .expect("the admins change"),
    );
    by.session()
        .confirm_published(pending)
        .await
        .expect("applied");
    for other in others {
        other
            .session()
            .process_event_settled_for_test(&event)
            .await
            .expect("applied");
    }
}

/// `by`'s commit of `effects`, confirmed: its event.
pub async fn confirmed(by: &CircleMember, effects: &SessionEffects) -> nostr::Event {
    let (event, pending) = staged(effects);
    by.session()
        .confirm_published(pending)
        .await
        .expect("applied");
    event
}
