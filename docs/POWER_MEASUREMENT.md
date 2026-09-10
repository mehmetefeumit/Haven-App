# Haven power measurement protocol

> ## ⏸ DEFERRED — 2026-08-30. Intact, unmodified, and still authoritative.
>
> **There is no macOS machine and no iPhone available for the duration of the
> power project** (owner constraint, recorded in `docs/POWER_EFFICIENCY_PLAN.md`
> §2.5) — **and no Android handset either**, which the owner's verbatim
> constraint does not mention but §2.5's "What IS lost" (a) does: the Android
> half needs "an Android phone the project also does not have on hand". So
> NEITHER half can run today. No run of this protocol has been performed, and
> none can be for now.
>
> **Nothing here has been weakened, shortened or removed** to accommodate that.
> A protocol written while the constants and the reasoning are fresh is exactly
> what a hardware campaign will need, and a version reconstructed from memory
> months later would omit the details that make it decisive. It is deferred, not
> retired: every step below stands as written, and every measurement it
> specifies is still owed.
>
> **The results tables in §9 stay EMPTY, on purpose.** An empty table is the
> honest record of a measurement nobody took. In the meantime the power plan
> uses an *estimation model* (`POWER_EFFICIENCY_PLAN.md` §6.5a) whose outputs
> are tagged ESTIMATED. **Never copy an estimate into this document.** This file
> records measurements only; an estimate written into a results row would be
> indistinguishable from a measurement the moment anyone reads it out of
> context, which is precisely the failure the tag exists to prevent.
>
> **The Android half is runnable EARLIER than the iOS half.** §1 (controls), §3
> (the relay-side liveness capture) and §5 (the Android run) need only an
> **Android phone plus `adb` on any laptop** — no macOS, no Xcode, no iPhone.
> The §0 "Laptop" row's macOS requirement applies to the iOS half alone (Energy
> Log import and the device console). So a single Android handset makes §1 + §3
> + §5 + the Android rows of §7 immediately executable, and one 60-minute
> stationary window would settle the model's three biggest unknowns at once —
> the GNSS draw, the battery capacity the %/h arithmetic assumes, and the
> application-processor term the model has no value for at all. It would also
> supply the forced-idle liveness row that currently keeps phase **P2b** parked.
> If an Android device appears, run the Android half; do not wait for the iPhone.

**Status:** ~~owner-run, on real hardware~~ → **DEFERRED (see the banner above);
owner-run, on real hardware, when hardware exists.** Created by packet P0-C of
`docs/POWER_EFFICIENCY_PLAN.md`; the protocol below is that plan's §6.5 and the
acceptance table is its §6.6 — note that §6.6 was rewritten on 2026-08-30 to
separate estimate-replaced power rows from the hard liveness clause, so read
this document's §7 together with the amended §6.6 rather than instead of it.

**What this produces.** One table row per run, in §9. Every later phase of the
power work is judged against the rows recorded under `## Baseline` here, so the
runs have to be repeatable by a second person on the same two phones months
apart. This document is written to be executable on its own: it assumes no
context beyond a laptop, two phones and a checkout of this repository.

**The one rule.** Every number here can be "improved" by doing less, and the
cheapest possible Haven publishes nothing at all. So a battery figure is never
accepted on its own — every run also carries relay-side proof that location
updates never stopped (§3). A power win that reopens the sharing-stops-after-
hours wedge is a regression, not a win. If a row fails, the row is the finding.
Never soften this protocol to make one pass.

**Tooling policy.** OS tooling only — Xcode Instruments, `adb`/`dumpsys`,
Battery Historian, iOS Settings. No analytics or telemetry SDK is ever added to
Haven for measurement (`INV-R-NO-TELEMETRY-SDK`, enforced by
`scripts/ci/check_privacy_invariants.sh`).

---

## 0. What you need

| | |
|---|---|
| Phones | One iPhone and one Android phone, both yours, **the same two every run**. Record model + OS build in every row. |
| App | A **release** build of the same commit on both phones, produced by `scripts/build_release.sh apk` / `scripts/build_release.sh ios`. Never a bare `flutter build --release` (it fails the release gate and ships without the map key), and never a debug build — debug builds enable code paths release builds compile out. |
| Laptop | macOS with Xcode (for the iOS Energy Log import and the device console) and `adb` (Android platform-tools). **The macOS/Xcode half is needed for the iOS run (§4) ONLY** — §1, §3 and the whole Android run (§5) work from any laptop with `adb`, which is why the Android half is runnable earlier (see the banner at the top). |
| CLI | `jq` (`brew install jq`), `nak` (`go install github.com/fiatjaf/nak@latest`), and — for capture option A — `docker` and `caddy`. |
| Repo | This checkout, for `tooling/e2e/ci/summarize-created-at-gaps.sh` and `tooling/e2e/ci/start-strfry.sh`. |

Before the first grading run, prove the grader itself works:

```bash
bash tooling/e2e/ci/summarize-created-at-gaps.sh --self-test
```

It must print `40 fixtures passed`. A tool you have not verified is not
evidence.

### The constants this protocol is built on

Every threshold below comes from a constant in the tree. Re-check them before a
campaign; if one moved, this document is stale, not the phone.

