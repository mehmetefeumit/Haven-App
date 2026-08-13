#!/usr/bin/env bash
# CI guard: FLAG_SECURE covers EVERY Activity, from exactly one registration
# site.
#
# `privacyWhatOthersSeeScreenshots` tells the user, in thirteen languages, that
# "On Android, Haven blocks screenshots and screen recording everywhere in the
# app". `FLAG_SECURE` is a WINDOW flag, so a per-Activity `setFlags` in
# `MainActivity.onCreate` makes that sentence true of MainActivity and of
# nothing else — and Haven hosts an Activity it does not own the source of:
# `com.yalantis.ucrop.UCropActivity`, which renders the user's picked photo
# full-screen. For as long as the flag lived in MainActivity the shipped promise
# was false on exactly the screen showing a photo, and no test or guard could
# tell, because the flag was set and the app looked protected.
#
# The fix is structural, so the guard is a UNION of the three links that make it
# hold. Any one of them can be removed on its own, each edit reads locally
# reasonable, and each leaves the other two looking correct:
#
#   1. REGISTERED, AND FROM THE ENTRY POINT. `HavenApplication.onCreate` must
#      call `registerActivityLifecycleCallbacks`. That call is what reaches
#      Activities whose `onCreate` we cannot edit; in any other method it is
#      dead code, since `onCreate` is the only Application hook Android runs.
#
#   2. THE CALLBACK ACTUALLY SETS THE FLAG, IN `onActivityCreated`. Bound to
#      that method's body rather than to the file, because the deadline is real:
#      the flag must be on the window BEFORE it is added to the WindowManager,
#      which `onActivityCreated` precedes and every later callback does not.
#      (`onActivityPreCreated` would be earlier still and is API 29+; minSdk
#      here is 23.) The body must SET the flag — a `clearFlags` here, the
#      natural "let the crop screen be screenshotted" edit, is an inversion a
#      presence grep would pass.
#
#   3. NOBODY SETS IT PER ACTIVITY. A second, isolated `FLAG_SECURE` is not
#      redundant belt-and-braces: it is the pattern the registration replaces,
#      and it makes the promise look owned by the Activity that carries it, so
#      the next Activity is added without one and the app-wide site is the last
#      thing anyone thinks to check. One owner, or none.
#
#   4. THE MANIFEST STILL NAMES THE APPLICATION. `android:name` on
#      `<application>` is what makes HavenApplication run at all. Drop it — or
#      let a merge resolve it to `android.app.Application` — and every link
#      above is intact, compiles, and executes never. Read with xmllint so an
#      XML-commented-out attribute cannot answer for a live one.
#
# Anti-vacuity floor: check 3 is a scan for an ABSENCE, so a scan that found no
# files would certify a clean tree forever. It therefore requires its own file
# set to contain the registration site, which is the one file it knows is there.
#
# Every source check reads a COMMENT-STRIPPED view: this guard's subject is a
# file whose KDoc names every token matched below, so prose that mentions a
# mechanism must never stand in for calling it.
#
# Pure grep/awk + xmllint (no Gradle, no device) — the runtime behaviour cannot
# be proven off-device, and this pins everything that can be proven statically.
#
# Usage:
#   check_flag_secure_app_wide.sh              # check the tree
#   check_flag_secure_app_wide.sh --self-test  # hermetic fixtures, no repo read
#
# Exit codes:
#   0  all checks pass
#   1  an invariant is violated
#   2  the guard itself is broken (its file set lost the registration site; a
#      manifest it cannot parse; a failed self-test)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ANDROID_SRC="${REPO_ROOT}/haven/android/app/src"
readonly APPLICATION_FILE="${ANDROID_SRC}/main/kotlin/com/oblivioustech/haven/HavenApplication.kt"
readonly MANIFEST="${ANDROID_SRC}/main/AndroidManifest.xml"
readonly APPLICATION_CLASS='HavenApplication'

# Kotlin and Java share Dart/Swift comment syntax, so one stripper serves `//`,
# `/* */` and KDoc. One output line per input line, so line numbers survive.
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

# Body of the first function whose signature contains $1, sliced from the
# already-comment-stripped source $2. Structure-bound: a token in a neighbouring
# method is not a token in this one.
#
# Kotlin has two body forms and the slice must end at the right one. A braced
# body ends by depth; an expression body (`fun f(a: Activity) = Unit`, which is
# how the no-op callbacks here are written) ends with its line, and treating it
# as brace-delimited would run the slice to EOF and swallow every method after
# it — silently turning a check bound to ONE method into a check on the file.
fn_body() {
  awk -v sig="$1" '
    !inbody && index($0, sig) > 0 { inbody = 1 }
    inbody {
      print
      o = gsub(/[{]/, "&"); c = gsub(/[}]/, "&")
      depth += o - c
      if (seen && depth <= 0) exit
      if (o > 0) { seen = 1; next }
      # No brace opened yet, so a `=` here opens an expression body. A signature
      # merely wrapped across lines reaches its `{` first and takes the branch
      # above.
      if (index($0, "=") > 0) exit
    }' <<<"$2"
}

