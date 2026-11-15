#!/usr/bin/env bash
#
# The release a launch-gate candidate must upgrade cleanly from: picked,
# downloaded, verified, made installable under the candidate, and held to a
# lower versionCode. Run by .github/workflows/launch-gate-android.yml before the
# emulator starts; tooling/e2e/ci/run-launch-gate-android.sh installs what it
# leaves behind.
#
#   launch-gate-previous-apk.sh fetch --out <dir> --previous-of <tag|''>
#   launch-gate-previous-apk.sh fetch --out <dir> --tag <tag>
#
#     --previous-of picks the newest published release older than <tag>: not a
#     draft, not a pre-release, a plain vMAJOR.MINOR.PATCH tag, not yanked for
#     Android (`android` or `all` in scripts/ci/launch_gate_yanked_releases.txt;
#     an `ios` entry leaves it eligible here), and below <tag> by version
#     (<tag> itself and anything later are out; '' — a pull request, which has
#     no tag — rules out nothing by version). "Newest" is by version, not by
#     publication date, so a patch published for an older line is never the
#     one a newer candidate is held to. --tag takes that release as it is (the
#     fixed baseline).
#
#     Into <dir>: app-x86_64-release.apk and its .sha256 sidecar from the
#     release (the sidecar must name that file and match it), app_en.arb from
#     the tag's own tree (the labels THAT build shows), `tag`, `version_code`
#     (aapt2), and `next_build_number`: the BUILD_NUMBER a pull-request
#     candidate is built with so its x86_64 versionCode is exactly one above.
#     Flutter's --split-per-abi sets versionCode = ABI factor * 1000 + build
#     number, x86_64's factor being 4 (flutter_tools FlutterPluginConstants
#     ABI_VERSION: armeabi-v7a 1, arm64-v8a 2, x86_64 4), so the build number is
#     version_code - 4000; a code outside 4001-4999 is refused rather than
#     guessed at.
#
#   launch-gate-previous-apk.sh prepare --candidate <x86_64 apk> --source <dir>
#                                       --context pr|release
#
#     Writes <dir>/install.apk, the APK the upgrade leg installs first.
#       release  both APKs as published: each has exactly one signer and the
#                two certificates are equal, or users could not upgrade (rc 1).
#       pr       the candidate was built and debug-signed in this job, so the
#                release is re-signed with this runner's debug keystore
#                (~/.android/debug.keystore) — the only way a replace install
#                is possible — and the result must carry exactly one signer,
#                the candidate's. A candidate not signed with that keystore is
#                a wiring error (rc 2): only a candidate built in the same job
#                may be paired with a re-signed release.
#     Then the candidate's versionCode must be above the release's (rc 1).
#
#   launch-gate-previous-apk.sh --self-test   stub gh, git, aapt2, apksigner
#
# Needs GH_TOKEN and GITHUB_REPOSITORY (the workflow sets both explicitly),
# python3, sha256sum, and aapt2 + apksigner from the newest
# $ANDROID_HOME/build-tools/*.
#
# Exit: 0 ok, 1 product (certificates differ, versionCode not above),
#       2 an input this cannot vouch for (fail closed).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
readonly REPO_ROOT
readonly APK_NAME='app-x86_64-release.apk'
readonly PACKAGE='com.oblivioustech.haven'
readonly X86_64_ABI_FACTOR=4
readonly ARB_PATH='haven/lib/l10n/app_en.arb'
YANKED="${LAUNCH_GATE_YANKED:-${REPO_ROOT}/scripts/ci/launch_gate_yanked_releases.txt}"
readonly YANKED

die2() { echo "launch-gate-previous-apk: $*" >&2; exit 2; }
die1() { echo "::error::launch-gate-previous-apk: $*" >&2; exit 1; }

