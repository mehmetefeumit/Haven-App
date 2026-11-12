#!/usr/bin/env bash
# Release-sign the Android APKs, in a job that builds nothing.
#
# The build job compiles and runs hundreds of third-party packages (pub,
# Gradle, cargo build scripts), and any one of them could read a keystore on
# the same runner. So that job holds no signing secret and leaves its APKs on
# Gradle's debug fallback, and this script, alone in release-build.yml's
# android-sign job, replaces that signature with the release key using the
# runner's own Android SDK build-tools.
#
# What apksigner does to an already-signed input (AOSP platform/tools/apksig,
# read at the GrapheneOS mirror, commit 54c5f4f): with
# --other-signers-signatures-preserved left false,
# DefaultApkSignerEngine.inputApkSigningBlock keeps nothing of the input's APK
# Signing Block, so the debug v2/v3 signers are dropped and the block rebuilt;
# getInputJarEntryOutputPolicy skips the input's v1 files (MANIFEST.MF's main
# section is carried, *.SF / *.RSA / *.DSA / *.EC / SIG-* are not); and
# ApkSigner re-aligns every uncompressed .so to --lib-page-alignment (default
# Constants.LIBRARY_PAGE_ALIGNMENT_BYTES = 16384; passed explicitly so an older
# build-tools cannot fall back to 4 KB). None of that is taken on trust: every
# APK must then verify under APK Signature Scheme v2 or v3 with exactly one
# signer, whose certificate is the keystore's AND the one README.md publishes
# (a different key would lock every installed copy out of the update), and
# must pass `zipalign -c -P 16 4`.
#
# The expected digest is the SHA-256 of the keystore certificate's DER, which
# is what apksigner prints (ApkSignerTool.printCertificate digests
# cert.getEncoded()) and what keytool -list -v shows as "SHA256", without
# parsing keytool's localisable text. Passwords reach the tools only by
# environment name (`--ks-pass env:`, `-storepass:env`), never in argv.
#
# Usage:
#   sign_android_release.sh <in-dir> <out-dir>
#     env: ANDROID_KEYSTORE_BASE64, ANDROID_KEYSTORE_PASSWORD,
#          ANDROID_KEY_ALIAS, ANDROID_KEY_PASSWORD, ANDROID_HOME, RUNNER_TEMP
#   sign_android_release.sh --self-test
#
# Exit codes:
#   0  every APK signed and verified (or the self-test passed)
#   1  an APK failed a check, or the keystore is not the published key
#   2  misconfiguration: a missing secret, tool, input or README fingerprint

set -euo pipefail

REPO_ROOT="${REPO_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
readonly KEYSTORE_NAME='haven-release.jks'
readonly LIB_PAGE_ALIGNMENT=16384
# How many fixtures the self-test runs. Pinned, because a fixture that stops
# running is the one way a deleted check reports success.
readonly SELF_TEST_FIXTURES=15

log() {
  printf '\033[1;34m[sign_android_release]\033[0m %s\n' "$*"
}

fail() { # <rc> <message>
  printf '\033[1;31m[sign_android_release] FAIL:\033[0m %s\n' "$2" >&2
  return "$1"
}

norm_digest() { # <digest>: lower-case hex, no colons
  tr -d ': \n' <<<"$1" | tr 'A-F' 'a-f'
}

# The fingerprint README.md's "Signing Certificate SHA-256" section publishes.
readme_fingerprint() { # <README.md>
  local fp
  fp="$(awk '/^### Signing Certificate SHA-256/ { s = 1; next } s && /^#/ { exit } s' "$1" \
    | grep -oE '^([0-9A-Fa-f]{2}:){31}[0-9A-Fa-f]{2}$' || true)"
  [[ -n "${fp}" && "${fp}" != *$'\n'* ]] || return 2
  norm_digest "${fp}"
}

