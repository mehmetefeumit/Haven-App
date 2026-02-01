//! Secure storage abstraction for identity key material.
//!
//! This module defines the [`SecureKeyStorage`] trait for platform-agnostic
//! secure storage of sensitive key material. Implementations are provided by
//! the platform layer (e.g., Flutter via `flutter_secure_storage`).
//!
//! # Security
//!
//! - Secret bytes are never stored directly by Rust code
//! - All storage operations delegate to platform secure storage
//! - Implementations should use OS-level secure storage (Keychain, Keystore, etc.)

use super::IdentityError;

/// Storage key for the Nostr identity secret bytes.
pub const NOSTR_IDENTITY_KEY: &str = "haven.nostr.identity";

/// Trait for secure storage of sensitive key material.
///
/// Implementations must provide platform-specific secure storage using
/// OS-level security mechanisms (iOS Keychain, Android Keystore, etc.).
///
/// # Thread Safety
///
/// Implementations must be `Send + Sync` to allow use across threads.
///
/// # Example
///
/// ```ignore
/// use haven_core::nostr::identity::SecureKeyStorage;
///
/// struct PlatformStorage { /* ... */ }
///
/// impl SecureKeyStorage for PlatformStorage {
///     fn store(&self, key: &str, value: &[u8]) -> Result<(), IdentityError> {
///         // Store in platform secure storage
///         Ok(())
///     }
///     // ... other methods
/// }
/// ```
pub trait SecureKeyStorage: Send + Sync {
    /// Stores secret bytes under the given key.
    ///
    /// # Arguments
    ///
    /// * `key` - Storage key identifier
    /// * `value` - Secret bytes to store
    ///
    /// # Errors
    ///
    /// Returns an error if the storage operation fails.
    fn store(&self, key: &str, value: &[u8]) -> Result<(), IdentityError>;

    /// Retrieves secret bytes for the given key.
    ///
    /// # Arguments
    ///
    /// * `key` - Storage key identifier
    ///
    /// # Returns
    ///
    /// `Ok(Some(bytes))` if found, `Ok(None)` if not found.
    ///
    /// # Errors
    ///
    /// Returns an error if the retrieval operation fails.
    fn retrieve(&self, key: &str) -> Result<Option<Vec<u8>>, IdentityError>;

    /// Deletes the secret for the given key.
    ///
    /// # Arguments
    ///
    /// * `key` - Storage key identifier
    ///
    /// # Errors
    ///
    /// Returns an error if the deletion fails.
    fn delete(&self, key: &str) -> Result<(), IdentityError>;

    /// Checks if a secret exists for the given key.
    ///
    /// # Arguments
    ///
    /// * `key` - Storage key identifier
    ///
    /// # Returns
    ///
    /// `true` if the key exists, `false` otherwise.
    ///
    /// # Errors
    ///
    /// Returns an error if the check fails.
    fn exists(&self, key: &str) -> Result<bool, IdentityError>;
}

#[cfg(test)]
pub mod tests {
    use super::*;
    use std::collections::HashMap;
    use std::sync::RwLock;

    /// In-memory storage implementation for testing.
    ///
    /// This implementation is NOT secure and should only be used in tests.
    #[derive(Debug, Default)]
    pub struct MockStorage {
        data: RwLock<HashMap<String, Vec<u8>>>,
    }

    impl MockStorage {
        /// Creates a new empty mock storage.
        #[must_use]
        pub fn new() -> Self {
            Self::default()
        }
    }

    impl SecureKeyStorage for MockStorage {
        fn store(&self, key: &str, value: &[u8]) -> Result<(), IdentityError> {
            let mut data = self
                .data
                .write()
                .map_err(|e| IdentityError::Storage(e.to_string()))?;
            data.insert(key.to_string(), value.to_vec());
            Ok(())
        }

        fn retrieve(&self, key: &str) -> Result<Option<Vec<u8>>, IdentityError> {
            let data = self
                .data
                .read()
                .map_err(|e| IdentityError::Storage(e.to_string()))?;
            Ok(data.get(key).cloned())
        }

        fn delete(&self, key: &str) -> Result<(), IdentityError> {
            let mut data = self
                .data
                .write()
                .map_err(|e| IdentityError::Storage(e.to_string()))?;
            data.remove(key);
            Ok(())
        }

        fn exists(&self, key: &str) -> Result<bool, IdentityError> {
            let data = self
                .data
                .read()
                .map_err(|e| IdentityError::Storage(e.to_string()))?;
            Ok(data.contains_key(key))
        }
    }

    #[test]
    fn mock_storage_store_and_retrieve() {
        let storage = MockStorage::new();
        let key = "test.key";
        let value = vec![1, 2, 3, 4, 5];

        storage.store(key, &value).unwrap();
        let retrieved = storage.retrieve(key).unwrap();

        assert_eq!(retrieved, Some(value));
    }

    #[test]
    fn mock_storage_retrieve_nonexistent() {
        let storage = MockStorage::new();
        let result = storage.retrieve("nonexistent").unwrap();
        assert_eq!(result, None);
    }

    #[test]
    fn mock_storage_exists() {
        let storage = MockStorage::new();
        let key = "test.key";

        assert!(!storage.exists(key).unwrap());

        storage.store(key, &[1, 2, 3]).unwrap();
        assert!(storage.exists(key).unwrap());
    }

    #[test]
    fn mock_storage_delete() {
        let storage = MockStorage::new();
        let key = "test.key";

        storage.store(key, &[1, 2, 3]).unwrap();
        assert!(storage.exists(key).unwrap());

        storage.delete(key).unwrap();
        assert!(!storage.exists(key).unwrap());
    }

    #[test]
    fn mock_storage_delete_nonexistent_succeeds() {
        let storage = MockStorage::new();
        // Deleting a non-existent key should succeed
        assert!(storage.delete("nonexistent").is_ok());
    }
}
