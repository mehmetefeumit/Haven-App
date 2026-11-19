//! The public surface of the MDK and rust-nostr crates that Haven's guards and
//! decisions are keyed to, read from the sources cargo resolved and compared,
//! both ways, with reviewed lists in `scripts/ci/dependency_surface/`.
//!
//! A guard that bans a dependency's spelling passes silently once the spelling
//! moves; a decision made outside an exhaustive `match` takes a new variant
//! into its default unseen. Here every surface they rest on is pinned, so a
//! renamed, added or removed method, field or variant fails and names itself,
//! and every name a guard must refuse is planted in a copy of the tree and run
//! through the guard script itself (grep and Rust regexes differ).
//!
//! The lists live beside the guards, not here: `check_no_forensic_recorder.sh`
//! and `check_sqlcipher_first_use_gate.sh` read `haven-core/tests`, and a list
//! of what they ban spells it. `HAVEN_BLESS_DEPENDENCY_SURFACE=1` rewrites
//! them from the sources; the diff is what gets reviewed.

mod cargo_graph;
#[path = "helpers/sources.rs"]
mod sources;

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::str::FromStr;
use std::sync::OnceLock;

use proc_macro2::{Delimiter, Spacing, TokenStream, TokenTree};

/// What a module of a dependency declares.
#[derive(Default)]
struct Module {
    enums: BTreeMap<String, Enum>,
    /// Every other item name.
    items: HashSet<String>,
    /// The identifiers in item-level macro calls, which a macro may declare:
    /// read after every real item and `use`, so one cannot mask them.
    macro_idents: HashSet<String>,
    /// `type NAME = PATH;`, resolved through PATH.
    aliases: Vec<UseEntry>,
    children: HashSet<String>,
    uses: Vec<UseEntry>,
}

struct Enum {
    variants: Vec<String>,
    non_exhaustive: bool,
}

/// `use` as written: resolved only when a path reaches it, once every module
/// is loaded.
struct UseEntry {
    /// `None` for a glob.
    name: Option<String>,
    target: Vec<String>,
    leading_colon: bool,
}

/// A method, associated function, free function or field of a dependency.
struct Member {
    /// Defining module, starting with the crate's lib name.
    module: Vec<String>,
    owner: Option<String>,
    name: String,
    field: bool,
    /// What it returns, when that is `Self` or a single named type.
    returns: Option<String>,
    /// The file it is in, under the crate's `src/`.
    file: String,
}

impl Member {
    fn path(&self) -> String {
        let mut path = self.module.join("::");
        if let Some(owner) = &self.owner {
            path = format!("{path}::{owner}");
        }
        format!("{path}{}{}", if self.field { "." } else { "::" }, self.name)
    }
}

/// An item-level call of a macro that declares an enum, expanded after load.
struct EnumMacroCall {
    module: Vec<String>,
    lib: String,
    macro_name: String,
    /// Kept as text: a token stream is neither `Send` nor `Sync`, and the
    /// index is shared by every test.
    tokens: String,
}

#[derive(Default)]
struct Index {
    libs: BTreeSet<String>,
    modules: HashMap<Vec<String>, Module>,
    members: Vec<Member>,
    /// `(lib, name)` of every `macro_rules!` whose body declares an enum.
    enum_macros: BTreeMap<(String, String), String>,
    enum_macro_calls: Vec<EnumMacroCall>,
}

#[derive(Debug, PartialEq, Eq)]
enum Found {
    Enum(String),
    Item,
    Module,
    /// A crate that is neither MDK's nor rust-nostr's.
    External,
    Unresolved,
}

fn ident_list(tokens: &TokenStream) -> Vec<String> {
    let mut out = Vec::new();
    for tree in tokens.clone() {
        match tree {
            TokenTree::Ident(ident) => out.push(ident.to_string()),
            TokenTree::Group(group) => out.extend(ident_list(&group.stream())),
            TokenTree::Punct(_) | TokenTree::Literal(_) => {}
        }
    }
    out
}

fn is_cfg_test(attrs: &[syn::Attribute]) -> bool {
    attrs.iter().any(|attr| {
        attr.path().is_ident("cfg")
            && attr
                .parse_args::<syn::Ident>()
                .is_ok_and(|ident| ident == "test")
    })
}

/// The file a `#[path = "…"]` attribute names.
fn path_attribute(attrs: &[syn::Attribute]) -> Option<String> {
    attrs.iter().find_map(|attr| match &attr.meta {
        syn::Meta::NameValue(pair) if pair.path.is_ident("path") => match &pair.value {
            syn::Expr::Lit(syn::ExprLit {
                lit: syn::Lit::Str(text),
                ..
            }) => Some(text.value()),
            _ => panic!("a `#[path]` that is not a string"),
        },
        _ => None,
    })
}

fn use_entries(
    tree: &syn::UseTree,
    prefix: &[String],
    out: &mut Vec<(Option<String>, Vec<String>)>,
) {
    let with = |segment: &syn::Ident| {
        let mut path = prefix.to_vec();
        if segment != "self" {
            path.push(segment.to_string());
        }
        path
    };
    match tree {
        syn::UseTree::Path(path) => use_entries(&path.tree, &with(&path.ident), out),
        syn::UseTree::Name(name) => {
            let target = with(&name.ident);
            out.push((target.last().cloned(), target));
        }
        syn::UseTree::Rename(rename) => {
            out.push((Some(rename.rename.to_string()), with(&rename.ident)));
        }
        syn::UseTree::Glob(_) => out.push((None, prefix.to_vec())),
        syn::UseTree::Group(group) => {
            for tree in &group.items {
                use_entries(tree, prefix, out);
            }
        }
    }
}

/// What a signature returns, when that is one named type, seen through a
/// `Result`, `Option`, `Arc` or `Box` around it.
fn returned_type(output: &syn::ReturnType) -> Option<String> {
    fn named(ty: &syn::Type) -> Option<String> {
        let syn::Type::Path(path) = ty else {
            return None;
        };
        let last = path.path.segments.last()?;
        if ["Result", "Option", "Arc", "Box"]
            .iter()
            .any(|wrapper| last.ident == wrapper)
        {
            if let syn::PathArguments::AngleBracketed(args) = &last.arguments {
                if let Some(syn::GenericArgument::Type(inner)) = args.args.first() {
                    return named(inner);
                }
            }
        }
        Some(last.ident.to_string())
    }
    let syn::ReturnType::Type(_, ty) = output else {
        return None;
    };
    named(ty)
}

