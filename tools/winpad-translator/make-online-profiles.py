#!/usr/bin/env python3
"""Writes data/online/profiles.json: all game profiles in one file, which the iPad app downloads.

The app carries the profiles of its build (data/profiles and data/protonfixes.json, copied into
it by tests/wine-app/build-xcode.sh). So that a fixed or new profile reaches it without a new
build, it also downloads this file from the repository (Library.m, WinPadUpdateOnlineProfiles:
raw.githubusercontent.com, the main branch, by default) and uses its profiles over its own when
they are newer (a higher "version") or new. Only data goes this way: what a profile can set is
what the app already does with it (DLL overrides, environment, arguments, registry, ...).

Run it after changing a profile; CI (tests/test_profiles.py) fails while the file is stale.

  make-online-profiles.py [--check] [OUT]
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from winpad_translator import profiles  # noqa: E402

OUT = os.path.join(HERE, "data", "online", "profiles.json")
FORMAT = 1


def bundle():
    """The file's text: format, then the profiles in the app's order (own ones, then Proton's)."""
    data = {
        "format": FORMAT,
        "about": "WinPad game profiles for the iPad app (made by tools/winpad-translator/make-online-profiles.py "
                 "from data/profiles and data/protonfixes.json; do not edit by hand).",
        "profiles": list(profiles.load_all().values()),
    }
    return json.dumps(data, ensure_ascii=False, indent=1, sort_keys=False) + "\n"


def main(argv):
    check = "--check" in argv
    args = [a for a in argv if a != "--check"]
    out = args[0] if args else OUT
    text = bundle()
    if check:
        try:
            with open(out, encoding="utf-8") as f:
                same = f.read() == text
        except FileNotFoundError:
            same = False
        if not same:
            print(f"{out} is stale: run tools/winpad-translator/make-online-profiles.py", file=sys.stderr)
            return 1
        return 0
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        f.write(text)
    print(f"{out}: {text.count(chr(10))} lines, {len(json.loads(text)['profiles'])} profiles")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
