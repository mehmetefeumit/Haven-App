//! `haven-wire-planes`: oracle C8 over a wire journal, through [`judge`].
//!
//! The lane declares which roles each proxy listen carries (`--plane`); the
//! journal supplies everything else — every account's relay lists (its kind
//! 10050 / 10002 in either direction), each circle's routing (the harness's
//! routing declarations) and the event index. Every non-harness client→relay
//! frame at or below the sentinel is then judged with no sender (the union
//! rules): L3 proves ROLE PLACEMENT; the per-identity bindings are L1b's and
//! the soak's.
//!
//! Output names rule ids, role names, kind numbers, row ids, declaration
//! ordinals and bucketed counts only — never a URL, host, port, listen, `h`,
//! pubkey, id, `wire_seq`, subscription id or the token (Security Rule 15).
//! A journal that does not parse is reported in fixed text, never echoed.

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::io::Write;
use std::net::SocketAddr;
use std::path::PathBuf;

use serde_json::Value;

use super::frame::{Event, Frame};
use super::judge::{judge, Class, Finding, Judgement, Observed};
use super::policy::{export_json, overlap_rule, OverlapRule, Plane, Role, Row, Verb};
use super::table::{explicit_port, List, PlaneTable, RelayIx, RelayMatch};
use crate::frame::SENTINEL_VERB;
use crate::journal::{TYPE_CONN_ERROR, TYPE_CONN_OPEN, TYPE_FRAME};

/// The prefix of a routing declaration's token:
/// `["HAVEN_WIRE_SENTINEL","HAVEN_WIRE_ROUTING:<n>",{"h":…,"relays":[…]}]`.
pub const ROUTING_DECLARATION_PREFIX: &str = "HAVEN_WIRE_ROUTING:";

/// Every rule held.
pub const RC_CLEAN: i32 = 0;
/// A frame crossed a plane.
pub const RC_VIOLATION: i32 = 1;
/// The invocation is wrong.
pub const RC_USAGE: i32 = 2;
/// The journal or a declaration cannot be judged.
pub const RC_UNUSABLE: i32 = 3;
/// Nothing provable: no anchor, an empty snapshot, or missing ground truth.
pub const RC_META_FLOOR: i32 = 4;

const USAGE: &str = "usage: haven-wire-planes --journal <path> --sentinel <token> \
--plane <role>=<ip>:<port>... [--exclude-conn <conn_id>]... \
[--declare-overlap <role>:<role>]...\n       haven-wire-planes --export <path>\n\
roles: inbox, keypackage, discovery, profile, location";

const BANNER: &str = "wire-planes: CLEAN - C8.1-C8.8 hold: every EVENT (C8.1), REQ (C8.2) and \
NEG-OPEN (C8.3) on a listen whose roles admit it, every routing on the location plane (C8.4), \
every circle declared (C8.5), every binding grounded (C8.6), every declared role witnessed \
(C8.7), every listen declared (C8.8)";

const fn plane_of(role: Role) -> Plane {
    match role {
        Role::Inbox => Plane::OwnInbox,
        Role::KeyPackage => Plane::OwnKeyPackage,
        Role::Discovery => Plane::Discovery,
        Role::Profile => Plane::Profile,
        Role::Location => Plane::Location,
    }
}

/// `0`, `1`, `2-4` or `5+`: a magnitude, never a count.
#[must_use]
pub const fn bucket(n: usize) -> &'static str {
    match n {
        0 => "0",
        1 => "1",
        2..=4 => "2-4",
        _ => "5+",
    }
}

struct Listen {
    addr: SocketAddr,
    roles: BTreeSet<Role>,
}

impl Listen {
    fn label(&self) -> String {
        self.roles
            .iter()
            .map(|role| role.name())
            .collect::<Vec<_>>()
            .join("+")
    }
}