impl Index {
    fn load(libs: &[sources::PinnedLib]) -> Self {
        let mut index = Self {
            libs: libs.iter().map(|lib| lib.lib.clone()).collect(),
            ..Self::default()
        };
        for lib in libs {
            let src = lib
                .root
                .parent()
                .expect("the lib's directory")
                .to_path_buf();
            index.load_file(std::slice::from_ref(&lib.lib), &lib.root, &src, &src);
        }
        index.expand_enum_macros();
        index
    }

    fn load_file(&mut self, module: &[String], file: &Path, child_dir: &Path, src: &Path) {
        let text = std::fs::read_to_string(file)
            .unwrap_or_else(|e| panic!("read {}: {e}", file.display()));
        let parsed =
            syn::parse_file(&text).unwrap_or_else(|e| panic!("parse {}: {e}", file.display()));
        let rel = file
            .strip_prefix(src)
            .expect("a module file under src/")
            .display()
            .to_string();
        self.modules.entry(module.to_vec()).or_default();
        self.load_items(module, &parsed.items, child_dir, src, &rel);
    }

    #[allow(clippy::too_many_lines)]
    fn load_items(
        &mut self,
        module: &[String],
        items: &[syn::Item],
        child_dir: &Path,
        src: &Path,
        file: &str,
    ) {
        let lib = module[0].clone();
        for item in items {
            let declared: Option<String> = match item {
                syn::Item::Mod(item) => {
                    if is_cfg_test(&item.attrs) {
                        continue;
                    }
                    let name = item.ident.to_string();
                    let mut child = module.to_vec();
                    child.push(name.clone());
                    self.modules
                        .get_mut(module)
                        .expect("the parent module")
                        .children
                        .insert(name.clone());
                    let dir = child_dir.join(&name);
                    if let Some((_, items)) = &item.content {
                        self.modules.entry(child.clone()).or_default();
                        self.load_items(&child, items, &dir, src, file);
                    } else if let Some(at) = path_attribute(&item.attrs) {
                        // Relative to the declaring file's directory; its own
                        // children sit beside it.
                        let path = src.join(file).parent().expect("a directory").join(at);
                        assert!(
                            path.is_file(),
                            "{file}: no file at the `#[path]` of `mod {name}`"
                        );
                        let own = path.parent().expect("a directory").to_path_buf();
                        self.load_file(&child, &path, &own, src);
                    } else {
                        let flat = child_dir.join(format!("{name}.rs"));
                        let nested = dir.join("mod.rs");
                        let path = if flat.is_file() { flat } else { nested };
                        assert!(path.is_file(), "{file}: no file for `mod {name}`");
                        self.load_file(&child, &path, &dir, src);
                    }
                    None
                }
                syn::Item::Enum(item) => {
                    self.declare_enum(
                        module,
                        item.ident.to_string(),
                        Enum {
                            variants: item.variants.iter().map(|v| v.ident.to_string()).collect(),
                            non_exhaustive: item
                                .attrs
                                .iter()
                                .any(|attr| attr.path().is_ident("non_exhaustive")),
                        },
                    );
                    None
                }
                syn::Item::Struct(item) => {
                    if let syn::Fields::Named(fields) = &item.fields {
                        for field in &fields.named {
                            if matches!(field.vis, syn::Visibility::Public(_)) {
                                self.members.push(Member {
                                    module: module.to_vec(),
                                    owner: Some(item.ident.to_string()),
                                    name: field.ident.as_ref().expect("a named field").to_string(),
                                    field: true,
                                    returns: None,
                                    file: file.to_owned(),
                                });
                            }
                        }
                    }
                    Some(item.ident.to_string())
                }
                syn::Item::Trait(item) => {
                    for trait_item in &item.items {
                        if let syn::TraitItem::Fn(method) = trait_item {
                            self.members.push(Member {
                                module: module.to_vec(),
                                owner: Some(item.ident.to_string()),
                                name: method.sig.ident.to_string(),
                                field: false,
                                returns: returned_type(&method.sig.output),
                                file: file.to_owned(),
                            });
                        }
                    }
                    Some(item.ident.to_string())
                }
                syn::Item::Impl(item) => {
                    let syn::Type::Path(self_ty) = &*item.self_ty else {
                        continue;
                    };
                    let owner = self_ty
                        .path
                        .segments
                        .last()
                        .expect("a type")
                        .ident
                        .to_string();
                    for impl_item in &item.items {
                        if let syn::ImplItem::Fn(method) = impl_item {
                            if item.trait_.is_some()
                                || matches!(method.vis, syn::Visibility::Public(_))
                            {
                                self.members.push(Member {
                                    module: module.to_vec(),
                                    owner: Some(owner.clone()),
                                    name: method.sig.ident.to_string(),
                                    field: false,
                                    returns: returned_type(&method.sig.output),
                                    file: file.to_owned(),
                                });
                            }
                        }
                    }
                    None
                }
                syn::Item::Fn(item) => {
                    if matches!(item.vis, syn::Visibility::Public(_)) {
                        self.members.push(Member {
                            module: module.to_vec(),
                            owner: None,
                            name: item.sig.ident.to_string(),
                            field: false,
                            returns: returned_type(&item.sig.output),
                            file: file.to_owned(),
                        });
                    }
                    Some(item.sig.ident.to_string())
                }
                syn::Item::Use(item) => {
                    let mut entries = Vec::new();
                    use_entries(&item.tree, &[], &mut entries);
                    let target = self.modules.get_mut(module).expect("module");
                    for (name, path) in entries {
                        target.uses.push(UseEntry {
                            name,
                            target: path,
                            leading_colon: item.leading_colon.is_some(),
                        });
                    }
                    None
                }
                syn::Item::Macro(item) => {
                    let name = item
                        .mac
                        .path
                        .segments
                        .last()
                        .expect("a macro")
                        .ident
                        .to_string();
                    if let Some(defined) = &item.ident {
                        if ident_list(&item.mac.tokens)
                            .iter()
                            .any(|ident| ident == "enum")
                        {
                            self.enum_macros.insert(
                                (lib.clone(), defined.to_string()),
                                item.mac.tokens.to_string(),
                            );
                        }
                        let exported = item
                            .attrs
                            .iter()
                            .any(|attr| attr.path().is_ident("macro_export"));
                        let home = if exported {
                            vec![lib.clone()]
                        } else {
                            module.to_vec()
                        };
                        self.modules
                            .entry(home)
                            .or_default()
                            .items
                            .insert(defined.to_string());
                    } else {
                        let target = self.modules.get_mut(module).expect("module");
                        target.macro_idents.extend(ident_list(&item.mac.tokens));
                        self.enum_macro_calls.push(EnumMacroCall {
                            module: module.to_vec(),
                            lib: lib.clone(),
                            macro_name: name,
                            tokens: item.mac.tokens.to_string(),
                        });
                    }
                    None
                }
                syn::Item::ExternCrate(item) => {
                    let name = item
                        .rename
                        .as_ref()
                        .map_or(&item.ident, |(_, rename)| rename);
                    self.modules
                        .get_mut(module)
                        .expect("module")
                        .uses
                        .push(UseEntry {
                            name: Some(name.to_string()),
                            target: vec![item.ident.to_string()],
                            leading_colon: true,
                        });
                    None
                }
                syn::Item::Const(item) => Some(item.ident.to_string()),
                syn::Item::Static(item) => Some(item.ident.to_string()),
                syn::Item::Type(item) => {
                    if let syn::Type::Path(aliased) = &*item.ty {
                        let segments = &aliased.path.segments;
                        self.modules
                            .get_mut(module)
                            .expect("module")
                            .aliases
                            .push(UseEntry {
                                name: Some(item.ident.to_string()),
                                target: segments.iter().map(|s| s.ident.to_string()).collect(),
                                leading_colon: aliased.path.leading_colon.is_some(),
                            });
                        None
                    } else {
                        Some(item.ident.to_string())
                    }
                }
                syn::Item::Union(item) => Some(item.ident.to_string()),
                syn::Item::TraitAlias(item) => Some(item.ident.to_string()),
                _ => None,
            };
            if let Some(name) = declared {
                self.modules
                    .get_mut(module)
                    .expect("module")
                    .items
                    .insert(name);
            }
        }
    }

