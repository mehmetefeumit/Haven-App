//! API module for Haven core functionality.

use crate::location::{LocationMessage, LocationSettings};

/// Core interface for Haven functionality.
///
/// This struct serves as the main entry point for all Haven operations,
/// including Nostr interactions and location data encryption.
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

    /// Processes raw location data and returns an obfuscated `LocationMessage`.
    ///
    /// This method implements privacy-focused location processing by:
    /// 1. Obfuscating coordinates to the configured precision (default: 5 decimals)
    /// 2. Generating geohash at precision 8 (~19m × 38m cell)
    /// 3. Stripping privacy-sensitive metadata (altitude, speed, device ID, etc.)
    /// 4. Setting automatic 24-hour expiration
    ///
    /// # Arguments
    ///
    /// * `latitude` - Raw GPS latitude
    /// * `longitude` - Raw GPS longitude
    ///
    /// # Returns
    ///
    /// An obfuscated `LocationMessage` ready for encryption and publishing.
    ///
    /// # Examples
    ///
    /// ```
    /// use haven_core::HavenCore;
    ///
    /// let mut core = HavenCore::new();
    /// let location = core.update_location(37.7749295, -122.4194155);
    ///
    /// // Coordinates are obfuscated to 5 decimal places (Enhanced precision by default)
    /// assert_eq!(location.latitude, 37.77493);
    /// assert_eq!(location.longitude, -122.41942);
    /// ```
    #[must_use]
    pub fn update_location(&self, latitude: f64, longitude: f64) -> LocationMessage {
        LocationMessage::with_precision(latitude, longitude, self.location_settings.precision)
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
    /// # Arguments
    ///
    /// * `settings` - New location settings to apply
    ///
    /// # Examples
    ///
    /// ```
    /// use haven_core::{HavenCore, location::{LocationSettings, LocationPrecision}};
    ///
    /// let mut core = HavenCore::new();
    /// let mut settings = LocationSettings::default();
    /// settings.precision = LocationPrecision::Enhanced;
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
    fn update_location_obfuscates_coordinates() {
        let core = HavenCore::new();
        let location = core.update_location(37.774_929_5, -122.419_415_5);

        // Coordinates should be obfuscated to 5 decimal places (Enhanced precision by default)
        assert_eq!(location.latitude, 37.774_93);
        assert_eq!(location.longitude, -122.419_42);
    }

    #[test]
    fn update_location_generates_geohash() {
        let core = HavenCore::new();
        let location = core.update_location(37.7749, -122.4194);

        // Geohash should be precision 8 (8 characters)
        assert_eq!(location.geohash.len(), 8);
    }

    #[test]
    fn update_location_uses_configured_precision() {
        use crate::location::LocationPrecision;

        let mut core = HavenCore::new();
        let mut settings = core.get_location_settings();
        settings.precision = LocationPrecision::Enhanced; // 5 decimals
        core.set_location_settings(settings);

        let location = core.update_location(37.774_929_5, -122.419_415_5);

        // Should use enhanced precision (5 decimals)
        assert_eq!(location.latitude, 37.774_93);
        assert_eq!(location.longitude, -122.419_42);
    }

    #[test]
    fn get_location_settings_returns_defaults() {
        let core = HavenCore::new();
        let settings = core.get_location_settings();

        assert_eq!(settings.update_interval_minutes, 5);
        assert!(!settings.include_geohash_in_events); // Privacy-first default
    }

    #[test]
    fn set_location_settings_updates_settings() {
        let mut core = HavenCore::new();
        let mut settings = core.get_location_settings();
        settings.update_interval_minutes = 10;
        settings.include_geohash_in_events = true;

        core.set_location_settings(settings);

        let updated = core.get_location_settings();
        assert_eq!(updated.update_interval_minutes, 10);
        assert!(updated.include_geohash_in_events);
    }
}
