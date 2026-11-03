//! A client→relay frame, parsed into what the plane judge reads.
//!
//! Separate from `crate::frame`, which is the recorder's control-frame model:
//! that one decides what the proxy intercepts, this one what a relay received.
//! Total over any JSON: a frame that does not parse into a shape below becomes
//! [`Frame::Other`] (an unknown frame, never a skipped one).
//!
//! These types hold pubkeys, routing ids, event ids and subscription ids, so
//! none has `Debug` (Security Rule 15).

use serde_json::{Map, Value};

use super::policy::Verb;

/// One event object.
pub struct Event {
    /// The id the event claims.
    pub id: String,
    /// The author.
    pub pubkey: String,
    /// The kind.
    pub kind: u16,
    /// `created_at`, unix seconds.
    pub created_at: u64,
    /// Every tag, each at least a name and one value.
    pub tags: Vec<Vec<String>>,
}

impl Event {
    /// Parses one event object; `None` when a field the judge reads is absent
    /// or of the wrong type, or a tag is not at least a name and a value.
    #[must_use]
    pub fn from_value(value: &Value) -> Option<Self> {
        let object = value.as_object()?;
        let tags = object
            .get("tags")?
            .as_array()?
            .iter()
            .map(|tag| {
                let parts = tag
                    .as_array()?
                    .iter()
                    .map(|part| part.as_str().map(str::to_owned))
                    .collect::<Option<Vec<String>>>()?;
                (parts.len() >= 2).then_some(parts)
            })
            .collect::<Option<Vec<_>>>()?;
        Some(Self {
            id: object.get("id")?.as_str()?.to_owned(),
            pubkey: object.get("pubkey")?.as_str()?.to_owned(),
            kind: u16::try_from(object.get("kind")?.as_u64()?).ok()?,
            created_at: object.get("created_at")?.as_u64()?,
            tags,
        })
    }

    /// The values of every tag named `name` (its first value).
    pub fn tag_values<'a>(&'a self, name: &'a str) -> impl Iterator<Item = &'a str> + 'a {
        self.tags
            .iter()
            .filter_map(move |tag| match tag.as_slice() {
                [tag_name, value, ..] if tag_name == name => Some(value.as_str()),
                _ => None,
            })
    }
}

/// One REQ or NEG-OPEN filter.
pub struct Filter {
    /// Every key the filter carries.
    pub keys: Vec<String>,
    /// `kinds`.
    pub kinds: Option<Vec<u16>>,
    /// `authors`.
    pub authors: Option<Vec<String>>,
    /// `ids`.
    pub ids: Option<Vec<String>>,
    /// `#h`.
    pub h: Option<Vec<String>>,
    /// `#p`.
    pub p: Option<Vec<String>>,
    /// `limit`.
    pub limit: Option<u64>,
    /// A key the judge reads carried a value of the wrong type.
    pub malformed: bool,
}

fn strings(value: &Value) -> Option<Vec<String>> {
    value
        .as_array()?
        .iter()
        .map(|item| item.as_str().map(str::to_owned))
        .collect()
}

impl Filter {
    /// Parses one filter object; `None` when it is not an object.
    #[must_use]
    pub fn from_value(value: &Value) -> Option<Self> {
        Some(Self::from_map(value.as_object()?))
    }

    fn from_map(map: &Map<String, Value>) -> Self {
        let mut filter = Self {
            keys: map.keys().cloned().collect(),
            kinds: None,
            authors: None,
            ids: None,
            h: None,
            p: None,
            limit: None,
            malformed: false,
        };
        for (key, value) in map {
            let ok = match key.as_str() {
                "kinds" => {
                    filter.kinds = value.as_array().and_then(|kinds| {
                        kinds
                            .iter()
                            .map(|kind| kind.as_u64().and_then(|k| u16::try_from(k).ok()))
                            .collect()
                    });
                    filter.kinds.is_some()
                }
                "authors" => {
                    filter.authors = strings(value);
                    filter.authors.is_some()
                }
                "ids" => {
                    filter.ids = strings(value);
                    filter.ids.is_some()
                }
                "#h" => {
                    filter.h = strings(value);
                    filter.h.is_some()
                }
                "#p" => {
                    filter.p = strings(value);
                    filter.p.is_some()
                }
                "limit" => {
                    filter.limit = value.as_u64();
                    filter.limit.is_some()
                }
                "since" | "until" => value.is_u64(),
                _ => true,
            };
            filter.malformed |= !ok;
        }
        filter
    }
}