# The newest build-tools that has both apksigner and zipalign.
pick_build_tools() { # <android sdk>
  local d best=''
  while IFS= read -r d; do
    [[ -x "${d}apksigner" && -x "${d}zipalign" ]] && best="${d%/}"
  done < <(printf '%s\n' "$1"/build-tools/*/ | sort -V)
  [[ -n "${best}" ]] || return 2
  printf '%s\n' "${best}"
}

# Distinct signer-certificate digests in `apksigner verify --verbose
# --print-certs` output. The line is "<name> certificate SHA-256 digest: <hex>",
# where <name> is "Signer #1" in older build-tools and "V3.0 Signer:" (or
# "V2 Signer:", "V3.1 Signer: (...)") in newer ones; a source stamp or a
# lineage entry is not a signer of this APK.
signer_digests() { # <verify output>
  sed -nE '/^Source Stamp|in lineage/d; s/^.*Signer.* certificate SHA-256 digest: ([0-9a-fA-F]{64})$/\1/p' "$1" \
    | tr 'A-F' 'a-f' | sort -u
}

judge_verify() { # <verify output> <expected digest>
  local got
  grep -qx 'Verifies' "$1" || { echo "it does not verify"; return 1; }
  grep -qE '^Verified using v[23] scheme \(APK Signature Scheme v[23]\): true$' "$1" \
    || { echo "neither APK Signature Scheme v2 nor v3 verified it"; return 1; }
  got="$(signer_digests "$1")"
  [[ "${got}" == "$2" ]] || { echo "its signer certificate is ${got//$'\n'/ + } (expected $2)"; return 1; }
}

sign_all() { # <in-dir> <out-dir>
  local in="$1" out="$2" var bt ks want pinned apk name n=0 why
  for var in ANDROID_KEYSTORE_BASE64 ANDROID_KEYSTORE_PASSWORD ANDROID_KEY_ALIAS ANDROID_KEY_PASSWORD ANDROID_HOME RUNNER_TEMP; do
    [[ -n "${!var:-}" ]] || { echo "ERROR: ${var} is not set" >&2; return 2; }
  done
  command -v keytool >/dev/null || { echo "ERROR: keytool is not on PATH" >&2; return 2; }
  bt="$(pick_build_tools "${ANDROID_HOME}")" \
    || { echo "ERROR: no build-tools under ${ANDROID_HOME} has both apksigner and zipalign" >&2; return 2; }
  log "build-tools ${bt##*/}"
  pinned="$(readme_fingerprint "${REPO_ROOT}/README.md")" \
    || { echo "ERROR: README.md does not publish exactly one signing-certificate SHA-256" >&2; return 2; }

  ks="${RUNNER_TEMP}/${KEYSTORE_NAME}"
  # shellcheck disable=SC2064 # the path is fixed now; expand it now
  trap "rm -f '${ks}' '${ks}.crt' '${ks}.verify' '${ks}.align'" EXIT
  ( umask 077; printf '%s' "${ANDROID_KEYSTORE_BASE64}" | base64 -d >"${ks}" ) \
    || { echo "ERROR: ANDROID_KEYSTORE_BASE64 is not base64" >&2; return 2; }
  keytool -exportcert -keystore "${ks}" -alias "${ANDROID_KEY_ALIAS}" \
    -storepass:env ANDROID_KEYSTORE_PASSWORD -file "${ks}.crt" >/dev/null 2>&1 \
    || { echo "ERROR: keytool cannot read ANDROID_KEY_ALIAS's certificate from the keystore" >&2; return 2; }
  want="$(sha256sum "${ks}.crt" | cut -d' ' -f1)"
  [[ "${want}" == "${pinned}" ]] \
    || { fail 1 "the keystore's certificate is ${want}, not the ${pinned} README.md publishes. A release signed by another key cannot update an installed Haven."; return; }
  log "release certificate SHA-256 ${want} (the one README.md publishes)"

  mkdir -p "${out}"
  for apk in "${in}"/app-*-release.apk; do
    [[ -f "${apk}" ]] || continue
    name="${apk##*/}"
    n=$(( n + 1 ))
    "${bt}/apksigner" sign --ks "${ks}" --ks-key-alias "${ANDROID_KEY_ALIAS}" \
      --ks-pass env:ANDROID_KEYSTORE_PASSWORD --key-pass env:ANDROID_KEY_PASSWORD \
      --lib-page-alignment "${LIB_PAGE_ALIGNMENT}" --v4-signing-enabled false \
      --out "${out}/${name}" "${apk}" \
      || { fail 1 "apksigner could not sign ${name}"; return; }
    "${bt}/apksigner" verify --verbose --print-certs "${out}/${name}" >"${ks}.verify" 2>&1 || true
    if ! why="$(judge_verify "${ks}.verify" "${want}")"; then
      sed 's/^/    /' "${ks}.verify" >&2
      fail 1 "${name}: ${why}"
      return
    fi
    "${bt}/zipalign" -c -P 16 -v 4 "${out}/${name}" >"${ks}.align" 2>&1 \
      || { tail -n 20 "${ks}.align" >&2; fail 1 "${name} is not 4-byte aligned with 16 KB-aligned native libraries"; return; }
    log "OK: ${name} — one signer, the release certificate, v2/v3 verified, 16 KB aligned"
  done
  (( n > 0 )) || { echo "ERROR: no app-*-release.apk in ${in}" >&2; return 2; }
  log "OK: signed and verified ${n} APKs."
}

