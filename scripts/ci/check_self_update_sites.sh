#!/usr/bin/env bash
# CI guard: a self-update is authored only while a post-join obligation MDK
# wrote at a join is open, or from the user's repair entry — never by a wake,
# a timer or a drain (V2-22, A-3; `INV-E-NO-PERIODIC-REKEY`).
#
# ## Why this exists
#
# `SendIntent::SelfUpdate` rotates this device's leaf and moves the circle's
# epoch. Haven makes exactly two: the repair the user asks for
# (`Publishing::repair_rotation`, reached only from the bridge's
# `repair_rotation_driven`), and the one post-join self-update MDK records at
# every Welcome join (`cgka-engine/src/group_lifecycle.rs` 52-105), made by a
# full drive after catch-up (`Publishing::post_join`, run in a
# `DriveMode::Full` block of `Publishing::resume`). A timer may SERVE that
# one-shot obligation through the drive it already wakes; it may never
# ORIGINATE one. MDK also QUEUES a self-update it cannot make now and drains
# it later with none of Haven's gates (`message_processor/mod.rs` 1177-1231),
# so a queued one is retired inside the hold that queued it, and again in the
# hold of every full advance.
#
# ## What it enforces (production Rust of `haven-core/src`,
# `haven/rust_builder/src` and `tooling/soak/src`; `#[cfg(test)]` items and
# `#[cfg(any(test, feature = "test-utils"))]` items brace-walked out, string
# contents and line comments dropped, `frb_generated` excluded)
#
#   1. Exactly one construction of `SendIntent::SelfUpdate`, inside
#      `send_self_update_now` (a pattern — `{ .. }`, a `|` arm, a `=>` arm,
#      a `matches!` — is not a construction).
#   2. `send_self_update_now` is called only from `repair_self_update_staging`
#      and `post_join_self_update_staging`, and from both.
#   3. The post-join self-update is made only by a full drive:
#      `.post_join_self_update_staging(` is called only from the circle
#      manager's wrapper of the same name and from `Publishing::post_join`,
#      which tests `DriveMode::Full` before it; `self.post_join(` is called
#      only from `resume`, inside a block opened by
#      `if self.mode.mode() == DriveMode::Full {`. `settle_post_join` names
#      `MaintenanceTrigger::PostJoin`, and `post_join_due` calls it.
#   4. `repair_epoch_rotation_staging` is called only from
#      `Publishing::repair_rotation`, which is called only from the bridge's
#      `repair_rotation_driven`; neither name appears in `processor.rs`,
#      `session.rs`, `catchup.rs` or `retick.rs`.
#   5. Every `put_maintenance_obligation(` sits in `settle_post_join`, whose
#      only phases are `Complete`, `Failed` and the one re-open to
#      `CatchUp`. `MaintenanceTrigger::Periodic`, `MaintenanceTrigger::Manual`,
#      `EnabledForNewGroups`, `schedule_manual_self_update` and
#      `run_due_maintenance` appear nowhere; every
#      `put_periodic_maintenance_policy(` passes `Disabled`.
#   6. No `tokio::time`, `spawn`, `interval` or `sleep` in the bodies of the
#      functions above.
#   7. No queued self-update survives a hold: `send_self_update_now` calls
#      `retire_queued_self_updates(`, and `advance_once_for_drive` calls it
#      before its `advance_convergence(`.
#
# Pure-grep gate (no Rust toolchain), part of the shared repo-guards job.
#
# Usage:
#   check_self_update_sites.sh            # check the repo
#   check_self_update_sites.sh --self-test
#
# Exit codes: 0 pass; 1 violation (including a missing file); 2 misuse.

set -Eeuo pipefail
LITERAL_FREE="$(cat "$(dirname "${BASH_SOURCE[0]}")/lib/literal_free.awk")"
readonly LITERAL_FREE

