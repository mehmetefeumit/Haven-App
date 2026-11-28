#!/usr/bin/env bash
# Re-lock every Cargo root against the manifests it is run on, moving only
# what those manifests require.
#
# haven/rust_builder and tooling/soak path-depend on haven-core, tooling/logscan
# and tooling/e2e/local-relay, and haven-core dev-depends on local-relay, but
# Dependabot re-locks only the directory it updates. A bump in one root leaves
# the others stale, and `cargo metadata --locked` (rust-check.yml) refuses
# them. dependabot-lockfile-sync.yml runs this on a Dependabot branch and
# commits what it changes.
#
# Every tracked Cargo.lock is a root. Each is re-locked with
# `cargo update --workspace`, which resolves only: it reads the index and git
# sources, downloads no crate and runs no build script. It keeps every locked
# package the changed manifests leave satisfiable at its locked version (cargo
# may re-point an edge to a version the lockfile already holds), so a root
# whose lockfile already agrees is left byte-identical. `cargo metadata` or
# `generate-lockfile` would re-resolve far more than the bump.
#
# A package the manifests now need is resolved fresh, at its newest release.
# Where some lockfile already holds a semver-compatible version of it, the
# root is pinned to the newest such version (`--precise`), so the roots agree
# and nothing enters that Dependabot did not resolve. That also covers a
# Dependabot run that edits a path dependency's manifest but not its lockfile.
# The sync never writes a (name, version, source) that no lockfile held before
# it ran; when cargo needs one (a release since Dependabot resolved the bump,
# with no compatible version held), it fails, and `@dependabot recreate`
# resolves the bump afresh.
#
# `--commit` puts the re-locked files on the branch through the REST API, as
# one commit on the exact head that was re-locked: no checkout and no cargo
# beside the write token, a ref update GitHub refuses unless it fast-forwards,
# and, made by an app with no author given, a commit GitHub signs. Its message
# carries `[dependabot skip]`, which lets Dependabot rebase over it; the sync
# then runs again on Dependabot's push.
#
# Usage:
#   bash scripts/ci/sync_cargo_lockfiles.sh              re-lock the repository
#   GH_TOKEN=… GITHUB_REPOSITORY=owner/name HEAD_SHA=… HEAD_REF=… \
#     bash scripts/ci/sync_cargo_lockfiles.sh --commit <dir>
#                                                        commit <dir>'s files,
#                                                        each at its path
#   bash scripts/ci/sync_cargo_lockfiles.sh --self-test  hermetic fixtures
#
# Exit: 0 every root agrees with its manifests (each lockfile it changed is
# listed on stdout) or the commit landed, 1 a root needs a version no lockfile
# held, cargo could not resolve, a staged file is not a Cargo.lock the head
# tracks, the API refused a step, or the self-test failed, 2 no tracked
# Cargo.lock or a usage error.

set -euo pipefail

