# DRAFT PLAN — Consolidated Privacy page (Haven)

Owner request: (1) remove the informational section in Relay settings; (2) remove "Who can see what"
from About so About retains only the highlight/value-prop cards plus everything from "Open Source
Licenses" down; (3) create a new **Privacy** page in Settings directly **above** About, holding all
the consolidated material: Nostr, public/private keys, your profile, what relays are, how Marmot
brings MLS to Nostr, what different parties learn about you, VPN, etc.
Hard constraint: **every detail about how Haven works must be available, while the page stays
accessible to a non-technical audience.**

---

## PART 1 — Removal / re-parenting inventory (verified against the working tree)

### 1a. Removed outright from their current home

| Site | Lines | What goes | Keys |
|---|---|---|---|
| `haven/lib/src/pages/settings/about_page.dart` | call site **68**, widgets **218-348** | `_WhoCanSeeWhat` + `_Actor` + that file's 2nd `_open` helper | `aboutWhoCanSeeTitle`, `aboutWhoCanSeeIntro`, `aboutActor{Circles,Relays,Map,Developers}{Who,Sees}`, `aboutWhoCanSeeMetadataNote`, `aboutScreenshot{Title,Body}`, `aboutVpn{Title,Body,LinkLabel}` (14) |
| `haven/lib/src/pages/settings/relay_settings_page.dart` | call site **100**, widget **461-571**, doc comment **1-7** | `_BackendExplainerNote` | `relaySettingsExplainer{Semantics,Heading,Nostr,Marmot,Metadata,Footer}` + 4 `Term`/`Body` pairs (15) |

After the About cut, About = `_HeroSection` → 3 `_buildInfoRow` value props → `_LegalLinks`
(licenses / report-map-issue / support-OSM / attribution) → `_Footer`. Exactly the owner's spec.
`aboutLinkOpenError` stays (still used by `_LegalLinks`).

### 1b. Shortened in place + given a "Learn more" link (NOT removed)

- Relay settings: replace the 450-word note with **2 sentences + `Learn more`** → Privacy ▸ Relays.
  Rationale: the page is a *control* surface; some framing must remain or the "Inbox"/"KeyPackage"
  headers are bare. Owner said remove the *informational section* — this keeps a caption, not a section.
- `qr_code_page.dart:91-122` (`qrCodeWhatIsThisTitle`, `qrCodeExplainerKeys`, `qrCodeExplainerUsername`)
  — in-context help on a page the user opened *to understand their key*. Keep, add `Learn more` →
  Privacy ▸ Your two keys. **Its test asserts `find.textContaining('Nostr')` findsOneWidget**, so do
  not add a second "Nostr" mention to that page.
- `PublicProfileNotice` (identity page + onboarding) — compliance-grade standing disclosure, keep;
  add `Learn more` → Privacy ▸ Your name and photo are public.
- `location_settings_page.dart:149-156` intro — keep, add `Learn more` → Privacy ▸ What members see.

### 1c. Explicitly NOT touched

- `location_disclosure_dialog.dart` `LocationDisclosureStrings` — hardcoded English **on purpose**
  (Google Play Prominent Disclosure & Consent gate, must stay aligned with iOS `Info.plist`).
- `nameCircleSharingInfo`, `addMemberInfo`, `circleDetailsRelaysNote`, `mapOpenInAppleMapsBody`,
  `legacyCutoverExplainerDialog`, `identityAdvancedSecretKeyWarning` — all in-context, all
  test-guarded, all correct.
- `intro_screen.dart` — has a **no-scroll layout budget test at 390×844**; cannot grow.

### 1d. Incidental correctness fixes in scope

- `relaySettingsKeyPackageSubtitle` says **"kind 10051"**; Dark Matter moved KeyPackage relay
  discovery to **kind 10002** (NIP-65). Same staleness in `relay_settings_page.dart:3-4`.
- `about_page.dart:146-148` `_LegalLinks` doc comment claims it renders a privacy-policy action.
  It does not; no privacy-policy link exists anywhere.
- `'https://mullvad.net'` is hardcoded inline at `about_page.dart:274` → move to `constants/tiles.dart`.
- `kHavenWebsiteUrl` / `kHavenContactEmail` are still `haven.example` placeholders
  (`constants/tiles.dart:24-27`). **Owner decision needed** before release.

---

## PART 2 — Five factual errors + one omission in the current copy

These must be fixed, not carried over. All also exist in 12 translated ARB files.
(Item 4 was reclassified from "error" to "omission" by the confirmation round: the Android body copy
is true and correctly scoped; only the iOS case is missing. So the body needs no retranslation —
only a new iOS string. Corrected error count: **5 errors + 1 omission**.)

1. **`aboutActorCirclesSees`** — "your exact location **and the display name you pick**, but only
   inside the circles you share with them." The display name is **no longer circle-scoped**; it is a
   public kind-0 readable by anyone. Survived the public-profile migration unedited.