# ---------------------------------------------------------------------------
# Self-test: the parsers over apksigner's output formats (ApkSignerTool's
# println calls; this repository cannot run the Android SDK), and the whole
# flow over stubbed build-tools and a keystore keytool makes here.
# ---------------------------------------------------------------------------
self_test() {
  local tmp fails=0 checked=0 want
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN
  want="$(printf 'ab%.0s' {1..32})"

  _case() { # _case <label> <want-rc> <command>...
    local label="$1" expect="$2" got=0; shift 2
    checked=$(( checked + 1 ))
    ( "$@" ) >"${tmp}/out" 2>&1 || got=$?
    if [[ "${got}" -eq "${expect}" ]]; then
      printf '  \033[1;32mPASS\033[0m %s\n' "${label}"
    else
      printf '  \033[1;31mFAIL\033[0m %s (want rc=%d, got rc=%d)\n' "${label}" "${expect}" "${got}" >&2
      sed 's/^/      /' "${tmp}/out" >&2
      fails=1
    fi
  }
  _verify() { # <file> <v2> <v3> <signers> <signer line>...
    local f="$1" v2="$2" v3="$3" signers="$4"; shift 4
    { echo Verifies
      echo 'Verified using v1 scheme (JAR signing): false'
      echo "Verified using v2 scheme (APK Signature Scheme v2): ${v2}"
      echo "Verified using v3 scheme (APK Signature Scheme v3): ${v3}"
      echo 'Verified using v3.1 scheme (APK Signature Scheme v3.1): false'
      echo 'Verified using v4 scheme (APK Signature Scheme v4): false'
      echo 'Verified for SourceStamp: false'
      echo "Number of signers: ${signers}"
      printf '%s\n' "$@"; } >"${tmp}/${f}"
  }
  local cert="certificate SHA-256 digest: ${want}" other
  other="certificate SHA-256 digest: $(printf 'cd%.0s' {1..32})"

  echo "sign_android_release.sh --self-test"
  _verify new.txt true true 1 "V3.0 Signer: certificate DN: CN=Fixture" "V3.0 Signer: ${cert}" \
    "V3.0 Signer: public key SHA-256 digest: $(printf 'ef%.0s' {1..32})"
  _case "one v3 signer with the release certificate passes" 0 judge_verify "${tmp}/new.txt" "${want}"
  _verify old.txt true false 1 "Signer #1 certificate SHA-256 digest: ${want^^}"
  _case "older build-tools' 'Signer #1' line, in upper case, passes" 0 judge_verify "${tmp}/old.txt" "${want}"
  _verify wrong.txt true true 1 "V3.0 Signer: ${other}"
  _case "a signer with another certificate fails" 1 judge_verify "${tmp}/wrong.txt" "${want}"
  _verify two.txt true true 2 "V3.0 Signer #1: ${cert}" "V3.0 Signer #2: ${other}"
  _case "two signers fail" 1 judge_verify "${tmp}/two.txt" "${want}"
  _verify rotated.txt true true 1 "V3.1 Signer: (minSdkVersion=33, maxSdkVersion=2147483647) ${other}" "V3.0 Signer: ${cert}"
  _case "a rotated key (a v3.1 signer besides v3.0) fails" 1 judge_verify "${tmp}/rotated.txt" "${want}"
  _verify v1.txt false false 1 "V1 Signer: ${cert}"
  _case "a v1-only signature fails" 1 judge_verify "${tmp}/v1.txt" "${want}"
  sed '/^Verifies$/s//DOES NOT VERIFY/' "${tmp}/new.txt" >"${tmp}/bad.txt"
  _case "an APK that does not verify fails" 1 judge_verify "${tmp}/bad.txt" "${want}"

  _readme() { [[ "$(readme_fingerprint "$1")" == "$2" ]]; }
  _case "README.md's published fingerprint is read" 0 _readme "${REPO_ROOT}/README.md" \
    "$(norm_digest "$(grep -oE '^([0-9A-F]{2}:){31}[0-9A-F]{2}$' "${REPO_ROOT}/README.md" | head -1)")"
  printf '# Haven\n\n### Signing Certificate SHA-256\n```\ncom.example\n```\n' >"${tmp}/README.md"
  _case "a README without a fingerprint is a misconfiguration" 2 readme_fingerprint "${tmp}/README.md"

  local sdk="${tmp}/sdk/build-tools"
  mkdir -p "${sdk}/34.0.0" "${sdk}/35.0.1" "${sdk}/36.1.0"
  for d in 34.0.0 35.0.1; do printf '#!/bin/sh\n' | tee "${sdk}/${d}/apksigner" >"${sdk}/${d}/zipalign"; done
  printf '#!/bin/sh\n' >"${sdk}/36.1.0/zipalign"
  chmod +x "${sdk}"/*/*
  _picks() { [[ "$(pick_build_tools "${tmp}/sdk")" == "${sdk}/35.0.1" ]]; }
  _case "the newest build-tools with both apksigner and zipalign is picked" 0 _picks
  _case "an SDK with no usable build-tools is a misconfiguration" 2 pick_build_tools "${tmp}/empty"

  # The whole flow, run as its own process: a real keystore, and stubbed
  # build-tools that record their argv.
  command -v keytool >/dev/null || { echo "ERROR: the self-test needs keytool" >&2; return 2; }
  local ks="${tmp}/release.jks" digest bt="${tmp}/tools/build-tools/36.0.0"
  export ANDROID_KEYSTORE_PASSWORD='fixture-store-pass'
  keytool -genkeypair -keystore "${ks}" -storetype PKCS12 -alias upload -keyalg EC -groupname secp256r1 \
    -validity 2 -dname 'CN=Fixture' -storepass:env ANDROID_KEYSTORE_PASSWORD >/dev/null 2>&1
  keytool -exportcert -keystore "${ks}" -alias upload -storepass:env ANDROID_KEYSTORE_PASSWORD \
    -file "${tmp}/c.der" >/dev/null 2>&1
  digest="$(sha256sum "${tmp}/c.der" | cut -d' ' -f1)"
  _readme_with() { # <dir> <hex digest>
    mkdir -p "$1"
    printf '### Signing Certificate SHA-256\n```\ncom.example\n%s\n```\n## License\n' \
      "$(sed -E 's/../&:/g; s/:$//' <<<"${2^^}")" >"$1/README.md"
  }
  _readme_with "${tmp}/repo" "${digest}"
  _readme_with "${tmp}/other" "${want}"
  mkdir -p "${tmp}/in" "${bt}"
  printf 'apk\n' | tee "${tmp}/in/app-arm64-v8a-release.apk" >"${tmp}/in/app-x86_64-release.apk"
  _verify stub-verify.txt true true 1 "V3.0 Signer: certificate SHA-256 digest: ${digest}"
  cat >"${bt}/apksigner" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>'${tmp}/argv'
if [[ "\$1" == sign ]]; then
  [[ -n "\${ANDROID_KEY_PASSWORD:-}" ]] || exit 9
  cp "\${@: -1}" "\${@: -2:1}"
else
  cat '${tmp}/stub-verify.txt'
fi
EOF
  printf '#!/usr/bin/env bash\nexit "${ZIPALIGN_RC:-0}"\n' >"${bt}/zipalign"
  chmod +x "${bt}/apksigner" "${bt}/zipalign"
  _flow() { # <repo root>; then checks what the run left behind
    rm -rf "${tmp}/signed" "${tmp}/argv" "${tmp}/runner"; mkdir -p "${tmp}/runner"
    REPO_ROOT_OVERRIDE="$1" ANDROID_HOME="${tmp}/tools" RUNNER_TEMP="${tmp}/runner" \
      ANDROID_KEYSTORE_BASE64="$(base64 -w0 "${ks}")" ANDROID_KEY_ALIAS=upload ANDROID_KEY_PASSWORD='fixture-key-pass' \
      bash "${BASH_SOURCE[0]}" "${tmp}/in" "${tmp}/signed" || return
    [[ -f "${tmp}/signed/app-arm64-v8a-release.apk" && -f "${tmp}/signed/app-x86_64-release.apk" ]] \
      || { echo "a signed APK is missing"; return 1; }
    ! grep -q 'fixture-.*-pass' "${tmp}/argv" || { echo "a password reached argv"; return 1; }
    grep -q -- '--ks-pass env:ANDROID_KEYSTORE_PASSWORD --key-pass env:ANDROID_KEY_PASSWORD --lib-page-alignment 16384' "${tmp}/argv" \
      || { echo "apksigner was not given both passwords by name and 16 KB page alignment"; return 1; }
    [[ -z "$(ls -A "${tmp}/runner")" ]] || { echo "left on disk: $(ls -A "${tmp}/runner")"; return 1; }
  }
  _case "every APK is signed, the passwords go by env name only, and the keystore is deleted" 0 _flow "${tmp}/repo"
  _misaligned() { ZIPALIGN_RC=1 _flow "${tmp}/repo"; }
  _case "an APK zipalign rejects fails" 1 _misaligned
  _case "a keystore that is not the key README.md publishes fails" 1 _flow "${tmp}/other"
  _case "a missing signing secret is a misconfiguration" 2 \
    env -u ANDROID_KEY_PASSWORD REPO_ROOT_OVERRIDE="${tmp}/repo" bash "${BASH_SOURCE[0]}" "${tmp}/in" "${tmp}/signed"

  if (( checked != SELF_TEST_FIXTURES )); then
    printf '  \033[1;31mFAIL\033[0m ran %d fixtures, expected %d\n' "${checked}" "${SELF_TEST_FIXTURES}" >&2
    fails=1
  fi
  (( fails == 0 )) || { echo "sign_android_release.sh --self-test: FAILED" >&2; return 1; }
  log "OK: self-test passed — each way a signed APK can fail (verify, scheme, signer count, certificate, rotation, alignment), the README pin and build-tools choice, and a stubbed end-to-end run."
}

case "${1:-}" in
  --self-test) self_test ;;
  -*|'') echo "ERROR: expected <in-dir> <out-dir> or --self-test" >&2; exit 2 ;;
  *)
    [[ -n "${2:-}" ]] || { echo "ERROR: expected <in-dir> <out-dir>" >&2; exit 2; }
    sign_all "$1" "$2" ;;
esac
