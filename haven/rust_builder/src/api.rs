//! API bridging layer that exposes haven-core functionality.

use flutter_rust_bridge::frb;
pub use haven_core::location::LocationPrecision;

/// Core interface for Haven functionality (wrapper around haven-core).
#[derive(Debug, Default)]
#[frb(opaque)]
pub struct HavenCore {
    inner: haven_core::HavenCore,
}

impl HavenCore {
    /// Creates a new `HavenCore` instance.
    #[must_use]
    pub fn new() -> Self {
        Self {
            inner: haven_core::HavenCore::new(),
        }
    }

    /// Returns whether the core has been initialized.
    #[must_use]
    #[frb(sync)]
    pub fn is_initialized(&self) -> bool {
        self.inner.is_initialized()
    }

    /// Initializes the core.
    pub fn initialize(&mut self) -> Result<(), String> {
        self.inner.initialize()
    }

    /// Processes raw location data and returns an obfuscated `LocationMessage`.
    #[frb(sync)]
    pub fn update_location(&self, latitude: f64, longitude: f64) -> LocationMessage {
        let msg = self.inner.update_location(latitude, longitude);
        LocationMessage { inner: msg }
    }

    /// Gets the current location settings.
    #[frb(sync)]
    pub fn get_location_settings(&self) -> LocationSettings {
        let settings = self.inner.get_location_settings();
        LocationSettings { inner: settings }
    }

    /// Updates the location settings.
    #[frb(sync)]
    pub fn set_location_settings(&mut self, settings: LocationSettings) {
        self.inner.set_location_settings(settings.inner);
    }
}

/// Location message with obfuscated coordinates (FFI wrapper).
#[derive(Debug, Clone)]
#[frb(opaque)]
pub struct LocationMessage {
    inner: haven_core::location::LocationMessage,
}

impl LocationMessage {
    /// Gets the obfuscated latitude.
    #[frb(sync)]
    #[must_use]
    pub fn latitude(&self) -> f64 {
        self.inner.latitude
    }

    /// Gets the obfuscated longitude.
    #[frb(sync)]
    #[must_use]
    pub fn longitude(&self) -> f64 {
        self.inner.longitude
    }

    /// Gets the geohash representation.
    #[frb(sync)]
    #[must_use]
    pub fn geohash(&self) -> String {
        self.inner.geohash.clone()
    }

    /// Gets the timestamp as Unix timestamp (seconds since epoch).
    #[frb(sync)]
    #[must_use]
    pub fn timestamp(&self) -> i64 {
        self.inner.timestamp.timestamp()
    }

    /// Gets the expiration time as Unix timestamp (seconds since epoch).
    #[frb(sync)]
    #[must_use]
    pub fn expires_at(&self) -> i64 {
        self.inner.expires_at.timestamp()
    }

    /// Gets the precision level.
    #[frb(sync)]
    #[must_use]
    pub fn precision(&self) -> LocationPrecision {
        self.inner.precision
    }

    /// Checks if the location has expired.
    #[frb(sync)]
    #[must_use]
    pub fn is_expired(&self) -> bool {
        self.inner.is_expired()
    }
}

/// Location settings (FFI wrapper).
#[derive(Debug, Clone)]
#[frb(opaque)]
pub struct LocationSettings {
    inner: haven_core::location::LocationSettings,
}

impl LocationSettings {
    /// Creates new location settings.
    #[must_use]
    pub fn new(
        precision: LocationPrecision,
        update_interval_minutes: u32,
        include_geohash_in_events: bool,
    ) -> Self {
        Self {
            inner: haven_core::location::LocationSettings {
                precision,
                update_interval_minutes,
                include_geohash_in_events,
            },
        }
    }

    /// Gets the precision level.
    #[frb(sync)]
    #[must_use]
    pub fn precision(&self) -> LocationPrecision {
        self.inner.precision
    }

    /// Gets the update interval in minutes.
    #[frb(sync)]
    #[must_use]
    pub fn update_interval_minutes(&self) -> u32 {
        self.inner.update_interval_minutes
    }

    /// Gets whether to include geohash in events.
    #[frb(sync)]
    #[must_use]
    pub fn include_geohash_in_events(&self) -> bool {
        self.inner.include_geohash_in_events
    }
}