| Constant | Value | Where |
|---|---|---|
| `kLocationUpdateInterval` | 120 s (nominal publish cadence) | `haven/lib/src/constants/location.dart` |
| `kLocationPublishMinInterval` | 72 s (jitter floor) | same file |
| `kLocationPublishMaxInterval` | 168 s (jitter ceiling) | same file |
| `kTtlNetworkBufferSeconds` | 30 s | same file |
| `LOCATION_MESSAGE_RETENTION_SECS` | 228 s = 168 + 2 × 30 | `haven-core/src/location/ttl.rs` |
| `kMemberAgePillThreshold` | 5 min | `haven/lib/src/widgets/map/member_marker.dart` |

228 s is the promise: the relay must always hold a non-expired location event
from every active publisher, so a consecutive publish gap above 228 s is a
window in which peers had no position at all. **The promise has one accepted
departure, and it is not a second promise:** on Android API 23–30 the foreground
service's realized gap reaches 248 s once, so a 20 s window with no position is
a residual on record (`POWER_EFFICIENCY_PLAN.md` D3 (iii)) rather than a
finding. §3.5 says how to grade that, and every gap bound in this document is
read per API level for exactly this reason.

**Why iOS keeps 228 s here while `haven/lib/src/constants/location.dart` derives
238 s for it** (reconciled 2026-09-09 — the two are not in conflict, but nothing
said so). That 238 s is `168 + 40 + spread`: the interval ceiling, the iOS burst
head (connect + backlog wait + one-shot fix, which varies between bursts and so
enters the realized gap as a differential), and the burst spread a circle can
move across. The spread is what makes it cross — 226 s at three circles, 235 s
at four, 238 s from five up — and **control 3 of §1 fixes this campaign at
exactly ONE circle**, where there is no spread at all and the derived worst is
`168 + 40 = 208 s`. So 228 s is the right bound for every row in this document
and is NOT evidence that iOS is inside the retention at every roster. Two iOS
terms are additionally outside any bound: a due maintenance fold and the Rule-13
teardown drain push the NEXT burst late, and `burstBound` excludes both because
neither is boundable — so an iOS gap above 228 s on a one-circle campaign is
still a finding, but the finding may be one of those rather than the head.

---

## 1. Controls — identical every run, and recorded every run

Each of these changes the result, so each is fixed and each gets written down.

1. **Same two phones.** Record model and OS build for both. A different handset
   is a different campaign, not another row.
2. **Same commit, release build, both phones.** Record the commit hash.
3. **Circle: exactly one, with exactly two members** — the iPhone and the
   Android phone. Peer count is therefore 1. Use the *same* circle for every
   run in a campaign; do not add members mid-campaign.
4. **Background sharing ON** on the device under test; the peer is running
   Haven normally and publishing. Both facts matter: the peer's publishes are
   the device under test's inbound radio load.
   **The peer's own state is a control too, and is fixed and recorded:** screen
   off, Haven backgrounded (not foregrounded, not force-quit), sharing ON,
   and plugged in — the peer's battery is not being measured, and a peer that
   sleeps, throttles or dies partway changes the inbound load and the capture
   under it. Two runs with different peer states are not comparable.
5. **Screen off** for the whole window. Do not wake the device to "check".
6. **Low Power Mode (iOS) / Battery Saver (Android) OFF.**
7. **Network state fixed per run and recorded.** Run the stationary scenario
   **twice**: once cellular-only (Wi-Fi off) and once on Wi-Fi. Radio cost is
   per wake and differs between the two; a campaign measured on Wi-Fi twice has
   measured one thing twice.
8. **No other location app running** on the device under test.
9. **Unplugged for the whole window.** Android `batterystats` only accrues
   on-battery, and a charging phone reports no discharge at all.
10. **Start state of charge 80–90 %**, recorded, and the end % recorded too.
    iOS %/h drifts with state of charge, so rows that started at different
    charge levels are not comparable.
11. **iOS authorization tier recorded**: Always (confirmed), Always
    (provisional), or When-In-Use. Settings → Privacy & Security → Location
    Services → Haven.
12. **Android fused backend recorded**: `adb shell dumpsys location | grep -i fused`.
13. **Relay set recorded** (§3). During a measurement campaign the circle sits
    on the capture relay(s), not on Haven's three default relays
    (`relay.damus.io`, `relay.primal.net`, `nos.lol`). Record the count in the
    *relays (count)* column: publish cost scales with it, and baseline and
    acceptance rows must use the same count or the comparison is void. An
    Option-A campaign runs on ONE relay, so its absolute figures describe a
    one-relay configuration and are **not** the shipped 3-relay default's
    numbers. That is fine — every threshold in §7 is a comparison between rows
    of the same configuration — but a figure quoted out of this document
    without its relay count is wrong.
14. **Both phones on automatic network time**, and the offset recorded. Every
    number in §3 is a `created_at` the *device* stamped, so a phone whose clock
    drifts moves its own gaps. Settings → General → Date & Time → *Set
    Automatically* (iOS) and Settings → System → Date & time → *Set time
    automatically* (Android). At T0 and again at the end, record each phone's
    clock against the laptop's:

    ```bash
    date -u; adb shell date -u          # laptop, then the Android phone
    ```

    For the iPhone read Settings → General → Date & Time against the laptop
    clock. Write both offsets into the *notes* cell. A drift of more than a few
    seconds inside one window makes that run's gaps unreliable: re-run it.

---

## 2. Scenarios

**S — stationary.** Phone on a desk, app sent to the background with the Home
gesture (not force-quit).

* **iOS: ≥ 3 h.** Settings › Battery reports whole percent, so a 60 min window
  cannot resolve a ≤ 1 %/h target — it can only say "0 % or 1 %". Three hours
  gives at least three counts. If a single 3 h block is impractical, run
  **3 × 60 min** under identical controls and sum them into one row, noting in
  the notes column that it was summed. A relative threshold whose baseline is
  under 4 % across the window is not resolvable either — extend the window.
