"""Prints the UDID of an available iPad simulator with the newest iOS runtime
at or above MIN, from `xcrun simctl list devices available -j` on stdin.

Usage: pick-ipad.py MIN
"""
import json
import sys

minimum = tuple(int(x) for x in sys.argv[1].split("."))
best = None
for runtime, devices in json.load(sys.stdin)["devices"].items():
    if ".iOS-" not in runtime:
        continue
    version = tuple(int(x) for x in runtime.rsplit(".iOS-", 1)[1].split("-"))
    if version < minimum:
        continue
    for d in devices:
        if d["name"].startswith("iPad") and (best is None or version > best[0]):
            best = (version, d["udid"])
print(best[1] if best else "")
