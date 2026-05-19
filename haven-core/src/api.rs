//! API module for Haven core functionality.

use crate::location::{LocationMessage, LocationSettings};

/// Core interface for Haven functionality.
///
/// This struct serves as the main entry point for all Haven operations,
/// including Nostr interactions and location data handling.
#[derive(Debug)]
pub struct HavenCore {
    initialized: bool,
    location_settings: LocationSettings,
}

#[allow(clippy::derivable_impls)] // initialized field differs from new()
impl Default for HavenCore {
    fn default() -> Self {
        Self {
            initialized: false, // Default is uninitialized, new() creates initialized
            location_settings: LocationSettings::default(),
        }
    }
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
    pub fn new() -> Self {
        Self {
            initialized: true,
            location_settings: LocationSettings::default(),
        }
    }

    /// Returns whether the core has been initialized.
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
    pub const fn is_initialized(&self) -> bool {
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

    /// Processes raw location data and returns a `LocationMessage` with
    /// exact GPS coordinates. Privacy-sensitive metadata (altitude, speed,
    /// device ID, etc.) is stripped from the serialized form.
    ///
    /// # Examples
    ///
    /// ```
    /// use haven_core::HavenCore;
    ///
    /// let core = HavenCore::new();
    /// let location = core.update_location(37.7749295, -122.4194155);
    /// assert_eq!(location.latitude, 37.7749295);
    /// assert_eq!(location.longitude, -122.4194155);
    /// ```
    #[must_use]
    pub fn update_location(&self, latitude: f64, longitude: f64) -> LocationMessage {
        LocationMessage::new(latitude, longitude)
    }

    /// Gets the current location settings.
    ///
    /// # Examples
    ///
    /// ```
    /// use haven_core::HavenCore;
    ///
    /// let core = HavenCore::new();
    /// let settings = core.get_location_settings();
    /// assert_eq!(settings.update_interval_minutes, 5);
    /// ```
    #[must_use]
    pub fn get_location_settings(&self) -> LocationSettings {
        self.location_settings.clone()
    }

    /// Updates the location settings.
    ///
    /// # Examples
    ///
    /// ```
    /// use haven_core::{HavenCore, location::LocationSettings};
    ///
    /// let mut core = HavenCore::new();
    /// let mut settings = LocationSettings::default();
    /// settings.update_interval_minutes = 10;
    /// core.set_location_settings(settings);
    /// ```
    pub const fn set_location_settings(&mut self, settings: LocationSettings) {
        self.location_settings = settings;
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

    #[test]
    fn update_location_preserves_exact_coordinates() {
        let core = HavenCore::new();
        let location = core.update_location(37.774_929_5, -122.419_415_5);

        assert_eq!(location.latitude, 37.774_929_5);
        assert_eq!(location.longitude, -122.419_415_5);
    }

    #[test]
    fn update_location_generates_geohash() {
        let core = HavenCore::new();
        let location = core.update_location(37.7749, -122.4194);

        // Geohash should be precision 8 (8 characters)
        assert_eq!(location.geohash.len(), 8);
    }

    #[test]
    fn get_location_settings_returns_defaults() {
        let core = HavenCore::new();
        let settings = core.get_location_settings();

        assert_eq!(settings.update_interval_minutes, 5);
    }

    #[test]
    fn set_location_settings_updates_settings() {
        let mut core = HavenCore::new();
        let mut settings = core.get_location_settings();
        settings.update_interval_minutes = 10;

        core.set_location_settings(settings);

        let updated = core.get_location_settings();
        assert_eq!(updated.update_interval_minutes, 10);
    }
}