struct Args {
    journal: PathBuf,
    sentinel: String,
    listens: Vec<Listen>,
    exclude: HashSet<String>,
    overlaps: Vec<(Role, Role)>,
}

enum Mode {
    Export(PathBuf),
    Judge(Args),
}

fn parse_plane(value: &str) -> Option<(Role, SocketAddr)> {
    let (role, listen) = value.split_once('=')?;
    Some((Role::from_name(role)?, listen.parse().ok()?))
}

fn parse_overlap(value: &str) -> Option<(Role, Role)> {
    let (a, b) = value.split_once(':')?;
    let (a, b) = (Role::from_name(a)?, Role::from_name(b)?);
    (overlap_rule(plane_of(a), plane_of(b)) == OverlapRule::Declared).then_some((a, b))
}

fn parse_args(args: &[String]) -> Result<Mode, &'static str> {
    let mut journal = None;
    let mut sentinel = None;
    let mut export = None;
    let mut listens: Vec<Listen> = Vec::new();
    let mut exclude = HashSet::new();
    let mut overlaps = Vec::new();
    let mut it = args.iter();
    while let Some(flag) = it.next() {
        let value = it.next().ok_or("every flag takes a value")?;
        match flag.as_str() {
            "--journal" if journal.is_none() => journal = Some(PathBuf::from(value)),
            "--journal" => return Err("--journal is given once: one journal, one wire_seq space"),
            "--sentinel" if sentinel.is_none() && !value.is_empty() => sentinel = Some(value.clone()),
            "--sentinel" => return Err("--sentinel is given once, non-empty"),
            "--export" if export.is_none() => export = Some(PathBuf::from(value)),
            "--export" => return Err("--export is given once"),
            "--plane" => {
                let (role, addr) = parse_plane(value).ok_or(
                    "--plane takes <role>=<ip>:<port>: a known role and an IP literal with a port (no scheme, no hostname)",
                )?;
                if let Some(listen) = listens.iter_mut().find(|l| l.addr == addr) {
                    if !listen.roles.insert(role) {
                        return Err("a --plane role and listen pair is declared twice");
                    }
                } else if listens.iter().any(|l| l.addr.port() == addr.port()) {
                    return Err("two --plane listens share a port; routing relays map to listens by port");
                } else {
                    listens.push(Listen {
                        addr,
                        roles: BTreeSet::from([role]),
                    });
                }
            }
            "--exclude-conn" => {
                exclude.insert(value.clone());
            }
            "--declare-overlap" => overlaps.push(parse_overlap(value).ok_or(
                "--declare-overlap takes <role>:<role> naming a pair that needs a declaration (profile shares with nothing, location never with discovery; inbox and keypackage need none)",
            )?),
            _ => return Err("unknown flag"),
        }
    }
    if let Some(path) = export {
        let alone = journal.is_none() && sentinel.is_none() && listens.is_empty();
        return if alone && exclude.is_empty() && overlaps.is_empty() {
            Ok(Mode::Export(path))
        } else {
            Err("--export takes no other flag")
        };
    }
    match (journal, sentinel) {
        (Some(journal), Some(sentinel)) if !listens.is_empty() => Ok(Mode::Judge(Args {
            journal,
            sentinel,
            listens,
            exclude,
            overlaps,
        })),
        _ => Err("--journal, --sentinel and at least one --plane are required"),
    }
}

/// One journal line, validated.
struct Line {
    lifecycle: bool,
    conn: String,
    c2r: bool,
    listen: Option<String>,
    frame: Value,
}

