//! `KeyPackage`s the product never mints — expired, not last-resort,
//! pre-migration — built with `OpenMLS` directly, so validation, ranking and
//! deletion are driven against real bytes. They live here, outside
//! `haven-core/src`, because setting a lifetime is banned in every shipped
//! path (`scripts/ci/check_no_kp_lifetime_override.sh`).
//!
//! The engine's capability helpers are private, so a twin copies the leaf
//! capabilities and extensions of a package the account's own session minted
//! and re-signs the account-identity proof (component 0x8009) over a fresh MLS
//! signer with the account's Nostr keys. The MLS signer and the identity key
//! differ by construction (Security Rule 1).

use cgka_engine::account_identity_proof::{
    account_identity_proof_component, account_identity_proof_extension,
};
use cgka_traits::app_components::{
    decode_components_list, encode_components_list, ACCOUNT_IDENTITY_PROOF_COMPONENT_ID,
    APP_COMPONENTS_COMPONENT_ID,
};
use nostr::Keys;
use openmls::prelude::tls_codec::{Deserialize as _, Serialize as _};
use openmls::prelude::{
    AppDataDictionaryExtension, BasicCredential, Capabilities, Ciphersuite, CredentialWithKey,
    Extension, ExtensionType, Extensions, KeyPackage, Lifetime, MlsMessageBodyIn, MlsMessageIn,
    MlsMessageOut, OpenMlsProvider, ProtocolVersion,
};
use openmls_basic_credential::SignatureKeyPair;
use openmls_rust_crypto::OpenMlsRustCrypto;

use haven_core::nostr::mls::HavenIdentityProofSigner;
use haven_core::relay::maintenance::now_secs;

/// How a twin differs from the package it copies.
#[derive(Clone, Copy)]
pub struct Twin {
    /// The MLS `Lifetime` to carry; `None` keeps the template's.
    pub lifetime: Option<Lifetime>,
    /// Whether it keeps the template's last-resort marker.
    pub last_resort: bool,
    /// An app component the twin does not advertise support for, so a circle
    /// that requires it cannot admit the twin.
    pub without_component: Option<u16>,
}

/// A lifetime that ended an hour ago, one hour wide (inside the accepted
/// range, so only its validity can refuse it).
pub fn expired_lifetime() -> Lifetime {
    let now = now_secs();
    Lifetime::init(now - 7_200, now - 3_600)
}

/// A minted twin: its wire bytes and its `KeyPackageRef`.
pub struct Minted {
    /// The framed `MLSMessage(mls_key_package)` bytes a 30443 carries.
    pub bytes: Vec<u8>,
    /// The package's `KeyPackageRef`.
    pub key_package_ref: Vec<u8>,
}

/// A Current-profile package of `keys`'s account shaped like `template` (wire
/// bytes of a package that account's session minted), as `twin` says. Its
/// private bundle is written to `provider`'s storage.
pub fn mint_like<P: OpenMlsProvider>(
    provider: &P,
    template: &[u8],
    keys: &Keys,
    twin: Twin,
) -> Minted {
    let MlsMessageBodyIn::KeyPackage(template) = MlsMessageIn::tls_deserialize_exact(template)
        .expect("a framed MLS message")
        .extract()
    else {
        panic!("the template is a KeyPackage");
    };
    let template = template
        .validate(provider.crypto(), ProtocolVersion::Mls10)
        .expect("a package the session just minted validates");
    let ciphersuite = template.ciphersuite();
    let signer = SignatureKeyPair::new(ciphersuite.signature_algorithm()).expect("mls signer");
    let identity = keys.public_key().to_bytes().to_vec();
    let proof = account_identity_proof_component(
        &identity,
        &signer.to_public_vec(),
        ciphersuite,
        ciphersuite.signature_algorithm(),
        now_secs(),
        &HavenIdentityProofSigner::new(keys),
    )
    .expect("account identity proof");
    let mut leaf_extensions = template.leaf_node().extensions().clone();
    let mut dictionary = leaf_extensions
        .app_data_dictionary()
        .expect("a current leaf carries a dictionary")
        .dictionary()
        .clone();
    dictionary.insert(ACCOUNT_IDENTITY_PROOF_COMPONENT_ID, proof);
    if let Some(dropped) = twin.without_component {
        let mut supported = decode_components_list(
            dictionary
                .get(&APP_COMPONENTS_COMPONENT_ID)
                .expect("a current leaf lists its components"),
        )
        .expect("decode the supported components");
        assert!(supported.remove(&dropped), "the template supports it");
        dictionary.insert(
            APP_COMPONENTS_COMPONENT_ID,
            encode_components_list(&supported),
        );
    }
    leaf_extensions
        .add_or_replace(Extension::AppDataDictionary(
            AppDataDictionaryExtension::new(dictionary),
        ))
        .expect("replace the dictionary");
    let mut builder = KeyPackage::builder()
        .leaf_node_capabilities(template.leaf_node().capabilities().clone())
        .leaf_node_extensions(leaf_extensions)
        .key_package_lifetime(twin.lifetime.unwrap_or_else(|| *template.life_time()));
    if twin.last_resort {
        builder = builder.key_package_extensions(template.extensions().clone());
    }
    let bundle = builder
        .build(
            ciphersuite,
            provider,
            &signer,
            CredentialWithKey {
                credential: BasicCredential::new(identity).into(),
                signature_key: signer.public().into(),
            },
        )
        .expect("build the twin");
    Minted {
        bytes: MlsMessageOut::from(bundle.key_package().clone())
            .tls_serialize_detached()
            .expect("serialize"),
        key_package_ref: bundle
            .key_package()
            .hash_ref(provider.crypto())
            .expect("key package ref")
            .as_slice()
            .to_vec(),
    }
}

/// [`mint_like`] with a throwaway provider: the private bundle is discarded.
pub fn mint_unowned_like(template: &[u8], keys: &Keys, twin: Twin) -> Minted {
    mint_like(&OpenMlsRustCrypto::default(), template, keys, twin)
}

/// A package whose leaf binds `keys`'s account with the pre-migration proof
/// extension (0xF2F1), built the way an MDK v0.9.x engine did.
pub fn pre_migration(keys: &Keys) -> Vec<u8> {
    let ciphersuite = Ciphersuite::MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519;
    let provider = OpenMlsRustCrypto::default();
    let signer = SignatureKeyPair::new(ciphersuite.signature_algorithm()).expect("mls signer");
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
    MlsMessageOut::from(bundle.key_package().clone())
        .tls_serialize_detached()
        .expect("serialize")
}
