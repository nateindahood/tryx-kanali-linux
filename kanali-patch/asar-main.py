#!/usr/bin/env python3
"""Point KANALI's app.asar package.json "main" at an external bootstrap (or back).

Usage: asar-main.py <app.asar> status
       asar-main.py <app.asar> patch <bootstrap-relative-path> <sidecar.json>
       asar-main.py <app.asar> restore <sidecar.json>

The edit is done in place with the same byte length (the value is padded with spaces), so
no other part of the archive moves. KANALI's original "main" is stored in the sidecar JSON
for the bootstrap to load and for `restore`.
"""
import json
import re
import struct
import sys


def locate(f):
    hdr = f.read(16)
    header = json.loads(f.read(struct.unpack("<I", hdr[12:16])[0]))
    base = 8 + struct.unpack("<I", hdr[4:8])[0]
    ent = header["files"]["package.json"]
    return base + int(ent["offset"]), int(ent["size"])


def main():
    asar, action = sys.argv[1], sys.argv[2]
    with open(asar, "r+b") as f:
        off, size = locate(f)
        f.seek(off)
        raw = f.read(size)
        text = raw.decode("utf-8")
        m = re.search(r'"main"\s*:\s*"([^"]*)"\s*', text)
        if not m:
            sys.exit("no \"main\" in package.json")
        current = m.group(1)

        def write_main(value):
            repl = '"main": "%s"' % value
            span = m.end() - m.start()
            if len(repl.encode()) > span:
                sys.exit("new main value too long for in-place edit")
            new = text[: m.start()] + repl + " " * (span - len(repl.encode())) + text[m.end():]
            assert len(new.encode()) == size
            json.loads(new)  # still valid JSON
            f.seek(off)
            f.write(new.encode())

        if action == "status":
            print(current)
        elif action == "patch":
            target, sidecar = sys.argv[3], sys.argv[4]
            if current != target:
                with open(sidecar, "w") as s:
                    json.dump({"main": current}, s)
                write_main(target)
            print("patched" if current != target else "already patched")
        elif action == "restore":
            sidecar = sys.argv[3]
            with open(sidecar) as s:
                orig = json.load(s)["main"]
            if current != orig:
                write_main(orig)
            print("restored")
        else:
            sys.exit("unknown action")


if __name__ == "__main__":
    main()