SCRIPT_NAME="check_self_update_sites"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly PROD_DIRS=("haven-core/src" "haven/rust_builder/src" "tooling/soak/src")
readonly SESSION="haven-core/src/nostr/mls/manager.rs"
readonly CIRCLE="haven-core/src/circle/manager.rs"
readonly FANOUT="haven-core/src/relay/fanout.rs"
readonly BRIDGE="haven/rust_builder/src/api.rs"
readonly REQUIRED=("${SESSION}" "${CIRCLE}" "${FANOUT}" "${BRIDGE}")
readonly NO_REPAIR=(
  "haven-core/src/relay/live_sync/processor.rs"
  "haven-core/src/relay/live_sync/session.rs"
  "haven-core/src/relay/catchup.rs"
  "haven-core/src/relay/retick.rs"
)
readonly UNTIMED=(
  "send_self_update_now" "repair_self_update_staging" "post_join_self_update_staging"
  "settle_post_join" "post_join_due" "post_join_may_stage" "post_join"
)
readonly SELF_TEST_FIXTURES=17

log() { printf '\033[1;34m[%s]\033[0m %s\n' "${SCRIPT_NAME}" "$*"; }
fail_msg() { printf '\033[1;31m[%s] FAIL:\033[0m %s\n' "${SCRIPT_NAME}" "$*" >&2; }