* **Android: 60 min.** `batterystats` reports per-uid seconds, not percent, so
  an hour resolves it.

**W — walking, 30 min.** A normal walk with the phone in a pocket, screen off,
both platforms. GPS-grade power is expected here by design; W exists to catch a
change that breaks *moving* behaviour, and to hold the relative thresholds.

Run S then W in one unplugged sitting where the battery allows; otherwise
recharge to the same 80–90 % start band between them and record two rows.

---

## 3. The relay-side liveness capture — MANDATORY

### 3.1 Why it is not optional, and why it cannot be the phone

No run is accepted without it. The evidence cannot come from:

* **The app under test.** A wedged publisher is usually still convinced it is
  publishing; the defendant does not get to testify.
* **The receiving phone's screen.** The Android peer's foreground-service fetch
  runs once per `kLocationUpdateInterval` (120 s) and the marker age pill only
  thresholds at 5 min, so a perfectly healthy run routinely *reads* as
  168 + 120 s stale. The pill is a UI affordance, not an instrument.

It comes from the relay: the sequence of `created_at` values the phone actually
landed there.

### 3.2 Choose a capture relay

Haven **release** builds accept `wss://` only — the plaintext `ws://` loopback
opt-in is compiled out of release binaries (`haven-core/src/relay/manager.rs`,
`validate_single_relay_url`). So a capture relay must be reachable over TLS with
a certificate the phones already trust. Two options:

**Option A — your own hermetic relay (recommended).** Only your traffic reaches
it, nobody else's ciphertext is recorded, and the capture is complete.

```bash
# On a host with a DNS name you control, from this checkout:
bash tooling/e2e/ci/start-strfry.sh          # strfry on 127.0.0.1:7777
caddy reverse-proxy --from relay.example.org --to 127.0.0.1:7777
```

Then, on **both** phones, **before creating the measurement circle**:
Settings → Relays → *My Inbox Relays* and *My KeyPackage Relays* → remove the
existing entries and add `wss://relay.example.org`. Now create a fresh circle
from the device under test and invite the peer.

Verify it took: open the circle → details → **"Relays for this circle"**. It
must list only `wss://relay.example.org`. This matters because a circle's relay
set is fixed **at creation** from the relay lists the invited members had
published; changing your relay list afterwards does not move an existing
circle. If the list is wrong, delete the circle and create it again.

**Option B — capture from Haven's own relays.** No infrastructure needed, at the
cost of one extra step and a privacy caveat: a bare kind-445 subscription on a
public relay records other Nostr users' ciphertext as well as yours. Narrow it
to your own circle with a server-side `#h` filter, which needs the circle's
public `nostrGroupId`:

1. **Discovery pass.** Start `nak req -k 445 --stream <relays> > discover.ndjson`,
   then create the measurement circle. Run the grader on `discover.ndjson`
   without `--series` and without `--from`/`--until`:

   ```bash
   bash tooling/e2e/ci/summarize-created-at-gaps.sh --publishers 2 discover.ndjson
   ```

   It prints one `series` block per `h` value it saw; yours is the one whose
   observed window starts when you created the circle. Note the hex. **This
   pass exits non-zero (5, `UNGRADED`) by design** — it is a listing, not a
   graded run, and a grader that returned 0 for a run whose window was never
   declared is exactly the false green §3.5 refuses. Ignore the code here, and
   nowhere else.
2. **Delete `discover.ndjson`.** It holds strangers' events; it has served its
   purpose.
3. Capture the real windows with `--tag h=<hex>` (§3.4), so only your circle's
   events are ever written to disk.

Option A is still preferable: it needs no discovery pass, records nothing but
your own traffic, and its relay is under your control for the end-of-run export.

### 3.3 The capture file format

`summarize-created-at-gaps.sh` reads **NDJSON**: one JSON value per line, no
wrapping array. Each line is either

* a bare Nostr event object — what `nak req`, `strfry scan` and `strfry export`
  emit:

  ```json
  {"id":"<64-hex>","pubkey":"<64-hex>","created_at":1756540800,"kind":445,
   "tags":[["h","<32-hex>"],["expiration","1756541028"]],"content":"…","sig":"…"}
  ```

  (wrapped here for readability; on disk it is one line)

* or a relay message array whose first element is `"EVENT"` — what a raw
  WebSocket dump emits:

  ```json
  ["EVENT","<subscription-id>",{ …the same event object… }]
  ```

Both shapes may be mixed in one file, blank lines are ignored, and unknown
fields are ignored. The script sorts by `created_at` (relay exports are often
newest-first) and de-duplicates by event id, so a streaming capture and an
end-of-run export can simply be concatenated into the same file.

By default only **kind 445 carrying a NIP-40 `expiration` tag** is counted. That
tag is the location-message discriminator: kind 445 also carries MLS commits and
proposals, which carry no `expiration`, and which would otherwise land inside a
gap and hide a breach.

**One capture file per device under test per run.** Name it after the run —
`dut-ios-S-cellular.ndjson` — because the file name becomes the series label in
the report.

### 3.4 Take the capture

The capture is a **live stream held for the whole window**, not an export taken
at the end. A relay that honours NIP-40 drops a location event 228 s after it
was published, so an end-of-run export cannot be relied on to show more than the
last four minutes — and whether a given relay honours it is not something the
run should depend on.

