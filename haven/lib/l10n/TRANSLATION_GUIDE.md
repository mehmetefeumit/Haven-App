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

## Shipped languages, their plural categories and their digits

| Locale | Language | Plural categories (cardinal) | Script | Digits (CLDR default) |
|--------|----------|------------------------------|--------|-----------------------|
| en | English (template) | one, other | Latin | Western |
| es | Spanish | one, many, other | Latin | Western |
| fr | French | one, many, other (note: `one` covers 0 and 1) | Latin | Western |
| de | German | one, other | Latin | Western |
| pt | Portuguese | one, many, other | Latin | Western |
| tr | Turkish | one, other | Latin | Western |
| ru | Russian | one, few, many, other | Cyrillic | Western |
| ar | Arabic | zero, one, two, few, many, other | Arabic (RTL) | **Western** |
| fa | Persian | one, other | Arabic (RTL) | **Persian** |
| ur | Urdu | one, other | Arabic (RTL) | **Western** |
| hi | Hindi | one, other | Devanagari | **Western** |
| ne | Nepali | one, other | Devanagari | **Devanagari** |
| ja | Japanese | other | Japanese | Western |

The bolded rows are the trap: **the digits do not follow the script.** A locale's
numbering system is its own CLDR default, not an inference from its alphabet —
`ar`, `ur` and `hi` all default to `latn` (Western digits) despite writing in
Arabic and Devanagari script, while `ne` and `fa` do use native digits. (`ar_EG`
defaults to `arab`; plain `ar` does not, and plain `ar` is what ships.) Read
`number_symbols_data.dart` in the `intl` pub cache before claiming a locale's
digits; do not reason from the language.

You never render digits yourself. A number reaches a string only as an ICU
placeholder — with `"format": "decimalPattern"` in the template's `@` metadata —
and `intl` renders it in the reader's numbering system with the reader's
grouping. **Typing the digits into the sentence is always a bug**, even when
they look right: it freezes a constant that can change, and it hands `ne` and
`fa` readers the wrong script. `test/l10n/numeral_format_test.dart` and
`test/l10n/roster_bound_copy_accuracy_test.dart` both fail when it happens.

### What the plural gate actually checks

Rule 4 of `arb_parity_check.dart` checks **one** thing: that a message which *is*
a plural in your file supplies the CLDR categories **your own locale** requires.
It does **not** compare plural structure against English.

Two consequences, both previously stated wrongly here:

- **A locale-only plural block is a CHOICE, not a violation.** If English says it
  with one sentence and your language needs a plural to say it well, write the
  plural — you then owe your locale's full category set and nothing else. The
  reverse is equally allowed: `refreshRingSemanticChecking` ships as a plural in
  the template and in eleven locales, and as a plain sentence in `fa` and `ru`,
  and that passes.
- **Explicit `=1` / `=0` branches are fine.** They do not make gen-l10n warn —
  the template itself carries twenty of them and regenerates warning-free — and
  the parity tool counts `=1` as satisfying `one`, `=0` as `zero` and `=2` as
  `two`. `few` and `many` have no explicit form, so those must be keyword
  branches.

### Never let a placeholder govern inflection

The recurring defect in this codebase's numeric copy, and the one no gate can
catch for you: a runtime number placed where the following word must agree with
it. Russian noun case breaks at every value ending in 1 (`1 круг`, `2 круга`,
`5 кругов`); Arabic تمييز changes class with the number; the Japanese `つ`
counter has no form above nine. A plural block solves the *count* word, not a
noun three words later, and not a verb.

So restructure until the number modifies nothing — put it after a colon, make it
the object of a bounded phrase, or use a counter that does not inflect — and
**say in your review notes that you did**, because the next translator will
otherwise "fix" your unnatural-looking word order back into a broken one.

## Gender: keep the agreement off the reader

Haven does not know its reader's gender and must never guess one. Where a
language would inflect a verb, participle or adjective to agree with the person
being addressed, restructure instead of picking a default: an infinitive, a
verbal noun, a passive, or the plural/formal address most of these locales
already use for the reader.

Recorded honestly, because the next translator will meet it: **the shipped copy
already gets this wrong in older strings.** The `hi`, `ur` and `ar` reviewers in
the roster-bound wave each independently found masculine defaults addressing the
reader in existing keys — `locationDisclosureManage`, `leaveCircleDialogBody`
and `circleBlockedBannerBody` among them. New or edited copy must not propagate
the pattern by matching its neighbours. Fixing the existing strings is a
separate task, and **nobody has taken it** — so do not read their phrasing as
precedent, and do not silently repair them as a side effect of another change
either: that hides a real l10n defect inside an unrelated diff.

## The reviewer checks the reasoning, not just the string

The reviewer agent's job is not only "is this string right". In the
roster-bound wave, **eleven of twelve reviews found a defect in the
justification behind a string that was itself correct.** A right answer reached
by a wrong rule is a landmine: the rule gets reused, and the next string it
touches is wrong.

The shapes it took, all real:

- **Invented grammar.** "`Solo` is adverbial, so it cannot agree" — Spanish
  `solo` also exists as an agreeing adjective; the string happened to be safe
  by pragmatics, not by the stated rule.
- **Mis-cited precedent.** A collocation defended as house style, whose cited
  key turned out to be a bare button word; a form claimed as "reused from"
  keys that do not contain it.
- **Counts off by a factor of two**, offered as evidence.
- **An invented register distinction.** A claimed French rule that `Veuillez`
  marks a second, higher politeness register than English "Please". It does
  not: `Veuillez` and `Please` occupy **the same eighteen keys**, one for one.

So: **a citation must be checked, not remembered.** If a review or a
translation note cites a key, open the key. If it cites a count, count. If it
cites a grammatical rule, state the rule in a form that could be falsified —
and then try to falsify it. A justification that cannot be checked is not a
justification, and a reviewer who only diffs the output has reviewed half the
work.

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
5. Add the locale's vocabulary to each per-locale copy-accuracy guard in
   `test/l10n/` (`repair_copy_accuracy_test.dart`,
   `roster_bound_copy_accuracy_test.dart`, …). Each one asserts up front that
   every supported locale has an entry, so a new language reds them
   deliberately: a locale scanned against nothing would pass silently and the
   gate would report coverage it does not have.
6. `flutter test` green; `arb_parity_check.dart` green.
