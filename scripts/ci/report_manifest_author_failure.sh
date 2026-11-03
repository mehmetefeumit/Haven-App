#!/usr/bin/env bash
#
# Name the reason the Manifest Author's model run failed, and print nothing else
# from its transcript.
#
# ## Why this exists
#
# `privacy-manifest-author.yml` failed on every scheduled run from 2026-08-18 in
# under two seconds, one turn, zero cost: the shape of an API request refused
# before any work, most likely the CLAUDE_CODE_OAUTH_TOKEN credential, though a
# lapsed plan or usage limit looks the same. `anthropics/claude-code-action`
# logs only a sanitised summary of the result message (`is_error: true`) unless
# `show_full_output` is set, and that must stay off: this is a public
# repository and a full transcript can hold repository text and secrets. So the
# reason sat in `execution_file` — a JSON array of SDK messages, the result
# message last — and nobody saw it for eleven weeks.
#
# ## What is printed, exactly
#
# Only the LAST message, only when it is `type: "result"` with `is_error: true`,
# and only its reason: `.result` (a `success` subtype that errored) or
# `.errors` (the `error_*` subtypes). It is printed as one line of ASCII JSON
# (`jq -c -a`), so model- or API-authored text can neither span lines, nor
# open a `::command::` (the encoding starts with a quote or a bracket), nor
# carry a raw control, escape or bidi character. Every `#` is written as the
# equivalent JSON escape `\u0023`, because the runner's legacy `##[command]`
# syntax is matched anywhere in a line, not only at its start. Anthropic
# request ids (`req_…`) are redacted, and the line is bounded.
#
# Every other state — no file, an empty or malformed one, a last message that
# is not an error result — prints one fixed sentence and exits 0: this runs
# after the job has already failed, so it only reports and never changes the
# verdict.
#
# Usage:
#   report_manifest_author_failure.sh <execution-file>
#   report_manifest_author_failure.sh --self-test
#
# Exit codes:
#   0  reported (including "nothing to report")
#   2  misused (bad arguments, jq missing) or the self-test failed

set -euo pipefail

SCRIPT_NAME="report_manifest_author_failure"
MAX_CHARS=500

misconfig() { printf '%s: %s\n' "${SCRIPT_NAME}" "$*" >&2; exit 2; }

