# The privacy-invariant manifest — contract

`docs/privacy/privacy_invariants.json` is the join table between **what Haven
tells the user**, **the code that makes it true**, and **the test or guard that
fails when it stops being true**. `scripts/ci/check_privacy_invariants.sh`
enforces it in the toolchain-free `repo-guards` job.

This document is the authoritative description of the contract. The schema is
the file; this is the argument for it.

## Why it exists

Workstream F audited every user-facing privacy claim in the app and corrected
the ones that had gone false. It also recorded why that was not enough:

> nothing stops a NEW claim from being written tomorrow with no invariant behind
> it.

Before this manifest, `haven/test/pages/settings/privacy_page_test.dart`
rendered the privacy copy and asserted that the strings *appeared* — never that
they were *true*. All 86 `privacy*` keys could drift from behaviour with fully
green CI. Separately, six times during the CI audit, code was found that looked
complete, passed review, and executed nowhere — `check_no_tile_cache_secrets.sh`
was written, passing, and wired into no workflow for months.

The manifest closes both: a claim with no proof fails, and a cited guard that is
no longer wired fails.

## The three claim kinds, and why the split carries the weight

* **`assertion_arb_keys`** — the string PROMISES something checkable. A test or
  guard must exist that fails when the promise breaks. This is enforced: an
  assertion whose invariant cites neither a test nor a guard is a hard failure.
* **`disclosure_arb_keys`** — the string WARNS the user about something Haven
  does, or cannot prevent. Deleting it hides a real cost. Disclosures are
  **non-removable**: the ratchet rejects a diff that drops one.
* **`attributed_arb_keys`** — the string reports a THIRD PARTY's claim that
  Haven cannot enforce, and must never be collapsed into an unattributed
  assertion. Exactly one ARB key is attributed: the VPN paragraph. The other
  attributed claim is not an ARB string at all — the Stadia Maps policy sentence
  inside the Play consent dialog is a `non_arb_claims` entry with
  `kind: "attributed"`, which is why the label exists on both sides of the ARB
  boundary. Each of the two invariants carrying one also carries an
  `attribution` block with a provenance date, because an attributed claim's
  truth is "they said this, on this date", and that is what must be
  re-checkable.

**The load-bearing rule is E3's:** an invariant whose `status` is
`accepted_deviation` MUST carry zero assertion keys and at least one disclosure.
You may not promise what you have accepted deviating from, and you may not
record a deviation the user was never told about.

Thirteen deviations are declared, each mirroring a section of
`haven-core/SECURITY.md`: P1–P7 (profile-plane relay separation), M5
(self-update disabled), RC1 (relay-session correlation), R10 (the owner-directed
public-profile reversal), and the ones added after review found them
unregistered — `IOS-KEYCHAIN`, `CONV-BUFFER`, `TTL-FINGERPRINT` and
`LEAVE-GHOST`. No count is written down: this list grows every time somebody
reads `SECURITY.md` against the manifest, which is the point of it.
`jq -r '.accepted_deviations[].id' docs/privacy/privacy_invariants.json` is the
answer that cannot go stale.

**Several of them carry no invariant, and that is a finding, not an omission.**
An `accepted_deviation` invariant requires a disclosure, so a deviation the user
is never told about cannot be filed as one without inventing a disclosure —
which is the failure mode this workstream exists to prevent. Each of these costs
the user something and none of them is disclosed anywhere:

* `P4` — a Haven save can drop kind-0 fields another client set on non-pool
  relays.
* `IOS-KEYCHAIN` — a still-powered-on iPhone unlocked once since boot can have
  the OS surrender the SQLCipher key *while locked*.
* `TTL-FINGERPRINT` — the constant 228 s kind-445 expiration is, in its own
  record's words, "a client-wide discriminator visible to any relay or member",
  and cannot be changed for circles that already exist.
* `CONV-BUFFER` — a circle member can grow the engine's convergence buffer
  without a bound Haven can impose.
