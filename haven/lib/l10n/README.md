# Localization (l10n)

Haven uses Flutter's official **gen-l10n + ARB** pipeline. It adds no third-party
packages: `flutter_localizations` ships in the SDK and `intl` is already a
dependency. Config lives in `../../l10n.yaml`.

## Layout

```
lib/l10n/
  app_en.arb              ← English template / source of truth (edit this)
  app_<locale>.arb        ← translations (es/fr/de/ar — added in M3)
  app_localizations*.dart ← GENERATED (committed); never hand-edit
```

## Adding or changing a string

1. Add the key to `app_en.arb` with an `@key` metadata block (a `description` is
   **required** — `required-resource-attributes: true`). Conventions:
   - camelCase, screen/widget-prefixed (`settingsTitle`, `circlesEmptyTitle`,
     `memberMarkerMinutesAgoSemantics`); shared generics use `common*`.
   - Interpolation/plurals use ICU, e.g.
     `"{count, plural, =1{1 member} other{{count} members}}"` with an `int`
     placeholder. Provide a `placeholders` map for every `{name}`.
   - Brand/protocol/format strings that must stay English (Haven, Nostr,
     `nsec1…`, `kind 10050`) are tagged **"intentionally English"** in their
     description — the parity gate then won't flag them as untranslated.
2. Use it via `AppLocalizations.of(context).<key>` (non-null —
   `nullable-getter: false`). Capture `final l10n = AppLocalizations.of(context)`
   at the top of `build`, and **before any `await`** in async handlers. For a
   helper without a `BuildContext`, thread `AppLocalizations` in as a parameter.
3. Run `flutter gen-l10n` and commit the regenerated sources.
4. In widget tests, pump via `test/helpers/localized_app_harness.dart`
   (`pumpLocalized`), or add `AppLocalizations.localizationsDelegates` +
   `supportedLocales` to a custom `MaterialApp`.

## Consistency gate

`scripts/ci/check_l10n_parity.sh` (CI: `.github/workflows/l10n-check.yml`)
regenerates, fails on any untranslated message or generated-source drift, and
runs `scripts/ci/arb_parity_check.dart` (cross-locale key/placeholder/empty/
CLDR-plural-category parity + untranslated-copy detection). A separate advisory
AI review (`l10n-ai-review.yml`) semantically QAs changed translations on PRs.
`scripts/ci/check_locale_privacy.sh` keeps the chosen locale a local-only
preference (it must never reach a relay).

## Pseudo-locale (overflow / un-extracted-string check)

```sh
# from haven/
dart ../scripts/ci/gen_pseudo_arb.dart lib/l10n/app_en.arb lib/l10n/app_en_XA.arb
flutter gen-l10n
# run the app, switch the language to the accented "English" entry, eyeball
# screens for clipping and any un-accented (still-hardcoded) text, then:
rm lib/l10n/app_en_XA.arb && flutter gen-l10n
```

`app_en_XA.arb` is gitignored — it is a local-only aid and must never ship.

## Known deferred item

`lib/src/widgets/identity/avatar.dart`'s composed semantics label
(`"User avatar"` / `"online"` / `"offline"`) is **not yet localized** — it was
held back because that file carries unrelated in-progress work. Localize it
(thread `AppLocalizations` into `_buildSemanticLabel` and add delegates to
`haven_avatar_test.dart` / `haven_avatar_image_test.dart`) once that work lands.
