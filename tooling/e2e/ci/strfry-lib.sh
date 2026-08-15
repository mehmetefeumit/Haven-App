#!/usr/bin/env bash
#
# Shared strfry access for the E2E lane orchestrators. SOURCED, never run.
#
# One definition, because the candidate list below is a fact about the PINNED
# `dockurr/strfry` image rather than a per-lane preference: the image has moved
# the binary between paths before, and a list corrected in one lane and not the
# other leaves that lane discovering it twenty minutes in — as an unexplained
# empty relay baseline (B5) or an unexplained empty post-scan (B9).
#
# Reads STRFRY_CONTAINER from the caller and assigns STRFRY_BIN in it.

# detect_strfry_bin — finds a `strfry` inside ${STRFRY_CONTAINER} that can
# actually answer a scan, and assigns it to STRFRY_BIN. 0 on success.
#
# Probed with a REAL query rather than `--version`: the capability the callers
# need is "can read the event store", and a binary that exists but cannot open
# the LMDB would otherwise be discovered only once its absence had already been
# misread as "the relay holds nothing".
detect_strfry_bin() {
  local candidate
  for candidate in strfry /app/strfry /usr/local/bin/strfry /usr/bin/strfry
  do
    if docker exec "${STRFRY_CONTAINER}" "${candidate}" scan \
         '{"kinds":[445],"limit":1}' >/dev/null 2>&1; then
      STRFRY_BIN="${candidate}"
      return 0
    fi
  done
  return 1
}