```bash
# Start this BEFORE the battery window and leave it running for all of it.
nak req -k 445 --stream wss://relay.example.org > dut-ios-S-cellular.ndjson

# Option B instead — all three default relays, narrowed to your own circle by
# the `h` value found in the discovery pass of §3.2:
nak req -k 445 --tag h=<32-hex h value> --stream \
  wss://relay.damus.io wss://relay.primal.net wss://nos.lol \
  > dut-ios-S-cellular.ndjson
```

`nak req` prints one bare event object per line, which is format (a) above; the
same three relays returning the same event three times is expected and is
de-duplicated by event id at grading time.

At the end of the window, with option A, append the relay's own store as a
belt-and-braces against a stream that dropped near the end (duplicates are
merged, so this is always safe):

```bash
docker exec strfry strfry scan '{"kinds":[445]}' >> dut-ios-S-cellular.ndjson
# If the binary is not on PATH inside the container, try /app/strfry.
```

Stop the stream with Ctrl-C. A single truncated last line is expected and is
handled; anything else unparseable makes the capture unusable on purpose.

**Write down the battery window's own start and end, in epoch seconds** — `date
+%s` on the laptop at T0 and again when you end the window. They are what §3.5
grades the head and tail of the capture against, and without them the grader
returns `UNGRADED` rather than a pass. Start the capture stream *before* T0 and
stop it *after* the end; events outside the declared window are kept and never
count against it.

### 3.5 Grade the capture

`--publishers` and the declared window `--from`/`--until` are **required**, and
for the same reason: each has a wrong value that reads as a clean run. Declaring
1 publisher for a 2-member circle halves every event-count floor, so a device
that dropped out behind a healthy peer passes; and without the window the grader
only sees the span *between the first and last event it observed*, so a device
that published for 30 minutes of a 3-hour run and then died reports "worst gap
120 s, OK". Both are the field failure this whole section exists to catch.

```bash
# Baseline row, live 2-member circle. T0 and T_END are the battery window's own
# start and end in epoch seconds, from §3.4.
bash tooling/e2e/ci/summarize-created-at-gaps.sh \
  --publishers 2 --from <T0> --until <T_END> dut-ios-S-cellular.ndjson

# Acceptance row after phase P2a. The bound is PER API LEVEL, so pass the one
# that belongs to the ANDROID phone in the run — which is why the capture file
# below is the Android one; an iOS row keeps 228 and takes no --max-gap here:
#   --max-gap 198   Android API 31+ (S+ delayed register, worst cold gap 198 s)
#   --max-gap 248   Android API 23-30 (D3 (iii)'s ACCEPTED cold residual)
bash tooling/e2e/ci/summarize-created-at-gaps.sh \
  --publishers 2 --from <T0> --until <T_END> --max-gap 198 dut-android-S-cellular.ndjson

# Belt to the `--tag h=` suspenders on an option B capture: grade only your own
# circle, so a stranger's events can neither fail your run nor pad its counts.
bash tooling/e2e/ci/summarize-created-at-gaps.sh \
  --publishers 2 --from <T0> --until <T_END> \
  --series <32-hex h value> dut-ios-S-cellular.ndjson
