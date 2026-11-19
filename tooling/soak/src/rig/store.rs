//! Where a device's stores live and how they are keyed.
//!
//! A device either owns a temporary directory, as every scenario's does, or
//! opens one the caller keeps — a fixture's output, a store another process
//! wrote — which outlives it. And it opens its stores either under the fixed
//! test key, or the way the app does: the session key from the keyring (a mock
//! one, planted with a synthetic secret) through PBKDF2, and an encrypted
//! circle store.

use std::fmt;
use std::path::{Path, PathBuf};

use haven_core::circle::CircleManager;
use haven_core::nostr::mls::storage::use_mock_keyring_with_session_secret_for_test;
use nostr::key::Keys;
use rand::rngs::OsRng;
use rand::RngCore;
use zeroize::Zeroizing;

use crate::rig::{RigError, Step};

/// A device's store directory.
pub enum StoreDir {
    /// The rig's own, removed with the device.
    Temp(tempfile::TempDir),
    /// The caller's, left in place when the device goes.
    Kept(PathBuf),
}

impl StoreDir {
    /// A fresh temporary directory.
    ///
    /// # Errors
    ///
    /// [`RigError::Core`] with [`Step::OpenStore`] if none can be made.
    pub fn temp() -> Result<Self, RigError> {
        tempfile::TempDir::new()
            .map(Self::Temp)
            .map_err(|_| RigError::Core(Step::OpenStore))
    }

    /// The directory itself.
    #[must_use]
    pub fn path(&self) -> &Path {
        match self {
            Self::Temp(dir) => dir.path(),
            Self::Kept(path) => path,
        }
    }
}

// Which kind only: the path names the run's scratch space.
impl fmt::Debug for StoreDir {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Temp(_) => "StoreDir::Temp",
            Self::Kept(_) => "StoreDir::Kept",
        })
    }
}

/// How a device's stores are keyed.
pub enum Keying {
    /// The fixed test key and a plain circle store
    /// (`CircleManager::new_unencrypted`).
    Test,
    /// The app's own opener (`CircleManager::new`): the session secret is
    /// planted in a mock keyring, which the process holds one of, so at most
    /// one production-keyed device opens per process.
    Production {
        /// The raw secret the keyring holds for the MLS store.
        session_secret: Zeroizing<Vec<u8>>,
        /// The circle store's raw `SQLCipher` key, 64 hex digits.
        circles_key_hex: Zeroizing<String>,
    },
}

impl Keying {
    /// Production keying with fresh synthetic material, 32 bytes of each, as
    /// the app mints them: throwaway by construction.
    #[must_use]
    pub fn fresh_production() -> Self {
        let mut session_secret = Zeroizing::new(vec![0u8; 32]);
        OsRng.fill_bytes(session_secret.as_mut_slice());
        let mut circles_key = Zeroizing::new([0u8; 32]);
        OsRng.fill_bytes(circles_key.as_mut());
        Self::Production {
            session_secret,
            circles_key_hex: Zeroizing::new(hex::encode(circles_key.as_ref())),
        }
    }

    /// Opens the stores in `dir` for `keys`, keyed this way.
    ///
    /// # Errors
    ///
    /// [`RigError::Core`] with [`Step::OpenStore`] if the keyring cannot be
    /// planted or the stores cannot be opened.
    pub fn open(&self, dir: &Path, keys: &Keys) -> Result<CircleManager, RigError> {
        let opened = match self {
            Self::Test => CircleManager::new_unencrypted(dir, keys),
            Self::Production {
                session_secret,
                circles_key_hex,
            } => {
                use_mock_keyring_with_session_secret_for_test(session_secret)
                    .map_err(|_| RigError::Core(Step::OpenStore))?;
                CircleManager::new(dir, keys, Some(circles_key_hex.as_str()))
            }
        };
        opened.map_err(|_| RigError::Core(Step::OpenStore))
    }
}

// Which kind only: the material is key material.
impl fmt::Debug for Keying {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Test => "Keying::Test",
            Self::Production { .. } => "Keying::Production",
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_keying_renders_its_kind_and_none_of_its_material() {
        let keying = Keying::fresh_production();
        let Keying::Production {
            session_secret,
            circles_key_hex,
        } = &keying
        else {
            panic!("fresh production keying is production keying");
        };
        let rendered = format!("{keying:?}");
        assert_eq!(rendered, "Keying::Production");
        assert!(!rendered.contains(circles_key_hex.as_str()));
        assert!(!rendered.contains(&hex::encode(session_secret.as_slice())));
        assert_eq!(format!("{:?}", Keying::Test), "Keying::Test");
    }

    #[test]
    fn fresh_production_material_is_full_length_and_never_repeats() {
        let (
            Keying::Production {
                session_secret: one_secret,
                circles_key_hex: one_key,
            },
            Keying::Production {
                session_secret: other_secret,
                circles_key_hex: other_key,
            },
        ) = (Keying::fresh_production(), Keying::fresh_production())
        else {
            panic!("fresh production keying is production keying");
        };
        assert_eq!(one_secret.len(), 32);
        assert_eq!(one_key.len(), 64, "the circle store takes 64 hex digits");
        assert!(one_key.bytes().all(|b| b.is_ascii_hexdigit()));
        assert_ne!(*one_secret, *other_secret);
        assert_ne!(*one_key, *other_key);
    }

    #[test]
    fn a_store_dir_renders_its_kind_and_not_its_path() {
        let temp = StoreDir::temp().expect("a temp dir");
        let path = temp.path().to_string_lossy().into_owned();
        assert_eq!(format!("{temp:?}"), "StoreDir::Temp");
        let kept = StoreDir::Kept(PathBuf::from(&path));
        assert_eq!(kept.path(), Path::new(&path));
        assert_eq!(format!("{kept:?}"), "StoreDir::Kept");
    }

    #[test]
    fn a_kept_dir_outlives_its_store_dir_and_a_temp_one_does_not() {
        let temp = StoreDir::temp().expect("a temp dir");
        let temp_path = temp.path().to_path_buf();
        let outer = tempfile::TempDir::new().expect("a temp dir");
        let kept_path = outer.path().join("kept");
        std::fs::create_dir(&kept_path).expect("make the kept dir");
        let kept = StoreDir::Kept(kept_path.clone());
        drop((temp, kept));
        assert!(!temp_path.exists(), "the rig's own directory goes with it");
        assert!(kept_path.exists(), "the caller's directory stays");
    }
}