fn parse_line(text: &str, seq: usize) -> Option<Line> {
    let value: Value = serde_json::from_str(text).ok()?;
    let object = value.as_object()?;
    let wire_seq = usize::try_from(object.get("wire_seq")?.as_u64()?).ok()?;
    let conn = object.get("conn_id")?.as_str()?.to_owned();
    let listen = match object.get("listen") {
        None => None,
        Some(listen) => Some(listen.as_str()?.to_owned()),
    };
    if wire_seq != seq {
        return None;
    }
    match object.get("type")?.as_str()? {
        TYPE_FRAME => {
            let c2r = match object.get("dir")?.as_str()? {
                "c2r" => true,
                "r2c" => false,
                _ => return None,
            };
            Some(Line {
                lifecycle: false,
                conn,
                c2r,
                listen,
                frame: object.get("frame")?.clone(),
            })
        }
        kind @ (TYPE_CONN_OPEN | TYPE_CONN_ERROR) => {
            let lifecycle_ok = !object.contains_key("frame")
                && !object.contains_key("dir")
                && (kind == TYPE_CONN_OPEN || object.get("reason").is_some_and(Value::is_string));
            lifecycle_ok.then_some(Line {
                lifecycle: kind == TYPE_CONN_OPEN,
                conn,
                c2r: false,
                listen,
                frame: Value::Null,
            })
        }
        _ => None,
    }
}

fn read_journal(args: &Args) -> Result<(Vec<Line>, String), &'static str> {
    let text = std::fs::read_to_string(&args.journal)
        .map_err(|_| "the journal is absent or unreadable; nothing was checked")?;
    if text.is_empty() {
        return Err("the journal is empty; the recorder never wrote a line");
    }
    let body = text.strip_suffix('\n').unwrap_or(&text);
    let lines = body
        .split('\n')
        .enumerate()
        .map(|(seq, line)| parse_line(line, seq))
        .collect::<Option<Vec<_>>>()
        .ok_or("the journal is not a gapless NDJSON wire journal from wire_seq 0 (a line does not parse, breaks the record schema or the sequence)")?;
    Ok((lines, text))
}

fn sentinel_frame(line: &Line) -> Option<&[Value]> {
    let array = line.frame.as_array()?;
    (line.c2r && array.first()?.as_str()? == SENTINEL_VERB).then_some(array.as_slice())
}

struct Declaration {
    h: String,
    ports: Vec<u16>,
}

enum SentinelFrame {
    /// A snapshot marker or a harness-socket declaration.
    Marker,
    /// A routing declaration.
    Routing(Declaration),
    /// Neither, well-formed.
    Malformed,
}

fn sentinel_kind(array: &[Value]) -> SentinelFrame {
    routing_declaration(array).unwrap_or(SentinelFrame::Malformed)
}

fn routing_declaration(array: &[Value]) -> Option<SentinelFrame> {
    let token = array.get(1)?.as_str()?;
    let Some(ordinal) = token.strip_prefix(ROUTING_DECLARATION_PREFIX) else {
        return (array.len() == 2).then_some(SentinelFrame::Marker);
    };
    if array.len() != 3 || ordinal.is_empty() || !ordinal.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let payload = array[2].as_object()?;
    if payload.len() != 2 {
        return None;
    }
    let h = payload.get("h")?.as_str()?;
    let hex = h.len() == 64 && h.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'));
    let ports = payload
        .get("relays")?
        .as_array()?
        .iter()
        .map(|relay| explicit_port(relay.as_str()?))
        .collect::<Option<Vec<_>>>()?;
    (hex && !ports.is_empty()).then(|| {
        SentinelFrame::Routing(Declaration {
            h: h.to_owned(),
            ports,
        })
    })
}

struct Report<'w> {
    out: &'w mut dyn Write,
    violation: bool,
    meta_floor: bool,
}

impl Report<'_> {
    fn line(&mut self, text: &str) {
        let _ = writeln!(self.out, "{text}");
    }

    fn violation(&mut self, text: &str) {
        self.violation = true;
        self.line(text);
    }

    fn meta_floor(&mut self, text: &str) {
        self.meta_floor = true;
        self.line(text);
    }
}

struct Judged {
    relay: RelayIx,
    conn: u64,
    at: u64,
    frame: Frame,
}

