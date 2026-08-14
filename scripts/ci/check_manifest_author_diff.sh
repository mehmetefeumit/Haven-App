#!/usr/bin/env bash
# CI guard: the weekly Manifest Author may propose changes to the privacy
# invariant manifest and the prose filed beside it, and to nothing else.
#
# ## Why this exists
#
# `privacy-manifest-author.yml` lets a model edit the working tree and then
# opens a pull request from the result. That is a write path into the
# repository, and the only thing standing between it and an arbitrary change is
# what the model was ASKED to do. A prompt is not an enforcement mechanism: it
# is advice to a system that is allowed to be wrong, and it is also the part of
# the job an attacker can influence, because the model reads the tree — ARB
# values, `@description`s, SECURITY.md prose — and every one of those is text a
# pull request can change. "Edit only the manifest" written in a prompt is
# exactly as strong as "please".
#
# So the instruction is repeated as a check. After the model finishes, the whole
# working tree is compared against HEAD; if ANY path outside the allowed set
# moved, the job fails and no pull request is opened. The failure direction is
# deliberate — an out-of-bounds edit is not filtered out and proposed anyway,
# because a model that edited something it was told not to touch has also, by
# the same token, stopped being evidence for the edits it WAS asked to make.
#
# Untracked files count. The realistic way this fires is not a malicious rewrite
# of `manager.rs`; it is a scratch file — notes, a draft, a `.bak` — left in the
# workspace and swept into the commit. `git status` sees those, `git diff` does
# not, which is why this reads status and not diff.
#
# ## The bound, exactly
#
# `ALLOWED_RE` below is the whole of it: `docs/privacy/privacy_invariants.json`,
# and any `.md` sitting DIRECTLY in `docs/privacy/`. Not a nested subdirectory,
# not `NOTES.md.bak`, not the same directory with another extension, not
# `haven/docs/privacy/` — each of those has a fixture, because each is a way the
# regex could be loosened by one character and still look right.
#
# The workflow's prompt is deliberately NARROWER than this check: it tells the
# model to write two paths, the manifest and `.manifest-author/summary.md`. That
# second path is NOT in the allowed set and is not meant to be — the summary
# becomes a pull request body, not a file the repository keeps — and it clears
# this check only because `privacy-manifest-author.yml` reads it out to
# `RUNNER_TEMP` and `rm -rf`s the scratch directory in the step immediately
# before this guard runs. That cleanup is load-bearing: remove it, or make it
# conditional, and every run that authored anything fails the bound. The fix if
# that ever happens is to restore the cleanup, not to widen the set here.
#
# Prompt narrower than check is the intended direction and the only safe one: a
# prompt is advice to a system allowed to be wrong, and the check is what a
# wrong answer runs into. They may differ, but only that way round, and only in
# writing.
#
# ## What it cannot do
#
# It bounds the SHAPE of the proposal, never its CONTENT: a manifest edit that
# is wrong, or that quietly drops an invariant, is in bounds here. That is the
# deterministic gate's job — `check_privacy_invariants.sh`'s ratchet fails on a
# status downgrade, a deleted invariant, a removed disclosure key or an
# assertion that lost its last proof, which is why an authored proposal is
# expected to be purely additive and why the author workflow runs that gate
# before it opens anything.
#
# Usage:
#   check_manifest_author_diff.sh [--repo-root <dir>]
#   check_manifest_author_diff.sh --self-test
#
# Exit codes:
#   0  every changed path is inside the allowed set (including "nothing
#      changed" — a week with nothing to propose is a normal outcome)
#   1  a path outside the allowed set changed; the proposal must not be opened
#   2  this guard is broken or was misused (not a git work tree, no git, bad
#      arguments) — fail closed: a bounding check that cannot read the change
#      set has not bounded anything

set -Eeuo pipefail

SCRIPT_NAME="check_manifest_author_diff"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# The manifest, plus prose that documents it, and nothing else. Every piece of
# this is load-bearing and every piece has a fixture, because each is one
# character away from a bound that still reads correctly:
#
#   `^`   without it, `haven/docs/privacy/notes.md` — or any path with those
#         segments buried in it — is in bounds, since a bash `=~` match is a
#         SEARCH, not a whole-string test.
#   `$`   without it, `docs/privacy/NOTES.md.bak` is in bounds: the class
#         backtracks, `\.md` matches mid-path, and the very `.bak` this guard's
#         header names as its motivating case sails through.
#   no `/` in the filename class, so `docs/privacy/anything/else.md` is out of
#         bounds — a bash glob would match across the separator and quietly
#         widen this to a whole subtree.
ALLOWED_RE='^docs/privacy/(privacy_invariants\.json|[A-Za-z0-9_][A-Za-z0-9_.-]*\.md)$'

