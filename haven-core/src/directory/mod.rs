//! The local member directory: how a person's name is matched, and how it is
//! shown.
//!
//! Two functions with deliberately DIFFERENT rules, kept side by side because
//! the difference is the whole point and running one where the other belongs is
//! a bug in both directions:
//!
//! * [`fold_for_search`] normalises a name for MATCHING. Nobody ever sees its
//!   output, so it may delete every invisible character — including the
//!   ZWNJ/ZWJ joiners — which is what makes `می‌رود` and `میرود` one key.
//! * [`sanitize_display_name`] normalises a name for RENDERING. It must keep
//!   exactly those joiners, because in Persian, Urdu and Devanagari they are
//!   spelling rather than decoration, while removing the bidi controls whose
//!   only effect is to make the rendered text differ from the string.
//!
//! Folding what is rendered erases real orthography; matching on what is
//! rendered would flag every legitimate ZWNJ spelling pair as an impersonation
//! attempt — a false positive aimed squarely at the users the joiner carve-out
//! exists to protect.
//!
//! Combining marks split the same way. The fold ignores a mark only where it is
//! optional POINTING — Latin, Greek and Cyrillic accents, Arabic harakat,
//! Hebrew niqqud — and keeps every other one, because in Devanagari and kana a
//! mark is a letter: `कमला`/`कमल` and `ガンダム`/`ガンタム` are different names,
//! not different spellings. The sanitizer keeps them all.

mod fold;
mod invisible;
mod sanitize;

pub use fold::fold_for_search;
pub use sanitize::{
    sanitize_display_name, DISPLAY_NAME_MAX_CLUSTER_CHARS, DISPLAY_NAME_MAX_GRAPHEMES,
};