build_tool() { # <name> — the newest build-tools' <name>, or rc 2
  local sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}" newest d
  [[ -n "${sdk}" ]] || die2 "ANDROID_HOME is not set; cannot find $1."
  newest="$(for d in "${sdk}"/build-tools/*/; do [[ -d "${d}" ]] && basename "${d}"; done | sort -V | tail -n 1)"
  [[ -n "${newest}" && -x "${sdk}/build-tools/${newest}/$1" ]] \
    || die2 "the newest build-tools ('${newest}') has no executable $1."
  printf '%s\n' "${sdk}/build-tools/${newest}/$1"
}

# resolve_tools — AAPT2 and APKSIGNER, in this shell so a refusal exits it.
resolve_tools() {
  AAPT2="$(build_tool aapt2)" || exit 2
  APKSIGNER="$(build_tool apksigner)" || exit 2
}

version_code() { # <apk> — its versionCode, after checking the package name
  local out line
  out="$("${AAPT2}" dump badging "$1" 2>/dev/null)" || die2 "aapt2 could not read $(basename "$1")."
  line="${out%%$'\n'*}"
  [[ "${line}" =~ ^package:\ name=\'([^\']+)\'\ versionCode=\'([0-9]+)\' ]] \
    || die2 "aapt2 printed no package line for $(basename "$1")."
  [[ "${BASH_REMATCH[1]}" == "${PACKAGE}" ]] \
    || die2 "$(basename "$1") is package ${BASH_REMATCH[1]}, not ${PACKAGE}."
  printf '%s\n' "${BASH_REMATCH[2]}"
}

signer_digests() { # <apk> — its signers' distinct SHA-256 certificate digests, or rc 1
  local out
  out="$("${APKSIGNER}" verify --print-certs "$1" 2>/dev/null)" || return 1
  # Read the digests, not the layout: build-tools 37 turned "Signer #1
  # certificate …" into "V2 Signer: certificate …", one line per scheme.
  sed -nE 's/.*certificate SHA-256 digest: ([0-9a-f]{64})$/\1/p' <<<"${out}" | sort -u
}

# select_tag <release-list-json> <previous-of> — the tag `fetch --previous-of`
# takes, or nothing.
select_tag() {
  python3 -I -c '
import json, re, sys
releases, before, yanked = json.load(open(sys.argv[1])), sys.argv[2], set(sys.argv[3:])
plain = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")
def version(tag):
    m = plain.match(tag)
    return tuple(int(g) for g in m.groups()) if m else None
limit = version(before) if before else None
best = None
for r in releases:
    tag = r.get("tagName", "")
    v = version(tag)
    if v is None or r.get("isDraft") is not False or r.get("isPrerelease") is not False or tag in yanked:
        continue
    if limit is not None and v >= limit:
        continue
    if best is None or v > best[0]:
        best = (v, tag)
if best:
    print(best[1])
' "$@"
}

# yanked_tags — the tags yanked for Android. The list is shared with the iOS
# gate, so every line is checked whatever platform it names.
yanked_tags() {
  local tag platform reason
  [[ -f "${YANKED}" ]] || die2 "the yanked-release list ${YANKED} is missing."
  while read -r tag platform reason; do
    [[ -z "${tag}" || "${tag}" == \#* ]] && continue
    [[ "${tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ && "${platform}" =~ ^(android|ios|all)$ && -n "${reason}" ]] \
      || die2 "${YANKED} has a line that is not '<vMAJOR.MINOR.PATCH> <android|ios|all> <reason>'."
    [[ "${platform}" == ios ]] || printf '%s\n' "${tag}"
  done < "${YANKED}"
}

cmd_fetch() {
  local out="" tag="" previous_of="" mode="" vc line
  while (( $# )); do
    case "$1" in
      --out) out="$2"; shift 2 ;;
      --tag) tag="$2"; mode=tag; shift 2 ;;
      --previous-of) previous_of="$2"; mode=previous; shift 2 ;;
      *) die2 "fetch: unknown argument '$1'." ;;
    esac
  done
  [[ -n "${out}" && -n "${mode}" ]] || die2 "fetch needs --out and one of --tag / --previous-of."
  [[ -n "${GH_TOKEN:-}" && -n "${GITHUB_REPOSITORY:-}" ]] \
    || die2 "GH_TOKEN and GITHUB_REPOSITORY must be set (the workflow passes github.token explicitly)."
  resolve_tools
  mkdir -p "${out}"
  if [[ "${mode}" == previous ]]; then
    [[ -z "${previous_of}" || "${previous_of}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-.*)?$ ]] \
      || die2 "--previous-of '${previous_of}' is not a release tag."
    local -a yanked=()
    yanked_tags > "${out}/yanked.tags"
    mapfile -t yanked < "${out}/yanked.tags"
    rm -f "${out}/yanked.tags"
    gh release list --repo "${GITHUB_REPOSITORY}" --limit 100 \
      --json tagName,isDraft,isPrerelease > "${out}/releases.json" \
      || die2 "gh release list failed."
    tag="$(select_tag "${out}/releases.json" "${previous_of%%-*}" ${yanked[@]+"${yanked[@]}"})" \
      || die2 "the release list did not parse."
    rm -f "${out}/releases.json"
    [[ -n "${tag}" ]] || die2 "no published release qualifies as the one to upgrade from" \
      "(previous of '${previous_of}', yanked: ${yanked[*]:-none})."
    echo "launch-gate-previous-apk: upgrading from ${tag} (newest eligible release before '${previous_of:-this pull request}')."
  fi
  [[ "${tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die2 "'${tag}' is not a plain release tag."
  rm -f "${out:?}/${APK_NAME}" "${out}/${APK_NAME}.sha256"
  gh release download "${tag}" --repo "${GITHUB_REPOSITORY}" --dir "${out}" \
    --pattern "${APK_NAME}" --pattern "${APK_NAME}.sha256" \
    || die2 "gh release download ${tag} failed."
  [[ -s "${out}/${APK_NAME}" && -s "${out}/${APK_NAME}.sha256" ]] \
    || die2 "${tag} does not carry both ${APK_NAME} and its .sha256."
  line="$(cat "${out}/${APK_NAME}.sha256")"
  [[ "${line}" =~ ^[0-9a-f]{64}\ \ ${APK_NAME//./\\.}$ ]] \
    || die2 "${tag}'s ${APK_NAME}.sha256 is not one '<sha256>  ${APK_NAME}' line."
  (cd "${out}" && sha256sum --status -c "${APK_NAME}.sha256") \
    || die2 "${tag}'s ${APK_NAME} does not match its published sha256."
  git -C "${REPO_ROOT}" fetch --quiet --depth=1 origin "+refs/tags/${tag}:refs/tags/${tag}" \
    || die2 "git could not fetch ${tag}."
  git -C "${REPO_ROOT}" show "${tag}:${ARB_PATH}" > "${out}/app_en.arb" \
    || die2 "${tag} has no ${ARB_PATH}."
  vc="$(version_code "${out}/${APK_NAME}")"
  (( vc > X86_64_ABI_FACTOR * 1000 && vc < (X86_64_ABI_FACTOR + 1) * 1000 )) \
    || die2 "${tag}'s x86_64 versionCode ${vc} is not ${X86_64_ABI_FACTOR}xxx, so no build number can be derived from it."
  printf '%s\n' "${tag}" > "${out}/tag"
  printf '%s\n' "${vc}" > "${out}/version_code"
  printf '%s\n' "$(( vc - X86_64_ABI_FACTOR * 1000 + 1 ))" > "${out}/next_build_number"
  echo "launch-gate-previous-apk: ${tag} verified (x86_64 versionCode ${vc})."
}

cmd_prepare() {
  local candidate="" source="" context="" cand_vc prev_vc
  local -a cand_certs=() src_certs=() inst_certs=()
  while (( $# )); do
    case "$1" in
      --candidate) candidate="$2"; shift 2 ;;
      --source) source="$2"; shift 2 ;;
      --context) context="$2"; shift 2 ;;
      *) die2 "prepare: unknown argument '$1'." ;;
    esac
  done
  [[ -f "${candidate}" && -f "${source}/${APK_NAME}" && -f "${source}/version_code" ]] \
    || die2 "prepare needs --candidate <apk> and a --source directory written by fetch."
  [[ "${context}" == pr || "${context}" == release ]] || die2 "--context must be pr or release."
  resolve_tools
  local tag
  tag="$(cat "${source}/tag")"
  mapfile -t cand_certs < <(signer_digests "${candidate}" || echo FAILED)
  [[ "${cand_certs[*]}" != *FAILED* && ${#cand_certs[@]} -eq 1 ]] \
    || die1 "the candidate does not verify with exactly one signer (apksigner verify)."
  mapfile -t src_certs < <(signer_digests "${source}/${APK_NAME}" || echo FAILED)
  [[ "${src_certs[*]}" != *FAILED* && ${#src_certs[@]} -eq 1 ]] \
    || die2 "${tag} does not verify with exactly one signer."
  rm -f "${source}/install.apk"
  if [[ "${context}" == release ]]; then
    [[ "${cand_certs[0]}" == "${src_certs[0]}" ]] \
      || die1 "the candidate is signed with a different certificate from ${tag}: no user of ${tag} could install it as an update."
    cp "${source}/${APK_NAME}" "${source}/install.apk"
  else
    local keystore="${HOME}/.android/debug.keystore"
    [[ -f "${keystore}" ]] || die2 "no debug keystore at ${keystore}; the pull-request candidate must be built in this job."
    "${APKSIGNER}" sign --alignment-preserved true --v4-signing-enabled false \
      --ks "${keystore}" --ks-key-alias androiddebugkey --ks-pass pass:android --key-pass pass:android \
      --out "${source}/install.apk" "${source}/${APK_NAME}" >/dev/null 2>&1 \
      || die2 "apksigner could not re-sign ${tag} with the debug keystore."
    mapfile -t inst_certs < <(signer_digests "${source}/install.apk" || echo FAILED)
    [[ "${inst_certs[*]}" != *FAILED* && ${#inst_certs[@]} -eq 1 ]] \
      || die2 "the re-signed ${tag} does not verify with exactly one signer."
    [[ "${inst_certs[0]}" == "${cand_certs[0]}" ]] \
      || die2 "the candidate is not signed with this job's debug keystore, so a re-signed ${tag} cannot stand in for the published one."
  fi
  cand_vc="$(version_code "${candidate}")"
  prev_vc="$(cat "${source}/version_code")"
  (( cand_vc > prev_vc )) \
    || die1 "the candidate's versionCode ${cand_vc} is not above ${tag}'s ${prev_vc}: Android refuses it as an update."
  printf '%s\n' "${cand_vc}" > "${source}/candidate_version_code"
  echo "launch-gate-previous-apk: ${tag} prepared for the upgrade leg (${context}; versionCode ${prev_vc} -> ${cand_vc})."
}

# ---------------------------------------------------------------------------
# Self-test. Stub gh, git, aapt2 and apksigner record their argv and play the
# shapes this script reads; sha256sum and python3 are real.
# ---------------------------------------------------------------------------
readonly SELF_TEST_CASES=33

self_test() {
  local tmp ran=0 fail=0 rc out
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN
  mkdir -p "${tmp}/bin" "${tmp}/sdk/build-tools/9.0.0" "${tmp}/sdk/build-tools/10.0.0" "${tmp}/home/.android"
  # 10.0.0 is newer than 9.0.0 only by version; 9.0.0's tools always fail.
  printf '#!/usr/bin/env bash\nexit 97\n' > "${tmp}/sdk/build-tools/9.0.0/aapt2"
  printf '#!/usr/bin/env bash\nexit 97\n' > "${tmp}/sdk/build-tools/9.0.0/apksigner"
  : > "${tmp}/home/.android/debug.keystore"
  # gh: `release list` prints $STUB/releases.json; `release download` copies
  # $STUB/assets/<tag>/* into --dir.
  cat > "${tmp}/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB}/gh.calls"
[[ -n "${GH_TOKEN:-}" ]] || exit 4
if [[ "$1 $2" == "release list" ]]; then cat "${STUB}/releases.json"; exit 0; fi
if [[ "$1 $2" == "release download" ]]; then
  tag="$3"; dir=""; shift 3
  while (( $# )); do [[ "$1" == --dir ]] && dir="$2"; shift; done
  [[ -d "${STUB}/assets/${tag}" ]] || exit 1
  cp "${STUB}/assets/${tag}/"* "${dir}/"; exit 0
fi
exit 9
EOF
  # git: `fetch` is recorded; `show <tag>:<path>` prints $STUB/arb/<tag>.
  cat > "${tmp}/bin/git" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB}/git.calls"
[[ "$1" == -C ]] && shift 2
case "$1" in
  fetch) exit 0 ;;
  show) f="${STUB}/arb/${2%%:*}"; [[ -f "${f}" ]] && cat "${f}" && exit 0; exit 128 ;;
esac
exit 9
EOF
  # aapt2: the versionCode is the APK's first line ("vc <n>"). The real tool
# prints hundreds of lines after the package line; so does this, so a reader
# that stops after the first one meets the SIGPIPE it would meet in CI.
  cat > "${tmp}/sdk/build-tools/10.0.0/aapt2" <<'EOF'
#!/usr/bin/env bash
vc="$(sed -n 's/^vc //p' "$3")"; pkg="$(sed -n 's/^pkg //p' "$3")"
printf "package: name='%s' versionCode='%s' versionName='0.1.0' platformBuildVersionName='16'\n" "${pkg:-com.oblivioustech.haven}" "${vc}"
for (( i = 0; i < 20000; i++ )); do echo "uses-permission: name='android.permission.P${i}'"; done
EOF
  # apksigner: `verify` prints one digest line per "signer <hex>" line of the
  # APK; `sign` writes the input with its signers replaced by $STUB/debug.
  cat > "${tmp}/sdk/build-tools/10.0.0/apksigner" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB}/apksigner.calls"
if [[ "$1" == verify ]]; then
  apk="${!#}"; grep -q '^unsigned' "${apk}" && exit 1
  n=0; while read -r w hex; do [[ "${w}" == signer ]] || continue; n=$((n+1))
    if [[ "${STUB_APKSIGNER_FORMAT:-}" == v37 ]]; then
      for scheme in V2 V3; do echo "${scheme} Signer: certificate DN: CN=x"; echo "${scheme} Signer: certificate SHA-256 digest: ${hex}"; done
    else
      echo "Signer #${n} certificate DN: CN=x"; echo "Signer #${n} certificate SHA-256 digest: ${hex}"
    fi; done < "${apk}"
  exit 0
fi
if [[ "$1" == sign ]]; then
  out=""; while (( $# )); do [[ "$1" == --out ]] && out="$2"; last="$1"; shift; done
  { grep -v '^signer' "${last}"; cat "${STUB}/debug"; } > "${out}"; exit 0
fi
exit 9
EOF
  chmod +x "${tmp}/bin/"* "${tmp}"/sdk/build-tools/*/*
  local rel='a1' dbg='b2'
  rel="$(printf 'a%.0s' {1..64})"; dbg="$(printf 'b%.0s' {1..64})"
  _apk() { # _apk <path> <vc> <signer-hex>...
    local p="$1" v="$2"; shift 2
    { echo "vc ${v}"; local h; for h in "$@"; do echo "signer ${h}"; done; } > "${p}"
  }
  _release() { # _release <tag> <vc> — a published release whose sidecar matches
    mkdir -p "${tmp}/stub/assets/$1"
    _apk "${tmp}/stub/assets/$1/${APK_NAME}" "$2" "${rel}"
    (cd "${tmp}/stub/assets/$1" && sha256sum "${APK_NAME}" > "${APK_NAME}.sha256")
    printf '{"onboardingWelcomeCta": "Get Started %s"}\n' "$1" > "${tmp}/stub/arb/$1"
  }
  _reset() {
    rm -rf "${tmp}/stub" "${tmp}/out"; mkdir -p "${tmp}/stub/arb" "${tmp}/out"
    cat > "${tmp}/stub/releases.json" <<'EOF'
[{"tagName":"v0.1.15","isDraft":true,"isPrerelease":false},
 {"tagName":"v0.1.15-rc.1","isDraft":false,"isPrerelease":true},
 {"tagName":"v0.1.14","isDraft":false,"isPrerelease":false},
 {"tagName":"v0.1.13","isDraft":false,"isPrerelease":false},
 {"tagName":"v0.1.12","isDraft":false,"isPrerelease":false},
 {"tagName":"v0.1.9","isDraft":false,"isPrerelease":false},
 {"tagName":"nightly","isDraft":false,"isPrerelease":false}]
EOF
    printf 'v0.1.14 android crashes at start\n' > "${tmp}/yanked"
    _release v0.1.13 4020; _release v0.1.12 4019; _release v0.1.9 4009; _release v0.1.14 4021
    printf 'signer %s\n' "${dbg}" > "${tmp}/stub/debug"
  }
  _run() { # _run <label> <want-rc> <cmd>... — runs this script in a child
    local label="$1" want="$2"; shift 2
    ran=$(( ran + 1 )); rc=0
    out="$(env PATH="${tmp}/bin:${PATH}" STUB="${tmp}/stub" HOME="${tmp}/home" \
      ANDROID_HOME="${tmp}/sdk" ANDROID_SDK_ROOT='' GH_TOKEN="${GH_TOKEN_STUB-x}" \
      GITHUB_REPOSITORY=owner/repo LAUNCH_GATE_YANKED="${tmp}/yanked" \
      bash "${BASH_SOURCE[0]}" "$@" 2>&1)" || rc=$?
    if (( rc == want )); then echo "  PASS ${label}"; else
      echo "  FAIL ${label} (want rc ${want}, got ${rc}): ${out}" >&2; fail=1; fi
  }
  _expect() { # _expect <label> <condition-rc>
    ran=$(( ran + 1 ))
    if (( $2 == 0 )); then echo "  PASS $1"; else echo "  FAIL $1" >&2; fail=1; fi
  }

  echo "launch-gate-previous-apk.sh --self-test"
  # (1) A pull request: drafts, pre-releases, non-version tags and the yanked
  #     v0.1.14 are out, and v0.1.13 beats v0.1.9 by version, not by text.
  _reset; _run "a pull request upgrades from the newest eligible release" 0 fetch --out "${tmp}/out" --previous-of ''
  _expect "…which is v0.1.13, with its own ARB, versionCode and next build number" \
    "$( ([[ "$(cat "${tmp}/out/tag")" == v0.1.13 && "$(cat "${tmp}/out/version_code")" == 4020 \
       && "$(cat "${tmp}/out/next_build_number")" == 21 \
       && "$(cat "${tmp}/out/app_en.arb")" == '{"onboardingWelcomeCta": "Get Started v0.1.13"}' ]]) && echo 0 || echo 1 )"
  # (3) The ARB comes from the tag itself, through the amended refspec.
  _expect "the tag is fetched with the forced tag refspec, then read with git show" \
    "$( (grep -qxF -- "-C ${REPO_ROOT} fetch --quiet --depth=1 origin +refs/tags/v0.1.13:refs/tags/v0.1.13" "${tmp}/stub/git.calls" \
       && grep -qxF -- "-C ${REPO_ROOT} show v0.1.13:${ARB_PATH}" "${tmp}/stub/git.calls") && echo 0 || echo 1 )"
  # (4) The download asks for exactly the x86_64 APK and its sidecar.
  _expect "the download names the x86_64 APK and its sidecar" \
    "$( (grep -qxF -- "release download v0.1.13 --repo owner/repo --dir ${tmp}/out --pattern ${APK_NAME} --pattern ${APK_NAME}.sha256" "${tmp}/stub/gh.calls") && echo 0 || echo 1 )"
  # (5) A release candidate: its own tag and anything later are out.
  _reset; _run "a release candidate upgrades from the release below its own tag" 0 fetch --out "${tmp}/out" --previous-of v0.1.13
  _expect "…which is v0.1.12" "$( ([[ "$(cat "${tmp}/out/tag")" == v0.1.12 ]]) && echo 0 || echo 1 )"
  # (7) A candidate's pre-release suffix compares by its version.
  _reset; _run "a pre-release candidate tag compares by its version" 0 fetch --out "${tmp}/out" --previous-of v0.1.13-rc.2
  # (8) Nothing eligible.
  _reset; _run "no eligible release is rc 2" 2 fetch --out "${tmp}/out" --previous-of v0.1.9
  # (9) A yanked list line without a reason, or in the old two-field shape.
  _reset; printf 'v0.1.14 android\n' > "${tmp}/yanked"
  _run "a yanked line without a reason is rc 2" 2 fetch --out "${tmp}/out" --previous-of ''
  _reset; printf 'v0.1.14 crashes at start\n' > "${tmp}/yanked"
  _run "a yanked line without a platform is rc 2" 2 fetch --out "${tmp}/out" --previous-of ''
  # A yank for iOS alone leaves the release eligible here; one for all does not.
  _reset; printf 'v0.1.14 ios the simulator build is broken\n' > "${tmp}/yanked"
  _run "an iOS-only yank" 0 fetch --out "${tmp}/out" --previous-of ''
  _expect "…leaves v0.1.14 the Android upgrade source" "$( ([[ "$(cat "${tmp}/out/tag")" == v0.1.14 ]]) && echo 0 || echo 1 )"
  _reset; printf 'v0.1.14 all broken everywhere\n' > "${tmp}/yanked"
  _run "a yank for all platforms" 0 fetch --out "${tmp}/out" --previous-of ''
  _expect "…skips v0.1.14 for Android too" "$( ([[ "$(cat "${tmp}/out/tag")" == v0.1.13 ]]) && echo 0 || echo 1 )"
  # One malformed line anywhere fails the run, even a line for the other platform.
  _reset; printf 'v0.1.14 android crashes at start\nv0.1.12 watchos why\n' > "${tmp}/yanked"
  _run "a line naming no known platform is rc 2" 2 fetch --out "${tmp}/out" --previous-of ''
  # (16) The yanked list decides: without it v0.1.14 would be chosen.
  _reset; printf '# none\n' > "${tmp}/yanked"
  _run "an empty yanked list lets v0.1.14 be chosen" 0 fetch --out "${tmp}/out" --previous-of ''
  _expect "…proving the list is what excluded it" "$( ([[ "$(cat "${tmp}/out/tag")" == v0.1.14 ]]) && echo 0 || echo 1 )"
  # (18) A sidecar that does not match.
  _reset; printf 'tampered\n' >> "${tmp}/stub/assets/v0.1.13/${APK_NAME}"
  _run "an APK that does not match its sidecar is rc 2" 2 fetch --out "${tmp}/out" --previous-of ''
  # (19) A sidecar naming another file.
  _reset; sed -i 's/app-x86_64/app-arm64-v8a/' "${tmp}/stub/assets/v0.1.13/${APK_NAME}.sha256"
  _run "a sidecar naming another file is rc 2" 2 fetch --out "${tmp}/out" --previous-of ''
  # (20) A release without the sidecar.
  _reset; rm "${tmp}/stub/assets/v0.1.13/${APK_NAME}.sha256"
  _run "a release without the sidecar is rc 2" 2 fetch --out "${tmp}/out" --previous-of ''
  # (21) The fixed baseline: no listing, that tag only.
  _reset; _run "--tag fetches that release without listing" 0 fetch --out "${tmp}/out" --tag v0.1.12
  _expect "…and never lists releases" "$(grep -q '^release list' "${tmp}/stub/gh.calls" && echo 1 || echo 0)"
  # (23) A versionCode outside the x86_64 range.
  _reset; _apk "${tmp}/stub/assets/v0.1.13/${APK_NAME}" 2020 "${rel}"
  (cd "${tmp}/stub/assets/v0.1.13" && sha256sum "${APK_NAME}" > "${APK_NAME}.sha256")
  _run "a non-x86_64 versionCode is rc 2" 2 fetch --out "${tmp}/out" --previous-of ''
  # (24) No token.
  _reset; GH_TOKEN_STUB='' _run "no GH_TOKEN is rc 2" 2 fetch --out "${tmp}/out" --previous-of ''

  # prepare
  _reset; _run "fetch for prepare" 0 fetch --out "${tmp}/out" --previous-of ''
  ran=$(( ran - 1 ))
  # (25) Release context: equal certificates, a higher versionCode.
  _apk "${tmp}/cand.apk" 4022 "${rel}"
  _run "release: equal certificates and a higher versionCode pass" 0 prepare --candidate "${tmp}/cand.apk" --source "${tmp}/out" --context release
  _expect "…and install.apk is the published APK, byte for byte" "$( (cmp -s "${tmp}/out/install.apk" "${tmp}/out/${APK_NAME}") && echo 0 || echo 1 )"
  # (27) build-tools 37's layout, which prints each certificate once per scheme.
  export STUB_APKSIGNER_FORMAT=v37
  _run "release: build-tools 37's per-scheme lines are still one signer" 0 prepare --candidate "${tmp}/cand.apk" --source "${tmp}/out" --context release
  # (28) …and two distinct certificates in that layout are still refused.
  _apk "${tmp}/cand.apk" 4022 "${rel}" "${dbg}"
  _run "release: two certificates in build-tools 37's layout are rc 1" 1 prepare --candidate "${tmp}/cand.apk" --source "${tmp}/out" --context release
  unset STUB_APKSIGNER_FORMAT
  # (29) Release context: a different certificate is a product failure.
  _apk "${tmp}/cand.apk" 4022 "${dbg}"
  _run "release: a different certificate is rc 1" 1 prepare --candidate "${tmp}/cand.apk" --source "${tmp}/out" --context release
  # (30) A versionCode that is not above the previous one.
  _apk "${tmp}/cand.apk" 4020 "${rel}"
  _run "an equal versionCode is rc 1" 1 prepare --candidate "${tmp}/cand.apk" --source "${tmp}/out" --context release
  # (31) PR context: re-signed with the amended flags, one signer, the candidate's.
  _apk "${tmp}/cand.apk" 4021 "${dbg}"
  _run "pr: the release is re-signed to the candidate's debug certificate" 0 prepare --candidate "${tmp}/cand.apk" --source "${tmp}/out" --context pr
  _expect "…with exactly the amended apksigner flags" \
    "$( (grep -qxF -- "sign --alignment-preserved true --v4-signing-enabled false --ks ${tmp}/home/.android/debug.keystore --ks-key-alias androiddebugkey --ks-pass pass:android --key-pass pass:android --out ${tmp}/out/install.apk ${tmp}/out/${APK_NAME}" "${tmp}/stub/apksigner.calls") && echo 0 || echo 1 )"
  # (33) PR context: a candidate that is not debug-signed in this job.
  _apk "${tmp}/cand.apk" 4021 "${rel}"
  _run "pr: a candidate not signed with this job's debug keystore is rc 2" 2 prepare --candidate "${tmp}/cand.apk" --source "${tmp}/out" --context pr

  if (( ran != SELF_TEST_CASES )); then
    echo "SELF-TEST FAIL: ran ${ran} case(s), expected ${SELF_TEST_CASES}" >&2
    fail=1
  fi
  if (( fail )); then
    echo "launch-gate-previous-apk.sh --self-test: FAILED" >&2
    return 1
  fi
  echo "launch-gate-previous-apk.sh --self-test: all ${ran} cases passed"
}

case "${1:-}" in
  fetch) shift; cmd_fetch "$@" ;;
  prepare) shift; cmd_prepare "$@" ;;
  --self-test) self_test ;;
  *) die2 "usage: $0 fetch --out <dir> (--previous-of <tag|''> | --tag <tag>) | prepare --candidate <apk> --source <dir> --context pr|release | --self-test" ;;
esac
