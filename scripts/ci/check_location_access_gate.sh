#!/usr/bin/env bash
# CI guard: the location access gate runs BEFORE any coordinate is produced.
#
# Invariant being pinned (privacy Rule 10): no stored coordinate may outlive
# the user's location access. `GeolocatorLocationService` caches the unified
# stream's latest fix so publish cycles keep working while backgrounded on
# iOS, and that cache is the whole exposure — a warm entry stays servable for
# `kStreamPositionMaxAge` (168 s) after the provider is switched off or the
# permission withdrawn.
#
# The gate (`_ensureAccessOrThrow`) is what closes it, but ONLY because of
# where it sits. The permission/service checks used to live BELOW the cache
# read and below the iOS-backgrounded `getLastKnownPosition()` shortcut, so
# both shortcuts published a coordinate the user had already revoked. Moving
# the gate to the top of `getCurrentLocation` is the fix; nothing but
# statement ORDER enforces it, and re-introducing the defect is a one-line
# reorder that reads perfectly natural in review and breaks no compile.
#
# The unit tests cover the behaviour, but a reorder can be made to pass them
# by weakening a stub, and the ordering is not something a reader of a diff
# hunk can see. Hence a source-level gate, per CLAUDE.md's rule that privacy
# boundaries get a grep guard as a step in repo-guards.yml.
#
# Checks (all over a COMMENT-STRIPPED view, so prose describing a rule can
# never satisfy the rule):
#   1. getCurrentLocation calls _ensureAccessOrThrow before it reads the
#      cache, before getLastKnownPosition(), and before getCurrentPosition().
#   2. getCurrentLocationFresh does the same.
#   3. The cache read and the iOS-backgrounded last-known shortcut sit inside
#      the `if (granted)` block — `unableToDetermine` is not consent, so no
#      STORED coordinate may be served on it.
#   4. Every `throw LocationServiceException` inside the gate is preceded by
#      a `_noteAccessLost(` — losing access must CLEAR the cache, not merely
#      bypass it, or a later re-grant resurrects a pre-revocation fix.
#   5. The gate's `requestPermission()` is guarded by `_foregroundActive`.
#      On iOS `denied` also covers `notDetermined`, and a prompt raised while
#      backgrounded is deferred by the OS while geolocator's delegate
#      early-returns on `notDetermined` — the Dart future never completes and
#      one hung await wedges the per-circle publish chain for the process.
#   6. The gate consults the granted ACCURACY (`getLocationAccuracy`), the
#      only signal for an iOS "Precise Location" / Android FINE-vs-COARSE
#      downgrade, which `checkPermission()` still reports as `whileInUse`.
#   7. getLocationStream drops the cache on BOTH stream error and close.
#   8. The publish chain bounds each link with `.timeout(`, on BOTH of its
#      branches — an unfinished future raises no error, so `catchError` cannot
#      see it and a single hung link stalls publishing for every circle until
#      the provider is rebuilt. The chain link delegates to a dispatcher that
#      branches (background burst sink / direct paced publish), and only the
#      direct branch reaches `_publishCircle`, several calls down. So the check
#      resolves the delegate, requires a bound on it (the sink branch is
#      awaited there and nowhere deeper), then WALKS the private calls and
#      requires a bound in every body that awaits `_publishCircle`. Nothing
#      resolvable, or nothing reaching the publish at all, fails CLOSED.
#   9. Exactly ONE call site reaches `_geolocator.requestPermission(`, inside a
#      helper that returns the request already in flight instead of starting a
#      second. Android refuses a concurrent permission request and answers it
#      with an empty grant result the plugin drops — having already overwritten
#      its single result callback — so the caller that asked first is never
#      answered. Observed in CI: a publish tick and a one-shot read raced with
#      the permission revoked, and the loser hung for the rest of the process.
#
# Usage:
#   check_location_access_gate.sh              # check the checked-in sources
#   check_location_access_gate.sh --self-test  # hermetic fixtures, no toolchain
#
# Exit codes:
#   0  all checks pass
#   1  an invariant is violated
#   2  expected paths missing / self-test failed (the guard itself is broken)

set -uo pipefail

SCRIPT_NAME="check_location_access_gate"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

SERVICE="${REPO_ROOT}/haven/lib/src/services/geolocator_location_service.dart"
SCHEDULER="${REPO_ROOT}/haven/lib/src/providers/location_publish_scheduler_provider.dart"

RED=$'\033[1;31m'
GREEN=$'\033[1;32m'
BLUE=$'\033[1;34m'
RESET=$'\033[0m'

FAILED=0

log()  { printf '%s[%s]%s %s\n' "${BLUE}" "${SCRIPT_NAME}" "${RESET}" "$*"; }
fail() { printf '%sFAIL:%s %s\n' "${RED}" "${RESET}" "$*" >&2; FAILED=1; }
misconfig() {
  printf '%s[%s] MISCONFIGURED:%s %s\n' "${RED}" "${SCRIPT_NAME}" "${RESET}" "$*" >&2
  exit 2
}

