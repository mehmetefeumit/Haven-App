#!/usr/bin/env python3
"""Reads one `uiautomator dump` for the Android launch gate.

Standard library only; run with `python3 -I` so nothing beside a dump (or this
file) can be imported in its place.

  ui-dump.py keys --arb <app_en.arb> --keys <k1,k2,...>
      Prints each requested key the ARB holds, one per line. A key whose value
      is not one plain line of text cannot be matched against a node, so it is
      a usage error (rc 2), as is an unreadable ARB.

  ui-dump.py observe --dump <file> --package <pkg> --arb <app_en.arb>
                     --keys <k1,...> [--edit-value-out <file>]
                     [--digest-out <file>]
      One observation of the dump, on stdout:
          observation ok
          foreground <package of the first root node>
          labelled <nodes carrying text or a content description>
          edittexts <count>
          visible <key> <x> <y>      one per key on screen, at its centre
      or `observation none <reason>` and rc 3 when the dump is empty or
      partial, or is our package's window with no labelled node yet (the first
      dump after Flutter's semantics tree is switched on). The value of the
      one EditText is written to --edit-value-out (0600), and only when exactly
      one exists: never to stdout, which reaches a public job log.
      --digest-out (0600) receives the screen digest: the sha256 of our
      package's distinct text and content-desc lines, sorted. Two dumps of one
      screen hash alike and any change to its text does not, which is how the
      runner tells a tap that took effect from one that did not. It hashes the
      display name too, so it is never printed either.

Matching is exact per LINE: a node's text and content-desc are split on
newlines (Flutter merges a subtree's labels that way) and a line must equal the
label. Curly apostrophes are folded to ASCII on both sides, because the ARB
holds both spellings (onboardingDisplayNameError uses U+2019) and only one
reaches the screen per string. Element-tree parsing decodes `&apos;` and every
other entity. A node is on screen when its bounds have area and lie at least
partly inside the root's.

  ui-dump.py --self-test

Exit: 0 ok, 2 usage, 3 no observation.
"""

import hashlib
import io
import json
import os
import re
import sys
import tempfile
import xml.etree.ElementTree as ET

EDIT_TEXT_CLASS = "android.widget.EditText"
BOUNDS_RE = re.compile(r"^\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]$")
APOSTROPHES = str.maketrans({"’": "'", "‘": "'"})


class Usage(Exception):
    pass


def fold(text):
    return text.translate(APOSTROPHES)


def labels_from_arb(arb_path, keys):
    try:
        with open(arb_path, encoding="utf-8") as handle:
            arb = json.load(handle)
    except (OSError, ValueError) as err:
        raise Usage(f"cannot read the ARB ({type(err).__name__})") from None
    if not isinstance(arb, dict):
        raise Usage("the ARB is not a JSON object")
    labels = {}
    for key in keys:
        if key not in arb:
            continue
        value = arb[key]
        if not isinstance(value, str) or not value or "\n" in value or "{" in value:
            raise Usage(f"ARB key {key} is not one plain line of text")
        labels[key] = fold(value)
    return labels


def bounds(node):
    match = BOUNDS_RE.match(node.get("bounds", ""))
    if not match:
        return None
    return tuple(int(group) for group in match.groups())


def on_screen(box, screen):
    if box is None or box[2] <= box[0] or box[3] <= box[1]:
        return False
    if screen is None:
        return True
    return box[0] < screen[2] and box[2] > screen[0] and box[1] < screen[3] and box[3] > screen[1]