# --- checks 1 + 2, factored so --self-test can drive them over fixtures ------
check_registration() {
  local file="$1" code on_create on_activity_created

  code="$(code_view "${file}")"

  on_create="$(fn_body 'fun onCreate(' "${code}")"
  if [[ -z "${on_create}" ]]; then
    echo "ERROR: ${file} has no Application.onCreate() in code."
    echo "onCreate is the only Application hook Android runs, so the app-wide"
    echo "FLAG_SECURE registration has nowhere left to happen."
    return 1
  fi
  if ! grep -q 'registerActivityLifecycleCallbacks(' <<<"${on_create}"; then
    echo "ERROR: ${file} does not register ActivityLifecycleCallbacks from"
    echo "onCreate(). Without that registration FLAG_SECURE reaches only the"
    echo "Activities Haven writes, and UCropActivity — which renders the user's"
    echo "picked photo full-screen — is not one of them, so"
    echo "privacyWhatOthersSeeScreenshots (\"everywhere in the app\") is false."
    return 1
  fi

  on_activity_created="$(fn_body 'fun onActivityCreated(' "${code}")"
  if [[ -z "${on_activity_created}" ]]; then
    echo "ERROR: ${file} registers lifecycle callbacks but implements no"
    echo "onActivityCreated, so no window is ever secured."
    return 1
  fi
  if ! grep -q 'FLAG_SECURE' <<<"${on_activity_created}" \
    || ! grep -qE '(set|add)Flags\(' <<<"${on_activity_created}"; then
    echo "ERROR: ${file}: onActivityCreated does not set FLAG_SECURE on the"
    echo "activity's window. It must be set THERE: the flag has to be on the"
    echo "window before the window is added to the WindowManager, which every"
    echo "later lifecycle callback is too late for."
    return 1
  fi
  if grep -q 'clearFlags(' <<<"${on_activity_created}"; then
    echo "ERROR: ${file}: onActivityCreated CLEARS a window flag. Exempting a"
    echo "screen from FLAG_SECURE contradicts the shipped promise that Haven"
    echo "blocks screenshots everywhere in the app; change the promise first."
    return 1
  fi
  return 0
}

