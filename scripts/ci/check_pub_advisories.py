"""CI guard: no Dart/Flutter package Haven resolves has a known advisory.

cargo-audit covers the Rust lockfiles; nothing covered haven/pubspec.lock, the
resolution the app ships. This reads every hosted package from it, fetches the
reviewed, unwithdrawn advisories GitHub's advisory database holds for the pub
ecosystem, and fails when a resolved version falls in a vulnerable range.

Usage:
  python3 -I scripts/ci/check_pub_advisories.py <pubspec.lock>   (GITHUB_TOKEN raises the rate limit)
  python3 -I scripts/ci/check_pub_advisories.py --self-test

Exit: 0 none affected, 1 an affected package, 2 cannot vouch (unreadable
lockfile, the database could not be read or answered nothing).
"""

import json
import os
import re
import sys
import urllib.request

API = "https://api.github.com/advisories?ecosystem=pub&type=reviewed&per_page=100"


def hosted_packages(lock_text):
    """{name: version} for every package pub.dev hosts in a pubspec.lock."""
    packages, name, block = {}, None, []

    def close():
        if name and "    source: hosted" in block:
            for line in block:
                m = re.fullmatch(r'    version: "?([^"]+)"?', line)
                if m:
                    packages[name] = m.group(1)

    for line in lock_text.splitlines():
        m = re.fullmatch(r"  ([a-z0-9_]+):", line)
        if m:
            close()
            name, block = m.group(1), []
        elif name:
            block.append(line)
    close()
    return packages


def version_key(version):
    """Orders semantic versions: build metadata ignored, a pre-release first."""
    core = version.split("+", 1)[0]
    release, _, pre = core.partition("-")
    numbers = tuple(int(p) for p in release.split("."))
    return numbers + (0,) * (3 - len(numbers)), (1,) if not pre else (0, pre)


def in_range(version, spec):
    """True when version satisfies a GitHub range such as '>= 1.0.0, < 1.2.3'."""
    ops = {
        "<": lambda a, b: a < b,
        "<=": lambda a, b: a <= b,
        ">": lambda a, b: a > b,
        ">=": lambda a, b: a >= b,
        "=": lambda a, b: a == b,
    }
    for part in spec.split(","):
        m = re.fullmatch(r"\s*(<=|>=|<|>|=)\s*(\S+)\s*", part)
        if not m:
            raise ValueError("unparsable range")
        if not ops[m.group(1)](version_key(version), version_key(m.group(2))):
            return False
    return True


def findings(packages, advisories):
    """(package, version, advisory id) for each affected resolution."""
    out = []
    for advisory in advisories:
        if advisory.get("withdrawn_at"):
            continue
        for vuln in advisory.get("vulnerabilities") or []:
            package = (vuln.get("package") or {})
            name = package.get("name")
            if package.get("ecosystem") != "pub" or name not in packages:
                continue
            if in_range(packages[name], vuln.get("vulnerable_version_range") or ""):
                out.append((name, packages[name], advisory["ghsa_id"]))
    return out


def fetch_all():
    advisories, url = [], API
    headers = {"Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"}
    if os.environ.get("GITHUB_TOKEN"):
        headers["Authorization"] = "Bearer " + os.environ["GITHUB_TOKEN"]
    while url:
        with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=30) as resp:
            advisories.extend(json.load(resp))
            m = re.search(r'<([^>]+)>;\s*rel="next"', resp.headers.get("Link") or "")
            url = m.group(1) if m else None
    return advisories


def check(lock_path, fetch):
    try:
        with open(lock_path, encoding="utf-8") as f:
            packages = hosted_packages(f.read())
    except OSError:
        print("check_pub_advisories: cannot read " + lock_path, file=sys.stderr)
        return 2
    if not packages:
        print("check_pub_advisories: no hosted package in " + lock_path, file=sys.stderr)
        return 2
    try:
        advisories = fetch()
    except Exception as e:  # noqa: BLE001 - any failure to read the database means no verdict
        print("check_pub_advisories: advisory database unreadable (" + type(e).__name__ + ")", file=sys.stderr)
        return 2
    if not advisories:
        print("check_pub_advisories: the advisory database answered no pub advisory", file=sys.stderr)
        return 2
    try:
        hits = findings(packages, advisories)
    except ValueError:
        print("check_pub_advisories: an advisory range did not parse", file=sys.stderr)
        return 2
    for name, version, ghsa in hits:
        print(f"FAIL {name} {version} is affected by {ghsa} (https://github.com/advisories/{ghsa})")
    if hits:
        return 1
    print(f"ok: {len(packages)} hosted packages, none affected by {len(advisories)} pub advisories")
    return 0


