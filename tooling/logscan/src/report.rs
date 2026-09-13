//! Rendering a verdict without rendering a value.
//!
//! Security Rule 15 applies to this tool's own output: the report carries a
//! path, a line number, a class, an encoding or a rule id, a tag drawn from the
//! sink's own owned-tag list, and a count. It never carries the matched text, the
//! surrounding line, or any value from the manifest.
//!
//! The one exception is `--disclose-values`, which exists because an operator
//! reproducing a leak locally needs to see it. It announces itself on stderr,
//! naming the file it writes into, and a repo guard keeps it out of every
//! workflow and every non-interactive runner path.

use std::io::Write;

use crate::scan::{Finding, FindingKind, Outcome};

/// One human-readable line per finding.
///
/// `LEAK: <sink>:<line> [<class>/<encoding>|<rule>] tag=<tag> ×<n>`
#[must_use]
pub fn human_line(finding: &Finding) -> String {
    let what = match finding.kind {
        FindingKind::Needle => format!(
            "{}/{}",
            finding.class.as_deref().unwrap_or("?"),
            finding.encoding.as_deref().unwrap_or("?")
        ),
        FindingKind::Rule => finding.rule.clone().unwrap_or_else(|| "?".to_owned()),
    };
    // `tag=-` where the sink has no tag column: a line PREFIX would be a
    // perfectly good triage hint and also a channel for remote-authored text,
    // which is exactly what Rule 15 forbids printing.
    let tag = finding.tag.as_deref().unwrap_or("-");
    let reassembled = if finding.reassembled {
        " reassembled"
    } else {
        ""
    };
    let disclosed = finding
        .matched
        .as_ref()
        .map_or_else(String::new, |text| format!(" value={text}"));
    format!(
        "LEAK: {}:{} [{what}] tag={tag} ×{}{reassembled}{disclosed}",
        finding.sink.display(),
        finding.line,
        finding.count
    )
}

/// One NDJSON object per finding.
#[must_use]
pub fn ndjson_line(finding: &Finding) -> String {
    let mut object = serde_json::Map::new();
    object.insert(
        "sink".to_owned(),
        serde_json::Value::String(finding.sink.display().to_string()),
    );
    object.insert("line".to_owned(), serde_json::Value::from(finding.line));
    object.insert(
        "kind".to_owned(),
        serde_json::Value::String(
            match finding.kind {
                FindingKind::Needle => "needle",
                FindingKind::Rule => "rule",
            }
            .to_owned(),
        ),
    );
    for (key, value) in [
        ("class", finding.class.clone()),
        ("encoding", finding.encoding.clone()),
        ("rule", finding.rule.clone()),
        ("tag", finding.tag.clone()),
    ] {
        object.insert(
            key.to_owned(),
            value.map_or(serde_json::Value::Null, serde_json::Value::String),
        );
    }
    object.insert("count".to_owned(), serde_json::Value::from(finding.count));
    object.insert(
        "reassembled".to_owned(),
        serde_json::Value::Bool(finding.reassembled),
    );
    if let Some(text) = &finding.matched {
        object.insert("value".to_owned(), serde_json::Value::String(text.clone()));
    }
    serde_json::Value::Object(object).to_string()
}

/// Writes the human report to `out` and the problems to `err`.
///
/// # Errors
///
/// Returns an io error from the sinks it was handed.
pub fn write_report(
    outcome: &Outcome,
    out: &mut dyn Write,
    err: &mut dyn Write,
) -> std::io::Result<()> {
    for finding in &outcome.findings {
        writeln!(err, "{}", human_line(finding))?;
    }
    for problem in &outcome.problems {
        writeln!(err, "{}", problem.message)?;
    }
    let needles = outcome
        .findings
        .iter()
        .filter(|f| f.kind == FindingKind::Needle)
        .count();
    let rules = outcome.findings.len() - needles;
    writeln!(
        out,
        "haven-logscan: {} needle hit(s), {rules} structural hit(s), {} problem(s); plants {}/{}; {} line(s), {} byte(s) read",
        needles,
        outcome.problems.len(),
        outcome.plants_caught,
        outcome.plants_required,
        outcome.lines.values().sum::<u64>(),
        outcome.bytes_read
    )
}

/// Writes the NDJSON report.
///
/// # Errors
///
/// Returns the reason the report file could not be written.
pub fn write_ndjson(outcome: &Outcome, path: &std::path::Path) -> Result<(), String> {
    let mut body = String::new();
    for finding in &outcome.findings {
        body.push_str(&ndjson_line(finding));
        body.push('\n');
    }
    std::fs::write(path, body).map_err(|e| format!("cannot write the report: {:?}", e.kind()))
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use super::{human_line, ndjson_line};
    use crate::scan::{Finding, FindingKind};

    fn needle(matched: Option<String>) -> Finding {
        Finding {
            sink: PathBuf::from("/tmp/adb-logcat.log"),
            line: 4211,
            kind: FindingKind::Needle,
            class: Some("nostr_group_id".to_owned()),
            encoding: Some("hex-prefix8".to_owned()),
            rule: None,
            tag: Some("flutter".to_owned()),
            count: 3,
            matched,
            reassembled: false,
        }
    }

    #[test]
    fn a_report_line_names_the_class_and_never_the_value() {
        let line = human_line(&needle(None));
        assert_eq!(
            line,
            "LEAK: /tmp/adb-logcat.log:4211 [nostr_group_id/hex-prefix8] tag=flutter ×3"
        );
    }

    #[test]
    fn disclosure_is_the_only_path_that_prints_the_text() {
        let line = human_line(&needle(Some("0a1b2c3d".to_owned())));
        assert!(line.contains("value=0a1b2c3d"));
        let json = ndjson_line(&needle(Some("0a1b2c3d".to_owned())));
        assert!(json.contains("\"value\":\"0a1b2c3d\""));
        let withheld = ndjson_line(&needle(None));
        assert!(!withheld.contains("value"), "{withheld}");
    }

    #[test]
    fn the_ndjson_shape_is_the_one_the_wrapper_parses() {
        let json: serde_json::Value =
            serde_json::from_str(&ndjson_line(&needle(None))).expect("valid JSON");
        for key in [
            "sink",
            "line",
            "kind",
            "class",
            "encoding",
            "rule",
            "tag",
            "count",
            "reassembled",
        ] {
            assert!(json.get(key).is_some(), "missing `{key}`");
        }
        assert_eq!(json["kind"], "needle");
        assert_eq!(json["rule"], serde_json::Value::Null);
    }

    #[test]
    fn a_rule_hit_reports_the_rule_id_in_the_same_slot() {
        let mut finding = needle(None);
        finding.kind = FindingKind::Rule;
        finding.class = None;
        finding.encoding = None;
        finding.rule = Some("S5".to_owned());
        finding.tag = None;
        assert_eq!(
            human_line(&finding),
            "LEAK: /tmp/adb-logcat.log:4211 [S5] tag=- ×3"
        );
    }
}