    /// The enum a `macro_rules!` declares, for each call of it: the body's one
    /// `enum NAME { … }`, its one `$( … )*` repetition replaced by the leading
    /// identifier of every `NAME => …` entry of the call. A macro of another
    /// shape fails here rather than hiding its enum.
    fn expand_enum_macros(&mut self) {
        let calls = std::mem::take(&mut self.enum_macro_calls);
        let mut expanded = BTreeSet::new();
        for call in calls {
            let key = (call.lib.clone(), call.macro_name.clone());
            let Some(body) = self
                .enum_macros
                .get(&key)
                .map(|body| TokenStream::from_str(body).expect("lex"))
            else {
                let elsewhere = self.enum_macros.keys().find(|(_, name)| *name == key.1);
                assert!(
                    elsewhere.is_none(),
                    "a call of `{}!` in {} declares an enum with a macro of another crate, \
                     which this reader does not expand",
                    key.1,
                    key.0
                );
                continue;
            };
            let (name, body_variants) = macro_enum(&body).unwrap_or_else(|| {
                panic!(
                    "macro `{}` declares an enum this reader cannot expand",
                    key.1
                )
            });
            let entries = arrow_entries(&TokenStream::from_str(&call.tokens).expect("lex"));
            assert!(
                !entries.is_empty(),
                "a call of `{}` lists no entries",
                key.1
            );
            let variants = body_variants
                .into_iter()
                .flat_map(|v| {
                    if v.is_empty() {
                        entries.clone()
                    } else {
                        vec![v]
                    }
                })
                .collect();
            self.declare_enum(
                &call.module,
                name,
                Enum {
                    variants,
                    non_exhaustive: false,
                },
            );
            expanded.insert(key);
        }
        let unexpanded: Vec<_> = self
            .enum_macros
            .keys()
            .filter(|key| !expanded.contains(*key))
            .collect();
        assert!(
            unexpanded.is_empty(),
            "macros that declare an enum with no call this reader expanded: {unexpanded:?}"
        );
    }

    /// Records an enum. Two definitions of one name are cfg alternatives;
    /// they must agree, or which one a build sees is not pinned.
    fn declare_enum(&mut self, module: &[String], name: String, found: Enum) {
        let here = self.modules.get_mut(module).expect("module");
        if let Some(seen) = here.enums.get(&name) {
            assert!(
                seen.variants == found.variants && seen.non_exhaustive == found.non_exhaustive,
                "`{}::{name}` has cfg alternatives with different variants",
                module.join("::")
            );
        }
        here.enums.insert(name, found);
    }

    fn absolute(&self, module: &[String], entry: &UseEntry) -> Vec<String> {
        let (first, rest) = entry.target.split_first().expect("a use path");
        if entry.leading_colon {
            return entry.target.clone();
        }
        let mut base = match first.as_str() {
            "crate" => vec![module[0].clone()],
            "self" => module.to_vec(),
            "super" => module[..module.len() - 1].to_vec(),
            _ => {
                let here = &self.modules[module];
                if here.children.contains(first)
                    || here.items.contains(first)
                    || here.macro_idents.contains(first)
                    || here.enums.contains_key(first)
                {
                    let mut path = module.to_vec();
                    path.push(first.clone());
                    path
                } else {
                    vec![first.clone()]
                }
            }
        };
        let mut rest = rest.iter().peekable();
        while rest.peek().is_some_and(|segment| *segment == "super") {
            base.pop();
            rest.next();
        }
        base.extend(rest.cloned());
        base
    }

    fn resolve(&self, path: &[String], depth: usize) -> Found {
        if !self.libs.contains(&path[0]) {
            return Found::External;
        }
        if depth > 24 {
            return Found::Unresolved;
        }
        self.walk(&path[..1], &path[1..], depth)
    }

