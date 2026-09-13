//! Ledger reconciliation: the coverage claim, checked against the expander.
//!
//! `policy.toml`'s `[ledger]` is a hand-written claim, per `(class, encoding)`,
//! that the expander either searches a rendering or deliberately does not. This
//! module proves the claim and the code agree. Without it, a coverage test
//! measures the expander's own output — it asserts that what happens is what
//! happens.
//!
//! The model is `CanaryEncodingLedger` in
//! `haven/integration_test/e2e/_lib/wire_canaries.dart` (~842-1213), including
//! the central discipline: the ledger's boundaries are stated as literals, never
//! computed from the expander's constants, because a ledger that recomputed them
//! would follow a narrowing change instead of reporting it.
//!
//! Only classes this run actually declared are reconciled. A class with no
//! declared value produces no labels, and holding its `covered` claims against
//! it would make every scenario that does not mint every class rc 3.

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};

use crate::expand::{DropKind, Expansion};
use crate::policy::Policy;

/// What the ledger claims about one `(class, encoding)`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum ClaimKind {
    /// The expander produces a searchable term, or drops it as an alias of one,
    /// or the declared value has no such rendering.
    Covered,
    /// The expander deliberately does not search this rendering.
    Gap,
}

/// One sealed claim, copied into the manifest so the record of what was claimed
/// travels with the record of what was searched.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Claim {
    /// The needle class.
    pub class: String,
    /// The encoding label.
    pub encoding: String,
    /// The claim.
    pub claim: ClaimKind,
    /// The reason, for a gap.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

/// The four ways the ledger and the expander can disagree.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MismatchKind {
    /// Declared `covered`, but the expander produced nothing — or dropped it as
    /// a policy gap. Either way the rendering is no longer searched and nobody
    /// said so.
    CoveredNotProduced,
    /// Declared a `gap`, but the expander produced it (or dropped it for a
    /// reason that is not a policy decision). A limitation that stopped being
    /// one must be declared, not discovered.
    GapProduced,
    /// The expander produced a label the ledger does not mention at all, so the
    /// coverage statement is whatever the expander happens to do.
    UndeclaredProduced,
    /// A gap with no reason. A gap nobody explained is a gap nobody can review.
    GapWithoutReason,
}

/// One disagreement.
#[derive(Clone, Debug)]
pub struct Mismatch {
    /// Which kind.
    pub kind: MismatchKind,
    /// The class.
    pub class: String,
    /// The encoding label.
    pub encoding: String,
}

impl Mismatch {
    /// The operator-facing sentence. Classes and labels only — never a value.
    #[must_use]
    pub fn message(&self) -> String {
        let Self {
            class, encoding, ..
        } = self;
        match self.kind {
            MismatchKind::CoveredNotProduced => format!(
                "ledger: `{class}`/`{encoding}` is declared COVERED but the expander does not search it; restore the encoding or move the claim to a gap with a true reason"
            ),
            MismatchKind::GapProduced => format!(
                "ledger: `{class}`/`{encoding}` is declared a GAP but the expander searches it; a limitation that stopped being one must be declared, not discovered"
            ),
            MismatchKind::UndeclaredProduced => format!(
                "ledger: the expander produces `{class}`/`{encoding}`, which the ledger does not declare at all"
            ),
            MismatchKind::GapWithoutReason => format!(
                "ledger: the gap `{class}`/`{encoding}` has no reason; a gap nobody explained is a gap nobody can review"
            ),
        }
    }
}

/// What the expander did with one label.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Outcome {
    Searched,
    PolicyGap,
    OtherDrop,
}