REPO_ROOT="${REPO_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# One `name<TAB>version<TAB>source` row per [[package]] block, sorted; a path
# package has no `source` line and is recorded as `path`.
pairs() { # <lockfile>
  awk '
    function flush() { if (pkg && n != "") printf "%s\t%s\t%s\n", n, v, s }
    /^\[/ { flush(); pkg = ($0 == "[[package]]"); n = ""; v = ""; s = "path"; next }
    pkg && /^name = /    { n = $3; gsub(/"/, "", n) }
    pkg && /^version = / { v = $3; gsub(/"/, "", v) }
    pkg && /^source = /  { s = $3; gsub(/"/, "", s) }
    END { flush() }
  ' "$1" | LC_ALL=C sort -u
}

# The compatibility class of a caret requirement: the leftmost non-zero
# component.
compat() { # <version>
  awk -F. '{ if ($1 != 0) print $1; else if ($2 != 0) print "0." $2; else print "0.0." $3 }' <<<"${1%%[-+]*}"
}

run_sync() {
  local -a locks=()
  mapfile -t locks < <(git -C "${REPO_ROOT}" ls-files -- ':(glob)**/Cargo.lock')
  (( ${#locks[@]} > 0 )) || { echo "ERROR: no tracked Cargo.lock under ${REPO_ROOT}" >&2; return 2; }

  local tmp lock key dir
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN
  for lock in "${locks[@]}"; do
    key="${lock//\//_}"
    pairs "${REPO_ROOT}/${lock}" >"${tmp}/${key}.before"
    cp "${REPO_ROOT}/${lock}" "${tmp}/${key}.lock"
  done
  LC_ALL=C sort -u "${tmp}"/*.before >"${tmp}/held"

  local -a failures=()
  local now prev name version source want row
  for lock in "${locks[@]}"; do
    key="${lock//\//_}"
    dir="${REPO_ROOT}/$(dirname "${lock}")"
    # From the root itself, as rust-check.yml resolves it, so the repository's
    # cargo config applies to both.
    (cd "${dir}" && cargo update --workspace --quiet) \
      || { echo "FAIL: cargo could not re-lock ${lock}" >&2; return 1; }
    prev=''
    while now="$(pairs "${REPO_ROOT}/${lock}" | LC_ALL=C comm -23 - "${tmp}/${key}.before" \
                   | LC_ALL=C comm -23 - "${tmp}/held")"
          [[ -n "${now}" && "${now}" != "${prev}" ]]; do
      prev="${now}"
      while IFS=$'\t' read -r name version source; do
        [[ "${source}" == registry+* ]] || continue
        want="$(awk -F'\t' -v n="${name}" -v s="${source}" '$1 == n && $3 == s { print $2 }' "${tmp}/held" \
                  | while read -r row; do
                      [[ "$(compat "${row}")" != "$(compat "${version}")" ]] || echo "${row}"
                    done | sort -V | tail -n 1)"
        [[ -n "${want}" ]] || continue
        # A pin cargo refuses, or one whose row an earlier pin already moved,
        # leaves the row unheld, and the next pass or the report below sees it.
        (cd "${dir}" && cargo update --quiet -p "${name}@${version}" --precise "${want}" 2>/dev/null) || :
      done <<<"${now}"
    done
    cmp -s "${REPO_ROOT}/${lock}" "${tmp}/${key}.lock" || echo "${lock}"
    while IFS= read -r row; do
      [[ -z "${row}" ]] || failures+=("${lock}: ${row//$'\t'/ }")
    done <<<"${now}"
  done

  if (( ${#failures[@]} > 0 )); then
    printf '  %s\n' "${failures[@]}" >&2
    echo "FAIL: re-locking needs crate versions no lockfile held before it ran, with none compatible held (a release since Dependabot resolved this bump). Comment \`@dependabot recreate\` to resolve it afresh." >&2
    return 1
  fi
}

commit_relocked() { # <dir>
  local dir="$1" repo="${GITHUB_REPOSITORY:?}" head="${HEAD_SHA:?}" ref="${HEAD_REF:?}"
  local -a files=()
  [[ -d "${dir}" ]] || { echo "ERROR: ${dir} is not a directory" >&2; return 2; }
  mapfile -t files < <(cd "${dir}" && find . -type f -printf '%P\n' | LC_ALL=C sort)
  (( ${#files[@]} > 0 )) || { echo "ERROR: ${dir} holds no file" >&2; return 2; }

  # Only a Cargo.lock the head already tracks: the write token never carries a
  # path the re-lock did not own.
  local f
  for f in "${files[@]}"; do
    if [[ ! "${f}" =~ ^([A-Za-z0-9_-][A-Za-z0-9._-]*/)*Cargo\.lock$ ]] \
       || [[ "$(gh api "repos/${repo}/contents/${f}?ref=${head}" --jq .type)" != file ]]; then
      echo "FAIL: ${f} is not a Cargo.lock that ${head} tracks; nothing was committed." >&2
      return 1
    fi
  done

  local entries='[]' blob tree commit
  for f in "${files[@]}"; do
    blob="$(jq -n --rawfile c "${dir}/${f}" '{content: $c, encoding: "utf-8"}' \
              | gh api "repos/${repo}/git/blobs" --input - --jq .sha)"
    entries="$(jq -c --arg p "${f}" --arg s "${blob}" '. + [{path: $p, mode: "100644", type: "blob", sha: $s}]' <<<"${entries}")"
  done
  tree="$(gh api "repos/${repo}/git/commits/${head}" --jq .tree.sha)"
  tree="$(jq -n --arg b "${tree}" --argjson t "${entries}" '{base_tree: $b, tree: $t}' \
            | gh api "repos/${repo}/git/trees" --input - --jq .sha)"
  commit="$(jq -n --arg t "${tree}" --arg p "${head}" \
              --arg m "$(printf 'build(deps): re-lock the Cargo roots the bump left stale [dependabot skip]\n\nRe-locked by scripts/ci/sync_cargo_lockfiles.sh:\n%s\n' "$(printf '  %s\n' "${files[@]}")")" \
              '{message: $m, tree: $t, parents: [$p]}' \
              | gh api "repos/${repo}/git/commits" --input - --jq .sha)"
  # `force: false`: refused unless the branch is still at ${head}.
  jq -n --arg s "${commit}" '{sha: $s, force: false}' \
    | gh api --method PATCH "repos/${repo}/git/refs/heads/${ref}" --input - --silent \
    || { echo "FAIL: ${ref} moved past the re-locked head; the run for its new head re-locks it." >&2; return 1; }
  echo "committed ${commit} onto ${ref}"
}

# ---------------------------------------------------------------------------
# Self-test: throwaway git repositories, re-locked offline through the real
# entry point against a local registry. `core` and `other` are roots of their
# own; `app` path-depends on `core` the way rust_builder does on haven-core;
# `leaf` is a path crate no lockfile holds.
# ---------------------------------------------------------------------------
self_test() {
  local tmp fails=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN
  export CARGO_NET_OFFLINE=true CARGO_HOME="${tmp}/cargo-home"

  # A local registry serving `dep` 0.2.0 and 0.2.1 (index and .crate files).
  local reg="${tmp}/registry" v cksum
  mkdir -p "${reg}/index/3/d"
  for v in 0.2.0 0.2.1; do
    mkdir -p "${tmp}/pkg/dep-${v}/src"
    : >"${tmp}/pkg/dep-${v}/src/lib.rs"
    printf '[package]\nname = "dep"\nversion = "%s"\nedition = "2021"\n' "${v}" >"${tmp}/pkg/dep-${v}/Cargo.toml"
    tar -czf "${reg}/dep-${v}.crate" -C "${tmp}/pkg" "dep-${v}"
    cksum="$(sha256sum "${reg}/dep-${v}.crate" | cut -d' ' -f1)"
    printf '{"name":"dep","vers":"%s","deps":[],"cksum":"%s","features":{},"yanked":false}\n' "${v}" "${cksum}" \
      >>"${reg}/index/3/d/dep"
  done

  _crate() { # <dir> <name> [dependency line]...
    local dir="$1" name="$2" dep; shift 2
    mkdir -p "${dir}/src"
    : >"${dir}/src/lib.rs"
    printf '[package]\nname = "%s"\nversion = "0.1.0"\nedition = "2021"\n\n[dependencies]\n' "${name}" >"${dir}/Cargo.toml"
    for dep in "$@"; do printf '%s\n' "${dep}" >>"${dir}/Cargo.toml"; done
  }
  _commit() { git -C "$1" add -A && git -C "$1" -c user.name=t -c user.email=t@t commit -qm "$2"; }
  # A repository whose roots agree. `other` locks dep 0.2.0 exactly.
  _tree() { # <tree>
    mkdir -p "$1/.cargo"
    printf '[source.crates-io]\nreplace-with = "fixture"\n\n[source.fixture]\nlocal-registry = "%s"\n' "${reg}" \
      >"$1/.cargo/config.toml"
    _crate "$1/leaf" leaf
    _crate "$1/core" core
    _crate "$1/app" app 'core = { path = "../core" }'
    _crate "$1/other" other 'dep = "=0.2.0"'
    (cd "$1/core" && cargo generate-lockfile --quiet)
    (cd "$1/app" && cargo generate-lockfile --quiet)
    (cd "$1/other" && cargo generate-lockfile --quiet)
    git -C "$1" init -q
    _commit "$1" fixture
  }
  # Dependabot's commit: <line> added to core's manifest, and `cargo update`
  # run in each root named after it.
  _bump() { # <tree> <line> [root]...
    local t="$1" line="$2" r; shift 2
    printf '%s\n' "${line}" >>"${t}/core/Cargo.toml"
    for r in "$@"; do (cd "${t}/${r}" && cargo update --workspace --quiet); done
    _commit "${t}" bump
  }
  _run() { REPO_ROOT_OVERRIDE="$1" bash "${BASH_SOURCE[0]}" >"$1.out" 2>"$1.err"; }
  # Every root resolves from its lockfile alone, as rust-check.yml asks.
  _locked() { # <tree>
    local r
    for r in core app other; do
      (cd "$1/${r}" && cargo metadata --locked --format-version 1 >/dev/null 2>&1) || return 1
    done
  }
  _status() { git -C "$1" status --porcelain; }
  _verdict() { # <label> <condition rc>
    if [[ "$2" -eq 0 ]]; then
      printf '  \033[1;32mPASS\033[0m %s\n' "$1"
    else
      printf '  \033[1;31mFAIL\033[0m %s\n' "$1" >&2
      fails=1
    fi
  }

  echo "sync_cargo_lockfiles.sh --self-test"
  local t rc ok

  t="${tmp}/agree"; _tree "${t}"
  rc=0; _run "${t}" || rc=$?
  ok=0; [[ "${rc}" -eq 0 && -z "$(_status "${t}")" && ! -s "${t}.out" ]] || ok=1
  _verdict "roots that already agree are left byte-identical" "${ok}"

  t="${tmp}/stale"; _tree "${t}"
  _bump "${t}" 'leaf = { path = "../leaf" }' core
  ok=0; _locked "${t}" && ok=1
  rc=0; _run "${t}" || rc=$?
  [[ "${rc}" -eq 0 && "$(_status "${t}")" == ' M app/Cargo.lock' && "$(cat "${t}.out")" == 'app/Cargo.lock' ]] \
    && _locked "${t}" || ok=1
  _verdict "a root a bump left stale is re-locked, alone, and resolves --locked" "${ok}"

  # PR 77's shape: Dependabot edits core's manifest but re-locks only app,
  # which holds dep 0.2.0; 0.2.1 is the newest release.
  t="${tmp}/align"; _tree "${t}"
  _bump "${t}" 'dep = "0.2"' app
  (cd "${t}/app" && cargo update --quiet -p dep --precise 0.2.0)
  _commit "${t}" 'app holds 0.2.0'
  rc=0; _run "${t}" || rc=$?
  ok=0
  [[ "${rc}" -eq 0 && "$(_status "${t}")" == ' M core/Cargo.lock' ]] \
    && pairs "${t}/core/Cargo.lock" | grep -qx $'dep\t0.2.0\tregistry+https://github.com/rust-lang/crates.io-index' \
    && _locked "${t}" || ok=1
  _verdict "a package another root holds is pinned to the held version, not the newest" "${ok}"

  t="${tmp}/unheld"; _tree "${t}"
  _bump "${t}" 'leaf = { path = "../leaf" }'
  rc=0; _run "${t}" || rc=$?
  ok=0
  [[ "${rc}" -eq 1 ]] && grep -qF 'core/Cargo.lock: leaf 0.1.0 path' "${t}.err" \
    && grep -qF 'app/Cargo.lock: leaf 0.1.0 path' "${t}.err" || ok=1
  _verdict "a version no lockfile holds fails, naming each root and crate" "${ok}"

  # `other` holds 0.2.0, which core's new requirement excludes.
  t="${tmp}/refused"; _tree "${t}"
  _bump "${t}" 'dep = "0.2.1"'
  rc=0; _run "${t}" || rc=$?
  ok=0
  [[ "${rc}" -eq 1 ]] && grep -qF 'core/Cargo.lock: dep 0.2.1 registry+' "${t}.err" || ok=1
  _verdict "a held version the requirement excludes is not forced; the root fails" "${ok}"

  t="${tmp}/empty"; mkdir -p "${t}"; git -C "${t}" init -q
  rc=0; _run "${t}" || rc=$?
  ok=0; [[ "${rc}" -eq 2 ]] || ok=1
  _verdict "a repository with no tracked Cargo.lock is a misconfiguration" "${ok}"

  # --commit against a stub `gh` that answers like the REST API, tracks the
  # paths in ${GH_STUB_TRACKED}, and logs every call; a write's body is kept.
  mkdir -p "${tmp}/bin"
  cat >"${tmp}/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_STUB_LOG}"
case "$*" in
  "api repos/o/r/contents/"*)
    p="${2#repos/o/r/contents/}"
    grep -qxF -- "${p%%\?*}" "${GH_STUB_TRACKED}" && echo file || { echo 'HTTP 404' >&2; exit 1; } ;;
  "api repos/o/r/git/blobs "*)
    n=$(( $(ls "${GH_STUB_LOG}".blob.* 2>/dev/null | wc -l) + 1 ))
    cat >"${GH_STUB_LOG}.blob.${n}"; echo "blob${n}" ;;
  "api repos/o/r/git/commits/head0 "*) echo basetree ;;
  "api repos/o/r/git/trees "*) cat >"${GH_STUB_LOG}.tree"; echo newtree ;;
  "api repos/o/r/git/commits "*) cat >"${GH_STUB_LOG}.commit"; echo newcommit ;;
  "api --method PATCH repos/o/r/git/refs/heads/dependabot/cargo/x "*)
    cat >"${GH_STUB_LOG}.ref"; exit "${GH_STUB_PATCH_RC:-0}" ;;
  *) echo "unexpected call: $*" >&2; exit 9 ;;
esac
STUB
  chmod +x "${tmp}/bin/gh"
  _commit_case() { # <case> <tracked paths> <staged path>...
    local c="${tmp}/commit-$1" tracked="$2" p; shift 2
    mkdir -p "${c}/staged"
    tr ' ' '\n' <<<"${tracked}" >"${c}/tracked"
    for p in "$@"; do mkdir -p "$(dirname "${c}/staged/${p}")"; printf 'lock of %s\n' "${p}" >"${c}/staged/${p}"; done
    : >"${c}/log"
    PATH="${tmp}/bin:${PATH}" GH_STUB_LOG="${c}/log" GH_STUB_TRACKED="${c}/tracked" \
      GITHUB_REPOSITORY=o/r HEAD_SHA=head0 HEAD_REF=dependabot/cargo/x \
      bash "${BASH_SOURCE[0]}" --commit "${c}/staged" >"${c}/out" 2>"${c}/err"
  }

  rc=0; _commit_case ok 'app/Cargo.lock tooling/x/Cargo.lock' app/Cargo.lock tooling/x/Cargo.lock || rc=$?
  t="${tmp}/commit-ok/log"
  ok=0
  [[ "${rc}" -eq 0 ]] \
    && [[ "$(jq -r .content "${t}.blob.1")" == 'lock of app/Cargo.lock' ]] \
    && [[ "$(jq -r .content "${t}.blob.2")" == 'lock of tooling/x/Cargo.lock' ]] \
    && [[ "$(jq -c '[.base_tree, (.tree | map([.path, .mode, .type, .sha]))]' "${t}.tree")" \
          == '["basetree",[["app/Cargo.lock","100644","blob","blob1"],["tooling/x/Cargo.lock","100644","blob","blob2"]]]' ]] \
    && [[ "$(jq -c '[.tree, .parents, has("author"), has("committer")]' "${t}.commit")" == '["newtree",["head0"],false,false]' ]] \
    && jq -r .message "${t}.commit" | head -n 1 | grep -qF '[dependabot skip]' \
    && [[ "$(jq -c . "${t}.ref")" == '{"sha":"newcommit","force":false}' ]] || ok=1
  _verdict "--commit makes one unauthored commit on the head, fast-forward only, with [dependabot skip]" "${ok}"

  rc=0; _commit_case untracked 'app/Cargo.lock' app/Cargo.lock other/Cargo.lock || rc=$?
  ok=0; [[ "${rc}" -eq 1 ]] && ! grep -q '/git/' "${tmp}/commit-untracked/log" || ok=1
  _verdict "--commit writes nothing when a staged Cargo.lock is not tracked at the head" "${ok}"

  rc=0; _commit_case foreign '.github/workflows/ci.yml app/Cargo.lock' .github/workflows/ci.yml app/Cargo.lock || rc=$?
  ok=0; [[ "${rc}" -eq 1 && ! -s "${tmp}/commit-foreign/log" ]] || ok=1
  _verdict "--commit writes nothing when a staged file is not a Cargo.lock" "${ok}"

  rc=0; GH_STUB_PATCH_RC=1 _commit_case moved 'app/Cargo.lock' app/Cargo.lock || rc=$?
  ok=0; [[ "${rc}" -eq 1 ]] && grep -qF 'moved past the re-locked head' "${tmp}/commit-moved/err" || ok=1
  _verdict "--commit fails when the branch no longer fast-forwards" "${ok}"

  (( fails == 0 )) || { echo "sync_cargo_lockfiles.sh --self-test FAILED" >&2; return 1; }
  echo "sync_cargo_lockfiles.sh --self-test passed"
}

case "${1:-}" in
  --self-test) self_test ;;
  --commit) [[ $# -eq 2 ]] || { echo "usage: $0 --commit <dir>" >&2; exit 2; }; commit_relocked "$2" ;;
  '') run_sync ;;
  *) echo "usage: $0 [--commit <dir> | --self-test]" >&2; exit 2 ;;
esac