# ---------------------------------------------------------------------------
# Comment-aware source view (same shape as check_ios_background_publish.sh).
#
# Every check below runs over this, never over the raw file: a doc comment
# that DESCRIBES the ordering must not be able to satisfy a check about the
# ordering. That is the single most common way a source guard rots into a
# rubber stamp.
# ---------------------------------------------------------------------------
code_view() {
  awk '
    {
      line = $0; out = ""; i = 1; n = length(line)
      while (i <= n) {
        if (inblock) {
          e = index(substr(line, i), "*/")
          if (e == 0) { i = n + 1 } else { i += e + 1; inblock = 0 }
        } else {
          two = substr(line, i, 2)
          if (two == "/*") { inblock = 1; i += 2 }
          else if (two == "//") { i = n + 1 }
          else { out = out substr(line, i, 1); i += 1 }
        }
      }
      print out
    }' "$1"
}

# Prints the brace-balanced body of the first declaration whose line contains
# `sig`, from the comment-stripped view of `file`.
fn_slice() {
  local sig="$1" file="$2" v
  v="$(code_view "${file}")"
  awk -v sig="${sig}" '
    !inbody && index($0, sig) > 0 { inbody = 1 }
    inbody {
      print
      o = gsub(/[{]/, "&"); c = gsub(/[}]/, "&")
      depth += o - c
      if (seen && depth <= 0) exit
      if (o > 0) seen = 1
    }' <<<"${v}"
}

# 1-based line number of the first line of `body` matching the ERE `pat`,
# or empty when absent. grep, not awk: passing an ERE through `awk -v`
# subjects it to awk's string-escape pass first, which silently mangles the
# `\(` in every anchor here.
first_line_matching() {
  local pat="$1" body="$2"
  grep -nE -m1 -- "${pat}" <<<"${body}" | cut -d: -f1
}

# Fails unless `earlier` appears strictly before `later` in `body`, and both
# appear at all. An absent anchor is a failure, not a pass: a check whose
# anchor stopped matching is a check that proves nothing.
require_order() {
  local label="$1" body="$2" earlier="$3" later="$4" why="$5"
  local a b
  a="$(first_line_matching "${earlier}" "${body}")"
  b="$(first_line_matching "${later}" "${body}")"
  if [[ -z "${a}" ]]; then
    fail "${label}: no line matching /${earlier}/ — the access gate call is gone or renamed. ${why}"
    return
  fi
  if [[ -z "${b}" ]]; then
    # The guarded read is simply absent; nothing to order against.
    return
  fi
  if (( a >= b )); then
    fail "${label}: /${earlier}/ (line ${a} of the body) does not precede /${later}/ (line ${b}). ${why}"
  fi
}