# --- check 3, likewise ------------------------------------------------------
check_no_isolated_flag() {
  local root="$1" site="$2" files=() listing='' f view status=0

  mapfile -t files < <(find "${root}" -type f \( -name '*.kt' -o -name '*.java' \) | sort)
  if (( ${#files[@]} > 0 )); then
    listing="$(printf '%s\n' "${files[@]}")"
  fi

  # A scan for an absence that scanned nothing reports a clean tree. The one
  # file it can prove should be in range is the registration site itself.
  if ! grep -qxF "${site}" <<<"${listing}"; then
    echo "ERROR: scanned ${#files[@]} JVM source file(s) under ${root} without"
    echo "finding ${site} among them."
    echo "This guard is looking in the wrong place and is currently checking"
    echo "nothing — fix the path rather than deleting the guard."
    return 2
  fi

  for f in "${files[@]}"; do
    if [[ "${f}" == "${site}" ]]; then
      continue
    fi
    view="$(code_view "${f}")"
    if grep -q 'FLAG_SECURE' <<<"${view}"; then
      echo "ERROR: ${f} sets FLAG_SECURE itself."
      echo "The Application-wide registration in ${site}"
      echo "already covers every Activity in the process, including the ones"
      echo "Haven does not own. A per-Activity copy re-creates the split this"
      echo "replaced: it reads as if that Activity owns the protection, so the"
      echo "next Activity is added without one and nobody re-checks the"
      echo "app-wide site. One owner, or none."
      status=1
    fi
  done
  return "${status}"
}

# --- check 4, likewise ------------------------------------------------------
check_manifest_names_application() {
  local manifest="$1" name

  if ! xmllint --nonet --noout "${manifest}" 2>/dev/null; then
    echo "ERROR: ${manifest} is not well-formed XML; this guard cannot read it."
    return 2
  fi

  name="$(xmllint --nonet --xpath \
    "string(//application/@*[local-name()='name'])" "${manifest}" 2>/dev/null)"
  if [[ "${name}" != *".${APPLICATION_CLASS}" ]]; then
    echo "ERROR: ${manifest}: <application android:name> is"
    echo "\"${name:-(absent)}\", not the custom Application class"
    echo "${APPLICATION_CLASS}."
    echo "Every other half of this guard can be intact and still execute never:"
    echo "without this attribute Android instantiates android.app.Application,"
    echo "HavenApplication.onCreate does not run, no lifecycle callbacks are"
    echo "registered, and no window is secured."
    return 1
  fi
  return 0
}

# --- fixtures ---------------------------------------------------------------
# Two directions for every check, plus one mutation per mechanism: each fixture
# below removes exactly ONE of the four links and must be caught by exactly the
# check that owns it. A guard whose first mutation survives is the defect it was
# written to repair.
self_test() {
  local tmp failures=0
  tmp=$(mktemp -d)
  trap 'rm -rf "${tmp}"' RETURN

  record() {
    local want="$1" got="$2" name="$3"
    if (( got != want )); then
      echo "self-test FAILED [${name}]: expected exit ${want}, got ${got}" >&2
      failures=$((failures + 1))
    fi
  }

  reg_is() {
    local want="$1" name="$2" got
    printf '%s' "$3" >"${tmp}/App.kt"
    set +e; check_registration "${tmp}/App.kt" >/dev/null 2>&1; got=$?; set -e
    record "${want}" "${got}" "${name}"
  }

  # The fixture dir always carries the registration site, so check 3's own
  # anti-vacuity floor is satisfied and the verdict is about the extra file.
  iso_is() {
    local want="$1" name="$2" extra="$3" dir="${tmp}/iso" got
    rm -rf "${dir}"; mkdir -p "${dir}"
    printf 'class HavenApplication { fun c() { w.setFlags(FLAG_SECURE) } }\n' \
      >"${dir}/HavenApplication.kt"
    if [[ -n "${extra}" ]]; then printf '%s' "${extra}" >"${dir}/Other.kt"; fi
    set +e
    check_no_isolated_flag "${dir}" "${dir}/HavenApplication.kt" >/dev/null 2>&1
    got=$?
    set -e
    record "${want}" "${got}" "${name}"
  }

  # Fixtures declare the `android` prefix as the real manifest does: an
  # undeclared prefix leaves libxml2 with an attribute whose local-name is the
  # literal "android:name", which no fixture here is about.
  man_is() {
    local want="$1" name="$2" got
    printf '<manifest xmlns:android="http://schemas.android.com/apk/res/android">%s</manifest>' \
      "$3" >"${tmp}/AndroidManifest.xml"
    set +e
    check_manifest_names_application "${tmp}/AndroidManifest.xml" >/dev/null 2>&1
    got=$?
    set -e
    record "${want}" "${got}" "${name}"
  }

  # -- checks 1 + 2 ----------------------------------------------------------
  # Positive first: without it a guard hard-coded to fail passes every negative
  # fixture below and looks correct.
  reg_is 0 'registered from onCreate, flag set in onActivityCreated' \
'class HavenApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        registerActivityLifecycleCallbacks(SecureWindowCallbacks)
    }
}
private object SecureWindowCallbacks : Application.ActivityLifecycleCallbacks {
    override fun onActivityCreated(a: Activity, s: Bundle?) {
        a.window.setFlags(FLAG_SECURE, FLAG_SECURE)
    }
    override fun onActivityStarted(a: Activity) = Unit
}'

  # Mutation on link 1: the call survives, but outside the only method Android
  # runs. Compiles, reads fine in a diff, secures nothing.
  reg_is 1 'registration outside onCreate is dead code' \
'class HavenApplication : Application() {
    override fun onCreate() {
        super.onCreate()
    }
    fun installLater() {
        registerActivityLifecycleCallbacks(SecureWindowCallbacks)
    }
}
private object SecureWindowCallbacks : Application.ActivityLifecycleCallbacks {
    override fun onActivityCreated(a: Activity, s: Bundle?) {
        a.window.setFlags(FLAG_SECURE, FLAG_SECURE)
    }
}'

  # ...and the same mutation done by deleting the call while keeping the KDoc
  # that describes it. This is the shape the guarded file really has: its own
  # documentation names every token matched here.
  reg_is 1 'a registration named only in a comment is not a call' \
'/**
 * onCreate calls registerActivityLifecycleCallbacks(SecureWindowCallbacks) so
 * that onActivityCreated can set FLAG_SECURE via setFlags on every window.
 */
class HavenApplication : Application() {
    override fun onCreate() {
        super.onCreate()
    }
}'

  # Mutation on link 2, three ways it can be removed while link 1 still holds.
  reg_is 1 'callbacks registered but no onActivityCreated at all' \
'class HavenApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        registerActivityLifecycleCallbacks(SecureWindowCallbacks)
    }
}
private object SecureWindowCallbacks : Application.ActivityLifecycleCallbacks {
    override fun onActivityStarted(a: Activity) = Unit
}'

  reg_is 1 'the flag is set in a callback that is too late' \