```

If the run was captured in two files because the stream stopped and was
restarted, `cat` them into one before grading. The grader refuses two files
carrying the same circle (exit 3), because graded as two series the outage at
the seam between them belongs to neither — and duplicate event ids are merged,
so concatenating is always safe.

Exit codes: `0` clean **and graded**, `1` a bound was breached, `2` a usage
error, `3` the capture is unusable (absent, empty, malformed, split across
files, or holding no location event — and also the grader failing internally),
`4` its `--self-test` failed, `5` `UNGRADED`. Only `0` is a pass. `3` and `5`
are each a different answer from "clean" and neither is ever recorded as one.

Copy the reported **`worst gap`** into the *max relay gap (s)* column and the
capture file name into the *relay capture file* column. Bounds:

* **≤ 228 s** for a baseline row (`LOCATION_MESSAGE_RETENTION_SECS`) — **except
  on Android API 23–30, where the bound is ≤ 248 s**, because a baseline row is
  a row of the SHIPPED build and that regime's derived worst realized gap is
  248 s (D3 (iii)'s ACCEPTED cold residual; see the paragraph below the next
  one, which this bullet used to contradict). iOS and Android API 31+ keep 228 s
  — for iOS that is a ONE-CIRCLE number (control 3), not a claim about every
  roster; see "Why iOS keeps 228 s here" in the constants section above.
* For an acceptance row after P2a, **per API level, and record the level with
  the number or it means nothing**: **≤ 198 s on Android API 31+**, **≤ 248 s on
  API 23–30** — the second is `POWER_EFFICIENCY_PLAN.md` D3 (iii)'s **ACCEPTED**
  cold residual (two acquisitions, no delayed register; a peer's marker is absent
  for at most 20 s, once), not a passing invariant. This bullet said ≤ 188 s
  until 2026-09-08; §6.5 of the plan retracted that figure on 2026-09-04 as an
  artefact of a sweep that held σ = 0, and no tighter post-P2a number may be
  used as a threshold anywhere (§6.6).

A gap above the row's own bound is a real finding: stop, and file it under
`docs/BACKGROUND_SHARING_FAILURE_ANALYSIS.md` §7. **That bound is 228 s
everywhere except Android API 23–30, where it is 248 s** — this paragraph said
"above 228 s" flatly until 2026-09-09 and so contradicted both the bullet above
it and the correction below it, which is the whole point of recording the API
level beside the number. A 169 s gap is *not* a failure — it is a late tick
inside the promise, which is why the report buckets it separately.

**Which build the "baseline" row is of, since it decides the number** (corrected
2026-09-08). This paragraph said "today's derived worst case is 240 s"; that 240 s
is the PRE-P2a shape (a 72 s poll with a 30 s horizon plus a 30 s one-shot), which
was "today" when it was written on 2026-08-30 and is history since P2a landed on
2026-09-04. A baseline row taken now is a row of the SHIPPED build, whose derived
worst realized gap is 198 s on Android API 31+, 248 s on API 23–30, and 208 s on
iOS at this campaign's one circle — so on iOS and on API 31+ anything above 228 s
is a finding, while on API 23–30 a gap between
228 s and 248 s is D3 (iii)'s ACCEPTED residual and only above 248 s is it a
finding. Record the API level with the row, or the number cannot be read.

**Telling a dead capture from a dead app.** The report prints an `observed`
line (first and last `created_at` it saw) beside the `declared` window, and a
shortfall at either end is graded as a gap — which is right, because from the
relay a device that stopped publishing and a capture that stopped recording look
identical. Only you can tell them apart, and you must, before writing the row
down: was the `nak` process still running at the end, and does the option-A
end-of-run `strfry scan` append show the same silence? If the *stream* died, the
row's liveness column is **VOID and the run is redone**, not recorded as a
failure. Reading a broken instrument as a broken app is the mirror image of the
false green this whole section exists to prevent — and it is why the capture is
started before T0 and stopped after the end, so a healthy run has observations
on both sides of its own window.

### 3.6 What this capture can and cannot attribute

The capture is **circle-level**, not device-level, and the report says so when
you pass `--publishers 2`. A circle's relay set is fixed at creation and every
member publishes to all of it, so there is no relay that only one device writes
to; the two phones' publishes interleave in the capture. Consequences:

* An interleaved gap is *shorter* than either device's own gap, so a healthy
  peer can mask a device under test that stopped.
* The script therefore also applies two event-count floors, which are what can
  still see a device drop out. A publisher meeting the cadence emits at least
  `floor(W / 168)` events in any W-second window it is alive for, so two
  publishers emit at least twice that. The **span floor** takes W from the
  declared `--from`/`--until` window, so it sees both a device that never
  started and one that stopped: the events it never published are missing from
  the count. The **sliding-window floor** (`--window`, default 1800 s)
  re-applies the same arithmetic to every 30-minute window inside the observed
  span — that is what catches a device dying at two hours *behind a peer that
  keeps publishing*, which is the field shape this campaign exists to measure.
  It cannot see a lone publisher's death, because that death ends the observed
  span and leaves no window after it; the declared window's tail gap is what
  catches that one. Both floors need `--publishers` to be honest.
* Neither floor can see a device that merely *slowed*. **Never quote a
  multi-publisher gap as evidence about one device.**

If you can arrange a window in which the peer publishes nothing (Haven
force-quit on the peer), that window's capture *is* device-attributed — grade it
with `--publishers 1`. It is not a valid power row, because the device under
test receives nothing during it, but its liveness verdict is attributable. Note
in the row's notes column which kind of window the liveness number came from.

---

## 4. iOS run

Do these in order. (1) is the primary metric — the only iOS number in a
threshold. (2) and (3) are *attribution* evidence: they answer "was it Haven?",
not "how much?". (4) and (5) are the liveness and policy observations that make
the row interpretable.

1. **Device state of charge — the primary iOS metric.** Record the whole-device
   battery percentage at T0 and at the end of the window (Settings → Battery,
   or the status bar with *Battery Percentage* on), and report

   `device SoC %/h = (start SoC % − end SoC %) / window hours`

   into the *device SoC %/h* column. This is the only iOS figure that is a rate
   of energy over time, which is what the §7 thresholds are stated in — and it
   is why §1 pins everything else about the phone. Whole-device drain is only
   Haven's drain if nothing else is running, so controls 4–9 (screen off, no
   other location app, Low Power Mode off, unplugged, network state fixed) are
   what make this number attributable at all; a run that broke one of them
   measured something else. It also needs the long window §2 imposes: Settings
   reports whole percent, so a 3 h window at ≤ 1 %/h resolves to three or four
   counts while a 60 min one resolves to nothing.
2. **On-device Energy Log — attribution, not a rate.** Settings → Developer →
   Logging → Energy (the *Developer* menu only exists once **Developer Mode is
   enabled**: Settings → Privacy & Security → Developer Mode → on, then
   restart the phone; the phone must have been connected to Xcode at least once
   for the item to appear). Start it **before** backgrounding the app, stop it
   after the window. Import into Xcode Instruments (File → Import Logged Data
   from Device) and read the Haven process's energy impact and its Location and
   Network subcomponents. Use this rather than an Xcode-attached run: attaching
   keeps the process alive and skews the result.

   What it gives you is an **energy-impact score and component states over
   time** — which subsystems Haven kept awake, and when. It is not battery
   percent per hour and does not convert into one, so it never fills the
   primary column. What it is *for*: showing that the SoC drop in (1) came from
   Haven's location and networking rather than from something else, and showing
   *which* subsystem a regression is in.
3. **Settings → Battery — attribution, not a rate either.** Screenshot the
   "Last 24 Hours" per-app row for Haven at T0 and again at T0 + window,
   recording the percentage and the on-screen vs background minutes, and keep
   both screenshots as artefacts. Read it as a **share of app-attributed
   usage**: the rows sum to 100 %, so Haven's number moves when *other* apps
   run, and the difference between two screenshots is not an energy quantity.
   It is worth recording because a Haven share that jumps between two otherwise
   identical rows is a real signal — and because the background-minutes figure
   is the cheapest check that iOS ran Haven in the background at all.
4. **Device console.** Xcode → Window → Devices and Simulators → the device →
   Open Console, filtered on `locationd`. Watch for:
   * `"Location subscription"` RunningBoard assertions,
   * `runningboardd` `Suspending task` lines (recipe in
     `docs/M7_BACKGROUND_SHARING.md` §6),
   * the client's `desiredAccuracy` lines, which are what §6 turns into the
     profile-duty column.

   This console trace is the on-device liveness observation. It does not replace
   §3 — the relay capture is the evidence — but it is what tells you *why* a gap
   happened.
5. **Status-bar indicator.** Note what is visible at T0 + 5 min and again at the
   end: the blue pill, the arrow, or nothing. Record it in the *indicator seen*
   column, and check it against what the phase's policy predicts for the
   authorization tier you recorded in §1.

---

## 5. Android run

Connect over Wi-Fi adb so the phone can stay unplugged:

```bash
adb tcpip 5555                     # while still on USB
adb connect <phone-ip>:5555
# then unplug. (Alternatively: reconnect over USB only at the very end.)
```

Reset the counters, then run the window:

```bash
adb shell dumpsys batterystats --reset
adb shell dumpsys batterystats --enable full-wake-history
# unplug now, then run scenario S, then scenario W
```

**During the run**, roughly every 15 minutes, over the Wi-Fi adb link:

```bash
adb shell dumpsys location                      # Haven's live registrations
adb shell "dumpsys power | grep -A3 -i 'wake lock'"
adb shell dumpsys gnss
```

From `dumpsys location`, record for Haven's registration: the provider, the
requested interval (printed like `@+1m40s0ms`), `minUpdateDistance`, the
foreground flag, **and** the "gnss status listeners" / "nmea listeners" counts —
the plugin registers both, and they are a real cost even when no fix arrives.
From `dumpsys power`, record which `PARTIAL` wake locks Haven's uid holds and
the `ACQ=` age of each. From `dumpsys gnss`, record the fix count, TTFF,
"GNSS Power" if the HAL reports it, and whether `CAPABILITY_SCHEDULING` is
present.

**At the end of the window:**

```bash
adb shell dumpsys batterystats > bs.txt
adb shell dumpsys batterystats --checkin > bs.checkin
adb bugreport br.zip                            # for Battery Historian
```

From `bs.txt`, under Haven's uid, take:

* the `GPS` sensor time line → *Android GPS sensor s*
* `Wake lock … partial` time → *wake-lock s*
* `Mobile radio active` time → *mobile-radio active s*
* `Wifi` scan/running time and `CPU` user+system → notes
* the per-uid share of discharge → *discharge share*

Load `br.zip` into Battery Historian and record the `mobile_radio`, `gps` and
`wake_lock` bars for the window. Keep `bs.txt`, `bs.checkin` and `br.zip` as the
row's artefacts.

**Forced-idle rows** (only for the P2b merge gate) additionally run under
`adb shell dumpsys deviceidle force-idle`, screen off, on cellular, and are run
**twice** — once with Haven battery-optimisation-exempt and once not.

---

## 6. The profile-duty column

*Profile duty* records **how much of the window iOS spent at each location
accuracy profile**, written as the percentage at `Best`:
`profile duty (% at Best)`.

Compute it from the §4 step 4 console trace: the `desiredAccuracy` lines mark
every transition, so the duty is the summed time at `kCLLocationAccuracyBest`
divided by the window, with the remainder at `kCLLocationAccuracyHundredMeters`.
Write it as `100 % Best` or `38 % Best / 62 % HundredMeters`.

At baseline the answer is **100 % Best by construction** — Haven asks for
`LocationAccuracy.best` on every stream arm and both one-shots, and P0-A pins
that with a test so a change is a deliberate edit. The column is recorded anyway
because it is the number the two-profile work (phase P3) is re-tuned on, and a
baseline row without it cannot be compared to an acceptance row that has it.

Android has no equivalent column: the request carries one accuracy and the
platform decides. Leave it `n/a` on Android rows.

---

## 7. Acceptance thresholds

Copied from `docs/POWER_EFFICIENCY_PLAN.md` §6.6.

> **Deferred with the rest of this document (2026-08-30).** No row below has
> been evaluated, and none can be until hardware exists. Two consequences worth
> stating before the table is read:
>
> * **The relative column has no denominator.** It divides by a P0 baseline row
>   that was never measured (`POWER_EFFICIENCY_PLAN.md` §5.0, packet P0-D →
>   NOT AVAILABLE), so it is as unevaluable as the absolute column, not a
>   fallback for it.
> * **The absolute figures are now openly labelled as what they always were.**
>   They came from an extrapolation, and that extrapolation has since been
>   written out in full as estimation model E (`POWER_EFFICIENCY_PLAN.md`
>   §6.5a), with its inputs, its declared assumptions and its arithmetic on the
>   page. The iOS "≤ 1 %/h" is that model's output, not a measurement — the
>   model's own range for the same configuration is ≈ 0.4–1.6 %/h. Treat every
>   absolute figure below as an ESTIMATE to be *replaced* by the first real row,
>   exactly as the closing paragraph of this section already instructs.
>
> **The liveness row is the exception and keeps its full force.** It asserts
> that publishing never stopped, which is not a battery number and never was.
> While this protocol is deferred, the intended substitution is to run the same
> grader (§3.5) in CI over the e2e lanes' own relay captures instead of over a
> phone's — same instrument, same thresholds, same `--publishers` and
> declared-window requirements, a smaller subject and a shorter window. That
> substitution is specified in `POWER_EFFICIENCY_PLAN.md` §6.6, along with what
> it does not cover: a lane's minutes are not an afternoon, an emulator does not
> suspend its application processor, and a simulator has no suspension policy to
> exercise.
>
> **It has NOT been built yet, and this document will not pretend otherwise
> (corrected 2026-09-03).** The grader's only invocation in CI is its own
> `--self-test` (`.github/workflows/repo-guards.yml`): the instrument is
> fixture-tested, and nothing feeds it a real capture. No Android lane has a
> window that is both longer than the 228 s bound and guaranteed to carry the
> two events the grader needs; the lane that does — `e2e-ios-background-publish`,
> whose P2b window is 396 s with ≥ 2 events already asserted — runs the
> in-memory `tooling/e2e/local-relay`, which has no export path. The four pieces
> that would close it are itemised in `POWER_EFFICIENCY_PLAN.md` §5.1's LIVENESS
> block. Until they land, the deferred hardware protocol below and the CI
> substitute are BOTH outstanding, and the liveness clause is carried by the
> lanes' own in-process oracles alone.

| Metric | Threshold (absolute) | Threshold (relative to the P0 baseline) |
|---|---|---|
| iOS, background sharing ON, stationary ≥ 3 h, confirmed Always | ≤ 1 %/h **device SoC** (§4 step 1: `(start SoC − end SoC) / hours` under the §1 controls; reachable after P1+P3+P4; after P3 alone model E ESTIMATES ≈ 0.6–2.8 %/h — the "1.5–2.5 %/h expected" this cell carried until 2026-09-08 predated the model and agreed with nothing in it) | ≤ baseline / 4 (only resolvable if the baseline is ≥ 4 % over the window — else extend the window) |
| iOS, same, When-In-Use / provisional | ≤ 1.5 %/h device SoC (pill + activity session held) — like its neighbour above, an **extrapolation from model E**, never a measurement (in-cell tag added 2026-09-09; the row above carried one and this one did not). Model E predicts the same location saving here, because the retained session and pill are a policy claim rather than a radio (§6.6) | ≤ baseline / 3 |
| iOS, walking 30 min | no absolute (GPS-grade by design) | ≤ baseline / 2 |
| Android, stationary 60 min (P2a) | GPS sensor time ≤ 10 % of the window; mobile-radio active ≤ baseline / 3; the plugin wake lock is EXPECTED (P2a keeps it) | GPS time ≤ baseline / 8 |
| Android, stationary 60 min under forced idle (P2b merge gate), run in BOTH exemption states | exempt: `dumpsys power` shows no `ForegroundService:WakeLock` and no Haven partial lock older than 30 s at any sample, partial wake-lock time ≤ 1 % of the window; non-exempt: the plugin lock is EXPECTED and GPS time is still ≤ 10 %; both: indoor/no-fix publishes continue and relay-side gaps stay inside §3.5's per-API bound — **≤ 228 s at every API level.** D3 (iii)'s accepted 248 s cold residual (API 23–30) governs the "Both platforms" acceptance row two lines below, and **owner decision 2026-09-09 — `POWER_EFFICIENCY_PLAN.md` §4 OD-P2-4, L-125 — is that it does NOT travel to this gate**: forced idle is the scenario this gate exists to catch, so a handset that cannot meet 228 s here has produced a finding to FILE, not a threshold to relax. The two numbers are therefore not a contradiction — the looser one is scoped to the ordinary cold path, and was never evidence about a suspended AP. **Row history:** this cell read a flat ≤ 228 s until 2026-09-09, then cross-referenced the residual and left the question open; the flat number is restored by the decision, not by reverting the reasoning | — |
| Both platforms | the §3.5 grader exits **0** — a *graded* run, so `--publishers` and the declared `--from`/`--until` window were both given — with a max relay-side `created_at` gap ≤ 228 s in a baseline row and, in an acceptance row after P2a, ≤ 198 s on Android API 31+ or ≤ 248 s on API 23–30 with the API level recorded beside it — the second is D3 (iii)'s ACCEPTED cold residual, and the ≤ 188 s this row carried until 2026-09-08 was retracted by §6.5 on 2026-09-04 (liveness). A gap number without exit 0 behind it is not a liveness result: `5` means head and tail silence went ungraded and `3` means the capture proved nothing. Indicator state as the phase's policy predicts for the recorded tier; profile duty recorded | — |

Both iOS rows are stated in **device SoC %/h** because that is the only iOS
number that is a rate of energy over time. The Energy Log impact score and the
Settings → Battery per-app share are recorded on every row (§4 steps 2 and 3)
but are **attribution** evidence, not thresholds: the first is a score with no
percent-per-hour conversion, and the second is a share of app-attributed usage
whose rows sum to 100 %, so it moves when other apps run. A row that misses its
SoC threshold with Haven's Energy Log location/network components flat has found
something other than Haven; a row that meets it is not undone by an Energy Log
score. Neither ever substitutes for the SoC figure.

**The absolute figures are extrapolations, and are meant to be re-set from the
measured baseline.** They were derived from published bare-session power figures
— no vendor mA table exists for these radios — so a row that fails its absolute
threshold while passing its relative one does **not** reject the phase. When
that happens, the owner replaces the absolute figure in this document with the
value the hardware actually produced, states the reason next to it, and the new
figure becomes the standard from then on. The relative thresholds and the
liveness clause are not re-set: a power win that reopens the two-hour wedge
fails on liveness regardless of what the battery says, and a merge-gate row
(P3 item 0a, P2b forced idle) that fails its liveness clause blocks that phase.

---

## 8. The results template

One row per run. Columns, in order:

`date | commit | platform+OS | scenario | network | relays (count) | tier/backend | start→end SoC % | duration | device SoC %/h | Energy Log impact | iOS Δ% + bg minutes | profile duty (% at Best) | Android GPS sensor s | wake-lock s | mobile-radio active s | discharge share | max relay gap s | relay capture file | indicator seen | notes`

Empty row skeleton — copy this into the section for the run:

```
| date | commit | platform+OS | scenario | network | relays (count) | tier/backend | start→end SoC % | duration | device SoC %/h | Energy Log impact | iOS Δ% + bg min | profile duty (% at Best) | Android GPS sensor s | wake-lock s | mobile-radio active s | discharge share | max relay gap s | relay capture file | indicator seen | notes |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
|  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
```

Leave a cell `n/a` when the platform has no such metric (Energy Log, Δ% and
profile duty on Android; GPS sensor / wake-lock / mobile-radio on iOS). Never
leave a cell blank — a blank cell cannot be told apart from a measurement
somebody forgot to take. *device SoC %/h* is filled on **both** platforms: it is
arithmetic on two columns that are already there, and it is the iOS threshold
figure (§4 step 1). The *notes* cell carries the two clock offsets from control
14, and — on a liveness verdict taken from a peer-silent window — which kind of
window it came from (§3.6).

Name the artefacts after the row and keep them with it: `bs.txt`,
`bs.checkin`, `br.zip`, the two iOS Battery screenshots, the Energy Log trace,
and the `.ndjson` capture named in the *relay capture file* column.

Heading shapes, so rows are findable by what they were for:

* `## Baseline <date> <commit>` — the P0-D rows every later phase is compared to.
* `## Acceptance <date> <commit>` — a phase's acceptance rows.
* `## Merge gate <phase> <date> <commit>` — the P2b forced-idle rows, which
  block their phase rather than the release.