2. **`aboutActorRelaysSees`** — (i) "the public key you publish under (**a random ID, not your
   name**)" is true only of kind 445; kinds 0 / 30443 / 10002 / 10050 / 5 are authored by the
   **stable identity pubkey**, which (since onboarding always publishes) is bound to a name + photo.
   (ii) "never … who is in your circles" is too absolute — same-socket `#p`↔`#h` correlation,
   ephemeral-author counting for group size, and the `p`-tagged invitation gift wrap all leak.
3. **`aboutActorMapSees`** — "only the area you are viewing" omits the anticipatory prefetch
   (`tile_prefetch_policy.dart:29,52`, `prefetch_scope.dart:25-42`, `map_page.dart:731-760` passes
   **all** locations, not on-screen ones): a 3×3 ring + coarse parent centred on **circle members'
   positions**, capped 32 tiles. Also "Stadia anonymizes IP addresses and does not sell your data" is
   a third-party policy claim, not a code fact → attribute + link `kStadiaPrivacyUrl`, or drop.
   **CORRECTED by confirmation round:** the granularity is NOT ~1.5–2.5 km. `prefetch_scope.dart:55-60`
   uses `max(currentZoom, 14)` clamped to `maxNativeZoom`, so the landing zoom is the *user's current
   zoom* whenever zoomed in — at z18 a tile is **~150 m**. The original figure quoted the coarsest
   case as if it were the bound, understating the leak by an order of magnitude. Never let ~1.5–2.5 km
   reach user copy.
4. **`aboutScreenshotBody`** — Android-only framing. Android sets `FLAG_SECURE` app-wide
   (`MainActivity.kt:10-19`); iOS only blurs the app-switcher snapshot
   (`AppDelegate.swift:6-11`, `:110-124`) and **cannot block in-app screenshots or recording**.
   Put the iOS position in the title.
5. **`onboardingValueProp3Body`** — "nothing linking it to the real you" is overstated (IP is visible
   to every relay/host; the same pubkey carries a renameable public profile). Narrow to key custody.
6. **`qrCodeExplainerUsername`** — says name/photo "stay on this device unless you choose to publish
   a public profile", contradicting the unconditional public-by-default policy.

Correct as-is, do not soften: `aboutActorDevelopersSees`, `aboutVpnBody`, `aboutWhoCanSeeMetadataNote`.

### Facts the new copy must get right (and that are easy to get wrong)

- **Foreground sharing cannot be paused in-app.** The only toggle is *background* sharing. While
  Haven is open and you are in circles, exact GPS publishes to **all** of them every 72–168 s.
- **Keys rotate only on membership change, never on a timer**
  (`enablePeriodicSelfUpdate = false`). "Keys rotate regularly" would be false.
- **Removed member cutoff is not instant** — up to ~168 s with live-sync (the default); the
  documented poll-fallback worst case is ~228 s. Say "within a few minutes at most."
- **A new member cannot see past locations** (no history transfer + MLS epoch keys). Confident.
- **Exact GPS always** — obfuscation tiers were removed. No approximate mode to mention.
- Deliberately *not* sent: device ID, accuracy, altitude, speed, heading (`types.rs:79-98`).
- **Local location retention: 1 day**, hard-coded (`purge_after = timestamp + 86400`).
- **kind-445 TTL 228 s** (`ttl.rs:80`); commits/proposals deliberately un-stamped.
- **Invitation gift wraps (1059) have no expiry** and carry the invitee's real pubkey in a `p` tag.
- **Six public discovery indexers are contacted unconditionally** (`discovery.rs:45-52`), even by a
  user who configured only private relays — all profile reads go there. Currently undisclosed anywhere.
- **Live-sync is on by default** → continuous online-presence signal to relays.
- **The stable `h` tag** links every message of one circle forever. Protocol constraint, no fix.
- **Every circle member learns your npub**; a co-member can rebroadcast your kind-450 proof.
- **`SharedPreferences` is NOT encrypted** (theme, locale, toggles, onboarding flags). A blanket
  "everything on your device is encrypted" claim would be false.
- **On logout/delete:** DB files deleted **and keyring keys removed**, tile cache wiped. Strong claim,
  safe to make. Does *not* remove anything already published.
- **MLS wire format is PURE_PLAINTEXT** — the outer ChaCha20-Poly1305 layer is the *sole* MLS-level
  confidentiality layer on the wire. Never imply two independent layers protect content from a relay.
- Do NOT copy from `MARMOT_PROTOCOL_KNOWLEDGE.md:371-377` or `SECURITY.md:505-516` — both stale, both
  still claim kind-445 carries no expiration.
- Do NOT conflate the 228 s **TTL** with `SECURITY.md:296`'s coincidentally-equal 228 s **PCS window**.

---

## PART 3 — Structure: layered hub + topic subpages

Rejected: one long scrolling page (~4-5k words, 30+ viewports at 200% scale, no findability, no
deep-link target, hundreds of linear TalkBack swipes). Rejected as *primary*: a page of
`ExpansionTile`s (the app has **zero** existing usages; Flutter's `ExpansionTile` does not expose
expanded/collapsed state to TalkBack/VoiceOver without hand-wired `Semantics`; at 200% scale the
collapsed titles wrap to 2-3 lines each so the scannable-TOC benefit evaporates).

