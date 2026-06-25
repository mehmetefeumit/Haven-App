# Translating Haven

How to add or update a language. For the dev/build mechanics (gen-l10n, the
pseudo-locale, the CI gate) see `README.md` in this folder; for the policy see
the **Localization (l10n)** section of the repo `CLAUDE.md`.

## The two mandatory checks (every language addition)

A language is not "done" until BOTH pass:

1. **AI-agent review.** Multiple agents translate (one per language) and a
   **separate, independent reviewer agent** confirms each language for
   **correctness, readability, accessibility, and proper, natural use of the
   language** — idiomatic register, grammar/agreement, plural forms, script/RTL,
   and that semantics/label strings read well aloud for screen readers. One
   machine pass is never enough.
2. **Programmatic parity.** `dart scripts/ci/arb_parity_check.dart haven/lib/l10n`
   (keys / placeholders / empty values / CLDR plural categories) and
   `flutter gen-l10n` (must be **warning-free**).

## Readability and accessibility outrank literal parity

Exact, word-for-word parity with English must **never** come at the cost of how
the text reads in the target language. Where the language's features call for it
— gender agreement, plural categories, word order, honorific register,
script/RTL, or cognates that are genuinely identical to English — **deviate from
the literal rendering**. The parity tool is built for this: structural checks
hard-fail, but the "identical to English" check is only a non-failing *warning*,
because cognates are legitimate.

## Do not translate

Keep verbatim (the source `@description` flags these "intentionally English"):
- Brand / product names: **Haven**.
- Protocol / technical terms shown in UI: **Nostr**, `nsec1…`, `kind 10050`,
  `wss://…` examples.
- Compact time-pill abbreviations (`{count}m` / `{count}h` / `{count}d`).
- ICU placeholders `{name}` and plural/select structure (translate the branch
  *text*, not the syntax).

## Shipped languages and their CLDR plural categories

| Locale | Language | Plural categories (cardinal) | Script |
|--------|----------|------------------------------|--------|
| en | English (template) | one, other | Latin |
| es | Spanish | one, many, other | Latin |
| fr | French | one, many, other (note: `one` covers 0 and 1) | Latin |
| de | German | one, other | Latin |
| ar | Arabic | zero, one, two, few, many, other | Arabic (RTL) |
| tr | Turkish | one, other | Latin |
| ne | Nepali | one, other | Devanagari |

Use **keyword categories only** (`one`/`other`/…), not explicit `=1`/`=0`
branches — mixing them makes gen-l10n warn. The parity tool enforces that every
plural message supplies its language's required categories.

## Adding a new language (checklist)

1. Translate + review per the two checks above, producing `lib/l10n/app_<code>.arb`
   (just `@@locale` + message keys; no `@` metadata).
2. Add the language to:
   - `arb_parity_check.dart` → `_requiredPluralCategories` (its CLDR categories);
   - `lib/src/l10n/language_helpers.dart` → `kEndonyms` (its native name) and,
     if right-to-left, `kRtlLanguages`.
3. `flutter gen-l10n` (warning-free) → commit the regenerated sources.
4. The Appearance → Language picker and the `locale_smoke_test.dart` cover the
   new locale automatically (both derive from `AppLocalizations.supportedLocales`).
5. `flutter test` green; `arb_parity_check.dart` green.