# The production view of one file: `<line><TAB><enclosing fn><TAB><code>`,
# test and test-utils items walked out, literals and comments dropped.
prod_view() { # prod_view <file>
  awk "${LITERAL_FREE}"'
    { L[NR] = $0 }
    END {
      depth = 0; pending = 0; skipping = 0; itemdepth = 0; opened = 0; fn_name = ""
      for (j = 1; j <= NR; j++) {
        t = L[j]
        lfree = literal_free(t); tmp = lfree; o = gsub(/[{]/, "", tmp)
        tmp = lfree; c = gsub(/[}]/, "", tmp)
        attr = (t ~ /^[[:space:]]*#\[cfg\(test\)\]/ \
          || t ~ /^[[:space:]]*#\[cfg\(any\(test, feature = "test-utils"\)\)\]/)
        if (!skipping && attr) { pending = 1; depth += o - c; continue }
        if (pending && !skipping) {
          if (t ~ /^[[:space:]]*#\[/ || t ~ /^[[:space:]]*$/) { depth += o - c; continue }
          skipping = 1; itemdepth = depth; opened = 0; pending = 0; parens = 0
        }
        if (skipping) {
          depth += o - c
          tmp = lfree; parens += gsub(/[(]/, "", tmp); tmp = lfree; parens -= gsub(/[)]/, "", tmp)
          if (depth > itemdepth) opened = 1
          # An item with no body (a field, a `use`, a statement) ends at its
          # own `;` or `,` — not at one inside a signature still open.
          if ((opened && depth <= itemdepth) || (!opened && parens <= 0 && lfree ~ /[;,][[:space:]]*$/)) skipping = 0
          continue
        }
        depth += o - c
        if (t ~ /^[[:space:]]*(\/\/|\*|\/\*)/) continue
        if (match(lfree, /(^|[^A-Za-z0-9_])fn [a-z_0-9]+/)) {
          f = substr(lfree, RSTART, RLENGTH); sub(/^.*fn /, "", f); fn_name = f
        }
        printf "%d\t%s\t%s\n", j, fn_name, lfree
      }
    }
  ' "$1"
}

# Every production file, as `<rel>` lines.
prod_files() { # prod_files <root>
  local root="$1" dir
  for dir in "${PROD_DIRS[@]}"; do
    [[ -d "${root}/${dir}" ]] || continue
    find "${root}/${dir}" -name '*.rs' ! -name 'frb_generated*.rs' -printf '%P\n' |
      sed "s#^#${dir}/#"
  done | sort
}

# `<rel><TAB><line><TAB><fn><TAB><code>` for every production line of the tree.
tree_view() { # tree_view <root>
  local root="$1" rel
  while IFS= read -r rel; do
    prod_view "${root}/${rel}" | sed "s#^#${rel}\t#"
  done < <(prod_files "${root}")
}

run_checks() { # run_checks <root>
  local root="$1" fail=0 view rel
  for rel in "${REQUIRED[@]}"; do
    if [[ ! -f "${root}/${rel}" ]]; then
      fail_msg "${rel} is missing: a path this gate reads does not exist."
      fail=1
    fi
  done
  (( fail == 0 )) || return 1
  view="$(tree_view "${root}")"

  # 1. One construction, in send_self_update_now.
  local built
  built="$(awk -F'\t' '
    $4 ~ /SendIntent::SelfUpdate/ && $4 !~ /[.][.]/ && $4 !~ /^[[:space:]]*[|]/ \
      && $4 !~ /=>/ && $4 !~ /matches!/ { print $1 ":" $2 " (fn " $3 ")" }
  ' <<<"${view}")"
  if [[ "$(grep -c . <<<"${built}" || true)" != 1 ]] \
    || [[ "${built}" != "${SESSION}:"*" (fn send_self_update_now)" ]]; then
    fail_msg "[1] \`SendIntent::SelfUpdate\` is constructed at [${built//$'\n'/; }], expected \
exactly once, in \`send_self_update_now\`."
    fail=1
  fi

  # 2. Who asks the engine.
  local askers
  askers="$(awk -F'\t' '$4 ~ /([.]|::)send_self_update_now[(]/ { print $3 }' <<<"${view}" |
    sort -u | tr '\n' ' ')"
  if [[ "${askers}" != "post_join_self_update_staging repair_self_update_staging " ]]; then
    fail_msg "[2] \`send_self_update_now\` is called from [${askers}], expected exactly the \
repair's and the post-join's staging."
    fail=1
  fi

  # 3. The post-join is a full drive's.
  local stagers
  stagers="$(awk -F'\t' '$4 ~ /[.]post_join_self_update_staging[(]/ { print $1 ":" $3 }' \
    <<<"${view}" | sort -u | tr '\n' ' ')"
  if [[ "${stagers}" != "${CIRCLE}:post_join_self_update_staging ${FANOUT}:post_join " ]]; then
    fail_msg "[3] the post-join self-update is staged from [${stagers}], expected only the \
circle manager's wrapper and \`Publishing::post_join\`."
    fail=1
  fi
  if ! awk -F'\t' -v f="${FANOUT}" '
      $1 == f && $3 == "post_join" && $4 ~ /DriveMode::Full/ { full = 1 }
      $1 == f && $3 == "post_join" && $4 ~ /post_join_self_update_staging[(]/ { ok = full; seen = 1 }
      END { exit !(seen && ok) }' <<<"${view}"; then
    fail_msg "[3] \`Publishing::post_join\` does not test \`DriveMode::Full\` before it stages."
    fail=1
  fi
  local callers
  callers="$(awk -F'\t' '$4 ~ /self[.]post_join[(]/ { print $1 ":" $3 }' <<<"${view}" |
    sort -u | tr '\n' ' ')"
  if [[ "${callers}" != "${FANOUT}:resume " ]]; then
    fail_msg "[3] \`self.post_join(\` is called from [${callers}], expected only \`resume\`."
    fail=1
  elif ! awk -F'\t' -v f="${FANOUT}" '
      $1 == f && $3 == "resume" && $4 ~ /self[.]post_join[(]/ { ok = (prev ~ /^[[:space:]]*if self[.]mode[.]mode[(][)] == DriveMode::Full [{][[:space:]]*$/); seen = 1 }
      $1 == f && $3 == "resume" && $4 !~ /^[[:space:]]*$/ { prev = $4 }
      END { exit !(seen && ok) }' <<<"${view}"; then
    fail_msg "[3] \`resume\` calls \`self.post_join(\` outside a block opened by \
\`if self.mode.mode() == DriveMode::Full {\`."
    fail=1
  fi
  if ! awk -F'\t' -v f="${SESSION}" '$1 == f && $3 == "settle_post_join" && $4 ~ /MaintenanceTrigger::PostJoin/ { s = 1 }
      $1 == f && $3 == "post_join_due" && $4 ~ /settle_post_join[(]/ { d = 1 }
      END { exit !(s && d) }' <<<"${view}"; then
    fail_msg "[3] \`settle_post_join\` no longer names \`MaintenanceTrigger::PostJoin\`, or \
\`post_join_due\` no longer settles first."
    fail=1
  fi

  # 4. The repair is the bridge's alone.
  local repairs
  repairs="$(awk -F'\t' '$4 ~ /([.]|::)repair_epoch_rotation_staging[(]/ && $4 !~ /fn repair_epoch_rotation_staging/ { print $1 ":" $3 }' \
    <<<"${view}" | sort -u | tr '\n' ' ')"
  if [[ "${repairs}" != "${FANOUT}:repair_rotation " ]]; then
    fail_msg "[4] \`repair_epoch_rotation_staging\` is called from [${repairs}], expected only \
\`Publishing::repair_rotation\`."
    fail=1
  fi
  repairs="$(awk -F'\t' '$4 ~ /[.]repair_rotation[(]/ { print $1 ":" $3 }' <<<"${view}" |
    sort -u | tr '\n' ' ')"
  if [[ "${repairs}" != "${BRIDGE}:repair_rotation_driven " ]]; then
    fail_msg "[4] \`.repair_rotation(\` is called from [${repairs}], expected only the bridge's \
\`repair_rotation_driven\`."
    fail=1
  fi
  for rel in "${NO_REPAIR[@]}"; do
    if awk -F'\t' -v f="${rel}" '$1 == f && $4 ~ /repair_rotation|repair_epoch_rotation_staging/ { found = 1 } END { exit !found }' <<<"${view}"; then
      fail_msg "[4] ${rel} names the repair: no wake, plane or sweep may reach it."
      fail=1
    fi
  done

  # 5. The obligation writes and the policy.
  local writers phases
  writers="$(awk -F'\t' '$4 ~ /put_maintenance_obligation[(]/ { print $1 ":" $3 }' <<<"${view}" |
    sort -u | tr '\n' ' ')"
  if [[ "${writers}" != "${SESSION}:settle_post_join " ]]; then
    fail_msg "[5] an obligation is written from [${writers}], expected only \`settle_post_join\`."
    fail=1
  fi
  phases="$(awk -F'\t' -v f="${SESSION}" '$1 == f && $3 == "settle_post_join" {
      rest = $4
      while (match(rest, /MaintenancePhase::[A-Za-z]+/)) {
        print substr(rest, RSTART + 18, RLENGTH - 18); rest = substr(rest, RSTART + RLENGTH)
      }
    }' <<<"${view}")"
  if grep -qvxE 'Complete|Failed|CatchUp' <<<"${phases}" \
    || [[ "$(grep -cx CatchUp <<<"${phases}" || true)" != 1 ]]; then
    fail_msg "[5] \`settle_post_join\` names phases [${phases//$'\n'/ }], expected only Complete \
and Failed, and CatchUp once (the re-open)."
    fail=1
  fi
  local banned
  banned="$(awk -F'\t' '$4 ~ /MaintenanceTrigger::(Periodic|Manual)|EnabledForNewGroups|schedule_manual_self_update|run_due_maintenance/ { print $1 ":" $2 }' <<<"${view}")"
  if [[ -n "${banned}" ]]; then
    fail_msg "[5] periodic or manual maintenance is named at [${banned//$'\n'/; }]."
    fail=1
  fi
  if awk -F'\t' '$4 ~ /put_periodic_maintenance_policy[(]/ && $4 !~ /PeriodicMaintenancePolicy::Disabled/ { found = 1 } END { exit !found }' <<<"${view}"; then
    fail_msg "[5] a \`put_periodic_maintenance_policy(\` does not pass \`Disabled\`."
    fail=1
  fi

  # 6. Nothing here arms a timer.
  local fn
  for fn in "${UNTIMED[@]}"; do
    if awk -F'\t' -v fn="${fn}" '$3 == fn && $4 ~ /tokio::time|spawn|interval|sleep/ { found = 1 } END { exit !found }' <<<"${view}"; then
      fail_msg "[6] \`${fn}\` arms a timer, a task or a sleep."
      fail=1
    fi
  done

  # 7. No queued self-update survives a hold.
  if ! awk -F'\t' -v f="${SESSION}" '$1 == f && $3 == "send_self_update_now" && $4 ~ /retire_queued_self_updates[(]/ { found = 1 } END { exit !found }' <<<"${view}"; then
    fail_msg "[7] \`send_self_update_now\` no longer retires a self-update the engine queued."
    fail=1
  fi
  if ! awk -F'\t' -v f="${SESSION}" '$1 == f && $3 == "advance_once_for_drive" {
        if ($4 ~ /retire_queued_self_updates[(]/) r = NR
        if ($4 ~ /advance_convergence[(]/ && !a) a = NR
      }
      END { exit !(r && a && r < a) }' <<<"${view}"; then
    fail_msg "[7] \`advance_once_for_drive\` does not retire queued self-updates before its \
full advance."
    fail=1
  fi

  (( fail == 0 )) || return 1
  log "OK: a self-update is made only by the repair and the post-join, under a full drive."
}

self_test() {
  local tmp fails=0 checked=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN
  local session circle fanout bridge
  session='impl SessionManager {
    pub(crate) async fn repair_self_update_staging(&self, g: &G) {
        let r = self.send_self_update_now(&mut s, g).await;
    }
    pub(crate) async fn post_join_self_update_staging(&self, g: &G) {
        let r = self.send_self_update_now(&mut s, g).await;
    }
    async fn send_self_update_now(&self, s: &mut S, g: &G) {
        let r = s
            .send(SendIntent::SelfUpdate {
                group_id: g.clone(),
            })
            .await;
        self.retire_queued_self_updates(s, g);
    }
    fn retire_queued_self_updates(&self, s: &mut S, g: &G) -> bool {
        matches!(q.intent, SendIntent::SelfUpdate { .. })
    }
    fn settle_post_join(&self, s: &S) {
        if o.trigger != MaintenanceTrigger::PostJoin || o.phase == MaintenancePhase::Failed {}
        let p = if a { MaintenancePhase::Failed } else if b { MaintenancePhase::Complete } else { MaintenancePhase::CatchUp };
        s.put_maintenance_obligation(&o);
    }
    pub(crate) async fn post_join_due(&self) {
        let open = self.settle_post_join(&s);
    }
    async fn advance_once_for_drive(&self, s: &mut S, g: &G) {
        let r = if self.retire_queued_self_updates(s, g) {
            s.advance_convergence(g).await
        };
    }
    fn open(&self) {
        s.put_periodic_maintenance_policy(PeriodicMaintenancePolicy::Disabled);
    }
}
#[cfg(any(test, feature = "test-utils"))]
pub async fn queue_self_update_intent_for_test(&self, g: &G) {
    self.queue(SendIntent::SelfUpdate {
        group_id: g.clone(),
    });
}'
  circle='impl CircleManager {
    pub(crate) async fn post_join_self_update_staging(&self, g: &G) {
        self.session.post_join_self_update_staging(g).await
    }
}'
  fanout='impl Publishing {
    pub async fn repair_rotation(&self, c: &C, g: &G) {
        c.repair_epoch_rotation_staging(g).await
    }
    pub async fn resume(&self, c: &C) {
        if self.mode.mode() == DriveMode::Full {
            self.post_join(c, &mut pass).await;
        }
    }
    async fn post_join(&self, c: &C) {
        if self.mode.mode() != DriveMode::Full { return; }
        c.post_join_self_update_staging(g).await;
    }
}'
  bridge='impl RelayManagerFfi {
    pub async fn repair_rotation_driven(&self) {
        p.repair_rotation(c, g).await
    }
}'
  _case() { # _case <name> <expected rc> <session> <circle> <fanout> <bridge> [extra file] [extra text]
    local name="$1" expect="$2" root rc=0
    root="${tmp}/${checked}"
    mkdir -p "${root}/haven-core/src/nostr/mls" "${root}/haven-core/src/circle" \
      "${root}/haven-core/src/relay/live_sync" "${root}/haven/rust_builder/src"
    [[ -n "$3" ]] && printf '%s\n' "$3" >"${root}/${SESSION}"
    printf '%s\n' "$4" >"${root}/${CIRCLE}"
    printf '%s\n' "$5" >"${root}/${FANOUT}"
    printf '%s\n' "$6" >"${root}/${BRIDGE}"
    [[ -n "${7:-}" ]] && printf '%s\n' "$8" >"${root}/$7"
    run_checks "${root}" >/dev/null 2>&1 || rc=$?
    checked=$((checked + 1))
    if [[ "${rc}" != "${expect}" ]]; then
      echo "self-test: '${name}' exited ${rc}, expected ${expect}" >&2
      fails=$((fails + 1))
    fi
  }
  _case "the reviewed shape passes" 0 "${session}" "${circle}" "${fanout}" "${bridge}"
  _case "a missing session file FAILS" 1 "" "${circle}" "${fanout}" "${bridge}"
  _case "a test-utils seam with a signature over lines is walked out" 0 "${session}
