//! Applying sparse user edits onto the freshest fetched metadata.
//!
//! A kind-0 update is a **full replace** (NIP-01), so the correct edit path is
//! fetch-latest → merge → republish the whole object. [`merge_edits`] mutates
//! only the fields the user actually touched, preserving every other known
//! field and — crucially — the `custom` map (fields written by other clients),
//! so an edit never silently drops metadata Haven does not model.

use nostr::Metadata;

use super::types::{ProfileEdits, ProfileMetadata};

/// Applies `edits` onto `base`, returning the metadata to republish.
///
/// For each of `display_name` / `about` / `picture`:
/// * `None` — leave the field untouched;
/// * `Some(value)` — set it to `value.trim()`, or **clear** it (set `None`) if
///   the trimmed value is empty.
///
/// All other fields (`name`, `website`, `banner`, `nip05`, `lud06`, `lud16`)
/// and the entire `custom` map are carried over unchanged.
#[must_use]
pub fn merge_edits(base: &ProfileMetadata, edits: &ProfileEdits) -> ProfileMetadata {
    let mut metadata = base.as_metadata().clone();

    if let Some(display_name) = &edits.display_name {
        metadata.display_name = normalize_edit(display_name);
    }
    if let Some(about) = &edits.about {
        metadata.about = normalize_edit(about);
    }
    if let Some(picture) = &edits.picture {
        metadata.picture = normalize_edit(picture);
    }

    ProfileMetadata::from_metadata(metadata)
}

/// Trims an edit value; an empty / whitespace-only result clears the field.
fn normalize_edit(value: &str) -> Option<String> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

