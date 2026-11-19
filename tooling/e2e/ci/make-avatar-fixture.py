#!/usr/bin/env python3
"""Writes the gallery photos the photo rounds pick, deterministically.

Standard library only; run with `python3 -I`.

  make-avatar-fixture.py --variant a|b --out <file.png>
      An 800x600 RGB PNG — not square, so uCrop's 1:1 lock does real work —
      with no ancillary chunk (no text, time or EXIF), the same bytes on every
      run. Variant a is diagonal stripes, b concentric squares, so the two
      never encode alike and a replaced photo is a different picture. No
      binary is committed: the lanes generate both.

  make-avatar-fixture.py --self-test

Exit: 0 ok, 1 self-test failed, 2 usage.
"""

import struct
import sys
import tempfile
import os
import zlib

WIDTH, HEIGHT = 800, 600
SIGNATURE = b"\x89PNG\r\n\x1a\n"


def chunk(kind, data):
    body = kind + data
    return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)


def pixel(variant, x, y):
    if variant == "a":
        band = ((x + y) // 40) % 3
        return ((200, 60, 40), (40, 160, 90), (50, 70, 200))[band]
    ring = max(abs(x - WIDTH // 2), abs(y - HEIGHT // 2)) // 30
    return (ring * 23 % 256, 255 - ring * 11 % 256, 90)


def png(variant):
    rows = bytearray()
    for y in range(HEIGHT):
        rows.append(0)  # filter: none
        for x in range(WIDTH):
            rows.extend(pixel(variant, x, y))
    header = struct.pack(">IIBBBBB", WIDTH, HEIGHT, 8, 2, 0, 0, 0)
    return SIGNATURE + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(bytes(rows), 9)) + chunk(b"IEND", b"")


def chunks(data):
    """[(kind, data)] with every CRC checked; raises ValueError otherwise."""
    if not data.startswith(SIGNATURE):
        raise ValueError("no PNG signature")
    out, at = [], len(SIGNATURE)
    while at < len(data):
        (length,) = struct.unpack(">I", data[at:at + 4])
        kind, body = data[at + 4:at + 8], data[at + 8:at + 8 + length]
        (crc,) = struct.unpack(">I", data[at + 8 + length:at + 12 + length])
        if zlib.crc32(kind + body) & 0xFFFFFFFF != crc:
            raise ValueError("bad CRC")
        out.append((kind, body))
        at += 12 + length
    return out


def self_test():
    failed = 0
    ran = 0

    def case(label, ok):
        nonlocal failed, ran
        ran += 1
        print(f"  {'PASS' if ok else 'FAIL'} {label}", file=sys.stdout if ok else sys.stderr)
        failed += 0 if ok else 1

    a1, a2, b = png("a"), png("a"), png("b")
    case("(1) the same variant is the same bytes every time", a1 == a2)
    case("(2) the two variants differ", a1 != b)
    for name, data in (("a", a1), ("b", b)):
        try:
            parts = chunks(data)
        except ValueError:
            parts = []
        kinds = [kind for kind, _ in parts]
        width, height = struct.unpack(">II", parts[0][1][:8]) if parts else (0, 0)
        raw = zlib.decompress(parts[1][1]) if len(parts) > 1 else b""
        case(f"(3{name}) variant {name}: signature and every CRC valid, IHDR/IDAT/IEND only, 800x600",
             kinds == [b"IHDR", b"IDAT", b"IEND"] and (width, height) == (WIDTH, HEIGHT)
             and len(raw) == HEIGHT * (1 + 3 * WIDTH))
    with tempfile.TemporaryDirectory() as tmp:
        out = os.path.join(tmp, "x.png")
        rc = main(["--variant", "b", "--out", out])
        with open(out, "rb") as handle:
            case("(4) --out writes the variant's bytes", rc == 0 and handle.read() == b)
        case("(5) an unknown variant is a usage error", main(["--variant", "c", "--out", out]) == 2)
    if failed or ran != 6:
        print("make-avatar-fixture.py --self-test: FAILED", file=sys.stderr)
        return 1
    print(f"make-avatar-fixture.py --self-test: all {ran} cases passed")
    return 0


def main(argv):
    if len(argv) != 4 or argv[0] != "--variant" or argv[2] != "--out" or argv[1] not in ("a", "b"):
        print("usage: make-avatar-fixture.py --variant a|b --out <file.png>", file=sys.stderr)
        return 2
    with open(argv[3], "wb") as handle:
        handle.write(png(argv[1]))
    return 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        sys.exit(self_test())
    sys.exit(main(sys.argv[1:]))