/// Reconciles `expansion` against `policy`'s ledger.
///
/// Returns one [`Mismatch`] per disagreement; empty means the claim and the code
/// agree exactly. The caller's contract is rc 3: a coverage claim that is
/// unverified carries no information, so the verdict is "unusable", not "leak"
/// and not "pass".
#[must_use]
pub fn reconcile(policy: &Policy, expansion: &Expansion) -> Vec<Mismatch> {
    let mut produced: BTreeMap<(String, String), Outcome> = BTreeMap::new();
    for term in &expansion.terms {
        produced.insert(
            (term.class.clone(), term.encoding.clone()),
            Outcome::Searched,
        );
    }
    for dropped in &expansion.dropped {
        let outcome = if dropped.kind == DropKind::PolicyGap {
            Outcome::PolicyGap
        } else {
            Outcome::OtherDrop
        };
        let key = (dropped.class.clone(), dropped.encoding.clone());
        // A label can be searched for one value and dropped for another (a long
        // name yields a prefix, a short one does not). Searched wins: the
        // rendering IS searched this run.
        produced
            .entry(key)
            .and_modify(|existing| {
                if *existing != Outcome::Searched {
                    *existing = outcome;
                }
            })
            .or_insert(outcome);
    }

    let declared_classes: BTreeSet<String> =
        produced.keys().map(|(class, _)| class.clone()).collect();
    let mut mismatches = Vec::new();

    for class in &declared_classes {
        let Some(entry) = policy.ledger.get(class) else {
            // An undeclared class cannot be reconciled label by label; name the
            // class once rather than once per label.
            mismatches.push(Mismatch {
                kind: MismatchKind::UndeclaredProduced,
                class: class.clone(),
                encoding: "*".to_owned(),
            });
            continue;
        };
        let mut claimed: BTreeSet<&str> = BTreeSet::new();
        for encoding in &entry.covered {
            claimed.insert(encoding.as_str());
            match produced.get(&(class.clone(), encoding.clone())) {
                Some(Outcome::Searched | Outcome::OtherDrop) => {}
                _ => mismatches.push(Mismatch {
                    kind: MismatchKind::CoveredNotProduced,
                    class: class.clone(),
                    encoding: encoding.clone(),
                }),
            }
        }
        for (encoding, reason) in &entry.gaps {
            claimed.insert(encoding.as_str());
            if reason.trim().is_empty() {
                mismatches.push(Mismatch {
                    kind: MismatchKind::GapWithoutReason,
                    class: class.clone(),
                    encoding: encoding.clone(),
                });
            }
            if produced.get(&(class.clone(), encoding.clone())) != Some(&Outcome::PolicyGap) {
                mismatches.push(Mismatch {
                    kind: MismatchKind::GapProduced,
                    class: class.clone(),
                    encoding: encoding.clone(),
                });
            }
        }
        for (label_class, encoding) in produced.keys() {
            if label_class == class && !claimed.contains(encoding.as_str()) {
                mismatches.push(Mismatch {
                    kind: MismatchKind::UndeclaredProduced,
                    class: class.clone(),
                    encoding: encoding.clone(),
                });
            }
        }
    }
    mismatches
}

/// The claims for the classes this run declared, flattened for the manifest.
#[must_use]
pub fn sealed_claims(policy: &Policy, expansion: &Expansion) -> Vec<Claim> {
    let classes: BTreeSet<&str> = expansion
        .terms
        .iter()
        .map(|t| t.class.as_str())
        .chain(expansion.dropped.iter().map(|d| d.class.as_str()))
        .collect();
    let mut claims = Vec::new();
    for class in classes {
        if let Some(entry) = policy.ledger.get(class) {
            for encoding in &entry.covered {
                claims.push(Claim {
                    class: class.to_owned(),
                    encoding: encoding.clone(),
                    claim: ClaimKind::Covered,
                    reason: None,
                });
            }
            for (encoding, reason) in &entry.gaps {
                claims.push(Claim {
                    class: class.to_owned(),
                    encoding: encoding.clone(),
                    claim: ClaimKind::Gap,
                    reason: Some(reason.clone()),
                });
            }
        }
    }
    claims
}

#[cfg(test)]
mod tests {
    use super::{reconcile, sealed_claims, MismatchKind};
    use crate::expand::{expand, Declared};
    use crate::policy::Policy;

    /// A policy small enough to break deliberately, with the four mismatch kinds
    /// one edit away each.
    fn policy(ledger: &str) -> Policy {
        let text = format!(
            r#"
schema = 1
base64_entropy_bits = 4.2
min_term_len = 6
furniture = []
[classes]
geohash = {{ kind = "geohash" }}
[sinks]
drive = {{ term_floor = 6, structural_rules = true, reassemble = false, min_lines = 1, entry_format = "plain" }}
{ledger}
"#
        );
        Policy::parse(&text).expect("fixture policy must parse")
    }

    fn declared() -> Vec<Declared> {
        vec![Declared {
            id: "v1".to_owned(),
            class: "geohash".to_owned(),
            raw: "r3gx2f7k".to_owned(),
        }]
    }