const fn rule_of(finding: &Finding) -> (&'static str, bool) {
    match finding.class {
        Class::UndeclaredCircle => ("C8.5", false),
        Class::UnresolvedId | Class::NoGroundTruth => ("C8.6", false),
        _ => match finding.verb {
            Verb::Event => ("C8.1", true),
            Verb::NegOpen | Verb::NegMsg | Verb::NegClose => ("C8.3", true),
            _ => ("C8.2", true),
        },
    }
}

const fn witnesses(role: Role, row: Row, plane: Plane) -> bool {
    match role {
        Role::Inbox => matches!(row, Row::Ev1059 | Row::Req1059P),
        Role::KeyPackage => matches!(row, Row::Ev30443),
        Role::Discovery => matches!(plane, Plane::Discovery),
        Role::Profile => matches!(row, Row::Ev0),
        Role::Location => matches!(row, Row::Ev445Commit | Row::Ev445Location),
    }
}

/// Every account's lists from the journal: kind 10050 `relay` entries on
/// inbox listens, kind 10002 write-capable `r` entries on key-package listens.
/// The newest copy of each list wins (NIP-01: `created_at`, then the lower id);
/// the first one seen is taken to have held from the start, since a list
/// exists on the device before it is first published.
fn add_lists(table: &mut PlaneTable, snapshot: &[Line], port_ix: &Ports<'_>) {
    struct Version {
        created_at: u64,
        id: String,
        relays: BTreeSet<RelayIx>,
        at: u64,
    }
    let mut lists: BTreeMap<(String, u16), Vec<Version>> = BTreeMap::new();
    for (seq, line) in snapshot.iter().enumerate() {
        for event in events_of(line) {
            let (role, tag) = match event.kind {
                10050 => (Role::Inbox, "relay"),
                10002 => (Role::KeyPackage, "r"),
                _ => continue,
            };
            let relays = event
                .tags
                .iter()
                .filter_map(|t| match t.as_slice() {
                    [name, url, marker @ ..]
                        if name == tag
                            && (role == Role::Inbox
                                || marker.first().is_none_or(|m| m == "write")) =>
                    {
                        explicit_port(url)
                    }
                    _ => None,
                })
                .filter_map(|port| port_ix.get(&port))
                .filter(|(_, listen)| listen.roles.contains(&role))
                .map(|(ix, _)| *ix)
                .collect();
            let versions = lists.entry((event.pubkey.clone(), event.kind)).or_default();
            let newer = versions.last().is_none_or(|last| {
                event.created_at > last.created_at
                    || (event.created_at == last.created_at && event.id < last.id)
            });
            if newer {
                versions.push(Version {
                    created_at: event.created_at,
                    id: event.id,
                    relays,
                    at: if versions.is_empty() { 0 } else { seq as u64 },
                });
            }
        }
    }
    for ((author, kind), versions) in &lists {
        table.add_account(author);
        let list = if *kind == 10050 {
            List::OwnInbox(author)
        } else {
            List::OwnKeyPackage(author)
        };
        let mut held: BTreeSet<RelayIx> = BTreeSet::new();
        for version in versions {
            for relay in held.difference(&version.relays) {
                table.remove(list, *relay, version.at);
            }
            for relay in &version.relays {
                table.add(list, *relay, version.at);
            }
            held.clone_from(&version.relays);
        }
    }
}

/// Every event object of an `EVENT` frame, either direction.
fn events_of(line: &Line) -> Vec<Event> {
    match line.frame.as_array() {
        Some(array) if array.first().and_then(Value::as_str) == Some("EVENT") => {
            array.iter().skip(1).filter_map(Event::from_value).collect()
        }
        _ => Vec::new(),
    }
}