#[cfg(any(test, feature = \"test-utils\"))]
pub async fn seam_for_test(
    &self,
    g: &G,
) -> R {
    self.queue(SendIntent::SelfUpdate {
        group_id: g.clone(),
    });
}" "${circle}" "${fanout}" "${bridge}"
  _case "[1] a second construction FAILS" 1 "${session}
fn sneak(&self) { s.send(SendIntent::SelfUpdate { group_id: g }); }" \
    "${circle}" "${fanout}" "${bridge}"
  _case "[1] a construction elsewhere FAILS" 1 "${session}" "${circle}" "${fanout}" "${bridge}" \
    "haven-core/src/relay/live_sync/processor.rs" 'fn drive_due(&self) {
    s.send(SendIntent::SelfUpdate {
        group_id: g,
    });
}'
  _case "[2] a third asker FAILS" 1 "${session}
fn tick(&self) { self.send_self_update_now(&mut s, g).await; }" \
    "${circle}" "${fanout}" "${bridge}"
  _case "[3] a post-join staged from a plane FAILS" 1 "${session}" "${circle}" "${fanout}" \
    "${bridge}" "haven-core/src/relay/catchup.rs" 'fn sweep(&self) { c.post_join_self_update_staging(g).await; }'
  _case "[3] a post-join outside the full block FAILS" 1 "${session}" "${circle}" \
    "${fanout/        if self.mode.mode() == DriveMode::Full \{/        \{}" "${bridge}"
  _case "[3] a post-join with no full test FAILS" 1 "${session}" "${circle}" \
    "${fanout/        if self.mode.mode() != DriveMode::Full \{ return; \}/}" "${bridge}"
  _case "[4] the repair from a plane FAILS" 1 "${session}" "${circle}" "${fanout}" "${bridge}" \
    "haven-core/src/relay/live_sync/session.rs" 'fn serve(&self) { p.repair_rotation(c, g).await; }'
  _case "[4] the repair staged from elsewhere FAILS" 1 "${session}" "${circle}
