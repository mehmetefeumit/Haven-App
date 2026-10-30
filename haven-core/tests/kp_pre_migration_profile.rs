//! Which on-relay `KeyPackage` the maintenance tick may treat as this
//! account's own pre-reset package (`kp_event_is_pre_migration`): one carrying
//! the pre-migration (Legacy) account-identity proof, as every package a v0.9.x
//! Haven published does — and never a current one, which another live client
//! may own.

mod helpers;

use cgka_engine::account_identity_proof::account_identity_proof_extension;
use haven_core::nostr::mls::{HavenIdentityProofSigner, SessionManager};
use haven_core::relay::maintenance::kp_event_is_pre_migration;
use helpers::{cleanup_dir, create_key_package_event, unique_temp_dir};
use nostr::{EventBuilder, Keys, Kind, Tag};
use openmls::prelude::tls_codec::Serialize as _;
use openmls::prelude::*;
use openmls_basic_credential::SignatureKeyPair;
use openmls_rust_crypto::OpenMlsRustCrypto;

/// A kind-30443 carrying a package whose leaf binds the account with the
/// pre-migration proof extension (0xF2F1), built the way a v0.9.x engine did.
fn pre_migration_key_package_event(keys: &Keys) -> nostr::Event {
    let ciphersuite = Ciphersuite::MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519;
    let provider = OpenMlsRustCrypto::default();
    let signer = SignatureKeyPair::new(ciphersuite.signature_algorithm()).expect("signer");
    let account = keys.public_key().to_bytes();
    let proof = account_identity_proof_extension(
        &account,
        signer.public(),
        ciphersuite,
        ciphersuite.signature_algorithm(),
        &HavenIdentityProofSigner::new(keys),
    )
    .expect("legacy proof");
    let bundle = KeyPackage::builder()
        .leaf_node_capabilities(Capabilities::new(
            None,
            Some(&[ciphersuite]),
            Some(&[ExtensionType::Unknown(0xF2F1)]),
            None,
            None,
        ))
        .leaf_node_extensions(Extensions::single(proof).expect("one extension"))
        .build(
            ciphersuite,
            &provider,
            &signer,
            CredentialWithKey {
                credential: BasicCredential::new(account.to_vec()).into(),
                signature_key: signer.public().into(),
            },
        )
        .expect("legacy key package");
    let message: MlsMessageOut = bundle.key_package().clone().into();
    let bytes = message.tls_serialize_detached().expect("serialize");
    EventBuilder::new(
        Kind::Custom(30443),
        nostr::base64::Engine::encode(&nostr::base64::engine::general_purpose::STANDARD, bytes),
    )
    .tags([Tag::identifier("a".repeat(64))])
    .sign_with_keys(keys)
    .expect("sign")
}

#[tokio::test]
async fn only_a_package_with_the_pre_migration_proof_is_read_as_pre_reset() {
    let keys = Keys::generate();
    assert!(
        kp_event_is_pre_migration(&pre_migration_key_package_event(&keys)),
        "a v0.9.x package is this account's pre-reset self"
    );

    let dir = unique_temp_dir("kp_pre_migration_current");
    let session = SessionManager::new_unencrypted(&dir, &keys).expect("session");
    let current =
        create_key_package_event(&session, &keys, &["wss://relay.test.com".to_string()]).await;
    assert!(
        !kp_event_is_pre_migration(&current),
        "a current package may be another live client's, and is never taken over"
    );

    let mut garbled = current;
    garbled.content = "not a key package".to_string();
    assert!(!kp_event_is_pre_migration(&garbled));
    cleanup_dir(&dir);
}
