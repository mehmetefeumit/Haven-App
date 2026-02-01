//! Tag builders for Nostr events.
//!
//! This module provides utilities for constructing Nostr event tags
//! following the relevant NIPs:
//! - `h` tag: Group identifier (Marmot protocol)
//! - `expiration` tag: NIP-40 automatic expiration
//! - `g` tag: Geohash for optional relay filtering

use chrono::{DateTime, Utc};

/// Builder for Nostr event tags.
///
/// Provides static methods for constructing properly formatted tags.
///
/// # Example
///
/// ```
/// use haven_core::nostr::TagBuilder;
/// use chrono::Utc;
///
/// let h_tag = TagBuilder::h_tag("abc123");
/// assert_eq!(h_tag, vec!["h", "abc123"]);
///
/// let exp_tag = TagBuilder::expiration_tag(Utc::now());
/// assert_eq!(exp_tag[0], "expiration");
/// ```
pub struct TagBuilder;

impl TagBuilder {
    /// Builds the `h` tag for group identification.
    ///
    /// The `h` tag contains the Nostr group ID (not the MLS group ID).
    /// This allows relays to efficiently route messages to group subscribers.
    ///
    /// # Arguments
    ///
    /// * `nostr_group_id` - The group identifier (typically 32-byte hex)
    ///
    /// # Example
    ///
    /// ```
    /// use haven_core::nostr::TagBuilder;
    ///
    /// let tag = TagBuilder::h_tag("abc123def456");
    /// assert_eq!(tag, vec!["h", "abc123def456"]);
    /// ```
    #[must_use]
    pub fn h_tag(nostr_group_id: &str) -> Vec<String> {
        vec!["h".to_string(), nostr_group_id.to_string()]
    }

    /// Builds the `expiration` tag for NIP-40 automatic expiration.
    ///
    /// Relays that support NIP-40 will automatically delete events
    /// after the specified timestamp.
    ///
    /// # Arguments
    ///
    /// * `expires_at` - When the event should expire
    ///
    /// # Example
    ///
    /// ```
    /// use haven_core::nostr::TagBuilder;
    /// use chrono::{Utc, Duration};
    ///
    /// let expires = Utc::now() + Duration::hours(24);
    /// let tag = TagBuilder::expiration_tag(expires);
    /// assert_eq!(tag[0], "expiration");
    /// ```
    #[must_use]
    pub fn expiration_tag(expires_at: DateTime<Utc>) -> Vec<String> {
        vec!["expiration".to_string(), expires_at.timestamp().to_string()]
    }

    /// Builds the `d` tag for addressable events (kind 30078).
    ///
    /// The `d` tag creates an addressable event that can be replaced
    /// by publishing a new event with the same `d` tag value.
    ///
    /// # Arguments
    ///
    /// * `identifier` - The unique identifier for this addressable event
    ///
    /// # Example
    ///
    /// ```
    /// use haven_core::nostr::TagBuilder;
    ///
    /// let tag = TagBuilder::d_tag("haven.location");
    /// assert_eq!(tag, vec!["d", "haven.location"]);
    /// ```
    #[must_use]
    pub fn d_tag(identifier: &str) -> Vec<String> {
        vec!["d".to_string(), identifier.to_string()]
    }

    /// Builds the optional `g` tag for geohash-based relay filtering.
    ///
    /// The geohash is truncated to the specified precision for privacy.
    /// A precision of 5 gives approximately ±2.4km resolution.
    ///
    /// # Arguments
    ///
    /// * `geohash` - The full geohash string
    /// * `precision` - Number of characters to include (typically 5)
    ///
    /// # Privacy Note
    ///
    /// This tag is optional and disabled by default. When enabled,
    /// relays can see the approximate location (city-level with precision 5).
    ///
    /// # Example
    ///
    /// ```
    /// use haven_core::nostr::TagBuilder;
    ///
    /// let tag = TagBuilder::geohash_tag("9q8yyz8r", 5);
    /// assert_eq!(tag, vec!["g", "9q8yy"]);
    /// ```
    #[must_use]
    pub fn geohash_tag(geohash: &str, precision: usize) -> Vec<String> {
        let truncated_len = precision.min(geohash.len());
        let truncated = &geohash[..truncated_len];
        vec!["g".to_string(), truncated.to_string()]
    }