def observe(dump_text, package, labels):
    """(stdout lines, None, the one EditText value or None, screen digest), or
    (None, reason, None, None)."""
    if not dump_text.strip():
        return None, "the dump is empty", None, None
    try:
        root = ET.fromstring(dump_text)
    except ET.ParseError:
        return None, "the dump is not a complete XML document", None, None
    if root.tag != "hierarchy":
        return None, "the dump has no hierarchy root", None, None
    roots = [child for child in root if child.tag == "node"]
    if not roots:
        return None, "the dump holds no node", None, None
    foreground = roots[0].get("package", "")
    screen = bounds(roots[0])
    labelled = 0
    edits = []
    visible = {}
    ours = set()
    for node in root.iter("node"):
        text = node.get("text", "")
        desc = node.get("content-desc", "")
        if text or desc:
            labelled += 1
        if node.get("package") == package:
            ours.update(line for line in text.split("\n") + desc.split("\n") if line)
        if node.get("class") == EDIT_TEXT_CLASS:
            edits.append(text)
        box = bounds(node)
        if not on_screen(box, screen):
            continue
        lines = {fold(line) for line in text.split("\n") + desc.split("\n")}
        for key, label in labels.items():
            if key not in visible and label in lines:
                visible[key] = ((box[0] + box[2]) // 2, (box[1] + box[3]) // 2)
    if foreground == package and labelled == 0:
        return None, "our window has no labelled node yet", None, None
    out = [
        "observation ok",
        f"foreground {foreground or '<none>'}",
        f"labelled {labelled}",
        f"edittexts {len(edits)}",
    ]
    out += [f"visible {key} {x} {y}" for key, (x, y) in sorted(visible.items())]
    digest = hashlib.sha256("\n".join(sorted(ours)).encode("utf-8")).hexdigest()
    return out, None, edits[0] if len(edits) == 1 else None, digest


def write_private(path, value):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(value)


def parse_args(argv):
    if not argv:
        raise Usage("no command")
    command, rest = argv[0], argv[1:]
    opts = {}
    while rest:
        flag = rest.pop(0)
        if not flag.startswith("--") or not rest:
            raise Usage(f"bad argument {flag!r}")
        opts[flag[2:]] = rest.pop(0)
    return command, opts


def main(argv, stdout=sys.stdout):
    command, opts = parse_args(argv)
    keys = [key for key in opts.get("keys", "").split(",") if key]
    if command == "keys":
        if "arb" not in opts or not keys or set(opts) != {"arb", "keys"}:
            raise Usage("keys needs --arb and --keys")
        for key in labels_from_arb(opts["arb"], keys):
            print(key, file=stdout)
        return 0
    if command == "observe":
        required = {"dump", "package", "arb", "keys"}
        if not required <= set(opts) or not set(opts) <= required | {"edit-value-out", "digest-out"} or not keys:
            raise Usage("observe needs --dump, --package, --arb and --keys")
        labels = labels_from_arb(opts["arb"], keys)
        try:
            with open(opts["dump"], encoding="utf-8", errors="replace") as handle:
                dump_text = handle.read()
        except OSError:
            dump_text = ""
        out, reason, edit_value, digest = observe(dump_text, opts["package"], labels)
        if out is None:
            print(f"observation none {reason}", file=stdout)
            return 3
        if "edit-value-out" in opts:
            if edit_value is not None:
                write_private(opts["edit-value-out"], edit_value)
            elif os.path.exists(opts["edit-value-out"]):
                os.remove(opts["edit-value-out"])
        if "digest-out" in opts:
            write_private(opts["digest-out"], digest)
        print("\n".join(out), file=stdout)
        return 0
    raise Usage(f"unknown command {command!r}")


# ---------------------------------------------------------------------------
# Self-test: hermetic dumps in the shape uiautomator writes, run through main()
# exactly as the runner calls it.
# ---------------------------------------------------------------------------
SELF_TEST_CASES = 22
PKG = "com.oblivioustech.haven"
SECRET_NAME = "Quiet Wanderer"


def node(cls="android.view.View", text="", desc="", pkg=PKG, box="[0,0][100,100]", children=""):
    return (
        f'<node index="0" text="{text}" resource-id="" class="{cls}" package="{pkg}" '
        f'content-desc="{desc}" checkable="false" checked="false" clickable="true" '
        f'enabled="true" focusable="true" focused="false" scrollable="false" '
        f'long-clickable="false" password="false" selected="false" bounds="{box}">{children}</node>'
    )


def dump(*roots):
    return (
        "<?xml version='1.0' encoding='UTF-8' standalone='yes' ?>"
        f'<hierarchy rotation="0">{"".join(roots)}</hierarchy>'
    )


def self_test():
    ran = 0
    failed = 0
    with tempfile.TemporaryDirectory() as tmp:
        arb = os.path.join(tmp, "app_en.arb")
        with open(arb, "w", encoding="utf-8") as handle:
            json.dump(
                {
                    "onboardingWelcomeCta": "Get Started",
                    "onboardingFinishSetupError": "Couldn't finish setting up your account.",
                    "onboardingDisplayNameError": "Couldn’t save that name.",
                    "commonSettings": "Settings",
                    "withPlaceholder": "Hello {name}",
                },
                handle,
            )
        keys = "onboardingWelcomeCta,onboardingFinishSetupError,onboardingDisplayNameError,commonSettings,notInArb"
        screen = "[0,0][1080,2400]"

        def run(dump_text, extra=(), keys_arg=keys):
            path = os.path.join(tmp, "dump.xml")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(dump_text)
            captured = io.StringIO()
            argv = ["observe", "--dump", path, "--package", PKG, "--arb", arb, "--keys", keys_arg, *extra]
            try:
                rc = main(argv, captured)
            except Usage:
                rc = 2
            return rc, captured.getvalue().rstrip("\n")

        def case(label, ok):
            nonlocal ran, failed
            ran += 1
            if ok:
                print(f"  PASS {label}")
            else:
                print(f"  FAIL {label}", file=sys.stderr)
                failed += 1

        welcome = dump(node(box=screen, children=node(cls="android.widget.Button", desc="Get Started", box="[40,2200][1040,2300]")))
        rc, out = run(welcome)
        case("(1) a visible CTA is reported with its centre", rc == 0 and "visible onboardingWelcomeCta 540 2250" in out.split("\n"))
        case("(2) the foreground package is the first root's", f"foreground {PKG}" in out.split("\n"))
        rc, out = run(dump(node(box=screen, children=node(desc="Get Started now", box="[0,0][10,10]"))))
        case("(3) a label inside a longer line is not a match", rc == 0 and "visible" not in out)
        rc, out = run(dump(node(box=screen, children=node(desc="Welcome&#10;Get Started", box="[0,0][10,10]"))))
        case("(4) a label on its own line of a merged description matches", "visible onboardingWelcomeCta" in out)
        rc, out = run(dump(node(box=screen, children=node(text="Couldn&apos;t finish setting up your account.", box="[0,0][10,10]"))))
        case("(5) &apos; in the dump matches an ASCII apostrophe label", "visible onboardingFinishSetupError" in out)
        rc, out = run(dump(node(box=screen, children=node(text="Couldn’t finish setting up your account.", box="[0,0][10,10]"))))
        case("(6) a curly apostrophe on screen matches an ASCII label", "visible onboardingFinishSetupError" in out)
        rc, out = run(dump(node(box=screen, children=node(text="Couldn't save that name.", box="[0,0][10,10]"))))
        case("(7) an ASCII apostrophe on screen matches a curly label", "visible onboardingDisplayNameError" in out)
        rc, out = run(dump(node(box=screen, children=node(desc="Settings", box="[50,50][50,90]"))))
        case("(8) a node with no area is not on screen", rc == 0 and "visible" not in out)
        rc, out = run(dump(node(box=screen, children=node(desc="Settings", box="[0,2500][100,2600]"))))
        case("(9) a node outside the screen is not on screen", rc == 0 and "visible" not in out)
        rc, out = run("")
        case("(10) an empty dump is no observation, rc 3", rc == 3 and out.startswith("observation none"))
        rc, out = run(welcome[: len(welcome) // 2])
        case("(11) a partial dump is no observation, rc 3", rc == 3 and out.startswith("observation none"))
        rc, out = run("ERROR: could not get idle state.")
        case("(12) uiautomator's idle error is no observation, rc 3", rc == 3)
        rc, out = run(dump(node(box=screen, children=node(box="[0,0][10,10]"))))
        case("(13) our window with no labelled node is no observation", rc == 3 and "no labelled node" in out)
        rc, out = run(dump(node(pkg="com.android.permissioncontroller", box=screen)))
        case("(14) a foreign window is an observation naming its package",
             rc == 0 and "foreground com.android.permissioncontroller" in out.split("\n"))
        value_out = os.path.join(tmp, "name")
        one_edit = dump(node(box=screen, children=node(cls=EDIT_TEXT_CLASS, text=SECRET_NAME, box="[0,900][1080,1000]")))
        rc, out = run(one_edit, ("--edit-value-out", value_out))
        with open(value_out, encoding="utf-8") as handle:
            stored = handle.read()
        case("(15) one EditText: counted, its value only in the 0600 file, never on stdout",
             rc == 0 and "edittexts 1" in out and stored == SECRET_NAME and SECRET_NAME not in out
             and (os.stat(value_out).st_mode & 0o777) == 0o600)
        two_edits = dump(node(box=screen, children=node(cls=EDIT_TEXT_CLASS, text=SECRET_NAME) + node(cls=EDIT_TEXT_CLASS, text="x")))
        rc, out = run(two_edits, ("--edit-value-out", value_out))
        case("(16) two EditTexts: counted, and no value is kept", rc == 0 and "edittexts 2" in out and not os.path.exists(value_out))
        rc, out = run(welcome, keys_arg="withPlaceholder")
        case("(17) an ARB value with a placeholder is a usage error", rc == 2)
        keys_out = io.StringIO()
        rc = main(["keys", "--arb", arb, "--keys", "commonSettings,notInArb"], keys_out)
        case("(18) keys lists the requested keys the ARB holds, and only those",
             rc == 0 and keys_out.getvalue() == "commonSettings\n")
        # The screen digest: in a 0600 file only, the same for one screen
        # however its nodes are ordered, different when any text changes, and
        # blind to another package's window.
        digest_out = os.path.join(tmp, "digest")

        def digest_of(dump_text):
            rc, out = run(dump_text, ("--digest-out", digest_out))
            with open(digest_out, encoding="utf-8") as handle:
                return rc, out, handle.read()

        dialog_a = node(desc="Not now", box="[40,2000][500,2100]") + node(text="Share your location in the background?", box="[40,900][1040,1000]")
        dialog_b = node(desc="Not now", box="[40,2000][500,2100]") + node(text="Share your location while you use Haven?", box="[40,900][1040,1000]")
        rc, out, first = digest_of(dump(node(box=screen, children=dialog_a)))
        case("(19) the digest is a sha256 kept in a 0600 file and never on stdout",
             rc == 0 and re.fullmatch(r"[0-9a-f]{64}", first) is not None and first not in out
             and (os.stat(digest_out).st_mode & 0o777) == 0o600)
        reordered = node(box=screen, children=node(text="Share your location in the background?", box="[40,900][1040,1000]")
                         + node(desc="Not now", box="[40,2000][500,2100]"))
        _, _, again = digest_of(dump(reordered))
        case("(20) one screen dumped twice, nodes in another order, has one digest", again == first)
        _, _, other = digest_of(dump(node(box=screen, children=dialog_b)))
        case("(21) a second dialog with the same button and other text has another digest", other != first)
        _, _, foreign = digest_of(dump(node(box=screen, children=dialog_a), node(pkg="com.android.systemui", desc="12:01", box=screen)))
        case("(22) another package's nodes do not move the digest", foreign == first)
    if ran != SELF_TEST_CASES:
        print(f"SELF-TEST FAIL: ran {ran} cases, expected {SELF_TEST_CASES}", file=sys.stderr)
        failed += 1
    if failed:
        print("ui-dump.py --self-test: FAILED", file=sys.stderr)
        return 1
    print(f"ui-dump.py --self-test: all {ran} cases passed")
    return 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        sys.exit(self_test())
    try:
        sys.exit(main(sys.argv[1:]))
    except Usage as err:
        print(f"ui-dump.py: {err}", file=sys.stderr)
        sys.exit(2)