/// A client→relay frame.
pub enum Frame {
    /// `["EVENT", <event>]`.
    Event(Event),
    /// `["REQ", <sub>, <filter>…]`.
    Req {
        /// The subscription id.
        sub: String,
        /// The filters, each parsed.
        filters: Vec<Filter>,
    },
    /// `["NEG-OPEN", <sub>, <filter>, <initial message>]`.
    NegOpen {
        /// The subscription id.
        sub: String,
        /// The filter.
        filter: Filter,
        /// The opening message, hex.
        initial: String,
    },
    /// `["CLOSE", <sub>]`.
    Close(String),
    /// `["NEG-MSG", <sub>, <message>]`.
    NegMsg(String),
    /// `["NEG-CLOSE", <sub>]`.
    NegClose(String),
    /// Anything else, with the verb it claimed (`Verb::Other` when none).
    Other(Verb),
}

impl Frame {
    /// Parses a frame as the journal records it (the parsed array, or `null`).
    #[must_use]
    pub fn from_value(value: &Value) -> Self {
        let Some(array) = value.as_array() else {
            return Self::Other(Verb::Other);
        };
        let verb = match array.first().and_then(Value::as_str) {
            Some("EVENT") => Verb::Event,
            Some("REQ") => Verb::Req,
            Some("NEG-OPEN") => Verb::NegOpen,
            Some("CLOSE") => Verb::Close,
            Some("NEG-MSG") => Verb::NegMsg,
            Some("NEG-CLOSE") => Verb::NegClose,
            _ => return Self::Other(Verb::Other),
        };
        Self::parse_as(verb, array).unwrap_or(Self::Other(verb))
    }

    /// Parses a frame from its wire text.
    #[must_use]
    pub fn parse(text: &str) -> Self {
        serde_json::from_str::<Value>(text)
            .map_or(Self::Other(Verb::Other), |value| Self::from_value(&value))
    }

    fn parse_as(verb: Verb, array: &[Value]) -> Option<Self> {
        let sub = || array.get(1)?.as_str().map(str::to_owned);
        match (verb, array.len()) {
            (Verb::Event, 2) => Event::from_value(&array[1]).map(Self::Event),
            (Verb::Req, n) if n >= 3 => Some(Self::Req {
                sub: sub()?,
                filters: array[2..]
                    .iter()
                    .map(Filter::from_value)
                    .collect::<Option<Vec<_>>>()?,
            }),
            (Verb::NegOpen, 4) => Some(Self::NegOpen {
                sub: sub()?,
                filter: Filter::from_value(&array[2])?,
                initial: array[3].as_str()?.to_owned(),
            }),
            (Verb::Close, 2) => sub().map(Self::Close),
            (Verb::NegMsg, 3) => sub().map(Self::NegMsg),
            (Verb::NegClose, 2) => sub().map(Self::NegClose),
            _ => None,
        }
    }

    /// The verb the frame claimed.
    #[must_use]
    pub const fn verb(&self) -> Verb {
        match self {
            Self::Event(_) => Verb::Event,
            Self::Req { .. } => Verb::Req,
            Self::NegOpen { .. } => Verb::NegOpen,
            Self::Close(_) => Verb::Close,
            Self::NegMsg(_) => Verb::NegMsg,
            Self::NegClose(_) => Verb::NegClose,
            Self::Other(verb) => *verb,
        }
    }
}