**Chosen: hub of tiles → topic subpages (the app's own Identity→{QR,Advanced} idiom), executed as
three content tiers.**

- **Tier 1 — the hub, zero taps.** Top third is always-visible: a 4-sentence plain-language summary
  (`bodyLarge`), then the who-can-see-what actor list condensed to one line per actor, each row
  tappable into its topic. This is the 30-second answer, free.
- **Tier 2 — each subpage, ~150-250 words.** Plain answer first, then a fixed-position, fixed-label
  "What this means for you" block.
- **Tier 3 — one collapsed "In more detail" region per subpage.** Protocol depth lives here (MLS,
  kind numbers, exporter secrets, MIP refs). Built **once** as a shared widget, so the
  `ExpansionTile` a11y cost is paid once in one tested place rather than 12 times.

This is what satisfies "every detail available" without any of it landing on a lay reader.

### Topics — 8, merged down from the reviewer's 12 to cut the l10n tail

Group "The basics": 1 What Haven is, and why there's no account · 2 Your two keys: one secret, one to
share · 3 Your name and photo are public
Group "How your location travels": 4 Relays: the servers that pass messages along · 5 How the
encryption works · 6 What your circle members see — and what relay operators see
Group "The limits": 7 What can still be figured out about you (metadata + traffic analysis + IP + VPN)
Group "This phone": 8 Your phone (screenshots Android vs iOS + device loss + where data is stored +
what is and isn't encrypted + logout wipe)

Trade-off to flag: merging pushes topics 7 and 8 to ~400 words, above the 250-word target. The
12-topic split keeps every page short but costs ~50% more keys.

### Files

- `lib/src/pages/settings/privacy_page.dart` — hub. Plain `StatelessWidget`, no Riverpod, no async
  state → fully widget-testable on the Linux host (unlike `IdentityPage`).
- `lib/src/pages/settings/privacy_topic_page.dart` — ONE renderer taking `enum PrivacyTopic`, with
  `static Route<void> route(PrivacyTopic)`.
- `lib/src/pages/settings/privacy_content.dart` — `switch (PrivacyTopic)` → `List<PrivacyBlock>`;
  `PrivacyBlock` a small sealed class: `Heading` / `Para` / `MeansForYou` / `Note(tone)` /
  `MoreDetail(children)` / `RelatedTopic(topic)`.

The content model's payoff is enforcement, not brevity: heading semantics, heading levels, spacing,
contrast and RTL padding are applied once in the renderer, so it is structurally impossible to ship a
section title without `Semantics(header: true)`. It also makes the one `switch` the complete string
manifest, and gives the pseudo-locale + 200%-scale sweeps a single widget to exercise.

### Settings entry

`_SettingsTile(icon: LucideIcons.shieldCheck, title: privacyTitle, subtitle: privacySubtitle)`
inserted directly above the About tile at `settings_page.dart:103`. Give it a subtitle — About has
none, and a bare "Privacy" row reads as a legal dumping ground.

---

## PART 4 — Widget extraction / reuse (so it cannot look bolted on)

| Extract | From | To |
|---|---|---|
| `_SettingsTile` | `settings_page.dart:135` | `widgets/common/settings_tile.dart` — share with the hub, else the rows visually drift |
| `_SectionHeader` | `appearance_settings_page.dart:97` | `widgets/common/section_header.dart` + optional `headingLevel` |
| `_Actor` | `about_page.dart:304` | `widgets/common/actor_row.dart` — **fix the RTL bullet during extraction** (it renders a literal `'•  '` with trailing spaces) |
| `_open` link helper | duplicated twice inside `about_page.dart` | shared helper; reuse `aboutLinkOpenError` |
| `HavenInfoNote({icon,title,body,tone})` | NEW — unifies 3 drifting explainer boxes | `PublicProfileNotice` + `qr_code_page.dart:93` use `surfaceContainerLow`/radius `sm`; `relay_settings_page.dart:488` uses `surfaceContainerHighest`/radius 12. Standardise on the former; keep `PublicProfileNotice` as a thin wrapper so its reviewed copy and 2 call sites don't move |

Reuse `cardTheme` (do not hand-roll `BoxDecoration` borders), `HavenSpacing` (base/lg/md/sm exactly
as other settings pages), `DisclosureChevron` on **every** tile (Lucide chevrons do not auto-flip —
a hand-rolled `chevronRight` is a bug in ar/fa/ur), `directional_arrow.dart` for inline next-topic
affordances. Add `WidgetKeys` entries in `lib/src/test_keys.dart` for the hub and each topic route so
E2E navigates without depending on localized text.

Deliberately not reused: `HavenEmptyState`, `HavenSkeletonList`, `RefreshRingButton`, any provider.

---

## PART 5 — Readability + accessibility

- Reading level: US grade 8-9 for tiers 1-2; tier 3 may run to 11-12. Median sentence ≤20 words,
  hard cap ~30. Paragraph ≤3 sentences / ~45 words.
- Terminology: **plain phrase first, real term in parentheses once** ("servers called relays"), so it
  stays searchable. Once **per subpage** (deep-linked readers may never see another page), never
  "relays (servers that…)" — the reader hits the unknown word before the handhold. **Never introduce
  a term you don't reuse.** Tier-2 vocabulary is capped at: Nostr, relay, end-to-end encrypted,
  metadata, public key, secret key, forward secrecy, MLS. Everything else is tier 3.
- Define **"metadata"** at first use — the single most misunderstood word on the page.
- "What this means for you": structural (fixed label, fixed position, `Semantics(header: true)`), not
  a bold inline sentence. Must be actionable or reassuring, never a restatement. When there is
  nothing to do, say so rather than manufacturing an action.
- **No tables.** 4×3 at 360dp/200% is unreadable, horizontal scroll fails WCAG 1.4.10 reflow, and
  Flutter `Table`/`DataTable` expose no row/column header association. Use the `_Actor` hanging-bullet
  pattern; where a comparison must punch, use per-actor "Can see" / "Cannot see" lists with an icon
  **plus the literal words** (never colour/icon alone — WCAG 1.4.1).
- Banned: "military-grade", "100% private", "unhackable", "we never collect any data".
- **Honest negatives:** grouped into "The limits" (candour reads better than scattered hedging);
  neutral `surfaceContainerLow` + `LucideIcons.info` styling, NOT error styling; always bound and
  quantify the limit in the same breath; put the negative **in the title** when action is required
  ("On iPhone, Haven cannot block screenshots").

### Contrast finding (computed, needs an owner decision)

Against light `surface` #FFFFFF: `onSurfaceVariant` #525252 = **7.8:1** (passes body);
`HavenSecurityColors.encrypted` #16A34A = **3.3:1** (icons/large only, fails 4.5:1 body);
`HavenSecurityColors.warning` #D97706 = **2.5:1** — **fails even the 3:1 non-text threshold, WCAG
1.4.11**. Both pass in dark theme (7.9:1 / 6.0:1). Consequences: **zero coloured body text** on this
page; amber only as an icon on its own tinted container (the `warning.withValues(alpha: 0.1)`
treatment at `identity_advanced_page.dart:322` is fine because the text on it stays `onSurface`).
`#B45309` measures 5.0:1 and would pass for both. **Pre-existing bug, out of scope but worth
reporting:** amber icons directly on light surface at `location_settings_page.dart:183` and
`identity_advanced_page.dart:291` are below 3:1 today.

- `bodySmall` is 12sp and is what all existing explainer notes use. A reading page must not be:
  `bodyMedium` (14sp) floor for prose, `bodyLarge` (16sp) for the tier-1 summary.
- Heading semantics on every group header and section title, with explicit `headingLevel`
  (1 = subpage title region, 2 = section, 3 = "What this means for you"). Highest-value a11y
  investment here — it is what makes the TalkBack Headings control and the VoiceOver rotor work.
- **Do not over-merge `Semantics` — correction to current app habit.** `PublicProfileNotice`,
  `_ValuePropCard` and `about_page._buildInfoRow` all use `Semantics(label: '$title. $body',
  container: true, excludeSemantics: true)`. Correct for a 2-line card, **wrong for a 200-word
  section**: one enormous unnavigable node, no single-sentence re-read, breaks text selection. Rule:
  merge only under ~2 short sentences; leave body prose as individual `Text` nodes.
- Tier-3 expansion: `Semantics(expanded:)` + hint + `SemanticsService.announce` on toggle; do not
  auto-scroll the header off screen; honour `MediaQuery.disableAnimations` → `Duration.zero`;
  ≥48dp target at all scales.
- 200% scale: **no `maxLines`/`ellipsis` on anything explanatory** (do NOT copy
  `location_settings_page.dart:223`, which ellipsises a heading); `CrossAxisAlignment.start` on every
  icon+text row; `Wrap` not `Row` for link/chip pairs; no fixed-height containers. Test 1.0/1.5/2.0
  at 320dp. Never clamp scale via `MediaQuery` — WCAG 1.4.4 requires 200%.
- RTL: `EdgeInsetsDirectional`/`AlignmentDirectional` throughout; wrap LTR tokens
  (`npub1…`, `wss://…`, `MLS`, `FLAG_SECURE`) in `Directionality(textDirection: ltr)` or bidi
  isolates, and preferably keep raw tokens out of tiers 1-2 entirely.
- Front-load each tile title with its distinguishing word (WCAG 2.4.6): "Relays: the servers that
  pass messages along", not "How Haven's message transport works". No custom in-page anchor bar.

---

## PART 6 — l10n

- Namespace `privacy` + topic + **semantic** role: `privacyRelaysWhatIsARelay`, `privacyRelaysWhyMany`,
  `privacyRelaysMeansForYou`. **Never ordinal** (`…Body2`): insert a paragraph mid-page and all 12
  translation files silently attach to the wrong paragraph while the parity gate stays green.
- **One key per paragraph** (2-4 sentences, ≤60 words). Per-page keys produce unreviewable 400-word
  JSON values with embedded `\n\n` that would have to be split at runtime — which also destroys the
  per-paragraph `Text` nodes the a11y rules require. Per-sentence keys strip the context translators
  need to reorder clauses.
- Spend the mandatory `@description`s on **register and audience**, not restatement — e.g. "Audience:
  non-technical, no Nostr knowledge. Sentences under 20 words. 'relay' is a Nostr term of art — keep
  it recognizable; do not translate to a generic word for 'server'."
- **Add `lib/l10n/GLOSSARY.md`** and reference it from the descriptions. Terminology drift is the
  biggest l10n risk here: without a decision table, `relay` will render three different ways inside
  the same page in the same locale.
- "Intentionally English" tags for Nostr, Marmot, MLS, Haven, Stadia Maps, OpenStreetMap, Mullvad,
  `npub1…`, `nsec1…`, `FLAG_SECURE`, SQLCipher, kind numbers — **but only when the entire value is a
  proper noun**; a sentence merely *containing* "Nostr" is still translatable and exempting it would
  suppress a genuine `arb_parity_check.dart` warning.

### Translation traps to avoid (all present in code today)

1. **Split bold-lead-in spans.** The `_BackendExplainerNote` `…Term` + `…Body` `Text.rich`
   concatenation hard-codes English word order and forces the body to begin with a leading space
   (`" are your mailbox: …"`) — invisible in JSON, silently trimmed by translation tools, and broken
   outright where the term must inflect (German case, Japanese は, Arabic construct state).
   **Use heading + body key pairs instead**, which also buys screen-reader heading navigation.
2. **Substring-emphasis hacks** — `intro_screen.dart:128` does `full.indexOf(word)` to bold a word.
   Degrades silently when a translator inflects it. Do not extend to this page.
3. **Widget-owned punctuation** — `_Actor` builds `'$who: $sees'`; ja/zh want fullwidth `：`. Move the
   separator to `commonLabelValueSeparator`.
4. Plurals: this page needs none. Keep it that way (`arb_parity_check.dart` hard-fails Arabic without
   all six CLDR categories).
5. Expansion: de/ru/fa run 20-35% longer; combined with 200% scale that is the real overflow risk.

### Volume and staging

8 topics × ~10 keys + hub ≈ **90-100 new keys × 13 locales ≈ 1,200 translated values.**
(12 topics would be ~150 keys ≈ 1,900.) **Land in 4 PRs, one per group**, each independently
parity-green and independently AI-reviewable — one PR this size cannot be genuinely reviewed, and
CLAUDE.md mandates a real per-language reviewer pass.

**Re-parent, don't rewrite, wherever the claim is correct.** Rendering existing keys under their
current names reuses already-translated, already-reviewed strings across 13 locales for free.

**CORRECTED by confirmation round — the re-parent list was the plan's single most dangerous line.**
Three of the proposed strings must NOT be re-parented:
- **`relaySettingsExplainerMarmot` — DO NOT REUSE.** It asserts *"Those keys keep advancing over time,
  a property called forward secrecy, so even a key exposed later cannot unlock your earlier
  messages."* `haven-core/SECURITY.md:405-415` documents the opposite as an **accepted project cost**:
  leaf key material is re-keyed only by a real membership change, so a leaked current-epoch leaf
  secret lets an attacker derive **every future epoch** until membership churn, and the 5-epoch
  exporter prune does not bound it. This directly contradicts Part 2's own fact list — the original
  draft self-contradicted between the fact list and the reuse list. Also, its
  *"separate circles cannot be linked together"* is a key-separation fact dressed up as an
  unlinkability claim (same pubkey, same IP, same sockets, same indexer `REQ`).
  **The word "forward secrecy" must not appear on this page** without the membership-churn caveat.
- **`relaySettingsExplainerMetadata` — DO NOT REUSE** (same "never … your identity / who is in your
  circles" defect as error #2).
- **`aboutVpnBody` — DO NOT REUSE as-is.** It enumerates only "relays and the map provider" as
  IP-visible parties, omitting `blossom.primal.net` and the six indexers. Correct today only because
  it is vague; false the moment it sits on a page claiming completeness.

Net reuse ≈ **8-10 keys**, not 25.

---

## PART 7 — Tests

| Test | Change |
|---|---|
| `test/pages/settings/about_page_test.dart:21` | Drop the `find.text('Who can see what')` assertion; **add a negative assertion** that it is gone, so the removal can't silently regress |
| `test/pages/settings/relay_settings_page_test.dart:106-127` | Rewrite `'shows the backend explainer note'` → asserts the short caption + the `Learn more` affordance; keep a negative assert for the removed 450-word body |
| `test/pages/settings/settings_page_test.dart` | Assert the Privacy tile exists **and sits directly above About** (index order, not just presence) |
| NEW `test/pages/settings/privacy_page_test.dart` | Hub renders; all 8 tiles present; each tile pushes its topic route; tier-1 summary + actor rows visible without scrolling at 100% scale |
| NEW `test/pages/settings/privacy_topic_page_test.dart` | Parameterised over all 8 `PrivacyTopic` values: renders, has ≥1 `Semantics(header: true)`, has a "What this means for you" block, tier-3 region collapsed by default and expandable, expansion announces state |
| `test/l10n/locale_smoke_test.dart` | **Add the hub + all topic pages to the 13-locale × 1.5× loop** — this is the only overflow/RTL guard in the repo, and this page is the most prose-heavy surface in the app |
| NEW a11y test | 320dp × text scale 1.0/1.5/2.0, assert no overflow for every topic |
| `test/pages/settings/qr_code_page_test.dart` | Only if the QR explainer is touched — its `find.textContaining('Nostr')` is `findsOneWidget` |

No golden/screenshot tests exist anywhere in the repo — nothing to regenerate.
Pseudo-locale sweep (`scripts/ci/gen_pseudo_arb.dart`, per `lib/l10n/README.md`) at 200% scale before
merge — cheapest catch for both clipping and un-extracted hardcoded strings on a page this text-heavy.

---

## PART 8 — Sequencing

1. **Extraction PR (no user-visible change):** `settings_tile.dart`, `section_header.dart`,
   `actor_row.dart` (+RTL bullet fix), `HavenInfoNote`, shared `_open`, Mullvad URL → constants.
   Existing tests must stay green untouched.
2. **Scaffold PR:** `PrivacyTopic` enum, `privacy_content.dart` model, hub + topic renderer, Settings
   tile above About, `WidgetKeys`, tier-3 expansion widget + its a11y test. English copy only for
   group 1; the other groups render placeholder-free but shortened.
3. **Content PRs ×4 (one per group):** copy drafted at tier 2, tier 3 drafted by **marmot-expert** and
   verified by **security-reviewer** before any of it enters an ARB file — once a false claim is
   translated into 13 languages, correcting it costs 13 reviews. Each PR: 12 translations + the
   mandated independent per-language reviewer pass + `arb_parity_check.dart` + `flutter gen-l10n`.
4. **Removal PR:** delete `_WhoCanSeeWhat` and `_BackendExplainerNote`, shorten the relay caption, wire
   all `Learn more` deep links, update the 3 affected tests, fix the kind-10051 staleness. Last, so
   the app is never in a state where the information exists nowhere.
5. **Fact-fix PR:** the 6 Part-2 corrections in en + 12 locales.

Steps 4 and 5 could merge into step 3's last PR if the owner prefers fewer PRs.

---

---

## PART 9 — CONFIRMATION-ROUND CORRECTIONS (verified independently, then re-verified by me)

### 9a. NEW CONTENT that the plan omitted entirely — all must be disclosed

1. **Blossom was missing from the plan completely.** Topic 3 must cover: the photo is uploaded to a
   third party, `https://blossom.primal.net` (`profile/config.rs:47`), which receives your IP and a
   kind-24242 event **signed by your identity key** (`blossom.rs:5-8`) — a durable pubkey↔IP↔image
   binding. The blob then sits at a **public, unauthenticated, content-addressed URL**.
   **Removing your profile photo does NOT delete it.** I verified this myself: there is **no Blossom
   `DELETE` anywhere in `haven-core`** (`grep -rn "DELETE|\.delete(" haven-core/src/profile/` → no
   hits; the only `DELETE /<sha256>` in the tree is the e2e fixture at
   `tooling/e2e/local-blossom/src/main.rs:193`). The image stays fetchable indefinitely. An earlier
   research pass claimed retraction "issues a Blossom DELETE" — that claim is **false**.
   Positive counterweight worth stating: EXIF/GPS is stripped before upload (`blossom.rs:5`).
2. **Co-member IP harvesting via profile pictures — undisclosed anywhere in the app.**
   `blossom.rs:18-19` names it in Haven's own words: a member's kind-0 `picture` URL is
   *"fully attacker-controlled, so a naive download is an SSRF + automatic co-member IP-harvesting
   primitive."* Every shipped defense addresses SSRF against **internal** targets; **none** stops a
   public host the co-member controls from logging your IP. The download is automatic and ungated
   (`rust_builder/src/api.rs:4705-4721`). So **any circle co-member can learn your IP address with no
   action by you.** This refutes `aboutActorCirclesSees` far more severely than the display-name bug,
   and belongs in topic 6.
3. **The removed-member window is an epoch, not minutes.** The draft's "removed members lose access
   within a few minutes at most" is true of *live traffic* and **materially misleading about archived
   traffic**: a removed member keeps that epoch's key and can decrypt anything they archived from the
   entire epoch they were in — potentially weeks in a stable circle. Since keys rotate only on
   membership change, **all location messages within one epoch share one key.** Must be stated.
4. **Following the app's own relay advice publicly advertises your private relay.**
   `nostr_relay_preferences_service.dart:265-267` maps `RelayCategory.keyPackage → RelayTypeFfi.nip65`,
   so the "KeyPackage relays" list is published as a **kind-10002 signed by your identity key** — yet
   `relaySettingsExplainerReachabilityBody` recommends using "the same private relay listed as
   everyone's inbox and KeyPackage relay." Undisclosed in both the current copy and the draft.

### 9b. CORRECTED claims

- **Logout/wipe was overstated — "strong claim, safe to make" is REFUTED.** Two ways:
  (i) it is best-effort and documented as fallible — `identity_provider.dart:319-334`: *"A wipe
  failure leaves a DECRYPTABLE circles.db/haven_mdk.db at rest (both the file AND its key survive)"*
  (retried next launch, but false at the moment logout returns). Copy must say "removes … and retries
  if it cannot", not assert deletion.
  (ii) **a plaintext residue survives unconditionally** — I verified: `nostr_identity_service.dart:284`
  writes `haven.display_name.<pubkeyHex>` to `SharedPreferences`, and `deleteIdentity()` (`:244-269`)
  deletes the secure-storage key and wipes the tile cache but **never removes that preference**. The
  plaintext display name *and the pubkey hex* survive "delete identity". **This is a real bug worth
  filing separately from this page.**
- **Contrast — my figure was wrong; corrected and triple-checked.** I recomputed the WCAG formula
  myself: `warning #D97706` on white = **3.19:1** (not 2.5:1) — it **passes** the 3:1 non-text
  threshold, so *"fails WCAG 1.4.11"* is **REFUTED**, and so is the claim that the amber icons at
  `location_settings_page.dart:183` / `identity_advanced_page.dart:291` are violations today.
  `encrypted #16A34A` = 3.30:1; `onSurfaceVariant #525252` = 7.81:1; `#B45309` = 5.02:1; dark theme
  warning 6.21:1 / encrypted 6.01:1. The surviving conclusion is narrower but still holds: **no
  coloured body text on this page** (3.19 fails the 4.5:1 body threshold).
  **The one real violation the draft missed:** `identity_advanced_page.dart:312` sets
  `foregroundColor: HavenSecurityColors.warning` on an `OutlinedButton` **label** — amber body text at
  3.19:1, failing WCAG 1.4.3. Pre-existing, out of scope, worth filing.
- **`SharedPreferences` "not encrypted"** needs a qualifier or it over-alarms: say *"app-private, not
  encrypted"* — `AndroidManifest.xml:48` sets `allowBackup="false"`, so it is not in cloud backups.
- **kind-445 TTL framing.** NIP-40 `expiration` is **advisory**; a relay MAY ignore it. "Your location
  is deleted from relays after ~4 minutes" would be an unenforceable claim about third-party software.
  Say Haven *asks* relays to drop it.
- **The six indexers are not read-only.** `config.rs:140-146` + `publish.rs:174-185` make the discovery
  plane the **write fallback** for kind-0/24242 when no NIP-65 write relays resolve — contradicting
  `discovery.rs:20-21`'s own "never a publish target" comment. In practice most users publish a 10002
  so the fallback rarely fires, but do not assert a property the code does not guarantee.
- **A third stale doc to distrust:** `SECURITY.md:237` ("Forward Secrecy: Provided by MLS epoch
  rotation") is contradicted by `:405-415` in the same file.
- **`ExpansionTile` rationale was overstated.** The pinned Flutter 3.41.0 stock widget *does* wire
  state-change announcements and expanded/collapsed hints (`expansion_tile.dart:537-643`). What it
  genuinely lacks is the formal `Semantics(expanded:)` flag. The conclusion (custom tier-3 widget)
  still stands, on the narrower premise. `Semantics(expanded:)` is already used in-repo at
  `circle_selector.dart:382`, and a sealed-class precedent exists at
  `background_location_manager.dart:19` — the content model is confirmed idiomatic, not novel.
- **`_buildInfoRow` is a *different* bug, not the over-merge pattern.** `about_page.dart:98-100` sets
  `label` + `container: true` but **no `excludeSemantics: true`** (unlike `PublicProfileNotice:47-49`
  and `_ValuePropCard:164-166`), so children may be **double-announced**. Fix during extraction.
- **`_Actor`'s RTL bullet** auto-mirrors correctly already (the `Row` has no explicit `textDirection`).
  The real defect is the font-dependent literal-space gap, not directional placement.

### 9c. Execution traps the draft missed

1. **`library;` deletion trap.** Part 1a lists `relay_settings_page.dart` "doc comment 1-7" for
   removal — **line 7 is the `library;` directive itself.** Rewrite the doc comment in place *above*
   the retained directive; do not delete the block.
2. **NEVER run `dart format <dir>`** on the touched directories — match in-file style by hand. The
   draft never mentioned this despite touching 6+ files; it is a previously-hit footgun in this repo.
3. **Locale-smoke-test scale-out is unbudgeted.** Adding a hub + 8 topic pages to the 13-locale sweep
   takes that file from ~31 cases to 100+, with real CI time. Budget it or sample locales.
   Good news: no navigation needed — `PrivacyTopicPage(topic:)` can be pumped directly as `home:`,
   exactly like the existing `IntroScreen` pattern.
4. **Pick a barrel convention** for the three new `widgets/common/*.dart` files: the repo has two
   competing ones (`widgets.dart` barrel vs. `DisclosureChevron`'s direct-import-only).
5. Two more kind-10051 staleness sites the draft missed: `services/relay_preferences_service.dart:21`
   and `:27`.
6. **`LocationDisclosureStrings` should NOT simply be frozen.** Its compliance status is confirmed
   (removing About's section and the relay explainer deletes no compliance-required disclosure — the
   dialog is the sole Prominent Disclosure gate, and Play/Apple privacy labels are console-side). BUT
   `location_disclosure_dialog.dart:30-33` claims location is visible *"never Haven, and never any
   other entity"* — inaccurate given co-member IP harvesting (9a.2) and the Stadia member-centred
   prefetch. An inaccurate absolute **inside a compliance disclosure** is worse than an edited one.
   Escalate to the owner rather than declaring out of scope.
7. **The missing privacy policy is a release blocker, not a placeholder decision.** No privacy-policy
   link exists anywhere, yet `about_page.dart:146-148`, `location_disclosure_dialog.dart:17-18` and
   `constants/tiles.dart:17-20` all reference one, and `kHavenWebsiteUrl`/`kHavenContactEmail` are
   `haven.example`. Play and the App Store both require an accessible privacy policy for a location
   app. The new Privacy page is its natural home.

### 9d. Confirmed sound, no change needed

Structure (hub + subpages + 3 tiers), the content-model choice, all Part 1 line ranges and the
removal's compile-safety (`url_launcher` and `LucideIcons` both still needed by `_LegalLinks`;
`HavenSecurityColors` was never imported in `about_page.dart`; the `Spacer`-pinned footer survives
losing a child), every widget-extraction source location, all four cited test assertions,
`bodySmall`=12sp / `bodyMedium`=14sp / `bodyLarge`=16sp, the `location_settings_page.dart:223`
ellipsised-heading citation, the l10n key-granularity and translation-trap analysis, and the
sequencing that lands removals *after* content.

---

## OWNER DECISION — 2026-07-28: "Your phone" topic DROPPED

Group 4 (topic 8, "Your phone": screenshots + device loss + on-device storage) is
**removed from the plan** at the owner's direction. The section is 7 topics, not 8.

Consequence handled: `aboutScreenshotTitle`/`aboutScreenshotBody` lived inside the
`_WhoCanSeeWhat` block that PR 6 deletes, and were the app's ONLY mention of screenshot
protection. Rather than lose the disclosure — and with it the Android/iOS asymmetry, which
was one of the six identified copy errors — it survives as a single warning note inside the
existing "What members see" topic (`privacyWhatOthersSeeScreenshots`). That topic's takeaway
already ends "Against a member who saves a screenshot, nothing does", so it is the natural
home. It is one note, not a section.

Dropped with the topic, and NOT disclosed anywhere in the app as a result:
device loss / seizure (incl. the iOS `AfterFirstUnlockThisDeviceOnly` tradeoff), the three
SQLCipher databases and OS-keyring key storage, that `SharedPreferences` is app-private but
NOT encrypted, and that logout/delete is best-effort with a `haven.display_name.<pubkeyHex>`
plaintext residue. If any of that should be user-visible, it needs a new home.

## OWNER DECISIONS — LOCKED 2026-07-27

1. **Topic granularity: 8 merged topics.** ~1,200 translated values. Accepted trade-off: topics 7 and
   8 run ~400 words, above the 250-word target. Mitigate by leaning on tier-3 collapse inside those
   two pages so the always-visible tier-2 body stays near target.
2. **Relay page: 2-sentence caption + "Learn more."** (Recommended, accepted.)
3. **QR page explainer: keep** as in-context help + "Learn more". Do not add a second "Nostr" mention.
4. **Fact fixes: SAME change set.** Write the new page against corrected facts and fix the stale
   strings in the same PRs — do not translate known-false copy into 13 languages and re-translate later.
   This covers the 5 errors + 1 omission (Part 2) AND the 3 undisclosed leaks (Part 9a: no Blossom
   deletion, co-member IP harvesting, private-relay advertising via kind-10002).
5. **Side fixes IN SCOPE (all three approved):**
   - `haven.display_name.<pubkeyHex>` surviving `deleteIdentity()` in plaintext `SharedPreferences`
     (`nostr_identity_service.dart:244-269` vs `:284`). Fix + regression test.
   - `identity_advanced_page.dart:312` amber `foregroundColor` on an `OutlinedButton` **label**
     (3.19:1, fails WCAG 1.4.3's 4.5:1). Fix to `#B45309` (5.02:1) at this call site.
   - kind 10051 → 10002 staleness: `relaySettingsKeyPackageSubtitle` (+12 locales),
     `relay_settings_page.dart:3-4`, `services/relay_preferences_service.dart:21` and `:27`.
   - NOT approved as an app-wide token change: leave `HavenSecurityColors.warning` alone (it passes
     the 3:1 non-text bar); avoid amber body text on the new page instead.
6. **STILL BLOCKED ON OWNER (release blockers, not plan blockers):**
   - No privacy policy exists. `kHavenWebsiteUrl`/`kHavenContactEmail` are `haven.example`
     (`constants/tiles.dart:24,27`); three code sites reference a policy that does not exist. Play and
     the App Store both require one for a location app.
   - `location_disclosure_dialog.dart:30-33` claims location is seen "never by any other entity" —
     inaccurate given co-member IP harvesting + the Stadia member-centred prefetch. An inaccurate
     absolute inside the Prominent Disclosure gate needs an owner/legal call before editing.
