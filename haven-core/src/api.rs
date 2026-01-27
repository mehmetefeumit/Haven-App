//! API module exposed to Flutter via `flutter_rust_bridge`.

use flutter_rust_bridge::frb;

/// Core interface for Haven functionality.
///
/// This struct serves as the main entry point for all Haven operations,
/// including Nostr interactions and location data encryption.
#[derive(Debug, Default)]
#[frb(opaque)]
pub struct HavenCore {
    initialized: bool,
}

impl HavenCore {
    /// Creates a new `HavenCore` instance.
    ///
    /// # Examples
    ///
    /// ```
    /// use haven_core::HavenCore;
    ///
    /// let core = HavenCore::new();
    /// ```
    #[must_use]
    pub const fn new() -> Self {
        Self { initialized: true }
    }

    /// Returns whether the core has been initialized.
    ///
    /// This is a synchronous FFI call since it's a simple getter.
    ///
    /// # Examples
    ///
    /// ```
    /// use haven_core::HavenCore;
    ///
    /// let core = HavenCore::new();
    /// assert!(core.is_initialized());
    /// ```
    #[must_use]
    #[frb(sync)]
    pub fn is_initialized(&self) -> bool {
        self.initialized
    }

    /// Placeholder for future initialization logic.
    ///
    /// Currently a no-op that returns success.
    ///
    /// # Errors
    ///
    /// Returns `Err` if initialization fails (currently never fails).
    #[allow(clippy::missing_const_for_fn)] // Will have side effects when implemented.
    pub fn initialize(&mut self) -> Result<(), String> {
        self.initialized = true;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn new_creates_initialized_instance() {
        let core = HavenCore::new();
        assert!(core.is_initialized());
    }

    #[test]
    fn default_creates_uninitialized_instance() {
        let core = HavenCore::default();
        assert!(!core.is_initialized());
    }

    #[test]
    fn initialize_sets_initialized_flag() {
        let mut core = HavenCore::default();
        assert!(!core.is_initialized());

        let result = core.initialize();

        assert!(result.is_ok());
        assert!(core.is_initialized());
    }

    #[test]
    fn debug_trait_implementation() {
        let core = HavenCore::new();
        let debug_str = format!("{core:?}");
        assert!(debug_str.contains("HavenCore"));
        assert!(debug_str.contains("initialized: true"));
    }

    #[test]
    fn multiple_initialize_calls_are_idempotent() {
        let mut core = HavenCore::default();
        let _ = core.initialize();
        let _ = core.initialize();
        assert!(core.is_initialized());
    }
}