# ---------------------------------------------------------------------------
# The checks, factored over explicit paths so --self-test can drive fixtures.
# ---------------------------------------------------------------------------
check_service() {
  local service="$1"
  local body

  # -- getCurrentLocation ---------------------------------------------------
  body="$(fn_slice 'Future<Position> getCurrentLocation()' "${service}")"
  if [[ -z "${body}" ]]; then
    fail "getCurrentLocation() not found in $(basename "${service}") — the guard cannot see what it is meant to protect"
  else
    local why='A cached, last-known or fresh coordinate produced before the gate is a coordinate that outlived the user consent for it.'
    require_order "getCurrentLocation" "${body}" \
      '_ensureAccessOrThrow\(' '_lastStreamPosition' \
      "The warm-cache shortcut must not run before the gate. ${why}"
    require_order "getCurrentLocation" "${body}" \
      '_ensureAccessOrThrow\(' 'getLastKnownPosition\(' \
      "The iOS-backgrounded last-known shortcut must not run before the gate. ${why}"
    require_order "getCurrentLocation" "${body}" \
      '_ensureAccessOrThrow\(' 'getCurrentPosition\(' \
      "The one-shot must not run before the gate. ${why}"

    # Both stored-coordinate shortcuts must sit under the affirmative-grant
    # branch: `unableToDetermine` returns false from the gate, and serving a
    # stored fix on an authorization nobody could determine is not consent.
    require_order "getCurrentLocation" "${body}" \
      'if *\( *granted *\)' '_lastStreamPosition' \
      'The cache read must sit inside the `if (granted)` block.'
    require_order "getCurrentLocation" "${body}" \
      'if *\( *granted *\)' 'getLastKnownPosition\(' \
      'The iOS-backgrounded last-known shortcut must sit inside the `if (granted)` block.'
  fi

  # -- getCurrentLocationFresh ---------------------------------------------
  body="$(fn_slice 'Future<Position> getCurrentLocationFresh()' "${service}")"
  if [[ -z "${body}" ]]; then
    fail "getCurrentLocationFresh() not found in $(basename "${service}")"
  else
    require_order "getCurrentLocationFresh" "${body}" \
      '_ensureAccessOrThrow\(' 'getCurrentPosition\(' \
      'The fresh path must gate first too — it is also the path that DISCOVERS a revocation and clears the cache for everyone else.'
  fi

  # -- the gate -------------------------------------------------------------
  body="$(fn_slice 'Future<bool> _ensureAccessOrThrow()' "${service}")"
  if [[ -z "${body}" ]]; then
    fail "_ensureAccessOrThrow() not found in $(basename "${service}") — the access gate is gone"
    return
  fi

  # Every denial must CLEAR the cache before throwing. Bypassing without
  # clearing lets a later re-grant resurrect a pre-revocation coordinate.
  local throws cleared
  throws="$(grep -cE 'throw +LocationServiceException' <<<"${body}")"
  if (( throws == 0 )); then
    fail "_ensureAccessOrThrow: no LocationServiceException is thrown — the gate cannot refuse anything"
  fi
  # PROXIMITY, not "somewhere earlier in the function": the gate has several
  # denial branches, and a `_noteAccessLost` in one of them would otherwise
  # vouch for a throw in another. Blank lines are skipped so deleting the
  # call cannot be papered over by the gap it leaves.
  cleared="$(awk '
    /^[[:space:]]*$/ { next }
    /throw[[:space:]]+LocationServiceException/ {
      if (p1 !~ /_noteAccessLost\(/ && p2 !~ /_noteAccessLost\(/) bad++
    }
    { p2 = p1; p1 = $0 }
    END { print bad + 0 }' <<<"${body}")"
  if (( cleared > 0 )); then
    fail "_ensureAccessOrThrow: ${cleared} LocationServiceException throw(s) are not preceded by a _noteAccessLost( — an observed denial must CLEAR the cached fix, not merely refuse this call, or a later re-grant serves the pre-revocation coordinate"
  fi

  # Never prompt from a non-interactive context (see the header).
  if ! grep -qE 'requestPermission\(' <<<"${body}"; then
    fail "_ensureAccessOrThrow: no requestPermission( call site — a first-run denial can no longer be recovered by asking"
  elif ! grep -qE 'if *\( *_foregroundActive *\)' <<<"${body}"; then
    fail "_ensureAccessOrThrow: requestPermission() is not guarded by \`if (_foregroundActive)\` — on iOS a backgrounded prompt is deferred by the OS and geolocator never resolves its FlutterResult, so this await never returns and wedges the publish chain for the whole process"
  fi

  # -- one prompt in flight at a time ---------------------------------------
  # A second SIMULTANEOUS platform request is not a duplicate, it is a
  # cancellation. Android refuses it ("Can request only one set of permissions
  # at a time") with an empty grant result geolocator drops, and the plugin
  # keeps ONE result callback which the second caller has already overwritten
  # — so the caller that asked FIRST is never answered at all. Both prompting
  # paths (this gate and the public requestPermission) must share one
  # in-flight request, which holds only while exactly one call site reaches
  # the platform.
  # A local of its own: `body` still has to hold the GATE for the checks
  # below, and reusing it here silently pointed the accuracy check at this
  # helper instead (caught by the self-test, which is why it has fixtures).
  local direct helper
  direct="$(grep -cE '_geolocator\.requestPermission\(' <<<"$(code_view "${service}")")"
  if (( direct != 1 )); then
    fail "${direct} call site(s) reach _geolocator.requestPermission( — there must be exactly ONE, inside the coalescing helper. Two callers prompting at once cancel each other on Android and the loser's future never completes, wedging whichever publish cycle or map read is awaiting it"
  else
    helper="$(fn_slice 'Future<geo.LocationPermission> _requestPermission()' "${service}")"
    if [[ -z "${helper}" ]]; then
      fail "_requestPermission() not found — the single platform call site is no longer behind a coalescing helper, so concurrent callers race"
    else
      # A store, not merely a mention: the helper clears the field to `null`
      # when the request settles, and that clear alone would satisfy a bare
      # "the field is assigned somewhere" grep while nothing is ever shared.
      if ! grep -E '_permissionRequestInFlight *=' <<<"${helper}" |
           grep -qvE '= *null'; then
        fail "_requestPermission: never STORES the in-flight request (only clears it) — with nothing recorded, every concurrent caller starts its own platform request"
      fi
      require_order "_requestPermission" "${helper}" \
        'return ' '_geolocator\.requestPermission\(' \
        'The helper must be able to return the request already in flight WITHOUT asking the platform again; a helper that always asks has coalesced nothing.'
    fi
  fi

  # Precision downgrade is invisible to checkPermission(); the gate must read
  # the accuracy authorization to see it.
  if ! grep -qE 'getLocationAccuracy\(' <<<"${body}"; then
    if ! grep -qE '_noteAccuracyDowngrade\(' <<<"${body}"; then
      fail "_ensureAccessOrThrow: neither getLocationAccuracy( nor _noteAccuracyDowngrade( is reached — an iOS 'Precise Location' off / Android FINE-revoked-COARSE-kept downgrade still reads as whileInUse, and the cache would keep serving the PRECISE fix captured before it"
    fi
  fi

  # -- the position stream's end-of-life handlers ---------------------------
  #
  # An ERROR and a CLOSE are the two ways the platform reports a mid-session
  # revocation, and both mean no further fix will arrive — so the teed
  # coordinate must be dropped THEN, not left to age out over
  # kStreamPositionMaxAge.
  #
  # Where the handlers live is not fixed: `getLocationStream` hands back an
  # outer controller whose platform subscription is established in
  # `_listenInner` (`listen(onError:/onDone:)`), and it used to transform the
  # plugin stream inline (`handleError:`/`handleDone:`). Both spellings are
  # accepted; a missing handler, or one that does not drop the cache, is not.
  body="$(fn_slice 'Stream<Position> getLocationStream(' "${service}")"
  if [[ -z "${body}" ]]; then
    fail "getLocationStream() not found in $(basename "${service}")"
  else
    # Declaration-shaped, so the `_listenInner(outer);` CALL inside
    # getLocationStream cannot be sliced instead (it has no braces to balance,
    # so fn_slice would run to end of file).
    body="${body}
$(fn_slice 'void _listenInner(' "${service}")"
    local h name
    for h in 'handleError|onError' 'handleDone|onDone'; do
      name="${h//|/ or }"
      if ! grep -qE "(${h}):" <<<"${body}"; then
        fail "the position stream has no ${name} handler — the end of the stream is how a mid-session revocation is reported, and it must drop the teed coordinate"
        continue
      fi
      # The _noteAccessLost call must be inside that handler, not merely
      # somewhere in the method.
      if ! awk -v h="(${h}):" '
            $0 ~ h { inh = 1 }
            inh && /_noteAccessLost\(/ { found = 1; exit }
            inh && /^ *\},? *$/ { inh = 0 }
            END { exit(found ? 0 : 1) }' <<<"${body}"; then
        fail "the position stream's ${name} handler does not call _noteAccessLost( — no further fix will arrive, so the cached one must be dropped now instead of ageing out over kStreamPositionMaxAge"
      fi
    done
  fi
}

# Prints the brace-balanced body of the DECLARATION of `name` in `file`.
#
# A declaration, never a call site. `await _publishCircle(...).timeout(` is a
# call and satisfies every "type then name" shape you can write, and it sits
# ABOVE the real declaration — a resolver that picked it would find a
# `.timeout(` belonging to a different call and pass an unbounded chain. Two
# discriminators, because Dart wraps long signatures:
#
#   * the line ends with `{` (single-line signature) or with `(` (a signature
#     whose parameters continue on the next line), and
#   * it does not START with a statement keyword and carries no `=` or `.`
#     before the name, which is what every call site here does.
#
# Empty when nothing matches, which every caller treats as FAIL CLOSED.
decl_slice() {
  local name="$1" file="$2" decl
  decl="$(code_view "${file}" \
    | grep -E "^[[:space:]]*[A-Za-z_][A-Za-z0-9_<>,?]*[[:space:]]+${name}\((.*\{|)[[:space:]]*$" \
    | grep -vE "^[[:space:]]*(await|return|yield|final|var|const)[[:space:]]" \
    | grep -vE "^[^_]*[=.][^_]*${name}\(" \
    | head -1 | sed 's/^[[:space:]]*//')"
  [[ -z "${decl}" ]] && return 0
  fn_slice "${decl}" "${file}"
}

# Every private method `body` calls, so the chain can be followed rather than
# assumed. The declaration line is dropped first: a method's own name appears
# in its signature, and following that is an infinite loop.
callees_of() {
  tail -n +2 <<<"$1" | grep -oE '_[A-Za-z0-9_]+\(' | tr -d '(' | sort -u
}

check_scheduler() {
  local scheduler="$1"
  local body
  # Declaration-shaped signature on purpose: a bare `_onCircleTick(` matches
  # the `onTick: () => _onCircleTick(...)` call site FIRST and would slice a
  # one-line closure, which contains none of the tokens below — i.e. the
  # guard would fail the healthy tree while looking like it had found
  # something.
  body="$(fn_slice 'void _onCircleTick(' "${scheduler}")"
  if [[ -z "${body}" ]]; then
    fail "_onCircleTick() not found in $(basename "${scheduler}")"
    return
  fi
  if ! grep -qE 'catchError\(' <<<"${body}"; then
    fail "_onCircleTick: the per-circle publish chain has no catchError( — one failed publish would poison the chain for every later circle"
  fi

  # The bound lives one or more calls deeper than the chain link. `_onCircleTick`
  # enqueues `.then((_) => X(...))`, X dispatches to a BRANCH per publish plane
  # — the background burst sink and the direct paced publish — and only the
  # branch that actually awaits `_publishCircle` can carry the per-publish
  # bound. Checking one level found a `.timeout(` in the sink branch and
  # declared the whole chain bounded, so deleting the direct branch's timeout
  # outright left this guard GREEN while printing "the publish chain is
  # bounded".
  #
  # So: resolve the delegate, then WALK the private calls from it and require a
  # `.timeout(` in every body that awaits `_publishCircle`. Nothing resolvable,
  # or nothing reaching `_publishCircle` at all, is FAIL CLOSED — an
  # unfollowable chain is not evidence of a bounded one.
  local delegate
  delegate="$(grep -oE '\.then\(\([^)]*\) => _[A-Za-z0-9_]+\(' <<<"${body}" \
              | head -1 | grep -oE '_[A-Za-z0-9_]+\($' | tr -d '(')"
  if grep -qE '\.timeout\(' <<<"${body}"; then
    : # the link is bounded inline; there is no delegate to follow
  elif [[ -z "${delegate}" ]]; then
    fail "_onCircleTick: the per-circle publish chain has no .timeout( and no resolvable delegate to carry one — a link that never completes raises no error, so catchError alone cannot see it, and one hung publish (e.g. a permission prompt the OS deferred) stalls EVERY circle until the provider is rebuilt"
    return
  fi

  local dbody
  if [[ -n "${delegate}" ]]; then
    dbody="$(decl_slice "${delegate}" "${scheduler}")"
    if [[ -z "${dbody}" ]]; then
      fail "_onCircleTick delegates its publish to ${delegate}(), whose declaration could not be found in $(basename "${scheduler}") — the per-link bound cannot be verified, so it is treated as absent"
      return
    fi
    # The delegate's own body must be bounded too: it is where the branch that
    # hands the tick to the background burst sink is awaited, and that branch
    # never reaches `_publishCircle` at all.
    if ! grep -qE '\.timeout\(' <<<"${dbody}"; then
      fail "_onCircleTick delegates its publish to ${delegate}(), which has no .timeout( — the branch that hands the tick to the burst sink is awaited there and nowhere deeper, so nothing bounds it"
    fi
  else
    dbody="${body}"
  fi

  # Walk. Bounded by the `seen` set, so a cycle in the call graph terminates.
  # The seed is the delegate's own body (or the tick's, when the link does not
  # delegate at all) — the publish can be right there.
  local -A seen=()
  local -a queue=()
  local reached=0 fn next fbody
  queue=("__seed__")
  while (( ${#queue[@]} > 0 )); do
    fn="${queue[0]}"
    queue=("${queue[@]:1}")
    [[ -n "${seen[${fn}]:-}" ]] && continue
    seen[${fn}]=1
    if [[ "${fn}" == "__seed__" ]]; then
      fbody="${dbody}"
    else
      fbody="$(decl_slice "${fn}" "${scheduler}")"
    fi
    # Fields, getters and cross-object calls resolve to nothing; they are not
    # steps in the chain, so they are skipped rather than failed. The
    # fail-closed case is reaching NO `_publishCircle` at all, below.
    [[ -z "${fbody}" ]] && continue
    if tail -n +2 <<<"${fbody}" | grep -qE '_publishCircle\('; then
      reached=1
      if ! grep -qE '\.timeout\(' <<<"${fbody}"; then
        fail "the publish chain awaits _publishCircle() in ${fn}() with no .timeout( — a link that never completes raises no error, so catchError cannot see it, and one hung publish (e.g. a permission prompt the OS deferred) stalls EVERY circle until the provider is rebuilt"
      fi
      continue
    fi
    while read -r next; do queue+=("${next}"); done < <(callees_of "${fbody}")
  done
  if (( reached == 0 )); then
    fail "_onCircleTick: no function reachable from the publish chain awaits _publishCircle() — the guard can no longer see where the publish happens, so it cannot certify that anything bounds it"
  fi
}

# ---------------------------------------------------------------------------
# Self-test: fixtures the guard has never seen, in BOTH directions.
#
# The positive fixture matters as much as the negatives: a guard hard-coded to
# fail would look correct on every negative fixture and would then fail the
# real tree for no reason.
# ---------------------------------------------------------------------------
GOOD_SERVICE=$(cat <<'DART'
class GeolocatorLocationService {
  Position? _lastStreamPosition;
  bool _foregroundActive = true;
  Future<geo.LocationPermission>? _permissionRequestInFlight;

  void _noteAccessLost(String reason) {
    _lastStreamPosition = null;
  }

  Future<geo.LocationPermission> _requestPermission() {
    final inFlight = _permissionRequestInFlight;
    if (inFlight != null) return inFlight;
    final request = _geolocator.requestPermission();
    _permissionRequestInFlight = request;
    return request.whenComplete(() => _permissionRequestInFlight = null);
  }

  Future<bool> _ensureAccessOrThrow() async {
    final serviceEnabled = await _geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      _noteAccessLost('location services disabled');
      throw LocationServiceException('disabled');
    }
    var permission = await _geolocator.checkPermission();
    if (permission == geo.LocationPermission.denied) {
      _noteAccessLost('permission read denied');
      if (_foregroundActive) {
        permission = await _requestPermission();
      }
    }
    switch (permission) {
      case geo.LocationPermission.whileInUse:
        await _noteAccuracyDowngrade();
        return true;
      case geo.LocationPermission.denied:
        _noteAccessLost('permission denied');
        throw LocationServiceException('denied');
      case geo.LocationPermission.unableToDetermine:
        return false;
    }
  }

  Future<void> _noteAccuracyDowngrade() async {
    final accuracy = await _geolocator.getLocationAccuracy();
    if (accuracy == geo.LocationAccuracyStatus.reduced) {
      _noteAccessLost('precise location downgraded to approximate');
    }
  }

  @override
  Future<Position> getCurrentLocation() async {
    final granted = await _ensureAccessOrThrow();
    if (granted) {
      final cached = _lastStreamPosition;
      if (cached != null) {
        return cached;
      }
      if (_isIOS && !_foregroundActive) {
        final lastPosition = await _geolocator.getLastKnownPosition();
        if (lastPosition != null) {
          return _convertPosition(lastPosition);
        }
      }
    }
    final geoPosition = await _geolocator.getCurrentPosition();
    return _convertPosition(geoPosition);
  }

  @override
  Future<Position> getCurrentLocationFresh() async {
    await _ensureAccessOrThrow();
    final geoPosition = await _geolocator.getCurrentPosition();
    return _convertPosition(geoPosition);
  }

  @override
  Stream<Position> getLocationStream({bool backgroundSharingEnabled = false}) {
    return _geolocator.getPositionStream().transform(
      StreamTransformer<Position, Position>.fromHandlers(
        handleError: (error, stackTrace, sink) {
          _noteAccessLost('position stream error');
          sink.addError(error, stackTrace);
        },
        handleDone: (sink) {
          _noteAccessLost('position stream closed');
          sink.close();
        },
      ),
    );
  }
}
DART
)

# The shape the real scheduler took once a pacing/stagger step landed between
# the chain link and the publish: the link delegates, and the BOUND lives in the
# delegate. Checking only `_onCircleTick` failed this healthy shape in CI run
# 31216078806 while the bound was intact one call deeper.
GOOD_SCHEDULER_DELEGATED=$(cat <<'DART'
class LocationPublishSchedulerNotifier extends Notifier<void> {
  void _onCircleTick(int generation) {
    if (!_isCurrent(generation) || !_active) return;
    _publishChain = _publishChain
        .then((_) => _dispatchBurst(burst, generation))
        .catchError((Object _) {});
  }

  Future<void> _dispatchBurst(List<Target> burst, int generation) {
    final sink = _tickSink;
    if (sink == null) return _publishBurst(burst, generation);
    return Future.wait(handovers).then<void>((_) {}).timeout(
      _publishLinkTimeout,
      onTimeout: () => debugPrint('reported'),
    );
  }

  Future<void> _publishBurst(List<Target> burst, int generation) async {
    for (var i = 0; i < burst.length; i++) {
      await _pacedPublish(burst[i].key, generation, gaps[i], fix);
    }
  }

  Future<void> _pacedPublish(
    String circleKey,
    int generation,
    Duration gap,
    BurstFix fix,
  ) async {
    await _wait(gap);
    await _publishCircle(circle, generation, fix: fix).timeout(
      _publishLinkTimeout,
      onTimeout: () => debugPrint('abandoned'),
    );
  }

  Future<void> _publishCircle(
    Circle circle,
    int generation, {
    required BurstFix fix,
  }) async {
    await service.publishLocation();
  }
}
DART
)

GOOD_SCHEDULER=$(cat <<'DART'
class LocationPublishSchedulerNotifier extends Notifier<void> {
  void _onCircleTick(String key, int generation) {
    if (!_isCurrent(generation) || !_active) return;
    final circle = _circles[key];
    if (circle == null) return;
    _publishChain = _publishChain
        .then(
          (_) => _publishCircle(circle, generation).timeout(
            _publishLinkTimeout,
            onTimeout: () => debugPrint('abandoned'),
          ),
        )
        .catchError((Object _) {});
  }
}
DART
)

SELFTEST_TMP=""
cleanup_selftest() { [[ -n "${SELFTEST_TMP}" ]] && rm -rf "${SELFTEST_TMP}"; }

self_test() {
  local failures=0 checked=0 tmp
  SELFTEST_TMP="$(mktemp -d)"
  # EXIT, not RETURN: bash tears down the function's locals before running a
  # RETURN trap, so the trap would fire against an unbound name.
  trap cleanup_selftest EXIT
  tmp="${SELFTEST_TMP}"

  # Runs `fn` against a fixture and asserts the resulting FAILED flag.
  # `expected` is 0 (must pass) or 1 (must fail).
  #
  # The check runs in THIS shell with its output redirected to a file, never
  # inside a `$(...)`: command substitution forks a subshell, so the FAILED
  # flag the guard sets would be discarded and every negative fixture would
  # report a spurious pass — the exact way a self-test becomes decorative.
  _expect() {
    local desc="$1" fn="$2" content="$3" expected="$4"
    local path="${tmp}/fixture.dart" out="${tmp}/out.txt"
    # COUNTED, not asserted against a literal. The summary used to print a
    # hardcoded total, so adding fixtures left it unchanged and the number said
    # nothing about what actually ran.
    checked=$((checked + 1))
    printf '%s\n' "${content}" >"${path}"
    FAILED=0
    "${fn}" "${path}" >"${out}" 2>&1
    if [[ "${FAILED}" -ne "${expected}" ]]; then
      printf '%sself-test FAILED%s [%s]: expected FAILED=%s, got %s\n' \
        "${RED}" "${RESET}" "${desc}" "${expected}" "${FAILED}" >&2
      sed 's/^/  guard said: /' "${out}" >&2
      # Count, never exit: an early return would leave every later fixture
      # silently unrun — a self-test that only ever proves the happy path.
      failures=$((failures + 1))
    fi
    FAILED=0
  }

  log "self-test: service fixtures"

  _expect "a correctly ordered service passes" \
    check_service "${GOOD_SERVICE}" 0

  # THE regression this guard exists for: the gate moved back below the
  # warm-cache shortcut. Compiles, reads fine, publishes revoked coordinates.
  _expect "gate AFTER the cache read must fail" check_service \
    "$(sed -e 's/^    final granted = await _ensureAccessOrThrow();$//' \
           -e 's/^    if (granted) {$/    final cached = _lastStreamPosition;\n    if (cached != null) { return cached; }\n    final granted = await _ensureAccessOrThrow();\n    if (granted) {/' \
        <<<"${GOOD_SERVICE}")" 1

  # A gate that is deleted outright must fail LOUDLY, not vacuously pass for
  # want of an anchor to order against.
  _expect "no gate call at all must fail" check_service \
    "${GOOD_SERVICE//final granted = await _ensureAccessOrThrow();/final granted = true;}" 1

  # Prose is not code: a doc comment describing the gate must not satisfy it.
  _expect "the gate call in a COMMENT must not count" check_service \
    "${GOOD_SERVICE//final granted = await _ensureAccessOrThrow();//\/ calls _ensureAccessOrThrow() first\n    final granted = true;}" 1

  # `unableToDetermine` is not consent: the stored-coordinate shortcuts must
  # stay inside `if (granted)`.
  _expect "cache read outside the if (granted) block must fail" check_service \
    "$(sed -e 's/^    if (granted) {$/    if (true) {/' <<<"${GOOD_SERVICE}")" 1

  # Bypassing the cache on a denial is not the same as clearing it: a later
  # re-grant would resurrect the pre-revocation fix.
  _expect "a throw not preceded by _noteAccessLost must fail" check_service \
    "$(sed -e "s/^        _noteAccessLost('permission denied');$//" <<<"${GOOD_SERVICE}")" 1

  # The F4 regression: an unguarded prompt reachable from a background tick.
  _expect "unguarded requestPermission() in the gate must fail" check_service \
    "$(sed -e 's/^      if (_foregroundActive) {$//' \
           -e 's/^        permission = await _requestPermission();$/      permission = await _requestPermission();/' \
        <<<"${GOOD_SERVICE}")" 1

  # --- one prompt in flight at a time --------------------------------------
  # The CI regression: a publish tick and a one-shot read both prompted, the
  # platform cancelled one, and the caller that asked first was never answered.

  _expect "a second platform call site must fail" check_service \
    "$(sed -e 's|^  Future<void> _noteAccuracyDowngrade() async {$|  Future<bool> requestPermission() async {\n    final p = await _geolocator.requestPermission();\n    return p == geo.LocationPermission.whileInUse;\n  }\n\n  Future<void> _noteAccuracyDowngrade() async {|' \
        <<<"${GOOD_SERVICE}")" 1

  # One call site, but nothing coalescing it: every caller reaches the
  # platform, which is the same race with fewer lines.
  _expect "the single call site outside a coalescing helper must fail" \
    check_service \
    "$(sed -e '/^  Future<geo.LocationPermission> _requestPermission() {$/,/^  }$/d' \
           -e 's|^        permission = await _requestPermission();$|        permission = await _geolocator.requestPermission();|' \
        <<<"${GOOD_SERVICE}")" 1

  # A helper that asks unconditionally has coalesced nothing.
  _expect "a helper that always asks the platform must fail" check_service \
    "$(sed -e 's|^    if (inFlight != null) return inFlight;$||' \
        <<<"${GOOD_SERVICE}")" 1

  # The store is what later callers find; the `null` clear on completion must
  # not stand in for it.
  _expect "a helper that never stores the request must fail" check_service \
    "$(sed -e 's|^    _permissionRequestInFlight = request;$||' \
        <<<"${GOOD_SERVICE}")" 1

  # The precision hole: whileInUse + approximate reads as full access.
  _expect "no accuracy read in the gate must fail" check_service \
    "$(sed -e 's/^        await _noteAccuracyDowngrade();$//' <<<"${GOOD_SERVICE}")" 1

  # A mid-stream revocation is reported as an error or a close; both must
  # drop the teed coordinate rather than let it age out.
  _expect "handleDone without _noteAccessLost must fail" check_service \
    "$(sed -e "s/^          _noteAccessLost('position stream closed');$//" <<<"${GOOD_SERVICE}")" 1
  _expect "handleError without _noteAccessLost must fail" check_service \
    "$(sed -e "s/^          _noteAccessLost('position stream error');$//" <<<"${GOOD_SERVICE}")" 1

  # The same rule against the shape the service actually has: an outer
  # controller whose platform subscription — and therefore whose end-of-life
  # handlers — live in `_listenInner`. Without these three the guard could
  # accept the production spelling while enforcing nothing about it.
  local OUTER_SERVICE
  OUTER_SERVICE="$(sed -e '/^  Stream<Position> getLocationStream(/,/^  }$/c\
  Stream<Position> getLocationStream({bool backgroundSharingEnabled = false}) {\
    final outer = StreamController<Position>(sync: true);\
    _listenInner(outer);\
    return outer.stream;\
  }\
\
  void _listenInner(StreamController<Position> outer) {\
    _inner = _geolocator.getPositionStream().listen(\
      outer.add,\
      onError: (Object error, StackTrace stackTrace) {\
        _noteAccessLost('"'"'position stream error'"'"');\
        outer.addError(error, stackTrace);\
      },\
      onDone: () {\
        _noteAccessLost('"'"'position stream closed'"'"');\
        unawaited(outer.close());\
      },\
    );\
  }' <<<"${GOOD_SERVICE}")"

  _expect "the outer-controller stream shape must pass" check_service \
    "${OUTER_SERVICE}" 0
  _expect "onDone without _noteAccessLost must fail" check_service \
    "$(sed -e "s/^        _noteAccessLost('position stream closed');$//" <<<"${OUTER_SERVICE}")" 1
  _expect "onError without _noteAccessLost must fail" check_service \
    "$(sed -e "s/^        _noteAccessLost('position stream error');$//" <<<"${OUTER_SERVICE}")" 1

  # The fresh path has its own ordering: it never serves the cache, but it is
  # the path that DISCOVERS a revocation and clears the cache for everyone
  # else, so a read placed ahead of its gate loses that too.
  _expect "getCurrentLocationFresh reading before its gate must fail" check_service \
    "$(awk '
        /^  Future<Position> getCurrentLocationFresh\(\) async \{$/ { inf = 1 }
        inf && /^    await _ensureAccessOrThrow\(\);$/ {
          print "    final geoPosition = await _geolocator.getCurrentPosition();"
          print $0
          inf = 0
          next
        }
        inf && /^    final geoPosition = await _geolocator.getCurrentPosition\(\);$/ { next }
        { print }' <<<"${GOOD_SERVICE}")" 1

  log "self-test: scheduler fixtures"

  _expect "a bounded publish chain passes" \
    check_scheduler "${GOOD_SCHEDULER}" 0

  # An unfinished future raises no error, so catchError cannot see it.
  _expect "an unbounded publish chain must fail" check_scheduler \
    "$(sed -e 's/\.timeout($//' -e 's/^            _publishLinkTimeout,$//' \
           -e "s/^            onTimeout: () => debugPrint('abandoned'),$//" \
           -e 's/^          ),$//' <<<"${GOOD_SCHEDULER}")" 1

  _expect "a publish chain without catchError must fail" check_scheduler \
    "${GOOD_SCHEDULER//.catchError((Object _) {})/}" 1

  # --- delegated shape: the bound lives SEVERAL calls deeper -----------------
  # The real scheduler's shape: the chain link delegates to a dispatcher that
  # BRANCHES — one branch hands the tick to the background burst sink and is
  # bounded there, the other walks a paced publish loop whose own bound is two
  # calls further down.
  _expect "a two-branch chain bounded on both branches passes" \
    check_scheduler "${GOOD_SCHEDULER_DELEGATED}" 0

  # THE HOLE THAT SHIPPED. Only the SINK branch's timeout is left. One level of
  # delegate resolution finds it, declares the chain bounded and prints
  # "the publish chain is bounded" — while the direct branch, two levels
  # deeper, has no bound at all and one hung publish stalls every circle.
  _expect "a direct branch that lost its bound must fail" check_scheduler \
    "$(sed -e '/await _publishCircle(circle, generation, fix: fix).timeout(/,+3c\
    await _publishCircle(circle, generation, fix: fix);' \
        <<<"${GOOD_SCHEDULER_DELEGATED}")" 1

  # ...and the mirror image: the SINK branch loses its bound while the direct
  # branch keeps one. A guard that only followed the chain to `_publishCircle`
  # would miss this, because the sink branch never reaches it.
  _expect "a sink branch that lost its bound must fail" check_scheduler \
    "$(sed -e '/return Future.wait(handovers).then<void>((_) {}).timeout(/,+3c\
    return Future.wait(handovers).then<void>((_) {});' \
        <<<"${GOOD_SCHEDULER_DELEGATED}")" 1

  # The link stops delegating and calls an UNBOUNDED function directly, while a
  # bounded-but-now-dead delegate remains in the file. A resolver that matched
  # the call site `await _publishCircle(...).timeout(` instead of the
  # declaration would find that stray timeout and pass an unbounded chain.
  _expect "a link calling an unbounded function directly must fail" \
    check_scheduler \
    "${GOOD_SCHEDULER_DELEGATED//await _pacedPublish(/await _publishCircle(}" 1

  # Unresolvable delegate: fail CLOSED. An unfollowable chain is not evidence
  # of a bounded one.
  _expect "an unresolvable delegate must fail closed" check_scheduler \
    "${GOOD_SCHEDULER_DELEGATED//Future<void> _dispatchBurst(/Future<void> _dispatchBurstGone(}" 1

  # The publish itself moves out of reach of the walk: nothing the chain can
  # follow awaits `_publishCircle` any more, so the guard has stopped being
  # able to certify anything and must say so instead of passing.
  _expect "a chain that no longer reaches the publish must fail closed" \
    check_scheduler \
    "${GOOD_SCHEDULER_DELEGATED//await _publishCircle(circle, generation, fix: fix).timeout(/await somethingElse(circle).timeout(}" 1

  if (( failures > 0 )); then
    printf '%s[%s] self-test FAILED (%d case(s)) — this guard cannot be trusted until it is fixed%s\n' \
      "${RED}" "${SCRIPT_NAME}" "${failures}" "${RESET}" >&2
    exit 2
  fi
  printf '%sOK: self-test passed (%d fixtures).%s\n' "${GREEN}" "${checked}" "${RESET}"
}

# ---------------------------------------------------------------------------
main() {
  if [[ "${1:-}" == "--self-test" ]]; then
    self_test
    return 0
  fi

  for f in "${SERVICE}" "${SCHEDULER}"; do
    [[ -f "${f}" ]] || misconfig "expected file not found: ${f}"
  done

  log "Checking the location access gate ordering ..."
  check_service "${SERVICE}"
  check_scheduler "${SCHEDULER}"

  if [[ "${FAILED}" -ne 0 ]]; then
    printf '%s[%s] location access gate guard FAILED — see failures above.%s\n' \
      "${RED}" "${SCRIPT_NAME}" "${RESET}" >&2
    exit 1
  fi
  printf '%sOK: the access gate precedes every coordinate-producing read; denials clear the cache; no background prompt; precision downgrade is seen; the publish chain is bounded; exactly one platform permission request is in flight at a time.%s\n' \
    "${GREEN}" "${RESET}"
}

main "$@"