/// Enforces the NIP-24 rule that `name` should always be set when publishing:
/// if `name` is absent / blank, mirror a non-blank `display_name` into it.
///
/// This is app-level logic — `EventBuilder::metadata` does not do it. Existing
/// non-blank `name` values are left untouched.
pub fn enforce_name_rule(metadata: &mut Metadata) {
    let name_blank = metadata.name.as_deref().is_none_or(|n| n.trim().is_empty());
    if !name_blank {
        return;
    }
    if let Some(display_name) = metadata.display_name.as_deref() {
        let trimmed = display_name.trim();
        if !trimmed.is_empty() {
            metadata.name = Some(trimmed.to_string());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use nostr::{JsonUtil, Metadata};
    use proptest::prelude::*;

    fn md_from(json: &str) -> ProfileMetadata {
        ProfileMetadata::from_metadata(Metadata::from_json(json).expect("valid json"))
    }

    #[test]
    fn merge_preserves_untouched_known_fields() {
        let base = md_from(
            r#"{"name":"alice","display_name":"Alice","about":"bio","website":"https://a.example","nip05":"a@b.c"}"#,
        );
        // Only edit `about`; everything else must survive verbatim.
        let edits = ProfileEdits {
            about: Some("new bio".to_string()),
            ..ProfileEdits::default()
        };
        let merged = merge_edits(&base, &edits);
        let m = merged.as_metadata();
        assert_eq!(m.about.as_deref(), Some("new bio"));
        assert_eq!(m.name.as_deref(), Some("alice"));
        assert_eq!(m.display_name.as_deref(), Some("Alice"));
        assert_eq!(m.website.as_deref(), Some("https://a.example"));
        assert_eq!(m.nip05.as_deref(), Some("a@b.c"));
    }

    #[test]
    fn merge_preserves_custom_unknown_fields() {
        // A `lud16` set by another client (modeled here as a known field) plus a
        // genuinely-unknown `custom` key must both survive an unrelated edit.
        let base = md_from(r#"{"name":"alice","lud16":"alice@wallet","bot":true}"#);
        let edits = ProfileEdits {
            display_name: Some("Alice".to_string()),
            ..ProfileEdits::default()
        };
        let merged = merge_edits(&base, &edits);
        let m = merged.as_metadata();
        assert_eq!(m.lud16.as_deref(), Some("alice@wallet"));
        assert_eq!(
            m.custom.get("bot").and_then(serde_json::Value::as_bool),
            Some(true),
            "unknown custom field must be preserved"
        );
        assert_eq!(m.display_name.as_deref(), Some("Alice"));
    }

    #[test]
    fn merge_clear_with_empty_string() {
        let base = md_from(r#"{"display_name":"Alice","about":"bio"}"#);
        let edits = ProfileEdits {
            about: Some(String::new()),
            ..ProfileEdits::default()
        };
        let merged = merge_edits(&base, &edits);
        assert_eq!(merged.as_metadata().about, None, "empty string clears");
        // Untouched field stays.
        assert_eq!(merged.display_name(), Some("Alice"));
    }

    #[test]
    fn merge_leaves_field_on_none() {
        let base = md_from(r#"{"display_name":"Alice","about":"bio","picture":"https://x/y"}"#);
        // All-None edits are a no-op.
        let merged = merge_edits(&base, &ProfileEdits::default());
        assert_eq!(merged, base);
    }

    #[test]
    fn name_rule_mirrors_display_name() {
        let mut m = Metadata::from_json(r#"{"display_name":"Alice"}"#).unwrap();
        enforce_name_rule(&mut m);
        assert_eq!(m.name.as_deref(), Some("Alice"));
    }

    #[test]
    fn name_rule_mirrors_over_blank_name() {
        let mut m = Metadata::from_json(r#"{"name":"   ","display_name":"Alice"}"#).unwrap();
        enforce_name_rule(&mut m);
        assert_eq!(m.name.as_deref(), Some("Alice"));
    }

    #[test]
    fn name_rule_leaves_existing() {
        let mut m = Metadata::from_json(r#"{"name":"realname","display_name":"Alice"}"#).unwrap();
        enforce_name_rule(&mut m);
        assert_eq!(
            m.name.as_deref(),
            Some("realname"),
            "existing name untouched"
        );
    }

    #[test]
    fn name_rule_noop_without_display_name() {
        let mut m = Metadata::from_json(r#"{"about":"hi"}"#).unwrap();
        enforce_name_rule(&mut m);
        assert_eq!(m.name, None);
    }

    proptest! {
        /// Merging sparse edits onto an arbitrary base leaves every non-edited
        /// modeled field value-equal after a serialize→parse round-trip. Compare
        /// PARSED VALUES (not raw bytes): JSON key order normalizes through
        /// `Metadata`.
        #[test]
        fn prop_merge_roundtrip(
            name in proptest::option::of("[a-zA-Z ]{0,12}"),
            website in proptest::option::of("[a-z]{1,8}"),
            lud16 in proptest::option::of("[a-z]{1,8}@[a-z]{1,8}"),
            custom_val in proptest::option::of("[a-zA-Z0-9]{1,10}"),
            edit_about in proptest::option::of("[a-zA-Z ]{0,20}"),
            edit_display in proptest::option::of("[a-zA-Z ]{0,20}"),
        ) {
            let mut base_md = Metadata::new();
            base_md.name = name.clone();
            base_md.website = website.clone();
            base_md.lud16 = lud16.clone();
            if let Some(v) = &custom_val {
                base_md = base_md.custom_field("canary", v.clone());
            }
            let base = ProfileMetadata::from_metadata(base_md);

            let edits = ProfileEdits {
                display_name: edit_display.clone(),
                about: edit_about.clone(),
                picture: None,
            };
            let merged = merge_edits(&base, &edits);

            // Serialize→parse to prove wire round-trip stability.
            let reparsed = Metadata::from_json(&merged.as_metadata().as_json())
                .expect("merged metadata must round-trip");

            // Non-edited modeled fields are value-equal.
            prop_assert_eq!(reparsed.name, name);
            prop_assert_eq!(reparsed.website, website);
            prop_assert_eq!(reparsed.lud16, lud16);
            // The unknown custom canary survives untouched.
            prop_assert_eq!(
                reparsed.custom.get("canary").and_then(serde_json::Value::as_str)
                    .map(str::to_string),
                custom_val
            );
        }
    }
}