    /// Builds the `alt` tag for NIP-31 human-readable descriptions.
    ///
    /// Provides a human-readable description for clients that don't
    /// understand the event kind.
    ///
    /// # Arguments
    ///
    /// * `description` - Human-readable description
    #[must_use]
    pub fn alt_tag(description: &str) -> Vec<String> {
        vec!["alt".to_string(), description.to_string()]
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Duration;

    #[test]
    fn h_tag_format() {
        let tag = TagBuilder::h_tag("test-group-id");
        assert_eq!(tag.len(), 2);
        assert_eq!(tag[0], "h");
        assert_eq!(tag[1], "test-group-id");
    }

    #[test]
    fn h_tag_with_hex_id() {
        let hex_id = "abc123def456789012345678901234567890123456789012345678901234abcd";
        let tag = TagBuilder::h_tag(hex_id);
        assert_eq!(tag[1], hex_id);
    }

    #[test]
    fn expiration_tag_format() {
        let expires = Utc::now() + Duration::hours(24);
        let tag = TagBuilder::expiration_tag(expires);
        assert_eq!(tag.len(), 2);
        assert_eq!(tag[0], "expiration");
        // Should be a valid timestamp string
        let timestamp: i64 = tag[1].parse().unwrap();
        assert!(timestamp > 0);
    }

    #[test]
    fn expiration_tag_matches_timestamp() {
        let expires = Utc::now();
        let expected_ts = expires.timestamp();
        let tag = TagBuilder::expiration_tag(expires);
        let actual_ts: i64 = tag[1].parse().unwrap();
        assert_eq!(actual_ts, expected_ts);
    }

    #[test]
    fn d_tag_format() {
        let tag = TagBuilder::d_tag("haven.location");
        assert_eq!(tag.len(), 2);
        assert_eq!(tag[0], "d");
        assert_eq!(tag[1], "haven.location");
    }

    #[test]
    fn geohash_tag_truncates_to_precision() {
        let tag = TagBuilder::geohash_tag("9q8yyz8r", 5);
        assert_eq!(tag.len(), 2);
        assert_eq!(tag[0], "g");
        assert_eq!(tag[1], "9q8yy");
        assert_eq!(tag[1].len(), 5);
    }

    #[test]
    fn geohash_tag_handles_short_geohash() {
        let tag = TagBuilder::geohash_tag("9q8", 5);
        assert_eq!(tag[1], "9q8");
        assert_eq!(tag[1].len(), 3);
    }

    #[test]
    fn geohash_tag_precision_8() {
        let tag = TagBuilder::geohash_tag("9q8yyz8r", 8);
        assert_eq!(tag[1], "9q8yyz8r");
    }

    #[test]
    fn alt_tag_format() {
        let tag = TagBuilder::alt_tag("Encrypted family location update");
        assert_eq!(tag.len(), 2);
        assert_eq!(tag[0], "alt");
        assert_eq!(tag[1], "Encrypted family location update");
    }

    #[test]
    fn geohash_tag_empty_geohash() {
        let tag = TagBuilder::geohash_tag("", 5);
        assert_eq!(tag[1], "");
    }

    #[test]
    fn geohash_tag_zero_precision() {
        let tag = TagBuilder::geohash_tag("9q8yyz8r", 0);
        assert_eq!(tag[1], "");
    }

    #[test]
    fn h_tag_empty_id() {
        let tag = TagBuilder::h_tag("");
        assert_eq!(tag.len(), 2);
        assert_eq!(tag[0], "h");
        assert_eq!(tag[1], "");
    }

    #[test]
    fn d_tag_empty_identifier() {
        let tag = TagBuilder::d_tag("");
        assert_eq!(tag.len(), 2);
        assert_eq!(tag[0], "d");
        assert_eq!(tag[1], "");
    }

    #[test]
    fn alt_tag_with_special_chars() {
        let tag = TagBuilder::alt_tag("Line1\nLine2\t\"quoted\"");
        assert_eq!(tag[1], "Line1\nLine2\t\"quoted\"");
    }

    #[test]
    fn expiration_tag_past_date() {
        use chrono::Duration;

        let past_date = Utc::now() - Duration::hours(24);
        let tag = TagBuilder::expiration_tag(past_date);
        assert_eq!(tag[0], "expiration");
        // Should still create the tag, even for past dates
        let timestamp: i64 = tag[1].parse().unwrap();
        assert!(timestamp < Utc::now().timestamp());
    }
}