    fn walk(&self, module: &[String], rest: &[String], depth: usize) -> Found {
        let Some(here) = self.modules.get(module) else {
            return Found::Unresolved;
        };
        let Some((name, tail)) = rest.split_first() else {
            return Found::Module;
        };
        let child = || [module, std::slice::from_ref(name)].concat();
        if here.enums.contains_key(name) {
            return Found::Enum(child().join("::"));
        }
        if !tail.is_empty() && here.children.contains(name) {
            return self.walk(&child(), tail, depth);
        }
        if here.items.contains(name) {
            return Found::Item;
        }
        if here.children.contains(name) {
            return self.walk(&child(), tail, depth);
        }
        if let Some(entry) = here
            .aliases
            .iter()
            .find(|entry| entry.name.as_ref() == Some(name))
        {
            return match self.resolve(&self.absolute(module, entry), depth + 1) {
                Found::Enum(key) => Found::Enum(key),
                Found::Unresolved => Found::Unresolved,
                Found::Item | Found::Module | Found::External => Found::Item,
            };
        }
        for entry in here
            .uses
            .iter()
            .filter(|entry| entry.name.as_ref() == Some(name))
        {
            let found = self.resolve(
                &[self.absolute(module, entry).as_slice(), tail].concat(),
                depth + 1,
            );
            if found != Found::Unresolved {
                return found;
            }
        }
        if here.macro_idents.contains(name) {
            return Found::Item;
        }
        // A glob of an enum's variants brings no item a path through this
        // module could mean. A glob into a crate this index does not read
        // could bring any name, so it answers only when no glob into one it
        // reads does.
        let mut outside = false;
        for entry in here.uses.iter().filter(|entry| entry.name.is_none()) {
            let target = self.absolute(module, entry);
            if matches!(self.resolve(&target, depth + 1), Found::Enum(_)) {
                continue;
            }
            match self.resolve(&[target.as_slice(), rest].concat(), depth + 1) {
                Found::Unresolved => {}
                Found::External => outside = true,
                found => return found,
            }
        }
        if outside {
            Found::External
        } else {
            Found::Unresolved
        }
    }
}

/// The enum a macro body declares: its name, and its variants in order with
/// `""` where the one repetition stands.
fn macro_enum(body: &TokenStream) -> Option<(String, Vec<String>)> {
    fn find(tokens: &TokenStream) -> Option<(String, TokenStream)> {
        let trees: Vec<TokenTree> = tokens.clone().into_iter().collect();
        for (at, tree) in trees.iter().enumerate() {
            match tree {
                TokenTree::Ident(ident) if ident == "enum" => {
                    let (Some(TokenTree::Ident(name)), Some(TokenTree::Group(group))) =
                        (trees.get(at + 1), trees.get(at + 2))
                    else {
                        return None;
                    };
                    return Some((name.to_string(), group.stream()));
                }
                TokenTree::Group(group) => {
                    if let Some(found) = find(&group.stream()) {
                        return Some(found);
                    }
                }
                _ => {}
            }
        }
        None
    }
    let (name, variants) = find(body)?;
    let trees: Vec<TokenTree> = variants.into_iter().collect();
    let mut out = Vec::new();
    let mut at = 0;
    while at < trees.len() {
        match (&trees[at], trees.get(at + 1)) {
            (TokenTree::Punct(p), Some(TokenTree::Group(_))) if p.as_char() == '#' => at += 2,
            (TokenTree::Punct(p), Some(TokenTree::Group(g)))
                if p.as_char() == '$' && g.delimiter() == Delimiter::Parenthesis =>
            {
                if out.contains(&String::new()) {
                    return None;
                }
                out.push(String::new());
                at += 2;
            }
            (TokenTree::Ident(ident), _) => {
                out.push(ident.to_string());
                at += 1;
            }
            _ => at += 1,
        }
    }
    out.contains(&String::new()).then_some((name, out))
}

/// The identifier before every top-level `=>` of a macro call.
fn arrow_entries(tokens: &TokenStream) -> Vec<String> {
    let trees: Vec<TokenTree> = tokens.clone().into_iter().collect();
    trees
        .windows(3)
        .filter_map(|w| match w {
            [TokenTree::Ident(name), TokenTree::Punct(eq), TokenTree::Punct(gt)]
                if eq.as_char() == '=' && eq.spacing() == Spacing::Joint && gt.as_char() == '>' =>
            {
                Some(name.to_string())
            }
            _ => None,
        })
        .collect()
}

fn index() -> &'static Index {
    static INDEX: OnceLock<Index> = OnceLock::new();
    INDEX.get_or_init(|| Index::load(&sources::pinned_libs()))
}

fn repo() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("the repository")
        .to_path_buf()
}

fn rust_files(dir: &Path, out: &mut Vec<PathBuf>) {
    let mut entries: Vec<_> = std::fs::read_dir(dir)
        .unwrap_or_else(|e| panic!("read {}: {e}", dir.display()))
        .map(|entry| entry.expect("a directory entry").path())
        .collect();
    entries.sort();
    for path in entries {
        if path.is_dir() {
            rust_files(&path, out);
        } else if path.extension().is_some_and(|ext| ext == "rs") {
            out.push(path);
        }
    }
}

/// Every path a token stream spells, `a::b::C`, with whether it starts with
/// `::`. A segment after a closing `>` is an associated item of a qualified
/// type, never the start of a path.
fn paths(tokens: TokenStream, out: &mut Vec<(bool, Vec<String>)>) {
    let trees: Vec<TokenTree> = tokens.into_iter().collect();
    let colons = |at: usize| {
        matches!(
            (trees.get(at), trees.get(at + 1)),
            (Some(TokenTree::Punct(a)), Some(TokenTree::Punct(b)))
                if a.as_char() == ':' && a.spacing() == Spacing::Joint && b.as_char() == ':'
        )
    };
    let ident = |at: usize| matches!(trees.get(at), Some(TokenTree::Ident(_)));
    let mut at = 0;
    while at < trees.len() {
        if let TokenTree::Group(group) = &trees[at] {
            paths(group.stream(), out);
            at += 1;
            continue;
        }
        let leading = colons(at);
        let start = if leading { at + 2 } else { at };
        if !ident(start) {
            at = start.max(at + 1);
            continue;
        }
        let after_type = leading
            && at > 0
            && matches!(&trees[at - 1], TokenTree::Punct(p) if p.as_char() == '>');
        let mut segments = Vec::new();
        at = start;
        while let Some(TokenTree::Ident(segment)) = trees.get(at) {
            segments.push(segment.to_string());
            at += 1;
            if colons(at) && ident(at + 2) {
                at += 2;
            } else {
                break;
            }
        }
        if !after_type {
            out.push((leading, segments));
        }
    }
}

/// A `use` statement: whether it starts with `::`, and each name it binds
/// (`None` for a glob) with its path.
type UseStatement = (bool, Vec<(Option<String>, Vec<String>)>);