def self_test():
    lock = '''packages:
  http:
    dependency: "direct main"
    description:
      name: http
      sha256: "abc"
      url: "https://pub.dev"
    source: hosted
    version: "1.2.0"
  local_plugin:
    dependency: "direct overridden"
    description:
      path: "../third_party/local_plugin"
      relative: true
    source: path
    version: "5.2.1"
  flutter:
    dependency: "direct main"
    description: flutter
    source: sdk
    version: "0.0.0"
  dio:
    dependency: transitive
    description:
      name: dio
      sha256: "def"
      url: "https://pub.dev"
    source: hosted
    version: "5.0.0-dev.1+build.7"
sdks:
  dart: ">=3.10.0 <4.0.0"
'''

    def adv(ghsa, name, spec, withdrawn=None):
        return {"ghsa_id": ghsa, "withdrawn_at": withdrawn,
                "vulnerabilities": [{"package": {"ecosystem": "pub", "name": name},
                                     "vulnerable_version_range": spec}]}

    fails = 0

    def expect(label, got, want):
        nonlocal fails
        if got == want:
            print("  ok   " + label)
        else:
            print(f"  FAIL {label}: got {got!r}, want {want!r}")
            fails += 1

    expect("only hosted packages are read", hosted_packages(lock), {"http": "1.2.0", "dio": "5.0.0-dev.1+build.7"})
    expect("a version inside the range is affected", in_range("1.2.0", ">= 1.0.0, < 1.2.3"), True)
    expect("the patched version is not", in_range("1.2.3", ">= 1.0.0, < 1.2.3"), False)
    expect("a pre-release sorts before its release", in_range("5.0.0-dev.1", "< 5.0.0"), True)
    expect("build metadata is ignored", in_range("1.2.3+4", "<= 1.2.3"), True)
    expect("a two-part version compares as x.y.0", in_range("1.2", "< 1.2.1"), True)
    sample = [adv("GHSA-aaaa", "http", "< 1.2.1"), adv("GHSA-bbbb", "http", "< 1.0.0"),
              adv("GHSA-cccc", "http", "< 9.0.0", withdrawn="2026-01-01T00:00:00Z"),
              adv("GHSA-dddd", "local_plugin", "< 9.0.0"), adv("GHSA-eeee", "dio", ">= 5.0.0-dev.0, < 5.0.0")]
    expect("affected, unaffected, withdrawn and path packages are told apart",
           findings(hosted_packages(lock), sample),
           [("http", "1.2.0", "GHSA-aaaa"), ("dio", "5.0.0-dev.1+build.7", "GHSA-eeee")])
    try:
        in_range("1.0.0", "~> 1.0")
        expect("an unparsable range is refused", "accepted", "ValueError")
    except ValueError:
        expect("an unparsable range is refused", "ValueError", "ValueError")

    lock_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "haven", "pubspec.lock")
    expect("this tree's lockfile has hosted packages", len(hosted_packages(open(lock_path, encoding="utf-8").read())) > 50, True)
    expect("a clean lockfile passes", check(lock_path, lambda: [adv("GHSA-zzzz", "no_such_package", "< 1.0.0")]), 0)
    expect("an affected lockfile fails", check(lock_path, lambda: [adv("GHSA-yyyy", "http", ">= 0.0.1")]), 1)
    expect("an empty answer is refused", check(lock_path, lambda: []), 2)

    def unreachable():
        raise OSError("no network")

    expect("an unreachable database is refused", check(lock_path, unreachable), 2)
    expect("a missing lockfile is refused", check("/nonexistent/pubspec.lock", lambda: sample), 2)
    print("self-test: all cases passed" if fails == 0 else f"self-test: {fails} case(s) failed")
    return 1 if fails else 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        sys.exit(self_test())
    if len(sys.argv) == 2:
        sys.exit(check(sys.argv[1], fetch_all))
    print("usage: check_pub_advisories.py <pubspec.lock> | --self-test", file=sys.stderr)
    sys.exit(2)