* `## Deferred proof <phase> <date> <commit>` — a row for a gate that was owed
  but could not be run when its phase merged. P3's `docs/M7_BACKGROUND_SHARING.md`
  §6 item 0 rows (0a confirmed Always, 0a-provisional, 0b When-In-Use, 0c stuck
  indicator) are the standing case: P3 merged on the re-based CI bundle in
  `POWER_EFFICIENCY_PLAN.md` §5.3 WP3-2 because there is no iPhone, so 0a was
  re-based rather than met and its rows are still owed. Run them under this
  heading when hardware returns — 0a needs the ≥ 2 h stationary window and the
  *max relay gap s* and *indicator seen* columns above all others, because
  V-P3-3 (does the confirmed-Always shape, holding no activity session with the
  indicator flag false, keep delivering for hours?) is what those two columns
  answer, and it is UNKNOWN today.

---

## 9. Results

<!--
Fill in below. Add one heading per campaign, newest last, and keep the table
skeleton from §8. Do not edit a recorded row: if a run is redone, add a new row
and say in its notes why it supersedes the earlier one.
-->

## Baseline <date> <commit>

| date | commit | platform+OS | scenario | network | relays (count) | tier/backend | start→end SoC % | duration | device SoC %/h | Energy Log impact | iOS Δ% + bg min | profile duty (% at Best) | Android GPS sensor s | wake-lock s | mobile-radio active s | discharge share | max relay gap s | relay capture file | indicator seen | notes |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
|  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |

Required to call the baseline complete: for each platform, one S row on
cellular, one S row on Wi-Fi, and one W row — with the max-relay-gap column
filled and inside §3.5's per-row bound (≤ 228 s on iOS and on Android API 31+;
**≤ 248 s on Android API 23–30**, D3 (iii)'s ACCEPTED cold residual, with the
API level recorded beside the number), and every artefact named. Stated per API
level rather than as a flat ≤ 228 s, which until 2026-09-09 would have refused
to certify a legitimately complete baseline taken on any API 23–30 handset.

**Unmet as of 2026-08-30, and deliberately left unmet** (see the banner at the
top): no phones, so zero rows. Do not fill these tables with estimates from
`POWER_EFFICIENCY_PLAN.md` §6.5a — the estimates live there, tagged, and this
table stays empty until somebody measures something. If an Android phone
appears first, fill the Android rows and leave the iOS rows empty; a
half-complete baseline is a real result, and a fabricated one is not.

**There is also no `## Acceptance`, `## Merge gate` or `## Deferred proof`
section below this one, and that absence is the record rather than an omission**
(re-verified 2026-09-08 by the P6-B′ estimate-integrity sweep). §8's heading
shapes are created by the run that fills them, and no run has happened — so the
plan's requirement that `## Acceptance` "stays EMPTY"
(`POWER_EFFICIENCY_PLAN.md` §5.6) holds in its strongest form: nothing has been
written under it because it does not exist yet. If one of those headings ever
appears here it should carry a dated row; an empty one means somebody added a
heading ahead of the measurement.