log() { printf '\033[1;34m[%s]\033[0m %s\n' "${SCRIPT_NAME}" "$*"; }
fail_msg() { printf '\033[1;31m[%s] FAIL:\033[0m %s\n' "${SCRIPT_NAME}" "$*" >&2; }
misconfig() { printf '\033[1;31m[%s] ERROR:\033[0m %s\n' "${SCRIPT_NAME}" "$*" >&2; exit 2; }

# ---------------------------------------------------------------------------
# check_bounded <repo-root>
#
# `--no-renames` keeps every record a single path, so the NUL-delimited stream
# needs no rename special-casing.
#
# `-uall` lists untracked files individually rather than collapsing a new
# directory to its name. Note what that is and is not for. It is NOT a scratch
# file "hiding behind its parent": a collapsed record is `scratch/`, trailing
# slash and all, which this regex rejects just as firmly as `scratch/notes.md` —
# the verdict is the same either way, and the fixture for a buried scratch file
# below pins that rejection rather than this flag. What `-uall` actually buys is
# the other direction. Under `-unormal` a run that creates `docs/privacy/` where
# no such directory was tracked reports one record, `docs/`, and this guard
# rejects a proposal that was entirely in bounds — a false FAIL on the exact
# shape the job exists to produce. Its fixture is the one that creates the
# directory wholesale. The second, smaller benefit is legibility: an
# out-of-bounds report names the file rather than some ancestor of it.
# ---------------------------------------------------------------------------
check_bounded() {
  local root="$1" fail=0 changed=0 allowed=0

  git -C "${root}" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || misconfig "'${root}' is not a git work tree — the change set cannot be read, so nothing has been bounded."

  # Via a file, not a variable: `git status -z` is NUL-delimited (the only form
  # that survives a path containing a space or a quote unmangled), and bash
  # DISCARDS NUL bytes in a command substitution — capturing it would silently
  # collapse every record into one unparseable line, i.e. a guard that reports
  # clean over any change set at all.
  local statusfile
  statusfile="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '${statusfile}'" RETURN
  git -C "${root}" status --porcelain=v1 -uall --no-renames -z > "${statusfile}" \
    || misconfig "'git status' failed in '${root}' — the change set could not be read."

  local record path
  while IFS= read -r -d '' record; do
    # Records are `XY<space><path>`; the status codes are fixed-width.
    path="${record:3}"
    [[ -n "${path}" ]] || continue
    changed=$(( changed + 1 ))
    if [[ "${path}" =~ ${ALLOWED_RE} ]]; then
      allowed=$(( allowed + 1 ))
      echo "  in bounds: ${path} (${record:0:2})"
    else
      fail_msg "out of bounds: ${path} (${record:0:2})"
      fail=1
    fi
  done < "${statusfile}"

  if (( fail )); then
    return 1
  fi
  if (( changed == 0 )); then
    log "nothing changed — there is no proposal to bound this week."
  else
    log "all ${allowed} changed path(s) are inside the manifest bound."
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Self-test — hermetic git repositories under a mktemp dir.
#
# (4) and (5) are the fixtures this guard exists for: an edit to a source file
# the manifest merely CITES, and an untracked scratch file left in the
# workspace. (7) pins the separator behaviour that a bash glob would have got
# wrong, and (9) proves an in-bounds edit does not launder an out-of-bounds one
# alongside it.
#
# (11)-(14) exist because the three levers this guard's verdict actually hangs
# on — the two regex anchors and `-uall` — were each verified to survive being
# deleted. A lever nothing pins is a lever that has already been removed; it
# just has not happened yet.
# ---------------------------------------------------------------------------
self_test() {
  local tmp fails=0 checked=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  command -v git >/dev/null 2>&1 || misconfig "git is required to run the self-test"

  _fixture() { # _fixture <name> -> prints the path to a fresh committed repo
    local name="$1"
    local repo="${tmp}/${name}"
    mkdir -p "${repo}/docs/privacy" "${repo}/haven-core/src"
    printf '{"schema_version":1,"invariants":[]}\n' > "${repo}/docs/privacy/privacy_invariants.json"
    printf '# Manifest notes\n' > "${repo}/docs/privacy/NOTES.md"
    printf 'pub fn build_group_event() {}\n' > "${repo}/haven-core/src/manager.rs"
    git -C "${repo}" -c init.defaultBranch=main init -q
    git -C "${repo}" add -A
    git -C "${repo}" \
      -c user.email=ci@example.invalid -c user.name=ci -c commit.gpgsign=false \
      commit -q -m base
    printf '%s' "${repo}"
  }

  _case() { # _case <label> <expect-rc> <repo>
    local label="$1" want="$2" repo="$3" got=0
    checked=$(( checked + 1 ))
    ( check_bounded "${repo}" ) >/dev/null 2>&1 || got=$?
    if [[ "${got}" -eq "${want}" ]]; then
      printf '  \033[1;32mPASS\033[0m %s (rc=%d)\n' "${label}" "${got}"
    else
      printf '  \033[1;31mFAIL\033[0m %s (want rc=%d, got rc=%d)\n' "${label}" "${want}" "${got}" >&2
      fails=1
    fi
  }

  log "self-test: manifest-author diff bounding"

  local r

  # (1) A week with nothing to propose is not a failure.
  r="$(_fixture clean)"
  _case "an unchanged tree is in bounds" 0 "${r}"

  # (2) The intended proposal.
  r="$(_fixture manifest_only)"
  printf '{"schema_version":1,"invariants":[{"id":"INV-A"}]}\n' > "${r}/docs/privacy/privacy_invariants.json"
  _case "editing the manifest alone is in bounds" 0 "${r}"

  # (3) The manifest's prose companion, including one that did not exist before.
  r="$(_fixture doc_only)"
  printf '# Manifest notes\n\nDerived 2026-08-13.\n' > "${r}/docs/privacy/NOTES.md"
  printf '# New companion\n' > "${r}/docs/privacy/DERIVATION.md"
  _case "editing and adding manifest documentation is in bounds" 0 "${r}"

  # (4) THE CRITICAL FIXTURE. The manifest CITES source symbols, so "fix the
  #     manifest" and "fix the code so the manifest is right" are one keystroke
  #     apart for a model. Only the first is in bounds.
  r="$(_fixture source_edit)"
  printf 'pub fn build_group_event() { /* edited */ }\n' > "${r}/haven-core/src/manager.rs"
  _case "editing cited source is OUT of bounds" 1 "${r}"

  # (5) THE OTHER CRITICAL FIXTURE, and the likelier one: a scratch file left
  #     behind. `git diff` cannot see it; `git status -uall` can.
  r="$(_fixture scratch_file)"
  printf 'draft notes\n' > "${r}/manifest-draft.md"
  _case "an untracked scratch file is OUT of bounds" 1 "${r}"

  # (6) Deletion is a change like any other — and the most damaging shape.
  r="$(_fixture deletion)"
  rm "${r}/haven-core/src/manager.rs"
  _case "deleting a file outside the bound is OUT of bounds" 1 "${r}"

  # (7) A bash glob (`docs/privacy/*.md`) matches across `/`, which would have
  #     widened the bound to an entire subtree. The regex must not.
  r="$(_fixture nested_doc)"
  mkdir -p "${r}/docs/privacy/sub"
  printf '# nested\n' > "${r}/docs/privacy/sub/x.md"
  _case "a nested docs/privacy subdirectory is OUT of bounds" 1 "${r}"

  # (8) Same directory, wrong extension: the bound is the manifest and its
  #     prose, not "anything filed under docs/privacy".
  r="$(_fixture wrong_extension)"
  printf 'x\n' > "${r}/docs/privacy/scratch.json"
  _case "an unrelated file in docs/privacy is OUT of bounds" 1 "${r}"

  # (9) An in-bounds edit must not launder an out-of-bounds one beside it.
  r="$(_fixture mixed)"
  printf '{"schema_version":1,"invariants":[{"id":"INV-A"}]}\n' > "${r}/docs/privacy/privacy_invariants.json"
  printf 'pub fn build_group_event() { /* edited */ }\n' > "${r}/haven-core/src/manager.rs"
  _case "a legitimate manifest edit does not excuse a source edit" 1 "${r}"

  # (10) Fail closed: with no change set to read, nothing has been bounded.
  mkdir -p "${tmp}/not_a_repo"
  _case "a non-git directory is a MISCONFIGURATION, not a pass" 2 "${tmp}/not_a_repo"

  # (11) THE `^` ANCHOR. `=~` searches rather than matching whole strings, so
  #      without the anchor these same segments buried anywhere in a path are
  #      in bounds — and `haven/docs/` is a real directory in this repository.
  r="$(_fixture unanchored_prefix)"
  mkdir -p "${r}/haven/docs/privacy"
  printf '# notes\n' > "${r}/haven/docs/privacy/notes.md"
  _case "docs/privacy nested under another directory is OUT of bounds" 1 "${r}"

  # (12) THE `$` ANCHOR, and the `.bak` this guard's header names as the case
  #      it prevents. Without the anchor the filename class backtracks, `\.md`
  #      matches mid-path, and the suffix is simply ignored.
  r="$(_fixture md_suffixed)"
  printf '# Manifest notes\n' > "${r}/docs/privacy/NOTES.md.bak"
  _case "a .md.bak beside the manifest is OUT of bounds" 1 "${r}"

  # (13) `-uall`, the direction it actually protects: a proposal that creates
  #      docs/privacy/ where the directory was not tracked. `-unormal` reports
  #      that as one collapsed `docs/` record and rejects a proposal that is
  #      entirely in bounds. Deliberately built WITHOUT docs/privacy in HEAD.
  r="${tmp}/created_dir"
  mkdir -p "${r}/haven-core/src"
  printf 'pub fn build_group_event() {}\n' > "${r}/haven-core/src/manager.rs"
  git -C "${r}" -c init.defaultBranch=main init -q
  git -C "${r}" add -A
  git -C "${r}" \
    -c user.email=ci@example.invalid -c user.name=ci -c commit.gpgsign=false \
    commit -q -m base
  mkdir -p "${r}/docs/privacy"
  printf '{"schema_version":1,"invariants":[]}\n' > "${r}/docs/privacy/privacy_invariants.json"
  printf '# Manifest notes\n' > "${r}/docs/privacy/NOTES.md"
  _case "creating docs/privacy wholesale is IN bounds" 0 "${r}"

  # (14) The buried scratch file. This one is verdict-identical under
  #      `-unormal` (the collapsed `scratch/` record is rejected too) and is
  #      here for what it does pin: a draft two levels down is no more in
  #      bounds than one at the root, and `-uall` is what makes the report name
  #      the file instead of an ancestor.
  r="$(_fixture buried_scratch)"
  mkdir -p "${r}/scratch/drafts"
  printf 'draft notes\n' > "${r}/scratch/drafts/manifest.md"
  _case "a scratch file buried in a new subdirectory is OUT of bounds" 1 "${r}"

  if (( fails )); then
    fail_msg "self-test failed — this guard cannot be trusted until it is fixed"
    exit 2
  fi
  log "OK: self-test passed (${checked} fixtures)."
}

# ---------------------------------------------------------------------------
main() {
  if [[ "${1:-}" == "--self-test" ]]; then
    self_test
    exit 0
  fi

  local root="${REPO_ROOT}"
  while (( $# > 0 )); do
    case "$1" in
      --repo-root) root="${2:-}"; shift 2 ;;
      *) misconfig "unknown argument '$1' — usage: ${SCRIPT_NAME}.sh [--repo-root <dir>] | --self-test" ;;
    esac
  done
  [[ -n "${root}" && -d "${root}" ]] || misconfig "--repo-root '${root}' is not a directory"

  if check_bounded "${root}"; then
    log "OK: the proposed change touches nothing outside the privacy invariant manifest."
    exit 0
  fi
  fail_msg "the proposed change reaches outside the privacy invariant manifest (see above). \
The Manifest Author may change docs/privacy/privacy_invariants.json and its accompanying .md \
documentation, and nothing else — so no pull request is opened. A model that edited what it was \
told to leave alone has also stopped being evidence for the edits it WAS asked to make, which is \
why the out-of-bounds paths are not simply filtered out and the rest proposed anyway."
  exit 1
}

main "$@"