/// Every `use` tree in a token stream, at any depth.
fn uses(tokens: TokenStream, out: &mut Vec<UseStatement>) {
    let trees: Vec<TokenTree> = tokens.into_iter().collect();
    let mut at = 0;
    while at < trees.len() {
        match &trees[at] {
            TokenTree::Ident(ident) if ident == "use" => {
                let end = trees[at..]
                    .iter()
                    .position(|tree| matches!(tree, TokenTree::Punct(p) if p.as_char() == ';'))
                    .map_or(trees.len(), |n| at + n);
                let mut body: Vec<TokenTree> = trees[at + 1..end].to_vec();
                let leading = matches!(
                    (body.first(), body.get(1)),
                    (Some(TokenTree::Punct(a)), Some(TokenTree::Punct(b))) if a.as_char() == ':' && b.as_char() == ':'
                );
                if leading {
                    body.drain(..2);
                }
                if let Ok(tree) = syn::parse2::<syn::UseTree>(body.into_iter().collect()) {
                    let mut entries = Vec::new();
                    use_entries(&tree, &[], &mut entries);
                    out.push((leading, entries));
                }
                at = end;
            }
            TokenTree::Group(group) => {
                uses(group.stream(), out);
                at += 1;
            }
            _ => at += 1,
        }
    }
}

/// The dependency enums Haven's source names, each with the files naming it,
/// and every path rooted in a dependency that resolves to nothing.
fn named_enums() -> (BTreeMap<String, BTreeSet<String>>, Vec<String>) {
    let index = index();
    let repo = repo();
    let mut files = Vec::new();
    for root in ["haven-core/src", "haven/rust_builder/src"] {
        rust_files(&repo.join(root), &mut files);
    }
    assert!(
        files.len() > 100,
        "{} Rust files under Haven's source",
        files.len()
    );
    let mut named: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    let mut unresolved = Vec::new();
    for file in files {
        let rel = file
            .strip_prefix(&repo)
            .expect("under the repository")
            .display()
            .to_string();
        let text = std::fs::read_to_string(&file).unwrap_or_else(|e| panic!("read {rel}: {e}"));
        let tokens = TokenStream::from_str(&text).unwrap_or_else(|e| panic!("lex {rel}: {e}"));
        let mut aliases: HashMap<String, Vec<Vec<String>>> = HashMap::new();
        let mut shadowed = HashSet::new();
        let mut trees = Vec::new();
        uses(tokens.clone(), &mut trees);
        for (leading, entries) in trees {
            for (name, target) in entries {
                let dependency = index.libs.contains(&target[0]);
                match name {
                    None => assert!(
                        !dependency,
                        "{rel} glob-imports `{}`: name each item, so the enums it brings are seen here",
                        target.join("::")
                    ),
                    Some(name) if dependency => aliases.entry(name).or_default().push(target),
                    Some(name) if !leading => {
                        shadowed.insert(name);
                    }
                    Some(_) => {}
                }
            }
        }
        let mut spelled = Vec::new();
        paths(tokens, &mut spelled);
        for (leading, segments) in spelled {
            let first = &segments[0];
            let targets: Vec<Vec<String>> =
                if let Some(targets) = aliases.get(first).filter(|_| !leading) {
                    targets
                        .iter()
                        .map(|target| [target.as_slice(), &segments[1..]].concat())
                        .collect()
                } else if index.libs.contains(first) && (leading || !shadowed.contains(first)) {
                    vec![segments.clone()]
                } else {
                    continue;
                };
            for target in targets {
                match index.resolve(&target, 0) {
                    Found::Enum(key) => {
                        named.entry(key).or_default().insert(rel.clone());
                    }
                    Found::Unresolved => unresolved.push(format!("{rel}: {}", target.join("::"))),
                    Found::Item | Found::Module | Found::External => {}
                }
            }
        }
    }
    unresolved.sort();
    unresolved.dedup();
    (named, unresolved)
}

// ---------------------------------------------------------------------------
// Reviewed lists.
// ---------------------------------------------------------------------------

fn list_path(name: &str) -> PathBuf {
    repo().join("scripts/ci/dependency_surface").join(name)
}

fn blessing() -> bool {
    std::env::var("HAVEN_BLESS_DEPENDENCY_SURFACE").as_deref() == Ok("1")
}

/// The list's lines, without its `#` header and blank lines.
fn list_body(name: &str) -> Vec<String> {
    let text = std::fs::read_to_string(list_path(name))
        .unwrap_or_else(|e| panic!("read scripts/ci/dependency_surface/{name}: {e}"));
    text.lines()
        .filter(|line| !line.trim().is_empty() && !line.starts_with('#'))
        .map(str::to_owned)
        .collect()
}

fn bless(name: &str, body: &[String]) {
    let text = std::fs::read_to_string(list_path(name)).unwrap_or_default();
    let mut out = String::new();
    for line in text
        .lines()
        .take_while(|line| line.starts_with('#'))
        .chain(body.iter().map(String::as_str))
    {
        out.push_str(line);
        out.push('\n');
    }
    std::fs::write(list_path(name), out).expect("write the list");
}

/// Lines grouped under the unindented line before them: an enum and its
/// variants.
fn grouped(lines: &[String]) -> BTreeMap<String, Vec<String>> {
    let mut groups: BTreeMap<String, Vec<String>> = BTreeMap::new();
    let mut header = String::new();
    for line in lines {
        if let Some(variant) = line.strip_prefix("    ") {
            groups
                .entry(header.clone())
                .or_default()
                .push(variant.to_owned());
        } else {
            header.clone_from(line);
            groups.entry(header.clone()).or_default();
        }
    }
    groups
}

/// The committed enum list must equal `actual`; a difference names each enum
/// added, removed or changed, with its variants before and after.
fn compare_enums(name: &str, actual: &[String]) {
    let committed = list_body(name);
    if committed == actual {
        return;
    }
    if blessing() {
        bless(name, actual);
        return;
    }
    let (was, now) = (grouped(&committed), grouped(actual));
    let mut moved = Vec::new();
    let keys: BTreeSet<&String> = was.keys().chain(now.keys()).collect();
    for key in keys {
        match (was.get(key), now.get(key)) {
            (Some(_), None) => moved.push(format!("no longer named, or gone: {key}")),
            (None, Some(variants)) => moved.push(format!("newly named: {key} {variants:?}")),
            (Some(before), Some(after)) if before != after => {
                moved.push(format!("{key}: listed {before:?}, now {after:?}"));
            }
            _ => {}
        }
    }
    if moved.is_empty() {
        moved.push("the same enums and variants, in another order".to_owned());
    }
    panic!(
        "scripts/ci/dependency_surface/{name} no longer matches the resolved sources: \
         {moved:#?}\nRe-read every Haven use of each enum outside an exhaustive `match`, \
         then rewrite the list with HAVEN_BLESS_DEPENDENCY_SURFACE=1 and review the diff."
    );
}

