"""Copies the static libraries of CMake's link of the iPad test app into the
Xcode project and writes its link flags, in link order, one per line, with
library paths as $(PROJECT_DIR)/lib/$(PLATFORM_NAME)/NAME.

Usage: link-libs.py BUILD_DIR LINK_COMMAND_FILE LIB_DIR FLAGS_OUT
"""
import os
import shlex
import shutil
import sys

build, command, libdir, flags_out = sys.argv[1:]
# CMake's Ninja link rule is ": && <link> && :".
with open(command) as fh:
    args = shlex.split(max(fh.read().split("&&"), key=len))
flags, seen = [], set()
i = 0
while i < len(args):
    a = args[i]
    if a.endswith(".a"):
        name = os.path.basename(a)
        if name in seen:
            sys.exit("two libraries named " + name)
        seen.add(name)
        shutil.copy(os.path.join(build, a), os.path.join(libdir, name))
        flags.append("$(PROJECT_DIR)/lib/$(PLATFORM_NAME)/" + name)
    elif a == "-framework":
        flags += [a, args[i + 1]]
        i += 1
    elif a.startswith("-framework "):
        flags += a.split()
    elif a.startswith("-l"):
        flags.append(a)
    i += 1
if not any(f.endswith("libWinPadProbeCore.a") for f in flags):
    sys.exit("libWinPadProbeCore.a is not on the link line")
with open(flags_out, "w") as fh:
    fh.write("\n".join(flags) + "\n")
print("\n".join(flags))