* `LEAVE-GHOST` — **the sharpest of them, because the copy asserts the opposite
  of the residual.** In the conjunction of a leaver crashing mid-leave, its
  `SelfRemove` being deferred or losing the order race, and it never re-opening
  the app, no removal commit is ever produced and a stale roster ghost stays
  authorized until an admin removes it by hand — with no admin-visible signal
  that one is owed. `privacyEncryptionWhenSomeoneLeaves` states the bounded form
  ("usually within a few minutes, longer for anyone who was offline at the
  time"). It carries no invariant here because filing one would require a
  disclosure that does not exist; it sits under `INV-E-REMOVAL-ADVANCES-EPOCH`,
  which is `ratcheted` for exactly this reason. **Open owner decision.**

Recover the current set with:

```
jq -r '(.accepted_deviations | map(.id))
       - ([.invariants[] | select(.status=="accepted_deviation") | .accepted_deviation_id] | unique)
       | .[]' docs/privacy/privacy_invariants.json
```

`P4`, `IOS-KEYCHAIN` and `LEAVE-GHOST` are open owner decisions, listed under
"Known gaps" below; the rest are recorded as accepted in `SECURITY.md`, where
the acceptance is argued. Note that the gate cannot detect an *unregistered*
deviation: rule 9 checks only that cited ids resolve. Keeping this register
complete is a human duty.

**A key may appear under more than one invariant, and usually must.** Roughly
two dozen strings promise and warn in the same paragraph — several
`@description`s say verbatim *"Do not merge the sentences back together"*. A
one-label-per-key design would silently drop the disclosure half of the most
important ones. `privacyRelaysDetailProfileLookups` is the extreme case: one
assertion (the at-most-two-relays bound) and three disclosures (P1's birthday
collisions, P2's publish fan-out, P5's durable per-relay record), because its own
`@description` names all three deviations by id. The only forbidden overlap is a
key appearing in both a claim list and `non_claim_arb_keys`.

Four strings are **platform-asymmetric** — one Android invariant and one iOS
invariant in a single sentence (`privacyWhatOthersSeeScreenshots`,
`privacyWhatOthersSeeCannotPause`, `locationSettingsIntro`, and the iOS
Always-location prompt). Three of them carry a note that a prior flattened
version was false in the dangerous direction. Each platform gets its own
invariant.

## Claims live outside the ARB, and those are the ones that matter most

Workstream F's sharpest finding was that a claim register scoped to the
localization files cannot see the claims a user is most likely to believe.
`non_arb_claims[]` carries sixteen such strings — thirteen stating a fact, three
classified `kind: "none"` — and they are not one screen but four: the four iOS
`Info.plist` usage descriptions, the nine `LocationDisclosureStrings` fields of
the Play consent dialog, the Android foreground-service notification's channel
description and body, and one relay-storage error string. **The iOS permission
prompt and the Play consent dialog are the two screens where the user is
actively deciding whether to trust the app**, and neither is localized. Rule 12
enumerates those two carriers — and only those two — so a new usage description
or a new consent sentence cannot land unclassified. The remaining carriers are
classified but not enumerated; see "What the gate cannot prove".

`non_arb_claims[].kind` also admits `"none"`, with a mandatory reason, for the
three genuinely claim-free fields (`title`, `agree`, `notNow`). `"none"` never
satisfies a disclosure requirement and never counts toward the ratchet —
otherwise it would be a laundering route for exactly what E3 forbids.

## `non_claim_arb_keys`, and the strings that are correct by omission

Every `privacy*` key must be classified: claimed by an invariant, or listed here
with a reason. The map shape makes the reason mandatory.

Three entries carry `forbidden_additions` — strings that are honest only because
of what they do **not** say, each with an `@description` naming the exact
forbidden clause. `relaySettingsKeyPackageSubtitle` must stay silent about the
public profile; `locationSettingsToggleSubtitle` must never say "when the app is
closed"; `avatarPickerPhotoRemoved` must never read as a deletion promise, which
it is not (no Blossom DELETE exists). The gate asserts the ARB value does not
contain a forbidden addition.

## The ratchet, and what CI genuinely cannot do

Checked against a baseline the caller names. `repo-guards.yml` passes
`--baseline-ref`: on a pull request the base-branch commit the change is built
on (`pull_request.base.sha`), and on a push the branch's PREVIOUS tip
(`github.event.before`) — so a push ratchets against what that same branch was a
moment earlier, which on a direct push to `main` is the one path with no branch
protection in front of it. Where the event carries no base commit at all — a tag
build, the first push of a new branch, a manual run — every rule still runs and
**the ratchet is skipped entirely**, announced rather than silent.

Invoked with **no** flags the script falls back to `origin/main` — the live tip
of the default branch, which is right for a local check and wrong for anything
built on a commit that is not main's tip, since every invariant added to main
since then reads as `.deleted`. Two callers, two behaviours, and it is worth
knowing which is which: `repo-guards.yml` always names the ref; the weekly
`privacy-manifest-author.yml` deliberately does not, and validates its proposal
against that `origin/main` default, which is correct there only because its
branch is cut from that same tip seconds earlier.

A **weakening** is a deleted invariant, a status
moving down `enforced` > `ratcheted` > `accepted_deviation`, a dropped
disclosure, or an assertion losing its last proof. Each weakening fails unless
its exact item id is listed in `ratchet_override`, whose reason must be
substantive — and, symmetrically, an override naming something that is *not*
actually weakened also fails, so stale allowances cannot accumulate.

**Be clear about what this buys.** CI cannot judge whether a downgrade is
*justified*. It can only force it to be named in the diff, where review sees it.
That is a visibility mechanism, not a correctness one, and the script says so.

## What the gate cannot prove

Stated plainly, because a guard that overclaims is worse than one that does not
exist:

* **Event-kind enumeration is necessary but not sufficient.** Kinds 445, 1059
  and the 444 rumor are built out-of-tree in the rev-pinned
  `transport-nostr-peeler`; kinds 0 and 5 carry no kind token or number at all
  (`EventBuilder::metadata`, `EventBuilder::delete`); three sites compute the
  kind at runtime, one of which signs. So the gate keys on construction-shaped
  **tokens** rather than numbers, and pins `pinned_dependencies.mdk_rev` against
  `haven-core/Cargo.toml` — that pin is the only mechanism that can force a
  re-derivation when an MDK bump introduces a kind. The authoritative
  closed-world check remains the send-side wire journal
  (`tooling/e2e/ci/check-wire-journal.sh` + `tooling/e2e/wire_allowlist.json`),
  which observes what actually left the device.
* **"Cited test is not tautological" is only partly decidable.** The gate proves
  a cited test exists, is not `#[ignore]`d / `skip:`ped / declared in
  `expected_test_skips.txt` / `markTestSkipped` (that last one matters: the
  integration surface is outside the skip guard entirely, because
  `integrationDriver()` records success for a body that skipped), and contains
  at least one assertion. It cannot tell you the assertion is *strong*.
* **A guard cited as proof must be wired as an ENFORCING run.** Several guards
  appear in `repo-guards.yml` only as `--self-test`: some because their real run
  needs a toolchain that job deliberately does not have (it reads `cargo test` /
  `flutter test` output, or an lcov report), and two — the advisory review's
  finding-anchor verifier and the manifest author's diff bound — because their
  subject is another workflow's behaviour, so they enforce nowhere at all. A
  self-test proves the guard's fixtures pass and says nothing about the
  repository, so a citation satisfied only by a self-test fails unless the
  manifest names the enforcing workflow with the `#workflow=` suffix — and one
  with no enforcing run anywhere is not proof of anything and must not be cited.
  No count is written here: it was "four" for as long as it took to add two more.
* **"You cannot silently delete a privacy warning" is key-level, and English
  only.** `enumerate_weakenings` compares the manifest's key LISTS; it never
  reads an ARB value, and every rule that reads one reads `app_en.arb` alone.
  Gut a disclosure sentence down to an empty promise while keeping its key and
  nothing here fails — not in English, and not in any of the other twelve
  languages, which the gate does not open. What the ratchet holds is that the
  KEY cannot vanish; that the string behind it still warns is a review duty.
* **Rule 12's carrier enumeration is narrower than the manifest's own
  content.** It enumerates exactly two non-ARB carriers — the iOS
  `NS*UsageDescription` keys and the `LocationDisclosureStrings` fields — while
  the manifest already classifies three claims from files nothing enumerates:
  `background_location_manager.dart`'s `channelDescription` and
  `notificationText` (the Android foreground-service notification, which is what
  a user sees the whole time background sharing is on) and
  `nostr_relay_preferences_service.dart`'s `_mapStorageError`. A new claim added
  in any of those lands unclassified with this gate green.
* **Rule 12's ARB sweep is opt-in by naming convention, and that is the widest
  hole in the completeness half.** The sweep greps `^privacy`, which is 86 of the
  ARB's 535 keys, while 47 of the 133 keys the manifest classifies do not start
  with `privacy` — `onboardingValueProp*`, `onboardingCreateIdentityWarning`,
  `mapLocationSharingStopped*`, `locationSettingsIos*`, `clockSkewBody*`,
  `qrCodeExplainer*`, `identityAdvancedDeleteBody` and the rest. Those 47 are
  classified because somebody chose to classify them; nothing forces the next
  one. Concretely: add `onboardingWeNeverSeeYourLocation` = *"We never see your
  location. Ever."* and every rule stays green, because it is outside the
  prefix the sweep looks at. Onboarding is where a user forms their threat
  model, so the unswept third is not the harmless third. Rule 12's coverage is
  bidirectional and genuinely strong **within** `^privacy`; outside it, adding a
  claim to the manifest is a human act.
* **The release gate never ratchets.** `release-build.yml` calls this same
  `repo-guards` job, but it runs on tags and `workflow_dispatch`, neither of
  which carries a `pull_request.base.sha` or a non-zero `event.before` — so the
  step takes the `--no-ratchet` branch. Rules 1-14 still run. What a release
  build cannot detect is a *weakening*: a status downgraded, an invariant
  deleted or a disclosure key dropped between the last PR and the tag passes the
  release gate in silence. The ratchet is a pull-request mechanism, and only a
  pull-request mechanism.
* **The pre-commit hook does not run this gate.** `scripts/ci/run_source_guards.sh`
  derives its list from `repo-guards.yml` by matching argument-less
  `bash scripts/ci/check_*.sh` steps, and this gate's invocation always carries a
  flag (`--baseline-ref` / `--no-ratchet`), so it is excluded along with the
  `--self-test`-only steps. That is deliberate — the ratchet needs a baseline
  fetch, which is not a pre-commit-shaped operation — but it means the headline
  gate is first evaluated in CI. Run `scripts/ci/check_privacy_invariants.sh`
  by hand after touching privacy copy or the manifest.
* **The weekly Manifest Author's pull request gets no CI.** It is opened with
  `GITHUB_TOKEN`, and GitHub deliberately does not trigger `on: pull_request`
  workflows for such a PR — so nothing in `ci.yml` runs on it. The
  in-workflow `check_privacy_invariants.sh` call inside
  `privacy-manifest-author.yml` is the only gate that proposal ever faces, and
  it inherits every limitation on this list. Treat the draft PR as unverified by
  CI, not as CI-approved; a human marking it ready for review is what puts it in
  front of the real pipeline.
* **A claim can be laundered out of coverage without moving any number.**
  `enumerate_weakenings` enumerates deleted invariants, status downgrades,
  dropped *disclosures* and assertions that lost their last proof — it does
  **not** enumerate a dropped `assertion_arb_keys` entry. So moving a key out of
  an invariant and into `non_claim_arb_keys` with a plausible reason passes
  every rule, ratchets silently, and does not move rule 12's ARB count, because
  `non_claim` keys count toward it too. The README closes this route for
  `non_arb_claims` `kind:"none"` (which never satisfies a disclosure and never
  counts toward the ratchet) and leaves the ARB-side twin open.
  **`non_claim_arb_keys` is the escape hatch, and every entry in it is a review
  decision that CI records but does not check.**

## Adding an invariant

1. Write `statement` in checkable terms — what code change would falsify it, not
   a restatement of the copy.
2. Classify every claim key as assertion, disclosure or attributed. If the
   paragraph does two things, list it under both invariants.
3. Cite `symbols`, `tests` and `guards` that you have **verified exist**. Grep
   before you cite. A manifest full of dead citations is worse than no manifest.
4. Set `status` honestly. `enforced` only where a cited test or guard actually
   fails when the claim breaks. If the claim is true but unproven, use
   `ratcheted` with a `residual` saying exactly what is not held — never invent
   a test name to make an entry look complete.
5. Run `scripts/ci/check_privacy_invariants.sh`.

## Known gaps and owner decisions

Recorded here rather than papered over:

* **P4 is declared with no invariant.** No user-facing string discloses that a
  Haven profile save can drop kind-0 fields another Nostr client set on relays
  outside the pool. Filing an invariant would require inventing a disclosure
  that does not exist. Owner decision: disclose it, or record P4 as a
  data-fidelity deviation outside this manifest's scope.
* **`IOS-KEYCHAIN` is declared with no invariant, and it is the one with a
  security consequence.** The iOS SQLCipher keys use
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, which is what permits
  locked-device background location sharing. The owner-approved cost, stated in
  `SECURITY.md` and nowhere the user can see it: a still-powered-on device that
  has been unlocked at least once since boot can have the OS surrender the DB
  key *while locked*. Only a device powered off and not yet unlocked keeps it
  sealed. Owner decision: disclose, or record that this is out of the privacy
  copy's scope.
* **`LEAVE-GHOST` is declared with no invariant, and the copy currently asserts
  the bounded form its record forbids.** `privacyEncryptionWhenSomeoneLeaves`
  tells the user a departing member stops being able to read anything new "once
  the rest of the circle has caught up, usually within a few minutes, longer for
  anyone who was offline at the time". The deviation's `forbidden_claim` is
  exactly that: copy must not state that leaving always re-keys the circle
  within a bounded time, because the corroboration gate deliberately keeps no
  admin-side record of a departing member's intent, so the crashed-leaver case
  needs a manual admin removal that nothing signals is owed. This is the one
  entry on this page where a registered deviation and a shipped sentence
  contradict each other; it is held as `ratcheted` under
  `INV-E-REMOVAL-ADVANCES-EPOCH` rather than filed as an accepted deviation,
  because filing it would require inventing a disclosure. Owner decision: add
  the residual to the copy (a 13-locale round), or re-scope the sentence to the
  converged case.
* **`INV-W-445-EXPIRATION-SCOPE` holds only for circles this device created.**
  The 0x8005 retention component is supplied at exactly one site
  (`CreateGroupRequest`), with no read-back, no validation on `accept_welcome`,
  and no `UpdateAppComponents` path that adds it to a group lacking it. In a
  circle created by a client that did not declare it, this device's own
  application 445s carry no expiration — and then both halves of
  `privacyWhatOthersSeeDetailExpiry` invert.
* **`privacyWhatOthersSeeDetailExpiry` under-describes the un-stamped class.**
  It says a 445 without an expiration "is visibly a membership change". The
  un-stamped class is every group-control message: membership, circle rename,
  admin handoff, relay-set changes, retention changes. Not false, but narrower
  than reality. Correcting it is a 13-locale round, so it is recorded rather
  than done.
* **`onboardingValueProp2Title` / `…Body` overclaim.** "No one can shut it down"
  / "No single company or government can switch the network off" is backable on
  the location plane and false app-wide: the map has exactly one provider by CI
  enforcement, the eight profile relays cannot be removed by the user
  (`usable_profile_relays()` re-unions the pool), and the Blossom host is a
  single hardcoded server. The app's own privacy copy
  (`privacyRelaysDetailIndexers`, `privacyPublicProfileDetailKindZero`)
  contradicts the onboarding claim, and onboarding is where a user forms their
  threat model. Recorded as `ratcheted` with the three exceptions named. Owner
  decision: scope the copy to the location plane, or withdraw the claim.
* **`relay_settings_page.dart` shows raw English error text** from
  `_mapStorageError` while the add-relay sheet localizes the same three errors
  correctly. A UI defect, not a copy defect.