report() {
  local file="$1" line

  if [[ ! -s "${file}" ]]; then
    echo "${SCRIPT_NAME}: the execution file is missing or empty; no reason to report."
    return 0
  fi

  if ! line="$(jq -c -a '
      if type == "array" and length > 0 then .[-1] else empty end
      | select(type == "object" and .type == "result" and .is_error == true)
      | (.result // .errors // "no reason recorded")
      | walk(if type == "string" then gsub("req_[A-Za-z0-9]+"; "req_<redacted>") else . end)
    ' "${file}" 2>/dev/null)"; then
    echo "${SCRIPT_NAME}: the execution file is not valid JSON; no reason to report."
    return 0
  fi

  if [[ -z "${line}" ]]; then
    echo "${SCRIPT_NAME}: the last message is not an error result; no reason to report."
    return 0
  fi

  line="${line//#/\\u0023}"
  if (( ${#line} > MAX_CHARS )); then
    line="${line:0:MAX_CHARS} [truncated]"
  fi
  printf '%s: model run failed; reason (JSON, request ids redacted): %s\n' "${SCRIPT_NAME}" "${line}"
}

self_test() {
  local tmp fails=0 checked=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" EXIT

  # Planted in every fixture outside the reason: if it is ever printed, the
  # script has leaked transcript content beyond the one field it may print.
  local planted='PLANTED_TRANSCRIPT_TEXT'
  local preamble='{"type":"system","subtype":"init","model":"m"},{"type":"assistant","message":{"content":"'"${planted}"'"}}'

  _expect() { # _expect <label> <file> <want-rc> <must-contain> [<must-not-contain>...]
    local label="$1" file="$2" want="$3" needle="$4" got=0 out bad=""
    shift 4
    checked=$(( checked + 1 ))
    out="$(report "${file}" 2>&1)" || got=$?
    [[ "${got}" -eq "${want}" ]] || bad="want rc=${want}, got rc=${got}"
    [[ "${out}" == *"${needle}"* ]] || bad="${bad:+${bad}; }missing '${needle}'"
    local forbidden
    for forbidden in "${planted}" "$@"; do
      [[ "${out}" != *"${forbidden}"* ]] || bad="${bad:+${bad}; }printed '${forbidden}'"
    done
    [[ "${out}" != *$'\n'* ]] || bad="${bad:+${bad}; }printed more than one line"
    ! grep -Eq '^[[:space:]]*::' <<<"${out}" || bad="${bad:+${bad}; }a line opens a workflow command"
    ! grep -Fq '##[' <<<"${out}" || bad="${bad:+${bad}; }a legacy ##[ command survived"
    ! LC_ALL=C grep -q '[^ -~]' <<<"${out}" || bad="${bad:+${bad}; }printed a byte that is not printable ASCII"
    if [[ -z "${bad}" ]]; then
      printf '  PASS %s\n' "${label}"
    else
      printf '  FAIL %s (%s)\n         output: %s\n' "${label}" "${bad}" "${out}" >&2
      fails=1
    fi
  }

  _fixture() { # _fixture <name> <messages-after-preamble> -> path
    printf '[%s,%s]\n' "${preamble}" "$2" > "${tmp}/$1.json"
    printf '%s' "${tmp}/$1.json"
  }

  echo "${SCRIPT_NAME}: self-test"

  _expect "a credential refusal names its reason" \
    "$(_fixture refused '{"type":"result","subtype":"success","is_error":true,"result":"OAuth token has expired"}')" \
    0 '"OAuth token has expired"'

  _expect "an error_* subtype reports .errors" \
    "$(_fixture errors '{"type":"result","subtype":"error_during_execution","is_error":true,"errors":["first","second"]}')" \
    0 '["first","second"]'

  _expect "a ::error:: payload stays inside the quoted reason" \
    "$(_fixture injected '{"type":"result","subtype":"success","is_error":true,"result":"::error::forged"}')" \
    0 '"::error::forged"'

  _expect "a multi-line reason stays one line" \
    "$(_fixture multiline '{"type":"result","subtype":"success","is_error":true,"result":"one\n::warning::two\r\nthree"}')" \
    0 '"one\n::warning::two\r\nthree"'

  _expect "a legacy ##[ command is escaped, not printed" \
    "$(_fixture legacy '{"type":"result","subtype":"success","is_error":true,"result":"x ##[error]forged"}')" \
    0 '"x \u0023\u0023[error]forged"'

  _expect "escape and bidi characters are printed as JSON escapes" \
    "$(_fixture controls '{"type":"result","subtype":"success","is_error":true,"result":"a\u001b[31mb\u202ec"}')" \
    0 '"a\u001b[31mb\u202ec"'

  _expect "a request id is redacted in .result" \
    "$(_fixture reqid '{"type":"result","subtype":"success","is_error":true,"result":"401 (request_id: req_011CVabcDEF123)"}')" \
    0 'req_<redacted>' 'req_011CVabcDEF123'

  _expect "a request id is redacted in .errors" \
    "$(_fixture reqid_errors '{"type":"result","subtype":"error_max_turns","is_error":true,"errors":["req_9zZ9 refused"]}')" \
    0 '["req_<redacted> refused"]' 'req_9zZ9'

  _expect "an error result with no reason says so" \
    "$(_fixture noreason '{"type":"result","subtype":"success","is_error":true}')" \
    0 '"no reason recorded"'

  local long
  long="$(printf 'A%.0s' {1..2000})"
  _expect "a long reason is bounded" \
    "$(_fixture long '{"type":"result","subtype":"success","is_error":true,"result":"'"${long}TAIL_PAST_BOUND"'"}')" \
    0 ' [truncated]' 'TAIL_PAST_BOUND'

  _expect "a successful result prints no reason" \
    "$(_fixture ok '{"type":"result","subtype":"success","is_error":false,"result":"SUCCESS_TEXT"}')" \
    0 'not an error result' 'SUCCESS_TEXT'

  _expect "an error result that is not the last message prints nothing" \
    "$(_fixture notlast '{"type":"result","subtype":"success","is_error":true,"result":"EARLIER_ERROR"},{"type":"assistant","is_error":true,"result":"ASSISTANT_TEXT"}')" \
    0 'not an error result' 'EARLIER_ERROR' 'ASSISTANT_TEXT'

  printf '{"type":"result","is_error":true,"result":"NOT_AN_ARRAY"}\n' > "${tmp}/object.json"
  _expect "a file that is not a message array prints nothing" \
    "${tmp}/object.json" 0 'not an error result' 'NOT_AN_ARRAY'

  printf '[{"type":"result","is_error":true,"result":"TRUNCATED_FILE' > "${tmp}/malformed.json"
  _expect "a malformed file is reported, not echoed" \
    "${tmp}/malformed.json" 0 'not valid JSON' 'TRUNCATED_FILE'

  : > "${tmp}/empty.json"
  _expect "an empty file is reported" "${tmp}/empty.json" 0 'missing or empty'

  _expect "a missing file is reported" "${tmp}/absent.json" 0 'missing or empty'

  local argv rc
  for argv in '' 'a b'; do
    checked=$(( checked + 1 ))
    rc=0
    # shellcheck disable=SC2086 # word-splitting argv into arguments is the point
    bash "${BASH_SOURCE[0]}" ${argv} >/dev/null 2>&1 || rc=$?
    if (( rc == 2 )); then
      printf '  PASS arguments [%s] are refused\n' "${argv}"
    else
      printf '  FAIL arguments [%s] are not refused (rc=%d)\n' "${argv}" "${rc}" >&2
      fails=1
    fi
  done

  if (( fails )); then
    misconfig "self-test FAILED (${checked} fixtures)"
  fi
  echo "${SCRIPT_NAME}: OK, self-test passed (${checked} fixtures)."
}

command -v jq >/dev/null 2>&1 || misconfig "jq is required"

(( $# == 1 )) || misconfig "usage: ${SCRIPT_NAME}.sh <execution-file> | --self-test"
case "$1" in
  --self-test) self_test ;;
  *)           report "$1" ;;
esac