    /// The truthful ledger for a geohash: `full` and every prefix the expander
    /// builds, and nothing else. The ladder starts at `prefix6` because the
    /// global term floor is 6 — a shorter prefix is unsearchable for every
    /// value, so the expander does not produce it at all.
    const HONEST: &str = r#"
[ledger.geohash]
covered = ["full", "prefix6", "prefix7", "prefix8"]
"#;

    #[test]
    fn an_honest_ledger_reconciles() {
        let policy = policy(HONEST);
        let expansion = expand(&policy, &declared()).expect("expand");
        let mismatches = reconcile(&policy, &expansion);
        assert!(
            mismatches.is_empty(),
            "{:?}",
            mismatches
                .iter()
                .map(super::Mismatch::message)
                .collect::<Vec<_>>()
        );
    }

    #[test]
    fn a_covered_label_the_expander_does_not_produce_is_a_mismatch() {
        let policy = policy(
            r#"
[ledger.geohash]
covered = ["full", "prefix6", "prefix7", "prefix8", "prefix9"]
"#,
        );
        let expansion = expand(&policy, &declared()).expect("expand");
        let mismatches = reconcile(&policy, &expansion);
        assert_eq!(mismatches.len(), 1);
        assert_eq!(mismatches[0].kind, MismatchKind::CoveredNotProduced);
        assert_eq!(mismatches[0].encoding, "prefix9");
    }

    #[test]
    fn a_gap_label_the_expander_produces_is_a_mismatch() {
        let policy = policy(
            r#"
[ledger.geohash]
covered = ["full", "prefix6", "prefix7"]
[ledger.geohash.gaps]
"prefix8" = "a precision-8 cell is ~19 m and nothing logs it"
"#,
        );
        let expansion = expand(&policy, &declared()).expect("expand");
        let mismatches = reconcile(&policy, &expansion);
        assert_eq!(mismatches.len(), 1);
        assert_eq!(mismatches[0].kind, MismatchKind::GapProduced);
        assert_eq!(mismatches[0].encoding, "prefix8");
    }

    #[test]
    fn a_label_the_ledger_never_mentions_is_a_mismatch() {
        let policy = policy(
            r#"
[ledger.geohash]
covered = ["full", "prefix6", "prefix7"]
"#,
        );
        let expansion = expand(&policy, &declared()).expect("expand");
        let mismatches = reconcile(&policy, &expansion);
        assert_eq!(mismatches.len(), 1);
        assert_eq!(mismatches[0].kind, MismatchKind::UndeclaredProduced);
        assert_eq!(mismatches[0].encoding, "prefix8");
    }

    #[test]
    fn a_gap_with_no_reason_is_a_mismatch() {
        let policy = policy(
            r#"
[ledger.geohash]
covered = ["full", "prefix6", "prefix7"]
[ledger.geohash.gaps]
"prefix8" = "  "
"#,
        );
        let expansion = expand(&policy, &declared()).expect("expand");
        let kinds: Vec<MismatchKind> = reconcile(&policy, &expansion)
            .into_iter()
            .map(|m| m.kind)
            .collect();
        assert!(kinds.contains(&MismatchKind::GapWithoutReason), "{kinds:?}");
    }

    #[test]
    fn a_class_nothing_declared_is_not_reconciled() {
        // The anti-flake property: a scenario that mints no geohash must not be
        // rc 3 for every geohash encoding it therefore did not produce.
        let policy = policy(HONEST);
        let expansion = expand(&policy, &[]).expect("expand");
        assert!(reconcile(&policy, &expansion).is_empty());
        assert!(sealed_claims(&policy, &expansion).is_empty());
    }

    #[test]
    fn the_sealed_claims_carry_every_gap_reason() {
        let policy = policy(
            r#"
[ledger.geohash]
covered = ["full", "prefix6", "prefix7"]
[ledger.geohash.gaps]
"prefix8" = "a precision-8 cell is ~19 m and nothing logs it"
"#,
        );
        let expansion = expand(&policy, &declared()).expect("expand");
        let claims = sealed_claims(&policy, &expansion);
        let gap = claims
            .iter()
            .find(|c| c.encoding == "prefix8")
            .expect("the gap is sealed");
        assert_eq!(
            gap.reason.as_deref(),
            Some("a precision-8 cell is ~19 m and nothing logs it")
        );
    }
}
