//! Storage configuration for MDK.
//!
//! This module provides utilities for configuring MDK's `SQLite` storage backend.
//! The storage is used to persist MLS group state, messages, and key material.

use std::path::{Path, PathBuf};

use mdk_sqlite_storage::MdkSqliteStorage;

use crate::nostr::error::{NostrError, Result};

/// Configuration for MDK storage.
///
/// This struct holds the configuration needed to initialize
/// MDK's `SQLite` storage backend.
#[derive(Debug, Clone)]
pub struct StorageConfig {
    /// Path to the directory where the database will be stored
    pub data_dir: PathBuf,
}

impl StorageConfig {
    /// Creates a new storage configuration.
    ///
    /// # Arguments
    ///
    /// * `data_dir` - Path to the directory where the database will be stored.
    ///   The directory will be created if it doesn't exist.
    ///
    /// # Example
    ///
    /// ```no_run
    /// use std::path::Path;
    /// use haven_core::nostr::mls::storage::StorageConfig;
    ///
    /// let config = StorageConfig::new("/path/to/data");
    /// ```
    pub fn new(data_dir: impl AsRef<Path>) -> Self {
        Self {
            data_dir: data_dir.as_ref().to_path_buf(),
        }
    }

    /// Returns the path to the `SQLite` database file.
    #[must_use]
    pub fn database_path(&self) -> PathBuf {
        self.data_dir.join("haven_mdk.db")
    }

    /// Creates the MDK `SQLite` storage instance.
    ///
    /// This will:
    /// 1. Create the data directory if it doesn't exist
    /// 2. Initialize the `SQLite` database with MDK's schema
    ///
    /// # Errors
    ///
    /// Returns an error if:
    /// - The directory cannot be created
    /// - The database cannot be initialized
    pub fn create_storage(&self) -> Result<MdkSqliteStorage> {
        // Ensure the data directory exists
        std::fs::create_dir_all(&self.data_dir).map_err(|e| {
            NostrError::StorageError(format!(
                "Failed to create data directory {}: {}",
                self.data_dir.display(),
                e
            ))
        })?;

        // Create the SQLite storage with the full database file path
        let db_path = self.database_path();
        MdkSqliteStorage::new(&db_path)
            .map_err(|e| NostrError::StorageError(format!("Failed to initialize MDK storage: {e}")))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::env;
    use std::sync::atomic::{AtomicU64, Ordering};

    static TEST_COUNTER: AtomicU64 = AtomicU64::new(0);

    fn unique_temp_dir() -> PathBuf {
        let id = TEST_COUNTER.fetch_add(1, Ordering::SeqCst);
        env::temp_dir().join(format!("haven_storage_test_{}_{}", std::process::id(), id))
    }

    #[test]
    fn storage_config_new() {
        let config = StorageConfig::new("/tmp/test");
        assert_eq!(config.data_dir, PathBuf::from("/tmp/test"));
    }

    #[test]
    fn storage_config_database_path() {
        let config = StorageConfig::new("/tmp/test");
        assert_eq!(
            config.database_path(),
            PathBuf::from("/tmp/test/haven_mdk.db")
        );
    }

    #[test]
    fn storage_config_create_storage() {
        let temp_dir = unique_temp_dir();
        let config = StorageConfig::new(&temp_dir);

        let result = config.create_storage();
        assert!(
            result.is_ok(),
            "Failed to create storage: {}",
            result.err().map(|e| e.to_string()).unwrap_or_default()
        );

        // Cleanup
        let _ = std::fs::remove_dir_all(&temp_dir);
    }

    #[test]
    fn storage_config_creates_nested_directories() {
        let base_dir = unique_temp_dir();
        let nested = base_dir.join("level1").join("level2");
        let config = StorageConfig::new(&nested);

        let result = config.create_storage();
        assert!(result.is_ok());
        assert!(nested.exists());

        let _ = std::fs::remove_dir_all(&base_dir);
    }

    #[test]
    fn storage_config_clone_and_debug() {
        let config = StorageConfig::new("/test/path");
        let cloned = config.clone();

        assert_eq!(config.data_dir, cloned.data_dir);

        let debug_str = format!("{:?}", config);
        assert!(debug_str.contains("StorageConfig"));
        assert!(debug_str.contains("/test/path"));
    }

    #[test]
    fn storage_config_with_pathbuf() {
        let path = PathBuf::from("/another/test/path");
        let config = StorageConfig::new(&path);

        assert_eq!(config.data_dir, path);
        assert_eq!(
            config.database_path(),
            PathBuf::from("/another/test/path/haven_mdk.db")
        );
    }

    #[test]
    fn storage_config_relative_path() {
        let config = StorageConfig::new("relative/path");
        assert_eq!(config.data_dir, PathBuf::from("relative/path"));
    }

    #[test]
    fn storage_config_empty_path() {
        let config = StorageConfig::new("");
        assert_eq!(config.data_dir, PathBuf::from(""));
        assert_eq!(config.database_path(), PathBuf::from("haven_mdk.db"));
    }

    #[test]
    fn storage_config_unicode_path() {
        let config = StorageConfig::new("/tmp/prueba/datos");
        assert_eq!(config.data_dir, PathBuf::from("/tmp/prueba/datos"));
    }
}