fn tick(&self) { self.repair_epoch_rotation_staging(g).await; }" "${fanout}" "${bridge}"
  _case "[5] an obligation written elsewhere FAILS" 1 "${session}
fn arm(&self) { s.put_maintenance_obligation(&o); }" "${circle}" "${fanout}" "${bridge}"
  _case "[5] another phase FAILS" 1 \
    "${session/MaintenancePhase::CatchUp/MaintenancePhase::Jitter}" \
    "${circle}" "${fanout}" "${bridge}"
  _case "[5] periodic enrolment FAILS" 1 \
    "${session/PeriodicMaintenancePolicy::Disabled/PeriodicMaintenancePolicy::EnabledForNewGroups}" \
    "${circle}" "${fanout}" "${bridge}"
  _case "[6] a timer in the due read FAILS" 1 \
    "${session/let open = self.settle_post_join(&s);/let open = self.settle_post_join(\&s); tokio::time::sleep(d).await;}" \
    "${circle}" "${fanout}" "${bridge}"
  _case "[7] no retirement in the send FAILS" 1 \
    "${session/        self.retire_queued_self_updates(s, g);/}" \
    "${circle}" "${fanout}" "${bridge}"
  _case "[7] no retirement before the full advance FAILS" 1 \
    "${session/let r = if self.retire_queued_self_updates(s, g) \{/let r = if true \{}" \
    "${circle}" "${fanout}" "${bridge}"
  if (( fails )); then echo "self-test: FAILED" >&2; return 1; fi
  if (( checked != SELF_TEST_FIXTURES )); then
    echo "self-test: ran ${checked} fixture(s), expected exactly ${SELF_TEST_FIXTURES}." >&2
    return 1
  fi
  local rel
  for rel in "${REQUIRED[@]}" "${NO_REPAIR[@]}"; do
    if [[ ! -f "${REPO_ROOT}/${rel}" ]]; then
      echo "self-test: ${rel}, a path this gate names, does not exist." >&2
      return 1
    fi
  done
  log "OK: self-test passed (${checked} fixtures; every named path exists)."
}

case "${1:-}" in
  --self-test) self_test ;;
  '') run_checks "${REPO_ROOT}" ;;
  *) echo "usage: $(basename "$0") [--self-test]" >&2; exit 2 ;;
esac
