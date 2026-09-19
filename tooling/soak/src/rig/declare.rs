//! Declaring what the rig minted, so the scanner can search for it.
//!
//! A value the rig minted and never declared is one the needle scan cannot look
//! for: the structural rules still catch most SHAPES, but a circle name is just
//! a word and a relay endpoint is just a URL. The world therefore declares
//! every device, circle and relay it creates through this seam, and the run
//! attaches the seam once — so a circle an ARM builds mid-run is declared by
//! the same path that declared the ones the world was built with, rather than
//! by a caller remembering to.
//!
//! The trait is here rather than beside the manifest because the world is what
//! creates the values: the sink is environment, like the other three planes,
//! and a world built by a test that has no manifest simply has none attached.

use crate::rig::RigError;

/// Where a world declares the values it mints.
pub trait DeclareSink: Send + Sync {
    /// Declares one device's identity: its secret key in the raw encoding a
    /// manifest must be able to search for, and its public key.
    ///
    /// # Errors
    ///
    /// [`RigError::DeclarationRefused`] if the class will not take the value.
    fn declare_device(&self, secret_hex: &str, pubkey_hex: &str) -> Result<(), RigError>;

    /// Declares one circle: both group ids and the name the MLS group data
    /// carries.
    ///
    /// # Errors
    ///
    /// [`RigError::DeclarationRefused`] if a class will not take its value.
    fn declare_circle(
        &self,
        mls_group_id_hex: &str,
        nostr_group_id_hex: &str,
        name: &str,
    ) -> Result<(), RigError>;

    /// Declares one relay endpoint.
    ///
    /// # Errors
    ///
    /// [`RigError::DeclarationRefused`] if the class will not take the value.
    fn declare_relay(&self, url: &str) -> Result<(), RigError>;
}