/// A members list: `<path> <verdict>[ # reason]`. The paths must equal
/// `actual` both ways; returns each path's verdict.
fn verdicts(name: &str, actual: &BTreeSet<String>) -> BTreeMap<String, String> {
    let mut listed = BTreeMap::new();
    for line in list_body(name) {
        let (entry, reason) = line
            .split_once(" # ")
            .map_or((line.as_str(), ""), |(e, r)| (e, r));
        let mut words = entry.split_whitespace();
        let (Some(path), Some(verdict), None) = (words.next(), words.next(), words.next()) else {
            panic!("{name}: `{line}` is not `<path> <verdict>[ # reason]`");
        };
        assert!(
            verdict == "refused" || (verdict == "allowed" && !reason.trim().is_empty()),
            "{name}: `{line}`: the verdict is `refused`, or `allowed` with a reason"
        );
        listed.insert(path.to_owned(), verdict.to_owned());
    }
    let have: BTreeSet<String> = listed.keys().cloned().collect();
    if &have != actual {
        if blessing() {
            let body: Vec<String> = actual
                .iter()
                .map(|path| {
                    list_body(name)
                        .into_iter()
                        .find(|line| line.split_whitespace().next() == Some(path.as_str()))
                        .unwrap_or_else(|| format!("{path} refused"))
                })
                .collect();
            bless(name, &body);
            return verdicts(name, actual);
        }
        let gone: Vec<_> = have.difference(actual).collect();
        let new: Vec<_> = actual.difference(&have).collect();
        panic!(
            "scripts/ci/dependency_surface/{name} no longer matches the resolved sources.\n\
             In the list, not in the sources: {gone:#?}\n\
             In the sources, not in the list: {new:#?}\n\
             Review each against the guard the list keeps honest, give it a verdict, and \
             make the guard refuse every `refused` one."
        );
    }
    listed
}

/// Runs `script` over a copy of `roots` with each plant written to a file of
/// its own, and asserts it fails, naming every planted file.
fn guard_refuses(script: &str, roots: &[&str], plants: &[(String, String)]) {
    assert!(!plants.is_empty(), "{script}: nothing planted");
    let repo = repo();
    let tree = tempfile::tempdir().expect("a temporary tree");
    for root in roots {
        let to = tree.path().join(root);
        std::fs::create_dir_all(to.parent().expect("a parent")).expect("mkdir");
        let status = Command::new("cp")
            .arg("-R")
            .arg(repo.join(root))
            .arg(&to)
            .status()
            .expect("run cp");
        assert!(status.success(), "copy {root}");
    }
    let mut files = Vec::new();
    for (n, (dir, code)) in plants.iter().enumerate() {
        let rel = format!("{dir}/planted_{n}.rs");
        std::fs::write(tree.path().join(&rel), format!("{code}\n")).expect("plant");
        files.push(rel);
    }
    let out = Command::new("bash")
        .arg(repo.join("scripts/ci").join(script))
        .env("REPO_ROOT_OVERRIDE", tree.path())
        .env("LC_ALL", "C.UTF-8")
        .output()
        .expect("run the guard");
    let said = format!(
        "{}{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    assert_eq!(
        out.status.code(),
        Some(1),
        "{script} over the plants:\n{said}"
    );
    let missed: Vec<String> = files
        .iter()
        .zip(plants)
        .filter(|(file, _)| !said.contains(file.as_str()))
        .map(|(file, (_, code))| format!("{file}: {code}"))
        .collect();
    assert!(
        missed.is_empty(),
        "{script} lets these through: {missed:#?}"
    );
}

/// The members of `packages` (`(package, prefix)`: files under `src/` whose
/// path starts with the prefix) that `wanted` keeps.
fn members(packages: &[(&str, &str)], wanted: impl Fn(&Member) -> bool) -> Vec<&'static Member> {
    let libs = sources::pinned_libs();
    let scopes: Vec<(String, String)> = packages
        .iter()
        .map(|(package, under)| {
            let lib = libs
                .iter()
                .find(|lib| lib.package == *package)
                .unwrap_or_else(|| panic!("`{package}` is not in the graph"));
            (lib.lib.clone(), (*under).to_owned())
        })
        .collect();
    index()
        .members
        .iter()
        .filter(|member| {
            scopes.iter().any(|(lib, under)| {
                member.module[0] == *lib && member.file.starts_with(under.as_str())
            }) && wanted(member)
        })
        .collect()
}