/// Runs the CLI; returns the exit code.
pub fn run(args: &[String], stdout: &mut dyn Write, stderr: &mut dyn Write) -> i32 {
    let args = match parse_args(args) {
        Ok(Mode::Judge(args)) => args,
        Ok(Mode::Export(path)) => {
            return if std::fs::write(&path, export_json()).is_ok() {
                RC_CLEAN
            } else {
                let _ = writeln!(stderr, "UNUSABLE: the matrix could not be written");
                RC_UNUSABLE
            };
        }
        Err(why) => {
            let _ = writeln!(stderr, "usage error: {why}\n{USAGE}");
            return RC_USAGE;
        }
    };
    let mut report = Report {
        out: stdout,
        violation: false,
        meta_floor: false,
    };
    match judge_journal(&args, &mut report) {
        Err((rc, why)) => {
            let label = if rc == RC_UNUSABLE {
                "UNUSABLE"
            } else {
                "META-FLOOR"
            };
            let _ = writeln!(stderr, "{label}: {why}");
            rc
        }
        Ok(()) if report.violation => {
            report.line("wire-planes: VIOLATION (rc 1)");
            RC_VIOLATION
        }
        Ok(()) if report.meta_floor => {
            report.line("wire-planes: META-FLOOR (rc 4): the planes could not be proved");
            RC_META_FLOOR
        }
        Ok(()) => {
            report.line(BANNER);
            RC_CLEAN
        }
    }
}

type Failure = (i32, &'static str);

fn check_placement(args: &Args) -> Result<(), Failure> {
    for listen in &args.listens {
        let roles: Vec<Role> = listen.roles.iter().copied().collect();
        for (i, &a) in roles.iter().enumerate() {
            for &b in &roles[i + 1..] {
                match overlap_rule(plane_of(a), plane_of(b)) {
                    OverlapRule::Allowed => {}
                    OverlapRule::Never => {
                        return Err((
                            RC_UNUSABLE,
                            "a listen carries two roles that never share a relay (profile with any, location with discovery)",
                        ));
                    }
                    OverlapRule::Declared => {
                        if !args
                            .overlaps
                            .iter()
                            .any(|&(x, y)| (x, y) == (a, b) || (y, x) == (a, b))
                        {
                            return Err((
                                RC_UNUSABLE,
                                "a listen carries two roles no --declare-overlap admits together",
                            ));
                        }
                    }
                }
            }
        }
    }
    Ok(())
}

/// Each declared listen by port, with its relay in the table.
type Ports<'a> = HashMap<u16, (RelayIx, &'a Listen)>;

/// The table: the lane's placement, the declared routings, every account's
/// lists and the event index, all from the snapshot.
fn build_table<'a>(
    args: &'a Args,
    snapshot: &[Line],
    declarations: &[Declaration],
    report: &mut Report<'_>,
) -> Result<(PlaneTable, Ports<'a>), Failure> {
    let mut table = PlaneTable::new(RelayMatch::Port);
    let mut port_ix = HashMap::new();
    for listen in &args.listens {
        let ix = table
            .add_relay(&format!("ws://{}", listen.addr))
            .ok_or((RC_USAGE, "a --plane listen is not an address"))?;
        port_ix.insert(listen.addr.port(), (ix, listen));
        for (role, list) in [
            (Role::Discovery, List::Discovery),
            (Role::Profile, List::Profile),
        ] {
            if listen.roles.contains(&role) {
                table.add(list, ix, 0);
            }
        }
    }
    for &(a, b) in &args.overlaps {
        table.declare_overlap(plane_of(a), plane_of(b));
    }
    // A routing is the circle's from its creation, before the harness can
    // declare it, so it holds from the start of the snapshot.
    for (n, declaration) in declarations.iter().enumerate() {
        for port in &declaration.ports {
            match port_ix.get(port) {
                None => report.meta_floor(&format!(
                    "C8.4 META-FLOOR: declared circle #{} names a relay on no declared listen; its traffic can reach a relay this check cannot see",
                    n + 1
                )),
                Some((_, listen)) if !listen.roles.contains(&Role::Location) => {
                    report.violation(&format!(
                        "C8.4 VIOLATION: declared circle #{} is routed to a listen carrying {}",
                        n + 1,
                        listen.label()
                    ));
                }
                Some((ix, _)) => table.add_routing(&declaration.h, *ix, 0),
            }
        }
    }
    add_lists(&mut table, snapshot, &port_ix);
    for line in snapshot {
        for event in events_of(line) {
            let h = event.tag_values("h").next().map(str::to_owned);
            table.index_event(&event.id, event.kind, h.as_deref());
        }
    }
    Ok((table, port_ix))
}