'class HavenApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        registerActivityLifecycleCallbacks(SecureWindowCallbacks)
    }
}
private object SecureWindowCallbacks : Application.ActivityLifecycleCallbacks {
    override fun onActivityCreated(a: Activity, s: Bundle?) = Unit
    override fun onActivityResumed(a: Activity) {
        a.window.setFlags(FLAG_SECURE, FLAG_SECURE)
    }
}'

  reg_is 1 'onActivityCreated clears the flag instead of setting it' \
'class HavenApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        registerActivityLifecycleCallbacks(SecureWindowCallbacks)
    }
}
private object SecureWindowCallbacks : Application.ActivityLifecycleCallbacks {
    override fun onActivityCreated(a: Activity, s: Bundle?) {
        a.window.setFlags(FLAG_SECURE, FLAG_SECURE)
        if (a is CropActivity) a.window.clearFlags(FLAG_SECURE)
    }
}'

  # -- check 3 ---------------------------------------------------------------
  iso_is 0 'the registration site alone may set the flag' ''

  # Mutation on link 3: the pattern the app-wide registration replaced,
  # re-introduced beside it.
  iso_is 1 'an Activity setting FLAG_SECURE itself' \
'class MainActivity : FlutterActivity() {
    override fun onCreate(b: Bundle?) {
        window.setFlags(FLAG_SECURE, FLAG_SECURE)
    }
}'

  # False-positive direction, and the reason check 3 reads a comment-stripped
  # view rather than the raw file: explaining where the flag went must stay
  # possible, or the explanation gets deleted instead of the code.
  iso_is 0 'an Activity that only mentions FLAG_SECURE in prose' \
'// FLAG_SECURE is set app-wide from HavenApplication; do not add one here.
class MainActivity : FlutterActivity()'

  # Anti-vacuity: a scan whose file set lost the registration site is BROKEN,
  # never clean. Without this the guard passes forever on a renamed directory.
  local empty="${tmp}/empty"
  rm -rf "${empty}"; mkdir -p "${empty}"
  local got
  set +e
  check_no_isolated_flag "${empty}" "${empty}/HavenApplication.kt" >/dev/null 2>&1
  got=$?
  set -e
  record 2 "${got}" 'a file set with no sources in it is broken, not clean'

  # -- check 4 ---------------------------------------------------------------
  man_is 0 'the manifest names the custom Application' \
'<application android:name=".HavenApplication"/>'

  man_is 0 'a fully-qualified name is the same class' \
'<application android:name="com.oblivioustech.haven.HavenApplication"/>'

  # Mutation on link 4: everything else intact, nothing ever runs.
  man_is 1 'no android:name leaves HavenApplication uninstantiated' \
'<application android:label="Haven"/>'

  man_is 1 'a different Application class is not this one' \
'<application android:name=".OtherApplication"/>'

  # xmllint, not grep: an attribute inside an XML comment is not an attribute.
  man_is 1 'a commented-out android:name does not count' \
'<application android:label="Haven">
  <!-- android:name=".HavenApplication" -->
</application>'

  man_is 2 'a manifest this guard cannot parse is broken, not a violation' \
'<application android:name=".HavenApplication">'

  if (( failures )); then
    echo "This guard cannot be trusted until the ${failures} case(s) above are fixed." >&2
    return 2
  fi
  echo "App-wide FLAG_SECURE guard: self-test OK (14 fixtures)."
  return 0
}

command -v xmllint >/dev/null 2>&1 \
  || { echo "ERROR: xmllint (libxml2-utils) is required by this guard" >&2; exit 2; }

if [[ "${1:-}" == "--self-test" ]]; then
  self_test
  exit $?
fi

for path in "${APPLICATION_FILE}" "${MANIFEST}"; do
  [[ -f "${path}" ]] || { echo "ERROR: ${path} not found" >&2; exit 2; }
done

status=0
broken=0
# Every check runs even after one fails, so a red run names every broken link
# rather than the first — the same reason repo-guards.yml runs its steps under
# `if: !cancelled()`.
run_check() {
  local rc=0
  "$@" || rc=$?
  if (( rc == 2 )); then broken=1; elif (( rc != 0 )); then status=1; fi
}
run_check check_registration "${APPLICATION_FILE}"
run_check check_no_isolated_flag "${ANDROID_SRC}" "${APPLICATION_FILE}"
run_check check_manifest_names_application "${MANIFEST}"

if (( broken )); then
  exit 2
fi
if (( status == 0 )); then
  echo "OK: FLAG_SECURE is registered app-wide from HavenApplication.onCreate, set in onActivityCreated, set nowhere else, and the manifest still names the class."
fi
exit "${status}"
