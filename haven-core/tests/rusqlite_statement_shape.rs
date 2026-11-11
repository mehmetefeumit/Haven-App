//! Pins the one rusqlite behaviour change the MDK v0.10.4 bump (rusqlite 0.32 →
//! 0.40.1) made fatal for code that compiles: since 0.35, `execute`,
//! `prepare`, `prepare_cached` and `query_row` refuse SQL carrying a second
//! statement at runtime (`MultipleStatement`), where 0.32 silently ran the
//! first. A u64/usize bind — the other break — no longer compiles without the
//! opt-in `fallible_uint` feature Haven does not enable, so the compiler
//! already pins it.
//!
//! A source scan over every Haven file that talks to `SQLite`: each string
//! literal handed to one of those calls holds at most one statement (a single
//! trailing `;` is allowed). Multi-statement SQL goes through `execute_batch`.

const FILES: [&str; 12] = [
    "src/circle/storage.rs",
    "src/circle/storage_contamination.rs",
    "src/circle/storage_key_packages.rs",
    "src/circle/storage_member_directory.rs",
    "src/circle/storage_mesh.rs",
    "src/circle/storage_profile.rs",
    "src/circle/storage_profile_sync.rs",
    "src/circle/storage_relay_prefs.rs",
    "src/circle/manager.rs",
    "src/tiles/storage.rs",
    "src/nostr/mls/storage.rs",
    "src/nostr/mls/manager.rs",
];

const SINGLE_STATEMENT_CALLS: [&str; 4] =
    [".execute(", ".prepare(", ".prepare_cached(", ".query_row("];

/// The string literal starting at `at` (a `"…"` or raw `r#"…"#` literal), or
/// `None` when the argument is not a literal.
fn literal_at(source: &str, at: usize) -> Option<&str> {
    let rest = &source[at..];
    if let Some(body) = rest.strip_prefix('"') {
        let mut escaped = false;
        for (i, c) in body.char_indices() {
            match (escaped, c) {
                (true, _) => escaped = false,
                (false, '\\') => escaped = true,
                (false, '"') => return Some(&body[..i]),
                _ => {}
            }
        }
        return None;
    }
    let raw = rest.strip_prefix('r')?;
    let hashes = raw.len() - raw.trim_start_matches('#').len();
    let open = format!("{}\"", "#".repeat(hashes));
    let body = raw.strip_prefix(open.as_str())?;
    let close = format!("\"{}", "#".repeat(hashes));
    body.find(close.as_str()).map(|end| &body[..end])
}

/// Every `(file, line, literal)` that carries more than one statement.
fn multi_statement_literals(files: &[(&str, String)]) -> Vec<(String, usize, String)> {
    let mut found = Vec::new();
    for (name, source) in files {
        for call in SINGLE_STATEMENT_CALLS {
            for (at, _) in source.match_indices(call) {
                let arg = at + call.len();
                let arg = arg + source[arg..].len() - source[arg..].trim_start().len();
                let Some(literal) = literal_at(source, arg) else {
                    continue;
                };
                let statement = literal.trim();
                let statement = statement.strip_suffix(';').unwrap_or(statement);
                if statement.contains(';') {
                    let line = source[..at].matches('\n').count() + 1;
                    found.push(((*name).to_owned(), line, literal.to_owned()));
                }
            }
        }
    }
    found
}

#[test]
fn haven_sqlite_statements_are_single_and_sign_typed() {
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
    let files: Vec<(&str, String)> = FILES
        .iter()
        .map(|name| {
            let source = std::fs::read_to_string(root.join(name))
                .unwrap_or_else(|_| panic!("{name} must exist; update FILES when it moves"));
            (*name, source)
        })
        .collect();
    let scanned: usize = files
        .iter()
        .map(|(_, source)| {
            SINGLE_STATEMENT_CALLS
                .iter()
                .map(|call| source.matches(call).count())
                .sum::<usize>()
        })
        .sum();
    assert!(
        scanned > 0,
        "anti-vacuity: the scan found no SQL call at all"
    );

    let violations = multi_statement_literals(&files);
    assert!(
        violations.is_empty(),
        "rusqlite ≥ 0.35 refuses a second statement in these calls at runtime; use \
         `execute_batch`: {violations:?}"
    );
}

#[test]
fn the_scan_catches_a_second_statement_in_every_literal_form() {
    let planted = [
        (
            "plain",
            r#"conn.execute("DELETE FROM a; DELETE FROM b", [])?;"#.to_owned(),
        ),
        (
            "raw",
            "conn.prepare(r#\"SELECT 1; SELECT 2\"#)?;".to_owned(),
        ),
        (
            "multi-line",
            "conn.query_row(\n    \"SELECT x FROM t;\n     DROP TABLE t\",\n    [],\n    |r| r.get(0),\n)?;"
                .to_owned(),
        ),
    ];
    for (form, source) in &planted {
        assert_eq!(
            multi_statement_literals(&[("planted.rs", source.clone())]).len(),
            1,
            "the {form} literal must be caught"
        );
    }
    let fine = r#"conn.execute("DELETE FROM a;", [])?; conn.execute_batch("A; B;")?;"#.to_owned();
    assert!(
        multi_statement_literals(&[("fine.rs", fine)]).is_empty(),
        "one trailing `;` and `execute_batch` are not violations"
    );
}