/// What the snapshot hands the judge: every non-harness client frame on a
/// declared listen (an EVENT once per listen), and what it could not place.
#[derive(Default)]
struct Collected {
    judged: Vec<Judged>,
    client_frames: usize,
    undeclared: usize,
    unresolvable: usize,
    inbound: BTreeMap<Role, BTreeSet<u16>>,
}

fn collect(snapshot: &[Line], harness: &HashSet<String>, port_ix: &Ports<'_>) -> Collected {
    let opened: HashMap<&str, &str> = snapshot
        .iter()
        .filter(|line| line.lifecycle)
        .filter_map(|line| Some((line.conn.as_str(), line.listen.as_deref()?)))
        .collect();
    let mut conns: HashMap<&str, u64> = HashMap::new();
    let mut seen_events: HashSet<(String, RelayIx)> = HashSet::new();
    let mut out = Collected::default();
    for (seq, line) in snapshot.iter().enumerate() {
        if line.lifecycle || harness.contains(&line.conn) {
            continue;
        }
        let listen = line
            .listen
            .as_deref()
            .filter(|listen| !listen.is_empty())
            .or_else(|| opened.get(line.conn.as_str()).copied());
        let declared = listen
            .and_then(|listen| listen.parse::<SocketAddr>().ok())
            .and_then(|addr| port_ix.get(&addr.port()).filter(|(_, l)| l.addr == addr));
        if !line.c2r {
            if let Some((_, listen)) = declared {
                for event in events_of(line) {
                    for role in &listen.roles {
                        out.inbound.entry(*role).or_default().insert(event.kind);
                    }
                }
            }
            continue;
        }
        out.client_frames += 1;
        let Some((relay, _)) = declared else {
            if listen.is_some() {
                out.undeclared += 1;
            } else {
                out.unresolvable += 1;
            }
            continue;
        };
        let frame = Frame::from_value(&line.frame);
        if frame.verb() == Verb::Event && !seen_events.insert((line.frame.to_string(), *relay)) {
            continue;
        }
        let next = conns.len() as u64;
        let conn = *conns.entry(line.conn.as_str()).or_insert(next);
        out.judged.push(Judged {
            relay: *relay,
            conn,
            at: seq as u64,
            frame,
        });
    }
    out
}

/// One report line's grouping: rule, violation or not, class, row, frame
/// label, listen roles.
type Group<'a> = (&'a str, bool, &'a str, &'a str, String, String);