fn by_path(found: Vec<&'static Member>) -> BTreeMap<String, &'static Member> {
    found
        .into_iter()
        .map(|member| (member.path(), member))
        .collect()
}

// ---------------------------------------------------------------------------
// I6: the variants of every dependency enum Haven's source names.
// ---------------------------------------------------------------------------

/// Every MDK and rust-nostr enum `haven-core/src` or `haven/rust_builder/src`
/// names has exactly the variants the list records, in declaration order. A
/// decision over one of them outside an exhaustive `match` (an `if let`, a
/// `matches!`, an `==`, a wildcard over a wrapper) takes a new variant into its
/// default branch without a compile error; this is what makes that variant
/// seen.
#[test]
fn every_dependency_enum_haven_names_has_the_reviewed_variants() {
    let (named, unresolved) = named_enums();
    assert!(
        unresolved.is_empty(),
        "paths into MDK or rust-nostr that resolve to nothing, so the enums they may name \
         go unseen: {unresolved:#?}"
    );
    let index = index();
    let mut actual = Vec::new();
    for key in named.keys() {
        let (module, name) = key.rsplit_once("::").expect("a module path");
        let module: Vec<String> = module.split("::").map(str::to_owned).collect();
        let found = &index.modules[&module].enums[name];
        actual.push(if found.non_exhaustive {
            format!("{key} #[non_exhaustive]")
        } else {
            key.clone()
        });
        actual.extend(
            found
                .variants
                .iter()
                .map(|variant| format!("    {variant}")),
        );
    }
    compare_enums("enums.txt", &actual);
}

/// The reader behind the list sees what the list depends on it seeing: an
/// enum reached through a crate's re-export, one a macro declares, an `Error`
/// told apart from its namesakes by its `use` path, and a variant named inside
/// a macro call.
#[test]
fn the_enum_reader_resolves_re_exports_macros_and_namesakes() {
    let index = index();
    let path = |p: &str| p.split("::").map(str::to_owned).collect::<Vec<_>>();
    assert_eq!(
        index.resolve(&path("nostr_sdk::prelude::RelayPoolNotification"), 0),
        Found::Enum("nostr_relay_pool::pool::RelayPoolNotification".into())
    );
    assert_eq!(
        index.resolve(&path("nostr::Kind::Custom"), 0),
        Found::Enum("nostr::event::kind::Kind".into())
    );
    assert!(index.modules[&path("nostr::event::kind")].enums["Kind"]
        .variants
        .ends_with(&["Custom".to_owned()]));
    assert_eq!(
        index.resolve(&path("nostr::event::Error"), 0),
        Found::Enum("nostr::event::error::Error".into())
    );
    assert_eq!(index.resolve(&path("nostr::Keys"), 0), Found::Item);
    assert_eq!(
        index.resolve(&path("nostr::NoSuchThing"), 0),
        Found::Unresolved
    );
    assert_eq!(index.resolve(&path("serde::Serialize"), 0), Found::External);

    let mut spelled = Vec::new();
    paths(
        TokenStream::from_str("matches!(x, IngestOutcome::Processed { .. }) && <T as U>::Error::A")
            .expect("lex"),
        &mut spelled,
    );
    assert!(spelled.contains(&(false, path("IngestOutcome::Processed"))));
    assert!(!spelled.iter().any(|(_, s)| s[0] == "Error"));
}

/// An index over crates written out from `crates` (`(lib, [(path under src,
/// source)])`), for the reader's own tests.
fn fixture_index(crates: &[(&str, &[(&str, &str)])]) -> Index {
    let dir = tempfile::tempdir().expect("a temporary tree");
    let libs: Vec<sources::PinnedLib> = crates
        .iter()
        .map(|(lib, files)| {
            for (path, source) in *files {
                let at = dir.path().join(lib).join(path);
                std::fs::create_dir_all(at.parent().expect("a parent")).expect("mkdir");
                std::fs::write(at, source).expect("write a fixture source");
            }
            sources::PinnedLib {
                package: (*lib).to_owned(),
                lib: (*lib).to_owned(),
                root: dir.path().join(lib).join("lib.rs"),
            }
        })
        .collect();
    Index::load(&libs)
}

fn path_of(text: &str) -> Vec<String> {
    text.split("::").map(str::to_owned).collect()
}

/// A dependency's `type` alias of an enum is the enum.
#[test]
fn the_enum_reader_resolves_a_type_alias_to_its_enum() {
    let index = fixture_index(&[(
        "dep",
        &[(
            "lib.rs",
            "pub enum Mode { A, B }\npub type Alias = Mode;\npub type Other = u8;",
        )],
    )]);
    assert_eq!(
        index.resolve(&path_of("dep::Alias::A"), 0),
        Found::Enum("dep::Mode".into())
    );
    assert_eq!(index.resolve(&path_of("dep::Other"), 0), Found::Item);
}

/// An identifier inside an item-level macro call is no item that hides a
/// re-exported enum of the same name.
#[test]
fn a_macro_calls_identifier_does_not_mask_a_re_exported_enum() {
    let index = fixture_index(&[(
        "dep",
        &[(
            "lib.rs",
            "mod inner { pub enum Mode { A } }\npub use inner::Mode;\nregister!(Mode);",
        )],
    )]);
    assert_eq!(
        index.resolve(&path_of("dep::Mode"), 0),
        Found::Enum("dep::inner::Mode".into())
    );
}

/// cfg alternatives of one enum that disagree leave its variants unpinned.
#[test]
#[should_panic(expected = "`dep::Mode` has cfg alternatives with different variants")]
fn cfg_alternatives_with_different_variants_fail() {
    fixture_index(&[(
        "dep",
        &[(
            "lib.rs",
            "#[cfg(unix)]\npub enum Mode { A }\n#[cfg(not(unix))]\npub enum Mode { A, B }",
        )],
    )]);
}

/// An enum declared through another crate's macro is not expanded here, so it
/// fails rather than going unseen.
#[test]
#[should_panic(expected = "declares an enum with a macro of another crate")]
fn an_enum_declared_by_another_crates_macro_fails() {
    fixture_index(&[
        (
            "maker",
            &[(
                "lib.rs",
                "#[macro_export]\nmacro_rules! modes { ($($n:ident => $v:expr),*) => { pub enum Mode { $($n,)* Other } }; }",
            )],
        ),
        ("dep", &[("lib.rs", "maker::modes! { A => 1, B => 2 }")]),
    ]);
}

// ---------------------------------------------------------------------------
// I1, I2: check 11 of check_engine_client_options.sh.
// ---------------------------------------------------------------------------

const RELAY_CLIENT_TREES: [&str; 3] = [
    "haven-core/src",
    "haven/rust_builder/src",
    "tooling/soak/src",
];
const RELAY_CLIENT_CRATES: [(&str, &str); 2] = [("nostr-sdk", "client/"), ("nostr-relay-pool", "")];

/// Every way to give a relay client a key or tell it to authenticate (I1),
/// and every constructor of a relay-client type (I2), is either refused by
/// check 11 — planted in a copy of the tree, the guard fails naming it — or
/// listed as allowed with the reason it needs no ban.
#[test]
fn check_11_refuses_every_signer_authentication_and_constructor_spelling() {
    let auth = by_path(members(&RELAY_CLIENT_CRATES, |member| {
        let name = member.name.to_lowercase();
        name.contains("auth") || name.contains("signer")
    }));
    let auth_verdicts = verdicts("i1_client_auth.txt", &auth.keys().cloned().collect());

    let relay_type = |name: &str| {
        let base = name.strip_suffix("Builder").unwrap_or(name);
        base.ends_with("Client") || base.ends_with("Pool") || base.ends_with("Relay")
    };
    let constructors = by_path(members(&RELAY_CLIENT_CRATES, |member| {
        !member.field
            && member.owner.as_deref().is_some_and(relay_type)
            && member
                .returns
                .as_deref()
                .is_some_and(|ty| ty == "Self" || relay_type(ty))
    }));
    let constructor_verdicts = verdicts(
        "i2_client_constructors.txt",
        &constructors.keys().cloned().collect(),
    );

    let mut plants = Vec::new();
    for (path, member) in &auth {
        if auth_verdicts[path] != "refused" {
            continue;
        }
        let name = &member.name;
        if member.field {
            plants.push(format!(
                "fn planted(x: &mut Planted, y: Planted) {{ x.{name} = y; }}"
            ));
        } else {
            plants.push(format!("fn planted(x: &Planted) {{ x.{name}(true); }}"));
            if let Some(owner) = &member.owner {
                plants.push(format!(
                    "fn planted(x: &Planted) {{ {owner}::{name}(x, true); }}"
                ));
            }
        }
    }
    for (path, member) in &constructors {
        if constructor_verdicts[path] == "refused" {
            let owner = member.owner.as_deref().expect("an owner");
            plants.push(format!(
                "fn planted() {{ let _ = {owner}::{}(); }}",
                member.name
            ));
        }
    }
    let plants: Vec<(String, String)> = plants
        .into_iter()
        .map(|code| ("haven-core/src".to_owned(), code))
        .collect();
    guard_refuses(
        "check_engine_client_options.sh",
        &RELAY_CLIENT_TREES,
        &plants,
    );
}

// ---------------------------------------------------------------------------
// I4: check_no_forensic_recorder.sh.
// ---------------------------------------------------------------------------

const RECORDER_TREES: [&str; 5] = [
    "haven-core/src",
    "haven-core/tests",
    "haven/rust_builder/src",
    "tooling/soak/src",
    "tooling/soak/tests",
];

/// Every function and field of every MDK crate whose name says recorder is
/// either refused by the forensic-recorder guard or listed as allowed with
/// the reason it installs nothing.
#[test]
fn the_forensic_recorder_guard_refuses_every_way_to_install_one() {
    let libs = sources::pinned_libs();
    let mdk: Vec<(&str, &str)> = libs
        .iter()
        .filter(|lib| !(lib.package == "nostr" || lib.package.starts_with("nostr-")))
        .map(|lib| (lib.package.as_str(), ""))
        .collect();
    assert!(mdk.len() >= 6, "{} MDK crates in the graph", mdk.len());
    let found = by_path(members(&mdk, |member| {
        member.name.to_lowercase().contains("recorder")
    }));
    let listed = verdicts("i4_recorder.txt", &found.keys().cloned().collect());
    let plants: Vec<(String, String)> = found
        .iter()
        .filter(|(path, _)| listed[*path] == "refused")
        .enumerate()
        .map(|(n, (_, member))| {
            let code = if member.field {
                format!(
                    "fn planted() -> Planted {{ Planted {{ {}: Some(x) }} }}",
                    member.name
                )
            } else {
                format!("fn planted(x: Planted) {{ x.{}(y); }}", member.name)
            };
            (RECORDER_TREES[n % RECORDER_TREES.len()].to_owned(), code)
        })
        .collect();
    guard_refuses("check_no_forensic_recorder.sh", &RECORDER_TREES, &plants);
}

// ---------------------------------------------------------------------------
// I3: check_publish_client_no_subscription.sh.
// ---------------------------------------------------------------------------

/// Every method of MDK's relay-client trait and of its transport adapter is
/// either refused by the publish-client guard or listed as allowed: the
/// subscription plane can grow a method the guard does not spell.
#[test]
fn the_publish_client_guard_refuses_every_subscription_method() {
    let owners = [
        "NostrRelayClient",
        "TransportAdapter",
        "NostrTransportAdapter",
    ];
    let found = by_path(members(
        &[
            ("transport-nostr-adapter", ""),
            ("cgka-traits", "transport_adapter.rs"),
        ],
        |member| {
            !member.field
                && member
                    .owner
                    .as_deref()
                    .is_some_and(|owner| owners.contains(&owner))
        },
    ));
    assert!(found.len() > 10, "{} methods", found.len());
    let listed = verdicts(
        "i3_relay_client_methods.txt",
        &found.keys().cloned().collect(),
    );
    let plants: Vec<(String, String)> = found
        .iter()
        .filter(|(path, _)| listed[*path] == "refused")
        .map(|(_, member)| {
            let owner = member.owner.as_deref().expect("an owner");
            let code = if owner == "NostrRelayClient" {
                format!(
                    "fn planted(c: &NostrSdkRelayClient) {{ c.{}(); }}",
                    member.name
                )
            } else {
                format!("fn planted(a: &{owner}) {{ a.{}(); }}", member.name)
            };
            ("haven-core/src".to_owned(), code)
        })
        .collect();
    guard_refuses(
        "check_publish_client_no_subscription.sh",
        &RELAY_CLIENT_TREES,
        &plants,
    );
}

// ---------------------------------------------------------------------------
// check_no_exporter_label_override.sh.
// ---------------------------------------------------------------------------

/// The guard bans one spelling of the one local lever that can downgrade the
/// kind-445 exporter derivation (Security Rule 11). The peeler must still
/// spell it so, and have no second one, or the ban guards nothing.
#[test]
fn the_exporter_label_override_the_guard_bans_is_the_peelers_only_one() {
    let found: Vec<String> = members(&[("transport-nostr-peeler", "")], |member| {
        member.name.contains("exporter") || member.name.contains("label")
    })
    .iter()
    .map(|member| member.path())
    .collect();
    assert_eq!(
        found,
        ["transport_nostr_peeler::peeler::NostrMlsPeeler::with_exporter_label"]
    );
}

// ---------------------------------------------------------------------------
// I5: check_sqlcipher_first_use_gate.sh.
// ---------------------------------------------------------------------------

const SQLITE_TREES: [&str; 5] = [
    "haven-core/src",
    "haven-core/tests",
    "haven/rust_builder/src",
    "tooling/soak/src",
    "tooling/soak/tests",
];

/// Every public opener of MDK's store and session crates is either refused by
/// the first-use gate when no gate call comes before it, or listed as opening
/// nothing: `SQLCipher` finishes its start-up after `SQLite` says it is ready, so
/// an opener the gate does not spell is a keyed open that can fail at process
/// start (tracker `T-SQLCIPHER-FIRST-USE`).
#[test]
fn the_first_use_gate_refuses_every_ungated_store_opener() {
    let found = by_path(members(
        &[("storage-sqlite", ""), ("cgka-session", "")],
        |member| {
            !member.field
                && (member.name.starts_with("open") || member.name.starts_with("in_memory"))
        },
    ));
    let listed = verdicts("i5_sqlite_openers.txt", &found.keys().cloned().collect());
    let plants: Vec<(String, String)> = found
        .iter()
        .filter(|(path, _)| listed[*path] == "refused")
        .map(|(_, member)| {
            let callee = member.owner.as_ref().map_or_else(
                || member.name.clone(),
                |owner| format!("{owner}::{}", member.name),
            );
            (
                "haven-core/src".to_owned(),
                format!("fn planted() {{ let _ = {callee}(x); }}"),
            )
        })
        .collect();
    guard_refuses("check_sqlcipher_first_use_gate.sh", &SQLITE_TREES, &plants);
}