fn report_findings(
    args: &Args,
    collected: &Collected,
    judgement: &Judgement,
    report: &mut Report<'_>,
) {
    let listen_of = |relay: RelayIx| args.listens.get(relay.0 as usize);
    let mut grouped: BTreeMap<Group<'_>, usize> = BTreeMap::new();
    for finding in &judgement.findings {
        let (rule, violation) = rule_of(finding);
        let kind = match &collected.judged[finding.index].frame {
            Frame::Event(event) => format!("kind {}", event.kind),
            other => other.verb().name().to_owned(),
        };
        let label = listen_of(finding.relay).map_or_else(String::new, Listen::label);
        let row = finding.row.map_or("no row", Row::id);
        *grouped
            .entry((rule, violation, finding.class.name(), row, kind, label))
            .or_default() += 1;
    }
    for ((rule, violation, class, row, kind, label), n) in grouped {
        let severity = if violation { "VIOLATION" } else { "META-FLOOR" };
        let text = format!(
            "{rule} {severity}: {class}: {kind} (row {row}) on a listen carrying {label}: {}",
            bucket(n)
        );
        if violation {
            report.violation(&text);
        } else {
            report.meta_floor(&text);
        }
    }
    if collected.undeclared > 0 {
        report.meta_floor(&format!(
            "C8.8 META-FLOOR: client frames on a listen no --plane declares: {}",
            bucket(collected.undeclared)
        ));
    }
    if collected.unresolvable > 0 {
        report.meta_floor(&format!(
            "C8.8 META-FLOOR: client frames with no resolvable listen: {}",
            bucket(collected.unresolvable)
        ));
    }
    for role in Role::ALL {
        let declared = args.listens.iter().any(|l| l.roles.contains(&role));
        let witnessed = judgement.hits.keys().any(|&(relay, row, plane)| {
            witnesses(role, row, plane) && listen_of(relay).is_some_and(|l| l.roles.contains(&role))
        });
        if declared && !witnessed {
            report.meta_floor(&format!(
                "C8.7 META-FLOOR: the declared role {} met no witness; its containment is vacuous",
                role.name()
            ));
        }
    }
    for (role, kinds) in &collected.inbound {
        let kinds: Vec<String> = kinds.iter().map(u16::to_string).collect();
        report.line(&format!(
            "advisory: inbound kinds seen on listens carrying {}: [{}] (not asserted)",
            role.name(),
            kinds.join(", ")
        ));
    }
}

fn judge_journal(args: &Args, report: &mut Report<'_>) -> Result<(), Failure> {
    check_placement(args)?;
    let (lines, text) = read_journal(args).map_err(|why| (RC_UNUSABLE, why))?;
    let boundary = lines
        .iter()
        .rposition(|line| {
            sentinel_frame(line)
                .and_then(|array| array.get(1)?.as_str())
                .is_some_and(|token| token == args.sentinel)
        })
        .ok_or_else(|| {
            let why = if text.contains(args.sentinel.as_str()) {
                "the token is in the journal but never as a sentinel marker frame; the read cannot be anchored"
            } else {
                "no sentinel marker frame; the read cannot be anchored"
            };
            (RC_META_FLOOR, why)
        })?;
    let snapshot = &lines[..=boundary];

    let mut harness = args.exclude.clone();
    let mut declarations = Vec::new();
    for line in snapshot {
        if let Some(array) = sentinel_frame(line) {
            harness.insert(line.conn.clone());
            match sentinel_kind(array) {
                SentinelFrame::Marker => {}
                SentinelFrame::Routing(declaration) => declarations.push(declaration),
                SentinelFrame::Malformed => {
                    return Err((
                        RC_UNUSABLE,
                        "a routing declaration is malformed (h must be 64 lowercase hex, relays a non-empty list of URLs with ports)",
                    ));
                }
            }
        }
    }
    let (table, port_ix) = build_table(args, snapshot, &declarations, report)?;
    let collected = collect(snapshot, &harness, &port_ix);
    if collected.client_frames == 0 {
        return Err((
            RC_META_FLOOR,
            "the snapshot holds no client frame outside the harness; nothing was judged",
        ));
    }
    let judgement = judge(
        &table,
        collected.judged.iter().map(|j| Observed {
            relay: j.relay,
            conn: j.conn,
            sender: None,
            at: j.at,
            frame: &j.frame,
        }),
    )
    .map_err(|_| {
        (
            RC_UNUSABLE,
            "the plane table is unusable (an undeclared or undeclarable overlap)",
        )
    })?;

    report_findings(args, &collected, &judgement, report);
    report.line(&format!(
        "advisory: listens holding more than one plane: {}; client frames judged: {}",
        bucket(table.overlapping_relays()),
        bucket(collected.judged.len())
    ));
    Ok(())
}
